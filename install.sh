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
INSTALL_USER="$(effective_install_user)"
INSTALL_GROUP="$(effective_install_group "${INSTALL_USER}")"

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
      # Distro docker.io / containerd packages conflict with Docker CE.
      $SUDO apt-get remove -y docker.io docker-doc docker-compose docker-compose-v2 podman-docker containerd runc || true
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
      info "Waiting for the Docker daemon..."
      if wait_for_docker; then
        ok "Docker installed."
      else
        die "Docker was installed but the daemon is not responding. Try: sudo systemctl status docker"
      fi
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
      $SUDO apt-get update -y
      $SUDO apt-get install -y openssl || die "Please install openssl and re-run."
      ;;
    *)
      die "openssl is required. Please install it and re-run."
      ;;
  esac
fi

# Allow the invoking user to run docker without sudo (best-effort; needs re-login)
if [[ "${INSTALL_USER}" != "root" ]]; then
  if ! id -nG "${INSTALL_USER}" | tr ' ' '\n' | grep -qx docker; then
    info "Adding ${INSTALL_USER} to the docker group (log out/in may be required)..."
    warn "Members of the docker group can effectively become root via the Docker daemon."
    $SUDO usermod -aG docker "${INSTALL_USER}" || warn "Could not add user to docker group."
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
# Use sudo ls so a permission error cannot look like "empty".
if [[ "${INSTALL_USER}" != "root" ]]; then
  exec_listing="$($SUDO ls -A "${DATA_DIR}/execution" 2>/dev/null || true)"
  cons_listing="$($SUDO ls -A "${DATA_DIR}/consensus" 2>/dev/null || true)"
  if [[ -z "${exec_listing}" && -z "${cons_listing}" ]]; then
    $SUDO chown -R "${INSTALL_USER}:${INSTALL_GROUP}" "${DATA_DIR}" 2>/dev/null || true
  else
    $SUDO chown "${INSTALL_USER}:${INSTALL_GROUP}" "${DATA_DIR}" 2>/dev/null || true
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

read_jwt_payload() {
  local path="$1"
  if [[ -r "${path}" ]]; then
    tr -d '[:space:]' < "${path}"
  else
    $SUDO cat "${path}" 2>/dev/null | tr -d '[:space:]'
  fi
}

write_jwt_payload() {
  local path="$1"
  local payload="$2"
  printf '%s' "${payload}" | $SUDO tee "${path}" >/dev/null
}

if $SUDO test -f "${JWT_PATH}"; then
  jwt_existing="$(read_jwt_payload "${JWT_PATH}")"
  if jwt_payload_is_valid "${jwt_existing}"; then
    jwt_raw_len="$($SUDO wc -c < "${JWT_PATH}" | tr -d ' ')"
    if [[ "${jwt_raw_len}" -ne 64 ]]; then
      info "Normalizing JWT secret at ${JWT_PATH} (stripping whitespace/newlines)..."
      write_jwt_payload "${JWT_PATH}" "${jwt_existing}"
    fi
    ok "JWT secret already exists at ${JWT_PATH}"
  else
    warn "JWT secret at ${JWT_PATH} is invalid (expected 64 hex characters, no whitespace)."
    jwt_bak="${JWT_PATH}.bak.$(date +%s)"
    $SUDO mv "${JWT_PATH}" "${jwt_bak}"
    warn "Moved it aside to ${jwt_bak}"
  fi
fi

if ! $SUDO test -f "${JWT_PATH}"; then
  info "Generating JWT secret at ${JWT_PATH} ..."
  # No trailing newline (required by clients / official docs)
  jwt_new="$(openssl rand -hex 32 | tr -d '[:space:]')"
  if ! jwt_payload_is_valid "${jwt_new}"; then
    die "openssl failed to produce a 64-character hex JWT."
  fi
  write_jwt_payload "${JWT_PATH}" "${jwt_new}"
  if [[ "${INSTALL_USER}" != "root" ]]; then
    $SUDO chown "${INSTALL_USER}:${INSTALL_GROUP}" "${JWT_PATH}" 2>/dev/null || true
  fi
  if [[ ! -s "${JWT_PATH}" ]] && ! $SUDO test -s "${JWT_PATH}"; then
    die "JWT secret at ${JWT_PATH} was not written."
  fi
  jwt_written="$(read_jwt_payload "${JWT_PATH}")"
  if ! jwt_payload_is_valid "${jwt_written}"; then
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
PORTS_TO_CHECK=("${HTTP_PORT}" "${WS_PORT}" "${BEACON_HTTP_PORT}" "${BEACON_GRPC_PORT}" 8551 30303 13000 12000)
if our_stack_running; then
  ok "Existing ${GETH_CONTAINER}/${BEACON_CONTAINER} detected — re-run will refresh this stack (not a foreign port conflict)."
