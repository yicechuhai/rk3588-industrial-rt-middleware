#!/bin/bash
# =============================================================================
# RK3588 PREEMPT_RT 内核补丁自动化脚本
# 自动检测BSP内核版本 → 下载源码 → 下载RT补丁 → 打补丁 → 编译 → 安装
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORK_DIR="${WORK_DIR:-/tmp/rk3588-rt-build}"
LOG_FILE="${WORK_DIR}/build.log"

# 颜色输出
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

log_info()  { echo -e "${GREEN}[INFO]${NC}  $(date '+%H:%M:%S') $*" | tee -a "$LOG_FILE"; }
log_warn()  { echo -e "${YELLOW}[WARN]${NC}  $(date '+%H:%M:%S') $*" | tee -a "$LOG_FILE"; }
log_error() { echo -e "${RED}[ERROR]${NC} $(date '+%H:%M:%S') $*" | tee -a "$LOG_FILE"; }
log_step()  { echo -e "${BLUE}[STEP]${NC}  $(date '+%H:%M:%S') $*" | tee -a "$LOG_FILE"; }

# =============================================================================
# 清理和退出处理
# =============================================================================
cleanup() {
    if [ $? -ne 0 ] && [ "${KEEP_WORKDIR:-0}" != "1" ]; then
        log_error "构建失败！工作目录保留在: $WORK_DIR"
        log_error "查看日志: cat $LOG_FILE"
    fi
}
trap cleanup EXIT

# =============================================================================
# 使用说明
# =============================================================================
usage() {
    cat << EOF
RK3588 PREEMPT_RT 内核补丁自动化工具 v1.0

Usage: $0 [OPTIONS]

选项:
  -v, --version VER     指定内核版本 (默认: 自动检测)
                        格式: 6.1.75 或 6.1.75-rt23
  -b, --bsp-branch BR    Rockchip BSP 分支 (默认: linux-6.1.y)
  -j, --jobs N           编译并行数 (默认: \$(nproc))
  -a, --arch ARCH        目标架构 (默认: arm64)
  -c, --cross CC         交叉编译器前缀 (默认: aarch64-linux-gnu-)
  -o, --output DIR       内核安装输出目录 (默认: /boot)
  --rt-version VER       指定 RT 补丁版本 (默认: 自动匹配)
  --dry-run              干运行，只检查不执行
  --keep-workdir         构建失败后保留工作目录
  --no-build             只下载和打补丁，不编译
  -h, --help             显示此帮助

示例:
  $0                                          # 全自动检测并构建
  $0 -v 6.1.75 --dry-run                      # 检查但不构建
  $0 -v 6.1.75 -j 4 --no-build                # 只打补丁不编译
  $0 -v 6.1.75 -c aarch64-linux-gnu-          # 交叉编译

支持的 BSP 内核源:
  - Rockchip 官方: https://github.com/rockchip-linux/kernel
  - Radxa:         https://github.com/radxa/kernel
  - FriendlyElec:  https://github.com/friendlyarm/kernel-rockchip

RT 补丁源: https://cdn.kernel.org/pub/linux/kernel/projects/rt/
EOF
    exit 0
}

# =============================================================================
# 参数解析
# =============================================================================
KERNEL_VERSION=""
BSP_BRANCH="linux-6.1.y"
BUILD_JOBS=$(nproc 2>/dev/null || echo 4)
TARGET_ARCH="arm64"
CROSS_COMPILE="aarch64-linux-gnu-"
OUTPUT_DIR="/boot"
RT_VERSION=""
DRY_RUN=0
KEEP_WORKDIR=0
NO_BUILD=0
BSP_SOURCE="rockchip"

