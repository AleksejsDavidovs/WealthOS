"""WealthOS banking backend (FastAPI).

Read-only account information for the WealthOS iOS app via Enable Banking. The app never sees
the Enable Banking private key, JWTs, authorization codes or session ids.

Run locally (loopback only):  uvicorn app.main:app --host 127.0.0.1 --port 8787 --no-access-log
"""

from __future__ import annotations

import ipaddress
import re
import secrets
import time
from contextlib import asynccontextmanager
from datetime import datetime, timedelta, timezone
from urllib.parse import urlencode

from fastapi import Depends, FastAPI, HTTPException, Query, Request
from fastapi.responses import HTMLResponse, JSONResponse, RedirectResponse, Response
from pydantic import BaseModel, ConfigDict, Field, ValidationError
from starlette.middleware.trustedhost import TrustedHostMiddleware

from . import normalize
from .config import ConfigError, Settings, get_settings
from .enable_banking import EnableBankingClient, EnableBankingError, JWTSigner
from .security import client_ip, configure_logging, verify_request
from .store import Store

log = configure_logging()

ID = re.compile(r"[A-Za-z0-9_-]{1,128}")
# A bank page larger than this is served in parts (continuation keys starting with CHUNK_PREFIX),
# which keeps every request well inside the Cloudflare Workers Free CPU budget.
CHUNK_SIZE = 150
CHUNK_PREFIX = "wos1."
# Requests per minute. A full sync is ~2 + pages requests per account. Requests with a bad
# signature are rejected before any database work, so they cost nothing to absorb.
LIMIT_CLIENT, LIMIT_CALLBACK_IP = 240, 20
SECURITY_HEADERS = [(b"cache-control", b"no-store"), (b"x-content-type-options", b"nosniff"),
                    (b"referrer-policy", b"no-referrer"), (b"x-frame-options", b"DENY")]
_SECURITY_NAMES = {name for name, _ in SECURITY_HEADERS}


class Harden:
    """Pure ASGI (no per-request task/stream like BaseHTTPMiddleware — that overhead matters on
    Workers): size cap, security headers, and a bare 500 for anything unexpected."""

    def __init__(self, app):
        self.app = app

    async def __call__(self, scope, receive, send):
        if scope["type"] != "http":
            return await self.app(scope, receive, send)
        started = time.monotonic()
        length = next((value for name, value in scope.get("headers", []) if name == b"content-length"), b"0")
        if int(length or b"0") > 16 * 1024:
            return await JSONResponse({"error": "too_large"}, status_code=413)(scope, receive, self._send(send, {}))
        state = {}
        try:
            await self.app(scope, receive, self._send(send, state))
        except Exception as exc:  # noqa: BLE001 - never leak a traceback or values to the caller
            log.error("Unhandled %s on %s", type(exc).__name__, getattr(scope.get("route"), "path", "?"))
            if "status" not in state:
                await JSONResponse({"error": "internal"}, status_code=500)(scope, receive, self._send(send, state))
        # Route template only — never the query string (it carries the authorization code).
        log.info("%s %s -> %s (%d ms)", scope["method"], getattr(scope.get("route"), "path", "?"),
                 state.get("status"), (time.monotonic() - started) * 1000)

    @staticmethod
    def _send(send, state):
        async def wrapped(message):
            if message["type"] == "http.response.start":
                state["status"] = message["status"]
                headers = [h for h in message.get("headers", []) if h[0].lower() not in _SECURITY_NAMES]
                message = {**message, "headers": headers + SECURITY_HEADERS}
            await send(message)
        return wrapped
CALLBACK_ERRORS = {"access_denied": "access_denied", "cancelled": "cancelled", "user_cancelled": "cancelled"}


class StartBody(BaseModel):
    model_config = ConfigDict(extra="forbid")
    aspsp_name: str = Field(max_length=80)
    aspsp_country: str = Field(pattern=r"^[A-Z]{2}$")
    psu_type: str = Field(pattern=r"^personal$")


class CompleteBody(BaseModel):
    model_config = ConfigDict(extra="forbid")
    attempt_id: str = Field(pattern=r"^[A-Za-z0-9_-]{8,64}$")


def error(status: int, code: str, headers: dict | None = None) -> HTTPException:
    return HTTPException(status_code=status, detail={"error": code}, headers=headers)


