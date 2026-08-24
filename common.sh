#!/usr/bin/env bash
# common.sh — shared helpers for pulsechain-rpc-node scripts
# shellcheck shell=bash

_COMMON_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Load KEY=VALUE pairs from .env without executing it. Existing environment
# variables win so `DATA_DIR=/other ./install.sh` still works.
load_dotenv() {
  local file="${1:-}"
  local line key val
  [[ -n "${file}" && -f "${file}" ]] || return 0
  while IFS= read -r line || [[ -n "${line}" ]]; do
    line="${line%$'\r'}"
    [[ "${line}" =~ ^[[:space:]]*$ ]] && continue
    [[ "${line}" =~ ^[[:space:]]*# ]] && continue
    if [[ "${line}" =~ ^([A-Za-z_][A-Za-z0-9_]*)=(.*)$ ]]; then
      key="${BASH_REMATCH[1]}"
      val="${BASH_REMATCH[2]}"
      if [[ "${val}" =~ ^\"(.*)\"$ ]]; then
        val="${BASH_REMATCH[1]}"
      elif [[ "${val}" =~ ^\'(.*)\'$ ]]; then
        val="${BASH_REMATCH[1]}"
      fi
      if [[ -z "${!key+x}" ]]; then
        printf -v "${key}" '%s' "${val}"
        export "${key}"
      fi
    fi
  done < "${file}"
}

load_dotenv "${_COMMON_DIR}/.env"

# Defaults match docker-compose.yml ${VAR:-default} interpolation.
: "${DATA_DIR:=/blockchain}"
: "${HTTP_PORT:=8545}"
: "${WS_PORT:=8546}"
: "${BEACON_HTTP_PORT:=3500}"
: "${BEACON_GRPC_PORT:=4000}"
: "${GETH_IMAGE:=registry.gitlab.com/pulsechaincom/go-pulse:v3.3.0}"
: "${BEACON_IMAGE:=registry.gitlab.com/pulsechaincom/prysm-pulse/beacon-chain:v2.3.0}"
export DATA_DIR HTTP_PORT WS_PORT BEACON_HTTP_PORT BEACON_GRPC_PORT GETH_IMAGE BEACON_IMAGE

GETH_IMAGE_LATEST="registry.gitlab.com/pulsechaincom/go-pulse:latest"
BEACON_IMAGE_LATEST="registry.gitlab.com/pulsechaincom/prysm-pulse/beacon-chain:latest"

# Run docker compose with sudo only when the current user cannot talk to the daemon.
# Does NOT hide real compose errors (unlike "try docker; on any failure try sudo").
run_compose() {
  if docker info >/dev/null 2>&1; then
    docker compose "$@"
  elif command -v sudo >/dev/null 2>&1; then
    sudo --preserve-env=DATA_DIR,HTTP_PORT,WS_PORT,BEACON_HTTP_PORT,BEACON_GRPC_PORT,GETH_IMAGE,BEACON_IMAGE \
      docker compose "$@"
  else
    echo "Cannot access Docker. Install Docker, or add your user to the docker group, or re-run with sudo." >&2
    return 1
  fi
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

# True when the host itself has a publicly routable address (typical VPS).
# Home machines behind NAT usually only have RFC1918 / ULA addresses.
host_has_public_ip() {
  local addr
  while read -r addr; do
    [[ -z "${addr}" ]] && continue
    case "${addr}" in
      127.*|10.*|192.168.*|169.254.*) ;;
      172.1[6-9].*|172.2[0-9].*|172.3[0-1].*) ;;
      *) return 0 ;;
    esac
  done < <(ip -o -4 addr show up 2>/dev/null | awk '{print $4}' | cut -d/ -f1)

  while read -r addr; do
    [[ -z "${addr}" ]] && continue
    case "${addr}" in
      fc*|fd*|fe80*) ;;
      *) return 0 ;;
    esac
  done < <(ip -o -6 addr show up scope global 2>/dev/null | awk '{print $4}' | cut -d/ -f1)

  return 1
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
