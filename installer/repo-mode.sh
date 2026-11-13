#!/usr/bin/env bash
# Installed as /usr/local/sbin/cachyos-repo-mode.
set -euo pipefail

write_repo_mode() {
    local mode=$1 config=$2 assets=$3 tmp
    [[ $mode == online || $mode == offline ]] || return 1
    # Do not silently discard edits made after installation.
    if [[ -f $config ]] && ! cmp -s "$config" "$assets/pacman-online.conf" && ! cmp -s "$config" "$assets/pacman-offline.conf"; then
        echo "pacman.conf 已被修改；请先合并修改到 $assets 下的配置，再切换。" >&2
        return 1
    fi
    tmp=$(mktemp "${config}.XXXXXX")
    if ! install -m644 "$assets/pacman-$mode.conf" "$tmp"; then
        rm -f "$tmp"
        return 1
    fi
    [[ ! -f $config ]] || cp -a "$config" "${config}.before-mode-switch"
    mv -f "$tmp" "$config"
}

switch_repo_mode() {
    local mode=$1 config=$2 assets=$3 repo=$4 name version installed
    if [[ $mode == offline ]]; then
        [[ -f $repo/offline.db ]] || { echo '离线仓库不存在' >&2; return 1; }
        # An old snapshot must not supply packages to a newer installed system.
        while read -r name version; do
            installed=$(pacman -Q "$name" 2>/dev/null) || continue
            [[ $installed == "$name $version" ]] || {
                echo "$name 已偏离离线快照；拒绝切回旧仓库。请制作匹配的新离线快照。" >&2
                return 1
            }
        done < "$assets/target-versions.txt"
    fi
    write_repo_mode "$mode" "$config" "$assets"
    if [[ $mode == online ]]; then
        echo '已禁用离线仓库，启用在线仓库；正在执行完整升级。'
        pacman -Syu || {
            echo '升级未完成，保留在线模式；修复网络/镜像后重新执行 sudo pacman -Syu。' >&2
            return 1
        }
    else
        echo '已启用离线仓库，禁用全部在线仓库。'
    fi
}

main() {
    [[ $EUID -eq 0 ]] || { echo '请用 sudo 运行' >&2; return 1; }
    [[ $# == 1 && ( $1 == online || $1 == offline ) ]] || {
        echo '用法: sudo cachyos-repo-mode online|offline' >&2; return 1;
    }
    switch_repo_mode "$1" /etc/pacman.conf /usr/local/share/cachyos-offline /opt/offline-repo
}

if [[ ${BASH_SOURCE[0]} == "$0" ]]; then main "$@"; fi
