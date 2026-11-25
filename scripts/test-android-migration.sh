#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
serial=${1:?Specify the dedicated migration emulator serial}
export JAVA_HOME="${JAVA_HOME:-/opt/homebrew/opt/openjdk@17/libexec/openjdk.jdk/Contents/Home}"
export PATH="$JAVA_HOME/bin:$PATH"
sdk="${ANDROID_HOME:-$HOME/Library/Android/sdk}"
bt="$sdk/build-tools/35.0.0"
stage=$(mktemp -d)
trap 'rm -rf "$stage"' EXIT
mkdir "$stage/classes"
javac -encoding UTF-8 --release 8 -cp "$sdk/platforms/android-35/android.jar" -d "$stage/classes" native/android/tests/MigrationProbe.java
jar cf "$stage/classes.jar" -C "$stage/classes" .
"$bt/d8" --min-api 28 --lib "$sdk/platforms/android-35/android.jar" --output "$stage" "$stage/classes.jar"
"$bt/aapt2" link -I "$sdk/platforms/android-35/android.jar" --min-sdk-version 28 --target-sdk-version 35 --manifest native/android/tests/AndroidManifest.xml -o "$stage/probe.apk"
if [[ ${2:-} == --first-import ]]; then
    mkdir -p "$stage/assets"
    xc=${KEEPASSXC_CLI:-keepassxc-cli}
    printf 'fixture-password\nfixture-password\n' | "$xc" db-create -p "$stage/assets/fixture.kdbx"
    printf 'fixture-password\n' | "$xc" add -u example "$stage/assets/fixture.kdbx" ImportFixture
    (cd "$stage" && zip -q probe.apk assets/fixture.kdbx)
fi
(cd "$stage" && zip -q probe.apk classes.dex)
"$bt/apksigner" sign --ks "$HOME/.android/debug.keystore" --ks-pass pass:android --out "$stage/test.apk" "$stage/probe.apk"
adb="$sdk/platform-tools/adb"
"$adb" -s "$serial" install -r "$stage/test.apk"
user=$("$adb" -s "$serial" shell am get-current-user | tr -d '\r')
"$adb" -s "$serial" shell cmd package install-existing --user "$user" com.max.keykeep.tests
"$adb" -s "$serial" shell am force-stop --user "$user" com.max.keykeep_passwords
probe_args=()
if [[ ${2:-} == --fingerprint ]]; then
    [[ $serial == emulator-* ]] || { echo "Fingerprint simulation requires an emulator" >&2; exit 1; }
    probe_args=(-e fingerprint true)
elif [[ ${2:-} == --first-import ]]; then
    probe_args=(-e firstImport true)
fi
"$adb" -s "$serial" shell am instrument --user "$user" -w "${probe_args[@]+"${probe_args[@]}"}" com.max.keykeep.tests/.MigrationProbe |
while IFS= read -r line; do
    echo "$line" | tee -a "$stage/result"
    case "$line" in
        *keykeepPrompt=finger*|*keykeepPrompt=cancel*)
            for ((i=0;i<60;i++)); do
                sensor=$("$adb" -s "$serial" shell dumpsys fingerprint </dev/null)
                if [[ $sensor == *"Fps state: 3"* && $sensor == *"owner=com.max.keykeep_passwords"* ]]; then
                    if [[ $line == *keykeepPrompt=cancel* ]]; then
                        "$adb" -s "$serial" shell input keyevent 4 </dev/null
                    else
                        "$adb" -s "$serial" emu finger touch 1 </dev/null
                    fi
                    break
                fi
                sleep 0.2
            done
            ;;
    esac
done
grep -Eq 'result=PASS (migrated|first import)' "$stage/result"
