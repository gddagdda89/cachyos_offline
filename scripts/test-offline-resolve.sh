#!/usr/bin/env bash
set -euo pipefail
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$root"
mkdir -p logs/db-offline-test/sync
cp repo/offline.db.tar.zst logs/db-offline-test/sync/offline.db
mapfile -t pkgs < <(grep -vE '^[[:space:]]*(#|$)' config/packages.txt)
pacman -Sp --noconfirm --config logs/pacman-offline-test.conf --dbpath logs/db-offline-test "${pkgs[@]}" \
    > logs/offline-resolve-test.txt 2> logs/offline-resolve-test.err
echo "解析出 $(wc -l < logs/offline-resolve-test.txt) 个包"