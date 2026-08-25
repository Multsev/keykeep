#!/usr/bin/env bash
set -euo pipefail

# Builds one compact, signed calendar-versioned release for the current commit
# and mirrors exactly the same files to all configured destinations.
root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$root"

if [[ -f .env ]]; then
  set -a
  source .env
  set +a
fi

for required in ANDROID_KEYSTORE_PATH ANDROID_KEYSTORE_PASSWORD ANDROID_KEY_ALIAS ANDROID_KEY_PASSWORD; do
  if [[ -z "${!required:-}" ]]; then
    echo "Missing $required. Cannot produce a signed release." >&2
    exit 1
  fi
done

commit="$(git rev-parse HEAD)"
short_commit="$(git rev-parse --short=12 HEAD)"
date_part="$(TZ=Europe/Moscow date '+%d%m%y')"
code_date="$(TZ=Europe/Moscow date '+%y%m%d')"
version="0.$date_part"
tag_prefix="build/v$version-b"

existing_tag="$(git tag --points-at "$commit" --list "$tag_prefix*" | sort -V | tail -n 1)"
if [[ -n "$existing_tag" ]]; then
  release="${existing_tag#build/v}"
  sequence="${release##*-b}"
else
  highest=0
  while IFS= read -r tag; do
    candidate="${tag##*-b}"
    if [[ "$candidate" =~ ^[0-9]+$ ]] && (( 10#$candidate > highest )); then
      highest=$((10#$candidate))
    fi
  done < <(git tag --list "$tag_prefix*")
  shopt -s nullglob
  for apk in Release/KeyKeep-v"$version"-b*-arm64-v8a.apk; do
    candidate="${apk##*-b}"
    candidate="${candidate%-arm64-v8a.apk}"
    if [[ "$candidate" =~ ^[0-9]+$ ]] && (( 10#$candidate > highest )); then
      highest=$((10#$candidate))
    fi
  done
  shopt -u nullglob
  sequence=$((highest + 1))
  release="$version-b$(printf '%02d' "$sequence")"
fi
build_number="$code_date$(printf '%02d' "$((10#$sequence))")"
output="Release"
report="$output/latest-build.txt"
tag="build/v$release"

flutter analyze
flutter test
build_args=(--release --split-per-abi --build-name="$version" --build-number="$build_number")
if [[ -n "${YANDEX_OAUTH_CLIENT_ID:-}" ]]; then
  build_args+=(--dart-define="YANDEX_OAUTH_CLIENT_ID=$YANDEX_OAUTH_CLIENT_ID")
fi
flutter build apk "${build_args[@]}"

mkdir -p "$output"
artifacts=()
for abi in arm64-v8a armeabi-v7a x86_64; do
  artifact="KeyKeep-v$release-$abi.apk"
  cp "build/app/outputs/flutter-apk/app-$abi-release.apk" "$output/$artifact"
  shasum -a 256 "$output/$artifact" > "$output/$artifact.sha256"
  artifacts+=("$artifact" "$artifact.sha256")
done

yandex_status="not configured"
if [[ -n "${YANDEX_DISK_TOKEN:-}" ]]; then
  disk_folder="${YANDEX_DISK_FOLDER:-KeyKeep/releases}"
  folder=""
  IFS='/' read -ra parts <<< "$disk_folder"
  for part in "${parts[@]}"; do
    [[ -z "$part" ]] && continue
    folder="${folder:+$folder/}$part"
    code="$(curl --silent --output /dev/null --write-out '%{http_code}' --request PUT --get --data-urlencode "path=app:/$folder" -H "Authorization: OAuth $YANDEX_DISK_TOKEN" "https://cloud-api.yandex.net/v1/disk/resources")"
    [[ "$code" == "201" || "$code" == "409" ]] || { echo "Cannot create Yandex folder $folder (HTTP $code)." >&2; exit 1; }
  done
  for artifact in "${artifacts[@]}"; do
    metadata="$(curl --fail --silent --show-error -H "Authorization: OAuth $YANDEX_DISK_TOKEN" --get --data-urlencode "path=app:/$disk_folder/$artifact" --data-urlencode "overwrite=true" "https://cloud-api.yandex.net/v1/disk/resources/upload")"
    href="$(printf '%s' "$metadata" | plutil -extract href raw -)"
    curl --fail --silent --show-error --upload-file "$output/$artifact" "$href"
  done
  yandex_status="app:/$disk_folder"
fi

nfs_status="not configured"
if [[ -n "${NFS_RELEASE_PATH:-}" ]]; then
  if [[ ! -d "$NFS_RELEASE_PATH" || ! -w "$NFS_RELEASE_PATH" ]]; then
    echo "NFS_RELEASE_PATH is not a writable mounted directory: $NFS_RELEASE_PATH" >&2
    exit 1
  fi
  for artifact in "${artifacts[@]}"; do
    cp "$output/$artifact" "$NFS_RELEASE_PATH/$artifact"
  done
  nfs_status="$NFS_RELEASE_PATH"
fi

if ! git rev-parse -q --verify "refs/tags/$tag" >/dev/null; then
  git tag -a "$tag" "$commit" -m "KeyKeep $release ($short_commit)"
fi

{
  printf 'KeyKeep release: %s\n' "$release"
  printf 'Android versionName: %s\n' "$version"
  printf 'Android versionCode: %s\n' "$build_number"
  printf 'Git commit: %s\n' "$commit"
  printf 'Git tag: %s\n' "$tag"
  printf 'Local files: %s/KeyKeep-v%s-{arm64-v8a,armeabi-v7a,x86_64}.apk\n' "$root/$output" "$release"
  printf 'Yandex Disk: %s\n' "$yandex_status"
  printf 'NFS: %s\n' "$nfs_status"
} | tee "$report"
