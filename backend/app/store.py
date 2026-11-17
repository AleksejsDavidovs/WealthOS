"""Persistence for authorization attempts, connections, request nonces, rate limits and
short-lived page chunks.

- Enable Banking session ids are encrypted at rest (AES-256-GCM, connection id as AAD).
- The OAuth `state` is stored only as a SHA-256 hash.
- Every state transition is a single conditional UPDATE/DELETE whose affected-row count decides
  the outcome, so a callback, a completion or a page chunk can be used exactly once even under
  concurrent requests — without relying on an in-process lock. That keeps the same guarantees on
  a single SQLite file (local) and on Cloudflare D1 (many Worker isolates, one database).

The SQL lives here once; `SQLiteDatabase` and `app.cloudflare.D1Database` only execute it.
"""

from __future__ import annotations

import base64
import hashlib
import json
import os
import secrets
import sqlite3
import threading
import time
from dataclasses import dataclass
from pathlib import Path
from typing import Any, Protocol, Sequence

from cryptography.hazmat.primitives.ciphers.aead import AESGCM

ATTEMPT_TTL_SECONDS = 15 * 60
NONCE_TTL_SECONDS = 10 * 60
CHUNK_TTL_SECONDS = 10 * 60

SCHEMA_STATEMENTS = [
    """CREATE TABLE IF NOT EXISTS attempts (
        attempt_id TEXT PRIMARY KEY,
        state_hash TEXT NOT NULL UNIQUE,
        client_id TEXT NOT NULL,
        aspsp_name TEXT NOT NULL,
        aspsp_country TEXT NOT NULL,
        created_at INTEGER NOT NULL,
        expires_at INTEGER NOT NULL,
        status TEXT NOT NULL,
        error TEXT,
        connection_id TEXT
    )""",
    """CREATE TABLE IF NOT EXISTS connections (
        connection_id TEXT PRIMARY KEY,
        client_id TEXT NOT NULL,
        session_enc BLOB NOT NULL,
        aspsp_name TEXT NOT NULL,
        aspsp_country TEXT NOT NULL,
        valid_until TEXT,
        accounts_json TEXT NOT NULL,
        created_at INTEGER NOT NULL
    )""",
    """CREATE TABLE IF NOT EXISTS meta (
        key TEXT PRIMARY KEY,
        value TEXT NOT NULL
    )""",
    """CREATE TABLE IF NOT EXISTS nonces (
        client_id TEXT NOT NULL,
        nonce TEXT NOT NULL,
        seen_at INTEGER NOT NULL,
        PRIMARY KEY (client_id, nonce)
    )""",
    """CREATE TABLE IF NOT EXISTS rate_hits (
        bucket TEXT NOT NULL,
        window_start INTEGER NOT NULL,
        hits INTEGER NOT NULL,
        PRIMARY KEY (bucket, window_start)
    )""",
    """CREATE TABLE IF NOT EXISTS page_chunks (
        token_hash TEXT PRIMARY KEY,
        client_id TEXT NOT NULL,
        connection_id TEXT NOT NULL,
        account_uid TEXT NOT NULL,
        payload_enc TEXT NOT NULL,
        expires_at INTEGER NOT NULL
    )""",
]


ATTEMPT_COLUMNS = "attempt_id, client_id, aspsp_name, aspsp_country, expires_at, status, error, connection_id"


def sha256_hex(text: str) -> str:
    return hashlib.sha256(text.encode()).hexdigest()


@dataclass
class Attempt:
    attempt_id: str
    client_id: str
    aspsp_name: str
    aspsp_country: str
    expires_at: int
    status: str
    error: str | None
    connection_id: str | None


@dataclass
class Connection:
    connection_id: str
    client_id: str
    session_id: str
    aspsp_name: str
    aspsp_country: str
    valid_until: str | None
    accounts: list[dict]


class EnvironmentMismatch(RuntimeError):
    """The database belongs to another Enable Banking environment (sandbox vs production)."""


class Database(Protocol):
    """The two operations the store needs. Values are str / int / None only."""

    async def execute(self, sql: str, params: Sequence[Any] = ()) -> int:
        """Runs a statement; returns the number of rows it changed."""

    async def fetchone(self, sql: str, params: Sequence[Any] = ()) -> tuple | None:
        """Runs a statement (SELECT or ... RETURNING) and returns its first row."""

    async def batch(self, statements: Sequence[tuple[str, Sequence[Any]]]) -> list[tuple[int, list[tuple]]]:
        """Runs several statements atomically in one round trip; per statement (changes, rows)."""


