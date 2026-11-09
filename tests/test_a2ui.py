from __future__ import annotations

import os as _os

assert _os.environ.get("LUOKE_AGENT_TESTING") == "1", "用 python3 -m unittest 跑：tests/__init__.py 先把一切指到临时目录"

import copy
import unittest

from luoke_agent import a2ui, cards, textcard
from luoke_agent.a2ui import CardError

V = "v0.9"


def card(components, data=None, catalog=a2ui.AGENT_CATALOG):
    out = [{"version": V, "createSurface": {"surfaceId": "s", "catalogId": catalog}},
           {"version": V, "updateComponents": {"surfaceId": "s", "components": components}}]
    if data is not None:
        out.append({"version": V, "updateDataModel": {"surfaceId": "s", "path": "/", "value": data}})
    return out


def plan():
    return cards.plan_card("p1", "这 2 封我打算这样处理", [
        {"key": "m1", "label": "王老师：答辩时间", "detail": "周五前回",
         "options": [("draft", "写草稿"), ("keep", "先不动")], "selected": "draft"},
        {"key": "rest", "label": "另外 4 封", "options": [("archive", "照建议归档"), ("keep", "先不动")],
         "selected": "archive"},
    ], apply_event="mail_apply_plan", plan_id="p1",
        extra_buttons=[cards.open_url_button("加入日程", "https://calendar.google.com/x")])


