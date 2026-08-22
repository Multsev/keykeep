#!/usr/bin/env bash
set -euo pipefail

# Always produces a versioned local APK. If OAuth token is configured, mirrors it to Yandex Disk.
root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$root"

if [[ -f .env ]]; then
  set -a
  source .env
  set +a
fi

version="$(sed -nE 's/^version: ([0-9]+\.[0-9]+\.[0-9]+\+[0-9]+)$/\1/p' pubspec.yaml)"
if [[ -z "$version" ]]; then
  echo "Could not read version from pubspec.yaml." >&2
  exit 1
fi

flutter build apk --debug
artifact="KeyKeep-v$version-debug.apk"
output="Release"
mkdir -p "$output"
cp build/app/outputs/flutter-apk/app-debug.apk "$output/$artifact"
shasum -a 256 "$output/$artifact" > "$output/$artifact.sha256"
echo "Local artifact: $output/$artifact"

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

if upload "$artifact" && upload "$artifact.sha256"; then
  echo "Yandex Disk: $disk_folder/$artifact"
else
  echo "Yandex Disk upload failed; the local artifact is preserved in $output/." >&2
fi
