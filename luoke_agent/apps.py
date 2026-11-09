"""应用的页和权限（docs/界面接口.md §6、§10；工具协议 §1a）：清单里的 `service`、`permissions` 怎么认，
工具报的概览和权限状态怎么认，权限一行现在能做什么，系统设置的哪一页。

工具给的文字（标题、`facts`、`without`）照原文交给窗口，窗口按纯文本画；工具给的动作名只在 agent 里用，不交给窗口。
"""
from __future__ import annotations

import re
from typing import Any, Dict, List, Optional, Tuple


KINDS = ("system", "account", "delegate", "each-time")
STATES = ("granted", "denied", "ask", "on", "off")
HOST_STATES = ("granted", "denied", "ask")
OPS = ("request", "settings", "on", "off", "open", "remove")
TOOL_OPS = ("request", "on", "off", "open", "remove")   # 这几样要工具在运行；settings 的地址由 agent 给，螺壳.app 打开
CONNECTED = ("granted", "on")                            # 算"给了"的状态
ID = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$")    # 页 id、权限 id：放进资源地址和网址路径里也不出岔子
MAX_TEXT = 2000

# tcc 键 → 系统设置「隐私与安全性」里的哪一页、叫什么。只认这几个，不认工具给的网址（协议 §1a）。
SETTINGS_URL = "x-apple.systempreferences:com.apple.preference.security?"
SETTINGS_PANES: Dict[str, Tuple[str, str]] = {
    "SystemPolicyAllFiles": ("Privacy_AllFiles", "完全磁盘访问"),
    "SystemPolicyDocumentsFolder": ("Privacy_FilesAndFolders", "文件与文件夹"),
    "SystemPolicyDownloadsFolder": ("Privacy_FilesAndFolders", "文件与文件夹"),
    "SystemPolicyDesktopFolder": ("Privacy_FilesAndFolders", "文件与文件夹"),
    "Accessibility": ("Privacy_Accessibility", "辅助功能"),
    "ScreenCapture": ("Privacy_ScreenCapture", "录屏"),
    "ListenEvent": ("Privacy_ListenEvent", "输入监控"),
    "AppleEvents": ("Privacy_Automation", "自动化"),
    "Calendar": ("Privacy_Calendars", "日历"),
    "Reminders": ("Privacy_Reminders", "提醒事项"),
    "AddressBook": ("Privacy_Contacts", "通讯录"),
    "Photos": ("Privacy_Photos", "照片"),
    "Camera": ("Privacy_Camera", "摄像头"),
    "Microphone": ("Privacy_Microphone", "麦克风"),
}


def settings_pane(tcc: Any) -> Optional[Tuple[str, str]]:
    """登记过的 tcc 键 → (系统设置的地址, 那一页叫什么)；没登记的是 None。"""
    pane = SETTINGS_PANES.get(tcc) if isinstance(tcc, str) else None
    return (SETTINGS_URL + pane[0], pane[1]) if pane else None


# ---------------------------------------------------------------- 清单


def _action(v: Any) -> Optional[str]:
    return v if isinstance(v, str) and v and not v.startswith("agent.") and len(v) <= 128 else None


def _pages(v: Any) -> List[dict]:
    out: List[dict] = []
    for p in v if isinstance(v, list) else []:
        if isinstance(p, dict) and isinstance(p.get("id"), str) and ID.match(p["id"]) \
                and isinstance(p.get("title"), str) and p["id"] not in {x["id"] for x in out}:
            out.append({"id": p["id"], "title": p["title"]})
    return out


def service(raw: Any) -> dict:
    """清单的 `service` → `{summary, pages, ui, search}`；`ui` 只有写了 `open` 才有（`{open, pages}`），否则是 None；
    `search` 是 `ask.search` 写的搜索工具名（协议 §1b），没写是 None。"""
    s = raw if isinstance(raw, dict) else {}
    ui = s.get("ui") if isinstance(s.get("ui"), dict) else {}
    ask = s.get("ask") if isinstance(s.get("ask"), dict) else {}
    opener = _action(ui.get("open"))
    return {"summary": s.get("summary") is True, "pages": _pages(s.get("pages")),
            "ui": {"open": opener, "pages": _pages(ui.get("pages"))} if opener else None,
            "search": _action(ask.get("search"))}


