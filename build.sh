#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"

echo "› swift build -c release"
swift build -c release --product Whisp

APP="Whisp.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp ".build/release/Whisp" "$APP/Contents/MacOS/Whisp"
cp "Resources/Info.plist.template" "$APP/Contents/Info.plist"

# Bundle the default Whisper model if present in ~/.whisp/models.
MODEL="$HOME/.whisp/models/ggml-base.en.bin"
[ -f "$MODEL" ] && cp "$MODEL" "$APP/Contents/Resources/" || true

# Sign with the self-signed identity if available, else ad-hoc.
IDENTITY="Whisp Signing"
KEYCHAIN="$HOME/Library/Keychains/whisp-signing.keychain-db"
if security find-identity -v "$KEYCHAIN" 2>/dev/null | grep -q "$IDENTITY"; then
  echo "› codesign with '$IDENTITY'"
  codesign --force --deep --options runtime \
    --keychain "$KEYCHAIN" --sign "$IDENTITY" "$APP"
else
  echo "› codesign ad-hoc (run scripts/setup-signing.sh for persistent TCC grants)"
  codesign --force --deep --sign - "$APP"
fi

echo "✓ Built $APP"
