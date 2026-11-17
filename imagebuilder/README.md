# imagebuilder 目录说明

用官方 Docker ImageBuilder 在容器里定制 x86-64 旁路由 / 路由器固件，集成 nikki（mihomo 的 OpenWrt 集成）与一组自定义网络配置。无需本地搭建 OpenWrt 编译环境。

## 目录与版本

仓库里保留了三代构建脚本，对应不同的上游镜像与包管理器，**当前维护的是 `25.12-immortalwrt/`**：

| 目录 | 上游镜像 | 包管理 / 源文件 | 状态 |
|------|----------|-----------------|------|
| `24.10/` | `openwrt/imagebuilder:x86-64-24.10.*` | opkg，`repositories.conf` + `src/gz` | 早期版本，含 full / bypass 两套，含 `.0` 版本兜底（已不推荐） |
| `25.12/` | `openwrt/imagebuilder:x86-64-25.12.*` | apk，`repositories` + `public-key.pem` | 过渡版本 |
| `25.12-immortalwrt/` | `immortalwrt/imagebuilder:x86-64-openwrt-25.12.*` | apk | **当前主力** |

下文未特别说明时，均指 `25.12-immortalwrt/`。

### 25.12-immortalwrt 目录结构

```
25.12-immortalwrt/
├── docker-build-bypass.sh          # 宿主入口：查询版本 + 启动容器
├── builder-bypass/
│   ├── build.sh                    # 容器内执行的实际构建脚本
│   └── files/                      # 需要打进固件的静态配置（FILES 机制）
│       └── etc/
│           ├── sysctl.d/99-bypass-optimization.conf
│           └── uci-defaults/lvxj00-public.sh
└── output/                         # 构建产物（.gitignore 忽略，仅本地保留）
```

## 快速开始

在 `25.12-immortalwrt/` 目录下手动执行（脚本自动判断 TTY，终端里可交互、可 Ctrl+C）：

```bash
./docker-build-bypass.sh          # 默认：只产出 ext4 EFI 的 qcow2（可直接导入 PVE）
./docker-build-bypass.sh -c       # 常用格式：ext4 的 qcow2 + raw、EFI + BIOS（gzip 压缩）
./docker-build-bypass.sh -a       # 全部格式：上游支持的所有镜像格式
```

产物落在 `output/`。依赖：宿主机有 Docker、`curl`；构建期需能访问南大镜像、Docker Hub 与 `nikkinikki.pages.dev`。格式档位见下节。

## 构建流程

### 1. 宿主入口 `docker-build-bypass.sh`

- **版本锁定**：通过 Docker Hub API 查询 `x86-64-openwrt-25.12` 系列的最新补丁版本（如 `25.12.2`），最多重试 2 次；查询失败**直接退出，绝不回退到滚动 tag**，也不猜测固定版本 —— 保证同一份脚本构建出的固件版本确定、可复现。
- **TTY 自适应**：`[ -t 0 ]` 为真时加 `-it`（手动执行可交互、可 Ctrl+C），非交互环境（CI / 管道）自动去掉 `-t`。
- 把 `output/`、`builder-bypass/files/`、`builder-bypass/build.sh` 挂进容器，执行 `/builder/build.sh`。

### 2. 容器内 `build.sh`

1. **按档位裁剪镜像格式**：读 `IMAGE_FORMATS` 环境变量（由入口脚本 `-e` 传入），从 `.config` 增删格式开关。详见本文「镜像格式档位」一节。
2. **换国内源**：把 `repositories` 里的官方地址替换为南大镜像（实测最快；不稳时可换中科大 `mirrors.ustc.edu.cn`）。
3. **自定义软件包**：`-dnsmasq + dnsmasq-full`、TPROXY 相关内核模块（`kmod-nft-socket` / `kmod-nft-tproxy`）、常用工具与 LuCI 中文语言包等。
4. **nikki 源与公钥**：最多下载 3 次公钥 `public-key.pem`；**仍失败则醒目报错并 `exit 1`，绝不静默跳过 nikki** —— 否则会产出「构建成功、校验和齐全、却完全没有 nikki」的固件。成功后把 nikki 源追加进 `repositories`，并追加 `luci-app-nikki` / `luci-i18n-nikki-zh-cn` 两个包。
5. **组装运行时 FILES**：`make image` 前把构建期现成的产物复制到 `/tmp/ib-runtime-files`：
   - 仓库静态配置 `files/` 整个 `cp -a` 进去
   - `repositories` 按是否含 `nikki` 拆成 `distfeeds.list`（7 条官方源，已是南大地址）与 `customfeeds.list`（nikki 源）
   - `keys/`（官方 2 个 + 本次下载的 `nikki.pem`）整个复制进 `/etc/apk/keys/`
