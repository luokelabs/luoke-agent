# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 螺壳实验室 Luoke Labs
"""记忆的页：照它给的原始数据（luoke-mem fixtures/agent/README.md「原始数据」，`data/…`）拼，样子照批过的效果图
（走查重画稿「记忆」四块）。页上的字都在这里写，记忆只给事实和动作（顶层 ADR 0028）。"""
from __future__ import annotations

import re
from typing import Any, Callable, Dict, List, Optional, Tuple
from urllib.parse import urlencode

from .kit import PageKit

APP = "luoke-mem"
# 清单里给界面用的固定名字（提醒的类别 `reports`、权限 `permissions`）：按代号在这里起名（负责人 11-17：用语由 agent 定）；
# 这里没有的代号照清单写的
KIND_NAMES = {"question": "记忆的待确认事项", "suggestion": "记忆的建议"}
PAGE_NEEDS = {
    "overview": ("recent", "asks"),
    "all": ("notes",),
    "people": ("people",),
    "person": ("person",),
    "item": ("note",),
    "settings": ("sources", "data"),
}
NEEDS = PAGE_NEEDS["overview"]
BUILT = set(PAGE_NEEDS)

PAGES = [
    {"id": "overview", "title": "概览"},
    {"id": "all", "title": "全部记忆"},
    {"id": "people", "title": "人物"},
    {"id": "settings", "title": "记忆设置", "hidden": True, "icon": "settings"},
    {"id": "item", "title": "一条记忆", "hidden": True},
    {"id": "person", "title": "人物", "hidden": True},
]

# 界面上的字一律用书面说法，按钮和标签不用口语（负责人 11-16）
KIND = {"fact": "个人信息", "interest": "关注话题", "dislike": "不感兴趣", "preference": "处理习惯", "term": "常用词",
        "taste": "精选偏好"}
# 全部记忆的筛选：有条目的才列（负责人 11-15：少了「说过不对的」「不感兴趣」「常用说法」）
FILTERS = [("all", "全部"), ("fact", "个人信息"), ("interest", "关注话题"), ("preference", "处理习惯"), ("taste", "精选偏好"),
           ("dislike", "不感兴趣"), ("term", "常用词"), ("pending", "待确认"), ("past", "历史"), ("rejected", "已否定")]
# 依据来自哪个应用 → 「来自 …」
FROM = {"luoke-mail": "邮件助手", "luoke-ime": "输入记录", "luoke-mem": "手动", "luoke-search": "搜索记录"}
APP_NAME = {"luoke-mail": "邮件助手", "luoke-ime": "螺壳输入法", "luoke-search": "螺壳搜索", "luoke-scan": "螺壳扫描"}
# 写过的记录话题 → 设置里「学习来源」那一句
LEARNS = {"sent-mail": "邮件处理方式", "mail-contact": "通信对象", "ime-commit": "输入内容", "search-query": "搜索内容"}
# 一条记忆的状态、置信度、怎么来的（负责人 11-15：都不显示）
STATUS = {"active": "有效", "proposed": "待确认", "observed": "观察中", "past": "历史", "rejected": "已否定", "superseded": "已被取代"}
CONFIDENCE = {"guess": "置信度低", "likely": "置信度中", "sure": "置信度高"}
ORIGIN = {"user": "手动添加", "inferred": "推断"}
PEOPLE_ROWS = 20        # 人物一页几个（记忆 data/people 的默认）
ABOUT_ROWS = 15         # 一个人的弹窗先列几条记忆，多的收起来

Read = Callable[[str], Any]


LATER = "later"     # 「以后再说」：交 mem_reply {ask, choice: "later"}，不带 text（记忆 0.41.0：同一个人的问题 answer 只认 是/不是）


def action(name: str, ctx: Dict[str, Any]) -> Tuple[str, Dict[str, Any]]:
    """点按交给记忆前改形状。页上：一排「是 / 不是 / 以后再说」共用一个「回答」按钮，选了「以后再说」交的是 later。
    「今天」的卡片（`card`）：选了第几个，交记忆给的那一种答法（data/ask 的 `replies`，卡片上写死的），原样交"""
    if name == "mem_reply" and isinstance(ctx.get("replies"), dict):
        pick = ctx.get("pick")
        pick = pick[0] if isinstance(pick, list) and pick else pick       # 选的值是数组（A2UI 单选也是数组）
        r = ctx["replies"].get(str(pick))
        if isinstance(r, dict) and isinstance(r.get("choice"), str) and all(isinstance(v, str) for v in r.values()):
            return name, dict(r, ask=ctx.get("ask"))
        return name, {"ask": ctx.get("ask"), "choice": ""}       # 没选：记忆会拒绝，核心照样说没做成
    if name == "mem_reply" and ctx.get("choice") == "answer" and ctx.get("text") == LATER:
        return name, {"ask": ctx.get("ask"), "choice": "later"}
    return name, ctx


# 「今天」的卡片也由核心照原始数据拼（负责人 11-13：不要一排字按钮）：清单列了 data/ask 才拼
CARD_NEEDS = ("ask",)
# 卡片上一排选项：只放这几种答法（「以前是，现在不是」「改成」「归档」在记忆那一页里）
REPLY_WORDS = {"yes": "是", "no": "不是", "later": "稍后", "useful": "同意", "useless": "不需要", "never": "不再询问"}
CITES_SHOWN = 3


