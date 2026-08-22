#!/usr/bin/env bash
set -euo pipefail

# Creates an installable local artifact without publishing or changing Git.
root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$root"

release="$(sed -nE 's/^version: ([0-9]+\.[0-9]+\.[0-9]+\+[0-9]+)$/\1/p' pubspec.yaml)"
if [[ -z "$release" ]]; then
  echo "Could not read version from pubspec.yaml." >&2
  exit 1
fi

flutter build apk --debug
artifact="KeyKeep-v$release-debug.apk"
mkdir -p releases
cp build/app/outputs/flutter-apk/app-debug.apk "releases/$artifact"
shasum -a 256 "releases/$artifact" > "releases/$artifact.sha256"
echo "Local debug-signed artifact: releases/$artifact"
