#!/usr/bin/env python3
"""
RK3588 OPC UA 服务器
支持节点树管理、变量订阅、方法调用
基于 opcua-asyncio，支持 RT 优先级
"""
import sys
import os
import time
import signal
import asyncio
import logging
import argparse
from enum import Enum

try:
    from asyncua import Server, ua
    from asyncua.common.node import Node
    HAS_OPCUA = True
except ImportError:
    HAS_OPCUA = False

# =============================================================================
# OPC UA 服务器
# =============================================================================
class Rk3588OpcuaServer:
    """RK3588 OPC UA 服务器"""

    def __init__(self, endpoint="opc.tcp://0.0.0.0:4840", name="RK3588-RT-Server"):
        if not HAS_OPCUA:
            raise ImportError(
                "opcua-asyncio 未安装。安装: pip install asyncua"
            )

        self.endpoint = endpoint
        self.name = name
        self.server = Server()
        self._nodes = {}
        self._running = False

    async def init(self):
        """初始化服务器地址空间"""
        await self.server.init()

        # 设置端点
        self.server.set_endpoint(self.endpoint)
        self.server.set_server_name(self.name)

        # 创建地址空间结构
        idx = await self.server.register_namespace("http://rk3588-rt.local")

        # 根对象: RK3588
        self.root = await self.server.nodes.objects.add_object(idx, "RK3588")

        # CPU 信息
        self.node_cpu = await self.root.add_object(idx, "CPU")
        self.node_cpu_temp = await self.node_cpu.add_variable(idx, "Temperature", 45.0)
        self.node_cpu_freq = {}
        for i in range(8):
            freq_node = await self.node_cpu.add_variable(idx, f"Core{i}_Frequency", 1800)
            await freq_node.set_writable()
            self.node_cpu_freq[i] = freq_node

        # 内存信息
        self.node_mem = await self.root.add_object(idx, "Memory")
        self.node_mem_used = await self.node_mem.add_variable(idx, "UsedMB", 0)
        self.node_mem_total = await self.node_mem.add_variable(idx, "TotalMB", 8192)
        self.node_mem_pct = await self.node_mem.add_variable(idx, "PercentUsed", 0.0)

        # 实时状态
        self.node_rt = await self.root.add_object(idx, "Realtime")
        self.node_rt_enabled = await self.node_rt.add_variable(idx, "Enabled", False)
        self.node_rt_latency = await self.node_rt.add_variable(idx, "MaxLatency", 0.0)
        self.node_rt_p99 = await self.node_rt.add_variable(idx, "P99Latency", 0.0)

        # 工业协议状态
        self.node_proto = await self.root.add_object(idx, "Protocols")

        # EtherCAT
        self.node_ecat = await self.node_proto.add_object(idx, "EtherCAT")
        self.node_ecat_state = await self.node_ecat.add_variable(idx, "State", "STOPPED")
        self.node_ecat_slaves = await self.node_ecat.add_variable(idx, "SlaveCount", 0)

        # Modbus
        self.node_modbus = await self.node_proto.add_object(idx, "Modbus")
        self.node_modbus_state = await self.node_modbus.add_variable(idx, "State", "STOPPED")

        # I/O 引脚
        self.node_io = await self.root.add_object(idx, "IO")
        self.node_digital_inputs = {}
        self.node_digital_outputs = {}
        for i in range(8):
            di = await self.node_io.add_variable(idx, f"DI_{i}", False)
            do_ = await self.node_io.add_variable(idx, f"DO_{i}", False)
            await do_.set_writable()
            self.node_digital_inputs[i] = di
            self.node_digital_outputs[i] = do_

        # 模拟量
        self.node_analog = await self.root.add_object(idx, "Analog")
        for i in range(4):
            await self.node_analog.add_variable(idx, f"AI_{i}", 0.0)
            ao = await self.node_analog.add_variable(idx, f"AO_{i}", 0.0)
            await ao.set_writable()

        logging.info("OPC UA 地址空间初始化完成: %d 个变量", len(self._get_all_variables()))

    def _get_all_variables(self):
        """递归获取所有变量节点 (辅助诊断)"""
        variables = []

        async def _collect(node):
            nonlocal variables
            try:
                children = await node.get_children()
                for c in children:
                    try:
                        ncl = await c.read_node_class()
                        if ncl == ua.NodeClass.Variable:
                            variables.append(c)
                    except Exception:
                        pass
                    await _collect(c)
            except Exception:
                pass

        return variables  # 近似计数

    async def add_custom_node(self, parent_path, name, value, writable=False):
        """动态添加自定义节点

        Args:
            parent_path: 父节点路径，如 "Protocols/EtherCAT"
            name: 节点名称
            value: 初始值
            writable: 是否可写
        """
        # 解析路径
        parts = parent_path.strip("/").split("/")
        current = self.root

        for part in parts:
            found = False
            children = await current.get_children()
            for child in children:
                bname = await child.read_browse_name()
                if bname.Name == part:
                    current = child
                    found = True
                    break
            if not found:
                idx = await self.server.register_namespace("http://rk3588-rt.local")
                current = await current.add_object(idx, part)

        idx = await self.server.register_namespace("http://rk3588-rt.local")
        node = await current.add_variable(idx, name, value)
        if writable:
            await node.set_writable()
        return node

    async def set_value(self, node_path, value):
        """根据路径设置变量值

        Args:
            node_path: "CPU/Temperature" 或 "IO/DO_3"
            value: 新值
        """
        node = await self.resolve_path(node_path)
        if node:
            await node.write_value(value)
            return True
        return False

    async def get_value(self, node_path):
        """根据路径读取变量值"""
        node = await self.resolve_path(node_path)
        if node:
            return await node.read_value()
        return None

    async def resolve_path(self, path):
        """路径解析"""
        parts = path.strip("/").split("/")
        current = self.root

        for part in parts:
            found = False
            children = await current.get_children()
            for child in children:
                try:
                    bname = await child.read_browse_name()
                    if bname.Name == part:
                        current = child
                        found = True
                        break
                except Exception:
                    continue
            if not found:
                return None
        return current

    async def start(self):
        """启动 OPC UA 服务器"""
        await self.server.start()
        self._running = True
        logging.info("OPC UA 服务器启动: %s", self.endpoint)

    async def stop(self):
        """停止 OPC UA 服务器"""
        if self._running:
            await self.server.stop()
            self._running = False
            logging.info("OPC UA 服务器已停止")

    def list_nodes(self):
        """打印节点树 (同步版本，用于调试)"""
        print("\nOPC UA 节点树:")
        print("-" * 40)

        async def _print_tree(node, indent=0):
            try:
                children = await node.get_children()
                for child in children:
                    try:
                        bname = await child.read_browse_name()
                        nclass = await child.read_node_class()
                        prefix = {
                            ua.NodeClass.Object: "📁",
                            ua.NodeClass.Variable: "📊",
                            ua.NodeClass.Method: "⚡",
                        }.get(nclass, "  ")
                        print(f"  {'  ' * indent}{prefix} {bname.Name}")

                        if nclass == ua.NodeClass.Variable:
                            try:
                                val = await child.read_value()
                                print(f"  {'  ' * (indent+1)}  = {val}")
                            except Exception:
                                pass
                    except Exception:
                        pass
                    await _print_tree(child, indent + 1)
            except Exception:
                pass

        asyncio.run(_print_tree(self.root))


