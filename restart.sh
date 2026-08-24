#!/usr/bin/env bash
# restart.sh — recreate the PulseChain node stack from docker-compose.yml
# Uses `up -d` so flag, image, and env changes are actually applied.
# (`docker compose restart` would keep the old container config.)
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"
# shellcheck source=common.sh
source "${SCRIPT_DIR}/common.sh"

echo "Recreating node from docker-compose.yml (applies flag/image/.env changes)..."
run_compose up -d
echo "Node is up (pulse-geth + pulse-beacon)."
echo "Follow logs with: ./logs.sh"
echo "Check sync with:  ./status.sh"
