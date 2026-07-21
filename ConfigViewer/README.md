# Config Viewer

A read-only web UI for viewing the live DayZ server configs. Served at
`configs.<BaseDomain>`; talks to the API service's config endpoints.

## How it works

- One static file (`web/index.html`) — no build, no framework, no CDN.
- The nginx vhost serves the app and reverse-proxies `/api/` to the API service
  (`localhost:3100`), so the browser calls the config endpoints **same-origin**
  (no CORS).
- The browser signs each request itself (HMAC-SHA256 over the empty body, via
  Web Crypto) with the derived key the user pastes in — the same way the API
  verifies it. The viewer holds no secret of its own.

## Auth

Each user pastes the **Key ID + secret** of a derived key minted with the Keys
API. Use an **`observe`** (read-only) scope:

```
POST /keys/create   { "id": "config-viewer", "scope": "observe" }   # wizard key only
```

### First login on a fresh box

There is no default account, and **the wizard secret cannot be typed into the login form** —
the viewer always sends `X-Key-Id`, and an id that isn't in the key store is rejected outright
(it deliberately never falls back to the wizard secret). So the first credential must be minted
out-of-band. Run this ON the box, where the wizard secret lives:

```bash
SECRET=$(sudo awk -F= '/^HMAC_SECRET=/{print $2}' /etc/api/secrets.env)
BODY='{"id":"config-viewer","scope":"observe"}'
SIG=$(printf '%s' "$BODY" | openssl dgst -sha256 -hmac "$SECRET" -r | cut -d' ' -f1)
curl -s -X POST http://127.0.0.1:3100/keys/create \
  -H 'Content-Type: application/json' -H "X-Signature-256: sha256=$SIG" -d "$BODY"
```

The response contains the `id` and `secret` — **the secret is shown once**. Paste those two
values into the viewer's login form. Mint one key per person (`observe` scope) so any of them
can be revoked individually with `POST /keys/revoke`.

Credentials are stored in a cookie on the user's device (`Secure`,
`SameSite=Strict`) and destroyed the first time the API rejects them (401).

> The secret lives in a JS-readable cookie because the browser must sign with it.
> That is acceptable only for a read-only `observe` key — it can view the
> allowlisted configs and nothing else, and you can revoke it any time via
> `POST /keys/revoke`.

## Deploy

Two independent steps, both **report-only until you pass the apply flag**:

```powershell
# 1. TLS + nginx vhost + webroot (issues the configs. cert; creates /var/www/config-viewer)
../../Provision-Tls.ps1 -Service ConfigViewer          # dry run
../../Provision-Tls.ps1 -Service ConfigViewer -Apply

# 2. Ship the static app into the webroot
./deploy/Deploy-ConfigViewer.ps1                        # dry run
./deploy/Deploy-ConfigViewer.ps1 -Push
```

What gets exposed is controlled by the API's `Configs` allowlist
(`Api/deploy/deploy.config.json`), not here — this is only the front end.
