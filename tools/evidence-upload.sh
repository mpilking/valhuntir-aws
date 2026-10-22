#!/usr/bin/env bash
# evidence-upload.sh <file-or-folder>... <s3-dest> — upload evidence from an
# acquisition workstation to the deployment's evidence bucket.
#
#   s3-dest   where it goes in the bucket, e.g. INC-2026-1022/laptop-01
#             (folders keep their name: ./triage -> INC-2026-1022/laptop-01/triage/...)
#   bucket    $EVIDENCE_BUCKET, else `terraform output evidence_bucket`
#
# Each file's SHA-256 is computed here, stored on the object (x-amz-meta-sha256)
# for evidence-fetch to verify on SIFT, and appended to ./evidence-upload.log.
# Needs AWS credentials allowed to s3:PutObject + the stack's KMS key, from an
# IP in evidence_upload_cidrs. Objects are WORM (Object Lock) once uploaded.
set -euo pipefail
[ $# -ge 2 ] || { sed -n '2,13p' "$0" | sed 's/^# \{0,1\}//'; exit 2; }
DEST="${*: -1}"; DEST="${DEST#/}"; DEST="${DEST%/}"
SRCS=("${@:1:$#-1}")
TF_DIR="$(cd "$(dirname "$0")/../terraform" && pwd)"
BUCKET="${EVIDENCE_BUCKET:-$(terraform -chdir="$TF_DIR" output -raw evidence_bucket)}"
LOG="$PWD/evidence-upload.log"

up() { # <local file> <key>
  local sum; sum=$(sha256sum "$1" | cut -d' ' -f1)
  echo "uploading $1 -> s3://$BUCKET/$2 ($(du -h "$1" | cut -f1))"
  aws s3 cp --only-show-errors --metadata "sha256=$sum" "$1" "s3://$BUCKET/$2"
  printf '%s\t%s\ts3://%s/%s\t%s\n' "$(date -u +%FT%TZ)" "$sum" "$BUCKET" "$2" "$1" | tee -a "$LOG"
}
for s in "${SRCS[@]}"; do
  [ "$s" = / ] || s="${s%/}"
  if [ -d "$s" ]; then
    base=$(basename "$(realpath "$s")")
    while IFS= read -r -d '' f; do up "$f" "$DEST/$base/${f#"$s"/}"; done < <(find "$s" -type f -print0 | sort -z)
  elif [ -f "$s" ]; then up "$s" "$DEST/$(basename "$s")"
  else echo "not found: $s" >&2; exit 1; fi
done
echo "Done. On SIFT:  evidence-fetch $DEST"
