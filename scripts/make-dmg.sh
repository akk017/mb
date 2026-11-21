#!/bin/sh
# Packages dist/MiniBrain.app into dist/MiniBrain.dmg (drag-to-Applications).
set -eu
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
STAGE="$(mktemp -d -t minibrain-dmg)"
ditto "$ROOT/dist/MiniBrain.app" "$STAGE/MiniBrain.app"
ln -sfn /Applications "$STAGE/Applications"
hdiutil create -volname MiniBrain -srcfolder "$STAGE" -ov -format UDZO "$ROOT/dist/MiniBrain.dmg"
echo "built $ROOT/dist/MiniBrain.dmg"
