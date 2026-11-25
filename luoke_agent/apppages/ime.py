# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 螺壳实验室 Luoke Labs
"""输入法的设置页：照它给的原始数据（`data/settings`，luoke-ime fixtures/agent/README.md）拼。页上的字都在这里写，
输入法只给键、值、代号和数字（顶层 ADR 0028；设置页归主窗口：顶层 ADR 0002 第 10、13 条，负责人 11-19）。

分组和各项的叫法照输入法原来那一页和它自己的设置窗口，不另起名；每项下面的说明压成一句（负责人 11-19：说明不把知道的都列上去，
界面规范「说明一句话」）。隐私和权限的几句留着（负责人 11-19 看过：识别在本机完成、首次使用请求麦克风权限、
密码框等处不统计，都有用）。「设置」一页从上到下只放日常用的：输入方式、模糊音、语音、中英文、排版、
候选窗口、联想、记忆记录（这些改设置，走 `ime_set`），和词语（清除已学的、恢复忘记的，日常纠错用，走 `ime_do`）；
最下面一行「高级设置」点进隐藏页 `more`。不常用的几组收在 `more` 里（标签栏右端的图标也能打开，弹窗；UX-13）：
使用统计、开发模式（走 `ime_do`）；文件（在访达中显示，核心自己做）。

「各应用」那一页照 `data/apps` 拼：有单独设置的应用一个一组，都摊开，不点进二级页；改一项、恢复跟随全局都走 `ime_set`。"""
from __future__ import annotations

import re
from typing import Any, Callable, Dict, List, Optional, Tuple
from urllib.parse import urlencode

from .kit import PageKit

APP = "luoke-ime"
PAGE_NEEDS = {"settings": ("settings",), "apps": ("apps",), "more": ("settings",)}
NEEDS = PAGE_NEEDS["settings"]
BUILT = set(PAGE_NEEDS)
PAGES = [{"id": "settings", "title": "设置"}, {"id": "apps", "title": "各应用"},
         {"id": "more", "title": "高级设置", "hidden": True, "icon": "sliders-horizontal"}]
SET = "ime_set"
DO = "ime_do"

Read = Callable[[str], Any]

# 开关：键 → （叫什么，下面那行小字）
SWITCHES = {
    "fuzzyOn": ("模糊音", "同时给出拼法相近的字，准确的候选可能排序靠后"),
    "voiceOn": ("语音输入", "按住所选按键说话，松开后上屏；识别和整理均由螺壳在本机完成；首次使用时系统将请求麦克风权限"),
    "voiceTidy": ("语音整理", "去除口头禅、修正改口、整理列表和分段"),
    "rememberMode": ("记住各应用上次的中英文模式", None),
    "shiftToggles": ("单按 Shift 切换中英文", None),
    "autoSpace": ("中英文之间自动加空格", None),
    "cornerBraces": ("中文状态下 { } 输入为「」", None),
    "predict": ("联想", "按 Tab 选用推荐"),
    "memory": ("记录输入内容到记忆", "保存在本机，用于联想和候选排序"),
    "recordingPaused": ("暂停所有记录", "暂停期间不记录，可随时恢复"),
}
# 一组里选一个：键 → （叫什么，下面那行小字，{值的代号: 字}）；真假两个值的写 "true" / "false"
CHOICES: Dict[str, Tuple[str, Optional[str], Dict[str, str]]] = {
    "currentEngine": ("输入方案", None, {}),          # 选项的名字输入法给（引擎名）
    "voiceKey": ("语音输入按键", "右 Alt 无效时请选择右 ⌘",
                 {"right_option": "右 ⌥（Alt）", "right_command": "右 ⌘", "right_control": "右 ⌃"}),
    "defaultEnglish": ("进入应用时的默认模式", None, {"false": "中文", "true": "英文"}),
    "orientation": ("候选排列", None, {"horizontal": "横排", "vertical": "竖排"}),
    "pagingKeys": ("翻页键", None, {"-=": "- 和 =", ",.": ", 和 ."}),
    "inline": ("拼音显示位置", None, {"true": "输入框", "false": "候选窗口"}),
}
# 一格一格调的数：键 → （叫什么，往小调的按钮，往大调的按钮）
STEPS = {"fontSize": ("字号", "减小", "增大"), "pageSize": ("每页候选数", "减少", "增加")}
# 分组和顺序；一组里没有一项的不画（语音那几项没装语音引擎时没有，联想、记忆记录没装个人化组件时没有）
GROUPS = [
    ("输入方式", ["currentEngine"]),
    ("模糊音", ["fuzzyOn", "fuzzyPairs.*"]),
    ("语音", ["voiceOn", "voiceKey", "voiceTidy"]),
    ("中英文", ["defaultEnglish", "rememberMode", "shiftToggles"]),
    ("排版", ["autoSpace", "cornerBraces"]),
    ("候选窗口", ["fontSize", "orientation", "pageSize", "pagingKeys", "inline"]),
    ("联想", ["predict"]),
    ("记忆记录", ["memory", "recordingPaused"]),
]
# 开了才用得上的：主开关关着时不画
UNDER = {"fuzzyPairs.": "fuzzyOn", "voiceKey": "voiceOn", "voiceTidy": "voiceOn"}
FORGOTTEN_ROWS = 50

