#!/usr/bin/env bash
# Assert compose + README contracts: prysm grpc-gateway flags, localhost Engine API,
# localhost beacon APIs, ipcdisable, pinned digests, and interpolated defaults.
# Drives the real shipped docker-compose.yml via `docker compose config` when Docker exists.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
COMPOSE="$ROOT/docker-compose.yml"
FAILED=0

fail() { echo "FAIL: $*" >&2; FAILED=1; }
pass() { echo "PASS: $*"; }

# --- 1. Source file structural checks (shipped artifact) ---
if [[ ! -f "$COMPOSE" ]]; then
  fail "missing docker-compose.yml"
  exit 1
fi

# Command-array form only: lines that are YAML list items for flags (not comments).
if grep -E '^\s+-\s+--http-host' "$COMPOSE" >/dev/null 2>&1; then
  fail "docker-compose.yml still has --http-host as a beacon command flag"
else
  pass "no --http-host command flag in docker-compose.yml"
fi

if grep -E '^\s+-\s+--http-port' "$COMPOSE" >/dev/null 2>&1; then
  fail "docker-compose.yml still has --http-port as a beacon command flag"
else
  pass "no --http-port command flag in docker-compose.yml"
fi

if grep -E '^\s+-\s+--grpc-gateway-host=\$\{BEACON_HTTP_HOST:-127\.0\.0\.1\}' "$COMPOSE" >/dev/null \
   || grep -E '^\s+-\s+--grpc-gateway-host=127\.0\.0\.1' "$COMPOSE" >/dev/null; then
  pass "grpc-gateway-host defaults to 127.0.0.1"
else
  fail "missing --grpc-gateway-host default 127.0.0.1 in docker-compose.yml"
fi

if grep -E '^\s+-\s+--grpc-gateway-port=\$\{BEACON_HTTP_PORT:-3500\}' "$COMPOSE" >/dev/null \
   || grep -E '^\s+-\s+--grpc-gateway-port=3500' "$COMPOSE" >/dev/null; then
  pass "grpc-gateway-port defaults to 3500"
else
  fail "missing --grpc-gateway-port default 3500 in docker-compose.yml"
fi

if grep -E '^\s+-\s+--rpc-host=\$\{BEACON_GRPC_HOST:-127\.0\.0\.1\}' "$COMPOSE" >/dev/null \
   || grep -E '^\s+-\s+--rpc-host=127\.0\.0\.1' "$COMPOSE" >/dev/null; then
  pass "rpc-host defaults to 127.0.0.1"
else
  fail "missing --rpc-host default 127.0.0.1 (beacon API is localhost unless overridden)"
fi

if grep -E '^\s+-\s+--authrpc\.addr=127\.0\.0\.1' "$COMPOSE" >/dev/null; then
  pass "Engine API bound to 127.0.0.1"
else
  fail "authrpc.addr must be 127.0.0.1 (do not bind Engine API to 0.0.0.0)"
fi

if grep -E '^\s+-\s+--authrpc\.addr=0\.0\.0\.0' "$COMPOSE" >/dev/null; then
  fail "authrpc.addr is 0.0.0.0 — Engine API must stay localhost"
else
  pass "Engine API is not bound to 0.0.0.0"
fi

if grep -E '^\s+-\s+--ipcdisable' "$COMPOSE" >/dev/null; then
  pass "geth IPC disabled"
else
  fail "docker-compose.yml should pass --ipcdisable (IPC exposes admin APIs on the host datadir)"
fi

if grep -E '^\s+-\s+--cache=\$\{GETH_CACHE:-1024\}' "$COMPOSE" >/dev/null; then
  pass "geth --cache is tunable via GETH_CACHE"
else
  fail "missing --cache=\${GETH_CACHE:-1024} in docker-compose.yml"
fi

if grep -E '^\s+-\s+--subscribe-all-subnets' "$COMPOSE" >/dev/null; then
  fail "subscribe-all-subnets should not be set for a private RPC node"
else
  pass "no --subscribe-all-subnets (RPC-only default)"
fi

if grep -E '^\s+image:' "$COMPOSE" | grep -q 'go-pulse:latest'; then
  fail "geth image default is floating :latest — pin a version tag"
