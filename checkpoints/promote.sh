#!/usr/bin/env bash
#
# promote.sh <name> — mark a checkpoint validated after it passed a deploy test.
#
# Records the date and the IaC commit it was tested with, then prints the git
# commands to commit it and tag the repo as checkpoint/<name>. Deploying from
# that tag later reproduces exactly what was tested: the same AMIs and the same
# first-boot templates.
#
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
NAME="${1:?usage: promote.sh <name>}"
CP="$HERE/$NAME.json"
[ -f "$CP" ] || { echo "no such checkpoint: $CP" >&2; exit 1; }

EMPTY=$(jq -r '.amis | to_entries[] | select(.value == "") | .key' "$CP")
[ -z "$EMPTY" ] || echo "note: no AMI for: $EMPTY (that host can't be deployed from this checkpoint)" >&2
if [ -n "$(git -C "$HERE" status --porcelain -- ":(top,exclude)checkpoints/$NAME.json")" ]; then
  echo "uncommitted changes outside $NAME.json — commit what you tested first" >&2; exit 1
fi

jq --arg d "$(date -u +%F)" --arg c "$(git -C "$HERE" rev-parse HEAD)" \
  '.status = "validated" | .validated_on = $d | .iac_commit = $c' "$CP" > "$CP.tmp" && mv "$CP.tmp" "$CP"
jq '{name, status, validated_on, iac_commit, amis}' "$CP"
cat <<EOF

Now record it:
  git add checkpoints/$NAME.json
  git commit -m "Checkpoint $NAME validated"
  git tag -a checkpoint/$NAME -m "Checkpoint $NAME"
EOF
