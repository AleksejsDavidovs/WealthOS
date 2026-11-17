#!/usr/bin/env python3
"""Uploads one Worker environment's secrets with `wrangler secret put`, without printing them.

    python put_secrets.py --env sandbox    --env-file ../.env             [--dry-run]
    python put_secrets.py --env production --env-file ../.env.production  [--allow-real-bank] [--dry-run]

- EB_APPLICATION_ID and the private key come from the given backend env file (the key file is
  read from EB_PRIVATE_KEY_PATH; it must be chmod 600 and outside the repository).
- WOS_CLIENT_SECRET and WOS_DATA_KEY are generated fresh for this Worker, so the cloud Worker
  never shares credentials with the local server. They are kept in
  ~/.wealthos/secrets/cloudflare-<env>.env (chmod 600) — the iPhone app needs the client secret.
  Re-running reuses that file, so the app keeps working.
- WOS_ALLOW_PRODUCTION (the real-bank opt-in) is uploaded only with --allow-real-bank.
Values travel to wrangler over stdin only — never as arguments, never on screen.
"""

from __future__ import annotations

import argparse
import base64
import os
import secrets
import stat
import subprocess
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
REPO = HERE.parents[1]
SECRETS_DIR = Path.home() / ".wealthos" / "secrets"
PRODUCTION_OPT_IN = "I_UNDERSTAND_THIS_ACCESSES_REAL_BANK_DATA"


def read_env_file(path: Path) -> dict[str, str]:
    values = {}
    for line in path.read_text().splitlines():
        line = line.strip()
        if line and not line.startswith("#") and "=" in line:
            key, value = line.split("=", 1)
            values[key.strip()] = value.strip().strip('"').strip("'")
    return values


def private_file(path: Path, content: str) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    os.chmod(path.parent, 0o700)
    fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
    with os.fdopen(fd, "w") as handle:
        handle.write(content)


def checked_key(path: Path) -> str:
    path = path.expanduser().resolve()
    if not path.is_file():
        sys.exit("EB_PRIVATE_KEY_PATH does not point to a file")
    if path.stat().st_mode & (stat.S_IRWXG | stat.S_IRWXO):
        sys.exit("The private key must be chmod 600")
    if REPO in path.parents:
        sys.exit("Keep the private key outside the repository")
    pem = path.read_text().strip()
    if not pem.startswith("-----BEGIN PRIVATE KEY-----"):
        sys.exit("The key must be PKCS#8 PEM (BEGIN PRIVATE KEY)")
    return pem


def worker_credentials(env: str) -> dict[str, str]:
    path = SECRETS_DIR / f"cloudflare-{env}.env"
    if path.is_file():
        return read_env_file(path)
    values = {"WOS_CLIENT_SECRET": secrets.token_urlsafe(48),
              "WOS_DATA_KEY": base64.b64encode(os.urandom(32)).decode()}
    private_file(path, "".join(f"{k}={v}\n" for k, v in values.items()))
    return values


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--env", required=True, choices=["sandbox", "production"])
    parser.add_argument("--env-file", required=True, type=Path)
    parser.add_argument("--allow-real-bank", action="store_true")
    parser.add_argument("--dry-run", action="store_true", help="validate and list names; upload nothing")
    args = parser.parse_args()

    source = read_env_file(args.env_file)
    if source.get("EB_ENVIRONMENT", "sandbox") != args.env:
        sys.exit(f"{args.env_file} is for {source.get('EB_ENVIRONMENT', 'sandbox')}, not {args.env}")
    if args.allow_real_bank and args.env != "production":
        sys.exit("--allow-real-bank only applies to production")
    uploads = {"EB_APPLICATION_ID": source["EB_APPLICATION_ID"],
               "EB_PRIVATE_KEY_PEM": checked_key(Path(source["EB_PRIVATE_KEY_PATH"]))}
    if not args.dry_run:
        uploads.update(worker_credentials(args.env))
    else:
        uploads.update({"WOS_CLIENT_SECRET": "(generated)", "WOS_DATA_KEY": "(generated)"})
    if args.allow_real_bank:
        uploads["WOS_ALLOW_PRODUCTION"] = PRODUCTION_OPT_IN

    for name, value in uploads.items():
        if args.dry_run:
            print(f"would set {name} for --env {args.env}")
            continue
        config = ["-c", "wrangler.local.jsonc"] if (HERE / "wrangler.local.jsonc").is_file() else []
        result = subprocess.run(["npx", "--no-install", "wrangler", "secret", "put", name, "--env", args.env, *config],
                                input=value.encode(), cwd=HERE, stdout=subprocess.DEVNULL, stderr=subprocess.PIPE)
        if result.returncode != 0:
            sys.exit(f"wrangler secret put {name} failed (exit {result.returncode})")
        print(f"set {name} for --env {args.env}")
    if not args.dry_run:
        print(f"Worker client secret kept in {SECRETS_DIR / f'cloudflare-{args.env}.env'} (not shown).")


if __name__ == "__main__":
    main()
