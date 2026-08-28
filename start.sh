#!/usr/bin/env bash
# start.sh — start the PulseChain node stack
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"
# shellcheck source=common.sh
source "${SCRIPT_DIR}/common.sh"

run_compose up -d --remove-orphans
echo "Node started (${GETH_CONTAINER} + ${BEACON_CONTAINER})."
echo "Follow logs with: ./logs.sh"
