#!/bin/sh
# Assembles dist/MiniBrain.app from a release build. Usage: make-app.sh <bin-path>
set -eu
BIN="$1"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP="$ROOT/dist/MiniBrain.app"
VERSION="$(sed -n 's/.*version = "\(.*\)".*/\1/p' "$ROOT/Sources/MiniBrainCore/MiniBrain.swift")"
[ -d "$APP" ] && chmod -R u+w "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN/MiniBrain" "$APP/Contents/MacOS/MiniBrain"
sed "s/__VERSION__/$VERSION/g" "$ROOT/Resources/Info.plist" > "$APP/Contents/Info.plist"
cp "$ROOT/Resources/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"
for b in "$BIN"/*.bundle; do
  case "$(basename "$b")" in *Tests.bundle) continue ;; esac   # test fixtures don't ship
  [ -e "$b" ] && ditto "$b" "$APP/Contents/Resources/$(basename "$b")"
done
codesign --force --deep --sign - "$APP"
echo "built $APP ($VERSION)"
