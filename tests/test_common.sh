#!/usr/bin/env bash
# Unit checks for common.sh helpers (no Docker required).
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck source=../common.sh
source "${ROOT}/common.sh"

FAILED=0
fail() { echo "FAIL: $*" >&2; FAILED=1; }
pass() { echo "PASS: $*"; }

tmp="$(mktemp)"
trap 'rm -f "$tmp"' EXIT

# load_dotenv does not execute shell
printf 'DATA_DIR=/mnt/from-env\n# comment\nEVIL=$(echo pwned)\n' > "$tmp"
unset DATA_DIR
load_dotenv "$tmp"
if [[ "${DATA_DIR}" == "/mnt/from-env" ]]; then
  pass "load_dotenv reads DATA_DIR"
else
  fail "load_dotenv DATA_DIR got '${DATA_DIR:-}'"
fi
if [[ -z "${EVIL:-}" ]]; then
  pass "load_dotenv does not execute command substitutions"
else
  fail "load_dotenv executed a value: EVIL='${EVIL}'"
fi

# Existing environment wins
export DATA_DIR=/already-set
printf 'DATA_DIR=/should-not-win\n' > "$tmp"
load_dotenv "$tmp"
if [[ "${DATA_DIR}" == "/already-set" ]]; then
  pass "load_dotenv does not override exported vars"
else
  fail "load_dotenv overrode DATA_DIR to '${DATA_DIR}'"
fi

# Defaults for ports
if [[ "${HTTP_PORT}" == "8545" || -n "${HTTP_PORT}" ]]; then
  pass "HTTP_PORT is set (${HTTP_PORT})"
else
  fail "HTTP_PORT missing"
fi

# confirm_yes is non-interactive safe
if confirm_yes "should not prompt" </dev/null; then
  fail "confirm_yes returned true without a TTY/yes"
else
  pass "confirm_yes declines when stdin is not a TTY"
fi

# Syntax of helper scripts
for script in install.sh start.sh stop.sh restart.sh logs.sh update.sh status.sh common.sh; do
  if bash -n "${ROOT}/${script}"; then
    pass "bash -n ${script}"
  else
    fail "bash -n ${script}"
  fi
done

# restart.sh must recreate from compose, not `compose restart`
if grep -qE 'compose restart' "${ROOT}/restart.sh"; then
  fail "restart.sh still uses 'compose restart' (drops compose/flag edits)"
else
  pass "restart.sh does not use 'compose restart'"
fi
if grep -qE 'up -d' "${ROOT}/restart.sh"; then
  pass "restart.sh uses up -d"
else
  fail "restart.sh should call up -d so compose edits apply"
fi

# update.sh opt-in latest
if grep -q -- '--latest' "${ROOT}/update.sh"; then
  pass "update.sh documents --latest"
else
  fail "update.sh missing --latest opt-in"
fi

# JWT hardened in installer
if grep -q 'chmod 600' "${ROOT}/install.sh"; then
  pass "install.sh sets JWT mode 600"
else
  fail "install.sh should chmod 600 the JWT"
fi

if [[ "$FAILED" -ne 0 ]]; then
  echo "One or more common.sh / script checks failed." >&2
  exit 1
fi
echo "All common.sh checks passed."
exit 0
