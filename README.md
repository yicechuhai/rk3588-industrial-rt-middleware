# RK3588 Industrial Protocol Real-Time Middleware

\\\
RK3588 SoC
├── A55 Cluster (Cores 0-3) → Linux Management
│   ├── OPC UA Server (port 4840)
│   ├── Modbus TCP/RTU (port 502)
│   ├── Dashboard (port 8080)
│   └── System Monitor
│
├── A76 Cluster (Cores 4-7) → Real-Time Island
│   ├── EtherCAT Master
│   ├── Profinet Stack
│   ├── Motion Control
│   └── Sensor Fusion
│
└── IPC (RPMsg / Shared Memory)
\\\

## Components

| Module | Path | Description |
|--------|------|-------------|
| CPU Isolation | src/rt-core/cpu_isolation.sh | Isolate cores, set affinity |
| IRQ Affinity | src/rt-core/irq_affinity.sh | Pin interrupts to housekeeping cores |
| Jitter Monitor | src/monitor/jitter_monitor.py | Cyclictest-style latency measurement |
| EtherCAT | src/protocols/install_ethercat.sh | IgH EtherCAT Master installer |
| RT Scheduler | config/rt_scheduler.yaml | RT task scheduling config |

## Quick Start

\\\ash
# 1. Isolate real-time cores (A76)
sudo bash src/rt-core/cpu_isolation.sh isolate 4-7

# 2. Pin IRQs to housekeeping cores
sudo bash src/rt-core/irq_affinity.sh isolate 0-3

# 3. Measure baseline latency
sudo python3 src/monitor/jitter_monitor.py -d 60

# 4. Install EtherCAT Master
sudo bash src/protocols/install_ethercat.sh

# 5. Deploy with PREEMPT_RT kernel for <50us latency
bash docs/PREEMPT_RT_GUIDE.sh
\\\

## Performance Targets

| Metric | PREEMPT_VOLUNTARY | PREEMPT_RT | Xenomai |
|--------|-------------------|------------|---------|
| P99 Latency | 500us | <50us | <25us |
| Max Latency | 5ms | 80us | 30us |
| EtherCAT Cycle | N/A | 250us | 100us |
