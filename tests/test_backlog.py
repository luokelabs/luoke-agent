"""Unix socket 上一下来十几条连接：都要排得下。

窗口一屏的搜索结果，每格的缩略图各开一条连接、同时连到 agent.sock。socketserver 默认只排 5 条，
macOS 上排不下的 connect 当场 ECONNREFUSED，窗口不重连，那几格就一直是占位框。
（Linux 上排不下的 connect 不拒，是等到超时；这里的测试照样失败，只是报的是 timeout。）
这里先只建好监听、不去接（accept），一口气连 20 条：排得下就都连得上。
"""
from __future__ import annotations

import os
import shutil
import socket
import tempfile
import unittest
from typing import List

from luoke_agent import mcp, ui

BURST = 20   # 比默认的 5 多，比 LISTEN_BACKLOG 少


def burst(path: str, n: int) -> List[str]:
    """连 n 条、先不发东西；答连不上的（错误名），全连上是空的。"""
    errors: List[str] = []
    socks: List[socket.socket] = []
    try:
        for _ in range(n):
            s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
            socks.append(s)
            s.settimeout(2)
            try:
                s.connect(path)
            except OSError as e:
                errors.append(type(e).__name__)
    finally:
        for s in socks:
            s.close()
    return errors


class BacklogTest(unittest.TestCase):
    def setUp(self):
        self.dir = tempfile.mkdtemp(prefix="la")
        self.addCleanup(shutil.rmtree, self.dir, True)
        self.path = os.path.join(self.dir, "s.sock")

    def check(self, server_class, handler) -> None:
        server = server_class(self.path, handler)   # 已经在听，还没人接
        self.addCleanup(server.server_close)
        self.assertGreaterEqual(server.request_queue_size, BURST)
        self.assertEqual(burst(self.path, BURST), [], f"同时 {BURST} 条连接有被拒的")

    def test_ui_socket_takes_a_burst(self):
        self.check(ui._Server, ui._Handler)

    def test_tool_socket_takes_a_burst(self):
        self.check(mcp._UnixServer, mcp._Handler)


if __name__ == "__main__":
    unittest.main()