else
  PORT_CONFLICTS=()
  for port in "${PORTS_TO_CHECK[@]}"; do
    if port_in_use "${port}"; then
      PORT_CONFLICTS+=("${port}")
    fi
  done
  if [[ "${#PORT_CONFLICTS[@]}" -gt 0 ]]; then
    warn "These ports are already in use on this machine: ${PORT_CONFLICTS[*]}"
    warn "A full node needs them free (or you must change ports in .env / docker-compose.yml)."
    warn "Common cause: another Geth/Prysm/PulseChain node already running."
    echo ""
    if [[ "${PULSE_ALLOW_PORT_CONFLICTS:-}" == "1" ]]; then
      warn "Continuing because PULSE_ALLOW_PORT_CONFLICTS=1"
    elif confirm_yes "Continue anyway? [y/N] "; then
      warn "Continuing despite port conflicts..."
    else
      if [[ ! -t 0 ]]; then
        die "Aborted due to port conflicts (non-interactive). Free the ports, or re-run with PULSE_ALLOW_PORT_CONFLICTS=1"
      fi
      die "Aborted due to port conflicts. Free the ports and re-run ./install.sh"
    fi
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
  warn "Do not use this stack on a VPS/cloud VM unless you restrict ${HTTP_PORT}/${WS_PORT}."
  warn "On a cloud VPC, UFW rules that allow 10.0.0.0/8 expose RPC to the whole VPC, not just your home LAN."
  if ufw_is_active; then
    ok "UFW is active. Confirm RPC rules are LAN-only before relying on this node."
  else
    warn "No active UFW firewall detected."
    warn "To skip this check, re-run with PULSE_ALLOW_PUBLIC_RPC=1"
    echo ""
    if [[ "${PULSE_ALLOW_PUBLIC_RPC:-}" == "1" ]]; then
      warn "Continuing because PULSE_ALLOW_PUBLIC_RPC=1"
    elif confirm_yes "Continue anyway? [y/N] "; then
      warn "Continuing without an active host firewall..."
    else
      if [[ ! -t 0 ]]; then
        die "Aborted due to public IP without an active firewall (non-interactive). Enable a firewall or re-run with PULSE_ALLOW_PUBLIC_RPC=1"
      fi
      die "Aborted. Enable a firewall (see README) or re-run with PULSE_ALLOW_PUBLIC_RPC=1"
    fi
  fi
  echo ""
fi

# ---------------------------------------------------------------------------
# 9. UFW rules (only if UFW is already installed)
# ---------------------------------------------------------------------------
if command -v ufw >/dev/null 2>&1; then
  info "UFW is installed — adding recommended rules (RPC restricted to common private ranges)..."

  ufw_ok=0
  ufw_fail=0
  ufw_try() {
    local out=""
    if out="$($SUDO ufw allow "$@" 2>&1)"; then
      ufw_ok=$((ufw_ok + 1))
    else
      ufw_fail=$((ufw_fail + 1))
      warn "UFW command failed: $*"
      [[ -n "${out}" ]] && warn "  ${out}"
    fi
  }

  # Allow P2P for better connectivity
  ufw_try 30303/tcp comment 'PulseChain Geth P2P'
  ufw_try 30303/udp comment 'PulseChain Geth P2P'
  ufw_try 13000/tcp comment 'PulseChain Beacon P2P TCP'
  ufw_try 12000/udp comment 'PulseChain Beacon P2P UDP'

  # Restrict wallet RPC to common private LAN ranges (safe default).
  # Beacon HTTP/gRPC default to localhost; rules still help if you later bind them to the LAN.
  for range in 10.0.0.0/8 172.16.0.0/12 192.168.0.0/16; do
    ufw_try from "${range}" to any port "${HTTP_PORT}" proto tcp comment 'Pulse RPC HTTP - LAN'
    ufw_try from "${range}" to any port "${WS_PORT}" proto tcp comment 'Pulse RPC WS - LAN'
    ufw_try from "${range}" to any port "${BEACON_HTTP_PORT}" proto tcp comment 'Pulse Beacon API - LAN'
    ufw_try from "${range}" to any port "${BEACON_GRPC_PORT}" proto tcp comment 'Pulse Beacon gRPC - LAN'
  done

  if [[ "${ufw_fail}" -gt 0 ]]; then
    warn "UFW accepted ${ufw_ok} rule(s) and failed ${ufw_fail}. Check: sudo ufw status numbered"
  elif $SUDO ufw status 2>/dev/null | grep -q 'Pulse RPC HTTP'; then
    ok "UFW rules present (P2P open, RPC limited to private networks)."
  else
    warn "UFW commands succeeded (${ufw_ok}) but could not verify 'Pulse RPC HTTP' in ufw status."
    warn "If UFW is not enabled yet, the rules are stored and apply after: sudo ufw enable"
  fi
  echo ""
  warn "IMPORTANT about UFW:"
  warn "  The rules have been added, but UFW may still be inactive."
  warn "  To enable the firewall safely (after confirming SSH still works):"
  warn "    sudo ufw allow OpenSSH"
  warn "    sudo ufw enable"
  warn "  Then check: sudo ufw status numbered"
  warn "  If your home network uses a different subnet, edit the rules accordingly."
  warn "  IPv4 rules do not cover IPv6 — if the host has global IPv6, add matching rules or disable it."
  warn "  10.0.0.0/8 on a cloud VPC is the VPC, not a home LAN — tighten that range on VPS hosts."
