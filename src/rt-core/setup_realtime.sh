#!/bin/bash
# =============================================================================
# RK3588 实时系统初始化脚本
# 添加 isolcpus/nohz_full/rcu_nocbs 启动参数
# 安装 rt-tests，运行 cyclictest 验证
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LOG_FILE="/tmp/rk3588-rt-setup.log"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

log_info()  { echo -e "${GREEN}[INFO]${NC}  $*" | tee -a "$LOG_FILE"; }
log_warn()  { echo -e "${YELLOW}[WARN]${NC}  $*" | tee -a "$LOG_FILE"; }
log_error() { echo -e "${RED}[ERROR]${NC} $*" | tee -a "$LOG_FILE"; }
log_step()  { echo -e "${BLUE}[STEP]${NC}  $*" | tee -a "$LOG_FILE"; }

# =============================================================================
# 使用说明
# =============================================================================
usage() {
    cat << EOF
RK3588 实时系统初始化脚本 v1.0

Usage: $0 [OPTIONS]

选项:
  --linux-cores CORES    管理核心 (默认: 0-3, A55)
  --rt-cores CORES       实时核心 (默认: 4-7, A76)
  --dry-run              仅显示将执行的配置，不实际修改
  --no-cyclictest        跳过 cyclictest 验证
  --test-duration SEC    cyclictest 测试时长 (默认: 60s)
  -h, --help             显示此帮助

配置内容:
  1. 添加内核启动参数 (isolcpus, nohz_full, rcu_nocbs)
  2. 配置实时调度器参数
  3. 安装 rt-tests 工具包
  4. 配置 CPU 调频策略
  5. 运行 cyclictest 验证延迟

示例:
  sudo $0                                    # 全自动配置
  sudo $0 --dry-run                          # 预览配置
  sudo $0 --linux-cores 0-1 --rt-cores 2-7   # 自定义核心分配
EOF
    exit 0
}

# =============================================================================
# 参数解析
# =============================================================================
LINUX_CORES="0-3"
RT_CORES="4-7"
DRY_RUN=0
NO_CYCLICTEST=0
TEST_DURATION="60s"

while [[ $# -gt 0 ]]; do
    case "$1" in
        --linux-cores)    LINUX_CORES="$2"; shift 2 ;;
        --rt-cores)       RT_CORES="$2"; shift 2 ;;
        --dry-run)        DRY_RUN=1; shift ;;
        --no-cyclictest)  NO_CYCLICTEST=1; shift ;;
        --test-duration)  TEST_DURATION="$2"; shift 2 ;;
        -h|--help)        usage ;;
        *)                log_error "未知选项: $1"; usage ;;
    esac
done

# 检查 root 权限
if [ "$DRY_RUN" -eq 0 ] && [ "$(id -u)" -ne 0 ]; then
    log_error "此脚本需要 root 权限运行"
    log_error "请使用: sudo $0"
    exit 1
fi

# =============================================================================
# 检测启动方式 (GRUB / extlinux / U-Boot)
# =============================================================================
detect_bootloader() {
    log_step "检测启动引导方式..."

    if [ -f /etc/default/grub ] && command -v update-grub &>/dev/null; then
        BOOTLOADER="grub"
        CMDLINE_FILE="/etc/default/grub"
        CMDLINE_KEY="GRUB_CMDLINE_LINUX"
        log_info "检测到: GRUB"
    elif [ -f /boot/extlinux/extlinux.conf ]; then
        BOOTLOADER="extlinux"
        CMDLINE_FILE="/boot/extlinux/extlinux.conf"
        CMDLINE_KEY="append"
        log_info "检测到: extlinux (U-Boot)"
    elif [ -f /boot/uEnv.txt ]; then
        BOOTLOADER="uenv"
        CMDLINE_FILE="/boot/uEnv.txt"
        CMDLINE_KEY="extraargs"
        log_info "检测到: uEnv.txt (U-Boot)"
    elif [ -f /boot/armbianEnv.txt ]; then
        BOOTLOADER="armbian"
        CMDLINE_FILE="/boot/armbianEnv.txt"
        CMDLINE_KEY="extraargs"
        log_info "检测到: Armbian (U-Boot)"
    else
        BOOTLOADER="unknown"
        log_warn "未检测到标准启动引导器"
        log_warn "请手动添加内核参数到启动配置"
    fi
}

