"""Configuration from environment / `.env`. Validated at startup; secrets are never logged."""

from __future__ import annotations

import base64
import os
import re
import stat
from urllib.parse import urlsplit
from functools import lru_cache
from pathlib import Path

from pydantic import Field, SecretStr, field_validator
from pydantic_settings import BaseSettings, SettingsConfigDict

PRODUCTION_OPT_IN = "I_UNDERSTAND_THIS_ACCESSES_REAL_BANK_DATA"


class ConfigError(RuntimeError):
    pass


class Settings(BaseSettings):
    model_config = SettingsConfigDict(env_file=".env", env_file_encoding="utf-8", extra="ignore")

    eb_environment: str = Field("sandbox", alias="EB_ENVIRONMENT")
    eb_application_id: str = Field(..., alias="EB_APPLICATION_ID")
    eb_private_key_path: Path | None = Field(None, alias="EB_PRIVATE_KEY_PATH")
    # Cloudflare Workers: the key arrives as a Worker secret instead of a file.
    eb_private_key_pem: SecretStr | None = Field(None, alias="EB_PRIVATE_KEY_PEM")
    eb_api_base: str = Field("https://api.enablebanking.com", alias="EB_API_BASE")
    eb_redirect_url: str = Field(..., alias="EB_REDIRECT_URL")
    eb_aspsp_name: str = Field("Swedbank", alias="EB_ASPSP_NAME")
    eb_aspsp_country: str = Field("LV", alias="EB_ASPSP_COUNTRY")
    eb_consent_days: int = Field(90, alias="EB_CONSENT_DAYS", ge=1, le=730)

    wos_client_id: str = Field(..., alias="WOS_CLIENT_ID")
    wos_client_secret: SecretStr = Field(..., alias="WOS_CLIENT_SECRET")
    wos_data_key: SecretStr = Field(..., alias="WOS_DATA_KEY")
    wos_db_path: Path = Field(Path("./data/wealthos-banking.sqlite3"), alias="WOS_DB_PATH")
    wos_app_callback: str = Field("wealthos://bank-callback", alias="WOS_APP_CALLBACK")
    wos_allowed_hosts: str = Field("localhost,127.0.0.1", alias="WOS_ALLOWED_HOSTS")
    wos_allow_production: str = Field("", alias="WOS_ALLOW_PRODUCTION")
    wos_storage: str = Field("sqlite", alias="WOS_STORAGE")  # sqlite (local file) | d1 (Cloudflare)
    wos_trust_cf_connecting_ip: bool = Field(False, alias="WOS_TRUST_CF_CONNECTING_IP")

    @field_validator("eb_application_id")
    @classmethod
    def _uuid(cls, value: str) -> str:
        if not re.fullmatch(r"[0-9a-fA-F-]{36}", value):
            raise ValueError("EB_APPLICATION_ID must be the application's UUID")
        return value

    @field_validator("wos_client_id")
    @classmethod
    def _client_id(cls, value: str) -> str:
        if not re.fullmatch(r"[A-Za-z0-9_-]{3,64}", value):
            raise ValueError("WOS_CLIENT_ID must be 3-64 characters [A-Za-z0-9_-]")
        return value

    @field_validator("eb_aspsp_country")
    @classmethod
    def _country(cls, value: str) -> str:
        if not re.fullmatch(r"[A-Z]{2}", value):
            raise ValueError("EB_ASPSP_COUNTRY must be a two-letter ISO code")
        return value

    @property
    def allowed_hosts(self) -> list[str]:
        return [h.strip() for h in self.wos_allowed_hosts.split(",") if h.strip()]

    @property
    def data_key(self) -> bytes:
        return base64.b64decode(self.wos_data_key.get_secret_value())

    def validate_runtime(self, check_key_file: bool = True) -> None:
        """Refuses unsafe configurations before the server accepts any request."""
        if self.eb_environment not in ("sandbox", "production"):
            raise ConfigError("EB_ENVIRONMENT must be 'sandbox' or 'production'")
        if self.eb_environment == "production" and self.wos_allow_production != PRODUCTION_OPT_IN:
            raise ConfigError("Production is disabled. Real-bank activation requires an explicit opt-in (see README).")
        secret = self.wos_client_secret.get_secret_value()
        if len(secret) < 43 or "REPLACE" in secret:
            raise ConfigError("WOS_CLIENT_SECRET must be at least 256 bits (use `python -m app.tools new-client`)")
        try:
            key = self.data_key
        except Exception as exc:  # noqa: BLE001 - never echo the value
            raise ConfigError("WOS_DATA_KEY must be base64") from exc
        if len(key) != 32:
            raise ConfigError("WOS_DATA_KEY must decode to 32 bytes (use `python -m app.tools new-data-key`)")
        if not (self.eb_redirect_url.startswith("https://") or self.eb_redirect_url.startswith("http://localhost")):
            raise ConfigError("EB_REDIRECT_URL must be https:// (http://localhost only for local sandbox)")
        if self.eb_environment == "production" and not self.eb_redirect_url.startswith("https://"):
            raise ConfigError("Production requires an https redirect URL")
        redirect_host = (urlsplit(self.eb_redirect_url).hostname or "").lower()
        if redirect_host not in [h.lower() for h in self.allowed_hosts]:
            # Otherwise the bank's browser redirect would be refused by the TrustedHost check.
            raise ConfigError("The EB_REDIRECT_URL host must be listed in WOS_ALLOWED_HOSTS")
        if self.wos_storage not in ("sqlite", "d1"):
            raise ConfigError("WOS_STORAGE must be 'sqlite' or 'd1'")
        if self.eb_environment == "production" and self.wos_storage == "sqlite" \
                and str(self.wos_db_path) in ("", ":memory:"):
            raise ConfigError("Production needs its own persistent WOS_DB_PATH")
        if self.eb_private_key_pem is not None:
            if self.eb_private_key_path is not None:
                raise ConfigError("Set EB_PRIVATE_KEY_PATH or EB_PRIVATE_KEY_PEM, not both")
            pem = self.eb_private_key_pem.get_secret_value().strip()
            # Shape check only: parsing the key is expensive under WebAssembly.
            if not (pem.startswith("-----BEGIN PRIVATE KEY-----") and pem.endswith("-----END PRIVATE KEY-----")):
                raise ConfigError("EB_PRIVATE_KEY_PEM must be a PKCS#8 PEM private key (BEGIN PRIVATE KEY)")
            return
        if self.eb_private_key_path is None:
            raise ConfigError("Set EB_PRIVATE_KEY_PATH (local) or EB_PRIVATE_KEY_PEM (Worker secret)")
        if check_key_file:
            path = self.eb_private_key_path.expanduser()
            if not path.is_file():
                raise ConfigError("EB_PRIVATE_KEY_PATH does not point to a file")
            mode = path.stat().st_mode
            if mode & (stat.S_IRWXG | stat.S_IRWXO):
                raise ConfigError("The private key file must not be accessible by group/others (chmod 600)")
            repo_root = Path(__file__).resolve().parents[2]
            try:
                path.resolve().relative_to(repo_root)
                raise ConfigError("Keep the private key outside the repository")
            except ValueError:
                pass

    def private_key_pem(self) -> bytes:
        if self.eb_private_key_pem is not None:
            return self.eb_private_key_pem.get_secret_value().strip().encode() + b"\n"
        if self.eb_private_key_path is None:
            raise ConfigError("No private key configured")
        return self.eb_private_key_path.expanduser().read_bytes()


ENV_FILE_VARIABLE = "WOS_ENV_FILE"


def env_file() -> str:
    """`.env` (sandbox) unless WOS_ENV_FILE names another file, e.g. `.env.production`.
    Keeping environments in separate files keeps their credentials, keys and databases apart."""
    return os.environ.get(ENV_FILE_VARIABLE) or ".env"


@lru_cache
def get_settings() -> Settings:
    path = env_file()
    if path != ".env" and not Path(path).is_file():
        raise ConfigError(f"{ENV_FILE_VARIABLE} points to a missing file")
    return Settings(_env_file=path)  # type: ignore[call-arg]


def ensure_private_dir(path: Path) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    os.chmod(path.parent, 0o700)