6. **生成镜像**：`make V=s image ... FILES=/tmp/ib-runtime-files BIN_DIR=/output ROOTFS_PARTSIZE=800`。装包失败时 `make` 非 0 退出，配合 `set -e` 直接中止。
7. **默认档清理**：`minimal` 档在构建后精确删除本次附带产出的 raw `*.img` 并同步 `sha256sums`，只保留 qcow2 与构建元数据。

### 3. 两套软件源（容易混淆）

| | 构建时源 | 产物内源（刷机后运行时） |
|---|---|---|
| 文件 | ImageBuilder 工作目录的 `repositories` | rootfs 的 `/etc/apk/repositories.d/distfeeds.list` + `customfeeds.list` |
| 用途 | `make image` 期间 apk 从哪下载 .apk 装进固件 | 系统里 `apk update` / `apk add` 从哪下载 |
| 怎么来的 | `build.sh` sed 换成南大 + 追加 nikki 源 | 由 `build.sh` 从构建期 `repositories` / `keys/` **组装**进 FILES |

两者都要保留：构建期源决定「装什么」，产物源决定「刷机后能否在线装 / 升级 nikki」。公钥随产物一起打入，`apk` 才能验签 nikki 源。

> 注意：`distfeeds.list` / `customfeeds.list` 是预编译进 `base-files` / `apk-openssl` 包的静态文件，改 `.config` 的 `CONFIG_VERSION_REPO` 在 ImageBuilder 里**不生效**，只能走 FILES 覆盖。

### 4. 版本跟随（不写死版本号）

仓库里**不写死**补丁版本号 `25.12.2` 和 kmods 哈希 —— 产物内 `distfeeds.list` 的版本号与 kmods 路径全部来自构建期 ImageBuilder 生成的 `repositories`。升级补丁版本时，仓库里没有任何源文件需要改。

需要跟随大版本升级的常量只有下面几个（是架构 / 分支 / 域名，不是补丁号）：

| 文件 | 常量 | 何时需要改 |
|------|------|-----------|
| `docker-build-bypass.sh` | `VERSION='x86-64-openwrt-25.12'` | 换 OpenWrt 大版本（如 26.x） |
| `build.sh` | `ARCH="x86_64"`、`BRANCH="openwrt-25.12"`、`REPOSITORY_URL` | 换架构 / nikki feed 分支 / 源站域名 |

> 补丁版本 25.12.2 → 25.12.3 由入口脚本自动查询、distfeeds 自动跟随，无需手动改任何文件。`FEED_URL` 里的 `openwrt-25.12` 是 nikki feed 的大版本分支，跨大版本升级时才需同步。

## 镜像格式档位

只在 PVE 使用，日常只需要一个 ext4 qcow2；用不到的格式靠参数按需产出。三档由 `docker-build-bypass.sh` 的 `-c` / `-a` 选择，通过 `-e IMAGE_FORMATS` 传给容器内的 `build.sh`。

| 档位 | 命令 | 产出 | 压缩 | 清理 |
|------|------|------|------|------|
| **minimal**（默认） | `./docker-build-bypass.sh` | 仅 `ext4-combined-efi.qcow2` **1 个**磁盘镜像 + 元数据 | **关**（`.qcow2` 未压缩，可直接导入） | **是**：删本次 raw，只留 qcow2 |
| **common** | `./docker-build-bypass.sh -c`（或 `--common`） | ext4 全变体：`combined` / `combined-efi` 的 qcow2 + raw，以及 `rootfs.img.gz` | 开（ext4 产物带 `.gz`） | 否 |
| **all** | `./docker-build-bypass.sh -a`（或 `--all`） | 上游全部格式：上述 ext4 + squashfs 组合镜像、rootfs 归档、ISO / VDI / VMDK / VHDX | 开（ext4 产物带 `.gz`；squashfs 的 qcow2/vdi/vmdk/vhdx 按上游规则不压缩） | 否 |

