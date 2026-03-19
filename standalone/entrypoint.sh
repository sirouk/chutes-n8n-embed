#!/bin/sh
#
# chutes-n8n-local standalone entrypoint
#
# Supports all deploy.sh modes as runtime switches:
#   INSTALL_MODE    local | domain
#   CHUTES_TRAFFIC_MODE   direct | e2ee-proxy
#   --reconfigure   re-enter interactive prompts
#   --wipe          destroy data and re-initialize
#
# Compose-mode fallback: if DB_TYPE=postgresdb is set, skip standalone
# logic and exec the original n8n entrypoint.
#
set -eu

DATA_DIR="/data"
ENV_FILE="$DATA_DIR/.env"
SENTINEL="$DATA_DIR/.configured"
N8N_HOME="$DATA_DIR/.n8n"
CADDY_DATA="$DATA_DIR/caddy"
LOCAL_HOSTNAME="e2ee-local-proxy.chutes.dev"
RECONFIGURE=false
WIPE=false

# ---------------------------------------------------------------------------
# Compose-mode detection: if DB_TYPE=postgresdb, this container is running
# inside the compose stack managed by deploy.sh.  Skip standalone logic.
# ---------------------------------------------------------------------------
if [ "${DB_TYPE:-}" = "postgresdb" ]; then
    exec tini -- /docker-entrypoint.sh "$@"
fi

# ---------------------------------------------------------------------------
# Parse flags
# ---------------------------------------------------------------------------
for arg in "$@"; do
    case "$arg" in
        --reconfigure) RECONFIGURE=true ;;
        --wipe) WIPE=true ;;
    esac
done

# ---------------------------------------------------------------------------
# Output helpers
# ---------------------------------------------------------------------------
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'

info()  { printf "${CYAN}[*]${NC} %s\n" "$*"; }
ok()    { printf "${GREEN}[+]${NC} %s\n" "$*"; }
warn()  { printf "${YELLOW}[!]${NC} %s\n" "$*"; }
err()   { printf "${RED}[x]${NC} %s\n" "$*" >&2; }

# ---------------------------------------------------------------------------
# Interactive helpers (mirrors deploy.sh)
# ---------------------------------------------------------------------------
INTERACTIVE=false
[ -t 0 ] && [ -t 1 ] && INTERACTIVE=true

read_value() {
    _var_name="$1"
    _prompt="$2"
    _secret="${3:-false}"

    if [ "$INTERACTIVE" != true ]; then
        err "$_var_name must be set in non-interactive mode"
        exit 1
    fi

    printf '%s' "$_prompt"
    if [ "$_secret" = true ]; then
        stty -echo 2>/dev/null || true
        IFS= read -r _val
        stty echo 2>/dev/null || true
        printf '\n'
    else
        IFS= read -r _val
    fi

    eval "$_var_name=\$_val"
}

prompt_required() {
    _var_name="$1"
    _prompt="$2"
    _secret="${3:-false}"

    eval "_current=\${$_var_name:-}"
    [ -n "$_current" ] && return 0

    read_value "$_var_name" "  $_prompt: " "$_secret"

    eval "_current=\${$_var_name:-}"
    if [ -z "$_current" ]; then
        err "$_var_name must not be empty"
        exit 1
    fi
}

# ---------------------------------------------------------------------------
# Secret generation (mirrors deploy.sh)
# ---------------------------------------------------------------------------
generate_hex() {
    openssl rand -hex "$1"
}

generate_owner_password() {
    _lower="$(openssl rand -hex 6 | tr 'A-F' 'a-f')"
    _upper="$(openssl rand -hex 4 | tr 'a-f' 'A-F')"
    _digits="$(openssl rand -hex 4 | tr -dc '0-9' | cut -c1-4)"

    while [ "${#_digits}" -lt 4 ]; do
        _digits="${_digits}$(openssl rand -hex 1 | tr -dc '0-9')"
        _digits="$(echo "$_digits" | cut -c1-4)"
    done

    printf 'Ch%s%s%s' "$_upper" "$_lower" "$_digits"
}

# ---------------------------------------------------------------------------
# Env file helpers
# ---------------------------------------------------------------------------
env_escape() {
    _v="$1"
    _v="$(printf '%s' "$_v" | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g' -e 's/\$/\\$/g' -e 's/`/\\`/g')"
    printf '"%s"' "$_v"
}

env_line() {
    printf '%s=%s\n' "$1" "$(env_escape "$2")"
}

load_env_file() {
    set -a
    # shellcheck source=/dev/null
    . "$1"
    set +a
}