def card(key: str, surface_id: str, read: Read) -> Optional[List[dict]]:
    """「今天」上记忆想问的一件（outbox 里的 ask-84）：一句问题、一句为什么、一排选项（选了就交），依据收起来。
    读不到（found 为假、已经答过）就是 None，照旧画记忆自己的卡片"""
    num = "".join(ch for ch in key.rsplit("/", 1)[-1].rsplit("-", 1)[-1] if ch.isdigit())
    if not num:
        return None
    d = read(uri("ask", id=num)) or {}
    if not d.get("found") or d.get("status", "open") != "open":
        return None
    kit = PageKit(surface_id)
    ask = int(num)
    opts, replies = [], {}
    for r in d.get("replies") or []:
        if not isinstance(r, dict):
            continue
        word = r.get("text") if r.get("choice") == "answer" else REPLY_WORDS.get(r.get("choice"))
        if d.get("type") == "unsubscribe" and r.get("choice") == "useful":
            word = "已了解"           # 退订的建议只有「已了解 / 不再询问」（记忆 0.42.0）：照 replies 有几种画几种
        if not word:
            continue
        replies[str(len(opts))] = {k: v for k, v in r.items() if isinstance(v, str)}
        opts.append((str(len(opts)), word))
    text, why = _card_words(d)
    top = [kit.text(text, "strong")]
    if why:
        top.append(kit.text(why, "caption"))
    if opts:
        go = kit.button("回答", "mem_reply", {"ask": ask, "pick": {"path": f"/choices/a{num}"}, "replies": replies})
        top.append(kit.choice(f"a{num}", opts, "", submit=go))
    every = [c for c in d.get("cites") or [] if isinstance(c, dict) and c.get("text")]
    cites = [c for c in every if not c.get("sensitive")]        # 敏感的记录不上卡片
    # 依据几条：有敏感的被拿掉时数留下的；都留下了用记忆数的全部（含 50 条以外的）
    total = len(cites) if len(cites) < len(every) else (d.get("cites_total") or len(cites))
    if cites:
        rows = [kit.text(f"{APP_NAME.get(c.get('tool'), '手动')} · {_date(c.get('happened_at'))}：{c['text']}", "caption")
                for c in cites[:CITES_SHOWN]]
        col = kit.list(rows)
        for comp in kit.components:
            if comp["id"] == col:
                comp["collapsed"] = f"依据 {total} 条"
        top.append(col)
    return kit.messages(top)


# 卡片上问一条猜测：按这条记忆是哪一类写（记忆自己的问法是「你在关注「…」吗？」「「…」，对吗？」）
ASK_NOTE = {"interest": "是否关注「{text}」？", "term": "「{text}」是否为常用说法？", "dislike": "是否对「{text}」不感兴趣？",
            "preference": "「{text}」是否为处理习惯？", "taste": "「{text}」是否符合阅读偏好？"}
ASK_NOTE_WHY = {"guess": "依据近期记录推断，确认后生效", "quiet": "相关记录已较长时间未更新", "reworded": "已有更新的表述"}


def _card_words(d: dict) -> Tuple[str, str]:
    """「今天」卡片上的问题和理由（负责人 11-17：界面上的字由 agent 写）：认得的类型照记忆给的代号和事实写；
    别的应用托记忆问的（`own`）、一般的建议是提问方写的内容，照原样；习惯的询问把旧写法换成书面的"""
    kind = d.get("type")
    if kind == "same_person":
        return _ask_words(d)
    if kind == "note" and isinstance(d.get("note"), dict) and d["note"].get("text"):
        n = d["note"]
        ask = ASK_NOTE.get(n.get("kind"), "「{text}」是否属实？") if d.get("basis") == "guess" else "「{text}」是否仍然成立？"
        return ask.format(text=n["text"]), ASK_NOTE_WHY.get(d.get("basis"), "")
    if kind == "unsubscribe":
        f = d.get("facts") or {}
        if f.get("sender") and isinstance(f.get("times"), int) and f["times"] > 0:
            n = f.get("count")
            return (f"建议退订「{f['sender']}」",
                    f"近期已手动清理其邮件 {f['times']} 次" + (f"，共 {n} 封" if isinstance(n, int) and n > 0 else ""))
    return _formal_habit(d.get("text") or "", d.get("why") or "")


# 习惯的询问：记忆 2026-11-16（luoke-mem 8d8d461）起写成书面说法；那以前问出来、还没答的存在记忆库里，是口语的
# （「以后…都自动归档？」「你 1 次自己把它的邮件归档。说好以后…」）。库不改，画的时候换成新写法
_OLD_HABIT = re.compile(r"^以后(.+?)，都自动(.+?)？$")
_OLD_HABIT_WHY = re.compile(r"^(.*?)。说好以后，邮件助手会自动(.+?)并告诉你，随时能撤回。?$")
_OLD_REASONS = ((re.compile(r"^你 (\d+) 次自己把它的邮件(.+)$"), r"已手动\2 \1 次"),
                (re.compile(r"^邮件助手的建议你 (\d+) 次改成了(.+)$"), r"邮件助手的建议 \1 次被改为\2"),
                (re.compile(r"^你几次都这样处理$"), "多次这样处理"))


def _formal_habit(text: str, why: str) -> Tuple[str, str]:
    m = _OLD_HABIT.match(text)
    if m:
        text = f"{m.group(1)}自动{m.group(2)}"
    m = _OLD_HABIT_WHY.match(why)
    if m:
        reason = m.group(1)
        for pat, to in _OLD_REASONS:
            reason = pat.sub(to, reason)
        why = f"{reason}。同意后邮件助手自动{m.group(2)}并在「今天」中列出，可随时撤销"
    return text, why