class ValidateTest(unittest.TestCase):
    def test_plan_card_is_valid(self):
        self.assertEqual(a2ui.validate(plan()), [])

    def test_basic_problems(self):
        text = {"id": "root", "component": "Text", "text": "hi"}
        self.assertEqual(a2ui.validate(card([text])), [])
        self.assertTrue(a2ui.validate([]))
        self.assertTrue(a2ui.validate(card([text])[1:]), "第一条要是 createSurface")
        self.assertTrue(a2ui.validate(card([text], catalog="x")))
        self.assertIn("没有 id 为 root 的组件", a2ui.validate(card([{"id": "a", "component": "Text", "text": "x"}])))
        probs = a2ui.validate(card([{"id": "root", "component": "Image", "url": "x"}]))
        self.assertTrue(any("Image" in p for p in probs))
        bad_version = card([text])
        bad_version[1]["version"] = "v0.8"
        self.assertTrue(a2ui.validate(bad_version))

    def test_references_cycles_parents(self):
        dangling = card([{"id": "root", "component": "Column", "children": ["nope"]}])
        self.assertTrue(any("不存在" in p for p in a2ui.validate(dangling)))
        cyc = card([{"id": "root", "component": "Column", "children": ["a"]},
                    {"id": "a", "component": "Row", "children": ["b"]},
                    {"id": "b", "component": "Card", "child": "a"}])
        probs = a2ui.validate(cyc)
        self.assertTrue(any("环" in p or "两个父组件" in p for p in probs), probs)
        two = card([{"id": "root", "component": "Column", "children": ["a", "b"]},
                    {"id": "a", "component": "Card", "child": "t"},
                    {"id": "b", "component": "Card", "child": "t"},
                    {"id": "t", "component": "Text", "text": "x"}])
        self.assertTrue(any("两个父组件" in p for p in a2ui.validate(two)))
        tmpl = card([{"id": "root", "component": "List", "children": {"componentId": "t", "path": "/xs"}}])
        self.assertTrue(any("模板" in p for p in a2ui.validate(tmpl)))

    def test_bindings_and_types(self):
        unbound = card([{"id": "root", "component": "CheckBox", "label": "x", "value": {"path": "/on"}}], {})
        self.assertTrue(any("/on" in p for p in a2ui.validate(unbound)))
        ok = card([{"id": "root", "component": "CheckBox", "label": "x", "value": {"path": "/on"}}], {"on": True})
        self.assertEqual(a2ui.validate(ok), [])
        single = card([{"id": "root", "component": "ChoicePicker", "options": [{"label": "a", "value": "a"}],
                        "value": {"path": "/v"}}], {"v": "a"})
        self.assertTrue(any("字符串数组" in p for p in a2ui.validate(single)))
        outside = card([{"id": "root", "component": "ChoicePicker", "options": [{"label": "a", "value": "a"}],
                         "value": {"path": "/v"}}], {"v": ["b"]})
        self.assertTrue(any("不在选项里" in p for p in a2ui.validate(outside)))
        number = card([{"id": "root", "component": "Text", "text": 3}])
        self.assertTrue(a2ui.validate(number))
        long = card([{"id": "root", "component": "Text", "text": "字" * (a2ui.MAX_TEXT + 1)}])
        self.assertTrue(a2ui.validate(long))
        icon = card([{"id": "root", "component": "Icon", "name": "rocket"}])
        self.assertTrue(a2ui.validate(icon))

    def test_buttons(self):
        def btn(name, context):
            return card([{"id": "root", "component": "Button", "child": "t",
                          "action": {"event": {"name": name, "context": context}}},
                         {"id": "t", "component": "Text", "text": "点"}], {"x": 1})
        self.assertEqual(a2ui.validate(btn("do", {"x": {"path": "/x"}})), [])
        self.assertTrue(a2ui.validate(btn("do", {"x": {"path": "/y"}})))
        self.assertTrue(a2ui.validate(btn("agent.rm_rf", {})))
        self.assertTrue(a2ui.validate(btn("agent.open_url", {"url": "http://example.com"})))
        self.assertTrue(a2ui.validate(btn("agent.open_url", {"url": {"path": "/x"}})))
        self.assertEqual(a2ui.validate(btn("agent.open_url", {"url": "https://example.com"})), [])
        self.assertTrue(a2ui.validate(btn("agent.open_url", {"url": "https://u@evil.example/"})))

    def test_open_url_site(self):
        """显示的网站和打开的网址出自同一次解析；解析可能和浏览器不一致的都不认（工具协议 §5）。"""
        good = {
            "https://calendar.google.com/x?a=1": ("calendar.google.com", "https://calendar.google.com/x?a=1"),
            "https://EXAMPLE.com:443/a": ("example.com", "https://example.com/a"),
            "https://example.com:8443": ("example.com:8443", "https://example.com:8443"),
            "https://bücher.example/路径?q=中#f": ("xn--bcher-kva.example",
                                                "https://xn--bcher-kva.example/%E8%B7%AF%E5%BE%84?q=%E4%B8%AD#f"),
            "https://\u0430pple.com/": ("xn--pple-43d.com", "https://xn--pple-43d.com/"),
            "https://example\u3002com/": ("example.com", "https://example.com/"),
            "https://127.0.0.1/": ("127.0.0.1", "https://127.0.0.1/"),
            "https://example.com/?a@b": ("example.com", "https://example.com/?a@b"),
            'https://example.com/"q"<x>': ("example.com", "https://example.com/%22q%22%3Cx%3E"),
        }
        for url, want in good.items():
            with self.subTest(url=url):
                self.assertEqual(a2ui.open_url_site(url), want)
        bad = ["https://example.com/\ud800", "https://exa\udfffmple.com", "http://example.com", "https://", "https:///evil.example", "https://?x", "https://example.com\\@evil.example/",
               "https://user:pass@evil.example/", "https://user@evil.example", "https://exa\tmple.com", "https://example.com/a b",
               "https://evil.example\u202e/moc.elgoog", "https://exa\u200bmple.com", "https://ex\u00a0ample.com",
               "https://%65vil.example", "https://0x7f.1/", "https://127.1/", "https://2130706433/", "https://[::1]/",
               "https://example.com:/", "https://example.com:99999", "https://example.com:0", "https://example.com:\uff18\uff10",
               "https://example.com./", "https://a..example/", "https://-x.example/", "https://ex!ample.com/",
               "https://" + "a" * 64 + ".example/", "https://example.com/" + "x" * a2ui.MAX_TEXT, None, 3,
               {"path": "/url"}]
        for url in bad:
            with self.subTest(url=url):
                self.assertIsNone(a2ui.open_url_site(url))

    def test_open_url_label_must_be_literal_text(self):
        def card_with(label, data=None):
            return card([{"id": "root", "component": "Button", "child": "t",
                          "action": {"event": {"name": "agent.open_url", "context": {"url": "https://example.com"}}}}, label],
                        data)
        self.assertEqual(a2ui.validate(card_with({"id": "t", "component": "Text", "text": "打开"})), [])
        self.assertTrue(a2ui.validate(card_with({"id": "t", "component": "Text", "text": {"path": "/l"}}, {"l": "打开"})))
        self.assertTrue(a2ui.validate(card_with({"id": "t", "component": "Row", "children": []})))
        odd = card([{"id": "root", "component": "Button", "child": ["t"],
                     "action": {"event": {"name": "agent.open_url", "context": {"url": "https://example.com"}}}},
                    {"id": "t", "component": "Text", "text": "打开"}])
        self.assertTrue(a2ui.validate(odd), "child 不是编号：查出问题，不抛别的错")
        ok = card_with({"id": "t", "component": "Text", "text": "打开"})
        s = a2ui.build(ok)
        swap = [{"version": a2ui.VERSION, "updateComponents": {"surfaceId": "s", "components": [
            {"id": "t", "component": "Text", "text": {"path": "/l"}}]}},
                {"version": a2ui.VERSION, "updateDataModel": {"surfaceId": "s", "path": "/l", "value": "打开"}}]
        with self.assertRaises(a2ui.CardError):
            a2ui.update(s, swap)
        tool_button = card([{"id": "root", "component": "Button", "child": "t", "action": {"event": {"name": "do", "context": {}}}},
                            {"id": "t", "component": "Text", "text": {"path": "/l"}}], {"l": "删除 3 个"})
        self.assertEqual(a2ui.validate(tool_button), [], "只管打开网页的按钮")

    def test_progress_bar(self):
        def bar(**props):
            return card([{"id": "root", "component": "ProgressBar", **props}])
        for value in (0, 0.5, 1):
            self.assertEqual(a2ui.validate(bar(value=value)), [])
        for value in (-0.1, 1.5, "0.5", True, None, {"path": "/x"}):
            self.assertTrue(a2ui.validate(bar(value=value)), value)
        self.assertTrue(a2ui.validate(bar()))
        self.assertTrue(a2ui.validate(card([{"id": "root", "component": "ProgressBar", "value": 0.5}],
                                           catalog=a2ui.IME_CATALOG)))

    def test_progress_bar_in_text(self):
        surface = a2ui.build(card([{"id": "root", "component": "ProgressBar", "value": 0.5}]))
        self.assertEqual(textcard.render(surface), ["50%"])

    def test_switch_button_keeps_button_rules(self):
        def switch(name):
            return card([{"id": "root", "component": "Button", "child": "t", "variant": "switch", "on": True,
                          "action": {"event": {"name": name, "context": {}}}},
                         {"id": "t", "component": "Text", "text": "也搜照片"}])
        self.assertEqual(a2ui.validate(switch("do")), [])
        self.assertTrue(a2ui.validate(switch("agent.rm_rf")))

    def test_open_url_is_never_a_switch(self):
        comps = [{"id": "root", "component": "Button", "child": "t", "variant": "switch", "on": False,
                  "action": {"event": {"name": "agent.open_url", "context": {"url": "https://example.com"}}}},
                 {"id": "t", "component": "Text", "text": "也搜照片"}]
        self.assertTrue(any("开关" in p for p in a2ui.validate(card(comps))))

    def test_too_many(self):
        comps = [{"id": "root", "component": "Column", "children": [f"t{i}" for i in range(a2ui.MAX_COMPONENTS)]}]
        comps += [{"id": f"t{i}", "component": "Text", "text": "x"} for i in range(a2ui.MAX_COMPONENTS)]
        self.assertTrue(any("超过" in p for p in a2ui.validate(card(comps))))

    def test_ime_catalog(self):
        slider = [{"id": "root", "component": "Slider", "value": {"path": "/n"}, "min": 0, "max": 5}]
        self.assertEqual(a2ui.validate(card(slider, {"n": 2}, a2ui.IME_CATALOG), a2ui.IME_CATALOG), [])
        self.assertTrue(a2ui.validate(card(slider, {"n": 2}), a2ui.AGENT_CATALOG))
        cardc = [{"id": "root", "component": "Card", "child": "t"}, {"id": "t", "component": "Text", "text": "x"}]
        self.assertTrue(a2ui.validate(card(cardc, catalog=a2ui.IME_CATALOG), a2ui.IME_CATALOG))


