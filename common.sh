#!/usr/bin/env bash
# common.sh — shared helpers for pulsechain-rpc-node scripts
# shellcheck shell=bash

_COMMON_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

GETH_IMAGE_PINNED="registry.gitlab.com/pulsechaincom/go-pulse:v3.3.0@sha256:d2f59592244decca2d1f53b5c8a1d2f7b26cf25d0722118567cc8978b44e526f"
BEACON_IMAGE_PINNED="registry.gitlab.com/pulsechaincom/prysm-pulse/beacon-chain:v2.3.0@sha256:31b44010a9e1ed35125541c4347bae8d343ea98e792651d48d595e610f4d1d78"
GETH_IMAGE_LATEST="registry.gitlab.com/pulsechaincom/go-pulse:latest"
BEACON_IMAGE_LATEST="registry.gitlab.com/pulsechaincom/prysm-pulse/beacon-chain:latest"
export GETH_IMAGE_LATEST BEACON_IMAGE_LATEST
GETH_CONTAINER="pulse-geth"
BEACON_CONTAINER="pulse-beacon"

# Env keys interpolated by docker-compose.yml / passed through sudo.
COMPOSE_ENV_KEYS="DATA_DIR,HTTP_PORT,WS_PORT,BEACON_HTTP_PORT,BEACON_GRPC_PORT,BEACON_HTTP_HOST,BEACON_GRPC_HOST,GETH_IMAGE,BEACON_IMAGE,GETH_CACHE"

