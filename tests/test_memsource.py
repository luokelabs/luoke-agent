from __future__ import annotations

import os as _os

assert _os.environ.get("LUOKE_AGENT_TESTING") == "1", "用 python3 -m unittest 跑：tests/__init__.py 先把一切指到临时目录"

import os
import shutil
import tempfile
import unittest

from luoke_agent import a2ui
from luoke_agent.agent import Agent
from luoke_agent.memsource import CANT_ARCHIVE, CHANGED, SAID, MemorySource, load_luoke_mem
from luoke_agent.devdata import make_sample_memory as make_memory
from luoke_agent.state import State

lm = load_luoke_mem()
NOW = 1_800_000_000.0


class _Memory:
    """只做卡片用到的几样的假记忆，不依赖自带那份 luoke_mem 的版本：asks、note、reply。没有 archive，像 0.34 以前的。"""

    ASKS = [
        {"id": 1, "kind": "question", "text": "「行云」是你们的项目名？", "why": "打字里出现了几次", "about_note": 11},
        {"id": 2, "kind": "question", "text": "周报一般哪天发？", "answer": {"type": "text"}},
        {"id": 3, "kind": "question", "text": "周末也看工作邮件吗？", "answer": {"type": "yes_no"}},
        {"id": 4, "kind": "question", "text": "例会在哪天？", "answer": {"type": "choice", "options": ["周一", "周五"]}},
        {"id": 5, "kind": "suggestion", "text": "以后某某商城的邮件都归档？", "answer": {"type": "yes_no"}},
        {"id": 6, "kind": "suggestion", "text": "这周的周报还没发。"},
    ]

    def __init__(self):
        self.db = type("DB", (), {"close": lambda self: None})()
        self.state = {a["id"]: "open" for a in self.ASKS}
        self.replies = []

    def asks(self, status=None):
        return [dict(a) for a in self.ASKS if self.state[a["id"]] in (status or ["open"])]

    def note(self, nid):
        return None

    def reply(self, aid, choice, text=None):
        if self.state.get(aid) != "open":
            raise ValueError("this is not open")
        if choice == "archive" and not hasattr(self, "archive"):
            raise ValueError("not an answer: archive")
        self.replies.append((aid, choice, text))
        self.state[aid] = "archived" if choice == "archive" else "answered"


class _ArchivingMemory(_Memory):
    """luoke_mem 0.34 起：Memory.archive，reply 也认 "archive"。"""

    def archive(self, aid):
        self.reply(aid, "archive")