while [[ $# -gt 0 ]]; do
    case "$1" in
        -v|--version)      KERNEL_VERSION="$2"; shift 2 ;;
        -b|--bsp-branch)   BSP_BRANCH="$2"; shift 2 ;;
        -j|--jobs)         BUILD_JOBS="$2"; shift 2 ;;
        -a|--arch)         TARGET_ARCH="$2"; shift 2 ;;
        -c|--cross)        CROSS_COMPILE="$2"; shift 2 ;;
        -o|--output)       OUTPUT_DIR="$2"; shift 2 ;;
        --rt-version)      RT_VERSION="$2"; shift 2 ;;
        --bsp-source)      BSP_SOURCE="$2"; shift 2 ;;
        --dry-run)         DRY_RUN=1; shift ;;
        --keep-workdir)    KEEP_WORKDIR=1; shift ;;
        --no-build)        NO_BUILD=1; shift ;;
        -h|--help)         usage ;;
        *)                 log_error "未知选项: $1"; usage ;;
    esac
done

# =============================================================================
# 依赖检查
# =============================================================================
check_dependencies() {
    log_step "检查构建依赖..."

    local missing=()
    local deps=(
        "git:git"
        "wget:wget"
        "make:build-essential"
        "gcc:build-essential"
        "bc:bc"
        "bison:bison"
        "flex:flex"
        "libssl-dev:libssl-dev"
        "libncurses-dev:libncurses-dev"
        "libelf-dev:libelf-dev"
        "xz:xz-utils"
    )

    for dep in "${deps[@]}"; do
        local cmd="${dep%%:*}"
        local pkg="${dep##*:}"
        if ! command -v "$cmd" &>/dev/null; then
            missing+=("$pkg")
        fi
    done

    if [ ${#missing[@]} -gt 0 ]; then
        log_warn "缺少以下依赖: ${missing[*]}"
        if [ "$DRY_RUN" -eq 0 ]; then
            echo -n "是否自动安装? [Y/n] "
            read -r answer
            if [[ "$answer" =~ ^[Nn] ]]; then
                log_error "请手动安装依赖后重试"
                exit 1
            fi
            sudo apt-get update -qq
            sudo apt-get install -y "${missing[@]}" || {
                log_error "依赖安装失败"
                exit 1
            }
        fi
    fi
    log_info "依赖检查完成"
}

# =============================================================================
# 检测当前 BSP 内核版本
# =============================================================================
detect_kernel_version() {
    log_step "检测 BSP 内核版本..."

    if [ -n "$KERNEL_VERSION" ]; then
        # 去掉 -rtXX 后缀获取基础版本
        KERNEL_BASE="${KERNEL_VERSION%%-rt*}"
        log_info "使用指定版本: $KERNEL_BASE"
        return
    fi

    # 从运行中的内核检测
    local running_ver
    running_ver=$(uname -r | grep -oP '^\d+\.\d+\.\d+' || echo "")

    if [ -n "$running_ver" ]; then
        KERNEL_BASE="$running_ver"
        log_info "检测到运行内核: $KERNEL_BASE"
    else
        # 默认使用已知的 RK3588 BSP 版本
        KERNEL_BASE="6.1.75"
        log_warn "无法检测运行内核，使用默认版本: $KERNEL_BASE"
    fi

    # 验证 Rockchip BSP 分支存在
    if [ "$DRY_RUN" -eq 0 ]; then
        local branch_exists
        branch_exists=$(git ls-remote --heads "https://github.com/${BSP_SOURCE}-linux/kernel.git" \
            "$BSP_BRANCH" 2>/dev/null | wc -l)
        if [ "$branch_exists" -eq 0 ]; then
            log_warn "BSP 分支 $BSP_BRANCH 不存在，尝试 detect..."
            # 尝试自动匹配 BSP 分支
            local major_minor="${KERNEL_BASE%.*}"
            BSP_BRANCH="linux-${major_minor}.y"
            log_info "自动匹配分支: $BSP_BRANCH"
        fi
    fi
}

# =============================================================================
# 查找匹配的 RT 补丁
# =============================================================================
find_rt_patch() {
    log_step "查找匹配的 RT 补丁..."

    if [ -n "$RT_VERSION" ]; then
        RT_PATCH_VERSION="$RT_VERSION"
        RT_PATCH_URL="https://cdn.kernel.org/pub/linux/kernel/projects/rt/${KERNEL_BASE%.*}/patch-${RT_PATCH_VERSION}.patch.xz"
        log_info "使用指定 RT 版本: $RT_PATCH_VERSION"
        return
    fi

    # 从 kernel.org CDN 获取可用的 RT 补丁列表
    local rt_dir="https://cdn.kernel.org/pub/linux/kernel/projects/rt/${KERNEL_BASE%.*}"
    local rt_list
    rt_list=$(wget -qO- "$rt_dir/sha256sums.asc" 2>/dev/null | grep "patch-${KERNEL_BASE}" || echo "")

    if [ -z "$rt_list" ]; then
        # 尝试从索引页获取
        rt_list=$(wget -qO- "$rt_dir/" 2>/dev/null | grep -oP "patch-${KERNEL_BASE}-rt\d+\.patch\.xz" | sort -V | tail -1 || echo "")
    fi

    if [ -z "$rt_list" ]; then
        log_error "未找到匹配内核版本 ${KERNEL_BASE} 的 RT 补丁"
        log_error "请手动指定: $0 -v ${KERNEL_BASE} --rt-version ${KERNEL_BASE}-rtXX"
        log_error "查看可用补丁: https://cdn.kernel.org/pub/linux/kernel/projects/rt/${KERNEL_BASE%.*}/"
        exit 1
    fi

    # 提取最新补丁版本
    RT_PATCH_FILE=$(echo "$rt_list" | grep -oP "patch-${KERNEL_BASE}-rt\d+\.patch\.xz" | sort -V | tail -1)
    RT_PATCH_VERSION="${RT_PATCH_FILE#patch-}"
    RT_PATCH_VERSION="${RT_PATCH_VERSION%.patch.xz}"
    RT_PATCH_URL="${rt_dir}/${RT_PATCH_FILE}"
    log_info "匹配 RT 补丁: $RT_PATCH_VERSION"
}

# =============================================================================
# 下载内核源码
# =============================================================================
download_kernel_source() {
    log_step "下载 RK3588 BSP 内核源码..."

    local bsp_url="https://github.com/${BSP_SOURCE}-linux/kernel.git"
    local kernel_dir="${WORK_DIR}/rk3588-kernel"

    if [ -d "$kernel_dir/.git" ]; then
        log_info "内核源码已存在，更新中..."
        cd "$kernel_dir"
        git fetch --depth=1 origin "$BSP_BRANCH" 2>&1 | tee -a "$LOG_FILE" || {
            log_error "Git fetch 失败"
            exit 1
        }
        git checkout "$BSP_BRANCH" 2>&1 | tee -a "$LOG_FILE"
        git reset --hard "origin/$BSP_BRANCH" 2>&1 | tee -a "$LOG_FILE"
    else
        log_info "克隆 BSP 内核 (depth=1, 约需 1-3GB 空间)..."
        git clone --depth=1 --branch="$BSP_BRANCH" "$bsp_url" "$kernel_dir" 2>&1 | tee -a "$LOG_FILE" || {
            log_error "内核源码克隆失败"
            log_error "请检查网络连接和磁盘空间"
            exit 1
        }
    fi

    cd "$kernel_dir"
    log_info "内核源码就绪: $(pwd)"
    log_info "HEAD: $(git log --oneline -1)"
}

# =============================================================================
# 下载 RT 补丁
# =============================================================================
download_rt_patch() {
    log_step "下载 PREEMPT_RT 补丁..."

    local patch_file="${WORK_DIR}/patch-${RT_PATCH_VERSION}.patch.xz"

    if [ -f "$patch_file" ]; then
        log_info "RT 补丁已存在: $patch_file"
    else
        log_info "下载: $RT_PATCH_URL"
        wget -q --show-progress "$RT_PATCH_URL" -O "$patch_file" || {
            log_error "RT 补丁下载失败"
            exit 1
        }
    fi

    # 验证补丁文件
    if ! xz -t "$patch_file" 2>/dev/null; then
        log_error "RT 补丁文件损坏"
        rm -f "$patch_file"
        exit 1
    fi

    RT_PATCH_FILE="$patch_file"
    log_info "RT 补丁就绪: $RT_PATCH_FILE ($(du -h "$RT_PATCH_FILE" | cut -f1))"
}

# =============================================================================
# 应用 RT 补丁
# =============================================================================
apply_rt_patch() {
    log_step "应用 PREEMPT_RT 补丁..."

    cd "${WORK_DIR}/rk3588-kernel"

    # 检查是否已打过补丁
    if grep -q "CONFIG_PREEMPT_RT=y" .config 2>/dev/null; then
        log_warn "检测到内核可能已打过 RT 补丁，跳过补丁应用"
        return
    fi

    log_info "解压并应用补丁: $RT_PATCH_FILE"
    xzcat "$RT_PATCH_FILE" | patch -p1 --dry-run 2>&1 | tee -a "$LOG_FILE" || {
        log_error "补丁干运行失败！可能存在冲突"
        log_error "请检查内核版本是否匹配: 源码=$KERNEL_BASE, 补丁=$RT_PATCH_VERSION"
        exit 1
    }

    if [ "$DRY_RUN" -eq 1 ]; then
        log_info "[DRY-RUN] 补丁验证通过"
        return
    fi

    xzcat "$RT_PATCH_FILE" | patch -p1 2>&1 | tee -a "$LOG_FILE" || {
        log_error "补丁应用失败！"
        log_error "查看失败的 .rej 文件"
        find . -name "*.rej" -exec echo "  冲突文件: {}" \;
        exit 1
    }

    log_info "PREEMPT_RT 补丁应用成功"
}

# =============================================================================
# 配置内核
# =============================================================================
configure_kernel() {
    log_step "配置 PREEMPT_RT 内核..."

    if [ "$DRY_RUN" -eq 1 ]; then
        log_info "[DRY-RUN] 跳过内核配置"
        return
    fi

    cd "${WORK_DIR}/rk3588-kernel"

    export ARCH="$TARGET_ARCH"
    export CROSS_COMPILE="$CROSS_COMPILE"

    # 加载 Rockchip 默认配置
    if [ -f "arch/${TARGET_ARCH}/configs/rockchip_linux_defconfig" ]; then
        make rockchip_linux_defconfig 2>&1 | tee -a "$LOG_FILE"
    elif [ -f "arch/${TARGET_ARCH}/configs/defconfig" ]; then
        make defconfig 2>&1 | tee -a "$LOG_FILE"
    else
        log_warn "未找到 Rockchip 默认配置，使用 defconfig"
        make defconfig 2>&1 | tee -a "$LOG_FILE"
    fi

    # 启用 PREEMPT_RT
    ./scripts/config -e CONFIG_PREEMPT_RT \
                     -d CONFIG_PREEMPT_VOLUNTARY \
                     -d CONFIG_PREEMPT_NONE 2>/dev/null || true

    # 启用高精度定时器
    ./scripts/config -e CONFIG_HZ_1000 \
                     -e CONFIG_HIGHRES_TIMERS \
                     -e CONFIG_HZ_PERIODIC 2>/dev/null || true

    # 启用 NO_HZ_FULL 和 RCU_NOCB
    ./scripts/config -e CONFIG_NO_HZ_FULL \
                     -e CONFIG_RCU_NOCB_CPU \
                     -e CONFIG_RCU_NOCB_CPU_ALL 2>/dev/null || true

    # 启用 CPU 隔离
    ./scripts/config -e CONFIG_CPU_ISOLATION 2>/dev/null || true

    # RK3588 特定优化
    ./scripts/config -e CONFIG_ARM64_VA_BITS_48 \
                     -e CONFIG_ROCKCHIP_IPA \
                     -e CONFIG_ROCKCHIP_OPP 2>/dev/null || true

    # 禁用调试选项减少延迟
    ./scripts/config -d CONFIG_DEBUG_PREEMPT \
                     -d CONFIG_DEBUG_SPINLOCK \
                     -d CONFIG_DEBUG_MUTEXES \
                     -d CONFIG_DEBUG_LOCK_ALLOC \
                     -d CONFIG_PROVE_LOCKING \
                     -d CONFIG_LOCK_STAT \
                     -d CONFIG_DEBUG_OBJECTS \
                     -d CONFIG_DEBUG_OBJECTS_FREE \
                     -d CONFIG_DEBUG_OBJECTS_TIMERS \
                     -d CONFIG_DEBUG_KOBJECT \
                     -d CONFIG_DEBUG_BUGVERBOSE \
                     -d CONFIG_DEBUG_INFO \
                     -d CONFIG_DEBUG_INFO_DWARF5 \
                     -d CONFIG_FTRACE \
                     -d CONFIG_KGDB \
                     -d CONFIG_KGDB_SERIAL_CONSOLE \
                     -d CONFIG_SLUB_DEBUG 2>/dev/null || true

    # 内核抢占模型验证
    local preempt_model
    preempt_model=$(grep CONFIG_PREEMPT_RT .config 2>/dev/null || echo "NOT_FOUND")

    if [ "$preempt_model" != "CONFIG_PREEMPT_RT=y" ]; then
        log_error "PREEMPT_RT 未正确配置！"
        log_error "当前配置: $preempt_model"
        exit 1
    fi

    # 解析依赖
    make olddefconfig 2>&1 | tee -a "$LOG_FILE"

    log_info "内核配置完成"
    log_info "抢占模型: CONFIG_PREEMPT_RT=y"
}

# =============================================================================
# 编译内核
# =============================================================================
build_kernel() {
    log_step "编译 PREEMPT_RT 内核 (jobs=$BUILD_JOBS)..."

    if [ "$DRY_RUN" -eq 1 ] || [ "$NO_BUILD" -eq 1 ]; then
        log_info "跳过编译步骤"
        return
    fi

    cd "${WORK_DIR}/rk3588-kernel"
    export ARCH="$TARGET_ARCH"
    export CROSS_COMPILE="$CROSS_COMPILE"

    local start_time
    start_time=$(date +%s)

    log_info "编译内核镜像..."
    make -j"$BUILD_JOBS" Image 2>&1 | tee -a "$LOG_FILE" || {
        log_error "内核编译失败！"
        exit 1
    }

    log_info "编译内核模块..."
    make -j"$BUILD_JOBS" modules 2>&1 | tee -a "$LOG_FILE" || {
        log_error "模块编译失败！"
        exit 1
    }

    log_info "编译设备树..."
    make -j"$BUILD_JOBS" dtbs 2>&1 | tee -a "$LOG_FILE" || {
        log_warn "设备树编译有警告 (可能不影响使用)"
    }

    local end_time
    end_time=$(date +%s)
    local elapsed=$((end_time - start_time))
    log_info "编译完成，耗时: ${elapsed}s ($((elapsed / 60))m $((elapsed % 60))s)"
}

# =============================================================================
# 安装内核
# =============================================================================
install_kernel() {
    log_step "安装 PREEMPT_RT 内核..."

    if [ "$DRY_RUN" -eq 1 ] || [ "$NO_BUILD" -eq 1 ]; then
        log_info "跳过安装步骤"
        return
    fi

    cd "${WORK_DIR}/rk3588-kernel"
    export ARCH="$TARGET_ARCH"
    export CROSS_COMPILE="$CROSS_COMPILE"

    local rt_suffix="-rt"
    local kernel_release
    kernel_release=$(make kernelrelease 2>/dev/null || echo "${KERNEL_BASE}${rt_suffix}")

    # 安装模块
    log_info "安装内核模块..."
    sudo make modules_install INSTALL_MOD_PATH=/ 2>&1 | tee -a "$LOG_FILE" || {
        log_error "模块安装失败！"
        exit 1
    }

    # 安装内核镜像
    log_info "安装内核镜像..."
    sudo cp "arch/${TARGET_ARCH}/boot/Image" "${OUTPUT_DIR}/Image${rt_suffix}" || {
        log_error "内核镜像复制失败！"
        exit 1
    }

    # 安装设备树
    log_info "安装设备树..."
    if ls "arch/${TARGET_ARCH}/boot/dts/rockchip/rk3588"*.dtb 1>/dev/null 2>&1; then
        sudo cp "arch/${TARGET_ARCH}/boot/dts/rockchip/rk3588"*.dtb "${OUTPUT_DIR}/" 2>/dev/null || true
    fi

    # 更新 initramfs (如果目标 == 本机)
    if [ "$TARGET_ARCH" = "arm64" ] && [ "$(uname -m)" = "aarch64" ] && command -v update-initramfs &>/dev/null; then
        log_info "更新 initramfs..."
        sudo update-initramfs -c -k "${kernel_release}" 2>&1 | tee -a "$LOG_FILE" || {
            log_warn "initramfs 更新失败，可能需要手动处理"
        }
    fi

    log_info "内核安装完成"
    log_info "内核镜像: ${OUTPUT_DIR}/Image${rt_suffix}"
    log_info "模块目录: /lib/modules/${kernel_release}/"
}

# =============================================================================
# 打印构建摘要
# =============================================================================
print_summary() {
    echo ""
    echo "============================================"
    echo "  RK3588 PREEMPT_RT 内核构建完成"
    echo "============================================"
    echo ""
    echo "  内核版本:    ${KERNEL_BASE} (PREEMPT_RT)"
    echo "  RT 补丁:     ${RT_PATCH_VERSION}"
    echo "  架构:        ${TARGET_ARCH}"
    echo "  工作目录:    ${WORK_DIR}"
    echo "  构建日志:    ${LOG_FILE}"
    echo ""
    echo "下一步操作:"
    echo "  1. 配置启动参数:"
    echo "     sudo bash setup_realtime.sh"
    echo ""
    echo "  2. 重启到 RT 内核:"
    echo "     sudo reboot"
    echo ""
    echo "  3. 验证 RT 内核:"
    echo "     uname -r                    # 应显示 -rt 后缀"
    echo "     cat /sys/kernel/realtime    # 应返回 1"
    echo ""
    echo "  4. 运行延迟测试:"
    echo "     sudo cyclictest -t4 -p99 -i200 -D 60s"
    echo "     # 或使用内置工具:"
    echo "     sudo python3 src/monitor/jitter_monitor.py -d 60"
    echo ""
    echo "============================================"
}

# =============================================================================
# 主流程
# =============================================================================
main() {
    echo "============================================"
    echo "  RK3588 PREEMPT_RT 内核补丁自动化"
    echo "============================================"
    echo ""

    # 创建工作目录
    mkdir -p "$WORK_DIR"

    # 初始化日志
    echo "=== RK3588 PREEMPT_RT Build Log - $(date) ===" > "$LOG_FILE"

    # 执行构建步骤
    check_dependencies
    detect_kernel_version
    find_rt_patch

    log_info "构建配置确认:"
    log_info "  内核版本:    $KERNEL_BASE"
    log_info "  BSP 分支:    $BSP_BRANCH"
    log_info "  RT 补丁:     $RT_PATCH_VERSION"
    log_info "  架构:        $TARGET_ARCH"
    log_info "  编译并行:    $BUILD_JOBS"
    log_info "  工作目录:    $WORK_DIR"
    echo ""

    if [ "$DRY_RUN" -eq 1 ]; then
        log_info ">>> 干运行模式，仅验证不执行 <<<"
    fi

    download_kernel_source
    download_rt_patch
    apply_rt_patch
    configure_kernel
    build_kernel
    install_kernel
    print_summary
}

main "$@"
