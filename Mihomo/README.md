# Mihomo 目录说明

## 目录概述

在已安装好的 Alpine Linux 3.x（同一大版本）上快速部署 mihomo 旁路网关：一键脚本安装 mihomo、配置 nftables / TUN / 系统网络参数，并带上完整的示例配置与配套资源文件。

## 安装前须知

- 需 **root** 权限；要求 Alpine 3.x、支持 TUN 的内核、可联网
- **两个版本都可显式钉死以便复现**：
  - `ALPINE_VERSION`：从 `/etc/alpine-release` 读取并用 `case 3.*` 严格校验，只支持 3.x 大版本，跨大版本（如 4.x）直接报错退出、不做兼容；取不到一律醒目报错退出，不猜测、不回退到滚动版本
  - `MIHOMO_VERSION`：默认从 GitHub `releases/latest` 解析具体 tag；查询/下载失败重试 2 次后醒目报错退出，绝不回退到滚动 tag / 主版本 tag / 猜测版本。显式指定时按该 tag 查发布资源
- 脚本会检查「运行中的内核」与「已安装内核」是否一致：安装前查一次，`apk upgrade` 后再复查一次；任何一处不一致都会醒目提示「需要重启」并退出，请先 `reboot` 再重跑
- 把 `/etc/apk/repositories` 里的官方源域名 `dl-cdn.alpinelinux.org` 换成南大镜像 `mirror.nju.edu.cn`（域名以南大官方文档首页写法为准，不带 s）：只换域名、保留版本路径与 main/community/testing 条目，原文件先备份为 `.bak.<时间戳>`；换源是幂等的，重跑安全
- 换源后执行 `apk update` + `apk upgrade`。若源指向 `latest-stable` / `edge` 滚动版本会直接报错退出（避免跨大版本）；cloud-init 镜像若只启用 main，会自动补上 community（`yq-go` 等包在 community）
- 优先取默认路由所在网卡（排除 `tun` / `veth` / `docker` 等虚拟接口），并把各模板里的 `eth0` 替换成实际网卡名
- `assets/` 里的文件都是必需的：缺失一律报错退出，不会「警告后继续」产出残缺系统。请从脚本所在目录连同 `assets/` 一起取用，不要只拷脚本
- 安装后必须把 `/etc/mihomo/config.yaml` 里的订阅占位符换成真实订阅地址（见下文）

## 随附工具

`PACKAGES_BASE` 在原有基础上补齐了旁路网关排障与日常维护工具，全部随脚本一次装好（`apk add` 任一包名不存在会醒目报错退出，不会静默跳过）：

| 包 | 用途 |
|---|---|
| `yq-go` | YAML 配置检查 / 就地编辑；**Alpine 3.20+ 的 `yq` 包名就是这个**，旧 `yq`（Python 版）只到 3.19，且它在 community 仓库 |
| `bind-tools` | `dig` / `nslookup`，排查 fake-ip / DoH 的 DNS 问题 |
| `conntrack-tools` | `conntrack -L`，查看 NAT 表与回程连接，定位非对称路由 |
| `iputils` | 完整版 `ping` / `traceroute6`（busybox 自带版功能较少） |
| `socat` | 端口监听 / 转发 / 连通性测试 |
| `iperf3` | 吞吐 / 带宽测速，验证旁路网关转发性能 |
| `mtr` | ping + traceroute 合体，持续探测每一跳丢包与延迟；在 community 仓库 |
| `lsof` | 列出进程打开的文件 / 端口占用，查 9090、7892、53 被谁占 |
| `tree` | 树形展示目录结构 |
| `tmux` | 终端复用 / 会话保持，SSH 断开后任务仍在 |
| `nano` / `vim` | 编辑器；cloud-init 精简镜像通常只有 busybox `vi`（只想要一个就删掉另一个） |
| `rsync` | 增量同步，备份配置或传到别的机器 |

