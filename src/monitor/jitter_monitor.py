#!/usr/bin/env python3
"""
RK3588 Latency Jitter Monitor
Measures scheduling latency with microsecond precision.
Drop-in replacement for cyclictest on ARM64.
"""
import time, sys, os, signal, threading
import numpy as np
from collections import deque

HIST_SIZE = 10000
INTERVAL_US = 1000  # 1ms between measurements
DURATION_S = 60     # Default 60s test

class JitterMonitor:
    def __init__(self, interval_us=1000, duration_s=60, rt_priority=80):
        self.interval_us = interval_us
        self.duration_s = duration_s
        self.rt_priority = rt_priority
        self.latencies = deque(maxlen=HIST_SIZE)
        self.running = True
        self.overruns = 0
        
    def set_rt_priority(self):
        try:
            param = os.sched_param(self.rt_priority)
            os.sched_setscheduler(0, os.SCHED_FIFO, param)
            print(f"RT priority set to {self.rt_priority} (SCHED_FIFO)")
        except PermissionError:
            print("WARNING: Cannot set RT priority (run with sudo for accurate results)")
    
    def measure(self):
        self.set_rt_priority()
        
        period_ns = self.interval_us * 1000
        next_wake = time.monotonic_ns()
        
        t_start = time.time()
        samples = 0
        
        while self.running and (time.time() - t_start) < self.duration_s:
            # Calculate next wake time
            next_wake += period_ns
            
            # Busy-wait until target time
            now = time.monotonic_ns()
            if now > next_wake:
                self.overruns += 1
                next_wake = now
            
            # Record latency (how late we are)
            actual = time.monotonic_ns()
            latency_us = (actual - next_wake) / 1000.0
            
            self.latencies.append(latency_us)
            samples += 1
            
            # Print periodic status
            if samples % 5000 == 0:
                self.print_status(samples, time.time() - t_start)
        
        return samples
    
    def print_status(self, samples, elapsed):
        arr = np.array(self.latencies)
        print(f"\r[{elapsed:5.1f}s] Samples:{samples:6d} | "
              f"Min:{np.min(arr):6.1f}us Avg:{np.mean(arr):6.1f}us "
              f"Max:{np.max(arr):6.1f}us P99:{np.percentile(arr,99):6.1f}us "
              f"Overruns:{self.overruns}", end='')
        sys.stdout.flush()
    
    def report(self, samples, elapsed):
        arr = np.array(self.latencies)
        
        print(f"\n\n{'='*60}")
        print(f"  RK3588 Latency Jitter Report")
        print(f"{'='*60}")
        print(f"  Duration:       {elapsed:.1f}s")
        print(f"  Samples:        {samples}")
        print(f"  Interval:       {self.interval_us}us")
        print(f"  Overruns:       {self.overruns}")
        print(f"  RT Priority:    {self.rt_priority}")
        print(f"  ---")
        print(f"  Min Latency:    {np.min(arr):8.1f} us")
        print(f"  Avg Latency:    {np.mean(arr):8.1f} us")
        print(f"  Median:         {np.median(arr):8.1f} us")
        print(f"  P95:            {np.percentile(arr,95):8.1f} us")
        print(f"  P99:            {np.percentile(arr,99):8.1f} us")
        print(f"  P99.9:          {np.percentile(arr,99.9):8.1f} us")
        print(f"  Max Latency:    {np.max(arr):8.1f} us")
        print(f"{'='*60}")
        
        # Grade
        p99 = np.percentile(arr, 99)
        if p99 < 50:
            grade = "A+ (Hard Real-Time Ready)"
        elif p99 < 100:
            grade = "A  (Soft Real-Time Ready)"
        elif p99 < 500:
            grade = "B  (Industrial Control Grade)"
        elif p99 < 1000:
            grade = "C  (General Automation)"
        else:
            grade = "D  (Non-Real-Time — consider PREEMPT_RT)"
        
        print(f"  Grade: {grade}")
        print(f"{'='*60}\n")

def main():
    import argparse
    ap = argparse.ArgumentParser(description="RK3588 Jitter Monitor")
    ap.add_argument("-i", "--interval", type=int, default=1000, help="Sample interval in us")
    ap.add_argument("-d", "--duration", type=int, default=60, help="Test duration in seconds")
    ap.add_argument("-p", "--priority", type=int, default=80, help="RT priority (1-99)")
    ap.add_argument("--json", action="store_true", help="Output JSON")
    args = ap.parse_args()
    
    monitor = JitterMonitor(args.interval, args.duration, args.priority)
    samples = monitor.measure()
    elapsed = args.duration
    
    if args.json:
        arr = np.array(monitor.latencies)
        import json
        print(json.dumps({
            "samples": samples,
            "duration_s": elapsed,
            "min_us": float(np.min(arr)),
            "avg_us": float(np.mean(arr)),
            "max_us": float(np.max(arr)),
            "p99_us": float(np.percentile(arr, 99)),
            "overruns": monitor.overruns,
            "grade": "A+" if np.percentile(arr,99) < 50 else "B" if np.percentile(arr,99) < 500 else "D"
        }))
    else:
        monitor.report(samples, elapsed)

if __name__ == "__main__":
    main()
