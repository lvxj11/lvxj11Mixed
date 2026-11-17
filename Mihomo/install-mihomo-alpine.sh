#!/bin/sh
# Alpine 3.x 旁路网关 + mihomo 一键安装脚本
set -e

# ============================================================================
# 全局变量定义
# ============================================================================

# 脚本信息
SCRIPT_NAME="install-mihomo-alpine.sh"
SCRIPT_VERSION="1.5.1"

# 系统配置变量
TIMEZONE="Asia/Shanghai"
LOCALE_TIMEZONE="/usr/share/zoneinfo/Asia/Shanghai"

# Alpine 版本：跟随当前系统（/etc/alpine-release），可显式覆盖以便复现。
# 只支持 3.x 大版本；取不到或跨大版本一律报错退出，不猜测、不降级。
ALPINE_VERSION="${ALPINE_VERSION:-}"

# mihomo 版本：可显式钉死以便复现（如 MIHOMO_VERSION=v1.19.22）。
# 未指定时从 GitHub releases/latest 解析具体 tag；查询失败重试后醒目退出，
# 绝不回退到滚动 tag / 主版本 tag / 猜测版本。
MIHOMO_VERSION="${MIHOMO_VERSION:-}"
RELEASE_INFO=""
MIHOMO_RELEASE_URL=""

# 网络配置变量
NETWORK_IFACE=""

# mihomo 配置
MIHOMO_CONFIG_DIR="/etc/mihomo"
MIHOMO_BIN_PATH="/usr/local/bin/mihomo"

# GitHub API 配置
GITHUB_API_URL="https://api.github.com/repos/MetaCubeX/mihomo/releases/latest"
RELEASES_TAGS_URL="https://api.github.com/repos/MetaCubeX/mihomo/releases/tags"
RETRY_COUNT=2

# 系统架构映射
ARCH_MAP="x86_64:amd64 aarch64:arm64 armv7l:armv7 arm:armv7"

# 软件包列表（不装 radvd：本方案刻意不让旁路由接管 IPv6 网关，见 README）
# 分三行只为可读性，最终仍是同一个空格分隔列表；按需删某一组即可。
# yq-go 是 Alpine 3.20+ 中 mikefarah/yq 的包名；旧版 yq（Python 实现）只到 3.19。
# yq-go、mtr 在 community 仓库，configure_apk_repos() 已确保 community 被启用。
PACKAGES_BASE="curl iproute2 nftables openssh tzdata jq ca-certificates wget tcpdump htop iftop qemu-guest-agent ethtool"
PACKAGES_BASE="${PACKAGES_BASE} yq-go bind-tools conntrack-tools iputils socat"
PACKAGES_BASE="${PACKAGES_BASE} tmux nano vim iperf3 mtr rsync tree lsof"

# 软件源：cloud-init 官方镜像默认指向 dl-cdn.alpinelinux.org，国内访问慢。
# 只替换域名，保留版本路径与 main/community/testing 条目（南大官方帮助即如此）。
# 域名以南大官方文档 https://doc.nju.edu.cn/books/e1654 首页为准：mirror.nju.edu.cn（不带 s）。
APK_REPOS_FILE="/etc/apk/repositories"
APK_MIRROR_HOST="mirror.nju.edu.cn"

# 内核模块列表
KERNEL_MODULES="tun br_netfilter nf_conntrack"

# 服务列表
SERVICES_BOOT="nftables"
SERVICES_DEFAULT="sshd mihomo crond qemu-guest-agent"

# 文件路径：assets 相对脚本自身定位，不依赖当前工作目录
SCRIPT_DIR=$(CDPATH= cd "$(dirname "$0")" && pwd)
ASSETS_DIR="${SCRIPT_DIR}/assets"
SYSCTL_CONFIG="/etc/sysctl.d/99-network-gateway.conf"
MIHOMO_SERVICE="/etc/init.d/mihomo"
LOGROTATE_CONFIG="/etc/logrotate.d/mihomo"
LL_BIN="/usr/local/bin/ll"

# 下载/解压用的临时目录，由 EXIT trap 统一清理
TMP_DIR=""

# ============================================================================
# 工具函数
# ============================================================================

log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1"
}

error_exit() {
    log "错误: $1"
    exit 1
}

cleanup() {
    if [ -n "${TMP_DIR}" ] && [ -d "${TMP_DIR}" ]; then
        rm -rf "${TMP_DIR}"
    fi
}

