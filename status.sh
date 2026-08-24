#!/usr/bin/env bash
# status.sh — container, sync, peer, and disk overview
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"
# shellcheck source=common.sh
source "${SCRIPT_DIR}/common.sh"

echo ""
echo "=== Container status ==="
run_compose ps || true

echo ""
echo "=== Execution RPC (127.0.0.1:${HTTP_PORT}) ==="
if command -v python3 >/dev/null 2>&1; then
  python3 - "${HTTP_PORT}" <<'PY' || echo "HTTP RPC: not responding yet (still starting or firewalled)"
import json, sys, urllib.error, urllib.request

port = sys.argv[1]
url = f"http://127.0.0.1:{port}"

def rpc(method):
    req = urllib.request.Request(
        url,
        data=json.dumps({"jsonrpc": "2.0", "method": method, "params": [], "id": 1}).encode(),
        headers={"Content-Type": "application/json"},
        method="POST",
    )
    with urllib.request.urlopen(req, timeout=5) as resp:
        return json.load(resp)

try:
    sync = rpc("eth_syncing")
    block = rpc("eth_blockNumber")
    peers = rpc("net_peerCount")
except (urllib.error.URLError, TimeoutError, json.JSONDecodeError, OSError) as exc:
    print(f"HTTP RPC: not responding yet ({exc})")
    sys.exit(0)

def hex_int(value):
    if isinstance(value, str) and value.startswith("0x"):
        return int(value, 16)
    return value

sync_result = sync.get("result")
block_n = hex_int(block.get("result"))
peer_n = hex_int(peers.get("result"))

if sync_result is False:
    print("eth_syncing:     false (execution client reports synced)")
elif isinstance(sync_result, dict):
    current = hex_int(sync_result.get("currentBlock", "?"))
    highest = hex_int(sync_result.get("highestBlock", "?"))
    print(f"eth_syncing:     yes  current={current}  highest={highest}")
else:
    print(f"eth_syncing:     {sync_result}")

print(f"eth_blockNumber: {block_n}")
print(f"net_peerCount:   {peer_n}")
PY
else
  if curl -s --max-time 5 -X POST "http://127.0.0.1:${HTTP_PORT}" \
    -H 'Content-Type: application/json' \
    -d '{"jsonrpc":"2.0","method":"eth_syncing","params":[],"id":1}' | grep -q '"result":false'; then
    echo "eth_syncing:     false (execution client reports synced)"
  elif curl -s --max-time 3 -X POST "http://127.0.0.1:${HTTP_PORT}" \
    -H 'Content-Type: application/json' \
    -d '{"jsonrpc":"2.0","method":"eth_blockNumber","params":[],"id":1}' | grep -q result; then
    echo "HTTP RPC: responding (install python3 for decoded sync/peer details)"
  else
    echo "HTTP RPC: not responding yet (still syncing or starting)"
  fi
fi

echo ""
echo "=== Beacon REST (127.0.0.1:${BEACON_HTTP_PORT}) ==="
if command -v python3 >/dev/null 2>&1; then
  python3 - "${BEACON_HTTP_PORT}" <<'PY' || echo "Beacon REST: not responding yet (still starting or firewalled)"
import json, sys, urllib.error, urllib.request

port = sys.argv[1]
base = f"http://127.0.0.1:{port}"

def get(path):
    with urllib.request.urlopen(base + path, timeout=5) as resp:
        return json.load(resp)

try:
    sync = get("/eth/v1/node/syncing")
except (urllib.error.URLError, TimeoutError, json.JSONDecodeError, OSError) as exc:
    print(f"Beacon REST: not responding yet ({exc})")
    sys.exit(0)

data = sync.get("data") or {}
is_syncing = data.get("is_syncing")
head = data.get("head_slot")
distance = data.get("sync_distance")
el_offline = data.get("el_offline")
if is_syncing is False:
    print("syncing:         false (beacon reports synced)")
elif is_syncing is True:
    print(f"syncing:         yes  head_slot={head}  distance={distance}")
else:
    print(f"syncing:         {is_syncing}")
if el_offline is not None:
    print(f"el_offline:      {el_offline}")

try:
    peers = get("/eth/v1/node/peer_count")
    pdata = peers.get("data") or {}
    print(f"peers:           connected={pdata.get('connected', '?')}  disconnected={pdata.get('disconnected', '?')}")
except (urllib.error.URLError, TimeoutError, json.JSONDecodeError, OSError):
    pass
PY
else
  if curl -s --max-time 5 "http://127.0.0.1:${BEACON_HTTP_PORT}/eth/v1/node/syncing" | grep -q is_syncing; then
    echo "Beacon REST: responding (install python3 for decoded sync/peer details)"
  else
    echo "Beacon REST: not responding yet (still starting)"
  fi
fi

echo ""
echo "=== Disk (${DATA_DIR}) ==="
if [[ -d "${DATA_DIR}" ]]; then
  df -h "${DATA_DIR}" | awk 'NR==1 || NR==2'
else
  echo "${DATA_DIR} does not exist yet"
fi

echo ""
echo "Tip: use ./logs.sh for detailed logs"
echo ""