**为什么默认关压缩**：上游 `CONFIG_TARGET_IMAGES_GZIP=y` 会把 qcow2 也 gzip 成 `.qcow2.gz`，导入前还得解压，正好违背 qcow2「免解压直接导入」的优势。默认档关掉它，拿到的是未压缩、稀疏（约 48 MiB）、PVE 9.x GUI 可直接上传导入的 `.qcow2`。

**为什么默认要清理**：raw `*.img` 是 Makefile 里 `IMAGES-y` 无条件生成的，删 `.config` 格式开关去不掉；关掉 gzip 后这些 raw 是**未压缩**的（`combined-efi.img` + `rootfs.img` 合计约 1.6 GB），对 PVE 无用且浪费空间。清理只依据**本次生成的 `sha256sums`** 精确定位文件，同步移除对应校验行，因此 `output/` 里历史遗留的任何镜像都不会被误删；`sha256sum -c sha256sums` 仍全部通过。`common` / `all` 两档不清理，且保留 gzip 压缩，raw 是 `.img.gz`（约 48 MiB）不会撑大磁盘。

**引导变体**：默认档只保留 EFI（`combined-efi.qcow2`，对应 PVE 的 OVMF / q35）。若要用 SeaBIOS，加 `-c` 或 `-a` 产出带 MBR 的 `combined.*` 变体。`-c` 与 `-a` 互斥，同时给会报错退出。

> 想直接在容器外单独跑 `build.sh` 时，可用 `IMAGE_FORMATS=common bash build.sh` 指定档位，默认 `minimal`。

## 自定义配置（files/）

| 文件 | 作用 |
|------|------|
| `etc/sysctl.d/99-bypass-optimization.conf` | 关重定向、开 BBR/fq、TCP 缓冲与队列、ARP gc 阈值等网络优化 |
| `etc/uci-defaults/lvxj00-public.sh` | 首次开机执行的 UCI 初始化：LAN 默认 `10.0.1.1/24`；单网卡改 DHCP、多网卡桥接 LAN + 单独 WAN；IPv6 相关设置与 DNS 重定向关闭；给 `/etc/custom-scripts/` 加执行权限 |

新增静态配置直接放进 `files/etc/...` 即可，会被 `cp -a` 带入运行时 FILES。**不要**手工往 `files/` 里写 `distfeeds.list` / `customfeeds.list` / `*.pem`：运行时源与密钥由脚本构建期自动生成，写死会在升级后失效。

## 产物（output/）

`output/` 被 `.gitignore` 忽略，只在本地保留。具体清单随镜像格式档位变化（见上节），各档都会带的构建元数据：

- `*-kernel.bin`：内核
- `*.manifest`：本次实际安装的软件包清单
- `sha256sums`、`profiles.json`、`*.bom.cdx.json`：校验和、profile 信息、SBOM

默认档只额外保留一个 `*-ext4-combined-efi.qcow2`（未压缩），导入 PVE 用 `qm set <vmid> --scsi0 <storage>:0,import-from=<path>` 或在 PVE 9.x GUI 从 `Import` 存储直接上传导入；`-c` / `-a` 档的 ext4 `.gz` 镜像需先 `gunzip`。

## 常见问题

- **产物里没有 nikki**：多为公钥下载失败导致构建中止（脚本会醒目报错并退出）。检查 `nikkinikki.pages.dev` 连通性后重跑；脚本不会静默产出残缺镜像。
- **刷机后 `apk update` 仍走官方慢源**：检查产物 `/etc/apk/repositories.d/distfeeds.list`；正常应为南大地址，来自构建期 `repositories` 的组装。
- **升级后产物内 kmods 路径失效**：确认入口脚本查到的补丁版本与所用镜像一致；distfeeds 跟随构建期 repositories 生成，不手工维护。