# 关键资源缺失一律报错退出，禁止「警告后继续」产出看着成功、实则残缺的系统
require_asset() {
    if [ ! -f "$1" ]; then
        error_exit "缺少必需的资源文件: $1（请从脚本所在目录连同 assets/ 一起取用，不要只拷脚本）"
    fi
}

# 带重试的下载：$1=标签 $2=URL $3=输出文件（"-" 表示输出到 stdout）
fetch_with_retry() {
    local label="$1" url="$2" output="$3"
    local attempt=0
    while [ "${attempt}" -le "${RETRY_COUNT}" ]; do
        if [ "${output}" = "-" ]; then
            wget -qO- "${url}" && return 0
        else
            wget -qO "${output}" "${url}" && return 0
        fi
        attempt=$((attempt + 1))
        if [ "${attempt}" -le "${RETRY_COUNT}" ]; then
            log "警告: ${label} 第 ${attempt} 次失败，重试 ${attempt}/${RETRY_COUNT}"
            sleep 1
        fi
    done
    return 1
}

check_root() {
    if [ "$(id -u)" != "0" ]; then
        error_exit "请使用root用户运行脚本！"
    fi
}

check_alpine_version() {
    log "检查 Alpine 版本..."
    if [ -z "${ALPINE_VERSION}" ]; then
        ALPINE_VERSION=$(cut -d. -f1,2 /etc/alpine-release 2>/dev/null || true)
    fi
    # 只接受 3.x：跨大版本的内核 / 软件包差异不做兼容
    case "${ALPINE_VERSION}" in
        3.[0-9]|3.[0-9][0-9]) ;;
        *) error_exit "无法确定 Alpine 版本（/etc/alpine-release）。仅支持 3.x，可用 ALPINE_VERSION=3.23 显式指定" ;;
    esac
    log "Alpine 版本检查通过: ${ALPINE_VERSION}"
}

detect_network_interface() {
    log "检测网卡名称..."
    local iface=""
    # 优先取默认路由所在网卡；再退回「第一个非虚拟网卡」
    iface=$(ip -o -4 route show default 2>/dev/null | awk '{for (i=1; i<=NF; i++) if ($i == "dev") print $(i+1)}' | head -n 1)
    if [ -z "${iface}" ]; then
        iface=$(ip -o -6 route show default 2>/dev/null | awk '{for (i=1; i<=NF; i++) if ($i == "dev") print $(i+1)}' | head -n 1)
    fi
    if [ -z "${iface}" ]; then
        iface=$(ip -o link show | awk -F': ' '{print $2}' | grep -v '^lo$' \
            | grep -vE '^(tun|tap|veth|docker|br-|virbr|wg|ppp)' | head -n 1)
    fi
    if [ -z "${iface}" ]; then
        error_exit "无法检测到主网卡"
    fi
    # 网卡名只允许安全字符，避免破坏后续 sed 替换
    case "${iface}" in
        *[!A-Za-z0-9_.-]*) error_exit "网卡名包含非法字符: ${iface}" ;;
    esac
    NETWORK_IFACE="${iface}"
    log "检测到主网卡: ${NETWORK_IFACE}"
}

check_kernel_version() {
    local reason="${1:-安装前}"
    log "检查内核版本（${reason}）..."
    local running_kernel=$(uname -r)
    local installed_kernel=""
    local pkg=""

    for pkg in linux-lts linux-virt; do
        installed_kernel=$(apk list "${pkg}" 2>/dev/null | grep "\[installed\]" | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -n 1)
        if [ -n "${installed_kernel}" ]; then
            break
        fi
    done

    if [ -n "${installed_kernel}" ]; then
        case "${running_kernel}" in
            "${installed_kernel}"*) ;;
            *)
                log "警告: 运行中的内核版本 (${running_kernel}) 与已安装的内核版本 (${installed_kernel}) 不匹配"
                log "需要重启：请执行 reboot，重启后重新运行本脚本"
                exit 1
                ;;
        esac
    fi
    log "内核版本检查通过: ${running_kernel}"
}

# ============================================================================
# 系统初始化函数
# ============================================================================

