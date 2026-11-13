# 操作日志 — CachyOS Offline ISO 构建

## 项目信息

- 目标：构建完全离线的 CachyOS 安装 ISO（方案见 plan.md）
- 构建机：本机 — CachyOS, i7-10700F, GTX 970, 31GB RAM, /home 剩余 874GB, KVM 可用
- 目标机：另一台电脑 — E5-2666 v3, GT 1030, 32GB RAM（按 plan.md；两台机器均支持 x86-64-v3，同一 ISO 通用）
- 约定：
  - 操作日志：`logs/operations.md`（助手维护，按时间追加）
  - 安装日志：`logs/install-*.log`（sudo 命令输出经 tee 落盘，由用户执行）
  - 后续阶段日志：`logs/download-packages.log`、`logs/build-iso.log`、`logs/test-iso.log`

## 2026-11-12

### 晚间 — 阶段 0：方案分析与环境核查

- 阅读 plan.md 并核对关键事实：
  - 官方已在 24.05 移除离线安装器（官方 Wiki changelog "ISO: Drop Offline Installer"）→ 必须自建离线安装能力，方案前提成立
  - buildiso.sh 参数已核实：`-p` 默认 desktop、`-v` 详细输出、`-w` 删除工作目录、`-r` 内存构建（>23GB 才启用）
  - `pacman -Syw --dbpath 独立库 + repo-add` 为 ArchWiki 标准离线方案，路线正确
- 本机环境核查结果：
  - 系统 CachyOS，内核 linux-cachyos 7.3.3-1
  - CPU i7-10700F（支持 x86-64-v3）；GPU GTX 970（与方案所写硬件不同，已确认目标机为另一台电脑）
  - 内存 31GB；/home 剩余 874GB；/dev/kvm 可用
  - 已装：git 2.56.1；未装：archiso、mkinitcpio-archiso、squashfs-tools、grub、arch-install-scripts、qemu-full、edk2-ovmf
- 分析结论：方案整体可行，需补强：
  1. 软件包清单补充：arch-install-scripts、pipewire/wireplumber/pipewire-pulse、plasma-nm/kscreen/powerdevil/polkit-kde-agent/xdg-desktop-portal-kde、noto-fonts-cjk（中文）、可选 fcitx5 输入法
  2. linux-firmware 已拆分子包，按需安装以控制 ISO 体积（预计最终 ISO 3–5GB）
  3. v3 仓库须排在 core/extra 之前；目标系统装好后 pacman.conf 指向在线 v3 仓库
  4. 安装器流程补 mkinitcpio -P 与 locale-gen；坚持 UEFI+BIOS 双模式（X99 主板 UEFI 可能有坑）
  5. 下载时记录版本清单（manifest）保证可重复构建
  6. 签名验证保持开启：本地库 DatabaseOptional，包签名 Required，预置 keyring
- 用户决定：ISO 用于其他电脑；sudo 命令由用户自行执行；所有日志记录到本项目目录

### 23:14 — 阶段 1 准备：日志初始化与安装命令

- 创建 `logs/` 目录与本操作日志
- 已验证 7 个待装包均存在于仓库（archiso 92-1、mkinitcpio-archiso 73-1 等；grub/squashfs-tools 在 v3 与 Arch 仓库各有一份，pacman 自动优选）
- 已向用户提供安装命令（输出 tee 到 `logs/install-tools.log`），等待用户执行：
  `sudo pacman -Syu --needed archiso mkinitcpio-archiso squashfs-tools grub arch-install-scripts qemu-full edk2-ovmf`
- 待办：用户执行后验证工具 → 克隆 CachyOS-Live-ISO → 试构建官方原版 ISO 验证环境

### 23:19 — 阶段 1：安装验证、克隆官方项目、构建准备

- 安装验证通过（install-tools.log 622 行，无 error/warning）：
  archiso 92-1 / mkinitcpio-archiso 73-1 / squashfs-tools 4.7.5-1.1 / grub 2:2.16-1.1 / arch-install-scripts 32-1 / qemu-full 11.1.3-1 / edk2-ovmf 202608-1