# 没做成时的那一句（答复的 `code`）
ERRORS = {
    "not_running": "输入法未运行，切换到螺壳输入法后重试",
    "engine_not_running": "当前输入方案未运行，无法操作",
    "engine_changed": "输入方案已更换，请确认后重试",
    "not_found": "此词语已恢复",
    "not_ready": "设置文件尚未升级，使用一次输入法后重试",
    "settings_unreadable": "设置文件无法读取",
    "failed": "设置未能保存",
    "invalid": "此操作无法识别",
}


def build(page: str, args: Dict[str, str], read: Read) -> List[dict]:
    return {"settings": settings, "apps": apps, "more": more}[page](args, read)


def _n(v: Any) -> int:
    return v if isinstance(v, int) and not isinstance(v, bool) and v >= 0 else 0


def _percent(part: int, whole: int) -> str:
    return f"{round(part * 100 / whole)}%" if whole else "—"


def _setting_row(kit: PageKit, s: dict) -> Optional[str]:
    """一项设置一行；认不出的键、形状不对的不画"""
    key, value = s.get("key"), s.get("value")
    if not isinstance(key, str):
        return None
    if key.startswith("fuzzyPairs.") and isinstance(value, bool):
        title = key[len("fuzzyPairs."):].replace("_", " = ")
        return kit.item(title, None, [kit.button(title, SET, {"key": key, "value": not value}, variant="switch", on=value)],
                        strong=False)
    if key in SWITCHES and isinstance(value, bool):
        title, sub = SWITCHES[key]
        return kit.item(title, sub, [kit.button(title, SET, {"key": key, "value": not value}, variant="switch", on=value)])
    if key in CHOICES and isinstance(s.get("options"), list):
        title, sub, names = CHOICES[key]
        opts = []
        for o in s["options"]:
            v = o.get("value") if isinstance(o, dict) else o
            name = o.get("name") if isinstance(o, dict) else names.get(str(v))
            if isinstance(v, str) and isinstance(name, str) and name:
                opts.append((v, name))
        if not opts or not isinstance(value, str):
            return None
        pick = kit.button(title, SET, {"key": key, "value": {"path": f"/choices/{key}/0"}})
        return kit.row([kit.column([kit.text(title, "strong")] + ([kit.text(sub, "caption")] if sub else [])),
                        kit.choice(key, opts, value, submit=pick)], justify="spaceBetween")
    if key in CHOICES and isinstance(value, bool):          # 真假两个值的选项：选的是字，交回去时换成真假（`action`）
        title, sub, names = CHOICES[key]
        pick = kit.button(title, SET, {"key": key, "value": {"path": f"/choices/{key}/0"}, "bool": True})
        return kit.row([kit.text(title, "strong"),
                        kit.choice(key, [(v, names[v]) for v in names], "true" if value else "false", submit=pick)],
                       justify="spaceBetween")
    if key in STEPS and _is_int(value):
        title, less, more = STEPS[key]
        lo, hi, step = s.get("min"), s.get("max"), s.get("step") if _is_int(s.get("step")) and s.get("step") else 1
        right = []
        if not _is_int(lo) or value - step >= lo:        # 到头了的那一边不放按钮
            right.append(kit.button(less, SET, {"key": key, "value": value - step}, tooltip=f"{less}{title}"))
        right.append(kit.text(str(value)))
        if not _is_int(hi) or value + step <= hi:
            right.append(kit.button(more, SET, {"key": key, "value": value + step}, tooltip=f"{more}{title}"))
        return kit.item(title, None, right)
    return None