else
  pass "geth image default is not :latest"
fi

if grep -E '^\s+image:' "$COMPOSE" | grep -q 'beacon-chain:latest'; then
  fail "beacon image default is floating :latest — pin a version tag"
else
  pass "beacon image default is not :latest"
fi

if grep -E '^\s+image:' "$COMPOSE" | grep -q 'sha256:'; then
  pass "compose image defaults include a digest pin"
else
  fail "compose image defaults should pin sha256 digests"
fi

if grep -q 'max-size' "$COMPOSE"; then
  pass "container log rotation configured"
else
  fail "docker-compose.yml missing log rotation (max-size)"
fi

if grep -q 'nofile' "$COMPOSE"; then
  pass "container nofile ulimit configured"
else
  fail "docker-compose.yml missing nofile ulimits (geth needs more than the Docker default)"
fi

# --- 2. Parsed compose config (real docker compose entry point) ---
run_compose_config() {
  local cfg=""
  if ! command -v docker >/dev/null 2>&1; then
    if [[ -n "${CI:-}${GITHUB_ACTIONS:-}" ]]; then
      fail "docker not available; cannot parse compose config"
    else
      echo "SKIP: docker not available; source checks only"
    fi
    return 1
  fi
  cfg="$(
    env -u DATA_DIR -u HTTP_PORT -u WS_PORT -u BEACON_HTTP_PORT -u BEACON_GRPC_PORT \
      -u BEACON_HTTP_HOST -u BEACON_GRPC_HOST -u GETH_CACHE \
      -u GETH_IMAGE -u BEACON_IMAGE \
      docker compose --env-file /dev/null -f "$COMPOSE" config 2>&1
  )" || {
    fail "docker compose config failed: $cfg"
    return 1
  }
  printf '%s\n' "$cfg"
}

extract_service_command() {
  local service="$1"
  awk -v svc="$service" '
    $0 ~ "^  " svc ":" { in_svc=1; next }
    in_svc && /^  [a-z]/ { exit }
    in_svc && /command:/ { in_cmd=1; next }
    in_svc && in_cmd && /^    [a-z]/ { exit }
    in_svc && in_cmd { print }
  '
}

assert_contains() {
  local haystack="$1"
  local needle="$2"
  local okmsg="$3"
  local failmsg="$4"
  if printf '%s\n' "${haystack}" | grep -q -- "${needle}"; then
    pass "${okmsg}"
  else
    fail "${failmsg}"
  fi
}

