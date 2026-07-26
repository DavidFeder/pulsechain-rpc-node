#!/usr/bin/env bash
# Assert prysm-pulse beacon launch flags: grpc-gateway-*, never modern --http-host/--http-port.
# Drives the real shipped docker-compose.yml via `docker compose config`.
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

if grep -E '^\s+-\s+--grpc-gateway-port=3500' "$COMPOSE" >/dev/null; then
  pass "grpc-gateway-port=3500 present in source"
else
  fail "missing --grpc-gateway-port=3500 in docker-compose.yml"
fi

if grep -E '^\s+-\s+--rpc-host=0\.0\.0\.0' "$COMPOSE" >/dev/null; then
  pass "rpc-host=0.0.0.0 still present"
else
  fail "missing --rpc-host=0.0.0.0 (must remain)"
fi

# --- 2. Parsed compose config (real docker compose entry point) ---
if ! command -v docker >/dev/null 2>&1; then
  fail "docker not available; cannot parse compose config"
else
  CFG="$(docker compose -f "$COMPOSE" config 2>&1)" || {
    fail "docker compose config failed: $CFG"
    CFG=""
  }
  if [[ -n "$CFG" ]]; then
    # Extract beacon service command block only (between "beacon:" and next top-level-ish service)
    BEACON_CMD="$(printf '%s\n' "$CFG" | awk '
      /^  beacon:/ { in_beacon=1; next }
      in_beacon && /^  [a-z]/ { exit }
      in_beacon && /command:/ { in_cmd=1; next }
      in_beacon && in_cmd && /^    [a-z]/ { exit }
      in_beacon && in_cmd { print }
    ')"

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
fi

if [[ "$FAILED" -ne 0 ]]; then
  echo "One or more beacon flag checks failed." >&2
  exit 1
fi
echo "All beacon flag checks passed."
exit 0
