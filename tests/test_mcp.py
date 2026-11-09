from __future__ import annotations

import os as _os

assert _os.environ.get("LUOKE_AGENT_TESTING") == "1", "用 python3 -m unittest 跑：tests/__init__.py 先把一切指到临时目录"

import contextlib
import io
import os
import shutil
import socket
import stat
import tempfile
import threading
import unittest

from luoke_agent import mcp
from luoke_agent.mcp import ToolClient, ToolError, ToolServer

UA = {"surfaceId": "s1", "componentId": "ok", "at": "2026-10-15T09:00:00+08:00"}


def rpc(method, params=None, rid=1, meta=None):
    p = dict(params or {})
    p["_meta"] = {mcp.META_VERSION: mcp.PROTOCOL_VERSION, **(meta or {})}
    return {"jsonrpc": "2.0", "id": rid, "method": method, "params": p}


def make_server():
    s = ToolServer("t", "1")
    s.resource("luoke://t/outbox", lambda: {"items": [{"id": "a", "title": "一件事"}]}, name="要报的事")
    s.tool("read_it", lambda a, m: {"text": "读到了", "n": a.get("n")}, title="读")
    s.tool("write_it", lambda a, m: {"text": "做完了", "done": True}, title="写", read_only=False,
           input_schema={"type": "object", "required": ["x"], "properties": {"x": {"type": "string"}}})

    def refuse(a, m):
        raise ToolError("stale", "已经不在了。", card=[{"version": "v0.9"}])

    s.tool("refuse", refuse, title="拒绝")
    s.tool("broken", lambda a, m: 1 / 0, title="坏的")
    return s


class HandleTest(unittest.TestCase):
    def setUp(self):
        self.s = make_server()

    def test_discover(self):
        r = self.s.handle(rpc("server/discover"))["result"]
        self.assertEqual(r["resultType"], "complete")
        self.assertEqual(r["supportedVersions"], [mcp.PROTOCOL_VERSION])
        self.assertIn("tools", r["capabilities"])
        self.assertIn("resources", r["capabilities"])
        self.assertEqual(r["_meta"][mcp.META_SERVER]["name"], "t")

    def test_wrong_version(self):
        msg = rpc("server/discover")
        msg["params"]["_meta"][mcp.META_VERSION] = "2025-06-18"
        err = self.s.handle(msg)["error"]
        self.assertEqual(err["data"]["supportedVersions"], [mcp.PROTOCOL_VERSION])

    def test_bad_requests(self):
        self.assertEqual(self.s.handle([1])["error"]["code"], mcp.INVALID_REQUEST)
        self.assertEqual(self.s.handle({"jsonrpc": "2.0", "id": 1})["error"]["code"], mcp.INVALID_REQUEST)
        self.assertEqual(self.s.handle(rpc("nope"))["error"]["code"], mcp.METHOD_NOT_FOUND)
        self.assertIsNone(self.s.handle({"jsonrpc": "2.0", "method": "notifications/x"}))

    def test_tools_list_annotations(self):
        tools = {t["name"]: t for t in self.s.handle(rpc("tools/list"))["result"]["tools"]}
        self.assertTrue(tools["read_it"]["annotations"]["readOnlyHint"])
        self.assertFalse(tools["write_it"]["annotations"]["readOnlyHint"])

    def test_agent_prefix_reserved(self):
        with self.assertRaises(ValueError):
            self.s.tool("agent.open_url", lambda a, m: {"text": "x"}, title="x")

    def test_read_resource(self):
        r = self.s.handle(rpc("resources/read", {"uri": "luoke://t/outbox"}))["result"]
        self.assertIn("一件事", r["contents"][0]["text"])
        self.assertEqual(self.s.handle(rpc("resources/read", {"uri": "luoke://x"}))["error"]["code"],
                         mcp.RESOURCE_NOT_FOUND)

    def test_write_needs_user_action(self):
        r = self.s.handle(rpc("tools/call", {"name": "write_it", "arguments": {"x": "1"}}))["result"]
        self.assertTrue(r["isError"])
        self.assertEqual(r["structuredContent"]["code"], "needs_user_action")
        r = self.s.handle(rpc("tools/call", {"name": "write_it", "arguments": {"x": "1"}},
                              meta={mcp.USER_ACTION: {"surfaceId": "s1"}}))["result"]
        self.assertTrue(r["isError"], "user-action 缺字段也不算")
        r = self.s.handle(rpc("tools/call", {"name": "write_it", "arguments": {"x": "1"}},
                              meta={mcp.USER_ACTION: UA}))["result"]
        self.assertFalse(r["isError"])
        self.assertEqual(r["content"][0]["text"], "做完了")
        self.assertTrue(r["structuredContent"]["done"])

    def test_missing_argument(self):
        r = self.s.handle(rpc("tools/call", {"name": "write_it", "arguments": {}},
                              meta={mcp.USER_ACTION: UA}))["result"]
        self.assertEqual(r["structuredContent"]["code"], "invalid")

    def test_tool_error_and_crash(self):
        r = self.s.handle(rpc("tools/call", {"name": "refuse"}))["result"]
        self.assertTrue(r["isError"])
        self.assertEqual(r["structuredContent"]["code"], "stale")
        self.assertEqual(r["content"][0]["text"], "已经不在了。")
        self.assertEqual(self.s.handle(rpc("tools/call", {"name": "broken"}))["error"]["code"], mcp.INTERNAL_ERROR)
        self.assertEqual(self.s.handle(rpc("tools/call", {"name": "nope"}))["error"]["code"], mcp.INVALID_PARAMS)

    def test_crash_goes_to_the_tools_log_without_content(self):
        """工具内部的错：agent 只拿到「工具内部出错」，工具的 stderr 记下哪个方法、什么类型、在哪一行，不记错误信息（可能带着内容）"""
        def outbox():
            raise ValueError("王老师的信：答辩改到周五")
        self.s.resource("luoke://t/bad", outbox, name="坏的待办")
        for params, which in (({"name": "broken"}, "tools/call broken"), ({"uri": "luoke://t/bad"}, "resources/read luoke://t/bad")):
            method = which.split()[0]
            err = io.StringIO()
            with contextlib.redirect_stderr(err):
                r = self.s.handle(rpc(method, params))
            self.assertEqual(r["error"], {"code": mcp.INTERNAL_ERROR, "message": "工具内部出错"})
            log = err.getvalue()
            self.assertIn(f"t: {which} 出错", log)
            self.assertIn("test_mcp.py:", log)
            self.assertNotIn("王老师", log)
        self.assertIn("ValueError", log)
        # 对不上登记的名字时只写方法，不把 agent 送来的字符串写进日志
        self.assertEqual(self.s._which("tools/call", {"name": "王老师"}), "tools/call")