class MemoryArchiveTest(unittest.TestCase):
    """「归档」：先收起来、不作答（luoke_mem 0.34 起）。记忆有就画在每张卡片最后，没有就不画。"""

    def setUp(self):
        self.dir = tempfile.mkdtemp(prefix="la")
        self.state = State(os.path.join(self.dir, "agent"))
        self.src = MemorySource(os.path.join(self.dir, "mem.db"), self.state, opener=lambda *a: None)

    def tearDown(self):
        self.src.close()
        self.state.close()
        shutil.rmtree(self.dir, ignore_errors=True)

    def use(self, mem):
        self.src._mem = mem
        self.src._open = lambda: self.src._mem
        return mem

    @staticmethod
    def buttons(card):
        comps = {c["id"]: c for m in card if "updateComponents" in m for c in m["updateComponents"]["components"]}
        return [(comps[c["id"] + "-text"]["text"], c) for c in comps.values() if c.get("component") == "Button"]

    def test_archive_is_the_last_button_on_every_card(self):
        mem = self.use(_ArchivingMemory())
        items = self.src.poll(NOW)
        self.assertEqual(len(items), len(mem.ASKS), "问题、猜测、建议各种都在")
        for it in items:
            self.assertEqual(a2ui.validate(it.card), [], it.key)
            label, b = self.buttons(it.card)[-1]
            self.assertEqual(label, "归档", it.key)
            self.assertEqual(b.get("variant"), "borderless", "不带边框：不算回答")
            self.assertEqual(b["action"]["event"], {"name": "mem.reply", "context": {"ask": it.extra["ask"], "choice": "archive"}})
            self.assertEqual([x for x, _ in self.buttons(it.card)].count("归档"), 1)

    def test_older_memory_draws_no_archive_and_refuses_it(self):
        mem = self.use(_Memory())
        items = self.src.poll(NOW)
        for it in items:
            self.assertNotIn("归档", [x for x, _ in self.buttons(it.card)], it.key)
        r = self.src.handle(items[1], "mem.reply", {"ask": items[1].extra["ask"], "choice": "archive"}, NOW)
        self.assertEqual(r, {"text": "不认识这个回答。", "error": True}, "卡片上没有的按钮不认")
        self.assertEqual(mem.replies, [])

    def test_memory_older_than_the_card_says_it_cannot(self):
        """画卡片时的记忆能归档、点的时候换成了更早的（主控带的那份退回了）：答一句做不了，卡片留着。"""
        self.use(_ArchivingMemory())
        item = self.src.poll(NOW)[0]
        mem = self.use(_Memory())
        r = self.src.handle(item, "mem.reply", {"ask": item.extra["ask"], "choice": "archive"}, NOW)
        self.assertEqual(r, {"text": CANT_ARCHIVE, "error": True})
        self.assertEqual(mem.replies, [])

    def test_archived_elsewhere_meanwhile(self):
        mem = self.use(_ArchivingMemory())
        item = self.src.poll(NOW)[0]
        mem.state[item.extra["ask"]] = "answered"           # 在别处答过了
        r = self.src.handle(item, "mem.reply", {"ask": item.extra["ask"], "choice": "archive"}, NOW)
        self.assertEqual(r["text"], CHANGED)
        self.assertTrue(r["done"])

    def test_archive_from_the_window_puts_it_away(self):
        """在窗口里点「归档」：交回记忆，这张卡片收掉，下次读清单也不再出现；别的按钮改不成归档。"""
        mem = self.use(_ArchivingMemory())
        agent = Agent(self.state, [self.src], clock=lambda: NOW)
        agent.poll(["memory"])
        self.assertIn("memory/ask-2", agent.order())

        def tap(sid, label, client=None):
            bid = next(b["id"] for x, b in self.buttons(agent.surfaces[sid][1].messages()) if x == label)
            return agent.tap(sid, bid, client)

        # 界面送来的上下文改不了按钮上写死的选择：点「以后再说」只会是以后再说
        tap("memory/ask-3", "以后再说", {"ask": 3, "choice": "archive"})
        self.assertEqual(mem.replies, [(3, "later", None)])
        r = tap("memory/ask-2", "归档")
        self.assertEqual(r["text"], SAID["archive"])
        self.assertNotIn("找回", r["text"], "主窗口里还没有记忆的页，不说去哪儿找")
        self.assertEqual(mem.replies[-1], (2, "archive", None))
        self.assertEqual(mem.state[2], "archived")
        section = lambda: {c["id"]: c["section"] for c in agent._cards()}
        self.assertEqual(section()["memory/ask-2"], "done", "收进做完的，不在「要你决定」里")
        self.assertNotIn("memory/ask/2", agent.items)
        agent.poll(["memory"])
        self.assertEqual(section()["memory/ask-2"], "done", "归档的不在清单里，不再作为要你决定的出现")
        self.assertNotIn("memory/ask/2", agent.items)
        self.assertEqual(section()["memory/ask-1"], "later", "别的照旧")


