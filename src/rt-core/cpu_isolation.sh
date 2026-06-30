#!/bin/bash
# =============================================================================
# RK3588 CPU Core Isolation Tool
# 将指定核心从 Linux 调度器中隔离，专用于实时任务
# 支持 AMP (Asymmetric Multi-Processing) 架构
# =============================================================================
set -euo pipefail

usage() {
    cat << EOF
RK3588 CPU Core Isolation Tool v1.0

Usage: $0 <command> [args]

Commands:
  info                    Show CPU topology and current isolation
  isolate <cores>         Isolate cores (e.g. "4-7" or "4,5,6,7")
  release <cores>         Release isolated cores back to scheduler
  affinity <pid> <mask>   Set CPU affinity for process (hex mask)
  rt-priority <pid> <pri> Set real-time priority (1-99, FIFO)
  status                  Show isolation + affinity status

Examples:
  $0 isolate 4-7           # Isolate A76 cores for RT tasks
  $0 affinity \$(pidof pipeline_runner) 0xf0  # Pin to cores 4-7
  $0 rt-priority \$(pidof modbus_server) 80
EOF
    exit 0
}

info() {
    echo "=== CPU Topology ==="
    lscpu 2>/dev/null | grep -E 'Architecture|CPU\(s\)|Model name|Thread|Core|Socket'
    echo ""
    echo "=== NUMA Nodes ==="
    numactl --hardware 2>/dev/null || echo "numactl not available"
    echo ""
    echo "=== Current Isolation ==="
    cat /sys/devices/system/cpu/isolated 2>/dev/null || echo "none"
    echo ""
    echo "=== CPU Governor ==="
    for cpu in /sys/devices/system/cpu/cpu[0-9]*; do
        gov=$(cat $cpu/cpufreq/scaling_governor 2>/dev/null || echo "N/A")
        freq=$(cat $cpu/cpufreq/scaling_cur_freq 2>/dev/null || echo "N/A")
        echo "  $(basename $cpu): governor=$gov freq=$((freq/1000))MHz"
    done
    echo ""
    echo "=== IRQ Affinity ==="
    for irq in /proc/irq/*/smp_affinity_list 2>/dev/null; do
        irq_num=$(echo $irq | cut -d'/' -f4)
        aff=$(cat $irq 2>/dev/null)
        name=$(cat /proc/irq/$irq_num/actions 2>/dev/null | head -1 | awk '{print $NF}' || echo "unknown")
        [ "$aff" != "0-7" ] && echo "  IRQ $irq_num ($name): $aff"
    done
}

isolate() {
    local cores="$1"
    echo "Isolating cores: $cores"
    # Set isolcpus via sysfs (dynamic isolation)
    echo "$cores" | sudo tee /sys/devices/system/cpu/isolated > /dev/null 2>&1 || {
        echo "ERROR: Dynamic isolation not supported by kernel"
        echo "Add 'isolcpus=$cores' to kernel cmdline and reboot:"
        echo "  sudo sed -i 's/GRUB_CMDLINE_LINUX=\"/GRUB_CMDLINE_LINUX=\"isolcpus=$cores /' /etc/default/grub"
        echo "  sudo update-grub && sudo reboot"
        return 1
    }
    # Move IRQs off isolated cores
    for irq in /proc/irq/*/smp_affinity_list; do
        echo "0-3" | sudo tee $(dirname $irq)/smp_affinity_list > /dev/null 2>&1 || true
    done
    echo "Cores $cores isolated. IRQs moved to 0-3."
}

release() {
    local cores="$1"
    echo "" | sudo tee /sys/devices/system/cpu/isolated > /dev/null 2>&1
    echo "All cores released."
}

affinity() {
    local pid="$1"
    local mask="$2"
    taskset -p 0x$mask $pid 2>/dev/null || {
        # Try decimal
        taskset -cp $(printf "%d" 0x$mask) $pid
    }
    echo "PID $pid affinity set to 0x$mask"
}

rt_priority() {
    local pid="$1"
    local pri="$2"
    sudo chrt -f -p $pri $pid
    echo "PID $pid RT priority set to $pri (SCHED_FIFO)"
}

status() {
    echo "=== CPU Isolation ==="
    isolated=$(cat /sys/devices/system/cpu/isolated 2>/dev/null || echo "none")
    echo "Isolated: $isolated"
    echo ""
    echo "=== RT Tasks ==="
    ps -eo pid,comm,rtprio,psr | grep -v "  - " | head -20
}

# Main
case "${1:-}" in
    info)        info ;;
    isolate)     isolate "${2:-4-7}" ;;
    release)     release "${2:-}" ;;
    affinity)    affinity "${2:-}" "${3:-}" ;;
    rt-priority) rt_priority "${2:-}" "${3:-}" ;;
    status)      status ;;
    *)           usage ;;
esac
