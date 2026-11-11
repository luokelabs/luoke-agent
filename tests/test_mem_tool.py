"""本体起的记忆（luoke-mem，清单 `transport: "stdio"`）连着时：清单有 `reports` 就走记忆自己的 outbox，
记忆这一路（memsource）不再拼卡片，「设置 · 提醒」里换成清单的那几类；「在螺壳记忆里看」能换到窗口里那一条。"""
from __future__ import annotations

import os as _os

assert _os.environ.get("LUOKE_AGENT_TESTING") == "1", "用 python3 -m unittest 跑：tests/__init__.py 先把一切指到临时目录"

import os
import queue
import shutil
import tempfile
import time
import unittest
from unittest import mock

from luoke_agent import a2ui, apps, cards, runner
from luoke_agent.agent import MEMORY_TOOL, Agent
from luoke_agent.toolsource import HubNotReady
from luoke_agent.devdata import make_sample_memory as make_memory
from luoke_agent.items import Item
from luoke_agent.memsource import MemorySource
from luoke_agent.state import State

T0 = 1_800_000_000.0
REPORTS = {"question": {"kind": "question", "title": "记忆想问的事", "urgency": "normal"},
           "suggestion": {"kind": "suggestion", "title": "记忆的建议", "urgency": "normal"}}


class FakeMemTool:
    """本体起的记忆，像 ToolSource 那样是窗口上的一个应用；outbox 里的事由测试给。"""

    source = MEMORY_TOOL
    name = "螺壳记忆"

    def __init__(self, reports=True, pages=("overview", "guesses")):
        self.reports = dict(REPORTS) if reports else {}
        self.service = apps.service({"summary": True, "pages": [{"id": p, "title": p} for p in pages]})
        self.permissions = []
        self.summary = None
        self.perm_states = None
        self.asking = set()
        self.running = True
        self.items = []
        self.polls = 0
        self.acks = []

    def ack(self, it, state):
        self.acks.append((it.key, state))

    def poll(self, now):
        self.polls += 1
        return list(self.items)

    def refresh_app(self, summary=True):
        pass

    def handle(self, it, name, ctx, ua):
        return {"text": "记下了。", "done": True}


def ask_item(n, kind="question"):
    card = cards.Card(f"ask-{n}")
    card.heading("记忆想问你")
    card.buttons(cards.button("对", "mem_reply", {"ask": n, "choice": "yes"}, primary=True))
    return Item(key=f"{MEMORY_TOOL}/ask/{n}", source=MEMORY_TOOL, kind=kind, urgency="normal",
                title="记忆想问：你常用「行云」？", summary="", why_now="", card=card.messages(), extra={"id": f"ask/{n}"})