# 点完以后窗口提示的那一句由 agent 写（负责人 11-16：界面上的字不用口语；记忆自己答的是「记下了：对。」这样的话）。
# 只换做成了的；没做成的照记忆说的（它说的是哪里不对、要先做什么）
SAID_NOTE = {"confirm": "已确认", "reject": "已标记为错误", "forget": "已删除", "revise": "已保存，原表述标为已被取代",
             "split": "已拆分为单独的一条", "reject_family": "已否定同类记忆"}
SAID_PERSON = {"rename": "已重命名", "merge": "已合并", "split": "已拆分为另一个人物", "reject": "已标记为非人物", "forget": "已删除此人物"}
SAID_REPLY = {"yes": "已确认", "no": "已否定", "past": "已标记为过去的情况", "revise": "已按修改保存", "useless": "近期不再询问",
              "later": "将在数日后再次询问", "never": "不再询问", "archive": "已归档"}
# 「今天」的卡片上点完的那一句也用这里的（负责人 11-17：历史里只有「对」；记忆自己答的是「记下了：对。」）
SAID_ON_CARDS = True


# 没做成时记忆说的几句口语 → 书面的；别的照它说的
SAID_ERRORS = (("先在上面写好名字", "请先填写名称"), ("先在上面写好", "请先填写内容"), ("先选一个人", "请先选择人物"),
               ("和原来的一样", "内容未变化，请修改后重试"), ("改一下再点", "记忆不保存密码、验证码和证件号码，请修改后重试"),
               ("看一眼新的条数再点", "条数已变化，请重新确认"))
CHANGED = "此条已变更，未执行"


# 没做成的原因（记忆 0.44 答复里的 `reason`）→ 页上的字；没有 `reason` 的旧版本照上面认句子
SAID_REASONS = {
    "unknown": "无法识别此操作", "empty_text": "请先填写内容", "same_text": "内容未变化，请修改后重试",
    "secret": "记忆不保存密码、验证码和证件号码，请修改后重试", "unconfirmed": "请先确认", "no_choice": "请先选择人物",
    "wrong_word": "输入不符，未清空", "changed": CHANGED, "family_changed": "条数已变化，请重新确认",
    "no_share": "此应用未写入过记忆", "empty": "没有可处理的内容", "too_new": "记录时间过短，暂不能执行",
    "links": "仍有关联内容，暂不能执行", "locked": "记忆正在被使用，请稍后重试", "broken": "记忆无法打开", "open_failed": "无法打开",
}


def _n(v: Any) -> Optional[int]:
    return v if isinstance(v, int) and not isinstance(v, bool) and v >= 0 else None


def said(name: str, ctx: Dict[str, Any], result: dict) -> Optional[str]:
    """点完以后的那一句：照记忆答复里的代号和数写（0.44 的 `result`、`reason`、`n`……，在 `result["facts"]`）；
    旧一点的记忆没有这些，照点的是什么、它说的那句话认"""
    text = result.get("text") if isinstance(result.get("text"), str) else ""
    f = result.get("facts") if isinstance(result.get("facts"), dict) else {}
    # 问题已经失效（已生效、在别处答过）：记忆答的是「做完了」，其实没做，不能写成「已确认」
    if f.get("stale") is True or f.get("result") == "changed" or (not f and "已经变了" in text):
        return CHANGED
    if result.get("error"):
        if f.get("reason") in SAID_REASONS:
            return SAID_REASONS[f["reason"]]
        return next((new for old, new in SAID_ERRORS if old in text), None)
    if name == "mem_note":
        op = f.get("result") or ctx.get("op")
        if op == "reject_family" and _n(f.get("n")) is not None:
            return f"已否定 {f['n']} 条同类记忆"
        if op == "confirm" and f.get("was") == "past":
            return "已确认仍然成立"
        return SAID_NOTE.get(op)
    if name == "mem_person":
        return SAID_PERSON.get(f.get("result") or ctx.get("op"))
    if name == "mem_reply":
        choice = f.get("result") or ctx.get("choice")
        if choice == "later" and _n(f.get("days")):
            return f"将在 {f['days']} 天后再次询问"
        if f.get("same") is True:
            return "已合并为同一人物"
        return SAID_REPLY.get(choice, "已记录")
    if name == "mem_learn":
        on = f["on"] if isinstance(f.get("on"), bool) else ctx.get("on")
        return "已开始学习" if on else "已停止学习"
    if name == "mem_archive":
        n, of = _n(f.get("n")), _n(f.get("of"))
        if n is not None:
            done = "已放回" if f.get("result") == "back" else "已归档"
            return f"{done} {n} 件" + (f"，{of - n} 件未处理" if of is not None and of > n else "")
        return "已归档"
    if name == "mem_forget_tool":
        r, n = _n(f.get("records")), _n(f.get("notes"))
        return f"已删除 {r} 条记录、{n} 条记忆" if r is not None and n is not None else "已删除"
    return {"mem_forget_all": "已清空"}.get(name)