def _is_int(v: Any) -> bool:
    return isinstance(v, int) and not isinstance(v, bool)


def settings(args: Dict[str, str], read: Read) -> List[dict]:
    d = read("data/settings")
    d = d if isinstance(d, dict) else {}
    kit = PageKit("settings")
    top: List[str] = []
    state = d.get("state")
    if state == "unreadable":
        top.append(kit.heading("设置"))
        top.append(kit.list([kit.item("设置文件无法读取", "修正或移除设置文件后，使用一次输入法即可恢复")]))
    elif state == "not_ready":
        top.append(kit.heading("设置"))
        top.append(kit.list([kit.item("设置文件尚未升级", "使用一次输入法后即可在此更改设置")]))

    items = [s for s in d.get("settings") or [] if isinstance(s, dict) and isinstance(s.get("key"), str)]
    by_key = {s["key"]: s for s in items}
    if state != "not_ready":            # 没升级时改不了：不放开关
        for heading, keys in GROUPS:
            rows = []
            for k in keys:
                for s in ([x for x in items if x["key"].startswith(k[:-1])] if k.endswith("*") else [by_key[k]] if k in by_key else []):
                    main = next((m for prefix, m in UNDER.items() if s["key"].startswith(prefix)), None)
                    if main is not None and (by_key.get(main) or {}).get("value") is not True:
                        continue
                    row = _setting_row(kit, s)
                    if row:
                        rows.append(row)
            if rows:
                top.append(kit.heading(heading))
                top.append(kit.list(rows))
    _words(kit, top, d)
    # 不常用的几组在「高级设置」：标签栏右端的图标不好发现，页底再放一行进去的入口
    go = kit.open_page("高级设置", "more")
    top.append(kit.list([kit.item("高级设置", "使用统计、开发模式和文件", [go], open=go, strong=False)]))
    return kit.messages(top)


def more(args: Dict[str, str], read: Read) -> List[dict]:
    """「高级设置」：不常用的几组（UX-13）。设置文件读不到时只剩「文件」，能在访达中找到它"""
    d = read("data/settings")
    d = d if isinstance(d, dict) else {}
    kit = PageKit("more")
    top: List[str] = []
    _usage(kit, top, d)
    _dev(kit, top, d, d.get("state"))
    _files(kit, top, d)
    if not top:
        top.append(kit.text("暂无高级设置", "caption"))
    return kit.messages(top)


