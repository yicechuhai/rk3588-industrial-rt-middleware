#!/usr/bin/env python3
"""
RK3588 延迟分析报告生成器
从 CSV 数据/JSON 结果生成分析报告
支持趋势分析、异常检测、对比报告
"""
import sys
import os
import csv
import json
import argparse
import logging
from datetime import datetime
from collections import defaultdict
from typing import List, Dict, Optional, Tuple

import numpy as np


# =============================================================================
# 数据加载器
# =============================================================================
class DataLoader:
    """从多种格式加载延迟数据"""

    @staticmethod
    def load_csv(path: str) -> np.ndarray:
        """从 CSV 加载延迟数据"""
        latencies = []
        with open(path, 'r') as f:
            reader = csv.DictReader(f)
            for row in reader:
                try:
                    latencies.append(float(row.get("latency_us", 0)))
                except (ValueError, KeyError):
                    continue
        return np.array(latencies)

    @staticmethod
    def load_json(path: str) -> np.ndarray:
        """从 JSON 加载延迟数据 (jitter_monitor.py 输出)"""
        with open(path, 'r') as f:
            data = json.load(f)

        if "raw_samples" in data:
            return np.array(data["raw_samples"])
        # 如果有 histogram_stats 但没有原始数据，返回空
        logging.warning("JSON 文件中没有原始样本数据")
        return np.array([])

    @staticmethod
    def load_multiple(paths: List[str]) -> Dict[str, np.ndarray]:
        """加载多个文件"""
        datasets = {}
        for path in paths:
            name = os.path.basename(path).rsplit(".", 1)[0]
            if path.endswith(".csv"):
                datasets[name] = DataLoader.load_csv(path)
            elif path.endswith(".json"):
                datasets[name] = DataLoader.load_json(path)
            else:
                logging.warning("跳过未知格式: %s", path)
        return datasets


# =============================================================================
# 统计分析器
# =============================================================================
class LatencyAnalyzer:
    """延迟数据分析"""

    def __init__(self, data: np.ndarray, name: str = "dataset"):
        self.data = data
        self.name = name
        self._stats = None

    @property
    def stats(self) -> Dict:
        """计算并缓存统计信息"""
        if self._stats is None:
            self._stats = self._compute_stats()
        return self._stats

    def _compute_stats(self) -> Dict:
        """计算完整统计"""
        if len(self.data) == 0:
            return {"count": 0, "error": "No data"}

        arr = self.data
        percentiles = [50, 75, 90, 95, 99, 99.5, 99.9, 99.99, 100]

        stats = {
            "name": self.name,
            "count": len(arr),
            "min": float(np.min(arr)),
            "max": float(np.max(arr)),
            "mean": float(np.mean(arr)),
            "median": float(np.median(arr)),
            "std": float(np.std(arr)),
            "variance": float(np.var(arr)),
        }

        for p in percentiles:
            stats[f"p{p}"] = float(np.percentile(arr, p))

        # 抖动 (相邻样本差异的标准差)
        if len(arr) > 1:
            jitter = np.abs(np.diff(arr))
            stats["jitter_mean"] = float(np.mean(jitter))
            stats["jitter_max"] = float(np.max(jitter))
            stats["jitter_std"] = float(np.std(jitter))
        else:
            stats["jitter_mean"] = 0
            stats["jitter_max"] = 0
            stats["jitter_std"] = 0

        # 等级
        p99 = stats["p99"]
        if p99 < 50:
            grade, grade_desc = "A+", "硬实时就绪"
        elif p99 < 100:
            grade, grade_desc = "A", "软实时就绪"
        elif p99 < 500:
            grade, grade_desc = "B", "工业控制级"
        elif p99 < 1000:
            grade, grade_desc = "C", "通用自动化"
        else:
            grade, grade_desc = "D", "非实时"
        stats["grade"] = grade
        stats["grade_desc"] = grade_desc

        # 延迟分布区间
        stats["below_10us"] = float(np.sum(arr < 10) / len(arr) * 100)
        stats["below_50us"] = float(np.sum(arr < 50) / len(arr) * 100)
        stats["below_100us"] = float(np.sum(arr < 100) / len(arr) * 100)
        stats["below_500us"] = float(np.sum(arr < 500) / len(arr) * 100)
        stats["below_1000us"] = float(np.sum(arr < 1000) / len(arr) * 100)

        return stats

    def detect_outliers(self, threshold_multiplier: float = 3.0) -> np.ndarray:
        """检测异常值 (基于 IQR 或 Z-Score)"""
        if len(self.data) == 0:
            return np.array([])

        # 使用 IQR 方法
        q1 = np.percentile(self.data, 25)
        q3 = np.percentile(self.data, 75)
        iqr = q3 - q1

        lower = q1 - threshold_multiplier * iqr
        upper = q3 + threshold_multiplier * iqr

        outliers = self.data[(self.data < lower) | (self.data > upper)]
        return outliers

    def trend_analysis(self, window_size: int = 1000) -> Dict:
        """趋势分析 (滑动窗口)"""
        if len(self.data) < window_size:
            return {"error": f"数据不足，需要至少 {window_size} 个样本"}

        arr = self.data
        means = []
        p99s = []
        windows = len(arr) // window_size

        for i in range(windows):
            start = i * window_size
            end = start + window_size
            window = arr[start:end]
            means.append(float(np.mean(window)))
            p99s.append(float(np.percentile(window, 99)))

        # 趋势检测 (简单的线性回归)
        x = np.arange(len(means))
        if len(means) > 1:
            mean_slope = np.polyfit(x, means, 1)[0]
            p99_slope = np.polyfit(x, p99s, 1)[0]
        else:
            mean_slope = 0
            p99_slope = 0

        return {
            "windows": windows,
            "window_size": window_size,
            "mean_trend": "上升" if mean_slope > 0.001 else "下降" if mean_slope < -0.001 else "稳定",
            "mean_slope_us_per_window": float(mean_slope),
            "p99_trend": "上升" if p99_slope > 0.001 else "下降" if p99_slope < -0.001 else "稳定",
            "p99_slope_us_per_window": float(p99_slope),
            "window_means": means,
            "window_p99s": p99s,
        }


