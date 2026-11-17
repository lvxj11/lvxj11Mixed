# 在 Proxmox VE 9.2 上用 cloud-init 部署 Alpine（推荐方式）

> 适用环境：Proxmox VE 9.2、`local-lvm`（LVM-thin）存储。
> 本文是新建 VM 的**推荐方式**；传统 ISO 控制台安装见 [setup-alpine.sh](setup-alpine.sh)（legacy 备选）。
> 两种方式的对比见 [README.md](README.md)。

## 为什么改用 cloud-init

Alpine 官方云镜像是**已经装好系统的磁盘**，直接导入即可开机，跳过整个 `setup-alpine -f` 安装流程：

- 不需要在 PVE 控制台粘贴脚本，也不再需要单独的 virt/raw 安装镜像；
- 主机名、IP、SSH 公钥全部在 PVE 里声明式配置，可转模板 + 克隆批量复用；
- 官方镜像默认登录用户是 `alpine`（非 root，配好 doas 免密提权），比 root 直登更安全；
- 公钥由 PVE 注入，脚本和仓库里都不含任何密钥；
- 版本由镜像文件名钉死，不存在「装 3.24 内核配 3.23 源」的错配。

---

## 一、镜像选择

在 [Alpine Cloud Images](https://alpinelinux.org/cloud/) 下载页按下表筛选，钉死一个具体版本（本文用 `3.23.8`），**不要用 `latest-stable` 路径**：

| 维度 | 选择 | 说明 |
|---|---|---|
| Cloud Provider | **Generic** | 与 Debian 选 `genericcloud` 保持一致、好记不混淆 |
| Bootstrap | **cloud-init** | 决定镜像里装的是标准 cloud-init；`Tiny Cloud` 是 Alpine 自家轻量实现，PVE 的 CloudInit Drive 不适配 |
| Boot Method | `bios` / `uefi` | **必须匹配 VM 固件**：SeaBIOS → `bios`；OVMF(UEFI) → `uefi` |
| Machine | Virtual | 文件名**不带** `metal`（那是裸机变体） |
| 格式 | qcow2 | 导入 local-lvm 时 PVE 自动转成 raw 卷，无需手动转换 |

**关于 Generic / NoCloud / OCI**：3.23.6 起这三者是**同一份 qcow2**（哈希相同）。官方 manifest 里 `identity.cloud: generic`，而 `outputs.qcow2.clouds: [nocloud, oci]` —— Generic 是镜像身份，NoCloud/OCI 只是分发标签。选哪个入口下载到的文件都一样，所以按语义选 Generic 即可。

> 注意：3.23.8 上**不存在** `generic_` / `nocloud_` 前缀的文件（404），那是 3.23.4 及更早的旧版命名。点 Generic 入口下载到的文件名是**无前缀**的：
> ```
> alpine-3.23.8-x86_64-bios-cloudinit-r0.qcow2     # SeaBIOS
> alpine-3.23.8-x86_64-uefi-cloudinit-r0.qcow2     # OVMF
> ```
> 旧版（3.23.4 及更早）里 `generic_` 和 `nocloud_` 是两个不同文件，`generic_` 未固定 datasource、只挂 CIDATA 时可能回退到 `DataSourceNone` 导致配置不生效；若必须用旧版，请选 `nocloud_` 前缀那个。

**校验**（同目录下的 `.sha512` / `.asc`，GPG 公钥指纹 `F26A DFAD BAE7 02EF 7AF6 3745 9DA7 EF23 BFFC DF22`）：

```sh
cd /var/lib/vz/import
sha512sum -c alpine-3.23.8-x86_64-bios-cloudinit-r0.qcow2.sha512
gpg --verify alpine-3.23.8-x86_64-bios-cloudinit-r0.qcow2.asc
```

---

## 二、最佳实践配置清单

| 项 | 配置 | 理由 |
|---|---|---|
| 登录用户 | **默认 `alpine`，不用 root** | 官方镜像已建好该用户（wheel 组 + doas 免密），root 账户在镜像里是锁定的 |
| 认证 | `--sshkeys <公钥文件路径>`，**不设 `--cipassword`** | 仅密钥登录；口令会被 PVE 加密存进 Cloud-Init 数据，安全性更低 |
| 用户数据 | `ssh_pwauth: false`、`disable_root: true` | 禁密码登录、禁 root 远程登录 |
| 数据源 | `citype nocloud`（默认） | PVE 生成的是卷标 `cidata` 的 NoCloud ISO |
| 控制台 | 加串口 `serial0`，显示设为 serial0 | Alpine 云镜像走串口，否则 noVNC 黑屏 |
| 网络 | `--ipconfig0 ip=dhcp`（至少给一个值） | 留空会让 cloud-init 报错 |
| 生效 | 每次改 Cloud-Init 后 **Regenerate Image** | 不重新生成 ISO 则改动不生效 |
| 模板 | 配置完**先不要启动**就转模板 | 避免 machine-id / SSH host key 被所有克隆继承 |
| 密钥存放 | 公钥文件、自定义 user-data 放 PVE 本机 | **不要提交到公开仓库** |
| 首启升级 | **`--ciupgrade 0`** | PVE 9 的 `ciupgrade` 默认 1 → 生成的 user-data 带 `package_upgrade: true`，首启跑 `apk upgrade` 占用 apk 锁、拖慢启动 |

**不要**在 PVE 或 user-data 里设置 `ciuser root`、追加 `PermitRootLogin yes`，这会破坏上面的安全基线。

---

## 三、GUI 方式（PVE 9.2）

1. **启用 Import 内容类型**：数据中心 → 存储 → `local` → 编辑 → 内容(Content) 勾上 `Import` → OK。
2. **放入镜像**：该存储的 `Import` 页 → `Upload` 上传，或 `Download from URL` 填官方地址；也可直接 `scp` 到 `/var/lib/vz/import/`。
3. **创建 VM 骨架**（不要挂安装介质、不要建硬盘）：
   - 常规：VM ID 用高段位（如 `9000`），名称 `alpine-tpl`
   - 操作系统：`Do not use any media`，Guest OS 选 Linux
   - 系统：BIOS 按镜像变体选（SeaBIOS ↔ `bios` / OVMF ↔ `uefi`）；机器 `q35`；**勾选 QEMU Guest Agent**；SCSI 控制器 `VirtIO SCSI single`
   - 若用 OVMF：加 EFI Disk，并**取消 Pre-Enroll keys**（微软 Secure Boot keys 会挡住 Alpine）
   - 磁盘：删掉默认的 scsi0
   - CPU / 内存：1~2 核、1024 MiB 够用
   - 网络：`vmbr0`，模型 `VirtIO`
4. **导入磁盘**：在「硬件 → 添加 → 硬盘」或创建向导的磁盘步骤里选 **Import from image**，选中第 2 步的 qcow2，目标存储 `local-lvm`、总线 `SCSI 0`。PVE 9 一步完成转换 + 挂载。
5. **加 CloudInit Drive**：硬件 → 添加 → `CloudInit Drive`，保持 `ide2`。
6. **串口与引导**：硬件 → 添加 → 串口 0；选项 → 显示改为 `Serial terminal 0`；选项 → 引导顺序只启用 `scsi0` 并置顶。
7. **Cloud-Init 面板**：
   - User: `alpine`
   - SSH public key: 粘贴你的公钥（不要带注释行）
   - IP Config (net0): `DHCP`
   - Password: **留空**
   - PVE 9.2 的 Web UI **没有** `Upgrade packages`（`ciupgrade`）控件，需在 PVE shell 执行 `qm set <vmid> --ciupgrade 0`，再回来点 **Regenerate Image**；用 `qm config <vmid> | grep ciupgrade` 确认已写入
8. **（可选）扩容**：硬件 → 磁盘 → 调整大小到 8G，首启 cloud-init 的 growpart/resizefs 会自动扩展。
9. **转模板**：右键 VM → `Convert to template`。
10. **部署**：右键模板 → `Clone`，得到新 VM 后**先改** Cloud-Init（IP / 公钥 / 按需静态地址）→ **Regenerate Image** → 再开机。

---

## 四、CLI 方式

在 PVE 主机 shell 中执行。先按实际环境改变量：

```sh
VMID=9000
STORAGE=local-lvm
IMAGE=/var/lib/vz/import/alpine-3.23.8-x86_64-bios-cloudinit-r0.qcow2
PUBKEY=/root/.ssh/id_ed25519.pub      # PVE 本机上的公钥文件，不入库
BRIDGE=vmbr0
```

```sh
# 1. 建 VM 骨架（无盘）。BIOS 需与镜像变体一致：bios↔seabios，uefi↔ovmf
qm create "$VMID" --name alpine-tpl --memory 1024 --cores 2 \
  --net0 "virtio,bridge=$BRIDGE" --scsihw virtio-scsi-pci \
  --serial0 socket --vga serial0 --bios seabios --ostype l26

# 用 UEFI 镜像时改成（并加 EFI Disk，pre-enrolled-keys=0）：
# qm create "$VMID" --name alpine-tpl --memory 1024 --cores 2 \
#   --net0 "virtio,bridge=$BRIDGE" --scsihw virtio-scsi-pci \
#   --serial0 socket --vga serial0 --bios ovmf --machine q35 \
#   --efidisk0 "${STORAGE}:1,efitype=4m,pre-enrolled-keys=0" --ostype l26

# 2. 导入并挂载磁盘（PVE 8.3+；qcow2 自动转 raw 存入 local-lvm）
qm set "$VMID" --scsi0 "${STORAGE}:0,import-from=$IMAGE"

# 3. CloudInit Drive + 引导顺序
qm set "$VMID" --ide2 "${STORAGE}:cloudinit" --boot order=scsi0

# 4. Cloud-Init 配置：alpine 用户 + 公钥，不设密码
qm set "$VMID" --citype nocloud \
  --ciuser alpine \
  --sshkeys "$PUBKEY" \
  --ipconfig0 ip=dhcp \
  --ciupgrade 0

# 5.（可选）QEMU Guest Agent、磁盘扩容
qm set "$VMID" --agent enabled=1
qm resize "$VMID" scsi0 8G

# 6. 启动前核对生成的 user-data（应出现 user: alpine 与你的公钥，无 password）
qm cloudinit dump "$VMID" user

# 7. 转模板（不要先启动）
qm template "$VMID"

# 8. 克隆部署：先改配置、重新生成，再开机
qm clone "$VMID" 110 --name gw-01 --full
qm set 110 --ipconfig0 ip=dhcp            # 或 ip=192.168.1.10/24,gw=192.168.1.1
qm cloudinit dump 110 user
qm start 110
```

> 说明：
> - `--sshkeys` 接受**公钥文件路径**（每行一把，OpenSSH 格式），这是 PVE 9.2 手册中的写法；部分旧文档写作 `--sshkey`，以 `--sshkeys` 为准。
> - PVE 8.3 以下没有 `import-from`，改用 `qm importdisk "$VMID" "$IMAGE" "$STORAGE"` 再 `qm set "$VMID" --scsi0 "${STORAGE}:vm-${VMID}-disk-0"`。
> - 改动 Cloud-Init 配置后，CLI 可用 `qm set "$VMID" --ide2 "${STORAGE}:cloudinit"` 重新生成 ISO，等价于 GUI 的 Regenerate Image。

---

## 五、可选进阶：自定义 vendor-data

需要固定时区、预装软件包时，**用 `vendor=` 而不是 `user=`**：

> PVE 的 `--cicustom "user=..."` 是**替换**自动生成的 user-data，不是合并。用了它，PVE 动态注入的 hostname、`alpine` 用户、SSH 公钥全部丢失，克隆时也无法按 VM 改配置。而 PVE **不生成 vendor-data**，挂 `vendor=` 可以补充配置且保留 PVE 的 user-data（cloud-config 合并时 user-data 优先）。

```sh
mkdir -p /var/lib/vz/snippets
cat > /var/lib/vz/snippets/alpine-vendor.yaml <<'EOF'
#cloud-config
timezone: Asia/Shanghai
ssh_pwauth: false
disable_root: true
packages:
  - tzdata
  - qemu-guest-agent
runcmd:
  - rc-update add qemu-guest-agent default
  - rc-service qemu-guest-agent start
EOF

qm set "$VMID" --cicustom "vendor=local:snippets/alpine-vendor.yaml"
qm cloudinit dump "$VMID" user      # 确认 PVE 生成的 user-data 仍在（hostname / user / 公钥）
```

注意：

- vendor-data 里**不要**写 `users:`、`ssh_authorized_keys`、`hostname`、`fqdn`、`package_upgrade` —— 这些由 PVE 的 user-data 生成或优先，写了会被忽略 / 冲突。
- 首启的 `package_upgrade: true` 来自 PVE user-data，vendor-data 里写 `false` 压不过它，**必须用 `--ciupgrade 0`** 关掉。
- 公钥仍用 `--sshkeys` 注入，不要写进 snippets；也不要在 snippets 里放订阅地址、口令、设备 MAC 等私有信息。

### 更换软件源（`apk_repos`）

cloud-init 有 Alpine 专用模块 `cc_apk_configure`，负责生成 `/etc/apk/repositories`。放进同一份 vendor-data 即可（PVE 的 user-data 里没有 `apk_repos` 键，不会冲突）：

```yaml
apk_repos:
  alpine_repo:
    base_url: 'https://mirror.nju.edu.cn/alpine'
    community_enabled: true
    version: 'v3.23'
```

生成结果：

```
https://mirror.nju.edu.cn/alpine/v3.23/main
https://mirror.nju.edu.cn/alpine/v3.23/community
```

要点：

- `base_url` 填镜像的 alpine **根目录**，模块自己拼 `/<version>/main` 和 `/community`；URL 含冒号，YAML 里要加引号。
- **`version` 必须和镜像版本对齐**（3.23.x → `'v3.23'`）。换镜像版本时同步改这里，否则会装出「内核 3.24 + 用户态 3.23」的混血系统 —— 和传统 ISO 脚本原来写死版本是同一类坑。
- 模块只写文件，**不会自动 `apk update`**；设了 `--ciupgrade 0` 后首启也没有自动更新，开机后手动跑一次 `doas apk update`（或在 `runcmd` 里加）。
- 该模块在 config 阶段执行，早于 final 阶段的包操作，换源对首启生效。换成国内镜像也能缓解首启 `apk upgrade` 访问 CDN 慢、长时间占用 apk 锁的问题。

想让版本自动跟随镜像，可改用 `runcmd` 生成（不要和 `apk_repos` 同时用）：

```yaml
runcmd:
  - |
    V=$(cut -d. -f1,2 /etc/alpine-release)
    printf 'https://mirror.nju.edu.cn/alpine/v%s/main\nhttps://mirror.nju.edu.cn/alpine/v%s/community\n' "$V" "$V" > /etc/apk/repositories
    apk update
```

取舍：显式 `version` 更声明式、和「版本必须锁定」一致；`runcmd` 免维护但偏命令式，二选一。另也可用通用的 `write_files` 直接覆盖 `/etc/apk/repositories`。

---

## 六、首次启动验证

在克隆出来的 VM 上（串口控制台或 SSH）：

```sh
cloud-init status --long        # status: done；detail 行必须是 DataSourceNoCloud
ssh alpine@<VM_IP>              # 用 alpine 登录，不是 root
doas -s                         # 提权到 root；doas 规则由镜像预置
```

- 若 `cloud-init status --long` 的 detail 显示 `DataSourceNone` 或日志里有 `Used fallback datasource`，说明镜像没认出 PVE 的 CIDATA。补救：进系统写 `/etc/cloud/cloud.cfg.d/99-datasource.cfg`（内容 `datasource_list: [NoCloud]`）后 `cloud-init clean`，再重新封模板；或退回使用带 `nocloud_` 前缀的 3.23.4 镜像。
- 验证 root **不能**远程登录（应被拒绝），且 `ssh_pwauth` 为 false。
- `qm cloudinit dump <vmid> user` 可在开机前核对 PVE 生成的 user-data 是否正确。

---

## 七、常见坑

| 现象 | 原因 / 处理 |
|---|---|
| noVNC 黑屏、看不到启动过程 | 未加串口；补 `--serial0 socket --vga serial0` |
| OVMF 起不来 | 镜像选了 `bios` 变体；或 Pre-Enroll keys 未关 |
| cloud-init 配置不生效 | 改完没 Regenerate Image；或 IP Config 留空 |
| `DataSourceNone` / fallback | datasource 未识别，见第六节补救 |
| 克隆后所有 VM 相同 machine-id / host key | 模板被提前启动过；重新封模板并清理 `/etc/machine-id`、`/var/lib/cloud` |
| 磁盘只看到 2~3G | 扩容后靠 cloud-init 首次启动自动 growpart/resizefs，重启一次即可 |
| `tz: not found` / 时区不对 | 云镜像精简未装 `tzdata`；`apk add tzdata` 后用 `setup-timezone -z Asia/Shanghai`，或用 vendor-data 的 `timezone:` |
| `apk update` 报 `Unable to open log: Permission denied` | apk 需 root：用 `doas apk update`，不是脚本或镜像故障 |
| `doas apk update` 报 `Unable to lock database: Resource temporarily unavailable` | cloud-init 首启的 `apk upgrade` 还在占 apk 锁；等 `cloud-init status --long` 显示 `status: done` 再执行，模板层设 `--ciupgrade 0` 根治 |
| 用 `--cicustom "user=..."` 后公钥 / 主机名不生效 | `user=` 是替换不是合并，覆盖了 PVE 动态生成的 user-data；改用 `vendor=` |
| 首启出现 `apk upgrade` 相关告警 | PVE 默认 `ciupgrade=1`；设 `--ciupgrade 0`，非致命 |

---

## 八、后续：部署旁路网关

装好系统后接 [Mihomo](../Mihomo/README.md) 或 [sing-box](../sing-box/readme.md)。**注意两点兼容问题**：

1. 下游脚本要求 root 权限（`Mihomo/install-mihomo-alpine.sh:60`、`sing-box/singbox-autoinit-alpine.sh:5` 都检查 `id -u == 0`），用 `doas ./xxx.sh` 运行，或 `doas -s` 后再执行。
2. `sing-box/singbox-autoinit-alpine.sh` 会向 `sshd_config` 追加 `PermitRootLogin yes`，这会**打开 root 密码登录**、与本文的安全基线冲突。用 cloud-init 方式时请先去掉或改掉这一段（至少改成 `prohibit-password`）。
