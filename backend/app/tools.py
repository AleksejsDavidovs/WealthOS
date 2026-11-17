"""Setup helpers. Usage:

    python -m app.tools new-client         # prints a WOS_CLIENT_SECRET (put it in .env and in the app)
    python -m app.tools new-data-key       # prints a WOS_DATA_KEY
    python -m app.tools list-aspsps --country LV   # verifies the exact bank name (needs .env + key)
    python -m app.tools check-config       # validates the active env file offline; prints no secrets

Production uses a separate file: WOS_ENV_FILE=.env.production python -m app.tools check-config

Values are printed to your terminal only; nothing is written or sent anywhere else.
"""

from __future__ import annotations

import argparse
import asyncio
import base64
import os
import secrets


def main() -> None:
    parser = argparse.ArgumentParser(prog="python -m app.tools")
    sub = parser.add_subparsers(dest="command", required=True)
    sub.add_parser("new-client")
    sub.add_parser("new-data-key")
    sub.add_parser("check-config")
    aspsps = sub.add_parser("list-aspsps")
    aspsps.add_argument("--country", default="LV")
    args = parser.parse_args()

    if args.command == "new-client":
        print(secrets.token_hex(32))
    elif args.command == "new-data-key":
        print(base64.b64encode(os.urandom(32)).decode())
    elif args.command == "check-config":
        _check_config()
    elif args.command == "list-aspsps":
        asyncio.run(_list_aspsps(args.country))


def _check_config() -> None:
    from .config import env_file, get_settings

    settings = get_settings()
    settings.validate_runtime()
    app_id = settings.eb_application_id
    # Non-secret values only; the application id is shortened, secrets are never printed.
    print(f"env file:        {env_file()}")
    print(f"environment:     {settings.eb_environment}")
    print(f"application id:  {app_id[:8]}…{app_id[-4:]}")
    print(f"redirect url:    {settings.eb_redirect_url}")
    print(f"allowed hosts:   {', '.join(settings.allowed_hosts)}")
    print(f"bank:            {settings.eb_aspsp_name} ({settings.eb_aspsp_country}), consent {settings.eb_consent_days} days")
    print(f"database:        {settings.wos_db_path}")
    print("private key:     present, permissions OK, outside the repository")
    print("client secret:   set (not shown)")
    print("data key:        set (not shown)")
    print("OK")


async def _list_aspsps(country: str) -> None:
    from .config import get_settings
    from .enable_banking import EnableBankingClient, JWTSigner

    settings = get_settings()
    settings.validate_runtime()
    client = EnableBankingClient(settings.eb_api_base, JWTSigner(settings.eb_application_id, settings.private_key_pem()))
    try:
        for aspsp in await client.aspsps(country):
            print(f"{aspsp.get('name')!r:40} country={aspsp.get('country')} psu_types={aspsp.get('psu_types')} "
                  f"maximum_consent_validity={aspsp.get('maximum_consent_validity')}")
    finally:
        await client.close()


if __name__ == "__main__":
    main()
