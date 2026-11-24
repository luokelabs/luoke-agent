# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 螺壳实验室 Luoke Labs
"""搜索的应用页：照它给的原始数据（luoke-search docs/窗口接口.md「应用页的原始数据」，`data/…`）拼，
样子照批过的效果图（走查重画稿「搜索的应用页（第二稿）」）。页上的字都在这里写，搜索只给事实和动作（顶层 ADR 0028）。

一页从上到下：最近搜索（点了就搜，能清除）；检索范围（一个文件夹一行，写状态；添加、跳过的）；
权限（文件、照片两个开关）；建立索引（自动 / 手动，进度只在这一行）。都摊开，不点进二级页（负责人的批注）。"""
from __future__ import annotations

import os
from typing import Any, Callable, Dict, List, Optional

from .kit import PageKit

APP = "luoke-search"
# 清单里给界面用的固定名字（提醒的类别 `reports`、权限 `permissions`）：按代号在这里起名（负责人 11-17：用语由 agent 定）；
# 这里没有的代号照清单写的
KIND_NAMES = {"needs-setup": "检索范围未设置", "needs-access": "权限申请", "index-ready": "索引建立完成"}
PERMISSION_NAMES = {"photos": "照片图库", "folders": "读取个人文件夹和 iCloud 云盘", "quicktime": "控制 QuickTime Player 跳转到视频位置"}
PAGE_NEEDS = {"overview": ("recent", "scope", "permissions", "index")}
NEEDS = PAGE_NEEDS["overview"]
BUILT = set(PAGE_NEEDS)
PAGES = [{"id": "overview", "title": "概览"}]
SET = "search_settings_apply"

# 常见的文件夹叫它在访达里的名字
FOLDER = {"Desktop": "桌面", "Documents": "文稿", "Downloads": "下载", "Pictures": "图片", "Movies": "影片", "Music": "音乐"}
# 暂停的原因（data/index 的 paused.reasons 代号，同 search_status）：每个代号都认（负责人 11-15：原因对不上代号）
PAUSED = {"battery": "使用电池", "low_power": "低电量模式", "thermal": "设备温度过高", "memory": "内存不足",
          "manual": "手动模式，有文件等待索引"}
PAUSED_BY = {"luoke": "螺壳已暂停后台任务", "user": "手动模式"}
SKIPPED_ROWS = 20

Read = Callable[[str], Any]


def build(page: str, args: Dict[str, str], read: Read) -> List[dict]:
    return {"overview": overview}[page](args, read)


def folder_name(f: dict) -> str:
    if f.get("kind") == "icloud":
        return "iCloud 云盘"
    name = f.get("name") or (f.get("path") or "").rstrip("/").split("/")[-1]
    return FOLDER.get(name, name) or (f.get("path") or "")


def _short(path: Optional[str]) -> str:
    """路径里的家目录写成 `~`"""
    path = path or ""
    home = os.path.expanduser("~").rstrip("/")
    return "~" + path[len(home):] if home and (path == home or path.startswith(home + "/")) else path


def _index_line(ix: dict) -> str:
    state = ix.get("state")
    if state == "building":
        p = ix.get("progress")
        return f"正在建立索引 {round(p * 100)}%" if isinstance(p, (int, float)) else "正在建立索引"
    if state == "paused":
        paused = ix.get("paused") or {}
        reasons = [PAUSED[r] for r in (paused.get("reasons") or []) if r in PAUSED]
        if not reasons and paused.get("by") in PAUSED_BY:
            reasons = [PAUSED_BY[paused["by"]]]
        return "已暂停：" + "、".join(reasons) if reasons else "已暂停"
    if state == "needs_setup":
        return "尚未选择检索范围"
    return "有新文件时点击「立即索引」" if ix.get("mode") == "manual" else "索引已是最新"


# 搜索结果一条上的字：类型、命中在哪、按钮（顶层 ADR 0028：搜索给代号和数字，这里写字）
HIT_KIND = {"doc": "文档", "pdf": "PDF", "sheet": "表格", "screenshot": "截图", "image": "图片", "video": "视频", "audio": "录音",
            "photo": "照片"}


def _clock(seconds: float) -> str:
    """「1:05」「1:02:03」"""
    s = int(seconds)
    return f"{s // 3600}:{s % 3600 // 60:02d}:{s % 60:02d}" if s >= 3600 else f"{s // 60}:{s % 60:02d}"