write_env_file() {
    {
        echo "# chutes-n8n-local standalone config — $(date -u +%Y-%m-%dT%H:%M:%SZ)"
        echo
        env_line INSTALL_MODE "$INSTALL_MODE"
        env_line CHUTES_TRAFFIC_MODE "$CHUTES_TRAFFIC_MODE"
        env_line ALLOW_NON_CONFIDENTIAL "$ALLOW_NON_CONFIDENTIAL"
        env_line CHUTES_SSO_PROXY_BYPASS "$CHUTES_SSO_PROXY_BYPASS"
        env_line CHUTES_PROXY_BASE_URL "$CHUTES_PROXY_BASE_URL"
        env_line CHUTES_CREDENTIAL_TEST_BASE_URL "$CHUTES_CREDENTIAL_TEST_BASE_URL"
        echo
        env_line N8N_HOST "$N8N_HOST"
        env_line ACME_EMAIL "${ACME_EMAIL:-}"
        env_line TZ "${TZ:-UTC}"
        echo
        env_line N8N_ENCRYPTION_KEY "$N8N_ENCRYPTION_KEY"
        env_line N8N_JWT_SECRET "$N8N_JWT_SECRET"
        env_line N8N_ADMIN_EMAIL "$N8N_ADMIN_EMAIL"
        env_line N8N_ADMIN_PASSWORD "$N8N_ADMIN_PASSWORD"
        env_line N8N_EXPIRABLE_CREDENTIAL_REFRESH_WINDOW_SECONDS "${N8N_EXPIRABLE_CREDENTIAL_REFRESH_WINDOW_SECONDS:-300}"
        echo
        env_line CHUTES_OAUTH_CLIENT_ID "$CHUTES_OAUTH_CLIENT_ID"
        env_line CHUTES_OAUTH_CLIENT_SECRET "$CHUTES_OAUTH_CLIENT_SECRET"
        env_line CHUTES_IDP_BASE_URL "${CHUTES_IDP_BASE_URL:-https://api.chutes.ai}"
        env_line CHUTES_SSO_LOGIN_LABEL "${CHUTES_SSO_LOGIN_LABEL:-Login with Chutes}"
        env_line CHUTES_SSO_SCOPES "${CHUTES_SSO_SCOPES:-openid profile chutes:read chutes:invoke}"
        env_line CHUTES_ADMIN_USERNAMES "${CHUTES_ADMIN_USERNAMES:-}"
        env_line CHUTES_API_KEY "${CHUTES_API_KEY:-}"
    } > "$ENV_FILE"

    chmod 600 "$ENV_FILE"
}

# ---------------------------------------------------------------------------
# Ensure /data exists and is writable
# ---------------------------------------------------------------------------
mkdir -p "$N8N_HOME" "$CADDY_DATA"

# ---------------------------------------------------------------------------
# Wipe mode
# ---------------------------------------------------------------------------
if [ "$WIPE" = true ]; then
    warn "Wipe mode: destroying existing data"
    rm -rf "${N8N_HOME:?}" "${CADDY_DATA:?}" "$SENTINEL" "$ENV_FILE"
    mkdir -p "$N8N_HOME" "$CADDY_DATA"
fi

# ---------------------------------------------------------------------------
# Configuration: load existing or run interactive setup
# ---------------------------------------------------------------------------
if [ -f "$SENTINEL" ] && [ "$RECONFIGURE" != true ]; then
    info "Loading existing configuration"
    load_env_file "$ENV_FILE"
