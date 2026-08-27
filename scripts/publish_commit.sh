#!/usr/bin/env bash
set -euo pipefail

# Builds a compact, debug-signed calendar-versioned APK for personal development
# and mirrors the same APK to the local Release folder and Yandex Disk.
root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$root"

if [[ -f .env ]]; then
  set -a
  source .env
  set +a
fi

commit="$(git rev-parse HEAD)"
short_commit="$(git rev-parse --short=12 HEAD)"
date_part="$(TZ=Europe/Moscow date '+%d%m%y')"
code_date="$(TZ=Europe/Moscow date '+%y%m%d')"
version_base="0.$date_part"
tag_prefix="build/v$version_base"

prune_release_folder() {
  local directory="$1"
  local candidate name
  local -a releases=()

  # This pipeline owns KeyKeep APKs only; other files are untouched.
  shopt -s nullglob
  for candidate in "$directory"/KeyKeep-v*.apk; do
    name="${candidate##*/}"
    if [[ "$name" =~ ^KeyKeep-v0\.[0-9]{6}\.[0-9]{2}\.apk$ ]]; then
      releases+=("$candidate")
    else
      # Removes the previous unnumbered release format so it cannot be mistaken
      # for the newest build.
      rm -f -- "$candidate"
    fi
  done
  shopt -u nullglob

  if (( ${#releases[@]} > 4 )); then
    while IFS= read -r candidate; do
      rm -f -- "$candidate"
    done < <(ls -1t "${releases[@]}" | tail -n +5)
  fi
}

release_sequence_from_tag() {
  local tag="$1"
  local suffix="${tag#build/v$version_base}"
  case "$suffix" in
    .[0-9]*) printf '%s\n' "${suffix#.}" ;;
    -b[0-9]*) printf '%s\n' "${suffix#-b}" ;;
  esac
}

existing_tag="$(git tag --points-at "$commit" --list "$tag_prefix.*" | sort -V | tail -n 1)"
if [[ -n "$existing_tag" ]]; then
  sequence="$(release_sequence_from_tag "$existing_tag")"
else
  highest=0
  while IFS= read -r tag; do
    candidate="$(release_sequence_from_tag "$tag")"
    if [[ "$candidate" =~ ^[0-9]+$ ]] && (( 10#$candidate > highest )); then
      highest=$((10#$candidate))
    fi
  done < <(git tag --list "$tag_prefix*")
  shopt -s nullglob
  for apk in Release/KeyKeep-v"$version_base".*.apk; do
    candidate="${apk##*.}"
    candidate="${candidate%.apk}"
    if [[ "$candidate" =~ ^[0-9]+$ ]] && (( 10#$candidate > highest )); then
      highest=$((10#$candidate))
    fi
  done
  shopt -u nullglob
  sequence=$((highest + 1))
fi
build_number="$code_date$(printf '%02d' "$((10#$sequence))")"
version="$version_base.$(printf '%02d' "$sequence")"
build_date="$(TZ=Europe/Moscow date '+%Y-%m-%d %H:%M %Z')"
output="Release"
tag="build/v$version"

flutter analyze
flutter test
build_args=(--release --target-platform=android-arm64 --build-name="$version" --build-number="$build_number" --dart-define="APP_RELEASE_VERSION=$version" --dart-define="APP_BUILD_DATE=$build_date")
if [[ -n "${YANDEX_OAUTH_CLIENT_ID:-}" ]]; then
  build_args+=(--dart-define="YANDEX_OAUTH_CLIENT_ID=$YANDEX_OAUTH_CLIENT_ID")
fi
flutter build apk "${build_args[@]}"

mkdir -p "$output"
artifact="KeyKeep-v$version.apk"
cp "build/app/outputs/flutter-apk/app-release.apk" "$output/$artifact"
prune_release_folder "$output"

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
  # Upload first: a failure never deletes a previous successful release.
  metadata="$(curl --fail --silent --show-error -H "Authorization: OAuth $YANDEX_DISK_TOKEN" --get --data-urlencode "path=app:/$disk_folder/$artifact" --data-urlencode "overwrite=true" "https://cloud-api.yandex.net/v1/disk/resources/upload")"
  href="$(printf '%s' "$metadata" | plutil -extract href raw -)"
  curl --fail --silent --show-error --upload-file "$output/$artifact" "$href"

  # Remove obsolete unnumbered names, then keep the four newest numbered APKs.
  remote_items="$(curl --fail --silent --show-error --get \
    --data-urlencode "path=app:/$disk_folder" --data-urlencode 'limit=1000' \
    -H "Authorization: OAuth $YANDEX_DISK_TOKEN" \
    'https://cloud-api.yandex.net/v1/disk/resources')"
  while IFS= read -r name; do
    [[ -z "$name" ]] && continue
    curl --fail --silent --show-error --request DELETE --get \
      --data-urlencode "path=app:/$disk_folder/$name" \
      --data-urlencode 'permanently=true' \
      -H "Authorization: OAuth $YANDEX_DISK_TOKEN" \
      'https://cloud-api.yandex.net/v1/disk/resources' >/dev/null
  done < <(printf '%s' "$remote_items" | jq -r '
    ._embedded.items[]?
    | select(.type == "file")
    | select(.name | test("^KeyKeep-v"))
    | select(.name | test("^KeyKeep-v0\\.[0-9]{6}\\.[0-9]{2}\\.apk$") | not)
    | .name')
  while IFS= read -r name; do
    [[ -z "$name" ]] && continue
    curl --fail --silent --show-error --request DELETE --get \
      --data-urlencode "path=app:/$disk_folder/$name" \
      --data-urlencode 'permanently=true' \
      -H "Authorization: OAuth $YANDEX_DISK_TOKEN" \
      'https://cloud-api.yandex.net/v1/disk/resources' >/dev/null
  done < <(printf '%s' "$remote_items" | jq -r '
    [._embedded.items[]?
      | select(.type == "file")
      | select(.name | test("^KeyKeep-v0\\.[0-9]{6}\\.[0-9]{2}\\.apk$"))
      | [.modified, .name]]
    | sort_by(.[0]) | reverse | .[4:][]? | .[1]')
  yandex_status="app:/$disk_folder"
fi

if ! git rev-parse -q --verify "refs/tags/$tag" >/dev/null; then
  git tag -a "$tag" "$commit" -m "KeyKeep $version ($short_commit)"
fi

printf 'KeyKeep release: %s\n' "$version"
printf 'Android versionName: %s\n' "$version"
printf 'Android versionCode: %s\n' "$build_number"
printf 'Git commit: %s\n' "$commit"
printf 'Git tag: %s\n' "$tag"
printf 'Local APK: %s/%s\n' "$root/$output" "$artifact"
printf 'Yandex Disk: %s/%s\n' "$yandex_status" "$artifact"
