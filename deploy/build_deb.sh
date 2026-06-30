#!/bin/bash
# =============================================================================
# Build RK3588 RT Middleware .deb package
# 支持多架构、自动依赖检测、交叉编译
# =============================================================================
set -euo pipefail

# =============================================================================
# 颜色输出
# =============================================================================
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

log_info()  { echo -e "${GREEN}[INFO]${NC}  $*"; }
log_warn()  { echo -e "${YELLOW}[WARN]${NC}  $*"; }
log_error() { echo -e "${RED}[ERROR]${NC} $*"; }
log_step()  { echo -e "${BLUE}[STEP]${NC}  $*"; }

# =============================================================================
# 配置
# =============================================================================
DEB_NAME="rk3588-rt-middleware"
VERSION="${VERSION:-1.1.0}"
ARCH="${ARCH:-arm64}"
BUILD_DIR="build/deb"
PKG_DIR="${BUILD_DIR}/${DEB_NAME}_${VERSION}_${ARCH}"

# 获取仓库根目录
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

# =============================================================================
# 使用说明
# =============================================================================
usage() {
    cat << EOF
RK3588 RT Middleware .deb 打包工具 v${VERSION}

Usage: $0 [OPTIONS]

选项:
  -v, --version VER     设置版本号 (默认: $VERSION)
  -a, --arch ARCH       目标架构: arm64, amd64, armhf, all (默认: $ARCH)
  --dry-run             仅预览打包内容
  --no-sign             跳过包签名
  -h, --help            显示此帮助

支持架构:
  arm64  - RK3588 / ARM64 SBC (树莓派4/5, Rock 5, Orange Pi 5 等)
  amd64  - x86_64 开发/测试环境
  armhf  - ARM32 SBC (树莓派2/3, BeagleBone 等)
  all    - 架构无关 (纯脚本)

示例:
  $0                              # 默认: arm64 打包
  $0 -a arm64 -v 1.2.0            # 指定版本
  $0 -a all                       # 跨架构打包
  VERSION=1.2.0 ARCH=amd64 $0     # 环境变量方式
EOF
    exit 0
}

# =============================================================================
# 参数解析
# =============================================================================
DRY_RUN=0
NO_SIGN=0

while [[ $# -gt 0 ]]; do
    case "$1" in
        -v|--version)  VERSION="$2"; shift 2 ;;
        -a|--arch)     ARCH="$2"; shift 2 ;;
        --dry-run)     DRY_RUN=1; shift ;;
        --no-sign)     NO_SIGN=1; shift ;;
        -h|--help)     usage ;;
        *)             log_error "未知选项: $1"; usage ;;
    esac
done

# 验证架构
case "$ARCH" in
    arm64|amd64|armhf|all) ;;
    *) log_error "不支持的架构: $ARCH (支持: arm64, amd64, armhf, all)"; exit 1 ;;
esac

# =============================================================================
# 自动依赖检测
# =============================================================================
detect_python_deps() {
    log_step "检测 Python 依赖..."

    local deps=("python3")

    # 检测 argparse (Python 3.2+ 内置)
    deps+=("python3")

    # 检测 numpy
    if python3 -c "import numpy" 2>/dev/null; then
        local numpy_ver
        numpy_ver=$(python3 -c "import numpy; print(numpy.__version__)" 2>/dev/null || echo "1.24")
        deps+=("python3-numpy")
        log_info "  检测到 numpy ${numpy_ver}"
    else
        # 默认添加 numpy 依赖
        deps+=("python3-numpy")
    fi

    # 可选依赖检测
    local opt_deps=()

    if python3 -c "import yaml" 2>/dev/null; then
        opt_deps+=("python3-yaml")
        log_info "  检测到 PyYAML"
    fi

    # 系统依赖
    local sys_deps=(
        "util-linux"
        "numactl"
    )

    # 检查 util-linux 版本 (需要 >=2.34 以支持 taskset 等)
    if command -v taskset &>/dev/null; then
        local uver
        uver=$(taskset --version 2>&1 | grep -oP '\d+\.\d+' | head -1 || echo "2.34")
        log_info "  util-linux 版本: $uver"
        # util-linux 版本号动态处理
        if awk "BEGIN{exit !($uver >= 2.34)}"; then
            sys_deps=("util-linux (>= 2.34)")
        else
            sys_deps=("util-linux (>= $uver)")
        fi
    fi

    PYTHON_DEPS="${deps[*]}"
    OPT_DEPS="${opt_deps[*]}"
    SYS_DEPS="${sys_deps[*]}"
}

