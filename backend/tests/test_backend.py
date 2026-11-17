"""Backend tests. No network, no real keys, no real `.env`: a fake Enable Banking client and an
in-memory database are injected."""

from __future__ import annotations

import base64
import json
import logging
import time
from urllib.parse import parse_qs, urlparse

import pytest
from fastapi.testclient import TestClient

from app import normalize
from app.config import PRODUCTION_OPT_IN, ConfigError, Settings
from app.enable_banking import EnableBankingError
from app.main import create_app
from app.security import sign
from app.store import Store

SECRET = "0123456789abcdef" * 4
IBAN_A = "LV80HABA0551000000001"
IBAN_B = "LV97HABA0012345678910"


def settings(**overrides) -> Settings:
    values = dict(
        EB_ENVIRONMENT="sandbox", EB_APPLICATION_ID="00000000-0000-0000-0000-000000000000",
        EB_PRIVATE_KEY_PATH="/nonexistent/key.pem", EB_REDIRECT_URL="http://localhost:8787/v1/callback",
        WOS_CLIENT_ID="wealthos-ios", WOS_CLIENT_SECRET=SECRET,
        WOS_DATA_KEY=base64.b64encode(b"k" * 32).decode(), WOS_DB_PATH=":memory:",
    )
    values.update(overrides)
    return Settings(_env_file=None, **values)  # type: ignore[call-arg]


class FakeEB:
    def __init__(self):
        self.calls: list[tuple] = []
        self.psu: list = []
        self.session_status = "AUTHORIZED"
        self.fail_balances: EnableBankingError | None = None
        self.pages = {None: {"transactions": [tx("t1", "12.30", "DBIT")], "continuation_key": "next+/="},
                      "next+/=": {"transactions": [tx("t2", "2500.00", "CRDT")]}}

    async def close(self):
        pass

    async def start_authorization(self, **kwargs):
        self.calls.append(("auth", kwargs))
        return {"url": "https://tilisy.enablebanking.com/welcome?x=1", "authorization_id": "auth-1"}

    async def create_session(self, code):
        self.calls.append(("session", code))
        return {"session_id": "sess-SECRET-1", "access": {"valid_until": "2027-02-01T00:00:00+00:00"},
                "accounts": [
                    {"uid": "acc-1", "account_id": {"iban": IBAN_A}, "name": "Main", "currency": "EUR", "cash_account_type": "CACC"},
                    {"uid": "acc-2", "account_id": {"iban": IBAN_B}, "currency": "EUR", "cash_account_type": "SVGS"},
                    {"uid": "bad uid!", "account_id": {"iban": IBAN_B}, "currency": "EUR"},
                ]}

    async def get_session(self, session_id, psu=None):
        self.calls.append(("get_session", session_id))
        self.psu.append(psu)
        return {"status": self.session_status, "access": {"valid_until": "2027-02-01T00:00:00+00:00"}}

    async def delete_session(self, session_id):
        self.calls.append(("delete", session_id))

    async def balances(self, uid, psu=None):
        self.calls.append(("balances", uid))
        self.psu.append(psu)
        if self.fail_balances:
            raise self.fail_balances
        return {"balances": [{"name": "x", "balance_amount": {"currency": "EUR", "amount": "1234.56"},
                              "balance_type": "ITBD", "reference_date": "2026-11-15"}]}

    async def transactions(self, uid, *, date_from, continuation_key, psu=None):
        self.calls.append(("transactions", uid, date_from, continuation_key))
        self.psu.append(psu)
        return self.pages[continuation_key]


def tx(tid, amount, indicator, creditor_iban=IBAN_B):
    return {"transaction_id": tid, "transaction_amount": {"currency": "EUR", "amount": amount},
            "credit_debit_indicator": indicator, "status": "BOOK", "booking_date": "2026-11-05",
            "creditor": {"name": "Rimi", "postal_address": {"town_name": "Riga"}},
            "creditor_account": {"iban": creditor_iban}, "debtor": {"name": "ACME"},
            "debtor_account": {"iban": IBAN_A}, "remittance_information": ["Groceries"],
            "balance_after_transaction": {"currency": "EUR", "amount": "1.00"}, "merchant_category_code": "5411"}


