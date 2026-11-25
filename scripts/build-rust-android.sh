#!/bin/bash
# Local arm64 development APK, signed with the developer's Android debug identity.
set -euo pipefail
cd "$(dirname "$0")/.."
sdk="${ANDROID_HOME:-$HOME/Library/Android/sdk}"
ndk="${ANDROID_NDK_HOME:-$sdk/ndk/28.2.13676358}"
toolchain=("$ndk"/toolchains/llvm/prebuilt/*/bin)
export CC_aarch64_linux_android="${toolchain[0]}/aarch64-linux-android28-clang"
export AR_aarch64_linux_android="${toolchain[0]}/llvm-ar"
export JAVA_HOME="${JAVA_HOME:-/opt/homebrew/opt/openjdk@17/libexec/openjdk.jdk/Contents/Home}"
export PATH="$JAVA_HOME/bin:$PATH"
bt="$sdk/build-tools/35.0.0"
platform="$sdk/platforms/android-35/android.jar"
out="$PWD/target/android"
stage=$(mktemp -d)
trap 'rm -rf "$stage"' EXIT
mkdir -p "$out" "$stage/classes" "$stage/assets/ui" "$stage/lib/arm64-v8a"
cargo build --locked --release --target aarch64-linux-android
"$CC_aarch64_linux_android" -shared -O2 -Wl,-z,max-page-size=16384 -Wl,--no-undefined -I native/include native/android/bridge.c target/aarch64-linux-android/release/libkeykeep_core.a -ldl -lm -llog -o "$stage/lib/arm64-v8a/libkeykeep.so"
"${toolchain[0]}/llvm-strip" --strip-unneeded "$stage/lib/arm64-v8a/libkeykeep.so"
javac -encoding UTF-8 --release 8 -cp "$platform" -d "$stage/classes" native/android/java/com/max/keykeep_passwords/*.java
jar cf "$stage/classes.jar" -C "$stage/classes" .
"$bt/d8" --min-api 28 --lib "$platform" --output "$stage" "$stage/classes.jar"
cp native/ui/* "$stage/assets/ui/"
for directory in android/app/src/main/res/mipmap-*; do
    mkdir -p "$stage/resources/$(basename "$directory")"
    cp "$directory"/ic_launcher.* "$stage/resources/$(basename "$directory")/"
done
mkdir -p "$stage/resources/drawable" "$stage/resources/values"
cp android/app/src/main/res/drawable/keykeep_mark.xml "$stage/resources/drawable/"
cp android/app/src/main/res/values/keykeep_icon.xml "$stage/resources/values/"
"$bt/aapt2" compile --dir "$stage/resources" -o "$stage/icons.zip"
"$bt/aapt2" link "$stage/icons.zip" -I "$platform" --manifest native/android/AndroidManifest.xml -A "$stage/assets" --min-sdk-version 28 --target-sdk-version 35 --version-code "${KEYKEEP_VERSION_CODE:-26112501}" --version-name "0.1.0-dev" -o "$stage/app.apk"
(cd "$stage" && zip -q app.apk classes.dex lib/arm64-v8a/libkeykeep.so)
"$bt/zipalign" -f 4 "$stage/app.apk" "$stage/aligned.apk"
"$bt/apksigner" sign --ks "$HOME/.android/debug.keystore" --ks-key-alias androiddebugkey --ks-pass pass:android --out "$stage/KeyKeep.apk" "$stage/aligned.apk"
"$bt/apksigner" verify "$stage/KeyKeep.apk"
mv "$stage/KeyKeep.apk" "$out/KeyKeep.apk"
echo "$out/KeyKeep.apk"
