#!/usr/bin/env python3
"""QMP 操作工具（无网络依赖，仅标准库）

用法:
  qmp-tool.py SOCK shot FILE.png     截图
  qmp-tool.py SOCK status            查询运行状态
  qmp-tool.py SOCK type 'text'       逐字输入文本（支持大小写/常见符号）
  qmp-tool.py SOCK key ret           发送组合键，如 ret / ctrl-alt-f1 / shift-y
  qmp-tool.py SOCK tablet            热插入 USB 平板指针（绝对坐标点击前需要）
  qmp-tool.py SOCK click X Y [W H]   单击屏幕像素坐标（默认分辨率 1280x800）
  qmp-tool.py SOCK dclick X Y [W H]  双击
  qmp-tool.py SOCK powerdown          ACPI 关机（等待系统关闭）
  qmp-tool.py SOCK quit              立即终止 QEMU
"""
import json
import socket
import sys
import time

SYMBOLS = {
    " ": "spc", "-": "minus", "=": "equal", "[": "leftbracket", "]": "rightbracket",
    ";": "semicolon", "'": "apostrophe", ",": "comma", ".": "dot", "/": "slash",
    "\\": "backslash", "`": "grave_accent", "\n": "ret", "\t": "tab",
    ":": ("shift", "semicolon"), "_": ("shift", "minus"), "+": ("shift", "equal"),
    "!": ("shift", "1"), "@": ("shift", "2"), "#": ("shift", "3"), "$": ("shift", "4"),
    "%": ("shift", "5"), "^": ("shift", "6"), "&": ("shift", "7"), "*": ("shift", "8"),
    "(": ("shift", "9"), ")": ("shift", "0"), "~": ("shift", "grave_accent"),
    "{": ("shift", "leftbracket"), "}": ("shift", "rightbracket"), "|": ("shift", "backslash"),
    '"': ("shift", "apostrophe"), "<": ("shift", "comma"), ">": ("shift", "dot"),
    "?": ("shift", "slash"),
}


class Qmp:
    def __init__(self, path):
        self.sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        self.sock.connect(path)
        self.f = self.sock.makefile("r")
        self._read()  # greeting
        self.cmd("qmp_capabilities")

    def _read(self):
        while True:
            line = self.f.readline()
            if not line:
                raise ConnectionError("QMP 连接断开")
            msg = json.loads(line)
            if "event" not in msg:
                return msg

    def cmd(self, execute, arguments=None):
        req = {"execute": execute}
        if arguments:
            req["arguments"] = arguments
        self.sock.sendall((json.dumps(req) + "\n").encode())
        resp = self._read()
        if "error" in resp:
            raise RuntimeError(f"{execute}: {resp['error']}")
        return resp.get("return")

    def send_key(self, qcodes):
        self.cmd("send-key", {"keys": [{"type": "qcode", "data": q} for q in qcodes]})

    def click(self, x, y, w=1280, h=800, double=False):
        ax, ay = int(x * 32767 / w), int(y * 32767 / h)
        self.cmd("input-send-event", {"events": [
            {"type": "abs", "data": {"axis": "x", "value": ax}},
            {"type": "abs", "data": {"axis": "y", "value": ay}},
        ]})
        time.sleep(0.2)
        for _ in range(2 if double else 1):
            self.cmd("input-send-event", {"events": [
                {"type": "btn", "data": {"button": "left", "down": True}}]})
            time.sleep(0.12)
            self.cmd("input-send-event", {"events": [
                {"type": "btn", "data": {"button": "left", "down": False}}]})
            time.sleep(0.25)

    def type_text(self, text):
        for ch in text:
            if ch.isascii() and ch.isalpha():
                q = ch.lower()
                self.send_key(["shift", q] if ch.isupper() else [q])
            elif ch.isdigit():
                self.send_key([ch])
            elif ch in SYMBOLS:
                v = SYMBOLS[ch]
                self.send_key(list(v) if isinstance(v, tuple) else [v])
            else:
                raise ValueError(f"无法输入的字符: {ch!r}")
            time.sleep(0.03)

    def close(self):
        self.sock.close()


def main():
    if len(sys.argv) < 3:
        print(__doc__)
        sys.exit(1)
    sock, action = sys.argv[1], sys.argv[2]
    q = Qmp(sock)
    try:
        if action == "shot":
            q.cmd("screendump", {"filename": sys.argv[3], "format": "png"})
            print(f"已截图: {sys.argv[3]}")
        elif action == "status":
            print(q.cmd("query-status"))
        elif action == "type":
            q.type_text(sys.argv[3])
            print(f"已输入 {len(sys.argv[3])} 个字符")
        elif action == "key":
            q.send_key(sys.argv[3].split("-"))
            print(f"已发送按键: {sys.argv[3]}")
        elif action == "tablet":
            try:
                q.cmd("device_add", {"driver": "usb-tablet", "id": "tablet0"})
                print("已热插入 usb-tablet")
            except RuntimeError as e:
                print(f"usb-tablet 已存在或不可用: {e}")
        elif action in ("click", "dclick"):
            args = [int(v) for v in sys.argv[3:7]]
            q.click(*args, double=(action == "dclick"))
            print(f"已{'双' if action == 'dclick' else '单'}击: {args[:2]}")
        elif action == "powerdown":
            q.cmd("system_powerdown")
            print("已发送 ACPI 关机请求")
        elif action == "quit":
            q.cmd("quit")
            print("QEMU 已终止")
        else:
            print(__doc__)
            sys.exit(1)
    finally:
        q.close()


if __name__ == "__main__":
    main()