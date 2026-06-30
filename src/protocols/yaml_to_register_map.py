#!/usr/bin/env python3
"""
RK3588 YAML 寄存器映射转换器
将 YAML 配置转换为 Modbus/OPC UA 寄存器映射
"""
import sys
import os
import argparse
import logging
from typing import Dict, List, Any, Optional

try:
    import yaml
except ImportError:
    logging.error("PyYAML 未安装。安装: pip install pyyaml")
    sys.exit(1)


# =============================================================================
# 寄存器映射生成器
# =============================================================================
class RegisterMapGenerator:
    """从 YAML 配置生成 Modbus/OPC UA 寄存器映射"""

    def __init__(self, config_path: str):
        with open(config_path, "r", encoding="utf-8") as f:
            self.config = yaml.safe_load(f)

        self.register_map: List[Dict[str, Any]] = []
        self._next_coil = 0
        self._next_holding = 0
        self._next_input = 0
        self._errors: List[str] = []

    def generate(self) -> List[Dict[str, Any]]:
        """生成完整的寄存器映射表"""
        self._validate_config()

        # 处理 coils (离散输出)
        for item in self.config.get("coils", []):
            self._process_coil(item)

        # 处理 holding_registers
        for item in self.config.get("holding_registers", []):
            self._process_holding(item)

        # 处理 input_registers
        for item in self.config.get("input_registers", []):
            self._process_input(item)

        return self.register_map

    def _validate_config(self):
        """验证 YAML 配置基本结构"""
        required_sections = ["coils", "holding_registers", "input_registers"]

        for section in required_sections:
            if section not in self.config:
                self._errors.append(f"缺少配置段: {section}")
                self.config[section] = []

        for i, item in enumerate(self.config.get("coils", [])):
            if "name" not in item:
                self._errors.append(f"coils[{i}]: 缺少 'name' 字段")

        for i, item in enumerate(self.config.get("holding_registers", [])):
            if "name" not in item:
                self._errors.append(f"holding_registers[{i}]: 缺少 'name' 字段")

        for i, item in enumerate(self.config.get("input_registers", [])):
            if "name" not in item:
                self._errors.append(f"input_registers[{i}]: 缺少 'name' 字段")

    def _process_coil(self, item: Dict[str, Any]):
        """处理线圈定义"""
        name = item.get("name", "Unnamed")
        address = item.get("address", self._next_coil)
        count = item.get("count", 1)

        entry = {
            "type": "coil",
            "name": name,
            "address": address,
            "count": count,
            "modbus_addr": f"0{address:04x}",
            "default": item.get("default", False),
            "description": item.get("description", ""),
            "tags": item.get("tags", []),
            "opcua_path": f"IO/{name}",
        }

        self.register_map.append(entry)
        self._next_coil = max(self._next_coil, address + count)

    def _process_holding(self, item: Dict[str, Any]):
        """处理保持寄存器定义"""
        name = item.get("name", "Unnamed")
        address = item.get("address", self._next_holding)
        data_type = item.get("type", "uint16").lower()
        count = self._type_to_count(data_type, item.get("count", 1))

        entry = {
            "type": "holding",
            "name": name,
            "address": address,
            "count": count,
            "data_type": data_type,
            "modbus_addr": f"4{address:04x}",
            "default": item.get("default", 0),
            "unit": item.get("unit", ""),
            "scale": item.get("scale", 1.0),
            "min": item.get("min"),
            "max": item.get("max"),
            "description": item.get("description", ""),
            "tags": item.get("tags", []),
            "opcua_path": f"Variables/{name}",
        }

        self.register_map.append(entry)
        self._next_holding = max(self._next_holding, address + count)

    def _process_input(self, item: Dict[str, Any]):
        """处理输入寄存器定义"""
        name = item.get("name", "Unnamed")
        address = item.get("address", self._next_input)
        data_type = item.get("type", "uint16").lower()
        count = self._type_to_count(data_type, item.get("count", 1))

        entry = {
            "type": "input",
            "name": name,
            "address": address,
            "count": count,
            "data_type": data_type,
            "modbus_addr": f"3{address:04x}",
            "unit": item.get("unit", ""),
            "scale": item.get("scale", 1.0),
            "description": item.get("description", ""),
            "tags": item.get("tags", []),
            "opcua_path": f"Sensors/{name}",
            "readonly": True,
        }

        self.register_map.append(entry)
        self._next_input = max(self._next_input, address + count)

    @staticmethod
    def _type_to_count(data_type: str, count: int) -> int:
        """根据数据类型计算 Modbus 寄存器数量"""
        type_sizes = {
            "bool": 1,
            "uint16": 1,
            "int16": 1,
            "uint32": 2,
            "int32": 2,
            "float32": 2,
            "float64": 4,
            "uint64": 4,
            "int64": 4,
            "string": count,  # count 表示字符串长度
        }
        return type_sizes.get(data_type, 1)

    def get_errors(self) -> List[str]:
        """返回验证错误列表"""
        return self._errors


