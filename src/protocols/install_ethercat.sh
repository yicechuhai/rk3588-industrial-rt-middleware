#!/bin/bash
# =============================================================================
# RK3588 IgH EtherCAT Master Installer
# 下载、编译、安装 IgH EtherCAT Master 到 RK3588
# =============================================================================
set -euo pipefail

IGH_VERSION="1.6.0"
IGH_URL="https://gitlab.com/etherlab.org/ethercat/-/archive/stable-${IGH_VERSION}/ethercat-stable-${IGH_VERSION}.tar.gz"
INSTALL_DIR="/opt/ethercat"

echo "=========================================="
echo "  RK3588 IgH EtherCAT Master Installer"
echo "  Version: $IGH_VERSION"
echo "=========================================="
echo ""

# Check dependencies
echo "[1/5] Checking dependencies..."
DEPS="build-essential autoconf automake libtool pkg-config linux-headers-$(uname -r)"
for dep in $DEPS; do
    dpkg -s "$dep" >/dev/null 2>&1 || {
        echo "  Installing $dep..."
        sudo apt-get install -y "$dep" 2>/dev/null || echo "  WARNING: $dep not available"
    }
done
echo "  Dependencies OK"

# Download
echo "[2/5] Downloading EtherCAT Master $IGH_VERSION..."
cd /tmp
if [ ! -f "ethercat-${IGH_VERSION}.tar.gz" ]; then
    wget -q "$IGH_URL" -O "ethercat-${IGH_VERSION}.tar.gz" || {
        echo "ERROR: Download failed. Try manual install."
        exit 1
    }
fi

# Extract and build
echo "[3/5] Building..."
tar xzf "ethercat-${IGH_VERSION}.tar.gz"
cd "ethercat-stable-${IGH_VERSION}"

./bootstrap 2>/dev/null || true
./configure --prefix=$INSTALL_DIR \
    --enable-generic \
    --enable-rtdm \
    --with-linux-dir=/usr/src/linux-headers-$(uname -r) \
    2>&1 | tail -3

make -j$(nproc) 2>&1 | tail -5

# Install
echo "[4/5] Installing..."
sudo make install 2>&1 | tail -3
sudo make modules_install 2>&1 | tail -3

# Configure
echo "[5/5] Configuring..."
sudo cp /opt/etherlab/etc/sysconfig/ethercat /etc/ethercat.conf 2>/dev/null || true

cat << EOF
==========================================
  EtherCAT Master Installation Complete!
==========================================

  Binary:   $INSTALL_DIR/bin/ethercat
  Library:  $INSTALL_DIR/lib/libethercat.so
  Modules:  /lib/modules/$(uname -r)/ethercat/

  Start:    sudo $INSTALL_DIR/etc/init.d/ethercat start
  Test:     $INSTALL_DIR/bin/ethercat slaves

  Documentation: $INSTALL_DIR/share/doc/ethercat-doc/
==========================================
EOF
