#!/usr/bin/env bash
# The package snapshot is prepared separately; this step never syncs online repos.
set -euo pipefail
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
"$root/scripts/integrate-offline.sh"
mkdir -p "$root/logs" "$root/output"
# Never reuse mkarchiso run-once markers from another build/profile.
work=$(mktemp -d "$root/work/build.XXXXXX")
iso_out=$(mktemp -d "$root/work/iso.XXXXXX")
release=$(cat "$root/config/release")
epoch=$(python3 -c 'import json, sys; print(json.load(open(sys.argv[1]))["source_date_epoch"])' "$root/releases/$release.json")
sudo env SOURCE_DATE_EPOCH="$epoch" mkarchiso -v -w "$work" -o "$iso_out" "$root/work/profile" 2>&1 | tee "$root/logs/build-iso.log"
python3 "$root/scripts/release.py" check-pkglist "$work/iso/arch/pkglist.x86_64.txt"
mapfile -t isos < <(find "$iso_out" -maxdepth 1 -name '*.iso' -type f)
[[ ${#isos[@]} == 1 ]] || { echo '构建失败：未得到唯一 ISO' >&2; exit 1; }
cp --reflink=auto "${isos[0]}" "$root/output/CachyOS-Offline.iso"
(cd "$root/output" && sha256sum CachyOS-Offline.iso > CachyOS-Offline.iso.sha256)
echo "==> 完成: $root/output/CachyOS-Offline.iso"
echo "构建目录保留在 $work；确认后可自行删除。"