# =============================================================================
# 构建内核启动参数
# =============================================================================
build_cmdline_params() {
    log_step "构建实时内核启动参数..."

    local params=(
        "isolcpus=${RT_CORES}"
        "nohz_full=${RT_CORES}"
        "rcu_nocbs=${RT_CORES}"
        "rcu_nocb_poll"
        "nohz=on"
        "irqaffinity=${LINUX_CORES}"
        "skew_tick=1"
        "preempt=full"
        "audit=0"
        "nosoftlockup"
        "nowatchdog"
        "processor.max_cstate=1"
        "intel_idle.max_cstate=0"
        "idle=poll"
        "mitigations=off"
        "tsc=reliable"
        "clocksource=arch_sys_counter"
    )

    NEW_CMDLINE="${params[*]}"
    log_info "新增启动参数: $NEW_CMDLINE"
}

# =============================================================================
# 写入启动配置
# =============================================================================
write_boot_config() {
    log_step "写入启动配置..."

    if [ "$BOOTLOADER" = "unknown" ]; then
        log_warn "跳过启动配置写入 (未检测到标准引导器)"
        log_warn "请手动添加以下内核参数:"
        echo "  $NEW_CMDLINE"
        return
    fi

    if [ "$DRY_RUN" -eq 1 ]; then
        log_info "[DRY-RUN] 将写入 $CMDLINE_FILE:"
        log_info "  $NEW_CMDLINE"
        return
    fi

    # 备份原始配置
    local backup="${CMDLINE_FILE}.bak.$(date +%Y%m%d_%H%M%S)"
    cp "$CMDLINE_FILE" "$backup"
    log_info "备份原始配置: $backup"

    if [ "$BOOTLOADER" = "grub" ]; then
        # GRUB 配置
        local current_cmdline
        current_cmdline=$(grep "^${CMDLINE_KEY}=" "$CMDLINE_FILE" | head -1 || echo "")

        if [ -n "$current_cmdline" ]; then
            # 移除已有的实时参数
            local cleaned
            cleaned=$(echo "$current_cmdline" | sed -E \
                's/isolcpus=[^ "]*//g; s/nohz_full=[^ "]*//g; s/rcu_nocbs=[^ "]*//g; s/rcu_nocb_poll//g; s/nohz=on//g; s/irqaffinity=[^ "]*//g; s/skew_tick=1//g; s/preempt=full//g; s/processor\.max_cstate=[^ "]*//g; s/mitigations=off//g; s/audit=0//g; s/nosoftlockup//g; s/nowatchdog//g; s/idle=poll//g; s/tsc=reliable//g; s/clocksource=[^ "]*//g' | tr -s ' ')

            # 添加新的实时参数
            local new_line="${cleaned%\"} ${NEW_CMDLINE}\""
            sed -i "s|^${CMDLINE_KEY}=.*|${new_line}|" "$CMDLINE_FILE"
        else
            echo "${CMDLINE_KEY}=\"${NEW_CMDLINE}\"" >> "$CMDLINE_FILE"
        fi

        log_info "GRUB 配置已更新"
        log_info "运行 update-grub 使配置生效..."

        if [ "$DRY_RUN" -eq 0 ]; then
            update-grub 2>&1 | tee -a "$LOG_FILE" || {
                log_warn "update-grub 失败，请手动运行"
            }
        fi

    elif [ "$BOOTLOADER" = "extlinux" ]; then
        # extlinux 配置
        local current
        current=$(grep "^\s*${CMDLINE_KEY}" "$CMDLINE_FILE" | head -1 || echo "")

        if [ -n "$current" ]; then
            local cleaned
            cleaned=$(echo "$current" | sed -E \
                's/isolcpus=[^ ]*//g; s/nohz_full=[^ ]*//g; s/rcu_nocbs=[^ ]*//g; s/rcu_nocb_poll//g; s/nohz=on//g; s/irqaffinity=[^ ]*//g; s/skew_tick=1//g; s/preempt=full//g; s/processor\.max_cstate=[^ ]*//g; s/mitigations=off//g; s/audit=0//g; s/nosoftlockup//g; s/nowatchdog//g; s/idle=poll//g; s/tsc=reliable//g; s/clocksource=[^ ]*//g' | tr -s ' ')
            local new_line="${cleaned} ${NEW_CMDLINE}"
            sed -i "s|^\s*${CMDLINE_KEY}.*|${new_line}|" "$CMDLINE_FILE"
        else
            echo "  ${CMDLINE_KEY} ${NEW_CMDLINE}" >> "$CMDLINE_FILE"
        fi
        log_info "extlinux 配置已更新"

    elif [ "$BOOTLOADER" = "uenv" ] || [ "$BOOTLOADER" = "armbian" ]; then
        # uEnv / armbianEnv 配置
        local current
        current=$(grep "^${CMDLINE_KEY}=" "$CMDLINE_FILE" | head -1 || echo "")

        if [ -n "$current" ]; then
            local cleaned
            cleaned=$(echo "$current" | sed -E \
                's/isolcpus=[^ ]*//g; s/nohz_full=[^ ]*//g; s/rcu_nocbs=[^ ]*//g; s/rcu_nocb_poll//g; s/nohz=on//g; s/irqaffinity=[^ ]*//g; s/skew_tick=1//g; s/preempt=full//g; s/processor\.max_cstate=[^ ]*//g; s/mitigations=off//g; s/audit=0//g; s/nosoftlockup//g; s/nowatchdog//g; s/idle=poll//g; s/tsc=reliable//g; s/clocksource=[^ ]*//g' | tr -s ' ')
            local new_line="${cleaned} ${NEW_CMDLINE}"
            sed -i "s|^${CMDLINE_KEY}=.*|${new_line}|" "$CMDLINE_FILE"
        else
            echo "${CMDLINE_KEY}=${NEW_CMDLINE}" >> "$CMDLINE_FILE"
        fi
        log_info "${BOOTLOADER} 配置已更新"
    fi

    log_info "启动配置写入完成"
}

