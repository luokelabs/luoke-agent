from __future__ import annotations

import os as _os

assert _os.environ.get("LUOKE_AGENT_TESTING") == "1", "用 python3 -m unittest 跑：tests/__init__.py 先把一切指到临时目录"

import copy
import sys
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
    ], apply_event="mail_apply_plan", plan_id="p1", apply_label="写草稿 1 · 归档 4",
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

    def test_open_page_names_only_a_page_of_its_own(self):
        def btn(ctx, variant=None):
            b = {"id": "root", "component": "Button", "child": "t",
                 "action": {"event": {"name": "agent.open_page", "context": ctx}}}
            if variant:
                b.update(variant=variant, on=False)
            return card([b, {"id": "t", "component": "Text", "text": "去扫描页看 12 项"}])
        self.assertEqual(a2ui.validate(btn({"page": "overview"})), [])
        for ctx in ({"page": "luoke-mail/accounts"}, {"app": "luoke-mail", "page": "accounts"}, {"page": "../x"},
                    {"page": ""}, {}, {"page": 3}):
            self.assertTrue(any("agent.open_page 只开这个应用自己的页" in p for p in a2ui.validate(btn(ctx))), ctx)
        self.assertTrue(any("开关" in p for p in a2ui.validate(btn({"page": "overview"}, "switch"))))

    def test_count_label(self):
        def btn(count, data=None):
            return card([{"id": "root", "component": "Button", "child": "t", "count": count,
                          "action": {"event": {"name": "scan_apply", "context": {"choices": {"path": "/choices"}}}}},
                         {"id": "t", "component": "Text", "text": "移到废纸篓 {n} 项"}],
                        data if data is not None else {"choices": {"i0": ["trash"], "i1": ["keep"], "i2": ["trash"]}, "n": 1})
        ok = {"path": "/choices", "value": "trash"}
        self.assertEqual(a2ui.validate(btn(ok)), [])
        for bad in ({"path": "/choices"}, {"path": "/choices", "value": ""}, {"path": "/choices", "value": "trash", "x": 1},
                    "trash", {"path": "/nope", "value": "trash"}, {"path": "/n", "value": "trash"}):
            self.assertTrue(any("count" in p for p in a2ui.validate(btn(bad))), bad)
        data = {"choices": {"i0": ["trash"], "i1": ["keep"], "i2": ["trash"]}}
        self.assertEqual(a2ui.count_chosen(data, ok), 2)
        self.assertEqual(a2ui.count_chosen({"choices": {}}, ok), 0)
        self.assertEqual(a2ui.count_chosen({}, ok), 0)

    def test_count_weights(self):
        """§4 countWeights：一项合了好几样（41 个安装包合成一行、一个选择）时，{n} 按 weights 算几样；不写算 1；
        weights 里有、选择里没有的键不管；also 照旧。"""
        def btn(count, data=None):
            return card([{"id": "root", "component": "Button", "child": "t", "count": count,
                          "action": {"event": {"name": "scan_apply", "context": {"choices": {"path": "/choices"}}}}},
                         {"id": "t", "component": "Text", "text": "移到废纸篓 {n} 项"}],
                        data if data is not None else {"choices": {"g-pkg": ["keep"], "i1": ["keep"]}})
        ok = {"path": "/choices", "value": "trash", "weights": {"g-pkg": 41, "gone": 7}}
        self.assertEqual(a2ui.validate(btn(ok)), [])
        self.assertEqual(a2ui.validate(btn(dict(ok, weights={}))), [])
        for bad in ({"g-pkg": 0}, {"g-pkg": -1}, {"g-pkg": 1.5}, {"g-pkg": "41"}, {"g-pkg": True}, {"g-pkg": None}, [41], 41, "x"):
            self.assertTrue(any("count" in p for p in a2ui.validate(btn(dict(ok, weights=bad)))), bad)
        def n(**picks):
            return a2ui.count_chosen({"choices": {k: [v] for k, v in picks.items()}}, ok)
        self.assertEqual(n(**{"g-pkg": "trash", "i1": "keep"}), 41, "合成一行的那一组移到废纸篓：算它的 41 样")
        self.assertEqual(n(**{"g-pkg": "trash", "i1": "trash"}), 42, "一组加一项：加起来")
        self.assertEqual(n(**{"g-pkg": "keep", "i1": "trash"}), 1, "没写 weights 的键算 1")
        self.assertEqual(n(i1="trash"), 1, "weights 里有、选择里没有的键（gone、g-pkg）不管")
        also = dict(ok, also=["ignore"], alsoLabel="按上面的选择清理")
        self.assertEqual(a2ui.validate(btn(also)), [])
        data = {"choices": {"g-pkg": ["ignore"], "i1": ["keep"]}}
        self.assertEqual((a2ui.count_chosen(data, also), a2ui.count_also(data, also)), (0, True), "also 照旧")

    def test_count_also(self):
        """§4 countAlso：别的值（以后别提、换成克隆）也交得上去。{n} 照样只数 value；选了 also 里的值时按钮能点、
        字换成 alsoLabel；没选时照 countLabel（0 项灰掉）。"""
        def btn(count, data=None):
            return card([{"id": "root", "component": "Button", "child": "t", "count": count,
                          "action": {"event": {"name": "scan_apply", "context": {"choices": {"path": "/choices"}}}}},
                         {"id": "t", "component": "Text", "text": "移到废纸篓 {n} 项"}],
                        data if data is not None else {"choices": {"i0": ["keep"]}})
        ok = {"path": "/choices", "value": "trash", "also": ["ignore", "clone"], "alsoLabel": "按上面的选择清理（移到废纸篓 {n} 项）"}
        self.assertEqual(a2ui.validate(btn(ok)), [])
        for bad in (dict(ok, also=[]), dict(ok, also="ignore"), dict(ok, also=["ignore", ""]), dict(ok, also=[1]),
                    {k: v for k, v in ok.items() if k != "alsoLabel"}, {k: v for k, v in ok.items() if k != "also"},
                    dict(ok, alsoLabel=" "), dict(ok, alsoLabel=3), dict(ok, alsoLabel="x" * (a2ui.MAX_TEXT + 1)),
                    dict(ok, extra=1)):
            self.assertTrue(any("count" in p for p in a2ui.validate(btn(bad))), bad)
        def state(*picks):
            data = {"choices": {f"i{k}": [v] for k, v in enumerate(picks)}}
            return a2ui.count_chosen(data, ok), a2ui.count_also(data, ok)
        self.assertEqual(state("ignore", "keep"), (0, True), "只选了以后别提：0 项也能点，写 alsoLabel")
        self.assertEqual(state("trash", "clone"), (1, True), "混着选：写 alsoLabel，{n} 只数移到废纸篓的")
        self.assertEqual(state("keep", "keep"), (0, False), "都先不动：照 countLabel，0 项灰掉")
        self.assertEqual(state("trash", "trash"), (2, False), "只选了移到废纸篓：原来的字")
        self.assertFalse(a2ui.count_also({"choices": {"i0": ["ignore"]}}, {"path": "/choices", "value": "trash"}), "没写 also")
        self.assertFalse(a2ui.count_also({}, ok))

    def test_placement_aside_only_on_a_section_under_root(self):
        def page(root="Column", placement="aside", kind="Column", nested=False):
            sec = {"id": "a", "component": kind, "placement": placement}
            if kind == "Column":
                sec["children"] = ["t"]
            else:
                sec["text"] = "x"
            top = ["w"] if nested else ["a"]
            comps = [{"id": "root", "component": root, "children": top}, sec, {"id": "t", "component": "Text", "text": "x"}]
            if nested:
                comps.append({"id": "w", "component": "Column", "children": ["a"]})
            return card(comps)
        self.assertEqual(a2ui.validate(page()), [])
        self.assertTrue(any("placement 只能是" in p for p in a2ui.validate(page(placement="side"))))
        self.assertTrue(any("placement 只能是" in p for p in a2ui.validate(page(placement=True))))
        self.assertTrue(any("placement 只能是" in p for p in a2ui.validate(page(placement=["aside"]))))
        self.assertTrue(any("下面一层的 Column" in p for p in a2ui.validate(page(kind="Text"))))
        self.assertTrue(any("下面一层的 Column" in p for p in a2ui.validate(page(nested=True))))
        self.assertTrue(any("下面一层的 Column" in p for p in a2ui.validate(page(root="Row"))))

    def test_today_template_additions(self):
        ok = [
            [{"id": "root", "component": "Row", "children": ["w", "s", "d"]},
             {"id": "w", "component": "Text", "text": "CareerLink 事務局", "variant": "strong"},
             {"id": "s", "component": "Text", "text": "很长的主题", "maxLines": 1},
             {"id": "d", "component": "Text", "text": "今天截止", "variant": "badge", "tone": "warning"}],
            [{"id": "root", "component": "Column", "collapsed": "206 封，都先不动", "children": ["i"]},
             {"id": "i", "component": "Icon", "name": "shield-alert"}],
        ]
        for comps in ok:
            self.assertEqual(a2ui.validate(card(comps)), [], comps)
        picker = card([{"id": "root", "component": "ChoicePicker", "value": {"path": "/c"},
                        "options": [{"value": "flag", "label": "加星标", "icon": "star"},
                                    {"value": "draft", "label": "写草稿", "icon": "pencil-line"}]}], {"c": ["flag"]})
        self.assertEqual(a2ui.validate(picker), [])
        bad = {
            "tone": [{"id": "root", "component": "Text", "text": "x", "tone": "danger"}],
            "maxLines": [{"id": "root", "component": "Text", "text": "x", "maxLines": 21}],
            "collapsed": [{"id": "root", "component": "Column", "collapsed": "", "children": []}],
            "图标名": [{"id": "root", "component": "ChoicePicker", "value": ["a"],
                     "options": [{"value": "a", "label": "A", "icon": "calendar-days"}]}],
        }
        for word, comps in bad.items():
            self.assertTrue(any(word in p for p in a2ui.validate(card(comps))), word)

    def test_subtitle_only_on_root_and_plain_text(self):
        """§4 subtitle：卡片的副标题（紧凑的「今天」里分得清是哪一件），只写在 root 上，一句不空的文字。"""
        def with_sub(where, value, data=None):
            root = {"id": "root", "component": "Column", "children": ["t"]}
            t = {"id": "t", "component": "Text", "text": "一封可疑邮件"}
            (root if where == "root" else t)["subtitle"] = value
            return card([root, t], data)
        self.assertEqual(a2ui.validate(with_sub("root", "某银行 <notice@bank.example> · 账户已冻结")), [])
        for msgs in (with_sub("root", "  "), with_sub("root", 3), with_sub("root", {"path": "/s"}, {"s": "x"}),
                     with_sub("root", "x" * (a2ui.MAX_TEXT + 1)), with_sub("t", "某银行")):
            self.assertTrue(any("subtitle" in p for p in a2ui.validate(msgs)), msgs)
        c = cards.Card("s1")
        c.heading("一封可疑邮件")
        c.subtitle = "某银行 <notice@bank.example> · 账户已冻结"
        msgs = c.messages()
        self.assertEqual(a2ui.validate(msgs), [])
        root = next(x for x in msgs[1]["updateComponents"]["components"] if x["id"] == "root")
        self.assertEqual(root["subtitle"], "某银行 <notice@bank.example> · 账户已冻结", "Card.subtitle 写在 root 上")
        self.assertNotIn("subtitle", next(x for x in cards.Card("s2").messages()[1]["updateComponents"]["components"]
                                          if x["id"] == "root"), "不写就没有")

    def test_old_icon_names_still_accepted(self):
        for old, new in a2ui.ICON_ALIASES.items():
            self.assertIn(new, a2ui.LUCIDE_ICONS)
            self.assertEqual(a2ui.validate(card([{"id": "root", "component": "Icon", "name": old}])), [])

    def test_core_tells_tools_which_additions_it_knows(self):
        from luoke_agent import mcp
        sent = mcp.CLIENT_CAPABILITIES["experimental"]["ai.luoke/a2ui"]["features"]
        self.assertEqual(sent, list(a2ui.A2UI_FEATURES))

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
        ], apply_event="mail_apply_plan", plan_id="p1", apply_label="按选的处理", note="先开处理模式", update=True,
            id_prefix="s1-")
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

    def test_list_indexes_are_strict(self):
        """数组下标照 RFC 6901：只认 0 或不以 0 开头的 ASCII 数字；别的写法取不到、写不了、删不了（同 Swift 的 pointerIndex）。"""
        d = {"l": [f"v{i}" for i in range(11)], "o": {"00": "key"}}
        self.assertEqual(a2ui.get_path(d, "/l/0"), "v0")
        self.assertEqual(a2ui.get_path(d, "/l/10"), "v10")
        self.assertEqual(a2ui.get_path(d, "/o/00"), "key")          # 对象的键照原样比
        for bad in ("00", "01", "+0", "-0", "٠", "²", "０", "", " 0", "0 ", "11"):
            with self.subTest(index=bad):
                with self.assertRaises(KeyError):
                    a2ui.get_path(d, "/l/" + bad)
                with self.assertRaises(KeyError):
                    a2ui.set_path(copy.deepcopy(d), "/l/" + bad, "x")
                with self.assertRaises(KeyError):
                    a2ui.set_path(copy.deepcopy(d), "/l/" + bad, None, remove=True)
                with self.assertRaises(KeyError):
                    a2ui.set_path(copy.deepcopy(d), f"/l/{bad}/deep", "x")
        e = a2ui.set_path(copy.deepcopy(d), "/l/10", "new")
        self.assertEqual(e["l"][10], "new")
        e = a2ui.set_path(e, "/l/0", None, remove=True)
        self.assertEqual(e["l"][0], "v1")

    def test_a_huge_list_index_is_just_out_of_range(self):
        """5000 位的下标和越界一样取不到、写不了、删不了，整页校验照常报「在数据模型里没有」，不抛别的异常。
        Python 3.11 起 int() 遇到 4300 位以上的数字串抛 ValueError，_index 不能去换它。"""
        huge = "1" * 5000
        if hasattr(sys, "get_int_max_str_digits") and sys.get_int_max_str_digits():
            with self.assertRaises(ValueError):          # 这一版的 Python 真会抛，下面测的才是那条路
                int(huge)
        d = {"l": ["v0", "v1"]}
        for call in (lambda: a2ui.get_path(d, "/l/" + huge),
                     lambda: a2ui.set_path(copy.deepcopy(d), "/l/" + huge, "x"),
                     lambda: a2ui.set_path(copy.deepcopy(d), "/l/" + huge, None, remove=True),
                     lambda: a2ui.set_path(copy.deepcopy(d), f"/l/{huge}/deep", "x")):
            with self.assertRaises(KeyError):
                call()
        page = card([{"id": "root", "component": "Text", "text": {"path": "/l/" + huge}}], d)
        problems = a2ui.validate(page, page=True)
        self.assertTrue(any("在数据模型里没有" in p for p in problems), problems)



