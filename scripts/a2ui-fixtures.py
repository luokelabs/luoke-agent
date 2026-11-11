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


def count_btn(count):
    """一个数选择的按钮（§4 countLabel）：「移到废纸篓 {n} 项」，数 /choices 里选了 trash 的。"""
    return card([{"id": "root", "component": "Button", "child": "t", "count": count,
                  "action": {"event": {"name": "scan_apply", "context": {"choices": {"path": "/choices"}}}}},
                 {"id": "t", "component": "Text", "text": "移到废纸篓 {n} 项"}],
                {"choices": {"i0": ["trash"], "i1": ["keep"]}, "n": 1})


def page_many(n):
    """一页 n 个组件：一个 Column 加 n-1 段字。"""
    return [{"id": "root", "component": "Column", "children": [f"t{i}" for i in range(n - 1)]}] + \
           [{"id": f"t{i}", "component": "Text", "text": "x"} for i in range(n - 1)]


def secure_page(data, event="mail_connect", context=None, extra=()):
    """一个密码框加一个交回的按钮（§4 secureField），`extra` 的组件挂在 root 下面。"""
    ctx = {"code": {"path": "/fields/code"}} if context is None else context
    return card([{"id": "root", "component": "Column", "children": ["f", "b"] + [c["id"] for c in extra if c.get("top", True)]},
                 {"id": "f", "component": "TextField", "label": "授权码", "variant": "obscured", "value": {"path": "/fields/code"}},
                 {"id": "b", "component": "Button", "child": "bt",
                  "action": {"event": {"name": event, "context": ctx}}},
                 {"id": "bt", "component": "Text", "text": "加上"}]
                + [{k: v for k, v in c.items() if k != "top"} for c in extra], data)


def secure_in_list(event="mail_connect", context=None, extra=(), data=None):
    """密码框绑在数组里（`/l/0`）：`/l/00`、`/l/+0` 这类写法取不到（RFC 6901），不能借它绕过「正好引用」。"""
    ctx = {"code": {"path": "/l/0"}} if context is None else context
    return card([{"id": "root", "component": "Column", "children": ["f", "b"] + [c["id"] for c in extra]},
                 {"id": "f", "component": "TextField", "label": "授权码", "variant": "obscured", "value": {"path": "/l/0"}},
                 {"id": "b", "component": "Button", "child": "bt", "action": {"event": {"name": event, "context": ctx}}},
                 {"id": "bt", "component": "Text", "text": "加上"}] + list(extra),
                {"l": [""] + [f"x{i}" for i in range(1, 11)]} if data is None else data)


bound_label = {"id": "t", "component": "Text", "text": {"path": "/label"}}
row_label = {"id": "t", "component": "Row", "children": []}