# =============================================================================
# 对比分析器
# =============================================================================
class ComparisonAnalyzer:
    """多数据集对比分析"""

    def __init__(self, datasets: Dict[str, np.ndarray]):
        self.analyzers = {
            name: LatencyAnalyzer(data, name)
            for name, data in datasets.items()
        }

    def compare(self) -> Dict:
        """生成对比报告"""
        results = {}

        for name, analyzer in self.analyzers.items():
            results[name] = analyzer.stats

        # 排名
        if len(results) > 1:
            rankings = sorted(
                results.items(),
                key=lambda x: x[1].get("p99", float("inf"))
            )
            for rank, (name, _) in enumerate(rankings, 1):
                results[name]["p99_rank"] = rank

        return results


# =============================================================================
# 报告生成器
# =============================================================================
class ReportGenerator:
    """生成多种格式的分析报告"""

    def __init__(self, analyzer: LatencyAnalyzer):
        self.analyzer = analyzer
        self.stats = analyzer.stats
        self.timestamp = datetime.now()

    def markdown(self) -> str:
        """生成 Markdown 报告"""
        s = self.stats
        lines = [
            f"# RK3588 延迟分析报告",
            f"",
            f"**生成时间**: {self.timestamp.strftime('%Y-%m-%d %H:%M:%S')}",
            f"**数据集**: {s.get('name', 'N/A')}",
            f"",
            f"## 执行摘要",
            f"",
            f"| 指标 | 值 |",
            f"|------|----|",
            f"| 等级 | **{s.get('grade', 'N/A')}** — {s.get('grade_desc', '')} |",
            f"| P99 延迟 | **{s.get('p99', 0):.1f}** us |",
            f"| 最大延迟 | {s.get('max', 0):.1f} us |",
            f"| 平均延迟 | {s.get('mean', 0):.1f} us |",
            f"| 样本数 | {s.get('count', 0)} |",
            f"",
            f"## 详细统计",
            f"",
            f"| 指标 | 值 |",
            f"|------|----|",
            f"| 最小值 | {s.get('min', 0):.1f} us |",
            f"| 最大值 | {s.get('max', 0):.1f} us |",
            f"| 平均值 | {s.get('mean', 0):.1f} us |",
            f"| 中位数 | {s.get('median', 0):.1f} us |",
            f"| 标准差 | {s.get('std', 0):.1f} us |",
            f"| 方差 | {s.get('variance', 0):.1f} us² |",
            f"| P50 | {s.get('p50', 0):.1f} us |",
            f"| P75 | {s.get('p75', 0):.1f} us |",
            f"| P90 | {s.get('p90', 0):.1f} us |",
            f"| P95 | {s.get('p95', 0):.1f} us |",
            f"| P99 | {s.get('p99', 0):.1f} us |",
            f"| P99.5 | {s.get('p99.5', 0):.1f} us |",
            f"| P99.9 | {s.get('p99.9', 0):.1f} us |",
            f"| P99.99 | {s.get('p99.99', 0):.1f} us |",
            f"",
            f"## 抖动分析",
            f"",
            f"| 指标 | 值 |",
            f"|------|----|",
            f"| 平均抖动 | {s.get('jitter_mean', 0):.1f} us |",
            f"| 最大抖动 | {s.get('jitter_max', 0):.1f} us |",
            f"| 抖动标准差 | {s.get('jitter_std', 0):.1f} us |",
            f"",
            f"## 延迟分布",
            f"",
            f"| 阈值 | 样本占比 |",
            f"|------|----------|",
            f"| < 10 us | {s.get('below_10us', 0):.1f}% |",
            f"| < 50 us | {s.get('below_50us', 0):.1f}% |",
            f"| < 100 us | {s.get('below_100us', 0):.1f}% |",
            f"| < 500 us | {s.get('below_500us', 0):.1f}% |",
            f"| < 1000 us | {s.get('below_1000us', 0):.1f}% |",
            f"",
        ]

        # 异常值
        outliers = self.analyzer.detect_outliers()
        if len(outliers) > 0:
            lines.extend([
                f"## 异常值检测 (IQR 方法)",
                f"",
                f"- 异常值数量: {len(outliers)} / {s.get('count', 0)}",
                f"- 异常值占比: {len(outliers) / s.get('count', 1) * 100:.2f}%",
                f"- 最大异常值: {np.max(outliers):.1f} us",
                f"",
            ])

        # 趋势分析
        trend = self.analyzer.trend_analysis()
        if "error" not in trend:
            lines.extend([
                f"## 趋势分析 (窗口: {trend['window_size']} 样本)",
                f"",
                f"- 平均延迟趋势: **{trend['mean_trend']}** ({trend['mean_slope_us_per_window']:+.4f} us/窗口)",
                f"- P99 延迟趋势: **{trend['p99_trend']}** ({trend['p99_slope_us_per_window']:+.4f} us/窗口)",
                f"",
            ])

        # 建议
        lines.extend([
            f"## 优化建议",
            f"",
        ])

        grade = s.get("grade", "")
        if grade in ("D", "C"):
            lines.append("- ⚠️ 建议启用 PREEMPT_RT 内核以获得更低延迟")
        if s.get("below_500us", 100) < 95:
            lines.append("- ⚠️ 5% 以上样本超过 500us，建议检查 IRQ 亲和性")
        if s.get("jitter_max", 0) > 100:
            lines.append("- ⚠️ 抖动较大，建议使用 isolcpus 隔离实时核心")
        if grade in ("A+", "A"):
            lines.append("- ✅ 系统延迟表现优秀，适合硬实时工业应用")
        if not lines[-1].startswith("- ✅") and not lines[-1].startswith("- ⚠️"):
            lines.append("- ℹ️ 当前配置满足基础自动化需求")

        return "\n".join(lines)

    def json_report(self) -> str:
        """生成 JSON 报告"""
        trend = self.analyzer.trend_analysis()
        outliers = self.analyzer.detect_outliers()

        report = {
            "timestamp": self.timestamp.isoformat(),
            "statistics": self.stats,
            "trend_analysis": trend,
            "outliers": {
                "count": len(outliers),
                "percentage": len(outliers) / max(self.stats.get("count", 1), 1) * 100,
                "max_value": float(np.max(outliers)) if len(outliers) > 0 else 0,
            }
        }
        return json.dumps(report, indent=2, ensure_ascii=False)

    def plain_text(self) -> str:
        """生成纯文本报告"""
        s = self.stats
        lines = [
            f"{'='*60}",
            f"  RK3588 延迟分析报告",
            f"{'='*60}",
            f"  生成时间: {self.timestamp.strftime('%Y-%m-%d %H:%M:%S')}",
            f"  数据集:   {s.get('name', 'N/A')}",
            f"",
            f"  等级:     {s.get('grade', 'N/A')} — {s.get('grade_desc', '')}",
            f"",
            f"  样本数:   {s.get('count', 0)}",
            f"  最小值:   {s.get('min', 0):.1f} us",
            f"  平均值:   {s.get('mean', 0):.1f} us",
            f"  中位数:   {s.get('median', 0):.1f} us",
            f"  最大值:   {s.get('max', 0):.1f} us",
            f"  标准差:   {s.get('std', 0):.1f} us",
            f"",
            f"  P50:      {s.get('p50', 0):.1f} us",
            f"  P95:      {s.get('p95', 0):.1f} us",
            f"  P99:      {s.get('p99', 0):.1f} us",
            f"  P99.9:    {s.get('p99.9', 0):.1f} us",
            f"",
            f"  分布:",
            f"    <10us:   {s.get('below_10us', 0):.1f}%",
            f"    <50us:   {s.get('below_50us', 0):.1f}%",
            f"    <100us:  {s.get('below_100us', 0):.1f}%",
            f"    <500us:  {s.get('below_500us', 0):.1f}%",
            f"    <1000us: {s.get('below_1000us', 0):.1f}%",
            f"",
            f"  抖动:",
            f"    平均:    {s.get('jitter_mean', 0):.1f} us",
            f"    最大:    {s.get('jitter_max', 0):.1f} us",
            f"{'='*60}",
        ]
        return "\n".join(lines)


