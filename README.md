# lvxj11Mixed

家用网络 / 代理相关的脚本与配置集合：Alpine 系统安装、mihomo / sing-box 旁路网关、OpenWrt / ImmortalWrt 定制固件构建、RouterOS 中国 IP 列表生成等。

## 目录

| 目录 | 用途 | 说明 |
|------|------|------|
| [Alpine/](Alpine/README.md) | Alpine 系统安装 | 在 PVE 等虚拟化环境里无人值守装好 Alpine 基础系统 |
| [Mihomo/](Mihomo/README.md) | mihomo 旁路网关 | 在已装好的 Alpine 上部署 mihomo + nftables + TUN |
| [sing-box/](sing-box/readme.md) | sing-box 部署 | Alpine 上部署 sing-box 1.11，订阅转换与自动更新 |
| [imagebuilder/](imagebuilder/README.md) | 定制固件构建 | 用 Docker ImageBuilder 生成带 nikki 的 x86-64 旁路由固件 |
| [cn-ip-routeros/](cn-ip-routeros/README.md) | RouterOS IP 列表 | 生成 RouterOS 地址列表脚本，CI 每日自动更新 |
| [release/](release/) | 规则集产物 | `gfw-and-!cn.mrs` 等规则文件 |

## 快速开始：旁路网关固件

近期主要维护的是 `imagebuilder/25.12-immortalwrt/`（ImmortalWrt 25.12 + nikki）：

```bash
cd imagebuilder/25.12-immortalwrt
./docker-build-bypass.sh
```

构建流程、版本跟随机制、产物清单见 [imagebuilder/README.md](imagebuilder/README.md)。若改用「Alpine + mihomo/sing-box」方案，则从 [Alpine/](Alpine/README.md) 开始，再接 [Mihomo/](Mihomo/README.md) 或 [sing-box/](sing-box/readme.md)。

## 说明

- 各子目录的 README 是各自的权威说明，本文件只做索引。
- 脚本里的订阅地址、SSH 公钥等均为占位符，使用前按各 README 替换。
- 本仓库公开，请勿提交订阅地址、密钥、设备 MAC / 主机名等私有信息；相关路径已在 `.gitignore` 中忽略。
