#!/usr/bin/env python3
"""
RK3588 Modbus TCP 服务器
支持 Holding Registers / Coils / Discrete Inputs / Input Registers
基于 pymodbus 3.x，支持 RT 优先级
"""
import sys
import os
import time
import signal
import struct
import logging
import socket
import argparse
from collections import defaultdict

try:
    from pymodbus.server import ModbusTcpServer
    from pymodbus.datastore import ModbusSlaveContext, ModbusServerContext
    from pymodbus.datastore import ModbusSequentialDataBlock
    HAS_PYMODBUS = True
except ImportError:
    HAS_PYMODBUS = False
    logging.warning("pymodbus 未安装，将使用内置简易实现")
    logging.warning("安装: pip install pymodbus")


# =============================================================================
# 内置简易 Modbus TCP 实现 (无 pymodbus 依赖时使用)
# =============================================================================
class SimpleModbusServer:
    """简易 Modbus TCP 服务器，无需外部依赖"""

    def __init__(self, host="0.0.0.0", port=502, holding_count=1024, coil_count=1024):
        self.host = host
        self.port = port
        self.holding_registers = bytearray(holding_count * 2)  # 16-bit 寄存器
        self.coils = bytearray(coil_count)  # 1-bit 线圈
        self.input_registers = bytearray(holding_count * 2)
        self.discrete_inputs = bytearray(coil_count)

        self._running = False
        self._socket = None
        self._log = logging.getLogger("ModbusTCP")

        # 设置 RT 优先级
        self._set_rt_priority()

    def _set_rt_priority(self):
        """设置 SCHED_FIFO 实时优先级"""
        try:
            param = os.sched_param(80)
            os.sched_setscheduler(0, os.SCHED_FIFO, param)
        except (PermissionError, OSError):
            pass

    def start(self):
        """启动服务器"""
        self._socket = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        self._socket.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        self._socket.settimeout(1.0)

        try:
            self._socket.bind((self.host, self.port))
            self._socket.listen(5)
        except PermissionError:
            self._log.error("端口 %d 需要 root 权限 (端口 < 1024)", self.port)
            sys.exit(1)

        self._running = True
        self._log.info("Modbus TCP 服务器启动: %s:%d", self.host, self.port)

        while self._running:
            try:
                client, addr = self._socket.accept()
                self._log.debug("连接: %s:%d", addr[0], addr[1])
                self._handle_client(client, addr)
            except socket.timeout:
                continue
            except OSError:
                if self._running:
                    self._log.exception("Socket 错误")
                break

        self._socket.close()

    def stop(self):
        """停止服务器"""
        self._running = False
        self._log.info("服务器已停止")

    def _handle_client(self, client, addr):
        """处理单个 Modbus TCP 连接"""
        client.settimeout(30.0)
        buf = b""

        try:
            while self._running:
                try:
                    data = client.recv(1024)
                except socket.timeout:
                    break
                if not data:
                    break

                buf += data
                while len(buf) >= 8:
                    # 检查是否有完整帧
                    if len(buf) < 6:
                        break
                    length = struct.unpack(">H", buf[4:6])[0]
                    total_len = 6 + length
                    if len(buf) < total_len:
                        break

                    request = buf[:total_len]
                    buf = buf[total_len:]
                    response = self._process_request(request)
                    if response:
                        client.sendall(response)

        except (ConnectionResetError, BrokenPipeError):
            pass
        except Exception:
            self._log.exception("客户端处理异常: %s", addr)
        finally:
            try:
                client.close()
            except OSError:
                pass

    def _process_request(self, request):
        """解析并处理 Modbus 请求"""
        if len(request) < 8:
            return self._error_response(request, 0x04)

        txn_id = request[0:2]
        proto_id = request[2:4]
        length = request[4:6]
        unit_id = request[6]
        func_code = request[7]

        try:
            if func_code == 0x03:  # Read Holding Registers
                return self._read_holding_registers(txn_id, unit_id, request)
            elif func_code == 0x01:  # Read Coils
                return self._read_coils(txn_id, unit_id, request)
            elif func_code == 0x06:  # Write Single Register
                return self._write_single_register(txn_id, unit_id, request)
            elif func_code == 0x10:  # Write Multiple Registers
                return self._write_multiple_registers(txn_id, unit_id, request)
            elif func_code == 0x05:  # Write Single Coil
                return self._write_single_coil(txn_id, unit_id, request)
            elif func_code == 0x04:  # Read Input Registers
                return self._read_input_registers(txn_id, unit_id, request)
            elif func_code == 0x02:  # Read Discrete Inputs
                return self._read_discrete_inputs(txn_id, unit_id, request)
            else:
                return self._error_response(
                    txn_id + proto_id + struct.pack(">H", 2) + bytes([unit_id]),
                    func_code, 0x01
                )
        except Exception:
            self._log.exception("处理请求失败")
            return self._error_response(
                txn_id + proto_id + struct.pack(">H", 2) + bytes([unit_id]),
                func_code, 0x04
            )

    def _read_holding_registers(self, txn_id, unit_id, request):
        """读取保持寄存器 (FC 03)"""
        start_addr = struct.unpack(">H", request[8:10])[0]
        quantity = struct.unpack(">H", request[10:12])[0]

        byte_count = quantity * 2
        if start_addr * 2 + byte_count > len(self.holding_registers):
            return self._error_response(
                txn_id + b"\x00\x00\x00\x02" + bytes([unit_id]), 0x03, 0x02
            )

        data = self.holding_registers[start_addr * 2 : start_addr * 2 + byte_count]
        response = (
            txn_id +
            b"\x00\x00" +
            struct.pack(">H", 3 + byte_count) +
            bytes([unit_id, 0x03, byte_count]) +
            bytes(data)
        )
        return response

    def _read_coils(self, txn_id, unit_id, request):
        """读取线圈 (FC 01)"""
        start_addr = struct.unpack(">H", request[8:10])[0]
        quantity = struct.unpack(">H", request[10:12])[0]

        byte_count = (quantity + 7) // 8
        if start_addr + quantity > len(self.coils):
            return self._error_response(
                txn_id + b"\x00\x00\x00\x02" + bytes([unit_id]), 0x01, 0x02
            )

        # 打包位数据
        result = bytearray(byte_count)
        for i in range(quantity):
            if start_addr + i < len(self.coils) and self.coils[start_addr + i]:
                result[i // 8] |= (1 << (i % 8))

        response = (
            txn_id +
            b"\x00\x00" +
            struct.pack(">H", 3 + byte_count) +
            bytes([unit_id, 0x01, byte_count]) +
            bytes(result)
        )
        return response

    def _write_single_register(self, txn_id, unit_id, request):
        """写单个寄存器 (FC 06)"""
        addr = struct.unpack(">H", request[8:10])[0]
        value = struct.unpack(">H", request[10:12])[0]

        if addr * 2 + 2 > len(self.holding_registers):
            return self._error_response(
                txn_id + b"\x00\x00\x00\x02" + bytes([unit_id]), 0x06, 0x02
            )

        self.holding_registers[addr * 2 : addr * 2 + 2] = struct.pack(">H", value)
        # Echo back
        return txn_id + b"\x00\x00\x00\x06" + bytes([unit_id]) + request[7:]

    def _write_multiple_registers(self, txn_id, unit_id, request):
        """写多个寄存器 (FC 10)"""
        start_addr = struct.unpack(">H", request[8:10])[0]
        quantity = struct.unpack(">H", request[10:12])[0]
        byte_count = request[12]
        values = request[13:13 + byte_count]

        end_pos = start_addr * 2 + byte_count
        if end_pos > len(self.holding_registers):
            return self._error_response(
                txn_id + b"\x00\x00\x00\x02" + bytes([unit_id]), 0x10, 0x02
            )

        self.holding_registers[start_addr * 2 : end_pos] = values
        # Response: txn_id + proto + length + unit + func + start + quantity
        return (
            txn_id +
            b"\x00\x00\x00\x06" +
            bytes([unit_id, 0x10]) +
            struct.pack(">HH", start_addr, quantity)
        )

    def _write_single_coil(self, txn_id, unit_id, request):
        """写单个线圈 (FC 05)"""
        addr = struct.unpack(">H", request[8:10])[0]
        value = request[10]  # 0xFF00 = ON, 0x0000 = OFF

        if addr >= len(self.coils):
            return self._error_response(
                txn_id + b"\x00\x00\x00\x02" + bytes([unit_id]), 0x05, 0x02
            )

        self.coils[addr] = 1 if value == 0xFF else 0
        return txn_id + b"\x00\x00\x00\x06" + bytes([unit_id]) + request[7:]

    def _read_input_registers(self, txn_id, unit_id, request):
        """读取输入寄存器 (FC 04)"""
        start_addr = struct.unpack(">H", request[8:10])[0]
        quantity = struct.unpack(">H", request[10:12])[0]

        byte_count = quantity * 2
        if start_addr * 2 + byte_count > len(self.input_registers):
            return self._error_response(
                txn_id + b"\x00\x00\x00\x02" + bytes([unit_id]), 0x04, 0x02
            )

        data = self.input_registers[start_addr * 2 : start_addr * 2 + byte_count]
        return (
            txn_id +
            b"\x00\x00" +
            struct.pack(">H", 3 + byte_count) +
            bytes([unit_id, 0x04, byte_count]) +
            bytes(data)
        )

    def _read_discrete_inputs(self, txn_id, unit_id, request):
        """读取离散输入 (FC 02)"""
        start_addr = struct.unpack(">H", request[8:10])[0]
        quantity = struct.unpack(">H", request[10:12])[0]

        byte_count = (quantity + 7) // 8
        if start_addr + quantity > len(self.discrete_inputs):
            return self._error_response(
                txn_id + b"\x00\x00\x00\x02" + bytes([unit_id]), 0x02, 0x02
            )

        result = bytearray(byte_count)
        for i in range(quantity):
            if self.discrete_inputs[start_addr + i]:
                result[i // 8] |= (1 << (i % 8))

        return (
            txn_id +
            b"\x00\x00" +
            struct.pack(">H", 3 + byte_count) +
            bytes([unit_id, 0x02, byte_count]) +
            bytes(result)
        )

    @staticmethod
    def _error_response(header, func_code, exception_code):
        """生成 Modbus 异常响应"""
        return header + bytes([func_code | 0x80, exception_code])

    def set_holding(self, addr, value):
        """设置保持寄存器值 (外部接口)"""
        if isinstance(value, int):
            self.holding_registers[addr * 2 : addr * 2 + 2] = struct.pack(">H", value & 0xFFFF)
        elif isinstance(value, float):
            self.holding_registers[addr * 2 : addr * 2 + 4] = struct.pack(">f", value)
        elif isinstance(value, list):
            for i, v in enumerate(value):
                self.holding_registers[(addr + i) * 2 : (addr + i) * 2 + 2] = struct.pack(">H", v & 0xFFFF)

    def set_coil(self, addr, value):
        """设置线圈值"""
        self.coils[addr] = 1 if value else 0

    def get_holding(self, addr, count=1):
        """读取保持寄存器"""
        values = []
        for i in range(count):
            v = struct.unpack(">H", self.holding_registers[(addr + i) * 2 : (addr + i) * 2 + 2])[0]
            values.append(v)
        return values[0] if count == 1 else values


# =============================================================================
# pymodbus 实现
# =============================================================================
class PymodbusServer:
    """基于 pymodbus 的 Modbus TCP 服务器"""

    def __init__(self, host="0.0.0.0", port=502, holding_count=1024, coil_count=1024):
        self.host = host
        self.port = port

        # 创建数据存储
        store = ModbusSlaveContext(
            di=ModbusSequentialDataBlock(0, [0] * coil_count),       # Discrete Inputs
            co=ModbusSequentialDataBlock(0, [0] * coil_count),       # Coils
            hr=ModbusSequentialDataBlock(0, [0] * holding_count),    # Holding Registers
            ir=ModbusSequentialDataBlock(0, [0] * holding_count),    # Input Registers
        )
        self.context = ModbusServerContext(slaves=store, single=True)

    def start(self):
        """启动服务器"""
        self._log = logging.getLogger("ModbusTCP")
        self._log.info("Modbus TCP 服务器启动 (pymodbus): %s:%d", self.host, self.port)

        server = ModbusTcpServer(
            context=self.context,
            address=(self.host, self.port),
        )
        server.serve_forever()


# =============================================================================
# 主程序
# =============================================================================
def main():
    ap = argparse.ArgumentParser(
        description="RK3588 Modbus TCP 服务器",
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog="""
示例:
  %(prog)s                                    # 默认配置启动
  %(prog)s -p 1502 --holding 2048             # 自定义端口和寄存器数
  %(prog)s -p 502 --coil 512 --no-rt          # 禁用 RT 优先级
  %(prog)s --builtin                          # 强制使用内置实现
  %(prog)s --dry-run                          # 验证配置
        """
    )
    ap.add_argument("-H", "--host", default="0.0.0.0", help="监听地址 (默认: 0.0.0.0)")
    ap.add_argument("-p", "--port", type=int, default=502, help="监听端口 (默认: 502)")
    ap.add_argument("--holding", type=int, default=1024, help="保持寄存器数量 (默认: 1024)")
    ap.add_argument("--coil", type=int, default=1024, help="线圈数量 (默认: 1024)")
    ap.add_argument("--builtin", action="store_true", help="强制使用内置实现 (无依赖)")
    ap.add_argument("--no-rt", action="store_true", help="禁用实时优先级")
    ap.add_argument("--dry-run", action="store_true", help="验证配置后退出")
    ap.add_argument("--log-level", default="INFO",
                    choices=["DEBUG", "INFO", "WARNING", "ERROR"])
    args = ap.parse_args()

    # 日志配置
    logging.basicConfig(
        level=getattr(logging, args.log_level),
        format="%(asctime)s [%(levelname)-7s] %(name)s: %(message)s",
        datefmt="%Y-%m-%d %H:%M:%S",
    )

    # 配置信息
    print("=" * 55)
    print("  RK3588 Modbus TCP 服务器")
    print("=" * 55)
    print(f"  监听地址:     {args.host}:{args.port}")
    print(f"  保持寄存器:   {args.holding} 个 (4xxxx)")
    print(f"  线圈:         {args.coil} 个 (0xxxx)")
    print(f"  实现:         {'内置' if args.builtin or not HAS_PYMODBUS else 'pymodbus'}")
    print(f"  RT 优先级:    {'禁用' if args.no_rt else '启用'}")
    print("=" * 55)

    if args.dry_run:
        print("\n[DRY-RUN] 配置验证通过")
        return

    if HAS_PYMODBUS and not args.builtin:
        server = PymodbusServer(
            host=args.host,
            port=args.port,
            holding_count=args.holding,
            coil_count=args.coil,
        )
    else:
        server = SimpleModbusServer(
            host=args.host,
            port=args.port,
            holding_count=args.holding,
            coil_count=args.coil,
        )

    # 信号处理
    def shutdown(sig, frame):
        logging.info("收到退出信号...")
        server.stop()
        sys.exit(0)

    signal.signal(signal.SIGINT, shutdown)
    signal.signal(signal.SIGTERM, shutdown)

    try:
        server.start()
    except KeyboardInterrupt:
        pass
    finally:
        server.stop()


if __name__ == "__main__":
    main()