detect_arch_specific_deps() {
    log_step "检测架构特定依赖..."

    case "$ARCH" in
        arm64)
            ARCH_DEPS="linux-image-rt-arm64"
            ARCH_RECOMMENDS="linux-image-6.1.75-rt, linux-headers-rt-arm64"
            ARCH_CONFLICTS=""
            ;;
        amd64)
            ARCH_DEPS="linux-image-rt-amd64"
            ARCH_RECOMMENDS="linux-headers-rt-amd64"
            ARCH_CONFLICTS=""
            ;;
        armhf)
            ARCH_DEPS=""
            ARCH_RECOMMENDS="linux-image-rt-armmp"
            ARCH_CONFLICTS=""
            ;;
        all)
            ARCH_DEPS=""
            ARCH_RECOMMENDS=""
            ARCH_CONFLICTS=""
            ;;
    esac
}

# =============================================================================
# 生成 DEBIAN/control
# =============================================================================
generate_control() {
    log_step "生成 DEBIAN/control..."

    local control_file="${PKG_DIR}/DEBIAN/control"

    cat > "$control_file" << EOF
Package: ${DEB_NAME}
Version: ${VERSION}
Architecture: ${ARCH}
Maintainer: RK3588 Industrial Toolkit Team <1513741889@qq.com>
Depends: ${PYTHON_DEPS}, ${SYS_DEPS}
EOF

    if [ -n "$OPT_DEPS" ]; then
        echo "Recommends: ${OPT_DEPS}, ${ARCH_RECOMMENDS}, rt-tests" >> "$control_file"
    else
        echo "Recommends: ${ARCH_RECOMMENDS}, rt-tests" >> "$control_file"
    fi

    if [ -n "$ARCH_DEPS" ]; then
        echo "Suggests: ${ARCH_DEPS}" >> "$control_file"
    fi

    if [ -n "$ARCH_CONFLICTS" ]; then
        echo "Conflicts: ${ARCH_CONFLICTS}" >> "$control_file"
    fi

    cat >> "$control_file" << 'EOF'
Section: utils
Priority: optional
Homepage: https://github.com/yicechuhai/rk3588-industrial-rt-middleware
Description: RK3588 Industrial Protocol Real-Time Middleware
 Real-time middleware for industrial control applications
 on Rockchip RK3588 SoC and compatible ARM64 platforms.
 .
 Features:
  - CPU core isolation with AMP support (big.LITTLE)
  - IRQ affinity for deterministic latency
  - PREEMPT_RT kernel build automation
  - Cyclictest-style jitter monitor with histogram analysis
  - Modbus TCP server (port 502)
  - OPC UA server (port 4840)
  - IgH EtherCAT Master auto-installer
  - Latency analysis and report generation
  - YAML register map configuration
 .
 Performance Targets:
  - PREEMPT_RT: P99 < 50us, Max < 80us
  - Xenomai:    P99 < 25us, Max < 30us
 .
 Target Platforms:
  - RK3588-based industrial controllers
  - Radxa ROCK 5, Orange Pi 5, Firefly ITX-3588J
  - Compatible ARM64 SBCs with PREEMPT_RT kernel
EOF

    log_info "DEBIAN/control 已生成"
}

