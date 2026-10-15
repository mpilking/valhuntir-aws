#!/usr/bin/env bash
#
# install-remnux.sh — the heavy, generic REMnux install.
#
# Single-sourced: run by Packer at bake time AND by the from-base cloud-init at
# first boot. Performs the slow, deployment-independent work — the `cast` REMnux
# salt run and the Node-based remnux-mcp server. It sets NO secrets; the token
# env file and service enablement happen at first boot.
#
# Parameters via environment (with defaults):
#   REMNUX_USER  OS account          (default: remnux)
#   CAST_VER     cast release tag    (default: v1.0.22)
#   REMNUX_MODE  cast REMnux mode    (default: dedicated)
#
set -euxo pipefail

REMNUX_USER="${REMNUX_USER:-remnux}"
CAST_VER="${CAST_VER:-v1.0.22}"
REMNUX_MODE="${REMNUX_MODE:-dedicated}"

# cloud-init runs runcmd as root with no HOME set; cast needs it for its cache.
export HOME="${HOME:-/root}"

# Egress may not be wired the instant cloud-init runs (NAT/route race at boot).
# Wait for real IPv4 reachability, then retry apt operations.
wait_for_net() {
  for i in $(seq 1 30); do
    curl -4 -sS -m 10 -o /dev/null https://archive.ubuntu.com 2>/dev/null && return 0
    echo "waiting for network egress (attempt $i)..." >&2; sleep 10
  done
  return 1
}
apt_retry() {
  local n=0
  until "$@"; do
    n=$((n + 1)); [ "$n" -ge 10 ] && return 1
    echo "retrying: $* (attempt $n)" >&2; sleep 10
  done
}

wait_for_net
export DEBIAN_FRONTEND=noninteractive
apt_retry apt-get update
# No 'awscli' apt package on Ubuntu 24.04 — install AWS CLI v2 from the bundle.
apt_retry apt-get install -y jq curl unzip git python3-venv python3-pip

install_awscli_v2() {
  command -v aws >/dev/null 2>&1 && return 0
  curl -fsSL "https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip" -o /tmp/awscliv2.zip
  unzip -q -o /tmp/awscliv2.zip -d /tmp
  /tmp/aws/install --update
  rm -rf /tmp/aws /tmp/awscliv2.zip
}
install_awscli_v2

# --- OS account (must exist before the REMnux salt-states run) ---------------
id "$REMNUX_USER" >/dev/null 2>&1 || useradd -m -s /bin/bash -G sudo "$REMNUX_USER"

# --- cast + REMnux (the long salt run we want to bake) -----------------------
curl -fsSL -o /tmp/cast.deb \
  "https://github.com/ekristen/cast/releases/download/$CAST_VER/cast-$CAST_VER-linux-amd64.deb"
apt-get install -y /tmp/cast.deb
cast install remnux --mode "$REMNUX_MODE" --user "$REMNUX_USER" < /dev/null

# --- remnux-mcp server (Node) ------------------------------------------------
curl -fsSL https://deb.nodesource.com/setup_20.x | bash -
apt-get install -y nodejs
npm install -g @remnux/mcp-server

echo "install-remnux.sh complete"
