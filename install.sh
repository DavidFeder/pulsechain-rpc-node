#!/usr/bin/env bash
# install.sh — one-command setup for pulsechain-rpc-node
# Installs Docker (if needed), prepares the data dir, generates JWT, starts the node.
# Also adds safe UFW rules if UFW is already present.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"
# shellcheck source=common.sh
source "${SCRIPT_DIR}/common.sh"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

info()  { echo -e "${CYAN}→${NC} $*"; }
ok()    { echo -e "${GREEN}✓${NC} $*"; }
warn()  { echo -e "${YELLOW}⚠${NC}  $*"; }
err()   { echo -e "${RED}✗${NC} $*" >&2; }
die()   { err "$*"; exit 1; }

echo ""
echo -e "${BOLD}========================================${NC}"
echo -e "${BOLD}  pulsechain-rpc-node installer${NC}"
echo -e "${BOLD}  PulseChain private RPC (mainnet)${NC}"
echo -e "${BOLD}========================================${NC}"
echo ""

# ---------------------------------------------------------------------------
# 1. Root / sudo check
# ---------------------------------------------------------------------------
if [[ "${EUID}" -eq 0 ]]; then
  warn "You are running as root."
  warn "This works, but running as a normal user with sudo is safer and recommended."
  echo ""
  SUDO=""
else
  if ! command -v sudo >/dev/null 2>&1; then
    die "sudo is required when not running as root. Install sudo or re-run as root."
  fi
  if ! sudo -n true 2>/dev/null; then
    info "This script needs sudo for Docker install and ${DATA_DIR} setup."
    sudo -v || die "Could not obtain sudo privileges."
  fi
  SUDO="sudo"
  # Keep sudo credential cache warm during long steps
  (while true; do sudo -n true; sleep 50; done) 2>/dev/null &
  SUDO_KEEPALIVE_PID=$!
  trap 'kill "${SUDO_KEEPALIVE_PID}" 2>/dev/null || true' EXIT
fi

# ---------------------------------------------------------------------------
# 2. Detect OS (Ubuntu/Debian focused)
# ---------------------------------------------------------------------------
if [[ -f /etc/os-release ]]; then
  # shellcheck source=/dev/null
  . /etc/os-release
  OS_ID="${ID:-unknown}"
else
  OS_ID="unknown"
fi

case "${OS_ID}" in
  ubuntu|debian|linuxmint|pop)
    ok "Detected Debian-family OS: ${OS_ID}"
    ;;
  *)
    warn "OS '${OS_ID}' is not Ubuntu/Debian. Docker install may need to be done manually."
    warn "If Docker + Compose are already installed, the rest of this script should still work."
    ;;
esac

# ---------------------------------------------------------------------------
# 3. Install Docker + Compose plugin if missing
# ---------------------------------------------------------------------------
need_docker_install=false
if ! command -v docker >/dev/null 2>&1; then
  need_docker_install=true
elif ! docker compose version >/dev/null 2>&1; then
  # Compose plugin may only be visible via sudo if group membership is pending
  if ! $SUDO docker compose version >/dev/null 2>&1; then
    need_docker_install=true
  fi
fi

if [[ "${need_docker_install}" == true ]]; then
  info "Installing Docker Engine + Compose plugin..."
  case "${OS_ID}" in
    ubuntu|debian|linuxmint|pop)
      $SUDO apt-get update -y
      $SUDO apt-get install -y ca-certificates curl gnupg openssl
      $SUDO install -m 0755 -d /etc/apt/keyrings
      if [[ ! -f /etc/apt/keyrings/docker.asc ]]; then
        # Mint/Pop use Ubuntu packages; their own Docker GPG URL may not exist
        if [[ "${OS_ID}" == "ubuntu" || "${OS_ID}" == "debian" ]]; then
          $SUDO curl -fsSL "https://download.docker.com/linux/${OS_ID}/gpg" -o /etc/apt/keyrings/docker.asc
        else
          $SUDO curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc
        fi
        $SUDO chmod a+r /etc/apt/keyrings/docker.asc
      fi
      DOCKER_DISTRO="${OS_ID}"
      DOCKER_CODENAME="${VERSION_CODENAME:-stable}"
      if [[ "${OS_ID}" != "ubuntu" && "${OS_ID}" != "debian" ]]; then
        DOCKER_DISTRO="ubuntu"
        DOCKER_CODENAME="${UBUNTU_CODENAME:-${VERSION_CODENAME:-jammy}}"
      fi
      echo \
        "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/${DOCKER_DISTRO} ${DOCKER_CODENAME} stable" \
        | $SUDO tee /etc/apt/sources.list.d/docker.list >/dev/null
      $SUDO apt-get update -y
      $SUDO apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
      $SUDO systemctl enable --now docker
      ok "Docker installed."
      ;;
    *)
      die "Automatic Docker install is only supported on Ubuntu/Debian. Install Docker manually: https://docs.docker.com/engine/install/ then re-run this script."
      ;;
  esac
