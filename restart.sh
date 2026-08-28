#!/usr/bin/env bash
# restart.sh — recreate the PulseChain node stack from docker-compose.yml
# Uses `up -d --force-recreate` so flag, image, and env changes apply and
# running containers actually bounce (`compose restart` keeps stale flags;
# plain `up -d` is a no-op when the config hash is unchanged).
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"
# shellcheck source=common.sh
source "${SCRIPT_DIR}/common.sh"

echo "Recreating node from docker-compose.yml (graceful stop up to ~5 minutes)..."
run_compose up -d --force-recreate --remove-orphans
echo "Node is up (${GETH_CONTAINER} + ${BEACON_CONTAINER})."
echo "Follow logs with: ./logs.sh"
echo "Check sync with:  ./status.sh"