class MemorySourceTest(unittest.TestCase):
    def setUp(self):
        self.dir = tempfile.mkdtemp(prefix="la")
        self.path = os.path.join(self.dir, "mem.db")
        self.state = State(os.path.join(self.dir, "agent"))
        self.opened = []
        self.src = MemorySource(self.path, self.state, opener=lambda *a: self.opened.append(a if len(a) > 1 else a[0]))

    def tearDown(self):
        self.src.close()
        self.state.close()
        shutil.rmtree(self.dir, ignore_errors=True)

    def by_prefix(self, prefix):
        return [it for it in self.src.poll(NOW) if it.key.startswith(prefix)]

    def test_memory_refuses_a_password_keeps_the_card(self):
        import luoke_agent.memsource as ms
        src = self.src
        item = type("I", (), {"kind": "question", "card": None, "extra": {"ask": 7, "note": 1}})()

        class Mem:
            db = type("DB", (), {"close": lambda self: None})()

            def reply(self, aid, choice, text):
                raise ValueError("记忆中不保存密码")

            def asks(self, status=None):
                return [{"id": 7}]
        self.assertIsNotNone(ms.NOT_KEPT)
        src._mem = Mem()
        src._open = lambda: src._mem
        out = src.handle(item, "mem.reply", {"ask": 7, "choice": "revise", "text": "密码是 123"}, {})
        self.assertTrue(out["error"], out)
        self.assertNotIn("done", out)

    def test_missing_memory_is_left_alone(self):
        self.assertIsNone(self.src.poll(NOW))
        self.assertFalse(os.path.exists(self.path), "不替记忆建文件")
        self.assertEqual(self.src.status, "missing")

    def test_items_come_only_from_the_list(self):
        """顶层 ADR 0015：卡片只从记忆的清单（asks）出；没有"要你亲自看"的卡片，也没有"最近记下了这些"。"""
        ids = make_memory(self.path)
        items = self.src.poll(NOW)
        keys = sorted(it.key for it in items)
        self.assertEqual(keys, sorted(f"memory/ask/{ids[k]}" for k in ("ask", "pick", "q习惯", "建议")))
        for it in items:
            self.assertEqual(a2ui.validate(it.card), [], it.key)
            self.assertNotIn("牙医", it.title + it.summary + str(it.card), "清单里没问到的不上卡片")

    def ask_item(self, ids, key):
        return next(it for it in self.by_prefix("memory/ask/") if it.extra["ask"] == ids[key])

    def test_question_about_a_guess(self):
        ids = make_memory(self.path)
        q = self.ask_item(ids, "q习惯")
        texts = [c.get("text") or "" for m in q.card if "updateComponents" in m for c in m["updateComponents"]["components"]]
        self.assertIn("你几次都这样处理，想确认以后照这个习惯建议。确认后，邮件助手会照这个习惯给出处理建议。", texts, "理由写在正文")
        r = self.src.handle(q, "mem.reply", {"ask": 99999, "choice": "yes"}, NOW)
        self.assertTrue(r["error"], "不是这张卡片上的问题")
        r = self.src.handle(q, "mem.reply", {"ask": ids["q习惯"], "choice": "revise", "text": "  "}, NOW)
        self.assertTrue(r["error"])
        r = self.src.handle(q, "mem.reply", {"ask": ids["q习惯"], "choice": "yes"}, NOW)
        self.assertEqual(r["text"], "记下了：对。")
        w = lm.WholeMemory(self.path)
        self.assertEqual(w.note(ids["习惯"])["status"], "active")
        w.db.close()
        self.src.handle(q, "mem.open", {"note": ids["习惯"]}, NOW)
        self.assertEqual(self.opened, [ids["习惯"]])

    def test_it_was_so_but_not_now(self):
        """luoke-mem 0.23：想问的多了"以前是，现在不是"（reply past），那条理解成以前的事。"""
        ids = make_memory(self.path)
        q = self.ask_item(ids, "q习惯")
        labels = [c.get("text") for m in q.card if "updateComponents" in m for c in m["updateComponents"]["components"]]
        self.assertIn("以前是，现在不是", labels)
        r = self.src.handle(q, "mem.reply", {"ask": ids["q习惯"], "choice": "past"}, NOW)
        self.assertEqual(r["text"], "记下了：以前是，现在不是。")
        w = lm.WholeMemory(self.path)
        self.assertEqual(w.note(ids["习惯"])["status"], "past")
        w.db.close()

    def test_later_puts_the_question_off(self):
        ids = make_memory(self.path)
        q = self.ask_item(ids, "q习惯")
        r = self.src.handle(q, "mem.reply", {"ask": ids["q习惯"], "choice": "later"}, NOW)
        self.assertTrue(r["done"])
        self.assertNotIn(q.key, [it.key for it in self.src.poll(NOW)])
        # 什么时候再问由记忆定（luoke-mem 0.17：later 把这条想问的先收起，反刍过一阵再挑）
        w = lm.WholeMemory(self.path)
        later = w.records(topic="note-later")
        w.db.close()
        self.assertEqual(len(later), 1, "以后再说记成回执，不是否定")

    def test_suggestion_is_informational(self):
        ids = make_memory(self.path)
        sug = self.ask_item(ids, "建议")
        events = [c["action"]["event"]["name"] for m in sug.card if "updateComponents" in m
                  for c in m["updateComponents"]["components"] if c.get("component") == "Button"]
        self.assertEqual(set(events), {"mem.reply"}, "建议不调工具，执行是工具的事")
        choices = [c["action"]["event"]["context"]["choice"] for m in sug.card if "updateComponents" in m
                   for c in m["updateComponents"]["components"] if c.get("component") == "Button"]
        self.assertEqual(choices, ["useful", "useless", "never"] + (["archive"] if hasattr(lm.Memory, "archive") else []),
                         "是非类的建议：好 / 不用 / 别再提（自带的记忆能归档时最后加「归档」）")
        self.assertTrue(self.src.handle(sug, "mem.reply", {"ask": ids["建议"], "choice": "yes"}, NOW)["error"])
        r = self.src.handle(sug, "mem.reply", {"ask": ids["建议"], "choice": "useful"}, NOW)
        self.assertEqual(r["text"], "好。")

    def test_free_questions(self):
        ids = make_memory(self.path)
        yes_no, pick = self.ask_item(ids, "ask"), self.ask_item(ids, "pick")
        r = self.src.handle(yes_no, "mem.reply", {"ask": ids["ask"], "choice": "answer", "text": "是"}, NOW)
        self.assertEqual(r["text"], "记下了。")
        s = a2ui.build(pick.card)
        self.assertEqual(s.data["choices"]["reply"], ["周五"])
        r = self.src.handle(pick, "mem.reply", {"ask": ids["pick"], "choice": "answer", "text": ["周一"]}, NOW)
        self.assertTrue(r["done"])
        self.assertTrue(self.src.handle(pick, "mem.reply", {"ask": ids["pick"], "choice": "yes"}, NOW)["error"],
                        "自由问答没有对不对")
        w = lm.WholeMemory(self.path)
        answers = [x["text"] for x in w.records(topic="ask-answer")]
        w.db.close()
        self.assertTrue(any("答：周一" in a for a in answers))

    def test_free_question_later(self):
        """luoke-mem 0.23.4：自由问题也能「以后再说」，什么时候再问由记忆定；旧的库不收时卡片不关。"""
        ids = make_memory(self.path)
        pick = self.ask_item(ids, "pick")
        r = self.src.handle(pick, "mem.reply", {"ask": ids["pick"], "choice": "later"}, NOW)
        self.assertTrue(r["done"])
        self.assertNotIn(pick.key, [it.key for it in self.src.poll(NOW)])
        yes_no = self.ask_item(ids, "ask")
        mem = self.src._open()
        real = mem.reply

        def old_reply(aid, choice, text=None, **kw):
            if choice == "later":
                raise ValueError("not an answer to this: later")
            return real(aid, choice, text, **kw)
        mem.reply = old_reply
        r = self.src.handle(yes_no, "mem.reply", {"ask": ids["ask"], "choice": "later"}, NOW)
        self.assertTrue(r["error"])
        self.assertNotIn("done", r)

    def test_users_words_belong_to_memory(self):
        """顶层 ADR 0015：经 agent 交回的话记在 luoke-mem 名下、注明经 luoke-agent；卸载 agent 时不跟着忘掉。"""
        ids = make_memory(self.path)
        self.src.handle(self.ask_item(ids, "q习惯"), "mem.reply",
                        {"ask": ids["q习惯"], "choice": "revise", "text": "某某商城的邮件一律归档"}, NOW)
        self.src.handle(self.ask_item(ids, "ask"), "mem.reply", {"ask": ids["ask"], "choice": "answer", "text": "是"}, NOW)
        self.src.close()
        w = lm.WholeMemory(self.path)
        said = [r for r in w.records() if r["topic"] in ("note-decision", "ask-answer")]
        self.assertTrue(said)
        for r in said:
            self.assertEqual(r["tool"], "luoke-mem")
            self.assertEqual((r["data"] or {}).get("via"), "luoke-agent")
        revised = [n for n in w.notes(kinds=["preference"]) if n["text"] == "某某商城的邮件一律归档"]
        self.assertEqual([n["tool"] for n in revised], ["luoke-mem"])
        w.db.close()
        gone = lm.Memory(self.path, tool="luoke-agent").forget_tool()
        self.assertEqual(gone, {"records": 0, "notes": 0}, "agent 自己什么都不记")

    def test_cites_on_the_card(self):
        """顶层 ADR 0013：依据的原文直接放在卡片上（谁、哪天、原话，新的在前，最多 3 条）；没有就用记忆给的一句依据。"""
        ids = make_memory(self.path)
        q = self.ask_item(ids, "q习惯")
        texts = [c.get("text") or "" for m in q.card if "updateComponents" in m for c in m["updateComponents"]["components"]]
        shown = [t for t in texts if t.startswith("邮件助手 · ")]
        self.assertEqual(len(shown), 3, "luoke_mem 0.23 起别的工具的原文也给 agent")
        self.assertIn("把某某商城的邮件改成归档", shown[0])
        long = "很长的一句" * 40
        cites = [{"tool": "luoke-mail", "happened_at": f"2026-10-1{i} 09:00:00", "text": long if i == 0 else f"第 {i} 条  原话"}
                 for i in range(5)]

        class Stub:
            def note(self, nid):
                return {"id": nid, "cites": cites} if nid == 7 else None
        got = self.src._cites(Stub(), 7)
        self.assertEqual(len(got), 3)
        self.assertTrue(got[0].startswith("邮件助手 · 2026-10-10："))
        self.assertTrue(got[0].endswith("…"))
        self.assertEqual(got[1], "邮件助手 · 2026-10-11：第 1 条 原话")
        self.assertEqual(self.src._cites(Stub(), 8), [])
        self.assertEqual(self.src._cites(Stub(), None), [])
        a = {"id": 1, "kind": "question", "text": "以后某某商城的邮件都归档？", "about_note": 7, "evidence": "一句依据"}
        texts = [c.get("text") for m in self.src._ask_item(a, got).card if "updateComponents" in m
                 for c in m["updateComponents"]["components"]]
        self.assertIn(got[2], texts)
        self.assertNotIn("依据：一句依据", texts, "有原文就不用那一句")
        texts = [c.get("text") for m in self.src._ask_item(a).card if "updateComponents" in m
                 for c in m["updateComponents"]["components"]]
        self.assertIn("依据：一句依据", texts)

    def test_refuses_real_memory_in_tests(self):
        with self.assertRaises(RuntimeError):
            MemorySource(os.path.expanduser("~/.luoke/mem.db"), self.state)


if __name__ == "__main__":
    unittest.main()
