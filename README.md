# pulsechain-rpc-node

Run a **PulseChain mainnet full node** and use it as a **private JSON-RPC endpoint** for MetaMask, Internet Money, and other wallets.

This project packages the official PulseChain clients in Docker Compose with a single install script. No manual client builds, no complex config for the common case.

| Component | Role | Image |
|-----------|------|-------|
| [Go-Pulse](https://gitlab.com/pulsechaincom/go-pulse) | Execution layer (JSON-RPC / WebSocket) | `registry.gitlab.com/pulsechaincom/go-pulse:v3.3.0` |
| [Prysm-Pulse](https://gitlab.com/pulsechaincom/prysm-pulse) | Consensus layer (beacon chain) | `registry.gitlab.com/pulsechaincom/prysm-pulse/beacon-chain:v2.3.0` |

**Defaults:** mainnet · checkpoint sync · data under `/blockchain` · wallet RPC on the LAN (`0.0.0.0`) · Engine API and beacon HTTP/gRPC localhost-only · digest-pinned client tags (`./update.sh --latest` writes `:latest` into `.env`)

---

## Quick start

**Requirements:** Linux (Ubuntu 22.04 / 24.04 or Debian recommended; amd64 or arm64), `sudo`, outbound internet, and a large SSD mounted where `/blockchain` will live.

```bash
git clone https://github.com/DavidFeder/pulsechain-rpc-node.git
cd pulsechain-rpc-node
chmod +x install.sh
./install.sh
```

The installer will:

1. Install Docker Engine and the Compose plugin if they are missing (Ubuntu/Debian)
2. Create `/blockchain` (with `execution` / `consensus` subdirs) and generate a JWT secret if needed
3. Pull the official images and start both containers
4. Print your LAN IP and wallet connection settings

---

## Hardware recommendations

PulseChain includes Ethereum mainnet state through the fork block, so storage and memory needs are substantial.

| Resource | Recommended | Minimum |
|----------|-------------|---------|
| **RAM** | 32 GB or more | 16 GB (may swap under load) |
| **Storage** | 2 TB+ NVMe SSD | 1.5 TB+ fast SSD (full node; leave growth headroom) |
| **CPU** | 4+ modern cores | 4 cores |
| **Network** | Stable broadband, preferably unmetered | Required for sync and peers |

- Use an **SSD**. Mechanical drives are generally unsuitable for a reliable full node.
- Initial sync can take **hours to days**, depending on hardware and bandwidth. Checkpoint sync accelerates the beacon client significantly.
- This stack targets a **full node + private RPC**, not an archive node (archive deployments need many terabytes of disk).

If you need ready-to-run node hardware, you can find pre-built options at [validatorstore.com](https://validatorstore.com).

---

## Security notice

> **By default, wallet RPC ports are bound to all interfaces (`0.0.0.0`) and are reachable on your local network.**

| Port | Service |
|------|---------|
| **8545** | HTTP JSON-RPC (primary wallet endpoint) |
| **8546** | WebSocket RPC |
| **3500** | Beacon HTTP API (**localhost** by default) |
| **4000** | Beacon gRPC (**localhost** by default; not needed for MetaMask) |

**Intended use**

- Trusted home or lab network, behind a normal router firewall
- Private RPC for devices you control on that LAN

**Not intended for**

- Public internet exposure
- Untrusted or shared networks without additional controls

**Do not** port-forward **8545**, **8546**, **3500**, or **4000** to the public internet. This project is a **private RPC**, not a public endpoint. The Engine API on **8551** and the beacon HTTP/gRPC APIs are bound to localhost.

Checkpoint sync trusts [checkpoint.pulsechain.com](https://checkpoint.pulsechain.com) (same URL as the official PulseChain docs). That is a trusted third party for the initial beacon state. Prysm also recommends pairing it with a weak-subjectivity checkpoint if you want extra assurance against a long-range attack.

CORS / vhosts default to `*` so LAN web wallets can reach the node. A page you visit can also call that RPC if it can reach the LAN IP — keep this on a trusted network.

The installer warns if the host itself has a public IP and UFW is not active. That is the typical VPS misconfiguration (an unauthenticated public RPC). Home machines behind NAT are fine.

LAN binding is intentional so phones and other machines on the same network can use `http://YOUR_LAN_IP:8545`. To restrict access to the host only, see [Localhost-only mode](#localhost-only-mode).

---

## Installation

### Prerequisites

- Linux host (Ubuntu 22.04 / 24.04 or Debian recommended; **amd64 or arm64**)
- `sudo` privileges
- Sufficient free space for `/blockchain`
- Outbound connectivity to pull images and sync with the network

### Install

```bash
git clone https://github.com/DavidFeder/pulsechain-rpc-node.git
cd pulsechain-rpc-node
chmod +x *.sh
./install.sh
```

### Sync status

```bash
./logs.sh
# or
./status.sh
```

- The **beacon** client typically advances quickly via [checkpoint sync](https://checkpoint.pulsechain.com).
- The **execution** client (Go-Pulse) generally takes longer to fully sync.
- The RPC may respond before the node is fully synced. Wait until both clients are healthy before relying on the endpoint for important transactions.

### Discover your LAN IP

Printed by the installer and by `./status.sh` (source address of the default route). Prefer that over `hostname -I`, which often prints Docker's `172.17.0.1` (`docker0`) first and will not work from a phone.

---

## Wallet configuration

### MetaMask

1. Open MetaMask → **Networks** → **Add network** → **Add a network manually**
2. Use the following parameters:

| Field | Value |
|-------|--------|
| Network Name | PulseChain |
| New RPC URL | `http://YOUR_LAN_IP:8545` |
| Chain ID | `369` |
| Currency Symbol | `PLS` |
| Block explorer URL | `https://scan.pulsechain.com` |

**Example:** if the node host is `192.168.1.50`, set the RPC URL to `http://192.168.1.50:8545`.

### Internet Money and other wallets

Use the same network parameters:

| Setting | Value |
|---------|--------|
| RPC URL | `http://YOUR_LAN_IP:8545` |
| Chain ID | `369` |
| Symbol | `PLS` |
| Explorer | `https://scan.pulsechain.com` |

Mobile wallets must reach the node over the **same LAN** (or a VPN you configure yourself; VPN setup is out of scope for this guide).

---

## Operations

Run the following from the project directory:

| Action | Command |
|--------|---------|
| Sync, peers, and disk | `./status.sh` |
| Follow logs (both services) | `./logs.sh` |
| Follow Go-Pulse logs | `./logs.sh geth` |
| Follow beacon logs | `./logs.sh beacon` |
| Stop | `./stop.sh` |
| Start | `./start.sh` |
| Recreate from compose (applies flag/.env changes and bounces containers) | `./restart.sh` |
| Update pinned images and recreate | `./update.sh` |
| Float on upstream `:latest` images (persists to `.env`) | `./update.sh --latest` |

Equivalent Docker Compose commands:

```bash
docker compose logs -f
docker compose down
docker compose up -d
docker compose pull && docker compose up -d
```

Chain data is stored under **`/blockchain`** and is retained when containers are stopped.

---

## Localhost-only mode

By default, **wallet** RPC binds to `0.0.0.0` (all interfaces). The Engine API (`--authrpc.addr=127.0.0.1`, port 8551) and beacon HTTP/gRPC (`BEACON_HTTP_HOST` / `BEACON_GRPC_HOST`, default `127.0.0.1`) are already host-only.

To accept wallet RPC connections **only on the host**:

1. Edit `docker-compose.yml`.
2. Under the **geth** service, change:
   - `--http.addr=0.0.0.0` → `--http.addr=127.0.0.1`
   - `--ws.addr=0.0.0.0` → `--ws.addr=127.0.0.1`
3. Apply the change (`./restart.sh` recreates containers from compose; it does not keep stale flags):

```bash
./restart.sh
```

Use `http://127.0.0.1:8545` in wallets on **that machine only**.

### LAN beacon API (optional)

Beacon REST/gRPC are not required for MetaMask. Prysm-Pulse still uses `--grpc-gateway-host` / `--rpc-host` (not `--http-host`). To expose them on the LAN, set in `.env`:

```bash
BEACON_HTTP_HOST=0.0.0.0
BEACON_GRPC_HOST=0.0.0.0
```

Then run `./restart.sh`. Keep those ports firewalled to your LAN; never port-forward them.

---

## Network ports

| Port | Protocol | Purpose | Default bind |
|------|----------|---------|--------------|
| 8545 | TCP | HTTP JSON-RPC (wallets) | `0.0.0.0` (LAN) |
| 8546 | TCP | WebSocket RPC | `0.0.0.0` (LAN) |
| 3500 | TCP | Beacon REST API | `127.0.0.1` (localhost; override with `BEACON_HTTP_HOST`) |
| 4000 | TCP | Beacon gRPC | `127.0.0.1` (localhost; override with `BEACON_GRPC_HOST`) |
| 8551 | TCP | Engine API (JWT; geth ↔ beacon) | `127.0.0.1` (localhost only) |
| 30303 | TCP/UDP | Execution P2P | Host |
| 13000 | TCP | Beacon P2P | Host |
| 12000 | UDP | Beacon P2P | Host |

**Do not** forward RPC/API ports 8545, 8546, 3500, or 4000 to the public internet.

---

## Opening P2P ports (strongly recommended)

Your node can already make **outbound** connections. That is not enough if you want a healthy, well-connected node.

To properly participate in the network you should also accept **inbound** peers. Nodes that only make outbound connections put more load on the network and usually have worse peer counts and slower sync.

**Open these ports for inbound traffic:**

| Port | Protocol | Purpose |
|------|----------|---------|
| 30303 | TCP + UDP | Go-Pulse (execution) |
| 13000 | TCP | Beacon P2P |
| 12000 | UDP | Beacon P2P |

### 1. Firewall on the node (UFW)

The install script already adds the rules if UFW is present. You can also add them manually:

```bash
sudo ufw allow 30303/tcp
sudo ufw allow 30303/udp
sudo ufw allow 13000/tcp
sudo ufw allow 12000/udp
```

### 2. Port forwarding on your router (required for inbound peers)

This is the part most people skip — and it’s the most important.

You must log into your router and forward the ports above to the local IP of the machine running the node.

- Log into your router (usually `192.168.0.1` or `192.168.1.1`)
- Find **Port Forwarding / Virtual Server / NAT**
- Forward external ports 30303, 13000, and 12000 to the same ports on your node’s local IP

**Every router is different.**  
Look up your exact make and model, or ask an AI with the model name for step-by-step instructions. We cannot give universal router instructions.

If you do not open these ports on your router, your node will mostly only connect outward and will contribute less to the network.

Opening inbound P2P is one of the highest-impact things you can do for both your own node performance and the health of PulseChain.

---

## Recommended firewall (UFW)

If you use UFW, here are sensible rules for a home node:

```bash
# Allow SSH (adjust if you use a different port)
sudo ufw allow OpenSSH

# Allow P2P (helps with peer count)
sudo ufw allow 30303/tcp
sudo ufw allow 30303/udp
sudo ufw allow 13000/tcp
sudo ufw allow 12000/udp

# Allow RPC only from your local network (edit the subnet!)
# Common home subnets: 192.168.0.0/16 or 192.168.1.0/24
sudo ufw allow from 192.168.0.0/16 to any port 8545 proto tcp comment 'Geth HTTP RPC - LAN only'
sudo ufw allow from 192.168.0.0/16 to any port 8546 proto tcp comment 'Geth WS RPC - LAN only'
sudo ufw allow from 192.168.0.0/16 to any port 3500 proto tcp comment 'Beacon HTTP API - LAN only'
sudo ufw allow from 192.168.0.0/16 to any port 4000 proto tcp comment 'Beacon gRPC - LAN only'

sudo ufw enable
sudo ufw status numbered
```

Replace `192.168.0.0/16` with your actual LAN range. Never open the RPC ports to `0.0.0.0/0` or the public internet. These examples are IPv4; if the host has global IPv6, add matching `from <your-ula>` rules or disable IPv6 on the node.

On a VPS or cloud VM, `10.0.0.0/8` (and often `172.16.0.0/12`) is the **VPC**, not a home Wi-Fi. Tighten `from` to your office/VPN prefix instead of the whole RFC1918 range.

---

## Configuration summary

| Setting | Value |
|---------|--------|
| Network | PulseChain mainnet (`--pulsechain`), chain ID `369` |
| Host data root | `/blockchain` (override with `DATA_DIR` in `.env`) |
| Execution datadir | `$DATA_DIR/execution` |
| Consensus datadir | `$DATA_DIR/consensus` |
| JWT secret | `$DATA_DIR/jwt.hex` (mode `600`) |
| Execution image | `go-pulse:v3.3.0` digest-pinned (override with `GETH_IMAGE` or `./update.sh --latest`) |
| Beacon image | `beacon-chain:v2.3.0` digest-pinned (override with `BEACON_IMAGE` or `./update.sh --latest`) |
| Beacon HTTP / gRPC | `127.0.0.1` (`BEACON_HTTP_HOST` / `BEACON_GRPC_HOST`) |
| Geth IPC | disabled (`--ipcdisable`; admin APIs are not on the host filesystem) |
| Geth cache | `1024` MB (`GETH_CACHE`) |
| File descriptors | `nofile` 65535 (container ulimit) |
| Checkpoint sync | `https://checkpoint.pulsechain.com` (trusted third party; same as official docs) |
| Restart policy | `unless-stopped` |
| Stop grace period | `5m` |
| Container logs | json-file, 50 MB × 5 files |
| Networking | `host` (aligned with official examples; simplifies P2P) |

Optional variables (`DATA_DIR`, ports, image pins) are documented in `.env.example` and are read by both Compose and the helper scripts.

---

## Troubleshooting

| Issue | Suggested action |
|-------|------------------|
| Docker permission denied | Log out and back in after install (docker group membership), or prefix commands with `sudo` |
| `address already in use` / crash loop | Another node is using ports 8545, 8546, 3500, 4000, or 8551. Stop the other process or change ports in `docker-compose.yml` |
| Beacon cannot find execution client | Confirm both containers are running and that `/blockchain/jwt.hex` exists and is shared by both |
| JWT / `401 Unauthorized` to execution | Ensure only one execution client is on port 8551 and both services use the same `/blockchain/jwt.hex`. The file must be 64 hex characters with **no newline**. Keep the host clock in sync (NTP / `timedatectl`); JWT `iat` skew also returns 401. |
| Wallet cannot connect | Verify LAN IP from `./status.sh` (not `hostname -I` / docker0), same network, host firewall rules; test `curl` against `127.0.0.1:8545` on the node. `./restart.sh` after compose edits (it recreates containers). |
| `./restart.sh` did nothing (old versions) | Current `restart.sh` uses `docker compose up -d --force-recreate`. Upgrade the scripts if an older copy only ran `up -d`. |
| Disk space pressure | Full nodes grow over time — monitor free space and use a large SSD |
| Slow sync | Prefer NVMe storage, adequate RAM, and open P2P ports where practical. On 16 GB hosts, try `GETH_CACHE=512` in `.env` if the machine swaps. |

**Health checks** (run on the node host):

```bash
./status.sh
```

`status.sh` reports container state, `eth_syncing` / block / peers, beacon sync, disk free, and the wallet RPC URL.

If `eth_syncing` returns `false`, the execution client reports that it is synced. Wait for the beacon section to report synced as well before relying on the endpoint.

---

## Repository layout

```
pulsechain-rpc-node/
├── README.md
├── LICENSE
├── docker-compose.yml    # Go-Pulse + Prysm-Pulse
├── .env.example          # DATA_DIR, ports, image pins
├── common.sh             # Shared env + docker compose helpers
├── install.sh            # One-command setup
├── status.sh             # Sync, peers, disk
├── start.sh
├── stop.sh
├── restart.sh            # Recreate from compose (applies edits)
├── logs.sh
├── update.sh             # Pull pinned images; --latest to float
├── tests/
│   ├── test_common.sh
│   ├── test_beacon_flags.sh
│   └── test_image_pins.sh
```

---

## Credits

| Resource | Link |
|----------|------|
| Go-Pulse (execution) | [gitlab.com/pulsechaincom/go-pulse](https://gitlab.com/pulsechaincom/go-pulse) |
| Prysm-Pulse (consensus) | [gitlab.com/pulsechaincom/prysm-pulse](https://gitlab.com/pulsechaincom/prysm-pulse) |
| Official mainnet documentation | [gitlab.com/pulsechaincom/pulsechain-mainnet](https://gitlab.com/pulsechaincom/pulsechain-mainnet) |
| Checkpoint sync | [checkpoint.pulsechain.com](https://checkpoint.pulsechain.com) |
| Block explorer | [scan.pulsechain.com](https://scan.pulsechain.com) |

This project is a convenience wrapper around the **official PulseChain Docker images**. It is an independent community project and is not affiliated with PulseChain Core unless otherwise stated.

---

## License

[MIT](LICENSE)