- -Syu 顺带全系统升级，重建了两次内核 initramfs（想用新内核需重启；不影响 ISO 构建）
- 克隆官方项目 → `CachyOS-Live-ISO/`（commit 3215497，2026-09-30）
- 构建脚本分析结论：
  - 官方 README 调用方式 `sudo ./buildiso.sh -p desktop -v`；默认每次构建前清空 build/（-c 可禁用）；-w 构建后删工作目录（本次不用）
  - 脚本会补丁宿主 /usr/bin/mkarchiso（-v 改 quiet=n；移除 ISO 内 archlinux-keyring-wkd-sync.timer）——官方行为，`sudo pacman -S archiso` 可恢复
  - profiledef.sh：bios.syslinux + uefi.grub 双引导 ✓；squashfs 用 xz 压缩（慢但体积小）
  - 构建期仓库 = 标准 cachyos + core/extra/multilib（非 v3）；Live 登录器是 plasmalogin（plasma-login-manager），不是 sddm
  - 未配置 GPGKEY 时 ISO 签名自动跳过（仅 warning，不报错）
  - syslinux 只需在 ISO 包清单中（mkarchiso 从 pacstrap_dir 取文件），宿主无需安装；宿主依赖 dosfstools/mtools/libisoburn/grub 已齐全
  - util-iso.sh 的 run_safe/run_log 为死代码，-v 安全
- Live 包清单 packages_desktop.x86_64（201 包）很全：含 arch-install-scripts、pipewire 全栈、noto-fonts-cjk、firefox、gparted 等 → 作为阶段 2 离线仓库基线
- 注意：Live 清单含 linux-cachyos-nvidia-open 等 open 内核模块，不支持 GT 1030（Pascal）；目标机仓库应排除、用 Nouveau（与方案一致）
- **用户约束：所有产物必须放在 /home/robola/dev/cachyos_iso 内**
  - 已改 `CachyOS-Live-ISO/archiso/pacman.conf`：CacheDir → `/home/robola/dev/cachyos_iso/pkg-cache/`（已核实 mkarchiso _make_pacman_conf 尊重非默认 CacheDir；缓存在 clone 外、build/ 清理不受影响，阶段 2 可复用）
  - build/、out/ 本就在 clone 目录内；不用 -r（避免 mktemp 写 /tmp）
  - 后续：离线仓库、QEMU 测试磁盘、脚本均放项目内
- 待用户执行构建命令（输出 → logs/build-iso.log）

### 23:25 — 构建进行中：中途检查

- 用户已启动 `sudo ./buildiso.sh -p desktop -v`，日志写入 logs/build-iso.log
- 进度很快：pacstrap 已完成（"Packages installed successfully"），检查时处于 SquashFS 压缩阶段（16 线程并行）
- 日志中两处 error 已核实无害：
  1. cachyos-rate-mirrors 安装脚本启用 timer 失败——构建脚本故意 mask 了该 timer（prepare_profile 里 ln -sf /dev/null），预期行为
  2. 生成 pkglist 时的 keyring 警告——发生在包安装完成之后；安装阶段 SigLevel=Required 已通过签名验证，不影响 ISO
- 系统影响评估：唯一被修改的系统文件是 /usr/bin/mkarchiso（官方脚本补丁，仅影响以后的 ISO 构建，sudo pacman -S archiso 可恢复）；不安装/卸载宿主软件包、不动引导与系统配置；产物全部在项目内

### 23:30 — 阶段 1 完成：ISO 验证 + 断网启动冒烟测试通过

- 构建耗时 8.25 分钟；产物 `CachyOS-Live-ISO/out/desktop/cachyos-desktop-linux-261112.iso`（3.1GB）+ sha1/sha256 + pkgs.txt
- 结尾 "ERROR: An unknown error has occurred" 为 buildiso.sh 无条件 EXIT trap 的固定文案，正常退出也打印，非真实失败
- sha256sum -c 通过；file/xorriso 确认 ISO 9660 + MBR isohybrid + El Torito EFI 双引导；根目录含 EFI/arch/boot/shellx64.efi
- 无头 QEMU 冒烟测试（KVM、-nic none 断网、4G 内存）：90 秒进入 KDE Plasma 桌面（CachyOS Hello 欢迎界面），截图 `vm/boot-90s.png`；QMP 正常关机
- squashfs 2.86GB（xz 压缩率 40.3%）
- 阶段 1 完成

### 23:36 — 阶段 2：配置与脚本就绪

