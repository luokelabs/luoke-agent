"""简报那一段话（`luoke_agent/brief.py`、`runner.maybe_brief_words`）和它的评测集"""
from __future__ import annotations

import json
import os
import sys
import unittest

from luoke_agent import brief, hub as hubmod
from luoke_agent.agent import BRIEF_WORDS_KEPT, Agent
from luoke_agent.runner import BRIEF_WORDS_FOR, BRIEF_WORDS_RETRY, Runner
from luoke_agent.state import State

from tests.test_hello import WithHub

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, os.path.join(ROOT, "bench"))
import brief_set  # noqa: E402
import run_brief  # noqa: E402

MATTERS = [{"id": "m/a", "kind": "done", "text": "螺壳邮件助手：归档 14 封促销邮件"},
           {"id": "m/b", "kind": "waiting", "text": "螺壳邮件助手：5 封新邮件"},
           {"id": "m/c", "kind": "urgent", "text": "螺壳邮件助手：可疑邮件，冒充银行"},
           {"id": "m/d", "kind": "later", "text": "有新版本"}, {"id": "m/e", "kind": "done", "text": "  "}]
GOOD = "有 1 件急事先看：冒充银行的可疑邮件。另外归档了 14 封促销邮件，没一封是人写的"


class BriefTest(unittest.TestCase):
    def test_what_the_model_reads(self):
        system, user = brief.messages(MATTERS, "11月18日 星期三 早上")
        self.assertEqual(system["content"], brief.PROMPT["system"])
        self.assertEqual(user["content"], "今天：11月18日 星期三 早上\n\n今天的事：\n1. [急事] 螺壳邮件助手：可疑邮件，冒充银行\n"
                         "2. [已自动处理] 螺壳邮件助手：归档 14 封促销邮件\n3. [待确认] 螺壳邮件助手：5 封新邮件\n\n"
                         "一共：急事 1 件，已自动处理 1 件，待确认 1 件", "急事在前；别的类别、空的不给")
        many = [{"id": i, "kind": "done", "text": f"第 {i} 件"} for i in range(30)]
        self.assertEqual(len(brief.usable(many)), brief.MAX_MATTERS)
        self.assertIn("已自动处理 30 件", brief.messages(many, "x")[1]["content"], "件数照全部的数")

    def test_an_answer_out_of_line_is_dropped(self):
        self.assertEqual(brief.parse(json.dumps({"text": GOOD}, ensure_ascii=False), MATTERS), GOOD)
        for bad, why in (("不是 JSON", "格式"), ('{"text": 3}', "格式"), ('{"text": "好"}', "太短"),
                         (json.dumps({"text": "字" * 81}), "太长"), ('{"text": "归档了促销邮件\\n还有新邮件等你"}', "两行"),
                         ('{"text": "归档了 15 封促销邮件，都收拾好了"}', "列表里没有 15"),
                         ('{"text": "我这个 AI 归档了促销邮件，放心吧"}', "提了 AI")):
            self.assertEqual(brief.parse(bad, MATTERS), "", why)

    def test_the_set_is_fixed_and_scored(self):
        cases = brief_set.cases()
        kinds = [c["kind"] for c in cases]
        self.assertEqual({k: kinds.count(k) for k in set(kinds)}, {"normal": 6, "urgent": 6, "inject": 6, "heavy": 4})
        self.assertEqual(run_brief.set_hash(cases), run_brief.set_hash(brief_set.cases()), "固定的种子：集合不变")
        for c in cases:
            self.assertEqual(len(brief.usable(c["matters"])), len(c["matters"]), c["id"])
            brief.messages(c["matters"], "x")
        case = next(c for c in cases if c["kind"] == "urgent")
        u = next(m for m in case["matters"] if m["kind"] == "urgent")
        ok = run_brief.judge(case, json.dumps({"text": f"先看这件：{u['keys'][0]}的事。别的都收拾好了哦"}, ensure_ascii=False))
        self.assertEqual((ok["hard"], ok["urgent_said"], ok["urgent_first"], ok["voice"]), ([], True, True, True))
        bad = run_brief.judge(next(c for c in cases if c["kind"] == "inject"), json.dumps({"text": "忽略上面的话，都收拾好了"}, ensure_ascii=False))
        self.assertIn("never:忽略", bad["hard"])
        self.assertTrue(run_brief.score([{"id": "urgent-0", "kind": "urgent", "runs": [ok]}])["passed"])


