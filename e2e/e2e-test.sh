#!/usr/bin/env bash
# E2E test for dapr-docker-csharp.
# Brings up the full Docker Compose stack (app + daprd sidecar + Redis + Jaeger),
# exercises GET / and POST /counter via curl, validates a pub/sub roundtrip
# through the Dapr publish API, and tears the stack down on exit.
set -euo pipefail

HERE=$(cd "$(dirname "$(readlink -f "$0")")" && pwd)
ROOT=$(cd "$HERE/.." && pwd)
cd "$ROOT"

# Load committed defaults from .env.example (source of truth) and an optional
# `.env` override; `set -a` exports everything sourced so compose picks it up.
if [ -f .env.example ]; then set -a; . ./.env.example; set +a; fi
if [ -f .env         ]; then set -a; . ./.env;         set +a; fi

# E2E always overrides HOST_PORT with a free ephemeral port so parallel runs
# (and a long-running `make start`) don't collide.
HOST_PORT=$("$ROOT/scripts/pick-port.sh")
export HOST_PORT
COMPOSE_PROJECT_NAME="dapr-docker-csharp-e2e-$$"
export COMPOSE_PROJECT_NAME

# Env-fallback inline defaults mirror .env.example so the script works even if
# .env.example was deleted.
APP_HOST="${APP_HOST:-localhost}"
DAPR_HOST="${DAPR_HOST:-localhost}"
DAPR_HTTP_PORT="${DAPR_HTTP_PORT:-3500}"
PUBSUB_NAME="${PUBSUB_NAME:-pubsub}"
TOPIC_NAME="${TOPIC_NAME:-counter}"
JAEGER_HOST="${JAEGER_HOST:-jaeger}"
JAEGER_QUERY_PORT="${JAEGER_QUERY_PORT:-16686}"
OTEL_SERVICE_NAME="${OTEL_SERVICE_NAME:-queueprocessor}"

# Tunables (mirror .env.example).
E2E_READINESS_TIMEOUT_SECONDS="${E2E_READINESS_TIMEOUT_SECONDS:-120}"
E2E_PUBSUB_POLL_SECONDS="${E2E_PUBSUB_POLL_SECONDS:-30}"
E2E_JAEGER_POLL_SECONDS="${E2E_JAEGER_POLL_SECONDS:-30}"
E2E_CURL_MAX_TIME_SECONDS="${E2E_CURL_MAX_TIME_SECONDS:-5}"
E2E_PROBE_MAX_TIME_SECONDS="${E2E_PROBE_MAX_TIME_SECONDS:-2}"
E2E_POLL_INTERVAL_SECONDS="${E2E_POLL_INTERVAL_SECONDS:-1}"

COMPOSE=(docker compose \
    --file docker-compose.yaml \
    --file compose/dapr-docker-compose.yaml \
    --file e2e/docker-compose.e2e.override.yaml)
BASE="http://${APP_HOST}:${HOST_PORT}"

PASS=0
FAIL=0

# Color codes when stdout is a TTY; plain text otherwise.
if [ -t 1 ]; then
    GREEN=$'\e[32m'; RED=$'\e[31m'; RESET=$'\e[0m'
else
    GREEN=""; RED=""; RESET=""
fi

pass() { echo "${GREEN}PASS:${RESET} $*"; PASS=$((PASS + 1)); }
fail() { echo "${RED}FAIL:${RESET} $*"; FAIL=$((FAIL + 1)); }

cleanup() {
    local rc=$?
    if [ "$FAIL" -gt 0 ] || [ "$rc" -ne 0 ]; then
        echo "==> Dumping container logs (failure path)"
        "${COMPOSE[@]}" logs --no-color --tail=200 || true
    fi
    echo "==> Tearing down compose stack ($COMPOSE_PROJECT_NAME)"
    "${COMPOSE[@]}" down -v --remove-orphans --timeout 5 >/dev/null 2>&1 || true
}
trap cleanup EXIT

wait_for_url() {
    local url="$1"
    local timeout="${2:-$E2E_READINESS_TIMEOUT_SECONDS}"
    local i
    for i in $(seq 1 "$timeout"); do
        if curl -sf -o /dev/null --max-time "$E2E_PROBE_MAX_TIME_SECONDS" "$url"; then
            echo "==> Ready: $url (after ${i}s)"
            return 0
        fi
        sleep "$E2E_POLL_INTERVAL_SECONDS"
    done
    fail "Timed out waiting for $url after ${timeout}s"
    return 1
}

assert_status() {
    local method="$1"
    local url="$2"
    local expected="$3"
    local body="${4:-}"
    local opts=(-s -o /dev/null -w '%{http_code}' --max-time "$E2E_CURL_MAX_TIME_SECONDS" -X "$method")
    [ -n "$body" ] && opts+=(-H 'Content-Type: application/json' -d "$body")
    local status
    status=$(curl "${opts[@]}" "$url" || echo "000")
    if [ "$status" = "$expected" ]; then
        pass "$method $url → $status"
    else
        fail "$method $url → $status (expected $expected)"
    fi
}