text = {"id": "root", "component": "Text", "text": "hi"}
plan = cards.plan_card("p1", "这 2 封我打算这样处理", [
    {"key": "m1", "label": "王老师：答辩时间", "detail": "周五前回", "options": [("draft", "写草稿"), ("keep", "先不动")],
     "selected": "draft"},
    {"key": "rest", "label": "另外 4 封", "options": [("archive", "照建议归档"), ("keep", "先不动")], "selected": "archive"},
], apply_event="mail_apply_plan", plan_id="p1", apply_label="写草稿 1 · 归档 4",
    extra_buttons=[cards.open_url_button("加入日程", "https://calendar.google.com/x")])
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
    # 宽窗口的侧栏（工具协议 §4）：placement 只能是 aside，只能写在根 Column 下面一层的 Column 上
    "placement_aside": (card([{"id": "root", "component": "Column", "children": ["m", "a"]},
                              {"id": "m", "component": "Text", "text": "要你看看的"},
                              {"id": "a", "component": "Column", "placement": "aside", "children": ["d", "t"]},
                              {"id": "d", "component": "Divider"},
                              {"id": "t", "component": "Text", "text": "病毒库更新于 11月9日", "variant": "caption"}]), A),
    "placement_bad_value": (card([{"id": "root", "component": "Column", "children": ["a"]},
                                  {"id": "a", "component": "Column", "placement": "side", "children": ["t"]},
                                  {"id": "t", "component": "Text", "text": "x"}]), A),
    "placement_not_text": (card([{"id": "root", "component": "Column", "children": ["a"]},
                                 {"id": "a", "component": "Column", "placement": True, "children": ["t"]},
                                 {"id": "t", "component": "Text", "text": "x"}]), A),
    "placement_on_text": (card([{"id": "root", "component": "Column", "children": ["t"]},
                                {"id": "t", "component": "Text", "text": "x", "placement": "aside"}]), A),
    "placement_nested": (card([{"id": "root", "component": "Column", "children": ["c"]},
                               {"id": "c", "component": "Column", "children": ["a"]},
                               {"id": "a", "component": "Column", "placement": "aside", "children": ["t"]},
                               {"id": "t", "component": "Text", "text": "x"}]), A),
    "placement_under_row": (card([{"id": "root", "component": "Row", "children": ["a"]},
                                  {"id": "a", "component": "Column", "placement": "aside", "children": ["t"]},
                                  {"id": "t", "component": "Text", "text": "x"}]), A),
    "placement_on_root": (card([{"id": "root", "component": "Column", "placement": "aside", "children": ["t"]},
                                {"id": "t", "component": "Text", "text": "x"}]), A),
    # 「今天」新模板（工具协议 §4）：标签和它的颜色、加粗、截断、选项图标、可折叠、Lucide 图标名
    "badge_ok": (card([{"id": "root", "component": "Text", "text": "ming@harbor-tech.example", "variant": "badge"}]), A),
    "badge_tone_ok": (card([{"id": "root", "component": "Text", "text": "09-20 已过", "variant": "badge", "tone": "danger"}]), A),
    "badge_tone_bad": (card([{"id": "root", "component": "Text", "text": "x", "variant": "badge", "tone": "blue"}]), A),
    "tone_without_badge": (card([{"id": "root", "component": "Text", "text": "x", "tone": "warning"}]), A),
    "strong_ok": (card([{"id": "root", "component": "Text", "text": "CareerLink 事務局", "variant": "strong"}]), A),
    "max_lines_ok": (card([{"id": "root", "component": "Text", "text": "很长的主题", "maxLines": 1}]), A),
    "max_lines_zero": (card([{"id": "root", "component": "Text", "text": "x", "maxLines": 0}]), A),
    "max_lines_text": (card([{"id": "root", "component": "Text", "text": "x", "maxLines": "1"}]), A),
    "max_lines_bool": (card([{"id": "root", "component": "Text", "text": "x", "maxLines": True}]), A),
    "option_icon_ok": (card([{"id": "root", "component": "ChoicePicker", "value": {"path": "/c"},
                              "options": [{"value": "flag", "label": "加星标", "icon": "star"},
                                          {"value": "keep", "label": "先不动", "icon": "circle-minus"}]}], {"c": ["flag"]}), A),
    "option_icon_bad": (card([{"id": "root", "component": "ChoicePicker", "value": ["a"],
                               "options": [{"value": "a", "label": "A", "icon": "rocket"}]}]), A),
    "collapsed_ok": (card([{"id": "root", "component": "Column", "collapsed": "206 封，都先不动", "children": ["t"]},
                           {"id": "t", "component": "Text", "text": "x"}]), A),
    "collapsed_empty": (card([{"id": "root", "component": "Column", "collapsed": " ", "children": ["t"]},
                              {"id": "t", "component": "Text", "text": "x"}]), A),
    "collapsed_not_text": (card([{"id": "root", "component": "Column", "collapsed": True, "children": ["t"]},
                                 {"id": "t", "component": "Text", "text": "x"}]), A),
    "lucide_icon_ok": (card([{"id": "root", "component": "Icon", "name": "calendar-plus"}]), A),
    "done_group_ok": (card([{"id": "root", "component": "Column", "children": ["t"],
                             "group": {"key": "ming@harbor/spam", "label": "可疑邮件", "text": "已移到垃圾邮件 {n} 封", "n": 2,
                                       "badge": "ming@harbor-tech.example"}},
                            {"id": "t", "component": "Text", "text": "已移到垃圾邮件 2 封"}]), A),
    "done_group_no_n": (card([{"id": "root", "component": "Column", "children": ["t"],
                               "group": {"key": "k", "text": "已归档 {n} 封"}},
                              {"id": "t", "component": "Text", "text": "x"}]), A),
    "done_group_not_root": (card([{"id": "root", "component": "Column", "children": ["t"]},
                                  {"id": "t", "component": "Text", "text": "x", "group": {"key": "k", "text": "x", "n": 1}}]), A),
    # 卡片的副标题（§4 subtitle）：只写在 root 上，一句不空的文字，不能绑定
    "subtitle_ok": (card([{"id": "root", "component": "Column", "children": ["t"], "subtitle": "王老师 · 答辩时间"},
                          {"id": "t", "component": "Text", "text": "x"}]), A),
    "subtitle_empty": (card([{"id": "root", "component": "Column", "children": ["t"], "subtitle": " "},
                             {"id": "t", "component": "Text", "text": "x"}]), A),
    "subtitle_bound": (card([{"id": "root", "component": "Column", "children": ["t"], "subtitle": {"path": "/s"}},
                             {"id": "t", "component": "Text", "text": "x"}], {"s": "王老师"}), A),
    "subtitle_not_root": (card([{"id": "root", "component": "Column", "children": ["t"]},
                                {"id": "t", "component": "Text", "text": "x", "subtitle": "王老师"}]), A),
    "open_url_icon_row_ok": (card([{"id": "root", "component": "Button", "child": "r", "tooltip": "加入日程",
                                    "action": {"event": {"name": "agent.open_url", "context": {"url": "https://calendar.google.com/x"}}}},
                                   {"id": "r", "component": "Row", "children": ["i", "t"]},
                                   {"id": "i", "component": "Icon", "name": "calendar-plus"},
                                   {"id": "t", "component": "Text", "text": "11-12 16:00"}]), A),
    "open_url_icon_row_bound": (card([{"id": "root", "component": "Button", "child": "r",
                                       "action": {"event": {"name": "agent.open_url", "context": {"url": "https://calendar.google.com/x"}}}},
                                      {"id": "r", "component": "Row", "children": ["i", "t"]},
                                      {"id": "i", "component": "Icon", "name": "calendar-plus"},
                                      {"id": "t", "component": "Text", "text": {"path": "/when"}}], {"when": "11-12"}), A),
    "old_icon_name_ok": (card([{"id": "root", "component": "Icon", "name": "trash"}]), A),
    "open_page_ok": (btn("agent.open_page", {"page": "overview"}), A),
    "open_page_other_app": (btn("agent.open_page", {"page": "luoke-mail/accounts"}), A),
    "open_page_app_key": (btn("agent.open_page", {"app": "luoke-mail", "page": "accounts"}), A),
    "open_page_bad_id": (btn("agent.open_page", {"page": "../x"}), A),
    "open_page_no_page": (btn("agent.open_page", {}), A),
    "open_page_switch": (card([{"id": "root", "component": "Button", "child": "t", "variant": "switch", "on": False,
                                "action": {"event": {"name": "agent.open_page", "context": {"page": "overview"}}}},
                               {"id": "t", "component": "Text", "text": "去看看"}]), A),
    "count_ok": (count_btn({"path": "/choices", "value": "trash"}), A),
    "count_bad_shape": (count_btn({"path": "/choices"}), A),
    "count_empty_value": (count_btn({"path": "/choices", "value": ""}), A),
    "count_missing_path": (count_btn({"path": "/nope", "value": "trash"}), A),
    "count_not_choices": (count_btn({"path": "/n", "value": "trash"}), A),
    # 2026-11-10：应用页（§1a page/<id>）的规矩，第三项是 page=True
    "open_page_args_ok": (btn("agent.open_page", {"page": "notes", "args": {"item": "n-42", "q": {"path": "/q"}}}, {"q": "发票"}), A),
    "open_page_args_too_many": (btn("agent.open_page", {"page": "notes", "args": {k: "1" for k in "abcde"}}), A),
    "open_page_args_bad_key": (btn("agent.open_page", {"page": "notes", "args": {"Item": "1"}}), A),
    "open_page_args_newline_key": (btn("agent.open_page", {"page": "notes", "args": {"item\n": "1"}}), A),
    "open_page_args_long": (btn("agent.open_page", {"page": "notes", "args": {"q": "长" * 201}}), A),
    "open_page_args_200": (btn("agent.open_page", {"page": "notes", "args": {"q": "长" * 200}}), A),
    "open_page_args_number": (btn("agent.open_page", {"page": "notes", "args": {"n": 2}}), A),
    "open_page_args_not_object": (btn("agent.open_page", {"page": "notes", "args": ["x"]}), A),
    "open_page_args_unbound": (btn("agent.open_page", {"page": "notes", "args": {"q": {"path": "/nope"}}}), A),
    "page_400": (card(page_many(a2ui.MAX_PAGE_COMPONENTS)), A, True),
    "page_401": (card(page_many(a2ui.MAX_PAGE_COMPONENTS + 1)), A, True),
    "page_refresh_ok": (card([dict(text, refresh=5)]), A, True),
    "page_refresh_too_fast": (card([dict(text, refresh=1)]), A, True),
    "page_refresh_too_slow": (card([dict(text, refresh=61)]), A, True),
    "page_refresh_string": (card([dict(text, refresh="5")]), A, True),
    "page_refresh_bool": (card([dict(text, refresh=True)]), A, True),
    "page_refresh_not_root": (card([{"id": "root", "component": "Column", "children": ["t"]},
                                    {"id": "t", "component": "Text", "text": "x", "refresh": 5}]), A, True),
    "card_refresh": (card([dict(text, refresh=5)]), A),
    # §4 pageSections：页的根 Column 写 layout sections；§4 neutralBadge：badge 的 tone 可以是 neutral
    "page_sections_ok": (card([{"id": "root", "component": "Column", "children": ["h", "sec"], "layout": "sections"},
                               {"id": "h", "component": "Text", "text": "扫描", "variant": "h3"},
                               {"id": "sec", "component": "Column", "children": ["st", "t"]},
                               {"id": "st", "component": "Row", "children": ["si", "sx", "sn"]},
                               {"id": "si", "component": "Icon", "name": "eye"},
                               {"id": "sx", "component": "Text", "text": "要你看看"},
                               {"id": "sn", "component": "Text", "text": "4", "variant": "caption"},
                               {"id": "t", "component": "Text", "text": "x"}]), A, True),
    "page_sections_bad_value": (card([{"id": "root", "component": "Column", "children": ["t"], "layout": "cards"},
                                      {"id": "t", "component": "Text", "text": "x"}]), A, True),
    "page_sections_not_root": (card([{"id": "root", "component": "Column", "children": ["c"]},
                                     {"id": "c", "component": "Column", "children": ["t"], "layout": "sections"},
                                     {"id": "t", "component": "Text", "text": "x"}]), A, True),
    "page_sections_root_text": (card([dict(text, layout="sections")]), A, True),
    "card_sections": (card([{"id": "root", "component": "Column", "children": ["t"], "layout": "sections"},
                            {"id": "t", "component": "Text", "text": "x"}]), A),
    "badge_neutral": (card([{"id": "root", "component": "Row", "children": ["a", "b", "m"]},
                            {"id": "a", "component": "Text", "text": "Alpha", "variant": "badge", "tone": "neutral"},
                            {"id": "b", "component": "Text", "text": "Beta", "variant": "badge", "tone": "neutral"},
                            {"id": "m", "component": "Text", "text": "等 12 个", "variant": "caption"}]), A),
    "badge_beige": (card([{"id": "root", "component": "Text", "text": "2 GB", "variant": "badge", "tone": "beige"}]), A),
    "page_secure_ok": (secure_page({"fields": {"code": ""}}), A, True),
    "card_secure": (secure_page({"fields": {"code": ""}}), A),
    "page_secure_prefilled": (secure_page({"fields": {"code": "abc"}}), A, True),
    "page_secure_literal": (card([{"id": "root", "component": "TextField", "label": "授权码", "variant": "obscured", "value": ""}]),
                            A, True),
    "page_secure_unbound": (secure_page({}), A, True),
    # 密码框的字只交给工具：agent. 开头的动作不能引用它，也不能引用它上面一层
    "page_secure_open_page_arg": (secure_page({"fields": {"code": ""}}, "agent.open_page",
                                              {"page": "notes", "args": {"q": {"path": "/fields/code"}}}), A, True),
    "page_secure_open_page_parent": (secure_page({"fields": {"code": ""}}, "agent.open_page",
                                                 {"page": "notes", "args": {"q": {"path": "/fields"}}}), A, True),
    "page_secure_open_page_other": (secure_page({"fields": {"code": ""}, "q": ""}, "agent.open_page",
                                                {"page": "notes", "args": {"q": {"path": "/q"}}}), A, True),
    "page_secure_parent_to_tool": (secure_page({"fields": {"code": ""}}, "mail_connect", {"all": {"path": "/fields"}}), A, True),
    "page_secure_root_to_tool": (secure_page({"fields": {"code": ""}}, "mail_connect", {"all": {"path": "/"}}), A, True),
    "page_secure_exact_and_beside": (secure_page({"fields": {"code": "", "name": ""}}, "mail_connect",
                                                 {"code": {"path": "/fields/code"}, "name": {"path": "/fields/name"}}), A, True),
    "page_secure_open_page_child": (secure_page({"fields": {"code": ""}}, "agent.open_page",
                                                {"page": "notes", "args": {"q": {"path": "/fields/code/x"}}}), A, True),
    # 别的绑定是密码框的路径或它上面一层：会明文显示出来，不认；几个密码框绑同一个路径不算
    "page_secure_shown_by_text": (secure_page({"fields": {"code": ""}}, extra=[
        {"id": "t", "component": "Text", "text": {"path": "/fields/code"}}]), A, True),
    "page_secure_shown_by_parent": (secure_page({"fields": {"code": ""}}, extra=[
        {"id": "t", "component": "Text", "text": {"path": "/fields"}}]), A, True),
    "page_secure_shown_by_field": (secure_page({"fields": {"code": ""}}, extra=[
        {"id": "t", "component": "TextField", "label": "看一眼", "value": {"path": "/fields/code"}}]), A, True),
    "page_secure_shown_by_label": (secure_page({"fields": {"code": "", "name": ""}}, extra=[
        {"id": "t", "component": "TextField", "label": {"path": "/fields/code"}, "value": {"path": "/fields/name"}}]), A, True),
    "page_secure_shown_by_count": (secure_page({"fields": {"code": ""}}, extra=[
        {"id": "c", "component": "Button", "child": "ct", "count": {"path": "/fields", "value": "x"},
         "action": {"event": {"name": "mail_go", "context": {}}}},
        {"id": "ct", "component": "Text", "text": "去 {n} 个", "top": False}]), A, True),
    "page_secure_twin": (secure_page({"fields": {"code": ""}}, extra=[
        {"id": "t", "component": "TextField", "label": "再填一次", "variant": "obscured", "value": {"path": "/fields/code"}}]), A, True),
    "page_secure_beside_shown": (secure_page({"fields": {"code": "", "name": "王"}}, extra=[
        {"id": "t", "component": "Text", "text": {"path": "/fields/name"}}]), A, True),
    # 密码框在数组里：下标只认 0 或不以 0 开头的 ASCII 数字（RFC 6901），`/l/00`、`/l/+0`、`/l/-0` 取不到，整页不画；
    # 正好引用 `/l/0` 的照旧能交，别的下标（`/l/10`）照旧取得到
    "page_secure_list_exact": (secure_in_list(), A, True),
    "page_secure_list_open_page_00": (secure_in_list("agent.open_page", {"page": "notes", "args": {"q": {"path": "/l/00"}}}),
                                      A, True),
    "page_secure_list_open_page_plus0": (secure_in_list("agent.open_page", {"page": "notes", "args": {"q": {"path": "/l/+0"}}}),
                                         A, True),
    "page_secure_list_text_00": (secure_in_list(extra=[{"id": "t", "component": "Text", "text": {"path": "/l/00"}}]), A, True),
    "page_secure_list_text_minus0": (secure_in_list(extra=[{"id": "t", "component": "Text", "text": {"path": "/l/-0"}}]),
                                     A, True),
    "page_secure_list_tool_00": (secure_in_list(context={"code": {"path": "/l/00"}}), A, True),
    "page_secure_list_tool_plus0": (secure_in_list(context={"code": {"path": "/l/+0"}}), A, True),
    "page_secure_list_option_label_00": (secure_in_list(extra=[
        {"id": "t", "component": "ChoicePicker", "options": [{"label": {"path": "/l/00"}, "value": "a"}], "value": ["a"]}]),
        A, True),
    "page_secure_list_text_10_ok": (secure_in_list(extra=[{"id": "t", "component": "Text", "text": {"path": "/l/10"}}]), A, True),
    "page_option_label_unbound": (card([{"id": "root", "component": "ChoicePicker",
                                         "options": [{"label": {"path": "/nope"}, "value": "a"}], "value": ["a"]}], {}), A, True),
    "page_plain_text_field_prefilled": (card([{"id": "root", "component": "TextField", "label": "改成", "value": {"path": "/v"}}],
                                             {"v": "原来的话"}), A, True),
    # §4 countAlso：别的值也交得上去（also 和 alsoLabel 一起写）
    "count_also_ok": (count_btn({"path": "/choices", "value": "trash", "also": ["ignore", "clone"],
                                 "alsoLabel": "按上面的选择清理（移到废纸篓 {n} 项）"}), A),
    "count_also_without_label": (count_btn({"path": "/choices", "value": "trash", "also": ["ignore"]}), A),
    "count_also_label_only": (count_btn({"path": "/choices", "value": "trash", "alsoLabel": "按上面的选择清理"}), A),
    "count_also_empty": (count_btn({"path": "/choices", "value": "trash", "also": [], "alsoLabel": "x"}), A),
    "count_also_not_texts": (count_btn({"path": "/choices", "value": "trash", "also": ["ignore", 3], "alsoLabel": "x"}), A),
    "count_also_blank_label": (count_btn({"path": "/choices", "value": "trash", "also": ["ignore"], "alsoLabel": " "}), A),
    "count_extra_key": (count_btn({"path": "/choices", "value": "trash", "extra": 1}), A),
    # §4 countWeights：选择的键 → 正整数（一项合了好几样）
    "count_weights_ok": (count_btn({"path": "/choices", "value": "trash", "weights": {"i0": 41, "absent": 3}}), A),
    "count_weights_empty_ok": (count_btn({"path": "/choices", "value": "trash", "weights": {}}), A),
    "count_weights_with_also_ok": (count_btn({"path": "/choices", "value": "trash", "weights": {"i0": 41},
                                              "also": ["ignore"], "alsoLabel": "按上面的选择清理"}), A),
    "count_weights_zero": (count_btn({"path": "/choices", "value": "trash", "weights": {"i0": 0}}), A),
    "count_weights_negative": (count_btn({"path": "/choices", "value": "trash", "weights": {"i0": -2}}), A),
    "count_weights_fraction": (count_btn({"path": "/choices", "value": "trash", "weights": {"i0": 1.5}}), A),
    "count_weights_text": (count_btn({"path": "/choices", "value": "trash", "weights": {"i0": "41"}}), A),
    "count_weights_bool": (count_btn({"path": "/choices", "value": "trash", "weights": {"i0": True}}), A),
    "count_weights_not_object": (count_btn({"path": "/choices", "value": "trash", "weights": [41]}), A),
}
out = []
for name, (msgs, catalog, *page) in cases.items():
    is_page = bool(page and page[0])
    problems = a2ui.validate(msgs, catalog, page=is_page) if catalog in a2ui.CATALOGS else ["不认识的组件目录"]
    case = {"name": name, "catalog": catalog, "messages": msgs, "ok": not problems}
    if is_page:
        case["page"] = True
    out.append(case)
path = os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))),
                    "a2ui", "Tests", "LuokeA2UICoreTests", "Fixtures", "cases.json")
with open(path, "w", encoding="utf-8") as f:
    json.dump(out, f, ensure_ascii=False, indent=1)
print(f"{len(out)} 例，{sum(c['ok'] for c in out)} 例画得了 → {path}")
