"""由螺壳本体起的工具：向本体要连接、在上面一条一答（docs/工具协议.md §2a；hostlink.py）。用假的本体和假的工具。"""
from __future__ import annotations

import os as _os

assert _os.environ.get("LUOKE_AGENT_TESTING") == "1", "用 python3 -m unittest 跑：tests/__init__.py 先把一切指到临时目录"

import contextlib
import io
import json
import os
import socket
import sys
import tempfile
import threading
import time
import unittest

from luoke_agent.hostlink import HostLink, exec_opener
from luoke_agent.mcp import NotRunning, ToolClient, ToolServer
from luoke_agent.toolsource import ToolSource, accessories

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))


def make_tool() -> ToolServer:
    s = ToolServer("fake-scan", "1")
    s.resource("luoke://fake-scan/outbox", lambda: {"items": [{"id": "a", "title": "一件事"}]}, name="要报的事")
    s.tool("read_it", lambda a, m: {"text": "读到了"}, title="读", read_only=True)
    return s


def serve_lines(sock: socket.socket, server: ToolServer, before: bytes = b"",
                keep: socket.socket = None) -> None:
    """像 Go 版 `luoke-scan mcp`：一行一条，读到结尾就退出。`before`：回复前先发的东西（比如一条通知）。
    `keep`：本体留着的那一份，工具退出时才关（§2a：交出去就关，macOS 可能把还在路上的 socket 当垃圾收掉）。"""
    with contextlib.ExitStack() as stack:
        if keep is not None:
            stack.enter_context(keep)
        stack.enter_context(sock)
        f = stack.enter_context(sock.makefile("rb"))
        for line in f:
            reply = server.handle(json.loads(line))
            if reply is not None:
                sock.sendall(before + json.dumps(reply, ensure_ascii=False).encode("utf-8") + b"\n")


class FakeHost(threading.Thread):
    """本体那一头：认 `open`，带着的工具起一个「进程」（这里是线程），把连接随回复交过去；别的回 error。"""

    def __init__(self, sock: socket.socket, tools: dict, *, delay_first: float = 0.0, before: bytes = b""):
        super().__init__(daemon=True)
        self.sock = sock
        self.tools = tools
        self.delay_first = delay_first
        self.before = before
        self.opened = 0
        self.served = []

    def run(self) -> None:
        with self.sock.makefile("rb") as f:
            for line in f:
                req = json.loads(line)
                name = req.get("open")
                if self.delay_first and self.opened == 0:
                    time.sleep(self.delay_first)
                self.opened += 1
                if name not in self.tools:
                    self.sock.sendall(json.dumps({"id": req["id"], "error": "螺壳里没带这个工具"}).encode() + b"\n")
                    continue
                mine, theirs = socket.socketpair()
                socket.send_fds(self.sock, [json.dumps({"id": req["id"], "ok": True}).encode() + b"\n"], [mine.fileno()])
                t = threading.Thread(target=serve_lines, args=(theirs, self.tools[name], self.before, mine), daemon=True)
                t.start()
                self.served.append(t)


