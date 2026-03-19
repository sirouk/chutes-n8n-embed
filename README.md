# chutes-n8n-local

Self-hosted n8n with native `Login with Chutes`, bundled `n8n-nodes-chutes`, local `e2ee-local-proxy.chutes.dev` mode, and public-domain mode with ACME.

This repo supports two packaging shapes:

- a single-container standalone image built from `Dockerfile.local-repo`
- a Docker Compose deployment driven by `deploy.sh`

Build workflows with Chutes-native auth, multi-modal capabilities, and node integrations on top of n8n's orchestration, scheduling, webhooks, and automation runtime.

## Quick Start

### Docker

```bash
docker run --rm -it \
  -p 80:80 -p 443:443 \
  -v chutes_n8n_data:/data \
  ghcr.io/chutesai/chutes-n8n-local:latest
```

See [Standalone Image](#standalone-image) for non-interactive runs, domain mode, runtime flags, persisted state layout, and building from source.

### Repo-Based

macOS/Linux/WSL:

```bash
bash <(curl -fsSL -H 'Cache-Control: no-cache' \
  "https://raw.githubusercontent.com/chutesai/chutes-n8n-local/main/deploy.sh?$(date +%s)")
```

The deploy script:

- clones or refreshes `chutesai/chutes-n8n-local`
- runs `deploy.sh`
- auto-clones `sirouk/n8n-nodes-chutes` beside it if missing
- fast-forwards `n8n-nodes-chutes` on clean reruns so the embedded nodes do not drift stale

When launched from a terminal, the deploy script prompts for install mode and the required Chutes OAuth settings even when invoked via `curl ... | bash`.

For headless or CI usage, preseed the required environment variables:

```bash
curl -fsSL https://raw.githubusercontent.com/chutesai/chutes-n8n-local/main/deploy.sh | \
  INSTALL_MODE=local \
  CHUTES_OAUTH_CLIENT_ID=... \
  CHUTES_OAUTH_CLIENT_SECRET=... \
  bash
```

Manual clone:

```bash
git clone https://github.com/chutesai/chutes-n8n-local.git
cd chutes-n8n-local
./deploy.sh
```

If `../n8n-nodes-chutes` is missing, deploy will clone:

```text
https://github.com/sirouk/n8n-nodes-chutes.git
```

You can override that source if needed (fork) with:

```bash
CHUTES_N8N_NODES_GIT_URL=git@github.com:sirouk/n8n-nodes-chutes.git ./deploy.sh
```

## Deploy

```bash
./deploy.sh
./deploy.sh --force
./deploy.sh --wipe
./deploy.sh --reset-owner-password
./deploy.sh --down
```

Deploy asks for, when a terminal is attached:

- install mode: `local` or `domain`
- existing-install action: `update` or `wipe`
- Chutes traffic mode: `direct` or `e2ee-proxy`
- if you pick `e2ee-proxy`, deploy also asks whether to keep it strict TEE-only for text models
- Chutes OAuth client ID and secret
- ACME email for `domain` installs

Mode behavior:

- `local`: serves n8n at `https://e2ee-local-proxy.chutes.dev` using the embedded e2ee-proxy certificate path
- `domain`: serves n8n on your real domain through Caddy with Let's Encrypt

Existing install behavior:

- `update` is the default and preserves Postgres and n8n data volumes
- `wipe` removes containers, volumes, and encrypted n8n state, then recreates everything cleanly

Chutes traffic mode:

- `direct`: the Chutes nodes use native Chutes endpoints and keep Chutes routing and failover behavior
- `e2ee-proxy`: OpenAI-compatible LLM text traffic uses the local `e2ee-proxy` path
  By default this follows `e2ee-proxy`'s TEE-only behavior. Deploy asks whether to keep that strict mode, and it writes `ALLOW_NON_CONFIDENTIAL` accordingly.
  While the backend `/e2e/*` SSO auth fix is rolling out, deploy also keeps `CHUTES_SSO_PROXY_BYPASS=true` so SSO-backed text execution stays direct. Once that backend fix is live, set it to `false` to send SSO text execution through `e2ee-proxy` too.

Traffic-mode scope:

- `local` / `domain` controls how n8n itself is exposed
- `direct` / `e2ee-proxy` controls how text-based Chutes LLM requests are executed
- chute discovery and non-text Chutes traffic stay on native Chutes endpoints

## Standalone Image

`Dockerfile.local-repo` packages n8n, OpenResty, Caddy, s6-overlay, bundled Chutes nodes, and starter workflows into a single image.

Published image:

- `ghcr.io/chutesai/chutes-n8n-local:latest`
- release tags are also published as semver tags when releases are cut

Releases are published for `linux/amd64`.

Persistent standalone state lives under `/data`:

- `/data/.n8n`: n8n user data and SQLite database
- `/data/caddy`: Caddy certificate and state storage
- `/data/.env`: standalone runtime configuration written after first boot
- `/data/.configured`: initialization sentinel

Build from source locally:

The examples below tag the image as `chutes-n8n-local:local-repo` to make it clear that it was built from your current checkout, not pulled from GHCR.

```bash
docker buildx build --load \
  -t chutes-n8n-local:local-repo \
  -f Dockerfile.local-repo .
```

Run it interactively and let the container prompt for settings:

```bash
docker run --rm -it \
  -p 80:80 -p 443:443 \
  -v chutes_n8n_data:/data \
  chutes-n8n-local:local-repo
```

Run it non-interactively in local mode:

```bash
docker run --rm -it \
  -p 80:80 -p 443:443 \
  -v chutes_n8n_data:/data \
  -e INSTALL_MODE=local \
  -e CHUTES_TRAFFIC_MODE=direct \
  -e CHUTES_OAUTH_CLIENT_ID=... \
  -e CHUTES_OAUTH_CLIENT_SECRET=... \
  chutes-n8n-local:local-repo
```

Run it non-interactively in domain mode:

```bash
docker run --rm -it \
  -p 80:80 -p 443:443 \
  -v chutes_n8n_data:/data \
  -e INSTALL_MODE=domain \
  -e N8N_HOST=n8n.example.com \
  -e ACME_EMAIL=you@example.com \
  -e CHUTES_TRAFFIC_MODE=e2ee-proxy \
  -e CHUTES_OAUTH_CLIENT_ID=... \
  -e CHUTES_OAUTH_CLIENT_SECRET=... \
  chutes-n8n-local:local-repo
```

Standalone runtime knobs:

- `INSTALL_MODE`: `local` or `domain`
- `CHUTES_TRAFFIC_MODE`: `direct` or `e2ee-proxy`
- `N8N_HOST` and `ACME_EMAIL`: required for `domain`
- `--reconfigure`: rerun setup prompts while preserving existing data
- `--wipe`: delete persisted n8n and Caddy state, then initialize again

In local mode, the container serves n8n on `https://e2ee-local-proxy.chutes.dev`. To test it without editing your hosts file:

```bash
curl -sk \
  --resolve e2ee-local-proxy.chutes.dev:443:127.0.0.1 \
  https://e2ee-local-proxy.chutes.dev/
```

## What Deploy Builds

- Community n8n with native Chutes SSO
- baked-in `n8n-nodes-chutes`
- `n8n` built from `Dockerfile.local-repo`
- `postgres`
- one edge service:
  - `local-proxy` for local installs
  - `caddy` for public-domain installs
- optional `e2ee-proxy` sidecar for domain installs when `CHUTES_TRAFFIC_MODE=e2ee-proxy`

## Quality

```bash
./scripts/smoke-test.sh --syntax
./scripts/smoke-test.sh
./scripts/e2e-test.sh
```

- `smoke-test.sh --syntax` is safe anywhere
- `smoke-test.sh` validates the compose stack after `deploy.sh`
- `e2e-test.sh` is destructive and rebuilds the local test stack

CI runs syntax smoke checks plus the local test-IdP end-to-end path.

## Test Before Packaging

Before publishing the standalone image, validate both the existing compose path and the standalone package path:

```bash
./scripts/smoke-test.sh --syntax
./scripts/e2e-test.sh

docker buildx build --load \
  -t chutes-n8n-local:standalone-test \
  -f Dockerfile.local-repo .

mkdir -p .tmp/standalone-data

docker run --rm -it \
  -p 80:80 -p 443:443 \
  -v "$PWD/.tmp/standalone-data:/data" \
  -e INSTALL_MODE=local \
  -e CHUTES_TRAFFIC_MODE=direct \
  -e CHUTES_OAUTH_CLIENT_ID=... \
  -e CHUTES_OAUTH_CLIENT_SECRET=... \
  chutes-n8n-local:standalone-test
```

For the standalone image, check at least:

- first boot initializes cleanly with an empty `/data` volume
- second boot reuses the saved config without prompting again
- `--reconfigure` updates settings without deleting data
- `--wipe` clears persisted state and starts from scratch
- local mode responds on `https://e2ee-local-proxy.chutes.dev`
- domain mode obtains certificates and serves the expected hostname

## Repo Layout

- `deploy.sh`: consolidated quick-start, install, and update entrypoint
- `docker-compose*.yml`: base, local, domain, and test stacks
- `Dockerfile.local-repo`: standalone package image with n8n, OpenResty, Caddy, and s6-overlay
- `Dockerfile.n8n`: n8n-focused build recipe retained alongside the standalone image
- `n8n-overlays/`: native n8n backend and UI changes
- `standalone/`: standalone entrypoint, proxy templates, post-start setup, and s6 service definitions
- `scripts/`: deploy helpers, smoke tests, and E2E coverage
- `tests/test-chutes-idp/`: local test IdP for CI and destructive local E2E

## Licensing Note

This project builds on the self-hosted n8n Community Edition and adds Chutes-specific packaging, local/domain deployment, and native Chutes integrations.

Use of upstream n8n remains subject to n8n’s licensing terms, including the Sustainable Use License and any applicable Enterprise licensing. This repository does not modify or replace those upstream license obligations.

Before using this project in a commercial, embedded, hosted-for-others, or customer-facing offering, review the official n8n licensing and Community Edition documentation:

- https://docs.n8n.io/sustainable-use-license/
- https://docs.n8n.io/hosting/community-edition-features/