`htop` 原本就在列表里，无需重复添加。按需删减改 `PACKAGES_BASE` 即可（脚本里按「基础 / 排障 / 维护」分了三行赋值）；`yq-go`、`mtr` 在 community，换源时脚本会自动补 community。

## 文件说明

`assets/` 下所有源文件统一以 `.template` 结尾，表示这是**供脚本复制 / 渲染的模板**，不是可以直接放进系统使用的最终文件。部署时脚本把它们复制到各自的部署路径，目标文件名都不带 `.template`（例如 `nftables.conf.template` → `/etc/nftables.nft`、`config.yaml.template` → `/etc/mihomo/config.yaml`、`network-optimization.template` → `/etc/network/if-up.d/network-optimization`），`.template` 文件本身不会被执行。这样在目录里一眼就能把「源模板」和「脚本本体 / 部署产物」区分开。所有 `cp` 都显式写出目标文件名，不用「复制到目录」的写法（那会让目标继承 `.template` 后缀）；服务启动前脚本还会自检这些目标文件确实存在。

唯一例外是全局 `ll` 命令：只有一行，由 `install_ll_command()` 在脚本里用 heredoc 内联生成到 `/usr/local/bin/ll`，不占 `assets/` 文件（见第 10 节）。`.template` 约定是给大段、需要单独审阅 / 编辑的配置与脚本用的；一行内容单独做成资产，只会多一个要随脚本分发、还要小心目标文件名的文件，不划算。

### 1. install-mihomo-alpine.sh

Alpine 系统 mihomo 旁路网关一键安装脚本（v1.6.0）。

**主要功能**：
- 更换官方源为南大镜像（只换域名、补 community）、`apk update` + `apk upgrade`，升级后复查内核、需要重启则提示退出；一次装好全部随附工具（见「随附工具」）；不装 radvd
- 校验 Alpine / 内核版本、检测主网卡并替换模板中的网卡名
- 解析或接受显式指定的 mihomo 版本；自动检测架构与 CPU 指令集（amd64 下按 avx2 / avx 选 v3 / v2 / v1 版本），下载、解压、版本自检通过后才落位到 `/usr/local/bin/mihomo`
- 配置 nftables 防火墙（IPv4 / IPv6 双栈动态伪装）
- 配置系统网络参数（IP 转发、BBR、连接跟踪等）
- 创建 mihomo 配置目录与默认配置、OpenRC 服务并设为开机启动
- 配置日志轮转、安装网卡优化与 IPv6 网段更新脚本
- 安装全局 `ll` 命令（`/usr/local/bin/ll`，等价于 `ls -alhF`），脚本内联生成、无需模板文件，所有用户 / 所有 shell 类型可用，见第 10 节
- 关键资源缺失 / 版本解析失败 / 下载失败 / 部署产物缺失 / mihomo 启动失败，一律醒目报错退出；启动服务前会自检所有部署产物，不产出「看着成功、实则残缺」的系统

**使用方法**：
```bash
chmod +x install-mihomo-alpine.sh
./install-mihomo-alpine.sh
```

**钉死版本（可复现）**：
```bash
# 只钉 Alpine 版本（仅 3.x 合法）
ALPINE_VERSION=3.23 ./install-mihomo-alpine.sh

# 只钉 mihomo 版本（按该 tag 查发布资源，不再看 latest）
MIHOMO_VERSION=v1.19.22 ./install-mihomo-alpine.sh

# 两个都钉死
ALPINE_VERSION=3.23 MIHOMO_VERSION=v1.19.22 ./install-mihomo-alpine.sh
```
安装完成的日志会打印实际使用的 Alpine 与 mihomo 版本。

### 2. assets/config.yaml.template

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

**应用方式**：`install-mihomo-alpine.sh` 会先备份已有的 `/etc/sysctl.d/99-network-gateway.conf` 为 `.bak.<时间戳>`，再部署模板（`eth0` 替换为实际网卡名）并执行 `sysctl -p`。脚本会 best-effort 加载 `tcp_bbr` / `sch_fq` 模块；若内核不支持导致 `sysctl -p` 失败，会醒目报错退出，不静默跳过。

