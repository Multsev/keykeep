#!/usr/bin/env bash
set -euo pipefail

# Builds a signed KeyKeep APK, records an immutable release in Git and uploads it.
root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$root"

if [[ -f .env ]]; then
  set -a
  source .env
  set +a
fi

if [[ $# -ne 0 ]]; then
  echo "Usage: ./scripts/release.sh" >&2
  exit 1
fi

if [[ -n "$(git status --porcelain)" ]]; then
  echo "Commit or stash local changes before making a release." >&2
  exit 1
fi

: "${YANDEX_DISK_TOKEN:?Copy .env.example to .env and set YANDEX_DISK_TOKEN.}"
: "${ANDROID_KEYSTORE_PATH:?Set Android signing variables in .env.}"
: "${ANDROID_KEYSTORE_PASSWORD:?Set Android signing variables in .env.}"
: "${ANDROID_KEY_ALIAS:?Set Android signing variables in .env.}"
: "${ANDROID_KEY_PASSWORD:?Set Android signing variables in .env.}"
YANDEX_DISK_FOLDER="${YANDEX_DISK_FOLDER:-KeyKeep/releases}"

date_part="$(TZ=Europe/Moscow date '+%d%m%y')"
code_date="$(TZ=Europe/Moscow date '+%y%m%d')"
version="0.$date_part"
sequence=1
while git rev-parse -q --verify "refs/tags/v$version-b$(printf '%02d' "$sequence")" >/dev/null; do
  sequence=$((sequence + 1))
done
build="$code_date$(printf '%02d' "$sequence")"
release="$version-b$(printf '%02d' "$sequence")"

# pubspec requires semantic x.y.z, while Android's visible version is exactly
# 0.DDMMYY and is passed below with --build-name.
sed -i '' -E "s/^version: .*/version: 0.0.0+$build/" pubspec.yaml
flutter pub get
flutter analyze
flutter test
build_args=(--release --build-name="$version" --build-number="$build")
if [[ -n "${YANDEX_OAUTH_CLIENT_ID:-}" ]]; then
  build_args+=(--dart-define="YANDEX_OAUTH_CLIENT_ID=$YANDEX_OAUTH_CLIENT_ID")
fi
flutter build apk --split-per-abi "${build_args[@]}"

mkdir -p Release
artifacts=()
for abi in arm64-v8a armeabi-v7a x86_64; do
  artifact="KeyKeep-v$release-$abi.apk"
  cp "build/app/outputs/flutter-apk/app-$abi-release.apk" "Release/$artifact"
  shasum -a 256 "Release/$artifact" > "Release/$artifact.sha256"
  artifacts+=("$artifact" "$artifact.sha256")
done

create_disk_folder() {
  local path="$1"
  local code
  code="$(curl --silent --output /dev/null --write-out '%{http_code}' --request PUT --get --data-urlencode "path=app:/$path" -H "Authorization: OAuth $YANDEX_DISK_TOKEN" "https://cloud-api.yandex.net/v1/disk/resources")"
  if [[ "$code" != "201" && "$code" != "409" ]]; then
    echo "Could not create Yandex Disk folder: $path (HTTP $code)" >&2
    exit 1
  fi
}

folder=""
IFS='/' read -ra parts <<< "$YANDEX_DISK_FOLDER"
for part in "${parts[@]}"; do
  [[ -z "$part" ]] && continue
  folder="${folder:+$folder/}$part"
  create_disk_folder "$folder"
done

upload_artifact() {
  local name="$1"
  local response href
  response="$(curl --fail --silent --show-error -H "Authorization: OAuth $YANDEX_DISK_TOKEN" --get --data-urlencode "path=app:/$YANDEX_DISK_FOLDER/$name" --data-urlencode "overwrite=true" "https://cloud-api.yandex.net/v1/disk/resources/upload")"
  href="$(printf '%s' "$response" | plutil -extract href raw -)"
  curl --fail --silent --show-error --upload-file "Release/$name" "$href"
}

for artifact in "${artifacts[@]}"; do
  upload_artifact "$artifact"
done

git add pubspec.yaml pubspec.lock
git commit -m "Release v$release"
git tag -a "v$release" -m "KeyKeep v$release"

echo "Released v$release"
echo "Yandex Disk: $YANDEX_DISK_FOLDER/ (three ABI-specific APKs)"