def _words(kit: PageKit, top: List[str], d: dict) -> None:
    """词语：学到的、忘掉的都存在当前输入方案那里"""
    learned = d.get("learned") if isinstance(d.get("learned"), dict) else None
    engine = learned.get("engine") if learned and isinstance(learned.get("engine"), dict) else None
    f = d.get("forgotten") if isinstance(d.get("forgotten"), dict) else {}
    recent = [w for w in f.get("recent") or [] if isinstance(w, dict) and isinstance(w.get("id"), str) and isinstance(w.get("text"), str)]
    older = _n(f.get("older"))
    if not (engine and isinstance(engine.get("id"), str)) and not recent and not older:
        return
    name = str(engine.get("name") or "") if engine else ""
    top.append(kit.heading(f"「{name}」的词语" if name else "词语"))
    rows = []
    if engine and isinstance(engine.get("id"), str):
        clear = kit.button("清除", DO, {"op": "clear_learned", "engine": engine["id"]}, variant="destructive",
                           confirm={"title": f"清除「{name}」的已学词语？" if name else "清除已学词语？",
                                    "text": "因改选而排序靠前的词语将全部清除，此后按默认顺序排列；已忘记的词语仍不显示。清除后无法恢复。",
                                    "label": "清除"})
        rows.append(kit.item("已学词语", "改选过的词语排序靠前", [clear]))
    if not recent and not older:
        rows.append(kit.item("已忘记词语", "在候选上按 Shift+⌫ 可忘记词语"))
    else:
        rows.append(kit.item("已忘记词语", "以下词语不再显示，可恢复"))
        for w in recent[:FORGOTTEN_ROWS]:
            rows.append(kit.item(w["text"], w.get("input") if isinstance(w.get("input"), str) else None,
                                 [kit.button("恢复", DO, {"op": "restore", "id": w["id"]}, variant="borderless")], strong=False))
        rest = older + max(0, len(recent) - FORGOTTEN_ROWS)
        if rest:
            rows.append(kit.item(f"另有 {rest} 个较早忘记的词语未列出", "仍不显示", strong=False))
    top.append(kit.list(rows))


def _usage(kit: PageKit, top: List[str], d: dict) -> None:
    u = d.get("usage") if isinstance(d.get("usage"), dict) else None
    if u is None:
        return
    days = [x for x in u.get("days") or [] if isinstance(x, dict) and isinstance(x.get("date"), str)]
    total: Dict[str, int] = {}
    for day in days:
        for k, v in (day.get("counts") or {}).items() if isinstance(day.get("counts"), dict) else ():
            total[k] = total.get(k, 0) + _n(v)
    top.append(kit.heading("使用统计"))
    note = "仅在本机统计次数，不记录输入内容和应用；密码框、暂停所有记录期间和禁止记录的应用中不统计"
    if not any(total.values()):
        top.append(kit.list([kit.item("最近 7 天", "暂无统计")]))
        return
    reset = kit.button("清零", DO, {"op": "reset_usage"},
                       confirm={"title": "清零使用统计？", "text": "最近 7 天的次数将全部清除，无法恢复。", "label": "清零"})
    rows = [kit.item("最近 7 天", note, [reset])]
    commit = total.get("commit", 0)
    picks = total.get("pick_first", 0) + total.get("pick_other", 0)
    rows.append(kit.item("上屏", None, [kit.text(f"{commit} 次")], strong=False))
    rows.append(kit.item("所选候选中首选占比", None, [kit.text(_percent(total.get("pick_first", 0), picks))], strong=False))
    rows.append(kit.item("上屏后立即退格占比", None, [kit.text(_percent(total.get("backspace_after_commit", 0), commit))], strong=False))
    if u.get("personal") is True:
        rows.append(kit.item("联想", None, [kit.text(
            f"显示 {total.get('predict_shown', 0)} 次，展开 {total.get('predict_opened', 0)} 次，"
            f"选用 {total.get('predict_picked', 0)} 次（共 {total.get('predict_chars', 0)} 字）")], strong=False))
    top.append(kit.list(rows))
    daily = [kit.item(day["date"][5:] if len(day["date"]) == 10 else day["date"], None,
                      [kit.text(f"{_n((day.get('counts') or {}).get('commit'))} 次")], strong=False) for day in days]
    top.append(kit.fold("每日上屏次数", [kit.list(daily)]))


