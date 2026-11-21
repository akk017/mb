#!/bin/sh
# Installs dist/MiniBrain.app into /Applications and relaunches it:
# quits the running copy, ejects mounted MiniBrain disk images (so you don't
# keep launching an old build from one), replaces the installed app.
set -eu
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SRC="$ROOT/dist/MiniBrain.app"
DEST="/Applications/MiniBrain.app"
[ -d "$SRC" ] || { echo "build first: make app"; exit 1; }

osascript -e 'tell application id "app.minibrain.MiniBrain" to quit' >/dev/null 2>&1 || true
sleep 1
pkill -x MiniBrain >/dev/null 2>&1 || true

for vol in /Volumes/MiniBrain*; do
  [ -d "$vol" ] && hdiutil detach "$vol" -quiet >/dev/null 2>&1 && echo "ejected $vol"
done

if [ -d "$DEST" ]; then
  chmod -R u+w "$DEST"
  rm -rf "/Applications/MiniBrain.app"
fi
ditto "$SRC" "$DEST"
echo "installed $DEST"
open "$DEST"