class SocketTest(unittest.TestCase):
    def setUp(self):
        self.dir = tempfile.mkdtemp(prefix="la")
        self.path = os.path.join(self.dir, "run", "agent.sock")

    def tearDown(self):
        shutil.rmtree(self.dir, ignore_errors=True)

    def test_round_trip_and_cleanup(self):
        server = make_server().start(self.path)
        try:
            self.assertEqual(stat.S_IMODE(os.stat(os.path.dirname(self.path)).st_mode), 0o700)
            self.assertEqual(stat.S_IMODE(os.lstat(self.path).st_mode), 0o600)
            c = ToolClient(self.path, client_version="test")
            self.assertEqual(c.discover()["_meta"][mcp.META_SERVER]["name"], "t")
            self.assertEqual(c.outbox("t"), [{"id": "a", "title": "一件事"}])
            r = c.call_tool("read_it", {"n": 3})
            self.assertEqual((r.text, r.structured, r.is_error), ("读到了", {"n": 3}, False))
            self.assertTrue(c.call_tool("write_it", {"x": "1"}).is_error)
            r = c.call_tool("write_it", {"x": "1"}, user_action=UA)
            self.assertFalse(r.is_error)
            self.assertTrue(r.done)
            r = c.call_tool("refuse")
            self.assertEqual((r.code, r.card), ("stale", [{"version": "v0.9"}]))
            with self.assertRaises(mcp.RpcError):
                c.call_tool("broken")
        finally:
            server.close()
        self.assertFalse(os.path.exists(self.path))

    def test_not_running(self):
        c = ToolClient(self.path)
        with self.assertRaises(mcp.NotRunning):
            c.discover()
        # 上次没删掉的 socket 文件：连不上，也算没在运行
        os.makedirs(os.path.dirname(self.path))
        stale = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        stale.bind(self.path)
        stale.close()
        with self.assertRaises(mcp.NotRunning):
            c.discover()
        server = make_server().start(self.path)  # 没人在听的旧 socket 被换掉
        try:
            self.assertEqual(c.discover()["supportedVersions"], [mcp.PROTOCOL_VERSION])
            with self.assertRaises(RuntimeError):
                make_server().start(self.path)  # 已经有人在服务
        finally:
            server.close()

    def test_refuses_non_socket(self):
        os.makedirs(os.path.dirname(self.path))
        open(self.path, "w").close()
        with self.assertRaises(RuntimeError):
            make_server().start(self.path)

    def test_write_timeout_is_timed_out(self):
        release = threading.Event()
        s = ToolServer("slow", "1")
        s.tool("slow_write", lambda a, m: (release.wait(5), {"text": "好了"})[1], title="慢", read_only=False)
        s.start(self.path)
        try:
            with self.assertRaises(mcp.TimedOut):
                ToolClient(self.path).call_tool("slow_write", user_action=UA, timeout=0.3)
        finally:
            release.set()
            s.close()


if __name__ == "__main__":
    unittest.main()
