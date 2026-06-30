#!/bin/bash
# =============================================================================
# RK3588 PREEMPT_RT Kernel Build Guide
# 为 RK3588 构建实时内核，实现微秒级确定性延迟
# =============================================================================
# 
# 当前状态: CONFIG_PREEMPT_VOLUNTARY → 延迟 ~1-5ms (非确定性)
# 目标状态: CONFIG_PREEMPT_RT      → 延迟 <50us  (硬实时)
#
# 适用芯片: RK3588 (Cortex-A76 + Cortex-A55)
# RT 补丁:  https://cdn.kernel.org/pub/linux/kernel/projects/rt/
# =============================================================================

echo "=========================================="
echo "  RK3588 PREEMPT_RT Kernel Build Guide"
echo "=========================================="
echo ""

# Detect current kernel
KVER=$(uname -r)
echo "Current: $KVER (PREEMPT_VOLUNTARY)"
echo "Target:  $KVER-rtXX (PREEMPT_RT)"
echo ""

cat << 'GUIDE'
## Quick Start (Manual Build)

### 1. Download RT Patch
```bash
RT_VER="6.1.75-rt23"  # Match your kernel version
wget https://cdn.kernel.org/pub/linux/kernel/projects/rt/6.1/patch-${RT_VER}.patch.xz
```

### 2. Get Kernel Source
```bash
git clone --depth=1 --branch=linux-6.1.y \
    https://github.com/rockchip-linux/kernel.git rk3588-kernel
cd rk3588-kernel
```

### 3. Apply RT Patch
```bash
xzcat ../patch-${RT_VER}.patch.xz | patch -p1
```

### 4. Configure for Real-Time
```bash
export ARCH=arm64
export CROSS_COMPILE=aarch64-linux-gnu-
make rockchip_linux_defconfig
./scripts/config -e CONFIG_PREEMPT_RT -d CONFIG_PREEMPT_VOLUNTARY
./scripts/config -e CONFIG_HZ_1000 -e CONFIG_HIGHRES_TIMERS
./scripts/config -e CONFIG_NO_HZ_FULL -e CONFIG_RCU_NOCB_CPU
./scripts/config -e CONFIG_CPU_ISOLATION
make olddefconfig
```

### 5. Build
```bash
make -j$(nproc) Image modules dtbs
sudo make modules_install
sudo cp arch/arm64/boot/Image /boot/Image-rt
sudo cp arch/arm64/boot/dts/rockchip/rk3588-*.dtb /boot/
sudo update-initramfs -c -k ${RT_VER}
```

### 6. Boot with isolcpus
Add to kernel cmdline: `isolcpus=4-7 rcu_nocbs=4-7 nohz_full=4-7`

### 7. Verify
```bash
uname -r                     # Should show -rtXX
cat /sys/kernel/realtime     # Should return 1
cyclictest -t4 -p99 -i200 -d0 -D 60s
```

## Expected Latency Improvement

| Kernel Type         | Avg Latency | Max Latency | P99 Latency |
|---------------------|-------------|-------------|-------------|
| PREEMPT_VOLUNTARY   | 50-200us    | 1-5ms       | 500us       |
| PREEMPT (Low-Lat)   | 20-50us     | 200-500us   | 100us       |
| PREEMPT_RT          | 5-15us      | 30-80us     | 25us        |
| Xenomai (Cobalt)    | 2-8us       | 15-30us     | 10us        |

GUIDE
