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

bump="${1:-patch}"
case "$bump" in
  patch|minor|major) ;;
  *) echo "Usage: ./scripts/release.sh [patch|minor|major]" >&2; exit 1 ;;
esac

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

current="$(sed -nE 's/^version: ([0-9]+\.[0-9]+\.[0-9]+)\+([0-9]+)$/\1+\2/p' pubspec.yaml)"
if [[ -z "$current" ]]; then
  echo "Could not read version from pubspec.yaml." >&2
  exit 1
fi
IFS='+.' read -r major minor patch build <<< "$current"
case "$bump" in
  patch) patch=$((patch + 1)) ;;
  minor) minor=$((minor + 1)); patch=0 ;;
  major) major=$((major + 1)); minor=0; patch=0 ;;
esac
build=$((build + 1))
version="$major.$minor.$patch"
release="$version+$build"

sed -i '' -E "s/^version: .*/version: $release/" pubspec.yaml
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
