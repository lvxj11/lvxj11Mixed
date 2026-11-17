#!/bin/sh
# Alpine 无人值守安装（传统 ISO / Live 环境）
# 新部署请优先使用 cloud-init 方案，见同目录 PVE9-cloud-init.md。
# 本脚本保留给需要在控制台粘贴执行、或需要自定义分区整盘安装的场景。
set -eu

die() {
    printf 'ERROR: %s\n' "$*" >&2
    exit 1
}

[ "$(id -u)" -eq 0 ] || die "请以 root 运行本脚本"

# 版本：跟随启动介质（即你选定的那份官方镜像），可显式覆盖以便复现。
# 取不到就报错退出，不猜测、不回退到滚动版本。
ALPINE_VERSION="${ALPINE_VERSION:-$(cut -d. -f1,2 /etc/alpine-release 2>/dev/null || true)}"
case "$ALPINE_VERSION" in
    3.[0-9]|3.[0-9][0-9]) ;;
    *) die "无法确定 Alpine 版本（/etc/alpine-release）。可用 ALPINE_VERSION=3.23 显式指定" ;;
esac

TARGET_DISK="${TARGET_DISK:-sda}"

# root 公钥从外部文件读取，真实公钥不写进仓库。
# 文件内容可以是一行公钥，也可以是 HTTP(S)/FTP URL（setup-sshd 会自行 wget 下载）。
SSH_KEY_FILE="${SSH_KEY_FILE:-$(dirname "$0")/authorized_keys}"
[ -r "$SSH_KEY_FILE" ] || die "缺少公钥文件 $SSH_KEY_FILE；可用 SSH_KEY_FILE 指定路径，真实公钥请勿提交到仓库"
ROOTSSHKEY="$(cat "$SSH_KEY_FILE")"
[ -n "$ROOTSSHKEY" ] || die "$SSH_KEY_FILE 为空"

ANSWERS_FILE="$(mktemp /tmp/alpine-answers.XXXXXX)"
trap 'rm -f "$ANSWERS_FILE"' EXIT INT TERM
chmod 600 "$ANSWERS_FILE"

printf '==> Alpine %s | APK 源 mirror.nju.edu.cn | 目标磁盘 /dev/%s（将被整盘清空）\n' \
    "$ALPINE_VERSION" "$TARGET_DISK" >&2

# 生成应答文件。ERASE_DISKS 是 setup-disk 的环境变量，不写在应答文件里。
cat > "$ANSWERS_FILE" << ANSWERS
KEYMAPOPTS="us us"
HOSTNAMEOPTS="-n alpine-pve"
INTERFACESOPTS="auto lo
iface lo inet loopback

auto eth0
iface eth0 inet dhcp"
TIMEZONEOPTS="-z Asia/Shanghai"
PROXYOPTS="none"
NTPOPTS="-c chrony"
APKREPOSOPTS="https://mirror.nju.edu.cn/alpine/v${ALPINE_VERSION}/main https://mirror.nju.edu.cn/alpine/v${ALPINE_VERSION}/community"
SSHDOPTS="-c openssh"
DISKOPTS="-m sys /dev/${TARGET_DISK}"
ANSWERS

# 公钥单独追加，避免其内容进入 heredoc 被二次展开
printf 'ROOTSSHKEY="%s"\n' "$ROOTSSHKEY" >> "$ANSWERS_FILE"

if ! ERASE_DISKS="$TARGET_DISK" setup-alpine -f "$ANSWERS_FILE"; then
    die "setup-alpine 安装失败，未产出可用系统（切勿当作安装成功直接重启使用）"
fi

# ROOTSSHKEY 已由 setup-sshd 写入目标系统 /root/.ssh/authorized_keys（umask 077），
# OpenSSH 默认 PermitRootLogin prohibit-password，即仅密钥、禁密码登录。
# 目标盘在 setup-alpine 结束后已卸载，不要再对 /mnt/etc/ssh/sshd_config 做修改。
printf '安装完成，请执行 reboot 重启。\n'