# =============================================================================
# 主程序
# =============================================================================
def main():
    ap = argparse.ArgumentParser(
        description="RK3588 延迟分析报告生成器",
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog="""
示例:
  %(prog)s latency.csv                           # 分析 CSV 数据
  %(prog)s result.json -f markdown               # JSON 数据分析
  %(prog)s run1.csv run2.csv --compare           # 对比多次测试
  %(prog)s latency.csv -f json -o report.json    # 导出 JSON 报告
  %(prog)s latency.csv -f markdown -o README.md  # 导出 Markdown 报告
        """
    )
    ap.add_argument("files", nargs="+", help="数据文件 (CSV 或 JSON)")
    ap.add_argument("-f", "--format", choices=["markdown", "json", "text"],
                    default="markdown", help="输出格式 (默认: markdown)")
    ap.add_argument("-o", "--output", help="输出到文件 (默认: stdout)")
    ap.add_argument("--compare", action="store_true", help="多文件对比模式")
    ap.add_argument("--threshold", type=float, default=3.0,
                    help="异常值检测阈值 (IQR 倍数, 默认: 3.0)")
    ap.add_argument("--window", type=int, default=1000,
                    help="趋势分析窗口大小 (默认: 1000)")
    args = ap.parse_args()

    # 检查文件存在性
    for f in args.files:
        if not os.path.exists(f):
            logging.error("文件不存在: %s", f)
            sys.exit(1)

    if args.compare and len(args.files) > 1:
        # 对比模式
        datasets = DataLoader.load_multiple(args.files)
        comparison = ComparisonAnalyzer(datasets)
        results = comparison.compare()

        if args.format == "json":
            output = json.dumps(results, indent=2, ensure_ascii=False)
        else:
            lines = ["# RK3588 多数据集延迟对比\n"]
            lines.append("| 数据集 | P99 (us) | 最大 (us) | 平均 (us) | 等级 |")
            lines.append("|--------|----------|-----------|-----------|------|")

            for name, stats in results.items():
                lines.append(
                    f"| {name} "
                    f"| {stats.get('p99', 0):.1f} "
                    f"| {stats.get('max', 0):.1f} "
                    f"| {stats.get('mean', 0):.1f} "
                    f"| {stats.get('grade', 'N/A')} |"
                )

            if args.format == "markdown":
                output = "\n".join(lines)
            else:
                output = "\n".join(lines).replace("|", " ").replace("#", "")

    else:
        # 单文件分析
        data = None
        for f in args.files:
            if f.endswith(".csv"):
                data = DataLoader.load_csv(f)
            elif f.endswith(".json"):
                data = DataLoader.load_json(f)

        if data is None or len(data) == 0:
            logging.error("没有有效数据")
            sys.exit(1)

        analyzer = LatencyAnalyzer(data, name=os.path.basename(args.files[0]))
        generator = ReportGenerator(analyzer)

        if args.format == "json":
            output = generator.json_report()
        elif args.format == "text":
            output = generator.plain_text()
        else:
            output = generator.markdown()

    # 输出
    if args.output:
        with open(args.output, "w", encoding="utf-8") as f:
            f.write(output)
        print(f"报告已写入: {args.output}")
    else:
        print(output)


if __name__ == "__main__":
    main()