class MemoryToolTest(unittest.TestCase):
    def setUp(self):
        self.dir = tempfile.mkdtemp(prefix="la")
        self.path = os.path.join(self.dir, "mem.db")
        make_memory(self.path)
        self.state = State(os.path.join(self.dir, "agent"))
        self.opened = []
        self.memory = MemorySource(self.path, self.state, opener=lambda note: self.opened.append(note))
        self.mem_polls = 0
        real = self.memory.poll

        def counted(now):
            self.mem_polls += 1
            return real(now)
        self.memory.poll = counted
        self.agent = Agent(self.state, [self.memory], clock=lambda: T0)

    def tearDown(self):
        self.memory.close()
        self.state.close()
        shutil.rmtree(self.dir, ignore_errors=True)

    def keys(self, prefix):
        return sorted(k for k in self.agent.items if k.startswith(prefix))

    def connect(self, tool):
        """runner 见主控列出记忆时做的：加来源，记下清单 reports 的类名。"""
        for kind, r in tool.reports.items():
            self.agent.labels[f"{MEMORY_TOOL}:{kind}"] = r["title"]
        self.agent.add_source(tool)

    def look_button(self):
        """记忆这一路的卡片上「在螺壳记忆里看」：(卡片, 按钮)"""
        for sid, (_key, surface) in self.agent.surfaces.items():
            for c in surface.components.values():
                if c.get("component") == "Button" and c["action"]["event"]["name"] == "mem.open":
                    return sid, c["id"]
        self.fail("没有「在螺壳记忆里看」")

    def test_the_memorys_own_outbox_takes_over(self):
        self.agent.poll()
        self.assertTrue(self.keys("memory/"), "连上之前照旧由这一路拼卡片")
        self.state.set_setting("modes", {"memory:question": "window", "luoke-scan:malware": "now"})
        tool = FakeMemTool()
        tool.items = [ask_item(1)]
        self.connect(tool)
        polls = self.mem_polls
        self.agent.poll()
        self.assertEqual(self.mem_polls, polls, "记忆自己报了：这一路不再读")
        self.assertEqual(self.keys("memory/"), [], "这一路的卡片撤下")
        self.assertEqual(self.keys(f"{MEMORY_TOOL}/"), [f"{MEMORY_TOOL}/ask/1"])
        self.assertEqual(self.state.setting("modes"), {f"{MEMORY_TOOL}:question": "window", "luoke-scan:malware": "now"},
                         "用户定过的方式搬到清单的那一类")
        kinds = {k["id"]: k for k in self.agent.settings()["kinds"]}
        self.assertNotIn("memory:question", kinds)
        self.assertNotIn("memory:suggestion", kinds)
        self.assertEqual(kinds[f"{MEMORY_TOOL}:question"]["label"], "记忆想问的事")
        self.assertEqual(kinds[f"{MEMORY_TOOL}:question"]["mode"], "window")
        self.assertIn(f"{MEMORY_TOOL}:suggestion", kinds)

    def test_already_set_for_the_tool_stays(self):
        self.state.set_setting("modes", {"memory:question": "window", f"{MEMORY_TOOL}:question": "off"})
        self.connect(FakeMemTool())
        self.agent.poll()
        self.assertEqual(self.state.setting("modes"), {f"{MEMORY_TOOL}:question": "off"})

    def test_down_memory_tool_does_not_bring_this_way_back(self):
        tool = FakeMemTool()
        tool.poll = lambda now: None          # 本体起不来它：窗口说它没在运行
        self.connect(tool)
        self.agent.poll()
        self.assertEqual(self.keys("memory/"), [])
        self.assertIn(MEMORY_TOOL, self.agent.notices)
        self.assertNotIn("memory", self.agent.notices)

    def test_a_memory_without_reports_still_goes_this_way(self):
        self.connect(FakeMemTool(reports=False))
        self.agent.poll()
        self.assertTrue(self.keys("memory/"), "清单没写 reports：照旧由这一路拼卡片")
        self.assertIn("memory:question", {k["id"] for k in self.agent.settings()["kinds"]})

    def test_look_opens_the_memorys_own_ui_until_the_window_can_show_the_note(self):
        self.connect(FakeMemTool(reports=False, pages=("overview", "item")))
        self.agent.poll()
        sid, button = self.look_button()
        with mock.patch.object(a2ui, "A2UI_FEATURES", tuple(f for f in a2ui.A2UI_FEATURES if f != "pageArgs")):
            r = self.agent.tap(sid, button)
        self.assertNotIn("page", r)
        self.assertEqual(len(self.opened), 1, "核心不认 pageArgs：照旧打开记忆自己的界面")

    def test_look_goes_to_the_note_in_the_window(self):
        self.connect(FakeMemTool(reports=False, pages=("overview", "item")))
        self.agent.poll()
        sid, button = self.look_button()
        with mock.patch.object(a2ui, "A2UI_FEATURES", a2ui.A2UI_FEATURES + ("pageArgs",)):
            r = self.agent.tap(sid, button)
        self.assertFalse(r.get("error"), r)
        self.assertEqual({k: r["page"][k] for k in ("app", "page")}, {"app": MEMORY_TOOL, "page": "item"})
        self.assertEqual(self.opened, [], "不再打开记忆自己的界面")

    def test_look_without_an_item_page_opens_the_memorys_own_ui(self):
        self.connect(FakeMemTool(reports=False, pages=("overview",)))
        self.agent.poll()
        sid, button = self.look_button()
        with mock.patch.object(a2ui, "A2UI_FEATURES", a2ui.A2UI_FEATURES + ("pageArgs",)):
            r = self.agent.tap(sid, button)
        self.assertNotIn("page", r)
        self.assertEqual(len(self.opened), 1)


    # ---- 交接：新出现的记忆当轮就读，旧的 memory 那一路要等 5 分钟才轮到（runner.MEMORY_EVERY）

    def same_asks(self):
        """记忆这一路现在列着的事，照样做成记忆自己 outbox 里的（问题编号两路一样）。"""
        return [ask_item(k.rsplit("/", 1)[1], kind=self.agent.items[k].kind) for k in self.keys("memory/")]

    def drain(self, q):
        """到现在为止发给窗口的事件：{种类: [内容]}"""
        out = {}
        while True:
            try:
                e = q.get_nowait()
            except queue.Empty:
                return out
            out.setdefault(e[0], []).append(e[1])

    @staticmethod
    def deleted(ev):
        return [m["deleteSurface"]["surfaceId"] for m in ev.get("a2ui", []) if "deleteSurface" in m]

    def test_memory_showing_up_late_takes_over_that_round(self):
        """主控第一次答 503，几秒后才列出 luoke-mem：当轮就读它，memory 那一路还没到 300 秒。同一件事不会两张卡，
        「马上提醒」的不会再说一遍，用户的提醒方式当轮就搬过去。"""
        self.state.set_setting("quiet", None)
        self.state.set_setting("modes", {"memory:question": "now", "memory:suggestion": "now"})
        q = self.agent.subscribe()
        self.agent.set_presence(0)
        tool = FakeMemTool()
        made = []

        def make_source(accessory, where, **kw):      # runner 照主控的清单接上记忆
            self.assertEqual(accessory, MEMORY_TOOL)
            made.append(tool)
            return tool
        found = [{"accessory": MEMORY_TOOL, "name": "螺壳记忆", "reports": list(REPORTS.values()), "transport": "stdio",
                  "socket": None, "service": {"summary": True, "pages": [{"id": "overview", "title": "概览"}]},
                  "permissions": []}]
        answers = [HubNotReady("hub"), found]

        def discover(*a, **kw):
            got = answers.pop(0) if len(answers) > 1 else answers[0]
            if isinstance(got, Exception):
                raise got
            return got
        t = [100.0]
        r = runner.Runner(self.agent, hub="hub", clock=lambda: t[0], host=object())
        with mock.patch.object(runner, "discover", discover), mock.patch.object(runner, "ToolSource", make_source):
            r.step()                                  # 主控答 503：只有 memory 这一路，列出卡片，马上说了
            old = self.keys("memory/")
            self.assertTrue(old)
            self.assertEqual(made, [])
            self.assertTrue(self.drain(q).get("notify"), "「马上提醒」的说了一次")
            sids = sorted(self.agent.items[k].surface_id() for k in old)
            tool.items = self.same_asks()
            t[0] += 3                                 # 主控几秒后再问：列出 luoke-mem
            polls = self.mem_polls
            r.step()
            self.assertEqual(made, [tool])
            self.assertEqual(tool.polls, 1, "新出现的记忆当轮就读")
            self.assertEqual(self.mem_polls, polls, "memory 那一路还没到 5 分钟，也没再读")
            self.assertEqual(self.keys("memory/"), [], "同一件事不会两张卡：旧路的当轮撤下")
            self.assertEqual(self.keys(f"{MEMORY_TOOL}/"), sorted(f"{MEMORY_TOOL}/" + k[len("memory/"):] for k in old))
            ev = self.drain(q)
            self.assertEqual(ev.get("notify", []), [], "说过的不再说一遍")
            self.assertEqual(self.state.setting("modes"), {f"{MEMORY_TOOL}:question": "now", f"{MEMORY_TOOL}:suggestion": "now"})
            for k in old:
                self.assertEqual(self.state.item(k)["outcome"], "withdrawn")
                self.assertEqual(self.state.item(f"{MEMORY_TOOL}/" + k[len("memory/"):])["status"], "notified")
            self.assertEqual(self.acks(tool, len(old)), sorted((f"{MEMORY_TOOL}/" + k[len("memory/"):], "shown") for k in old),
                             "记忆没听过旧路说的：新编号回一次 shown")
            gone = self.deleted(ev)
            self.assertEqual(sorted(g for g in gone if g.startswith("memory/")), sids, "旧路的卡片当轮撤下")
            t[0] += runner.MEMORY_EVERY               # 轮到 memory 那一路：交接过了，什么都不再动
            r.step()
            ev = self.drain(q)
            self.assertEqual([g for g in self.deleted(ev) if g.startswith("memory/")], [], "旧路的卡片只撤一次")
            self.assertEqual(ev.get("notify", []), [])
            self.assertEqual(self.keys("memory/"), [])
            self.assertEqual(len(tool.acks), len(old), "shown 每件只回一次")

    def test_memory_turn_first_then_the_memorys_own_outbox(self):
        """反过来的顺序（运行中升级了记忆，memory 那一路先轮到）：旧路先撤下，记忆自己的 outbox 列出来时照旧路到的地步，
        还没说过的照常排着。"""
        self.agent.poll()
        old = self.keys("memory/")
        first = old[0]
        self.state.set_status(first, "notified", T0)     # 这一件说过了，别的还排着
        tool = FakeMemTool()
        tool.items = self.same_asks()
        self.connect(tool)
        self.agent.poll(["memory"])
        self.assertEqual(self.keys("memory/"), [])
        self.assertEqual(tool.polls, 0)
        self.agent.poll([MEMORY_TOOL])
        new = lambda k: f"{MEMORY_TOOL}/" + k[len("memory/"):]
        self.assertEqual(self.state.item(new(first))["status"], "notified")
        for k in old[1:]:
            self.assertEqual(self.state.item(new(k))["status"], "queued")
        self.assertEqual(self.acks(tool, 1), [(new(first), "shown")])

    def test_a_note_already_listed_by_the_memory_keeps_its_own_state(self):
        """新编号已经记下的（记忆自己先报过）不被旧路盖掉。"""
        self.agent.poll()
        k = self.keys("memory/")[0]
        n = f"{MEMORY_TOOL}/" + k[len("memory/"):]
        self.state.remember(n, MEMORY_TOOL, "question", "normal", T0)
        self.state.set_status(k, "notified", T0)
        self.assertFalse(self.state.carry(k, n, MEMORY_TOOL))
        self.assertEqual(self.state.item(n)["status"], "queued")

    def acks(self, tool, n):
        """工具收到的回执（ack 在后台线程里发，等一会儿）。"""
        deadline = time.monotonic() + 2
        while len(tool.acks) < n and time.monotonic() < deadline:
            time.sleep(0.01)
        time.sleep(0.05)
        return sorted(tool.acks)

if __name__ == "__main__":
    unittest.main()
