#!/usr/bin/env bash
# Creates a stable self-signed code-signing identity in a dedicated keychain.
# Why: ad-hoc signatures change on every build, so macOS would forget the folder access
# permissions (Desktop, Documents, Downloads) after each rebuild. A stable certificate keeps the app's identity constant.
# Your login keychain is not touched.
set -euo pipefail

KEYCHAIN="$HOME/Library/Keychains/local-codesign.keychain-db"
# Not a secret: it only unlocks this throwaway keychain, which holds a self-signed certificate created on
# your own Mac by this script. Every machine generates its own certificate.
PASS="local-codesign"
NAME="Local Code Signing"

if [[ -f "$KEYCHAIN" ]] && security find-certificate -c "$NAME" "$KEYCHAIN" >/dev/null 2>&1; then
  echo "Signing identity already exists in $KEYCHAIN"
  exit 0
fi

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

openssl req -x509 -newkey rsa:2048 -keyout "$tmp/key.pem" -out "$tmp/cert.pem" -days 3650 -nodes \
  -subj "/CN=$NAME" \
  -addext "extendedKeyUsage=codeSigning" \
  -addext "keyUsage=critical,digitalSignature" \
  -addext "basicConstraints=critical,CA:false" 2>/dev/null
openssl pkcs12 -export -out "$tmp/id.p12" -inkey "$tmp/key.pem" -in "$tmp/cert.pem" -passout "pass:$PASS"

[[ -f "$KEYCHAIN" ]] || security create-keychain -p "$PASS" "$KEYCHAIN"
security set-keychain-settings "$KEYCHAIN"
security unlock-keychain -p "$PASS" "$KEYCHAIN"
security import "$tmp/id.p12" -k "$KEYCHAIN" -P "$PASS" -T /usr/bin/codesign >/dev/null
security set-key-partition-list -S apple-tool:,apple:,codesign: -s -k "$PASS" "$KEYCHAIN" >/dev/null
echo "Created '$NAME' in $KEYCHAIN"
