#!/usr/bin/env bash
set -euo pipefail

# Backwards-compatible entry point used by the post-commit hook.
# The release itself is built and published by GitHub Actions.
root="$(cd "$(dirname "$0")/.." && pwd)"
exec "$root/scripts/release.sh"
