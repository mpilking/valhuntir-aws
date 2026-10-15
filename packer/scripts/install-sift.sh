#!/usr/bin/env bash
#
# install-sift.sh — the heavy, generic SIFT install.
#
# Single-sourced: run by Packer at bake time (baked AMI) AND by the from-base
# cloud-init at first boot (when no baked AMI is used). It performs everything
# slow and deployment-independent — apt deps, XFCE/XRDP, the `cast` SANS SIFT
# salt run, and the Valhuntir sift-mcp stack. It sets NO secrets and NO
# per-case identity; those are applied at first boot by valhuntir-firstboot.sh.
#
# Parameters via environment (with defaults):
#   SIFT_USER  OS login account          (default: sansforensics)
#   CAST_VER   cast release tag          (default: v1.0.22)
#   SIFT_MODE  cast SIFT mode            (default: desktop)
#
# Version pins (defaults = the versions validated on 2026-07-12). Every input
# that would otherwise float to "latest" is pinned so a from-base boot and a
# Packer bake install exactly the same, already-tested software:
#   SIFT_SALTSTACK_VERSION  teamdfir/sift-saltstack release   (v2026.04.21)
#   SIFT_MCP_REF            AppliedIR/sift-mcp commit          (c67a860...)
#   VALHUNTIR_REF           AppliedIR/Valhuntir commit         (ce1ae36...)
#   AWSCLI_VERSION          AWS CLI v2 bundle version          (2.35.21)
#   PYPI_EXCLUDE_NEWER      resolve ALL Python deps as of this time (2026-07-12T19:00:00Z)
# PYPI_EXCLUDE_NEWER is required, not optional: sift-mcp declares open-ended deps
# (e.g. mcp>=1.26) and mcp 2.x — released after July — breaks the July code. It is
# passed to setup-sift.sh as UV_EXCLUDE_NEWER; every package it installs goes via uv.
# Note: the SIFT salt-states install their own AWS CLI (2.15.24) and make it the
# active one, so AWSCLI_VERSION only governs the CLI used before cast runs.
# Not pinned: Ubuntu apt packages, the uv binary itself, and the third-party
# reference data that the "recommended" tier downloads (RAG sources, baselines).
#
set -euxo pipefail

SIFT_USER="${SIFT_USER:-sansforensics}"
CAST_VER="${CAST_VER:-v1.0.22}"
SIFT_MODE="${SIFT_MODE:-desktop}"
SIFT_SALTSTACK_VERSION="${SIFT_SALTSTACK_VERSION:-v2026.04.21}"
SIFT_MCP_REF="${SIFT_MCP_REF:-c67a860ea70c38dc3c5243193a76f0bcbd6db18f}"
VALHUNTIR_REF="${VALHUNTIR_REF:-ce1ae368f425402545414eea50998608f4b887d7}"
AWSCLI_VERSION="${AWSCLI_VERSION:-2.35.21}"
PYPI_EXCLUDE_NEWER="${PYPI_EXCLUDE_NEWER:-2026-07-12T19:00:00Z}"

# cloud-init runs runcmd as root with no HOME set; cast needs it for its cache
# directory. Ensure HOME is defined for root-context commands (cast, etc.).
export HOME="${HOME:-/root}"

# Egress may not be wired the instant cloud-init runs (NAT/route race at boot).
# Wait for real IPv4 reachability, then retry apt operations. (No-op under Packer,
# where the build VPC already has internet.)
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
# NOTE: no 'awscli' here — that apt package was dropped in Ubuntu 24.04. We
# install AWS CLI v2 from the official bundle below.
apt_retry apt-get install -y git jq curl unzip python3-venv python3-pip \
  xfce4 xfce4-goodies xrdp libimage-exiftool-perl

# AWS CLI v2 (needed by firstboot for Secrets Manager + pull-evidence).
install_awscli_v2() {
  command -v aws >/dev/null 2>&1 && return 0
  curl -fsSL "https://awscli.amazonaws.com/awscli-exe-linux-x86_64-$AWSCLI_VERSION.zip" -o /tmp/awscliv2.zip
  unzip -q -o /tmp/awscliv2.zip -d /tmp
  /tmp/aws/install --update
  rm -rf /tmp/aws /tmp/awscliv2.zip
}
install_awscli_v2

# --- OS account (locked password; the real one is set at first boot) ---------
# Creating it now means the SIFT salt-states (which would otherwise create it
# with a well-known default password) find it present and leave it alone.
id "$SIFT_USER" >/dev/null 2>&1 || useradd -m -s /bin/bash -G sudo "$SIFT_USER"
HOME_DIR="/home/$SIFT_USER"

# Passwordless sudo — setup-sift.sh runs as this user and calls sudo internally
# (apt, samba, apparmor, the verification ledger). cloud-init has no TTY, so a
# password prompt would fail. Matches SANS SIFT's sansforensics default.
printf '%s ALL=(ALL) NOPASSWD:ALL\n' "$SIFT_USER" > "/etc/sudoers.d/90-$SIFT_USER"
chmod 440 "/etc/sudoers.d/90-$SIFT_USER"

