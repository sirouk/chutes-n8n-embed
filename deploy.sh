#!/usr/bin/env bash
#
# chutes-n8n-local deploy
#
# Deployment entry point:
# - clones or refreshes the repo when launched outside an existing checkout
# - prompts for local vs domain deployment
# - captures the Chutes OAuth client credentials required for native SSO
# - renders the correct edge config (Caddy for public domains, e2ee-proxy for local)
# - builds the pinned n8n image with Chutes SSO overlay
# - boots postgres + n8n + the selected edge
# - provisions the break-glass owner account
#
# Usage:
#   ./deploy.sh
#   ./deploy.sh --force
#   ./deploy.sh --wipe
#   ./deploy.sh --reset-owner-password
#   ./deploy.sh --force-all
#   ./deploy.sh --down
#
set -euo pipefail

REPO_REF="${CHUTES_N8N_LOCAL_GIT_REF:-${CHUTES_N8N_EMBED_GIT_REF:-main}}"
REPO_URL="${CHUTES_N8N_LOCAL_GIT_URL:-${CHUTES_N8N_EMBED_GIT_URL:-https://github.com/chutesai/chutes-n8n-local.git}}"
INSTALL_DIR="${CHUTES_N8N_LOCAL_DIR:-${CHUTES_N8N_EMBED_DIR:-$HOME/chutes-n8n-local}}"
SCRIPT_SOURCE="${BASH_SOURCE[0]:-$0}"
RUNNING_FROM_STDIN=false

