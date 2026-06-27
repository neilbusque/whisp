#!/bin/bash
# Creates a self-signed code-signing identity in a dedicated keychain so that
# Microphone + Accessibility TCC grants persist across rebuilds.
set -euo pipefail
KEYCHAIN="$HOME/Library/Keychains/whisp-signing.keychain-db"
PASS="whisp"
IDENTITY="Whisp Signing"

if security find-identity -v "$KEYCHAIN" 2>/dev/null | grep -q "$IDENTITY"; then
  echo "Signing identity already present."
  exit 0
fi

TMP="$(mktemp -d)"
# Use Homebrew openssl (-legacy) so the .p12 is importable by macOS security.
if [ -x "/opt/homebrew/opt/openssl@3/bin/openssl" ]; then
  OPENSSL="/opt/homebrew/opt/openssl@3/bin/openssl"
else
  OPENSSL="$(command -v openssl)"
fi
"$OPENSSL" req -x509 -newkey rsa:2048 -keyout "$TMP/k.key" -out "$TMP/c.crt" \
  -days 3650 -nodes -subj "/CN=$IDENTITY" \
  -addext "extendedKeyUsage=codeSigning" >/dev/null 2>&1
"$OPENSSL" pkcs12 -export -legacy -inkey "$TMP/k.key" -in "$TMP/c.crt" \
  -out "$TMP/c.p12" -passout pass:"$PASS" >/dev/null 2>&1

security create-keychain -p "$PASS" "$KEYCHAIN" 2>/dev/null || true
security unlock-keychain -p "$PASS" "$KEYCHAIN"
security import "$TMP/c.p12" -k "$KEYCHAIN" -P "$PASS" -T /usr/bin/codesign
security set-key-partition-list -S apple-tool:,apple:,codesign: -s -k "$PASS" "$KEYCHAIN" >/dev/null
existing="$(security list-keychains -d user | sed -e 's/^[[:space:]]*"//' -e 's/"[[:space:]]*$//')"
security list-keychains -d user -s "$KEYCHAIN" $existing
rm -rf "$TMP"
echo "Created signing identity '$IDENTITY' in $KEYCHAIN"