class Harness:
    def __init__(self, **overrides):
        self.now = 1_800_000_000
        self.eb = FakeEB()
        self.store = Store(":memory:", b"k" * 32, clock=lambda: self.now)
        self.app = create_app(settings(**overrides), eb_client=self.eb, store=self.store, clock=lambda: self.now,
                              check_key_file=False)
        self.http = TestClient(self.app, base_url="http://localhost", follow_redirects=False)
        self.nonce = 0

    def signed(self, method, path, body=None, *, secret=SECRET, nonce=None, timestamp=None, client="wealthos-ios"):
        data = json.dumps(body, separators=(",", ":"), sort_keys=True).encode() if body is not None else b""
        self.nonce += 1
        nonce = nonce or f"nonce-{self.nonce:08d}"
        ts = str(timestamp if timestamp is not None else self.now)
        headers = {"X-WOS-Client": client, "X-WOS-Timestamp": ts, "X-WOS-Nonce": nonce,
                   "X-WOS-Signature": sign(secret, method, path, ts, nonce, data)}
        if body is not None:
            headers["Content-Type"] = "application/json"
        return self.http.request(method, path, content=data or None, headers=headers)

    def connect(self) -> dict:
        start = self.signed("POST", "/v1/auth/start", {"aspsp_name": "Swedbank", "aspsp_country": "LV", "psu_type": "personal"})
        assert start.status_code == 200, start.text
        state = self.eb.calls[-1][1]["state"]
        callback = self.http.get(f"/v1/callback?code=CODE-123&state={state}")
        assert callback.status_code == 302
        completed = self.signed("POST", "/v1/auth/complete", {"attempt_id": start.json()["attempt_id"]})
        assert completed.status_code == 200, completed.text
        return completed.json()


# ---- authentication -------------------------------------------------------------------------

def test_requests_without_valid_signature_are_rejected():
    h = Harness()
    path = "/v1/connections/con_x"
    assert h.http.get(path).status_code == 401
    assert h.signed("GET", path, secret="wrong" * 10).status_code == 401
    assert h.signed("GET", path, client="someone-else").status_code == 401
    assert h.signed("GET", path, timestamp=h.now - 600).status_code == 401
    assert h.signed("GET", path, nonce="bad nonce!").status_code == 401


def test_nonce_replay_is_rejected():
    h = Harness()
    first = h.signed("GET", "/v1/connections/con_x", nonce="replayed-nonce")
    assert first.status_code == 404  # authenticated, unknown connection
    assert h.signed("GET", "/v1/connections/con_x", nonce="replayed-nonce").status_code == 401


def test_timestamp_outside_skew_window_is_rejected_both_ways():
    h = Harness()
    path = "/v1/connections/con_x"
    assert h.signed("GET", path, timestamp=h.now + 121).status_code == 401  # from the future
    assert h.signed("GET", path, timestamp=h.now - 121).status_code == 401  # stale
    assert h.signed("GET", path, timestamp=h.now + 120).status_code == 404  # edge: still accepted
    assert h.signed("GET", path, timestamp="1800000000.0").status_code == 401  # non-integer


def test_replay_with_a_fresh_timestamp_is_still_rejected():
    # Re-signing with a new timestamp needs the secret, and the nonce is single-use anyway.
    h = Harness()
    assert h.signed("GET", "/v1/connections/con_x", nonce="nonce-replay-02").status_code == 404
    h.now += 60
    assert h.signed("GET", "/v1/connections/con_x", nonce="nonce-replay-02").status_code == 401


def test_rejected_request_does_not_burn_the_nonce():
    # Otherwise an attacker could pre-burn nonces with garbage signatures.
    h = Harness()
    assert h.signed("GET", "/v1/connections/con_x", nonce="nonce-unburnt-1", secret="wrong" * 10).status_code == 401
    assert h.signed("GET", "/v1/connections/con_x", nonce="nonce-unburnt-1").status_code == 404


