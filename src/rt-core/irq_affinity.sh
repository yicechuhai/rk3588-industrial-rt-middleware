#!/bin/bash
# =============================================================================
# RK3588 IRQ Affinity Configuration Tool
# 将中断绑定到指定CPU核心，减少实时任务的抖动
# =============================================================================
set -euo pipefail

usage() {
    cat << EOF
RK3588 IRQ Affinity Tool v1.0

Usage: $0 <command>

Commands:
  list              Show all IRQs with current affinity
  isolate <cores>   Move all movable IRQs to specified cores (e.g. "0-3")
  restore           Restore default IRQ affinity (all cores)
  pin <irq> <cpu>   Pin specific IRQ to CPU core

Strategy:
  - Isolate RT cores (4-7, A76) from IRQ handling
  - Route all interrupts to housekeeping cores (0-3, A55)
  - Pin critical IRQs (e.g. Ethernet, NPU) to specific cores
EOF
    exit 0
}

list() {
    printf "%-6s %-6s %-10s %s\n" "IRQ" "CPU" "Count" "Device"
    printf "%-6s %-6s %-10s %s\n" "---" "---" "-----" "------"
    for irq in $(ls -d /proc/irq/[0-9]* 2>/dev/null | sort -V); do
        irq_num=$(basename $irq)
        [ "$irq_num" = "0" ] && continue
        
        affinity=$(cat $irq/smp_affinity_list 2>/dev/null || echo "N/A")
        count=$(awk '{sum += $2} END {print sum}' $irq/per_cpu_count 2>/dev/null || echo "0")
        
        # Get device name
        actions=$(cat $irq/actions 2>/dev/null | head -1)
        device=$(echo "$actions" | grep -oP '[^,]+$' | xargs 2>/dev/null || echo "unknown")
        
        printf "%-6s %-6s %-10s %s\n" "$irq_num" "$affinity" "$count" "$device"
    done
}

isolate() {
    local target="$1"
    echo "Moving IRQs to cores: $target"
    
    for irq in $(ls -d /proc/irq/[0-9]* 2>/dev/null); do
        irq_num=$(basename $irq)
        [ "$irq_num" = "0" ] && continue
        
        # Skip non-movable IRQs
        flags=$(cat $irq/flag 2>/dev/null || echo "")
        if echo "$flags" | grep -q "IRQ_NO_BALANCING\|IRQ_PER_CPU"; then
            continue
        fi
        
        echo "$target" | sudo tee $irq/smp_affinity_list > /dev/null 2>&1 || true
    done
    
    echo "Done. Verify with: $0 list"
}

restore() {
    local all_cores="0-7"
    echo "Restoring IRQs to all cores: $all_cores"
    for irq in $(ls -d /proc/irq/[0-9]* 2>/dev/null); do
        echo "$all_cores" | sudo tee $irq/smp_affinity_list > /dev/null 2>&1 || true
    done
    echo "Done."
}

pin() {
    local irq="$1"
    local cpu="$2"
    echo "$cpu" | sudo tee /proc/irq/$irq/smp_affinity_list > /dev/null 2>&1
    echo "IRQ $irq pinned to CPU $cpu"
}

case "${1:-}" in
    list)     list ;;
    isolate)  isolate "${2:-0-3}" ;;
    restore)  restore ;;
    pin)      pin "${2:-}" "${3:-}" ;;
    *)        usage ;;
esac