def permissions(raw: Any) -> List[dict]:
    """清单的 `permissions` → 认得的那几项（id、kind、title 必填；同一个 id 只认第一个）。"""
    out: List[dict] = []
    for p in raw if isinstance(raw, list) else []:
        if not isinstance(p, dict) or not isinstance(p.get("id"), str) or not ID.match(p["id"]) \
                or p.get("kind") not in KINDS or not isinstance(p.get("title"), str) \
                or p["id"] in {x["id"] for x in out}:
            continue
        e: Dict[str, Any] = {"id": p["id"], "kind": p["kind"], "title": p["title"]}
        for k in ("owner", "tcc", "without", "page"):
            if isinstance(p.get(k), str) and p[k]:
                e[k] = p[k]
        for k in ("request", "on", "remove"):
            if _action(p.get(k)):
                e[k] = p[k]
        facts = [f for f in p["facts"] if isinstance(f, str)] if isinstance(p.get("facts"), list) else []
        if facts:
            e["facts"] = facts
        out.append(e)
    return out


# ---------------------------------------------------------------- 工具报的


def summary(raw: Any) -> Optional[dict]:
    """`summary` 资源 → `{count, text}`；不对就当没有。"""
    if not isinstance(raw, dict) or not isinstance(raw.get("text"), str) or len(raw["text"]) > MAX_TEXT:
        return None
    count = raw.get("count")
    if isinstance(count, bool) or not isinstance(count, (int, float)) or count < 0 or count != int(count):
        return None
    return {"count": int(count), "text": raw["text"]}


def states(raw: Any) -> Optional[Dict[str, str]]:
    """`permissions` 资源 → `{权限 id: 状态}`，只留认得的状态。"""
    if not isinstance(raw, dict):
        return None
    return {k: v for k, v in raw.items() if isinstance(k, str) and v in STATES}


def host_states(raw: Any) -> Dict[str, Optional[str]]:
    """`POST /host` 的 `permissions`：`{权限 id: granted / denied / ask / null}`；不对抛 ValueError。"""
    if not isinstance(raw, dict):
        raise ValueError("permissions 要是对象")
    for k, v in raw.items():
        if not ID.match(k) or not (v is None or v in HOST_STATES):
            raise ValueError("permissions 要是 {\"权限 id\": granted / denied / ask / null}")
    return dict(raw)


def host_confirmed(raw: Any) -> Optional[Dict[str, Dict[str, str]]]:
    """`POST /host` 的 `confirmed`：`{应用: {权限 id: 确认的时间}}`，整份替换；没报是 None。不对抛 ValueError。"""
    if raw is None:
        return None
    if not isinstance(raw, dict) or not all(
            isinstance(ids, dict) and all(ID.match(k) and isinstance(v, str) for k, v in ids.items()) for ids in raw.values()):
        raise ValueError("confirmed 要是 {\"应用\": {\"权限 id\": 确认的时间}}")
    return {app: dict(ids) for app, ids in raw.items()}


# ---------------------------------------------------------------- 权限页的一行


def can(perm: dict, state: Optional[str], *, running: bool, ui_open: bool) -> Optional[List[str]]:
    """这一行现在能做什么（docs/界面接口.md §10）；`each-time` 的没有（None）。

    - system：写了 `request`、还没问过（`ask`）、工具在运行、不在螺壳名下 → `request`；否则 tcc 键登记过 → `settings`
      （去系统设置给或收回）。
    - delegate：写了 `on`、工具在运行：开着给 `off`，关着给 `on`；不知道状态就都不给。
    - account：工具有自己的界面 → `open`；写了 `remove`、连着（granted）→ `remove`；都要工具在运行。
    """
    kind = perm["kind"]
    if kind == "each-time":
        return None
    ops: List[str] = []
    if kind == "system":
        if perm.get("request") and perm.get("owner") != "luoke" and state == "ask":
            if running:
                ops.append("request")
        elif settings_pane(perm.get("tcc")):
            ops.append("settings")
    elif kind == "delegate":
        if perm.get("on") and running and state in ("on", "off"):
            ops.append("off" if state == "on" else "on")
    elif kind == "account" and running:
        if ui_open:
            ops.append("open")
        if perm.get("remove") and state == "granted":
            ops.append("remove")
    return ops


def row(app: str, perm: dict, state: Optional[str], ops: Optional[List[str]]) -> dict:
    out: Dict[str, Any] = {"app": app, "id": perm["id"], "kind": perm["kind"]}
    for k in ("owner", "tcc"):
        if k in perm:
            out[k] = perm[k]
    out["title"] = perm["title"]
    for k in ("facts", "without"):
        if k in perm:
            out[k] = perm[k]
    out["state"] = state
    if ops is not None:
        out["can"] = ops
    return out