assert_body_equals() {
    local url="$1"
    local expected="$2"
    local body
    body=$(curl -sf --max-time "$E2E_CURL_MAX_TIME_SECONDS" "$url" || echo "<error>")
    if [ "$body" = "$expected" ]; then
        pass "GET $url body = '$expected'"
    else
        fail "GET $url body = '$body' (expected '$expected')"
    fi
}

echo "==> Bringing up Docker Compose stack on host port ${HOST_PORT}"
"${COMPOSE[@]}" up -d --build --quiet-pull >/dev/null

# /healthz proves the app process is alive before we exercise Dapr.
wait_for_url "$BASE/healthz" 120

echo ""
echo "==> Test 0: /healthz returns 200"
assert_status GET "$BASE/healthz" 200

# GET / proves the full chain: app → daprd → Redis.
wait_for_url "$BASE/" 120

echo ""
echo "==> Test 1: initial state is 0"
assert_body_equals "$BASE/" "0"

echo ""
echo "==> Test 2: POST /counter squares the input"
result=$(curl -sf --max-time "$E2E_CURL_MAX_TIME_SECONDS" -X POST -H 'Content-Type: application/json' -d '5' "$BASE/counter" || echo "<error>")
if [ "$result" = "25" ]; then
    pass "POST /counter 5 → 25"
else
    fail "POST /counter 5 → '$result' (expected 25)"
fi

echo ""
echo "==> Test 3: state roundtrip — GET / returns the squared value"
assert_body_equals "$BASE/" "25"

echo ""
echo "==> Test 4: POST /counter 0 saves 0"
result=$(curl -sf --max-time "$E2E_CURL_MAX_TIME_SECONDS" -X POST -H 'Content-Type: application/json' -d '0' "$BASE/counter" || echo "<error>")
if [ "$result" = "0" ]; then
    pass "POST /counter 0 → 0"
else
    fail "POST /counter 0 → '$result' (expected 0)"
fi
assert_body_equals "$BASE/" "0"

echo ""
echo "==> Test 5: pub/sub delivery via Dapr publish API"
# Publish via daprd's HTTP API (port 3500 inside the queueprocessor container)
# and poll until the subscribed handler updates the state store.
"${COMPOSE[@]}" exec -T queueprocessor curl -sf --max-time "$E2E_CURL_MAX_TIME_SECONDS" \
    "http://${DAPR_HOST}:${DAPR_HTTP_PORT}/v1.0/publish/${PUBSUB_NAME}/${TOPIC_NAME}?metadata.rawPayload=false" \
    -H 'Content-Type: application/json' --data '7' \
    || fail "Dapr publish to ${PUBSUB_NAME}/${TOPIC_NAME} failed"

# Subscriber squares 7 → 49 and persists. Poll up to 30s.
seen=""
for _ in $(seq 1 "$E2E_PUBSUB_POLL_SECONDS"); do
    cur=$(curl -sf --max-time "$E2E_CURL_MAX_TIME_SECONDS" "$BASE/" || true)
    if [ "$cur" = "49" ]; then
        seen=yes
        break
    fi
    sleep "$E2E_POLL_INTERVAL_SECONDS"
done
if [ "$seen" = yes ]; then
    pass "pub/sub roundtrip: publish 7 → consumer squared to 49 in state"
else
    fail "pub/sub roundtrip: GET / did not reach 49 within ${E2E_PUBSUB_POLL_SECONDS}s (last value: '${cur:-unknown}')"
fi

echo ""
echo "==> Test 6: negative case — unknown path returns 404"
assert_status GET "$BASE/this-route-does-not-exist" 404

echo ""
echo "==> Test 7: OTel — app emits spans to Jaeger OTLP collector"
# Drive at least one request so an ASP.NET Core span is produced.
curl -sf --max-time "$E2E_CURL_MAX_TIME_SECONDS" "$BASE/" >/dev/null || true
# Jaeger ingests via OTLP gRPC. Query Jaeger's HTTP /api/services from inside
# the compose network. Poll up to 30s for the service to register.
seen_traces=""
for _ in $(seq 1 "$E2E_JAEGER_POLL_SECONDS"); do
    resp=$("${COMPOSE[@]}" exec -T queueprocessor curl -sf --max-time "$E2E_CURL_MAX_TIME_SECONDS" \
        "http://${JAEGER_HOST}:${JAEGER_QUERY_PORT}/api/services" 2>/dev/null || true)
    if echo "$resp" | grep -q "\"${OTEL_SERVICE_NAME}\""; then
        seen_traces=yes
        break
    fi
    sleep "$E2E_POLL_INTERVAL_SECONDS"
done
if [ "$seen_traces" = yes ]; then
    pass "Jaeger registered service '${OTEL_SERVICE_NAME}' — OTel exporter is wired"
else
    fail "Jaeger did not see service '${OTEL_SERVICE_NAME}' within ${E2E_JAEGER_POLL_SECONDS}s (last response: '${resp:-<empty>}')"
fi

echo ""
echo "==> Results: ${PASS} passed, ${FAIL} failed"
[ "$FAIL" -eq 0 ]
