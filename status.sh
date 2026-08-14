#!/usr/bin/env bash
# status.sh — quick health overview of the pulsechain-rpc-node stack
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"
source "${SCRIPT_DIR}/common.sh"

echo ""
echo "=== Container status ==="
run_compose ps

echo ""
echo "=== Quick RPC check (local) ==="
if curl -s --max-time 3 -X POST http://127.0.0.1:8545 \
  -H 'Content-Type: application/json' \
  -d '{"jsonrpc":"2.0","method":"eth_blockNumber","params":[],"id":1}' | grep -q result; then
  echo "HTTP RPC (8545): responding"
else
  echo "HTTP RPC (8545): not responding yet (still syncing or starting)"
fi

echo ""
echo "Tip: use ./logs.sh for detailed logs"
echo ""
