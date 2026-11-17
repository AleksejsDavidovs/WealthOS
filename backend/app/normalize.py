"""Turns Enable Banking resources into the minimal shapes the iOS app needs.

Data minimisation: raw account numbers (IBANs) never leave the backend. The app receives a
SHA-256 account key (stable across consents, used to recognise transfers between own accounts)
and a masked form for display. Amounts stay decimal strings end to end — never floats.
"""

from __future__ import annotations

import hashlib
import re
from decimal import Decimal, InvalidOperation

AMOUNT = re.compile(r"[+-]?\d+(\.\d+)?")
DAY = re.compile(r"\d{4}-\d{2}-\d{2}")
CURRENCY = re.compile(r"[A-Z]{3}")


def _clean(value, limit: int) -> str:
    return str(value).strip()[:limit] if isinstance(value, (str, int)) and str(value).strip() else ""


def normalize_iban(iban: str) -> str:
    return re.sub(r"\s+", "", iban).upper()


def iban_key(iban: str) -> str:
    """Must be identical for an account's own IBAN and the same IBAN seen as a counterparty."""
    return hashlib.sha256(("iban:" + normalize_iban(iban)).encode()).hexdigest()


def mask(identifier: str) -> str:
    compact = normalize_iban(identifier)
    if len(compact) <= 4:
        return "****"
    return f"{compact[:2]}** **** {compact[-4:]}"


def _identifier(account_ref: dict | None) -> tuple[str, str]:
    """(key, masked) for an AccountIdentification-like object; ('','') when absent."""
    if not isinstance(account_ref, dict):
        return "", ""
    iban = account_ref.get("iban")
    if isinstance(iban, str) and iban.strip():
        return iban_key(iban), mask(iban)
    identification = account_ref.get("identification")
    scheme = str(account_ref.get("scheme_name") or "").upper()
    if isinstance(identification, str) and identification.strip():
        if scheme in ("", "IBAN") and re.fullmatch(r"[A-Z]{2}\d{2}[A-Z0-9]{10,30}", normalize_iban(identification)):
            return iban_key(identification), mask(identification)
        return hashlib.sha256(f"other:{scheme}:{identification.strip()}".encode()).hexdigest(), mask(identification)
    other = account_ref.get("other")
    if isinstance(other, dict):
        return _identifier({"identification": other.get("identification"), "scheme_name": other.get("scheme_name") or "OTHER"})
    return "", ""


def valid_amount(text) -> str | None:
    if not isinstance(text, str) or not AMOUNT.fullmatch(text.strip()) or len(text) > 40:
        return None
    try:
        Decimal(text)
    except InvalidOperation:
        return None
    return text.strip()


def _amount(obj) -> tuple[str | None, str | None]:
    if not isinstance(obj, dict):
        return None, None
    currency = obj.get("currency")
    return valid_amount(obj.get("amount")), currency if isinstance(currency, str) and CURRENCY.fullmatch(currency) else None


def account(resource: dict) -> dict | None:
    """AccountResource → app account. Accounts without a stable identity are dropped (returns None)."""
    uid = resource.get("uid")
    if not isinstance(uid, str) or not re.fullmatch(r"[A-Za-z0-9_-]{1,128}", uid):
        return None
    key, masked = _identifier(resource.get("account_id"))
    if not key:
        identification_hash = resource.get("identification_hash")
        if isinstance(identification_hash, str) and identification_hash:
            key = hashlib.sha256(("ebh:" + identification_hash).encode()).hexdigest()
    if not key:
        return None
    limit_amount, limit_currency = _amount(resource.get("credit_limit"))
    currency = resource.get("currency")
    return {
        "uid": uid,
        "account_key": key,
        "display_name": _clean(resource.get("name") or resource.get("product") or resource.get("details"), 80),
        "masked_identifier": masked,
        "currency": currency if isinstance(currency, str) and CURRENCY.fullmatch(currency) else None,
        "cash_account_type": _clean(resource.get("cash_account_type"), 8),
        "product": _clean(resource.get("product"), 80),
        "credit_limit": {"amount": limit_amount, "currency": limit_currency} if limit_amount else None,
    }


def balance(item: dict) -> dict:
    amount, currency = _amount(item.get("balance_amount"))
    day = item.get("reference_date")
    return {
        "name": _clean(item.get("name"), 70),
        "amount": amount,
        "currency": currency,
        "balance_type": _clean(item.get("balance_type"), 4),
        "reference_date": day if isinstance(day, str) and DAY.fullmatch(day) else None,
        "last_change_date_time": _clean(item.get("last_change_date_time"), 40) or None,
    }


def transaction(item: dict) -> dict:
    amount, currency = _amount(item.get("transaction_amount"))
    indicator = item.get("credit_debit_indicator")
    indicator = indicator if indicator in ("CRDT", "DBIT") else None
    # The other party: who was paid for a debit, who paid for a credit.
    party, party_account = ("creditor", "creditor_account") if indicator == "DBIT" else ("debtor", "debtor_account")
    name = (item.get(party) or {}).get("name") if isinstance(item.get(party), dict) else None
    key, masked = _identifier(item.get(party_account)) if indicator else ("", "")
    code = item.get("bank_transaction_code") if isinstance(item.get("bank_transaction_code"), dict) else {}
    remittance = item.get("remittance_information") if isinstance(item.get("remittance_information"), list) else []
    status = item.get("status")

    def day(field: str):
        value = item.get(field)
        return value if isinstance(value, str) and DAY.fullmatch(value) else None

    return {
        "transaction_id": _clean(item.get("transaction_id"), 128) or None,
        "entry_reference": _clean(item.get("entry_reference"), 128) or None,
        "status": status if status in ("BOOK", "PDNG", "OTHR") else "OTHR",
        "credit_debit_indicator": indicator,
        "amount": amount,
        "currency": currency,
        "booking_date": day("booking_date"),
        "value_date": day("value_date"),
        "transaction_date": day("transaction_date"),
        "counterparty_name": _clean(name, 140) or None,
        "counterparty_account_hash": key or None,
        "counterparty_account_masked": masked or None,
        "remittance": [_clean(line, 140) for line in remittance[:5] if _clean(line, 140)],
        "reference_number": _clean(item.get("reference_number"), 70) or None,
        "bank_transaction_code": "|".join(_clean(code.get(k), 40) for k in ("code", "sub_code", "description")).strip("|") or None,
        "merchant_category_code": _clean(item.get("merchant_category_code"), 4) or None,
    }
