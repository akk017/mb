#!/bin/sh
# Builds a sudo-free workaround for Command Line Tools installs that carry
# stale files from older versions:
#  1. Copies SwiftPM's ManifestAPI without the stale *.private.swiftinterface
#     (built by Swift 5.10) that shadows the current interface and breaks
#     every Package.swift.
#  2. Writes a VFS overlay hiding the duplicate SwiftBridging module.modulemap
#     (bridging.modulemap defines the same module -> "redefinition" error).
set -eu
OUT="$1"
CLT=/Library/Developer/CommandLineTools
mkdir -p "$OUT/pm"
cp -R "$CLT/usr/lib/swift/pm/." "$OUT/pm/"
find "$OUT/pm/ManifestAPI" -name '*.private.swiftinterface' -delete
: > "$OUT/empty.modulemap"
MODMAP="$CLT/usr/include/swift/module.modulemap"
ROOTS=""
if [ -f "$CLT/usr/include/swift/bridging.modulemap" ] && [ -f "$MODMAP" ]; then
  ROOTS="{\"type\":\"file\",\"name\":\"$MODMAP\",\"external-contents\":\"$OUT/empty.modulemap\"}"
fi
printf '{"version":0,"case-sensitive":"false","roots":[%s]}\n' "$ROOTS" > "$OUT/overlay.yaml"
echo "CLT workaround ready in $OUT"

# 3. swiftc wrapper used for manifest compilation (dependency Package.swift
#    files import Foundation and hit the same modulemap problem).
cat > "$OUT/swiftc-manifest" <<WRAP
#!/bin/sh
exec "$CLT/usr/bin/swiftc" -vfsoverlay "$OUT/overlay.yaml" -Xcc -ivfsoverlay -Xcc "$OUT/overlay.yaml" "\$@"
WRAP
chmod +x "$OUT/swiftc-manifest"