configure_apk_repos() {
    log "更换软件源为南京大学镜像..."
    if [ ! -f "${APK_REPOS_FILE}" ]; then
        error_exit "找不到 ${APK_REPOS_FILE}，无法更换软件源"
    fi

    # 滚动版本会让 apk upgrade 跨大版本，按「版本必须锁定、不跟随浮动 tag」直接拒绝
    if grep -qE 'latest-stable|/edge/' "${APK_REPOS_FILE}"; then
        error_exit "软件源指向滚动版本（latest-stable / edge），apk upgrade 可能跨大版本；请先固定到 v3.x 再运行"
    fi

    # 只处理官方源或已经换好的情况；第三方镜像不猜测、不强行覆盖
    if ! grep -qE "dl-cdn\.alpinelinux\.org|${APK_MIRROR_HOST}" "${APK_REPOS_FILE}"; then
        error_exit "软件源既不是官方源也不是 ${APK_MIRROR_HOST}，未做猜测；请手动处理后重跑"
    fi

    local timestamp=$(date '+%Y%m%d%H%M%S')
    cp "${APK_REPOS_FILE}" "${APK_REPOS_FILE}.bak.${timestamp}"

    # 只换域名，保留 http/https、版本路径（v3.xx）与 main/community/testing 条目；
    # 已经是南大源时 sed 不再改动，天然幂等，重跑安全
    sed -i "s|dl-cdn\.alpinelinux\.org|${APK_MIRROR_HOST}|g" "${APK_REPOS_FILE}"

    # cloud-init 精简镜像常只启用 main；yq-go 等包在 community，缺则补上
    if ! grep -qE '^[[:space:]]*https?://.*/community' "${APK_REPOS_FILE}"; then
        printf 'https://%s/alpine/v%s/community\n' "${APK_MIRROR_HOST}" "${ALPINE_VERSION}" >> "${APK_REPOS_FILE}"
        log "已补充 community 仓库: v${ALPINE_VERSION}"
    fi

    if ! grep -qF "${APK_MIRROR_HOST}" "${APK_REPOS_FILE}"; then
        error_exit "软件源更换失败：替换后未出现 ${APK_MIRROR_HOST}（原仓库文件可能不是官方源，未做猜测）"
    fi
    log "软件源已指向 ${APK_MIRROR_HOST}"
}

update_system() {
    log "更新系统并安装必要工具..."

    if ! apk update; then
        error_exit "apk update 失败，请检查软件源与网络"
    fi
    if ! apk upgrade; then
        error_exit "apk upgrade 失败，请检查软件源与网络"
    fi

    # 升级可能装上新内核，运行中的仍是旧内核；若继续加载模块 / 启动服务会失败。
    # 复用内核一致性检查：不一致就醒目提示并退出，reboot 后重跑即可（换源幂等）。
    check_kernel_version "软件源升级后"

    if ! apk add ${PACKAGES_BASE}; then
        error_exit "安装工具包失败（确认包名存在于 v${ALPINE_VERSION} 的 main/community 仓库）"
    fi
}

install_ll_command() {
    log "安装全局 ll 命令..."
    # 一行就能生成，不值得单独做一个 .template 资产：内联写入自包含、少一个随脚本分发的文件，
    # 也彻底避开「cp 到目录时目标继承 .template 后缀」那类问题。
    cat > "${LL_BIN}" <<'EOF'
#!/bin/sh
# ll：等价于 ls -alhF（-h 可读大小、-F 类型后缀），全局 PATH 中的可执行文件，
# 供所有用户 / 所有 shell 类型使用；"$@" 让追加参数照样透传。
# 不用 alias：alias 只对交互式登录 shell 生效且按用户隔离，脚本 / cron / doas / ssh 单命令里不可用。
exec ls -alhF "$@"
EOF
    chmod 755 "${LL_BIN}"
    log "ll 已安装到 ${LL_BIN}（等价于 ls -alhF，所有用户 / 所有 shell 类型均可用）"
}

set_timezone() {
    log "设置时区..."
    ln -sf "${LOCALE_TIMEZONE}" /etc/localtime
    echo "${TIMEZONE}" > /etc/timezone
}

load_kernel_modules() {
    log "加载内核模块..."
    for module in ${KERNEL_MODULES}; do
        if ! lsmod | grep -q "^${module} "; then
            modprobe "${module}" || error_exit "无法加载内核模块: ${module}"
            grep -q "^${module}$" /etc/modules 2>/dev/null || echo "${module}" >> /etc/modules
            log "${module}模块已加载"
        fi
    done
    # BBR / fq 依赖的模块（内核内建或未提供时忽略，由后续 sysctl 校验兜底）
    for module in tcp_bbr sch_fq; do
        modprobe "${module}" 2>/dev/null || log "提示: 模块 ${module} 未加载（可能内核已内建或未提供）"
    done
}