- 核实宿主 v3 仓库结构：cachyos-v3 / cachyos-extra-v3 / cachyos-core-v3（共用 cachyos-v3-mirrorlist）+ cachyos/core/extra
- 固件裁剪决策：whence+nvidia+realtek+other ≈ 128MiB；排除 linux-firmware-intel（137MiB，主为 i915/Intel WiFi 固件，目标机不需要，日后可在线补装）
- 新建：`config/packages.txt`（70 个顶层包：基础/KDE/音频/中文字体输入法/firefox）、`config/pacman-v3.conf`（v3 优先、无 multilib）、`scripts/download-packages.sh`（独立 dbpath 下载 + manifest）、`scripts/build-repository.sh`（repo-add）
- 产物全部在项目内：repo/（包+签名+offline.db）、db/（独立 pacman 数据库）、logs/manifest.txt、logs/download-packages.log、logs/build-repository.log
- 包名预检：kcm-fcitx5 已不存在（KCM 并入 fcitx5-configtool），已替换；其余 56 个包全部命中仓库
- 待用户执行下载与建库
### 23:45 — 阶段 2 下载完成：仓库完整性验证通过 + 两处改进

- 用户执行 download-packages.sh + build-repository.sh 完成：680 个包 / 1.5G，全部带 .sig 签名（680/680）
- offline.db.tar.zst 生成成功（offline.db 软链接指向它）；manifest.txt 与 repo 内容比对：0 缺失
- 下载中的 provider 选择提示（v3 与 Arch 同名 soname 冲突）默认值=1 均为 v3 包，选择正确
- 改进 1：download-packages.sh 的 -Sp/-Sw 增加 --noconfirm，重跑无需人工应答
- 改进 2：packages.txt 音频段增加 pipewire-jack（此前 jack 依赖默认解析到 jack2）；已从 repo 移除 jack2 包与签名，避免离线安装时 provider 二义性
- 待用户增量重跑（--needed 只会新下载 pipewire-jack 及其少量依赖），随后重建 offline.db

### 23:58 — 阶段 3 文件就绪：离线安装器 + 集成/构建/测试脚本

- 新建 `installer/offline-install.sh`：磁盘选择（排除 live 启动盘）+ YES 擦除确认 → GPT（1M BIOS boot + 1G EFI FAT32 + 剩余 Btrfs）→ 子卷 @/@home/@cache/@log/@snapshots（zstd:1,noatime）→ pacstrap 离线安装 → genfstab → 时区 Asia/Shanghai、locale zh_CN.UTF-8、主机名/用户交互设置、wheel sudo → mkinitcpio -P → GRUB 双模式（i386-pc + x86_64-efi，BIOS 启动时用 --no-nvram 并复制 EFI/BOOT/BOOTX64.EFI 回退路径）→ 启用 sddm/NetworkManager → 离线仓库复制到目标 /opt/offline-repo + 目标 pacman.conf（offline 启用、在线仓库注释待联网后开启）
- 关键技术核实（arch-install-scripts 32-1）：pacstrap -K 只 init 不 populate 会导致验签失败，故用默认 keyring 复制；-c 参数使 CacheDir=/opt/offline-repo 生效（包直接从仓库取用，不进 live 内存）；live 的 pacman-init.service 开机初始化密钥环，离线可用
- live 包列表已含 arch-install-scripts/gptfdisk/btrfs-progs/dosfstools，无需改动
- 新建 `installer/pacman-offline.conf`（仅 [offline] file:// 源 + DisableSandbox）、`installer/cachyos-offline-installer.desktop`（konsole 启动，桌面+菜单双入口）
- 新建 `scripts/integrate-offline.sh`：仓库+安装器复制到 airootfs/opt/，profiledef.sh 幂等补权限；已试运行通过（679 包，待 pipewire-jack 增量后为 680+）
- 新建 `scripts/build-iso.sh`：集成 → sudo buildiso.sh（以产物判定成败，规避 EXIT trap 误报）→ 复制到 output/CachyOS-Offline.iso + sha256
- 新建 `scripts/test-iso.sh`（UEFI 用 OVMF pflash + 独立 VARS，BIOS 用 SeaBIOS，-nic none 断网，20G virtio 盘）+ `scripts/qmp-tool.py`（截图/状态/逐字输入/组合键/关机）
- heredoc 变量展开已用样例值验证正确；全部脚本 bash -n / py_compile 通过
- 待用户：增量下载（pipewire-jack）→ ./scripts/build-iso.sh 重建 ISO

