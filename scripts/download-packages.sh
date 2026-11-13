#!/usr/bin/env bash
# No implicit rolling-repository refresh: rebuilds consume an immutable snapshot.
set -euo pipefail
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
if [[ $# == 2 && $1 == --refresh ]]; then
    exec python3 "$root/scripts/release.py" freeze "$2"
elif [[ $# == 2 && $1 == --import-current ]]; then
    exec python3 "$root/scripts/release.py" freeze "$2" --import-current
elif [[ $# == 0 ]]; then
    exec python3 "$root/scripts/release.py" verify
else
    echo '用法: download-packages.sh [--refresh 新发布编号 | --import-current 首次迁移编号]' >&2
    exit 1
fi
