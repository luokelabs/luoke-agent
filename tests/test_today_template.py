"""「今天」新模板：cards.py 的拼法、旧的核心上退回原来的样子、对照稿的示例跟得上。"""
from __future__ import annotations

import os
import subprocess
import sys
import unittest

from luoke_agent import a2ui, cards

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
NEW = list(cards.NEW_TEMPLATE)


def comps(msgs):
    out = {}
    for m in msgs:
        for c in (m.get("updateComponents") or {}).get("components") or []:
            out[c["id"]] = c
    return out


def items():
    return [{"key": "m1", "who": "CareerLink 事務局", "subject": "IT 交流会", "why": "今天截止报名", "due": "今天截止",
             "due_tone": "warning", "options": [("flag", "加星标", "star"), ("keep", "先不动", "circle-minus")],
             "selected": "flag",
             "extra": cards.open_url_button("11-12 16:00", "https://calendar.google.com/x", icon="calendar-plus",
                                            tooltip="加入日程")},
            {"key": "m2", "label": "SignFlow Account：New Device Login", "options": [("flag", "加星标", "star")],
             "selected": "flag"}]


class CardsTest(unittest.TestCase):
    def test_host_features(self):
        meta = {"io.modelcontextprotocol/clientCapabilities": {"experimental": {"ai.luoke/a2ui": {"features": NEW}}}}
        self.assertEqual(cards.host_features(meta), frozenset(NEW))
        self.assertEqual(cards.host_features({"io.modelcontextprotocol/clientCapabilities": {}}), frozenset())
        self.assertEqual(cards.host_features(None), frozenset())

    def test_plan_card_new_template(self):
        msgs = cards.plan_card("p", "5 封要处理", items(), apply_event="mail_apply_plan", plan_id="p",
                               apply_label="加星标 2", badge="ming@harbor-tech.example", features=NEW)
        self.assertEqual(a2ui.validate(msgs), [])
        c = comps(msgs)
        variants = {x.get("variant") for x in c.values() if x["component"] == "Text"}
        self.assertTrue({"badge", "strong", "h4"} <= variants)
        self.assertTrue(any(x["component"] == "List" for x in c.values()), "一封一行的列表")
        rows = [x for x in c.values() if x.get("justify") == "spaceBetween"]
        self.assertEqual(len(rows), 2)
        self.assertEqual(c[rows[0]["children"][1]]["id"], "c-m1", "选择框还是 c-<key>，点按照旧")
        self.assertEqual(c["c-m1"]["options"][0]["icon"], "star")
        cal = c[rows[0]["children"][2]]
        self.assertEqual(cal["tooltip"], "加入日程")
        self.assertEqual(c[c[cal["child"]]["children"][0]]["name"], "calendar-plus", "图标 + 字")
        self.assertEqual(c["c-m2"]["label"], "SignFlow Account：New Device Login", "读屏念的还是整句")
        labels = [c[b["child"]] for b in c.values() if b["component"] == "Button" and b.get("variant") == "primary"]
        self.assertTrue(labels, "主按钮")
        self.assertEqual(comps(msgs)[c[labels[0]["id"]]["children"][1]]["text"], "加星标 2", "主按钮的字由工具给")

    def test_old_core_gets_the_old_layout(self):
        msgs = cards.plan_card("p", "5 封要处理", items(), apply_event="mail_apply_plan", plan_id="p",
                               apply_label="加星标 2", badge="ming@harbor-tech.example", features=["placement"])
        c = comps(msgs)
        self.assertFalse(any(x.get("variant") in ("badge", "strong") for x in c.values()))
        self.assertFalse(any(x["component"] == "List" for x in c.values()))
        self.assertFalse(any("tooltip" in x for x in c.values()))
        self.assertFalse(any(x["component"] == "Icon" and x["name"] not in cards.OLD_ICONS for x in c.values()))
        self.assertIn("（ming@harbor-tech.example）", next(x["text"] for x in c.values() if x.get("variant") == "h4"))
        self.assertEqual(c["c-m1"]["label"], "CareerLink 事務局：IT 交流会（今天截止）")

    def test_mailbox_card_parts(self):
        parts = [{"icon": "inbox", "title": "待处理", "items": items()[:1],
                  "buttons": [cards.button("加星标 1", "mail_apply_plan", {"choices": cards.CHOICES}, primary=True, icon="check")]},
                 {"icon": "archive", "title": "可以整理", "note": "多是 CoinDigest",
                  "buttons": [cards.button("归档 3", "mail_apply_plan", {}, primary=True, icon="archive")]},
                 {"icon": "shield-alert", "title": "判为可疑", "collapsed": "2 封，都先不动", "items": items()[1:],
                  "buttons": [cards.button("按选的处理", "mail_apply_plan", {}, primary=True, icon="check")]}]
        msgs = cards.mailbox_card("box", "邮箱", parts, badge="ming@harbor-tech.example")
        self.assertEqual(a2ui.validate(msgs), [])
        c = comps(msgs)
        root = c["root"]["children"]
        self.assertEqual([c[k]["component"] for k in root],
                         ["Row", "Divider", "Row", "Column", "Divider", "Row", "Column", "Divider", "Row", "Column"])
        self.assertEqual(c[root[-1]]["collapsed"], "2 封，都先不动")
        self.assertNotIn("collapsed", c[root[3]])
        old = comps(cards.mailbox_card("box", "邮箱", parts, badge="a@b", features=[]))
        self.assertFalse(any("collapsed" in x or x.get("variant") == "badge" for x in old.values()))

    def test_result_card_group(self):
        g = cards.done_group("harbor/spam", "已移到垃圾邮件 {n} 封", 2, label="可疑邮件", badge="ming@harbor-tech.example")
        msgs = [{"version": cards.VERSION, "createSurface": {"surfaceId": "r", "catalogId": cards.CATALOG}}] + \
            cards.result_card("r", "已移到垃圾邮件 2 封", undo_event="mail_undo", group=g)
        self.assertEqual(a2ui.validate(msgs), [])
        self.assertEqual(comps(msgs)["root"]["group"], g)
        bad = [{"id": "root", "component": "Column", "children": ["t"]},
               {"id": "t", "component": "Text", "text": "x", "group": {"key": "k", "text": "x", "n": 1}}]
        msgs = [{"version": cards.VERSION, "createSurface": {"surfaceId": "s", "catalogId": cards.CATALOG}},
                {"version": cards.VERSION, "updateComponents": {"surfaceId": "s", "components": bad}}]
        self.assertTrue(any("只能写在 root 上" in p for p in a2ui.validate(msgs)))

    def test_template_sample_is_up_to_date(self):
        r = subprocess.run([sys.executable, "-B", os.path.join(ROOT, "scripts", "today_template.py"), "--check"],
                           capture_output=True, text=True, timeout=60)
        self.assertEqual(r.returncode, 0, r.stdout + r.stderr)


if __name__ == "__main__":
    unittest.main()
