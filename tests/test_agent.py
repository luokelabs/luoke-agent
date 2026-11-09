"""挑时机、合并、点按（DESIGN §5），用假时钟和假来源。"""
from __future__ import annotations

import os as _os

assert _os.environ.get("LUOKE_AGENT_TESTING") == "1", "用 python3 -m unittest 跑：tests/__init__.py 先把一切指到临时目录"

import datetime as dt
import os
import queue
import shutil
import tempfile
import time
import unittest

from luoke_agent import a2ui, cards
from luoke_agent.agent import Agent
from luoke_agent.items import Item
from luoke_agent.memsource import MemorySource, load_luoke_mem
from luoke_agent.state import State

T0 = 1_800_000_000.0
HOUR = 3600.0


class Clock:
    def __init__(self):
        self.t = T0

    def __call__(self):
        return self.t


def item(key, urgency="normal", kind="new-mail", source="tool", **kw):
    sid = key.replace("/", "-")
    card = cards.plan_card(sid, f"卡片 {key}", [{"key": "m1", "label": "一封信", "options": [("archive", "归档"), ("keep", "先不动")],
                                               "selected": "archive"}], apply_event="mail_apply_plan", plan_id=f"plan-{sid}",
                           extra_buttons=[cards.open_url_button("加入日程", "https://calendar.google.com/x?a=1")])
    return Item(key=f"{source}/{key}", source=source, kind=kind, urgency=urgency, title=f"标题 {key}", summary="",
                why_now="为什么", card=card, extra={"id": key}, **kw)


class FakeSource:
    def __init__(self, name="tool"):
        self.source = name
        self.name = "假工具"
        self.items = []
        self.running = True
        self.calls = []
        self.acks = []

    def poll(self, now):
        return list(self.items) if self.running else None

    def handle(self, it, name, ctx, ua):
        self.calls.append((it.key, name, ctx, ua))
        sid = it.card[0]["createSurface"]["surfaceId"]
        if name == "mail_undo":
            return {"text": "已撤销。", "done": True, "card": cards.result_card(sid, "已撤销。")}
        return {"text": "已归档 1 封。", "done": True,
                "card": cards.result_card(sid, "已归档 1 封。", undo_event="mail_undo", undo_context={"execution_id": "e1"})}

    def ack(self, it, state):
        self.acks.append((it.key, state))


class _Base(unittest.TestCase):
    """假时钟、假来源；测试在下面几个子类里。"""

    def setUp(self):
        self.dir = tempfile.mkdtemp(prefix="la")
        self.state = State(os.path.join(self.dir, "agent"))
        self.clock = Clock()
        self.src = FakeSource()
        self.opened = []
        self.state.set_setting("brief", "every")    # 这一组照「攒满一小时」测；按时刻的在 BriefScheduleTest
        self.state.set_setting("quiet", None)
        self.agent = Agent(self.state, [self.src], clock=self.clock, url_opener=self.opened.append)
        self.q = self.agent.subscribe()

    def tearDown(self):
        self.state.close()
        shutil.rmtree(self.dir, ignore_errors=True)

    def events(self, kind=None):
        out = []
        while True:
            try:
                e = self.q.get_nowait()
            except queue.Empty:
                return out
            if kind is None or e[0] == kind:
                out.append(e[1])

    def acks(self, state, want=None):
        """工具收到的回执（ack 在后台线程里发，等一会儿）。"""
        deadline = time.monotonic() + 2
        while True:
            got = sorted(k for k, st in self.src.acks if st == state)
            if want is None or got == want or time.monotonic() > deadline:
                if want is None:
                    time.sleep(0.05)
                    got = sorted(k for k, st in self.src.acks if st == state)
                return got
            time.sleep(0.01)

    def present(self, yes=True):
        self.agent.set_presence(0 if yes else 3600)

    def at(self, seconds):
        self.clock.t = T0 + seconds
        self.agent.tick()


