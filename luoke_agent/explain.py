"""占空间的文件是做什么用的（扫描「状态」页每一行下面的那一句；负责人 2026-11-17：要能看出哪些文件占地方、
能不能清，需要 AI 简单讲一下它们是干什么的）。

模型任务 `luoke-agent.explain`（主控配方里的生成任务，后台优先级）。提示词在 `luoke_agent/prompts/explain.*`
（顶层 ADR 0019），这里只挑输入、填占位符、核答案：

- 输入：一次最多 `MAX_ITEMS` 项，每项是路径（家目录写成 `~`）、大小、多久没打开或什么时候改的；是文件夹的写上
  里面头几项的名字。只有这些，不读文件内容。两处来：扫描的大文件，核心自己量过的文件夹里最大的几项（`diskuse.py`）。
- 输出：`{"items": [{"n": 第几项, "use": 用途的一句, "verdict": safe / careful / keep}]}`。
- 核对（`parse`）：不合规矩的那一项不要，不改写、不重试；页上那一行就没有这一句。
- 判断是代号，页面上的字（`VERDICT_WORDS`）由 agent 写；模型不能触发任何动作，删不删只在扫描的清单页由用户点。

只用标准库。"""
from __future__ import annotations

import json
import os
from typing import Any, Dict, List, Optional, Sequence

from . import prompt_files

TASK = "explain"
MAX_ITEMS = 6           # 一次问几项
USE_CHARS = 30          # 那一句最长几个字（提示词里写 24，留一点余地）
PATH_CHARS = 200        # 路径截到多长
KEPT = 300              # 记着多少项的说明
VERDICTS = ("safe", "careful", "keep")
VERDICT_WORDS = {"safe": "可清理，需要时可重新获取", "careful": "清理前请确认是否仍需要", "keep": "不建议清理"}
BANNED = ("http://", "https://", "建议", "JSON", "提示词")

PROMPT = prompt_files.load(TASK, ("items",))
SCHEMA = PROMPT["schema"]


def key(path: str, size: Any) -> str:
    """一项的编号：路径加大小（文件换了内容、大小变了就重新问）"""
    return f"{path}|{size if isinstance(size, int) else ''}"


def short(path: str, home: Optional[str] = None) -> str:
    home = home if home is not None else os.path.expanduser("~")
    if home and (path == home or path.startswith(home.rstrip("/") + "/")):
        path = "~" + path[len(home.rstrip("/")):]
    return " ".join(path.split())[:PATH_CHARS]


def size_words(n: Any) -> str:
    if not isinstance(n, (int, float)) or n <= 0:
        return "大小未知"
    for unit, step in (("GB", 1 << 30), ("MB", 1 << 20), ("KB", 1 << 10)):
        if n >= step:
            return f"{n / step:.1f} {unit}"
    return f"{int(n)} B"


def line(i: int, it: dict, home: Optional[str] = None) -> str:
    opened = f"{it['lastOpened']} 后未打开" if it.get("lastOpened") else \
        ("从未打开" + (f"，{it['lastChanged']} 修改" if it.get("lastChanged") else "") if it.get("neverOpened") else "")
    if not opened and it.get("lastChanged"):
        opened = f"{it['lastChanged']} 修改"
    parts = [short(str(it.get("path") or ""), home), size_words(it.get("bytes"))] + ([opened] if opened else [])
    if it.get("dir"):
        names = [" ".join(str(n).split())[:40] for n in (it.get("contains") or [])[:5]]
        parts.append("文件夹" + (f"，里面有：{'、'.join(names)}" if names else ""))
    return f"{i}. " + " · ".join(parts)


def messages(items: Sequence[dict], home: Optional[str] = None) -> List[dict]:
    user = prompt_files.fill(PROMPT["user"], {"items": "\n".join(line(i, it, home) for i, it in enumerate(items, 1))},
                             f"{TASK}.user.txt")
    return [{"role": "system", "content": PROMPT["system"]}, {"role": "user", "content": user}]


def usable(use: Any) -> Optional[str]:
    """那一句能不能用：一行、不太长、没有网址和劝人做事的话"""
    if not isinstance(use, str):
        return None
    text = " ".join(use.split()).rstrip("。.")
    if not text or len(text) > USE_CHARS or any(b in text for b in BANNED) or "/" in text:
        return None
    return text


def parse(raw: str, items: Sequence[dict]) -> Dict[str, dict]:
    """{编号（`key`）: {"use", "verdict"}}；答得不合规矩的项不在里面"""
    try:
        answer = json.loads(raw)
    except ValueError:
        return {}
    rows = answer.get("items") if isinstance(answer, dict) else None
    out: Dict[str, dict] = {}
    for r in rows if isinstance(rows, list) else []:
        if not isinstance(r, dict) or isinstance(r.get("n"), bool) or not isinstance(r.get("n"), int):
            continue
        n, use = r["n"], usable(r.get("use"))
        if not 1 <= n <= len(items) or use is None or r.get("verdict") not in VERDICTS:
            continue
        it = items[n - 1]
        out.setdefault(key(str(it.get("path") or ""), it.get("bytes")), {"use": use, "verdict": r["verdict"]})
    return out


def ask(hub: Any, items: Sequence[dict], home: Optional[str] = None, waiting: bool = False) -> Dict[str, dict]:
    """问一次模型。主控说现在不行（`hub.Later`）、做不了（`hub.HubError`）照原样抛出去。
    `waiting`：用户正看着这几项（点开了那个文件夹），不当后台任务排"""
    if waiting:
        return parse(hub.chat(TASK, messages(items, home), SCHEMA, items=len(items), waiting=True), items)
    return parse(hub.chat(TASK, messages(items, home), SCHEMA, items=len(items)), items)


def words(rec: Any) -> Optional[str]:
    """页上那一行小字：「用途 · 能不能清」"""
    if not isinstance(rec, dict) or not isinstance(rec.get("use"), str) or rec.get("verdict") not in VERDICTS:
        return None
    return f"{rec['use']} · {VERDICT_WORDS[rec['verdict']]}"
