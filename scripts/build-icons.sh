#!/bin/bash
# Rebuild the packaged icons from the editable master with macOS system tools.
set -euo pipefail
cd "$(dirname "$0")/.."
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
res=android/app/src/main/res
sips -s format png native/art/keykeep.svg --out "$tmp/master.png" >/dev/null
mkdir -p "$tmp/KeyKeep.iconset"
for base in 16 32 128 256 512; do
    for scale in 1 2; do
        suffix=""
        [[ $scale == 1 ]] || suffix="@2x"
        size=$((base * scale))
        sips -z "$size" "$size" "$tmp/master.png" --out "$tmp/KeyKeep.iconset/icon_${base}x${base}${suffix}.png" >/dev/null
    done
done
iconutil -c icns "$tmp/KeyKeep.iconset" -o native/macos/KeyKeep.icns
for spec in mdpi:48 hdpi:72 xhdpi:96 xxhdpi:144 xxxhdpi:192; do
    density=${spec%:*}
    size=${spec#*:}
    sips -z "$size" "$size" "$tmp/master.png" --out "$res/mipmap-$density/ic_launcher.png" >/dev/null
done
