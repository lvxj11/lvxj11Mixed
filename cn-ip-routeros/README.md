# CN IP RouterOS Script Generator

下载中国 IP 地址段与代理相关 IP 段，生成可直接导入 RouterOS 的 `.rsc` 脚本（含 IPv4 与 IPv6）。

## 功能特性

- 从 MetaCubeX/meta-rules-dat 下载中国 IP 列表 `cn.list`，自动区分 IPv4 / IPv6 网段
- 额外合并一份 **PROXY-IP** 列表：Telegram IP 段、Google AS15169 段，并加入 Clash/Mihomo 的 fake-ip 地址段
- 一次生成两个 RouterOS address-list：`CN-IP`（直连用）与 `PROXY-IP`（走代理用）
- 支持自定义列表名称与输出文件；生成的脚本先清后加，具有幂等性，可重复导入
- CI 每日自动更新 `dist/` 里的成品，并保留最近 8 个历史版本

## 依赖

- `bash`（脚本用到数组与 here-string）、`curl` 或 `wget`
- `grep` / `sed` / `wc` 等基础工具

## 使用方法

### 方法一：直接下载仓库中已生成的脚本（推荐）

```bash
curl -o cn-ip-routeros.rsc \
  https://raw.githubusercontent.com/lvxj11/lvxj11Mixed/main/cn-ip-routeros/dist/cn-ip-routeros.rsc
```

`dist/cn-ip-routeros.rsc` 始终是最新版，另有 `dist/cn-ip-routeros-<时间戳>.rsc` 历史版本及配套 `.md5`。无需本地安装任何依赖。

### 方法二：本地运行脚本生成

```bash
# 基本用法（在当前目录生成 cn-ip-routeros.rsc）
./download-cn-ip.sh

# 自定义两个列表名称与输出文件
./download-cn-ip.sh -l china-ip -p proxy-ip -o output.rsc
```

## 选项

| 选项 | 描述 | 默认值 |
|------|------|--------|
| `-l, --list-name NAME` | 中国 IP 地址列表名称 | `CN-IP` |
| `-p, --proxy-list-name NAME` | 代理 IP 地址列表名称 | `PROXY-IP` |
| `-o, --output FILE` | 输出文件名 | `cn-ip-routeros.rsc` |
| `-h, --help` | 显示帮助信息 | — |

## 生成的脚本内容

脚本对两个列表都先**清除同名旧条目**保证幂等，再按下表写入：

| 列表 | 内容 |
|------|------|
| `CN-IP` | `cn.list` 中的全部中国 IPv4 / IPv6 网段 |
| `PROXY-IP` | fake-ip 段（`198.18.128.1/17`、`fdfe:dcba:9876::1/64`）+ Telegram IP 段 + Google AS15169 段 |

末尾输出一行 `:put "... updated successfully."`，便于在 RouterOS 中确认导入完成。

## 在 RouterOS 中导入脚本

### 方法一：通过 Winbox

1. 打开 Winbox，进入 `Files` 菜单
2. 上传生成的 `.rsc` 文件到 RouterOS 设备
3. 在终端中执行：`/import cn-ip-routeros.rsc`

### 方法二：通过 SSH

```bash
scp cn-ip-routeros.rsc admin@router-ip:/
ssh admin@router-ip "/import cn-ip-routeros.rsc"
```

## 自动更新（CI）

[`.github/workflows/update-cn-ip.yml`](../.github/workflows/update-cn-ip.yml) 每天 04:00 UTC（及手动触发）运行 `download-cn-ip.sh`，与 `dist/` 中现有文件比对 MD5：

- 无变化 → 跳过提交
- 有变化 → 覆盖 `dist/cn-ip-routeros.rsc`（及 `.md5`），另存一份带时间戳的历史归档，只保留最近 8 个，然后以 `[skip ci]` 提交推送

`dist/` 默认被 `.gitignore` 忽略，CI 用 `git add -f` 强制纳入，因此直接用 `dist/` 里的成品即可，无需本地定时生成。

## 数据源

全部来自 [MetaCubeX/meta-rules-dat](https://github.com/MetaCubeX/meta-rules-dat) 的 `meta` 分支：

| 用途 | 文件 |
|------|------|
| 中国 IP 段 | `geo/geoip/cn.list` |
| Telegram IP 段 | `geo/geoip/telegram.list` |
| Google AS15169 | `asn/AS15169.list` |

## 注意事项

- 列表条目较多，导入可能需要几分钟，建议在维护窗口执行
- 导入前会清除同名 address-list 的全部条目，请确认列表名不与现有配置冲突
- 本脚本只负责生成 IP 段列表，具体分流规则请以实际代理配置为准