def test_body_tampering_breaks_signature():
    h = Harness()
    body = json.dumps({"attempt_id": "att_aaaaaaaa"}).encode()
    ts, nonce = str(h.now), "nonce-tamper-1"
    headers = {"X-WOS-Client": "wealthos-ios", "X-WOS-Timestamp": ts, "X-WOS-Nonce": nonce,
               "X-WOS-Signature": sign(SECRET, "POST", "/v1/auth/complete", ts, nonce, body),
               "Content-Type": "application/json"}
    tampered = json.dumps({"attempt_id": "att_bbbbbbbb"}).encode()
    assert h.http.post("/v1/auth/complete", content=tampered, headers=headers).status_code == 401


def test_untrusted_host_header_is_rejected():
    h = Harness()
    assert TestClient(h.app, base_url="http://evil.example").get("/v1/health").status_code == 400


def test_api_docs_and_cors_are_disabled():
    h = Harness()
    assert h.http.get("/docs").status_code == 404
    assert h.http.get("/openapi.json").status_code == 404
    preflight = h.http.options("/v1/auth/start", headers={"Origin": "https://evil.example",
                                                         "Access-Control-Request-Method": "POST"})
    assert "access-control-allow-origin" not in {k.lower() for k in preflight.headers}


# ---- authorization flow ---------------------------------------------------------------------

def test_full_flow_never_exposes_code_or_session_to_the_app():
    h = Harness()
    connection = h.connect()
    assert [a["uid"] for a in connection["accounts"]] == ["acc-1", "acc-2"]  # invalid uid dropped
    text = json.dumps(connection)
    assert "CODE-123" not in text and "sess-SECRET-1" not in text and IBAN_A not in text
    assert connection["accounts"][0]["account_key"] == normalize.iban_key(IBAN_A)
    assert connection["accounts"][0]["masked_identifier"] == "LV** **** 0001"


def test_only_the_allowlisted_bank_can_be_started():
    h = Harness()
    response = h.signed("POST", "/v1/auth/start", {"aspsp_name": "Other Bank", "aspsp_country": "LV", "psu_type": "personal"})
    assert response.status_code == 403
    business = h.signed("POST", "/v1/auth/start", {"aspsp_name": "Swedbank", "aspsp_country": "LV", "psu_type": "business"})
    assert business.status_code == 422


def test_callback_state_is_single_use_and_redirect_carries_no_code():
    h = Harness()
    start = h.signed("POST", "/v1/auth/start", {"aspsp_name": "Swedbank", "aspsp_country": "LV", "psu_type": "personal"})
    state = h.eb.calls[-1][1]["state"]
    first = h.http.get(f"/v1/callback?code=CODE-123&state={state}")
    location = urlparse(first.headers["location"])
    assert location.scheme == "wealthos" and location.netloc == "bank-callback"
    assert parse_qs(location.query) == {"attempt": [start.json()["attempt_id"]], "result": ["success"]}
    assert h.http.get(f"/v1/callback?code=CODE-456&state={state}").status_code == 400
    assert [c for c in h.eb.calls if c[0] == "session"] == [("session", "CODE-123")]


def test_unknown_or_expired_state_does_nothing():
    h = Harness()
    assert h.http.get("/v1/callback?code=X&state=forged").status_code == 400
    h.signed("POST", "/v1/auth/start", {"aspsp_name": "Swedbank", "aspsp_country": "LV", "psu_type": "personal"})
    state = h.eb.calls[-1][1]["state"]
    h.now += 16 * 60
    assert h.http.get(f"/v1/callback?code=X&state={state}").status_code == 400
    assert not [c for c in h.eb.calls if c[0] == "session"]


def test_callback_without_state_or_with_mismatched_state_does_nothing():
    h = Harness()
    h.signed("POST", "/v1/auth/start", {"aspsp_name": "Swedbank", "aspsp_country": "LV", "psu_type": "personal"})
    state = h.eb.calls[-1][1]["state"]
    assert h.http.get("/v1/callback?code=X").status_code == 400
    assert h.http.get("/v1/callback?code=X&state=").status_code == 400
    assert h.http.get(f"/v1/callback?code=X&state={state[:-1]}").status_code == 400
    assert h.http.get(f"/v1/callback?code=X&state={state}x").status_code == 400
    assert not [c for c in h.eb.calls if c[0] == "session"]
    # The genuine state still works afterwards: failed guesses don't consume it.
    assert h.http.get(f"/v1/callback?code=X&state={state}").status_code == 302