def hit_words(h: dict) -> dict:
    """一条搜索结果上由核心写的字：`kind_label`（什么类型）、`line`（命中在第几页、几分几秒）、每个动作的 `title`。
    认不出的类型、动作照搜索给的"""
    out = dict(h)
    if h.get("kind") in HIT_KIND:
        out["kind_label"] = HIT_KIND[h["kind"]]
    where = h.get("where") or {}
    line = (f"第 {int(where['page'])} 页" if "page" in where else f"第 {int(where['part'])} 部分" if "part" in where
            else f"第 {int(where['sheet'])} 个工作表" if "sheet" in where else _clock(where["time"]) if "time" in where else None)
    if line:                    # 搜索没给位置：它带的那一行（没有就是没有）照旧
        out["line"] = line
    acts = []
    for a in h.get("actions") or []:
        if a.get("name") == "search_open":
            a = dict(a, title="在访达中显示" if (a.get("args") or {}).get("reveal") is True else "打开")
        acts.append(a)
    out["actions"] = acts
    return out


def summary(read: Read) -> Optional[str]:
    """侧栏上搜索名字下面的那一行，照原始数据写（负责人 11-17：应用只给数字和状态，怎么说由 agent 定）。
    读不到数据返回 None，照旧用应用给的"""
    ix = read("data/index")
    if not isinstance(ix, dict):
        return None
    state = ix.get("state")
    if state == "needs_setup":
        return "尚未选择检索范围"
    if state == "building":
        p = ix.get("progress")
        line = f"正在建立索引 {round(p * 100)}%" if isinstance(p, (int, float)) and not isinstance(p, bool) else "正在建立索引"
    elif state == "paused":
        line = "索引已暂停"
    else:
        line = "索引已是最新"
    perms = read("data/permissions")
    waiting = sum(1 for k in ("files", "photos") if isinstance(perms, dict) and isinstance(perms.get(k), dict)
                  and perms[k].get("on") and perms[k].get("system") == "denied")
    return f"{line}，{waiting} 项权限待允许" if waiting else line