# 一条记忆为什么这样认为（记忆 0.44 的 `why_data`：代号和数）→ 页上的字。用户自己写的、认不出的没有代号，用记忆的原文
def _why_words(n: dict) -> str:
    w = n.get("why_data")
    if not isinstance(w, dict) or not isinstance(w.get("code"), str):
        return str(n.get("why") or "").strip().rstrip("。")
    c, g = w["code"], (lambda k: _n(w.get(k)))
    if c == "typing_term_pending":
        seen = f"输入记录中 {g('days')} 天出现 {g('times')} 次" if g("days") and g("times") else "输入记录中出现"
        need = f"，达到 {g('need_days')} 天 {g('need_times')} 次后记为常用词" if g("need_days") and g("need_times") else ""
        out = seen + need
    elif c == "typing_term":
        out = f"输入记录中 {g('days')} 天出现 {g('times')} 次" if g("days") and g("times") else "输入记录中多次出现"
    elif c == "typing_interest_pending":
        out = (f"输入记录中 {g('days')} 天提到" if g("days") else "输入记录中提到") + \
              (f"，达到 {g('need_days')} 天后记为关注话题" if g("need_days") else "")
    elif c == "typing_interest":
        out = f"输入记录中 {g('days')} 天提到" if g("days") else "输入记录中多次提到"
    elif c == "sent_mail_person":
        rel = w.get("relation") if isinstance(w.get("relation"), str) and w["relation"].strip() else ""
        out = "已发送邮件中提到此人" + (f"（{rel.strip()[:20]}）" if rel else "")
    elif c == "frequent_contact":
        out = f"近 {g('months')} 个月经常通信" if g("months") else "经常通信"
    elif c in ("habit_overridden", "habit_manual"):
        act = w.get("action").strip()[:20] if isinstance(w.get("action"), str) and w["action"].strip() else "处理"
        t = g("times")
        if c == "habit_overridden":
            out = f"邮件助手的建议{f' {t} 次' if t else '多次'}被改为{act}"
        else:
            out = f"已手动{act}{f' {t} 次' if t else '多次'}"
    else:
        out = {"sent_mail": f"已发送邮件中提到 {g('count')} 次" if g("count") else "已发送邮件中提到",
               "received_mail": "依据收到的邮件", "mail_opened": "多次打开此类邮件", "topics_mail": "依据邮件中的话题",
               "taste_mail": "依据阅读精选的情况", "digest_dislike": "在精选中标记过不感兴趣"}.get(c, "")
        if not out:
            return str(n.get("why") or "").strip().rstrip("。")
    return out + ("，待确认" if w.get("waiting") is True else "")


# 同一类记忆的类名（记忆 0.44 `family.code`）；`other` 和旧版本用它给的 `head`
FAMILY = {"name": "姓名", "signature": "签名", "title": "职位", "employer": "工作单位", "work": "工作", "city": "所在城市",
          "language": "语言", "manager": "上级", "colleague": "同事", "report": "下属", "client": "客户", "partner": "合作方",
          "family": "家人", "friend": "朋友", "account": "账号", "service": "使用的服务", "membership": "会员", "school": "学校",
          "housing": "住房", "travel": "出行", "institution": "机构", "birthday": "生日", "hometown": "家乡"}


# 侧栏上记忆名字下面的那一行，照概览的数据写（记忆 0.44 的 `state`、`recent`、`kept`、`pending`）
def summary(read: Read) -> Optional[str]:
    d = read("summary")
    if not isinstance(d, dict) or not isinstance(d.get("state"), str):
        return None             # 旧一点的记忆没有这些：照它自己的那一句
    state = d["state"]
    if state == "not_ready":
        return "记忆无法打开"
    if state == "empty":
        return "尚无记忆"
    pending = _n(d.get("pending")) or 0
    recent = d.get("recent") if isinstance(d.get("recent"), dict) else {}
    if state == "recent" and isinstance(recent.get("text"), str) and recent["text"].strip():
        return f"最近记录：{recent['text'].strip()[:40]}"
    if pending:
        return f"{pending} 条待确认"
    kept = _n(d.get("kept"))
    return f"已记录 {kept} 条" if kept else "近期无新记录"


def uri(name: str, **params: Optional[str]) -> str:
    q = {k: v for k, v in params.items() if v not in (None, "")}
    return f"data/{name}" + (f"?{urlencode(q)}" if q else "")


def build(page: str, args: Dict[str, str], read: Read) -> List[dict]:
    return {"overview": overview, "all": all_notes, "people": people, "person": person, "item": item,
            "settings": settings}[page](args, read)


# 记忆打不开：每种原因一句，带下一步（负责人 11-15：一律「记忆现在打不开」，不分原因）
NOT_READY = {
    "empty": ("尚无记忆", "各应用使用一段时间后，记忆会逐步形成"),
    "locked": ("记忆正在整理", "请稍后查看"),
    "too_new": ("记忆的版本高于螺壳", "更新螺壳后即可打开"),
    "links": ("记忆的位置包含符号链接，无法打开", "请将记忆文件夹放回原位置后重试"),
    "broken": ("记忆文件已损坏", "可从备份恢复；恢复前不要删除现有文件"),
}


def _not_ready(kit: PageKit, d: Any) -> Optional[List[dict]]:
    if isinstance(d, dict) and d.get("ready") is False:
        title, sub = NOT_READY.get(d.get("problem"), ("记忆暂时无法打开", "请稍后重试"))
        return kit.messages([kit.heading("记忆"), kit.list([kit.item(title, sub, strong=False)])])
    return None


def _date(at: Optional[str]) -> str:
    if not at or len(at) < 10:
        return ""
    return f"{int(at[5:7])}月{int(at[8:10])}日"


def _from(n: dict) -> str:
    srcs = [FROM[s] for s in n.get("sources") or [] if s in FROM]
    return "来自" + "、".join(srcs[:2]) if srcs else ""


