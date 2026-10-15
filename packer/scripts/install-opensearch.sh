#!/usr/bin/env bash
#
# install-opensearch.sh — the generic OpenSearch-host install.
#
# Single-sourced: run by Packer at bake time AND by the from-base cloud-init at
# first boot (checkpoint=latest). Installs Docker and upstream's own OpenSearch
# deployment (AppliedIR/opensearch-mcp: docker/docker-compose.yml and
# scripts/setup-opensearch.sh) and pre-pulls the image. It sets NO secrets and
# starts nothing: the admin password is applied when first boot runs
# setup-opensearch.sh, which initialises the cluster on the data volume.
#
# Versions — REQUIRED, no defaults (a checkpoint's pins, or the literal "latest"):
#   OPENSEARCH_MCP_REF  AppliedIR/opensearch-mcp commit (fixes the OpenSearch
#                       image version via its docker-compose.yml)
#   DOCKER_VERSION      docker-ce version, e.g. 29.6.1
#   AWSCLI_VERSION      AWS CLI v2 bundle version
# The versions actually installed are written to /etc/valhuntir/versions/opensearch.
#
set -euxo pipefail

: "${OPENSEARCH_MCP_REF:?}" "${DOCKER_VERSION:?}" "${AWSCLI_VERSION:?}"
export HOME="${HOME:-/root}"
SRC=/opt/vhir/opensearch-mcp

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
# python3-yaml: setup-opensearch.sh reads its config with python3 + yaml.
apt_retry apt-get install -y jq curl unzip git ca-certificates gnupg python3 python3-yaml openssl

[ "$OPENSEARCH_MCP_REF" = latest ] && OPENSEARCH_MCP_REF=$(git ls-remote https://github.com/AppliedIR/opensearch-mcp.git HEAD | cut -f1)

install_awscli_v2() {
  command -v aws >/dev/null 2>&1 && return 0
  local v="-$AWSCLI_VERSION"; [ "$AWSCLI_VERSION" = latest ] && v=""
  curl -fsSL "https://awscli.amazonaws.com/awscli-exe-linux-x86_64$v.zip" -o /tmp/awscliv2.zip
  unzip -q -o /tmp/awscliv2.zip -d /tmp
  /tmp/aws/install --update
  rm -rf /tmp/aws /tmp/awscliv2.zip
}
install_awscli_v2

# --- Docker CE from Docker's apt repo (keeps every past version) ---------------
install -d -m 0755 /etc/apt/keyrings
curl -fsSL https://download.docker.com/linux/ubuntu/gpg | gpg --dearmor --yes -o /etc/apt/keyrings/docker.gpg
echo "deb [arch=amd64 signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu noble stable" \
  > /etc/apt/sources.list.d/docker.list
apt_retry apt-get update
if [ "$DOCKER_VERSION" = latest ]; then
  apt_retry apt-get install -y docker-ce docker-ce-cli containerd.io docker-compose-plugin
else
  V="5:$DOCKER_VERSION-1~ubuntu.24.04~noble"
  apt_retry apt-get install -y "docker-ce=$V" "docker-ce-cli=$V" containerd.io docker-compose-plugin
  apt-mark hold docker-ce docker-ce-cli
fi
systemctl enable --now docker

# OpenSearch needs a larger mmap count than Ubuntu's default.
echo "vm.max_map_count=262144" > /etc/sysctl.d/99-opensearch.conf
sysctl -w vm.max_map_count=262144

# --- Upstream deployment, pinned -------------------------------------------------
if [ ! -d "$SRC/.git" ]; then
  git clone --quiet https://github.com/AppliedIR/opensearch-mcp.git "$SRC"
fi
git -C "$SRC" -c advice.detachedHead=false checkout --quiet --detach "$OPENSEARCH_MCP_REF"
docker compose -f "$SRC/docker/docker-compose.yml" pull   # image baked into the AMI
IMAGE=$(docker compose -f "$SRC/docker/docker-compose.yml" config --images | head -1)

mkdir -p /etc/valhuntir/versions
{
  echo "opensearch_mcp=$OPENSEARCH_MCP_REF"
  echo "docker=$(docker version --format '{{.Server.Version}}')"
  echo "compose=$(docker compose version --short)"
  echo "opensearch_image=$IMAGE@$(docker image inspect --format '{{index .RepoDigests 0}}' "$IMAGE" | cut -d@ -f2)"
  echo "awscli_bootstrap=$AWSCLI_VERSION"
  echo "installed_at=$(date -u +%FT%TZ)"
} > /etc/valhuntir/versions/opensearch
cat /etc/valhuntir/versions/opensearch

echo "install-opensearch.sh complete"
