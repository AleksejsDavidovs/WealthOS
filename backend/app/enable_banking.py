"""Minimal Enable Banking API client — account information only.

Per https://enablebanking.com/docs/api/reference/ :
- Base URL https://api.enablebanking.com (sandbox and production are separated by application).
- Every call carries `Authorization: Bearer <JWT>`; the JWT is RS256-signed with the application's
  private key, header `kid` = application id, claims iss="enablebanking.com",
  aud="api.enablebanking.com", iat, exp (max 24 h; we use 1 h).

Only these endpoints exist in this client: POST /auth, POST /sessions, GET/DELETE
/sessions/{id}, GET /accounts/{uid}/balances, GET /accounts/{uid}/transactions, GET /aspsps.
There is intentionally no payment endpoint.
"""

from __future__ import annotations

import base64
import json
import time
from dataclasses import dataclass
from typing import Any

import httpx
import jwt

JWT_TTL_SECONDS = 3600


@dataclass
class EnableBankingError(Exception):
    status: int
    error_code: str = ""
    retry_after: str | None = None

    def __str__(self) -> str:  # never includes response bodies beyond the code
        return f"Enable Banking HTTP {self.status} {self.error_code}".strip()


def jwt_claims(application_id: str, now: int) -> tuple[dict, dict]:
    """(header, claims) exactly as Enable Banking documents them."""
    return ({"alg": "RS256", "typ": "JWT", "kid": application_id},
            {"iss": "enablebanking.com", "aud": "api.enablebanking.com", "iat": now, "exp": now + JWT_TTL_SECONDS})


class JWTSigner:
    """Signs with PyJWT/cryptography. Used locally (CPython)."""

    def __init__(self, application_id: str, private_key_pem: bytes, clock=time.time):
        self._kid = application_id
        self._key = private_key_pem
        self._clock = clock
        self._token: str | None = None
        self._expires = 0

    def token(self) -> str:
        now = int(self._clock())
        if self._token is None or now > self._expires - 300:
            header, claims = jwt_claims(self._kid, now)
            self._token = jwt.encode(claims, self._key, algorithm="RS256",
                                     headers={"kid": header["kid"], "typ": header["typ"]})
            self._expires = now + JWT_TTL_SECONDS
        return self._token

    async def get_token(self) -> str:
        return self.token()


def _b64url(data: bytes) -> bytes:
    return base64.urlsafe_b64encode(data).rstrip(b"=")


def pem_to_der(private_key_pem: bytes) -> bytes:
    """PKCS#8 PEM ("BEGIN PRIVATE KEY") to DER, without parsing the key."""
    text = private_key_pem.decode("ascii", "strict").strip()
    if not text.startswith("-----BEGIN PRIVATE KEY-----") or not text.endswith("-----END PRIVATE KEY-----"):
        raise ValueError("The private key must be PKCS#8 PEM (BEGIN PRIVATE KEY)")
    body = "".join(line.strip() for line in text.splitlines()[1:-1])
    return base64.b64decode(body, validate=True)


class AsyncRS256Signer:
    """Builds the same JWT with an injected RSASSA-PKCS1-v1_5/SHA-256 implementation.

    On Cloudflare Workers this is the platform's native WebCrypto (`app.cloudflare`): parsing the
    key with `cryptography` costs ~190 ms of CPU under WebAssembly, WebCrypto signs in <1 ms.
    `import_key(der)` and `sign(key, data) -> signature bytes` are coroutines."""

    def __init__(self, application_id: str, private_key_pem: bytes, *, import_key, sign, clock=time.time):
        self._kid = application_id
        self._der = pem_to_der(private_key_pem)
        self._import_key = import_key
        self._sign = sign
        self._clock = clock
        self._key = None
        self._token: str | None = None
        self._expires = 0

    async def get_token(self) -> str:
        now = int(self._clock())
        if self._token is None or now > self._expires - 300:
            if self._key is None:
                self._key = await self._import_key(self._der)
            header, claims = jwt_claims(self._kid, now)
            signing_input = (_b64url(json.dumps(header, separators=(",", ":")).encode()) + b"."
                             + _b64url(json.dumps(claims, separators=(",", ":")).encode()))
            signature = await self._sign(self._key, signing_input)
            self._token = (signing_input + b"." + _b64url(bytes(signature))).decode()
            self._expires = now + JWT_TTL_SECONDS
        return self._token


class EnableBankingClient:
    def __init__(self, base_url: str, signer, transport: httpx.AsyncBaseTransport | None = None):
        self._signer = signer
        self._http = httpx.AsyncClient(base_url=base_url, timeout=httpx.Timeout(30.0), transport=transport,
                                       follow_redirects=False, headers={"Accept": "application/json"})

    async def close(self) -> None:
        await self._http.aclose()

    async def _call(self, method: str, path: str, *, params: dict | None = None, json: Any = None,
                    psu: dict[str, str] | None = None) -> Any:
        # PSU headers mark a fetch the user started while using the app; without them banks treat
        # it as a background fetch (PSD2: typically 4 per day per account).
        headers = {"Authorization": f"Bearer {await self._signer.get_token()}", **(psu or {})}
        response = await self._http.request(method, path, params=params, json=json, headers=headers)
        if response.status_code >= 400:
            code = ""
            try:
                body = response.json()
                code = str(body.get("error") or body.get("error_code") or body.get("code") or "")[:64]
            except Exception:  # noqa: BLE001
                pass
            raise EnableBankingError(response.status_code, code, response.headers.get("Retry-After"))
        return response.json() if response.content else {}

    async def aspsps(self, country: str) -> list[dict]:
        return (await self._call("GET", "/aspsps", params={"country": country})).get("aspsps", [])

    async def start_authorization(self, *, aspsp_name: str, aspsp_country: str, state: str, redirect_url: str,
                                  valid_until: str) -> dict:
        return await self._call("POST", "/auth", json={
            "access": {"valid_until": valid_until},
            "aspsp": {"name": aspsp_name, "country": aspsp_country},
            "state": state,
            "redirect_url": redirect_url,
            "psu_type": "personal",
        })

    async def create_session(self, code: str) -> dict:
        return await self._call("POST", "/sessions", json={"code": code})

    async def get_session(self, session_id: str, psu: dict[str, str] | None = None) -> dict:
        return await self._call("GET", f"/sessions/{session_id}", psu=psu)

    async def delete_session(self, session_id: str) -> None:
        await self._call("DELETE", f"/sessions/{session_id}")

    async def balances(self, account_uid: str, psu: dict[str, str] | None = None) -> dict:
        return await self._call("GET", f"/accounts/{account_uid}/balances", psu=psu)

    async def transactions(self, account_uid: str, *, date_from: str | None, continuation_key: str | None,
                           psu: dict[str, str] | None = None) -> dict:
        params: dict[str, str] = {}
        if date_from:
            params["date_from"] = date_from
        if continuation_key:
            params["continuation_key"] = continuation_key
        return await self._call("GET", f"/accounts/{account_uid}/transactions", params=params, psu=psu)
