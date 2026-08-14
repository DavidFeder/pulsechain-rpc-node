#!/usr/bin/env bash
# install.sh — one-command setup for pulsechain-rpc-node
# Installs Docker (if needed), prepares /blockchain, generates JWT, starts the node.
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
    info "This script needs sudo for Docker install and /blockchain setup."
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
    $SUDO usermod -aG docker "${USER}" || warn "Could not add user to docker group."
  fi
fi

# ---------------------------------------------------------------------------
# 4. Prepare /blockchain (official layout: execution + consensus + jwt)
# ---------------------------------------------------------------------------
info "Preparing data directory /blockchain ..."
$SUDO mkdir -p /blockchain/execution /blockchain/consensus
$SUDO chmod 755 /blockchain /blockchain/execution /blockchain/consensus

# Only chown when safe: empty tree or already owned by this user.
# Avoid recursive chown of multi-TB chain data on every re-run.
if [[ "${EUID}" -ne 0 ]]; then
  if [[ -z "$(ls -A /blockchain/execution 2>/dev/null || true)" ]] \
     && [[ -z "$(ls -A /blockchain/consensus 2>/dev/null || true)" ]]; then
    $SUDO chown -R "${USER}:${USER}" /blockchain 2>/dev/null || true
  else
    $SUDO chown "${USER}:${USER}" /blockchain 2>/dev/null || true
  fi
fi
ok "/blockchain is ready (execution + consensus subdirs)."

# ---------------------------------------------------------------------------
# 5. JWT secret (required for Engine API between geth and beacon)
# ---------------------------------------------------------------------------
JWT_PATH="/blockchain/jwt.hex"
if [[ -f "${JWT_PATH}" ]]; then
  ok "JWT secret already exists at ${JWT_PATH}"
else
  info "Generating JWT secret at ${JWT_PATH} ..."
  # No trailing newline (required by clients / official docs)
  openssl rand -hex 32 | tr -d '\n' | $SUDO tee "${JWT_PATH}" >/dev/null
  $SUDO chmod 644 "${JWT_PATH}"
  if [[ "${EUID}" -ne 0 ]]; then
    $SUDO chown "${USER}:${USER}" "${JWT_PATH}" 2>/dev/null || true
  fi
  # Sanity: 64 hex chars, no newline
  if [[ ! -s "${JWT_PATH}" ]] || [[ "$(wc -c < "${JWT_PATH}" | tr -d ' ')" -ne 64 ]]; then
    die "JWT secret at ${JWT_PATH} looks invalid (expected 64 hex characters)."
  fi
  ok "JWT secret created."
fi

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

PORTS_TO_CHECK=(8545 8546 3500 4000 8551 30303 13000 12000)
PORT_CONFLICTS=()
for port in "${PORTS_TO_CHECK[@]}"; do
  if check_port_in_use "${port}"; then
    PORT_CONFLICTS+=("${port}")
  fi
done
if [[ "${#PORT_CONFLICTS[@]}" -gt 0 ]]; then
  warn "These ports are already in use on this machine: ${PORT_CONFLICTS[*]}"
  warn "A full node needs them free (or you must change ports in docker-compose.yml)."
  warn "Common cause: another Geth/Prysm/PulseChain node already running."
  echo ""
  read -r -p "Continue anyway? [y/N] " reply || reply="n"
  case "${reply}" in
    y|Y|yes|YES) warn "Continuing despite port conflicts..." ;;
    *) die "Aborted due to port conflicts. Free the ports and re-run ./install.sh" ;;
  esac
fi

