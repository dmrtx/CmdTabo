#!/usr/bin/env bash
# Explicit maintainer integration check; uses the existing private identity.
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/.." && pwd)
source "$ROOT/signing-config.env"
bash "$ROOT/scripts/check-signing-identity.sh"
WORK=$(mktemp -d "${TMPDIR:-/tmp}/cmdtabo-signing-test.XXXXXX")
trap 'rm -rf "$WORK"' EXIT
ID=local.cmdtabo.signature-test
REQUIREMENT="identifier \"$ID\" and certificate leaf = H\"$SIGNING_CERT_SHA1\""
for variant in A B; do
  cat > "$WORK/$variant.c" <<C
#include <stdio.h>
int main(void) { puts("CmdTabo signing fixture $variant"); return 0; }
C
  clang -o "$WORK/$variant" "$WORK/$variant.c"
  codesign --force --sign "$SIGNING_CERT_SHA1" --timestamp=none --identifier "$ID" \
    --requirements "=designated => $REQUIREMENT" "$WORK/$variant"
done
! cmp -s "$WORK/A" "$WORK/B"
for variant in A B; do
  codesign --verify --strict -R "=$REQUIREMENT" "$WORK/$variant"
  codesign --display -r- "$WORK/$variant" > "$WORK/$variant.requirement" 2>/dev/null
  "$WORK/$variant"
done
cmp "$WORK/A.requirement" "$WORK/B.requirement"
codesign --verify --strict -R "$(cat "$WORK/A.requirement" | sed 's/^designated => /=/')" "$WORK/B"
codesign --verify --strict -R "$(cat "$WORK/B.requirement" | sed 's/^designated => /=/')" "$WORK/A"

# An unrelated identity, a changed identifier and modified bytes must all fail.
cp "$WORK/A" "$WORK/adhoc"
codesign --force --sign - --identifier "$ID" "$WORK/adhoc"
cp "$WORK/B" "$WORK/wrong-id"
codesign --force --sign "$SIGNING_CERT_SHA1" --timestamp=none --identifier local.cmdtabo.other "$WORK/wrong-id"
cp "$WORK/A" "$WORK/tampered"
printf '\001' | dd of="$WORK/tampered" bs=1 seek=8192 conv=notrunc 2>/dev/null
for rejected in adhoc wrong-id tampered; do
  if codesign --verify --strict -R "=$REQUIREMENT" "$WORK/$rejected" >/dev/null 2>&1; then
    echo "FAIL: $rejected unexpectedly satisfied the pinned identity." >&2
    exit 1
  fi
done
echo 'PASS: distinct builds share identity; ad hoc, wrong identifiers and altered code are rejected.'