case "$SCRIPT_SOURCE" in
    /dev/fd/*|/proc/self/fd/*|-|bash|-bash)
        RUNNING_FROM_STDIN=true
        ;;
esac

if SCRIPT_DIR="$(cd "$(dirname "$SCRIPT_SOURCE")" >/dev/null 2>&1 && pwd)"; then
    :
else
    SCRIPT_DIR="$(pwd)"
fi

log() {
    printf '[deploy] %s\n' "$1"
}

in_repo_checkout() {
    [ "$RUNNING_FROM_STDIN" != true ] || return 1
    [ -f "$SCRIPT_DIR/docker-compose.yml" ] &&
    [ -f "$SCRIPT_DIR/Dockerfile.n8n" ] &&
    [ -d "$SCRIPT_DIR/scripts" ]
}

require_clone_cmd() {
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

if ! in_repo_checkout; then
    require_clone_cmd git
    checkout_repo
    cd "$INSTALL_DIR"
    chmod +x ./deploy.sh
    log "running deploy from $INSTALL_DIR"
    if [ "$RUNNING_FROM_STDIN" = true ] && [ ! -t 0 ]; then
        cat >/dev/null || true
    fi
    exec ./deploy.sh "$@"
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="$SCRIPT_DIR/.env"
LOCAL_HOSTNAME="e2ee-local-proxy.chutes.dev"
PROJECT_N8N_VERSION="2.12.1"
PROJECT_N8N_SOURCE_REPO="https://github.com/n8n-io/n8n.git"
PROJECT_NODES_REPO="https://github.com/chutesai/n8n-nodes-chutes.git"
PROJECT_NODES_REF="main"
FORCE_ALL=false
RESET_OWNER_PASSWORD=false
DOWN=false
INTERACTIVE=false
TTY_DEVICE=""
INSTALL_ACTION="${INSTALL_ACTION:-}"
EXISTING_INSTALL=false

if [ -t 1 ] && [ -r /dev/tty ] && [ -w /dev/tty ]; then
    TTY_DEVICE="/dev/tty"
    INTERACTIVE=true
elif [ -t 0 ] && [ -t 1 ]; then
    INTERACTIVE=true
fi

for arg in "$@"; do
    case "$arg" in
        --force) INSTALL_ACTION="update" ;;
        --wipe) FORCE_ALL=true; INSTALL_ACTION="wipe" ;;
        --force-all) FORCE_ALL=true ;;
        --reset-owner-password) RESET_OWNER_PASSWORD=true ;;
        --down) DOWN=true ;;
        *)
            echo "Unknown argument: $arg" >&2
            exit 1
            ;;
    esac
done

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'

info()  { echo -e "${CYAN}[*]${NC} $*"; }
ok()    { echo -e "${GREEN}[+]${NC} $*"; }
warn()  { echo -e "${YELLOW}[!]${NC} $*"; }
err()   { echo -e "${RED}[x]${NC} $*" >&2; }

read_interactive_value() {
    local var_name="$1"
    local prompt="$2"
    local secret="${3:-false}"
    local value=""

    if [ "$INTERACTIVE" != true ]; then
        err "$var_name must be set in non-interactive mode"
        exit 1
    fi

    if [ -n "$TTY_DEVICE" ]; then
        printf '%s' "$prompt" > "$TTY_DEVICE"
        if [ "$secret" = true ]; then
            IFS= read -r -s value < "$TTY_DEVICE"
            printf '\n' > "$TTY_DEVICE"
        else
            IFS= read -r value < "$TTY_DEVICE"
        fi
    else
        if [ "$secret" = true ]; then
            read -rsp "$prompt" value
            echo
        else
            read -rp "$prompt" value
        fi
    fi

    printf -v "$var_name" '%s' "$value"
}

compose_files_default() {
    local install_mode="$1"
    local traffic_mode="${2:-${CHUTES_TRAFFIC_MODE:-direct}}"
    local files="docker-compose.yml"

    case "$install_mode" in
        local) files="${files}:docker-compose.local.yml" ;;
        domain) files="${files}:docker-compose.domain.yml" ;;
        *)
            err "Unsupported install mode: $install_mode"
            exit 1
            ;;
    esac

    case "$traffic_mode" in
        direct|"")
            ;;
        e2ee-proxy)
            if [ "$install_mode" = "domain" ]; then
                files="${files}:docker-compose.traffic-proxy.yml"
            fi
            ;;
        *)
            err "Unsupported Chutes traffic mode: $traffic_mode"
            exit 1
            ;;
    esac

    printf '%s' "$files"
}

compose_args() {
    local files="${CHUTES_COMPOSE_FILES:-$(compose_files_default "${INSTALL_MODE:-local}")}"
    local file
    local old_ifs="$IFS"
    local -a args=()

    IFS=':' read -r -a compose_files <<< "$files"
    IFS="$old_ifs"

    for file in "${compose_files[@]}"; do
        if [[ "$file" != /* ]]; then
            file="$SCRIPT_DIR/$file"
        fi
        args+=(-f "$file")
    done

    printf '%s\0' "${args[@]}"
}

compose() {
    local -a args=()
    while IFS= read -r -d '' arg; do
        args+=("$arg")
    done < <(compose_args)
    docker compose "${args[@]}" "$@"
}

compose_command_hint() {
    local files="${CHUTES_COMPOSE_FILES:-$(compose_files_default "${INSTALL_MODE:-local}")}"
    local file
    local out="docker compose"
    local old_ifs="$IFS"

    IFS=':' read -r -a compose_files <<< "$files"
    IFS="$old_ifs"

    for file in "${compose_files[@]}"; do
        if [[ "$file" != /* ]]; then
            file="$SCRIPT_DIR/$file"
        fi
        out="${out} -f ${file}"
    done

    printf '%s' "$out"
}

require_cmd() {
    local cmd="$1"
    command -v "$cmd" >/dev/null 2>&1 || {
        err "$cmd is required"
        exit 1
    }
}

remember_env_override() {
    local var_name="$1"
    local is_set_var="BOOTSTRAP_OVERRIDE_SET_${var_name}"
    local value_var="BOOTSTRAP_OVERRIDE_VALUE_${var_name}"

    if [ "${!var_name+x}" = x ]; then
        printf -v "$is_set_var" '%s' "true"
        printf -v "$value_var" '%s' "${!var_name}"
    else
        printf -v "$is_set_var" '%s' "false"
    fi
}

restore_env_override() {
    local var_name="$1"
    local is_set_var="BOOTSTRAP_OVERRIDE_SET_${var_name}"
    local value_var="BOOTSTRAP_OVERRIDE_VALUE_${var_name}"

    if [ "${!is_set_var:-false}" = "true" ]; then
        printf -v "$var_name" '%s' "${!value_var}"
        export "${var_name?}"
    fi
}

load_env_file() {
    set -a
    # shellcheck source=/dev/null
    source "$1"
    set +a
}

generate_hex() {
    local bytes="$1"
    openssl rand -hex "$bytes"
}

generate_owner_password() {
    local lower upper digits
    lower="$(openssl rand -hex 6 | tr 'A-F' 'a-f')"
    upper="$(openssl rand -hex 4 | tr 'a-f' 'A-F')"
    digits="$(openssl rand -hex 4 | tr -dc '0-9' | cut -c1-4)"

    while [ "${#digits}" -lt 4 ]; do
        digits="${digits}$(openssl rand -hex 1 | tr -dc '0-9')"
        digits="${digits:0:4}"
    done

    printf 'Ch%s%s%s' "$upper" "$lower" "$digits"
}

env_escape() {
    local value="$1"
    value="${value//$'\\'/\\\\}"
    value="${value//\"/\\\"}"
    value="${value//\$/\\$}"
    value="${value//\`/\\\`}"
    printf '"%s"' "$value"
}

env_line() {
    printf '%s=%s\n' "$1" "$(env_escape "$2")"
}

project_name() {
    printf '%s' "${COMPOSE_PROJECT_NAME:-$(basename "$SCRIPT_DIR")}"
}

existing_install_detected() {
    local compose_project
    compose_project="$(project_name)"

    if [ -f "$ENV_FILE" ]; then
        return 0
    fi

    if [ -n "$(compose ps -q n8n 2>/dev/null | head -n 1)" ]; then
        return 0
    fi

    if docker volume inspect "${compose_project}_n8n_data" >/dev/null 2>&1; then
        return 0
    fi

    if docker volume inspect "${compose_project}_postgres_data" >/dev/null 2>&1; then
        return 0
    fi

    return 1
}

write_env_file() {
    {
        echo "# Auto-generated by deploy.sh — $(date -u +%Y-%m-%dT%H:%M:%SZ)"
        echo
        env_line INSTALL_MODE "$INSTALL_MODE"
        env_line CHUTES_TRAFFIC_MODE "$CHUTES_TRAFFIC_MODE"
        env_line CHUTES_COMPOSE_FILES "$CHUTES_COMPOSE_FILES"
        env_line EDGE_SERVICE "$EDGE_SERVICE"
        env_line E2EE_PROXY_IMAGE "$E2EE_PROXY_IMAGE"
        env_line ALLOW_NON_CONFIDENTIAL "$ALLOW_NON_CONFIDENTIAL"
        env_line CHUTES_SSO_PROXY_BYPASS "$CHUTES_SSO_PROXY_BYPASS"
        env_line CHUTES_PROXY_BASE_URL "$CHUTES_PROXY_BASE_URL"
        env_line CHUTES_CREDENTIAL_TEST_BASE_URL "$CHUTES_CREDENTIAL_TEST_BASE_URL"
        echo
        env_line N8N_VERSION "$N8N_VERSION"
        env_line N8N_SOURCE_REPO "$N8N_SOURCE_REPO"
        env_line N8N_SOURCE_REF "$N8N_SOURCE_REF"
        env_line TZ "$TZ"
        echo
        env_line N8N_HOST "$N8N_HOST"
        env_line ACME_EMAIL "$ACME_EMAIL"
        echo
        env_line POSTGRES_USER "$POSTGRES_USER"
        env_line POSTGRES_PASSWORD "$POSTGRES_PASSWORD"
        env_line POSTGRES_DB "$POSTGRES_DB"
        echo
        env_line N8N_ENCRYPTION_KEY "$N8N_ENCRYPTION_KEY"
        env_line N8N_JWT_SECRET "$N8N_JWT_SECRET"
        env_line N8N_ADMIN_EMAIL "$N8N_ADMIN_EMAIL"
        env_line N8N_ADMIN_PASSWORD "$N8N_ADMIN_PASSWORD"
        env_line N8N_EXPIRABLE_CREDENTIAL_REFRESH_WINDOW_SECONDS "$N8N_EXPIRABLE_CREDENTIAL_REFRESH_WINDOW_SECONDS"
        echo
        env_line CHUTES_OAUTH_CLIENT_ID "$CHUTES_OAUTH_CLIENT_ID"
        env_line CHUTES_OAUTH_CLIENT_SECRET "$CHUTES_OAUTH_CLIENT_SECRET"
        env_line CHUTES_IDP_BASE_URL "$CHUTES_IDP_BASE_URL"
        env_line CHUTES_SSO_LOGIN_LABEL "$CHUTES_SSO_LOGIN_LABEL"
        env_line CHUTES_SSO_SCOPES "$CHUTES_SSO_SCOPES"
        env_line CHUTES_ADMIN_USERNAMES "$CHUTES_ADMIN_USERNAMES"
        echo
        env_line CHUTES_API_KEY "$CHUTES_API_KEY"
    } > "$ENV_FILE"

    chmod 600 "$ENV_FILE"
}

render_caddyfile() {
    sed \
        -e "s|__SERVER_NAME__|${N8N_HOST}|g" \
        -e "s|__TLS_DIRECTIVE__|tls ${ACME_EMAIL}|g" \
        "$SCRIPT_DIR/conf/Caddyfile.template" > "$SCRIPT_DIR/conf/Caddyfile"
}

render_local_proxy_config() {
    cp "$SCRIPT_DIR/conf/local-proxy.nginx.template" \
       "$SCRIPT_DIR/conf/local-proxy.nginx.conf"
}

container_runtime_status() {
    if [ -z "${1:-}" ]; then
        echo missing
        return
    fi

    docker inspect "$1" --format='{{if .State.Health}}{{.State.Health.Status}}{{else}}{{.State.Status}}{{end}}' 2>/dev/null || echo missing
}

compose_container_id() {
    compose ps -q "$1" 2>/dev/null | head -n 1
}

wait_for_service_ready() {
    local service="$1"
    local attempts="$2"
    local status="missing"
    local container=""

    while [ "$attempts" -gt 0 ]; do
        container="$(compose_container_id "$service")"
        status="$(container_runtime_status "$container")"
        if [ "$status" = "healthy" ] || [ "$status" = "running" ]; then
            printf '%s' "$status"
            return 0
        fi
        attempts=$((attempts - 1))
        sleep 2
    done

    printf '%s' "$status"
    return 1
}

remove_stale_edge_container() {
    local container
    local -a stale_containers=("n8n-nginx" "n8n-oauth2-proxy")

    case "$EDGE_SERVICE" in
        caddy) stale_containers+=("n8n-local-proxy") ;;
        local-proxy) stale_containers+=("n8n-caddy") ;;
    esac

    for container in "${stale_containers[@]}"; do
        if docker inspect "$container" >/dev/null 2>&1; then
            info "Removing stale ${container} ..."
            docker rm -f "$container" >/dev/null 2>&1 || true
        fi
    done
}

remove_stale_project_containers() {
    local compose_project
    local container_ids

    compose_project="$(project_name)"
    container_ids="$(docker ps -aq --filter "name=^/${compose_project}-")"

    if [ -z "$container_ids" ]; then
        return
    fi

    info "Removing stale ${compose_project} containers left behind by earlier runs ..."
    # shellcheck disable=SC2086
    docker rm -f $container_ids >/dev/null 2>&1 || true
}

check_owner_login() {
    local login_result
    login_result=$(compose exec -T n8n \
        wget -q -O- \
        --header='Content-Type: application/json' \
        --header='browser-id: bootstrap-check' \
        --post-data="$(printf '{"emailOrLdapLoginId":"%s","password":"%s"}' "$N8N_ADMIN_EMAIL" "$N8N_ADMIN_PASSWORD")" \
        http://127.0.0.1:5678/rest/login 2>/dev/null || true)
    [[ "$login_result" == *'"id"'* ]]
}

is_placeholder_client_id() {
    case "$1" in
        ""|test-chutes-client|dummy-client|example-client-id|changeme)
            return 0
            ;;
        *)
            return 1
            ;;
    esac
}

is_placeholder_client_secret() {
    case "$1" in
        ""|test-secret|dummy-secret|changeme)
            return 0
            ;;
        *"test secret"*|*"example.invalid"*|*"changeme"*)
            return 0
            ;;
        *)
            return 1
            ;;
    esac
}

is_placeholder_email() {
    case "$1" in
        ""|ops@example.com|admin@example.com|e2e@example.invalid|example@example.com)
            return 0
            ;;
        *@example.com|*@example.invalid)
            return 0
            ;;
        *)
            return 1
            ;;
    esac
}

is_test_idp_base_url() {
    case "$1" in
        "" )
            return 1
            ;;
        http://test-chutes-idp:8080|https://test-chutes-idp:8080)
            return 0
            ;;
        http://localhost:*|https://localhost:*|http://127.0.0.1:*|https://127.0.0.1:*)
            return 0
            ;;
        *test-chutes-idp*|*.invalid*)
            return 0
            ;;
        *)
            return 1
            ;;
    esac
}

validate_domain_hostname() {
    local host="$1"

    if [ -z "$host" ]; then
        err "N8N_HOST is required for domain installs"
        exit 1
    fi

    if [ "$host" = "localhost" ] || [[ "$host" =~ ^[0-9.]+$ ]]; then
        err "Domain installs require a real FQDN, not '$host'"
        exit 1
    fi

    if [[ "$host" != *.* ]]; then
        err "N8N_HOST must be a fully-qualified domain name"
        exit 1
    fi
}

adopt_project_n8n_pin() {
    local desired_version="$PROJECT_N8N_VERSION"
    local desired_repo="$PROJECT_N8N_SOURCE_REPO"
    local desired_ref="n8n@${desired_version}"

    if [ "${BOOTSTRAP_OVERRIDE_SET_N8N_VERSION:-false}" != "true" ]; then
        if [ -n "${N8N_VERSION:-}" ] && [ "$N8N_VERSION" != "$desired_version" ]; then
            info "Project n8n pin advanced from ${N8N_VERSION} to ${desired_version}; updating the local install to match"
        fi
        N8N_VERSION="$desired_version"
    fi

    if [ "${BOOTSTRAP_OVERRIDE_SET_N8N_SOURCE_REPO:-false}" != "true" ]; then
        N8N_SOURCE_REPO="$desired_repo"
    fi

    if [ "${BOOTSTRAP_OVERRIDE_SET_N8N_SOURCE_REF:-false}" != "true" ]; then
        if [ "$N8N_SOURCE_REPO" = "$desired_repo" ]; then
            N8N_SOURCE_REF="$desired_ref"
        else
            N8N_SOURCE_REF="${N8N_SOURCE_REF:-n8n@${N8N_VERSION}}"
        fi
    fi
}

prompt_install_action() {
    local answer

    if [ "$EXISTING_INSTALL" != true ]; then
        INSTALL_ACTION="update"
        return
    fi

    if [ "$FORCE_ALL" = true ]; then
        INSTALL_ACTION="wipe"
        return
    fi

    if [ "$INSTALL_ACTION" = "update" ] || [ "$INSTALL_ACTION" = "wipe" ]; then
        return
    fi

    if [ "$INTERACTIVE" != true ]; then
        INSTALL_ACTION="update"
        info "Existing install detected; defaulting to update mode in non-interactive execution"
        return
    fi

    read_interactive_value answer "Existing install found. Action [update/wipe] (default: update): "

    case "${answer:-update}" in
        update|UPDATE|Update|u|U) INSTALL_ACTION="update" ;;
        wipe|WIPE|Wipe|w|W) INSTALL_ACTION="wipe" ;;
        *)
            err "Install action must be 'update' or 'wipe'"
            exit 1
            ;;
    esac
}

refresh_local_dependency_checkout() {
    local repo_dir="$1"
    local repo_name branch upstream current_head upstream_head dirty_state

    repo_name="$(basename "$repo_dir")"

    if [ ! -d "$repo_dir/.git" ]; then
        info "Using local ${repo_name} directory (not a git checkout)"
        return
    fi

    if ! command -v git >/dev/null 2>&1; then
        warn "git is not installed; using current ${repo_name} checkout without refreshing"
        return
    fi

    dirty_state="$(git -C "$repo_dir" status --porcelain --untracked-files=no 2>/dev/null || true)"
    if [ -n "$dirty_state" ]; then
        warn "${repo_name} has local tracked changes; using the current checkout without pulling"
        return
    fi

    upstream="$(git -C "$repo_dir" rev-parse --abbrev-ref --symbolic-full-name '@{upstream}' 2>/dev/null || true)"
    branch="$(git -C "$repo_dir" rev-parse --abbrev-ref HEAD 2>/dev/null || echo HEAD)"
    if [ -z "$upstream" ]; then
        info "${repo_name} branch ${branch} has no upstream; using the current checkout"
        return
    fi

    info "Refreshing ${repo_name} from ${upstream} ..."
    if ! git -C "$repo_dir" fetch --quiet; then
        warn "Failed to fetch updates for ${repo_name}; using the current checkout"
        return
    fi

    current_head="$(git -C "$repo_dir" rev-parse HEAD 2>/dev/null || true)"
    upstream_head="$(git -C "$repo_dir" rev-parse "$upstream" 2>/dev/null || true)"

    if [ -z "$current_head" ] || [ -z "$upstream_head" ]; then
        warn "Unable to determine ${repo_name} revision state; using the current checkout"
        return
    fi

    if [ "$current_head" = "$upstream_head" ]; then
        ok "${repo_name} is already up to date"
        return
    fi

    if git -C "$repo_dir" merge-base --is-ancestor "$current_head" "$upstream_head"; then
        if git -C "$repo_dir" pull --ff-only --quiet; then
            ok "${repo_name} fast-forwarded to the latest ${branch}"
        else
            warn "Fast-forward update failed for ${repo_name}; using the current checkout"
        fi
        return
    fi

    warn "${repo_name} has diverged from ${upstream}; using the current checkout without pulling"
}

ensure_dependency_checkout() {
    local repo_dir="$1"
    local repo_url="$2"
    local repo_ref="$3"
    local repo_name
    local tmp_dir

    repo_name="$(basename "$repo_dir")"

    if [ -d "$repo_dir" ]; then
        return
    fi

    require_cmd git

    mkdir -p "$(dirname "$repo_dir")"
    tmp_dir="${repo_dir}.tmp.$$"
    rm -rf "$tmp_dir"

    info "${repo_name} not found; cloning ${repo_url} (${repo_ref}) ..."

    if git clone --depth 1 --branch "$repo_ref" "$repo_url" "$tmp_dir" >/dev/null 2>&1; then
        mv "$tmp_dir" "$repo_dir"
        ok "${repo_name} cloned"
        return
    fi

    warn "Shallow clone for ${repo_name} failed; retrying with a full checkout"
    rm -rf "$tmp_dir"

    if git clone "$repo_url" "$tmp_dir" >/dev/null 2>&1 && git -C "$tmp_dir" checkout "$repo_ref" >/dev/null 2>&1; then
        mv "$tmp_dir" "$repo_dir"
        ok "${repo_name} cloned"
        return
    fi

    rm -rf "$tmp_dir"
    err "Failed to clone ${repo_name} from ${repo_url}"
    exit 1
}

prompt_install_mode() {
    local answer

    if [ "${INSTALL_MODE:-}" = "local" ] || [ "${INSTALL_MODE:-}" = "domain" ]; then
        return
    fi

    if [ "$INTERACTIVE" != true ]; then
        err "INSTALL_MODE must be set to 'local' or 'domain' in non-interactive mode"
        exit 1
    fi

    read_interactive_value answer "Install mode [local/domain] (default: local): "

    case "${answer:-local}" in
        local|LOCAL|Local|l|L) INSTALL_MODE="local" ;;
        domain|DOMAIN|Domain|d|D) INSTALL_MODE="domain" ;;
        *)
            err "Install mode must be 'local' or 'domain'"
            exit 1
            ;;
    esac
}

prompt_traffic_mode() {
    local answer
    local default_mode="direct"

    if [ "${BOOTSTRAP_OVERRIDE_SET_CHUTES_TRAFFIC_MODE:-false}" = "true" ]; then
        default_mode="$CHUTES_TRAFFIC_MODE"
    elif [ "$EXISTING_INSTALL" = true ] && [ "${INSTALL_ACTION:-update}" = "update" ]; then
        default_mode="${CHUTES_TRAFFIC_MODE:-direct}"
    fi

    case "$default_mode" in
        direct|e2ee-proxy)
            ;;
        *)
            default_mode="direct"
            ;;
    esac

    if [ "$INTERACTIVE" != true ]; then
        CHUTES_TRAFFIC_MODE="$default_mode"
        return
    fi

    echo
    echo "  Chutes model traffic:"
    echo "    direct      - use native Chutes endpoints (recommended, keeps Chutes routing/failover behavior)"
    echo "    e2ee-proxy  - route OpenAI-compatible LLM text traffic through the local e2ee-proxy path"
    if [ "$INSTALL_MODE" = "local" ]; then
        echo "  Note: local installs still use the embedded e2ee-proxy certificate path for serving n8n itself."
    fi
    read_interactive_value answer "  Choose traffic mode [direct/e2ee-proxy] (default: ${default_mode}): "

    case "${answer:-$default_mode}" in
        direct|DIRECT|Direct|d|D) CHUTES_TRAFFIC_MODE="direct" ;;
        e2ee-proxy|E2EE-PROXY|E2ee-proxy|proxy|PROXY|Proxy|p|P) CHUTES_TRAFFIC_MODE="e2ee-proxy" ;;
        *)
            err "Chutes traffic mode must be 'direct' or 'e2ee-proxy'"
            exit 1
            ;;
    esac
}

prompt_e2ee_proxy_confidential_mode() {
    local answer
    local default_answer="yes"

    if [ "$CHUTES_TRAFFIC_MODE" != "e2ee-proxy" ]; then
        return
    fi

    if [ "${BOOTSTRAP_OVERRIDE_SET_ALLOW_NON_CONFIDENTIAL:-false}" = "true" ]; then
        if [ "${ALLOW_NON_CONFIDENTIAL:-false}" = "true" ]; then
            default_answer="no"
        fi
    elif [ "$EXISTING_INSTALL" = true ] && [ "${INSTALL_ACTION:-update}" = "update" ]; then
        if [ "${ALLOW_NON_CONFIDENTIAL:-false}" = "true" ]; then
            default_answer="no"
        fi
    fi

    if [ "$INTERACTIVE" != true ]; then
        if [ "$default_answer" = "yes" ]; then
            ALLOW_NON_CONFIDENTIAL="false"
        else
            ALLOW_NON_CONFIDENTIAL="true"
        fi
        return
    fi

    echo
    echo "  e2ee-proxy confidentiality mode:"
    echo "    yes - keep the proxy path strict TEE-only for text models"
    echo "    no  - allow non-TEE text models through the proxy path too"
    if [ "$default_answer" = "yes" ]; then
        read_interactive_value answer "  Keep e2ee-proxy strictly TEE-only? [Y/n]: "
    else
        read_interactive_value answer "  Keep e2ee-proxy strictly TEE-only? [y/N]: "
    fi

    case "${answer:-$default_answer}" in
        y|Y|yes|YES|Yes)
            ALLOW_NON_CONFIDENTIAL="false"
            ;;
        n|N|no|NO|No)
            ALLOW_NON_CONFIDENTIAL="true"
            ;;
        *)
            err "Please answer yes or no"
            exit 1
            ;;
    esac
}

normalize_sso_proxy_bypass() {
    local default_bypass="true"

    if [ "$CHUTES_TRAFFIC_MODE" != "e2ee-proxy" ]; then
        CHUTES_SSO_PROXY_BYPASS="false"
        return
    fi

    if [ "${BOOTSTRAP_OVERRIDE_SET_CHUTES_SSO_PROXY_BYPASS:-false}" = "true" ]; then
        case "${CHUTES_SSO_PROXY_BYPASS:-true}" in
            true|false)
                ;;
            *)
                err "CHUTES_SSO_PROXY_BYPASS must be 'true' or 'false'"
                exit 1
                ;;
        esac
        return
    fi

    if [ "$EXISTING_INSTALL" = true ] && [ "${INSTALL_ACTION:-update}" = "update" ]; then
        case "${CHUTES_SSO_PROXY_BYPASS:-true}" in
            true|false)
                ;;
            *)
                CHUTES_SSO_PROXY_BYPASS="$default_bypass"
                ;;
        esac
        return
    fi

    CHUTES_SSO_PROXY_BYPASS="$default_bypass"
}

prompt_required_value() {
    local var_name="$1"
    local prompt="$2"
    local secret="${3:-false}"
    local current="${!var_name:-}"

    if [ -n "$current" ]; then
        return
    fi

    read_interactive_value current "  ${prompt}: " "$secret"

    if [ -z "$current" ]; then
        err "$var_name must not be empty"
        exit 1
    fi

    printf -v "$var_name" '%s' "$current"
}

ensure_real_chutes_oauth_credentials() {
    if [ "${BOOTSTRAP_OVERRIDE_SET_CHUTES_IDP_BASE_URL:-false}" != "true" ] && \
        is_test_idp_base_url "${CHUTES_IDP_BASE_URL:-}"; then
        warn "Ignoring test-only CHUTES_IDP_BASE_URL=${CHUTES_IDP_BASE_URL} for a real deploy run"
        CHUTES_IDP_BASE_URL="https://api.chutes.ai"
        CHUTES_OAUTH_CLIENT_ID=""
        CHUTES_OAUTH_CLIENT_SECRET=""
    fi

    if [ "${CHUTES_IDP_BASE_URL:-https://api.chutes.ai}" = "https://api.chutes.ai" ]; then
        if is_placeholder_client_id "${CHUTES_OAUTH_CLIENT_ID:-}"; then
            CHUTES_OAUTH_CLIENT_ID=""
        fi

        if is_placeholder_client_secret "${CHUTES_OAUTH_CLIENT_SECRET:-}"; then
            CHUTES_OAUTH_CLIENT_SECRET=""
        fi
    fi

    echo
    echo "  Configure your Chutes OAuth client with this redirect URI:"
    echo "    https://${N8N_HOST}/rest/sso/chutes/callback"
    prompt_required_value CHUTES_OAUTH_CLIENT_ID "Chutes OAuth Client ID"
    prompt_required_value CHUTES_OAUTH_CLIENT_SECRET "Chutes OAuth Client Secret" true
}

for overridable_var in \
    INSTALL_MODE \
    CHUTES_TRAFFIC_MODE \
    CHUTES_COMPOSE_FILES \
    EDGE_SERVICE \
    E2EE_PROXY_IMAGE \
    ALLOW_NON_CONFIDENTIAL \
    CHUTES_SSO_PROXY_BYPASS \
    CHUTES_PROXY_BASE_URL \
    CHUTES_CREDENTIAL_TEST_BASE_URL \
    N8N_VERSION \
    N8N_SOURCE_REPO \
    N8N_SOURCE_REF \
    TZ \
    N8N_HOST \
    ACME_EMAIL \
    POSTGRES_USER \
    POSTGRES_PASSWORD \
    POSTGRES_DB \
    N8N_ENCRYPTION_KEY \
    N8N_JWT_SECRET \
    N8N_ADMIN_EMAIL \
    N8N_ADMIN_PASSWORD \
    N8N_EXPIRABLE_CREDENTIAL_REFRESH_WINDOW_SECONDS \
    CHUTES_OAUTH_CLIENT_ID \
    CHUTES_OAUTH_CLIENT_SECRET \
    CHUTES_IDP_BASE_URL \
    CHUTES_SSO_LOGIN_LABEL \
    CHUTES_SSO_SCOPES \
    CHUTES_ADMIN_USERNAMES \
    CHUTES_API_KEY
do
    remember_env_override "$overridable_var"
done

if [ -f "$ENV_FILE" ]; then
    load_env_file "$ENV_FILE"
fi

for overridable_var in \
    INSTALL_MODE \
    CHUTES_TRAFFIC_MODE \
    CHUTES_COMPOSE_FILES \
    EDGE_SERVICE \
    E2EE_PROXY_IMAGE \
    ALLOW_NON_CONFIDENTIAL \
    CHUTES_SSO_PROXY_BYPASS \
    CHUTES_PROXY_BASE_URL \
    CHUTES_CREDENTIAL_TEST_BASE_URL \
    N8N_VERSION \
    N8N_SOURCE_REPO \
    N8N_SOURCE_REF \
    TZ \
    N8N_HOST \
    ACME_EMAIL \
    POSTGRES_USER \
    POSTGRES_PASSWORD \
    POSTGRES_DB \
    N8N_ENCRYPTION_KEY \
    N8N_JWT_SECRET \
    N8N_ADMIN_EMAIL \
    N8N_ADMIN_PASSWORD \
    N8N_EXPIRABLE_CREDENTIAL_REFRESH_WINDOW_SECONDS \
    CHUTES_OAUTH_CLIENT_ID \
    CHUTES_OAUTH_CLIENT_SECRET \
    CHUTES_IDP_BASE_URL \
    CHUTES_SSO_LOGIN_LABEL \
    CHUTES_SSO_SCOPES \
    CHUTES_ADMIN_USERNAMES \
    CHUTES_API_KEY
do
    restore_env_override "$overridable_var"
done

N8N_VERSION="${N8N_VERSION:-$PROJECT_N8N_VERSION}"
N8N_SOURCE_REPO="${N8N_SOURCE_REPO:-$PROJECT_N8N_SOURCE_REPO}"
N8N_SOURCE_REF="${N8N_SOURCE_REF:-n8n@${N8N_VERSION}}"
TZ="${TZ:-UTC}"
POSTGRES_USER="${POSTGRES_USER:-n8n}"
POSTGRES_DB="${POSTGRES_DB:-n8n}"
N8N_ADMIN_EMAIL="${N8N_ADMIN_EMAIL:-admin@chutes.local}"
N8N_EXPIRABLE_CREDENTIAL_REFRESH_WINDOW_SECONDS="${N8N_EXPIRABLE_CREDENTIAL_REFRESH_WINDOW_SECONDS:-300}"
CHUTES_IDP_BASE_URL="${CHUTES_IDP_BASE_URL:-https://api.chutes.ai}"
CHUTES_SSO_LOGIN_LABEL="${CHUTES_SSO_LOGIN_LABEL:-Login with Chutes}"
CHUTES_SSO_SCOPES="${CHUTES_SSO_SCOPES:-openid profile chutes:read chutes:invoke}"
CHUTES_ADMIN_USERNAMES="${CHUTES_ADMIN_USERNAMES:-}"
CHUTES_API_KEY="${CHUTES_API_KEY:-}"
CHUTES_TRAFFIC_MODE="${CHUTES_TRAFFIC_MODE:-direct}"
E2EE_PROXY_IMAGE="${E2EE_PROXY_IMAGE:-parachutes/e2ee-proxy:latest}"
ALLOW_NON_CONFIDENTIAL="${ALLOW_NON_CONFIDENTIAL:-false}"
CHUTES_SSO_PROXY_BYPASS="${CHUTES_SSO_PROXY_BYPASS:-false}"
CHUTES_PROXY_BASE_URL="${CHUTES_PROXY_BASE_URL:-}"
CHUTES_CREDENTIAL_TEST_BASE_URL="${CHUTES_CREDENTIAL_TEST_BASE_URL:-}"
INSTALL_MODE="${INSTALL_MODE:-}"
ACME_EMAIL="${ACME_EMAIL:-}"

adopt_project_n8n_pin

if [ "$DOWN" = true ] && [ -z "$INSTALL_MODE" ]; then
    INSTALL_MODE="local"
fi

if [ "$FORCE_ALL" = true ]; then
    warn "--force-all will rotate data secrets and destroy existing docker volumes for this stack"
fi

prompt_install_mode
if existing_install_detected; then
    EXISTING_INSTALL=true
fi
prompt_install_action
prompt_traffic_mode
prompt_e2ee_proxy_confidential_mode
normalize_sso_proxy_bypass

if [ "$INSTALL_ACTION" = "wipe" ] && [ "$FORCE_ALL" != true ]; then
    FORCE_ALL=true
fi

if [ "$INSTALL_MODE" = "local" ]; then
    if [ -n "${N8N_HOST:-}" ] && [ "$N8N_HOST" != "$LOCAL_HOSTNAME" ]; then
        warn "Local installs always use ${LOCAL_HOSTNAME}; overriding N8N_HOST=${N8N_HOST}"
    fi
    N8N_HOST="$LOCAL_HOSTNAME"
    ACME_EMAIL=""
    if [ "${BOOTSTRAP_OVERRIDE_SET_CHUTES_COMPOSE_FILES:-false}" != "true" ]; then
        CHUTES_COMPOSE_FILES="$(compose_files_default local "$CHUTES_TRAFFIC_MODE")"
    fi
    if [ "${BOOTSTRAP_OVERRIDE_SET_EDGE_SERVICE:-false}" != "true" ]; then
        EDGE_SERVICE="local-proxy"
    fi
    if [ "$CHUTES_TRAFFIC_MODE" = "e2ee-proxy" ]; then
        CHUTES_PROXY_BASE_URL="https://${N8N_HOST}"
        CHUTES_CREDENTIAL_TEST_BASE_URL="https://${N8N_HOST}"
    else
        CHUTES_PROXY_BASE_URL=""
        CHUTES_CREDENTIAL_TEST_BASE_URL=""
    fi
else
    if [ -z "${N8N_HOST:-}" ] && [ "$INTERACTIVE" = true ]; then
        read_interactive_value N8N_HOST "  Public n8n hostname: "
    fi

    if is_placeholder_email "${ACME_EMAIL:-}"; then
        ACME_EMAIL=""
    fi

    prompt_required_value N8N_HOST "Public n8n hostname"
    prompt_required_value ACME_EMAIL "Let's Encrypt email"
    validate_domain_hostname "$N8N_HOST"

    if [ "${BOOTSTRAP_OVERRIDE_SET_CHUTES_COMPOSE_FILES:-false}" != "true" ]; then
        CHUTES_COMPOSE_FILES="$(compose_files_default domain "$CHUTES_TRAFFIC_MODE")"
    fi
    if [ "${BOOTSTRAP_OVERRIDE_SET_EDGE_SERVICE:-false}" != "true" ]; then
        EDGE_SERVICE="caddy"
    fi
    if [ "$CHUTES_TRAFFIC_MODE" = "e2ee-proxy" ]; then
        CHUTES_PROXY_BASE_URL="https://${N8N_HOST}"
        CHUTES_CREDENTIAL_TEST_BASE_URL="https://${N8N_HOST}"
    else
        CHUTES_PROXY_BASE_URL=""
        CHUTES_CREDENTIAL_TEST_BASE_URL=""
    fi
fi

if [ "$DOWN" = true ]; then
    require_cmd docker
    if ! docker compose version >/dev/null 2>&1; then
        err "docker compose is required"
        exit 1
    fi
    compose down
    exit 0
fi

info "Pre-flight checks..."

require_cmd docker
require_cmd openssl
require_cmd rsync

if ! docker compose version >/dev/null 2>&1; then
    err "docker compose is required"
    exit 1
fi

if ! docker info >/dev/null 2>&1; then
    err "Docker daemon is not running"
    exit 1
fi

if ! command -v jq >/dev/null 2>&1 && ! command -v python3 >/dev/null 2>&1; then
    err "Either jq or python3 is required"
    exit 1
fi

ok "Docker is ready"

if [ "$EXISTING_INSTALL" = true ]; then
    if [ "$INSTALL_ACTION" = "wipe" ]; then
        warn "Wipe mode selected: volumes and encrypted n8n data will be recreated from scratch"
    else
        info "Update mode selected: rebuilding cleanly while preserving existing n8n and postgres data"
    fi
fi

ensure_real_chutes_oauth_credentials

if [ -z "${POSTGRES_PASSWORD:-}" ] || [ "$FORCE_ALL" = true ]; then
    POSTGRES_PASSWORD="$(generate_hex 16)"
fi
if [ -z "${N8N_ENCRYPTION_KEY:-}" ] || [ "$FORCE_ALL" = true ]; then
    N8N_ENCRYPTION_KEY="$(generate_hex 32)"
fi
if [ -z "${N8N_JWT_SECRET:-}" ] || [ "$FORCE_ALL" = true ]; then
    N8N_JWT_SECRET="$(generate_hex 32)"
fi
if [ -z "${N8N_ADMIN_PASSWORD:-}" ] || [ "$FORCE_ALL" = true ] || [ "$RESET_OWNER_PASSWORD" = true ]; then
    N8N_ADMIN_PASSWORD="$(generate_owner_password)"
fi

for required_var in \
    N8N_HOST \
    CHUTES_OAUTH_CLIENT_ID \
    CHUTES_OAUTH_CLIENT_SECRET \
    CHUTES_TRAFFIC_MODE \
    N8N_ENCRYPTION_KEY \
    POSTGRES_PASSWORD
do
    if [ -z "${!required_var:-}" ]; then
        err "$required_var must not be empty"
        exit 1
    fi
done

if [ "$INSTALL_MODE" = "domain" ] && [ -z "$ACME_EMAIL" ]; then
    err "ACME_EMAIL must not be empty for domain installs"
    exit 1
fi

info "Writing .env ..."
write_env_file
ok ".env updated"

if [ "$INSTALL_MODE" = "domain" ]; then
    info "Rendering Caddy config ..."
    render_caddyfile
    ok "Caddyfile rendered"
else
    info "Local e2ee-proxy config will be baked into the local-proxy image"
fi

NODES_SRC="$SCRIPT_DIR/../n8n-nodes-chutes"
BUILD_DIR="$SCRIPT_DIR/build/n8n-nodes-chutes"

ensure_dependency_checkout \
    "$NODES_SRC" \
    "${CHUTES_N8N_NODES_GIT_URL:-$PROJECT_NODES_REPO}" \
    "${CHUTES_N8N_NODES_GIT_REF:-$PROJECT_NODES_REF}"

refresh_local_dependency_checkout "$NODES_SRC"

info "Syncing n8n-nodes-chutes into Docker build context ..."
mkdir -p "$BUILD_DIR"
rsync -a --delete \
    --exclude node_modules \
    --exclude .git \
    --exclude tests \
    --exclude coverage \
    "$NODES_SRC/" "$BUILD_DIR/"
node "$SCRIPT_DIR/scripts/patch-n8n-nodes-chutes.mjs" "$BUILD_DIR"
ok "Custom node build context is ready"

if [ "$FORCE_ALL" = true ]; then
    info "Removing existing docker volumes for a clean redeploy ..."
    compose down -v --remove-orphans || true
    remove_stale_project_containers
elif [ "$EXISTING_INSTALL" = true ] && [ "$INSTALL_ACTION" = "update" ]; then
    info "Stopping the existing stack for a clean in-place rebuild ..."
    compose down --remove-orphans || true
    remove_stale_project_containers
fi

info "Building images ..."
compose build

remove_stale_edge_container

info "Starting services ..."
compose up -d

info "Waiting for n8n to become healthy ..."
attempts=0
max_attempts=80
status="starting"
while [ "$attempts" -lt "$max_attempts" ]; do
    status="$(container_runtime_status "$(compose_container_id n8n)")"
    if [ "$status" = "healthy" ]; then
        break
    fi
    attempts=$((attempts + 1))
    if [ $((attempts % 5)) -eq 0 ]; then
        echo "    still waiting... ($status)"
    fi
    sleep 3
done

if [ "$status" != "healthy" ]; then
    err "n8n did not become healthy"
    err "Check logs with: $(compose_command_hint) logs n8n ${EDGE_SERVICE}"
    exit 1
fi
ok "n8n is healthy"

info "Waiting for ${EDGE_SERVICE} to become ready ..."
edge_status="$(wait_for_service_ready "$EDGE_SERVICE" 30 || true)"
if [ "$edge_status" != "healthy" ] && [ "$edge_status" != "running" ]; then
    err "${EDGE_SERVICE} did not become ready (status: ${edge_status})"
    err "Check logs with: $(compose_command_hint) logs ${EDGE_SERVICE}"
    exit 1
fi
ok "${EDGE_SERVICE} is ${edge_status}"

info "Configuring n8n ..."
RESET_OWNER_PASSWORD="$RESET_OWNER_PASSWORD" "$SCRIPT_DIR/scripts/configure-n8n.sh"

OWNER_PASSWORD_VALID=false
if check_owner_login; then
    OWNER_PASSWORD_VALID=true
fi

echo
echo -e "${GREEN}${BOLD}========================================${NC}"
echo -e "${GREEN}${BOLD}  n8n is ready${NC}"
echo -e "${GREEN}${BOLD}========================================${NC}"
echo
echo -e "  Mode: ${BOLD}${INSTALL_MODE}${NC}"
echo -e "  URL:  ${BOLD}https://${N8N_HOST}${NC}"
echo
echo "  Chutes OAuth app settings:"
echo "    Redirect URI: https://${N8N_HOST}/rest/sso/chutes/callback"
if [ "$INSTALL_MODE" = "local" ]; then
    echo "    TLS: embedded e2ee-proxy certificate for ${LOCAL_HOSTNAME}"
else
    echo "    TLS: Let's Encrypt via Caddy"
fi
echo
echo "  Chutes SSO is enabled on the native n8n sign-in page."
echo "  Chutes traffic mode:"
if [ "$CHUTES_TRAFFIC_MODE" = "e2ee-proxy" ]; then
    echo "    e2ee-proxy - OpenAI-compatible LLM text traffic is routed through the existing e2ee-proxy path"
    if [ "$ALLOW_NON_CONFIDENTIAL" = "true" ]; then
        echo "    non-TEE text models are allowed through the proxy path"
    else
        echo "    TEE-only by default; set ALLOW_NON_CONFIDENTIAL=true to allow non-TEE text models"
    fi
    if [ "$CHUTES_SSO_PROXY_BYPASS" = "true" ]; then
        echo "    SSO text execution temporarily stays direct until the backend /e2e auth fix is deployed"
    else
        echo "    SSO and API-key text execution both use the proxy path"
    fi
else
    echo "    direct - native Chutes endpoints are used so Chutes routing/failover behavior stays intact"
    if [ "$INSTALL_MODE" = "local" ]; then
        echo "    local e2ee-proxy is still used for the embedded local certificate and serving n8n"
    fi
fi
echo
if [ "$OWNER_PASSWORD_VALID" = true ]; then
    echo "  Break-glass owner:"
    echo "    Email:    ${N8N_ADMIN_EMAIL}"
    echo -e "    Password: ${BOLD}${N8N_ADMIN_PASSWORD}${NC}"
else
    warn "Stored owner credentials could not be verified."
    warn "Run ./deploy.sh --reset-owner-password to rotate the break-glass owner password."
fi
echo
echo "  Commands:"
echo "    Logs:    $(compose_command_hint) logs -f"
echo "    Stop:    $(compose_command_hint) down"
echo "    Re-test: $SCRIPT_DIR/scripts/smoke-test.sh --syntax"
echo
