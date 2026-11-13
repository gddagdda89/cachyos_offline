#!/usr/bin/env bash
# CachyOS 离线安装器：在 Live 环境中运行，从 /opt/offline-repo 离线安装系统到磁盘
# 模式1 整盘自动：擦除所选磁盘并自动分区（GPT: BIOS boot + EFI + Btrfs）
# 模式2 共存手动：保留其它分区/Windows，仅格式化指定的 root 分区，复用已有 EFI 分区
# 用法: sudo /opt/offline-install/offline-install.sh
set -euo pipefail

# The same directory structure works inside the ISO and in an extracted bundle.
INSTDIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
REPO="$(cd "$INSTDIR/../offline-repo" && pwd)"
source "$INSTDIR/boot-policy.sh"
MNT=/mnt
LOG=/var/log/offline-install.log

exec > >(tee -a "$LOG") 2>&1

die() { echo "错误: $*" >&2; exit 1; }
trap 'echo; echo "!! 安装中断，请查看日志: $LOG"; echo "!! 若已挂载目标分区，可执行 umount -R /mnt 后重试"' ERR

[[ $EUID -eq 0 ]] || die "请用 sudo 运行"
[[ -d /run/archiso ]] || die "请在 CachyOS Live ISO 环境运行安装器"
[[ -f $REPO/offline.db ]] || die "未找到离线仓库: $REPO"
[[ -f $INSTDIR/packages.txt ]] || die "未找到包清单: $INSTDIR/packages.txt"
# Verify the entire bundle before offering any destructive action.
[[ -f $INSTDIR/../SHA256SUMS ]] || die "缺少离线包校验清单"
(cd "$INSTDIR/.." && sha256sum --quiet -c SHA256SUMS) || die "离线包校验失败"
for tool in pacstrap arch-chroot genfstab sgdisk partprobe mkfs.btrfs mkfs.fat; do
    command -v "$tool" >/dev/null || die "Live 环境缺少命令: $tool"
done
[[ -z $(findmnt -rn -o TARGET | awk '$0=="/mnt" || index($0,"/mnt/")==1') ]] || die "/mnt 已有挂载，请先卸载"
# Use a temporary config: bundle paths may contain spaces and need no /opt setup.
RUN_CONF=$(mktemp /run/cachyos-offline-pacman.XXXXXX)
trap 'rm -f "$RUN_CONF"' EXIT
{
    printf '[options]\nArchitecture = auto\nSigLevel = Required DatabaseOptional\n'
    printf 'CacheDir = %s/\nDisableSandbox\nParallelDownloads = 1\n' "$REPO"
    printf '\n[offline]\nServer = file://%s/\n' "$REPO"
} > "$RUN_CONF"

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
    FIRMWARE=uefi
    EFI_NVRAM_FLAG=""
else
    echo "==> Live 启动模式: BIOS（仍会安装 UEFI 引导，使用可移动设备回退路径）"
    FIRMWARE=bios
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
    ESP_COUNT=0
    BIOS_BOOT=no
    TABLE=$(lsblk -dno PTTYPE "$DISK" | tr -d '[:space:]')
    for p in "${parts[@]}"; do
        pt=$(lsblk -no PARTTYPE "/dev/$p" | tr '[:upper:]' '[:lower:]' | tr -d '[:space:]')
        [[ $pt != 21686148-6449-6e6f-744e-656564454649 ]] || BIOS_BOOT=yes
        if [[ $pt == c12a7328-f81f-11d2-ba4b-00a0c93ec93b || $pt == 0xef ]]; then
            ESP_COUNT=$((ESP_COUNT + 1))
            ESP_NAME=$p
        fi
    done
    validate_coexistence_boot "$FIRMWARE" "$TABLE" "$BIOS_BOOT" "$ESP_COUNT" || die "引导模式与分区布局不兼容"
    if [[ $FIRMWARE == uefi ]]; then
        [[ $(lsblk -no FSTYPE "/dev/$ESP_NAME" | tr -d '[:space:]') == vfat ]] || die "ESP 必须为 FAT 文件系统"
        [[ -z $(lsblk -no MOUNTPOINTS "/dev/$ESP_NAME" | tr -d '[:space:]') ]] || die "ESP 已挂载，请先卸载"
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

    if [[ $FIRMWARE == uefi ]]; then
        EFI="/dev/$ESP_NAME"
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
pacstrap -c -C "$RUN_CONF" "$MNT" "${PKGS[@]}"

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
    if [[ $FIRMWARE == uefi ]]; then
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
ASSETS="$MNT/usr/local/share/cachyos-offline"
mkdir -p "$ASSETS" "$MNT/usr/local/sbin"
install -m644 "$INSTDIR/pacman-installed-offline.conf" "$ASSETS/pacman-offline.conf"
install -m644 "$INSTDIR/pacman-installed-online.conf" "$ASSETS/pacman-online.conf"
install -m644 "$INSTDIR/target-versions.txt" "$ASSETS/target-versions.txt"
install -m755 "$INSTDIR/repo-mode.sh" "$MNT/usr/local/sbin/cachyos-repo-mode"
install -m644 "$ASSETS/pacman-offline.conf" "$MNT/etc/pacman.conf"

cp "$LOG" "$MNT/var/log/offline-install.log"

echo "==> 卸载目标分区"
umount -R "$MNT"
sync

echo
echo "=============================================="
echo " 安装完成！"
echo " 模式: $([[ $MODE == 1 ]] && echo 整盘自动 || echo 与已有系统共存)"
echo " 磁盘: $DISK  root: $ROOT  主机名: $HOSTNAME  用户: $USERNAME"
echo " 引导: GRUB（模式1: BIOS+UEFI 双模式；模式2: 随固件，启用已有系统探测，结果取决于实际系统）"
echo " 联网后运行 sudo cachyos-repo-mode online（切换仓库并完整升级）"
echo " 重启后请拔掉 U 盘/安装介质"
echo "=============================================="
read -rp "是否立即重启？[y/N] " ans
if [[ ${ans,,} == y* ]]; then
    reboot
fi
