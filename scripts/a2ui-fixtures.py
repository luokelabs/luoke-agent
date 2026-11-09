"""生成 a2ui/Tests/LuokeA2UICoreTests/Fixtures/cases.json：一批卡片和 Python 版（luoke_agent/a2ui.py）的判断。
Swift 的 LuokeA2UICore 测试读它，两边的规矩必须一样。改了 a2ui.py 的规矩就重跑：

    python3 scripts/a2ui-fixtures.py
"""
import json
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
from luoke_agent import a2ui, cards  # noqa: E402

V = "v0.9"
A, I = a2ui.AGENT_CATALOG, a2ui.IME_CATALOG


def card(components, data=None, catalog=A):
    out = [{"version": V, "createSurface": {"surfaceId": "s", "catalogId": catalog}},
           {"version": V, "updateComponents": {"surfaceId": "s", "components": components}}]
    if data is not None:
        out.append({"version": V, "updateDataModel": {"surfaceId": "s", "path": "/", "value": data}})
    return out


def btn(name, context, data=None, label=None):
    return card([{"id": "root", "component": "Button", "child": "t", "action": {"event": {"name": name, "context": context}}},
                 label or {"id": "t", "component": "Text", "text": "点"}], data if data is not None else {"x": 1})


def open_url(url):
    return (btn("agent.open_url", {"url": url}), A)


bound_label = {"id": "t", "component": "Text", "text": {"path": "/label"}}
row_label = {"id": "t", "component": "Row", "children": []}


text = {"id": "root", "component": "Text", "text": "hi"}
plan = cards.plan_card("p1", "这 2 封我打算这样处理", [
    {"key": "m1", "label": "王老师：答辩时间", "detail": "周五前回", "options": [("draft", "写草稿"), ("keep", "先不动")],
     "selected": "draft"},
    {"key": "rest", "label": "另外 4 封", "options": [("archive", "照建议归档"), ("keep", "先不动")], "selected": "archive"},
], apply_event="mail_apply_plan", plan_id="p1", extra_buttons=[cards.open_url_button("加入日程", "https://calendar.google.com/x")])
c = cards.Card("f1")
c.text_field("reply", "你的回答")
c.buttons(cards.button("交回", "mem.answer", {"ask": 1, "reply": {"path": "/fields/reply"}}, primary=True))
bad_version = card([text])
bad_version[1]["version"] = "v0.8"
many = [{"id": "root", "component": "Column", "children": [f"t{i}" for i in range(a2ui.MAX_COMPONENTS)]}] + \
       [{"id": f"t{i}", "component": "Text", "text": "x"} for i in range(a2ui.MAX_COMPONENTS)]
slider = [{"id": "root", "component": "Slider", "value": {"path": "/n"}, "min": 0, "max": 5}]