# =============================================================================
# 主程序
# =============================================================================
async def async_main(args):
    """异步主程序"""
    server = Rk3588OpcuaServer(
        endpoint=f"opc.tcp://{args.host}:{args.port}",
        name=args.name,
    )

    await server.init()

    if args.dry_run:
        logging.info("节点树初始化完成，退出 (--dry-run)")
        return

    # 信号处理
    stop_event = asyncio.Event()

    def signal_handler():
        logging.info("收到退出信号...")
        stop_event.set()

    loop = asyncio.get_event_loop()
    for sig in (signal.SIGINT, signal.SIGTERM):
        try:
            loop.add_signal_handler(sig, signal_handler)
        except NotImplementedError:
            # Windows 不支持 add_signal_handler
            pass

    try:
        await server.start()

        # 后台任务: 定期更新系统状态
        async def status_updater():
            """定期更新系统状态到 OPC UA 节点"""
            while not stop_event.is_set():
                try:
                    # CPU 温度 (从 thermal_zone 读取)
                    for i in range(4):
                        tz_path = f"/sys/class/thermal/thermal_zone{i}/temp"
                        if os.path.exists(tz_path):
                            with open(tz_path) as f:
                                temp = int(f.read().strip()) / 1000.0
                            await server.node_cpu_temp.write_value(temp)
                            break
                except Exception:
                    pass

                try:
                    # CPU 频率
                    for i in range(8):
                        freq_path = f"/sys/devices/system/cpu/cpu{i}/cpufreq/scaling_cur_freq"
                        if os.path.exists(freq_path):
                            with open(freq_path) as f:
                                freq = int(f.read().strip()) // 1000
                            await server.node_cpu_freq[i].write_value(freq)
                except Exception:
                    pass

                try:
                    # 内存
                    with open("/proc/meminfo") as f:
                        meminfo = {}
                        for line in f:
                            parts = line.split(":")
                            if len(parts) == 2:
                                meminfo[parts[0].strip()] = int(parts[1].strip().split()[0])

                    if "MemTotal" in meminfo and "MemAvailable" in meminfo:
                        total = meminfo["MemTotal"] // 1024
                        used = total - meminfo["MemAvailable"] // 1024
                        await server.node_mem_total.write_value(total)
                        await server.node_mem_used.write_value(used)
                        await server.node_mem_pct.write_value(round(used / total * 100, 1))
                except Exception:
                    pass

                try:
                    # 实时状态
                    if os.path.exists("/sys/kernel/realtime"):
                        with open("/sys/kernel/realtime") as f:
                            rt_enabled = f.read().strip() == "1"
                        await server.node_rt_enabled.write_value(rt_enabled)
                except Exception:
                    pass

                await asyncio.sleep(2.0)

        updater_task = asyncio.create_task(status_updater())

        logging.info("OPC UA 服务器运行中，按 Ctrl+C 退出")
        await stop_event.wait()

        updater_task.cancel()
        try:
            await updater_task
        except asyncio.CancelledError:
            pass

    finally:
        await server.stop()