else
  info "UFW not found — assuming no software firewall (or it is managed elsewhere). Skipping firewall rules."
fi

# ---------------------------------------------------------------------------
# 10. Pull images + start stack
# ---------------------------------------------------------------------------
if [[ ! -f docker-compose.yml ]]; then
  die "docker-compose.yml not found in ${SCRIPT_DIR}"
fi

if ! wait_for_docker; then
  die "Cannot reach the Docker daemon. Is it running?  sudo systemctl status docker"
fi

info "Pulling official PulseChain Docker images (this may take a few minutes)..."
run_compose pull || die "Failed to pull images. Check your internet connection and try again."

info "Starting node containers..."
run_compose up -d --remove-orphans || die "Failed to start containers. Run: ./logs.sh"

info "Checking that containers stayed running..."
sleep 3
if ! container_running "${GETH_CONTAINER}" || ! container_running "${BEACON_CONTAINER}"; then
  err "One or both containers are not running."
  run_compose ps || true
  die "Install did not finish cleanly. Check logs with: ./logs.sh"
fi
ok "Containers ${GETH_CONTAINER} and ${BEACON_CONTAINER} are running."

# ---------------------------------------------------------------------------
# 11. Success message
# ---------------------------------------------------------------------------
LAN_IP="$(detect_lan_ip)"

echo ""
echo -e "${GREEN}${BOLD}========================================${NC}"
echo -e "${GREEN}${BOLD}  Node is starting!${NC}"
echo -e "${GREEN}${BOLD}========================================${NC}"
echo ""
echo -e "  Containers: ${BOLD}${GETH_CONTAINER}${NC} + ${BOLD}${BEACON_CONTAINER}${NC}"
echo -e "  Data dir:   ${BOLD}${DATA_DIR}${NC}  (execution + consensus)"
echo -e "  Network:    ${BOLD}PulseChain Mainnet${NC} (chain id 369)"
echo -e "  Images:     ${BOLD}${GETH_IMAGE}${NC}"
echo -e "              ${BOLD}${BEACON_IMAGE}${NC}"
echo ""
echo -e "${YELLOW}${BOLD}SECURITY REMINDER${NC}"
echo -e "  Wallet RPC ports ${BOLD}${HTTP_PORT}${NC} and ${BOLD}${WS_PORT}${NC} are open on your LAN."
echo -e "  Beacon HTTP (${BEACON_HTTP_PORT}) and gRPC (${BEACON_GRPC_PORT}) bind ${BEACON_HTTP_HOST} / ${BEACON_GRPC_HOST}."
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
echo -e "  ./status.sh        # sync, peers, disk, wallet URL"
echo -e "  ./logs.sh          # follow logs"
echo -e "  ./stop.sh          # stop node"
echo -e "  ./start.sh         # start node"
echo -e "  ./restart.sh       # recreate containers from compose"
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
