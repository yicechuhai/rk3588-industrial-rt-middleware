#!/usr/bin/env python3
"""
RK3588 Latency Jitter Monitor
Measures scheduling latency with microsecond precision.
Drop-in replacement for cyclictest on ARM64.
增强功能: Histogram 统计、CSV 导出、实时图表
"""
import time, sys, os, signal, threading, csv, io
import numpy as np
from collections import deque
from datetime import datetime

HIST_SIZE = 100000
INTERVAL_US = 1000  # 1ms between measurements
DURATION_S = 60     # Default 60s test

class JitterMonitor:
    def __init__(self, interval_us=1000, duration_s=60, rt_priority=80,
                 histogram_bins=50, csv_file=None, chart_interval=1.0):
        self.interval_us = interval_us
        self.duration_s = duration_s
        self.rt_priority = rt_priority
        self.latencies = deque(maxlen=HIST_SIZE)
        self.running = True
        self.overruns = 0

        # 增强功能
        self.histogram_bins = histogram_bins
        self.csv_file = csv_file
        self._csv_writer = None
        self._csv_fh = None
        self.chart_interval = chart_interval  # 图表刷新间隔（秒）
        self._last_chart_time = 0
        self._sample_timestamps = deque(maxlen=HIST_SIZE)

    def set_rt_priority(self):
        try:
            param = os.sched_param(self.rt_priority)
            os.sched_setscheduler(0, os.SCHED_FIFO, param)
            print(f"RT priority set to {self.rt_priority} (SCHED_FIFO)")
        except PermissionError:
            print("WARNING: Cannot set RT priority (run with sudo for accurate results)")

    def _init_csv(self):
        """初始化 CSV 导出"""
        if not self.csv_file:
            return
        self._csv_fh = open(self.csv_file, 'w', newline='')
        self._csv_writer = csv.writer(self._csv_fh)
        self._csv_writer.writerow([
            "sample_id", "timestamp_ns", "latency_us",
            "interval_us", "overrun"
        ])

    def _write_csv_row(self, sample_id: int, timestamp_ns: int, latency_us: float):
        """写入 CSV 行"""
        if self._csv_writer:
            self._csv_writer.writerow([
                sample_id, timestamp_ns, f"{latency_us:.1f}",
                self.interval_us, 1 if self.overruns > 0 else 0
            ])

    def _close_csv(self):
        """关闭 CSV 文件"""
        if self._csv_fh:
            self._csv_fh.close()
            self._csv_fh = None
            self._csv_writer = None

    def measure(self):
        self.set_rt_priority()
        self._init_csv()

        period_ns = self.interval_us * 1000
        next_wake = time.monotonic_ns()

        t_start = time.time()
        samples = 0
        self._last_chart_time = t_start

        while self.running and (time.time() - t_start) < self.duration_s:
            # Calculate next wake time
            next_wake += period_ns

            # Busy-wait until target time
            now = time.monotonic_ns()
            was_overrun = False
            if now > next_wake:
                self.overruns += 1
                next_wake = now
                was_overrun = True

            # Record latency (how late we are)
            actual = time.monotonic_ns()
            latency_us = (actual - next_wake) / 1000.0

            self.latencies.append(latency_us)
            self._sample_timestamps.append(actual)
            samples += 1

            # CSV 导出
            self._write_csv_row(samples, actual, latency_us)

            # Print periodic status
            if samples % 5000 == 0:
                self.print_status(samples, time.time() - t_start)

            # 实时 ASCII 图表
            if self.chart_interval > 0:
                now_s = time.time()
                if now_s - self._last_chart_time >= self.chart_interval:
                    self._print_realtime_chart(samples, now_s - t_start)
                    self._last_chart_time = now_s

        self._close_csv()
        return samples

    def print_status(self, samples, elapsed):
        arr = np.array(self.latencies)
        print(f"\r[{elapsed:5.1f}s] Samples:{samples:6d} | "
              f"Min:{np.min(arr):6.1f}us Avg:{np.mean(arr):6.1f}us "
              f"Max:{np.max(arr):6.1f}us P99:{np.percentile(arr,99):6.1f}us "
              f"Overruns:{self.overruns}", end='')
        sys.stdout.flush()

    def _print_realtime_chart(self, samples, elapsed):
        """打印实时 ASCII 延迟图表"""
        arr = np.array(self.latencies)
        if len(arr) < 10:
            return

        # 只显示最近的一批样本
        recent = list(arr)[-100:]
        if not recent:
            return

        max_val = max(max(recent), 1)
        min_val = min(recent)
        p99 = np.percentile(arr, 99)

        # 终端宽度
        try:
            term_width = os.get_terminal_size().columns
        except (OSError, ValueError):
            term_width = 80

        chart_width = min(term_width - 30, 60)
        if chart_width < 20:
            return

        scale = chart_width / max_val if max_val > 0 else 1

        # 构建柱状图
        lines = []
        lines.append(f"\n{'─' * (chart_width + 26)}")
        lines.append(f" 实时延迟 | 最近100样本 [Min:{min_val:.1f} Avg:{np.mean(recent):.1f} Max:{max(recent):.1f} P99:{p99:.1f}]us")

        # 显示最近的样本
        step = max(1, len(recent) // chart_width)
        sampled_points = recent[::step][:chart_width]

        bar_line = "         |"
        for v in sampled_points:
            bar_len = min(int(v * scale), chart_width)
            if bar_len == 0 and v > 0:
                bar_len = 1

            # 根据延迟大小着色提示
            if v < 50:
                bar_line += "\033[32m█\033[0m"  # 绿色: <50us
            elif v < 100:
                bar_line += "\033[33m█\033[0m"  # 黄色: <100us
            elif v < 500:
                bar_line += "\033[36m█\033[0m"  # 青色: <500us
            elif v < 1000:
                bar_line += "\033[35m█\033[0m"  # 紫色: <1ms
            else:
                bar_line += "\033[31m█\033[0m"  # 红色: >=1ms

        lines.append(bar_line)

        # 添加参考线
        ref_line = "         |"
        for _ in range(chart_width):
            ref_line += "─"
        lines.append(ref_line)

        # P99 线
        p99_pos = min(int(p99 * scale), chart_width - 1)
        p99_line = "         |" + " " * p99_pos + "\033[31m▲ P99\033[0m"
        lines.append(p99_line)

        lines.append(f"{'─' * (chart_width + 26)}")

        # 清屏并打印
        sys.stdout.write("\033[2K\033[F" * (len(lines) + 1))  # 清除之前的内容
        for line in lines:
            sys.stdout.write("\033[2K" + line + "\n")
        sys.stdout.flush()

    def compute_histogram(self, bins=None):
        """计算延迟直方图统计"""
        arr = np.array(self.latencies)
        if len(arr) == 0:
            return [], [], {}

        if bins is None:
            bins = self.histogram_bins

        hist, bin_edges = np.histogram(arr, bins=bins)

        # 计算统计摘要
        stats = {
            "count": len(arr),
            "min": float(np.min(arr)),
            "max": float(np.max(arr)),
            "mean": float(np.mean(arr)),
            "median": float(np.median(arr)),
            "std": float(np.std(arr)),
            "p50": float(np.percentile(arr, 50)),
            "p90": float(np.percentile(arr, 90)),
            "p95": float(np.percentile(arr, 95)),
            "p99": float(np.percentile(arr, 99)),
            "p99_9": float(np.percentile(arr, 99.9)),
            "p99_99": float(np.percentile(arr, 99.99)),
            "overruns": self.overruns,
        }

        # 计算等级
        p99 = stats["p99"]
        if p99 < 50:
            stats["grade"] = "A+"
            stats["grade_desc"] = "硬实时就绪 (Hard Real-Time Ready)"
        elif p99 < 100:
            stats["grade"] = "A"
            stats["grade_desc"] = "软实时就绪 (Soft Real-Time Ready)"
        elif p99 < 500:
            stats["grade"] = "B"
            stats["grade_desc"] = "工业控制级 (Industrial Control Grade)"
        elif p99 < 1000:
            stats["grade"] = "C"
            stats["grade_desc"] = "通用自动化 (General Automation)"
        else:
            stats["grade"] = "D"
            stats["grade_desc"] = "非实时 — 建议启用 PREEMPT_RT"

        return hist.tolist(), bin_edges.tolist(), stats

    def print_histogram(self, bins=None):
        """打印延迟直方图"""
        hist, bin_edges, stats = self.compute_histogram(bins)

        if not hist:
            print("无数据")
            return

        max_count = max(hist) if hist else 1
        bar_width = 40

        print(f"\n{'='*70}")
        print(f"  延迟分布直方图 (Latency Histogram)")
        print(f"{'='*70}")
        print(f"  {'延迟范围 (us)':<22} {'计数':<10} {'占比':<8} 分布")
        print(f"  {'-'*22} {'-'*10} {'-'*8} {'-'*bar_width}")

        total = stats["count"]
        for i, (count, left, right) in enumerate(zip(hist, bin_edges[:-1], bin_edges[1:])):
            pct = count / total * 100 if total > 0 else 0
            bar_len = int(count / max_count * bar_width) if max_count > 0 else 0
            bar = "█" * bar_len

            range_str = f"[{left:6.1f} - {right:6.1f}]"
            print(f"  {range_str:<22} {count:<10} {pct:5.1f}%   {bar}")

        print(f"{'='*70}")

        # 统计摘要
        print(f"\n  统计摘要:")
        print(f"    样本数:    {stats['count']}")
        print(f"    最小值:    {stats['min']:8.1f} us")
        print(f"    平均值:    {stats['mean']:8.1f} us")
        print(f"    中位数:    {stats['median']:8.1f} us")
        print(f"    标准差:    {stats['std']:8.1f} us")
        print(f"    最大值:    {stats['max']:8.1f} us")
        print(f"    P50:       {stats['p50']:8.1f} us")
        print(f"    P90:       {stats['p90']:8.1f} us")
        print(f"    P95:       {stats['p95']:8.1f} us")
        print(f"    P99:       {stats['p99']:8.1f} us")
        print(f"    P99.9:     {stats['p99_9']:8.1f} us")
        print(f"    P99.99:    {stats['p99_99']:8.1f} us")
        print(f"    Overruns:  {stats['overruns']}")
        print(f"    等级:      {stats['grade']} ({stats['grade_desc']})")

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

        # CSV 导出提示
        if self.csv_file:
            print(f"  CSV:           {self.csv_file}")

        print(f"{'='*60}\n")

        # 打印直方图
        self.print_histogram()

    def export_histogram_csv(self, path: str):
        """导出直方图数据到 CSV"""
        hist, bin_edges, stats = self.compute_histogram()
        if not hist:
            return

        with open(path, 'w', newline='') as f:
            w = csv.writer(f)
            w.writerow(["bin_start_us", "bin_end_us", "count", "percentage"])
            total = stats["count"]
            for i, (count, left, right) in enumerate(zip(hist, bin_edges[:-1], bin_edges[1:])):
                w.writerow([
                    f"{left:.1f}", f"{right:.1f}",
                    count, f"{count/total*100:.2f}" if total > 0 else "0"
                ])

            # 附加统计摘要
            w.writerow([])
            w.writerow(["# Statistics"])
            for k, v in stats.items():
                w.writerow([f"# {k}", v])

        print(f"直方图数据已导出: {path}")


def main():
    import argparse
    ap = argparse.ArgumentParser(description="RK3588 Jitter Monitor")
    ap.add_argument("-i", "--interval", type=int, default=1000, help="采样间隔 (us, 默认: 1000)")
    ap.add_argument("-d", "--duration", type=int, default=60, help="测试时长 (s, 默认: 60)")
    ap.add_argument("-p", "--priority", type=int, default=80, help="RT 优先级 (1-99, 默认: 80)")
    ap.add_argument("--json", action="store_true", help="输出 JSON 格式")
    ap.add_argument("--csv", metavar="FILE", help="导出原始数据到 CSV 文件")
    ap.add_argument("--histogram-csv", metavar="FILE", help="导出直方图数据到 CSV 文件")
    ap.add_argument("--histogram", action="store_true", default=True,
                    help="打印延迟直方图 (默认: 启用)")
    ap.add_argument("--no-histogram", action="store_true", help="禁用直方图")
    ap.add_argument("--histogram-bins", type=int, default=50, help="直方图分桶数 (默认: 50)")
    ap.add_argument("--chart", action="store_true", default=True,
                    help="显示实时 ASCII 图表 (默认: 启用)")
    ap.add_argument("--no-chart", action="store_true", help="禁用实时图表")
    args = ap.parse_args()

    chart_interval = 1.0 if args.chart and not args.no_chart else 0

    monitor = JitterMonitor(
        interval_us=args.interval,
        duration_s=args.duration,
        rt_priority=args.priority,
        histogram_bins=args.histogram_bins,
        csv_file=args.csv,
        chart_interval=chart_interval,
    )

    samples = monitor.measure()
    elapsed = args.duration

    if args.json:
        arr = np.array(monitor.latencies)
        import json
        _, _, stats = monitor.compute_histogram()
        output = {
            "samples": samples,
            "duration_s": elapsed,
            "min_us": float(np.min(arr)),
            "avg_us": float(np.mean(arr)),
            "max_us": float(np.max(arr)),
            "p99_us": float(np.percentile(arr, 99)),
            "overruns": monitor.overruns,
            "grade": stats.get("grade", "N/A"),
            "histogram_stats": stats,
        }
        print(json.dumps(output, indent=2))
    else:
        monitor.report(samples, elapsed)

    # 导出直方图 CSV
    if args.histogram_csv:
        monitor.export_histogram_csv(args.histogram_csv)

    # CSV 导出提示
    if args.csv:
        print(f"原始数据已导出: {args.csv}")


if __name__ == "__main__":
    main()