# =============================================================================
# 生成 DEBIAN/postinst
# =============================================================================
generate_postinst() {
    log_step "生成 DEBIAN/postinst..."

    cat > "${PKG_DIR}/DEBIAN/postinst" << 'PEOF'
#!/bin/bash
set -e

echo "RK3588 RT Middleware v${VERSION} - Post Install"
echo "==============================================="

# 创建运行时目录
mkdir -p /opt/rk3588-rt/{bin,config,logs}
chmod 755 /opt/rk3588-rt/{bin,config,logs}

# 创建日志目录 (如果不存在)
if [ ! -d /var/log/rk3588-rt ]; then
    mkdir -p /var/log/rk3588-rt
    chmod 755 /var/log/rk3588-rt
fi

# 设置 Python 脚本能力标志 (允许 RT 优先级而无需完全 root)
for script in /opt/rk3588-rt/bin/*.py; do
    if [ -f "$script" ]; then
        setcap cap_sys_nice+ep "$script" 2>/dev/null || true
        setcap cap_ipc_lock+ep "$script" 2>/dev/null || true
    fi
done

# 启用 RT 组调度
if [ -f /proc/sys/kernel/sched_rt_runtime_us ]; then
    echo 980000 > /proc/sys/kernel/sched_rt_runtime_us 2>/dev/null || true
fi

if [ -f /proc/sys/kernel/sched_rt_period_us ]; then
    echo 1000000 > /proc/sys/kernel/sched_rt_period_us 2>/dev/null || true
fi

# 配置 sysctl 持久化
cat > /etc/sysctl.d/99-rk3588-rt.conf << 'SYSCTL'
# RK3588 Real-Time Configuration (installed by rk3588-rt-middleware)
kernel.sched_rt_runtime_us = 980000
kernel.sched_rt_period_us = 1000000
kernel.nmi_watchdog = 0
kernel.watchdog = 0
vm.stat_interval = 10
SYSCTL

sysctl -p /etc/sysctl.d/99-rk3588-rt.conf 2>/dev/null || true

# 配置 memlock 限制
cat > /etc/security/limits.d/99-rk3588-rt.conf << 'LIMITS'
# RK3588 RT Middleware: unlimited memory locking
*    -   memlock     unlimited
root -   memlock     unlimited
LIMITS

# 检测 PREEMPT_RT 内核
if [ -f /sys/kernel/realtime ] && [ "$(cat /sys/kernel/realtime)" = "1" ]; then
    echo ""
    echo "✅ PREEMPT_RT 内核已就绪"
else
    echo ""
    echo "⚠️  未检测到 PREEMPT_RT 内核"
    echo "   运行以下命令构建 RT 内核:"
    echo "   sudo rk3588-rt-build-kernel"
fi

echo ""
echo "==============================================="
echo "  安装完成！"
echo "==============================================="
echo ""
echo "  快速开始:"
echo "    sudo rk3588-rt-isolate 4-7     # 隔离 A76 核心"
echo "    sudo rk3588-rt-irq isolate 0-3 # 固定 IRQ 到 A55"
echo "    sudo rk3588-rt-jitter -d 60    # 60秒延迟测试"
echo ""
echo "  协议服务:"
echo "    sudo rk3588-rt-modbus          # Modbus TCP 服务器"
echo "    sudo rk3588-rt-opcua           # OPC UA 服务器"
echo "    sudo rk3588-rt-ethercat        # 安装 EtherCAT"
echo ""
echo "  分析工具:"
echo "    rk3588-rt-analyze <data.csv>   # 延迟分析报告"
echo ""
echo "  内核构建:"
echo "    sudo rk3588-rt-build-kernel    # 构建 PREEMPT_RT 内核"
echo ""
echo "  系统初始化:"
echo "    sudo rk3588-rt-setup           # 一键实时系统配置"
echo ""
echo "  配置文件: /etc/rk3588-rt/rt_config.yaml"
echo "==============================================="
PEOF

    chmod 755 "${PKG_DIR}/DEBIAN/postinst"
    log_info "DEBIAN/postinst 已生成"
}

# =============================================================================
# 生成 DEBIAN/prerm
# =============================================================================
generate_prerm() {
    log_step "生成 DEBIAN/prerm..."

    cat > "${PKG_DIR}/DEBIAN/prerm" << 'PREM'
#!/bin/bash
set -e
echo "Removing RK3588 RT Middleware..."

# 恢复默认 RT 设置
echo 950000 > /proc/sys/kernel/sched_rt_runtime_us 2>/dev/null || true

# 清除 CPU 隔离
echo "" > /sys/devices/system/cpu/isolated 2>/dev/null || true

# 移除 sysctl 配置
rm -f /etc/sysctl.d/99-rk3588-rt.conf

# 移除 limits 配置
rm -f /etc/security/limits.d/99-rk3588-rt.conf

# 应用 sysctl 更改
sysctl --system 2>/dev/null || true

echo "RK3588 RT Middleware 已移除"
echo "注意: 内核启动参数 (isolcpus 等) 需要手动从启动配置中移除"
PREM

    chmod 755 "${PKG_DIR}/DEBIAN/prerm"
    log_info "DEBIAN/prerm 已生成"
}

# =============================================================================
# 清理和准备
# =============================================================================
clean_build() {
    log_step "清理构建目录..."
    rm -rf "$BUILD_DIR"
    mkdir -p "${PKG_DIR}/DEBIAN"
    mkdir -p "${PKG_DIR}/opt/rk3588-rt/{bin,config,logs}"
    mkdir -p "${PKG_DIR}/usr/share/doc/${DEB_NAME}"
    mkdir -p "${PKG_DIR}/etc/${DEB_NAME}"
    mkdir -p "${PKG_DIR}/usr/bin"
    mkdir -p "${PKG_DIR}/var/log/rk3588-rt"
}

# =============================================================================
# 复制文件
# =============================================================================
copy_files() {
    log_step "复制应用文件..."

    # 复制核心脚本
    local files_to_copy=(
        "src/rt-core/cpu_isolation.sh:bin/cpu_isolation.sh"
        "src/rt-core/irq_affinity.sh:bin/irq_affinity.sh"
        "src/rt-core/apply_rt_patch.sh:bin/apply_rt_patch.sh"
        "src/rt-core/setup_realtime.sh:bin/setup_realtime.sh"
        "src/monitor/jitter_monitor.py:bin/jitter_monitor.py"
        "src/monitor/latency_analyzer.py:bin/latency_analyzer.py"
        "src/protocols/modbus_tcp_server.py:bin/modbus_tcp_server.py"
        "src/protocols/opcua_server.py:bin/opcua_server.py"
        "src/protocols/yaml_to_register_map.py:bin/yaml_to_register_map.py"
        "src/protocols/install_ethercat.sh:bin/install_ethercat.sh"
    )

    for entry in "${files_to_copy[@]}"; do
        local src="${entry%%:*}"
        local dst="${entry##*:}"

        if [ -f "$src" ]; then
            cp "$src" "${PKG_DIR}/opt/rk3588-rt/${dst}"
            log_info "  ${src} → bin/${dst}"
        else
            log_warn "  跳过 (不存在): ${src}"
        fi
    done

    # 设置可执行权限
    chmod +x "${PKG_DIR}/opt/rk3588-rt/bin/"*

    # 复制文档
    if [ -f "README.md" ]; then
        cp README.md "${PKG_DIR}/usr/share/doc/${DEB_NAME}/"
    fi
    if [ -f "CHANGELOG.md" ]; then
        cp CHANGELOG.md "${PKG_DIR}/usr/share/doc/${DEB_NAME}/"
    fi

    # 复制默认配置
    if [ -f "config/default_config.yaml" ]; then
        cp config/default_config.yaml "${PKG_DIR}/etc/${DEB_NAME}/rt_config.yaml"
    else
        # 生成内联默认配置
        cat > "${PKG_DIR}/etc/${DEB_NAME}/rt_config.yaml" << 'CONF'
# RK3588 RT Middleware Default Configuration
# 安装后编辑: /etc/rk3588-rt/rt_config.yaml

cpu:
  linux_cores: "0-3"         # A55 - Linux 管理核心
  rt_cores: "4-7"            # A76 - 实时任务核心
  governor: performance       # CPU 调频策略

scheduler:
  rt_runtime_us: 980000       # RT 任务 CPU 时间限制
  rt_period_us: 1000000       # RT 调度周期
  default_priority: 80        # 默认 RT 优先级

monitor:
  interval_us: 500            # 采样间隔
  duration_s: 60              # 默认测试时长
  output_dir: /opt/rk3588-rt/logs
  csv_export: true            # 自动导出 CSV
  histogram_bins: 50          # 直方图分桶数

protocols:
  modbus:
    enabled: false
    tcp_port: 502
    rtu_port: /dev/ttyRS485
    holding_registers: 1024
    coils: 1024
  opcua:
    enabled: false
    port: 4840
    name: "RK3588-RT-Server"
  ethercat:
    enabled: false
    master_id: 0
    install_dir: /opt/ethercat

rt_kernel:
  bsp_branch: linux-6.1.y
  arch: arm64
  cross_compile: aarch64-linux-gnu-
  build_jobs: 4
  output_dir: /boot
CONF
    fi

    # 创建符号链接
    log_step "创建符号链接..."

    declare -A symlinks=(
        ["cpu_isolation.sh"]="rk3588-rt-isolate"
        ["irq_affinity.sh"]="rk3588-rt-irq"
        ["jitter_monitor.py"]="rk3588-rt-jitter"
        ["latency_analyzer.py"]="rk3588-rt-analyze"
        ["apply_rt_patch.sh"]="rk3588-rt-build-kernel"
        ["setup_realtime.sh"]="rk3588-rt-setup"
        ["install_ethercat.sh"]="rk3588-rt-ethercat"
        ["modbus_tcp_server.py"]="rk3588-rt-modbus"
        ["opcua_server.py"]="rk3588-rt-opcua"
        ["yaml_to_register_map.py"]="rk3588-rt-regmap"
    )

    for src_name in "${!symlinks[@]}"; do
        local link_name="${symlinks[$src_name]}"
        local target="/opt/rk3588-rt/bin/${src_name}"

        if [ -f "${PKG_DIR}${target}" ]; then
            ln -sf "$target" "${PKG_DIR}/usr/bin/${link_name}"
            log_info "  ${link_name} → ${target}"
        fi
    done

    log_info "文件复制完成"
}

# =============================================================================
# 生成 md5sums
# =============================================================================
generate_md5sums() {
    log_step "生成 md5sums..."
    cd "$PKG_DIR"
    find . -type f ! -path "./DEBIAN/*" -exec md5sum {} \; | \
        sed 's|\./||' > DEBIAN/md5sums
    cd "$REPO_ROOT"
}

# =============================================================================
# 构建 .deb
# =============================================================================
build_deb() {
    if [ "$DRY_RUN" -eq 1 ]; then
        log_info "[DRY-RUN] 将构建: ${DEB_NAME}_${VERSION}_${ARCH}.deb"
        log_info "[DRY-RUN] 包内容预览:"
        find "$PKG_DIR" -type f | sort
        return
    fi

    log_step "构建 .deb 包..."

    local deb_file="${BUILD_DIR}/${DEB_NAME}_${VERSION}_${ARCH}.deb"

    dpkg-deb --build "$PKG_DIR" "$deb_file" || {
        log_error "dpkg-deb 构建失败"
        exit 1
    }

    # 显示包信息
    echo ""
    echo "============================================"
    echo "  构建完成"
    echo "============================================"
    echo ""
    echo "  包名: $(basename "$deb_file")"
    echo "  大小: $(du -h "$deb_file" | cut -f1)"
    echo "  路径: $(realpath "$deb_file")"
    echo ""
    echo "  安装:   sudo dpkg -i $deb_file"
    echo "  卸载:   sudo dpkg -r ${DEB_NAME}"
    echo "  查看:   dpkg -c $deb_file"
    echo "  信息:   dpkg -I $deb_file"
    echo ""
    echo "============================================"

    # 验证包
    if command -v lintian &>/dev/null; then
        log_step "运行 lintian 检查..."
        lintian --suppress-tags=new-package-should-close-itp-bug "$deb_file" 2>/dev/null || true
    fi
}

# =============================================================================
# 主流程
# =============================================================================
main() {
    echo "============================================"
    echo "  RK3588 RT Middleware .deb 打包"
    echo "  版本: ${VERSION}"
    echo "  架构: ${ARCH}"
    echo "============================================"
    echo ""

    detect_python_deps
    detect_arch_specific_deps
    clean_build
    generate_control
    generate_postinst
    generate_prerm
    copy_files
    generate_md5sums
    build_deb
}

main "$@"
