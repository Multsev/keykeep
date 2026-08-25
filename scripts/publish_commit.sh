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
tag="build/v$release"

flutter analyze
flutter test
build_args=(--release --target-platform=android-arm64 --build-name="$version" --build-number="$build_number")
if [[ -n "${YANDEX_OAUTH_CLIENT_ID:-}" ]]; then
  build_args+=(--dart-define="YANDEX_OAUTH_CLIENT_ID=$YANDEX_OAUTH_CLIENT_ID")
fi
flutter build apk "${build_args[@]}"

mkdir -p "$output"
artifact="KeyKeep-v$version.apk"
cp "build/app/outputs/flutter-apk/app-release.apk" "$output/$artifact"
# The release directory is intentionally a single-file handoff location.
find "$output" -maxdepth 1 -type f ! -name "$artifact" -delete

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
  # Keep the remote release folder as simple as the local handoff folder.
  while IFS= read -r name; do
    [[ -z "$name" ]] && continue
    curl --fail --silent --show-error --request DELETE --get \
      --data-urlencode "path=app:/$disk_folder/$name" \
      --data-urlencode 'permanently=true' \
      -H "Authorization: OAuth $YANDEX_DISK_TOKEN" \
      'https://cloud-api.yandex.net/v1/disk/resources' >/dev/null
  done < <(curl --fail --silent --show-error --get \
    --data-urlencode "path=app:/$disk_folder" --data-urlencode 'limit=1000' \
    -H "Authorization: OAuth $YANDEX_DISK_TOKEN" \
    'https://cloud-api.yandex.net/v1/disk/resources' | jq -r '._embedded.items[]?.name')
  metadata="$(curl --fail --silent --show-error -H "Authorization: OAuth $YANDEX_DISK_TOKEN" --get --data-urlencode "path=app:/$disk_folder/$artifact" --data-urlencode "overwrite=true" "https://cloud-api.yandex.net/v1/disk/resources/upload")"
  href="$(printf '%s' "$metadata" | plutil -extract href raw -)"
  curl --fail --silent --show-error --upload-file "$output/$artifact" "$href"
  yandex_status="app:/$disk_folder"
fi

nfs_status="not configured"
if [[ -n "${NFS_RELEASE_PATH:-}" ]]; then
  if [[ ! -d "$NFS_RELEASE_PATH" || ! -w "$NFS_RELEASE_PATH" ]]; then
    echo "NFS_RELEASE_PATH is not a writable mounted directory: $NFS_RELEASE_PATH" >&2
    exit 1
  fi
  cp "$output/$artifact" "$NFS_RELEASE_PATH/$artifact"
  nfs_status="$NFS_RELEASE_PATH"
fi

if ! git rev-parse -q --verify "refs/tags/$tag" >/dev/null; then
  git tag -a "$tag" "$commit" -m "KeyKeep $release ($short_commit)"
fi

printf 'KeyKeep release: %s\n' "$release"
printf 'Android versionName: %s\n' "$version"
printf 'Android versionCode: %s\n' "$build_number"
printf 'Git commit: %s\n' "$commit"
printf 'Git tag: %s\n' "$tag"
printf 'Local APK: %s/%s\n' "$root/$output" "$artifact"
printf 'Yandex Disk: %s/%s\n' "$yandex_status" "$artifact"
printf 'NFS: %s\n' "$nfs_status"
