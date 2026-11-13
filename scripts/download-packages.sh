#!/usr/bin/env bash
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
conf="$root/config/pacman-v3.conf"
repo="$root/repo"
db="$root/db"
log="$root/logs/download-packages.log"

mkdir -p "$repo" "$db" "$root/logs"

mapfile -t pkgs < <(grep -vE '^[[:space:]]*(#|$)' "$root/config/packages.txt")

echo "==> 同步仓库数据库（独立 dbpath: $db）" | tee "$log"
sudo pacman -Sy --config "$conf" --dbpath "$db" 2>&1 | tee -a "$log"

echo "==> 解析依赖，生成版本清单 logs/manifest.txt" | tee -a "$log"
pacman -Sp --noconfirm --config "$conf" --dbpath "$db" "${pkgs[@]}" 2>>"$log" \
    | sed 's|.*/||' | sort > "$root/logs/manifest.txt"
echo "    解析出 $(wc -l < "$root/logs/manifest.txt") 个包（含依赖）" | tee -a "$log"

echo "==> 下载包与签名到 $repo" | tee -a "$log"
sudo pacman -Sw --noconfirm --config "$conf" --dbpath "$db" --cachedir "$repo" --needed "${pkgs[@]}" 2>&1 | tee -a "$log"

sudo chown -R "$USER:$USER" "$repo" "$db"
echo "==> 完成：repo 内 $(find "$repo" -name '*.pkg.tar.zst' | wc -l) 个包，$(du -sh "$repo" | cut -f1)" | tee -a "$log"