else
  ok "Docker and Compose plugin already available."
fi

# Ensure openssl for JWT generation
if ! command -v openssl >/dev/null 2>&1; then
  info "Installing openssl..."
  case "${OS_ID}" in
    ubuntu|debian|linuxmint|pop)
      $SUDO apt-get update -y && $SUDO apt-get install -y openssl || die "Please install openssl and re-run."
      ;;
    *)
      die "openssl is required. Please install it and re-run."
      ;;
  esac
fi

# Allow current user to run docker without sudo (best-effort; needs re-login)
if [[ "${EUID}" -ne 0 ]]; then
  if ! id -nG "${USER}" | tr ' ' '\n' | grep -qx docker; then
    info "Adding ${USER} to the docker group (log out/in may be required)..."
    warn "Members of the docker group can effectively become root via the Docker daemon."
    $SUDO usermod -aG docker "${USER}" || warn "Could not add user to docker group."
  fi
fi

# ---------------------------------------------------------------------------
# 4. Prepare data directory (official layout: execution + consensus + jwt)
# ---------------------------------------------------------------------------
info "Preparing data directory ${DATA_DIR} ..."
$SUDO mkdir -p "${DATA_DIR}/execution" "${DATA_DIR}/consensus"
$SUDO chmod 755 "${DATA_DIR}" "${DATA_DIR}/execution" "${DATA_DIR}/consensus"

# Only chown when safe: empty tree or already owned by this user.
# Avoid recursive chown of multi-TB chain data on every re-run.
if [[ "${EUID}" -ne 0 ]]; then
  if [[ -z "$(ls -A "${DATA_DIR}/execution" 2>/dev/null || true)" ]] \
     && [[ -z "$(ls -A "${DATA_DIR}/consensus" 2>/dev/null || true)" ]]; then
    $SUDO chown -R "${USER}:${USER}" "${DATA_DIR}" 2>/dev/null || true
  else
    $SUDO chown "${USER}:${USER}" "${DATA_DIR}" 2>/dev/null || true
  fi
fi
ok "${DATA_DIR} is ready (execution + consensus subdirs)."

# Disk headroom — warn only. Official full-node guidance is ~1.5–2 TB+.
if avail_kb="$(df -Pk "${DATA_DIR}" 2>/dev/null | awk 'NR==2 {print $4}')"; then
  if [[ -n "${avail_kb}" && "${avail_kb}" =~ ^[0-9]+$ ]]; then
    avail_gb=$((avail_kb / 1024 / 1024))
    if (( avail_gb < 100 )); then
      warn "Only ${avail_gb} GB free on the filesystem that holds ${DATA_DIR}."
      warn "A PulseChain full node typically needs 1.5–2 TB+ SSD and grows over time."
    elif (( avail_gb < 1500 )); then
      warn "${avail_gb} GB free at ${DATA_DIR}. Official guidance is about 1.5–2 TB+ for a full node."
    else
      ok "${avail_gb} GB free at ${DATA_DIR}."
    fi
  fi
fi

# ---------------------------------------------------------------------------
# 5. JWT secret (required for Engine API between geth and beacon)
# ---------------------------------------------------------------------------
JWT_PATH="${DATA_DIR}/jwt.hex"
if [[ -f "${JWT_PATH}" ]]; then
  ok "JWT secret already exists at ${JWT_PATH}"
else
  info "Generating JWT secret at ${JWT_PATH} ..."
  # No trailing newline (required by clients / official docs)
  openssl rand -hex 32 | tr -d '\n' | $SUDO tee "${JWT_PATH}" >/dev/null
  if [[ "${EUID}" -ne 0 ]]; then
    $SUDO chown "${USER}:${USER}" "${JWT_PATH}" 2>/dev/null || true
  fi
  # Sanity: 64 hex chars, no newline
  if [[ ! -s "${JWT_PATH}" ]] || [[ "$(wc -c < "${JWT_PATH}" | tr -d ' ')" -ne 64 ]]; then
    die "JWT secret at ${JWT_PATH} looks invalid (expected 64 hex characters)."
  fi
  ok "JWT secret created."