# =============================================================================
# 配置实时调度器
# =============================================================================
configure_rt_scheduler() {
    log_step "配置实时调度器参数..."

    if [ "$DRY_RUN" -eq 1 ]; then
        log_info "[DRY-RUN] 将配置以下参数:"
        log_info "  /proc/sys/kernel/sched_rt_runtime_us = 980000"
        log_info "  /proc/sys/kernel/sched_rt_period_us = 1000000"
        return
    fi

    # 设置 RT 调度器 runtime (保留 2% 给非 RT 任务防止锁死)
    if [ -f /proc/sys/kernel/sched_rt_runtime_us ]; then
        echo 980000 > /proc/sys/kernel/sched_rt_runtime_us
        log_info "RT runtime: $(cat /proc/sys/kernel/sched_rt_runtime_us)us"
    else
        log_warn "sched_rt_runtime_us 不可用"
    fi

    if [ -f /proc/sys/kernel/sched_rt_period_us ]; then
        echo 1000000 > /proc/sys/kernel/sched_rt_period_us
        log_info "RT period:  $(cat /proc/sys/kernel/sched_rt_period_us)us"
    fi

    # 持久化 sysctl 配置
    local sysctl_conf="/etc/sysctl.d/99-rk3588-rt.conf"
    cat > "$sysctl_conf" << EOF
# RK3588 Real-Time Scheduler Configuration
kernel.sched_rt_runtime_us = 980000
kernel.sched_rt_period_us = 1000000
kernel.nmi_watchdog = 0
kernel.watchdog = 0
kernel.watchdog_thresh = 0
vm.stat_interval = 10
EOF
    sysctl -p "$sysctl_conf" 2>/dev/null || true
    log_info "sysctl 配置: $sysctl_conf"
}