def overview(args: Dict[str, str], read: Read) -> List[dict]:
    recent = read("data/recent") or {}
    scope = read("data/scope") or {}
    perms = read("data/permissions") or {}
    ix = read("data/index") or {}
    kit = PageKit("overview")
    setup = ix.get("state") == "needs_setup"

    # 搜用窗口底部的搜索框；这里只放最近搜过的，点了交给它；能清除（负责人 11-15：清除最近搜过的没了）
    top = []
    queries = [q for q in recent.get("queries") or [] if isinstance(q, str) and q][:5]
    if queries:
        top.append(kit.heading("最近搜索"))
        clear = kit.button("清除", SET, {"clear_recent": True}, variant="borderless",
                           confirm={"title": "清除最近搜索？", "text": "仅清除搜索记录，不影响索引。", "label": "清除"})
        top.append(kit.row([kit.row([kit.button(q, "agent.search", {"q": q}) for q in queries]), clear], justify="spaceBetween"))

    # 检索范围：每个文件夹一行，写状态（没接上、系统不让读）；外接盘、添加各一行；跳过的收起来，能取消跳过
    top.append(kit.heading("检索范围"))
    rows = []
    for f in scope.get("folders") or []:
        name = folder_name(f)
        state = "未连接" if f.get("connected") is False else "系统未允许读取" if f.get("readable") is False else ""
        drop = kit.button("移除", SET, {"remove_folder": f["id"]}, icon="x", variant="borderless",
                          confirm={"title": f"将「{name}」移出检索范围？", "text": "移出后不再搜索其中的文件，可随时重新添加。", "label": "移除"})
        rows.append(kit.item(name, " · ".join(x for x in (state, _short(f.get("path"))) if x) or None, [drop], strong=False))
    for d in scope.get("disks") or []:
        if d.get("connected"):
            rows.append(kit.item(d.get("name") or "外接磁盘", "已连接，未加入检索范围",
                                 [kit.button("加入", SET, {"disk": d["id"]}, variant="borderless")], strong=False))
    add = kit.button("选择", SET, {"add_folder": True})
    rows.append(kit.item("添加文件夹", "正在选择文件夹" if scope.get("picking") else None, [add], strong=False))
    top.append(kit.list(rows))
    skipped = [s for s in scope.get("skipped") or [] if isinstance(s, dict) and s.get("id")]
    if skipped:
        srows = [kit.item(s.get("name") or (s.get("path") or "").rstrip("/").split("/")[-1], _short(s.get("path")) or None,
                          [kit.button("取消跳过", SET, {"unskip": s["id"]}, variant="borderless")], strong=False)
                 for s in skipped[:SKIPPED_ROWS]]
        top.append(kit.fold(f"已跳过 {len(skipped)} 个", [kit.list(srows)]))

    # 权限：文件、照片图库两个开关；系统那一层没允许时写清楚去哪里允许（负责人 11-15：写「打开时会再问」是错的，系统不会再问）。
    # 照片图库没允许时搜索不读图库、也不打开图库里的照片，系统也不会自己来问（只在用户点了「允许」以后问）；
    # 检索范围里的图片文件走「文件」，照常能搜能开：写明白，免得看着像「没允许却打得开」（2026-11-23 的测试反馈）。
    # 还没选检索范围时点开关一律被拒：不放开关，写先做什么
    top.append(kit.heading("权限"))
    rows = []
    for key, title in (("files", "文件"), ("photos", "照片图库")):
        p = perms.get(key)
        if not isinstance(p, dict):
            continue
        on = bool(p.get("on"))
        if setup:
            rows.append(kit.item(title, "添加检索范围后可设置", strong=True))
            continue
        sub = None
        if on and p.get("system") == "denied":
            sub = "系统未允许读取，请在螺壳「设置 · 隐私与权限」中允许" + ("；文件夹里的图片照常能搜" if key == "photos" else "")
        elif on and p.get("system") == "ask":
            sub = "尚未允许读取，请在螺壳「设置 · 隐私与权限」中允许" + ("；文件夹里的图片照常能搜" if key == "photos" else "")
        sw = kit.button(title, SET, {key: not on}, variant="switch", on=on)
        rows.append(kit.item(title, sub, [sw]))
    top.append(kit.list(rows))

    top.append(kit.heading("建立索引"))
    mode = ix.get("mode") if ix.get("mode") in ("auto", "manual") else "auto"
    pick = kit.button("切换方式", SET, {"mode": {"path": "/choices/mode/0"}})
    right = [kit.choice("mode", [("auto", "自动"), ("manual", "手动")], mode, submit=pick)]
    if mode == "manual" and ix.get("state") != "building" and not setup:
        right.insert(0, kit.button("立即索引", SET, {"index_now": True}))
    left = kit.column([kit.text("方式", "strong"), kit.text(_index_line(ix), "caption")])
    top.append(kit.column([kit.row([left] + right, justify="spaceBetween")]))
    # 选文件夹的框开着（点了「添加」）：隔 2 秒再读，加上的文件夹一写进设置就出现（负责人 11-15：添加后页面不自己更新）
    return kit.messages(top, refresh=2 if scope.get("picking") else None)


# ---------------------------------------------------------------- 「今天」的卡片和点按后的那一句，照数据写
#
# 顶层 ADR 0028：搜索只给「是哪一种事、涉及什么、数字多少、能做哪些动作和参数」（outbox 每件事的 `data`，
# 搜索的 docs/窗口接口.md「outbox 每一件事的 data」），句子、按钮上的字在这里写。认不出的返回 None，照旧用搜索带的。

SAID_ON_CARDS = True        # 卡片上的点按做成了，那一句也照 `said` 写（`ToolSource._own_said`）
PLACE = {"home": "个人文件夹", "icloud": "iCloud 云盘", "desktop": "桌面", "documents": "文稿", "downloads": "下载",
         "pictures": "图片", "movies": "影片", "music": "音乐", "public": "公共"}


def _place(d: dict) -> str:
    return PLACE.get(d.get("place") or "") or str(d.get("name") or "") or "文件夹"


