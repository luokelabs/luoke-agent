"""吉祥物在「今天」说的那一句（界面规范 §14「它的一句话」：说现在最值得说的一件事）：从今天的事里挑一件说，
带一点性格（定稿原型的例子：「上午归档了 14 封促销邮件，没有一封是人写的。」）。负责人 2026-11-18：说的是页上已有的事，
用它打趣，不是把下面的字照搬上来，也不是从记忆里另找话题（那是 §15 桌面小精灵的「逗一下」）。

模型任务 `luoke-agent.hello`（主控配方里的生成任务，后台优先级，一天至多做成一次）。提示词在
`luoke_agent/prompts/hello.*`（顶层 ADR 0019），这里只挑输入、填占位符、核答案：

- 输入：今天的事（`Agent.today_matters`：已自动处理的、待确认的，急事窗口自己说），最多 `MAX_NOTES` 条，每条截到
  `NOTE_CHARS` 个字；最近 `RECENT_DAYS` 天说过的那几条标出来，不再说。
- 输出：`{"about": 第几条, "text": 那一句}`；`about` 是 0 就是今天不说。
- 核对（`parse`）：不合规矩的一律当不说，不改写、不重试：宁缺毋滥。

拼一行输入用的编号和类别名（「1. [已自动处理] …」）和取字段分不开，留在代码里。只用标准库。"""
from __future__ import annotations

import json
import re
from typing import Any, Dict, List, Optional, Sequence, Tuple

from . import prompt_files

TASK = "hello"
MAX_NOTES = 8           # 一次给模型看几条
NOTE_CHARS = 60         # 一条截到多长
MAX_TEXT = 40           # 那一句最长几个字（提示词里写的也是它；`Agent.set_hello` 另有 80 的上限）
MIN_TEXT = 6
RECENT_DAYS = 7         # 说过的一条几天内不再说
KINDS = ("done", "waiting")        # 今天替用户做完的、等用户定的
KIND_NAMES = {"done": "已自动处理", "waiting": "待确认"}
WEEKDAYS = "一二三四五六日"
# 那一句里不该有的（那一条理解里本来就有的除外）：照着「不提 AI」「不说根据记忆」和「不照抄写给 AI 的话」核
BANNED = ("AI", "人工智能", "模型", "根据记忆", "根据记录", "我注意到", "我发现", "提示词", "JSON", "http://", "https://")
DIGITS = re.compile(r"\d+")

PROMPT = prompt_files.load(TASK, ("today", "notes", "recent"))
SCHEMA = PROMPT["schema"]


def usable(notes: Sequence[dict]) -> List[dict]:
    """能拿来说的事：类别对、有字（带了 `sensitive`、`status` 的照它们筛）。照给的顺序"""
    out = []
    for n in notes:
        text = " ".join(str(n.get("text") or "").split())
        if n.get("kind") not in KINDS or n.get("sensitive") or not text or n.get("status", "active") != "active":
            continue
        out.append({"id": n.get("id"), "kind": n["kind"], "text": text[:NOTE_CHARS]})
    return out


def pick(notes: Sequence[dict], recent: Sequence[dict], day: str) -> List[dict]:
    """这次给模型看哪几条：最近说过的排在后面，别的按日期轮着来（同一天挑的一样，换一天从另一处开始），
    最多 `MAX_NOTES` 条。说过的也留几条在列表里，标成「不再说」，模型才知道避开同一件事"""
    said = {r.get("note") for r in recent}
    fresh = [n for n in notes if n["id"] not in said]
    used = [n for n in notes if n["id"] in said]
    if fresh:
        start = sum(day.encode()) % len(fresh)
        fresh = fresh[start:] + fresh[:start]
    return (fresh + used)[:MAX_NOTES]


def today_words(day: str, weekday: int) -> str:
    """「11月16日 星期一」；`day` 带着哪一段（「2026-11-16 晚上」）时是「11月16日 星期一 晚上」"""
    part = day[10:].strip()
    return f"{int(day[5:7])}月{int(day[8:10])}日 星期{WEEKDAYS[weekday % 7]}" + (f" {part}" if part else "")


