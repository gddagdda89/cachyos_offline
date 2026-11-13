#!/usr/bin/env bash
# CachyOS 离线安装器：在 Live 环境中运行，从 /opt/offline-repo 离线安装系统到磁盘
# 模式1 整盘自动：擦除所选磁盘并自动分区（GPT: BIOS boot + EFI + Btrfs）
# 模式2 共存手动：保留其它分区/Windows，仅格式化指定的 root 分区，复用已有 EFI 分区
# 用法: sudo /opt/offline-install/offline-install.sh
set -euo pipefail

REPO=/opt/offline-repo
INSTDIR=/opt/offline-install
MNT=/mnt
LOG=/var/log/offline-install.log

exec > >(tee -a "$LOG") 2>&1

die() { echo "错误: $*" >&2; exit 1; }
trap 'echo; echo "!! 安装中断，请查看日志: $LOG"; echo "!! 若已挂载目标分区，可执行 umount -R /mnt 后重试"' ERR

[[ $EUID -eq 0 ]] || die "请用 sudo 运行"
[[ -f $REPO/offline.db ]] || die "未找到离线仓库: $REPO"
[[ -f $INSTDIR/packages.txt ]] || die "未找到包清单: $INSTDIR/packages.txt"

echo "=============================================="
echo " CachyOS 离线安装器 (ISO: $(cat /etc/version-tag 2>/dev/null || echo unknown))"
echo "=============================================="

# 密钥环（正常已由 pacman-init.service 在开机时初始化）
if [[ ! -f /etc/pacman.d/gnupg/pubring.gpg ]]; then
    echo "==> 初始化 live 密钥环"
    pacman-key --init
    pacman-key --populate archlinux cachyos
fi

if [[ -d /sys/firmware/efi ]]; then
    echo "==> Live 启动模式: UEFI"
    EFI_NVRAM_FLAG=""
else
    echo "==> Live 启动模式: BIOS（仍会安装 UEFI 引导，使用可移动设备回退路径）"
    EFI_NVRAM_FLAG="--no-nvram"
fi

# ---- 选择安装模式 ----
echo
echo "==> 安装模式:"
echo "  1) 整盘自动安装 —— 擦除所选磁盘全部数据，自动分区"
echo "  2) 与已有系统共存 —— 保留 Windows/其它分区，手动指定 root 分区，复用已有 EFI 分区"
read -rp "选择模式 (1/2) [1]: " MODE
MODE=${MODE:-1}
[[ $MODE == 1 || $MODE == 2 ]] || die "无效模式"

# ---- 选择磁盘 ----
boot_src=$(findmnt -n -o SOURCE /run/archiso/bootmnt 2>/dev/null || true)
boot_disk=""
[[ -n $boot_src ]] && boot_disk=$(lsblk -no PKNAME "$boot_src" 2>/dev/null | head -1)