else
    # Defaults
    INSTALL_MODE="${INSTALL_MODE:-}"
    CHUTES_TRAFFIC_MODE="${CHUTES_TRAFFIC_MODE:-direct}"
    ALLOW_NON_CONFIDENTIAL="${ALLOW_NON_CONFIDENTIAL:-false}"
    CHUTES_SSO_PROXY_BYPASS="${CHUTES_SSO_PROXY_BYPASS:-false}"
    CHUTES_OAUTH_CLIENT_ID="${CHUTES_OAUTH_CLIENT_ID:-}"
    CHUTES_OAUTH_CLIENT_SECRET="${CHUTES_OAUTH_CLIENT_SECRET:-}"
    CHUTES_IDP_BASE_URL="${CHUTES_IDP_BASE_URL:-https://api.chutes.ai}"
    CHUTES_SSO_LOGIN_LABEL="${CHUTES_SSO_LOGIN_LABEL:-Login with Chutes}"
    CHUTES_SSO_SCOPES="${CHUTES_SSO_SCOPES:-openid profile chutes:read chutes:invoke}"
    CHUTES_ADMIN_USERNAMES="${CHUTES_ADMIN_USERNAMES:-}"
    CHUTES_API_KEY="${CHUTES_API_KEY:-}"
    N8N_ADMIN_EMAIL="${N8N_ADMIN_EMAIL:-admin@chutes.local}"
    TZ="${TZ:-UTC}"

    # Load existing env if present (for --reconfigure preserving secrets)
    if [ -f "$ENV_FILE" ]; then
        load_env_file "$ENV_FILE"
    fi

    # --- Install mode ---
    if [ "$INSTALL_MODE" != "local" ] && [ "$INSTALL_MODE" != "domain" ]; then
        if [ "$INTERACTIVE" = true ]; then
            read_value _answer "Install mode [local/domain] (default: local): "
            case "${_answer:-local}" in
                local|LOCAL|l|L) INSTALL_MODE="local" ;;
                domain|DOMAIN|d|D) INSTALL_MODE="domain" ;;
                *) err "Install mode must be 'local' or 'domain'"; exit 1 ;;
            esac
        else
            INSTALL_MODE="${INSTALL_MODE:-local}"
        fi
    fi

    # --- Traffic mode ---
    if [ "$INTERACTIVE" = true ]; then
        echo
        echo "  Chutes model traffic:"
        echo "    direct      - use native Chutes endpoints (recommended)"
        echo "    e2ee-proxy  - route LLM text traffic through local e2ee-proxy"
        read_value _answer "  Choose traffic mode [direct/e2ee-proxy] (default: ${CHUTES_TRAFFIC_MODE}): "
        case "${_answer:-$CHUTES_TRAFFIC_MODE}" in
            direct|DIRECT|d|D) CHUTES_TRAFFIC_MODE="direct" ;;
            e2ee-proxy|proxy|p|P) CHUTES_TRAFFIC_MODE="e2ee-proxy" ;;
            *) err "Traffic mode must be 'direct' or 'e2ee-proxy'"; exit 1 ;;
        esac
    fi

    # --- TEE-only (e2ee-proxy only) ---
    if [ "$CHUTES_TRAFFIC_MODE" = "e2ee-proxy" ] && [ "$INTERACTIVE" = true ]; then
        echo
        echo "  e2ee-proxy confidentiality mode:"
        echo "    yes - keep proxy strictly TEE-only for text models"
        echo "    no  - allow non-TEE text models through proxy"
        read_value _answer "  Keep e2ee-proxy strictly TEE-only? [Y/n]: "
        case "${_answer:-yes}" in
            y|Y|yes|YES) ALLOW_NON_CONFIDENTIAL="false" ;;
            n|N|no|NO) ALLOW_NON_CONFIDENTIAL="true" ;;
            *) err "Please answer yes or no"; exit 1 ;;
        esac
    fi

    # --- SSO proxy bypass (e2ee-proxy only) ---
    if [ "$CHUTES_TRAFFIC_MODE" != "e2ee-proxy" ]; then
        CHUTES_SSO_PROXY_BYPASS="false"
    else
        CHUTES_SSO_PROXY_BYPASS="${CHUTES_SSO_PROXY_BYPASS:-true}"
    fi

    # --- Domain-specific settings ---
    if [ "$INSTALL_MODE" = "local" ]; then
        N8N_HOST="$LOCAL_HOSTNAME"
        ACME_EMAIL=""
    else
        if [ "$INTERACTIVE" = true ]; then
            prompt_required N8N_HOST "Public n8n hostname"
            prompt_required ACME_EMAIL "Let's Encrypt email"
        fi
        if [ -z "${N8N_HOST:-}" ]; then
            err "N8N_HOST is required for domain installs"
            exit 1
        fi
        if [ -z "${ACME_EMAIL:-}" ]; then
            err "ACME_EMAIL is required for domain installs"
            exit 1
        fi
    fi

    # --- Proxy URLs ---
    if [ "$CHUTES_TRAFFIC_MODE" = "e2ee-proxy" ]; then
        CHUTES_PROXY_BASE_URL="https://${N8N_HOST}"
        CHUTES_CREDENTIAL_TEST_BASE_URL="https://${N8N_HOST}"
    else
        CHUTES_PROXY_BASE_URL=""
        CHUTES_CREDENTIAL_TEST_BASE_URL=""
    fi

    # --- OAuth credentials ---
    echo
    echo "  Configure your Chutes OAuth client with this redirect URI:"
    echo "    https://${N8N_HOST}/rest/sso/chutes/callback"
    prompt_required CHUTES_OAUTH_CLIENT_ID "Chutes OAuth Client ID"
    prompt_required CHUTES_OAUTH_CLIENT_SECRET "Chutes OAuth Client Secret" true

    # --- Generate secrets (only if not already set) ---
    N8N_ENCRYPTION_KEY="${N8N_ENCRYPTION_KEY:-$(generate_hex 32)}"
    N8N_JWT_SECRET="${N8N_JWT_SECRET:-$(generate_hex 32)}"
    N8N_ADMIN_PASSWORD="${N8N_ADMIN_PASSWORD:-$(generate_owner_password)}"

    # --- Persist ---
    info "Writing configuration"
    write_env_file
    touch "$SENTINEL"
    ok "Configuration saved"
fi