### 4. assets/network-optimization.template

网卡硬件层优化脚本（if-up.d / hotplug）。

**主要功能**：
- 增大发送队列长度（txqueuelen = 5000）
- 开启硬件卸载：`ethtool -K` 的 rx / tx / sg / tso / gso / **gro**（**不含 `lro`**）
- 自动配置多队列：`ethtool -L combined $(nproc)`

**关于 `lro`**：LRO（Large Receive Offload）是网卡/驱动把多个入站 TCP 报文合并成一个大包再交给协议栈的硬件卸载。这个合并是**不可逆、会改写报文头部**的，对开启 IP 转发的路由器 / 桥 / 旁路由有害（内核在开启转发时本身也会自动关掉它）。替代它的 GRO 有严格合并条件、可无损重分段，对转发安全，故保留 `gro`、移除 `lro`。VirtIO 网卡通常也不支持 LRO。

等待网卡就绪改为最多 2 秒的**条件等待**（接口已存在就立即继续），避免多网卡场景下固定 `sleep 2` 逐个累加阻塞。

**与 sysctl 的区别**：
- sysctl：内核协议栈层参数，持久化配置
- network-optimization.template：网卡驱动层参数，需要随网卡启动执行

**部署方式**：复制到 `/etc/network/if-up.d/`，每次网卡启动时自动执行。

### 5. assets/nftables.conf.template

nftables 防火墙与 NAT 规则配置。

**规则说明**：
- `input` 链默认 `drop`；`forward` / `output` 默认 `accept`
- 允许本地回环（`lo`）、已建立 / 相关连接；丢弃无效连接
- 放行 IPv4 ICMP；按类型**精确**放行常用 ICMPv6（含 ND 路由通告 / 邻居发现），以及 DHCPv6（udp/546）
  - 本环境是纯单播旁路由、不跑组播路由 / 组播应用，因此**不放行 MLD**（`mld2-listener-report` 等）与 `nd-router-solicit`。ND 用的 ICMPv6 类型已按类型单独放行，不受影响；将来若启用 IPTV 等组播应用，或启用 radvd 且依赖 RS 触发 RA，再按需补上
- 允许本地私网网段：IPv4 `10/8`、`172.16/12`、`192.168/16`；IPv6 `::1`、`fe80::/10`、`fc00::/7`
- `nat` 表对出口 `eth0` 做 `masquerade`，**同时作用于 IPv4 和 IPv6**
  - `table inet` 让 `masquerade` 双栈生效（Linux >= 5.2）。旁路由必须双栈都做伪装：否则经本机转发的 IPv6 流量源地址仍是客户端地址，回包会被主路由直接送回客户端、绕过本机，形成非对称路由（能 ping 通但网页打不开）。因此**不要**加 `meta nfproto ipv4` 限定，也不要把 `table inet` 改成 `table ip`
  - `masquerade` 是「动态」的：出口前缀变化（如 DHCPv6-PD 重拨）时自动跟随，无需改规则；`update-ipv6-set` 维护的是 input 链的允许集合，与它不是一回事