def item(data: dict, surface_id: str) -> Optional[dict]:
    """outbox 的一件事照它的 `data` 写：{"title", "summary", "why_now", "card"}；认不出是哪一种返回 None"""
    from .. import cards
    card = cards.Card(surface_id)
    kind = data.get("type")
    if kind == "needs-setup":
        choices = [c for c in data.get("choices") or [] if isinstance(c, dict) and isinstance(c.get("key"), str)]
        if not choices or not isinstance(data.get("plan"), str):
            return None
        title = "尚未选择检索范围"
        body = "勾选要检索的位置，确定后在后台建立索引，数据不离开这台 Mac"
        card.heading(title)
        card.text(body)
        for c in choices:
            label = "照片图库中的照片和视频（需允许读取照片）" if c.get("photos") else _place(c)
            card.checkbox(c["key"], label, bool(c.get("on")))
        if data.get("protected"):
            card.text("macOS 会先询问是否允许读取这些文件夹", caption=True)
        card.buttons(cards.button("确定", "search_settings_apply", {"plan_id": data["plan"], "checks": {"path": "/checks"}}, primary=True),
                     cards.button("暂不设置", "agent.dismiss"))
        names = "、".join(_place(c) for c in choices if c.get("on") and not c.get("photos"))
        summary = (f"默认检索{names}；" if names else "") + "照片图库和外接磁盘默认不检索"
        return {"title": title, "summary": summary, "why_now": "未选择检索范围时无法搜索", "card": card.messages()}
    if kind == "needs-access" and data.get("what") == "folder":
        title = f"无法读取「{_place(data)}」"
        body = "请在「系统设置 › 隐私与安全性 › 文件和文件夹」中允许螺壳读取"
        card.heading(title)
        card.text(body)
        card.buttons(cards.button("打开系统设置", "search_open_system_settings", {"pane": data.get("pane") or "files"}, primary=True))
        return {"title": title, "summary": body, "why_now": "未允许时无法搜索其中的内容", "card": card.messages()}
    if kind == "needs-access" and data.get("what") == "photos":
        pane = {"pane": data.get("pane") or "photos"}
        if data.get("refused"):
            title = "无法读取照片图库"
            body = "请在「系统设置 › 隐私与安全性 › 照片」中允许螺壳读取"
            card.heading(title)
            card.text(body)
            card.buttons(cards.button("打开系统设置", "search_open_system_settings", pane, primary=True),
                         cards.button("忽略", "agent.dismiss"))
        else:
            title = "需要允许读取照片图库"
            body = "已开启照片搜索，允许后可搜索照片图库中的照片和视频"
            card.heading(title)
            card.text(body)
            card.text("只读，不修改图库；不从 iCloud 下载；数据不离开这台 Mac", caption=True)
            card.buttons(cards.button("允许", "search_open_system_settings", pane, primary=True),
                         cards.button("忽略", "agent.dismiss"))
        return {"title": title, "summary": body, "why_now": "未允许时无法搜索照片图库", "card": card.messages()}
    if kind == "index-ready":
        n = lambda k: int(data.get(k) or 0) if not isinstance(data.get(k), bool) else 0   # noqa: E731
        title = "首次索引已完成"
        parts = [f"已索引 {n('total')} 个文件"]
        if n("waiting_for_media"):
            parts.append(f"其中 {n('waiting_for_media')} 个文件的图片和声音暂时只能按名称和文字搜索")
        if n("not_on_this_mac"):
            parts.append(f"另有 {n('not_on_this_mac')} 个文件不在这台 Mac 上，回到本机后再读取")
        card.heading(title)
        card.text("，".join(parts))
        return {"title": title, "summary": "，".join(parts), "why_now": "首次索引完成", "card": card.messages()}
    return None


def said(name: str, ctx: Dict[str, Any], result: dict) -> Optional[str]:
    """点按做成了以后的那一句，照点的是什么写（搜索的答复没有 `data`：点的是哪个开关、哪个按钮核心自己知道）。
    没做成的照搜索说的"""
    if result.get("error"):
        return None
    if name == "search_open_system_settings":
        return "已打开系统设置"
    if name == "search_open":
        return "已在访达中显示" if ctx.get("reveal") is True else "已打开"
    if name != "search_settings_apply":
        return None
    if "plan_id" in ctx:
        return "检索范围已保存，新加入的位置将在后台建立索引"
    if "files" in ctx:
        return "已开启文件搜索" if ctx["files"] else "已关闭文件搜索，已读取的内容保留"
    if "photos" in ctx:
        return "已开启照片搜索" if ctx["photos"] else "已关闭照片搜索"
    if "mode" in ctx:
        return "已改为自动建立索引" if ctx["mode"] == "auto" else "已改为手动建立索引"
    for key, words in (("index_now", "已开始建立索引"), ("add_folder", "请在弹出的窗口中选择文件夹"), ("clear_recent", "已清除最近搜索"),
                       ("skip", "已跳过，其中的内容将移出索引"), ("unskip", "已取消跳过，其中的内容将在后台读取"),
                       ("disk", "已加入检索范围，将在后台读取"), ("remove_folder", "已移出检索范围"), ("folder", "已移出检索范围")):
        if key in ctx:
            return words
    return None