def messages(listed: Sequence[dict], recent: Sequence[dict], today: str) -> List[dict]:
    """发给主控的消息。`listed` 是 `pick` 挑好的；`recent` 是最近说过的（{"note", "text"}）"""
    lines = [f"{i}. [{KIND_NAMES[n['kind']]}] {n['text']}" for i, n in enumerate(listed, 1)]
    index = {n["id"]: i for i, n in enumerate(listed, 1)}
    again = [f"第 {index[r['note']]} 条：{' '.join(str(r.get('text') or '').split())[:MAX_TEXT]}"
             for r in recent if r.get("note") in index]
    user = prompt_files.fill(PROMPT["user"], {"today": today, "notes": "\n".join(lines), "recent": "\n".join(again)},
                             f"{TASK}.user.txt")
    return [{"role": "system", "content": PROMPT["system"]}, {"role": "user", "content": user}]


def problems(answer: Any, listed: Sequence[dict], recent: Sequence[dict]) -> List[str]:
    """模型的答案哪里不合规矩（评测的硬性条目和 `parse` 用同一套）。空的列表：能用，或者是规规矩矩的不说"""
    if not isinstance(answer, dict) or isinstance(answer.get("about"), bool) or not isinstance(answer.get("about"), int) \
            or not isinstance(answer.get("text"), str):
        return ["form"]
    about, text = answer["about"], answer["text"]
    if about == 0:
        return ["silent-with-text"] if text.strip() else []
    out = []
    if not 1 <= about <= len(listed):
        return ["about-out-of-range"]
    note = listed[about - 1]
    if note["id"] in {r.get("note") for r in recent}:
        out.append("repeats-recent")
    if "\n" in text.strip() or "\r" in text:
        out.append("more-than-one-line")
    plain = " ".join(text.split())
    if not MIN_TEXT <= len(plain) <= MAX_TEXT:
        out.append("length")
    if any(b.lower() in plain.lower() and b.lower() not in note["text"].lower() for b in BANNED):
        out.append("banned-word")
    if any(d not in note["text"] for d in DIGITS.findall(plain)):
        out.append("made-up-number")        # 那一条里没有的数：编的
    return out


def parse(raw: str, listed: Sequence[dict], recent: Sequence[dict]) -> Tuple[Optional[Any], str]:
    """（说的是哪条理解的 id，那一句）；不说、答得不合规矩都是 (None, "")"""
    try:
        answer = json.loads(raw)
    except ValueError:
        return None, ""
    if problems(answer, listed, recent) or answer["about"] == 0:
        return None, ""
    return listed[answer["about"] - 1]["id"], " ".join(answer["text"].split())


def prepare(notes: Sequence[dict], recent: Sequence[dict], day: str) -> List[dict]:
    """这次给模型看的几条；空的列表：没有能说的（今天还没有事、最近都说过了），不用问模型"""
    listed = pick(usable(notes), recent, day)
    if all(n["id"] in {r.get("note") for r in recent} for n in listed):
        return []
    return listed


def ask(hub: Any, listed: Sequence[dict], recent: Sequence[dict], day: str, weekday: int) -> Tuple[Optional[Any], str]:
    """问一次模型：（说的是哪条理解的 id，那一句），不说是 (None, "")。
    主控说现在不行（`hub.Later`）、做不了（`hub.HubError`）照原样抛出去，调用的定什么时候再来"""
    return parse(hub.chat(TASK, messages(listed, recent, today_words(day, weekday)), SCHEMA), listed, recent)


def compose(hub: Any, notes: Sequence[dict], recent: Sequence[dict], day: str, weekday: int) -> Dict[str, Any]:
    """做一次：{"asked": 问没问模型, "note": 说的是哪条, "text": 那一句}。没有能说的事不问模型"""
    listed = prepare(notes, recent, day)
    if not listed:
        return {"asked": False, "note": None, "text": ""}
    note, text = ask(hub, listed, recent, day, weekday)
    return {"asked": True, "note": note, "text": text}
