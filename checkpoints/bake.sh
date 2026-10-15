#!/usr/bin/env bash
#
# bake.sh <checkpoint> [host ...] — build a checkpoint's AMIs with Packer.
#
#   hosts: any of sift remnux opensearch windows (default: all four)
#
# Reads checkpoints/<checkpoint>.json, passes its pins/build settings to the
# Packer config in ../packer (in parallel, one builder per host), and writes each
# new AMI id into the checkpoint's "amis" block. Builds that fail leave their old
# value in place. The checkpoint stays "candidate" until deployed and validated
# (see README.md).
#
# Needs: packer, jq, AWS credentials (AWS_PROFILE), and the build network from
# ../packer/build-vpc (or SUBNET_ID=<public subnet with internet access>).
#
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(dirname "$HERE")"
NAME="${1:?usage: bake.sh <checkpoint> [sift remnux opensearch windows]}"; shift
HOSTS=("$@"); [ ${#HOSTS[@]} -eq 0 ] && HOSTS=(sift remnux opensearch windows)
CP="$HERE/$NAME.json"
PACKER="${PACKER:-packer}"; command -v "$PACKER" >/dev/null || PACKER="$HOME/.local/bin/packer"
TF="${TF:-terraform}"; command -v "$TF" >/dev/null || TF="$HOME/.local/bin/terraform"
AWS="${AWS:-aws}"; command -v "$AWS" >/dev/null || AWS="$HOME/.local/bin/aws"

[ -f "$CP" ] || { echo "no such checkpoint: $CP" >&2; exit 1; }
for h in "${HOSTS[@]}"; do
  case "$h" in sift|remnux|opensearch|windows) ;; *) echo "unknown host: $h" >&2; exit 1 ;; esac
done
REGION=$(jq -r .region "$CP")
export AWS_REGION="$REGION"

# The Windows base AMI can't be pinned ahead of time (AWS deregisters old ones);
# record the one current at bake time.
if [[ " ${HOSTS[*]} " == *" windows "* ]] && [ "$(jq -r .pins.windows_base_ami "$CP")" = "" ]; then
  WIN=$("$AWS" ssm get-parameter --name /aws/service/ami-windows-latest/Windows_Server-2022-English-Full-Base \
    --query Parameter.Value --output text)
  echo "windows_base_ami: using current Windows Server 2022 base $WIN"
  jq --arg v "$WIN" '.pins.windows_base_ami = $v' "$CP" > "$CP.tmp" && mv "$CP.tmp" "$CP"
fi

MISSING=$(jq -r '.pins | to_entries[] | select(.value == "") | .key' "$CP")
[ -z "$MISSING" ] || { echo "checkpoint has empty pins: $MISSING" >&2; exit 1; }
if jq -e '.pins | to_entries[] | select(.value == "latest")' "$CP" >/dev/null; then
  echo "checkpoint has 'latest' pins; resolve them first (new.sh writes concrete versions)" >&2; exit 1
fi

SUBNET_ID="${SUBNET_ID:-$("$TF" -chdir="$ROOT/packer/build-vpc" output -raw subnet_id 2>/dev/null || true)}"
[ -n "$SUBNET_ID" ] || { echo "no build subnet: apply packer/build-vpc or set SUBNET_ID" >&2; exit 1; }

VARS=$(mktemp --suffix=.pkrvars.json)
trap 'rm -f "$VARS"' EXIT
jq --arg subnet "$SUBNET_ID" --arg name "$NAME" \
  '.pins + .build + {checkpoint: $name, region: .region, subnet_id: $subnet}' "$CP" > "$VARS"

ONLY=$(printf '%s.amazon-ebs.%s,' $(for h in "${HOSTS[@]}"; do echo "$h $h"; done) | sed 's/,$//')
mkdir -p "$ROOT/packer/logs"
LOG="$ROOT/packer/logs/$NAME-$(date -u +%Y%m%dT%H%M%SZ).log"
echo "baking ${HOSTS[*]} for checkpoint $NAME in $SUBNET_ID (log: $LOG)"

cd "$ROOT/packer"
"$PACKER" init . >/dev/null
set +e
PACKER_NO_COLOR=1 "$PACKER" build -timestamp-ui -only="$ONLY" -var-file="$VARS" . 2>&1 | tee "$LOG"
RC=${PIPESTATUS[0]}
set -e

# Record each AMI this run produced (manifest entries carry the run's uuid).
for h in "${HOSTS[@]}"; do
  M="manifest-$h.json"
  [ -f "$M" ] || { echo "$h: no AMI (no manifest)"; continue; }
  AMI=$(jq -r '.last_run_uuid as $u | .builds[] | select(.packer_run_uuid == $u) | .artifact_id' "$M" | cut -d: -f2)
  if [ -n "$AMI" ] && grep -q "$AMI" "$LOG"; then
    jq --arg h "$h" --arg ami "$AMI" '.amis[$h] = $ami | .status = "candidate"' "$CP" > "$CP.tmp" && mv "$CP.tmp" "$CP"
    echo "$h: $AMI recorded in $(basename "$CP")"
  else
    echo "$h: no AMI from this run"
  fi
done
exit "$RC"