def _note_row(kit: PageKit, n: dict, *, with_date: bool) -> str:
    """一条记忆：内容（待确认的带标签），下面「类别 · 来自哪里 / 日期」；右边「确认」（待确认的）、「标记错误」；点一行看依据"""
    btns = []
    if n.get("pending"):
        btns.append(kit.button("确认", "mem_note", {"note": n["id"], "op": "confirm"}, icon="check", variant="borderless"))
    if n.get("status") != "rejected":
        btns.append(kit.button("标记错误", "mem_note", {"note": n["id"], "op": "reject"}, icon="x", variant="borderless"))
    opened = kit.open_page("查看依据", "item", {"id": str(n["id"])})
    sub = " · ".join(x for x in (KIND.get(n.get("kind"), ""), _date(n.get("formed_at")) if with_date else _from(n)) if x)
    title = n.get("text") or ""
    left = [kit.text(title, "strong")]
    if n.get("pending"):
        left = [kit.row([kit.text(title, "strong"), kit.text("待确认", "badge")])]
    elif n.get("status") == "rejected":
        left = [kit.row([kit.text(title, "strong"), kit.text("已否定", "badge")])]
    if sub:
        left.append(kit.text(sub, "caption"))
    return kit.row([kit.column(left), kit.row(btns + [opened])], justify="spaceBetween", open=opened)


def _try(read: Read, u: str) -> dict:
    """多读的一样（单件问题的答法、合并时可选的人物）：读不到不让整页画不出来，当成没有"""
    try:
        d = read(u)
    except Exception:
        return {}
    return d if isinstance(d, dict) else {}


def _ask_options(d: dict) -> Tuple[List[Tuple[str, str]], Dict[str, dict]]:
    """一件要确认的事能怎么答（data/ask 的 `replies`）：只放点一下就能答的几种，要写字的（改成）、归档不在这里"""
    opts: List[Tuple[str, str]] = []
    replies: Dict[str, dict] = {}
    for r in d.get("replies") or []:
        if not isinstance(r, dict):
            continue
        word = r.get("text") if r.get("choice") == "answer" else REPLY_WORDS.get(r.get("choice"))
        if d.get("type") == "unsubscribe" and r.get("choice") == "useful":
            word = "已了解"
        if not word:
            continue
        replies[str(len(opts))] = {k: v for k, v in r.items() if isinstance(v, str)}
        opts.append((str(len(opts)), word))
    return opts, replies


def overview(args: Dict[str, str], read: Read) -> List[dict]:
    """概览：最近记下的几件事（不对就标记错误）；待确认的（一天最多三件）：照每件能怎么答给选项，默认都不选，
    选了再点「确定」才办（负责人 11-15：三种问题一律「是 / 不是 / 以后再说」，默认选中「是」、选了就办）"""
    kit = PageKit("overview")
    recent = read(uri("recent")) or {}
    bad = _not_ready(kit, recent)
    if bad:
        return bad
    asks = read(uri("asks")) or {}
    top: List[str] = []
    items = (recent.get("items") or [])[:5]
    if items:
        top.append(kit.heading("最近记录"))
        top.append(kit.list([_note_row(kit, n, with_date=False) for n in items]))
    # 「这些记忆帮上了忙」：各应用还报不上数（data/helped 的 recorded 是 false），报得上来以前不画
    qs = [a for a in asks.get("items") or [] if a.get("type") in ("same_person", "own", "note")][:3]
    if qs:
        top.append(kit.heading(f"待确认 · {len(qs)}"))
        rows = []
        for a in qs:
            key = f"ask{a['id']}"
            title, sub = _ask_words(a)
            parts = [kit.text(title, "strong")]
            if sub:
                parts.append(kit.text(sub, "caption"))
            # 能怎么答照记忆给的（data/ask 的 replies）；读不到时只给「稍后」
            opts, replies = _ask_options(_try(read, uri("ask", id=str(a["id"]))))
            if not opts:
                opts, replies = [("0", REPLY_WORDS["later"])], {"0": {"choice": "later"}}
            go = kit.button("确定", "mem_reply", {"ask": a["id"], "pick": {"path": f"/choices/{key}"}, "replies": replies},
                            variant="primary")
            parts.append(kit.row([kit.choice(key, opts, ""), go]))
            rows.append(kit.column(parts))
        top.append(kit.list(rows))
    if not top:
        top += [kit.heading("最近记录"), kit.list([kit.item("近期没有新记忆", None, strong=False)])]
    return kit.messages(top)


def _ask_words(a: dict) -> tuple:
    if a.get("type") == "same_person":
        p = a.get("people") or [{}, {}]
        names = [x.get("name") or "" for x in p[:2]]
        why = {"name_inside": "一个称呼包含另一个", "same_local": "两个邮箱地址的用户名相同"}.get(a.get("basis"), "")
        rel = "；".join(f"「{x.get('name')}」：{'、'.join(x.get('relations') or [])}" for x in p[:2] if x.get("relations"))
        return f"「{names[0]}」和「{names[1]}」是同一个人吗？", "；".join(x for x in (why, rel) if x)
    if a.get("type") == "note":
        return f"「{(a.get('note') or {}).get('text', '')}」是否仍然成立？", ""
    return a.get("text") or "", ""


def _pager(kit: PageKit, page_id: str, d: dict, base: Dict[str, str]) -> Optional[str]:
    """「第 2 / 5 页」和上一页、下一页；只有一页时没有"""
    page, pages = int(d.get("page") or 1), int(d.get("pages") or 1)
    if pages <= 1:
        return None
    btns = []
    if page > 1:
        btns.append(kit.open_page("上一页", page_id, {**base, "p": str(page - 1)}, variant="borderless"))
    if page < pages:
        btns.append(kit.open_page("下一页", page_id, {**base, "p": str(page + 1)}, variant="borderless"))
    return kit.row([kit.text(f"第 {page} / {pages} 页", "caption")] + btns, justify="spaceBetween")