### 11:50 — 离线 ISO 首次构建成功 + 仓库清理 + 脚本修复

- 用户执行增量下载 + build-iso.sh：构建成功（7.95 分钟），新 ISO `CachyOS-Live-ISO/out/desktop/cachyos-2026.11.13-x86_64.iso`（4.6G）；squashfs 2.86G→4.43G，unsquashfs -l 证实 opt/offline-install（3 文件）+ opt/offline-repo（701 包+db）已入镜像
- 收尾失败原因：构建 8 分钟超过 sudo 密码缓存时限，第二次 sudo cp 超时（output/ 为空）
- 发现并清理：隔夜仓库同步导致 21 个旧版本包滞留 repo（firefox-160.0-1、qt6-base-6.12.0-4.1 等，manifest 均为新版）；已删除旧包+签名；repo-add 的 .old 备份（db 与 files 两个）一并清理
- 修复 build-iso.sh：构建+复制+chown 合并为单个 sudo bash 会话，只需输入一次密码；仍以新产物判定成败
- 修复 build-repository.sh：repo-add 后 rm -f ./*.old
- 重建 offline.db 并最终验证：680 包 / 680 签名 / 680 清单，0 缺失，无 jack2、无 .old
- 阶段 2 完成；待用户重跑 ./scripts/build-iso.sh 得到干净的最终 ISO（output/CachyOS-Offline.iso）

### 12:30 — 断网测试第一轮：官方安装器拒绝离线 + 离线安装器入口验证 + 磁盘过滤修复

- UEFI 断网 VM 启动成功（OVMF pflash），60s 进 KDE；桌面出现「CachyOS Offline Installer」快捷方式
- 点击官方 CachyOS Hello「Launch installer」：弹窗 "Calamares install type: Unable to start online installation! No internet connection"，按钮随后置灰——证实官方安装器离线不可用（截图 vm/uefi-official-45s.png）
- 双击桌面离线安装器快捷方式：Konsole 正常启动安装器，识别 UEFI、中文提示正常（截图 vm/uefi-installer-start.png）
- 发现缺陷：QEMU 默认软驱 /dev/fd0(4K) 被列为候选安装盘；installer 磁盘过滤扩展为排除 ^(zram|fd|loop|sr)；test-iso.sh 增加 -global isa-fdc.driveA=/driveB= 去除软驱
- QMP 点击经验：该 guest 不识别同批 down+up 的鼠标事件，qmp-tool.py click/dclick 改为分开发送并按住 120ms
- 为保证"所测即所发"：停止 VM、重置测试盘，待重建最终 ISO 后再跑完整 UEFI+BIOS 安装测试
- 用户要求：验证通过后复制 ISO 到 /run/media/robola/Ventoy/（exFAT rw，剩余 23G，足够）

### 12:40 — 决策：离线 ISO 禁用 Hello 自启动（用户选定）

- 背景：官方 Hello「Launch installer」断网弹窗 "Unable to start online installation! No internet connection"；网络检查在 cachyos-hello 编译二进制内，无法安全改指向
- 用户选择：禁用 Hello 自启动（保留菜单入口），避免最终用户误点在线按钮
- 实现：installer/no-hello-autostart.hook（Trigger: usr/bin/cachyos-hello Install/Upgrade；PostTransaction Exec rm -f /etc/skel/.config/autostart/cachyos-hello.desktop）；integrate-offline.sh 幂等安装到 airootfs/etc/pacman.d/hooks/zz-offline-no-hello-autostart.hook
- 机制核实：libalpm hook 在目标 root 内执行；mkarchiso 结尾的 FS#49347 hook 清理会移除该构建期 hook，不影响成品系统；skel→home 复制发生在 pacstrap 之后，故 liveuser 不再自启动 Hello
- 待重建 ISO（含 fd0 过滤修复 + 本 hook），随后完整 UEFI/BIOS 断网安装测试，通过后复制到 Ventoy U 盘

### 16:28 — 核查 14:19 ISO：含 fd0 修复但不含 Hello hook（hook 晚于该次构建）

- 用户「好了 检查下」后核查：output/CachyOS-Offline.iso（14:19，4.5G）sha256 校验成功；sfs 内 installer 的 fd0 过滤 ^(zram|fd|loop|sr) 已生效
- 但 grep -c "disable CachyOS Hello autostart" logs/build-iso.log = 0；sfs 仍含 etc/skel 与 home/liveuser 两处 cachyos-hello.desktop 自启动
- 根因：installer/no-hello-autostart.hook 源文件 mtime=14:28，晚于 14:19 构建——该次重建只带 fd0 修复，hook 尚未进入 profile（hooks 目录 mtime 仍为 11月12日 23:17，仅 3 个官方 hook）
- 已重跑 ./scripts/integrate-offline.sh：profile hooks 目录新增 zz-offline-no-hello-autostart.hook（680 包/1.5G 集成正常）
- 机制再核实：mkarchiso 顺序 _make_custom_airootfs(1861)→_make_packages/pacstrap(1862)→_make_customize_airootfs/skel→home(1867)；HookDir 指向 airootfs hooks(311)；overlay 无 home/ 也无任何 hello 自启动文件，故 sfs 两处均来自「包安装 skel + 之后 skel→home 复制」；本 hook 在 pacstrap 期删除 skel 文件，home 复制(--update=none)随之不再产生 → 成品两处皆无
- 本 hook 不含 'remove from airootfs' 标记，FS#49347 清理不会误删；其执行顺序(zz-)早于清理 hook(zzzz99-)，即使被清理也已先完成删除
- 结论：需用户再执行一次 ./scripts/build-iso.sh 生成最终 ISO（fd0 修复 + Hello hook），随后跑完整 UEFI/BIOS 断网安装测试

### 16:39 — 最终 ISO 构建完成并核查通过

- 用户重建后 output/CachyOS-Offline.iso（16:39，4781539328 字节）；sha256sum -c 成功
- 构建日志：hook 执行 (35/36) "Offline ISO: disable CachyOS Hello autostart"，随后 (36/36) FS#49347 清理；构建用时 8.13 分钟（结尾 ERROR 为官方无条件 EXIT trap，非真失败）
- sfs 核查：autostart/cachyos-hello 两处均 NONE（已移除）；保留 usr/share/applications/cachyos-hello.desktop 菜单入口；离线安装器快捷方式齐全（skel/Desktop、liveuser/Desktop、applications）；installer fd0 过滤 ^(zram|fd|loop|sr) 在第 44 行
- 备注：构建 hook zz-offline-no-hello-autostart.hook 仍留在 live sfs（无 'remove from airootfs' 标记，未被清理）——无害，仅 live 会话装/升 hello 时触发，pacstrap 不会带入目标系统；不值得为此再重建
- 开始任务#5：QEMU 断网完整安装测试（先 UEFI 后 BIOS），安装到 vm/test-*.qcow2，再 disk-* 模式验证 SDDM

### 16:43–16:57 — 任务#5 完成：UEFI + BIOS 断网完整安装测试均通过

- 修正 test-iso.sh：本机 QEMU 无 isa-fdc.driveA 属性（-global 报错），移除该两参数；保留默认软驱反而验证 installer 的 fd 过滤生效（候选盘仅 vda）
- UEFI：live 进 KDE 无 Hello 弹窗（hook 生效）；双击桌面图标启动安装器；识别 UEFI；候选仅 /dev/vda 20G；1→YES→默认主机名/用户→pacstrap 离线 680 包(4304.97MiB)→root/用户密码→grub i386-pc+x86_64-efi 均 No error、NVRAM 写入 CachyOS(Boot0005)→sddm/NM enable→复制仓库→卸载→「安装完成」横幅
- UEFI 磁盘验证：disk-uefi 启动→SDDM（中文、user）→test1234 登录→KDE Wayland 桌面（截图 vm/uefi-disk-login.png）
- BIOS：live 进 KDE 无 Hello 弹窗；安装器识别 BIOS（--no-nvram+回退路径）；同样流程安装成功；grub 双目标 No error 且未写 NVRAM 条目（--no-nvram 生效）
- BIOS 磁盘验证：disk-bios 启动→SDDM→test1234 登录→KDE 桌面（截图 vm/bios-disk-login.png）
- 结论：最终 ISO 在 UEFI 与 BIOS 两种固件下均可完全断网安装并正常启动登录；任务#5 完成
- 下一步：按用户要求复制 output/CachyOS-Offline.iso 到 /run/media/robola/Ventoy/（exFAT rw，余 23G）

### 16:59 — 复制最终 ISO 到 Ventoy U 盘并校验通过

- cp output/CachyOS-Offline.iso → /run/media/robola/Ventoy/CachyOS-Offline.iso（4781539328 字节）+ sync
- 在 U 盘上 sha256sum -c 校验：成功（与构建产物一致）
- U 盘现含：Windows 10 安装 ISO（原有）+ CachyOS-Offline.iso；Ventoy 启动菜单可直接选择后者
- 全部交付完成：离线 ISO 构建 + 离线仓库 + 离线安装器 + UEFI/BIOS 断网安装验证 + U 盘交付

### 17:10 — 新需求：支持 Windows 共存（双系统），整盘/共存双模式都要

- 用户明确：既要整盘自动安装，也要与 Windows 共存；并询问图形分区 → live 自带 gparted/KDE partitionmanager 可图形分区
- 发现缺口：离线仓库与 packages.txt 缺 os-prober、ntfs-3g（GRUB 识别/引导 Windows 必需）；已加入 config/packages.txt「文件系统与引导」段
- 重写 installer/offline-install.sh 为双模式：开头选 1=整盘自动（原逻辑不变）/2=共存手动
  - 共存：不 wipefs/sgdisk；列分区让用户选 root；拒绝选 EFI/NTFS/exfat/vfat/swap/已挂载分区；自动探测同盘 ESP（GPT ef00 GUID 优先，回退 vfat）只挂载不格式化；仅 mkfs.btrfs root
  - 引导组合：模式1=i386-pc+x86_64-efi+回退 BOOTX64；模式2 UEFI=仅 x86_64-efi（复用 ESP、不覆盖 Windows 回退路径）；模式2 BIOS=仅 i386-pc 到 MBR
  - os-prober：模式2 设 GRUB_DISABLE_OS_PROBER=false（grub-mkconfig 生成 Windows 启动项）；模式1 保持 true
- bash -n 语法通过；待补依赖下载→重建→共存/整盘回归测试
- 共存测试计划：live VM 内先用 sgdisk 预置 ESP+NTFS 占位+空 root 分区，再跑模式2，验证不破坏已有分区、复用 ESP、可启动

### 19:31 — 双系统依赖仓库校验通过（任务#6 完成）

- 用户已跑 download-packages.sh + build-repository.sh；核查 repo：os-prober-1.85、ntfs-3g/libntfs-3g-2026.9.28 均在
- 发现镜像刷新导致 4 个旧版本残留（dbus/libp11-kit/llvm-libs/p11-kit），已删除旧 .pkg.tar.zst+.sig，保留新版
- 发现 offline.db 残留 jack2 条目（包文件已不存在）→ repo-remove 清除
- 重建后 repo 684 包 == logs/manifest.txt 684 行；offline.db 684 条 desc，无 .old
- 新增 scripts/test-offline-resolve.sh：仅用离线仓库做 pacman -Sp 依赖解析演练 → 684 包，与清单逐行一致（含 os-prober/ntfs-3g）
- 结论：离线仓库自洽，可进入 ISO 重建。下一步用户跑 ./scripts/build-iso.sh（自动 integrate），随后整盘+共存断网回归

### 19:37 — git 仓库初始化 + integrate 脚本补全手工改动

- 发现：grub.cfg 版本号 261113 由官方 util-iso.sh 构建时自动写入（date +%y%m%d），属构建产物，无需脚本化
- 真正未脚本化的手工改动仅 archiso/pacman.conf 的 CacheDir → 已并入 scripts/integrate-offline.sh（幂等：有则改值、无则插入；自动 mkdir pkg-cache）
- integrate 另新增：官方克隆存在性检查 + 固定 commit 3215497d2e8c5fea90e185affcf973dfa2cf790b 校验（不一致仅警告），脚本注释含克隆命令
- 连跑两遍 integrate 验证幂等：CacheDir 单行、对上游 diff 仍为 3 文件 4 行（grub 版本号/pacman.conf/profiledef）
- 写好 .gitignore：排除 repo/ db/ pkg-cache/ output/ CachyOS-Live-ISO/ vm/*.qcow2 vm/*.fd __pycache__/ logs/db-offline-test/ logs/.build-start
- git init -b main 完成；待跟踪 57 个文件约 11M（源码+日志+28 张测试截图 9.9M），尚未提交

### 19:39 — 首次提交并推送到 GitHub

- 远端: https://github.com/gddagdda89/cachyos_offline.git（ls-remote 确认为空仓库）；git 身份 robola <pl.liang@163.com> 已配置
- 提交前敏感信息扫描：命中均为包名（libsecret/libfido2 等）与 pacman 提示，无真实凭据；test1234 为一次性 VM 测试密码
- 初始提交：57 个文件约 11M（源码+日志+测试截图）；大体积产物由 .gitignore 排除
- git push -u origin main
- 结果：本地提交成功 f3ed8c1（57 文件，14560 行）；推送失败——无 GitHub 凭据（credential store 仅含其他主机、无 gh CLI、无 GitHub SSH 密钥），待用户在本机终端交互认证后推送

### 19:41 — 用户重建双模式 ISO 完成；内容验证通过

- 用户已跑 ./scripts/build-iso.sh：8.27 分钟，output/CachyOS-Offline.iso 4789538816 字节（较单模式版 +8MB，即 os-prober/ntfs-3g/libntfs-3g）
- sha256: ed71556cdf73a367727219e9aa9586c1c4547d7bc6f8d0cee28995543ac82093
- 从 ISO 提取 airootfs.sfs 核验：opt/offline-install/offline-install.sh 与源码 cmp 逐字节一致（含"选择模式"）；离线仓库含 os-prober-1.85/ntfs-3g/libntfs-3g；live 系统本身也装了 os-prober
- 开始任务#8 断网回归：整盘 UEFI → 整盘 BIOS → 共存 UEFI（预置 ESP+NTFS 占位+空 root，验证不擦盘/复用 ESP/可启动）

### 22:15 — 双模式 ISO 三项断网回归全部通过；U 盘已更新

- 整盘 UEFI（任务#9）：模式1 安装→GRUB Boot0005→硬盘启动→SDDM→test1234 登录 KDE Wayland（r2-uefi-*.png）
- 整盘 BIOS（任务#10）：模式1 安装→os-prober 按模式1 禁用（grub-mkconfig 警告符合预期）→硬盘启动→登录桌面（r2-bios-*.png）
- 共存 UEFI（任务#11）：新空盘预置 vda1=ESP512M(ef00, 含 EFI/Microsoft/Boot/bootmgfw.efi 标记)+vda2=NTFS8G(0700, windows-data.txt)+vda3=空 root；模式2 选 root=3 安装
  - 验证：分区表三原样（EF00/0700/8300）；ESP 标记留存且新增 EFI/CachyOS/grubx64.efi（只挂载不格式化）；NTFS 数据留存；目标 /etc/default/grub 含 GRUB_DISABLE_OS_PROBER=false；硬盘启动→登录桌面（r2-coex-*.png）
  - 说明：NTFS 为占位分区无真实 Windows 引导文件，os-prober 不产生 Windows 菜单项属预期；真实 Windows 盘会自动生成
- 测试脚本修正：test-iso.sh 增加 -boot order=d（live 模式优先光驱）/order=c（磁盘模式）——此前 VM 因硬盘旧系统/NVRAM 残留优先从硬盘启动
- 旧整盘 UEFI 测试盘保留为 vm/test-uefi-wholedisk.qcow2；共存测试盘为 vm/test-uefi.qcow2
- 交付：cp 新 ISO 覆盖 /run/media/robola/Ventoy/CachyOS-Offline.iso + sync + sha256sum -c 成功（ed71556c…）
- 待办：git 推送仍需用户终端认证；本轮新增改动（test-iso.sh、日志、r2-* 截图）待提交

### 22:24 — 中英文 README 编写完成（待提交推送）

- 新增 README.md：双语（English/中文）高规格文档，含徽章、目录、特性、原理流水线图、构建四步快速开始与分阶段表（含实测数据：684 包/1.5GiB 仓库/4324 MiB 安装/4789538816 字节 ISO/8.27 分钟）、mkarchiso 内部机制、安装器双模式说明、自动化测试全流程（VM 配置/QMP 操作表/共存预置命令/验证清单/结果矩阵）、仓库结构、可复现性、FAQ、免责声明
- 嵌入 7 张实测截图（vm/r2-*，已随 2c8c1cc 提交，GitHub 可渲染）
