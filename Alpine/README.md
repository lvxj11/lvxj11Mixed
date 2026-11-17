# Alpine 目录说明

## 目录概述

在 Proxmox VE 等虚拟化环境里部署 Alpine Linux 基础系统，装好后再接 [Mihomo](../Mihomo/README.md) 或 [sing-box](../sing-box/readme.md) 部署旁路网关。

提供两种方式，**推荐使用 cloud-init 方式**。

## 两种方式

| 方式 | 适用场景 | 文档 / 脚本 | 说明 |
|------|----------|-------------|------|
| **cloud-init（推荐）** | PVE 8.3+ / 9.x，新建 VM | [PVE9-cloud-init.md](PVE9-cloud-init.md)（GUI + CLI） | 导入 Alpine 官方云镜像，跳过安装流程；主机名 / IP / SSH 公钥在 PVE 里声明式配置，可转模板克隆；默认登录用户 `alpine`（非 root） |
| 传统 ISO 安装（legacy） | 需要在控制台粘贴执行、非 PVE 环境、或需要自定义分区 / 整盘 sys 安装 | [setup-alpine.sh](setup-alpine.sh) | 生成应答文件后调用 `setup-alpine -f`，在 PVE 控制台粘贴执行 |

**推荐 cloud-init 的理由**：不需要控制台粘贴脚本，也不再需要 virt/raw 安装镜像；公钥由 PVE 注入、不写进仓库；官方镜像默认非 root + doas 提权更安全；版本由镜像文件名钉死，不存在装好系统和 APK 源版本错配；可模板化批量部署。

传统脚本保留作为备选，仍可继续维护使用。

## 文件说明

### 1. PVE9-cloud-init.md

针对 PVE 9.2 的完整部署说明，包含 **GUI 方式**和 **CLI 方式**两套流程、镜像选择与校验、最佳实践配置（`alpine` 用户、仅密钥登录、禁 root、串口、模板化）、验证方法与常见坑。

### 2. setup-alpine.sh

生成 `/tmp/alpine-answers.XXXXXX` 并执行 `setup-alpine -f`，自动完成分区与安装。默认配置：

| 项 | 值 |
|----|----|
| 键盘布局 | `us us` |
| 主机名 | `alpine-pve` |
| 网络 | `eth0` DHCP |
| 时区 | `Asia/Shanghai` |
| NTP | `chrony` |
| APK 源 | 南大镜像 `mirror.nju.edu.cn`，版本**自动跟随启动介质** |
| SSH | `openssh`，root 仅密钥登录 |
| 磁盘 | `ERASE_DISKS=sda`、`-m sys /dev/sda`（sys 模式，整盘安装） |

**使用方法**（在 Alpine 安装 / Live 环境中执行）：

```bash
# 1. 把公钥放到脚本同目录的 authorized_keys（已 gitignore，不会入库）
cp ~/.ssh/id_ed25519.pub Alpine/authorized_keys

# 2. 在控制台执行
chmod +x setup-alpine.sh
./setup-alpine.sh
reboot
```

可用环境变量覆盖：`ALPINE_VERSION`（显式钉版本）、`TARGET_DISK`（目标磁盘，默认 `sda`）、`SSH_KEY_FILE`（公钥文件路径，也可以是 HTTP(S) URL）。

## ⚠️ 执行前必做（传统 ISO 方式）

1. **提供 SSH 公钥**：脚本从外部文件读取公钥，**不要把真实公钥写进脚本或提交到仓库**。文件内容可以是一行公钥，也可以是 URL（`setup-sshd` 会自行下载）。
2. **确认目标磁盘**：`ERASE_DISKS` / `DISKOPTS` 会**清空 `/dev/sda` 整盘**并无交互式安装；磁盘名不符或盘上有数据时先用 `TARGET_DISK` 改好再运行。
3. **版本**：脚本从 `/etc/alpine-release` 取版本并校验，取不到就醒目报错退出、不猜测；需要可复现时用 `ALPINE_VERSION=3.23 ./setup-alpine.sh` 显式指定。
4. root 公钥登录由 `ROOTSSHKEY` 交给 `setup-sshd` 处理，OpenSSH 默认 `PermitRootLogin prohibit-password`（仅密钥、禁密码）。脚本不再修改目标盘的 `sshd_config`。

## 系统要求

- Alpine Linux 3.x（版本自动跟随启动介质）
- Root 权限
- 网络连接（需能访问南大镜像）

## 相关链接

- [PVE 9.2 cloud-init 部署说明](PVE9-cloud-init.md)
- [Alpine Linux](https://alpinelinux.org/) / [Cloud Images](https://alpinelinux.org/cloud/)
- [Mihomo 部署](../Mihomo/README.md)
- [sing-box 部署](../sing-box/readme.md)
