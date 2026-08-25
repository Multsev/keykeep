#!/usr/bin/env bash
set -euo pipefail

# Produces compact, signed release APKs split by CPU architecture. Each phone
# downloads only its matching ABI instead of carrying all Flutter engines.
root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$root"

if [[ -f .env ]]; then
  set -a
  source .env
  set +a
fi

# Visible version is deliberately calendar based: 0.DDMMYY in Moscow time.
# Android also needs an ever-increasing integer, so the build number uses
# YYMMDD plus a two digit sequence for repeated builds on one day.
date_part="$(TZ=Europe/Moscow date '+%d%m%y')"
code_date="$(TZ=Europe/Moscow date '+%y%m%d')"
version="0.$date_part"
sequence=1
while [[ -e "Release/KeyKeep-v$version-b$(printf '%02d' "$sequence")-arm64-v8a.apk" ]]; do
  sequence=$((sequence + 1))
done
build_number="$code_date$(printf '%02d' "$sequence")"
release="$version-b$(printf '%02d' "$sequence")"

for required in ANDROID_KEYSTORE_PATH ANDROID_KEYSTORE_PASSWORD ANDROID_KEY_ALIAS ANDROID_KEY_PASSWORD; do
  if [[ -z "${!required:-}" ]]; then
    echo "Missing $required. A signed release key is required for compact artifacts." >&2
    exit 1
  fi
done

build_args=(--release --split-per-abi --build-name="$version" --build-number="$build_number")
if [[ -n "${YANDEX_OAUTH_CLIENT_ID:-}" ]]; then
  build_args+=(--dart-define="YANDEX_OAUTH_CLIENT_ID=$YANDEX_OAUTH_CLIENT_ID")
fi
flutter build apk "${build_args[@]}"
output="Release"
mkdir -p "$output"
artifacts=()
for abi in arm64-v8a armeabi-v7a x86_64; do
  source_apk="build/app/outputs/flutter-apk/app-$abi-release.apk"
  artifact="KeyKeep-v$release-$abi.apk"
  cp "$source_apk" "$output/$artifact"
  shasum -a 256 "$output/$artifact" > "$output/$artifact.sha256"
  artifacts+=("$artifact" "$artifact.sha256")
  echo "Local artifact: $output/$artifact"
done

if [[ -z "${YANDEX_DISK_TOKEN:-}" ]]; then
  echo "Yandex Disk upload skipped: YANDEX_DISK_TOKEN is not configured."
  exit 0
fi

disk_folder="${YANDEX_DISK_FOLDER:-KeyKeep/releases}"
folder=""
IFS='/' read -ra parts <<< "$disk_folder"
for part in "${parts[@]}"; do
  [[ -z "$part" ]] && continue
  folder="${folder:+$folder/}$part"
  code="$(curl --silent --output /dev/null --write-out '%{http_code}' --request PUT --get --data-urlencode "path=app:/$folder" -H "Authorization: OAuth $YANDEX_DISK_TOKEN" "https://cloud-api.yandex.net/v1/disk/resources")"
  if [[ "$code" != "201" && "$code" != "409" ]]; then
    echo "Yandex Disk upload skipped: could not create $folder (HTTP $code)." >&2
    exit 0
  fi
done

upload() {
  local name="$1"
  local metadata href
  metadata="$(curl --fail --silent --show-error -H "Authorization: OAuth $YANDEX_DISK_TOKEN" --get --data-urlencode "path=app:/$disk_folder/$name" --data-urlencode "overwrite=true" "https://cloud-api.yandex.net/v1/disk/resources/upload")"
  href="$(printf '%s' "$metadata" | plutil -extract href raw -)"
  curl --fail --silent --show-error --upload-file "$output/$name" "$href"
}

for artifact in "${artifacts[@]}"; do
  if upload "$artifact"; then
    echo "Yandex Disk: $disk_folder/$artifact"
  else
    echo "Yandex Disk upload failed; the local artifact is preserved in $output/." >&2
  fi
done
