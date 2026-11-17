"""Request authentication (HMAC, replay protection), client addressing and secret-free logging."""

from __future__ import annotations

import base64
import hashlib
import hmac
import logging
import re
import time

from fastapi import HTTPException, Request

MAX_CLOCK_SKEW_SECONDS = 120
MAX_BODY_BYTES = 16 * 1024
NONCE_PATTERN = re.compile(r"[A-Za-z0-9-]{8,64}")


def canonical_request(method: str, path_and_query: str, timestamp: str, nonce: str, body: bytes) -> bytes:
    body_hash = hashlib.sha256(body).hexdigest()
    return "\n".join([method, path_and_query, timestamp, nonce, body_hash]).encode()


def sign(secret: str, method: str, path_and_query: str, timestamp: str, nonce: str, body: bytes) -> str:
    """Must match `BankingClient.signature` in the iOS app."""
    mac = hmac.new(secret.encode(), canonical_request(method, path_and_query, timestamp, nonce, body), hashlib.sha256)
    return base64.b64encode(mac.digest()).decode()


def raw_path_and_query(request: Request) -> str:
    """Exactly the bytes the client signed: undecoded path plus raw query string."""
    raw_path = request.scope.get("raw_path") or request.url.path.encode()
    query = request.scope.get("query_string") or b""
    text = raw_path.decode("latin-1")
    return text + ("?" + query.decode("latin-1") if query else "")


def client_ip(request: Request, *, trust_cf_header: bool) -> str:
    """The caller's address for rate limiting. Behind Cloudflare the socket peer is Cloudflare
    itself, so the edge-set CF-Connecting-IP is used — only when configured, because anywhere
    else that header is client-controlled."""
    if trust_cf_header:
        forwarded = request.headers.get("cf-connecting-ip", "").strip()
        if forwarded:
            return forwarded[:64]
    return request.client.host if request.client else "?"


def unauthorized() -> HTTPException:
    return HTTPException(status_code=401, detail={"error": "unauthorized"})


async def verify_request(request: Request, *, client_id: str, secret: str, use_nonce, now=time.time) -> bytes:
    """Validates the HMAC headers and returns the (size-checked) body.

    Every failure looks the same to the caller (401) so nothing about the reason leaks.
    """
    body = await request.body()
    if len(body) > MAX_BODY_BYTES:
        raise HTTPException(status_code=413, detail={"error": "too_large"})
    headers = request.headers
    sent_client = headers.get("x-wos-client", "")
    timestamp = headers.get("x-wos-timestamp", "")
    nonce = headers.get("x-wos-nonce", "")
    signature = headers.get("x-wos-signature", "")
    if not hmac.compare_digest(sent_client.encode(), client_id.encode()):
        raise unauthorized()
    if not timestamp.isdigit() or abs(now() - int(timestamp)) > MAX_CLOCK_SKEW_SECONDS:
        raise unauthorized()
    if not NONCE_PATTERN.fullmatch(nonce):
        raise unauthorized()
    expected = sign(secret, request.method, raw_path_and_query(request), timestamp, nonce, body)
    if not hmac.compare_digest(expected.encode(), signature.encode()):
        raise unauthorized()
    # Only after the signature is valid, so attackers can't burn nonces.
    if not await use_nonce(client_id, nonce):
        raise unauthorized()
    return body


class RedactingFilter(logging.Filter):
    """Last line of defence: scrubs anything that looks like a code, state, token, IBAN or key."""

    PATTERNS = [
        (re.compile(r"(?i)(code|state|token|secret|session[_-]?id|authorization)=([^&\s]+)"), r"\1=[redacted]"),
        (re.compile(r"(?i)bearer\s+[A-Za-z0-9._-]+"), "Bearer [redacted]"),
        (re.compile(r"\b[A-Z]{2}\d{2}[A-Z0-9]{10,30}\b"), "[iban]"),
        (re.compile(r"-----BEGIN [A-Z ]+-----[\s\S]+?-----END [A-Z ]+-----"), "[pem]"),
    ]

    def filter(self, record: logging.LogRecord) -> bool:
        message = record.getMessage()
        for pattern, replacement in self.PATTERNS:
            message = pattern.sub(replacement, message)
        record.msg, record.args = message, None
        return True


def configure_logging() -> logging.Logger:
    logger = logging.getLogger("wealthos.banking")
    if not logger.handlers:
        handler = logging.StreamHandler()
        handler.setFormatter(logging.Formatter("%(asctime)s %(levelname)s %(message)s"))
        handler.addFilter(RedactingFilter())
        logger.addHandler(handler)
        logger.setLevel(logging.INFO)
        logger.propagate = False
    return logger


def silence_logging() -> None:
    """Cloudflare Workers: emit nothing. Worker console output would end up in Cloudflare's log
    pipeline if observability were ever enabled, so the banking logger is disabled outright."""
    logger = logging.getLogger("wealthos.banking")
    for handler in list(logger.handlers):
        logger.removeHandler(handler)
    logger.addHandler(logging.NullHandler())
    logger.propagate = False
    logger.disabled = True
