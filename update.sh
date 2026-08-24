#!/usr/bin/env bash
# update.sh — pull images and recreate containers
# Default: pull the pinned tags in docker-compose.yml / .env
#   ./update.sh --latest   float on upstream :latest (can break flags)
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"
# shellcheck source=common.sh
source "${SCRIPT_DIR}/common.sh"

if [[ "${1:-}" == "--latest" ]]; then
  export GETH_IMAGE="${GETH_IMAGE_LATEST}"
  export BEACON_IMAGE="${BEACON_IMAGE_LATEST}"
  echo "Pulling floating :latest PulseChain images..."
  echo "Note: :latest can change client flags and occasionally require a compose update."
else
  echo "Pulling pinned PulseChain images..."
  echo "  ${GETH_IMAGE}"
  echo "  ${BEACON_IMAGE}"
  echo "Use ./update.sh --latest to float on upstream :latest tags."
fi

run_compose pull

echo "Recreating containers with pulled images..."
echo "Client upgrades are usually compatible, but a rare release can stall sync."
run_compose up -d

echo "Update complete."
echo "Follow logs with: ./logs.sh"
echo "Check sync with:  ./status.sh"