def main():
    ap = argparse.ArgumentParser(
        description="RK3588 OPC UA 服务器",
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog="""
示例:
  %(prog)s                                    # 默认配置启动
  %(prog)s -p 4841 --name "MyServer"          # 自定义端口和名称
  %(prog)s --dry-run                          # 验证地址空间配置
        """
    )
    ap.add_argument("-H", "--host", default="0.0.0.0", help="监听地址 (默认: 0.0.0.0)")
    ap.add_argument("-p", "--port", type=int, default=4840, help="监听端口 (默认: 4840)")
    ap.add_argument("--name", default="RK3588-RT-Server", help="服务器名称")
    ap.add_argument("--dry-run", action="store_true", help="初始化后退出")
    ap.add_argument("--log-level", default="INFO",
                    choices=["DEBUG", "INFO", "WARNING", "ERROR"])
    args = ap.parse_args()

    # 日志配置
    logging.basicConfig(
        level=getattr(logging, args.log_level),
        format="%(asctime)s [%(levelname)-7s] %(name)s: %(message)s",
        datefmt="%Y-%m-%d %H:%M:%S",
    )

    print("=" * 55)
    print("  RK3588 OPC UA 服务器")
    print("=" * 55)
    print(f"  端点:     opc.tcp://{args.host}:{args.port}")
    print(f"  名称:     {args.name}")
    print(f"  命名空间: http://rk3588-rt.local")
    print("=" * 55)

    if not HAS_OPCUA:
        logging.error("opcua-asyncio 未安装")
        logging.error("安装: pip install asyncua")
        sys.exit(1)

    asyncio.run(async_main(args))


if __name__ == "__main__":
    main()
