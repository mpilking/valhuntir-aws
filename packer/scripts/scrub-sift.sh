#!/usr/bin/env bash
#
# scrub-sift.sh — final Packer step before the SIFT AMI is captured.
#
# setup-sift.sh generates per-install secrets (gateway CA + TLS key with the
# builder's IP in the SAN, and the gateway bearer token). Baked into an AMI they
# would be shared by every instance — and the cert would name the wrong IP. This
# removes them so valhuntir-firstboot.sh creates fresh ones on each instance.
#
# Fail-closed ordering matters: the gateway treats an EMPTY api_keys map as
# "auth disabled", so it is disabled here and only re-enabled by firstboot
# after a token has been written.
#
set -euxo pipefail

SIFT_USER="${SIFT_USER:-sansforensics}"
HOME_DIR="/home/$SIFT_USER"
SIFT_UID=$(id -u "$SIFT_USER")
VENV_PY="$HOME_DIR/.vhir/venv/bin/python"
GW_CONFIG="$HOME_DIR/.vhir/gateway.yaml"

# --- 1. Gateway must not start from the image --------------------------------
sudo -u "$SIFT_USER" XDG_RUNTIME_DIR="/run/user/$SIFT_UID" \
  systemctl --user disable --now vhir-gateway || true
pkill -u "$SIFT_USER" -f sift_gateway || true

# --- 2. Per-instance secrets and identity ------------------------------------
rm -rf "$HOME_DIR/.vhir/tls"
sudo -u "$SIFT_USER" "$VENV_PY" - "$GW_CONFIG" <<'PY'
import sys, yaml
path = sys.argv[1]
with open(path) as f:
    cfg = yaml.safe_load(f) or {}
cfg["api_keys"] = {}
with open(path, "w") as f:
    yaml.safe_dump(cfg, f, sort_keys=False)
PY
rm -f "$HOME_DIR/.vhir/network.yaml"   # static-IP choice is per instance
# No approval password should exist yet (it is only set interactively).
if [ -n "$(ls -A /var/lib/vhir/passwords 2>/dev/null)" ]; then
  echo "ERROR: an approval password is present; refusing to bake it" >&2
  exit 1
fi

# --- 3. Image hygiene ---------------------------------------------------------
rm -f /etc/ssh/ssh_host_*                                          # regenerated per instance
rm -f /home/ubuntu/.ssh/authorized_keys /root/.ssh/authorized_keys # Packer's temporary key
rm -f /root/.bash_history /home/*/.bash_history
apt-get clean
cloud-init clean --logs --machine-id --seed                        # re-run user-data on launch

echo "scrub-sift.sh complete"
