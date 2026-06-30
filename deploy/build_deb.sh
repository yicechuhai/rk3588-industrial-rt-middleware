#!/bin/bash
# =============================================================================
# Build RK3588 RT Middleware .deb package
# =============================================================================
set -euo pipefail

DEB_NAME="rk3588-rt-middleware"
VERSION="1.0.0"
ARCH="arm64"
BUILD_DIR="build/deb"
PKG_DIR="\/\_\_\"

echo "Building \ v\..."

# Clean
rm -rf \
mkdir -p \/DEBIAN
mkdir -p \/opt/rk3588-rt/{bin,config,logs}
mkdir -p \/usr/share/doc/\
mkdir -p \/etc/\

# Copy DEBIAN control files
cp deploy/DEBIAN/{control,postinst,prerm} \/DEBIAN/
chmod 755 \/DEBIAN/{postinst,prerm}

# Copy binaries
cp src/monitor/jitter_monitor.py \/opt/rk3588-rt/bin/
cp src/rt-core/cpu_isolation.sh \/opt/rk3588-rt/bin/
cp src/rt-core/irq_affinity.sh \/opt/rk3588-rt/bin/
cp docs/PREEMPT_RT_GUIDE.sh \/opt/rk3588-rt/bin/
cp src/protocols/install_ethercat.sh \/opt/rk3588-rt/bin/
chmod +x \/opt/rk3588-rt/bin/*

# Create symlinks in /usr/bin
mkdir -p \/usr/bin
ln -sf /opt/rk3588-rt/bin/jitter_monitor.py \/usr/bin/rk3588-rt-jitter
ln -sf /opt/rk3588-rt/bin/cpu_isolation.sh \/usr/bin/rk3588-rt-isolate
ln -sf /opt/rk3588-rt/bin/irq_affinity.sh \/usr/bin/rk3588-rt-irq
ln -sf /opt/rk3588-rt/bin/PREEMPT_RT_GUIDE.sh \/usr/bin/rk3588-rt-build-kernel
ln -sf /opt/rk3588-rt/bin/install_ethercat.sh \/usr/bin/rk3588-rt-ethercat

# Copy documentation
cp README.md \/usr/share/doc/\/
cp docs/PREEMPT_RT_GUIDE.sh \/usr/share/doc/\/

# Copy default config
cat > \/etc/\/rt_config.yaml << 'CONF'
# RK3588 RT Middleware Configuration
cpu:
  linux_cores: "0-3"       # A55 - Linux management
  rt_cores: "4-7"           # A76 - Real-time tasks
  governor: performance

scheduler:
  rt_runtime_us: 980000
  rt_period_us: 1000000
  default_priority: 80

monitor:
  interval_us: 500
  duration_s: 60
  output_dir: /opt/rk3588-rt/logs

protocols:
  ethercat:
    enabled: false
    master_id: 0
  opcua:
    port: 4840
  modbus:
    tcp_port: 502
    rtu_port: /dev/ttyRS485
CONF

# Build .deb
dpkg-deb --build \ \/\_\_\.deb

echo ""
echo "Package built: \/\_\_\.deb"
echo "Install: sudo dpkg -i \/\_\_\.deb"
