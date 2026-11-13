可以。针对你的 E5-2666 v3 + GT 1030 + 32GB 内存，我建议直接制作一个专用的 `CachyOS Offline ISO`，而不是使用官方 ISO 后再手动补装软件。

先说明一个重要情况：我核对了 CachyOS 当前的构建项目。官方提供了 ISO 构建脚本，但官方已经在 24.05 版本取消了离线安装器。网上残留的 `settings_offline.conf` 是旧安装流程配置，不能直接复制过来就实现完整离线安装。

[image](https://www.google.com/s2/favicons?domain=https://github.com\&sz=32)

GitHub+2



我们应该自己补上真正的离线安装能力。

## 一、制作方案

## CachyOS Offline ISO

一个 ISO，完成全部安装

第一层：Live 系统

KDE Plasma、终端、分区工具、安装环境。

第二层：离线软件仓库

CachyOS v3、Arch 软件包、全部依赖、签名及仓库数据库。

第三层：离线安装器

自动分区、pacstrap、本地软件源、系统配置、GRUB。

最终生成一个 .iso 文件

写入 U 盘即可安装，无需网络

技术基础使用：

- [CachyOS 官方 ISO 构建项目](https://github.com/CachyOS/CachyOS-Live-ISO?utm_source=chatgpt.com)
- [Archiso](https://gitlab.archlinux.org/archlinux/archiso?utm_source=chatgpt.com)
- [CachyOS Calamares](https://github.com/CachyOS/cachyos-calamares?utm_source=chatgpt.com)
- `pacman`、`repo-add`、`pacstrap`

## 二、第一步：准备制作环境

建议在一台能够联网的 CachyOS 电脑上制作，不要在 Windows 或 macOS 原生环境里直接构建。

安装构建工具：

```
sudo pacman -Syu --needed \
  archiso \
  mkinitcpio-archiso \
  git \
  squashfs-tools \
  grub
```

下载官方构建项目：

```
git clone https://github.com/CachyOS/CachyOS-Live-ISO.git

cd CachyOS-Live-ISO
```

先尝试构建一次官方原版 ISO：

```
sudo ./buildiso.sh -p desktop -v
```

完成后 ISO 会生成在项目的 `out` 目录。

这一步主要是验证构建环境和官方脚本正常。官方 README 也采用了这个构建流程。

[image](https://www.google.com/s2/favicons?domain=https://github.com\&sz=32)

GitHub+1



注意： 暂时不要使用 `-w`，它会删除构建工作目录，第一次调试需要保留中间文件。另外，你有 32GB 内存，暂时也不要启用 `-r` 内存构建模式。

## 三、第二步：准备目标系统的软件仓库

这是整个项目最关键的部分。

我建议目标系统先采用以下软件包组合：

| 类别      | 软件包                              |
| ------- | -------------------------------- |
| 基础系统    | base                             |
| 内核      | linux-cachyos                    |
| CPU 微码  | intel-ucode                      |
| 固件      | linux-firmware                   |
| CachyOS | cachyos-keyring、cachyos-settings |
| KDE     | plasma-desktop、plasma-workspace  |
| 登录管理器   | sddm                             |
| 常用软件    | dolphin、konsole、kate             |
| 显卡      | mesa、Nouveau 相关驱动                |
| 文件系统    | btrfs-progs、dosfstools           |
| 引导      | grub、efibootmgr                  |
| 网络      | networkmanager                   |

E5-2666 v3 支持 x86-64-v3，因此下载目标系统的软件包时，优先使用 CachyOS 的 v3 仓库。注意：ISO 本身仍然使用标准 `x86_64` 架构，v3 是软件仓库的优化等级，不是 ISO 架构名称。

[image](https://www.google.com/s2/favicons?domain=https://github.com\&sz=32)

GitHub+1



GT 1030 使用 Nouveau 作为默认驱动即可，不建议把 NVIDIA open 内核模块作为默认驱动。

### 下载逻辑

在联网电脑上建立一个空的软件包数据库：

```
mkdir -p ~/cachyos-offline/repo
mkdir -p ~/cachyos-offline/db
```

准备独立的 Pacman 配置，加入 CachyOS v3、Arch Core、Extra 等仓库。

然后执行：

```
sudo pacman -Syw \
  --dbpath "$HOME/cachyos-offline/db" \
  --cachedir "$HOME/cachyos-offline/repo" \
  base \
  linux-cachyos \
  linux-firmware \
  intel-ucode \
  cachyos-keyring \
  cachyos-settings \
  plasma-desktop \
  plasma-workspace \
  sddm \
  dolphin \
  konsole \
  kate \
  networkmanager \
  btrfs-progs \
  dosfstools \
  grub \
  efibootmgr
```

这里的 `-w` 是只下载、不安装，Pacman 会解析并下载依赖。

正式执行时要使用前面准备好的独立 v3 仓库配置，并把其他必要的软件包也加入清单。

然后生成本地仓库数据库：

```
cd ~/cachyos-offline/repo

repo-add offline.db.tar.zst ./*.pkg.tar.zst
```

这一步参考 Arch 官方的离线安装方案。

[image](https://www.google.com/s2/favicons?domain=https://wiki.archlinux.org\&sz=32)

ArchWiki



## 四、第三步：把软件仓库集成进 ISO

修改官方 ISO 项目。

将离线仓库放入：

```
archiso/
└── airootfs/
    └── opt/
        └── offline-repo/
            ├── offline.db
            ├── offline.db.tar.zst
            ├── *.pkg.tar.zst
            └── *.pkg.tar.zst.sig
```

再加入一个专门的 Pacman 配置：

```
[options]
Architecture = auto
SigLevel = Required DatabaseOptional

[offline]
Server = file:///opt/offline-repo/
```

还需要在 Live 系统中准备好 Arch 和 CachyOS 的密钥环，不能因为断网就关闭软件包签名验证。

## 五、第四步：制作离线安装器

我建议不再依赖官方在线安装器，而是增加一个自己的安装入口：

`CachyOS Offline Installer`

内部执行以下流程：

1. 检测 UEFI / BIOS 启动模式。
2. 识别硬盘型号、容量。
3. 选择安装磁盘并二次确认。
4. 创建 GPT 分区。
5. EFI 分区格式化为 FAT32。
6. 剩余空间建立 Btrfs。
7. 使用本地仓库调用 `pacstrap`。
8. 生成 fstab。
9. 配置系统、用户、时区、语言。
10. 安装 GRUB。
11. 配置 KDE、SDDM、NetworkManager。
12. 完成安装并重启。

因为你是全新硬盘，我们可以把默认分区设计为：

| 分区  | 容量     | 格式    |
| --- | ------ | ----- |
| EFI | 1GB    | FAT32 |
| 系统  | 剩余全部空间 | Btrfs |

安装器必须保留磁盘选择和擦除确认，不能直接默认擦除第一块硬盘。

## 六、第五步：重新构建 ISO 并测试

修改完成后：

```
sudo ./buildiso.sh -p desktop -v
```

最终得到：

```
CachyOS-Live-ISO/
└── out/
    └── CachyOS-Offline.iso
```

建议先用 QEMU 关闭网络测试一次：

- 能否进入 KDE？
- 能否识别磁盘？
- 能否读取 ISO 内的软件仓库？
- 能否完成 pacstrap？
- 能否安装引导程序？
- 重启后能否进入系统？

全部通过后再写入实体 U 盘。

## 七、我建议我们这样推进

不建议一次性把所有内容堆进去。分成三个交付阶段：

1. 阶段 1：基础 ISO 构建

   成功构建官方 CachyOS Live ISO，验证启动和 KDE 环境。
2. 阶段 2：离线软件仓库

   自动下载全部依赖、建立本地仓库、集成 ISO。
3. 阶段 3：图形化离线安装器

   实现磁盘选择、自动分区、系统安装、GRUB 配置和离线测试。

建议的最终工程目录

```
cachyos-offline-builder/
├── config/
│   ├── packages.txt
│   └── pacman-v3.conf
├── scripts/
│   ├── download-packages.sh
│   ├── build-repository.sh
│   ├── build-iso.sh
│   └── test-iso.sh
├── installer/
│   └── offline-install.sh
├── profile/
│   └── archiso/
└── output/
    └── CachyOS-Offline.iso
```

一个完整、可重复构建的工程

我建议下一步直接做阶段 1 和阶段 2 的自动化脚本。 这样后面修改软件包、重新构建 ISO，都只需要执行脚本，不必每次手工操作。

参考资料：

- [CachyOS 官方 ISO 构建源码](https://github.com/CachyOS/CachyOS-Live-ISO?utm_source=chatgpt.com)
- [Arch Linux 离线安装文档](https://wiki.archlinux.org/title/Offline_installation?utm_source=chatgpt.com)
- [CachyOS 官方 Wiki](https://wiki.cachyos.org/?utm_source=chatgpt.com)
