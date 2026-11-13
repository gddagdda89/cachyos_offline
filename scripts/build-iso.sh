#!/usr/bin/env bash
# 一键构建离线 ISO：集成离线内容 -> 官方 buildiso.sh -> 产物复制到 output/
# 用法: ./scripts/build-iso.sh   （只需输入一次 sudo 密码，构建与复制共用同一 sudo 会话）
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
log="$root/logs/build-iso.log"
marker="$root/logs/.build-start"

"$root/scripts/integrate-offline.sh"

touch "$marker"
echo "==> 开始构建 ISO（sudo，构建+复制同一会话）" | tee "$log"
# buildiso.sh 的 EXIT trap 成功时也会打印 ERROR 文案并返回非零，故以产物为准。
# 构建约 8 分钟，超过 sudo 密码缓存时限，因此构建与复制放在同一个 sudo 会话内。
sudo bash -c '
    cd "$1/CachyOS-Live-ISO" || exit 1
    ./buildiso.sh -p desktop -v
    iso=$(find out -name "*.iso" -newer "$2" 2>/dev/null | head -1)
    if [[ -z $iso || ! -f $iso ]]; then
        echo "==> 构建失败：未找到新 ISO"
        exit 1
    fi
    mkdir -p "$1/output"
    cp --reflink=auto "$iso" "$1/output/CachyOS-Offline.iso"
    chown "$3:$3" "$1/output/CachyOS-Offline.iso"
    echo "==> 已复制到 output/CachyOS-Offline.iso"
' bash "$root" "$marker" "$USER" 2>&1 | tee -a "$log"

( cd "$root/output" && sha256sum CachyOS-Offline.iso > CachyOS-Offline.iso.sha256 )
echo "==> 完成: output/CachyOS-Offline.iso ($(du -h "$root/output/CachyOS-Offline.iso" | cut -f1))" | tee -a "$log"