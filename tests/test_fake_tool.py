"""对着假的邮件工具，把 agent 这边会做的一遍走通：读 outbox → 查卡片 → 用户改选项、点按钮 → 执行 → 撤销。"""
from __future__ import annotations

import os as _os

assert _os.environ.get("LUOKE_AGENT_TESTING") == "1", "用 python3 -m unittest 跑：tests/__init__.py 先把一切指到临时目录"

import os
import shutil
import tempfile
import unittest

from luoke_agent import a2ui
from luoke_agent.fake_tool import ACCESSORY, FakeMail
from luoke_agent.mcp import ToolClient


def user_action(surface, component):
    return {"surfaceId": surface, "componentId": component, "at": "2026-10-15T09:00:00+08:00"}


def button(surface, event):
    """现在画着的那个、动作是 `event` 的按钮。"""
    comps = surface.components
    return next(cid for cid in a2ui._reachable(comps)
                if comps[cid].get("component") == "Button" and comps[cid]["action"]["event"]["name"] == event)


class FakeToolTest(unittest.TestCase):
    def setUp(self):
        self.dir = tempfile.mkdtemp(prefix="la")
        self.path = os.path.join(self.dir, "run", "agent.sock")

    def tearDown(self):
        shutil.rmtree(self.dir, ignore_errors=True)

    def start(self, **kw):
        self.fake = FakeMail(**kw)
        self.server = self.fake.server().start(self.path)
        self.addCleanup(self.server.close)
        return ToolClient(self.path)

    def outbox(self, client):
        items = {i["kind"]: i for i in client.outbox(ACCESSORY)}
        for it in items.values():
            self.assertEqual(a2ui.validate(it["card"]), [], it["id"])
            for k in ("id", "urgency", "why_now", "title", "summary"):
                self.assertTrue(it.get(k), k)
        return items

    def test_apply_then_undo(self):
        c = self.start()
        items = self.outbox(c)
        self.assertEqual(set(items), {"new-mail", "suspicious"})
        self.assertEqual(items["suspicious"]["urgency"], "urgent")
        s = a2ui.build(items["new-mail"]["card"])
        first = next(k for k in s.data["choices"] if k != "rest")
        s.data = a2ui.set_path(s.data, f"/choices/{first}", ["keep"])  # 第一封先不动
        name, ctx = s.find_action(button(s, "mail_apply_plan"))
        r = c.call_tool(name, ctx, user_action=user_action(s.surface_id, "ok"))
        self.assertFalse(r.is_error, r.text)
        self.assertTrue(r.done)
        self.assertIn("归档 5 封", r.text)  # 航空那封 + 另外 4 封
        self.assertEqual(self.fake.mails[first]["draft"], False)
        s = a2ui.update(s, r.card)
        self.assertNotIn("new-mail", {i["kind"] for i in c.outbox(ACCESSORY)})
        # 撤销
        name, ctx = s.find_action(button(s, "mail_undo"))
        r = c.call_tool(name, ctx, user_action=user_action(s.surface_id, "undo"))
        self.assertFalse(r.is_error, r.text)
        self.assertTrue(all(m["folder"] == "inbox" and not m["starred"] for m in self.fake.mails.values()))
        s = a2ui.update(s, r.card)
        # 再撤一次：已经撤过了
        r = c.call_tool(name, ctx, user_action=user_action(s.surface_id, "undo"))
        self.assertEqual(r.code, "stale")

    def test_write_without_tap_is_refused(self):
        c = self.start()
        it = self.outbox(c)["suspicious"]
        s = a2ui.build(it["card"])
        name, ctx = s.find_action(button(s, "mail_apply_plan"))
        r = c.call_tool(name, ctx)
        self.assertEqual(r.code, "needs_user_action")
        self.assertTrue(all(m["folder"] == "inbox" for m in self.fake.mails.values()))

    def test_choice_outside_card_is_refused(self):
        c = self.start()
        s = a2ui.build(self.outbox(c)["suspicious"]["card"])
        name, ctx = s.find_action(button(s, "mail_apply_plan"))
        key = next(iter(ctx["choices"]))
        ctx["choices"][key] = ["trash"]  # 卡片上没有这个选项
        r = c.call_tool(name, ctx, user_action=user_action(s.surface_id, "ok"))
        self.assertEqual(r.code, "invalid")

    def test_needs_setup_keeps_choices(self):
        c = self.start(processing=False)
        s = a2ui.build(self.outbox(c)["new-mail"]["card"])
        first = next(k for k in s.data["choices"] if k != "rest")
        s.data = a2ui.set_path(s.data, f"/choices/{first}", ["keep"])
        name, ctx = s.find_action(button(s, "mail_apply_plan"))
        r = c.call_tool(name, ctx, user_action=user_action(s.surface_id, "ok"))
        self.assertTrue(r.is_error)
        self.assertEqual(r.code, "needs_setup")
        s = a2ui.update(s, r.card)
        self.assertEqual(s.data["choices"][first], ["keep"])
        name, ctx = s.find_action(button(s, "mail_open_settings"))
        self.assertFalse(c.call_tool(name, ctx).is_error)  # 只读：不用点按凭据
        self.assertEqual(self.fake.opened, ["settings"])

    def test_ack(self):
        c = self.start()
        sid = self.outbox(c)["suspicious"]["id"]
        self.assertFalse(c.call_tool("outbox_ack", {"id": sid, "state": "shown"}).is_error)
        self.assertIn(sid, self.fake.shown)
        c.call_tool("outbox_ack", {"id": sid, "state": "dismissed"})
        self.assertNotIn("suspicious", {i["kind"] for i in c.outbox(ACCESSORY)})


if __name__ == "__main__":
    unittest.main()