class AgentTest(_Base):
    def test_urgent_waits_for_user_then_says_now(self):
        self.src.items = [item("bad", urgency="urgent", kind="suspicious")]
        self.agent.poll()
        self.agent.tick()
        self.assertEqual(self.events("notify"), [], "不知道用户在不在：不说")
        self.present(False)
        self.assertEqual(self.events("notify"), [])
        self.present(True)
        n = self.events("notify")
        self.assertEqual(len(n), 1)
        self.assertTrue(n[0]["urgent"])
        self.assertEqual(n[0]["surfaceId"], "tool/bad")
        self.agent.tick()
        self.assertEqual(self.events("notify"), [], "只说一次")

    def test_urgent_ones_together_are_one_notification(self):
        self.src.items = [item("v1", urgency="urgent", kind="security"), item("v2", urgency="urgent", kind="security")]
        self.agent.poll()
        self.present()
        n = self.events("notify")
        self.assertEqual(len(n), 1, "同一时刻的两件急事只打断一次")
        self.assertEqual(n[0]["title"], "2 件急事")
        self.assertIn("标题 v1", n[0]["body"])
        self.assertTrue(n[0]["urgent"])
        self.agent.tick()
        self.assertEqual(self.events("notify"), [])

    def test_brief_after_an_hour(self):
        self.present()
        self.src.items = [item("a")]
        self.agent.poll()
        self.at(1)
        self.assertEqual(self.events("notify"), [])
        self.assertAlmostEqual(self.state.meta("brief_due"), T0 + 1 + HOUR)
        self.src.items.append(item("b"))
        self.agent.poll()
        self.at(HOUR - 60)
        self.present()
        self.assertEqual(self.events("notify"), [])
        self.at(HOUR + 2)
        self.present()
        n = self.events("notify")
        self.assertEqual(len(n), 1)
        self.assertEqual(n[0]["title"], "2 件事")
        self.assertFalse(n[0]["silent"])
        self.assertIsNone(self.state.meta("brief_due"))
        # 下一件进来，重新计时；上一份没打开，这份不响
        self.src.items.append(item("c"))
        self.agent.poll()
        self.at(HOUR + 10)
        self.at(2 * HOUR + 20)
        self.present()
        n = self.events("notify")
        self.assertEqual((len(n), n[0]["title"], n[0]["silent"]), (1, "1 件事", True))

    def test_brief_body_is_one_templated_sentence(self):
        self.present()
        self.src.items = [item("a"), item("b"), item("bad", urgency="urgent", kind="suspicious"),
                          item("clean", urgency="low", kind="auto-done")]
        self.agent.poll()
        self.present()
        self.assertEqual([n["title"] for n in self.events("notify")], ["标题 bad"])
        self.at(1)
        self.at(HOUR + 2)
        self.present()
        n = self.events("notify")
        self.assertEqual(len(n), 1)
        self.assertEqual(n[0]["body"], "还有 2 件等你：标题 a、标题 b；急事：标题 bad；替你做了 1 件。")
        self.assertEqual(n[0]["title"], "4 件事", "件数和正文说的对得上")

    def test_brief_leaves_out_urgent_the_user_turned_off(self):
        """这一类急事关了提醒（off）或只在窗口里看（window）：锁屏的简报里不提，件数也不算。"""
        for i, mode in enumerate(("off", "window")):
            with self.subTest(mode=mode):
                if i:
                    self.tearDown()
                    self.setUp()
                self.state.set_setting("modes", {"tool:suspicious": mode})
                self.present()
                self.src.items = [item("a"), item("bad", urgency="urgent", kind="suspicious"),
                                  item("clean", urgency="low", kind="auto-done")]
                self.agent.poll()
                self.present()
                self.at(1)
                self.at(HOUR + 2)
                self.present()
                n = self.events("notify")
                self.assertEqual(len(n), 1)
                self.assertEqual(n[0]["body"], "还有 1 件等你：标题 a；替你做了 1 件。")
                self.assertEqual(n[0]["title"], "2 件事")

    def test_brief_body_names_three_and_says_how_many(self):
        self.present()
        self.src.items = [item(k) for k in "abcd"]
        self.agent.poll()
        self.at(1)
        self.at(HOUR + 2)
        self.present()
        n = self.events("notify")
        self.assertEqual(n[0]["body"], "还有 4 件等你：标题 a、标题 b、标题 c等。")
        self.assertEqual(n[0]["title"], "4 件事")

    def test_brief_body_drops_trailing_question_marks(self):
        self.present()
        a, b = item("a"), item("b")
        a.title, b.title = "在准备答辩？", "要不要续租！"
        self.src.items = [a, b]
        self.agent.poll()
        self.at(1)
        self.at(HOUR + 2)
        self.present()
        self.assertEqual(self.events("notify")[0]["body"], "还有 2 件等你：在准备答辩、要不要续租。")

    def test_tells_the_tool_what_was_shown(self):
        """简报、急事通知说过的，窗口开着时进来的，都回一次 shown（工具据此知道 §8a 的事说过没有）。"""
        self.present()
        self.src.items = [item("a"), item("bad", urgency="urgent", kind="suspicious")]
        self.agent.poll()
        self.present()
        self.assertEqual(self.acks("shown", ["tool/bad"]), ["tool/bad"], "急事当场说了")
        self.at(HOUR + 2)
        self.present()
        self.assertEqual(self.acks("shown", ["tool/a", "tool/bad"]), ["tool/a", "tool/bad"], "简报里说了")
        self.agent.set_window(True)
        self.src.items.append(item("b"))
        self.agent.poll()
        self.assertEqual(self.acks("shown", ["tool/a", "tool/b", "tool/bad"]), ["tool/a", "tool/b", "tool/bad"],
                         "窗口开着时进来的，用户看得到")
        self.agent.set_window(False)
        self.agent.set_window(True)
        self.assertEqual(len([1 for _, st in self.src.acks if st == "shown"]), 3, "每件只回一次")

    def test_window_open_but_not_in_front_is_not_seen(self):
        self.present()
        self.agent.set_window(True, front=False)
        self.src.items = [item("bad", urgency="urgent", kind="suspicious")]
        self.agent.poll()
        self.present()
        self.assertEqual(len(self.events("notify")), 1, "最小化、切走了：急事照样说")
        self.assertEqual(self.state.item("tool/bad")["status"], "notified")

    def test_window_in_front_but_user_away_is_not_seen(self):
        self.present(False)
        self.agent.set_window(True, front=True)
        self.src.items = [item("a")]
        self.agent.poll()
        self.assertEqual(self.state.item("tool/a")["status"], "queued")
        self.assertEqual(self.acks("shown"), [])
        self.present()
        self.assertEqual(self.state.item("tool/a")["status"], "seen", "人回来了，窗口就在眼前")
        self.assertEqual(self.acks("shown", ["tool/a"]), ["tool/a"])

    def test_notifications_off_is_not_told(self):
        self.agent.set_notifications("denied", False)
        self.present()
        self.src.items = [item("bad", urgency="urgent", kind="suspicious"), item("a")]
        self.agent.poll()
        self.at(1)
        self.at(HOUR + 2)
        self.present()
        self.assertEqual(self.events("notify"), [])
        self.assertEqual(self.state.item("tool/bad")["status"], "queued", "没到用户那里，不算说过")
        self.assertEqual(self.acks("shown"), [])
        self.agent.set_notifications("authorized", True)
        self.present()
        n = sorted(self.events("notify"), key=lambda e: e["title"])
        self.assertEqual([e["title"] for e in n], ["2 件事", "标题 bad"], "打开以后补上")
        self.assertEqual(n[0]["body"], "还有 1 件等你：标题 a；急事：标题 bad。", "件数和正文说的对得上")

    def test_one_ignored_brief_counts_once(self):
        self.present()
        self.src.items = [item("a"), item("b"), item("c")]
        self.agent.poll()
        self.at(1)
        self.at(HOUR + 2)
        self.present()
        self.src.items.append(item("d"))
        self.agent.poll()
        self.at(HOUR + 10)
        self.at(2 * HOUR + 20)
        self.present()
        self.assertEqual(self.state.react("tool:new-mail", "shown") and self.state.react("tool:new-mail", "x"), 1,
                         "三件一起说的只算一次")
        self.assertNotEqual((self.state.setting("modes") or {}).get("tool:new-mail"), "window")

    def test_less_card_survives_a_restart_and_reminds_again(self):
        self.state.set_setting("ignore_limit", 1)
        self.present()
        self.src.items = [item("a")]
        self.agent.poll()
        self.at(1)
        self.at(HOUR + 2)
        self.present()
        self.src.items.append(item("b"))
        self.agent.poll()
        self.at(HOUR + 10)
        self.at(2 * HOUR + 20)
        self.present()
        self.assertEqual(self.state.setting("modes"), {"tool:new-mail": "window"})
        again = Agent(self.state, [self.src], clock=self.clock, url_opener=self.opened.append, labels={})
        sid = next(s for s in again.surfaces if "less" in s)
        s = again.surfaces[sid][1]
        remind = next(c for c in a2ui._reachable(s.components) if s.components[c].get("component") == "Button")
        self.assertEqual(again.tap(sid, remind)["text"], "好，照旧提醒。")
        self.assertEqual(self.state.setting("modes"), {})
        self.assertEqual(self.state.react("tool:new-mail", "x"), 0, "连着没理的次数清零")
        third = Agent(self.state, [self.src], clock=self.clock, url_opener=self.opened.append)
        self.assertFalse([s for s in third.surfaces if "less" in s], "答过就不再画回来")

    def test_old_install_gets_its_less_cards_back(self):
        self.state.set_setting("modes", {"memory:question": "window"})
        self.state.set_meta("less_notices", None)
        again = Agent(self.state, [self.src], clock=self.clock, url_opener=self.opened.append)
        self.assertEqual(len([s for s in again.surfaces if "less" in s]), 1)

    def test_empty_list_from_a_restarting_tool_loses_nothing(self):
        self.present()
        self.src.items = [item("a")]
        self.agent.poll()
        self.at(1)
        self.at(HOUR + 2)
        self.present()
        self.assertEqual(self.state.item("tool/a")["status"], "notified")
        self.src.items, keep = [], self.src.items
        self.agent.poll()
        self.assertEqual(self.state.item("tool/a")["status"], "gone")
        self.src.items = keep
        self.agent.poll()
        self.assertEqual(self.state.item("tool/a")["status"], "notified", "说过的不再说")
        self.assertIn("tool/a", self.agent.order())

    def test_brief_waits_while_away_and_skips_withdrawn(self):
        self.present()
        self.src.items = [item("a"), item("b")]
        self.agent.poll()
        self.at(1)
        self.clock.t = T0 + HOUR + 5
        self.present(False)
        self.assertEqual(self.events("notify"), [], "不在 Mac 前：等")
        self.src.items = [item("b")]        # a 在别处处理掉了
        self.agent.poll()
        self.clock.t = T0 + 2 * HOUR
        self.present(True)
        n = self.events("notify")
        self.assertEqual(n[0]["title"], "1 件事")
        self.src.items = []
        self.agent.poll()
        self.assertEqual(self.agent.order(), [])

    def test_window_open_means_seen(self):
        self.present()
        self.src.items = [item("a")]
        self.agent.poll()
        self.at(1)
        self.agent.set_window(True)
        self.at(HOUR + 5)
        self.present()
        self.assertEqual(self.events("notify"), [], "看过了，不再通知")
        self.src.items.append(item("b"))
        self.agent.poll()          # 窗口开着时来的也算看过
        self.at(3 * HOUR)
        self.present()
        self.assertEqual(self.events("notify"), [])

    def test_low_only_once_a_day(self):
        self.present()
        self.src.items = [item("m1", urgency="low", kind="term")]
        self.agent.poll()
        self.at(1)
        self.at(HOUR + 5)
        self.present()
        self.assertEqual(len(self.events("notify")), 1)
        self.src.items.append(item("m2", urgency="low", kind="term"))
        self.agent.poll()
        self.at(HOUR + 10)
        self.at(5 * HOUR)
        self.present()
        self.assertEqual(self.events("notify"), [], "只有不急的：一天最多一份")
        self.at(26 * HOUR)
        self.at(28 * HOUR)
        self.present()
        self.assertEqual(len(self.events("notify")), 1)

    def test_ignored_three_times_goes_quiet(self):
        self.present()
        t = 0
        for n in range(4):   # 每份简报都没人打开窗口
            self.src.items.append(item(f"x{n}"))
            self.agent.poll()
            t += 10
            self.at(t)
            t += HOUR + 10
            self.at(t)
            self.present()
        modes = self.state.setting("modes")
        self.assertEqual(modes.get("tool:new-mail"), "window")
        self.assertTrue(any(s.startswith("agent/less-") for s in self.agent.order()), "说一次：以后只放这里")
        self.events()
        self.src.items.append(item("y"))
        self.agent.poll()
        self.at(t + 10)
        self.at(t + 2 * HOUR)
        self.present()
        self.assertEqual(self.events("notify"), [], "只放窗口了")
        sid = next(s for s in self.agent.order() if s.startswith("agent/"))
        s = self.agent.surfaces[sid][1]
        remind = next(c for c in s.components if s.components[c].get("component") == "Button"
                      and s.components[c]["action"]["event"]["name"] == "agent.remind")
        self.assertFalse(self.agent.tap(sid, remind).get("error"))
        self.assertNotIn("tool:new-mail", self.state.setting("modes"))
        self.assertNotIn(sid, self.agent.order())

    def test_tap_keeps_written_values(self):
        self.src.items = [item("a")]
        self.agent.poll()
        s = self.agent.surfaces["tool/a"][1]
        ok = next(c for c in s.components if s.components[c].get("component") == "Button"
                  and s.components[c]["action"]["event"]["name"] == "mail_apply_plan")
        r = self.agent.tap("tool/a", ok, {"plan_id": "plan-偷换", "choices": {"m1": ["keep"]}})
        self.assertEqual(r["text"], "已归档 1 封。")
        key, name, ctx, ua = self.src.calls[0]
        self.assertEqual(ctx, {"plan_id": "plan-a", "choices": {"m1": ["keep"]}}, "方案编号只认卡片上的")
        self.assertEqual(ua["componentId"], ok)
        self.assertEqual(self.state.item("tool/a")["status"], "done")
        self.assertIn("tool/a", self.agent.order(), "结果卡片留着，能撤销")
        self.assertEqual(self.events("result")[-1]["text"], "已归档 1 封。")
        # 撤销：工具已经把这件撤下了，卡片还在
        self.src.items = []
        self.agent.poll()
        s = self.agent.surfaces["tool/a"][1]
        undo = next(c for c in a2ui._reachable(s.components) if s.components[c].get("component") == "Button")
        self.assertEqual(self.agent.tap("tool/a", undo)["text"], "已撤销。")
        self.assertEqual(self.src.calls[-1][1:3], ("mail_undo", {"execution_id": "e1"}))
        self.assertEqual(self.agent.tap("tool/nope", "b1")["error"], True)
        self.assertEqual(self.acks("answered"), ["tool/a"])
        # 留够了时间、窗口关着：收起
        self.at(31 * 60)
        self.assertNotIn("tool/a", self.agent.order())

    def test_open_url_shows_site_and_opens_after_tap(self):
        self.src.items = [item("a")]
        self.agent.poll()
        msgs = [m for m in self.events("a2ui") if "updateComponents" in m]
        comps = [c for m in msgs for c in m["updateComponents"]["components"]]
        sites = {c["id"]: c.get("site") for c in comps if c.get("component") == "Button"}
        s = self.agent.surfaces["tool/a"][1]
        btn = next(c for c in s.components if s.components[c].get("component") == "Button"
                   and s.components[c]["action"]["event"]["name"] == "agent.open_url")
        self.assertEqual(sites.pop(btn), "calendar.google.com", "去哪个网站写在按钮上，界面画在按钮外面")
        self.assertEqual(set(sites.values()), {None}, "别的按钮不带")
        self.assertIn("加入日程", [c.get("text") for c in comps], "按钮文字不改")
        self.assertNotIn("site", s.components[btn], "存着的卡片不带")
        self.assertEqual(self.opened, [])
        self.agent.tap("tool/a", btn, {"url": "https://evil.example"})
        self.assertEqual(self.opened, ["https://calendar.google.com/x?a=1"], "网址只认卡片上写死的")
        self.assertEqual(self.src.calls, [])

    def _open_url_card(self, url, *, site=None, other_site=None):
        card = cards.Card("web")
        card.text("一封信")
        card.buttons(cards.open_url_button("打开", url), cards.button("好", "agent.dismiss"))
        msgs = card.messages()
        for c in msgs[1]["updateComponents"]["components"]:
            if c.get("component") == "Button":
                if c["action"]["event"]["name"] == "agent.open_url" and site:
                    c["site"] = site
                elif c["action"]["event"]["name"] != "agent.open_url" and other_site:
                    c["site"] = other_site
        return Item(key="tool/web", source="tool", kind="new-mail", urgency="normal", title="网页", summary="",
                    why_now="", card=msgs, extra={"id": "web"})

    def test_open_url_site_is_punycode_and_the_opened_url_is_rebuilt(self):
        self.src.items = [self._open_url_card("https://bücher.example/路径?q=1", site="google.com", other_site="bank.example")]
        self.agent.poll()
        comps = [c for m in self.events("a2ui") if "updateComponents" in m for c in m["updateComponents"]["components"]]
        sites = {c["action"]["event"]["name"]: c.get("site") for c in comps if c.get("component") == "Button"}
        self.assertEqual(sites, {"agent.open_url": "xn--bcher-kva.example", "agent.dismiss": None},
                         "工具自己写的 site 不算：换成 agent 解析出来的，别的按钮上的去掉")
        s = self.agent.surfaces["tool/web"][1]
        btn = next(c for c in s.components if s.components[c].get("component") == "Button"
                   and s.components[c]["action"]["event"]["name"] == "agent.open_url")
        r = self.agent.tap("tool/web", btn)
        self.assertFalse(r.get("error"), r)
        self.assertEqual(self.opened, ["https://xn--bcher-kva.example/%E8%B7%AF%E5%BE%84?q=1"],
                         "打开的网址照显示时同一次解析重新拼")
        self.assertIn("xn--bcher-kva.example", r["text"])

    def test_open_url_refuses_what_the_card_check_would(self):
        """卡片画得出来以后网址也再核一遍（例如 a2ui 以外的路进来的上下文）。"""
        for url in ("https://user@evil.example/", "https://example.com\\@evil.example", "http://example.com"):
            with self.subTest(url=url):
                r = self.agent._open_url({"url": url})
                self.assertTrue(r["error"])
        self.assertEqual(self.opened, [])

    def test_open_url_card_with_a_bound_label_is_not_drawn(self):
        it = self._open_url_card("https://example.com/")
        comps = it.card[1]["updateComponents"]["components"]
        label = next(c for c in comps if c.get("text") == "打开")
        label["text"] = {"path": "/label"}
        it.card.append({"version": a2ui.VERSION, "updateDataModel": {"surfaceId": "web", "path": "/label", "value": "打开"}})
        self.assertTrue(any("写死文字的 Text" in p for p in a2ui.validate(it.card)))

    def test_tool_down_and_back(self):
        self.src.items = [item("a")]
        self.agent.poll()
        self.src.running = False
        self.agent.poll()
        self.assertEqual(self.agent.order(), [])
        self.assertIn("假工具现在没在运行。", self.events("feed")[-1]["notices"])
        self.src.running = True
        self.agent.poll()
        self.assertEqual(self.agent.order(), ["tool/a"], "回来了照旧，状态没被当成撤回")

    def test_restart_closes_what_left_meanwhile(self):
        self.src.items = [item("a"), item("b")]
        self.agent.poll()
        again = Agent(self.state, [self.src], clock=self.clock)     # 核心重启；这期间 a 撤下了
        self.src.items = [item("b")]
        again.poll()
        self.assertEqual(self.state.item("tool/a")["status"], "gone")
        self.assertNotEqual(self.state.item("tool/b")["status"], "gone")

    def test_undo_survives_a_restart(self):
        """事项和卡片存在本机（顶层 ADR 0013）：核心重启后，答完的卡片照样在，[撤销] 还能点。"""
        self.src.items = [item("a")]
        self.agent.poll()
        s = self.agent.surfaces["tool/a"][1]
        ok = next(c for c in s.components if s.components[c].get("component") == "Button"
                  and s.components[c]["action"]["event"]["name"] == "mail_apply_plan")
        self.agent.tap("tool/a", ok)
        self.src.items = []
        again = Agent(self.state, [self.src], clock=self.clock)     # 核心重启；工具已经把这件撤下了
        again.poll()
        self.assertEqual(again.order(), ["tool/a"])
        s = again.surfaces["tool/a"][1]
        undo = next(c for c in a2ui._reachable(s.components) if s.components[c].get("component") == "Button")
        self.assertEqual(s.components[s.components[undo]["child"]]["text"], "撤销")
        self.assertEqual(again.tap("tool/a", undo)["text"], "已撤销。")
        self.assertEqual(self.src.calls[-1][1:3], ("mail_undo", {"execution_id": "e1"}))
        self.assertEqual(self.src.calls[-1][0], "tool/a", "来源拿到的是原来那件（extra 也在）")
        third = Agent(self.state, [self.src], clock=self.clock)
        texts = [c.get("text") for c in third.surfaces["tool/a"][1].components.values()]
        self.assertIn("已撤销。", texts, "撤销以后的样子也存下了")
        self.clock.t = T0 + 31 * 60
        self.assertEqual(Agent(self.state, [self.src], clock=self.clock).order(), [], "留够了时间就不再画回去")
        self.assertEqual(self.state.content("tool/a")["item"]["title"], "标题 a", "内容留着当历史")

    def test_done_row_says_what_was_done(self):
        """「已经替你做了」那一行写工具答的那句（做了什么），不写事项原来的标题；撤销以后写撤销的那句；核心重启也一样。"""
        self.src.items = [item("a")]
        self.agent.poll()
        title = lambda a: next(c["title"] for c in a._cards() if c["id"] == "tool/a")
        self.assertEqual(title(self.agent), "标题 a")
        s = self.agent.surfaces["tool/a"][1]
        ok = next(c for c in s.components if s.components[c].get("component") == "Button"
                  and s.components[c]["action"]["event"]["name"] == "mail_apply_plan")
        self.agent.tap("tool/a", ok)
        self.assertEqual(title(self.agent), "已归档 1 封。")
        again = Agent(self.state, [self.src], clock=self.clock)
        self.assertEqual(title(again), "已归档 1 封。", "重启以后照旧")
        s = again.surfaces["tool/a"][1]
        undo = next(c for c in a2ui._reachable(s.components) if s.components[c].get("component") == "Button")
        again.tap("tool/a", undo)
        self.assertEqual(title(again), "已撤销。")
        self.assertEqual(title(Agent(self.state, [self.src], clock=self.clock)), "已撤销。")

    def test_dismissed_cards_do_not_come_back(self):
        notice = Item(key="tool/x", source="tool", kind="k", urgency="low", title="t", summary="", why_now="",
                      card=cards.Card("x").messages())
        c = cards.Card("x")
        c.text("一句")
        c.buttons(cards.button("好", "agent.dismiss"))
        notice.card = c.messages()
        self.src.items = [notice]
        self.agent.poll()
        s = self.agent.surfaces["tool/x"][1]
        b = next(i for i in s.components if s.components[i].get("component") == "Button")
        self.agent.tap("tool/x", b)
        self.assertEqual(self.agent.order(), [])
        self.assertEqual(Agent(self.state, [self.src], clock=self.clock).order(), [])

    def test_a_new_ask_in_memory_comes_out_in_a_brief(self):
        """记忆里新起一条想问的：下一次读到，攒满一小时、用户在 Mac 前，就进简报。"""
        path = os.path.join(self.dir, "mem.db")
        lm = load_luoke_mem()
        m = lm.WholeMemory(path)
        mem = MemorySource(path, self.state, opener=lambda *a: None)
        self.agent.add_source(mem)
        self.agent.poll(["memory"])
        self.assertEqual(self.agent.order(), [])
        m.ask("question", "周报一般哪天发？", "发出的邮件里周报的日子不一样", answer={"type": "text"})
        m.db.close()
        self.present()
        self.agent.poll(["memory"])
        self.assertEqual(len(self.agent.order()), 1)
        self.at(1)
        self.assertEqual(self.events("notify"), [], "攒着")
        self.clock.t = T0 + HOUR + 2
        self.present()                      # 壳报"在 Mac 前"时顺带挑一次时机
        n = self.events("notify")
        self.assertEqual(len(n), 1)
        self.assertIn("周报一般哪天发", n[0]["body"])
        mem.close()

    def test_notifications_turned_off_are_said_in_the_window(self):
        self.assertIsNone(self.agent.status()["notifications"])
        self.agent.set_notifications("denied")
        self.assertEqual(self.agent.status()["notifications"], {"status": "denied", "alerts": True})
        self.assertTrue(any("系统通知被关掉了" in n for n in self.events("feed")[-1]["notices"]))
        self.agent.set_notifications("authorized", alerts=False)
        self.assertTrue(any("系统通知被关掉了" in n for n in self.agent._feed()["notices"]), "横幅关着也算")
        self.agent.set_notifications("not_determined", alerts=False)
        self.assertFalse(any("系统通知" in n for n in self.agent._feed()["notices"]), "还没问过：窗口留按钮")
        self.agent.set_notifications("authorized")
        self.assertFalse(any("系统通知" in n or "系统在问" in n for n in self.events("feed")[-1]["notices"]))

    def test_expired_items_are_not_shown(self):
        self.src.items = [item("old", expires="2020-01-01T00:00:00"), item("new")]
        self.agent.poll()
        self.assertEqual(self.agent.order(), ["tool/new"])

    def test_order_urgent_then_deadline(self):
        self.src.items = [item("late", deadline="2030-01-02"), item("soon", deadline="2030-01-01"),
                          item("bad", urgency="urgent"), item("m", urgency="low")]
        self.agent.poll()
        self.assertEqual(self.agent.order(), ["tool/bad", "tool/soon", "tool/late", "tool/m"])

    def test_new_subscriber_gets_everything(self):
        self.src.items = [item("a")]
        self.agent.poll()
        q = self.agent.subscribe()
        got = []
        while not q.empty():
            got.append(q.get_nowait())
        self.assertEqual(got[0][0], "a2ui")
        self.assertIn("createSurface", got[0][1])
        self.assertEqual(got[-1][0], "feed")
        self.assertEqual(got[-1][1]["order"], ["tool/a"])