def _search_row(kit: PageKit, page_id: str, label: str, q: str, extra: Dict[str, Any]) -> str:
    """页内的搜索框和「搜索」按钮（负责人 11-15：页内搜索没人能触发）"""
    kit.data.setdefault("fields", {})["q"] = q
    go = kit.open_page("搜索", page_id, {"q": {"path": "/fields/q"}, **extra})
    field = kit.add({"id": kit._id("f"), "component": "TextField", "label": label, "value": {"path": "/fields/q"}})
    return kit.row([field, go])


def all_notes(args: Dict[str, str], read: Read) -> List[dict]:
    """全部记忆：一行筛选、一个搜索框、一个列表；还没确认的带「待确认」；每行右边确认、标记错误，点一行看依据"""
    flt = args.get("filter") or args.get("kind") or args.get("view") or "all"
    q = args.get("q") or ""
    p = args.get("p") or "1"
    d = read(uri("notes", filter=None if flt == "all" else flt, q=q, p=None if p == "1" else p)) or {}
    kit = PageKit("all")
    bad = _not_ready(kit, d)
    if bad:
        return bad
    counts = d.get("counts") or {}
    opts = [(v, t) for v, t in FILTERS if v == "all" or counts.get(v) or v == flt]
    go = kit.open_page("筛选", "all", {"filter": {"path": "/choices/filter/0"}, **({"q": q} if q else {})})
    top = [kit.choice("filter", opts, flt if any(o[0] == flt for o in opts) else "all", submit=go),
           _search_row(kit, "all", "搜索记忆", q, {} if flt == "all" else {"filter": flt})]
    items = d.get("items") or []
    rows = [_note_row(kit, n, with_date=True) for n in items]
    if rows:
        top.append(kit.list(rows))
    else:
        top.append(kit.list([kit.item("未找到匹配的记忆" if q else "此类别暂无记忆", None, strong=False)]))
    pager = _pager(kit, "all", d, {**({"q": q} if q else {}), **({} if flt == "all" else {"filter": flt})})
    if pager:
        top.append(pager)
    return kit.messages(top)


def _person_line(p: dict) -> str:
    rel = "、".join(r["relation"] for r in p.get("relations") or [] if r.get("relation"))
    if p.get("top"):
        rel = "，".join(x for x in (rel, p["top"].get("text")) if x)
    c = p.get("contact") or {}
    if not rel and c.get("together"):
        rel = "常谈话题：" + "、".join(c["together"][:2])
    if not rel and c.get("count"):
        rel = f"往来邮件 {c['count']} 封"
    return rel


def people(args: Dict[str, str], read: Read) -> List[dict]:
    """人物：每人一行（名字和一句话），点一行看详细；能按名字搜、翻页（负责人 11-15：只看得到前 20 个）"""
    q = args.get("q") or ""
    p = args.get("p") or "1"
    d = read(uri("people", q=q, p=None if p == "1" else p)) or {}
    kit = PageKit("people")
    bad = _not_ready(kit, d)
    if bad:
        return bad
    top = [_search_row(kit, "people", "按称呼或地址搜索", q, {})]
    rows = []
    for one in d.get("items") or []:
        opened = kit.open_page("详情", "person", {"id": str(one["id"])})
        rows.append(kit.item(one.get("name") or "", _person_line(one) or None, open=opened))
    top.append(kit.list(rows) if rows else kit.list([kit.item("未找到匹配的人物" if q else "暂无人物", None, strong=False)]))
    pager = _pager(kit, "people", d, {"q": q} if q else {})
    if pager:
        top.append(pager)
    return kit.messages(top)


