#!/usr/bin/env bash
set -euo pipefail

REPO_REF="${CHUTES_N8N_LOCAL_GIT_REF:-${CHUTES_N8N_EMBED_GIT_REF:-main}}"
REPO_URL="${CHUTES_N8N_LOCAL_GIT_URL:-${CHUTES_N8N_EMBED_GIT_URL:-https://github.com/chutesai/chutes-n8n-local.git}}"
INSTALL_DIR="${CHUTES_N8N_LOCAL_DIR:-${CHUTES_N8N_EMBED_DIR:-$HOME/chutes-n8n-local}}"

log() {
  printf '[install] %s\n' "$1"
}

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || {
    echo "$1 is required." >&2
    exit 1
  }
}

checkout_repo() {
  if [ -d "$INSTALL_DIR/.git" ]; then
    local dirty branch upstream

    dirty="$(git -C "$INSTALL_DIR" status --porcelain --untracked-files=no 2>/dev/null || true)"
    if [ -n "$dirty" ]; then
      log "existing checkout has local tracked changes; using it as-is"
      return
    fi

    branch="$(git -C "$INSTALL_DIR" rev-parse --abbrev-ref HEAD 2>/dev/null || echo HEAD)"
    upstream="$(git -C "$INSTALL_DIR" rev-parse --abbrev-ref --symbolic-full-name '@{upstream}' 2>/dev/null || true)"

    log "refreshing existing checkout in $INSTALL_DIR"
    git -C "$INSTALL_DIR" fetch --quiet origin || true
    git -C "$INSTALL_DIR" checkout "$REPO_REF" >/dev/null 2>&1 || true
    if [ -n "$upstream" ]; then
      git -C "$INSTALL_DIR" pull --ff-only --quiet || true
    elif [ "$branch" = "$REPO_REF" ]; then
      git -C "$INSTALL_DIR" pull --ff-only --quiet origin "$REPO_REF" || true
    fi
    return
  fi

  if [ -e "$INSTALL_DIR" ] && [ ! -d "$INSTALL_DIR/.git" ]; then
    echo "Install dir exists and is not a git checkout: $INSTALL_DIR" >&2
    exit 1
  fi

  mkdir -p "$(dirname "$INSTALL_DIR")"
  log "cloning $REPO_URL into $INSTALL_DIR"
  if git clone --depth 1 --branch "$REPO_REF" "$REPO_URL" "$INSTALL_DIR" >/dev/null 2>&1; then
    return
  fi

  log "shallow clone failed, retrying full checkout"
  rm -rf "$INSTALL_DIR"
  git clone "$REPO_URL" "$INSTALL_DIR" >/dev/null 2>&1
  git -C "$INSTALL_DIR" checkout "$REPO_REF" >/dev/null 2>&1
}

require_cmd git

checkout_repo

cd "$INSTALL_DIR"
chmod +x ./bootstrap.sh

log "running bootstrap from $INSTALL_DIR"
exec ./bootstrap.sh "$@"
