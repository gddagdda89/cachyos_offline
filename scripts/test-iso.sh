#!/usr/bin/env bash
# 断网 QEMU 测试虚拟机
# 用法: ./scripts/test-iso.sh uefi|bios [ISO路径]   从 ISO 启动（安装测试）
#       ./scripts/test-iso.sh disk-uefi|disk-bios   从已安装磁盘启动（验证安装结果）
# 产物均在 vm/ 内；配合 scripts/qmp-tool.py 截图/按键/关机
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
mode="${1:-uefi}"
iso="${2:-$root/output/CachyOS-Offline.iso}"

case "$mode" in
    uefi|bios)
        [[ -f $iso ]] || { echo "ISO 不存在: $iso"; exit 1; }
        disk="$root/vm/test-${mode#disk-}.qcow2"
        ;;
    disk-uefi|disk-bios)
        disk="$root/vm/test-${mode#disk-}.qcow2"
        [[ -f $disk ]] || { echo "磁盘不存在: $disk（请先完成安装测试）"; exit 1; }
        ;;
    *)
        echo "用法: $0 uefi|bios|disk-uefi|disk-bios [ISO路径]"; exit 1
        ;;
esac

mkdir -p "$root/vm"
sock="$root/vm/qmp-$mode.sock"
rm -f "$sock"
[[ -f $disk ]] || qemu-img create -f qcow2 "$disk" 20G

fw=()
if [[ $mode == uefi || $mode == disk-uefi ]]; then
    code=/usr/share/edk2/x64/OVMF_CODE.4m.fd
    vars="$root/vm/OVMF_VARS-uefi.fd"
    [[ -f $code ]] || { echo "缺少 OVMF: sudo pacman -S edk2-ovmf"; exit 1; }
    [[ -f $vars ]] || cp /usr/share/edk2/x64/OVMF_VARS.4m.fd "$vars"
    fw=(-drive "if=pflash,format=raw,readonly=on,file=$code" -drive "if=pflash,format=raw,file=$vars")
fi

cdrom=()
if [[ $mode == uefi || $mode == bios ]]; then
    cdrom=(-drive "file=$iso,media=cdrom,readonly=on")
fi

qemu-system-x86_64 -enable-kvm -cpu host -smp 4 -m 4G \
    -nic none \
    "${cdrom[@]}" \
    -drive "file=$disk,if=virtio,format=qcow2" \
    "${fw[@]}" \
    -display none -daemonize \
    -qmp "unix:$sock,server,nowait" \
    -name "cachyos-test-$mode"

echo "==> VM 已启动（$mode，断网，磁盘 $disk）"
echo "    截图: python3 scripts/qmp-tool.py $sock shot $root/vm/$mode-1.png"
echo "    按键: python3 scripts/qmp-tool.py $sock type 'sudo /opt/offline-install/offline-install.sh'"
echo "    回车: python3 scripts/qmp-tool.py $sock key ret"
echo "    关机: python3 scripts/qmp-tool.py $sock powerdown"