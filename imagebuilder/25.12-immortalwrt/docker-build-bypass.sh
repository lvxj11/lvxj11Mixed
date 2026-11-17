#!/bin/bash
set -e

# 镜像格式档位（详见 imagebuilder/README.md 的「镜像格式档位」一节）
#   默认 minimal：仅 ext4 EFI 的 qcow2（未压缩，可直接导入 PVE），并清理本次附带产出的 raw
#   -c / --common：ext4 常用格式（qcow2 + raw、EFI + BIOS，均 gzip 压缩），不清理产物
#   -a / --all：上游全部格式（含 squashfs / iso / vdi / vmdk / vhdx / targz），不清理产物
IMAGE_FORMATS=minimal
set_format() {
    if [ "$IMAGE_FORMATS" != "minimal" ] && [ "$IMAGE_FORMATS" != "$1" ]; then
        echo "错误: -c/--common 与 -a/--all 不能同时使用" >&2
        exit 1
    fi
    IMAGE_FORMATS="$1"
}
for arg in "$@"; do
    case "$arg" in
        -c|--common) set_format common ;;
        -a|--all)    set_format all ;;
        -h|--help)
            echo "用法: $0 [-c|--common] [-a|--all]"
            echo "  无参数    默认 minimal：仅 ext4 EFI qcow2（未压缩，可直接导入 PVE）"
            echo "  -c|--common  常用格式：ext4 的 qcow2 + raw、EFI + BIOS，均 gzip 压缩"
            echo "  -a|--all     全部格式：上游支持的全部镜像格式"
            exit 0 ;;
        *)
            echo "错误: 未知参数 '$arg'（可用: -c/--common, -a/--all, -h/--help）" >&2
            exit 1 ;;
    esac
done
echo "镜像格式档位: $IMAGE_FORMATS"

VERSION='x86-64-openwrt-25.12'
QUERY_URL="https://hub.docker.com/v2/repositories/immortalwrt/imagebuilder/tags?name=${VERSION}&page_size=50"

# 查询最新稳定补丁版本；用 grep/sed 解析 JSON，不依赖宿主机安装 jq
# 最多尝试 3 次（首次 + 重试 2 次）。查询失败就退出，绝不回退到滚动 tag：
# 滚动 tag 会随上游移动，用它构建出的固件版本无法确定、不可复现。
LATEST_VERSION=""
for attempt in 1 2 3; do
    TAGS_JSON=$(curl -fsS --max-time 20 "$QUERY_URL" 2>/dev/null || true)
    LATEST_VERSION=$(printf '%s' "$TAGS_JSON" \
        | grep -o '"name":"[^"]*"' \
        | sed 's/^"name":"//; s/"$//' \
        | grep -E "^${VERSION}\.[0-9]{1,2}$" \
        | sort -V \
        | tail -n 1 || true)
    if [ -n "${LATEST_VERSION}" ]; then
        break
    fi
    if [ "$attempt" -lt 3 ]; then
        echo "警告: 第 ${attempt} 次查询补丁版本失败，重试..." >&2
        sleep 2
    fi
done

if [ -z "${LATEST_VERSION}" ]; then
    echo "" >&2
    echo "============================================================" >&2
    echo " 错误: 无法确定镜像补丁版本，构建已中止（绝不降级）" >&2
    echo " Docker Hub API 已重试 2 次仍失败。版本不确定 = 固件不可复现，" >&2
    echo " 因此不回退到滚动 tag ${VERSION}，也不猜测任何固定版本。" >&2
    echo " 请检查网络后重新执行本脚本，或手动把 VERSION 锁定为具体版本。" >&2
    echo "============================================================" >&2
    exit 1
fi

echo "找到最新版本: ${LATEST_VERSION}"
VERSION="${LATEST_VERSION}"
echo "使用版本: ${VERSION}"

mkdir -p output
chmod -R 777 .

# 手动执行（终端）保留 -it，可交互、可 Ctrl+C；
# 非交互环境（CI / 管道 / 无 TTY）去掉 -t，否则 docker 报 "the input device is not a TTY"
TTY_ARGS=()
if [ -t 0 ]; then
    TTY_ARGS=(-it)
fi

docker run --rm "${TTY_ARGS[@]}" --name imagebuilder \
    -e "IMAGE_FORMATS=${IMAGE_FORMATS}" \
    -v ./output:/output \
    -v ./builder-bypass/files:/builder/files \
    -v ./builder-bypass/build.sh:/builder/build.sh \
    immortalwrt/imagebuilder:${VERSION} \
    /bin/bash -c "/builder/build.sh"

#     /bin/bash -c "/builder/build.sh"
#     /bin/bash -c "sleep infinity"
