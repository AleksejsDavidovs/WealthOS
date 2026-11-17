"""Cloudflare Workers deployment: D1 storage semantics, WebCrypto-style JWT signing, page chunking,
shared rate limits, error/log hygiene and the wrangler configuration. No network, no real keys:
D1 is emulated over SQLite with D1's binding rules, the bank is an httpx MockTransport that
verifies every JWT like Enable Banking does, and the "WebCrypto" signer is backed by
`cryptography` so the token can be checked against the public key."""

from __future__ import annotations

import asyncio
import base64
import json
import logging
import re
import sqlite3
from pathlib import Path
from types import SimpleNamespace
from urllib.parse import parse_qs, urlparse

import httpx
import jwt
import pytest
from cryptography.hazmat.primitives import hashes, serialization
from cryptography.hazmat.primitives.asymmetric import padding, rsa
from fastapi.testclient import TestClient

from app import cloudflare
from app.cloudflare import D1Database, WorkerApp, build_app
from app.config import PRODUCTION_OPT_IN, ConfigError, Settings
from app.enable_banking import AsyncRS256Signer, pem_to_der
from app.main import CHUNK_PREFIX, CHUNK_SIZE, create_app
from app.security import sign
from app.store import EnvironmentMismatch, Store

SECRET = "0123456789abcdef" * 4
APP_ID = "00000000-0000-0000-0000-00000000cafe"
KEY = rsa.generate_private_key(public_exponent=65537, key_size=2048)
PEM = KEY.private_bytes(serialization.Encoding.PEM, serialization.PrivateFormat.PKCS8,
                        serialization.NoEncryption()).decode()
PUBLIC = KEY.public_key()
WRANGLER = Path(__file__).resolve().parents[1] / "cloudflare" / "wrangler.jsonc"


# ---- D1 emulation -------------------------------------------------------------------------------

NULL = object()  # stands in for pyodide.ffi.jsnull


class FakeD1:
    """The parts of the D1 binding API the adapter uses, with D1's restrictions: `undefined`
    (Python None crossing into JS) is rejected, and only text/number values are bound."""

    def __init__(self, connection: sqlite3.Connection | None = None):
        self.connection = connection or sqlite3.connect(":memory:", isolation_level=None, check_same_thread=False)
        self.round_trips = 0

    def prepare(self, sql):
        return FakeStatement(self, sql, ())

    async def batch(self, statements):
        """Like D1: one round trip, one transaction, rows as column-keyed objects."""
        self.round_trips += 1
        results = []
        self.connection.execute("BEGIN")
        try:
            for statement in statements:
                cursor = self.connection.execute(statement.sql, statement._args())
                rows = cursor.fetchall()
                columns = [c[0] for c in cursor.description or []]
                results.append(SimpleNamespace(results=[dict(zip(columns, row)) for row in rows],
                                               meta=SimpleNamespace(changes=max(cursor.rowcount, 0))))
            self.connection.execute("COMMIT")
        except BaseException:
            self.connection.execute("ROLLBACK")
            raise
        return results


class FakeStatement:
    def __init__(self, db, sql, params):
        self.db, self.sql, self.params = db, sql, params

    def bind(self, *params):
        for value in params:
            if value is None:
                raise TypeError("D1_TYPE_ERROR: Type 'undefined' not supported")
            if not (value is NULL or isinstance(value, (str, int, float))):
                raise TypeError(f"D1_TYPE_ERROR: unsupported {type(value).__name__}")
        return FakeStatement(self.db, self.sql, params)

    def _args(self):
        return tuple(None if value is NULL else value for value in self.params)

    async def run(self):
        self.db.round_trips += 1
        cursor = self.db.connection.execute(self.sql, self._args())
        cursor.fetchall()
        return SimpleNamespace(meta=SimpleNamespace(changes=max(cursor.rowcount, 0)))

    async def raw(self):
        self.db.round_trips += 1
        return [list(row) for row in self.db.connection.execute(self.sql, self._args()).fetchall()]


# ---- fake bank over HTTP ------------------------------------------------------------------------

def bank_tx(i):
    return {"transaction_id": f"t{i}", "transaction_amount": {"currency": "EUR", "amount": f"{i}.10"},
            "credit_debit_indicator": "DBIT", "status": "BOOK", "booking_date": "2026-11-05",
            "creditor": {"name": "Counterparty Secret Name"}, "creditor_account": {"iban": "LV97HABA0012345678910"},
            "remittance_information": [f"payment {i}"]}


