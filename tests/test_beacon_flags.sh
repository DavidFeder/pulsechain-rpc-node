#!/usr/bin/env bash
# Assert compose + README contracts: prysm grpc-gateway flags, localhost Engine API,
# pinned images, and interpolated defaults.
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

if grep -E '^\s+-\s+--grpc-gateway-host=0\.0\.0\.0' "$COMPOSE" >/dev/null; then
  pass "grpc-gateway-host=0.0.0.0 present in source"
else
  fail "missing --grpc-gateway-host=0.0.0.0 in docker-compose.yml"
fi

if grep -E '^\s+-\s+--grpc-gateway-port=\$\{BEACON_HTTP_PORT:-3500\}' "$COMPOSE" >/dev/null \
   || grep -E '^\s+-\s+--grpc-gateway-port=3500' "$COMPOSE" >/dev/null; then
  pass "grpc-gateway-port defaults to 3500"
else
  fail "missing --grpc-gateway-port default 3500 in docker-compose.yml"
fi

if grep -E '^\s+-\s+--rpc-host=0\.0\.0\.0' "$COMPOSE" >/dev/null; then
  pass "rpc-host=0.0.0.0 still present"
else
  fail "missing --rpc-host=0.0.0.0 (must remain for current LAN default)"
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

if grep -q 'max-size' "$COMPOSE"; then
  pass "container log rotation configured"
else
  fail "docker-compose.yml missing log rotation (max-size)"
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

if CFG="$(run_compose_config)"; then
  BEACON_CMD="$(printf '%s\n' "$CFG" | extract_service_command beacon)"
  GETH_CMD="$(printf '%s\n' "$CFG" | extract_service_command geth)"

  echo "$BEACON_CMD" | grep -q -- '--grpc-gateway-host=0.0.0.0' \
    && pass "compose config: --grpc-gateway-host=0.0.0.0" \
    || fail "compose config missing --grpc-gateway-host=0.0.0.0"

  echo "$BEACON_CMD" | grep -q -- '--grpc-gateway-port=3500' \
    && pass "compose config: --grpc-gateway-port=3500" \
    || fail "compose config missing --grpc-gateway-port=3500"

  echo "$BEACON_CMD" | grep -q -- '--rpc-host=0.0.0.0' \
    && pass "compose config: --rpc-host=0.0.0.0" \
    || fail "compose config missing --rpc-host=0.0.0.0"

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

  echo "$GETH_CMD" | grep -q -- '--authrpc.addr=127.0.0.1' \
    && pass "compose config: --authrpc.addr=127.0.0.1" \
    || fail "compose config missing --authrpc.addr=127.0.0.1"

  echo "$GETH_CMD" | grep -q -- '--http.port=8545' \
    && pass "compose config: --http.port=8545" \
    || fail "compose config missing default --http.port=8545"

  echo "$CFG" | grep -q 'go-pulse:v3.3.0' \
    && pass "compose config pins go-pulse:v3.3.0" \
    || fail "compose config did not pin go-pulse:v3.3.0"

  echo "$CFG" | grep -q 'beacon-chain:v2.3.0' \
    && pass "compose config pins beacon-chain:v2.3.0" \
    || fail "compose config did not pin beacon-chain:v2.3.0"

  # .env / environment interpolation still works
  OVERRIDE="$(DATA_DIR=/mnt/pulse-data HTTP_PORT=18545 BEACON_HTTP_PORT=13500 \
    docker compose --env-file /dev/null -f "$COMPOSE" config 2>&1)" || {
    fail "docker compose config with overrides failed: $OVERRIDE"
    OVERRIDE=""
  }
  if [[ -n "$OVERRIDE" ]]; then
    echo "$OVERRIDE" | grep -q '/mnt/pulse-data' \
      && echo "$OVERRIDE" | grep -q 'target: /blockchain' \
      && pass "DATA_DIR override interpolates into volume" \
      || fail "DATA_DIR override did not appear in compose config"
    echo "$OVERRIDE" | grep -q -- '--http.port=18545' \
      && pass "HTTP_PORT override interpolates" \
      || fail "HTTP_PORT override did not interpolate"
    echo "$OVERRIDE" | grep -q -- '--grpc-gateway-port=13500' \
      && pass "BEACON_HTTP_PORT override interpolates" \
      || fail "BEACON_HTTP_PORT override did not interpolate"
  fi
fi

# --- 3. README must document grpc-gateway (not modern http-host) for localhost mode ---
README="$ROOT/README.md"
if [[ -f "$README" ]]; then
  if grep -q -- '--grpc-gateway-host' "$README"; then
    pass "README documents --grpc-gateway-host"
  else
    fail "README missing --grpc-gateway-host localhost instructions"
  fi
  # Must not tell users to edit beacon --http-host
  if grep -E 'beacon|--http-host' "$README" | grep -q -- '--http-host'; then
    # Only fail if --http-host appears in a beacon context instruction
    if grep -A5 -B5 -- '--http-host' "$README" | grep -qi beacon; then
      fail "README still references --http-host for beacon"
    fi
  else
    pass "README has no beacon --http-host references"
  fi
  if grep -q -- '--authrpc.addr=127.0.0.1' "$README"; then
    pass "README documents localhost Engine API"
  else
    fail "README should mention --authrpc.addr=127.0.0.1"
  fi
fi

if [[ "$FAILED" -ne 0 ]]; then
  echo "One or more beacon/compose checks failed." >&2
  exit 1
fi
echo "All beacon flag checks passed."
exit 0