mapfile -t candidates < <(lsblk -dno NAME,TYPE | awk -v bd="$boot_disk" '$2=="disk" && $1 !~ /^(zram|fd|loop|sr)/ && $1!=bd {print $1}')
((${#candidates[@]})) || die "未找到可安装的磁盘（已排除 live 启动盘）"

echo "==> 可用磁盘:"
for i in "${!candidates[@]}"; do
    printf '  %d) /dev/%s\t%s\n' "$((i+1))" "${candidates[$i]}" "$(lsblk -dno SIZE,MODEL "/dev/${candidates[$i]}")"
done
read -rp "输入要安装到的磁盘编号 (1-${#candidates[@]}): " sel
[[ $sel =~ ^[0-9]+$ ]] && (( sel >= 1 && sel <= ${#candidates[@]} )) || die "无效选择"
DISK="/dev/${candidates[$((sel-1))]}"

EFI=""
if [[ $MODE == 1 ]]; then
    if lsblk -no MOUNTPOINTS "$DISK" | grep -q '[^[:space:]]'; then
        die "$DISK 存在已挂载的分区，请先卸载"
    fi
    echo
    lsblk "$DISK"
    echo
    echo "!!! 即将擦除 $DISK 上的全部数据（所有分区）!!!"
    read -rp "输入 YES 确认: " confirm
    [[ $confirm == YES ]] || die "已取消"

    read -rp "主机名 [cachyos-pc]: " HOSTNAME
    HOSTNAME=${HOSTNAME:-cachyos-pc}
    [[ $HOSTNAME =~ ^[a-zA-Z0-9-]+$ ]] || die "主机名无效"
    read -rp "新建用户名 [user]: " USERNAME
    USERNAME=${USERNAME:-user}
    [[ $USERNAME =~ ^[a-z_][a-z0-9_-]*$ ]] || die "用户名无效"

    case "$DISK" in
        *nvme*|*mmcblk*|*loop*) P="${DISK}p" ;;
        *) P="$DISK" ;;
    esac
    EFI="${P}2"; ROOT="${P}3"

    echo "==> 分区: GPT (1M BIOS boot + 1G EFI + 剩余 Btrfs)"
    swapoff -a 2>/dev/null || true
    wipefs -af "$DISK"
    sgdisk --zap-all "$DISK"
    sgdisk -n 1:0:+1M -t 1:ef02 -c 1:BIOS-BOOT "$DISK"
    sgdisk -n 2:0:+1G -t 2:ef00 -c 2:EFI "$DISK"
    sgdisk -n 3:0:0   -t 3:8300 -c 3:ROOT "$DISK"
    partprobe "$DISK" 2>/dev/null || true
    udevadm settle --timeout=15
    [[ -b $EFI && -b $ROOT ]] || die "分区节点未出现: $EFI / $ROOT"

    echo "==> 格式化"
    mkfs.fat -F32 -n EFI "$EFI"
    mkfs.btrfs -f -L CachyOS "$ROOT"
else
    # ---- 共存模式：不擦盘，选 root 分区，复用已有 EFI 分区 ----
    echo
    echo "==> $DISK 现有分区（共存模式不会改动分区表）:"
    mapfile -t parts < <(lsblk -lno NAME,TYPE "$DISK" | awk '$2=="part"{print $1}')
    ((${#parts[@]})) || die "$DISK 没有分区；共存模式需要已有分区表（含 Windows 与预留的 Linux 分区）"

    ESP_NAME=""
    for p in "${parts[@]}"; do
        pt=$(lsblk -no PARTTYPE "/dev/$p" | tr -d '[:space:]')
        [[ $pt == c12a7328-f81f-11d2-ba4b-00a0c93ec93b ]] && { ESP_NAME=$p; break; }
    done
    if [[ -z $ESP_NAME ]]; then
        for p in "${parts[@]}"; do
            fs=$(lsblk -no FSTYPE "/dev/$p" | tr -d '[:space:]')
            [[ $fs == vfat ]] && { ESP_NAME=$p; break; }
        done
    fi

    for i in "${!parts[@]}"; do
        p=${parts[$i]}
        tag=""
        [[ $p == "$ESP_NAME" ]] && tag="  <-- EFI 分区（将复用，不格式化）"
        printf '  %d) /dev/%s\t%s%s\n' "$((i+1))" "$p" "$(lsblk -no SIZE,FSTYPE,PARTLABEL "/dev/$p")" "$tag"
    done
    read -rp "输入作为 Linux root 的分区编号 (1-${#parts[@]}): " rsel
    [[ $rsel =~ ^[0-9]+$ ]] && (( rsel >= 1 && rsel <= ${#parts[@]} )) || die "无效选择"
    ROOT="/dev/${parts[$((rsel-1))]}"
    [[ $ROOT != "/dev/$ESP_NAME" ]] || die "不能把 EFI 分区作为 root"
    rfs=$(lsblk -no FSTYPE "$ROOT" | tr -d '[:space:]')
    case "$rfs" in
        ntfs|exfat|vfat|msdos|swap) die "$ROOT 是 Windows/EFI/swap 分区（$rfs），不能用作 root；请选择预留的 Linux 分区" ;;
    esac
    if lsblk -no MOUNTPOINTS "$ROOT" | grep -q '[^[:space:]]'; then
        die "$ROOT 已挂载，请先卸载"
    fi

    if [[ -n $ESP_NAME ]]; then
        EFI="/dev/$ESP_NAME"
    elif [[ -d /sys/firmware/efi ]]; then
        die "UEFI 共存需要已有 EFI 分区（通常为 Windows 的 ESP）；未找到"
    fi

    echo
    lsblk "$DISK"
    echo
    echo "!!! 即将仅格式化 $ROOT 为 Btrfs；其余分区（含 Windows）保持不变 !!!"
    [[ -n $EFI ]] && echo "!!! EFI 分区 $EFI 只挂载不格式化 !!!"
    read -rp "输入 YES 确认: " confirm
    [[ $confirm == YES ]] || die "已取消"

    read -rp "主机名 [cachyos-pc]: " HOSTNAME
    HOSTNAME=${HOSTNAME:-cachyos-pc}
    [[ $HOSTNAME =~ ^[a-zA-Z0-9-]+$ ]] || die "主机名无效"
    read -rp "新建用户名 [user]: " USERNAME
    USERNAME=${USERNAME:-user}
    [[ $USERNAME =~ ^[a-z_][a-z0-9_-]*$ ]] || die "用户名无效"

    echo "==> 仅格式化 root 分区 $ROOT"
    swapoff -a 2>/dev/null || true
    mkfs.btrfs -f -L CachyOS "$ROOT"
fi

echo "==> 创建 Btrfs 子卷并挂载"
mount "$ROOT" "$MNT"
for sv in @ @home @cache @log @snapshots; do btrfs subvolume create "$MNT/$sv"; done
umount "$MNT"
OPTS=noatime,compress=zstd:1
mount -o subvol=@,$OPTS "$ROOT" "$MNT"
mkdir -p "$MNT"/{home,var/cache,var/log,.snapshots,boot/efi}
mount -o subvol=@home,$OPTS "$ROOT" "$MNT/home"
mount -o subvol=@cache,$OPTS "$ROOT" "$MNT/var/cache"
mount -o subvol=@log,$OPTS "$ROOT" "$MNT/var/log"
mount -o subvol=@snapshots,$OPTS "$ROOT" "$MNT/.snapshots"
if [[ -n $EFI ]]; then
    mount "$EFI" "$MNT/boot/efi"
fi

echo "==> pacstrap 安装系统（离线仓库，约 680 个包）"
mapfile -t PKGS < <(grep -vE '^[[:space:]]*(#|$)' "$INSTDIR/packages.txt")
pacstrap -c -C "$INSTDIR/pacman-offline.conf" "$MNT" "${PKGS[@]}"

genfstab -U "$MNT" >> "$MNT/etc/fstab"

echo "==> 设置 root 密码"
until arch-chroot "$MNT" passwd; do echo "密码设置失败，请重试"; done

# ---- 引导命令按模式/固件组合 ----
GRUB_BIOS_CMD=""
GRUB_EFI_CMD=""
GRUB_FALLBACK_CMD=""
OS_PROBER="true"
if [[ $MODE == 1 ]]; then
    GRUB_BIOS_CMD="grub-install --target=i386-pc --recheck $DISK"
    GRUB_EFI_CMD="grub-install --target=x86_64-efi --efi-directory=/boot/efi --bootloader-id=CachyOS $EFI_NVRAM_FLAG --recheck"
    GRUB_FALLBACK_CMD="mkdir -p /boot/efi/EFI/BOOT && cp /boot/efi/EFI/CachyOS/grubx64.efi /boot/efi/EFI/BOOT/BOOTX64.EFI"
else
    OS_PROBER="false"
    if [[ -n $EFI ]]; then
        GRUB_EFI_CMD="grub-install --target=x86_64-efi --efi-directory=/boot/efi --bootloader-id=CachyOS $EFI_NVRAM_FLAG --recheck"
    else
        GRUB_BIOS_CMD="grub-install --target=i386-pc --recheck $DISK"
    fi
fi

echo "==> 配置系统（语言/时区/用户/引导/服务）"
arch-chroot "$MNT" /bin/bash -euo pipefail <<CHROOT_EOF
ln -sf /usr/share/zoneinfo/Asia/Shanghai /etc/localtime
hwclock --systohc
sed -i 's/^#zh_CN.UTF-8 UTF-8/zh_CN.UTF-8 UTF-8/; s/^#en_US.UTF-8 UTF-8/en_US.UTF-8 UTF-8/' /etc/locale.gen
locale-gen
echo 'LANG=zh_CN.UTF-8' > /etc/locale.conf
echo '$HOSTNAME' > /etc/hostname
printf '127.0.0.1\tlocalhost\n::1\t\tlocalhost\n127.0.1.1\t%s.localdomain\t%s\n' '$HOSTNAME' '$HOSTNAME' > /etc/hosts
useradd -m -G wheel -s /bin/bash '$USERNAME'
sed -i 's/^# %wheel ALL=(ALL) ALL/%wheel ALL=(ALL) ALL/; s/^# %wheel ALL=(ALL:ALL) ALL/%wheel ALL=(ALL:ALL) ALL/' /etc/sudoers
mkinitcpio -P
$GRUB_BIOS_CMD
$GRUB_EFI_CMD
$GRUB_FALLBACK_CMD
sed -i 's/^GRUB_CMDLINE_LINUX_DEFAULT=.*/GRUB_CMDLINE_LINUX_DEFAULT="loglevel=3 quiet"/' /etc/default/grub
if grep -q '^GRUB_DISABLE_OS_PROBER=' /etc/default/grub; then
    sed -i 's/^GRUB_DISABLE_OS_PROBER=.*/GRUB_DISABLE_OS_PROBER=$OS_PROBER/' /etc/default/grub
else
    echo 'GRUB_DISABLE_OS_PROBER=$OS_PROBER' >> /etc/default/grub
fi
grub-mkconfig -o /boot/grub/grub.cfg
systemctl enable sddm NetworkManager
CHROOT_EOF

echo "==> 设置用户 $USERNAME 的密码"
until arch-chroot "$MNT" passwd "$USERNAME"; do echo "密码设置失败，请重试"; done

echo "==> 复制离线仓库到目标系统（供日后离线装包）"
mkdir -p "$MNT/opt"
cp -a "$REPO" "$MNT/opt/offline-repo"
cat > "$MNT/etc/pacman.conf" <<'PACMAN_EOF'
[options]
HoldPkg = pacman glibc
Architecture = auto
SigLevel = Required DatabaseOptional
LocalFileSigLevel = Optional
ParallelDownloads = 5
Color
VerbosePkgLists

# 离线仓库（随 ISO 附带，始终可用）
[offline]
Server = file:///opt/offline-repo/

# 联网后取消注释以下仓库即可在线更新
# （建议先运行 sudo cachyos-rate-mirrors 选择镜像）
#[cachyos-v3]
#Include = /etc/pacman.d/cachyos-v3-mirrorlist
#[cachyos-extra-v3]
#Include = /etc/pacman.d/cachyos-v3-mirrorlist
#[cachyos-core-v3]
#Include = /etc/pacman.d/cachyos-v3-mirrorlist
#[cachyos]
#Include = /etc/pacman.d/cachyos-mirrorlist
#[core]
#Include = /etc/pacman.d/mirrorlist
#[extra]
#Include = /etc/pacman.d/mirrorlist
PACMAN_EOF

cp "$LOG" "$MNT/var/log/offline-install.log"

echo "==> 卸载目标分区"
umount -R "$MNT"
sync

echo
echo "=============================================="
echo " 安装完成！"
echo " 模式: $([[ $MODE == 1 ]] && echo 整盘自动 || echo 与已有系统共存)"
echo " 磁盘: $DISK  root: $ROOT  主机名: $HOSTNAME  用户: $USERNAME"
echo " 引导: GRUB（模式1: BIOS+UEFI 双模式；模式2: 随固件，含 Windows 启动项）"
echo " 重启后请拔掉 U 盘/安装介质"
echo "=============================================="
read -rp "是否立即重启？[y/N] " ans
if [[ ${ans,,} == y* ]]; then
    reboot
fi