class PagesTest(unittest.TestCase):
    """应用页（§1a page/<id>）的几样（§4，2026-11-10）：pageArgs、bigPages、secureField、pageRefresh、saveFile。"""

    @staticmethod
    def many(n):
        return card([{"id": "root", "component": "Column", "children": [f"t{i}" for i in range(n - 1)]}]
                    + [{"id": f"t{i}", "component": "Text", "text": "x"} for i in range(n - 1)])

    def test_big_pages(self):
        self.assertEqual(a2ui.validate(self.many(400), page=True), [])
        self.assertTrue(any("超过 400" in p for p in a2ui.validate(self.many(401), page=True)))
        self.assertTrue(any("超过 200" in p for p in a2ui.validate(self.many(201))), "卡片照旧 200 个")
        self.assertEqual(a2ui.validate(self.many(200)), [])

    def test_refresh_only_on_a_pages_root(self):
        root = {"id": "root", "component": "Column", "children": ["t"]}
        t = {"id": "t", "component": "Text", "text": "同步中…"}
        self.assertEqual(a2ui.validate(card([dict(root, refresh=5), t]), page=True), [])
        for n in (2, 60):
            self.assertEqual(a2ui.validate(card([dict(root, refresh=n), t]), page=True), [], n)
        for n in (1, 61, "5", True, 2.5, None):
            self.assertTrue(any("refresh" in p for p in a2ui.validate(card([dict(root, refresh=n), t]), page=True)), n)
        self.assertTrue(any("refresh" in p for p in a2ui.validate(card([dict(root, refresh=5), t]))), "卡片上不认")
        self.assertTrue(any("refresh" in p for p in a2ui.validate(card([root, dict(t, refresh=5)]), page=True)), "只在 root 上")

    def test_sections_only_on_a_pages_root_column(self):
        """§4 pageSections：页的根 Column 写 layout sections，一段一张卡片；卡片上、别处、别的值都不认。"""
        root = {"id": "root", "component": "Column", "children": ["head", "sec"]}
        head = {"id": "head", "component": "Text", "text": "扫描", "variant": "h3"}
        sec = {"id": "sec", "component": "Column", "children": ["t"]}
        t = {"id": "t", "component": "Text", "text": "要你看看"}
        self.assertEqual(a2ui.validate(card([dict(root, layout="sections"), head, sec, t]), page=True), [])
        for v in ("cards", "", True, None, ["sections"]):
            self.assertTrue(any("layout" in p for p in a2ui.validate(card([dict(root, layout=v), head, sec, t]), page=True)), v)
        self.assertTrue(any("layout" in p for p in a2ui.validate(card([dict(root, layout="sections"), head, sec, t]))),
                        "卡片上不认")
        self.assertTrue(any("layout" in p for p in a2ui.validate(card([root, head, dict(sec, layout="sections"), t]), page=True)),
                        "只在 root 上")
        row_root = {"id": "root", "component": "Row", "children": ["t"], "layout": "sections"}
        self.assertTrue(any("layout" in p for p in a2ui.validate(card([row_root, t]), page=True)), "根要是 Column")

    def test_neutral_badges_and_chips(self):
        """§4 neutralBadge：badge 的 tone 可以是 neutral；chips 是一行里几个 badge，不用新属性。"""
        comps = [{"id": "root", "component": "Column", "children": ["row"]},
                 {"id": "row", "component": "Row", "children": ["a", "b", "more"]},
                 {"id": "a", "component": "Text", "text": "Alpha", "variant": "badge", "tone": "neutral"},
                 {"id": "b", "component": "Text", "text": "2.3 GB", "variant": "badge", "tone": "neutral"},
                 {"id": "more", "component": "Text", "text": "等 12 个", "variant": "caption"}]
        self.assertEqual(a2ui.validate(card(comps)), [])
        for tone in ("beige", ["neutral"], {"x": 1}):      # 不是字符串的也只报问题，不出错
            bad = [dict(c, tone=tone) if c["id"] == "a" else c for c in comps]
            self.assertTrue(any("tone" in p for p in a2ui.validate(card(bad))), tone)
        plain = [dict(c, variant="body") if c["id"] == "b" else c for c in comps]
        self.assertTrue(any("tone" in p for p in a2ui.validate(card(plain))), "tone 只写在 badge 上")
        for f in ("neutralBadge", "chips", "pageSections"):
            self.assertIn(f, a2ui.A2UI_FEATURES)

    def secure(self, value, data, *, page=True):
        return a2ui.validate(card([{"id": "root", "component": "Column", "children": ["f", "b"]},
                                   {"id": "f", "component": "TextField", "label": "授权码", "variant": "obscured", "value": value},
                                   {"id": "b", "component": "Button", "child": "bt",
                                    "action": {"event": {"name": "mail_connect", "context": {"code": {"path": "/fields/code"}}}}},
                                   {"id": "bt", "component": "Text", "text": "加上"}], data), page=page)

    def test_secure_field(self):
        bound = {"path": "/fields/code"}
        self.assertEqual(self.secure(bound, {"fields": {"code": ""}}), [])
        self.assertTrue(any("应用页" in p for p in self.secure(bound, {"fields": {"code": ""}}, page=False)), "卡片上不认")
        self.assertTrue(any("空字符串" in p for p in self.secure(bound, {"fields": {"code": "123456"}})), "工具不能先填")
        self.assertTrue(any("绑定" in p for p in self.secure("", {"fields": {"code": ""}})))
        self.assertTrue(self.secure(bound, {"fields": {}}), "绑的路径要在")
        c = cards.Card("accounts")
        c.text_field("code", "IMAP 授权码", "不会留下", secure=True)
        msgs = c.messages()
        self.assertEqual(a2ui.validate(msgs, page=True), [])
        self.assertEqual(msgs[-1]["updateDataModel"]["value"]["fields"]["code"], "", "帮手给的初值一律是空的")

    def secure_page(self, *extra, ctx=None, event="mail_connect", data=None):
        """一个密码框（/fields/code）、一个按钮，再加几个组件（都挂在 root 下面）。"""
        ctx = {"code": {"path": "/fields/code"}} if ctx is None else ctx
        return a2ui.validate(card([{"id": "root", "component": "Column", "children": ["f", "b"] + [c["id"] for c in extra]},
                                   {"id": "f", "component": "TextField", "label": "授权码", "variant": "obscured",
                                    "value": {"path": "/fields/code"}},
                                   {"id": "b", "component": "Button", "child": "bt", "action": {"event": {"name": event, "context": ctx}}},
                                   {"id": "bt", "component": "Text", "text": "加上"}] + list(extra),
                                  data or {"fields": {"code": "", "name": ""}, "q": "", "choices": {}}), page=True)

    def test_secure_field_only_by_its_own_path(self):
        """交给工具的按钮只能正好引用密码框的路径：引用它上面一层（/fields、/、空的）会连授权码整个交出去，不认"""
        self.assertEqual(self.secure_page(), [])
        for path in ("/fields", "/", ""):
            problems = self.secure_page(ctx={"all": {"path": path}})
            self.assertTrue(any("只能正好引用 /fields/code" in p for p in problems), (path, problems))
        self.assertEqual(self.secure_page(ctx={"name": {"path": "/fields/name"}, "code": {"path": "/fields/code"}}), [],
                         "旁边的路径照用")

    def test_secure_field_never_in_agent_actions(self):
        """agent.open_page 的 args 会进读页的查询串、刷新时重发、离页也清不到：不能引用密码框的路径，也不能是它上面、下面一层"""
        for path in ("/fields/code", "/fields", "/", "/fields/code/x"):
            problems = self.secure_page(ctx={"page": "notes", "args": {"q": {"path": path}}}, event="agent.open_page")
            self.assertTrue(any("agent.open_page 不能引用密码框" in p for p in problems), (path, problems))
        self.assertEqual(self.secure_page(ctx={"page": "notes", "args": {"q": {"path": "/q"}}}, event="agent.open_page"), [])

    def test_secure_field_never_shown_elsewhere(self):
        """别的绑定是密码框的路径或它上面一层，会明文显示出来：不认。几个密码框绑同一个路径不算"""
        shown = [
            {"id": "t", "component": "Text", "text": {"path": "/fields/code"}},
            {"id": "t", "component": "Text", "text": {"path": "/fields"}},
            {"id": "t", "component": "TextField", "label": "看一眼", "value": {"path": "/fields/code"}},
            {"id": "t", "component": "TextField", "label": {"path": "/fields/code"}, "value": {"path": "/fields/name"}},
            {"id": "t", "component": "CheckBox", "label": "记住", "value": {"path": "/fields/code"}},
            {"id": "t", "component": "DateTimeInput", "value": {"path": "/fields/code"}},
            {"id": "t", "component": "ChoicePicker", "label": "选", "options": [{"label": {"path": "/fields/code"}, "value": "a"}],
             "value": {"path": "/choices/a"}},
        ]
        for c in shown:
            problems = self.secure_page(c, data={"fields": {"code": "", "name": ""}, "choices": {"a": ["a"]}})
            self.assertTrue(any("会把密码框（/fields/code）里的字显示出来" in p for p in problems), (c, problems))
        count = [{"id": "c", "component": "Button", "child": "ct", "count": {"path": "/fields", "value": "x"},
                  "action": {"event": {"name": "mail_go", "context": {}}}},
                 {"id": "ct", "component": "Text", "text": "去 {n} 个"}]
        problems = self.secure_page(*count)
        self.assertTrue(any("会把密码框" in p for p in problems), ("count", problems))
        tooltip = {"id": "t", "component": "Button", "child": "tt", "tooltip": {"path": "/fields/code"},
                   "action": {"event": {"name": "mail_go", "context": {}}}}
        problems = self.secure_page(tooltip, {"id": "tt", "component": "Text", "text": "去"})
        self.assertTrue(any("会把密码框" in p for p in problems), ("tooltip", problems))
        twin = {"id": "t", "component": "TextField", "label": "再填一次", "variant": "obscured", "value": {"path": "/fields/code"}}
        self.assertEqual(self.secure_page(twin), [], "几个密码框绑同一个路径不算")
        self.assertEqual(self.secure_page({"id": "t", "component": "Text", "text": {"path": "/fields/name"}}), [], "旁边的照显示")

    def test_open_page_args(self):
        def btn(args, data=None):
            return card([{"id": "root", "component": "Button", "child": "t",
                          "action": {"event": {"name": "agent.open_page", "context": {"page": "notes", "args": args}}}},
                         {"id": "t", "component": "Text", "text": "看这一条"}], data if data is not None else {"q": "发票"})
        for ok in ({"item": "n-42"}, {"q": {"path": "/q"}}, {"a": "1", "b": "2", "c": "3", "d": "4"}, {}, {"q": "长" * 200}):
            self.assertEqual(a2ui.validate(btn(ok)), [], ok)
        for bad in ({k: "1" for k in "abcde"}, {"Item": "1"}, {"item\n": "1"}, {"1x": "1"}, {"a" * 17: "1"}, {"q": "长" * 201},
                    {"n": 2}, {"q": {"path": "/nope"}}, ["x"], "item=1"):
            self.assertTrue(a2ui.validate(btn(bad)), bad)
        self.assertTrue(a2ui.validate(card([{"id": "root", "component": "Button", "child": "t",
                                             "action": {"event": {"name": "agent.open_page",
                                                                  "context": {"page": "notes", "item": "1"}}}},
                                            {"id": "t", "component": "Text", "text": "看"}])), "别的键不认")

    def test_page_args_problem_and_uri(self):
        self.assertIsNone(a2ui.page_args_problem({"q": "发票 x+y", "cursor": "2"}))
        for bad in ({"q": 1}, {"Q": "1"}, {"q": "长" * 201}, {k: "1" for k in "abcde"}, [], None):
            self.assertIsNotNone(a2ui.page_args_problem(bad), bad)
        self.assertEqual(a2ui.page_uri("inbox"), "page/inbox")
        self.assertEqual(a2ui.page_uri("inbox", {}), "page/inbox")
        self.assertEqual(a2ui.page_uri("inbox", {"q": "发票 x+y/&=", "cursor": "2~a"}),
                         "page/inbox?cursor=2~a&q=%E5%8F%91%E7%A5%A8%20x%2By%2F%26%3D", "键按字母顺序，空格是 %20")

    def test_save_file(self):
        good = {"name": "gmail-filters.xml", "mediaType": "application/xml", "text": "<feed/>"}
        self.assertEqual(a2ui.save_file(good), good)
        self.assertEqual(a2ui.save_file(dict(good, name="规则 导出.xml")), dict(good, name="规则 导出.xml"))
        self.assertIsNotNone(a2ui.save_file(dict(good, text="x" * a2ui.MAX_FILE_BYTES)))
        for k, v in (("name", "../x.xml"), ("name", "a/b.xml"), ("name", ".zshrc"), ("name", "a:b"), ("name", ""),
                     ("name", " x.xml"), ("name", "x\u202e.xml"), ("name", "x" * 101), ("name", 3),
                     ("mediaType", "xml"), ("mediaType", "Application/XML"), ("mediaType", "a/b/c"),
                     ("mediaType", "application/octet-stream"), ("mediaType", "text/html"), ("mediaType", "text/plain"),
                     ("name", "x.command"), ("name", "x.terminal"), ("name", "x.xml.command"), ("name", ".xml"), ("name", "xml"),
                     ("text", "x" * (a2ui.MAX_FILE_BYTES + 1)), ("text", "长" * 200_000), ("text", b"x"), ("text", "\ud800")):
            self.assertIsNone(a2ui.save_file(dict(good, **{k: v})), (k, v if not isinstance(v, str) else v[:20]))
        for media, name in (("text/plain", "a.txt"), ("text/csv", "a.CSV"), ("application/json", "a.json"),
                            ("text/markdown", "说明.md"), ("application/xml", "a.Xml")):
            self.assertIsNotNone(a2ui.save_file({"name": name, "mediaType": media, "text": "x"}), (media, name))
        self.assertIsNone(a2ui.save_file({"name": "a.txt", "mediaType": "text/csv", "text": "x"}), "扩展名要是它这一类的")
        self.assertIsNone(a2ui.save_file("x"))
        self.assertIsNone(a2ui.save_file({"name": "a.txt", "text": "x"}))

    def test_cards_refresh_helper(self):
        c = cards.Card("sync")
        c.text("同步中…")
        c.refresh = 5
        msgs = c.messages()
        self.assertEqual(msgs[1]["updateComponents"]["components"][0]["refresh"], 5)
        self.assertEqual(a2ui.validate(msgs, page=True), [])


if __name__ == "__main__":
    unittest.main()
