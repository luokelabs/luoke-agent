"""简报那一段话（「今天」吉祥物的气泡里；负责人 2026-11-18：简报是小精灵说的话，那一段也让模型写）。

模型任务 `luoke-agent.brief`（主控配方里的生成任务）。简报的通知发出去以后按后台任务问：那一刻没有人在屏幕前等
这段话（luoke-core 11-18：`user-waiting` 会打断后台任务、现加载底座，只在此刻真有人等时用）。还没问成用户就打开了
「今天」，这时人在等，补问一次「用户在等」；等的时候气泡里是模板拼的那一段，不空着。提示词在 `luoke_agent/prompts/brief.*`（顶层 ADR 0019），这里只挑输入、填占位符、核答案：

- 输入：今天的事（`Agent.today_matters(urgent=True)`：急事、已自动处理的、待确认的各一行），最多 `MAX_MATTERS` 条，
  每条截到 `MATTER_CHARS` 个字；再一行各有几件。
- 输出：`{"text": 那一段话}`。
- 核对（`parse`）：不合规矩的一律不要，不改写、不重试；没有这一段时窗口照模板拼（以前的写法）。

通知的正文不经模型，照旧是模板（`Agent._brief_body`）：通知要准点发，不等模型。只用标准库。"""
from __future__ import annotations

import json
import re
from typing import Any, Dict, List, Sequence

from . import prompt_files

TASK = "brief"
MAX_MATTERS = 12        # 一次给模型看几条（急事在前，再做完的、等着的）
MATTER_CHARS = 60
MAX_TEXT = 80           # 那一段最长几个字（提示词里写的也是它）
MIN_TEXT = 8
KINDS = ("urgent", "done", "waiting")
KIND_NAMES = {"urgent": "急事", "done": "已自动处理", "waiting": "待确认"}
BANNED = ("AI", "人工智能", "模型", "根据记忆", "根据记录", "我注意到", "我发现", "提示词", "JSON", "http://", "https://")
DIGITS = re.compile(r"\d+(?:\.\d+)?")

PROMPT = prompt_files.load(TASK, ("today", "matters", "counts"))
SCHEMA = PROMPT["schema"]


def usable(matters: Sequence[dict]) -> List[dict]:
    """给模型看的几条：类别对、有字；急事在前，再做完的、等着的；一共最多 `MAX_MATTERS` 条"""
    out = []
    for kind in KINDS:
        for m in matters:
            text = " ".join(str(m.get("text") or "").split())
            if m.get("kind") == kind and text:
                out.append({"id": m.get("id"), "kind": kind, "text": text[:MATTER_CHARS]})
    return out[:MAX_MATTERS]


def counts(matters: Sequence[dict]) -> Dict[str, int]:
    """各有几件（照全部的数，不是给模型看的那几条）"""
    return {k: sum(1 for m in matters if m.get("kind") == k and str(m.get("text") or "").strip()) for k in KINDS}


def counts_line(n: Dict[str, int]) -> str:
    return "一共：" + "，".join(f"{KIND_NAMES[k]} {n[k]} 件" for k in KINDS if n[k])


def messages(matters: Sequence[dict], today: str) -> List[dict]:
    listed = usable(matters)
    lines = [f"{i}. [{KIND_NAMES[m['kind']]}] {m['text']}" for i, m in enumerate(listed, 1)]
    user = prompt_files.fill(PROMPT["user"], {"today": today, "matters": "\n".join(lines), "counts": counts_line(counts(matters))},
                             f"{TASK}.user.txt")
    return [{"role": "system", "content": PROMPT["system"]}, {"role": "user", "content": user}]


def problems(answer: Any, matters: Sequence[dict]) -> List[str]:
    """模型的答案哪里不合规矩（评测的硬性条目和 `parse` 用同一套）"""
    if not isinstance(answer, dict) or not isinstance(answer.get("text"), str):
        return ["form"]
    text = answer["text"]
    out = []
    if "\n" in text.strip() or "\r" in text:
        out.append("more-than-one-line")
    plain = " ".join(text.split())
    if not MIN_TEXT <= len(plain) <= MAX_TEXT:
        out.append("length")
    given = " ".join(m["text"] for m in usable(matters))
    if any(b.lower() in plain.lower() and b.lower() not in given.lower() for b in BANNED):
        out.append("banned-word")
    known = set(DIGITS.findall(given)) | {str(v) for v in counts(matters).values()}
    if any(d not in known for d in DIGITS.findall(plain)):
        out.append("made-up-number")        # 列表和件数里都没有的数：编的
    return out


def parse(raw: str, matters: Sequence[dict]) -> str:
    """那一段话；答得不合规矩是空的"""
    try:
        answer = json.loads(raw)
    except ValueError:
        return ""
    return "" if problems(answer, matters) else " ".join(answer["text"].split())


def ask(hub: Any, matters: Sequence[dict], today: str, waiting: bool = False) -> str:
    """问一次模型。主控说现在不行（`hub.Later`）、做不了（`hub.HubError`）照原样抛出去。
    `waiting`：用户正看着「今天」等这一段，不当后台任务排"""
    if waiting:
        return parse(hub.chat(TASK, messages(matters, today), SCHEMA, waiting=True), matters)
    return parse(hub.chat(TASK, messages(matters, today), SCHEMA), matters)
