# Mihomo 目录说明

## 目录概述

在已安装好的 Alpine Linux 3.23 上快速部署 mihomo 旁路网关：一键脚本安装 mihomo、配置 nftables / TUN / 系统网络参数，并带上完整的示例配置与配套资源文件。

## 安装前须知

- 需 **root** 权限；要求 Alpine 3.23+、支持 TUN 的内核、可联网
- 脚本会检查「运行中的内核」与「已安装内核」是否一致，不一致请先 `reboot` 再运行
- 会自动检测主网卡名，并把各模板里的 `eth0` 替换成实际网卡名
- 安装后必须把 `/etc/mihomo/config.yaml` 里的订阅占位符换成真实订阅地址（见下文）

## 文件说明

### 1. install-mihomo-alpine.sh

Alpine 系统 mihomo 旁路网关一键安装脚本（v1.2.0）。

**主要功能**：
- 系统更新与必要工具安装（含 `qemu-guest-agent`、`ethtool`、`radvd`）
- 校验内核版本、检测主网卡并替换模板中的网卡名
- 自动检测系统架构与 CPU 指令集（amd64 下按 avx2 / avx 选 v3 / v2 / v1 版本），下载匹配的 mihomo 最新版
- 配置 nftables 防火墙（支持 IPv4 / IPv6）
- 配置系统网络参数（IP 转发、BBR、连接跟踪等）
- 创建 mihomo 配置目录与默认配置、OpenRC 服务并设为开机启动
- 配置日志轮转、安装网卡优化与 IPv6 网段更新脚本

**使用方法**：
```bash
chmod +x install-mihomo-alpine.sh
./install-mihomo-alpine.sh
```

### 2. assets/config.yaml

mihomo 完整配置示例。

**主要内容**：
- `proxy-providers`：机场订阅（`url`、`interval`、健康检查），按需自动更新
- 详细的 DNS 配置（DoH、fake-ip、域名策略等）
- 丰富的代理组（香港、亚洲、美国节点，fallback / url-test 等）
- 规则集配置（AI、TikTok、GitHub、Google、YouTube、Telegram 等，来自 meta-rules-dat）
- TUN 模式配置（自动路由、自动重定向、大 MTU）
- Sniffer 协议检测（HTTP / TLS / QUIC）
- 外部 UI 支持（Zashboard）、地理位置数据自动更新

**关键默认值**：

| 项 | 值 |
|----|----|
| `external-controller` | `[::]:9090` |
| `secret` | `CHANGE_ME`（**务必修改**） |
| `mixed-port` | `7892` |
| `proxy-providers.机场1.url` | `"订阅地址"`（占位符，**务必替换**） |

**注意**：订阅地址不是环境变量，请直接编辑 `/etc/mihomo/config.yaml` 里 `proxy-providers` 的 `url`（把 `"订阅地址"` 换成真实订阅链接），或在 `proxy-groups` 里直接写死代理服务器。脚本不会覆盖已存在的 `config.yaml`。

### 3. assets/sysctl.conf.template

系统网络参数优化配置模板。

**主要配置**：
- IP 转发（IPv4 / IPv6）
- 关闭反向路径过滤 `rp_filter`（旁路网关非对称路由必需）
- IPv6 RA 接收（旁路网关关键）
- 禁止重定向（防止路由冲突）
- TCP 拥塞控制（BBR + fq）、TCP Fast Open、MTU 探测
- 连接跟踪（`nf_conntrack_max`、established 超时）
- 网络队列和缓冲区调优、ARP gc 阈值
- 安全加固（syncookies、忽略广播 ICMP 等）

**应用方式**：由 `install-mihomo-alpine.sh` 自动部署到 `/etc/sysctl.d/99-network-gateway.conf`（模板里的 `eth0` 会被替换成实际网卡名）并执行 `sysctl -p`。

### 4. assets/network-optimization

网卡硬件层优化脚本（if-up.d / hotplug）。

**主要功能**：
- 增大发送队列长度（txqueuelen = 5000）
- 开启硬件卸载：`ethtool -K` 的 rx / tx / sg / tso / gso / gro / lro
- 自动配置多队列：`ethtool -L combined $(nproc)`

**与 sysctl 的区别**：
- sysctl：内核协议栈层参数，持久化配置
- network-optimization：网卡驱动层参数，需要随网卡启动执行

**部署方式**：复制到 `/etc/network/if-up.d/`，每次网卡启动时自动执行。

### 5. assets/nftables.conf

nftables 防火墙与 NAT 规则配置。