# ---------------------------------------------------------------------------
# 8. UFW rules (only if UFW is already installed)
# ---------------------------------------------------------------------------
if command -v ufw >/dev/null 2>&1; then
  info "UFW is installed — adding recommended rules (RPC restricted to common private ranges)..."

  # Allow P2P for better connectivity
  $SUDO ufw allow 30303/tcp comment 'PulseChain Geth P2P' >/dev/null 2>&1 || true
  $SUDO ufw allow 30303/udp comment 'PulseChain Geth P2P' >/dev/null 2>&1 || true
  $SUDO ufw allow 13000/tcp comment 'PulseChain Beacon P2P TCP' >/dev/null 2>&1 || true
  $SUDO ufw allow 12000/udp comment 'PulseChain Beacon P2P UDP' >/dev/null 2>&1 || true

  # Restrict RPC to common private LAN ranges (safe default)
  for range in 10.0.0.0/8 172.16.0.0/12 192.168.0.0/16; do
    $SUDO ufw allow from "${range}" to any port 8545 proto tcp comment 'Pulse RPC HTTP - LAN' >/dev/null 2>&1 || true
    $SUDO ufw allow from "${range}" to any port 8546 proto tcp comment 'Pulse RPC WS - LAN' >/dev/null 2>&1 || true
    $SUDO ufw allow from "${range}" to any port 3500 proto tcp comment 'Pulse Beacon API - LAN' >/dev/null 2>&1 || true
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
else
  info "UFW not found — assuming no software firewall (or it is managed elsewhere). Skipping firewall rules."
fi

# ---------------------------------------------------------------------------
# 9. Pull images + start stack
# ---------------------------------------------------------------------------
if [[ ! -f docker-compose.yml ]]; then
  die "docker-compose.yml not found in ${SCRIPT_DIR}"
fi

info "Pulling official PulseChain Docker images (this may take a few minutes)..."
run_compose pull || die "Failed to pull images. Check your internet connection and try again."

info "Starting node containers..."
run_compose up -d || die "Failed to start containers. Run: ./logs.sh"

# ---------------------------------------------------------------------------
# 10. Success message
# ---------------------------------------------------------------------------
LAN_IP="$(hostname -I 2>/dev/null | awk '{print $1}')"
if [[ -z "${LAN_IP}" ]]; then
  LAN_IP="$(ip -4 route get 1.1.1.1 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="src"){print $(i+1); exit}}')"
fi
if [[ -z "${LAN_IP}" ]]; then
  LAN_IP="YOUR_LAN_IP"
fi

echo ""
echo -e "${GREEN}${BOLD}========================================${NC}"
echo -e "${GREEN}${BOLD}  Node is starting!${NC}"
echo -e "${GREEN}${BOLD}========================================${NC}"
echo ""
echo -e "  Containers: ${BOLD}pulse-geth${NC} + ${BOLD}pulse-beacon${NC}"
echo -e "  Data dir:   ${BOLD}/blockchain${NC}  (execution + consensus)"
echo -e "  Network:    ${BOLD}PulseChain Mainnet${NC} (chain id 369)"
echo ""
echo -e "${YELLOW}${BOLD}SECURITY REMINDER${NC}"
echo -e "  RPC ports ${BOLD}8545${NC}, ${BOLD}8546${NC}, and beacon ${BOLD}3500${NC} are open on your LAN."
echo -e "  Use only on a trusted home network. ${BOLD}Do not${NC} port-forward them to the internet."
echo ""
echo -e "${BOLD}Connect MetaMask / Internet Money:${NC}"
echo -e "  Network Name:  PulseChain"
echo -e "  RPC URL:       ${CYAN}http://${LAN_IP}:8545${NC}"
echo -e "  Chain ID:      369"
echo -e "  Symbol:        PLS"
echo -e "  Explorer:      https://scan.pulsechain.com"
echo ""
echo -e "${BOLD}Useful commands (from this directory):${NC}"
echo -e "  ./logs.sh          # follow logs"
echo -e "  ./stop.sh          # stop node"
echo -e "  ./start.sh         # start node"
echo -e "  ./restart.sh       # restart node"
echo -e "  ./update.sh        # pull latest images & restart"
echo ""
echo -e "  Or:  docker compose logs -f"
echo ""
echo -e "${CYAN}Note:${NC} Initial sync can take hours to days depending on hardware and bandwidth."
echo -e "      Checkpoint sync speeds up the beacon client. Wait until both clients report as synced"
echo -e "      before relying on the RPC for transactions."
echo ""
ok "Install complete."
echo ""
