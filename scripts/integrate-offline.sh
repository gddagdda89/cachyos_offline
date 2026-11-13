#!/usr/bin/env bash
# 把离线仓库 + 安装器集成进官方 ISO profile（无需 sudo，产物均在项目内）
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
profile="$root/CachyOS-Live-ISO/archiso"
airootfs="$profile/airootfs"
log="$root/logs/integrate-offline.log"

[[ -f $root/repo/offline.db.tar.zst ]] || { echo "请先运行 scripts/download-packages.sh 和 scripts/build-repository.sh"; exit 1; }
[[ -f $root/installer/offline-install.sh ]] || { echo "缺少 installer/offline-install.sh"; exit 1; }

# 官方克隆固定 commit（复现构建用）。缺失时给出克隆命令：
#   git clone https://github.com/CachyOS/CachyOS-Live-ISO.git
#   git -C CachyOS-Live-ISO checkout 3215497d2e8c5fea90e185affcf973dfa2cf790b
upstream_commit="3215497d2e8c5fea90e185affcf973dfa2cf790b"
[[ -d $root/CachyOS-Live-ISO/.git ]] || { echo "缺少官方克隆 CachyOS-Live-ISO（见脚本头部注释的克隆命令）"; exit 1; }
head_commit=$(git -C "$root/CachyOS-Live-ISO" rev-parse HEAD)
[[ $head_commit == "$upstream_commit" ]] || echo "警告: 官方克隆 HEAD=$head_commit 与固定 commit $upstream_commit 不一致"

{
    echo "==> 集成离线仓库到 airootfs/opt/offline-repo"
    rm -rf "$airootfs/opt/offline-repo"
    mkdir -p "$airootfs/opt/offline-repo"
    cp -a "$root/repo/." "$airootfs/opt/offline-repo/"

    echo "==> 安装离线安装器到 airootfs/opt/offline-install"
    mkdir -p "$airootfs/opt/offline-install"
    install -m755 "$root/installer/offline-install.sh" "$airootfs/opt/offline-install/offline-install.sh"
    install -m644 "$root/config/packages.txt" "$airootfs/opt/offline-install/packages.txt"
    install -m644 "$root/installer/pacman-offline.conf" "$airootfs/opt/offline-install/pacman-offline.conf"

    echo "==> 桌面快捷方式与应用菜单入口"
    mkdir -p "$airootfs/usr/share/applications" "$airootfs/etc/skel/Desktop"
    install -m644 "$root/installer/cachyos-offline-installer.desktop" "$airootfs/usr/share/applications/"
    install -m755 "$root/installer/cachyos-offline-installer.desktop" "$airootfs/etc/skel/Desktop/"

    echo "==> 构建期 hook：移除 Hello 自启动（其在线安装按钮断网时误导用户）"
    mkdir -p "$airootfs/etc/pacman.d/hooks"
    install -m644 "$root/installer/no-hello-autostart.hook" "$airootfs/etc/pacman.d/hooks/zz-offline-no-hello-autostart.hook"

    echo "==> 更新 profiledef.sh 文件权限"
    if ! grep -q 'offline-install/offline-install.sh' "$profile/profiledef.sh"; then
        sed -i '/^file_permissions=(/a\  ["/opt/offline-install/offline-install.sh"]="0:0:755"\n  ["/etc/skel/Desktop/cachyos-offline-installer.desktop"]="0:0:755"' "$profile/profiledef.sh"
    fi

    echo "==> 构建缓存指向项目内 pkg-cache（产物不落主机目录）"
    mkdir -p "$root/pkg-cache"
    if grep -q '^CacheDir' "$profile/pacman.conf"; then
        sed -i "s|^CacheDir.*|CacheDir     = $root/pkg-cache/|" "$profile/pacman.conf"
    else
        sed -i "/^#CacheDir/a CacheDir     = $root/pkg-cache/" "$profile/pacman.conf"
    fi

    echo "==> 集成完成：$(find "$airootfs/opt/offline-repo" -name '*.pkg.tar.zst' | wc -l) 个包，$(du -sh "$airootfs/opt/offline-repo" | cut -f1)"
} 2>&1 | tee "$log"