def _dev(kit: PageKit, top: List[str], d: dict, state: Any) -> None:
    dev = d.get("dev") if isinstance(d.get("dev"), dict) else None
    if dev is None:
        return
    rows = []
    for e in dev.get("engines") or []:
        if not (isinstance(e, dict) and isinstance(e.get("id"), str) and isinstance(e.get("on"), bool)) or state == "not_ready":
            continue
        name = str(e.get("name") or e["id"])
        title = f"记录「{name}」的输入"
        confirm = None if e["on"] else {"title": f"开启「{name}」的开发模式？",
                                        "text": "开启后在本机记录此输入方案的按键和候选，保存在记录文件夹中，保留 7 天；"
                                                "密码框、暂停所有记录期间和禁止记录的应用中不记录。",
                                        "label": "开启"}
        rows.append(kit.item(title, None, [kit.button(title, DO, {"op": "dev_mode", "engine": e["id"], "on": not e["on"]},
                                                      variant="switch", on=e["on"], confirm=confirm)]))
    if isinstance(dev.get("log_dir"), str) and dev["log_dir"]:
        there = dev.get("log_dir_exists") is True
        rows.append(kit.item("记录文件夹", "开发模式的记录，保留 7 天" if there else "尚无记录",
                             [_reveal(kit, dev["log_dir"])] if there else []))
    if rows:
        top.append(kit.heading("开发模式"))
        top.append(kit.list(rows))


def _files(kit: PageKit, top: List[str], d: dict) -> None:
    paths = d.get("paths") if isinstance(d.get("paths"), dict) else {}
    rows = [kit.item(title, sub, [_reveal(kit, paths[key])])
            for key, title, sub in (("engines", "引擎文件夹", "用于放置自制引擎"), ("settings", "设置文件", None))
            if isinstance(paths.get(key), str) and paths[key]]
    if rows:
        top.append(kit.heading("文件"))
        top.append(kit.list(rows))


# 「各应用」：一个应用的一项 → （叫什么，{值的代号: 字}）
APP_CHOICES = {
    "english": ("默认输入模式", {"off": "中文", "on": "英文"}),
    "inline": ("拼音显示位置", {"on": "输入框", "off": "候选窗口"}),
    "predict": ("联想", {"on": "开启", "off": "关闭"}),
}
# 窗口示例里多存的几张带参数的页（scripts/window_samples.py 的 `views`）：名字 → （页，参数，{读的 uri: 样例里的文件}，只在哪个场景）
SAMPLE_VIEWS = {"apps-target": ("apps", {"app": "com.apple.Safari"},
                                {"data/apps?app=com.apple.Safari": "read-data-apps-target.json"}, "normal"),
                # 「高级设置」是隐藏页，回放时窗口不读：照录的 data/settings 拼一份，截图时换上去
                "more": ("more", {}, {"data/settings": "read-data-settings.json"}, "normal")}
APP_HOW = "在应用中打开输入法菜单，选择「此应用设置」"
_BUNDLE_ID = re.compile(r"^[A-Za-z0-9.-]{1,255}$")
APP_ROWS = 10           # 一页最多摊开几个应用（一个约 40 个组件）


