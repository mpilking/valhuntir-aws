#!/usr/bin/env bash
#
# install-remnux.sh — the heavy, generic REMnux install.
#
# Single-sourced: run by Packer at bake time AND by the from-base cloud-init at
# first boot (checkpoint=latest). Performs the slow, deployment-independent work
# — the `cast` REMnux salt run and the Node-based remnux-mcp server. It sets NO
# secrets; the token env file and service enablement happen at first boot.
#
# Parameters via environment:
#   REMNUX_USER  OS account          (default: remnux)
#   REMNUX_MODE  cast REMnux mode    (default: dedicated)
#
# Versions — REQUIRED, no defaults (a checkpoint's pins, or the literal "latest"):
#   CAST_VER                 ekristen/cast release tag
#   REMNUX_SALTSTACK_VERSION REMnux/salt-states release (cast install remnux@<tag>)
#   NODEJS_VERSION           Node.js version from NodeSource (e.g. 22.23.1)
#   REMNUX_MCP_VERSION       npm @remnux/mcp-server version
#   AWSCLI_VERSION           AWS CLI v2 bundle version
# The versions actually installed are written to /etc/valhuntir/versions/remnux.
#
set -euxo pipefail

REMNUX_USER="${REMNUX_USER:-remnux}"
REMNUX_MODE="${REMNUX_MODE:-dedicated}"
: "${CAST_VER:?}" "${REMNUX_SALTSTACK_VERSION:?}" "${NODEJS_VERSION:?}"
: "${REMNUX_MCP_VERSION:?}" "${AWSCLI_VERSION:?}"

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
apt_retry apt-get install -y jq curl unzip git ca-certificates gnupg python3-venv python3-pip

# "latest" -> the concrete newest version, resolved once up front so the rest of
# the install is identical to a pinned one (and the record below is exact).
gh_latest_tag() {  # github.com/<repo>/releases/latest redirects to .../tag/<tag>
  local u; u=$(curl -fsSLI -o /dev/null -w '%{url_effective}' "https://github.com/$1/releases/latest")
  echo "${u##*/}"
}
[ "$CAST_VER" = latest ]                 && CAST_VER=$(gh_latest_tag ekristen/cast)
[ "$REMNUX_SALTSTACK_VERSION" = latest ] && REMNUX_SALTSTACK_VERSION=$(gh_latest_tag REMnux/salt-states)
[ "$REMNUX_MCP_VERSION" = latest ]       && REMNUX_MCP_VERSION=$(curl -fsSL https://registry.npmjs.org/@remnux/mcp-server/latest | jq -r .version)
[ "$NODEJS_VERSION" = latest ]           && NODEJS_VERSION=$(curl -fsSL https://nodejs.org/dist/index.json | jq -r '[.[] | select(.lts)][0].version | ltrimstr("v")')

install_awscli_v2() {
  command -v aws >/dev/null 2>&1 && return 0
  local v="-$AWSCLI_VERSION"; [ "$AWSCLI_VERSION" = latest ] && v=""
  curl -fsSL "https://awscli.amazonaws.com/awscli-exe-linux-x86_64$v.zip" -o /tmp/awscliv2.zip
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
# Like SIFT, a few salt states can fail on a headless cloud box without making
# the install unusable; log and continue (failed states are listed by Packer).
cast install "remnux@$REMNUX_SALTSTACK_VERSION" --mode "$REMNUX_MODE" --user "$REMNUX_USER" < /dev/null \
  || echo "WARN: cast finished with failed states (see /var/cache/cast/installer/logs/results.yaml); continuing"

# --- Node.js (NodeSource, exact version) + remnux-mcp server -----------------
# REMnux may ship its own Node; the MCP server uses this one explicitly.
NODE_MAJOR="${NODEJS_VERSION%%.*}"
install -d -m 0755 /etc/apt/keyrings
curl -fsSL https://deb.nodesource.com/gpgkey/nodesource-repo.gpg.key \
  | gpg --dearmor --yes -o /etc/apt/keyrings/nodesource.gpg
echo "deb [signed-by=/etc/apt/keyrings/nodesource.gpg] https://deb.nodesource.com/node_$NODE_MAJOR.x nodistro main" \
  > /etc/apt/sources.list.d/nodesource.list
apt_retry apt-get update
apt_retry apt-get install -y --allow-downgrades "nodejs=$NODEJS_VERSION-1nodesource1"
apt-mark hold nodejs
# Absolute paths: the REMnux salt-states may put another node/npm earlier on PATH.
/usr/bin/npm install -g "@remnux/mcp-server@$REMNUX_MCP_VERSION"
test -x /usr/bin/remnux-mcp-server   # the systemd unit's ExecStart

mkdir -p /etc/valhuntir/versions
{
  echo "cast=$CAST_VER"
  echo "remnux_saltstack=$REMNUX_SALTSTACK_VERSION"
  echo "nodejs=$(/usr/bin/node --version)"
  echo "remnux_mcp_server=$(/usr/bin/npm ls -g --depth=0 --json | jq -r '.dependencies["@remnux/mcp-server"].version')"
  echo "awscli_bootstrap=$AWSCLI_VERSION"
  echo "installed_at=$(date -u +%FT%TZ)"
} > /etc/valhuntir/versions/remnux
cat /etc/valhuntir/versions/remnux

echo "install-remnux.sh complete"