- `nat` 表 `prerouting` 链做 **DNS 劫持（53 → 1053，双栈）**
  - 规则：`iifname "eth0" meta l4proto { tcp, udp } th dport 53 redirect to :1053`。用 `redirect`（`redirect to :<port>`）而不是 DNAT：它是「目的地址 = 本机」的 DNAT 特例（内核 ≥ 3.19，inet 表 NAT 需 ≥ 5.2），只改端口、不改地址族，所以一条 inet 规则就同时覆盖 IPv4 + IPv6，无需分别写 `ip/ip6` 两个目标地址。`redirect to 1053`（无冒号）同样合法、功能一致，这里用带冒号写法与 `nft list ruleset` 回显及 man page 示例保持一致
  - **与 `tun.dns-hijack` 的分工**：`dns-hijack` 只作用于**已进入 tun0** 的流量，`auto-redirect` 只作用于**本机转发**的流量，两者都覆盖不到「经 eth0 进入、目的端口 53、目的 IP 是原值」这条路径——而当上游用策略路由把 DNS 按 mark 送到网关时，DNS 包正是走这条路，mihomo 不会接管。这条 prerouting 规则补的就是这一段。两者不重复、不冲突
  - 改 `dns.listen` 从 `53` 到 `1053` 是这条劫持的**前提**：1053 上必须有东西在听（mihomo 自己），否则 DNS 请求会被劫到没人接的端口、直接超时失败
  - `input` 链**无需**为 1053 额外放行：redirect 后目标端口是 1053，但包仍从 eth0 进入，仍命中 input 链里的私网放行规则；若客户端源不在放行集合，53 同样不会被放行——行为与劫持前一致，不额外开洞

**迁移说明（上游用 RouterOS / mangle mark 分流时）**：
- 上游原有的 `dst-nat`（TCP + UDP，53 → mihomo 网关）**不删也能正常工作**：`redirect` 只匹配「eth0 进 + dport 53」，不看目的 IP 是谁——无论包是被 dst-nat 改写成 `mihomo-gw:53`、还是原目的 `任意IP:53`，到网关后目的端口都是 53，照样命中 redirect → 1053。两种状态功能等价
- 若要实现「DNS 与普通流量在上游统一成**一套 mark 逻辑**、改网关地址只改路由一处」，则应**删除** dst-nat、改由 mark 分流把「目的 53」也送到网关（端口改写下沉到网关内 nftables 完成）；保留 dst-nat 只是保留了原来的三处配置负担，不影响劫持生效
- 注意别让上游把「目的 53」单独排除在 mark 分流之外（若已删 dst-nat 走 mark，这条 DNS 就走不到网关、劫持失效）

**验证命令**：
```bash
nft list ruleset | grep -A2 'hook prerouting'    # 确认 redirect 规则在
ss -lunp | grep 1053                              # 确认 mihomo 在听 1053
dig @<网关IP> example.com                          # 返回 fake-ip 即说明劫持生效
```

脚本会先备份已有 `/etc/nftables.nft` 为 `.bak.<时间戳>` 再覆盖，并按实际网卡名替换规则中的 `eth0`。

### 6. 关于 IPv6 路由通告（radvd）

`radvd` 是 IPv6 **Router Advertisement Daemon**，通过 ICMPv6 RA 向局域网宣告前缀、默认网关、RDNSS 等，是 SLAAC 的核心。

**本方案刻意不启用**：让旁路由宣告自己是 IPv6 默认网关，等于接管整网 IPv6 网关，配置复杂且容易和主路由（ROS）冲突。因此脚本不安装 `radvd` 包、不加入运行级、不生成 `/etc/radvd.conf`，`assets/radvd.conf.template` 也已移除。

若以后确实需要旁路由完整接管 IPv6：`apk add radvd`，自行写 `/etc/radvd.conf`（宣告本机 link-local / ULA 为高优先级网关、RDNSS 指向本机），`rc-update add radvd default`，并在 `assets/nftables.conf.template` 的 ICMPv6 放行清单补 `nd-router-solicit` 及 MLD 相关类型。注意客户端的 IPv6 默认网关要指向本机；双栈 `masquerade`（NAT6）在上面第 5 节已具备。

### 7. assets/mihomo-service.template

mihomo OpenRC 服务脚本：启动 / 停止 / reload / 状态检查。部署到 `/etc/init.d/mihomo`。`depend()` 里用 `after nftables`（不是并不存在的 `firewall`）；`start_pre()` 只创建 `/var/log/mihomo` —— `-d /etc/mihomo` 让数据（proxy_providers / ui / cache）都落在配置目录，`/run/mihomo`、`/var/lib/mihomo` 是用不到的空目录，不再创建。