class FakeBank:
    def __init__(self, page_sizes=(400, 30)):
        self.calls, self.states, self.jwts, self.psu_headers = [], [], 0, []
        keys = [None] + [f"bank-key-{n}" for n in range(1, len(page_sizes))]
        self.pages, start = {}, 0
        for index, size in enumerate(page_sizes):
            nxt = keys[index + 1] if index + 1 < len(keys) else None
            self.pages[keys[index]] = {"transactions": [bank_tx(i) for i in range(start, start + size)],
                                       "continuation_key": nxt}
            start += size

    def __call__(self, request: httpx.Request) -> httpx.Response:
        token = request.headers["Authorization"].removeprefix("Bearer ")
        header = jwt.get_unverified_header(token)
        # Signature, audience and issuer are verified; time claims are checked against the test clock.
        claims = jwt.decode(token, PUBLIC, algorithms=["RS256"], audience="api.enablebanking.com",
                            issuer="enablebanking.com", options={"verify_iat": False, "verify_exp": False})
        assert claims["exp"] - claims["iat"] == 3600
        assert header == {"alg": "RS256", "typ": "JWT", "kid": APP_ID}
        self.jwts += 1
        self.psu_headers.append({k: v for k, v in request.headers.items() if k.lower().startswith("psu-")})
        path = request.url.path
        self.calls.append((request.method, path, dict(request.url.params)))
        if path == "/auth":
            self.states.append(json.loads(request.content)["state"])
            return httpx.Response(200, json={"url": "https://tilisy.enablebanking.com/x", "authorization_id": "a"})
        if path == "/sessions":
            return httpx.Response(200, json={"session_id": "sess-SECRET-cf", "access": {"valid_until": "2027-02-01T00:00:00+00:00"},
                                             "accounts": [{"uid": "acc-1", "account_id": {"iban": "LV80HABA0551000000001"}, "currency": "EUR"},
                                                          {"uid": "acc-2", "account_id": {"iban": "LV80HABA0551000000002"}, "currency": "EUR"}]})
        if path.startswith("/sessions/") and request.method == "DELETE":
            return httpx.Response(200, json={})
        if path.startswith("/sessions/"):
            return httpx.Response(200, json={"status": "AUTHORIZED"})
        if path.endswith("/transactions"):
            return httpx.Response(200, json=self.pages[request.url.params.get("continuation_key")])
        if path.endswith("/balances"):
            return httpx.Response(200, json={"balances": []})
        return httpx.Response(404, json={})


async def cryptography_import_key(der):
    return serialization.load_der_private_key(der, None)


async def cryptography_sign(key, data):
    return key.sign(data, padding.PKCS1v15(), hashes.SHA256())


def worker_env(**overrides):
    values = dict(EB_ENVIRONMENT="sandbox", EB_APPLICATION_ID=APP_ID, EB_PRIVATE_KEY_PEM=PEM,
                  EB_API_BASE="https://api.enablebanking.com",
                  EB_REDIRECT_URL="https://wealthos-banking-sandbox.example.workers.dev/v1/callback",
                  WOS_ALLOWED_HOSTS="wealthos-banking-sandbox.example.workers.dev", WOS_CLIENT_ID="wealthos-ios",
                  WOS_CLIENT_SECRET=SECRET, WOS_DATA_KEY=base64.b64encode(b"d" * 32).decode(),
                  WOS_TRUST_CF_CONNECTING_IP="true")
    values.update(overrides)
    return SimpleNamespace(**values)


