# chutes-n8n-local

Self-hosted n8n with native `Login with Chutes`, bundled `n8n-nodes-chutes`, local `e2ee-local-proxy.chutes.dev` mode, and public-domain mode with ACME.

Build workflows with Chutes-native auth, multi-modal capabilities, and node integrations on top of n8n's orchestration, scheduling, webhooks, and automation runtime.

## Quick Start

macOS/Linux/WSL:

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/chutesai/chutes-n8n-local/main/deploy.sh)
```

The deploy script:

- clones or refreshes `chutesai/chutes-n8n-local`
- runs `deploy.sh`
- auto-clones `chutesai/n8n-nodes-chutes` beside it if missing
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

## Manual Clone


```bash
git clone https://github.com/chutesai/chutes-n8n-local.git
cd chutes-n8n-local
./deploy.sh
```

If `../n8n-nodes-chutes` is missing, deploy will clone:

```text
https://github.com/chutesai/n8n-nodes-chutes.git
```

You can override that source if needed (fork) with:

```bash
CHUTES_N8N_NODES_GIT_URL=git@github.com:chutesai/n8n-nodes-chutes.git ./deploy.sh
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

## What Deploy Builds

- Community n8n with native Chutes SSO
- baked-in `n8n-nodes-chutes`
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
- `e2e-test.sh` is destructive and rebuilds the local test stack

CI runs syntax smoke checks plus the local test-IdP end-to-end path.

## Repo Layout

- `deploy.sh`: consolidated quick-start, install, and update entrypoint
- `docker-compose*.yml`: base, local, domain, and test stacks
- `Dockerfile.n8n`: pinned n8n build with SSO overlays and bundled Chutes nodes
- `n8n-overlays/`: native n8n backend and UI changes
- `scripts/`: deploy helpers, smoke tests, and E2E coverage
- `tests/test-chutes-idp/`: local test IdP for CI and destructive local E2E

## Licensing Note

This project builds on the self-hosted n8n Community Edition and adds Chutes-specific packaging, local/domain deployment, and native Chutes integrations.

Use of upstream n8n remains subject to n8n’s licensing terms, including the Sustainable Use License and any applicable Enterprise licensing. This repository does not modify or replace those upstream license obligations.

Before using this project in a commercial, embedded, hosted-for-others, or customer-facing offering, review the official n8n licensing and Community Edition documentation:

- https://docs.n8n.io/sustainable-use-license/
- https://docs.n8n.io/hosting/community-edition-features/
