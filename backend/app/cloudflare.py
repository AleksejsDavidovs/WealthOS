"""Cloudflare Workers glue: D1 storage, WebCrypto JWT signing, settings from Worker bindings.

Only `backend/cloudflare/src/entry.py` imports this inside the Worker. Pyodide's `js` /
`pyodide.ffi` modules are imported lazily, so the module also loads under CPython where the
tests drive it with fakes.

Security properties are the same as the local server's: the HMAC check, nonces, single-use
state/attempts, ownership checks and encryption at rest all live in `main.py` / `store.py`.
"""

from __future__ import annotations

import json
import time
from typing import Any, Sequence

from .config import Settings
from .enable_banking import AsyncRS256Signer, EnableBankingClient
from .main import create_app
from .security import silence_logging
from .store import Store

# Everything a Worker reads from its bindings. Secrets: EB_APPLICATION_ID, EB_PRIVATE_KEY_PEM,
# WOS_CLIENT_SECRET, WOS_DATA_KEY (and WOS_ALLOW_PRODUCTION for production). The rest are vars.
SETTING_NAMES = (
    "EB_ENVIRONMENT", "EB_APPLICATION_ID", "EB_PRIVATE_KEY_PEM", "EB_API_BASE", "EB_REDIRECT_URL",
    "EB_ASPSP_NAME", "EB_ASPSP_COUNTRY", "EB_CONSENT_DAYS", "WOS_CLIENT_ID", "WOS_CLIENT_SECRET",
    "WOS_DATA_KEY", "WOS_APP_CALLBACK", "WOS_ALLOWED_HOSTS", "WOS_ALLOW_PRODUCTION", "WOS_TRUST_CF_CONNECTING_IP",
)


# ---- D1 -------------------------------------------------------------------------------------

def _js_null():
    """D1 rejects `undefined` (what Pyodide sends for None); SQL NULL must be JS `null`."""
    from pyodide.ffi import jsnull  # type: ignore[import-not-found]

    return jsnull


def _to_py(value: Any) -> Any:
    return value.to_py() if hasattr(value, "to_py") else value


def _field(obj: Any, name: str) -> Any:
    return obj.get(name) if isinstance(obj, dict) else getattr(obj, name, None)


def _cell(value: Any) -> Any:
    # Some Pyodide/D1 combinations surface SQL NULL as an empty object.
    if isinstance(value, dict) and not value:
        return None
    return value


class D1Database:
    """`app.store.Database` on a Cloudflare D1 binding. Each statement is atomic; D1 serialises
    writes, so the store's conditional UPDATE/DELETE ... RETURNING keep their single-use guarantees."""

    def __init__(self, binding: Any, *, null: Any = None):
        self._db = binding
        self._null = null

    def _statement(self, sql: str, params: Sequence[Any]):
        statement = self._db.prepare(sql)
        if params:
            if self._null is None:
                self._null = _js_null()
            statement = statement.bind(*[self._null if value is None else value for value in params])
        return statement

    async def execute(self, sql: str, params: Sequence[Any] = ()) -> int:
        result = await self._statement(sql, params).run()
        return int(_to_py(result.meta.changes) or 0)

    async def fetchone(self, sql: str, params: Sequence[Any] = ()) -> tuple | None:
        rows = _to_py(await self._statement(sql, params).raw())
        if not rows:
            return None
        return tuple(_cell(value) for value in rows[0])

    async def batch(self, statements: Sequence[tuple[str, Sequence[Any]]]) -> list[tuple[int, list[tuple]]]:
        """D1 `batch()`: one round trip, executed as a single transaction. Rows come back as
        objects in column order; callers only read single-column RETURNING results.
        The statements go as a plain Python list: the Workers SDK's binding wrapper converts it
        (converting it ourselves with `to_js` hands D1 borrowed proxies that Pyodide destroys)."""
        prepared = [self._statement(sql, params) for sql, params in statements]
        results = _to_py(await self._db.batch(prepared))
        out = []
        for result in results:
            meta = _field(result, "meta") or {}
            rows = _field(result, "results") or []
            out.append((int(_field(meta, "changes") or 0),
                        [tuple(_cell(v) for v in (row.values() if isinstance(row, dict) else row)) for row in rows]))
        return out


# ---- WebCrypto --------------------------------------------------------------------------------

async def webcrypto_import_key(der: bytes):
    from js import Object, crypto  # type: ignore[import-not-found]
    from pyodide.ffi import to_js  # type: ignore[import-not-found]

    algorithm = to_js({"name": "RSASSA-PKCS1-v1_5", "hash": "SHA-256"}, dict_converter=Object.fromEntries)
    # Non-extractable: once imported, the key cannot be read back out of WebCrypto.
    return await crypto.subtle.importKey("pkcs8", to_js(der), algorithm, False, to_js(["sign"]))


async def webcrypto_sign(key, data: bytes) -> bytes:
    from js import Uint8Array, crypto  # type: ignore[import-not-found]
    from pyodide.ffi import to_js  # type: ignore[import-not-found]

    signature = await crypto.subtle.sign("RSASSA-PKCS1-v1_5", key, to_js(data))
    return bytes(Uint8Array.new(signature).to_py())