class SQLiteDatabase:
    """A local SQLite file (or :memory: in tests)."""

    def __init__(self, path: Path | str):
        self.path = str(path)
        if self.path != ":memory:":
            file = Path(path)
            file.parent.mkdir(parents=True, exist_ok=True)
            os.chmod(file.parent, 0o700)
        self.connection = sqlite3.connect(self.path, check_same_thread=False, isolation_level=None)
        self._lock = threading.Lock()
        if self.path != ":memory:":
            self.connection.execute("PRAGMA journal_mode=WAL")
            os.chmod(self.path, 0o600)

    def execute_sync(self, sql: str, params: Sequence[Any] = ()) -> int:
        with self._lock:
            return self.connection.execute(sql, tuple(params)).rowcount

    def fetchone_sync(self, sql: str, params: Sequence[Any] = ()) -> tuple | None:
        with self._lock:
            cursor = self.connection.execute(sql, tuple(params))
            row = cursor.fetchone()
            cursor.fetchall()  # finish RETURNING statements
            return row

    def batch_sync(self, statements: Sequence[tuple[str, Sequence[Any]]]) -> list[tuple[int, list[tuple]]]:
        with self._lock:
            results = []
            self.connection.execute("BEGIN IMMEDIATE")
            try:
                for sql, params in statements:
                    cursor = self.connection.execute(sql, tuple(params))
                    rows = cursor.fetchall()
                    results.append((max(cursor.rowcount, 0), rows))
                self.connection.execute("COMMIT")
            except BaseException:
                self.connection.execute("ROLLBACK")
                raise
            return results

    async def execute(self, sql: str, params: Sequence[Any] = ()) -> int:
        return self.execute_sync(sql, params)

    async def batch(self, statements: Sequence[tuple[str, Sequence[Any]]]) -> list[tuple[int, list[tuple]]]:
        return self.batch_sync(statements)

    async def fetchone(self, sql: str, params: Sequence[Any] = ()) -> tuple | None:
        return self.fetchone_sync(sql, params)


def _seal_text(aead: AESGCM, plaintext: bytes, aad: bytes) -> str:
    nonce = os.urandom(12)
    return base64.b64encode(nonce + aead.encrypt(nonce, plaintext, aad)).decode()


def _sealed_bytes(value: Any) -> bytes:
    """Session ciphertext was stored as raw bytes by earlier versions and as base64 text now
    (D1 has no reliable BLOB round trip from Python). Both are read."""
    if isinstance(value, (bytes, bytearray, memoryview)):
        return bytes(value)
    if isinstance(value, str):
        return base64.b64decode(value)
    if isinstance(value, list):
        return bytes(value)
    raise ValueError("unreadable sealed value")