class Worker:
    """One Worker isolate. Several can share one FakeD1, like isolates share one D1 database."""

    def __init__(self, d1: FakeD1 | None = None, bank: FakeBank | None = None, **env):
        self.now = 1_800_000_000
        self.d1 = d1 or FakeD1()
        self.bank = bank or FakeBank()
        self.app = build_app(worker_env(**env), clock=lambda: self.now, database=D1Database(self.d1, null=NULL),
                             import_key=cryptography_import_key, sign=cryptography_sign,
                             eb_transport=httpx.MockTransport(self.bank))
        self.http = TestClient(self.app, base_url="https://wealthos-banking-sandbox.example.workers.dev",
                               follow_redirects=False)
        self.nonce = 0

    def signed(self, method, path, body=None, extra=None):
        data = json.dumps(body, separators=(",", ":")).encode() if body is not None else b""
        self.nonce += 1
        nonce, ts = f"cf-nonce-{self.nonce:08d}", str(self.now)
        headers = {"X-WOS-Client": "wealthos-ios", "X-WOS-Timestamp": ts, "X-WOS-Nonce": nonce,
                   "X-WOS-Signature": sign(SECRET, method, path, ts, nonce, data)}
        if body is not None:
            headers["Content-Type"] = "application/json"
        headers.update(extra or {})
        return self.http.request(method, path, content=data or None, headers=headers)

    def connect(self) -> str:
        start = self.signed("POST", "/v1/auth/start", {"aspsp_name": "Swedbank", "aspsp_country": "LV", "psu_type": "personal"})
        assert start.status_code == 200, start.text
        assert self.http.get(f"/v1/callback?code=CODE-cf&state={self.bank.states[-1]}").status_code == 302
        done = self.signed("POST", "/v1/auth/complete", {"attempt_id": start.json()["attempt_id"]})
        assert done.status_code == 200, done.text
        return done.json()["connection_id"]

    def read_all(self, connection, account="acc-1"):
        key, items, parts = None, [], []
        while True:
            path = f"/v1/connections/{connection}/accounts/{account}/transactions?date_from=2026-08-01"
            if key:
                path += "&continuation_key=" + key
            response = self.signed("GET", path)
            assert response.status_code == 200, response.text
            page = response.json()
            items += page["transactions"]
            parts.append((len(page["transactions"]), page["continuation_key"]))
            key = page["continuation_key"]
            if not key:
                return items, parts


# ---- full flow on D1 ------------------------------------------------------------------------------

def test_full_flow_on_d1_with_verified_jwts_and_single_use_state():
    w = Worker()
    connection = w.connect()
    assert w.bank.jwts >= 2  # /auth and /sessions, each verified against the public key
    replay = w.http.get(f"/v1/callback?code=CODE-cf&state={w.bank.states[-1]}")
    assert replay.status_code == 400
    assert w.signed("GET", f"/v1/connections/{connection}").json()["status"] == "AUTHORIZED"


def test_d1_rejects_undefined_so_the_adapter_must_send_null():
    statement = FakeD1().prepare("SELECT ?")
    with pytest.raises(TypeError):
        statement.bind(None)
    db = D1Database(FakeD1(), null=NULL)
    assert asyncio.run(db.fetchone("SELECT ?", (None,))) == (None,)


def test_empty_object_from_d1_is_read_as_null():
    assert cloudflare._cell({}) is None and cloudflare._cell("x") == "x"


def test_nonce_replay_is_rejected_on_d1():
    w = Worker()
    path = "/v1/connections/con_x"
    ts, nonce = str(w.now), "replayed-nonce-1"
    headers = {"X-WOS-Client": "wealthos-ios", "X-WOS-Timestamp": ts, "X-WOS-Nonce": nonce,
               "X-WOS-Signature": sign(SECRET, "GET", path, ts, nonce, b"")}
    assert w.http.get(path, headers=headers).status_code == 404  # authenticated, unknown connection
    assert w.http.get(path, headers=headers).status_code == 401  # same nonce again


def test_session_and_chunks_are_encrypted_at_rest_in_d1():
    w = Worker()
    connection = w.connect()
    first = w.signed("GET", f"/v1/connections/{connection}/accounts/acc-1/transactions?date_from=2026-08-01").json()
    assert first["continuation_key"].startswith(CHUNK_PREFIX)
    dump = "\n".join(w.d1.connection.iterdump())
    for secret in ["sess-SECRET-cf", "Counterparty Secret Name", "LV97HABA0012345678910", "payment 399",
                   first["continuation_key"][len(CHUNK_PREFIX):]]:
        assert secret not in dump


def test_database_of_another_environment_is_refused_on_d1():
    d1 = FakeD1()
    asyncio.run(Store(None, b"d" * 32, environment="sandbox", database=D1Database(d1, null=NULL)).prepare())
    with pytest.raises(EnvironmentMismatch):
        asyncio.run(Store(None, b"d" * 32, environment="production", database=D1Database(d1, null=NULL)).prepare())


# ---- large pages are served in parts ---------------------------------------------------------------

