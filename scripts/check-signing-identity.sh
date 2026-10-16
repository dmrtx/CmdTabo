#!/usr/bin/env bash
# Read-only preflight. A missing identity must never generate a replacement key.
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/.." && pwd)
source "$ROOT/signing-config.env"
KEYCHAIN="$HOME/Library/Keychains/login.keychain-db"
WORK=$(mktemp -d "${TMPDIR:-/tmp}/cmdtabo-identity.XXXXXX")
trap 'rm -rf "$WORK"' EXIT

fail() {
  echo 'The pinned CmdTabo signing identity is unavailable. Restore the original certificate and private key from your secure backup; do not generate a replacement.' >&2
  exit 1
}

security find-certificate -a -c "$SIGNING_CERT_NAME" -p "$KEYCHAIN" > "$WORK/certificate" 2>/dev/null || fail
[[ $(grep -c 'BEGIN CERTIFICATE' "$WORK/certificate") == 1 ]] || fail
ACTUAL_SHA256=$(openssl x509 -in "$WORK/certificate" -outform DER | shasum -a 256 | awk '{print toupper($1)}')
[[ "$ACTUAL_SHA256" == "$SIGNING_CERT_SHA256" ]] || fail
openssl x509 -in "$WORK/certificate" -checkend 0 -noout >/dev/null || fail
# Include untrusted self-signed identities: certificate-chain trust and key access
# are separate from code identity. codesign will perform the actual key operation.
security find-identity -p codesigning "$KEYCHAIN" > "$WORK/identities"
grep -Fq "$SIGNING_CERT_SHA1 \"$SIGNING_CERT_NAME\"" "$WORK/identities" || fail
echo 'Pinned CmdTabo certificate and private identity found.'
