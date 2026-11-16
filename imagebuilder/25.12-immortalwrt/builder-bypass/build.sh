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

# 公钥下载最多尝试 3 次（首次 + 重试 2 次）；下载失败绝不静默跳过 nikki，
# 否则会产出一个构建"成功"、校验和齐全、却完全没有 nikki 的镜像
NIKKI_KEY_OK=0
for attempt in 1 2 3; do
    rm -f "keys/nikki.pem"
    if wget --timeout=30 -O "keys/nikki.pem" "$REPOSITORY_URL/public-key.pem" && [ -s "keys/nikki.pem" ]; then
        NIKKI_KEY_OK=1
        break
    fi
    if [ "$attempt" -lt 3 ]; then
        echo "警告: 第 ${attempt} 次下载 nikki 公钥失败，重试..." >&2
        sleep 2
    fi
done

if [ "$NIKKI_KEY_OK" -ne 1 ]; then
    rm -f "keys/nikki.pem"
    echo "" >&2
    echo "============================================================" >&2
    echo " 错误: nikki 公钥下载失败，构建已中止（绝不静默跳过 nikki）" >&2
    echo " 已重试 2 次仍失败 ($REPOSITORY_URL/public-key.pem)。" >&2
    echo " 若继续构建会产出看似正常、实则不完整的镜像，因此拒绝降级。" >&2
    echo " 请检查 nikkinikki.pages.dev 连通性后重新执行。" >&2
    echo "============================================================" >&2
    exit 1
fi

echo "$FEED_URL/packages.adb" >> repositories
echo "完成！nikki软件源已添加。"
PACKAGES="$PACKAGES luci-app-nikki luci-i18n-nikki-zh-cn"

# 组装运行时 FILES：仓库静态配置 + 构建期生成的软件源/密钥。
# 源与密钥全部取自构建期现成的 repositories / keys，不把版本号、kmods 哈希写死在仓库里；
# 升级 ImmortalWrt 版本时会自动跟随 ImageBuilder 生成的 repositories。
RUNTIME_FILES=/tmp/ib-runtime-files
rm -rf "$RUNTIME_FILES"
mkdir -p "$RUNTIME_FILES/etc/apk/repositories.d" "$RUNTIME_FILES/etc/apk/keys"
cp -a /builder/files/. "$RUNTIME_FILES/"

# 官方源 → distfeeds.list（7 条南大源，含构建期版本号与 kmods 哈希）
grep -v nikki repositories > "$RUNTIME_FILES/etc/apk/repositories.d/distfeeds.list"
# nikki 源 → customfeeds.list（遵循官方 feed.sh 的分法）
grep nikki repositories > "$RUNTIME_FILES/etc/apk/repositories.d/customfeeds.list"
# 密钥 → 构建期 keys/（官方 2 个 + 本次下载的 nikki.pem）
cp -a keys/. "$RUNTIME_FILES/etc/apk/keys/"

# 开始生成镜像（使用相对路径，适配非Docker环境）
# 装包失败时 make 会以非 0 退出，配合 set -e 直接中止，无需额外自检
make V=s image PACKAGES="$PACKAGES" FILES="$RUNTIME_FILES" BIN_DIR=/output ROOTFS_PARTSIZE="800"