def test_large_bank_page_is_served_in_parts_then_continues_with_the_bank():
    w = Worker(bank=FakeBank(page_sizes=(400, 30)))
    connection = w.connect()
    items, parts = w.read_all(connection)
    assert [t["transaction_id"] for t in items] == [f"t{i}" for i in range(430)]  # complete, in order, no dupes
    assert [n for n, _ in parts] == [CHUNK_SIZE, CHUNK_SIZE, 100, 30]
    transaction_calls = [c for c in w.bank.calls if c[1].endswith("/transactions")]
    assert len(transaction_calls) == 2  # the bank is asked once per bank page, never again for parts
    assert transaction_calls[1][2]["continuation_key"] == "bank-key-1"


def test_small_pages_pass_through_unchanged():
    w = Worker(bank=FakeBank(page_sizes=(20, 5)))
    connection = w.connect()
    items, parts = w.read_all(connection)
    assert len(items) == 25 and parts[0][1] == "bank-key-1"


def test_part_token_is_single_use_and_bound_to_its_account():
    w = Worker()
    connection = w.connect()
    base = f"/v1/connections/{connection}/accounts/%s/transactions?date_from=2026-08-01"
    key = w.signed("GET", base % "acc-1").json()["continuation_key"]
    other = w.signed("GET", (base % "acc-2") + "&continuation_key=" + key)
    assert other.status_code == 503 and other.json() == {"error": "page_expired"}
    # The failed attempt on another account does not consume it, the right account takes it once.
    assert w.signed("GET", (base % "acc-1") + "&continuation_key=" + key).status_code == 200
    assert w.signed("GET", (base % "acc-1") + "&continuation_key=" + key).status_code == 503


def test_part_token_expires():
    w = Worker()
    connection = w.connect()
    base = f"/v1/connections/{connection}/accounts/acc-1/transactions?date_from=2026-08-01"
    key = w.signed("GET", base).json()["continuation_key"]
    w.now += 11 * 60
    assert w.signed("GET", base + "&continuation_key=" + key).status_code == 503


def test_disconnect_drops_pending_parts():
    w = Worker()
    connection = w.connect()
    w.signed("GET", f"/v1/connections/{connection}/accounts/acc-1/transactions?date_from=2026-08-01")
    assert w.d1.connection.execute("SELECT COUNT(*) FROM page_chunks").fetchone()[0] == 1
    assert w.signed("DELETE", f"/v1/connections/{connection}").status_code == 200
    assert w.d1.connection.execute("SELECT COUNT(*) FROM page_chunks").fetchone()[0] == 0


def test_parts_work_on_local_sqlite_too():
    from tests.test_backend import Harness, tx

    h = Harness()
    h.eb.pages = {None: {"transactions": [tx(f"t{i}", "1.00", "DBIT") for i in range(CHUNK_SIZE + 10)]}}
    connection = h.connect()["connection_id"]
    base = f"/v1/connections/{connection}/accounts/acc-1/transactions?date_from=2026-11-01"
    first = h.signed("GET", base).json()
    second = h.signed("GET", base + "&continuation_key=" + first["continuation_key"]).json()
    assert len(first["transactions"]) == CHUNK_SIZE and len(second["transactions"]) == 10
    assert second["continuation_key"] is None


# ---- rate limits are shared between isolates ----------------------------------------------------------

def test_rate_limit_is_shared_by_isolates_using_the_same_database():
    d1 = FakeD1()
    a, b = Worker(d1=d1), Worker(d1=d1)
    statuses = [(a if i % 2 else b).http.get("/v1/callback?state=x&code=y", headers={"CF-Connecting-IP": "203.0.113.7"}).status_code
                for i in range(21)]
    assert statuses[:20] == [400] * 20 and statuses[20] == 429
    # Another address has its own budget; a new minute starts fresh.
    assert a.http.get("/v1/callback?state=x", headers={"CF-Connecting-IP": "203.0.113.8"}).status_code == 400
    a.now += 120
    assert a.http.get("/v1/callback?state=x", headers={"CF-Connecting-IP": "203.0.113.7"}).status_code == 400


def test_cf_connecting_ip_is_ignored_unless_trusted():
    from tests.test_backend import Harness

    h = Harness()  # local server: the header is client-controlled and must not create new budgets
    statuses = [h.http.get("/v1/callback?state=x", headers={"CF-Connecting-IP": f"198.51.100.{i}"}).status_code
                for i in range(21)]
    assert statuses[20] == 429