# =============================================================================
# 输出格式化
# =============================================================================
def output_markdown(register_map: List[Dict], errors: List[str]):
    """输出 Markdown 格式的寄存器映射表"""
    if errors:
        print("## ⚠️ 配置警告\n")
        for err in errors:
            print(f"- {err}")
        print()

    print("## 寄存器映射表\n")
    print("| 地址 | 名称 | 类型 | 长度 | 数据类型 | 默认值 | 说明 |")
    print("|------|------|------|------|----------|--------|------|")

    for entry in register_map:
        print(
            f"| {entry['modbus_addr']} "
            f"| {entry['name']} "
            f"| {entry['type']} "
            f"| {entry['count']} "
            f"| {entry.get('data_type', 'bool')} "
            f"| {entry.get('default', '-')} "
            f"| {entry.get('description', '-')} |"
        )

    # OPC UA 映射
    print("\n## OPC UA 节点映射\n")
    print("| OPC UA 路径 | Modbus 地址 | 变量名 | 类型 |")
    print("|-------------|-------------|--------|------|")

    for entry in register_map:
        print(
            f"| {entry['opcua_path']} "
            f"| {entry['modbus_addr']} "
            f"| {entry['name']} "
            f"| {entry.get('data_type', 'bool')} |"
        )

    # 统计
    coils = [e for e in register_map if e["type"] == "coil"]
    holdings = [e for e in register_map if e["type"] == "holding"]
    inputs = [e for e in register_map if e["type"] == "input"]

    print("\n## 统计\n")
    print(f"- 线圈: {len(coils)} 个, 地址范围 0-{max((c['address'] + c['count']) for c in coils) if coils else 0}")
    print(f"- 保持寄存器: {len(holdings)} 个, 地址范围 0-{max((h['address'] + h['count']) for h in holdings) if holdings else 0}")
    print(f"- 输入寄存器: {len(inputs)} 个, 地址范围 0-{max((i['address'] + i['count']) for i in inputs) if inputs else 0}")
    print(f"- 总计: {len(register_map)} 个映射项")


def output_json(register_map: List[Dict], errors: List[str]):
    """输出 JSON 格式"""
    import json
    output = {
        "register_map": register_map,
        "errors": errors,
        "summary": {
            "total": len(register_map),
            "coils": len([e for e in register_map if e["type"] == "coil"]),
            "holding_registers": len([e for e in register_map if e["type"] == "holding"]),
            "input_registers": len([e for e in register_map if e["type"] == "input"]),
        }
    }
    print(json.dumps(output, indent=2, ensure_ascii=False))


def output_csv(register_map: List[Dict], errors: List[str]):
    """输出 CSV 格式"""
    import csv
    writer = csv.writer(sys.stdout)
    writer.writerow(["type", "name", "address", "count", "data_type", "default", "unit",
                      "scale", "modbus_addr", "opcua_path", "description"])
    for entry in register_map:
        writer.writerow([
            entry["type"],
            entry["name"],
            entry["address"],
            entry["count"],
            entry.get("data_type", "bool"),
            entry.get("default", ""),
            entry.get("unit", ""),
            entry.get("scale", 1.0),
            entry["modbus_addr"],
            entry["opcua_path"],
            entry.get("description", ""),
        ])