fi
# Engine API credential — readable only by owner (and root).
$SUDO chmod 600 "${JWT_PATH}" 2>/dev/null || chmod 600 "${JWT_PATH}"

# ---------------------------------------------------------------------------
# 6. .env from example
# ---------------------------------------------------------------------------
if [[ ! -f .env ]]; then
  if [[ -f .env.example ]]; then
    cp .env.example .env
    ok "Created .env from .env.example"
  else
    warn ".env.example not found; continuing without .env"
  fi
else
  ok ".env already present"
fi

# ---------------------------------------------------------------------------
# 7. Port conflict pre-check (host networking shares the host's ports)
# ---------------------------------------------------------------------------
check_port_in_use() {
  local port="$1"
  if command -v ss >/dev/null 2>&1; then
    ss -lntu 2>/dev/null | awk '{print $5}' | grep -Eq "[:.]${port}$"
  elif command -v lsof >/dev/null 2>&1; then
    lsof -iTCP:"${port}" -sTCP:LISTEN >/dev/null 2>&1 \
      || lsof -iUDP:"${port}" >/dev/null 2>&1
  else
    return 1
  fi
}

PORTS_TO_CHECK=("${HTTP_PORT}" "${WS_PORT}" "${BEACON_HTTP_PORT}" "${BEACON_GRPC_PORT}" 8551 30303 13000 12000)
PORT_CONFLICTS=()
for port in "${PORTS_TO_CHECK[@]}"; do
  if check_port_in_use "${port}"; then
    PORT_CONFLICTS+=("${port}")
  fi
done
if [[ "${#PORT_CONFLICTS[@]}" -gt 0 ]]; then
  warn "These ports are already in use on this machine: ${PORT_CONFLICTS[*]}"
  warn "A full node needs them free (or you must change ports in .env / docker-compose.yml)."
  warn "Common cause: another Geth/Prysm/PulseChain node already running."
  echo ""
  if confirm_yes "Continue anyway? [y/N] "; then
    warn "Continuing despite port conflicts..."
  else
    if [[ ! -t 0 ]]; then
      die "Aborted due to port conflicts (non-interactive). Free the ports and re-run ./install.sh"
    fi
    die "Aborted due to port conflicts. Free the ports and re-run ./install.sh"
  fi
fi

# ---------------------------------------------------------------------------
# 8. Public-IP / firewall preflight
# ---------------------------------------------------------------------------
ufw_is_active() {
  command -v ufw >/dev/null 2>&1 || return 1
  $SUDO ufw status 2>/dev/null | grep -qi '^Status: active'
}

if host_has_public_ip; then
  echo ""
  warn "This machine appears to have a public IP address on a local interface."
  warn "RPC binds to 0.0.0.0 — without a firewall this is a public unauthenticated endpoint."
  warn "Do not use this stack on a VPS/cloud VM unless you restrict ${HTTP_PORT}/${WS_PORT}/${BEACON_HTTP_PORT}/${BEACON_GRPC_PORT}."
  if ufw_is_active; then
    ok "UFW is active. Confirm RPC rules are LAN-only before relying on this node."
  else
    warn "No active UFW firewall detected."
    echo ""
    if [[ -t 0 ]]; then
      if ! confirm_yes "Continue anyway? [y/N] "; then
        die "Aborted. Enable a firewall (see README) or run on a LAN-only host."
      fi
      warn "Continuing without an active host firewall..."
    else
      warn "Non-interactive session — continuing, but this is unsafe on a public host."
    fi
  fi
  echo ""
fi