# ---------------------------------------------------------------------------
# Derive runtime settings
# ---------------------------------------------------------------------------

# Database: external postgres if host is set, else sqlite
if [ -n "${DB_POSTGRESDB_HOST:-}" ]; then
    export DB_TYPE="postgresdb"
    export DB_POSTGRESDB_DATABASE="${DB_POSTGRESDB_DATABASE:-n8n}"
    export DB_POSTGRESDB_USER="${DB_POSTGRESDB_USER:-n8n}"
    export DB_POSTGRESDB_PORT="${DB_POSTGRESDB_PORT:-5432}"
else
    export DB_TYPE="sqlite"
fi

# n8n env vars
export N8N_USER_FOLDER="$N8N_HOME"
export N8N_ENCRYPTION_KEY
export N8N_USER_MANAGEMENT_JWT_SECRET="$N8N_JWT_SECRET"
export N8N_HOST
export N8N_PORT=5678
export N8N_PROTOCOL=https
export N8N_EDITOR_BASE_URL="https://${N8N_HOST}"
export N8N_PROXY_HOPS=1
export N8N_SECURE_COOKIE=true
export WEBHOOK_URL="https://${N8N_HOST}/"
export N8N_CUSTOM_EXTENSIONS=/opt/custom-nodes
export N8N_DIAGNOSTICS_ENABLED=false
export N8N_VERSION_NOTIFICATIONS_ENABLED=false
export N8N_RUNNERS_ENABLED=true
export N8N_ENFORCE_SETTINGS_FILE_PERMISSIONS=true
export N8N_EXPIRABLE_CREDENTIAL_REFRESH_WINDOW_SECONDS="${N8N_EXPIRABLE_CREDENTIAL_REFRESH_WINDOW_SECONDS:-300}"
export NODE_ENV=production

# Chutes env vars
export CHUTES_OAUTH_CLIENT_ID
export CHUTES_OAUTH_CLIENT_SECRET
export CHUTES_IDP_BASE_URL
export CHUTES_SSO_LOGIN_LABEL
export CHUTES_SSO_SCOPES
export CHUTES_ADMIN_USERNAMES
export CHUTES_TRAFFIC_MODE
export CHUTES_PROXY_BASE_URL
export CHUTES_CREDENTIAL_TEST_BASE_URL
export CHUTES_SSO_PROXY_BYPASS
export ALLOW_NON_CONFIDENTIAL
export CHUTES_API_KEY

# Standalone mode markers (read by s6 service scripts and configure)
export STANDALONE_INSTALL_MODE="$INSTALL_MODE"
export STANDALONE_TRAFFIC_MODE="$CHUTES_TRAFFIC_MODE"
export STANDALONE_N8N_HOST="$N8N_HOST"
export STANDALONE_ACME_EMAIL="${ACME_EMAIL:-}"
export STANDALONE_ADMIN_EMAIL="$N8N_ADMIN_EMAIL"
export STANDALONE_DATA_DIR="$DATA_DIR"

# Written to a file readable only by the configure oneshot, not the global env
printf '%s' "$N8N_ADMIN_PASSWORD" > /tmp/.owner-password
chmod 600 /tmp/.owner-password

# ---------------------------------------------------------------------------
# Render edge proxy configs
# ---------------------------------------------------------------------------
info "Rendering edge proxy configuration"

if [ "$INSTALL_MODE" = "local" ]; then
    sed \
        -e "s|__SERVER_NAME__|${N8N_HOST}|g" \
        -e "s|__RESOLVERS__|8.8.8.8 8.8.4.4|g" \
        /opt/standalone/nginx-standalone.conf.template \
        > /tmp/nginx-standalone.conf
    ok "nginx config rendered (local mode)"
fi

if [ "$INSTALL_MODE" = "domain" ]; then
    sed \
        -e "s|__SERVER_NAME__|${N8N_HOST}|g" \
        -e "s|__TLS_DIRECTIVE__|tls ${ACME_EMAIL}|g" \
        /opt/standalone/Caddyfile.template \
        > /tmp/Caddyfile
    ok "Caddyfile rendered (domain mode)"

    if [ "$CHUTES_TRAFFIC_MODE" = "e2ee-proxy" ]; then
        sed \
            -e "s|__SERVER_NAME__|${N8N_HOST}|g" \
            -e "s|__RESOLVERS__|8.8.8.8 8.8.4.4|g" \
            /opt/standalone/nginx-e2ee-internal.conf.template \
            > /tmp/nginx-e2ee-internal.conf
        ok "openresty e2ee config rendered (domain + e2ee-proxy)"
    fi
fi

# ---------------------------------------------------------------------------
# Hand off to s6-overlay
# ---------------------------------------------------------------------------
echo
info "Starting services (${INSTALL_MODE} + ${CHUTES_TRAFFIC_MODE})"
exec /init "$@"
