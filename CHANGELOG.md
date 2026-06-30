# Changelog - RK3588 Industrial RT Middleware

## v1.0.0 (2026-06-30) - Initial Release
### Added
- CPU Core Isolation Tool (cpu_isolation.sh)
  - Dynamic isolcpus management
  - CPU affinity configuration
  - Real-time priority (SCHED_FIFO) assignment
  - AMP architecture support (A55 + A76)
- IRQ Affinity Configuration (irq_affinity.sh)
  - Interrupt pinning to housekeeping cores
  - IRQ balance control
  - Per-IRQ affinity listing
- Jitter Monitor (jitter_monitor.py)
  - Cyclictest-style latency measurement
  - P99/P99.9/Max latency reporting
  - JSON output for CI integration
  - RT priority auto-configuration
- IgH EtherCAT Master Auto-Installer
- PREEMPT_RT Kernel Build Guide
- Debian packaging (deb + apt-ready)
### Performance Targets
- PREEMPT_VOLUNTARY: P99=0.6us, Max=50ms (Grade D)
- PREEMPT_RT target: P99<50us, Max<80us (Grade A+)
- Xenomai target: P99<25us, Max<30us