_trim() {
  local s="$1"
  s="${s#"${s%%[![:space:]]*}"}"
  s="${s%"${s##*[![:space:]]}"}"
  printf '%s' "${s}"
}

# Load KEY=VALUE pairs from .env without executing it. Existing environment
# variables win so `DATA_DIR=/other ./install.sh` still works.
# Accepts optional "export ", optional spaces around "=", and unquoted inline comments.
load_dotenv() {
  local file="${1:-}"
  local line key val rest quoted
  [[ -n "${file}" && -f "${file}" ]] || return 0
  while IFS= read -r line || [[ -n "${line}" ]]; do
    line="${line%$'\r'}"
    [[ "${line}" =~ ^[[:space:]]*$ ]] && continue
    [[ "${line}" =~ ^[[:space:]]*# ]] && continue
    rest="${line}"
    if [[ "${rest}" =~ ^[[:space:]]*export[[:space:]]+ ]]; then
      rest="${rest#*export}"
      rest="${rest#"${rest%%[![:space:]]*}"}"
    fi
    if [[ "${rest}" =~ ^([A-Za-z_][A-Za-z0-9_]*)[[:space:]]*=[[:space:]]*(.*)$ ]]; then
      key="${BASH_REMATCH[1]}"
      val="${BASH_REMATCH[2]}"
      quoted=0
      if [[ "${val}" =~ ^\"(.*)\"[[:space:]]*(#.*)?$ ]]; then
        val="${BASH_REMATCH[1]}"
        quoted=1
      elif [[ "${val}" =~ ^\'(.*)\'[[:space:]]*(#.*)?$ ]]; then
        val="${BASH_REMATCH[1]}"
        quoted=1
      fi
      if [[ "${quoted}" -eq 0 && "${val}" == *" #"* ]]; then
        val="${val%% #*}"
      fi
      val="$(_trim "${val}")"
      if [[ -z "${!key+x}" ]]; then
        printf -v "${key}" '%s' "${val}"
        export "${key?}"
      fi
    elif [[ "${line}" == *"="* ]]; then
      echo "load_dotenv: skipped line (expected KEY=VALUE): ${line}" >&2
    fi
  done < "${file}"
}

# Set or uncomment KEY=VALUE in a dotenv file. Preserves other lines.
upsert_dotenv() {
  local file="$1"
  local key="$2"
  local value="$3"
  local tmp line replaced=0

  if [[ ! -f "${file}" ]]; then
    printf '%s=%s\n' "${key}" "${value}" > "${file}"
    return 0
  fi

  tmp="$(mktemp)"
  while IFS= read -r line || [[ -n "${line}" ]]; do
    if [[ "${line}" =~ ^[[:space:]]*#?[[:space:]]*${key}= ]]; then
      if [[ "${replaced}" -eq 0 ]]; then
        printf '%s=%s\n' "${key}" "${value}"
        replaced=1
      fi
    else
      printf '%s\n' "${line}"
    fi
  done < "${file}" > "${tmp}"
  if [[ "${replaced}" -eq 0 ]]; then
    printf '%s=%s\n' "${key}" "${value}" >> "${tmp}"
  fi
  cat "${tmp}" > "${file}"
  rm -f "${tmp}"
}

load_dotenv "${_COMMON_DIR}/.env"

# Defaults match docker-compose.yml ${VAR:-default} interpolation.
# Empty values (HTTP_PORT=) are treated as unset so scripts and Compose agree.
[[ -n "${DATA_DIR:-}" ]] || DATA_DIR=/blockchain
[[ -n "${HTTP_PORT:-}" ]] || HTTP_PORT=8545
[[ -n "${WS_PORT:-}" ]] || WS_PORT=8546
[[ -n "${BEACON_HTTP_PORT:-}" ]] || BEACON_HTTP_PORT=3500
[[ -n "${BEACON_GRPC_PORT:-}" ]] || BEACON_GRPC_PORT=4000
[[ -n "${BEACON_HTTP_HOST:-}" ]] || BEACON_HTTP_HOST=127.0.0.1
[[ -n "${BEACON_GRPC_HOST:-}" ]] || BEACON_GRPC_HOST=127.0.0.1
[[ -n "${GETH_CACHE:-}" ]] || GETH_CACHE=1024
[[ -n "${GETH_IMAGE:-}" ]] || GETH_IMAGE="${GETH_IMAGE_PINNED}"
[[ -n "${BEACON_IMAGE:-}" ]] || BEACON_IMAGE="${BEACON_IMAGE_PINNED}"
export DATA_DIR HTTP_PORT WS_PORT BEACON_HTTP_PORT BEACON_GRPC_PORT
export BEACON_HTTP_HOST BEACON_GRPC_HOST GETH_CACHE GETH_IMAGE BEACON_IMAGE

# Cache how we talk to Docker so we do not run `docker info` on every call.
_DOCKER_MODE=""

_detect_docker_mode() {
  if docker info >/dev/null 2>&1; then
    _DOCKER_MODE=direct
    return 0
  fi
  if command -v sudo >/dev/null 2>&1 && sudo docker info >/dev/null 2>&1; then
    _DOCKER_MODE=sudo
    return 0
  fi
  _DOCKER_MODE=none
  return 1
}

wait_for_docker() {
  local i
  _DOCKER_MODE=""
  for ((i = 1; i <= 30; i++)); do
    if _detect_docker_mode; then
      return 0
    fi
    sleep 1
  done
  return 1
}

# Run docker with sudo only when the current user cannot talk to the daemon.
run_docker() {
  if [[ -z "${_DOCKER_MODE}" ]]; then
    _detect_docker_mode || true
  fi
  case "${_DOCKER_MODE}" in
    direct) docker "$@" ;;
    sudo)
      sudo --preserve-env="${COMPOSE_ENV_KEYS}" docker "$@"
      ;;
    *)
      echo "Cannot access Docker. Install Docker, or add your user to the docker group, or re-run with sudo." >&2
      return 1
      ;;
  esac
}

run_compose() {
  run_docker compose "$@"
}

container_running() {
  local name="$1"
  local state=""
  state="$(run_docker inspect -f '{{.State.Running}}' "${name}" 2>/dev/null || true)"
  [[ "${state}" == "true" ]]
}

our_stack_running() {
  container_running "${GETH_CONTAINER}" || container_running "${BEACON_CONTAINER}"
}

# True when TCP or UDP sport is bound on the host.
port_in_use() {
  local port="$1"
  [[ "${port}" =~ ^[0-9]+$ ]] || return 1
  if command -v ss >/dev/null 2>&1; then
    [[ -n "$(ss -H -ltn "sport = :${port}" 2>/dev/null)" ]] && return 0
    [[ -n "$(ss -H -lun "sport = :${port}" 2>/dev/null)" ]] && return 0
    return 1
  fi
  if command -v lsof >/dev/null 2>&1; then
    lsof -iTCP:"${port}" -sTCP:LISTEN >/dev/null 2>&1 && return 0
    lsof -iUDP:"${port}" >/dev/null 2>&1 && return 0
    return 1
  fi
  return 1
}

# Prefer the source address of the default route over `hostname -I` (which can
# be docker0, a VPN, or an unexpected first interface).
detect_lan_ip() {
  local ip=""
  ip="$(ip -4 route get 1.1.1.1 2>/dev/null | awk '{for (i = 1; i <= NF; i++) if ($i == "src") { print $(i + 1); exit }}')"
  if [[ -z "${ip}" ]]; then
    ip="$(hostname -I 2>/dev/null | awk '{print $1}')"
  fi
  printf '%s\n' "${ip:-YOUR_LAN_IP}"
}

# Loopback, RFC1918, link-local, and CGNAT (100.64.0.0/10) are not "public".
is_nonpublic_ipv4() {
  local addr="$1"
  case "${addr}" in
    127.*|10.*|192.168.*|169.254.*) return 0 ;;
    172.1[6-9].*|172.2[0-9].*|172.3[0-1].*) return 0 ;;
    100.6[4-9].*|100.[7-9][0-9].*|100.1[01][0-9].*|100.12[0-7].*) return 0 ;;
    *) return 1 ;;
  esac
}

is_public_ipv4() {
  [[ -n "${1:-}" ]] || return 1
  if is_nonpublic_ipv4 "$1"; then
    return 1
  fi
  return 0
}

# True when the host itself has a publicly routable IPv4 address (typical VPS).
# IPv6 is ignored: wallet listeners bind 0.0.0.0, so dual-stack home fiber
# must not trigger the installer warning. CGNAT (100.64.0.0/10) is not public.
host_has_public_ip() {
  local addr
  while read -r addr; do
    [[ -z "${addr}" ]] && continue
    if is_public_ipv4 "${addr}"; then
      return 0
    fi
  done < <(ip -o -4 addr show up 2>/dev/null | awk '{print $4}' | cut -d/ -f1)
  return 1
}

effective_install_user() {
  if [[ "${EUID}" -eq 0 && -n "${SUDO_USER:-}" && "${SUDO_USER}" != "root" ]]; then
    printf '%s\n' "${SUDO_USER}"
    return 0
  fi
  id -un
}

effective_install_group() {
  local user="$1"
  id -gn "${user}"
}

# Canonical JWT payload: 64 hex chars, no whitespace.
jwt_payload() {
  tr -d '[:space:]' < "$1"
}

jwt_payload_is_valid() {
  local payload="$1"
  [[ "${#payload}" -eq 64 && "${payload}" =~ ^[0-9a-fA-F]{64}$ ]]
}

confirm_yes() {
  local prompt="$1"
  local reply=""
  if [[ ! -t 0 ]]; then
    return 1
  fi
  read -r -p "${prompt}" reply || reply="n"
  case "${reply}" in
    y|Y|yes|YES) return 0 ;;
    *) return 1 ;;
  esac
}

os_is_debian_family() {
  local os_id="${1:-}"
  case "${os_id}" in
    ubuntu|debian|linuxmint|pop) return 0 ;;
    *) return 1 ;;
  esac
}

# Omarchy (https://omarchy.org) is Arch-based. Stock images still report ID=arch,
# so also look for Omarchy tools and install paths.
os_is_omarchy() {
  local os_id="${1:-}"
  [[ "${os_id}" == "omarchy" ]] && return 0
  command -v omarchy-pkg-add >/dev/null 2>&1 && return 0
  command -v omarchy >/dev/null 2>&1 && return 0
  [[ -f /etc/profile.d/omarchy.sh ]] && return 0
  [[ -d /usr/share/omarchy ]] && return 0
  [[ -d "${HOME}/.local/share/omarchy" ]] && return 0
  [[ -n "${OMARCHY_PATH:-}" && -e "${OMARCHY_PATH}" ]] && return 0
  return 1
}

os_is_arch_family() {
  local os_id="${1:-}"
  local id_like="${2:-}"
  case "${os_id}" in
    arch|omarchy) return 0 ;;
  esac
  [[ "${id_like}" == *arch* ]] && return 0
  [[ -f /etc/arch-release ]] && return 0
  return 1
}
