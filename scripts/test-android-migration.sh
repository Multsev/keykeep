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
elif [[ ${2:-} == --legacy-pin ]]; then
    avd=$("$adb" -s "$serial" emu avd name | tr -d '\r' | head -1)
    [[ $avd == keykeep-qa-api28 || $avd == keykeep-qa-api29 ]] || { echo "Requires dedicated legacy QA emulator" >&2; exit 1; }
    probe_args=(-e legacyPin true)
elif [[ ${2:-} == --first-import ]]; then
    probe_args=(-e firstImport true)
elif [[ ${2:-} == --erase-fixture ]]; then
    [[ $serial == emulator-* && $user != 0 ]] || { echo "Requires secondary test user on emulator" >&2; exit 1; }
    probe_args=(-e eraseFixture true)
elif [[ ${2:-} == --verify-erasure ]]; then
    probe_args=(-e verifyErase true)
fi
"$adb" -s "$serial" shell am instrument --user "$user" -w "${probe_args[@]+"${probe_args[@]}"}" com.max.keykeep.tests/.MigrationProbe |
while IFS= read -r line; do
    echo "$line" | tee -a "$stage/result"
    case "$line" in
        *keykeepPrompt=credential-*)
            for ((i=0;i<80;i++)); do
                focus=$("$adb" -s "$serial" shell dumpsys window </dev/null | sed -n '/mCurrentFocus=/p')
                if [[ $focus == *ConfirmLock* || $focus == *ConfirmDeviceCredential* ]]; then
                    sleep 0.6
                    if [[ $line == *credential-cancel* ]]; then
                        "$adb" -s "$serial" shell input keyevent 4 </dev/null
                        sleep 0.4
                        if "$adb" -s "$serial" shell dumpsys window </dev/null | grep "mCurrentFocus=" | grep -q ConfirmLock; then
                            "$adb" -s "$serial" shell input keyevent 4 </dev/null
                        fi
                    else
                        "$adb" -s "$serial" shell input text 772255 </dev/null
                        "$adb" -s "$serial" shell input keyevent 66 </dev/null
                    fi
                    break
                fi
                sleep 0.2
            done
            ;;
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
grep -Eq 'result=PASS (migrated|first import|erasure|legacy credential)' "$stage/result"

if [[ ${2:-} == --erase-fixture ]]; then
    "$adb" -s "$serial" shell am force-stop --user "$user" com.max.keykeep_passwords
    "$adb" -s "$serial" shell am instrument --user "$user" -w -e verifyErase true com.max.keykeep.tests/.MigrationProbe | tee "$stage/restart"
    grep -q 'PASS erasure persisted' "$stage/restart"
fi