# =============================================================================
# CPU 调频策略
# =============================================================================
configure_cpu_governor() {
    log_step "配置 CPU 调频策略为 performance..."

    if [ "$DRY_RUN" -eq 1 ]; then
        log_info "[DRY-RUN] 将设置所有 CPU governor 为 performance"
        return
    fi

    local governor_changed=0
    for cpu in /sys/devices/system/cpu/cpu[0-9]*/cpufreq/scaling_governor; do
        if [ -f "$cpu" ]; then
            local current
            current=$(cat "$cpu")
            if [ "$current" != "performance" ]; then
                echo "performance" > "$cpu" 2>/dev/null || true
                governor_changed=1
            fi
        fi
    done

    if [ $governor_changed -eq 1 ]; then
        log_info "CPU governor 已设为 performance"
    else
        log_info "CPU governor 已是 performance"
    fi
}

# =============================================================================
# 安装 rt-tests
# =============================================================================
install_rt_tests() {
    log_step "安装 rt-tests 工具包..."

    if command -v cyclictest &>/dev/null; then
        log_info "cyclictest 已安装: $(cyclictest --version 2>&1 | head -1)"
        return
    fi

    if [ "$DRY_RUN" -eq 1 ]; then
        log_info "[DRY-RUN] 将安装 rt-tests 包"
        return
    fi

    # 尝试从包管理器安装
    if apt-get install -y rt-tests 2>/dev/null; then
        log_info "rt-tests 安装成功"
        return
    fi

    # 包管理器不可用时从源码编译
    log_warn "包管理器安装失败，从源码编译 rt-tests..."
    local rt_tests_dir="/tmp/rt-tests-build"

    if [ ! -d "$rt_tests_dir" ]; then
        git clone --depth=1 https://git.kernel.org/pub/scm/utils/rt-tests/rt-tests.git "$rt_tests_dir" 2>&1 | tee -a "$LOG_FILE" || {
            log_error "rt-tests 源码克隆失败"
            return 1
        }
    fi

    cd "$rt_tests_dir"
    make -j"$(nproc)" 2>&1 | tee -a "$LOG_FILE" || {
        log_error "rt-tests 编译失败"
        return 1
    }

    sudo make install 2>&1 | tee -a "$LOG_FILE"
    log_info "rt-tests 编译安装完成"
}

# =============================================================================
# 运行 cyclictest 验证
# =============================================================================
run_cyclictest() {
    if [ "$NO_CYCLICTEST" -eq 1 ]; then
        log_info "跳过 cyclictest (--no-cyclictest)"
        return
    fi

    log_step "运行 cyclictest 验证延迟..."

    if [ "$DRY_RUN" -eq 1 ]; then
        log_info "[DRY-RUN] 将运行: cyclictest -t4 -p99 -i200 -D ${TEST_DURATION}"
        return
    fi

    if ! command -v cyclictest &>/dev/null; then
        log_warn "cyclictest 未安装，跳过延迟验证"
        return
    fi

    # 计算 RT 核心数
    local num_rt_cores
    num_rt_cores=$(echo "$RT_CORES" | tr ',' '\n' | wc -l)

    echo ""
    echo "============================================"
    echo "  cyclictest 延迟验证 (${TEST_DURATION})"
    echo "============================================"
    echo ""

    # 运行 cyclictest
    cyclictest \
        -t"${num_rt_cores}" \
        -p99 \
        -i200 \
        -D "$TEST_DURATION" \
        --smp \
        --mlockall \
        --histogram=1000 \
        2>&1 | tee -a "$LOG_FILE"

    local exit_code=${PIPESTATUS[0]}
    echo ""
    echo "============================================"
    if [ $exit_code -eq 0 ]; then
        log_info "cyclictest 完成"
    else
        log_warn "cyclictest 异常退出 (code: $exit_code)"
    fi
}

# =============================================================================
# 内存锁定配置
# =============================================================================
configure_memlock() {
    log_step "配置内存锁定限制..."

    if [ "$DRY_RUN" -eq 1 ]; then
        log_info "[DRY-RUN] 将设置 memlock 为 unlimited"
        return
    fi

    local limits_conf="/etc/security/limits.d/99-rk3588-rt.conf"
    cat > "$limits_conf" << EOF
# RK3588 Real-Time: unlimited memlock
*    -   memlock     unlimited
root -   memlock     unlimited
EOF
    log_info "memlock 配置: $limits_conf"
}