def person(args: Dict[str, str], read: Read) -> List[dict]:
    """一个人（弹窗）：名字（能改）、每个称呼和地址（认错的能拆出去）、关于他的记忆（先列有效的，已否定的收起来）、
    和别人合并、不是人物、删除。负责人 11-15：以前只剩「忘掉这个人」，认错人只能整个删掉"""
    pid = args.get("id") or ""
    kit = PageKit("person")
    if not pid:         # 没说是哪个人：不去读
        return kit.messages([kit.text("此人物已不在记忆中", "caption")])
    d = read(uri("person", id=pid)) or {}
    bad = _not_ready(kit, d)
    if bad:
        return bad
    if d.get("found") is False:
        return kit.messages([kit.text("此人物已不在记忆中", "caption")])
    me = d.get("id", pid)
    name = d.get("name") or ""
    top = [kit.text(name, "h4")]
    line = _person_line(d)
    if line:
        top.append(kit.text(line))
    kit.data.setdefault("fields", {})["rename"] = name
    rename = kit.button("重命名", "mem_person", {"op": "rename", "person": me, "name": {"path": "/fields/rename"}})
    top.append(kit.fold("重命名", [kit.row([kit.add({"id": kit._id("f"), "component": "TextField", "label": "名称",
                                                      "value": {"path": "/fields/rename"}}), rename])]))
    aliases = [a.get("name") or a.get("address") for a in d.get("aliases") or [] if a.get("name") or a.get("address")]
    if aliases:
        top.append(kit.heading("称呼和地址"))
        rows = []
        for alias in aliases:
            btns = []
            if len(aliases) > 1:      # 最后一个称呼拆不出去
                btns.append(kit.button("不是此人", "mem_person", {"op": "split", "person": me, "alias": alias, "sure": True},
                                       variant="borderless",
                                       confirm={"title": f"将「{alias}」拆分为另一个人？",
                                                "text": f"「{alias}」将不再属于「{name}」，成为单独的人物。", "label": "拆分"}))
            rows.append(kit.item(alias, None, btns, strong=False))
        top.append(kit.list(rows))
    about = d.get("about") or []
    live = [n for n in about if n.get("status") != "rejected"]
    gone = [n for n in about if n.get("status") == "rejected"]
    if live:
        top.append(kit.heading(f"相关记忆 · {len(live)}"))
        top.append(kit.list([_note_row(kit, n, with_date=True) for n in live[:ABOUT_ROWS]]))
        if len(live) > ABOUT_ROWS:
            top.append(kit.fold(f"其余 {len(live) - ABOUT_ROWS} 条", [kit.list([_note_row(kit, n, with_date=True)
                                                                                 for n in live[ABOUT_ROWS:ABOUT_ROWS * 3]])]))
    if gone:
        top.append(kit.fold(f"已否定 {len(gone)} 条", [kit.list([_note_row(kit, n, with_date=True) for n in gone[:ABOUT_ROWS]])]))
    # 和别人合并：从人物里选一个（先列写得最多的 20 个）
    others = [(str(o["id"]), o.get("name") or "") for o in (_try(read, uri("people")).get("items") or [])
              if o.get("id") != me and o.get("name")][:PEOPLE_ROWS]
    top.append(kit.heading("管理"))
    manage = []
    if others:
        merge = kit.button("合并", "mem_person", {"op": "merge", "person": me, "other": {"path": "/choices/merge_other"}},
                           confirm={"title": "合并人物？", "text": f"所选人物的称呼、地址和记忆将并入「{name}」。合并后可在「称呼和地址」中拆分。",
                                    "label": "合并"})
        manage.append(kit.row([kit.choice("merge_other", others, "", label="合并人物"), merge], justify="spaceBetween"))
    manage.append(kit.item("不是人物", "标记后不再作为人物记录", [
        kit.button("标记", "mem_person", {"op": "reject", "person": me},
                   confirm={"title": f"「{name}」不是人物？", "text": "标记后不再作为人物记录。", "label": "标记"})], strong=False))
    manage.append(kit.item("删除此人物", "相关记忆和依据一并删除，无法恢复", [
        kit.button("删除", "mem_person", {"op": "forget", "person": me, "sure": True}, icon="trash-2", variant="borderless",
                   confirm={"title": f"删除「{name}」？", "text": "相关记忆和依据将一并删除，无法恢复。", "label": "删除"})], strong=False))
    top.append(kit.list(manage))
    return kit.messages(top)


def item(args: Dict[str, str], read: Read) -> List[dict]:
    """一条记忆（弹窗）：内容；状态、置信度、怎么来的；为什么这么想；依据（每条写来源）；确认、标记错误、编辑、删除；
    并进来的表述能拆出去。负责人 11-15：以前只剩「不对」「忘掉」，改写（纠错的主路）没了，状态和来源都不显示"""
    nid = args.get("id") or ""
    kit = PageKit("item")
    if not nid:         # 没说是哪一条：不去读
        return kit.messages([kit.text("此记忆已不存在", "caption")])
    d = read(uri("note", id=nid)) or {}
    bad = _not_ready(kit, d)
    if bad:
        return bad
    n = d.get("note") or {}
    if not n:
        return kit.messages([kit.text("此记忆已不存在", "caption")])
    text = n.get("text") or ""
    state = "待确认" if n.get("pending") else STATUS.get(n.get("status"), "")
    top = [kit.text(text, "h4"),
           kit.text(" · ".join(x for x in (KIND.get(n.get("kind"), ""), state, CONFIDENCE.get(n.get("confidence"), ""),
                                           ORIGIN.get(n.get("origin"), ""), _date(n.get("formed_at"))) if x), "caption")]
    why = _why_words(n)
    if why:
        top.append(kit.text(why))
    if n.get("superseded_by"):
        go = kit.open_page("查看新版本", "item", {"id": str(n["superseded_by"])})
        top.append(kit.link("已被新版本取代", go))
    live = n.get("status") not in ("rejected", "superseded")
    btns = []
    if n.get("pending"):
        btns.append(kit.button("确认", "mem_note", {"note": n["id"], "op": "confirm"}, icon="check"))
    if live:
        btns.append(kit.button("标记错误", "mem_note", {"note": n["id"], "op": "reject"}, icon="x"))
    if n.get("status") != "superseded":
        btns.append(kit.button("删除", "mem_note", {"note": n["id"], "op": "forget", "sure": True}, icon="trash-2",
                               confirm={"title": "删除这条记忆？", "text": f"「{text}」及其依据将一并删除，无法恢复。", "label": "删除"}))
    if btns:
        top.append(kit.row(btns))
    if live:
        kit.data.setdefault("fields", {})["revise"] = text
        save = kit.button("保存", "mem_note", {"note": n["id"], "op": "revise", "text": {"path": "/fields/revise"}})
        top.append(kit.fold("编辑", [kit.row([kit.add({"id": kit._id("f"), "component": "TextField", "label": "内容",
                                                        "value": {"path": "/fields/revise"}}), save]),
                                     kit.text("保存后原表述保留，标为已被取代", "caption")]))
    cites = d.get("cites") or []
    if cites:
        top.append(kit.heading(f"依据 · {len(cites)}"))
        top.append(kit.list([kit.item(c.get("text") or "", " · ".join(
            x for x in ("来源：" + FROM[c["tool"]] if c.get("tool") in FROM else "", _date(c.get("happened_at")),
                        "敏感" if c.get("sensitive") else "") if x) or None, strong=False) for c in cites[:20]]))
    fam = d.get("family") if isinstance(d.get("family"), dict) else None
    ids = [i for i in (fam or {}).get("notes") or [] if isinstance(i, int) and not isinstance(i, bool)]
    if live and len(ids) > 1:       # 同一类里还没表态的那几条（记忆 data/note 的 family）：一次都否定
        head = FAMILY.get(fam.get("code")) or fam.get("head") or "其他"
        top.append(kit.heading("同类记忆"))
        top.append(kit.list([kit.item(f"「{head}」类共 {len(ids)} 条未确认", "否定后此类记忆将减少提示", [
            kit.button("否定同类记忆", "mem_note", {"note": n["id"], "op": "reject_family", "family": ids}, variant="borderless",
                       confirm={"title": f"否定「{head}」类的 {len(ids)} 条记忆？", "text": "这些记忆将标为已否定，此类记忆今后减少提示。",
                                "label": "否定"})], strong=False)]))
    merged = [m for m in d.get("merged") or [] if isinstance(m, dict) and m.get("id") is not None and m.get("text")]
    if merged:
        top.append(kit.heading(f"已合并的表述 · {len(merged)}"))
        top.append(kit.list([kit.item(m["text"], None, [
            kit.button("拆分", "mem_note", {"note": m["id"], "op": "split"}, variant="borderless",
                       tooltip="拆分为单独的一条，状态为待确认")], strong=False) for m in merged[:10]]))
    return kit.messages(top)


