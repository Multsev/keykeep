#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
export MACOSX_DEPLOYMENT_TARGET=14.0
cargo build --locked --release -p keykeep-core
app="target/macos/KeyKeep.app"
flags=()
bundle_id=com.max.keykeep.desktop
probe=
if [[ "${1:-}" == "--ui-test" ]]; then
    app="target/ui-test/KeyKeepTest.app"
    probe=smoke.js
elif [[ "${1:-}" == "--touch-id-test" ]]; then
    app="target/ui-test/KeyKeepTouchIDTest.app"
    probe=touch-id.js
fi
if [[ -n "$probe" ]]; then
    bundle_id="com.max.keykeep.tests.${probe%.js}"
    flags=(-D UI_TEST)
fi
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources/ui"
cp native/macos/KeyKeep.icns "$app/Contents/Resources/"
cp native/ui/* "$app/Contents/Resources/ui/"
version=0.1.0
sed -e "s/@KEYKEEP_VERSION@/$version/g" -e "s/@KEYKEEP_DATE@/$(date -u +%Y-%m-%d)/g" native/ui/index.html > "$app/Contents/Resources/ui/index.html"
if [[ -n "$probe" ]]; then cp "native/macos/tests/$probe" "$app/Contents/Resources/smoke.js"; fi
xcrun swiftc "${flags[@]+"${flags[@]}"}" -O -import-objc-header native/include/KeyKeep.h native/macos/main.swift native/macos/Fingerprint.swift native/macos/VaultCatalog.swift native/macos/VaultTrash.swift native/macos/DiskAccount.swift target/release/libkeykeep_core.a -o "$app/Contents/MacOS/KeyKeep"
cat > "$app/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>$bundle_id</string>
<key>CFBundleName</key><string>KeyKeep</string>
<key>CFBundleURLTypes</key><array><dict><key>CFBundleURLName</key><string>KeyKeep OAuth</string><key>CFBundleURLSchemes</key><array><string>keykeep</string></array></dict></array>
<key>CFBundleIconFile</key><string>KeyKeep.icns</string>
<key>CFBundleExecutable</key><string>KeyKeep</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleVersion</key><string>1</string>
<key>CFBundleShortVersionString</key><string>$version</string>
</dict></plist>
PLIST
if [[ -n "$probe" ]]; then /usr/libexec/PlistBuddy -c "Delete :CFBundleURLTypes" "$app/Contents/Info.plist"; fi
codesign --force --sign - "$app"
echo "$PWD/$app"
