"""搜索框的结果（docs/界面接口.md §7、工具协议 §1b）：工具给的 `hits` 核过形状交给窗口，窗口自己按类型分组画；
缩略图（`thumb/<id>`）由核心向工具读，核过是 JPEG、PNG，大小和尺寸在限度内才给窗口。

hits 里的字都当数据：只留认得的字段，字符串截短；动作只留工具自己的（不认 `agent.` 开头的），按钮点了由核心转给
出这条结果的工具，参数从这里留下的结果里取，不从窗口来。"""
from __future__ import annotations

import re
import struct
from typing import Any, Dict, List, Optional, Tuple

MAX_HITS = 50                    # 一个工具一次最多交给窗口几条（同 /search 的 limit 上限）
MAX_ACTIONS = 4                  # 一条最多几个动作
THUMB_REF = re.compile(r"thumb/(?!\.+$)[A-Za-z0-9._-]{1,64}")   # 用 fullmatch；只有点的（thumb/..）不认
MAX_THUMB_BYTES = 256 * 1024     # 一张缩略图最大（工具协议 §1b Image 组件）
MAX_THUMB_SIDE = 2048            # 长边最大

# 字段 → 最多几个字
TEXT_FIELDS = {"id": 200, "kind": 40, "kind_label": 20, "title": 200, "line": 120, "date": 40, "snippet": 400,
               "source": 200, "path": 1024, "alt": 200}


def _text(v: Any, n: int) -> Optional[str]:
    if not isinstance(v, str):
        return None
    v = v.strip()
    return v[:n] if v else None


def action(a: Any) -> Optional[dict]:
    """一个动作：`{name, title, args, primary?}`；agent 自己的动作不从工具的结果里认。"""
    if not isinstance(a, dict):
        return None
    name, title = a.get("name"), _text(a.get("title"), 20)
    if not isinstance(name, str) or not name or name.startswith("agent.") or len(name) > 100 or title is None:
        return None
    out = {"name": name, "title": title, "args": a["args"] if isinstance(a.get("args"), dict) else {}}
    if a.get("primary") is True:
        out["primary"] = True
    return out


def hit(h: Any) -> Optional[dict]:
    """一条结果，只留窗口要的字段；没有编号、标题的不算一条。"""
    if not isinstance(h, dict):
        return None
    out: Dict[str, Any] = {}
    for k, n in TEXT_FIELDS.items():
        v = _text(h.get(k), n)
        if v is not None:
            out[k] = v
    if "id" not in out or "title" not in out:
        return None
    if h.get("strong") is True:
        out["strong"] = True
    thumb = h.get("thumb")
    if isinstance(thumb, str) and THUMB_REF.fullmatch(thumb):
        out["thumb"] = thumb
    acts = [x for x in (action(a) for a in (h.get("actions") if isinstance(h.get("actions"), list) else [])) if x]
    out["actions"] = acts[:MAX_ACTIONS]
    return out


def hits(raw: Any, limit: int) -> List[dict]:
    """工具答复里的 `hits`，核过形状，编号重复的只留第一条，最多 `limit` 条。"""
    out: List[dict] = []
    seen = set()
    for h in raw if isinstance(raw, list) else []:
        x = hit(h)
        if x is None or x["id"] in seen:
            continue
        seen.add(x["id"])
        out.append(x)
        if len(out) >= min(limit, MAX_HITS):
            break
    return out


def only_tools(hits: List[dict], names: Any) -> List[dict]:
    """动作只留这个工具 `tools/list` 里有的（工具协议 §1b「不在的不画」），免得窗口画出点不了的按钮、回车选中它。"""
    return [{**h, "actions": [a for a in h["actions"] if a["name"] in names]} for h in hits]


def for_window(hits: List[dict]) -> List[dict]:
    """交给窗口的那份：动作的 `args` 留在核心（按钮点了从核心留下的结果里取），窗口只拿到
    `name`、`title`、`primary`，参数里有 `reveal: true` 的标 `reveal: true`（窗口认「在访达中显示」、⌘↩ 用）。"""
    out = []
    for h in hits:
        acts = []
        for a in h["actions"]:
            w = {k: a[k] for k in ("name", "title", "primary") if k in a}
            if a["args"].get("reveal") is True:
                w["reveal"] = True
            acts.append(w)
        out.append({**h, "actions": acts})
    return out


def image_size(data: bytes) -> Optional[Tuple[str, int, int]]:
    """看文件头认 JPEG、PNG（不看扩展名和 MIME），读出像素尺寸，不解码。认不出是 None。"""
    if data[:8] == b"\x89PNG\r\n\x1a\n" and len(data) >= 24 and data[12:16] == b"IHDR":
        w, h = struct.unpack(">II", data[16:24])
        return "image/png", w, h
    if data[:3] != b"\xff\xd8\xff":
        return None
    i = 2
    while i + 4 <= len(data):
        if data[i] != 0xFF:
            return None
        marker = data[i + 1]
        if marker == 0xFF:              # 填充
            i += 1
            continue
        if marker in (0xD8, 0x01) or 0xD0 <= marker <= 0xD7:
            i += 2
            continue
        seg = struct.unpack(">H", data[i + 2:i + 4])[0]
        if seg < 2:
            return None
        # SOF0–SOF15，除了 DHT（C4）、JPG（C8）、DAC（CC）
        if 0xC0 <= marker <= 0xCF and marker not in (0xC4, 0xC8, 0xCC):
            if i + 9 > len(data):
                return None
            h, w = struct.unpack(">HH", data[i + 5:i + 9])
            return "image/jpeg", w, h
        i += 2 + seg
    return None


def thumb_ok(data: bytes) -> Optional[str]:
    """能交给窗口的缩略图：JPEG 或 PNG，不超过 256 KB，长边不超过 2048，宽高都不是 0。答 MIME 类型，不行是 None。"""
    if not data or len(data) > MAX_THUMB_BYTES:
        return None
    found = image_size(data)
    if found is None:
        return None
    mime, w, h = found
    if not (0 < w <= MAX_THUMB_SIDE and 0 < h <= MAX_THUMB_SIDE):
        return None
    return mime