# ---------------------------------------------------------------------------
# 9. UFW rules (only if UFW is already installed)
# ---------------------------------------------------------------------------
if command -v ufw >/dev/null 2>&1; then
  info "UFW is installed — adding recommended rules (RPC restricted to common private ranges)..."

  # Allow P2P for better connectivity
  $SUDO ufw allow 30303/tcp comment 'PulseChain Geth P2P' >/dev/null 2>&1 || true
  $SUDO ufw allow 30303/udp comment 'PulseChain Geth P2P' >/dev/null 2>&1 || true
  $SUDO ufw allow 13000/tcp comment 'PulseChain Beacon P2P TCP' >/dev/null 2>&1 || true
  $SUDO ufw allow 12000/udp comment 'PulseChain Beacon P2P UDP' >/dev/null 2>&1 || true

  # Restrict RPC / beacon APIs to common private LAN ranges (safe default)
  for range in 10.0.0.0/8 172.16.0.0/12 192.168.0.0/16; do
    $SUDO ufw allow from "${range}" to any port "${HTTP_PORT}" proto tcp comment 'Pulse RPC HTTP - LAN' >/dev/null 2>&1 || true
    $SUDO ufw allow from "${range}" to any port "${WS_PORT}" proto tcp comment 'Pulse RPC WS - LAN' >/dev/null 2>&1 || true
    $SUDO ufw allow from "${range}" to any port "${BEACON_HTTP_PORT}" proto tcp comment 'Pulse Beacon API - LAN' >/dev/null 2>&1 || true
    $SUDO ufw allow from "${range}" to any port "${BEACON_GRPC_PORT}" proto tcp comment 'Pulse Beacon gRPC - LAN' >/dev/null 2>&1 || true
  done

  ok "UFW rules added (P2P open, RPC limited to private networks)."
  echo ""
  warn "IMPORTANT about UFW:"
  warn "  The rules have been added, but UFW may still be inactive."
  warn "  To enable the firewall safely (after confirming SSH still works):"
  warn "    sudo ufw allow OpenSSH"
  warn "    sudo ufw enable"
  warn "  Then check: sudo ufw status numbered"
  warn "  If your home network uses a different subnet, edit the rules accordingly."
  warn "  IPv4 rules do not cover IPv6 — if the host has global IPv6, add matching rules or disable it."
else
  info "UFW not found — assuming no software firewall (or it is managed elsewhere). Skipping firewall rules."
fi

# ---------------------------------------------------------------------------
# 10. Pull images + start stack
# ---------------------------------------------------------------------------
if [[ ! -f docker-compose.yml ]]; then
  die "docker-compose.yml not found in ${SCRIPT_DIR}"
fi

info "Pulling official PulseChain Docker images (this may take a few minutes)..."
run_compose pull || die "Failed to pull images. Check your internet connection and try again."

info "Starting node containers..."
run_compose up -d || die "Failed to start containers. Run: ./logs.sh"

# ---------------------------------------------------------------------------
# 11. Success message
# ---------------------------------------------------------------------------
LAN_IP="$(detect_lan_ip)"

echo ""
echo -e "${GREEN}${BOLD}========================================${NC}"
echo -e "${GREEN}${BOLD}  Node is starting!${NC}"
echo -e "${GREEN}${BOLD}========================================${NC}"
echo ""
echo -e "  Containers: ${BOLD}pulse-geth${NC} + ${BOLD}pulse-beacon${NC}"
echo -e "  Data dir:   ${BOLD}${DATA_DIR}${NC}  (execution + consensus)"
echo -e "  Network:    ${BOLD}PulseChain Mainnet${NC} (chain id 369)"
echo -e "  Images:     ${BOLD}${GETH_IMAGE}${NC}"
echo -e "              ${BOLD}${BEACON_IMAGE}${NC}"
echo ""
echo -e "${YELLOW}${BOLD}SECURITY REMINDER${NC}"
echo -e "  RPC ports ${BOLD}${HTTP_PORT}${NC}, ${BOLD}${WS_PORT}${NC}, beacon ${BOLD}${BEACON_HTTP_PORT}${NC}, and gRPC ${BOLD}${BEACON_GRPC_PORT}${NC} are open on your LAN."
echo -e "  Engine API (8551) is localhost-only. Use only on a trusted home network."
echo -e "  ${BOLD}Do not${NC} port-forward RPC/API ports to the internet."
echo ""
echo -e "${BOLD}Connect MetaMask / Internet Money:${NC}"
echo -e "  Network Name:  PulseChain"
echo -e "  RPC URL:       ${CYAN}http://${LAN_IP}:${HTTP_PORT}${NC}"
echo -e "  Chain ID:      369"
echo -e "  Symbol:        PLS"
echo -e "  Explorer:      https://scan.pulsechain.com"
echo ""
echo -e "${BOLD}Useful commands (from this directory):${NC}"
echo -e "  ./status.sh        # sync, peers, disk"
echo -e "  ./logs.sh          # follow logs"
echo -e "  ./stop.sh          # stop node"
echo -e "  ./start.sh         # start node"
echo -e "  ./restart.sh       # apply compose changes / restart"
echo -e "  ./update.sh        # pull pinned images & recreate"
echo ""
echo -e "  Or:  docker compose logs -f"
echo ""
echo -e "${CYAN}Note:${NC} Initial sync can take hours to days depending on hardware and bandwidth."
echo -e "      Checkpoint sync speeds up the beacon client. Wait until both clients report as synced"
echo -e "      before relying on the RPC for transactions."
echo ""
ok "Install complete."
echo ""
