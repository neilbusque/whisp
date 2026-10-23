#!/bin/bash
# Creates an optional local signing identity in a dedicated keychain.
# This is not a Developer ID certificate or notarization. macOS may still ask
# for Microphone or Accessibility permission after a rebuild.
set -euo pipefail
umask 077
KEYCHAIN="$HOME/Library/Keychains/whisp-signing.keychain-db"
IDENTITY="Whisp Signing"

if security find-identity -v -p codesigning "$KEYCHAIN" 2>/dev/null | grep -q "$IDENTITY"; then
  echo "Signing identity already present."
  exit 0
fi

if [ -e "$KEYCHAIN" ]; then
  echo "The dedicated keychain already exists but has no valid '$IDENTITY' identity."
  echo "Review it in Keychain Access before retrying. This script will not replace it."
  exit 1
fi

# OpenSSL 3 supports the legacy PKCS#12 export macOS security can import.
OPENSSL="$(command -v openssl || true)"
for candidate in /opt/homebrew/opt/openssl@3/bin/openssl /usr/local/opt/openssl@3/bin/openssl; do
  if [ -x "$candidate" ]; then
    OPENSSL="$candidate"
    break
  fi
done
if [ -z "$OPENSSL" ] || ! "$OPENSSL" version | grep -q '^OpenSSL 3\.'; then
  echo "OpenSSL 3 is required. Install it with 'brew install openssl@3', then retry."
  exit 1
fi
if [ ! -t 0 ]; then
  echo "Run this script in an interactive terminal to choose a keychain password."
  exit 1
fi
read -r -s -p "Choose a password for the Whisp signing keychain: " PASS
echo
read -r -s -p "Confirm the password: " CONFIRM_PASS
echo
if [ -z "$PASS" ] || [ "$PASS" != "$CONFIRM_PASS" ]; then
  echo "Passwords must match and cannot be empty. No keychain was created."
  exit 1
fi
unset CONFIRM_PASS

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"; unset PASS' EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
"$OPENSSL" req -x509 -newkey rsa:2048 -keyout "$TMP/k.key" -out "$TMP/c.crt" \
  -days 3650 -nodes -subj "/CN=$IDENTITY" \
  -addext "extendedKeyUsage=codeSigning" >/dev/null 2>&1
"$OPENSSL" pkcs12 -export -legacy -inkey "$TMP/k.key" -in "$TMP/c.crt" \
  -out "$TMP/c.p12" -passout fd:3 3<<<"$PASS" >/dev/null 2>&1

security create-keychain -p "$PASS" "$KEYCHAIN"
security unlock-keychain -p "$PASS" "$KEYCHAIN"
security import "$TMP/c.p12" -k "$KEYCHAIN" -P "$PASS" -T /usr/bin/codesign
security set-key-partition-list -S apple-tool:,apple:,codesign: -s -k "$PASS" "$KEYCHAIN" >/dev/null
existing=("$KEYCHAIN")
while IFS= read -r path; do
  [ -z "$path" ] || [ "$path" = "$KEYCHAIN" ] || existing+=("$path")
done < <(security list-keychains -d user | sed -e 's/^[[:space:]]*"//' -e 's/"[[:space:]]*$//')
security list-keychains -d user -s "${existing[@]}"
echo "Created signing identity '$IDENTITY' in $KEYCHAIN"
echo "Keep its password in your password manager. This script does not save it."
echo "Review certificate trust in Keychain Access if codesign cannot use the identity."