# --- XRDP session ------------------------------------------------------------
echo "xfce4-session" > "$HOME_DIR/.xsession"
chown "$SIFT_USER":"$SIFT_USER" "$HOME_DIR/.xsession"
adduser xrdp ssl-cert || true
systemctl enable xrdp

# --- cast + SANS SIFT (the long salt run we want to bake) --------------------
curl -fsSL -o /tmp/cast.deb \
  "https://github.com/ekristen/cast/releases/download/$CAST_VER/cast-$CAST_VER-linux-amd64.deb"
apt-get install -y /tmp/cast.deb
# cast exits non-zero if ANY salt state fails. The SIFT salt-states have a few
# known non-fatal failures on a headless cloud box (upstream exiftool version-pin
# 404s; cosmetic GNOME gsettings tweaks with no dbus session). Those must not
# abort provisioning — the Valhuntir stack (setup-sift.sh) still needs to run.
# We install exiftool via apt above as a fallback. Log and continue on failure.
# "sift@<tag>" pins the salt-states release (cast matches the tag exactly and
# errors if it doesn't exist, rather than falling back to latest).
cast install "sift@$SIFT_SALTSTACK_VERSION" --mode "$SIFT_MODE" --user "$SIFT_USER" < /dev/null \
  || echo "WARN: cast finished with failed states (see /var/cache/cast/installer/logs/results.yaml); continuing"

# --- Valhuntir sift-mcp stack (install only; identity/services at first boot) -
# setup-sift.sh fetches its own code: it clones sift-mcp into ~/.vhir/src/sift-mcp
# and Valhuntir into ~/.vhir/src/vhir, or `git pull`s them if they already exist.
# Pre-clone both there, checked out *detached* at the pinned commits: setup-sift's
# `git pull` then fails on the detached HEAD and it explicitly continues with the
# existing (pinned) code. The SHAs are re-checked after the install below.
SRC_DIR="$HOME_DIR/.vhir/src"
sudo -u "$SIFT_USER" mkdir -p "$SRC_DIR"
clone_pinned() {  # <repo-url> <dest> <commit>
  if [ ! -d "$2/.git" ]; then
    sudo -u "$SIFT_USER" HOME="$HOME_DIR" git clone --quiet "$1" "$2"
  fi
  sudo -u "$SIFT_USER" HOME="$HOME_DIR" \
    git -C "$2" -c advice.detachedHead=false checkout --quiet --detach "$3"
}
clone_pinned https://github.com/AppliedIR/sift-mcp.git  "$SRC_DIR/sift-mcp" "$SIFT_MCP_REF"
clone_pinned https://github.com/AppliedIR/Valhuntir.git "$SRC_DIR/vhir"     "$VALHUNTIR_REF"
# --remote -> TLS + bind 0.0.0.0. Installs the shared venv, all packages, and
# the RAG index (also slow — worth baking). setup-sift.sh manages the gateway
# systemd unit; first boot reconfigures identity + restarts it. Pass HOME so the
# sansforensics-context install resolves paths correctly under cloud-init.
# Enable a lingering user-systemd instance BEFORE setup-sift.sh so it installs
# the gateway as a persistent user service. cloud-init has no interactive login,
# so without linger + XDG_RUNTIME_DIR setup-sift falls back to a foreground
# process that dies on logout/reboot.
loginctl enable-linger "$SIFT_USER" || true
SIFT_UID=$(id -u "$SIFT_USER")
systemctl start "user@$SIFT_UID.service" 2>/dev/null || true
for i in $(seq 1 15); do [ -S "/run/user/$SIFT_UID/systemd/private" ] && break; sleep 1; done

sudo -u "$SIFT_USER" HOME="$HOME_DIR" \
  XDG_RUNTIME_DIR="/run/user/$SIFT_UID" \
  DBUS_SESSION_BUS_ADDRESS="unix:path=/run/user/$SIFT_UID/bus" \
  VHIR_EXAMINER="$SIFT_USER" \
  UV_EXCLUDE_NEWER="$PYPI_EXCLUDE_NEWER" \
  bash "$SRC_DIR/sift-mcp/setup-sift.sh" --remote -y --recommended \
  --examiner="$SIFT_USER" --cases-dir=/cases < /dev/null
# stdin is /dev/null on purpose: setup-sift's --remote static-IP step prompts via
# input(); EOF makes it skip (exactly what happened under cloud-init in July).
# Under Packer stdin is an idle SSH channel, so without this the bake would hang.

# Fail loudly if setup-sift.sh moved either checkout off its pin.
for pair in "sift-mcp:$SIFT_MCP_REF" "vhir:$VALHUNTIR_REF"; do
  # run as the repo owner (git refuses root on another user's repo: "dubious ownership")
  have=$(sudo -u "$SIFT_USER" HOME="$HOME_DIR" git -C "$SRC_DIR/${pair%%:*}" rev-parse HEAD)
  if [ "$have" != "${pair#*:}" ]; then
    echo "ERROR: ${pair%%:*} is at $have, expected ${pair#*:}" >&2
    exit 1
  fi
  echo "pinned OK: ${pair%%:*} @ $have"
done

echo "install-sift.sh complete"
