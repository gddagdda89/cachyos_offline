#!/usr/bin/env bash
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
repo="$root/repo"
log="$root/logs/build-repository.log"

cd "$repo"
echo "==> 生成本地仓库数据库 offline.db.tar.zst" | tee "$log"
repo-add offline.db.tar.zst ./*.pkg.tar.zst 2>&1 | tee -a "$log"
rm -f ./*.old
echo "==> 完成：$(find . -name '*.pkg.tar.zst' | wc -l) 个包，共 $(du -sh . | cut -f1)" | tee -a "$log"