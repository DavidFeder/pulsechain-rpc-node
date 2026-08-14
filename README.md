# pulsechain-rpc-node

Run a **PulseChain mainnet full node** and use it as a **private JSON-RPC endpoint** for MetaMask, Internet Money, and other wallets.

This project packages the official PulseChain clients in Docker Compose with a single install script. No manual client builds, no complex config for the common case.

| Component | Role | Image |
|-----------|------|-------|
| [Go-Pulse](https://gitlab.com/pulsechaincom/go-pulse) | Execution layer (JSON-RPC / WebSocket) | `registry.gitlab.com/pulsechaincom/go-pulse:latest` |
| [Prysm-Pulse](https://gitlab.com/pulsechaincom/prysm-pulse) | Consensus layer (beacon chain) | `registry.gitlab.com/pulsechaincom/prysm-pulse/beacon-chain:latest` |

**Defaults:** mainnet · checkpoint sync · data under `/blockchain` · RPC available on the LAN (`0.0.0.0`)

---

## Quick start

**Requirements:** Linux (Ubuntu 22.04 / 24.04 or Debian recommended), `sudo`, outbound internet, and a large SSD mounted where `/blockchain` will live.

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
| **Storage** | 2 TB+ NVMe SSD | 1 TB+ fast SSD (full node; leave growth headroom) |
| **CPU** | 4+ modern cores | 4 cores |
| **Network** | Stable broadband, preferably unmetered | Required for sync and peers |

- Use an **SSD**. Mechanical drives are generally unsuitable for a reliable full node.
- Initial sync can take **hours to days**, depending on hardware and bandwidth. Checkpoint sync accelerates the beacon client significantly.
- This stack targets a **full node + private RPC**, not an archive node (archive deployments need many terabytes of disk).

If you need ready-to-run node hardware, you can find pre-built options at [validatorstore.com](https://validatorstore.com).

---

## Security notice

> **By default, RPC ports are bound to all interfaces (`0.0.0.0`) and are reachable on your local network.**

| Port | Service |
|------|---------|
| **8545** | HTTP JSON-RPC (primary wallet endpoint) |
| **8546** | WebSocket RPC |
| **3500** | Beacon HTTP API |

**Intended use**

- Trusted home or lab network, behind a normal router firewall
- Private RPC for devices you control on that LAN

**Not intended for**

- Public internet exposure
- Untrusted or shared networks without additional controls

**Do not** port-forward **8545**, **8546**, or **3500** to the public internet. This project is a **private RPC**, not a public endpoint.

LAN binding is intentional so phones and other machines on the same network can use `http://YOUR_LAN_IP:8545`. To restrict access to the host only, see [Localhost-only mode](#localhost-only-mode).

---

## Installation

### Prerequisites

- Linux host (Ubuntu 22.04 / 24.04 or Debian recommended)
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

Printed by the installer. You can also run:

```bash
hostname -I | awk '{print $1}'
```

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
| Quick status + RPC check | `./status.sh` |
| Follow logs (both services) | `./logs.sh` |
| Follow Go-Pulse logs | `./logs.sh geth` |
| Follow beacon logs | `./logs.sh beacon` |
| Stop | `./stop.sh` |
| Start | `./start.sh` |
| Restart | `./restart.sh` |
| Update images and recreate | `./update.sh` |

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

By default, RPC binds to `0.0.0.0` (all interfaces). To accept connections **only on the host**:

1. Edit `docker-compose.yml`.
2. Under the **geth** service, change:
   - `--http.addr=0.0.0.0` → `--http.addr=127.0.0.1`
   - `--ws.addr=0.0.0.0` → `--ws.addr=127.0.0.1`
3. Under **beacon**, change:
   - `--grpc-gateway-host=0.0.0.0` → `--grpc-gateway-host=127.0.0.1`
   - `--rpc-host=0.0.0.0` → `--rpc-host=127.0.0.1`
4. Apply the change:

```bash
./restart.sh
```

Use `http://127.0.0.1:8545` in wallets on **that machine only**.

---

## Network ports

| Port | Protocol | Purpose | Default bind |
|------|----------|---------|--------------|
| 8545 | TCP | HTTP JSON-RPC (wallets) | `0.0.0.0` (LAN) |
| 8546 | TCP | WebSocket RPC | `0.0.0.0` (LAN) |
| 3500 | TCP | Beacon REST API | `0.0.0.0` (LAN) |
| 4000 | TCP | Beacon gRPC | `0.0.0.0` (LAN) |
| 8551 | TCP | Engine API (JWT; geth ↔ beacon) | Host-local (via `network_mode: host`) |
| 30303 | TCP/UDP | Execution P2P | Host |
| 13000 | TCP | Beacon P2P | Host |
| 12000 | UDP | Beacon P2P | Host |

**Do not** forward RPC ports 8545, 8546, or 3500 to the public internet.

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

sudo ufw enable
sudo ufw status numbered
```

Replace `192.168.0.0/16` with your actual LAN range. Never open the RPC ports to `0.0.0.0/0` or the public internet.

---

## Configuration summary

| Setting | Value |
|---------|--------|
| Network | PulseChain mainnet (`--pulsechain`), chain ID `369` |
| Host data root | `/blockchain` |
| Execution datadir | `/blockchain/execution` |
| Consensus datadir | `/blockchain/consensus` |
| JWT secret | `/blockchain/jwt.hex` |
| Checkpoint sync | `https://checkpoint.pulsechain.com` |
| Restart policy | `unless-stopped` |
| Stop grace period | `5m` |
| Networking | `host` (aligned with official examples; simplifies P2P) |

Optional variables are documented in `.env.example`. Version 1 keeps runtime flags explicit in `docker-compose.yml` for clarity and reliability.

---

## Troubleshooting

| Issue | Suggested action |
|-------|------------------|
| Docker permission denied | Log out and back in after install (docker group membership), or prefix commands with `sudo` |
| `address already in use` / crash loop | Another node is using ports 8545, 8546, 3500, 4000, or 8551. Stop the other process or change ports in `docker-compose.yml` |
| Beacon cannot find execution client | Confirm both containers are running and that `/blockchain/jwt.hex` exists and is shared by both |
| JWT / `401 Unauthorized` to execution | Ensure only one execution client is on port 8551 and both services use the same `/blockchain/jwt.hex` |
| Wallet cannot connect | Verify LAN IP, same network, host firewall rules; test `curl` against `127.0.0.1:8545` on the node |
| Disk space pressure | Full nodes grow over time — monitor free space and use a large SSD |
| Slow sync | Prefer NVMe storage, adequate RAM, and open P2P ports where practical |

**Health checks** (run on the node host):

```bash
./status.sh

# or manually:
docker compose ps
curl -s -X POST http://127.0.0.1:8545 \
  -H 'Content-Type: application/json' \
  -d '{"jsonrpc":"2.0","method":"eth_syncing","params":[],"id":1}'
```

If `eth_syncing` returns `false`, the execution client reports that it is synced.

---

## Repository layout

```
pulsechain-rpc-node/
├── README.md
├── LICENSE
├── docker-compose.yml    # Go-Pulse + Prysm-Pulse
├── .env.example          # Optional future settings
├── common.sh             # Shared docker compose helper
├── install.sh            # One-command setup
├── status.sh             # Quick status + RPC check
├── start.sh
├── stop.sh
├── restart.sh
├── logs.sh
└── update.sh
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
