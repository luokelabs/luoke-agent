# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 螺壳实验室 Luoke Labs
"""应用页由核心照各应用的原始数据拼（顶层 ADR 0028）。一个应用一个模块：`PAGES`（标签和隐藏页）、`BUILT`（已经搬过来的页）、
`NEEDS`（要应用给哪几样原始数据）、`build(page, args, read)`。应用在清单 `capabilities.data` 里列了 `NEEDS` 才由核心拼；
没列的（旧版本）照旧读它自己的页。

同一份 ADR 2026-11-17 起还管四处用语：卡片、侧栏的概览、动作做完后的结果、清单里固定的名字。应用只给数字和状态，
句子由这里写：模块里的 `summary`（侧栏那一句）、`KIND_NAMES` / `PERMISSION_NAMES`（按代号起名）、`items` / `card`
（「今天」的卡片）、`said`（结果的那一句）。应用还没给数据的，照旧用它带的文字（docs/工具协议.md §0）。"""
from __future__ import annotations

from typing import Any, List, Optional

from . import ime, mail, mem, scan, search

BUILDERS = {ime.APP: ime, mail.APP: mail, mem.APP: mem, scan.APP: scan, search.APP: search}


def kind_name(app: str, kind: str) -> Optional[str]:
    """提醒的一类事（清单 `reports` 的 `kind`）在界面上叫什么；没起名的是 None，照清单写的"""
    return getattr(BUILDERS.get(app), "KIND_NAMES", {}).get(kind)


def permission_name(app: str, pid: str) -> Optional[str]:
    """一项权限（清单 `permissions` 的 `id`）在界面上叫什么；没起名的是 None，照清单写的"""
    return getattr(BUILDERS.get(app), "PERMISSION_NAMES", {}).get(pid)


def item_words(app: str, data: Any, surface_id: str) -> Optional[dict]:
    """应用报的一件事照它带的 `data` 写（顶层 ADR 0028）：{"title", "summary", "why_now", "card"}。
    这个应用没有写法、认不出是哪一种、没拼成：None，照旧用应用带的卡片和文字"""
    mod = BUILDERS.get(app)
    if mod is None or not hasattr(mod, "item") or not isinstance(data, dict):
        return None
    return mod.item(data, surface_id)


def result_words(app: str, name: str, data: Any, surface_id: str, has_card: bool) -> Optional[dict]:
    """动作的答复照它带的 `data` 写：{"text"}，应用带了卡片时再有 {"card"}。没有写法、认不出：None"""
    mod = BUILDERS.get(app)
    if mod is None or not hasattr(mod, "result") or not isinstance(data, dict):
        return None
    return mod.result(name, data, surface_id, has_card)


def hit_words(app: str, hit: dict) -> dict:
    """一条搜索结果上的字照代号和数字写（这个应用的 `hit_words`）；没有写法、没写成的原样"""
    mod = BUILDERS.get(app)
    if mod is None or not hasattr(mod, "hit_words"):
        return hit
    try:
        return mod.hit_words(hit)
    except Exception:
        return hit


def builder(src: Any) -> Optional[Any]:
    """这个应用的标签由核心定吗：有拼页的模块，应用的清单也列了最基本的几样原始数据（`NEEDS`）"""
    mod = BUILDERS.get(getattr(src, "source", None))
    if mod is None or not set(mod.NEEDS) <= set(getattr(src, "data", None) or []):
        return None
    return mod


def builds(src: Any, page: str) -> Optional[Any]:
    """这一页由核心拼吗：这一页要的原始数据应用都给了（`PAGE_NEEDS`），没给齐的照旧读应用自己的页"""
    mod = builder(src)
    if mod is None or page not in mod.BUILT:
        return None
    return mod if set(mod.PAGE_NEEDS.get(page, ())) <= set(getattr(src, "data", None) or []) else None


def pages(src: Any, tool_pages: List[dict]) -> List[dict]:
    """标签和隐藏页：核心拼的那几页照模块写的；应用自己还有、模块里没有的页照旧留着（隐藏），卡片上的链接还去得了"""
    mod = builder(src)
    if mod is None:
        return tool_pages
    mine = [dict(p) for p in mod.PAGES]
    ids = {p["id"] for p in mine}
    return mine + [dict(p, hidden=True) for p in tool_pages if p["id"] not in ids]


def alias(src: Any, page: Any, args: Any = None) -> Any:
    """应用自己的旧页换成核心拼的那一页（模块的 `PAGE_ALIASES`）：那一页核心拼得出来才换，拼不出来照旧去应用自己的。
    带着某个参数去的换成另一页（模块的 `ARG_PAGES`：邮件助手卡片上「在邮件助手中查看」带 `id` 去收件箱，是要看那一封）"""
    mod = builder(src)
    to = getattr(mod, "PAGE_ALIASES", {}).get(page) if mod is not None and isinstance(page, str) else None
    page = to if to is not None and builds(src, to) is not None else page
    if mod is not None and isinstance(page, str) and isinstance(args, dict):
        for (frm, arg, without), to in getattr(mod, "ARG_PAGES", {}).items():
            if frm == page and args.get(arg) and not any(args.get(w) for w in without) and builds(src, to) is not None:
                return to
    return page


def cards(src: Any) -> Optional[Any]:
    """这个应用在「今天」上的卡片由核心拼吗：模块有 `card`，应用的清单也列了它要的原始数据（`CARD_NEEDS`）"""
    mod = BUILDERS.get(getattr(src, "source", None))
    if mod is None or not hasattr(mod, "card") or not set(mod.CARD_NEEDS) <= set(getattr(src, "data", None) or []):
        return None
    return mod
