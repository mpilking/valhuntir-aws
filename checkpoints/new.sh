#!/usr/bin/env bash
#
# new.sh <name> — start a new checkpoint from the newest upstream versions.
#
# Resolves every component's current latest release/commit to a concrete value
# and writes checkpoints/<name>.json (status "candidate", no AMIs yet). Then:
#   ./bake.sh <name>                         # build the AMIs
#   terraform apply -var checkpoint=<name>   # deploy + test (see README.md)
#   ./promote.sh <name>                      # mark validated, then commit + tag
# To retry a component at an older version, edit its pin before baking.
#
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
NAME="${1:?usage: new.sh <name>}"
OUT="$HERE/$NAME.json"
[ ! -e "$OUT" ] || { echo "$OUT exists" >&2; exit 1; }
REGION="${AWS_REGION:-us-east-1}"
AWS="${AWS:-aws}"; command -v "$AWS" >/dev/null || AWS="$HOME/.local/bin/aws"

gh_latest_tag() {  # github.com/<repo>/releases/latest redirects to .../tag/<tag>
  local u; u=$(curl -fsSLI -o /dev/null -w '%{url_effective}' "https://github.com/$1/releases/latest")
  echo "${u##*/}"
}
gh_head() { git ls-remote "https://github.com/$1.git" HEAD | cut -f1; }
python_latest() {  # newest 3.12.x (setup-windows.ps1's recommended series) with a Windows installer
  local v
  for v in $(curl -fsSL https://www.python.org/ftp/python/ | grep -oE 'href="3\.12\.[0-9]+/"' \
               | grep -oE '3\.12\.[0-9]+' | sort -Vr | head -15); do
    curl -fsI -o /dev/null "https://www.python.org/ftp/python/$v/python-$v-amd64.exe" && { echo "$v"; return; }
  done
}
docker_latest() {  # newest docker-ce in Docker's noble repo, e.g. 29.9.1
  curl -fsSL https://download.docker.com/linux/ubuntu/dists/noble/stable/binary-amd64/Packages \
    | awk '/^Package: docker-ce$/{p=1} p && /^Version:/{print $2; p=0}' \
    | sed -E 's/^5://; s/-1~ubuntu.*//' | sort -V | tail -1
}

echo "resolving latest versions..."
UBUNTU=$("$AWS" ec2 describe-images --region "$REGION" --owners 099720109477 \
  --filters 'Name=name,Values=ubuntu/images/hvm-ssd-gp3/ubuntu-noble-24.04-amd64-server-*' \
  --query 'sort_by(Images,&CreationDate)[-1].ImageId' --output text)
WINDOWS=$("$AWS" ssm get-parameter --region "$REGION" \
  --name /aws/service/ami-windows-latest/Windows_Server-2022-English-Full-Base --query Parameter.Value --output text)
AWSCLI=$(git ls-remote --tags https://github.com/aws/aws-cli.git 'refs/tags/2.*' \
  | sed 's#.*refs/tags/##' | grep -E '^[0-9.]+$' | sort -V | tail -1)

jq -n \
  --arg name "$NAME" --arg region "$REGION" --arg now "$(date -u +%FT%TZ)" \
  --arg ubuntu "$UBUNTU" --arg windows "$WINDOWS" --arg awscli "$AWSCLI" \
  --arg cast "$(gh_latest_tag ekristen/cast)" \
  --arg sift_saltstack "$(gh_latest_tag teamdfir/sift-saltstack)" \
  --arg sift_mcp "$(gh_head AppliedIR/sift-mcp)" \
  --arg valhuntir "$(gh_head AppliedIR/Valhuntir)" \
  --arg opensearch_mcp "$(gh_head AppliedIR/opensearch-mcp)" \
  --arg remnux_saltstack "$(gh_latest_tag REMnux/salt-states)" \
  --arg remnux_mcp "$(curl -fsSL https://registry.npmjs.org/@remnux/mcp-server/latest | jq -r .version)" \
  --arg nodejs "$(curl -fsSL https://nodejs.org/dist/index.json | jq -r '[.[] | select(.lts)][0].version | ltrimstr("v")')" \
  --arg docker "$(docker_latest)" \
  --arg wintools "$(gh_head AppliedIR/wintools-mcp)" \
  --arg git "$(gh_latest_tag git-for-windows/git)" --arg python "$(python_latest)" \
'{
  name: $name, status: "candidate",
  description: ("Newest upstream versions as of " + $now + "."),
  region: $region, validated_on: "", iac_commit: "",
  build: {sift_user: "sansforensics", sift_mode: "desktop", remnux_user: "remnux", remnux_mode: "dedicated"},
  pins: {
    ubuntu_ami: $ubuntu, windows_base_ami: $windows, awscli: $awscli, cast: $cast,
    sift_saltstack: $sift_saltstack, sift_mcp: $sift_mcp, valhuntir: $valhuntir,
    opensearch_mcp: $opensearch_mcp, pypi_exclude_newer: $now,
    remnux_saltstack: $remnux_saltstack, remnux_mcp_server: $remnux_mcp, nodejs: $nodejs,
    docker: $docker, wintools_mcp: $wintools, git_windows: $git, python_windows: $python
  },
  amis: {sift: "", remnux: "", opensearch: "", windows: ""},
  notes: []
}' > "$OUT"

EMPTY=$(jq -r '.pins | to_entries[] | select(.value == "" or .value == "null") | .key' "$OUT")
if [ -n "$EMPTY" ]; then
  echo "WARNING: could not resolve: $EMPTY — set them in $OUT before baking" >&2
fi
jq .pins "$OUT"
echo "wrote $OUT — next: ./bake.sh $NAME"