class Store:
    def __init__(self, path: Path | str | None, data_key: bytes, clock=time.time, environment: str | None = None, *,
                 database: Database | None = None):
        """`Store(path, key)` opens a SQLite file (prepared immediately, so a wrong environment
        fails at startup). `Store(None, key, database=D1Database(...))` uses another database;
        it is prepared on first use."""
        self._clock = clock
        self._aead = AESGCM(data_key)
        self._environment = environment
        self._prepared = False
        if database is None:
            if path is None:
                raise ValueError("A path or a database is required")
            sqlite = SQLiteDatabase(path)
            for statement in SCHEMA_STATEMENTS:
                sqlite.execute_sync(statement)
            if environment:
                row = sqlite.fetchone_sync("SELECT value FROM meta WHERE key = 'environment'")
                self._check_environment(row, environment, insert=lambda: sqlite.execute_sync(
                    "INSERT OR IGNORE INTO meta (key, value) VALUES ('environment', ?)", (environment,)))
            self._prepared = True
            database = sqlite
        self.database: Database = database

    @staticmethod
    def _check_environment(row, environment: str, insert) -> None:
        """The first server to open a database labels it; any other environment is refused, so
        sandbox sessions can never be served by a production server or the other way round."""
        if row is None:
            insert()
        elif row[0] != environment:
            raise EnvironmentMismatch(f"This database belongs to the {row[0]} environment, not {environment}")

    async def prepare(self) -> None:
        """Once per process/isolate. Usually a single read: the environment label exists only
        after the whole schema was created (they are written in one atomic batch)."""
        if self._prepared:
            return
        try:
            row = await self.database.fetchone("SELECT value FROM meta WHERE key = 'environment'")
        except Exception:  # noqa: BLE001 - a fresh database has no tables yet
            row = None
        if row is None:
            statements = [(sql, ()) for sql in SCHEMA_STATEMENTS]
            if self._environment:
                statements.append(("INSERT OR IGNORE INTO meta (key, value) VALUES ('environment', ?)",
                                   (self._environment,)))
            await self.database.batch(statements)
            row = await self.database.fetchone("SELECT value FROM meta WHERE key = 'environment'")
        if self._environment and (row is None or row[0] != self._environment):
            raise EnvironmentMismatch(
                f"This database belongs to the {row[0] if row else 'unknown'} environment, not {self._environment}")
        self._prepared = True

    async def _batch(self, statements: Sequence[tuple[str, Sequence[Any]]]) -> list[tuple[int, list[tuple]]]:
        await self.prepare()
        return await self.database.batch(statements)

    async def _execute(self, sql: str, params: Sequence[Any] = ()) -> int:
        await self.prepare()
        return await self.database.execute(sql, params)

    async def _fetchone(self, sql: str, params: Sequence[Any] = ()) -> tuple | None:
        await self.prepare()
        return await self.database.fetchone(sql, params)

    def now(self) -> int:
        return int(self._clock())

    # ---- attempts -------------------------------------------------------------------------

    async def create_attempt(self, client_id: str, aspsp_name: str, aspsp_country: str) -> tuple[str, str, int]:
        """Returns (attempt_id, state, expires_at). Only the hash of `state` is stored."""
        attempt_id = "att_" + secrets.token_urlsafe(18).replace("-", "x").replace("_", "y")
        state = secrets.token_urlsafe(32)
        now = self.now()
        expires = now + ATTEMPT_TTL_SECONDS
        await self._execute(
            "INSERT INTO attempts VALUES (?,?,?,?,?,?,?, 'pending', NULL, NULL)",
            (attempt_id, sha256_hex(state), client_id, aspsp_name, aspsp_country, now, expires),
        )
        return attempt_id, state, expires

    async def discard_attempt(self, attempt_id: str) -> None:
        await self._execute("DELETE FROM attempts WHERE attempt_id=? AND status='pending'", (attempt_id,))

    async def claim_attempt_by_state(self, state: str) -> Attempt | None:
        """Single use: atomically moves a pending, unexpired attempt to 'processing'."""
        row = await self._fetchone(
            "UPDATE attempts SET status='processing' WHERE state_hash=? AND status='pending' AND expires_at>? "
            "RETURNING " + ATTEMPT_COLUMNS,
            (sha256_hex(state), self.now()),
        )
        return Attempt(*row) if row else None

    async def finish_attempt(self, attempt_id: str, *, connection_id: str | None = None, error: str | None = None) -> None:
        await self._execute(
            "UPDATE attempts SET status=?, connection_id=?, error=? WHERE attempt_id=? AND status='processing'",
            ("completed" if connection_id else "failed", connection_id, error, attempt_id),
        )

    async def get_attempt(self, attempt_id: str) -> Attempt | None:
        row = await self._fetchone("SELECT " + ATTEMPT_COLUMNS + " FROM attempts WHERE attempt_id=?", (attempt_id,))
        return Attempt(*row) if row else None

    async def redeem_attempt(self, attempt_id: str, client_id: str) -> Attempt | None:
        """The app may fetch a completed attempt's connection exactly once."""
        row = await self._fetchone(
            "UPDATE attempts SET status='redeemed' WHERE attempt_id=? AND client_id=? AND status='completed' "
            "RETURNING " + ATTEMPT_COLUMNS,
            (attempt_id, client_id),
        )
        return Attempt(*row) if row else None

    # ---- connections ----------------------------------------------------------------------

    async def save_connection(self, client_id: str, session_id: str, aspsp_name: str, aspsp_country: str,
                              valid_until: str | None, accounts: list[dict]) -> str:
        connection_id = "con_" + secrets.token_hex(16)
        sealed = _seal_text(self._aead, session_id.encode(), connection_id.encode())
        await self._execute(
            "INSERT INTO connections VALUES (?,?,?,?,?,?,?,?)",
            (connection_id, client_id, sealed, aspsp_name, aspsp_country, valid_until,
             json.dumps(accounts, separators=(",", ":")), self.now()),
        )
        return connection_id

    async def get_connection(self, connection_id: str, client_id: str) -> Connection | None:
        """Ownership is enforced here: another client's connection is indistinguishable from none."""
        row = await self._fetchone(
            "SELECT connection_id, client_id, session_enc, aspsp_name, aspsp_country, valid_until, accounts_json "
            "FROM connections WHERE connection_id=? AND client_id=?",
            (connection_id, client_id),
        )
        if not row:
            return None
        sealed = _sealed_bytes(row[2])
        session_id = self._aead.decrypt(sealed[:12], sealed[12:], row[0].encode()).decode()
        return Connection(row[0], row[1], session_id, row[3], row[4], row[5], json.loads(row[6]))

    async def update_valid_until(self, connection_id: str, valid_until: str | None) -> None:
        await self._execute("UPDATE connections SET valid_until=? WHERE connection_id=?", (valid_until, connection_id))

    async def delete_connection(self, connection_id: str, client_id: str) -> bool:
        (deleted, _), _ = await self._batch([
            ("DELETE FROM connections WHERE connection_id=? AND client_id=?", (connection_id, client_id)),
            ("DELETE FROM page_chunks WHERE connection_id=? AND client_id=?", (connection_id, client_id)),
        ])
        return deleted == 1

    # ---- replay protection and rate limiting ----------------------------------------------

    @staticmethod
    def _hit_statements(bucket: str, now: int, window_seconds: int) -> list[tuple[str, tuple]]:
        window_start = now - now % window_seconds
        return [
            ("INSERT INTO rate_hits (bucket, window_start, hits) VALUES (?,?,1) "
             "ON CONFLICT(bucket, window_start) DO UPDATE SET hits = hits + 1 RETURNING hits", (bucket, window_start)),
            ("DELETE FROM rate_hits WHERE window_start<?", (now - 2 * window_seconds,)),
        ]

    async def use_nonce(self, client_id: str, nonce: str) -> bool:
        """False if this nonce was already used by this client within the TTL."""
        fresh, _ = await self.authorize_request(client_id, nonce, limit=None, window_seconds=60)
        return fresh

    async def authorize_request(self, client_id: str, nonce: str, *, limit: int | None,
                                window_seconds: int) -> tuple[bool, bool]:
        """For an already signature-verified request, in one atomic round trip: records the
        nonce (replay protection) and counts the client's rate-limit window.
        Returns (nonce_was_fresh, within_rate_limit)."""
        now = self.now()
        statements = [
            ("DELETE FROM nonces WHERE seen_at<?", (now - NONCE_TTL_SECONDS,)),
            ("INSERT OR IGNORE INTO nonces VALUES (?,?,?)", (client_id, nonce, now)),
        ]
        if limit is not None:
            statements += self._hit_statements("client:" + client_id, now, window_seconds)
        results = await self._batch(statements)
        fresh = results[1][0] == 1
        within = limit is None or (bool(results[2][1]) and int(results[2][1][0][0]) <= limit)
        return fresh, within

    async def allow(self, bucket: str, limit: int, window_seconds: int) -> bool:
        """Fixed-window counter shared by every server instance using this database."""
        results = await self._batch(self._hit_statements(bucket, self.now(), window_seconds))
        rows = results[0][1]
        return bool(rows) and int(rows[0][0]) <= limit

    # ---- page chunks ----------------------------------------------------------------------
    # A bank page that is too large to normalise within one request's CPU budget is served in
    # parts. The unsent rest is kept briefly, encrypted, bound to client/connection/account,
    # and can be taken exactly once.

    async def save_chunk(self, client_id: str, connection_id: str, account_uid: str, items: list,
                         bank_next_key: str | None) -> str:
        now = self.now()
        token = secrets.token_urlsafe(24)
        token_hash = sha256_hex(token)
        payload = json.dumps({"items": items, "next": bank_next_key}, separators=(",", ":")).encode()
        await self._batch([
            ("DELETE FROM page_chunks WHERE expires_at<?", (now,)),
            ("INSERT INTO page_chunks VALUES (?,?,?,?,?,?)",
             (token_hash, client_id, connection_id, account_uid,
              _seal_text(self._aead, payload, token_hash.encode()), now + CHUNK_TTL_SECONDS)),
        ])
        return token

    async def take_chunk(self, token: str, client_id: str, connection_id: str,
                         account_uid: str) -> tuple[list, str | None] | None:
        token_hash = sha256_hex(token)
        row = await self._fetchone(
            "DELETE FROM page_chunks WHERE token_hash=? AND client_id=? AND connection_id=? AND account_uid=? "
            "AND expires_at>=? RETURNING payload_enc",
            (token_hash, client_id, connection_id, account_uid, self.now()),
        )
        if not row:
            return None
        sealed = _sealed_bytes(row[0])
        data = json.loads(self._aead.decrypt(sealed[:12], sealed[12:], token_hash.encode()))
        return data["items"], data["next"]

    async def purge_expired(self) -> None:
        now = self.now()
        await self._execute("DELETE FROM attempts WHERE expires_at<?", (now - 24 * 3600,))
        await self._execute("DELETE FROM page_chunks WHERE expires_at<?", (now,))
