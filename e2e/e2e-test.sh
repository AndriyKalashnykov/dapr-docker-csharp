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

# check_post — POST helper that asserts HTTP status + Location header + body
# in a single curl, per the test-coverage skill's POST-assertion rule. Three
# orthogonal contracts (status code, Location target, response body) are each
# load-bearing for the queueprocessor's `Results.Accepted("/", squared)`
# response shape; asserting only the body would let a 200/Created regression
# ship as long as the squared value still appeared in the response stream.
#
# Captures the body via -o, the response headers via -D, and the status code
# via -w '%{http_code}' — one curl invocation, no race between separate probes.
check_post() {
    local name="$1" url="$2" body_json="$3" expected_status="$4" expected_body="$5" expected_location="$6"
    local body_tmp headers_tmp; body_tmp=$(mktemp); headers_tmp=$(mktemp)
    local status
    status=$(curl -s -o "$body_tmp" -D "$headers_tmp" -w '%{http_code}' \
        --max-time "$E2E_CURL_MAX_TIME_SECONDS" \
        -X POST -H 'Content-Type: application/json' -d "$body_json" "$url" 2>/dev/null || echo "000")
    local body; body=$(cat "$body_tmp"); rm -f "$body_tmp"
    # tolower() on both sides for portability across mawk (Ubuntu default) and
    # gawk — IGNORECASE is gawk-only and silently no-ops under mawk.
    local location
    location=$(awk 'tolower($1)=="location:"{sub(/^[^:]*:[ \t]*/,""); print; exit}' "$headers_tmp" | tr -d '\r')
    rm -f "$headers_tmp"
    local bad=0
    [ "$status" = "$expected_status" ] || { bad=1; echo "    status:   got '$status', expected '$expected_status'"; }
    [ "$body" = "$expected_body" ]       || { bad=1; echo "    body:     got '$body', expected '$expected_body'"; }
    [ "$location" = "$expected_location" ] || { bad=1; echo "    location: got '$location', expected '$expected_location'"; }
    if [ "$bad" -eq 0 ]; then
        pass "$name (HTTP $status, body '$body', Location '$location')"
    else
        fail "$name"
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
echo "==> Test 2: POST /counter squares the input (202 Accepted + Location: /)"
check_post "POST /counter 5 → 25" "$BASE/counter" '5' '202' '25' '/'

echo ""
echo "==> Test 3: state roundtrip — GET / returns the squared value"
assert_body_equals "$BASE/" "25"

echo ""
echo "==> Test 4: POST /counter 0 saves 0 (202 Accepted + Location: /)"
check_post "POST /counter 0 → 0" "$BASE/counter" '0' '202' '0' '/'
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
# Drive several requests so multiple ASP.NET Core spans are produced. The OTLP
# exporter buffers and flushes in batches (default ~5s), so a single request
# may not land before the first poll iteration.
for _ in 1 2 3 4 5; do
    curl -sf --max-time "$E2E_CURL_MAX_TIME_SECONDS" "$BASE/" >/dev/null || true
done

# Jaeger ingests via OTLP gRPC. Query its HTTP query API from inside the
# compose network so we don't depend on a host-side Jaeger port mapping.
# Two contracts to assert (service registration alone is necessary-but-not-
# sufficient — Jaeger registers the service name on the FIRST span ever seen,
# so a stale service registration can pass while subsequent exports are
# silently failing):
#   1. /api/services lists `${OTEL_SERVICE_NAME}` (exporter wired correctly)
#   2. /api/traces?service=${OTEL_SERVICE_NAME}&limit=1 returns ≥1 trace
#      with a "traceID" field (spans are actually being delivered)
seen_service=""
seen_trace=""
last_traces_resp=""
last_services_resp=""
for _ in $(seq 1 "$E2E_JAEGER_POLL_SECONDS"); do
    if [ "$seen_service" != yes ]; then
        last_services_resp=$("${COMPOSE[@]}" exec -T queueprocessor curl -sf --max-time "$E2E_CURL_MAX_TIME_SECONDS" \
            "http://${JAEGER_HOST}:${JAEGER_QUERY_PORT}/api/services" 2>/dev/null || true)
        if echo "$last_services_resp" | grep -q "\"${OTEL_SERVICE_NAME}\""; then
            seen_service=yes
        fi
    fi
    if [ "$seen_service" = yes ] && [ "$seen_trace" != yes ]; then
        last_traces_resp=$("${COMPOSE[@]}" exec -T queueprocessor curl -sf --max-time "$E2E_CURL_MAX_TIME_SECONDS" \
            "http://${JAEGER_HOST}:${JAEGER_QUERY_PORT}/api/traces?service=${OTEL_SERVICE_NAME}&limit=1" 2>/dev/null || true)
        if echo "$last_traces_resp" | grep -q '"traceID"'; then
            seen_trace=yes
            break
        fi
    fi
    sleep "$E2E_POLL_INTERVAL_SECONDS"
done

if [ "$seen_service" = yes ]; then
    pass "Jaeger registered service '${OTEL_SERVICE_NAME}'"
else
    fail "Jaeger did not see service '${OTEL_SERVICE_NAME}' within ${E2E_JAEGER_POLL_SECONDS}s (last response: '${last_services_resp:-<empty>}')"
fi
if [ "$seen_trace" = yes ]; then
    pass "Jaeger returned at least one trace for '${OTEL_SERVICE_NAME}' (spans delivered)"
else
    fail "Jaeger returned no traces for '${OTEL_SERVICE_NAME}' within ${E2E_JAEGER_POLL_SECONDS}s (last response: '${last_traces_resp:-<empty>}')"
fi

echo ""
echo "==> Results: ${PASS} passed, ${FAIL} failed"
[ "$FAIL" -eq 0 ]