def local(h, m=0, day=0):
    """T0 那天（本机时间）的 h:m，往后 day 天：按时刻的测试不受时区影响。"""
    base = dt.datetime.fromtimestamp(T0).replace(hour=0, minute=0, second=0, microsecond=0) + dt.timedelta(days=day)
    return base.replace(hour=h, minute=m).timestamp()


class BriefScheduleTest(_Base):
    """简报按时刻发（docs/界面接口.md §9）：每天早上、早晚各一次、只在我打开时；暂停、关掉主动提醒。"""

    def setUp(self):
        super().setUp()
        self.state.set_setting("brief", "morning")
        self.state.set_setting("quiet", {"start": "22:00", "end": "08:00"})

    def go(self, t, present=True):
        self.clock.t = t
        self.present(present)
        self.agent.tick()

    def briefs(self):
        return [n for n in self.events("notify") if n["id"] == "brief"]

    def test_morning_brief_once_then_next_morning(self):
        self.go(local(7, 0, -1) + 1)            # 前一天早上 7 点：免打扰里，没什么可说，不算用过早上那一份
        self.state.set_meta("last_brief", local(8, 5, -1))   # 前一天早上那份发过了
        self.src.items = [item("a")]
        self.clock.t = local(6, 0)
        self.agent.poll()
        self.go(local(6, 0))
        self.assertEqual(self.briefs(), [], "免打扰里不发")
        self.go(local(8, 30), present=False)
        self.assertEqual(self.briefs(), [], "不在 Mac 前：等")
        self.go(local(8, 40))
        self.assertEqual(len(self.briefs()), 1, "早上第一次在 Mac 前：发一份")
        self.src.items = [item("a"), item("b")]
        self.agent.poll()
        self.go(local(10, 0))
        self.go(local(18, 30))
        self.assertEqual(self.briefs(), [], "每天早上只发一份：之后来的等明天早上")
        self.go(local(8, 1, 1))
        b = self.briefs()
        self.assertEqual(len(b), 1)
        self.assertIn("标题 b", b[0]["body"])

    def test_nothing_to_say_uses_up_the_morning(self):
        self.go(local(8, 30))                    # 到了时刻、人在、没什么可说
        self.src.items = [item("late")]
        self.agent.poll()
        self.go(local(10, 0))
        self.assertEqual(self.briefs(), [], "早上那份不补发")
        nxt = self.agent._feed()["brief"]["next"]
        self.assertEqual(nxt, dt.datetime.fromtimestamp(local(8, 0, 1)).astimezone().isoformat(timespec="seconds"))

    def test_twice_adds_the_evening(self):
        self.agent.update_settings({"brief": "twice"})
        self.go(local(8, 30))
        self.src.items = [item("noon")]
        self.agent.poll()
        self.go(local(12, 0))
        self.assertEqual(self.briefs(), [])
        self.go(local(18, 10))
        self.assertEqual(len(self.briefs()), 1, "晚上 18:00 以后第一次在 Mac 前")

    def test_on_open_never_notifies(self):
        self.agent.update_settings({"brief": "on_open"})
        self.src.items = [item("x")]
        self.agent.poll()
        self.go(local(9, 0))
        self.assertEqual(self.briefs(), [])
        self.assertIsNone(self.agent._feed()["brief"]["next"])
        self.agent.set_window(True, True)
        self.assertEqual(self.state.item("tool/x")["status"], "seen", "打开窗口就是看过了")

    def test_pause_holds_urgent_until_it_ends(self):
        self.go(local(9, 0))
        until = dt.datetime.fromtimestamp(local(10, 0)).astimezone().isoformat(timespec="seconds")
        got = self.agent.update_settings({"paused_until": until})
        self.assertEqual(got["paused_until"], until)
        self.assertEqual(self.agent._feed()["paused_until"], until)
        self.src.items = [item("bad", urgency="urgent", kind="suspicious")]
        self.agent.poll()
        self.go(local(9, 30))
        self.assertEqual(self.events("notify"), [], "暂停着：急事也不发")
        self.assertEqual([c["section"] for c in self.agent._feed()["cards"]], ["urgent"], "窗口里照旧有")
        self.go(local(10, 1))
        self.assertEqual(len([n for n in self.events("notify") if n["urgent"]]), 1, "暂停到点：说")

    def test_proactive_off_is_silent(self):
        self.agent.update_settings({"proactive": False})
        self.src.items = [item("bad", urgency="urgent", kind="suspicious"), item("a")]
        self.agent.poll()
        self.go(local(9, 0))
        self.go(local(9, 5))
        self.assertEqual(self.events("notify"), [])
        self.assertEqual(len(self.agent._feed()["cards"]), 2)


