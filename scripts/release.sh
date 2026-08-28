#!/usr/bin/env bash
set -euo pipefail

# Validates main, starts the protected GitHub release workflow, waits for it,
# then downloads the published APK to the local Release folder.
root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$root"

repository="${GITHUB_REPOSITORY:-Multsev/keykeep}"
workflow="release.yml"
releases_to_keep="${RELEASES_TO_KEEP:-4}"

if ! [[ "$releases_to_keep" =~ ^[1-9][0-9]*$ ]]; then
  echo 'RELEASES_TO_KEEP must be a positive integer.' >&2
  exit 1
fi
if [[ "$(git branch --show-current)" != 'main' ]]; then
  echo 'Releases can be started only from main.' >&2
  exit 1
fi
if [[ -n "$(git status --porcelain)" ]]; then
  echo 'Commit or discard local changes before starting a release.' >&2
  exit 1
fi

command -v gh >/dev/null || {
  echo 'GitHub CLI is required: https://cli.github.com/' >&2
  exit 1
}
gh auth status >/dev/null

dart format --output=none --set-exit-if-changed lib test
flutter analyze
flutter test
git diff --check

git fetch origin --prune
if ! git merge-base --is-ancestor origin/main main; then
  echo 'Local main does not contain the current origin/main.' >&2
  exit 1
fi
git push origin main --follow-tags

head_sha="$(git rev-parse HEAD)"
gh workflow run "$workflow" --repo "$repository" --ref main

run_id=''
for _ in {1..30}; do
  run_id="$(gh run list \
    --repo "$repository" \
    --workflow "$workflow" \
    --event workflow_dispatch \
    --branch main \
    --commit "$head_sha" \
    --limit 1 \
    --json databaseId \
    --jq '.[0].databaseId // empty')"
  [[ -n "$run_id" ]] && break
  sleep 2
done
if [[ -z "$run_id" ]]; then
  echo 'GitHub accepted the workflow but its run was not found.' >&2
  exit 1
fi

gh run watch "$run_id" --repo "$repository" --exit-status

tag="$(gh release list \
  --repo "$repository" \
  --limit 1 \
  --json tagName,publishedAt \
  --jq 'sort_by(.publishedAt) | last.tagName')"
if ! [[ "$tag" =~ ^build/v0\.[0-9]{6}\.[0-9]{2}$ ]]; then
  echo "Unexpected GitHub release tag: $tag" >&2
  exit 1
fi

download_dir="$(mktemp -d)"
trap 'rm -rf "$download_dir"' EXIT
gh release download "$tag" \
  --repo "$repository" \
  --pattern 'KeyKeep-v*.apk' \
  --dir "$download_dir"

apk="$(find "$download_dir" -maxdepth 1 -type f -name 'KeyKeep-v*.apk' -print -quit)"
if [[ -z "$apk" ]]; then
  echo 'The GitHub Release does not contain a KeyKeep APK.' >&2
  exit 1
fi

mkdir -p Release
cp "$apk" "Release/$(basename "$apk")"

# This pipeline owns KeyKeep APKs only; other files are untouched.
shopt -s nullglob
releases=(Release/KeyKeep-v*.apk)
shopt -u nullglob
if (( ${#releases[@]} > releases_to_keep )); then
  while IFS= read -r obsolete; do
    [[ -z "$obsolete" ]] && continue
    rm -f -- "$obsolete"
    echo "Removed local obsolete release: $(basename "$obsolete")"
  done < <(ls -1t "${releases[@]}" | tail -n "+$((releases_to_keep + 1))")
fi

git fetch origin --tags --force
printf 'KeyKeep release: %s\n' "${tag#build/v}"
printf 'GitHub: https://github.com/%s/releases/tag/%s\n' "$repository" "$tag"
printf 'Local APK: %s/Release/%s\n' "$root" "$(basename "$apk")"