def create_app(settings: Settings | None = None, *, eb_client: EnableBankingClient | None = None,
               store: Store | None = None, clock=time.time, check_key_file: bool = True) -> FastAPI:
    settings = settings or get_settings()
    settings.validate_runtime(check_key_file=check_key_file)

    @asynccontextmanager
    async def lifespan(app: FastAPI):
        yield
        await app.state.eb.close()

    app = FastAPI(title="WealthOS banking backend", docs_url=None, redoc_url=None, openapi_url=None, lifespan=lifespan)
    # No CORS middleware: no browser origin is ever allowed to call this API.
    app.add_middleware(TrustedHostMiddleware, allowed_hosts=settings.allowed_hosts)
    app.state.settings = settings
    if store is None:
        if settings.wos_storage != "sqlite":
            raise ConfigError("D1 storage is provided by the Cloudflare Worker entry point")
        store = Store(settings.wos_db_path, settings.data_key, clock=clock, environment=settings.eb_environment)
    app.state.store = store
    app.state.eb = eb_client or EnableBankingClient(
        settings.eb_api_base, JWTSigner(settings.eb_application_id, settings.private_key_pem(), clock=clock))

    def ip_of(request: Request) -> str:
        return client_ip(request, trust_cf_header=settings.wos_trust_cf_connecting_ip)

    def psu_headers(request: Request) -> dict[str, str] | None:
        """The user's own IP and app for a fetch they started in the app (X-WOS-User-Present: 1).
        Swedbank requires both headers together, so either both are sent or none (then the bank
        counts it as a background fetch). Only a public address is meaningful to the bank."""
        if request.headers.get("x-wos-user-present") != "1":
            return None
        try:
            address = ipaddress.ip_address(ip_of(request))
        except ValueError:
            return None
        if not address.is_global:
            return None
        agent = (request.headers.get("user-agent") or "WealthOS").strip()[:256] or "WealthOS"
        return {"Psu-Ip-Address": str(address), "Psu-User-Agent": agent}

    app.add_middleware(Harden)

    @app.exception_handler(HTTPException)
    async def http_error(_: Request, exc: HTTPException):
        detail = exc.detail if isinstance(exc.detail, dict) else {"error": "error"}
        return JSONResponse(detail, status_code=exc.status_code, headers=exc.headers)

    async def client(request: Request) -> str:
        within_limit = [True]

        async def record(client_id: str, nonce: str) -> bool:
            # Runs only after the signature checked out: one atomic database round trip.
            fresh, within_limit[0] = await app.state.store.authorize_request(
                client_id, nonce, limit=LIMIT_CLIENT, window_seconds=60)
            return fresh

        request.state.body = await verify_request(
            request, client_id=settings.wos_client_id, secret=settings.wos_client_secret.get_secret_value(),
            use_nonce=record, now=clock)
        if not within_limit[0]:
            raise error(429, "rate_limited", {"Retry-After": "60"})
        return settings.wos_client_id

    def parse(model, request: Request):
        try:
            return model.model_validate_json(request.state.body or b"{}")
        except ValidationError:
            raise error(422, "invalid_request") from None

    async def connection_for(connection_id: str, client_id: str):
        if not ID.fullmatch(connection_id):
            raise error(404, "not_found")
        found = await app.state.store.get_connection(connection_id, client_id)
        if not found:
            raise error(404, "not_found")
        return found

    def require_account(connection, account_uid: str) -> None:
        # Only accounts this consent returned; never an arbitrary uid.
        if not ID.fullmatch(account_uid) or account_uid not in {a["uid"] for a in connection.accounts}:
            raise error(404, "not_found")

    async def bank_failure(exc: EnableBankingError, connection) -> HTTPException:
        log.warning("Enable Banking call failed: HTTP %s %s", exc.status, exc.error_code)
        if exc.status == 429:
            return error(429, "rate_limited", {"Retry-After": exc.retry_after or "600"})
        if exc.status in (401, 403, 404, 422) and connection is not None:
            # Ask the session itself whether the consent is still valid (documented status enum).
            try:
                status = str((await app.state.eb.get_session(connection.session_id)).get("status", "")).upper()
            except EnableBankingError:
                status = ""
            if status == "EXPIRED":
                return error(410, "consent_expired")
            if status in ("REVOKED", "CLOSED", "CANCELLED", "INVALID"):
                return error(403, "consent_revoked")
        if exc.status in (408, 504):
            return error(504, "timeout")
        return error(502, "bank_error")

    # ---- routes -----------------------------------------------------------------------------

    @app.get("/v1/health")
    async def health():
        return {"ok": True, "environment": settings.eb_environment}

    @app.post("/v1/auth/start")
    async def start(request: Request, client_id: str = Depends(client)):
        body = parse(StartBody, request)
        if body.aspsp_name != settings.eb_aspsp_name or body.aspsp_country != settings.eb_aspsp_country:
            raise error(403, "aspsp_not_allowed")
        attempt_id, state, expires = await app.state.store.create_attempt(client_id, body.aspsp_name, body.aspsp_country)
        valid_until = (datetime.now(timezone.utc) + timedelta(days=settings.eb_consent_days)).isoformat(timespec="seconds")
        try:
            result = await app.state.eb.start_authorization(
                aspsp_name=body.aspsp_name, aspsp_country=body.aspsp_country, state=state,
                redirect_url=settings.eb_redirect_url, valid_until=valid_until)
        except EnableBankingError as exc:
            await app.state.store.discard_attempt(attempt_id)
            raise await bank_failure(exc, None) from None
        url = result.get("url")
        if not isinstance(url, str) or not url.startswith("https://"):
            await app.state.store.discard_attempt(attempt_id)
            raise error(502, "bank_error")
        return {"attempt_id": attempt_id, "authorization_url": url,
                "expires_at": datetime.fromtimestamp(expires, timezone.utc).isoformat()}

    @app.get("/v1/callback", include_in_schema=False)
    async def callback(request: Request, state: str = Query("", max_length=256), code: str = Query("", max_length=2048),
                       error_code: str = Query("", alias="error", max_length=128)):
        """Enable Banking redirects the browser here. The code is exchanged server-side; the app
        only receives the attempt id it already knows."""
        if not await app.state.store.allow("callback-ip:" + ip_of(request), LIMIT_CALLBACK_IP, 60):
            return HTMLResponse(page("Too many attempts. Wait a minute and try again."), status_code=429)
        attempt = await app.state.store.claim_attempt_by_state(state) if state else None
        if attempt is None:
            # Unknown, expired or already used state: possible replay or forgery. Do nothing.
            return HTMLResponse(page("This bank authorization link is invalid or was already used. "
                                     "Return to WealthOS and start again."), status_code=400)
        if error_code or not code:
            reason = CALLBACK_ERRORS.get(error_code, "failed")
            await app.state.store.finish_attempt(attempt.attempt_id, error=reason)
            return app_redirect(attempt.attempt_id, "error", reason)
        try:
            session = await app.state.eb.create_session(code)
        except EnableBankingError as exc:
            log.warning("Session creation failed: HTTP %s %s", exc.status, exc.error_code)
            await app.state.store.finish_attempt(attempt.attempt_id, error="failed")
            return app_redirect(attempt.attempt_id, "error", "failed")
        session_id = session.get("session_id")
        accounts = [a for a in (normalize.account(r) for r in session.get("accounts") or [] if isinstance(r, dict)) if a]
        if not isinstance(session_id, str) or not session_id:
            await app.state.store.finish_attempt(attempt.attempt_id, error="failed")
            return app_redirect(attempt.attempt_id, "error", "failed")
        valid_until = (session.get("access") or {}).get("valid_until")
        connection_id = await app.state.store.save_connection(
            attempt.client_id, session_id, attempt.aspsp_name, attempt.aspsp_country,
            valid_until if isinstance(valid_until, str) else None, accounts)
        await app.state.store.finish_attempt(attempt.attempt_id, connection_id=connection_id)
        return app_redirect(attempt.attempt_id, "success", None)

    @app.post("/v1/auth/complete")
    async def complete(request: Request, client_id: str = Depends(client)):
        body = parse(CompleteBody, request)
        attempt = await app.state.store.get_attempt(body.attempt_id)
        if attempt is None or attempt.client_id != client_id:
            raise error(404, "not_found")
        if attempt.status in ("pending", "processing"):
            if attempt.expires_at < app.state.store.now():
                raise error(410, "attempt_expired")
            raise error(409, "attempt_pending")
        if attempt.status == "failed":
            code = {"access_denied": "authorization_rejected", "cancelled": "authorization_cancelled"}.get(
                attempt.error or "", "authorization_failed")
            raise error(400, code)
        redeemed = await app.state.store.redeem_attempt(body.attempt_id, client_id)
        if redeemed is None or not redeemed.connection_id:
            raise error(404, "not_found")  # already redeemed: single use
        connection = await connection_for(redeemed.connection_id, client_id)
        return {"connection_id": connection.connection_id,
                "aspsp": {"name": connection.aspsp_name, "country": connection.aspsp_country},
                "valid_until": connection.valid_until, "accounts": connection.accounts}

    @app.get("/v1/connections/{connection_id}")
    async def status(request: Request, connection_id: str, client_id: str = Depends(client)):
        connection = await connection_for(connection_id, client_id)
        try:
            session = await app.state.eb.get_session(connection.session_id, psu=psu_headers(request))
        except EnableBankingError as exc:
            raise await bank_failure(exc, connection) from None
        valid_until = (session.get("access") or {}).get("valid_until")
        if isinstance(valid_until, str) and valid_until != connection.valid_until:
            await app.state.store.update_valid_until(connection_id, valid_until)
        return {"status": str(session.get("status", "")).upper()[:32], "valid_until": valid_until}

    @app.delete("/v1/connections/{connection_id}")
    async def delete(connection_id: str, client_id: str = Depends(client)):
        connection = await connection_for(connection_id, client_id)
        try:
            await app.state.eb.delete_session(connection.session_id)
        except EnableBankingError as exc:
            if exc.status != 404:
                raise await bank_failure(exc, None) from None
        await app.state.store.delete_connection(connection_id, client_id)
        return {"deleted": True}

    @app.get("/v1/connections/{connection_id}/accounts/{account_uid}/balances")
    async def balances(request: Request, connection_id: str, account_uid: str, client_id: str = Depends(client)):
        connection = await connection_for(connection_id, client_id)
        require_account(connection, account_uid)
        try:
            data = await app.state.eb.balances(account_uid, psu=psu_headers(request))
        except EnableBankingError as exc:
            raise await bank_failure(exc, connection) from None
        return {"balances": [normalize.balance(b) for b in data.get("balances") or [] if isinstance(b, dict)]}

    @app.get("/v1/connections/{connection_id}/accounts/{account_uid}/transactions")
    async def transactions(request: Request, connection_id: str, account_uid: str, client_id: str = Depends(client),
                           date_from: str = Query(..., pattern=r"^\d{4}-\d{2}-\d{2}$"),
                           continuation_key: str | None = Query(None, max_length=2048)):
        connection = await connection_for(connection_id, client_id)
        require_account(connection, account_uid)
        if continuation_key and continuation_key.startswith(CHUNK_PREFIX):
            rest = await app.state.store.take_chunk(continuation_key[len(CHUNK_PREFIX):], client_id,
                                                    connection_id, account_uid)
            if rest is None:  # expired or already used: the app retries the whole read later
                raise error(503, "page_expired", {"Retry-After": "60"})
            items, next_key = rest
        else:
            try:
                data = await app.state.eb.transactions(account_uid, date_from=date_from, continuation_key=continuation_key,
                                                       psu=psu_headers(request))
            except EnableBankingError as exc:
                raise await bank_failure(exc, connection) from None
            items = [t for t in data.get("transactions") or [] if isinstance(t, dict)]
            next_key = data.get("continuation_key")
            next_key = next_key if isinstance(next_key, str) and next_key else None
        if len(items) > CHUNK_SIZE:
            token = await app.state.store.save_chunk(client_id, connection_id, account_uid, items[CHUNK_SIZE:], next_key)
            items, next_key = items[:CHUNK_SIZE], CHUNK_PREFIX + token
        # A ready JSONResponse skips FastAPI's per-item encoder (half the CPU on large pages).
        return JSONResponse({"transactions": [normalize.transaction(t) for t in items], "continuation_key": next_key})

    def app_redirect(attempt_id: str, result: str, reason: str | None) -> RedirectResponse:
        query = {"attempt": attempt_id, "result": result}
        if reason:
            query["error"] = reason
        return RedirectResponse(f"{settings.wos_app_callback}?{urlencode(query)}", status_code=302)

    return app


def page(message: str) -> str:
    return ("<!doctype html><meta name=viewport content='width=device-width'>"
            f"<title>WealthOS</title><body style='font-family:-apple-system;padding:2em'><p>{message}</p>")


def _nonce() -> str:  # exported for tools/tests
    return secrets.token_hex(16)


# ASGI entry point for uvicorn. Built lazily so importing this module never needs secrets.
def __getattr__(name: str):
    if name == "app":
        built = create_app()
        globals()["app"] = built
        return built
    raise AttributeError(name)
