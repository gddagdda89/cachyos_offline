#!/usr/bin/env bash
set -euo pipefail
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# Checks both target and Live closures using throwaway empty databases.
exec python3 "$root/scripts/release.py" verify