def test_rejected_consent_is_reported_and_not_completed():
    h = Harness()
    start = h.signed("POST", "/v1/auth/start", {"aspsp_name": "Swedbank", "aspsp_country": "LV", "psu_type": "personal"})
    state = h.eb.calls[-1][1]["state"]
    redirect = h.http.get(f"/v1/callback?error=access_denied&error_description=no&state={state}")
    assert parse_qs(urlparse(redirect.headers["location"]).query)["error"] == ["access_denied"]
    completed = h.signed("POST", "/v1/auth/complete", {"attempt_id": start.json()["attempt_id"]})
    assert completed.status_code == 400 and completed.json() == {"error": "authorization_rejected"}


def test_completion_is_single_use_and_pending_is_reported():
    h = Harness()
    start = h.signed("POST", "/v1/auth/start", {"aspsp_name": "Swedbank", "aspsp_country": "LV", "psu_type": "personal"})
    attempt = start.json()["attempt_id"]
    assert h.signed("POST", "/v1/auth/complete", {"attempt_id": attempt}).json() == {"error": "attempt_pending"}
    state = h.eb.calls[-1][1]["state"]
    h.http.get(f"/v1/callback?code=C&state={state}")
    assert h.signed("POST", "/v1/auth/complete", {"attempt_id": attempt}).status_code == 200
    assert h.signed("POST", "/v1/auth/complete", {"attempt_id": attempt}).status_code == 404


# ---- data access ----------------------------------------------------------------------------

def test_account_must_belong_to_the_connection():
    h = Harness()
    connection = h.connect()["connection_id"]
    assert h.signed("GET", f"/v1/connections/{connection}/accounts/acc-999/balances").status_code == 404
    assert h.signed("GET", f"/v1/connections/con_other/accounts/acc-1/balances").status_code == 404
    assert not [c for c in h.eb.calls if c[0] == "balances"]


def test_balances_are_decimal_strings():
    h = Harness()
    connection = h.connect()["connection_id"]
    response = h.signed("GET", f"/v1/connections/{connection}/accounts/acc-1/balances")
    assert response.json()["balances"][0]["amount"] == "1234.56"
    assert response.json()["balances"][0]["balance_type"] == "ITBD"


def test_transactions_paginate_and_are_minimised():
    h = Harness()
    connection = h.connect()["connection_id"]
    base = f"/v1/connections/{connection}/accounts/acc-1/transactions"
    first = h.signed("GET", f"{base}?date_from=2026-11-01").json()
    assert first["continuation_key"] == "next+/="
    second = h.signed("GET", f"{base}?date_from=2026-11-01&continuation_key=next%2B%2F%3D").json()
    assert second["continuation_key"] is None
    out, inn = first["transactions"][0], second["transactions"][0]
    assert out["amount"] == "12.30" and out["counterparty_name"] == "Rimi"
    assert out["counterparty_account_hash"] == normalize.iban_key(IBAN_B)
    assert inn["counterparty_name"] == "ACME" and inn["counterparty_account_hash"] == normalize.iban_key(IBAN_A)
    text = json.dumps(first) + json.dumps(second)
    assert IBAN_A not in text and IBAN_B not in text and "Riga" not in text and "balance_after" not in text
    assert h.signed("GET", f"{base}?date_from=01.11.2026").status_code == 422


def test_expired_consent_is_mapped_for_the_app():
    h = Harness()
    connection = h.connect()["connection_id"]
    h.eb.fail_balances = EnableBankingError(401, "EXPIRED_SESSION")
    h.eb.session_status = "EXPIRED"
    response = h.signed("GET", f"/v1/connections/{connection}/accounts/acc-1/balances")
    assert response.status_code == 410 and response.json() == {"error": "consent_expired"}
    h.eb.session_status = "REVOKED"
    assert h.signed("GET", f"/v1/connections/{connection}/accounts/acc-1/balances").json() == {"error": "consent_revoked"}