if CFG="$(run_compose_config)"; then
  BEACON_CMD="$(printf '%s\n' "$CFG" | extract_service_command beacon)"
  GETH_CMD="$(printf '%s\n' "$CFG" | extract_service_command geth)"

  assert_contains "$BEACON_CMD" '--grpc-gateway-host=127.0.0.1' \
    "compose config: --grpc-gateway-host=127.0.0.1" \
    "compose config missing --grpc-gateway-host=127.0.0.1"
  assert_contains "$BEACON_CMD" '--grpc-gateway-port=3500' \
    "compose config: --grpc-gateway-port=3500" \
    "compose config missing --grpc-gateway-port=3500"
  assert_contains "$BEACON_CMD" '--rpc-host=127.0.0.1' \
    "compose config: --rpc-host=127.0.0.1" \
    "compose config missing --rpc-host=127.0.0.1"

  if echo "$BEACON_CMD" | grep -qE -- '--http-host|--http-port'; then
    fail "compose config beacon command still contains --http-host or --http-port"
  else
    pass "compose config beacon command has no --http-host/--http-port"
  fi

  if echo "$BEACON_CMD" | grep -q -- '--subscribe-all-subnets'; then
    fail "compose config still has --subscribe-all-subnets"
  else
    pass "compose config has no --subscribe-all-subnets"
  fi

  assert_contains "$GETH_CMD" '--authrpc.addr=127.0.0.1' \
    "compose config: --authrpc.addr=127.0.0.1" \
    "compose config missing --authrpc.addr=127.0.0.1"
  assert_contains "$GETH_CMD" '--ipcdisable' \
    "compose config: --ipcdisable" \
    "compose config missing --ipcdisable"
  assert_contains "$GETH_CMD" '--http.port=8545' \
    "compose config: --http.port=8545" \
    "compose config missing default --http.port=8545"
  assert_contains "$CFG" 'go-pulse:v3.3.0' \
    "compose config pins go-pulse:v3.3.0" \
    "compose config did not pin go-pulse:v3.3.0"
  assert_contains "$CFG" 'beacon-chain:v2.3.0' \
    "compose config pins beacon-chain:v2.3.0" \
    "compose config did not pin beacon-chain:v2.3.0"
  assert_contains "$CFG" 'sha256:d2f59592244decca2d1f53b5c8a1d2f7b26cf25d0722118567cc8978b44e526f' \
    "compose config pins go-pulse digest" \
    "compose config missing go-pulse digest pin"
  assert_contains "$CFG" 'sha256:31b44010a9e1ed35125541c4347bae8d343ea98e792651d48d595e610f4d1d78' \
    "compose config pins beacon digest" \
    "compose config missing beacon digest pin"

  # .env / environment interpolation still works
  OVERRIDE="$(DATA_DIR=/mnt/pulse-data HTTP_PORT=18545 BEACON_HTTP_PORT=13500 \
    BEACON_HTTP_HOST=0.0.0.0 GETH_CACHE=512 \
    docker compose --env-file /dev/null -f "$COMPOSE" config 2>&1)" || {
    fail "docker compose config with overrides failed: $OVERRIDE"
    OVERRIDE=""
  }
  if [[ -n "$OVERRIDE" ]]; then
    if echo "$OVERRIDE" | grep -q '/mnt/pulse-data' && echo "$OVERRIDE" | grep -q 'target: /blockchain'; then
      pass "DATA_DIR override interpolates into volume"
    else
      fail "DATA_DIR override did not appear in compose config"
    fi
    assert_contains "$OVERRIDE" '--http.port=18545' \
      "HTTP_PORT override interpolates" \
      "HTTP_PORT override did not interpolate"
    assert_contains "$OVERRIDE" '--grpc-gateway-port=13500' \
      "BEACON_HTTP_PORT override interpolates" \
      "BEACON_HTTP_PORT override did not interpolate"
    assert_contains "$OVERRIDE" '--grpc-gateway-host=0.0.0.0' \
      "BEACON_HTTP_HOST override interpolates" \
      "BEACON_HTTP_HOST override did not interpolate"
    assert_contains "$OVERRIDE" '--cache=512' \
      "GETH_CACHE override interpolates" \
      "GETH_CACHE override did not interpolate"
  fi
fi

# --- 3. README must document grpc-gateway (not modern http-host) ---
README="$ROOT/README.md"
if [[ -f "$README" ]]; then
  if grep -q -- '--grpc-gateway-host' "$README"; then
    pass "README documents --grpc-gateway-host"
  else
    fail "README missing --grpc-gateway-host localhost instructions"
  fi
  if grep -q 'BEACON_HTTP_HOST' "$README"; then
    pass "README documents BEACON_HTTP_HOST"
  else
    fail "README should document BEACON_HTTP_HOST for LAN beacon API"
  fi
  # Must not tell users to configure beacon with the modern --http-host flag.
  if grep -q -- '--http-host=' "$README"; then
    fail "README still instructs setting --http-host= (prysm-pulse uses --grpc-gateway-host)"
  else
    pass "README does not instruct setting --http-host="
  fi
  if grep -q -- '--authrpc.addr=127.0.0.1' "$README"; then
    pass "README documents localhost Engine API"
  else
    fail "README should mention --authrpc.addr=127.0.0.1"
  fi
  if grep -q './status.sh' "$README" && ! grep -Fq 'hostname -I | awk' "$README"; then
    pass "README does not recommend hostname -I as the LAN IP method"
  else
    fail "README should not tell users to use hostname -I (docker0 footgun)"
  fi
fi

if [[ "$FAILED" -ne 0 ]]; then
  echo "One or more beacon/compose checks failed." >&2
  exit 1
fi
echo "All beacon flag checks passed."
exit 0
