# chutes-n8n-local

Self-hosted n8n with native `Login with Chutes`, bundled `n8n-nodes-chutes`, local `e2ee-local-proxy.chutes.dev` mode, and public-domain mode with ACME.

## Quick Start

macOS/Linux:

```bash
curl -fsSL https://raw.githubusercontent.com/chutesai/chutes-n8n-local/main/install.sh | bash
```

The installer:

- clones or refreshes `chutesai/chutes-n8n-local`
- runs `bootstrap.sh`
- auto-clones `chutesai/n8n-nodes-chutes` beside it if missing
- fast-forwards `n8n-nodes-chutes` on clean reruns so the embedded nodes do not drift stale

## Manual Clone

HTTPS:

```bash
git clone https://github.com/chutesai/chutes-n8n-local.git
cd chutes-n8n-local
./bootstrap.sh
```

SSH:

```bash
git clone git@github.com:chutesai/chutes-n8n-local.git
cd chutes-n8n-local
./bootstrap.sh
```

If `../n8n-nodes-chutes` is missing, bootstrap will clone:

```text
https://github.com/chutesai/n8n-nodes-chutes.git
```

You can override that source if needed with:

```bash
CHUTES_N8N_NODES_GIT_URL=git@github.com:chutesai/n8n-nodes-chutes.git ./bootstrap.sh
```

## Bootstrap

```bash
./bootstrap.sh
./bootstrap.sh --force
./bootstrap.sh --wipe
./bootstrap.sh --reset-owner-password
./bootstrap.sh --down
```

Bootstrap asks for:

- install mode: `local` or `domain`
- existing-install action: `update` or `wipe`
- Chutes OAuth client ID and secret
- ACME email for `domain` installs

Mode behavior:

- `local`: serves n8n at `https://e2ee-local-proxy.chutes.dev` using the embedded e2ee-proxy certificate path
- `domain`: serves n8n on your real domain through Caddy with Let's Encrypt

Existing install behavior:

- `update` is the default and preserves Postgres and n8n data volumes
- `wipe` removes containers, volumes, and encrypted n8n state, then recreates everything cleanly

## What Bootstrap Builds

- patched Community n8n with native Chutes SSO
- baked-in `n8n-nodes-chutes`
- `postgres`
- one edge service:
  - `local-proxy` for local installs
  - `caddy` for public-domain installs

## Quality

```bash
./scripts/smoke-test.sh --syntax
./scripts/smoke-test.sh
./scripts/e2e-test.sh
```

- `smoke-test.sh --syntax` is safe anywhere
- `e2e-test.sh` is destructive and rebuilds the local test stack

CI runs syntax smoke checks plus the local test-IdP end-to-end path.

## Repo Layout

- `install.sh`: one-line bootstrap entrypoint used by the raw GitHub quick start
- `bootstrap.sh`: main install and update entrypoint
- `docker-compose*.yml`: base, local, domain, and test stacks
- `Dockerfile.n8n`: pinned n8n build with SSO overlays and bundled Chutes nodes
- `n8n-overlays/`: native n8n backend and UI changes
- `scripts/`: bootstrap helpers, smoke tests, and E2E coverage
- `tests/test-chutes-idp/`: local test IdP for CI and destructive local E2E
