# WealthOS banking backend (Enable Banking, read-only)

A minimal FastAPI service that lets the WealthOS iOS app read **account information only** (accounts,
balances, transactions) from Swedbank Latvia through [Enable Banking](https://enablebanking.com/docs/api/reference/).
There is no payment, transfer or any money-moving endpoint — in this server or in the app.

```
iPhone/Simulator ──HMAC-signed HTTPS──▶ this backend ──RS256 JWT──▶ api.enablebanking.com ──▶ Swedbank
        ▲                                   │
        └── wealthos://bank-callback ◀──────┘ (browser redirect after the bank login; carries only an attempt id)
```

What stays on the server: the Enable Banking private key, JWTs, the authorization `code`, Enable Banking
`session_id`s (AES-256-GCM encrypted at rest) and raw IBANs. The app receives balances, transactions,
SHA-256 account keys and masked account numbers.

## 1. Enable Banking registration (Sandbox)

1. Create an account at https://enablebanking.com and open the Control Panel → **API applications**.
2. Create an application in the **Sandbox** environment.
3. Key pair: let the browser generate it (the private key is downloaded as `<application-id>.pem`
   and never transmitted), or generate one yourself and upload only the public key:
   ```sh
   mkdir -p ~/.wealthos/keys && chmod 700 ~/.wealthos ~/.wealthos/keys
   openssl genrsa -out ~/.wealthos/keys/enablebanking-sandbox.pem 4096
   openssl rsa -in ~/.wealthos/keys/enablebanking-sandbox.pem -pubout -out ~/.wealthos/keys/enablebanking-sandbox.pub.pem
   chmod 600 ~/.wealthos/keys/enablebanking-sandbox.pem
   ```
   Keep the private key **outside this repository** (the server refuses to start otherwise, and also if
   the file is readable by group/others).
4. Redirect URL whitelist: add exactly `http://localhost:8787/v1/callback`.
   If the Control Panel doesn't accept an `http://localhost` URL, use an HTTPS URL you control (see §5)
   and set the same value as `EB_REDIRECT_URL`.
5. Note the **application ID** (UUID) — it is the JWT `kid`.

## 2. Local setup (macOS Terminal)

```sh
cd backend
python3 -m venv .venv && source .venv/bin/activate
pip install -r requirements-dev.txt
cp .env.example .env && chmod 600 .env
python -m app.tools new-client      # → paste as WOS_CLIENT_SECRET in .env (and later into the app)
python -m app.tools new-data-key    # → paste as WOS_DATA_KEY in .env
# edit .env: EB_APPLICATION_ID, EB_PRIVATE_KEY_PATH (absolute path), EB_REDIRECT_URL
python -m pytest                    # offline tests; no network, no keys needed
python -m app.tools list-aspsps --country LV   # confirms the exact Swedbank ASPSP name (first live sandbox call)
uvicorn app.main:app --host 127.0.0.1 --port 8787 --no-access-log
```

`--host 127.0.0.1` keeps the server on the loopback interface: nothing else on your network can reach it.
`--no-access-log` matters: the default access log would print the callback query string, which contains the
authorization code. The app's own request log prints only method, route template and status.

## 3. Values to configure

| Where | Setting | Value |
| --- | --- | --- |
| `.env` | `EB_APPLICATION_ID` | Application UUID from the Control Panel |
| `.env` | `EB_PRIVATE_KEY_PATH` | Absolute path to the private key PEM (outside the repo, `chmod 600`) |
| `.env` | `EB_REDIRECT_URL` | Exactly the whitelisted redirect URL |
| `.env` | `EB_ASPSP_NAME` / `EB_ASPSP_COUNTRY` | As printed by `list-aspsps` (expected `Swedbank` / `LV`) |
| `.env` | `WOS_CLIENT_ID` / `WOS_CLIENT_SECRET` | Any id / output of `new-client` |
| `.env` | `WOS_DATA_KEY` | Output of `new-data-key` |
| WealthOS → Settings → Bank Connections → Banking Server | Server | `http://localhost:8787` (Simulator only) |
| same screen | Client ID / Client secret | Same as `WOS_CLIENT_ID` / `WOS_CLIENT_SECRET` |

Never paste these secrets into chats, issues or commits.

## 4. Sandbox test in the iOS Simulator

1. Start the backend (above). Run WealthOS in the **Simulator** (it shares the Mac's `localhost`).
   Use a fresh simulator or demo-free test data, not your real WealthOS data.
2. Settings → Bank Connections → Banking Server: enter the values from §3.
3. Tap **Connect Swedbank**. The Enable Banking/Swedbank sandbox page opens in a secure browser sheet.
   Use the sandbox credentials shown in the Enable Banking sandbox documentation for Swedbank (LV).
4. After approval the sheet closes; the accounts appear unlinked. Open each one and either
   **Link to This Account** (if you already track it manually) or **Add as New Account**.
5. Tap **Sync Now**. Check Accounts (bank balance), Transactions (bank icon) and the review queue.

A physical iPhone **cannot** reach `localhost` on your Mac. See §5.

## 5. Real iPhone and production — required changes (not done; needs your explicit go-ahead)

Real-bank access is blocked by design: `EB_ENVIRONMENT=production` refuses to start unless
`WOS_ALLOW_PRODUCTION=I_UNDERSTAND_THIS_ACCESSES_REAL_BANK_DATA`. Before setting that:

- **Hosting & TLS**: run the backend behind HTTPS with a valid certificate on a host you control
  (e.g. a small VPS or a private network reachable only by your devices such as Tailscale with HTTPS).
  Add the hostname to `WOS_ALLOWED_HOSTS`; set `EB_REDIRECT_URL=https://<host>/v1/callback` and whitelist it.
  Do not expose the plain-HTTP dev server or bind it to `0.0.0.0`.
- **Enable Banking production**: create a production application; activate it either in *restricted mode*
  (link your own accounts — data access limited to those) or via full KYC/contract review.
- **Secrets**: move `.env` values and the private key into a secrets manager or OS keychain-backed store,
  restrict file permissions, rotate `WOS_CLIENT_SECRET`/keys on suspicion, back up `WOS_DATA_KEY` securely
  (losing it orphans stored sessions; users would just reconnect).
- **Network hardening**: firewall to 443 only, reverse proxy with request size/time limits, fail2ban-style
  blocking on repeated 401s, OS/dependency updates, `pip install` from pinned hashes.
- **App**: prefer a universal-link HTTPS callback (`ASWebAuthenticationSession.Callback.https`, iOS 17.4+)
  with Associated Domains instead of the custom scheme; consider certificate pinning to your backend.
- **Multi-device**: today there is one client id/secret. For more devices, issue one per device and revoke
  individually.
- **Unattended access limits**: PSD2 banks limit background account-information requests per day; the app
  syncs automatically at most every 6 hours and never retries automatically in a loop.

## API (all `/v1/*` routes except `/v1/callback` and `/v1/health` require the HMAC headers)

| Method | Path | Purpose |
| --- | --- | --- |
| POST | `/v1/auth/start` | Starts Enable Banking `POST /auth` for the allow-listed bank; returns `attempt_id`, `authorization_url` |
| GET | `/v1/callback` | Browser redirect target; validates the single-use `state`, exchanges `code` (`POST /sessions`), redirects to `wealthos://bank-callback?attempt=…&result=…` |
| POST | `/v1/auth/complete` | One-time redemption of a completed attempt → connection id + accounts |
| GET | `/v1/connections/{id}` | Session status / `valid_until` (`GET /sessions/{id}`) |
| DELETE | `/v1/connections/{id}` | Ends the consent (`DELETE /sessions/{id}`) |
| GET | `/v1/connections/{id}/accounts/{uid}/balances` | Balances (decimal strings) |
| GET | `/v1/connections/{id}/accounts/{uid}/transactions?date_from=&continuation_key=` | One page of transactions |

Request signing: `X-WOS-Signature = base64(HMAC-SHA256(secret, METHOD\npath?query\ntimestamp\nnonce\nsha256hex(body)))`
with `X-WOS-Client`, `X-WOS-Timestamp` (±120 s) and a single-use `X-WOS-Nonce`. No CORS, API docs disabled,
TrustedHost enforced, 16 KB body limit, rate limits per client and IP.
