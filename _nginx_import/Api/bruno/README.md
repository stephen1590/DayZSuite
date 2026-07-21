# Bruno collection for the servermander API

Open this folder in [Bruno](https://www.usebruno.com/) (open source, collections are
plain text files in git). Every request is signed automatically - a collection-level
pre-request script computes the HMAC-SHA256 signature over the exact body bytes.

## Setup (once)

1. Copy `.env.example` to `.env` (gitignored - credentials never enter the repo).
2. Fill in `HMAC_SECRET` (the wizard) and `VPP_TOKEN`. Values live on the box:
   `sudo cat /etc/api/secrets.env`.
3. In Bruno, select the **prod** environment.

The public endpoints (`index`, `healthz`, `dayz/actions`, `dayz/server-info`) need no
secret - the pre-request script skips signing for them, so they work with an empty `.env`.

## Which key signs: the environment picks it

Secrets only ever live in `.env`; the environment files map them and hold none. The
**selected environment** decides which credential signs:

| Environment | Signs with | For |
|---|---|---|
| **prod** | the wizard (`HMAC_SECRET`) | everything, including `/keys` management |
| **testing** | a derived key (`API_KEY_ID` + `API_KEY_SECRET`) | testing as a specific key |

To test as a derived key (e.g. a `config-viewer` observe key):

1. In the **prod** environment, run `keys/create` (mint it as the wizard). The response
   shows the `secret` **once**.
2. Put the id + secret in `.env` as `API_KEY_ID` / `API_KEY_SECRET`.
3. Switch to the **testing** environment. `/dayz/*` and `/sysload` now sign with that
   key (an `X-Key-Id` header is added automatically); `/keys/*` still uses the wizard.

`HMAC_SECRET` must stay the **wizard** - do not paste a derived secret there. A derived
key goes in `API_KEY_ID` / `API_KEY_SECRET`, nowhere else. (Signing with a derived
secret but no `X-Key-Id` header is what produces a `bad_signature` 401 - the server
checks it against the wizard.)

## Layout

- `index` (GET /) - the whole-API discovery: every endpoint + the dayz action list.
- `healthz` - unauthenticated liveness probe; `dayz/actions` + `dayz/server-info` -
  public GETs (no auth).
- `sysload` - root host-load endpoint (authed, any key).
- `dayz/` - the command API, reads first (status, players, log, config), then
  broadcast/start, then the destructive ones (restart, stop, map). Destructive
  requests ship with `"force": false` - the player guard 409s while anyone is
  online, and a real run gives players a 15s in-game warning before acting.
- `dayz/sources/vpp` - simulates VPP's outbound event feed (URL-token auth).
- `keys/` - wizard-only derived-key management (always signed by the wizard).

## CLI

```bash
cd bruno
npx @usebruno/cli run sysload.bru --env prod       # as the wizard
npx @usebruno/cli run dayz/config.bru --env testing # as your derived key
```

The `.env` file is picked up automatically.

## Regenerating from the spec

`../openapi.yaml` is the source of truth for the HTTP surface. New endpoint flow:

1. Implement the action in `../app/src/actions.ts` (+ dayz-ctl verb if privileged).
2. Document it in `../openapi.yaml` (validate: `npx @apidevtools/swagger-cli validate ../openapi.yaml`).
3. `npm install && npm run generate` here - scaffolds a `.bru` for anything the
   spec has that this folder doesn't. Existing files are never touched; delete
   one (or `--force`) to regenerate it.
4. Tune the generated file (docs, body examples, seq order).

The spec also imports directly into the Bruno GUI (Import Collection - OpenAPI V3)
if you want a throwaway collection without the signing script.
