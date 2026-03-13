#!/usr/bin/env bash
#
# Smoke tests for chutes-n8n-embed.
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"

compose() {
    local files="${CHUTES_COMPOSE_FILES:-$PROJECT_DIR/docker-compose.yml}"
    local file
    local old_ifs="$IFS"
    local -a args=()

    IFS=':' read -r -a compose_files <<< "$files"
    IFS="$old_ifs"

    for file in "${compose_files[@]}"; do
        if [[ "$file" != /* ]]; then
            file="$PROJECT_DIR/$file"
        fi
        args+=(-f "$file")
    done

    docker compose "${args[@]}" "$@"
}

PASS=0
FAIL=0
SKIP=0
SYNTAX_ONLY=false
EDGE_SERVICE="${EDGE_SERVICE:-}"

for arg in "$@"; do
    [ "$arg" = "--syntax" ] && SYNTAX_ONLY=true
done

pass() { echo "  PASS: $*"; PASS=$((PASS + 1)); }
fail() { echo "  FAIL: $*"; FAIL=$((FAIL + 1)); }
skip() { echo "  SKIP: $*"; SKIP=$((SKIP + 1)); }

json_query() {
    local expression="$1"
    if command -v jq >/dev/null 2>&1; then
        jq -r "$expression"
    else
        python3 - "$expression" <<'PY'
import json
import sys

expr = sys.argv[1]
data = json.load(sys.stdin)
value = data
for part in expr.split('.'):
    if not part:
        continue
    value = value.get(part)
print("" if value is None else value)
PY
    fi
}

container_health_status() {
    docker inspect "$1" --format='{{if .State.Health}}{{.State.Health.Status}}{{else}}{{.State.Status}}{{end}}' 2>/dev/null || echo missing
}

wait_for_container() {
    local container="$1"
    local attempts="$2"
    local status="missing"

    while [ "$attempts" -gt 0 ]; do
        status="$(container_health_status "$container")"
        if [ "$status" = "healthy" ] || [ "$status" = "running" ]; then
            printf '%s' "$status"
            return 0
        fi
        attempts=$((attempts - 1))
        sleep 1
    done

    printf '%s' "$status"
    return 1
}

curl_edge() {
    local -a host_args=()

    if [ "${INSTALL_MODE:-}" = "local" ]; then
        host_args+=(--resolve "${N8N_HOST}:443:127.0.0.1")
        host_args+=(--resolve "${N8N_HOST}:80:127.0.0.1")
    fi

    curl "${host_args[@]}" "$@"
}

edge_container_name() {
    case "${EDGE_SERVICE:-}" in
        caddy) printf '%s' "n8n-caddy" ;;
        local-proxy) printf '%s' "n8n-local-proxy" ;;
        *)
            printf '%s' "missing"
            ;;
    esac
}

echo "=== Syntax checks ==="

for file in "$PROJECT_DIR/bootstrap.sh" "$PROJECT_DIR/scripts/"*.sh; do
    if bash -n "$file" >/dev/null 2>&1; then
        pass "bash -n $(basename "$file")"
    else
        fail "bash -n $(basename "$file")"
    fi
done

if command -v node >/dev/null 2>&1; then
    if node --check "$PROJECT_DIR/scripts/apply-n8n-overlay.mjs" >/dev/null 2>&1; then
        pass "node --check apply-n8n-overlay.mjs"
    else
        fail "node --check apply-n8n-overlay.mjs"
    fi
else
    skip "node not installed - cannot validate overlay patcher"
fi

if command -v jq >/dev/null 2>&1; then
    for file in "$PROJECT_DIR/workflows/"*.json; do
        if jq empty "$file" >/dev/null 2>&1; then
            pass "jq $(basename "$file")"
        else
            fail "jq $(basename "$file")"
        fi
    done
else
    skip "jq not installed - cannot validate workflow JSON"
fi

if docker compose -f "$PROJECT_DIR/docker-compose.yml" -f "$PROJECT_DIR/docker-compose.domain.yml" config -q >/dev/null 2>&1; then
    pass "docker compose config (domain stack)"
else
    fail "docker compose config (domain stack)"
fi

if docker compose -f "$PROJECT_DIR/docker-compose.yml" -f "$PROJECT_DIR/docker-compose.local.yml" config -q >/dev/null 2>&1; then
    pass "docker compose config (local stack)"
else
    fail "docker compose config (local stack)"
fi

for placeholder in __SERVER_NAME__ __TLS_DIRECTIVE__; do
    if grep -q "$placeholder" "$PROJECT_DIR/conf/Caddyfile.template"; then
        pass "Caddy template has $placeholder"
    else
        fail "Caddy template missing $placeholder"
    fi
done

for placeholder in __SERVER_NAME__ __RESOLVERS__; do
    if grep -q "$placeholder" "$PROJECT_DIR/conf/local-proxy.nginx.template"; then
        pass "local proxy template has $placeholder"
    else
        fail "local proxy template missing $placeholder"
    fi
done

if [ "$SYNTAX_ONLY" = true ]; then
    echo
    echo "=== Results: $PASS passed, $FAIL failed, $SKIP skipped ==="
    [ "$FAIL" -eq 0 ]
    exit $?
fi

echo
echo "=== Runtime checks ==="

if [ ! -f "$PROJECT_DIR/.env" ]; then
    fail ".env missing - run bootstrap.sh first"
    echo
    echo "=== Results: $PASS passed, $FAIL failed, $SKIP skipped ==="
    exit 1
fi

set -a
# shellcheck disable=SC1090
source "$PROJECT_DIR/.env"
set +a

EDGE_SERVICE="${EDGE_SERVICE:-}"
if [ -z "$EDGE_SERVICE" ]; then
    case "${INSTALL_MODE:-domain}" in
        local) EDGE_SERVICE="local-proxy" ;;
        *) EDGE_SERVICE="caddy" ;;
    esac
fi

for service in postgres n8n "$EDGE_SERVICE"; do
    case "$service" in
        postgres) container="n8n-postgres" ;;
        n8n) container="n8n" ;;
        *) container="$(edge_container_name)" ;;
    esac

    status="$(wait_for_container "$container" 30 || true)"
    if [ "$status" = "healthy" ] || [ "$status" = "running" ]; then
        pass "$service container $status"
    else
        fail "$service container status: $status"
    fi
done

if [ "$EDGE_SERVICE" = "caddy" ]; then
    if compose exec -T caddy caddy validate --config /etc/caddy/Caddyfile >/dev/null 2>&1; then
        pass "caddy validate"
    else
        fail "caddy validate"
    fi
else
    if compose exec -T local-proxy /usr/local/openresty/bin/openresty -t >/dev/null 2>&1; then
        pass "openresty validate"
    else
        fail "openresty validate"
    fi
fi

healthz="$(compose exec -T n8n wget -q -O- http://127.0.0.1:5678/healthz 2>/dev/null || echo '')"
if echo "$healthz" | grep -qi 'ok\|healthy\|{}'; then
    pass "n8n /healthz responds"
else
    fail "n8n /healthz unreachable"
fi

signin_html="$(curl_edge -sk "https://${N8N_HOST}/signin" 2>/dev/null || true)"
if [ -n "$signin_html" ]; then
    pass "HTTPS sign-in page reachable"
else
    fail "HTTPS sign-in page unreachable"
fi

settings_json="$(curl_edge -sk "https://${N8N_HOST}/rest/settings" 2>/dev/null || true)"
sso_enabled="$(printf '%s' "$settings_json" | json_query '.data.sso.chutes.loginEnabled' 2>/dev/null || true)"
sso_label="$(printf '%s' "$settings_json" | json_query '.data.sso.chutes.loginLabel' 2>/dev/null || true)"
if [ "$sso_enabled" = "true" ] && [ "$sso_label" = "${CHUTES_SSO_LOGIN_LABEL:-Continue with Chutes}" ]; then
    pass "frontend settings expose Chutes SSO"
else
    fail "frontend settings are missing Chutes SSO"
fi

if compose exec -T n8n node - <<'NODE' >/dev/null 2>&1
const { CredentialsHelper } = require('/usr/local/lib/node_modules/n8n/dist/credentials-helper.js');

(async () => {
	const helper = Object.create(CredentialsHelper.prototype);
	let updateCalled = false;

	helper.credentialTypes = {
		getByName() {
			return {
				name: 'chutesApi',
				properties: [
					{ name: 'sessionToken', type: 'hidden', typeOptions: { expirable: true } },
					{ name: 'tokenExpiresAt', type: 'hidden' },
				],
				async preAuthentication() {
					return {
						sessionToken: 'fresh-session-token',
						refreshToken: 'fresh-refresh-token',
						tokenExpiresAt: new Date(Date.now() + 60 * 60 * 1000).toISOString(),
					};
				},
			};
		},
	};

	helper.updateCredentials = async () => {
		updateCalled = true;
	};

	const result = await helper.preAuthentication(
		{ helpers: {} },
		{
			sessionToken: 'stale-session-token',
			refreshToken: 'stale-refresh-token',
			tokenExpiresAt: '1970-01-01T00:00:00.000Z',
		},
		'chutesApi',
		{
			type: 'n8n-nodes-chutes.chutes',
			parameters: {},
			credentials: {
				chutesApi: {
					id: 'cred-1',
					name: 'Chutes SSO',
				},
			},
		},
		false,
	);

	if (!updateCalled || result?.refreshToken !== 'fresh-refresh-token') {
		throw new Error('expirable credential helper did not refresh an expiring token');
	}
})().catch((error) => {
	console.error(error);
	process.exit(1);
});
NODE
then
    pass "expirable credentials refresh before token expiry"
else
    fail "expirable credentials did not refresh before token expiry"
fi

sso_headers="$(curl_edge -skI "https://${N8N_HOST}/rest/sso/chutes/login" 2>/dev/null || true)"
if echo "$sso_headers" | grep -qi '^location: .*idp/authorize'; then
    pass "native Chutes SSO endpoint redirects to the IDP"
else
    fail "native Chutes SSO endpoint did not redirect to the IDP"
fi

if compose exec -T n8n sh -lc \
    "grep -R 'restApiContext.baseUrl}/sso/chutes/login' /usr/local/lib/node_modules/n8n/node_modules/n8n-editor-ui/dist/assets >/dev/null"; then
    pass "editor bundle uses REST base URL for Chutes login"
else
    fail "editor bundle is missing the REST base URL Chutes login fix"
fi

if compose exec -T n8n sh -lc \
    "grep -R 'toggle-password-login' /usr/local/lib/node_modules/n8n/node_modules/n8n-editor-ui/dist/assets >/dev/null" && \
   compose exec -T n8n sh -lc \
    "grep -R 'Login using other credentials' /usr/local/lib/node_modules/n8n/node_modules/n8n-editor-ui/dist/assets >/dev/null"; then
    pass "editor bundle includes the local-login reveal flow"
else
    fail "editor bundle is missing the local-login reveal flow"
fi

http_status="$(curl_edge -s -o /dev/null -w '%{http_code}' "http://${N8N_HOST}/signin" 2>/dev/null || echo 000)"
if [ "$http_status" = "308" ] || [ "$http_status" = "301" ]; then
    pass "HTTP redirects to HTTPS"
else
    fail "HTTP did not redirect to HTTPS (status $http_status)"
fi

owner_login="$(curl_edge -sk -c /tmp/chutes-n8n-embed.cookies \
    -H 'Content-Type: application/json' \
    -H 'browser-id: smoke-test-browser' \
    -d "$(printf '{"emailOrLdapLoginId":"%s","password":"%s"}' "$N8N_ADMIN_EMAIL" "$N8N_ADMIN_PASSWORD")" \
    "https://${N8N_HOST}/rest/login" 2>/dev/null || true)"
if echo "$owner_login" | grep -q '"id"'; then
    pass "break-glass owner login works"
else
    fail "break-glass owner login failed"
fi

if compose exec -T n8n n8n export:nodes --output=/tmp/nodes.json >/dev/null 2>&1 && \
    compose exec -T n8n node - <<'NODE' >/dev/null 2>&1
const fs = require('fs');

const nodes = JSON.parse(fs.readFileSync('/tmp/nodes.json', 'utf8'));
const required = ['CUSTOM.chutes', 'CUSTOM.chutesChatModel', 'CUSTOM.chutesAIAgent'];
const missing = required.filter((name) => !nodes.some((node) => node.name === name));

if (missing.length > 0) {
	console.error(`Missing custom nodes: ${missing.join(', ')}`);
	process.exit(1);
}
NODE
then
    pass "custom nodes are registered in n8n"
else
    fail "custom nodes are not registered in n8n"
fi

credentials_response="$(curl_edge -sk -b /tmp/chutes-n8n-embed.cookies \
    -H 'browser-id: smoke-test-browser' \
    "https://${N8N_HOST}/rest/credentials" 2>/dev/null || true)"

if command -v jq >/dev/null 2>&1; then
    sso_credential_id="$(printf '%s' "$credentials_response" | jq -r '.data[] | select(.type == "chutesApi" and .name == "Chutes SSO") | .id' | head -n 1)"
    if [ -n "$sso_credential_id" ] && [ "$sso_credential_id" != "null" ]; then
        dynamic_payload="$(jq -nc --arg id "$sso_credential_id" '{
            credentials: {
                chutesApi: {
                    id: $id,
                    name: "Chutes SSO"
                }
            },
            currentNodeParameters: {
                resource: "imageGeneration",
                chuteUrl: "https://image.chutes.ai",
                operation: "generate",
                prompt: "",
                size: "1024x1024",
                n: 1,
                additionalOptions: {}
            },
            nodeTypeAndVersion: {
                name: "CUSTOM.chutes",
                version: 1
            },
            methodName: "getImageChutes",
            path: "chuteUrl"
        }')"
        dynamic_options_response="$(curl_edge -sk -b /tmp/chutes-n8n-embed.cookies \
            -H 'Content-Type: application/json' \
            -H 'browser-id: smoke-test-browser' \
            -d "$dynamic_payload" \
            "https://${N8N_HOST}/rest/dynamic-node-parameters/options" 2>/dev/null || true)"
        dynamic_options_count="$(printf '%s' "$dynamic_options_response" | jq -r '.data | length')"
        if [[ "$dynamic_options_count" =~ ^[0-9]+$ ]] && [ "$dynamic_options_count" -gt 0 ]; then
            pass "Chutes SSO credential loads chute options"
        else
            fail "Chutes SSO credential did not load chute options"
        fi
    else
        skip "no Chutes SSO credential present - skipping chute option load check"
    fi
else
    skip "jq not installed - cannot validate Chutes SSO option loading"
fi

rm -f /tmp/chutes-n8n-embed.cookies

echo
echo "=== Results: $PASS passed, $FAIL failed, $SKIP skipped ==="
[ "$FAIL" -eq 0 ]
