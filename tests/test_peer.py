"""agent.sock 只认起核心的那个进程（ui.py）：别的进程答 403；`serve --dev` 才认本账户的任何进程，`--tool`、`tap` 也只在那时管用。"""
from __future__ import annotations

import os as _os

assert _os.environ.get("LUOKE_AGENT_TESTING") == "1", "用 python3 -m unittest 跑：tests/__init__.py 先把一切指到临时目录"

import json
import os
import shutil
import socket
import subprocess
import sys
import tempfile
import time
import unittest
from typing import List, Optional

from luoke_agent import __main__ as cli
from luoke_agent import ui
from luoke_agent.agent import Agent
from luoke_agent.state import State

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))

# 在另一个进程里连 agent.sock，打印答复的状态码（连不上打印 0）
OTHER = """
import http.client, socket, sys
s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
s.settimeout(10)
s.connect(sys.argv[1])
c = http.client.HTTPConnection("localhost")
c.sock = s
try:
    c.request(sys.argv[2], sys.argv[3], body=sys.argv[4].encode() if len(sys.argv) > 4 else None,
              headers={"Content-Type": "application/json"})
    r = c.getresponse()
    print(r.status, r.read().decode())
except (OSError, http.client.HTTPException):
    print(0)
"""


def from_other_process(sock: str, method: str = "GET", path: str = "/status", body: Optional[dict] = None) -> int:
    args = [sys.executable, "-I", "-c", OTHER, sock, method, path] + ([json.dumps(body)] if body is not None else [])
    out = subprocess.run(args, capture_output=True, text=True, timeout=30)
    return int(out.stdout.split()[0])


def from_here(sock: str, path: str = "/status") -> int:
    c = cli._Conn(sock)
    try:
        c.request("GET", path)
        r = c.getresponse()
        r.read()
        return r.status
    finally:
        c.close()


class PeerTest(unittest.TestCase):
    def setUp(self):
        self.dir = tempfile.mkdtemp(prefix="la")
        self.home = os.path.join(self.dir, "agent")

    def tearDown(self):
        shutil.rmtree(self.dir, ignore_errors=True)

    def test_peer_pid(self):
        a, b = socket.socketpair(socket.AF_UNIX, socket.SOCK_STREAM)
        try:
            self.assertEqual(ui.peer_pid(a), os.getpid())
        finally:
            a.close()
            b.close()

    def test_launcher_only(self):
        parent = os.getppid()
        self.assertTrue(ui.launcher_only(parent)(parent))
        self.assertFalse(ui.launcher_only(parent)(os.getpid()), "别的进程")
        self.assertFalse(ui.launcher_only(parent)(None), "取不到进程号")
        self.assertFalse(ui.launcher_only(os.getpid())(os.getpid()), "不是核心的父进程（起它的那个已经没了）")

    def test_server_refuses_other_processes(self):
        state = State(self.home)
        self.addCleanup(state.close)
        agent = Agent(state, [])
        server = ui.UIServer(agent, cli.ui_socket(self.home), allow=lambda pid: pid == os.getpid()).start()
        self.addCleanup(server.close)
        sock = cli.ui_socket(self.home)
        self.assertEqual(from_here(sock), 200)
        for method, path, body in (("GET", "/status", None), ("GET", "/feed", None),
                                   ("POST", "/action", {"surfaceId": "x", "sourceComponentId": "y"}),
                                   ("POST", "/presence", {"idle": 9999, "locked": True}),
                                   ("POST", "/window", {"open": True})):
            with self.subTest(path=path):
                self.assertEqual(from_other_process(sock, method, path, body), 403)
        self.assertIsNone(agent.presence, "冒充的「不在 Mac 前」没进来")
        self.assertFalse(agent.window_open)
        self.assertEqual(from_here(sock), 200, "认的进程照旧连得上")

    def test_dev_server_takes_anyone(self):
        state = State(self.home)
        self.addCleanup(state.close)
        server = ui.UIServer(Agent(state, []), cli.ui_socket(self.home), allow=ui.anyone).start()
        self.addCleanup(server.close)
        self.assertEqual(from_other_process(cli.ui_socket(self.home)), 200)


