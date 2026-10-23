#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"

echo "› swift build -c release"
swift build -c release --product Whisp -j "${WHISP_BUILD_JOBS:-2}"

APP="Whisp.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp ".build/release/Whisp" "$APP/Contents/MacOS/Whisp"
cp "Resources/Info.plist.template" "$APP/Contents/Info.plist"
cp "Resources/Whisp.icns" "$APP/Contents/Resources/Whisp.icns"
cp "LICENSE" "$APP/Contents/Resources/LICENSE.txt"
cp "Sources/CWhisper/LICENSE" "$APP/Contents/Resources/whisper-cpp-LICENSE.txt"
cp "THIRD_PARTY_NOTICES.md" "$APP/Contents/Resources/"

# Bundle the accuracy-focused default model if present in ~/.whisp/models.
MODEL="$HOME/.whisp/models/ggml-small.en.bin"
if [ -f "$MODEL" ]; then
  cp "$MODEL" "$APP/Contents/Resources/"
fi

# Sign with the self-signed identity if available, else ad-hoc.
IDENTITY="Whisp Signing"
KEYCHAIN="$HOME/Library/Keychains/whisp-signing.keychain-db"
if [ -n "${WHISP_SIGNING_IDENTITY:-}" ]; then
  echo "› codesign with configured identity"
  codesign --force --deep --options runtime --entitlements Resources/Whisp.entitlements \
    --sign "$WHISP_SIGNING_IDENTITY" "$APP"
elif security find-identity -v -p codesigning "$KEYCHAIN" 2>/dev/null | grep -q "$IDENTITY"; then
  echo "› codesign with '$IDENTITY'"
  codesign --force --deep --options runtime --entitlements Resources/Whisp.entitlements \
    --keychain "$KEYCHAIN" --sign "$IDENTITY" "$APP"
else
  echo "› codesign ad-hoc (optional local identity: scripts/setup-signing.sh)"
  codesign --force --deep --sign - "$APP"
fi

echo "✓ Built $APP"