def test_bank_rate_limit_is_passed_through():
    h = Harness()
    connection = h.connect()["connection_id"]
    h.eb.fail_balances = EnableBankingError(429, "", "900")
    response = h.signed("GET", f"/v1/connections/{connection}/accounts/acc-1/balances")
    assert response.status_code == 429 and response.headers["retry-after"] == "900"


def test_disconnect_deletes_session_and_connection():
    h = Harness()
    connection = h.connect()["connection_id"]
    assert h.signed("DELETE", f"/v1/connections/{connection}").json() == {"deleted": True}
    assert ("delete", "sess-SECRET-1") in h.eb.calls
    assert h.signed("GET", f"/v1/connections/{connection}").status_code == 404


def test_session_id_is_encrypted_at_rest():
    h = Harness()
    connection = h.connect()["connection_id"]
    raw = h.store.database.connection.execute(
        "SELECT session_enc FROM connections WHERE connection_id=?", (connection,)).fetchone()[0]
    assert "sess-SECRET-1" not in str(raw) and b"sess-SECRET-1" not in base64.b64decode(raw)


def test_logs_contain_no_codes_states_or_sessions(caplog):
    h = Harness()
    logger = logging.getLogger("wealthos.banking")
    logger.addHandler(caplog.handler)
    try:
        h.connect()
    finally:
        logger.removeHandler(caplog.handler)
    text = caplog.text
    assert "CODE-123" not in text and "sess-SECRET-1" not in text and "state=" not in text and SECRET not in text


# ---- normalisation and configuration --------------------------------------------------------

def test_normalisation_rejects_float_like_amounts():
    for bad in ["1e5", "1,50", "NaN", "", "12.3.4", None, 12.5]:
        assert normalize.valid_amount(bad) is None
    assert normalize.valid_amount("0.10") == "0.10"


def test_iban_key_is_stable_across_formatting():
    assert normalize.iban_key("lv80 haba 0551 0000 0000 1") == normalize.iban_key(IBAN_A)


def test_configuration_guards():
    with pytest.raises(ConfigError):
        settings(EB_ENVIRONMENT="production").validate_runtime(check_key_file=False)
    settings(EB_ENVIRONMENT="production", WOS_ALLOW_PRODUCTION=PRODUCTION_OPT_IN,
             EB_REDIRECT_URL="https://banking.example.com/v1/callback", WOS_ALLOWED_HOSTS="banking.example.com",
             WOS_DB_PATH="/tmp/wealthos-prod-test.sqlite3").validate_runtime(check_key_file=False)
    with pytest.raises(ConfigError):
        settings(WOS_CLIENT_SECRET="short").validate_runtime(check_key_file=False)
    with pytest.raises(ConfigError):
        settings(EB_REDIRECT_URL="http://evil.example/cb").validate_runtime(check_key_file=False)
    with pytest.raises(ConfigError):
        settings().validate_runtime(check_key_file=True)  # key file missing


def test_signature_matches_documented_canonical_form():
    # The iOS app signs exactly: METHOD \n path?query \n timestamp \n nonce \n sha256(body).
    import hashlib, hmac
    body = b'{"attempt_id":"att_123"}'
    canonical = "\n".join(["POST", "/v1/auth/complete", "1800000000", "nonce-1", hashlib.sha256(body).hexdigest()])
    expected = base64.b64encode(hmac.new(SECRET.encode(), canonical.encode(), hashlib.sha256).digest()).decode()
    assert sign(SECRET, "POST", "/v1/auth/complete", "1800000000", "nonce-1", body) == expected


# ---- cross-language test vectors --------------------------------------------------------------
# The SAME constants are asserted in WealthOSTests/BankingTests.swift
# (`BankClientTests.signatureMatchesCrossLanguageTestVectors`). The expected values were computed
# independently with `openssl dgst -sha256 -hmac` over the documented canonical form, so a change
# on either side that breaks interoperability fails both suites.