class FeedAndSettingsTest(_Base):
    def test_cards_say_which_section(self):
        self.src.items = [item("bad", urgency="urgent", kind="suspicious"), item("a"), item("pick", urgency="low", kind="picks"),
                          item("fda", urgency="low", kind="needs-access")]
        self.agent.poll()
        feed = self.agent._feed()
        self.assertEqual([c["id"] for c in feed["cards"]], feed["order"])
        sec = {c["id"]: c["section"] for c in feed["cards"]}
        self.assertEqual(sec, {"tool/bad": "urgent", "tool/a": "decide", "tool/pick": "later", "tool/fda": "decide"},
                         "要权限的报成 low 也放「要你决定」")
        c = feed["cards"][0]
        self.assertEqual((c["app"], c["kind"], c["title"]), ("tool", "suspicious", "标题 bad"))
        self.assertTrue(c["time"])
        surface = self.agent.surfaces["tool/a"][1]
        apply = next(cid for cid, comp in surface.components.items() if comp.get("component") == "Button"
                     and comp["action"]["event"]["name"] == "mail_apply_plan")
        self.agent.tap("tool/a", apply)
        sec = {c["id"]: c["section"] for c in self.agent._feed()["cards"]}
        self.assertEqual(sec["tool/a"], "done", "点完、带撤销的进「已经替你做了」")

    def test_settings_round_trip_and_validation(self):
        q = self.q
        self.src.items = [item("bad", urgency="urgent", kind="suspicious"), item("a")]
        self.agent.poll()
        st = self.agent.settings()
        self.assertEqual((st["proactive"], st["brief"], st["paused_until"]), (True, "every", None))
        kinds = {k["id"]: k for k in st["kinds"]}
        self.assertEqual((kinds["tool:suspicious"]["default"], kinds["tool:new-mail"]["default"]), ("now", "brief"))
        got = self.agent.update_settings({"brief": "twice", "modes": {"tool:new-mail": "window"},
                                          "quiet": {"start": "23:00", "end": "07:30"}})
        self.assertEqual(got["brief"], "twice")
        self.assertEqual({k["id"]: k["mode"] for k in got["kinds"]}["tool:new-mail"], "window")
        self.assertEqual(self.agent.mode(self.agent.items["tool/a"]), "window")
        self.assertTrue(any(e == "settings" for e, _ in list(q.queue)), "推了 settings 事件")
        self.assertEqual(self.agent.update_settings({"modes": {"tool:new-mail": None}})["modes"], {})
        for bad in ({"brief": "hourly"}, {"quiet": {"start": "25:00", "end": "08:00"}}, {"proactive": "yes"},
                    {"paused_until": "2000-01-01T00:00:00"}, {"modes": {"x": "now"}}, {"volume": 3}):
            with self.assertRaises(ValueError, msg=bad):
                self.agent.update_settings(bad)
        self.assertEqual(self.agent.settings()["brief"], "twice", "值不对的什么都不改")


if __name__ == "__main__":
    unittest.main()