class SurfaceTest(unittest.TestCase):
    def test_find_action_resolves_current_choices(self):
        s = a2ui.build(plan())
        s.data = a2ui.set_path(s.data, "/choices/m1", ["keep"])  # 用户改了选项
        ok = next(c["id"] for c in s.components.values()
                  if c.get("component") == "Button" and c["action"]["event"]["name"] == "mail_apply_plan")
        name, ctx = s.find_action(ok)
        self.assertEqual(name, "mail_apply_plan")
        self.assertEqual(ctx, {"plan_id": "p1", "choices": {"m1": ["keep"], "rest": ["archive"]}})
        with self.assertRaises(CardError):
            s.find_action("root")

    def test_result_replaces_plan(self):
        s = a2ui.build(plan())
        after = a2ui.update(s, cards.result_card("p1", "已归档 4 封。", undo_event="mail_undo",
                                                  undo_context={"execution_id": "e1"}))
        texts = [c["text"] for c in after.components.values() if c.get("component") == "Text"]
        self.assertIn("已归档 4 封。", texts)
        undo = next(c["id"] for c in after.components.values()
                    if c.get("component") == "Button" and c["action"]["event"]["name"] == "mail_undo")
        self.assertEqual(after.find_action(undo), ("mail_undo", {"execution_id": "e1"}))
        # 撤销后再换一次，旧组件留着也不算两个父组件
        a2ui.update(after, cards.result_card("p1", "已撤销。"))

    def test_bad_update_keeps_original(self):
        s = a2ui.build(plan())
        before = copy.deepcopy(s.components)
        with self.assertRaises(CardError):
            a2ui.update(s, [{"version": V, "updateComponents": {"surfaceId": "p1", "components": [
                {"id": "root", "component": "Image"}]}}])
        with self.assertRaises(CardError):
            a2ui.update(s, [{"version": V, "updateComponents": {"surfaceId": "other", "components": [
                {"id": "root", "component": "Text", "text": "x"}]}}])
        self.assertEqual(s.components, before)

    def test_replot_keeps_user_choices(self):
        s = a2ui.build(plan())
        s.data = a2ui.set_path(s.data, "/choices/m1", ["keep"])
        again = cards.plan_card("p1", "标题", [
            {"key": "m1", "label": "王老师", "options": [("draft", "写草稿"), ("keep", "先不动")], "selected": "draft"},
            {"key": "rest", "label": "另外", "options": [("archive", "归档"), ("keep", "先不动")], "selected": "archive"},
        ], apply_event="mail_apply_plan", plan_id="p1", note="先开处理模式", update=True, id_prefix="s1-")
        after = a2ui.update(s, again)
        self.assertEqual(after.data["choices"]["m1"], ["keep"])

    def test_delete_and_messages(self):
        s = a2ui.build(plan())
        msgs = s.messages()
        self.assertEqual(a2ui.validate(msgs), [])
        gone = a2ui.update(s, [{"version": V, "deleteSurface": {"surfaceId": "p1"}}])
        self.assertTrue(gone.deleted)

    def test_paths(self):
        d = {"a": {"b": [1, {"c": 2}]}, "x~y/z": 3}
        self.assertEqual(a2ui.get_path(d, "/a/b/1/c"), 2)
        self.assertEqual(a2ui.get_path(d, "/x~0y~1z"), 3)
        with self.assertRaises(KeyError):
            a2ui.get_path(d, "/a/nope")
        d = a2ui.set_path(d, "/new/deep", 1)
        self.assertEqual(d["new"], {"deep": 1})
        d = a2ui.set_path(d, "/new", None, remove=True)
        self.assertNotIn("new", d)
        self.assertEqual(a2ui.resolve({"k": [{"path": "/a/b/0"}, "lit"]}, d), {"k": [1, "lit"]})


if __name__ == "__main__":
    unittest.main()