def settings(args: Dict[str, str], read: Read) -> List[dict]:
    """记忆设置（弹窗）：来源（每个应用一个开关，一句话说从哪里学）、数据（整理的时间、各来源写的、清空整份记忆）"""
    tab = args.get("tab") if args.get("tab") in ("sources", "data") else "sources"
    kit = PageKit("settings")
    go = kit.open_page("切换分页", "settings", {"tab": {"path": "/choices/tab/0"}})
    top = [kit.choice("tab", [("sources", "来源"), ("data", "数据")], tab, submit=go)]
    src = read(uri("sources")) or {}
    bad = _not_ready(kit, src)
    if bad:
        return bad
    items = src.get("items") or []
    if tab == "sources":
        rows = []
        for s in items:
            name = APP_NAME.get(s.get("tool"), s.get("tool") or "")
            learns = [LEARNS[t["topic"]] for t in s.get("topics") or [] if t.get("topic") in LEARNS]
            sub = "学习来源：" + "、".join(learns[:2]) if learns else None
            if s.get("tool") == "luoke-ime":
                sub = (sub or "学习来源：输入内容") + "；常用词自动记录，无需确认"
            on = bool(s.get("on"))
            sw = kit.button(f"从{name}学习", "mem_learn", {"tool": s.get("tool"), "on": not on}, variant="switch", on=on)
            rows.append(kit.item(name, sub if on else "已停止学习，已有记忆保留", [sw]))
        top.append(kit.list(rows) if rows else kit.text("暂无应用写入记忆", "caption"))
        return kit.messages(top)
    d = read(uri("data")) or {}
    tidied = (d.get("tidied") or {}).get("at")
    rows = [kit.item("整理", (f"上次整理：{_date(tidied)}；" if tidied else "尚未整理；") + "下次在电脑空闲时进行"),
            kit.item(f"记忆 {d.get('kept', 0)} 条"),
            kit.item(f"输入法词条 {d.get('terms', 0)} 条", "常用词，仅供输入法使用")]
    top.append(kit.list(rows))
    if items:
        top.append(kit.heading("各应用写入的记录"))
        frows = []
        for s in items:
            name = APP_NAME.get(s.get("tool"), s.get("tool") or "")
            # 会删多少先试算（记忆 data/forget，试一遍再撤回）：确认框写准确的数和留下的（负责人 11-15：数和范围不准）
            trial = _try(read, uri("forget", tool=s.get("tool")))
            if trial.get("known"):
                words = f"将删除 {trial.get('records', 0)} 条记录和 {trial.get('notes', 0)} 条记忆，无法恢复。"
                if trial.get("kept"):
                    words += f"另有 {trial['kept']} 条记忆保留：已确认、已否定、已修改，或有其他来源的依据。"
            else:
                words = (f"将删除{name}写入的 {s.get('records', 0)} 条记录，以及仅依据这些记录形成的记忆（至多 {s.get('notes', 0)} 条），无法恢复。"
                         "有其他来源依据的记忆会保留。")
            drop = kit.button(f"删除{name}写入的记录", "mem_forget_tool", {"tool": s.get("tool"), "sure": True}, icon="trash-2",
                              variant="borderless", confirm={"title": f"删除{name}写入的记录？", "text": words, "label": "删除"})
            frows.append(kit.item(name, f"记录 {s.get('records', 0)} 条 · 记忆 {s.get('notes', 0)} 条", [drop]))
        top.append(kit.list(frows))
    top.append(kit.row([kit.button("清空整份记忆", "mem_forget_all", {"confirm": "清空"},
                                   confirm={"title": "清空整份记忆？", "text": f"将删除全部 {d.get('kept', 0)} 条记忆和各应用写入的记录，无法恢复。",
                                            "label": "清空"})]))
    return kit.messages(top)