# =============================================================================
# 生成默认配置
# =============================================================================
def generate_default_config(output_path: str):
    """生成默认 YAML 配置文件"""
    default = {
        "metadata": {
            "name": "RK3588 Default Register Map",
            "version": "1.0.0",
            "description": "RK3588 工业控制器默认寄存器映射",
        },
        "coils": [
            {"name": "System_Enable",     "address": 0,  "default": False, "description": "系统使能"},
            {"name": "Emergency_Stop",    "address": 1,  "default": False, "description": "急停信号"},
            {"name": "Motor_Run",         "address": 2,  "default": False, "description": "电机运行"},
            {"name": "Motor_Direction",   "address": 3,  "default": False, "description": "电机方向"},
            {"name": "Relay_1",           "address": 4,  "default": False, "description": "继电器1"},
            {"name": "Relay_2",           "address": 5,  "default": False, "description": "继电器2"},
            {"name": "Relay_3",           "address": 6,  "default": False, "description": "继电器3"},
            {"name": "Relay_4",           "address": 7,  "default": False, "description": "继电器4"},
            {"name": "LED_Status",        "address": 8,  "default": False, "description": "状态指示灯"},
            {"name": "LED_Alarm",         "address": 9,  "default": False, "description": "报警指示灯"},
        ],
        "holding_registers": [
            {"name": "Target_Position",   "address": 0,  "type": "int32",  "default": 0,    "unit": "pulse",   "description": "目标位置"},
            {"name": "Target_Speed",      "address": 2,  "type": "uint16", "default": 0,    "unit": "rpm",     "description": "目标转速"},
            {"name": "Acceleration",      "address": 3,  "type": "uint16", "default": 100,  "unit": "rpm/s",   "description": "加速度"},
            {"name": "Deceleration",      "address": 4,  "type": "uint16", "default": 100,  "unit": "rpm/s",   "description": "减速度"},
            {"name": "PID_Kp",            "address": 5,  "type": "float32","default": 1.0,  "scale": 0.001,    "description": "PID 比例系数"},
            {"name": "PID_Ki",            "address": 7,  "type": "float32","default": 0.1,  "scale": 0.001,    "description": "PID 积分系数"},
            {"name": "PID_Kd",            "address": 9,  "type": "float32","default": 0.01, "scale": 0.001,    "description": "PID 微分系数"},
            {"name": "Torque_Limit",      "address": 11, "type": "uint16", "default": 1000, "unit": "0.1%%",   "description": "转矩限制"},
            {"name": "Control_Mode",      "address": 12, "type": "uint16", "default": 0,                        "description": "控制模式 (0=位置 1=速度 2=转矩)"},
            {"name": "Command_Register",  "address": 13, "type": "uint16", "default": 0,                        "description": "命令寄存器"},
        ],
        "input_registers": [
            {"name": "Actual_Position",   "address": 0,  "type": "int32",  "unit": "pulse",   "description": "实际位置"},
            {"name": "Actual_Speed",      "address": 2,  "type": "uint16", "unit": "rpm",     "description": "实际转速"},
            {"name": "Motor_Current",     "address": 3,  "type": "uint16", "unit": "0.1A",    "description": "电机电流"},
            {"name": "Motor_Voltage",     "address": 4,  "type": "uint16", "unit": "0.1V",    "description": "电机电压"},
            {"name": "CPU_Temperature",   "address": 5,  "type": "float32","unit": "°C",       "description": "CPU 温度"},
            {"name": "Board_Temperature", "address": 7,  "type": "float32","unit": "°C",       "description": "板卡温度"},
            {"name": "System_Uptime",     "address": 9,  "type": "uint32", "unit": "s",        "description": "系统运行时间"},
            {"name": "Error_Code",        "address": 11, "type": "uint16",                     "description": "错误代码"},
            {"name": "Status_Register",   "address": 12, "type": "uint16",                     "description": "状态寄存器"},
            {"name": "Digital_Inputs",    "address": 13, "type": "uint16",                     "description": "数字输入 (位映射)"},
            {"name": "Analog_Input_1",    "address": 14, "type": "uint16", "unit": "mV",       "description": "模拟输入通道1"},
            {"name": "Analog_Input_2",    "address": 15, "type": "uint16", "unit": "mV",       "description": "模拟输入通道2"},
        ],
    }

    with open(output_path, "w", encoding="utf-8") as f:
        yaml.dump(default, f, default_flow_style=False, allow_unicode=True, sort_keys=False)

    print(f"默认配置已生成: {output_path}")


# =============================================================================
# 主程序
# =============================================================================
def main():
    ap = argparse.ArgumentParser(
        description="RK3588 YAML 寄存器映射转换器",
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog="""
示例:
  %(prog)s config.yaml                          # 输出 Markdown 映射表
  %(prog)s config.yaml -f json                  # 输出 JSON
  %(prog)s config.yaml -f csv                   # 输出 CSV
  %(prog)s --generate-default register.yaml     # 生成默认配置
        """
    )
    ap.add_argument("config", nargs="?", help="YAML 配置文件路径")
    ap.add_argument("-f", "--format", choices=["markdown", "json", "csv"],
                    default="markdown", help="输出格式 (默认: markdown)")
    ap.add_argument("--generate-default", metavar="PATH",
                    help="生成默认 YAML 配置文件到指定路径")
    ap.add_argument("-o", "--output", help="输出到文件 (默认: stdout)")
    args = ap.parse_args()

    # 生成默认配置
    if args.generate_default:
        generate_default_config(args.generate_default)
        return

    if not args.config:
        ap.print_help()
        sys.exit(1)

    if not os.path.exists(args.config):
        logging.error("配置文件不存在: %s", args.config)
        sys.exit(1)

    # 生成寄存器映射
    generator = RegisterMapGenerator(args.config)
    register_map = generator.generate()
    errors = generator.get_errors()

    # 重定向输出
    if args.output:
        old_stdout = sys.stdout
        sys.stdout = open(args.output, "w", encoding="utf-8")

    try:
        if args.format == "json":
            output_json(register_map, errors)
        elif args.format == "csv":
            output_csv(register_map, errors)
        else:
            output_markdown(register_map, errors)
    finally:
        if args.output:
            sys.stdout.close()
            sys.stdout = old_stdout
            print(f"输出已写入: {args.output}")


if __name__ == "__main__":
    main()
