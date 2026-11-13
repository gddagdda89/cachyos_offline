#!/usr/bin/env bash
# Build from the pinned Git tree, without modifying the upstream checkout.
set -euo pipefail
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
exec python3 "$root/scripts/release.py" integrate
