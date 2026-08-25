#!/usr/bin/env bash
set -euo pipefail

# Backwards-compatible entry point for publishing the current Git commit.
root="$(cd "$(dirname "$0")/.." && pwd)"
exec "$root/scripts/publish_commit.sh"