class HostLinkTest(unittest.TestCase):
    def start(self, **kw) -> HostLink:
        agent_end, host_end = socket.socketpair()
        self.host = FakeHost(host_end, {"fake-scan": make_tool()}, **kw)
        self.host.start()
        self.link = HostLink(agent_end)
        self.addCleanup(self.stop, host_end)
        return self.link

    def stop(self, host_end: socket.socket) -> None:
        """先关 agent 这头：本体读到结尾自己停；等它和起过的工具都收完，再关本体那头（不在别的线程还在读的时候关）"""
        self.link.close()
        self.host.join(5)
        for t in self.host.served:
            t.join(5)
        host_end.close()

    def client(self, link: HostLink) -> ToolClient:
        return ToolClient("stdio:fake-scan", opener=lambda: link.open("fake-scan"))

    def test_open_then_one_request_per_connection(self):
        c = self.client(self.start())
        self.assertEqual(c.discover()["_meta"]["io.modelcontextprotocol/serverInfo"]["name"], "fake-scan")
        self.assertEqual(c.outbox("fake-scan")[0]["title"], "一件事")
        self.assertEqual(c.call_tool("read_it").text, "读到了")
        self.assertEqual(self.host.opened, 3, "每个请求向本体要一次")

    def test_refused_is_not_running(self):
        link = self.start()
        with self.assertRaises(NotRunning) as e:
            link.open("luoke-search")
        self.assertIn("没带", str(e.exception))

    def test_many_threads_at_once(self):
        c = self.client(self.start())
        got, errors = [], []

        def one():
            try:
                got.append(c.call_tool("read_it").text)
            except Exception as e:  # noqa: BLE001
                errors.append(e)
        threads = [threading.Thread(target=one) for _ in range(8)]
        for t in threads:
            t.start()
        for t in threads:
            t.join(10)
        self.assertEqual(errors, [])
        self.assertEqual(got, ["读到了"] * 8)

    def test_host_gone(self):
        agent_end, host_end = socket.socketpair()
        link = HostLink(agent_end)
        self.addCleanup(link.close)
        host_end.close()
        for _ in range(2):      # 断了以后不再试，马上答
            with self.assertRaises(NotRunning):
                link.open("fake-scan")

    def test_late_answer_is_dropped_and_the_next_one_matches(self):
        link = self.start(delay_first=0.5)
        with self.assertRaises(NotRunning):
            link.open("fake-scan", timeout=0.1)      # 本体没答
        conn = link.open("fake-scan")             # 迟到的那条连接关掉，这次拿到的是自己的
        conn.close()

    def test_notification_before_the_answer(self):
        note = json.dumps({"jsonrpc": "2.0", "method": "notifications/message", "params": {}}).encode() + b"\n"
        c = self.client(self.start(before=note))
        self.assertEqual(c.call_tool("read_it").text, "读到了")

    def test_tool_that_exits_without_answering(self):
        def opener():
            mine, theirs = socket.socketpair()
            theirs.close()
            return mine
        with self.assertRaises(NotRunning):
            ToolClient("stdio:x", opener=opener).discover()

    def test_stdin_must_be_a_socket(self):
        r, w = os.pipe()
        self.addCleanup(os.close, r)
        self.addCleanup(os.close, w)
        with self.assertRaises(ValueError):
            HostLink.from_fd(r)


class ExecOpenerTest(unittest.TestCase):
    """开发时没有本体：`--tool 配件=exec:程序` 由核心自己起，每个请求一次。"""

    def test_exec_tool(self):
        d = tempfile.mkdtemp(prefix="la")
        self.addCleanup(lambda: __import__("shutil").rmtree(d, ignore_errors=True))
        script = os.path.join(d, "tool.py")
        with open(script, "w", encoding="utf-8") as f:
            f.write("import json, sys\n"
                    f"sys.path.insert(0, {ROOT!r})\n"
                    "from luoke_agent.mcp import ToolServer\n"
                    "s = ToolServer('fake-scan', '1')\n"
                    "s.tool('read_it', lambda a, m: {'text': '读到了'}, title='读', read_only=True)\n"
                    "for line in sys.stdin:\n"
                    "    r = s.handle(json.loads(line))\n"
                    "    if r is not None:\n"
                    "        sys.stdout.write(json.dumps(r, ensure_ascii=False) + '\\n'); sys.stdout.flush()\n")
        src = ToolSource("fake-scan", "exec:fake-scan", opener=exec_opener([sys.executable, "-I", script]))
        self.assertEqual(src.client.call_tool("read_it").text, "读到了")
        self.assertEqual(src.client.call_tool("read_it").text, "读到了")


class ManifestTest(unittest.TestCase):
    def manifest(self, caps):
        return {"accessories": [{"accessory": "luoke-scan", "name": "螺壳扫描", "capabilities": caps}]}

    def test_stdio_tools_only_with_the_hosts_channel(self):
        caps = {"protocol": 1, "transport": "stdio", "reports": [{"kind": "security", "title": "安全问题"}]}
        got = accessories(self.manifest(caps), home=tempfile.gettempdir(), stdio=True)
        self.assertEqual([(g["accessory"], g["transport"], g["socket"]) for g in got], [("luoke-scan", "stdio", None)])
        err = io.StringIO()
        with contextlib.redirect_stderr(err):
            self.assertEqual(accessories(self.manifest(caps), home=tempfile.gettempdir()), [])
        self.assertIn("本体的通道", err.getvalue())

    def test_stdio_tool_keeps_the_id_rules(self):
        caps = {"protocol": 1, "transport": "stdio"}
        data = {"accessories": [{"accessory": "luoke-core-lab", "capabilities": caps}]}
        with contextlib.redirect_stderr(io.StringIO()):
            self.assertEqual(accessories(data, home=tempfile.gettempdir(), stdio=True), [])


if __name__ == "__main__":
    unittest.main()