# ============================================================================
# 网络配置函数
# ============================================================================

configure_nftables() {
    log "配置nftables防火墙..."
    local nftables_config="/etc/nftables.nft"
    require_asset "${ASSETS_DIR}/nftables.conf.template"
    require_asset "${ASSETS_DIR}/update-ipv6-set.template"

    if [ -f "${nftables_config}" ]; then
        local timestamp=$(date '+%Y%m%d%H%M%S')
        mv "${nftables_config}" "${nftables_config}.bak.${timestamp}"
    fi

    if [ "${NETWORK_IFACE}" != "eth0" ]; then
        log "检测到网卡为 ${NETWORK_IFACE}，替换配置中的网卡名称..."
        sed "s/eth0/${NETWORK_IFACE}/g" "${ASSETS_DIR}/nftables.conf.template" > "${nftables_config}"
    else
        log "使用默认网卡 eth0 配置..."
        cp "${ASSETS_DIR}/nftables.conf.template" "${nftables_config}"
    fi
    log "nftables配置文件复制完成"

    # 安装 IPv6 网段更新脚本
    log "安装 IPv6 网段更新脚本..."
    mkdir -p /etc/periodic/15min
    cp "${ASSETS_DIR}/update-ipv6-set.template" /etc/periodic/15min/update-ipv6-set
    chmod +x /etc/periodic/15min/update-ipv6-set
    log "IPv6 网段更新脚本安装完成"
}

configure_sysctl() {
    log "配置系统参数..."
    require_asset "${ASSETS_DIR}/sysctl.conf.template"

    if [ -f "${SYSCTL_CONFIG}" ]; then
        local timestamp=$(date '+%Y%m%d%H%M%S')
        cp "${SYSCTL_CONFIG}" "${SYSCTL_CONFIG}.bak.${timestamp}"
    fi

    if [ "${NETWORK_IFACE}" != "eth0" ]; then
        log "检测到网卡为 ${NETWORK_IFACE}，替换配置中的网卡名称..."
        sed "s/eth0/${NETWORK_IFACE}/g" "${ASSETS_DIR}/sysctl.conf.template" > "${SYSCTL_CONFIG}"
    else
        log "使用默认网卡 eth0 配置..."
        cp "${ASSETS_DIR}/sysctl.conf.template" "${SYSCTL_CONFIG}"
    fi
    log "系统参数配置文件复制完成"

    if ! sysctl -p "${SYSCTL_CONFIG}"; then
        error_exit "应用 sysctl 配置失败（常见于内核未提供 tcp_bbr / sch_fq），请检查内核模块后重跑"
    fi
}

install_network_optimization_script() {
    log "安装网络优化脚本..."
    local if_up_dir="/etc/network/if-up.d"
    require_asset "${ASSETS_DIR}/network-optimization.template"
    mkdir -p "${if_up_dir}"
    cp "${ASSETS_DIR}/network-optimization.template" "${if_up_dir}/network-optimization"
    chmod +x "${if_up_dir}/network-optimization"
    log "网络优化脚本安装完成"
}

# ============================================================================
# mihomo 安装函数
# ============================================================================

validate_mihomo_version() {
    if [ -z "$1" ] || ! echo "$1" | grep -Eq '^v[0-9]+\.[0-9]+(\.[0-9]+)?$'; then
        error_exit "无法确定 mihomo 版本（得到: '$1'），应为 v1.19.22 这类具体 tag；不猜测、不回退到滚动版本"
    fi
}

# 解析并锁定 mihomo 版本；同时把发布信息存入 RELEASE_INFO 供下载复用
resolve_mihomo_version() {
    if [ -n "${MIHOMO_VERSION}" ]; then
        validate_mihomo_version "${MIHOMO_VERSION}"
        MIHOMO_RELEASE_URL="${RELEASES_TAGS_URL}/${MIHOMO_VERSION}"
        log "使用显式指定的 mihomo 版本: ${MIHOMO_VERSION}"
    else
        MIHOMO_RELEASE_URL="${GITHUB_API_URL}"
    fi

    log "查询 mihomo 发布信息..."
    if ! RELEASE_INFO=$(fetch_with_retry "mihomo 发布信息" "${MIHOMO_RELEASE_URL}" "-"); then
        error_exit "查询 mihomo 发布信息失败（重试 ${RETRY_COUNT} 次后仍失败），不猜测、不回退到滚动版本"
    fi

    if [ -z "${MIHOMO_VERSION}" ]; then
        # 按字段名锚定提取，兼容美化（多行）与紧凑（单行）JSON；
        # 不能用 s/.*"([^"]+)".*/ 这种贪婪写法，单行 JSON 会取到别的字段值
        MIHOMO_VERSION=$(echo "${RELEASE_INFO}" | grep '"tag_name"' | head -n 1 \
            | sed -E 's/.*"tag_name"[[:space:]]*:[[:space:]]*"([^"]+)".*/\1/')
        validate_mihomo_version "${MIHOMO_VERSION}"
        log "解析到最新版本: ${MIHOMO_VERSION}"
    fi
    log "mihomo 版本: ${MIHOMO_VERSION}"
}