# ---- errors and logs --------------------------------------------------------------------------------

def test_unexpected_error_returns_bare_json_without_details():
    from tests.test_backend import Harness

    h = Harness()
    connection = h.connect()["connection_id"]

    async def boom(*_args, **_kwargs):
        raise RuntimeError("sess-SECRET-1 leaked in a message")

    h.eb.balances = boom
    response = h.signed("GET", f"/v1/connections/{connection}/accounts/acc-1/balances")
    assert response.status_code == 500 and response.json() == {"error": "internal"}
    assert "SECRET" not in response.text and "Traceback" not in response.text


def _asgi_get(app, path="/v1/health"):
    sent = []

    async def receive():
        return {"type": "http.request", "body": b"", "more_body": False}

    async def send(message):
        sent.append(message)

    scope = {"type": "http", "method": "GET", "path": path, "raw_path": path.encode(), "query_string": b"",
             "headers": [(b"host", b"x")], "env": SimpleNamespace()}
    asyncio.run(app(scope, receive, send))
    return sent


def test_worker_that_cannot_start_answers_503_without_details():
    def broken(_env):
        raise ConfigError("WOS_DATA_KEY must decode to 32 bytes — value was abc")

    sent = _asgi_get(WorkerApp(builder=broken))
    assert sent[0]["status"] == 503
    assert json.loads(sent[1]["body"]) == {"error": "unavailable"}


def test_worker_logs_nothing(capsys, caplog):
    caplog.set_level(logging.DEBUG)
    w = Worker()
    connection = w.connect()
    w.read_all(connection)
    out = capsys.readouterr()
    assert out.out == "" and out.err == ""
    assert not [r for r in caplog.records if r.name == "wealthos.banking"]
    logging.getLogger("wealthos.banking").disabled = False  # leave other tests' logging intact


# ---- configuration --------------------------------------------------------------------------------

def test_settings_come_from_worker_bindings():
    settings = cloudflare.settings_from_env(worker_env())
    assert settings.wos_storage == "d1" and settings.wos_trust_cf_connecting_ip is True
    assert settings.private_key_pem().startswith(b"-----BEGIN PRIVATE KEY-----")
    settings.validate_runtime(check_key_file=False)


def test_key_configuration_guards():
    def build(**values):
        base = dict(EB_APPLICATION_ID=APP_ID, EB_REDIRECT_URL="http://localhost:8787/v1/callback",
                    WOS_CLIENT_ID="wealthos-ios", WOS_CLIENT_SECRET=SECRET,
                    WOS_DATA_KEY=base64.b64encode(b"d" * 32).decode(), WOS_DB_PATH=":memory:")
        base.update(values)
        return Settings(_env_file=None, **base)  # type: ignore[call-arg]

    with pytest.raises(ConfigError):
        build().validate_runtime(check_key_file=False)  # no key at all
    with pytest.raises(ConfigError):
        build(EB_PRIVATE_KEY_PEM=PEM, EB_PRIVATE_KEY_PATH="/x.pem").validate_runtime(check_key_file=False)
    with pytest.raises(ConfigError):
        build(EB_PRIVATE_KEY_PEM="-----BEGIN RSA PRIVATE KEY-----\nabc\n-----END RSA PRIVATE KEY-----").validate_runtime()
    with pytest.raises(ConfigError):
        build(EB_PRIVATE_KEY_PEM=PEM, WOS_STORAGE="postgres").validate_runtime()
    build(EB_PRIVATE_KEY_PEM=PEM).validate_runtime()
    # Production on D1 needs no local database path, but still the explicit opt-in.
    prod = dict(EB_PRIVATE_KEY_PEM=PEM, EB_ENVIRONMENT="production", WOS_STORAGE="d1",
                EB_REDIRECT_URL="https://p.example.workers.dev/v1/callback", WOS_ALLOWED_HOSTS="p.example.workers.dev")
    with pytest.raises(ConfigError):
        build(**prod).validate_runtime()
    build(**prod, WOS_ALLOW_PRODUCTION=PRODUCTION_OPT_IN).validate_runtime()


def test_d1_storage_cannot_silently_fall_back_to_a_local_file():
    settings = cloudflare.settings_from_env(worker_env())
    with pytest.raises(ConfigError):
        create_app(settings, eb_client=object(), check_key_file=False)