# =============================================================================
# 验证当前配置
# =============================================================================
verify_config() {
    log_step "验证实时配置..."

    echo ""
    echo "============================================"
    echo "  实时系统配置验证"
    echo "============================================"

    echo ""
    echo "--- 内核信息 ---"
    echo -n "  版本: "; uname -r
    echo -n "  实时内核: "
    if [ -f /sys/kernel/realtime ] && [ "$(cat /sys/kernel/realtime)" = "1" ]; then
        echo -e "${GREEN}是 (PREEMPT_RT)${NC}"
    else
        echo -e "${YELLOW}否 (可能需要重启)${NC}"
    fi
    echo -n "  抢占模型: "; cat /sys/kernel/realtime 2>/dev/null || echo "N/A"

    echo ""
    echo "--- CPU 配置 ---"
    echo -n "  隔离核心: "; cat /sys/devices/system/cpu/isolated 2>/dev/null || echo "none"
    echo -n "  在线核心: "; cat /sys/devices/system/cpu/online 2>/dev/null || echo "N/A"

    echo ""
    echo "--- CPU Governor ---"
    for cpu in /sys/devices/system/cpu/cpu[0-9]*/cpufreq/scaling_governor; do
        [ -f "$cpu" ] && echo "  $(basename $(dirname $cpu)): $(cat $cpu)"
    done

    echo ""
    echo "--- 调度器 ---"
    if [ -f /proc/sys/kernel/sched_rt_runtime_us ]; then
        echo "  RT runtime: $(cat /proc/sys/kernel/sched_rt_runtime_us)us"
    fi
    if [ -f /proc/sys/kernel/sched_rt_period_us ]; then
        echo "  RT period:  $(cat /proc/sys/kernel/sched_rt_period_us)us"
    fi

    echo ""
    echo "--- 内核启动参数 ---"
    cat /proc/cmdline 2>/dev/null | tr ' ' '\n' | grep -E 'isolcpus|nohz|rcu|irqaffinity|preempt' || echo "  无实时参数"

    echo ""
    echo "--- rt-tests 状态 ---"
    if command -v cyclictest &>/dev/null; then
        echo "  cyclictest: $(which cyclictest)"
        cyclictest --version 2>&1 | head -1
    else
        echo "  cyclictest: 未安装"
    fi

    echo ""
    echo "============================================"
}

# =============================================================================
# 打印摘要
# =============================================================================
print_summary() {
    echo ""
    echo "============================================"
    echo "  RK3588 实时系统初始化完成"
    echo "============================================"
    echo ""
    echo "  管理核心 (Linux):   $LINUX_CORES"
    echo "  实时核心 (RT):      $RT_CORES"
    echo "  启动引导器:         $BOOTLOADER"
    echo ""
    echo "  已配置项:"
    echo "    - 内核启动参数 (isolcpus, nohz_full, rcu_nocbs)"
    echo "    - 实时调度器 (98% RT runtime)"
    echo "    - CPU 调频策略 (performance)"
    echo "    - 内存锁定限制 (unlimited)"
    echo ""
    if [ "$DRY_RUN" -eq 0 ] && [ "$BOOTLOADER" != "unknown" ]; then
        echo "  >>> 请重启系统使配置生效: sudo reboot <<<"
        echo ""
        echo "  重启后验证:"
        echo "    cat /proc/cmdline | tr ' ' '\\\\n' | grep isolcpus"
        echo "    cat /sys/kernel/realtime"
        echo "    sudo cyclictest -t4 -p99 -i200 -D 60s"
    fi
    echo ""
    echo "============================================"
}

# =============================================================================
# 主流程
# =============================================================================
main() {
    echo "============================================"
    echo "  RK3588 实时系统初始化"
    echo "============================================"
    echo ""

    echo "=== RK3588 RT Setup Log - $(date) ===" > "$LOG_FILE"

    detect_bootloader
    build_cmdline_params
    write_boot_config
    configure_rt_scheduler
    configure_cpu_governor
    configure_memlock
    install_rt_tests
    verify_config
    print_summary

    # cyclictest 在最后运行，因为比较耗时
    run_cyclictest
}

main "$@"