# ---- app ------------------------------------------------------------------------------------

def _binding(env: Any, name: str) -> Any:
    try:
        value = getattr(env, name)
    except (AttributeError, KeyError):
        return None
    return None if value is None else value


def settings_from_env(env: Any) -> Settings:
    values = {}
    for name in SETTING_NAMES:
        value = _binding(env, name)
        if value is not None:
            values[name] = str(value)
    values["WOS_STORAGE"] = "d1"
    return Settings(_env_file=None, **values)  # type: ignore[call-arg]


def build_app(env: Any, *, clock=time.time, database=None, import_key=webcrypto_import_key, sign=webcrypto_sign,
              eb_transport=None):
    silence_logging()
    settings = settings_from_env(env)
    settings.validate_runtime(check_key_file=False)
    binding = _binding(env, "DB")
    if database is None:
        if binding is None:
            raise RuntimeError("The Worker has no D1 binding named DB")
        database = D1Database(binding)
    store = Store(None, settings.data_key, clock=clock, environment=settings.eb_environment, database=database)
    signer = AsyncRS256Signer(settings.eb_application_id, settings.private_key_pem(),
                              import_key=import_key, sign=sign, clock=clock)
    eb = EnableBankingClient(settings.eb_api_base, signer, transport=eb_transport)
    return create_app(settings, eb_client=eb, store=store, clock=clock, check_key_file=False)


# Static pages Enable Banking's application registration links to (privacy policy, terms).
# Served before the app is built, so they work even while secrets are not yet configured.
_PAGE = ("<!doctype html><html lang=en><meta charset=utf-8><meta name=viewport content='width=device-width'>"
         "<title>{title}</title><body style='font-family:-apple-system,system-ui,sans-serif;max-width:40em;"
         "margin:2em auto;padding:0 1em;line-height:1.5'><h1>{title}</h1>{body}</body></html>")
LEGAL_PAGES = {
    "/privacy": _PAGE.format(title="WealthOS Banking — Privacy Policy", body=(
        "<p>WealthOS Banking is a personal, non-commercial application used only by its owner to view "
        "their own bank accounts in the WealthOS personal-finance app.</p>"
        "<p><b>Access is read-only.</b> With the account holder's consent it reads account details, "
        "balances and transactions through Enable Banking. It cannot initiate payments.</p>"
        "<p><b>Storage.</b> Account data is stored on the owner's own device. This service keeps only an "
        "encrypted bank-session reference and, for at most ten minutes, encrypted parts of a large "
        "transaction page being delivered. Nothing is sold, shared or used for advertising, and request "
        "logging is disabled.</p>"
        "<p><b>Retention and withdrawal.</b> Consent ends when it expires or is revoked; disconnecting "
        "in the app deletes the stored session reference.</p>")),
    "/terms": _PAGE.format(title="WealthOS Banking — Terms of Use", body=(
        "<p>This is a private application for the personal use of its owner only. It is not offered to "
        "the public and provides read-only access to the owner's own accounts.</p>"
        "<p>It is provided as is, without warranties. Bank data is shown as received from the bank via "
        "Enable Banking.</p>")),
}


def _plain(status: int, code: str):
    body = json.dumps({"error": code}).encode()
    return ({"type": "http.response.start", "status": status,
             "headers": [(b"content-type", b"application/json"), (b"cache-control", b"no-store")]},
            {"type": "http.response.body", "body": body})


class WorkerApp:
    """ASGI app for `workers.asgi.entrypoint`. Builds the FastAPI app once per isolate from the
    request's bindings (secrets are not available at import time, and must not end up in the
    deploy-time memory snapshot). Any failure becomes a bare JSON error — never a traceback."""

    def __init__(self, builder=build_app):
        self._builder = builder
        self._app = None

    async def __call__(self, scope, receive, send):
        if scope["type"] == "lifespan":
            while True:
                message = await receive()
                if message["type"] == "lifespan.startup":
                    await send({"type": "lifespan.startup.complete"})
                elif message["type"] == "lifespan.shutdown":
                    await send({"type": "lifespan.shutdown.complete"})
                    return
        if scope["type"] != "http":
            return
        if scope.get("method") == "GET" and scope.get("path") in LEGAL_PAGES:
            await send({"type": "http.response.start", "status": 200, "headers": [
                (b"content-type", b"text/html; charset=utf-8"), (b"cache-control", b"public, max-age=3600"),
                (b"x-content-type-options", b"nosniff"), (b"x-frame-options", b"DENY"),
                (b"content-security-policy", b"default-src 'none'; style-src 'unsafe-inline'")]})
            await send({"type": "http.response.body", "body": LEGAL_PAGES[scope["path"]].encode()})
            return
        started = False

        async def tracked(message):
            nonlocal started
            if message["type"] == "http.response.start":
                started = True
            await send(message)

        try:
            if self._app is None:
                self._app = self._builder(scope["env"])
            await self._app(scope, receive, tracked)
        except Exception:  # noqa: BLE001
            if not started:
                for message in _plain(503 if self._app is None else 500,
                                      "unavailable" if self._app is None else "internal"):
                    await send(message)
