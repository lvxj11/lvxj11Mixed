# sing-box 部署笔记

在 PVE 的 Alpine LXC 里部署 sing-box 1.11（TUN + fake-ip），通过订阅转换生成配置，并用 cron 每天自动更新内核与配置。

> 感谢七尺宇、不良林、悟空的日常、安格视界、索拉里斯风。

## 部署方案

1. PVE 下以 **LXC** 方式安装 Alpine 3.20（脚本按 3.20 适配）。
2. 初始系统没有 SSH，在 PVE 控制台执行初始化脚本，它会：安装防火墙 / SSH 等工具、清空默认防火墙规则、设置时区、允许 root 远程登录、配置开机启动（nftables / sshd / local / crond）、开启网络转发、从 Alpine `edge/testing` 安装 sing-box 并设为开机启动。
3. 重启 LXC 容器，之后可用 SSH 连接。
4. 在 `settings.json` 里填入订阅地址（需要时也可换模板文件）。
5. 手动执行一次更新脚本，确认能正常拉取订阅并启动。

### 初始化命令

```bash
wget https://raw.githubusercontent.com/lvxj11/lvxj11PDP/refs/heads/main/sing-box/singbox-alpine-init.sh
chmod +x singbox-alpine-init.sh
./singbox-alpine-init.sh
```

脚本可接一个 `https://` 开头的参数作为下载加速镜像前缀，例如 `./singbox-alpine-init.sh https://gh-proxy.com/`。

> 部署脚本托管在另一个仓库 `lvxj11/lvxj11PDP`；本目录保存的是对应脚本与配置的副本，便于查看和版本管理。上面「下载更新脚本并加入计划任务」的完整流程由 `singbox-autoinit-alpine.sh` 完成，见下表。

## 文件说明

| 文件 | 作用 |
|------|------|
| `singbox-alpine-init.sh` | 基础初始化：装工具、配 SSH / 时区 / 转发、安装 sing-box 并设开机启动。设置了更新脚本地址但未下载，属于轻量版 |
| `singbox-autoinit-alpine.sh` | 完整初始化：在基础之上把 `singbox-update-and-start.sh` 下载到 `/opt/sing-box-update-and-start/`、生成 `settings.json`、添加「每天 02:00 运行」的 cron |
| `singbox-update-and-start.sh` | 订阅转换与自更新：克隆 [Toperlock/sing-box-subscribe](https://github.com/Toperlock/sing-box-subscribe) 生成 `providers.json`，套用配置模板，下载 sing-box v1.11（`linux-amd64`），备份旧文件后重启服务 |
| `settings.json` | 更新脚本的配置文件，见下表 |
| `singbox-1.11-tun-fakeip-template-nomirror.json` | **默认模板**（`settings.json` 指向它）：TUN + fake-ip，不带镜像加速的规则引用 |
| `singbox-1.11-tun-fakeip-template.json` | TUN + fake-ip 模板 |
| `singbox-1.11-tun-template.json` | TUN 模板（不含 fake-ip） |
| `singbox-tun-template.json` | 早期 TUN 模板 |
| `custom-direct.json` / `custom-proxy.json` | 自定义分流规则片段（v2 格式）：前者放直连域名 / IP，后者放走代理域名。本地脚本未直接引用，按需手工合并进模板 |

## settings.json 字段

| 字段 | 说明 | 默认值 |
|------|------|--------|
| `subscribe_expire_time` | 订阅配置过期天数，到期重新拉取；设为 `0` 表示不自动更新 | `7` |
| `subscribe_url` | 代理订阅地址（**必填**） | 空 |
| `user_agent` | 拉取订阅时使用的 UA | `clashmeta` |
| `exclude_keyword` | 节点名排除关键字（过滤「剩余流量 / 官网」等广告节点） | `网站\|地址\|剩余\|过期\|时间\|有效\|到期\|官网` |
| `config_template_file` | 配置模板 URL，建议用远程地址 | `singbox-1.11-tun-fakeip-template-nomirror.json` |

也可以直接改 `singbox-update-and-start.sh` 顶部的同名变量（脚本优先读 `settings.json`）。

## 面板

模板里开启了 Clash API：`0.0.0.0:9090`，`external_ui` 为 `/etc/sing-box/ui`，面板访问 `http://<容器IP>:9090`。

## 更新与日志

- cron：`0 2 * * * /opt/sing-box-update-and-start/singbox-update-and-start.sh`
- 更新时旧文件 / 目录会备份为 `.bak`，出问题可回退
- 日志：`/opt/sing-box-update-and-start/singbox-update-and-start.log`（超过 1MB 自动轮转）

## 注意事项

- 需要 root 权限；脚本会清空 `/etc/nftables.nft`（先备份为 `.nft.bak`），如已有自定义防火墙规则请提前保留
- `sing-box` 从 Alpine `edge/testing` 安装（`--allow-untrusted`），版本较新但非稳定仓库
- 首次部署后务必手动跑一次更新脚本，确认订阅能正常转换再依赖 cron