**规则说明**：
- `input` 链默认 `drop`；`forward` / `output` 默认 `accept`
- 允许本地回环（`lo`）、已建立 / 相关连接；丢弃无效连接
- 放行 IPv4 ICMP；按类型**精确**放行常用 ICMPv6（含 ND 路由通告 / 邻居发现），以及 DHCPv6（udp/546）
- 允许本地私网网段：IPv4 `10/8`、`172.16/12`、`192.168/16`；IPv6 `::1`、`fe80::/10`、`fc00::/7`
- `nat` 表对出口 `eth0` 做 `masquerade`

脚本会先备份已有 `/etc/nftables.nft` 为 `.bak.<时间戳>` 再覆盖，并按实际网卡名替换规则中的 `eth0`。

### 6. assets/radvd.conf.template

IPv6 路由通告服务配置模板，向局域网广播 IPv6 前缀。

**当前状态**：`main()` 里 `configure_radvd` 已注释，目的是**避免旁路由接管 IPv6 网关**。因此脚本不会生成 `/etc/radvd.conf`；虽然 `radvd` 仍被加入 default 运行级，但实际不生效。需要 IPv6 旁路网关时请手动启用并按需配置。

### 7. assets/mihomo-service

mihomo OpenRC 服务脚本：启动 / 停止 / reload / 状态检查。部署到 `/etc/init.d/mihomo`。

### 8. assets/logrotate.conf.template

mihomo 日志轮转配置：`daily` 轮转、保留 7 份、`compress` + `delaycompress`、`missingok` / `notifempty` / `copytruncate`。部署到 `/etc/logrotate.d/mihomo`。

### 9. assets/update-ipv6-set

动态更新 IPv6 直连网段到防火墙集合 `local_ipv6_list`。

**功能**：
- 自动检测主网卡
- 提取以 `2` 开头的 IPv6 直连前缀（通常是公网地址）
- 加入 nftables 集合并设 `24h` 超时；重复执行时若剩余过期时间不足 2 小时才删除重建，否则跳过，避免频繁改动

**部署方式**：`install-mihomo-alpine.sh` 已自动把它复制到 `/etc/periodic/15min/update-ipv6-set` 并赋可执行权限，**无需手动安装**。Alpine 的 `/etc/periodic/15min` 由 crond 定期执行；如需手动触发：

```bash
/etc/periodic/15min/update-ipv6-set
```

## 安装流程

1. **安装 Alpine 系统**：参考 [../Alpine](../Alpine/README.md)
2. **安装 mihomo 服务**：
   ```bash
   chmod +x install-mihomo-alpine.sh
   ./install-mihomo-alpine.sh
   ```
3. **配置 mihomo**：
   - 编辑 `/etc/mihomo/config.yaml`，替换订阅地址、修改 `secret`
   - 重启服务：`rc-service mihomo restart`
4. **（可选）启用 IPv6 路由通告**：见第 6 节 `radvd.conf.template`

## 服务管理

```bash
# 查看服务状态
rc-service mihomo status
rc-service nftables status
rc-service qemu-guest-agent status

# 启动/停止/重启
rc-service mihomo start
rc-service mihomo stop
rc-service mihomo restart

# 查看日志
tail -f /var/log/mihomo/mihomo.log
```

> 脚本把 `nftables` 加入 boot 运行级，把 `sshd / mihomo / crond / qemu-guest-agent / radvd` 加入 default 运行级；其中 radvd 见第 6 节说明。

## Web 面板

安装完成后访问：

```
http://<服务器IP>:9090
```

API 密钥为 `config.yaml` 里的 `secret`（默认 `CHANGE_ME`，请修改），外部 UI 为 Zashboard。

## 系统要求

- Alpine Linux 3.23+
- 支持 TUN 的内核
- Root 权限
- 网络连接

## 故障排查

| 问题 | 排查命令 |
|------|----------|
| 脚本提示内核版本不匹配 | 先 `reboot` 再重跑 |
| mihomo 无法启动 | `tail /var/log/mihomo/mihomo.log` |
| 防火墙规则 | `nft list ruleset` |
| TUN 模块 | `lsmod | grep tun` |
| 网络连接 | `ping -c 4 223.5.5.5` |
| IPv6 网段 | `ip -6 route show` |
| IPv6 集合是否已加入 | `nft list set inet filter local_ipv6_list` |

## 相关链接

- [mihomo](https://github.com/MetaCubeX/mihomo)
- [meta-rules-dat](https://github.com/MetaCubeX/meta-rules-dat)
- [Alpine Linux](https://alpinelinux.org/)