### 8. assets/logrotate.conf.template

mihomo 日志轮转配置：`daily` 轮转、保留 7 份、`compress` + `delaycompress`、`missingok` / `notifempty` / `copytruncate`。部署到 `/etc/logrotate.d/mihomo`。

### 9. assets/update-ipv6-set.template

动态更新 IPv6 直连网段到防火墙集合 `local_ipv6_list`。

**功能**：
- 与主脚本一致，优先取默认路由所在网卡，排除虚拟接口
- 提取**所有**以 `2` 开头的 IPv6 直连前缀（去重复），逐个维护
- 加入 nftables 集合并设 `24h` 超时；过期剩余时间按 `d/h/m/s` 统一换算成秒，不足 2 小时才删除重建，否则跳过，避免频繁改动
- 从 `nft list set` 输出里按网段**精确截取自己的 `expires`**，兼容单行 / 多行输出与 `45m`、`1d2h`、`23h59m58s` 等格式（旧版只认 `XhYmZs` 三段，会把 `45m` 误判成「过期时间充足」）

**部署方式**：`install-mihomo-alpine.sh` 已自动把它复制到 `/etc/periodic/15min/update-ipv6-set` 并赋可执行权限，**无需手动安装**。Alpine 的 `/etc/periodic/15min` 由 crond 定期执行；如需手动触发：

```bash
/etc/periodic/15min/update-ipv6-set
```

### 10. 全局 ll 命令

`install_ll_command()` 在脚本里用 heredoc 直接生成 `/usr/local/bin/ll`（755），内容等价于 `exec ls -alhF "$@"`，参数照样透传（`ll /etc`、`ll -R ...`、`ll -A`）。**不用 `.template` 资产**：只有一行的文件单独做成模板，收益只是「和别的 assets 命名一致」，却要多维护一个随脚本分发的文件、多一次 `cp`（以及上次踩过的「目标继承 `.template` 后缀」风险）；内联生成自包含，一眼就能看到 `ll` 到底是什么。`.template` 约定留给大段、需要单独审阅 / 编辑的配置与脚本。它仍列在 `verify_deployed_files()` 的自检清单里。

`-h` 把大小换成 `4.0K` / `156K` 这类可读单位，`-F` 给条目名加类型后缀（`/` 目录、`*` 可执行文件、`@` 链接、`|` FIFO、`=` socket）。两者在 Alpine 的 busybox ls 上都支持（3.23 / BusyBox v1.37.0 实测）。`"$@"` 拼在命令末尾，追加 `-t`、路径、多个参数都不受影响——`ls` 的选项都是无参数开关、顺序无关。代价是**写死的选项不容易临时关掉**：GNU ls 还能用 `--block-size=1`、`--indicator-style=none` 之类长选项覆盖，busybox 没有这些长选项，在 Alpine 上基本只能接受默认值（短选项 `-A` 之类仍可透传）。另外 `/usr/local/bin/ll` 是**全系统、所有用户、所有 shell 共用**的默认，不是个人别名；`-F` 会让文件名带后缀，从输出里复制名字时会一起带上。只想要干净的 `ls -al`，把脚本里那行 `exec` 改回去即可。

用**可执行文件**而不是别名、也不靠装包：Alpine 用 busybox ash，别名要写进 `/etc/profile` 之类，只对**交互式登录 shell**、且按用户生效，在脚本 / cron / `doas` / `ssh 单命令`里都不可用；而 `ll` 是 shell 别名惯例、不是一条命令，Alpine 里没有任何 apk 包专门提供它。放到全局 PATH 的可执行文件后，`alpine` 用户、root、交互式与非交互式 shell 都统一可用。Alpine 默认不自带 `ll`；若以后手工加过 `alias ll=...`，交互式 shell 里 alias 会优先，注意保持一致。

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
4. **（可选）IPv6 路由通告**：本方案默认不启用，见第 6 节

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