cases = {
    "plan_card": (plan, A),
    "text_field_card": (c.messages(), A),
    "text_only": (card([text]), A),
    "empty": ([], A),
    "no_create_first": (card([text])[1:], A),
    "unknown_catalog": (card([text], catalog="x"), "x"),
    "no_root": (card([{"id": "a", "component": "Text", "text": "x"}]), A),
    "image_not_in_catalog": (card([{"id": "root", "component": "Image", "url": "x"}]), A),
    "old_version": (bad_version, A),
    "dangling_child": (card([{"id": "root", "component": "Column", "children": ["nope"]}]), A),
    "cycle": (card([{"id": "root", "component": "Column", "children": ["a"]}, {"id": "a", "component": "Row", "children": ["b"]},
                    {"id": "b", "component": "Card", "child": "a"}]), A),
    "two_parents": (card([{"id": "root", "component": "Column", "children": ["a", "b"]}, {"id": "a", "component": "Card", "child": "t"},
                          {"id": "b", "component": "Card", "child": "t"}, {"id": "t", "component": "Text", "text": "x"}]), A),
    "template_children": (card([{"id": "root", "component": "List", "children": {"componentId": "t", "path": "/xs"}}]), A),
    "unbound_checkbox": (card([{"id": "root", "component": "CheckBox", "label": "x", "value": {"path": "/on"}}], {}), A),
    "bound_checkbox": (card([{"id": "root", "component": "CheckBox", "label": "x", "value": {"path": "/on"}}], {"on": True}), A),
    "choice_single_string": (card([{"id": "root", "component": "ChoicePicker", "options": [{"label": "a", "value": "a"}],
                                    "value": {"path": "/v"}}], {"v": "a"}), A),
    "choice_outside": (card([{"id": "root", "component": "ChoicePicker", "options": [{"label": "a", "value": "a"}],
                              "value": {"path": "/v"}}], {"v": ["b"]}), A),
    "text_number": (card([{"id": "root", "component": "Text", "text": 3}]), A),
    "text_too_long": (card([{"id": "root", "component": "Text", "text": "字" * (a2ui.MAX_TEXT + 1)}]), A),
    "bad_icon": (card([{"id": "root", "component": "Icon", "name": "rocket"}]), A),
    "good_icon": (card([{"id": "root", "component": "Icon", "name": "mail"}]), A),
    "bad_variant": (card([{"id": "root", "component": "Text", "text": "x", "variant": "huge"}]), A),
    "button_ok": (btn("do", {"x": {"path": "/x"}}), A),
    "button_unbound": (btn("do", {"x": {"path": "/y"}}), A),
    "agent_unknown": (btn("agent.rm_rf", {}), A),
    "open_url_http": (btn("agent.open_url", {"url": "http://example.com"}), A),
    "open_url_bound": (btn("agent.open_url", {"url": {"path": "/x"}}), A),
    "open_url_https": (btn("agent.open_url", {"url": "https://example.com"}), A),
    # 工具协议 §5：网址解析和浏览器可能不一致的都不认；主机名转 punycode 的那份由 agent 写在按钮上
    "open_url_backslash": open_url("https://example.com\\@evil.example/"),
    "open_url_userinfo": open_url("https://user:pass@evil.example/"),
    "open_url_tab": open_url("https://exa\tmple.com/"),
    "open_url_space": open_url("https://example.com/a b"),
    "open_url_bidi": open_url("https://evil.example‮/moc.elgoog"),
    "open_url_zero_width": open_url("https://exa​mple.com/"),
    "open_url_empty_host": open_url("https:///evil.example"),
    "open_url_percent_host": open_url("https://%65vil.example/"),
    "open_url_hex_ip": open_url("https://0x7f.1/"),
    "open_url_short_ip": open_url("https://127.1/"),
    "open_url_ipv4": open_url("https://127.0.0.1/"),
    "open_url_ipv6": open_url("https://[::1]/"),
    "open_url_port": open_url("https://example.com:8443/x"),
    "open_url_bad_port": open_url("https://example.com:99999/"),
    "open_url_empty_port": open_url("https://example.com:/"),
    "open_url_trailing_dot": open_url("https://example.com./"),
    "open_url_empty_label": open_url("https://a..example/"),
    "open_url_idn": open_url("https://bücher.example/路径?q=中"),
    "open_url_at_in_query": open_url("https://example.com/?a@b"),
    "open_url_backslash_combining": open_url("https://evil.example\\\u0301/x"),
    "open_url_at_combining": open_url("https://user@\u0301evil.example/"),
    "open_url_bound_label": (btn("agent.open_url", {"url": "https://example.com"}, {"label": "打开"}, bound_label), A),
    "open_url_row_label": (btn("agent.open_url", {"url": "https://example.com"}, None, row_label), A),
    "button_bound_label": (btn("do", {}, {"label": "删除 3 个"}, bound_label), A),
    "switch_ok": (card([{"id": "root", "component": "Button", "child": "t", "variant": "switch", "on": True,
                         "action": {"event": {"name": "do", "context": {}}}},
                        {"id": "t", "component": "Text", "text": "点"}]), A),
    "switch_open_url": (card([{"id": "root", "component": "Button", "child": "t", "variant": "switch", "on": False,
                               "action": {"event": {"name": "agent.open_url", "context": {"url": "https://example.com"}}}},
                              {"id": "t", "component": "Text", "text": "点"}]), A),
    "progress_ok": (card([{"id": "root", "component": "ProgressBar", "value": 0.5}]), A),
    "progress_ends": (card([{"id": "root", "component": "Column", "children": ["a", "b"]},
                            {"id": "a", "component": "ProgressBar", "value": 0},
                            {"id": "b", "component": "ProgressBar", "value": 1}]), A),
    "progress_over": (card([{"id": "root", "component": "ProgressBar", "value": 1.5}]), A),
    "progress_under": (card([{"id": "root", "component": "ProgressBar", "value": -0.1}]), A),
    "progress_no_value": (card([{"id": "root", "component": "ProgressBar"}]), A),
    "progress_text_value": (card([{"id": "root", "component": "ProgressBar", "value": "0.5"}]), A),
    "progress_bool_value": (card([{"id": "root", "component": "ProgressBar", "value": True}]), A),
    "progress_bound_value": (card([{"id": "root", "component": "ProgressBar", "value": {"path": "/x"}}], {"x": 0.5}), A),
    "ime_progress": (card([{"id": "root", "component": "ProgressBar", "value": 0.5}], catalog=I), I),
    "too_many": (card(many), A),
    "ime_slider": (card(slider, {"n": 2}, I), I),
    "agent_slider": (card(slider, {"n": 2}), A),
    "ime_card": (card([{"id": "root", "component": "Card", "child": "t"}, {"id": "t", "component": "Text", "text": "x"}], catalog=I), I),
}
out = []
for name, (msgs, catalog) in cases.items():
    problems = a2ui.validate(msgs, catalog) if catalog in a2ui.CATALOGS else ["不认识的组件目录"]
    out.append({"name": name, "catalog": catalog, "messages": msgs, "ok": not problems})
path = os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))),
                    "a2ui", "Tests", "LuokeA2UICoreTests", "Fixtures", "cases.json")
with open(path, "w", encoding="utf-8") as f:
    json.dump(out, f, ensure_ascii=False, indent=1)
print(f"{len(out)} 例，{sum(c['ok'] for c in out)} 例画得了 → {path}")
