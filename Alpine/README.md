# Alpine 目录说明

## 目录概述

在 Proxmox VE 等虚拟化环境里无人值守安装 Alpine Linux 基础系统（生成应答文件后调用 `setup-alpine -f`）。装好系统后再接 [Mihomo](../Mihomo/README.md) 或 [sing-box](../sing-box/readme.md) 部署旁路网关。

## 文件说明

### 1. setup-alpine.sh

生成 `/tmp/answers.txt` 并执行 `setup-alpine -f`，自动完成分区与安装。

**应答文件里的默认配置**：

| 项 | 值 |
|----|----|
| 键盘布局 | `us us` |
| 主机名 | `alpine-pve` |
| 网络 | `eth0` DHCP |
| 时区 | `Asia/Shanghai` |
| NTP | `chrony` |
| APK 源 | 南大镜像 `mirror.nju.edu.cn/alpine/v3.23`（main + community） |
| SSH | `openssh`，允许 root 公钥登录 |
| 磁盘 | `ERASE_DISKS=sda`，`-m sys /dev/sda`（sys 模式，整盘安装） |

**使用方法**（在 Alpine 安装 / Live 环境中执行）：

```bash
chmod +x setup-alpine.sh
./setup-alpine.sh
# 安装完成后重启
reboot
```

## ⚠️ 执行前必做

1. **替换 SSH 公钥**：把脚本里 `ROOTSSHKEY="ssh-ed25519 REPLACE_WITH_YOUR_SSH_PUBLIC_KEY user@example.com"` 换成你自己的公钥，否则装完无法用密钥登录。
2. **确认目标磁盘**：`ERASE_DISKS=sda` / `DISKOPTS="-m sys /dev/sda"` 会**清空 `/dev/sda` 整盘**并无交互式安装；磁盘名不符或盘上有数据时先改脚本再运行。
3. 脚本末尾会把 `/mnt/etc/ssh/sshd_config` 改成 `PermitRootLogin prohibit-password`（仅公钥登录，禁止密码登录）。

## 安装流程

1. **安装 Alpine 系统**
   ```bash
   ./setup-alpine.sh
   reboot
   ```
2. **部署旁路网关**：参考 [../Mihomo](../Mihomo/README.md) 或 [../sing-box](../sing-box/readme.md)

## 系统要求

- Alpine Linux 3.23（脚本内 APK 源写死 v3.23，换版本需同步修改）
- Root 权限
- 网络连接（需能访问南大镜像）

## 相关链接

- [Alpine Linux](https://alpinelinux.org/)
- [Mihomo 部署](../Mihomo/README.md)
- [sing-box 部署](../sing-box/readme.md)