class ServePeerTest(unittest.TestCase):
    """真起一个核心（这个测试进程就是起它的那个）。"""

    def setUp(self):
        self.dir = tempfile.mkdtemp(prefix="la")
        self.home = os.path.join(self.dir, "agent")
        os.makedirs(self.home)
        self.procs: List[subprocess.Popen] = []

    def tearDown(self):
        for p in self.procs:
            if p.poll() is None:
                p.terminate()
                try:
                    p.wait(10)
                except subprocess.TimeoutExpired:
                    p.kill()
                    p.wait()
            if p.stderr:
                p.stderr.close()
        shutil.rmtree(self.dir, ignore_errors=True)

    def serve(self, *extra: str) -> subprocess.Popen:
        p = subprocess.Popen([sys.executable, "-B", "-m", "luoke_agent", "serve", "--home", self.home,
                              "--memory", os.path.join(self.dir, "mem.db"), *extra],
                             cwd=ROOT, stdout=subprocess.DEVNULL, stderr=subprocess.PIPE, text=True)
        self.procs.append(p)
        sock = cli.ui_socket(self.home)
        deadline = time.monotonic() + 20
        while time.monotonic() < deadline and p.poll() is None:
            if os.path.exists(sock):
                try:
                    from_here(sock)
                    return p
                except OSError:
                    pass
            time.sleep(0.1)
        self.fail(f"核心没起来：{p.poll()}")

    def run_cli(self, *args: str) -> subprocess.CompletedProcess:
        return subprocess.run([sys.executable, "-B", "-m", "luoke_agent", *args], cwd=ROOT, capture_output=True, text=True,
                              timeout=30)

    def test_only_the_launcher(self):
        self.serve("--parent-pid", str(os.getpid()))
        sock = cli.ui_socket(self.home)
        self.assertEqual(from_here(sock), 200, "起核心的进程")
        self.assertEqual(from_other_process(sock), 403, "本账户里别的进程")
        tap = self.run_cli("tap", "--home", self.home, "x", "y")
        self.assertNotEqual(tap.returncode, 0)
        self.assertIn("--dev", tap.stderr, "不经界面的点按只对开发模式的核心管用")
        for args in (("feed", "--home", self.home), ("presence", "--home", self.home, "--idle", "9999"),
                     ("window", "--home", self.home, "open")):
            with self.subTest(cmd=args[0]):
                self.assertNotEqual(self.run_cli(*args).returncode, 0)

    def test_without_parent_pid_the_parent_is_the_launcher(self):
        self.serve()
        sock = cli.ui_socket(self.home)
        self.assertEqual(from_here(sock), 200)
        self.assertEqual(from_other_process(sock), 403)

    def test_dev_takes_anyone(self):
        self.serve("--dev")
        sock = cli.ui_socket(self.home)
        self.assertEqual(from_other_process(sock), 200)
        feed = self.run_cli("feed", "--home", self.home)
        self.assertEqual(feed.returncode, 0, feed.stderr)
        tap = self.run_cli("tap", "--home", self.home, "nope", "b")
        self.assertIn("没有这张卡片", tap.stderr, "连上了，只是没有这张卡片")

    def test_tool_needs_dev_and_a_usable_id(self):
        tool = os.path.join(self.dir, "t", "agent.sock")
        os.makedirs(os.path.dirname(tool))
        r = self.run_cli("serve", "--home", self.home, "--memory", os.path.join(self.dir, "mem.db"), "--tool", f"fake-mail={tool}")
        self.assertNotEqual(r.returncode, 0)
        self.assertIn("--dev", r.stderr)
        r = self.run_cli("serve", "--dev", "--home", self.home, "--memory", os.path.join(self.dir, "mem.db"),
                         "--tool", f"memory={tool}")
        self.assertNotEqual(r.returncode, 0)
        self.assertIn("agent 自己用的", r.stderr)
        self.assertFalse(os.path.exists(cli.ui_socket(self.home)), "没起来")


if __name__ == "__main__":
    unittest.main()
