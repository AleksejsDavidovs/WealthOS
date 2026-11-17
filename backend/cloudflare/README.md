# WealthOS banking backend on Cloudflare Workers

The same FastAPI app as `backend/app`, run on Python Workers (Free plan). The iOS API contract is
unchanged; only the server URL and client credentials in the app change.

| Local server (`backend/`) | Worker (`backend/cloudflare/`) |
|---|---|
| SQLite file | Cloudflare D1 (`DB` binding), same SQL |
| JWT via PyJWT | JWT via WebCrypto (native; `cryptography` costs ~190 ms CPU under WebAssembly) |
| `.env` / `.env.production` | `vars` in `wrangler.jsonc` + Worker secrets |
| stderr logs (redacted) | no logs at all; observability disabled |

Each environment is a separate Worker with its own URL, D1 database, secrets and Enable Banking
application: `--env sandbox` → `wealthos-banking-sandbox`, `--env production` → `wealthos-banking-prod`.
A database stamped for one environment is refused by the other.

Large bank pages are served in parts of 150 transactions (continuation keys starting `wos1.`) so
every request stays within the Free plan's 10 ms CPU limit. The unsent rest is stored encrypted
for at most 10 minutes, bound to client/connection/account, and can be read once.

## Local run (no Cloudflare account, synthetic data)

```sh
cd backend/cloudflare
npm install            # pinned wrangler
uv sync --python 3.13
# .dev.vars.sandbox: synthetic values only (gitignored) — see tests for the variable names
uv run pywrangler dev --env sandbox --port 8799 --ip 127.0.0.1 --local   # add -c wrangler.local.jsonc if you have one
```

`wrangler` runs `sync_app.sh` first, copying `../app` into `src/app` (gitignored).

## Deploy (each step needs explicit approval)

1. `npx wrangler login` (your Cloudflare account; Free plan).
2. `cp wrangler.jsonc wrangler.local.jsonc` (gitignored). `npx wrangler d1 create wealthos-banking-sandbox`
   → put the printed id into `wrangler.local.jsonc`; set `YOUR-SUBDOMAIN` to your workers.dev subdomain.
3. `python put_secrets.py --env sandbox --env-file ../.env --dry-run`, then without `--dry-run`.
4. `uv run pywrangler deploy --env sandbox -c wrangler.local.jsonc`.
5. Add `https://wealthos-banking-sandbox.<subdomain>.workers.dev/v1/callback` as a redirect URL
   of the Enable Banking **sandbox** application.
6. Point the app's Banking Server at the Worker URL with the client secret from
   `~/.wealthos/secrets/cloudflare-sandbox.env`.

Production repeats this with `--env production`, a new Enable Banking production application and
`../.env.production`; `--allow-real-bank` uploads the real-bank opt-in. Nothing here connects to a
real bank until that application is activated by linking accounts.