XLANG_SECRET = "0123456789abcdef" * 4
XLANG_VECTORS = [
    ("POST", "/v1/auth/complete", "1800000000", "nonce-00000001", b'{"attempt_id":"att_123"}',
     "aOL+10RprGLFWsBP5tLOaEMDSVe3qljqYrwU/gJZ3eM="),
    ("GET", "/v1/connections/con_abc/accounts/acc-1/transactions?date_from=2026-11-01&continuation_key=next%2B%2F%3D",
     "1800000000", "nonce-00000002", b"", "v72Ml1hXFJjx+wNu+XO/btKklVu3qYBay+Y0UYdhBpY="),
]


@pytest.mark.parametrize("method,path,timestamp,nonce,body,expected", XLANG_VECTORS)
def test_signature_matches_cross_language_test_vectors(method, path, timestamp, nonce, body, expected):
    assert sign(XLANG_SECRET, method, path, timestamp, nonce, body) == expected


def test_server_accepts_request_signed_with_cross_language_vector():
    # End to end: the exact headers an iOS client would send for vector 1 authenticate.
    h = Harness(WOS_CLIENT_SECRET=XLANG_SECRET)
    h.now = 1_800_000_000
    method, path, ts, nonce, body, expected = XLANG_VECTORS[0]

    def send(signature):
        return h.http.post(path, content=body, headers={
            "X-WOS-Client": "wealthos-ios", "X-WOS-Timestamp": ts, "X-WOS-Nonce": nonce,
            "X-WOS-Signature": signature, "Content-Type": "application/json"})

    # Control: one flipped character is rejected (and does not consume the nonce)...
    assert send(expected.replace("a", "b", 1)).status_code == 401
    # ...while the vector's signature passes authentication. "att_123" is not a well-formed
    # attempt id, so the authenticated request then fails body validation (422), never 401.
    accepted = send(expected)
    assert accepted.status_code == 422, accepted.text


def test_redirect_host_must_be_an_allowed_host():
    with pytest.raises(ConfigError):
        settings(EB_ENVIRONMENT="production", WOS_ALLOW_PRODUCTION=PRODUCTION_OPT_IN,
                 EB_REDIRECT_URL="https://banking.example.com/v1/callback",
                 WOS_DB_PATH="/tmp/x.sqlite3").validate_runtime(check_key_file=False)
    settings(EB_ENVIRONMENT="production", WOS_ALLOW_PRODUCTION=PRODUCTION_OPT_IN,
             EB_REDIRECT_URL="https://mac.tail1234.ts.net/v1/callback", WOS_DB_PATH="/tmp/x.sqlite3",
             WOS_ALLOWED_HOSTS="mac.tail1234.ts.net").validate_runtime(check_key_file=False)


def test_production_needs_a_persistent_database():
    with pytest.raises(ConfigError):
        settings(EB_ENVIRONMENT="production", WOS_ALLOW_PRODUCTION=PRODUCTION_OPT_IN,
                 EB_REDIRECT_URL="https://mac.tail1234.ts.net/v1/callback",
                 WOS_ALLOWED_HOSTS="mac.tail1234.ts.net").validate_runtime(check_key_file=False)


def test_database_of_one_environment_is_refused_by_the_other(tmp_path):
    from app.store import EnvironmentMismatch

    key = b"k" * 32
    path = tmp_path / "db" / "banking.sqlite3"
    Store(path, key, environment="sandbox")
    Store(path, key, environment="sandbox")  # same environment reopens fine
    with pytest.raises(EnvironmentMismatch):
        Store(path, key, environment="production")


def test_env_file_selection(monkeypatch, tmp_path):
    from app import config

    monkeypatch.delenv(config.ENV_FILE_VARIABLE, raising=False)
    assert config.env_file() == ".env"
    monkeypatch.setenv(config.ENV_FILE_VARIABLE, str(tmp_path / "missing.env"))
    config.get_settings.cache_clear()
    with pytest.raises(ConfigError):
        config.get_settings()
    config.get_settings.cache_clear()
