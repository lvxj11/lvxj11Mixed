#!/bin/bash
# for ImmortalWrt 25.12 (Docker环境)

set -e

echo "=== ImmortalWrt ImageBuilder 构建脚本 ==="
echo "当前目录: $(pwd)"
echo "Docker环境: $(hostname)"

# 确保在正确的目录
if [ ! -f Makefile ]; then
    echo "错误: 未找到 Makefile，请确认脚本所在目录为 ImageBuilder 目录"
    exit 1
fi

# 不生成ext4文件系统镜像
# sed -i '/^CONFIG_TARGET_ROOTFS_EXT4FS/d' .config

# 只保留 raw (.img.gz) 磁盘镜像，取消其它打包格式（PVE 使用 ext4 raw 导入）
sed -i -E '/^CONFIG_(ISO|QCOW2|VDI|VMDK|VHDX)_IMAGES=/d' .config

# 更换为国内镜像源（南大镜像实测最快；稳定性不足时可切中科大 mirrors.ustc.edu.cn）
sed -i 's|https://downloads.immortalwrt.org|https://mirror.nju.edu.cn/immortalwrt|g' repositories

# 自定义软件包（ca-bundle/luci/luci-base 为默认包，luci-compat 新版 LuCI 不需要，均不再重复列出）
# kmod-nft-socket 与 kmod-nft-tproxy 配套（TPROXY 需 NFT_SOCKET + NFT_TPROXY 两个内核模块）
# yq 为常用 YAML 工具、kmod-dummy 为常用虚拟网卡驱动，均显式锁定，不依赖 nikki 是否安装
PACKAGES="-dnsmasq dnsmasq-full ip-full openssh-sftp-server qemu-ga \
kmod-tun kmod-inet-diag kmod-nft-socket kmod-nft-tproxy kmod-dummy kmod-sched kmod-tcp-bbr \
ca-certificates \
curl wget-ssl jq yq unzip tree \
htop iftop tcpdump-mini \
luci-i18n-base-zh-cn \
luci-i18n-package-manager-zh-cn \
luci-app-firewall luci-i18n-firewall-zh-cn \
luci-app-ttyd luci-i18n-ttyd-zh-cn"

# 添加nikki源（ImmortalWrt兼容）
ARCH="x86_64"
BRANCH="openwrt-25.12"
REPOSITORY_URL="https://nikkinikki.pages.dev"
FEED_URL="$REPOSITORY_URL/$BRANCH/$ARCH/nikki"
echo "添加密钥..."
mkdir -p keys
# 每次构建先清掉旧的 nikki 源，保证幂等
sed -i '/nikki/d' repositories
# 只有公钥下载成功且非空时才添加源与软件包，避免空密钥文件导致构建失败
if wget --timeout=30 -O "keys/nikki.pem" "$REPOSITORY_URL/public-key.pem" && [ -s "keys/nikki.pem" ]; then
    echo "$FEED_URL/packages.adb" >> repositories
    echo "完成！nikki软件源已添加。"
    PACKAGES="$PACKAGES luci-app-nikki luci-i18n-nikki-zh-cn"
else
    rm -f "keys/nikki.pem"
    echo "警告: nikki 密钥下载失败，跳过添加 nikki 源与软件包"
fi

# 开始生成镜像（使用相对路径，适配非Docker环境）
make V=s image PACKAGES="$PACKAGES" FILES=/builder/files BIN_DIR=/output ROOTFS_PARTSIZE="800"