download_mihomo() {
    log "检测系统架构..."
    local arch=$(uname -m)
    local mihomo_arch=""
    local mapping sys_arch
    for mapping in ${ARCH_MAP}; do
        sys_arch=$(echo "${mapping}" | cut -d':' -f1)
        if [ "${arch}" = "${sys_arch}" ]; then
            mihomo_arch=$(echo "${mapping}" | cut -d':' -f2)
            break
        fi
    done
    if [ -z "${mihomo_arch}" ]; then
        error_exit "不支持的架构: ${arch}（ARCH_MAP 无匹配，不猜测架构）"
    fi
    log "检测到系统架构: ${arch} (mihomo: ${mihomo_arch})"

    resolve_mihomo_version

    local file_name=""
    if [ "${mihomo_arch}" = "amd64" ]; then
        if grep -q "avx2" /proc/cpuinfo; then
            file_name="mihomo-linux-${mihomo_arch}-v3-${MIHOMO_VERSION}.gz"
        elif grep -q "avx" /proc/cpuinfo; then
            file_name="mihomo-linux-${mihomo_arch}-v2-${MIHOMO_VERSION}.gz"
        else
            file_name="mihomo-linux-${mihomo_arch}-v1-${MIHOMO_VERSION}.gz"
        fi
    else
        file_name="mihomo-linux-${mihomo_arch}-${MIHOMO_VERSION}.gz"
    fi

    local download_url=$(echo "${RELEASE_INFO}" | grep "browser_download_url" | grep -F "${file_name}" | head -n 1 \
        | sed -E 's/.*"browser_download_url"[[:space:]]*:[[:space:]]*"([^"]+)".*/\1/')
    if [ -z "${download_url}" ]; then
        error_exit "在 ${MIHOMO_VERSION} 的发布资源中找不到 ${file_name}，不降级到其他版本"
    fi
    log "下载链接: ${download_url}"

    # 下载 / 解压 / 自检全部在临时目录完成，通过后才落位，避免破坏已装二进制
    TMP_DIR=$(mktemp -d /tmp/mihomo-install.XXXXXX)
    if ! fetch_with_retry "mihomo 二进制下载" "${download_url}" "${TMP_DIR}/mihomo.gz"; then
        error_exit "下载 mihomo 失败（重试 ${RETRY_COUNT} 次后仍失败）"
    fi
    if ! gunzip -c "${TMP_DIR}/mihomo.gz" > "${TMP_DIR}/mihomo"; then
        error_exit "解压 mihomo 失败，下载文件可能不完整"
    fi
    chmod +x "${TMP_DIR}/mihomo"

    # 产物自检：能执行，且版本与请求一致
    if ! "${TMP_DIR}/mihomo" -v > "${TMP_DIR}/version.txt" 2>&1; then
        error_exit "下载的 mihomo 无法执行（架构 ${arch}/${mihomo_arch} 是否匹配？）"
    fi
    local installed_version=$(head -n 1 "${TMP_DIR}/version.txt")
    case "${installed_version}" in
        *"${MIHOMO_VERSION#v}"*) ;;
        *) error_exit "下载的二进制版本 (${installed_version}) 与请求版本 (${MIHOMO_VERSION}) 不一致" ;;
    esac

    mv "${TMP_DIR}/mihomo" "${MIHOMO_BIN_PATH}"
    log "mihomo安装成功: ${installed_version}"
}