def apps(args: Dict[str, str], read: Read) -> List[dict]:
    """`args["app"]`：从输入法菜单的「此应用的设置」点进来的那个应用（bundle id）。带着它读，还没单独设置过的输入法也给一项
    （`new`，各项跟随全局，改了第一项才记下）；它排在最前面"""
    target = args.get("app") if isinstance(args.get("app"), str) and _BUNDLE_ID.match(args.get("app") or "") else None
    d = read("data/apps?" + urlencode({"app": target})) if target else None
    if not isinstance(d, dict):         # 没带应用，或这一版输入法不认这个参数
        d = read("data/apps")
    d = d if isinstance(d, dict) else {}
    kit = PageKit("apps")
    top: List[str] = []
    state = d.get("state")
    if state in ("unreadable", "not_ready"):
        top.append(kit.heading("应用单独设置"))
        top.append(kit.list([kit.item("设置文件无法读取", "修正或移除设置文件后，使用一次输入法即可恢复") if state == "unreadable"
                             else kit.item("设置文件尚未升级", "使用一次输入法后即可在此更改设置")]))
        return kit.messages(top)
    listed = [a for a in d.get("apps") or [] if isinstance(a, dict) and isinstance(a.get("id"), str) and a["id"]]
    if not listed:
        top.append(kit.heading("应用单独设置"))
        top.append(kit.list([kit.item("暂无单独设置的应用", APP_HOW)]))
        return kit.messages(top)
    listed.sort(key=lambda a: a["id"] != target)        # 点进来的那个排最前，别的照输入法给的顺序
    for n, a in enumerate(listed[:APP_ROWS]):
        name = str(a.get("name") or a["id"])
        prefix = f"apps.{a['id']}."
        rows = [kit.item("尚未单独设置", "更改任一项后生效", strong=False)] if a.get("new") is True else []
        for s in a.get("settings") or []:
            key = s.get("key") if isinstance(s, dict) else None
            if not isinstance(key, str) or not key.startswith(prefix):
                continue
            what, value = key[len(prefix):], s.get("value")
            if what in APP_CHOICES and value in ("follow", "on", "off"):
                title, names = APP_CHOICES[what]
                # 全局现在是什么写在下面一行小字里：写进选项里太长，三个选项排不下会变成下拉菜单，一组里画法不齐
                f = s.get("follow")
                sub = "终端中默认关闭" if s.get("terminal") is True else f"全局：{names['on' if f else 'off']}" if isinstance(f, bool) else None
                ck = f"a{n}-{what}"
                pick = kit.button(title, SET, {"key": key, "value": {"path": f"/choices/{ck}/0"}})
                rows.append(kit.row([kit.column([kit.text(title, "strong")] + ([kit.text(sub, "caption")] if sub else [])),
                                     kit.choice(ck, [("follow", "跟随默认" if s.get("terminal") is True else "跟随全局")]
                                                + [(v, names[v]) for v in names], value, submit=pick)],
                                    justify="spaceBetween"))
            elif what == "noRecord" and isinstance(value, bool):
                title = "在此应用中禁止记录"
                rows.append(kit.item(title, "全局记录关闭或暂停时，此应用同样不记录",
                                     [kit.button(title, SET, {"key": key, "value": not value}, variant="switch", on=value)]))
        if a.get("new") is not True:        # 还没单独设置过的没有可恢复的
            reset = kit.button("恢复", SET, {"key": prefix + "reset", "value": True},
                               confirm={"title": f"将「{name}」恢复为跟随全局？", "text": "恢复后此应用不再单独设置，并从列表中移除。",
                                        "label": "恢复"})
            rows.append(kit.item("恢复跟随全局", "移除此应用的单独设置", [reset]))
        top.append(kit.heading(name))
        top.append(kit.list(rows))
    if len(listed) > APP_ROWS:
        top.append(kit.list([kit.item(f"另有 {len(listed) - APP_ROWS} 个应用未列出", "可在输入法菜单的「此应用设置」中查看", strong=False)]))
    top.append(kit.heading("添加"))
    top.append(kit.list([kit.item("为其他应用单独设置", APP_HOW)]))
    return kit.messages(top)


def _reveal(kit: PageKit, path: str) -> str:
    return kit.button("在访达中显示", "agent.reveal", {"item": path}, icon="folder", variant="borderless")


def action(name: str, ctx: Dict[str, Any]) -> Tuple[str, Dict[str, Any]]:
    """点按交给输入法前改形状：真假两个值的选项，页上选的是 "true" / "false" 两个字，交回去的是真假"""
    if name == SET and ctx.get("bool") is True:
        v = ctx.get("value")
        v = v[0] if isinstance(v, list) and v else v
        return name, {"key": ctx.get("key"), "value": v == "true"}
    return name, ctx


def result(name: str, data: dict, surface_id: str, has_card: bool) -> Optional[dict]:
    """动作做成了的那一句，照答复的 `data` 写（代号）。改设置的不另说话：页上的开关已经变了"""
    if name == DO:
        op = data.get("op")
        if op == "dev_mode":
            return {"text": "已开启开发模式" if data.get("on") is True else "已关闭开发模式"}
        words = {"clear_learned": "已清除已学词语", "restore": "已恢复", "reset_usage": "使用统计已清零"}.get(op)
        return {"text": words} if words else None
    if name == SET:
        return {"text": "已更改"}
    return None


def said(name: str, ctx: Dict[str, Any], result: dict) -> Optional[str]:
    """核心拼的页上点完的那一句：没做成的照代号写；做成的已经照 `data` 写好（`result`）"""
    if name in (SET, DO) and result.get("error"):
        return ERRORS.get(result.get("code") or "")
    return None