> 脚本把 `nftables` 加入 boot 运行级，把 `sshd / mihomo / crond / qemu-guest-agent` 加入 default 运行级。radvd 不在其中，见第 6 节。

## Web 面板

安装完成后访问：

```
http://<服务器IP>:9090
```

API 密钥为 `config.yaml` 里的 `secret`（默认 `CHANGE_ME`，请修改），外部 UI 为 Zashboard。

## 系统要求

- Alpine Linux 3.x（不跨大版本）
- 支持 TUN 的内核
- Root 权限
- 网络连接

## 故障排查

| 问题 | 排查命令 |
|------|----------|
| 脚本提示内核版本不匹配 | 先 `reboot` 再重跑 |
| 软件源更换后 `apk update` 失败 | `cat /etc/apk/repositories` 确认南大源可达；原文件已备份为 `.bak.<时间戳>` |
| 升级后脚本提示「需要重启」 | 执行 `reboot` 后重跑本脚本（换源幂等，不会重复追加） |
| 提示「滚动版本」而退出 | 把 `/etc/apk/repositories` 固定到 `v3.x` 具体版本再运行 |
| 工具安装失败 | `apk search <包名>` 确认该包在 v3.x 的 main/community 中存在 |
| 提示「缺少必需的资源文件」 | 从脚本所在目录连同 `assets/` 一起取用，不要只拷脚本 |
| 版本查询 / 下载反复失败 | 检查网络，或用 `MIHOMO_VERSION=v1.19.22` 显式钉死；脚本重试 2 次后即退出，不会降级 |
| `sysctl -p` 失败 | `modprobe tcp_bbr sch_fq` 后重跑，或确认内核支持 BBR / fq |
| mihomo 无法启动 | 脚本会直接报错退出；`tail /var/log/mihomo/mihomo.log` |
| 防火墙规则 | `nft list ruleset` |
| 确认双栈伪装是否生效 | `nft list table inet nat` |
| DNS 劫持不生效（`dig @<网关IP>` 返回真 IP 或超时） | `nft list ruleset \| grep redirect` 确认规则存在；`ss -lunp \| grep 1053` 确认 mihomo 在听 1053；确认 DNS 是否真的被送到了网关——若已删 dst-nat 改走 mark，检查「目的 53」是否仍被 mark 分流到网关（没到网关劫持自然失效）；若保留 dst-nat，确认它指向网关且 dport 为 53 |
| TUN 模块 | `lsmod | grep tun` |
| 网络连接 | `ping -c 4 223.5.5.5` |
| IPv6 网段 | `ip -6 route show` |
| IPv6 集合是否已加入 | `nft list set inet filter local_ipv6_list` |
| 升级后出现 `*.apk-new` 配置文件 | `update-conf -l` 只读列出；处理需人工，见下方说明 |

**关于 `*.apk-new`**：`apk upgrade` 不会覆盖 `/etc` 下被改过的配置文件，而是把包里的新版本另存为 `<文件>.apk-new`（类似 Debian 的 `.dpkg-dist`、RPM 的 `.rpmnew`）。`update-conf`（来自 `alpine-conf` 包）专门用来收拾它们：`update-conf -l` 只读列出所有新旧并存的路径、不改任何文件；不带参数直接跑会显示 `diff -u` 并让你选 `z`（删新文件、保留现状）/ `u`（用新文件覆盖）/ `e`（编辑）/ `s`（看 diff）等。脚本**不自动处理**：`u` 用在 `passwd`、`shadow`、`doas.conf`、`hosts` 上会清掉密码哈希与授权、可能把自己锁在门外，必须人工判断。`update-conf` 没装时也可用 `find /etc -name '*.apk-new'` 自己列。

## 相关链接

- [mihomo](https://github.com/MetaCubeX/mihomo)
- [meta-rules-dat](https://github.com/MetaCubeX/meta-rules-dat)
- [Alpine Linux](https://alpinelinux.org/)
- [南京大学开源镜像站帮助文档](https://doc.nju.edu.cn/books/e1654)