def test_async_signer_builds_a_valid_enable_banking_jwt_and_caches_it():
    now = [1_800_000_000]
    imports = []

    async def import_key(der):
        imports.append(der)
        return await cryptography_import_key(der)

    signer = AsyncRS256Signer(APP_ID, PEM.encode(), import_key=import_key, sign=cryptography_sign, clock=lambda: now[0])
    token = asyncio.run(signer.get_token())
    assert jwt.get_unverified_header(token) == {"alg": "RS256", "typ": "JWT", "kid": APP_ID}
    claims = jwt.decode(token, PUBLIC, algorithms=["RS256"], audience="api.enablebanking.com",
                        options={"verify_iat": False, "verify_exp": False})
    assert claims == {"iss": "enablebanking.com", "aud": "api.enablebanking.com", "iat": now[0], "exp": now[0] + 3600}
    now[0] += 60
    assert asyncio.run(signer.get_token()) == token  # cached
    now[0] += 3600
    assert asyncio.run(signer.get_token()) != token  # renewed before expiry
    assert len(imports) == 1  # the key is imported once per isolate


def test_only_pkcs8_keys_are_accepted_for_webcrypto():
    pkcs1 = KEY.private_bytes(serialization.Encoding.PEM, serialization.PrivateFormat.TraditionalOpenSSL,
                              serialization.NoEncryption())
    with pytest.raises(ValueError):
        pem_to_der(pkcs1)
    assert pem_to_der(PEM.encode())[:2] == b"\x30\x82"  # DER SEQUENCE


# ---- wrangler.jsonc ----------------------------------------------------------------------------------

def wrangler_config() -> dict:
    lines = [line for line in WRANGLER.read_text().splitlines() if not line.lstrip().startswith("//")]
    return json.loads("\n".join(lines))


SECRET_NAMES = {"EB_APPLICATION_ID", "EB_PRIVATE_KEY_PEM", "WOS_CLIENT_SECRET", "WOS_DATA_KEY", "WOS_ALLOW_PRODUCTION"}


def test_wrangler_environments_are_isolated_and_quiet():
    config = wrangler_config()
    assert "name" not in config, "no environment-less Worker: deploys must name --env"
    assert "python_workers" in config["compatibility_flags"]
    envs = config["env"]
    assert set(envs) == {"sandbox", "production"}
    names, databases, ids, clients = set(), set(), set(), set()
    for key, env in envs.items():
        assert env["observability"] == {"enabled": False, "logs": {"enabled": False, "invocation_logs": False}}
        assert env["preview_urls"] is False
        assert not SECRET_NAMES & set(env["vars"]), "secrets belong in `wrangler secret put`, never in the config"
        assert env["vars"]["EB_ENVIRONMENT"] == key
        redirect = urlparse(env["vars"]["EB_REDIRECT_URL"])
        assert redirect.scheme == "https" and redirect.path == "/v1/callback"
        assert env["vars"]["WOS_ALLOWED_HOSTS"].lower().split(",") == [redirect.hostname]
        assert redirect.hostname.startswith(env["name"] + ".")
        (database,) = env["d1_databases"]
        assert database["binding"] == "DB"
        names.add(env["name"]); databases.add(database["database_name"]); ids.add(database["database_id"])
        clients.add(env["vars"]["WOS_CLIENT_ID"])
    assert len(names) == len(databases) == len(ids) == len(clients) == 2


def test_worker_bundle_is_ignored_by_git():
    ignore = (WRANGLER.parent / ".gitignore").read_text()
    for pattern in [".dev.vars", ".dev.vars.*", "node_modules/", ".wrangler/", "python_modules/", "src/app/"]:
        assert pattern in ignore.splitlines()


# ---- database round trips (each D1 call costs ~2-3 ms of Worker CPU) ------------------------------

def test_signed_request_costs_two_d1_round_trips_and_bad_signatures_none():
    w = Worker()
    connection = w.connect()
    before = w.d1.round_trips
    assert w.signed("GET", f"/v1/connections/{connection}/accounts/acc-1/balances").status_code == 200
    assert w.d1.round_trips - before == 2  # nonce + rate limit in one batch, then the connection
    before = w.d1.round_trips
    bad = w.http.get(f"/v1/connections/{connection}", headers={
        "X-WOS-Client": "wealthos-ios", "X-WOS-Timestamp": str(w.now), "X-WOS-Nonce": "bad-signature-1",
        "X-WOS-Signature": "AAAA"})
    assert bad.status_code == 401 and w.d1.round_trips == before


