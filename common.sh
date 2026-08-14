#!/usr/bin/env bash
# common.sh — shared helpers for pulsechain-rpc-node scripts
# shellcheck shell=bash

# Run docker compose with sudo only when the current user cannot talk to the daemon.
# Does NOT hide real compose errors (unlike "try docker; on any failure try sudo").
run_compose() {
  if docker info >/dev/null 2>&1; then
    docker compose "$@"
  elif command -v sudo >/dev/null 2>&1; then
    sudo docker compose "$@"
  else
    echo "Cannot access Docker. Install Docker, or add your user to the docker group, or re-run with sudo." >&2
    return 1
  fi
}
