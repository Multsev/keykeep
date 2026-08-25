#!/usr/bin/env bash
set -euo pipefail

# Releases are commit-based. The post-commit hook invokes this same pipeline;
# this command retries publication of HEAD if necessary.
root="$(cd "$(dirname "$0")/.." && pwd)"
exec "$root/scripts/publish_commit.sh"