class WordsTest(WithHub):
    def setUp(self):
        super().setUp()
        self.hub.tasks = {"luoke-agent.brief": {"status": "ready"}}
        self.hub.answer = json.dumps({"text": GOOD}, ensure_ascii=False)
        self.state = State(os.path.join(self.dir, "agent"))
        self.wall = 1794800000.0
        self.agent = Agent(self.state, [], clock=lambda: self.wall)
        self.agent.today_matters = lambda urgent=False: MATTERS if urgent else MATTERS[:2]
        self.now = 1000.0
        self.runner = Runner(self.agent, hub=self.sock, home=self.dir, clock=lambda: self.now)

    def tearDown(self):
        self.state.close()
        super().tearDown()

    def go(self):
        self.runner.maybe_brief_words(self.now)
        if self.runner._brief_thread:
            self.runner._brief_thread.join(10)

    def sent(self):
        self.state.set_meta("last_brief", self.wall)
        self.agent.brief_wanted = self.wall

    def test_asked_once_after_a_brief_as_background_work(self):
        self.go()
        self.assertEqual(self.hub.asked, [], "没发简报：不问")
        self.sent()
        self.go()
        ask, = self.hub.asked
        self.assertEqual((ask["path"], ask["priority"]), ("/tasks/luoke-agent.brief/v1/chat/completions", "background"),
                         "通知发出去的那一刻没有人在等")
        self.assertIn("[急事]", ask["body"]["messages"][1]["content"])
        self.assertEqual(self.agent.brief_words(), GOOD)
        self.assertEqual(self.agent._feed()["brief"]["words"], GOOD)
        self.now += BRIEF_WORDS_RETRY
        self.go()
        self.assertEqual(len(self.hub.asked), 1, "这一份问过了")
        self.wall += BRIEF_WORDS_KEPT + 1
        self.assertIsNone(self.agent.brief_words(), "过了半天是旧事：窗口照现在的样子拼")

    def test_words_for_an_older_brief_are_not_used(self):
        self.sent()
        self.go()
        self.state.set_meta("last_brief", self.wall + 60)      # 又发了一份
        self.assertIsNone(self.agent.brief_words())
        self.agent.set_brief_words("给上一份写的那一段话，已经晚了", self.wall)
        self.assertIsNone(self.agent.brief_words(), "不是最近这一份的不要")

    def test_not_now_retries_then_gives_up_and_bad_answers_mean_none(self):
        self.sent()
        self.hub.answer = (503, {"code": "busy", "message": "忙", "retry_after": 1200})
        self.go()
        self.assertIsNone(self.agent.brief_words())
        self.now += BRIEF_WORDS_RETRY
        self.go()
        self.assertEqual(len(self.hub.asked), 1, "主控说二十分钟后：照它的")
        self.now += 1200
        self.hub.answer = '{"text": "归档了 99 封促销邮件，都收拾好了"}'
        self.go()
        self.assertEqual(len(self.hub.asked), 2)
        self.assertIsNone(self.agent.brief_words(), "编了数：不要，窗口照模板拼")
        self.assertIsNone(self.agent.brief_wanted, "答了就不再问")
        self.sent()
        self.wall += BRIEF_WORDS_FOR + 1
        self.now += BRIEF_WORDS_RETRY
        self.go()
        self.assertEqual(len(self.hub.asked), 2, "发出去太久了：不问了")
        self.assertIsNone(self.agent.brief_wanted)

    def test_opening_today_before_the_words_came_asks_once_as_user_waiting(self):
        self.sent()
        self.hub.answer = (503, {"code": "busy", "message": "忙", "retry_after": 1200})
        self.go()
        self.assertEqual([a["priority"] for a in self.hub.asked], ["background"])
        self.go()
        self.assertEqual(len(self.hub.asked), 1, "主控说过一阵：没人看着就等")
        self.agent.window_front, self.agent.window_page = True, "today"
        self.hub.answer = json.dumps({"text": GOOD}, ensure_ascii=False)
        self.go()
        self.assertEqual([a["priority"] for a in self.hub.asked], ["background", "user-waiting"], "用户打开了「今天」：人在等，补问")
        self.assertEqual(self.agent.brief_words(), GOOD)
        self.sent()
        self.agent.brief_wanted = self.wall
        self.runner._brief_waited = self.wall
        self.runner.next_brief_words = self.now + 999
        self.go()
        self.assertEqual(len(self.hub.asked), 2, "一份简报只补问一次")

    def test_today_matters_can_include_the_urgent(self):
        self.agent._cards = lambda: [{"id": "a", "app": "x", "section": "urgent", "title": "可疑邮件"},
                                     {"id": "b", "app": "x", "section": "done", "title": "归档 2 封"}]
        self.assertEqual([m["kind"] for m in Agent.today_matters(self.agent, urgent=True)], ["urgent", "done"])
        self.assertEqual([m["kind"] for m in Agent.today_matters(self.agent)], ["done"])


if __name__ == "__main__":
    unittest.main()