def test_warm_database_is_prepared_with_a_single_read():
    d1 = FakeD1()
    asyncio.run(Store(None, b"d" * 32, environment="sandbox", database=D1Database(d1, null=NULL)).prepare())
    before = d1.round_trips
    asyncio.run(Store(None, b"d" * 32, environment="sandbox", database=D1Database(d1, null=NULL)).prepare())
    assert d1.round_trips - before == 1


def test_client_rate_limit_is_enforced_after_authentication():
    from app import main

    w = Worker()
    statuses = [w.signed("GET", "/v1/connections/con_unknown").status_code for _ in range(main.LIMIT_CLIENT + 1)]
    assert set(statuses[:-1]) == {404} and statuses[-1] == 429


def test_sqlite_batch_is_atomic():
    from app.store import SQLiteDatabase

    db = SQLiteDatabase(":memory:")
    db.execute_sync("CREATE TABLE t (k TEXT PRIMARY KEY)")
    with pytest.raises(sqlite3.IntegrityError):
        db.batch_sync([("INSERT INTO t VALUES ('a')", ()), ("INSERT INTO t VALUES ('a')", ())])
    assert db.fetchone_sync("SELECT COUNT(*) FROM t") == (0,)


def test_status_check_writes_only_when_the_consent_date_changes():
    w = Worker()
    connection = w.connect()
    w.signed("GET", f"/v1/connections/{connection}")  # FakeBank's session has no new valid_until
    before = w.d1.round_trips
    assert w.signed("GET", f"/v1/connections/{connection}").status_code == 200
    assert w.d1.round_trips - before == 2


def test_privacy_and_terms_pages_work_without_secrets():
    def broken(_env):
        raise ConfigError("not configured yet")

    for path in ["/privacy", "/terms"]:
        sent = _asgi_get(WorkerApp(builder=broken), path)
        assert sent[0]["status"] == 200
        body = sent[1]["body"].decode()
        assert "read-only" in body and "@" not in body  # no personal contact details published


# ---- PSU headers: fetches the user starts are not background fetches ---------------------------------

def test_user_present_fetch_forwards_both_psu_headers():
    w = Worker()
    connection = w.connect()
    present = {"X-WOS-User-Present": "1", "CF-Connecting-IP": "81.198.10.20", "User-Agent": "WealthOS/1 CFNetwork Darwin"}
    for path in [f"/v1/connections/{connection}/accounts/acc-1/balances",
                 f"/v1/connections/{connection}/accounts/acc-1/transactions?date_from=2026-08-01",
                 f"/v1/connections/{connection}"]:
        assert w.signed("GET", path, extra=present).status_code == 200
        sent = {k.lower(): v for k, v in w.bank.psu_headers[-1].items()}
        assert sent == {"psu-ip-address": "81.198.10.20", "psu-user-agent": "WealthOS/1 CFNetwork Darwin"}


def test_background_fetch_sends_no_psu_headers():
    w = Worker()
    connection = w.connect()
    w.signed("GET", f"/v1/connections/{connection}/accounts/acc-1/balances", extra={"CF-Connecting-IP": "203.0.113.25"})
    assert w.bank.psu_headers[-1] == {}


def test_psu_headers_are_all_or_nothing_for_unusable_addresses():
    w = Worker()
    connection = w.connect()
    for ip in ["10.0.0.4", "127.0.0.1", "203.0.113.25", "not-an-ip"]:  # private, loopback, documentation
        w.signed("GET", f"/v1/connections/{connection}/accounts/acc-1/balances",
                 extra={"X-WOS-User-Present": "1", "CF-Connecting-IP": ip})
        assert w.bank.psu_headers[-1] == {}


def test_local_server_never_trusts_a_client_supplied_address_for_the_bank():
    from tests.test_backend import Harness

    h = Harness()
    connection = h.connect()["connection_id"]
    response = h.http.request("GET", f"/v1/connections/{connection}/accounts/acc-1/balances")  # unsigned control
    assert response.status_code == 401
    h.signed("GET", f"/v1/connections/{connection}/accounts/acc-1/balances")
    assert h.eb.psu[-1] is None
