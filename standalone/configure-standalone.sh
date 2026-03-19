#!/bin/sh
#
# Post-startup n8n configuration for standalone mode.
#
# Adapted from scripts/configure-n8n.sh:
# - Direct HTTP calls to localhost:5678 (no compose exec)
# - SQLite queries (no postgres) or external postgres via env
# - n8n CLI commands run directly (no compose exec wrapper)
#
set -eu

N8N_ADMIN_EMAIL="${STANDALONE_ADMIN_EMAIL:?STANDALONE_ADMIN_EMAIL must be set}"
N8N_ADMIN_PASSWORD="$(cat /tmp/.owner-password 2>/dev/null)" || true
if [ -z "$N8N_ADMIN_PASSWORD" ]; then
    echo "  ERROR: owner password not found"
    exit 1
fi
DATA_DIR="${STANDALONE_DATA_DIR:-/data}"
CHUTES_API_KEY="${CHUTES_API_KEY:-}"
DB_TYPE="${DB_TYPE:-sqlite}"
SQLITE_DB="$DATA_DIR/.n8n/database.sqlite"
WORKFLOW_DIR="/opt/workflows"

# ---------------------------------------------------------------------------
# Wait for n8n to be healthy
# ---------------------------------------------------------------------------
echo "  Waiting for n8n to be healthy ..."
attempts=0
max_attempts=60
while [ "$attempts" -lt "$max_attempts" ]; do
    if wget -q -O- http://127.0.0.1:5678/healthz >/dev/null 2>&1; then
        break
    fi
    attempts=$((attempts + 1))
    sleep 2
done

if [ "$attempts" -ge "$max_attempts" ]; then
    echo "  ERROR: n8n did not become healthy"
    exit 1
fi
echo "  n8n is healthy"

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------
n8n_api() {
    _method="$1"
    _path="$2"
    shift 2
    case "$_method" in
        POST)
            _body="${1:-}"
            wget -q -O- \
                --header='Content-Type: application/json' \
                --post-data="$_body" \
                "http://127.0.0.1:5678${_path}" 2>/dev/null || true
            ;;
        GET)
            wget -q -O- "http://127.0.0.1:5678${_path}" 2>/dev/null || true
            ;;
    esac
}

sql_escape() {
    printf "%s" "$1" | sed "s/'/''/g"
}

db_scalar() {
    if [ "$DB_TYPE" = "sqlite" ]; then
        sqlite3 "$SQLITE_DB" "$1" 2>/dev/null || true
    else
        PGPASSWORD="${DB_POSTGRESDB_PASSWORD:-}" psql \
            -h "${DB_POSTGRESDB_HOST:-localhost}" \
            -p "${DB_POSTGRESDB_PORT:-5432}" \
            -U "${DB_POSTGRESDB_USER:-n8n}" \
            -d "${DB_POSTGRESDB_DATABASE:-n8n}" \
            -At -v ON_ERROR_STOP=1 -c "$1" 2>/dev/null || true
    fi
}

owner_is_configured() {
    [ "$(db_scalar "SELECT value FROM settings WHERE key = 'userManagement.isInstanceOwnerSetUp';")" = "true" ]
}

workflow_exists() {
    _wf_name="$(sql_escape "$1")"
    _count="$(db_scalar "SELECT COUNT(*) FROM workflow_entity WHERE name = '${_wf_name}';")"
    [ "${_count:-0}" -gt 0 ]
}

credential_exists() {
    _cred_name="$(sql_escape "$1")"
    _cred_type="$(sql_escape "$2")"
    _count="$(db_scalar "SELECT COUNT(*) FROM credentials_entity WHERE name = '${_cred_name}' AND type = '${_cred_type}';")"
    [ "${_count:-0}" -gt 0 ]
}

owner_user_id() {
    db_scalar "SELECT id FROM \"user\" LIMIT 1;"
}

generate_uuid() {
    node -e 'console.log(require("crypto").randomUUID())'
}

json_field() {
    node -e "const d=JSON.parse(require('fs').readFileSync('$1','utf8')); console.log(d['$2']||'')"
}

# ---------------------------------------------------------------------------
# Owner setup
# ---------------------------------------------------------------------------
echo "  Configuring break-glass owner ..."

setup_body="$(printf '{"email":"%s","firstName":"Chutes","lastName":"Owner","password":"%s"}' \
    "$N8N_ADMIN_EMAIL" "$N8N_ADMIN_PASSWORD")"

if owner_is_configured; then
    echo "    Owner already configured"
else
    setup_result="$(n8n_api POST /rest/owner/setup "$setup_body")"
    case "$setup_result" in
        *'"id"'*)
            echo "    Owner account created"
            ;;
        *)
            echo "    ERROR: owner setup failed"
            echo "    $setup_result" | head -5
            exit 1
            ;;
    esac
fi

owner_id="$(owner_user_id)"
if [ -z "$owner_id" ]; then
    echo "    ERROR: owner user ID is empty after configuration"
    exit 1
fi

# ---------------------------------------------------------------------------
# Chutes API credential
# ---------------------------------------------------------------------------
if [ -n "$CHUTES_API_KEY" ]; then
    echo "  Ensuring Chutes API credential exists ..."
    if credential_exists "Chutes API" "chutesApi"; then
        echo "    Chutes API credential already present"
    else
        cred_id="$(generate_uuid)"
        node -e "
const fs = require('fs');
const creds = [{
    id: '$cred_id',
    name: 'Chutes API',
    type: 'chutesApi',
    data: { apiKey: process.env.CHUTES_API_KEY, environment: 'Production' }
}];
fs.writeFileSync('/tmp/creds.json', JSON.stringify(creds));
"
        n8n import:credentials --input=/tmp/creds.json 2>/dev/null
        rm -f /tmp/creds.json
        echo "    Chutes API credential imported"
    fi
fi

# ---------------------------------------------------------------------------
# Starter workflows
# ---------------------------------------------------------------------------
if [ -d "$WORKFLOW_DIR" ] && ls "$WORKFLOW_DIR"/*.json >/dev/null 2>&1; then
    echo "  Ensuring starter workflows exist ..."

    for wf_file in "$WORKFLOW_DIR"/*.json; do
        wf_name="$(json_field "$wf_file" name)"
        if [ -z "$wf_name" ]; then
            echo "    WARNING: could not read name from $(basename "$wf_file")"
            continue
        fi

        if workflow_exists "$wf_name"; then
            echo "    Workflow already present: $wf_name"
            continue
        fi

        wf_id="$(generate_uuid)"
        node -e "
const fs = require('fs');
const wf = JSON.parse(fs.readFileSync('$wf_file', 'utf8'));
wf.id = wf.id || '$wf_id';
fs.writeFileSync('/tmp/workflow.json', JSON.stringify(wf));
"
        n8n import:workflow --input=/tmp/workflow.json --userId="$owner_id" 2>/dev/null
        rm -f /tmp/workflow.json
        echo "    Imported workflow: $wf_name"
    done
fi

rm -f /tmp/.owner-password
echo "  Configuration complete."
