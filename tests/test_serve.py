"""从界面接口走一遍：假的邮件工具 + 临时记忆 → 核心 → 界面协议（SSE、点按、在不在、窗口）。"""
from __future__ import annotations

import os as _os

assert _os.environ.get("LUOKE_AGENT_TESTING") == "1", "用 python3 -m unittest 跑：tests/__init__.py 先把一切指到临时目录"

import argparse
import contextlib
import io
import json
import os
import shutil
import tempfile
import unittest

from luoke_agent import __main__ as cli
from luoke_agent import a2ui
from luoke_agent.agent import Agent
from luoke_agent.fake_tool import FakeMail
from luoke_agent.memsource import MemorySource
from luoke_agent.runner import Runner
from luoke_agent.state import State
from luoke_agent.toolsource import ToolSource
from luoke_agent.ui import UIServer
from tests.test_memsource import make_memory


class ServeTest(unittest.TestCase):
    def setUp(self):
        self.dir = tempfile.mkdtemp(prefix="la")
        self.home = os.path.join(self.dir, "agent")
        mem_path = os.path.join(self.dir, "mem.db")
        self.ids = make_memory(mem_path)
        self.fake = FakeMail()
        tool_sock = os.path.join(self.dir, "t", "agent.sock")
        self.tool_server = self.fake.server().start(tool_sock)
        self.state = State(self.home)
        self.memory = MemorySource(mem_path, self.state, opener=lambda n: None)
        self.agent = Agent(self.state, [self.memory, ToolSource("fake-mail", tool_sock, name="假邮件")],
                           url_opener=lambda u: None)
        self.runner = Runner(self.agent, explicit_tools={"fake-mail"})
        self.ui = UIServer(self.agent, cli.ui_socket(self.home), allow=lambda pid: pid == os.getpid(),
                           on_window=lambda o: o and self.runner.poll_soon()).start()
        self.runner.step()

    def tearDown(self):
        self.ui.close()
        self.tool_server.close()
        self.memory.close()
        self.state.close()
        shutil.rmtree(self.dir, ignore_errors=True)

    def test_feed_tap_undo(self):
        surfaces, info = cli.snapshot(self.home)
        order = info["order"]
        self.assertTrue(order[0].startswith("fake-mail/"), "急事（可疑邮件）在最前")
        self.assertEqual(set(order), set(surfaces))
        for s in surfaces.values():
            s.check()
        plan = next(sid for sid in order if surfaces[sid].data.get("choices", {}).get("rest"))
        out = io.StringIO()
        with contextlib.redirect_stdout(out):
            code = cli.tap(argparse.Namespace(home=self.home, surface=plan, component=self._button(surfaces[plan], "mail_apply_plan"),
                                              set=['/choices/m1=["keep"]']))
        self.assertEqual(code, 0, out.getvalue())
        self.assertIn("归档 5 封", out.getvalue())
        self.assertFalse(self.fake.mails["m1"]["draft"], "第一封选了先不动")
        surfaces, info = cli.snapshot(self.home)
        undo = self._button(surfaces[plan], "mail_undo")
        r = cli._post(self.home, "/action", {"surfaceId": plan, "sourceComponentId": undo, "context": {}})
        self.assertFalse(r["error"], r)
        self.assertTrue(all(m["folder"] == "inbox" for m in self.fake.mails.values()))

    def test_memory_card_through_ui(self):
        surfaces, info = cli.snapshot(self.home)
        sid = next(sid for sid in info["order"] if sid == f"memory/ask-{self.ids['q习惯']}")
        comps = surfaces[sid].components
        yes = next(c for c in a2ui._reachable(comps) if comps[c].get("component") == "Button"
                   and comps[c]["action"]["event"]["context"].get("choice") == "yes")
        r = cli._post(self.home, "/action", {"surfaceId": sid, "sourceComponentId": yes,
                                             "context": {"ask": 12345, "choice": "no"}})
        self.assertFalse(r["error"], "写死的值只认卡片上的：界面送来的 12345、no 不算")
        self.assertEqual(r["text"], "记下了：对。")

    def test_presence_window_status(self):
        self.assertEqual(cli._post(self.home, "/presence", {"idle": 1}), {})
        self.assertEqual(cli._post(self.home, "/window", {"open": True}), {})
        st = self.agent.status()
        self.assertTrue(st["present"])
        self.assertTrue(st["window_open"])
        self.assertEqual(cli._post(self.home, "/say", {"text": "hi"})["text"], "还不能打字问螺壳。")
        bad = cli._post(self.home, "/action", {"surfaceId": 3})
        self.assertIn("error", bad)

    def test_cards_and_settings_over_the_socket(self):
        surfaces, info = cli.snapshot(self.home)
        self.assertEqual([c["id"] for c in info["cards"]], info["order"])
        self.assertEqual(info["cards"][0]["section"], "urgent")
        self.assertEqual(info["cards"][0]["app"], "fake-mail")
        self.assertTrue(any(c["app"] == "memory" and c["section"] == "decide" for c in info["cards"]))
        self.assertEqual(self.agent.status()["api"], 2)
        c = cli._Conn(cli.ui_socket(self.home))
        try:
            c.request("GET", "/settings")
            st = json.loads(c.getresponse().read())
        finally:
            c.close()
        self.assertEqual(st["brief"], "morning", "默认每天早上一份")
        self.assertEqual(st["quiet"], {"start": "22:00", "end": "08:00"})
        self.assertEqual(cli._post(self.home, "/settings", {"brief": "on_open"})["brief"], "on_open")
        self.assertIn("error", cli._post(self.home, "/settings", {"brief": "hourly"}))
        self.assertEqual(self.agent.settings()["brief"], "on_open")

    def _button(self, s: a2ui.Surface, event: str) -> str:
        return next(c for c in a2ui._reachable(s.components) if s.components[c].get("component") == "Button"
                    and s.components[c]["action"]["event"]["name"] == event)


if __name__ == "__main__":
    unittest.main()