install_mihomo_service() {
    log "安装mihomo服务..."
    require_asset "${ASSETS_DIR}/mihomo-service.template"
    cp "${ASSETS_DIR}/mihomo-service.template" "${MIHOMO_SERVICE}"
    chmod +x "${MIHOMO_SERVICE}"
    log "mihomo服务安装完成"

    # 确保配置文件存在；已存在的用户配置不覆盖
    if [ ! -f "${MIHOMO_CONFIG_DIR}/config.yaml" ]; then
        require_asset "${ASSETS_DIR}/config.yaml.template"
        log "配置文件不存在，正在添加..."
        mkdir -p "${MIHOMO_CONFIG_DIR}"
        cp "${ASSETS_DIR}/config.yaml.template" "${MIHOMO_CONFIG_DIR}/config.yaml"
        log "mihomo配置文件添加完成"
    else
        log "配置文件已存在，保留不覆盖: ${MIHOMO_CONFIG_DIR}/config.yaml"
    fi
}

create_logrotate_config() {
    log "创建日志轮转配置..."
    require_asset "${ASSETS_DIR}/logrotate.conf.template"
    cp "${ASSETS_DIR}/logrotate.conf.template" "${LOGROTATE_CONFIG}"
    log "日志轮转配置文件复制完成"
}

# 部署后自检：确认所有产物都按预期文件名落位。曾踩过「cp 源 目录/」让目标
# 继承 .template 后缀，产物名不对却仍报成功；这里逐个核对，缺任一即退出。
verify_deployed_files() {
    log "自检部署产物..."
    for f in \
        /etc/nftables.nft \
        "${SYSCTL_CONFIG}" \
        /etc/network/if-up.d/network-optimization \
        /etc/periodic/15min/update-ipv6-set \
        "${MIHOMO_SERVICE}" \
        "${LOGROTATE_CONFIG}" \
        "${MIHOMO_CONFIG_DIR}/config.yaml" \
        "${MIHOMO_BIN_PATH}" \
        "${LL_BIN}"; do
        [ -f "$f" ] || error_exit "部署产物缺失: $f（检查模板复制的目标文件名是否带了 .template）"
    done
    log "部署产物自检通过"
}

# ============================================================================
# 服务管理函数
# ============================================================================

configure_services() {
    log "配置服务启动项..."
    for service in ${SERVICES_BOOT}; do
        rc-update add "${service}" boot
    done
    for service in ${SERVICES_DEFAULT}; do
        rc-update add "${service}" default
    done
}

start_services() {
    log "启动服务..."
    rc-service nftables restart
    rc-service sshd restart
    rc-service qemu-guest-agent start || log "警告: qemu-guest-agent 启动失败（非关键，继续）"
    rc-service mihomo start

    sleep 2
    if rc-service mihomo status | grep -q "started"; then
        log "mihomo服务启动成功"
    else
        error_exit "mihomo服务启动失败，请检查 ${MIHOMO_CONFIG_DIR}/config.yaml 与 /var/log/mihomo/mihomo.log"
    fi
}

# ============================================================================
# 主函数
# ============================================================================

main() {
    # POSIX sh 没有 ERR trap（busybox ash / dash 均不支持），改用 EXIT trap 统一清理与报错
    trap 'rc=$?; cleanup; if [ "${rc}" -ne 0 ]; then log "脚本执行出错，退出码: ${rc}"; fi' EXIT

    # 横幅要用到实际版本号，故先做 root 与 Alpine 版本检测
    check_root
    check_alpine_version

    log "=========================================="
    log "Alpine ${ALPINE_VERSION} 旁路网关 + mihomo 安装脚本"
    log "脚本版本: ${SCRIPT_VERSION}"
    log "=========================================="

    # 系统检测
    check_kernel_version "安装前"
    detect_network_interface

    # 系统初始化
    configure_apk_repos
    update_system
    install_ll_command
    set_timezone
    load_kernel_modules

    # 网络配置
    configure_nftables
    configure_sysctl
    install_network_optimization_script

    # mihomo 安装
    download_mihomo
    install_mihomo_service
    create_logrotate_config

    # 确认所有模板都落到正确的目标文件名，再去启动服务
    verify_deployed_files

    # 服务配置
    configure_services
    start_services

    # 完成信息
    log "=========================================="
    log "安装完成！"
    log "Alpine 版本: ${ALPINE_VERSION}"
    log "mihomo 版本: ${MIHOMO_VERSION}"
    log "配置文件: ${MIHOMO_CONFIG_DIR}/config.yaml"
    log "=========================================="
    log "管理命令:"
    log "  启动: rc-service mihomo start"
    log "  停止: rc-service mihomo stop"
    log "  重启: rc-service mihomo restart"
    log "  状态: rc-service mihomo status"
    log "=========================================="

    exit 0
}

# 执行主函数
main "$@"
