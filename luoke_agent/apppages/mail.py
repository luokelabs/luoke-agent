# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 螺壳实验室 Luoke Labs
"""邮件助手的页：照它给的原始数据（luoke-mail docs/agent-data.md，`data/…`）拼，样子照批过的效果图
（走查重画稿「邮件助手」五块）。页上的字都在这里写，邮件助手只给事实和动作（顶层 ADR 0028）。"""
from __future__ import annotations

import re
from typing import Any, Callable, Dict, List, Optional, Tuple
from urllib.parse import urlencode

from .. import a2ui
from . import clock
from .kit import PageKit

APP = "luoke-mail"
# 清单里给界面用的固定名字（提醒的类别 `reports`、权限 `permissions`）：按代号在这里起名（负责人 11-17：用语由 agent 定）；
# 这里没有的代号照清单写的
KIND_NAMES = {"new-mail": "待处理邮件", "suspicious": "可疑邮件", "mailbox": "不紧急的邮件", "auto-done": "自动处理的邮件",
              "needs-access": "邮箱连接", "due": "即将截止的邮件"}
PERMISSION_NAMES = {"mailbox": "邮箱"}
# 每一页要邮件助手给哪几样原始数据（清单 capabilities.data 里列了才由核心拼；没列的照旧读邮件助手自己的页，一页一页换）
PAGE_NEEDS = {
    "today": ("accounts", "today"),
    "inbox": ("accounts", "inbox"),
    "mail": ("mail",),
    "change": ("mail",),
    "digest": ("accounts", "digest"),
    "piece": ("digest", "piece"),
    "clean": ("accounts", "clean", "old"),
    "subs": ("accounts", "clean"),
    "old": ("accounts", "old"),
    "sender": ("accounts", "clean", "sender"),
    "sources": ("accounts", "digest"),
    "job": ("job",),
    "done": ("accounts", "today", "activity"),
    "activity": ("activity",),
    "settings": ("accounts", "settings"),
}
NEEDS = PAGE_NEEDS["today"]       # 至少给了这几样，标签才换成核心拼的
BUILT = set(PAGE_NEEDS)

# 标签：收件箱、精选、清理；设置、处理记录是右上角的图标（弹窗）；一封信、一条精选、一个订阅发件人是点开的弹窗。
# 旧界面的功能都在（负责人 11-15：精简是合并标签，不是删功能）：订阅体检并进清理，少用的收起来或放进点开的弹窗
PAGES = [
    {"id": "inbox", "title": "收件箱"},
    {"id": "digest", "title": "精选"},
    {"id": "clean", "title": "清理"},
    {"id": "activity", "title": "处理记录", "hidden": True, "icon": "history"},
    {"id": "settings", "title": "邮件助手设置", "hidden": True, "icon": "settings"},
    {"id": "mail", "title": "邮件", "hidden": True},
    {"id": "change", "title": "更改处理方式", "hidden": True},
    {"id": "piece", "title": "精选", "hidden": True},
    {"id": "sender", "title": "发件人", "hidden": True},
    {"id": "subs", "title": "订阅体检", "hidden": True},
    {"id": "old", "title": "旧邮件", "hidden": True},
    {"id": "sources", "title": "精选来源", "hidden": True},
    {"id": "job", "title": "后台任务", "hidden": True},
    {"id": "done", "title": "已处理的邮件", "hidden": True},
    # 「今日」不再是标签（负责人 11-16：整个应用已经有「今天」）：替你处理了什么在「今天」的「已自动处理」和右上角的处理记录里，
    # 要定的信在「今天」的邮箱卡片和收件箱「待处理」里。页还拼得出来（旧的链接去得了），只是不画成标签
    {"id": "today", "title": "今日", "hidden": True},
]
# 邮件助手自己的旧页（它的卡片上的「打开设置」「去设置」还指着）→ 核心拼的哪一页：旧页不再去（负责人 11-17：不该还有旧样子的页）
PAGE_ALIASES = {"legacy-settings": "settings", "rules": "settings", "sweep": "clean"}
# 带着这个参数去这一页的，换成另一页：卡片只讲一封时「在邮件助手中查看」带 `id` 去收件箱（邮件助手 new-mail、mailbox、due），
# 直接打开这一封（它可能不在收件箱的任何一组里：已归档的）。带 plan、list 的照旧去收件箱
ARG_PAGES = {("inbox", "id", ("plan", "list")): "mail"}
RULE_KIND = {"sender": "发件人是", "domain": "发件人域名是", "list": "邮件列表", "subject": "主题包含", "from": "发件人包含"}

# 动作代号 → 做过以后怎么说（「归档了 6 封」）、可选时按钮上的字
# 做过以后怎么说：{n} 是封数，{w} 是分类的词（「归档了 9 封通知」「给 2 封账单加了星标」）
DONE = {"archive": "已归档 {n} 封{w}", "trash": "已删除 {n} 封{w}", "spam": "已将 {n} 封{w}移到垃圾邮件",
        "read": "已将 {n} 封{w}标为已读", "unread": "已将 {n} 封{w}标为未读", "flag": "已为 {n} 封{w}加星标",
        "complete": "已完成并归档 {n} 封{w}", "skip": "{n} 封{w}保留在收件箱"}
WAYS = {"flag": "加星标", "archive": "归档", "skip": "留在收件箱", "trash": "删除", "spam": "移到垃圾邮件",
        "read": "标为已读", "unread": "标为未读", "complete": "完成并归档"}
# 分拣的分类代号 → 「归档了 9 封通知」里的那个词；认不得的不写
KIND_WORD = {"notice": "通知", "notification": "通知", "promotion": "推广邮件", "newsletter": "订阅邮件",
             "bill": "账单", "receipt": "收据", "social": "社交通知", "security": "安全提醒", "shipping": "快递通知"}

Read = Callable[[str], Any]


# 「今天」上「已自动处理」那一行也由核心照 data/today 拼（负责人 11-16：「今天」只算 1 件，邮件助手的「今日」列了 6 行，
# 两处要用同一份数）：一天一件，标题是各种处理各几封，展开一行一次处理，点开看信。邮件助手自己报的 auto-done 不再画
# 这几页记住上次看的是哪一组（核心 `_with_last`：没带参数时把上次的放进 `_last_<名>`）
REMEMBER_ARGS = {"inbox": ("list",), "digest": ("range",)}
CARD_NEEDS = ("today",)
REPLACES = frozenset({"auto-done"})
HANDLED_OPS = ("archive", "complete", "trash", "spam", "flag", "label", "read", "unread")
HANDLED_ROWS = 5        # 一种处理先列几行，多的进「处理记录」


def _handled_counts(handled: List[dict]) -> List[Tuple[str, int]]:
    counts: Dict[str, int] = {}
    for h in handled:
        op = h.get("op") or ""
        counts[op] = counts.get(op, 0) + int(h.get("count") or 0)
    order = [op for op in HANDLED_OPS if op in counts] + sorted(op for op in counts if op not in HANDLED_OPS)
    return [(op, counts[op]) for op in order if counts[op] > 0]


def handled_title(handled: List[dict]) -> str:
    """「归档 1 封 · 标为已读 5 封」"""
    words = {**WAYS, "label": "加标签"}
    return " · ".join(f"{words.get(op, '处理')} {n} 封" for op, n in _handled_counts(handled))


def handled_card(surface_id: str, handled: List[dict]) -> List[dict]:
    """展开以后：一种处理一组，一行一次处理（只动了一封的写「发件人 · 主题」，点开这封信；几封的点开列出来），行尾能撤销"""
    kit = PageKit(surface_id)
    words = {**WAYS, "label": "加标签"}
    top: List[str] = []
    groups = _handled_counts(handled)
    for op, n in groups:
        mine = [h for h in handled if (h.get("op") or "") == op]
        if len(groups) > 1:       # 只有一种处理时那一行的标题已经写了，不再写一遍
            top.append(kit.heading(f"{words.get(op, '处理')} {n} 封"))
        rows = []
        for h in mine[:HANDLED_ROWS]:
            acct = h.get("account") or "all"
            btns = []
            if h.get("undoable"):
                btns.append(kit.button("撤销此项", "mail_undo_step", {"account": acct, "log_id": h["log_id"]},
                                       icon="undo-2", variant="borderless"))
            mails = h.get("mails") or []
            opened = None
            if len(mails) == 1 and not h.get("more"):
                m = mails[0]
                title, sub = f"{_who(m.get('from'))} · {m.get('subject') or '（无主题）'}", None
                opened = kit.open_page("打开邮件", "mail", {"account": m.get("account") or acct, "id": str(m.get("id"))})
            else:
                title, sub = _names(h.get("senders") or []) or f"{h.get('count', 0)} 封", f"{h.get('count', 0)} 封"
                if mails and h.get("log_id") is not None:
                    opened = kit.open_page("查看邮件", "done", {"account": acct, "log_id": str(h["log_id"])})
            if opened:
                btns.append(opened)
            rows.append(kit.item(title, sub, btns, open=opened, strong=False))
        if len(mine) > HANDLED_ROWS:
            go = kit.open_page("处理记录", "activity")
            rows.append(kit.item(f"全部 {len(mine)} 项", None, [go], open=go, strong=False))
        top.append(kit.list(rows))
    return kit.messages(top)


def card(key: str, surface_id: str, read: Read) -> Optional[List[dict]]:
    """邮件助手自己报的事项的卡片：现在都照它给的画（None）"""
    return None


def items(listed: List[Any], read: Read) -> List[Any]:
    """「今天」上这个应用的事项：邮件助手报的照旧，只是「已自动处理」换成照 data/today 拼的一件（今天没处理过就不换）。
    读不到 data/today 时原样返回"""
    from ..items import Item
    d = read(uri("today", account="all"))
    if not isinstance(d, dict) or not isinstance(d.get("handled"), list):
        return listed
    handled = [h for h in d["handled"] if isinstance(h, dict) and not h.get("undone") and int(h.get("count") or 0) > 0]
    if not handled:
        return listed       # 数据里今天没有处理过的：邮件助手自己报了的照它的画，不让一件事没了
    out = [it for it in listed if it.kind not in REPLACES]
    day = str(d.get("day") or clock.now().date())
    title = handled_title(handled)
    first = min((h.get("at") or "" for h in handled), default="")
    out.append(Item(key=f"{APP}/handled/{day}", source=APP, kind="auto-done", urgency="normal", title=title,
                    summary=title, why_now="", card=handled_card(f"handled-{day}", handled),
                    created=first.replace(" ", "T") if first else None, extra={"core": True}))
    return out


def uri(name: str, **params: Optional[str]) -> str:
    q = {k: v for k, v in params.items() if v is not None}
    return f"data/{name}" + (f"?{urlencode(q)}" if q else "")


def build(page: str, args: Dict[str, str], read: Read) -> List[dict]:
    return {"today": today, "inbox": inbox, "mail": one_mail, "digest": digest, "piece": piece, "clean": clean,
            "sender": sender, "subs": subs, "change": change, "old": old, "sources": sources, "job": job, "done": done,
            "activity": activity, "settings": settings}[page](args, read)


def _problem(kit: PageKit, d: Any) -> Optional[List[dict]]:
    """读不出来（邮箱没连、信不在了）：页上写一句"""
    if isinstance(d, dict) and isinstance(d.get("error"), dict):
        code = d["error"].get("code")
        if code == "invalid":       # 不说去哪连，用户不知道下一步（旧界面：在「设置」里添加邮箱以后，这里会列出……）
            go = kit.open_page("添加邮箱", "settings", {"tab": "accounts", "add": "new"})
            return kit.messages([kit.text("尚未连接邮箱", "caption"), kit.link("在设置中添加邮箱", go)])
        text = {"stale": "此邮件已不存在"}.get(code, "此页暂时无法读取")
        return kit.messages([kit.text(text, "caption")])
    return None


def _when(at: Optional[str]) -> str:
    """「今天 08:45」「11月12日 20:10」（数据里的时间是本机时间，不带时区）"""
    if not at or len(at) < 16:
        return ""
    import datetime as dt
    try:
        t = dt.datetime.strptime(at[:16], "%Y-%m-%d %H:%M")
    except ValueError:
        return at
    today_ = clock.now().date()
    if t.date() == today_:
        return f"今天 {t:%H:%M}"
    if t.date() == today_ - dt.timedelta(days=1):
        return f"昨天 {t:%H:%M}"
    return f"{t.month}月{t.day}日 {t:%H:%M}"


def _who(sender: Optional[dict]) -> str:
    sender = sender or {}
    return sender.get("name") or sender.get("address") or "（无发件人）"


def _names(senders: List[dict], limit: int = 3) -> str:
    names = [_who(s) for s in senders[:limit]]
    return "、".join(names) + ("等" if len(senders) > limit else "")


def _account_switch(kit: PageKit, page: str, account: str, read: Read, extra: Optional[dict] = None) -> List[str]:
    """标签那一行右边的「全部邮箱 / 工作 / 个人」：两个以上邮箱才有；选了就换（停在上面写完整地址）"""
    accounts = (read(uri("accounts")) or {}).get("accounts") or []
    if len(accounts) < 2:
        return []
    opts = [("all", "全部邮箱")] + [(a["id"], a.get("name") or a["address"].split("@")[0], None, a["address"]) for a in accounts]
    args = dict(extra or {}, account={"path": "/choices/account/0"})
    go = kit.open_page("切换邮箱", page, args)
    return [kit.choice("account", opts, account if any(o[0] == account for o in opts) else "all",
                       submit=go, placement="header")]


# 现在分析不了邮件：data/accounts 的 `model.status` → 页上那一行（负责人 11-17：界面上的字由 agent 写；邮件助手的原文是口语的）
MODEL_STATE = {"none": "未选择本机模型，暂不分析邮件", "absent": "螺壳未运行，暂不分析邮件", "error": "螺壳暂无响应，暂不分析邮件",
               "downloading": "正在下载模型{progress}，完成后自动开始分析", "needs_download": "等待下载模型，完成后自动开始分析",
               "paused": "模型暂停运行，恢复后自动开始分析", "unsupported": "这台 Mac 暂不支持分析邮件"}


def _model_text(read: Read) -> Optional[str]:
    """现在分析不了邮件的原因（data/accounts 的 `model`）：认得的状态照代号写，不认得的用邮件助手的原文（去掉句尾的句号）；
    能分析时没有"""
    d = read(uri("accounts")) or {}
    m = d.get("model") if isinstance(d, dict) else None
    if not isinstance(m, dict):
        return None
    if m.get("status") in MODEL_STATE:
        p = m.get("progress")
        pct = f" {round(p * 100)}%" if isinstance(p, (int, float)) and not isinstance(p, bool) and 0 <= p <= 1 else ""
        return MODEL_STATE[m["status"]].format(progress=pct)
    text = m.get("text")
    return text.strip().rstrip("。") if isinstance(text, str) and text.strip() else None


# 停下的原因（邮件助手 docs/agent-data.md「停下的原因」的代号）→ 页上的字。邮件助手给代号，字由 agent 写（顶层 ADR 0002）
REASONS = {
    # 螺壳和本机模型
    "hub_not_running": "螺壳未运行", "busy": "本机模型正在处理更紧急的任务", "paused": "后台任务已暂停",
    "interrupted": "已让位给正在等待的请求", "not_ready": "本机模型正在加载", "memory_full": "内存不足",
    "task_unavailable": "本机模型暂不可用", "unsupported": "这台 Mac 上的螺壳不支持", "engine_failed": "本机模型出错",
    "input_too_long": "邮件过长", "model_timeout": "本机模型响应超时", "model_incomplete": "本机模型的回答不完整",
    "model_unusable": "本机模型的回答无法使用", "model_unreachable": "无法连接模型服务", "model_unresponsive": "模型服务无响应",
    "model_auth": "模型服务需要 API Key", "model_missing": "模型服务中没有所选模型", "model_error": "本机模型出错",
    # 邮箱
    "login_refused": "授权码无效或已过期，需重新填写", "missing_secret": "未保存授权码", "keychain_locked": "钥匙串暂时无法读取",
    "mail_login_blocked": "登录被邮箱拦截，需在浏览器中确认", "mail_unsafe_login": "需开启 IMAP 并使用授权码",
    "imap_disabled": "邮箱未开启 IMAP", "mail_timeout": "连接邮箱超时", "mail_unreachable": "无法连接邮箱服务器",
    "mail_tls": "不支持邮箱服务器的加密方式", "mail_unresponsive": "邮箱暂时无响应", "mail_refused": "邮箱未完成此操作",
    "no_folder": "找不到文件夹", "folder_hidden": "邮箱未开放「我的文件夹」", "label_invalid": "标签名无效",
    "search_failed": "邮箱搜索失败", "no_server": "未填写 IMAP 服务器", "mail_error": "邮箱出错",
    # 其余
    "timeout": "连接超时", "network": "网络连接失败", "invalid": "设置或请求无效", "error": "出错",
}


def _why(code: Any, text: Any = None) -> str:
    """停下的原因写成什么：有代号照代号写（不认识的当 `error`）；没有代号（旧一点的邮件助手）退回它的原文，
    去掉句尾的句号和「异常类名: 」（类名不上屏）；都没有是空的"""
    if isinstance(code, str) and code:
        return REASONS.get(code, REASONS["error"])
    t = re.sub(r"^[A-Za-z_][A-Za-z0-9_.]*(Error|Exception): ?", "", str(text or "")).strip().rstrip("。")
    return t


def _model_note(kit: PageKit, read: Read) -> Optional[str]:
    """页顶一行小字（收件箱）"""
    text = _model_text(read)
    return kit.text(text, "caption") if text else None


def _status_block(kit: PageKit, notes: List[Optional[str]]) -> List[str]:
    """按小标题分组的页（清理、订阅体检）：状态说明自己一组「分析状态」，一句一行。直接放一行小字会被窗口当成小标题，
    把下面几组并成一张卡片"""
    lines = [n for n in notes if n]
    return [kit.heading("分析状态"), kit.list([kit.item(n, None, strong=False) for n in lines])] if lines else []


def _accounts_of(read: Read) -> List[dict]:
    return (read(uri("accounts")) or {}).get("accounts") or []


def _single(account: str, read: Read) -> Optional[str]:
    """动作要一个邮箱：选了一个就是它；「全部」时只有一个邮箱就是那个，几个邮箱是 None（按钮按邮箱分开放）"""
    if account != "all":
        return account
    accts = _accounts_of(read)
    return accts[0]["id"] if len(accts) == 1 else None


def _box_name(a: dict) -> str:
    return a.get("name") or (a.get("address") or a["id"]).split("@")[0]


# 后台任务：`job.kind` → 进度那一行的名字（邮件助手的 `stage` 是它自己的句子：「正在阅读你发出的邮件」「正在检查会不会误伤」）
JOB_NAMES = {"sync": "正在同步邮件", "auto": "正在自动整理", "old_scan": "正在读取旧邮件", "clean": "正在处理所选邮件",
             "subscriptions": "正在检查订阅", "filter_preview": "正在预演过滤器", "older": "正在读取更早的邮件",
             "judge": "正在分析旧邮件", "read": "正在读取订阅内容", "profile": "正在整理个人资料", "edit": "正在挑选精选",
             "learn": "正在从邮件中学习偏好", "idle": "后台处理中"}


def _job_name(job: dict) -> str:
    return JOB_NAMES.get(job.get("kind")) or "后台处理中"


def _job(kit: PageKit, read: Read) -> Optional[str]:
    """正在跑的任务（同步、清理、读订阅……）：一行进度和「停下」（data/accounts 的 job）"""
    job = (read(uri("accounts")) or {}).get("job")
    if not isinstance(job, dict) or not job.get("id"):
        return None
    done, total = job.get("done"), job.get("total")
    sub = f"{done} / {total}" if isinstance(done, int) and isinstance(total, int) and total else None
    stop = kit.button("停止", "mail_job_stop", {"id": job["id"]}, icon="x", variant="borderless")
    return kit.list([kit.item(_job_name(job), sub, [stop])])


def _day(at: Optional[str]) -> str:
    """「11月10日」"""
    if not at or len(at) < 10:
        return ""
    try:
        return f"{int(at[5:7])}月{int(at[8:10])}日"
    except ValueError:
        return at[:10]


def today(args: Dict[str, str], read: Read) -> List[dict]:
    """今日：最上面替你处理了什么（每行一个撤销图标）；要你定的只有拿不准的那几封，处理方式排成一组、建议的已选中，
    点一下就办；等回复的只在最下面一行，点了去收件箱。正在后台跑的任务在最上面一行，能停下"""
    account = args.get("account") or "all"
    d = read(uri("today", account=account)) or {}
    kit = PageKit("today")
    top: List[str] = _account_switch(kit, "today", account, read)
    job = _job(kit, read)
    if job:
        top.append(job)
    handled = d.get("handled") or []
    picked = int(d.get("picked") or 0)
    if handled or picked:
        top.append(kit.heading("今日已处理"))
        done: List[str] = []
        for h in handled[:PAGE_ROWS]:
            word = next((KIND_WORD[c] for c in h.get("categories") or [] if c in KIND_WORD), "")
            title = DONE.get(h.get("op"), "已处理 {n} 封{w}").format(n=h.get("count", 0), w=word)
            if h.get("op") == "label" and h.get("label"):
                title = f"已为 {h.get('count', 0)} 封加标签「{h['label']}」"
            btns = []
            if h.get("undoable"):
                btns.append(kit.button("撤销", "mail_undo_step", {"account": h.get("account") or account, "log_id": h["log_id"]},
                                       icon="undo-2", variant="borderless"))
            # 处理了哪几封（邮件助手给了 `mails` 的）：点这一行列出来，再点一封看全文、去原信（负责人 11-15：看不懂处理的是啥）
            opened, sub = None, _names(h.get("senders") or [])
            mails = h.get("mails") or []
            if len(mails) == 1 and not h.get("more"):      # 只动了一封：写发件人和主题，点了直接打开这封信
                m = mails[0]
                sub = f"{_who(m.get('from'))}：{m.get('subject') or '（无主题）'}"
                opened = kit.open_page("打开邮件", "mail", {"account": m.get("account") or h.get("account") or account,
                                                              "id": str(m.get("id"))})
            elif mails and h.get("log_id") is not None:
                opened = kit.open_page("查看邮件", "done", {"account": h.get("account") or account, "log_id": str(h["log_id"])})
            if opened:
                btns.append(opened)
            done.append(kit.item(title, sub or None, btns, open=opened))
        if picked:
            go = kit.open_page("查看精选", "digest", {"range": "today"})
            done.append(kit.item(f"精选 {picked} 篇", "位于「精选」", open=go))
        top.append(kit.list(done))
    decide = d.get("decide") or []
    if decide:
        top.append(kit.heading("待确认"))      # 不写个数（界面规范 §18.1：页面上不出现「等你处理 N」）
        for it in decide:
            key = f"m{it['id']}"
            ways = [w for w in it.get("ways") or [] if w in WAYS]
            acct = it.get("account") or account
            # 点发件人和主题那一行打开这封信（看全文、去原信）
            opened = kit.open_page("打开邮件", "mail", {"account": acct, "id": str(it["id"])})
            late = "已过期" if it.get("late") == "overdue" else _due(it)
            sub = " · ".join(x for x in ("可疑邮件，请勿点击链接或转账" if it.get("suspicious") else "", late, it.get("summary_text")) if x)
            parts = [kit.item(f"{_who(it.get('from'))}：{it.get('subject') or '（无主题）'}", sub or None, [opened],
                              open=opened)]
            btns: List[str] = []
            if ways:
                # 处理方式排成一组，建议的已选中；选了不马上办，点旁边的按钮才办（负责人 11-15：一点就生效了）
                do = kit.button("处理", "mail_act", {"account": acct, "ids": [it["id"]], "op": {"path": f"/choices/{key}/0"}},
                                variant="primary")
                suggested = it.get("suggested") if it.get("suggested") in ways else ways[0]
                btns += [kit.choice(key, [(w, WAYS[w]) for w in ways], suggested), do]
            if "calendar" in (it.get("ways") or []):
                btns.append(kit.button("加入日程", "mail_calendar", {"account": acct, "id": it["id"]},
                                       icon="calendar-plus", variant="borderless"))
            if btns:
                parts.append(kit.row(btns))
            top.append(kit.column(parts))
    replies = int(d.get("replies") or 0)
    if replies:
        go = kit.open_page("前往收件箱", "inbox", {"list": "reply"} if account == "all" else {"list": "reply", "account": account})
        top.append(kit.link(f"收件箱有 {replies} 封待回复", go))
    if not handled and not picked and not decide and not replies:
        top.append(kit.text("今日没有待确认的邮件", "caption"))
    return kit.messages(top)


# 收件箱的几组（邮件助手 data/inbox 的 list）
LIST_WORDS = {"reply": "待回复", "needs": "待处理", "suspicious": "可疑", "archived": "已归档待处理", "all": "全部",
              "direct": "可整理"}


def _due(it: dict) -> Optional[str]:
    if it.get("overdue"):
        return "已过期"
    due = it.get("due")
    return f"{_day(due + ' ')}前" if isinstance(due, str) and len(due) >= 10 else None


def _due_badge(it: dict) -> Optional[str]:
    """截止日的小标签：「11-18 截止」「已过期」（和「今天」的邮箱卡片一个写法）"""
    if it.get("overdue"):
        return "已过期"
    due = it.get("due")
    return f"{due[5:10]} 截止" if isinstance(due, str) and len(due) >= 10 else None


def _short_when(at: Optional[str]) -> Optional[str]:
    """来信时间：今天的写时刻，其余写日期"""
    if not at or len(at) < 16:
        return None
    return at[11:16] if at[:10] == str(clock.now().date()) else at[5:10]


def _row_buttons(kit: PageKit, it: dict, acct: str) -> List[str]:
    """一行两个按钮，照分拣的建议：主按钮是建议做的那件，次按钮是归档（或留在收件箱）。界面规范：一个主按钮加一个次按钮。
    都带图标：行尾只画图标，字在悬停提示里（负责人 11-16：带字的按钮占掉一大块，主题被截断）"""
    ids, kind, act = [it["id"]], it.get("kind"), it.get("action")
    icons = {"spam": "shield-alert", "skip": "inbox", "archive": "archive", "flag": "star", "trash": "trash-2",
             "complete": "check"}

    def op(label: str, o: str, primary: bool = False) -> str:
        return kit.button(label, "mail_act", {"account": acct, "ids": ids, "op": o}, icon=icons[o],
                          variant="primary" if primary else "borderless")

    def calendar(primary: bool = False) -> str:
        return kit.button("加入日程", "mail_calendar", {"account": acct, "id": it["id"]}, icon="calendar-plus",
                          variant="primary" if primary else "borderless")

    if it.get("archived"):
        # 有截止日、还没过的可以把截止日加进日程（邮件助手 0.19.72）。在收件箱里的行照旧两个按钮，加入日程在打开的那封信里
        dated = isinstance(it.get("due"), str) and len(it["due"]) >= 10 and not it.get("overdue")
        # 已经不在收件箱里的（在别处归档的、截止日没到就归档的）：移动邮件的动作没有意义，只给「完成」（只改本机记录，可撤销），
        # 是日程或有没过的截止日的再给加入日程
        # 已经交给过「日历」的不再出（邮件助手 0.19.74 的 calendar_added）
        if (kind == "schedule" or act == "schedule" or dated) and not it.get("calendar_added"):
            return [op("完成", "complete", True), calendar()]
        return [op("完成", "complete", True)]
    if it.get("suspicious") or kind == "suspicious":
        return [op("移到垃圾邮件", "spam", True), op("留在收件箱", "skip")]
    if kind == "reply" or act == "reply":
        return [kit.button("回复", "mail_draft", {"account": acct, "id": it["id"]}, icon="reply", variant="primary"),
                op("归档", "archive")]
    if kind == "schedule" or act == "schedule":
        return [calendar(True), op("归档", "archive")]
    if kind == "follow_up" or act == "follow_up":
        return [op("加星标", "flag", True), op("归档", "archive")]
    if act == "ignore":
        return [op("删除", "trash", True), op("留在收件箱", "skip")]
    return [op("归档", "archive", True), op("留在收件箱", "skip")]


def inbox(args: Dict[str, str], read: Read) -> List[dict]:
    """收件箱：默认列等你回复的，还能换成待处理、可疑、全部；每行一句话说对方要什么、截止日；每行一个主按钮（照建议：回复、
    加入日程、加星标、移到垃圾邮件……）加一个次按钮；点一行打开这封信。右上一行「同步新邮件」；多的翻页"""
    # 邮件助手卡片上的「在邮件助手里看」写的是 box（哪个邮箱）、list（needs 待处理、direct 可以整理）
    account = args.get("account") or args.get("box") or "all"
    plan = args.get("plan") or ""
    picked = args.get("list") if args.get("list") in LIST_WORDS else None
    last = args.get("_last_list") if args.get("_last_list") in LIST_WORDS and args.get("_last_list") != "direct" else None
    lst = picked or last or "reply"     # 没指定：先看上次停的那一组（空了再换，见下面）
    cursor = args.get("cursor") or None
    if plan:
        # 卡片上「查看邮件」：只列这张卡片要动的那几封（点了「归档」动的就是这些），不出换组的那一排
        # 邮箱卡片一张方案管几块（todo、tidy、sus）：part 原样带上（邮件 0.19.63），只看那一块
        d = read(uri("inbox", account=account, part=args.get("part"), plan=plan)) or {}
    else:
        d = read(uri("inbox", account=account, list=None if lst == "reply" else lst, cursor=cursor)) or {}  # 待回复是默认的，不写
        # 没指定看哪一组：停在第一个不空的组（负责人 11-15：默认停在空的「等回复」，「待处理」里其实有 7 封）
        if picked is None and isinstance(d, dict) and not d.get("items"):
            c = d.get("counts") or {}
            first = next((k for k in ("reply", "needs", "suspicious") if k != lst and int(c.get(k) or 0) > 0), None)
            if first:
                lst = first
                d = read(uri("inbox", account=account, list=lst, cursor=cursor)) or {}
    kit = PageKit("inbox")
    bad = _problem(kit, d)
    if bad:
        return bad
    counts = d.get("counts") or {}
    if plan:
        n = len(d.get("items") or [])
        state = (d.get("plan") or {}).get("state", "open")
        head = {"handled": "此卡片已处理", "gone": "此卡片已失效"}.get(state) or \
            (f"此卡片涉及 {n} 封" if n else "此卡片涉及的邮件已不在收件箱")
        top: List[str] = [kit.heading(head) if state == "open" and n else kit.text(head, "caption")]
    else:
        top = _account_switch(kit, "inbox", account, read, {"list": lst})
        note = _model_note(kit, read)
        if note:
            top.append(note)
        go = kit.open_page("切换分组", "inbox", {"list": {"path": "/choices/list/0"}, **({} if account == "all" else {"account": account})})
        # 等回复、待处理、全部一直在；有可疑的才有「可疑」；你归档了、里面还有要回复或日程的才有「归档里待处理」；
        # 从卡片上点进来看「可以整理」的多一个它
        keys = ["reply", "needs"] + (["suspicious"] if counts.get("suspicious") or lst == "suspicious" else []) \
            + (["archived"] if counts.get("archived") or lst == "archived" else []) + ["all"] \
            + (["direct"] if lst == "direct" else [])
        sync = kit.button("同步新邮件", "mail_sync", {"account": account}, icon="refresh-cw", variant="borderless")
        # 每组写封数（「全部」邮件助手不给数，不写）；字不随选没选中变，选中框滑动时各段宽度不变
        def word(v: str) -> str:
            return f"{LIST_WORDS[v]} {int(counts.get(v) or 0)}" if v in counts else LIST_WORDS[v]
        top.append(kit.row([kit.choice("list", [(v, word(v)) for v in keys], lst, submit=go), sync],
                           justify="spaceBetween"))
        if counts.get("unsorted"):
            top.append(kit.text(f"{counts['unsorted']} 封未分析，将在同步时分析", "caption"))
    rows = []
    items = d.get("items") or []
    for it in items[:INBOX_ROWS]:
        acct = it.get("account") or account
        btns = [] if plan else _row_buttons(kit, it, acct)
        url = it.get("open_url")
        if not plan and isinstance(url, str) and url.startswith("https://"):
            # 去 Gmail 的按钮带着网站名（底线：链接先写明去哪个网站），只是写短（负责人 11-16：「Gmail ↗」）
            btns.append(kit.button("Gmail", "agent.open_url", {"url": url}, icon="square-arrow-out-up-right",
                                   variant="borderless", tooltip="在 Gmail 中打开"))
        opened = kit.open_page("打开邮件", "mail", {"account": acct, "id": str(it["id"])})
        warn = "可疑邮件，请勿点击链接或转账" if it.get("suspicious") or it.get("kind") == "suspicious" else ""
        sub = " · ".join(x for x in (warn, it.get("ask_text")) if x)
        # 发件人加粗、主题不加粗，截止日是小标签，后面是来信时间（负责人 11-16：发件人和主题一样粗、连在一起，不好扫读）。
        # 看一张卡片要动的那几封：只看，不放按钮（动它们回卡片上点）；点一行打开这封信
        rows.append(kit.mail_item(_who(it.get("from")), it.get("subject") or "（无主题）", sub or None, btns, open=opened,
                                  badge=_due_badge(it), when=_short_when(it.get("date"))))
    if rows:
        top.append(kit.list(rows))
    elif not plan:
        top.append(kit.text({"reply": "没有待回复的邮件", "needs": "没有待处理的邮件", "suspicious": "没有可疑邮件",
                             "direct": "没有可整理的邮件", "archived": "已归档邮件中没有待处理项"}.get(lst, "收件箱为空"), "caption"))
    # 一页最多 INBOX_ROWS 封：邮件助手一次给 200 封，全画超过页的组件上限（负责人 11-15 点「全部」只看到「这一页画不了」）。
    # 它的 cursor 是第几封起（offset），下一页从这一页最后一封往后数
    at = int(cursor) if cursor and cursor.isdigit() else 0
    nxt_at = at + INBOX_ROWS if len(items) > INBOX_ROWS else (int(d["cursor"]) if d.get("more") and str(d.get("cursor") or "").isdigit() else None)
    if not plan and (at > 0 or nxt_at):
        base_args = {"list": lst, **({} if account == "all" else {"account": account})}
        pager_btns: List[str] = []
        if at > 0:
            prev_at = max(0, at - INBOX_ROWS)
            prev_args = base_args if prev_at == 0 else {**base_args, "cursor": str(prev_at)}
            pager_btns.append(kit.open_page("较新", "inbox", prev_args, variant="borderless"))
        if nxt_at:
            pager_btns.append(kit.open_page("更早", "inbox", {**base_args, "cursor": str(nxt_at)}, variant="borderless"))
        top.append(kit.row(pager_btns))
    return kit.messages(top)


# 一封信「改成别的处理方式」可选的（邮件助手 triage.ACTIONS），记成规则时还能选移到垃圾邮件
CHANGE = [("reply", "回复"), ("schedule", "加入日程"), ("follow_up", "加星标"), ("archive", "归档"), ("ignore", "删除")]
REMEMBER = [("none", "仅此邮件"), ("sender", "此发件人今后同样处理"), ("domain", "此域名今后同样处理")]


def one_mail(args: Dict[str, str], read: Read) -> List[dict]:
    """一封信（弹窗）：发件人、时间、截止日、可疑的提醒、正文；全部可做的处理（建议的在前，是主按钮）；
    有草稿的给草稿（能改，存进邮箱的草稿箱）；有网页版地址的「在邮箱网页里打开」；
    改成别的处理方式并记成规则收起来"""
    account, mid = args.get("account") or "all", args.get("id") or ""
    # 卡片上带 id 来的没有邮箱：不写 account（邮件助手照 id 找，样例里录的就是 data/mail?id=）
    d = read(uri("mail", account=None if account == "all" else account, id=mid)) or {}
    kit = PageKit("mail")
    bad = _problem(kit, d)
    if bad:
        return bad
    acct = d.get("account") or account
    the_id = d.get("id", mid)
    top = [kit.text(d.get("subject") or "（无主题）", "h4"),
           kit.text(" · ".join(x for x in (_who(d.get("from")), (d.get("from") or {}).get("address"), _when(d.get("date")), _due(d))
                               if x), "caption")]     # 写地址：看是不是冒充的要靠它
    if d.get("suspicious"):
        top.append(kit.text("此邮件疑似诈骗：请勿点击其中的链接，也不要按其要求转账或提供密码", "strong"))
    if d.get("ask_text"):
        top.append(kit.text(d["ask_text"], "strong"))
    if d.get("body_text"):
        top.append(kit.text(d["body_text"] + ("……" if d.get("truncated") else "")))
        if d.get("truncated"):
            top.append(kit.text("正文未显示完，请在邮箱网页中查看全文" if d.get("open_url") else "正文未显示完，请在邮箱中查看全文", "caption"))
    to = [str(a) for a in d.get("to") or []] + [str(a) for a in d.get("cc") or []]
    if to:
        top.insert(2, kit.text("发给 " + "、".join(to[:4]) + (f" 等 {len(to)} 人" if len(to) > 4 else ""), "caption"))
    if d.get("attachments"):
        top.append(kit.text("附件：" + "、".join(str(a) for a in d["attachments"]), "caption"))
    events = [e for e in d.get("events") or [] if isinstance(e, dict)]
    btns = []
    # 截止日没到就归档了的（邮件助手 0.19.72）：能做的只有完成、把截止日加入日程，没有移动邮件的动作
    gone = bool(d.get("ways")) and "archive" not in d["ways"]
    for i, w in enumerate(d.get("ways") or []):
        kw: Dict[str, Any] = {"variant": "primary"} if i == 0 else {}
        if w == "draft":
            btns.append(kit.button("撰写回复", "mail_draft", {"account": acct, "id": the_id}, **kw))
        elif w == "calendar":
            if len(events) < 2:     # 几个日程的在下面一个一个加
                btns.append(kit.button("加入日程", "mail_calendar", {"account": acct, "id": the_id}, **kw))
        elif w in WAYS:
            # 已经不在收件箱里的（ways 里没有归档）「完成」只改本机记录，不写「并归档」
            label = "完成" if w == "complete" and gone else WAYS[w]
            btns.append(kit.button(label, "mail_act", {"account": acct, "ids": [the_id], "op": w}, **kw))
    url = d.get("open_url")
    if isinstance(url, str) and url.startswith("https://"):
        btns.append(kit.button("在邮箱网页中打开", "agent.open_url", {"url": url}, icon="square-arrow-out-up-right",
                               variant="borderless"))
    if btns:
        top.append(kit.row(btns))
        kit.components[-1]["placement"] = "footer"      # §4 footerPlacement：固定在弹窗底部，信长了也不用滚到底才点得到
    if len(events) == 1 and (events[0].get("added") or events[0].get("past")):
        e = events[0]
        top.append(kit.text("已加入日程" if e.get("added") else f"日程已过期（{_day(e.get('date'))}）", "caption"))
    if len(events) > 1:
        rows = []
        for e in events:
            when = " ".join(x for x in (_day(e.get("date")), e.get("start") or "") if x)
            if e.get("end"):
                when += f"–{e['end']}"
            sub = " · ".join(x for x in (when, e.get("location")) if x)
            if e.get("added"):
                b = [kit.text("已加入", "caption")]
            elif e.get("past"):
                b = [kit.text("已过期", "caption")]
            else:
                b = [kit.button("加入日程", "mail_calendar", {"account": acct, "id": the_id, "index": e.get("index", 0)},
                                icon="calendar-plus", variant="borderless")]
            rows.append(kit.item(e.get("title") or "日程", sub or None, b))
        top += [kit.heading(f"邮件中的日程 · {len(events)}"), kit.list(rows)]
    if isinstance(d.get("draft_text"), str) and d["draft_text"]:
        kit.data.setdefault("fields", {})["draft"] = d["draft_text"]
        field = kit.add({"id": kit._id("f"), "component": "TextField", "label": "草稿", "variant": "longText",
                         "value": {"path": "/fields/draft"}})
        save = kit.button("保存到草稿箱", "mail_draft_save", {"account": acct, "id": the_id, "text": {"path": "/fields/draft"}})
        top += [kit.heading("草稿"), field, kit.row([save])]
    if d.get("ways") and not gone:
        # 改成别的处理方式（可同时存成规则）不再收在正文最下面：弹窗标题那一行右边一个按钮，点开下一层（UX-14）
        b = kit.open_page("更改处理方式", "change", {"account": acct, "id": str(the_id)}, icon="pencil-line", variant="borderless",
                          tooltip="更改处理方式，可同时保存为规则")
        next(c for c in kit.components if c["id"] == b)["placement"] = "header"
        top.insert(0, b)
    return kit.messages(top)


def change(args: Dict[str, str], read: Read) -> List[dict]:
    """更改处理方式（从一封信的弹窗标题右边点开）：改成什么、以后同类的怎么办，一个「更改」"""
    account, mid = args.get("account") or "all", args.get("id") or ""
    d = read(uri("mail", account=None if account == "all" else account, id=mid)) or {}
    kit = PageKit("change")
    bad = _problem(kit, d)
    if bad:
        return bad
    acct = d.get("account") or account
    the_id = d.get("id", mid)
    top = [kit.text(d.get("subject") or "（无主题）", "strong")]
    if not d.get("ways") or "archive" not in d["ways"]:
        top.append(kit.text("此邮件已不在收件箱中，无法更改处理方式", "caption"))
        return kit.messages(top)
    do = kit.button("更改", "mail_change", {"account": acct, "ids": [the_id], "action": {"path": "/choices/change/0"},
                                          "remember": {"path": "/choices/remember/0"}}, variant="primary")
    top += [kit.choice("change", CHANGE, d.get("action") if d.get("action") in dict(CHANGE) else "archive", label="改成"),
            kit.choice("remember", REMEMBER, "none", label="以后"),
            kit.row([do])]
    return kit.messages(top)


# 精选的几段：今天、本周一直在；有收藏、看过了的才有那两段；往月最多两个
def _ranges(d: dict, rng: str, today_n: Optional[int]) -> List[Tuple[str, str]]:
    counts = d.get("counts") or {}
    # 字不随选没选中变（以前「今天 N」只在选中时带数，选中框滑动时各段宽度会变）：今天、本周不写数，
    # 收藏、已读写邮件助手给的数
    out = [("today", "今天"), ("week", "本周")]
    if counts.get("saved") or rng == "saved":
        out.append(("saved", f"收藏 {int(counts['saved'])}" if counts.get("saved") else "收藏"))
    if counts.get("archived") or rng == "archived":
        out.append(("archived", f"已读 {int(counts['archived'])}" if counts.get("archived") else "已读"))
    months = [m for m in d.get("months") or [] if isinstance(m, str) and len(m) == 7][:2]
    if rng.startswith("month:") and rng[6:] not in months:
        months.append(rng[6:])
    out += [(f"month:{m}", f"{int(m[5:])} 月") for m in months]
    return out


def _range(args: Dict[str, str]) -> str:
    r = args.get("range") or args.get("_last_range") or "today"     # 没指定：上次看的那一段
    return r if r in ("today", "week", "saved", "archived") or (r.startswith("month:") and len(r) == 13) else "today"


def digest(args: Dict[str, str], read: Read) -> List[dict]:
    """精选：直接列挑出来的，每条标题和一句摘要；点一行打开；右边图标：收藏（多来点这类）、减少此类、看过了（移出精选）。
    还能看收藏、看过了的和往月；最下面一行读订阅的进度，能暂停"""
    account = args.get("account") or "all"
    rng = _range(args)
    d = read(uri("digest", account=account, range=None if rng == "week" else rng)) or {}     # 本周是默认的，不写
    # 没指定看哪一段、「今天」是空的：换到「本周」（负责人 11-15：默认「今天」是空的，「本周」有一整页）
    if not args.get("range") and rng == "today" and isinstance(d, dict) and not d.get("items") and not d.get("error"):
        week = read(uri("digest", account=account)) or {}
        if isinstance(week, dict) and week.get("items"):
            rng, d = "week", week
    kit = PageKit("digest")
    bad = _problem(kit, d)
    if bad:
        return bad
    items = d.get("items") or []
    top: List[str] = _account_switch(kit, "digest", account, read, {"range": rng})
    go = kit.open_page("切换时间段", "digest", {"range": {"path": "/choices/range/0"}, **({} if account == "all" else {"account": account})})
    top.append(kit.choice("range", _ranges(d, rng, len(items) if rng == "today" else None), rng, submit=go))
    rows = []
    for it in items[:DIGEST_ROWS]:
        acct = it.get("account") or account
        saved = it.get("feedback") == "useful"
        keep = kit.button("取消收藏" if saved else "收藏并增加此类", "mail_digest_feedback",
                          {"account": acct, "id": it["id"], "value": None if saved else "useful"},
                          icon="star", variant="borderless")
        less = kit.button("减少此类", "mail_digest_feedback", {"account": acct, "id": it["id"], "value": "dismissed"},
                          icon="thumbs-down", variant="borderless")
        back = rng == "archived"
        arch = kit.button("移回精选" if back else "标为已读并移出精选", "mail_digest_archive",
                          {"account": acct, "id": it["id"], "on": not back}, icon="undo-2" if back else "archive",
                          variant="borderless")
        opened = kit.open_page("打开", "piece", {"account": acct, "id": str(it["id"]), "range": rng})
        sub = " · ".join(x for x in (it.get("source"), it.get("summary_text")) if x)
        rows.append(kit.item(it.get("title") or "（无标题）", sub or None, [keep, less, arch], open=opened))
    if rows and rng in ("today", "week") and not any(it.get("picked") for it in items):
        top.append(kit.text("按评分排序", "caption"))     # 这一段还没挑过：说明现在的次序（负责人 11-16：不写「还没挑好」那样的话）
    if rows:
        top.append(kit.list(rows))
    else:
        top.append(kit.text({"today": "今日暂无精选", "week": "本周暂无精选", "saved": "暂无收藏",
                             "archived": "暂无已读内容"}.get(rng, "本月暂无精选"), "caption"))
        if not (d.get("sources") or (d.get("counts") or {}).get("sources")) and rng in ("today", "week"):
            go = kit.open_page("前往清理", "clean", {} if account == "all" else {"account": account})
            top.append(kit.link("精选尚无订阅来源：在「清理」中选择订阅发件人并加入精选", go))
    reading = d.get("reading") or {}
    one = _single(account, read)
    if reading.get("problem") or reading.get("problem_code"):
        top.append(kit.text(f"订阅读取已停止：{_why(reading.get('problem_code'), reading.get('problem'))}，恢复后继续读取", "caption"))
    elif reading.get("queued") and one:
        on = reading.get("on") is not False
        flip = kit.button("暂停" if on else "继续", "mail_digest_reading", {"account": one, "on": not on},
                          variant="borderless")
        what = f"正在读取订阅邮件：已读 {reading.get('read', 0)} 封，剩余 {reading['queued']} 封" if on else \
            f"订阅邮件读取已暂停，剩余 {reading['queued']} 封"
        top.append(kit.row([kit.text(what, "caption"), flip], justify="spaceBetween"))
    n_src = len(d.get("sources") or []) or int((d.get("counts") or {}).get("sources") or 0)
    if n_src:
        go = kit.open_page("精选来源", "sources", {} if account == "all" else {"account": account})
        top.append(kit.link(f"精选来源：{n_src} 个发件人", go))
    return kit.messages(top)


ORIGIN = {"user": "手动添加", "subscriptions": "来自订阅体检", "clean": "来自清理"}


def sources(args: Dict[str, str], read: Read) -> List[dict]:
    """精选读的发件人（弹窗，从精选最下面一行点开）：一个一行，写是怎么加进来的，能移出"""
    account = args.get("account") or "all"
    d = read(uri("digest", account=account)) or {}
    kit = PageKit("sources")
    bad = _problem(kit, d)
    if bad:
        return bad
    rows = []
    for s in (d.get("sources") or [])[:PAGE_ROWS]:
        sub = "，".join(x for x in (ORIGIN.get(s.get("origin"), ""), f"{_day(s.get('added_at'))}添加" if s.get("added_at") else "")
                       if x)
        out = kit.button("移出精选", "mail_digest_source", {"account": s.get("account") or account, "key": s.get("key"), "on": False},
                         icon="x", variant="borderless")
        rows.append(kit.item(s.get("name") or s.get("key") or "（未命名）", sub or None, [out]))
    top = [kit.list(rows)] if rows else [kit.text("精选尚无来源。在「清理」中选择订阅发件人即可加入", "caption")]
    return kit.messages(top)


def piece(args: Dict[str, str], read: Read) -> List[dict]:
    """一条精选（弹窗）：标题、来源、摘要、为什么挑；在浏览器中打开（写网站）、在 Gmail 中查看原邮件、收藏、少来点、看过了"""
    account, pid = args.get("account") or "all", args.get("id") or ""
    rng = _range(args)
    kit = PageKit("piece")
    it: Optional[dict] = None
    if account != "all":
        # 读 data/piece 就记一次「打开过」（邮件助手 agent-data.md「有副作用的那一处」）
        one = read(uri("piece", account=account, id=pid)) or {}
        it = one if isinstance(one, dict) and one.get("id") is not None else None
    if it is None:
        d = read(uri("digest", account=account, range=None if rng == "week" else rng)) or {}
        bad = _problem(kit, d)
        if bad:
            return bad
        it = next((x for x in d.get("items") or [] if str(x.get("id")) == pid), None)
    if it is None:
        return kit.messages([kit.text("此条已不在精选中", "caption")])
    acct = it.get("account") or account
    top = [kit.text(it.get("title") or "（无标题）", "h4")]
    if it.get("source") or it.get("date"):
        top.append(kit.text(" · ".join(x for x in (it.get("source"), _day(it.get("date"))) if x), "caption"))
    if it.get("summary_text"):
        top.append(kit.text(it["summary_text"]))
    if it.get("why_text"):
        top.append(kit.text("入选理由：" + it["why_text"], "caption"))
    btns = []
    if isinstance(it.get("url"), str) and it["url"].startswith("https://"):
        btns.append(kit.button(f"在浏览器中打开（{it.get('host') or '网页'}）", "agent.open_url", {"url": it["url"]}, variant="primary"))
    if isinstance(it.get("mail_url"), str) and it["mail_url"].startswith("https://"):
        btns.append(kit.button("在 Gmail 中查看原邮件", "agent.open_url", {"url": it["mail_url"]}, icon="mail", variant="borderless"))
    saved = it.get("feedback") == "useful"
    btns.append(kit.button("取消收藏" if saved else "收藏", "mail_digest_feedback",
                           {"account": acct, "id": it["id"], "value": None if saved else "useful"},
                           icon="star"))
    btns.append(kit.button("减少此类", "mail_digest_feedback", {"account": acct, "id": it["id"], "value": "dismissed"}, icon="thumbs-down"))
    back = rng == "archived"
    btns.append(kit.button("移回精选" if back else "已读", "mail_digest_archive", {"account": acct, "id": it["id"], "on": not back},
                           icon="undo-2" if back else "archive"))
    top.append(kit.row(btns))
    kit.components[-1]["placement"] = "footer"      # §4 footerPlacement：固定在弹窗底部
    return kit.messages(top)


def _per(s: dict) -> str:
    """「每周 5 封，均未读」"""
    pw = float(s.get("per_week") or 0)
    freq = f"每周 {round(pw)} 封" if pw >= 1 else f"每月 {max(1, round(pw * 30 / 7))} 封"
    read_n = int(s.get("read") or 0)
    return freq + ("，均未读" if read_n == 0 else f"，已读 {read_n} 封")


def _size(n: Any) -> str:
    """「3.4 MB」「41 MB」：字节数说成大小，没有是空的"""
    try:
        n = int(n or 0)
    except (TypeError, ValueError):
        return ""
    if n <= 0:
        return ""
    for unit, base in (("GB", 1e9), ("MB", 1e6), ("KB", 1e3)):
        if n >= base:
            v = n / base
            return f"{v:.1f} {unit}".replace(".0 ", " ") if v < 10 else f"{round(v)} {unit}"
    return "不到 1 KB"


def _since(at: Optional[str]) -> str:
    """「2023 年 1 月起」"""
    if not isinstance(at, str) or len(at) < 7:
        return ""
    try:
        return f"{int(at[:4])} 年 {int(at[5:7])} 月起"
    except ValueError:
        return ""


# 一个订阅发件人在体检里的哪一组（邮件助手 data/clean subscriptions 的 group），照它排的顺序
SUB_GROUPS = [("unsubscribe", "建议退订"), ("no_way", "无法退订"), ("suspicious", "可疑"), ("handled", "已处理"),
              ("keep", "建议保留")]
# 用户定了的（decision.status）怎么说
DECISION = {"unsubscribed": "已退订", "unsubscribe_opened": "已打开退订网页", "keep": "保留，不再提示",
            "archive_rule": "今后一律归档", "trash_rule": "今后一律删除", "spam_rule": "今后一律移到垃圾邮件", "digest": "已加入精选"}
SUB_ROWS = 20           # 订阅体检一组最多几行：一行十五个组件上下
OLD_ROWS = 25           # 旧邮件一组最多几行：一行十一个上下


def _unsub_confirm(name: str) -> dict:
    return {"title": f"退订「{name}」？", "text": "退订后无法在螺壳中撤销", "label": "退订"}


def _trash_confirm(title: str, mode: Optional[bool] = None) -> dict:
    """移到已删除先问。`mode`：处理模式开没开（读了设置才知道，不知道是 None）"""
    first = {True: "", False: "需先在设置 ·「更多」中开启处理模式。"}.get(mode, "如未开启处理模式，需先在设置 ·「更多」中开启。")
    return {"title": title, "text": first + "邮箱清空「已删除」前可撤销", "label": "移到已删除"}


def _mode(read: Read) -> Optional[bool]:
    d = read(uri("settings")) or {}
    m = (d.get("more") or {}).get("mode_write") if isinstance(d, dict) else None
    return m if isinstance(m, bool) else None


def _check_note(s: Optional[dict]) -> Optional[str]:
    """这次体检本机模型没看完的说明：有 `model_check`（数据）照它写，没有（11-17 以前的体检）用邮件助手的原文 `model_note`"""
    if not s:
        return None
    c = s.get("model_check")
    if isinstance(c, dict) and isinstance(c.get("unchecked"), int) and c["unchecked"] > 0:
        why = {"no_model": "未选择本机模型", "unanswered": "本机模型未给出结果"}.get(c.get("reason")) \
            or _why(c.get("problem_code") or "error")
        return f"{c['unchecked']} 个发件人未经本机模型分析（{why}），建议仅依据收信和阅读情况"
    note = s.get("model_note")
    return note.strip().rstrip("。") if isinstance(note, str) and note.strip() else None


def _subs_of(d: dict) -> Optional[dict]:
    """订阅体检的结果：`subscriptions` 是全部发件人；邮件助手旧一点的只给 `unsubscribe`（都是建议退订的）"""
    if isinstance(d.get("subscriptions"), dict):
        return d["subscriptions"]
    u = d.get("unsubscribe")
    if isinstance(u, dict):
        return dict(u, senders=[dict(s, group=s.get("group") or "unsubscribe") for s in u.get("senders") or []])
    return None


def _unsub_button(kit: PageKit, s: dict, acct: str, primary: bool = False) -> Optional[str]:
    """能在螺壳里一键退订的给「退订」；只能去网页的给「去网页退订」（发信、回信退订的在发件人弹窗里说怎么做）"""
    if s.get("method") == "one_click":
        return kit.button("退订", "mail_unsubscribe", {"account": acct, "key": s["key"]}, icon=None if primary else "mail-x",
                          variant="primary" if primary else "borderless", confirm=_unsub_confirm(_who(s)))
    url = s.get("unsubscribe_url")
    if isinstance(url, str) and url.startswith("https://"):
        # 链接先写明去哪个网站（CLAUDE.md 底线）
        return kit.button(f"前往网页退订（{_host(url)}）", "agent.open_url", {"url": url}, variant="primary" if primary else None)
    return None


def _host(url: str) -> str:
    from urllib.parse import urlsplit
    h = (urlsplit(url).hostname or "").lower()
    return h[4:] if h.startswith("www.") else h or "网页"


# 怎么退订（data/clean 发件人的 method），订阅体检每行第二行写
METHOD = {"one_click": "支持一键退订", "web": "需在网页退订", "body_link": "退订链接在正文中", "mailto": "需发邮件退订",
          "reply": "需回复邮件退订"}


def _sub_row(kit: PageKit, s: dict, account: str) -> str:
    """订阅体检里的一个发件人一行：照它在哪一组给一两个按钮，点这一行打开它能做的全部"""
    acct = s.get("account") or account
    g = s.get("group")
    btns: List[str] = []
    sub = _per(s)
    if g == "unsubscribe":
        sub += "，" + METHOD.get(s.get("method"), "没有退订方式") + ("，点击查看步骤" if s.get("method") in ("mailto", "reply") else "")
        b = _unsub_button(kit, s, acct)
        btns += [b] if b else []
        btns.append(kit.button("保留，不再提示", "mail_sender_keep", {"account": acct, "key": s["key"]}, icon="bell-off",
                               variant="borderless"))
    elif g == "no_way":
        sub += "，没有退订方式"
        btns.append(kit.button("今后一律归档", "mail_sender_rule", {"account": acct, "key": s["key"], "action": "archive"},
                               icon="archive", variant="borderless"))
    elif g == "suspicious":
        sub = "曾发送可疑邮件，" + sub
        btns.append(kit.button("今后一律移到垃圾邮件", "mail_sender_rule", {"account": acct, "key": s["key"], "action": "spam"},
                               icon="shield-alert", variant="borderless"))
    elif g == "handled":
        dec = s.get("decision") or {}
        sub = DECISION.get(dec.get("status"), "已处理") + (f"（{_day(dec.get('at'))}）" if dec.get("at") else "")
        if s.get("still_sending"):
            sub += "，退订后仍在发送"
        btns.append(kit.button("撤销", "mail_sender_reset", {"account": acct, "key": s["key"]}, icon="undo-2",
                               variant="borderless"))
    opened = kit.open_page("这个发件人", "sender", {"account": acct, "key": s["key"]})
    return kit.item(_who(s), sub, btns, open=opened)


def _old_uri(account: str, scope: str, read: Read) -> str:
    """data/old 的地址：一定写邮箱（不写邮件助手答「没有连接这个邮箱」）；收件箱是默认的，不写"""
    return uri("old", account=account, scope=None if scope == "inbox" else scope)


def _old_part(g: dict) -> str:
    """旧邮件的一组在哪一类：留着的、未分析、建议、待确认"""
    if g.get("kept"):
        return "kept"
    if g.get("judged") is False or g.get("kind") == "pending":
        return "pending"
    return "suggested" if g.get("suggested") else "unsure"


def _old_row(kit: PageKit, g: dict, scope: str, mode: Optional[bool] = None) -> str:
    """旧邮件的一组一行：几封、多大、多少没读过、从什么时候起；右边「保留，不再提示」和照这一组的做法（归档、移到已删除）"""
    acct, n = g["account"], int(g.get("count") or 0)
    if g.get("kept"):
        btns = [kit.button("取消保留", "mail_old_keep", {"account": acct, "key": g["key"], "on": False, "scope": scope},
                           icon="undo-2", variant="borderless")]
    else:
        btns = [kit.button("保留，不再提示", "mail_old_keep", {"account": acct, "key": g["key"], "on": True, "scope": scope},
                           icon="bell-off", variant="borderless")]
        name = g.get("name") or g.get("address") or KIND_WORD.get(g.get("kind"), "旧邮件")
        if g.get("action") == "trash":
            btns.append(kit.button("移到已删除", "mail_old_trash", {"account": acct, "scope": scope, "keys": [g["key"]], "count": n},
                                   confirm=_trash_confirm(f"把「{name}」的 {n} 封移到已删除？", mode)))
        else:
            btns.append(kit.button("归档", "mail_old_archive", {"account": acct, "keys": [g["key"]], "count": n},
                                   tooltip=ARCHIVE_TIP))
    # 一组一句：是哪一类、几封、多大。未读几封、从哪年起不影响归不归档，不写（负责人 11-19：说明不把知道的都列上去）
    sub = "，".join(x for x in (KIND_WORD.get(g.get("kind"), ""), f"{n} 封", _size(g.get("size"))) if x)
    return kit.item(g.get("name") or g.get("address") or KIND_WORD.get(g.get("kind"), "旧邮件"), sub, btns)


def _old_bulk(kit: PageKit, groups: List[dict], scope: str, mode: Optional[bool] = None) -> List[str]:
    """建议的几组一次做完：一个邮箱、一种做法一个主按钮（只有一组的不另给，行上就有）"""
    by: Dict[Tuple[str, str], List[dict]] = {}
    for g in groups:
        by.setdefault((g["account"], "trash" if g.get("action") == "trash" else "archive"), []).append(g)
    multi = len({a for a, _ in by}) > 1
    out = []
    for (acct, act), gs in by.items():
        if len(gs) < 2:
            continue
        n = sum(int(g.get("count") or 0) for g in gs)
        keys = [g["key"] for g in gs]
        box = f"（{acct.split('@')[0]}）" if multi else ""
        if act == "trash":
            out.append(kit.button(f"全部移到已删除（{n} 封）{box}", "mail_old_trash",
                                  {"account": acct, "scope": scope, "keys": keys, "count": n}, variant="primary",
                                  confirm=dict(_trash_confirm(f"把这 {len(gs)} 组的 {n} 封移到已删除？"),
                                               text=_old_detail(gs) + _trash_confirm("", mode)["text"])))
        else:
            out.append(kit.button(f"全部归档（{n} 封）{box}", "mail_old_archive", {"account": acct, "keys": keys, "count": n},
                                  variant="primary", confirm={"title": f"归档这 {len(gs)} 组的 {n} 封？",
                                                              "text": _old_detail(gs) + ARCHIVE_TIP, "label": "归档"}))
    return [kit.row(out)] if out else []


ARCHIVE_TIP = "标为已读、移出收件箱，不会删除；能在处理记录里撤销"


def _old_detail(gs: List[dict]) -> str:
    """一次做几组之前先给明细（界面规范 §18.1「重的决定先给明细」）：按分类各几封、几封还没分析、约多大"""
    by: Dict[str, int] = {}
    for g in gs:
        w = KIND_WORD.get(g.get("kind"), "其他")
        by[w] = by.get(w, 0) + int(g.get("count") or 0)
    parts = ["、".join(f"{w} {n} 封" for w, n in sorted(by.items(), key=lambda x: -x[1])[:5])]
    pending = sum(int(g.get("count") or 0) for g in gs if g.get("judged") is False)
    if pending:
        parts.append(f"其中 {pending} 封本机模型尚未分析")
    size = _size(sum(int(g.get("size") or 0) for g in gs))
    if size:
        parts.append(f"约 {size}")
    return "，".join(parts) + "。"


def _judging(o: dict) -> Tuple[bool, bool]:
    """本机模型在不在看旧邮件：（开着，正在跑）。邮件助手旧一点的 data/clean archive 里是一个布尔"""
    j = o.get("judging")
    if isinstance(j, dict):
        return bool(j.get("on")), bool(j.get("running"))
    return bool(j), bool(j)


def _old_progress(kit: PageKit, o: dict, scope: str, multi: bool) -> Optional[str]:
    """没看完的：「看了 x / y 封旧邮件」和暂停、接着看"""
    judged, total = int(o.get("judged") or 0), int(o.get("total") or 0)
    if not total or judged >= total:
        return None
    on, _ = _judging(o)
    flip = kit.button("暂停" if on else "继续", "mail_old_judge", {"account": o["account"], "on": not on, "scope": scope},
                      variant="borderless")
    box = f"（{o['account']}）" if multi else ""         # 写整个地址：@ 前面是一串数字的分不出是哪个邮箱
    judging = o.get("judging") if isinstance(o.get("judging"), dict) else {}
    state = "本机模型分析中" if on else "已暂停，未完成的在「未分析」中"
    why = _why(judging.get("problem_code"), judging.get("problem"))
    if why:
        state = f"已停止：{why}"       # 停下的原因：照代号写，旧的邮件助手没有代号时是它的原文
    return kit.item(f"已分析 {judged} / {total} 封旧邮件{box}", state, [flip])


# 清理页顶上的分段（UX-14）：订阅体检、旧邮件两个平级的视图，各自直接铺开分组，不再先列一部分、再点进弹窗看全部
CLEAN_VIEWS = [("subs", "订阅体检"), ("old", "旧邮件")]


def _clean_views(kit: PageKit, view: str, account: str) -> List[str]:
    go = kit.open_page("切换视图", "clean", {"view": {"path": "/choices/view/0"}, **({} if account == "all" else {"account": account})})
    return [kit.choice("view", CLEAN_VIEWS, view, submit=go)]


def clean(args: Dict[str, str], read: Read) -> List[dict]:
    """清理：顶上分段「订阅体检 / 旧邮件」，两个平级的视图（UX-14），各自就是原来点开的那张弹窗的全部内容，
    直接铺在页上（少套一层弹窗）。订阅体检、旧邮件两张隐藏页照旧在（卡片、旧链接点得进去）"""
    view = args.get("view") if args.get("view") in dict(CLEAN_VIEWS) else "subs"
    return subs(args, read, host="clean") if view == "subs" else old(args, read, host="clean")


def subs(args: Dict[str, str], read: Read, host: str = "subs") -> List[dict]:
    """订阅体检：建议退订、无法退订、可疑、已处理、建议保留几组，一次看一组；每行照组给按钮，
    已处理的能撤回；最下面写哪天检查了多少封，能重新检查。`host`：画在哪一页上，清理页的「订阅体检」分段（UX-14）
    或单独的隐藏页（弹窗，卡片、旧链接点进来的）；切换分组、邮箱都回到这一页"""
    account = args.get("account") or "all"
    d = read(uri("clean", account=account)) or {}
    kit = PageKit(host)
    bad = _problem(kit, d)
    if bad:
        return bad
    view = {"view": "subs"} if host == "clean" else {}
    top: List[str] = _account_switch(kit, host, account, read, {"group": args.get("group") or "unsubscribe", **view})
    if host == "clean":
        top += _clean_views(kit, "subs", account)
    s = _subs_of(d)
    # 现在分析不了的原因；这次体检本机模型没看完的说明（邮件助手的原文）
    top += _status_block(kit, [_model_text(read), _check_note(s)])
    job = _job(kit, read)
    if job:
        top.append(job)
    if s is None:
        top.append(kit.list([kit.item("尚未检查订阅", "检查最近 60 天的订阅邮件，列出可退订的发件人",
                                      [kit.button("检查订阅", "mail_subscriptions_check", {"account": account}, variant="primary")])]))
        return kit.messages(top, refresh=3 if job else None)
    senders = s.get("senders") or []
    counts = {g: sum(1 for x in senders if x.get("group") == g) for g, _ in SUB_GROUPS}
    shown = [g for g, _ in SUB_GROUPS if counts[g]]
    grp = args.get("group") if args.get("group") in shown else (shown[0] if shown else "unsubscribe")
    if shown:
        go = kit.open_page("切换分组", host, {"group": {"path": "/choices/group/0"}, **view,
                                              **({} if account == "all" else {"account": account})})
        top.append(kit.choice("group", [(g, f"{w} {counts[g]}") for g, w in SUB_GROUPS if counts[g]], grp, submit=go))
    mine = [x for x in senders if x.get("group") == grp]
    rows = [_sub_row(kit, x, account) for x in mine[:SUB_ROWS]]
    # 建议退订里一键退订的不止一个、都在一个邮箱：一个主按钮一次做完
    one_click = [x for x in mine if grp == "unsubscribe" and not x.get("decision") and x.get("method") == "one_click"]
    boxes = {x.get("account") or account for x in one_click}
    if len(one_click) > 1 and len(boxes) == 1 and "all" not in boxes:
        rows.append(kit.row([kit.button(f"全部退订（{len(one_click)}）", "mail_unsubscribe",
                                        {"account": boxes.pop(), "keys": [x["key"] for x in one_click]}, variant="primary",
                                        confirm={"title": f"退订这 {len(one_click)} 个发件人？",
                                                 "text": _names(one_click, 5) + "。退订后无法在螺壳中撤销；如需重新订阅，需在对方网站操作",
                                                 "label": "全部退订"})]))
    if rows:
        top.append(kit.list(rows))
        if len(mine) > SUB_ROWS:
            top.append(kit.text(f"还有 {len(mine) - SUB_ROWS} 个未列出，请先处理以上各项", "caption"))
    else:
        top.append(kit.text("订阅邮件已全部检查，暂无待处理项", "caption"))
    when = f"上次检查：{_day(s.get('checked_at'))}"
    big = _size(sum(int(x.get("size") or 0) for x in senders if x.get("group") == "unsubscribe"))
    if big:
        when += f"，建议退订的约占 {big}"
    again = kit.button("重新检查", "mail_subscriptions_check", {"account": account}, icon="refresh-cw", variant="borderless")
    top.append(kit.row([kit.text(when, "caption"), again], justify="spaceBetween"))
    return kit.messages(top, refresh=3 if job else None)


OLD_SCOPES = [("inbox", "收件箱"), ("archive", "已归档")]
OLD_PARTS = [("suggested", "建议"), ("unsure", "待确认"), ("pending", "未分析"), ("kept", "已保留")]


def old(args: Dict[str, str], read: Read, host: str = "old") -> List[dict]:
    """旧邮件：一个邮箱一处（收件箱里的、已归档的）；建议、待确认、未分析、留着的几类，一次看一类；
    建议的一次做完；上面一行写共多少、多大、看了多少，星标和按标签留着的不动；没看完的能暂停、接着看。
    `host`：清理页的「旧邮件」分段（UX-14）或单独的隐藏页（弹窗）；切换都回到这一页"""
    accts = _accounts_of(read)
    account = args.get("account") if any(a["id"] == args.get("account") for a in accts) else (accts[0]["id"] if accts else "")
    scope = args.get("scope") if args.get("scope") in dict(OLD_SCOPES) else "inbox"
    d = read(_old_uri(account, scope, read)) or {}
    kit = PageKit(host)
    bad = _problem(kit, d)
    if bad:
        return bad
    view = {"view": "old"} if host == "clean" else {}
    top: List[str] = []
    if len(accts) > 1:
        go = kit.open_page("切换邮箱", host, {"account": {"path": "/choices/box/0"}, "scope": scope, **view})
        top.append(kit.choice("box", [(a["id"], _box_name(a), None, a["address"]) for a in accts], account,
                              submit=go, placement="header"))
    if host == "clean":
        top += _clean_views(kit, "old", account)
    go = kit.open_page("切换范围", host, {"scope": {"path": "/choices/scope/0"}, "account": account, **view})
    top.append(kit.choice("scope", OLD_SCOPES, scope, submit=go))
    job = _job(kit, read)
    if job:
        top.append(job)
    if not d.get("scanned_at"):
        where = "收件箱中超过保留天数的邮件" if scope == "inbox" else "已归档"
        top.append(kit.list([kit.item(f"尚未检查{where}旧邮件", "仅读取邮件头，完成后按发件人分组并给出清理建议",
                                      [kit.button("开始检查", "mail_old_scan", {"account": account, "scope": scope},
                                                  variant="primary")])]))
        return kit.messages(top, refresh=3 if job else None)
    groups = [dict(g, account=g.get("account") or account) for g in d.get("groups") or []]
    total, judged = int(d.get("total") or 0), int(d.get("judged") or 0)
    held = int(d.get("held") or 0)
    where = f"收件箱中超过 {d['days']} 天的邮件" if scope == "inbox" and d.get("days") else ""
    head = "，".join(x for x in (f"{where}共 {total} 封" if total else "", _size(d.get("size")) and f"占 {_size(d.get('size'))}") if x)
    if held:
        head += f"；星标和按标签保留的 {held} 封不处理"
    if head:
        top.append(kit.text(head, "caption"))
    o = dict(d, account=account)
    extra = []
    p = _old_progress(kit, o, scope, False)
    if p:
        extra.append(p)
    if d.get("stale"):
        extra.append(kit.item("检查后邮箱有变化", None, [
            kit.button("重新检查", "mail_old_scan", {"account": account, "scope": scope}, variant="borderless")]))
    if extra:
        top.append(kit.list(extra))
    counts = {k: sum(1 for g in groups if _old_part(g) == k) for k, _ in OLD_PARTS}
    shown = [k for k, _ in OLD_PARTS if counts[k]]
    part = args.get("part") if args.get("part") in shown else (shown[0] if shown else "suggested")
    words = dict(OLD_PARTS, suggested="建议删除" if scope == "archive" else "建议")
    if shown:
        go = kit.open_page("切换分类", host, {"part": {"path": "/choices/part/0"}, "scope": scope, "account": account, **view})
        top.append(kit.choice("part", [(k, f"{words[k]} {counts[k]}") for k, _ in OLD_PARTS if counts[k]], part, submit=go))
    mine = [g for g in groups if _old_part(g) == part]
    if part == "unsure" and mine:
        top.append(kit.text("可能尚未办结，例如未付的账单、未回复的问题；请确认后再处理", "caption"))
    elif part == "pending" and mine:
        top.append(kit.text("本机模型尚未分析，暂无清理建议", "caption"))
    mode = _mode(read)
    rows = [_old_row(kit, g, scope, mode) for g in mine[:OLD_ROWS]]
    if part == "suggested":
        rows += _old_bulk(kit, mine, scope, mode)
    if rows:
        top.append(kit.list(rows))
        if len(mine) > OLD_ROWS:
            top.append(kit.text(f"还有 {len(mine) - OLD_ROWS} 组未列出，请先处理以上各项", "caption"))
    else:
        top.append(kit.text("暂无可清理的旧邮件", "caption"))
    _, running = _judging(d)
    return kit.messages(top, refresh=3 if job or running else None)


SENDER_RULES = [("archive", "今后一律归档", "archive"), ("trash", "今后一律删除", "trash-2"), ("spam", "今后一律移到垃圾邮件", "shield-alert")]


def _unsub_how(kit: PageKit, s: dict, acct: str) -> List[str]:
    """退订怎么做：一键退订的直接退；去网页、发信、回信退订的写清怎么做，做完点「我退订好了」记下（之后还在发信会标出来）"""
    first: List[str] = []
    b = _unsub_button(kit, s, acct, primary=True)
    if b:
        first.append(b)
    done = kit.button("已完成退订", "mail_sender_unsubscribed", {"account": acct, "key": s["key"]})
    method = s.get("method")
    out: List[str] = []
    if method == "mailto" and isinstance(s.get("mailto"), str) and s["mailto"].startswith("mailto:"):
        to = s["mailto"][7:].split("?")[0]
        out.append(kit.text(f"退订需发送邮件至 {to}", "caption"))
        first.append(done)
    elif method == "reply" and s.get("reply_keyword"):
        out.append(kit.text(f"退订需回复邮件至 {s.get('address') or _who(s)}，正文填写「{s['reply_keyword']}」", "caption"))
        first.append(done)
    elif method in ("web", "body_link") and b:
        if method == "body_link":
            out.append(kit.text("退订链接取自邮件正文，打开后请先确认网址属于该发件人", "caption"))
        first.append(done)
    first.append(kit.button("保留，不再提示", "mail_sender_keep", {"account": acct, "key": s["key"]}))
    return out + [kit.row(first)]


# 订阅体检的结论、本机模型判的内容种类 → 「建议理由」那一行
VERDICT = {"unsubscribe": "收信多、阅读少，可退订", "filter": "收信多、阅读少，无退订方式", "never": "曾发送可疑邮件",
           "keep": "经常阅读", "important": "阅读少，内容建议保留"}
SENDER_KIND = {"marketing": "广告促销", "newsletter": "订阅内容", "notification": "一般通知", "transactional": "账单和交易记录",
               "security": "登录和安全提醒", "personal": "个人或工作往来", "other": "其他"}


def _block_how(kit: PageKit, s: dict, acct: str, read: Read) -> List[str]:
    """在邮箱里屏蔽这个发件人的步骤（data/providers 的 `block`，收起来）：退订后还在发信时给"""
    box = next((a for a in _accounts_of(read) if a.get("id") == acct), None)
    p = next((x for x in _providers(read) if x.get("key") == (box or {}).get("provider")), None)
    block = (p or {}).get("block")
    if not isinstance(block, dict) or not block.get("steps"):
        return []
    lines = [kit.text(f"{i + 1}. {step}", "caption") for i, step in enumerate(block["steps"]) if isinstance(step, str)]
    target = " · ".join(x for x in (s.get("address"), s.get("domain")) if x)
    if target:
        lines.append(kit.text("需填写：" + target, "caption"))
    link = block.get("link") if isinstance(block.get("link"), dict) else None
    if link and str(link.get("url") or "").startswith("https://"):
        lines.append(kit.row([kit.button(link.get("label") or "打开邮箱设置", "agent.open_url", {"url": link["url"]},
                                         icon="square-arrow-out-up-right", variant="borderless")]))
    return [kit.fold(block.get("title") or "在邮箱中屏蔽", lines)]


SENDER_WAIT = 3.0       # data/sender 现去邮箱查历史，邮箱忙时很慢：只等这么久，等不到照体检的结果画


def _within(read: Read, u: str, seconds: float) -> Any:
    """慢的数据只等几秒（核心 `_page_read` 的 `within`）：没等到答 None"""
    f = getattr(read, "within", None)
    return f(u, seconds) if f else read(u)


def sender(args: Dict[str, str], read: Read) -> List[dict]:
    """一个订阅发件人（弹窗，从清理、订阅体检点一行打开）：多少信、多大、最近的主题；定过的写出来、能撤回；
    怎么退订（一键、网页、发信、回信）、保留，不再提示；以后都归档、删除、移到垃圾邮件；加进精选；
    清理历史邮件（先写清邮箱里还有几封、多大，几天后清空）"""
    account, key = args.get("account") or "all", args.get("key") or ""
    kit = PageKit("sender")
    s: Optional[dict] = None
    offline = busy = False
    if account != "all":
        d = _within(read, uri("sender", account=account, key=key), SENDER_WAIT)
        busy = d is None
        d = d or {}
        if isinstance(d, dict) and d.get("key"):
            s = d
        offline = isinstance(d, dict) and isinstance(d.get("error"), dict)
    if s is None:       # 连不上邮箱、邮箱正忙（data/sender 现去邮箱查历史）：照体检的结果画，不写历史有多少
        c = read(uri("clean", account=account)) or {}
        bad = _problem(kit, c)
        if bad:
            return bad
        s = next((x for x in ((_subs_of(c) or {}).get("senders") or []) if x.get("key") == key), None)
    if s is None:
        return kit.messages([kit.text("此发件人已不在订阅体检中", "caption")])
    acct = s.get("account") or account
    name = _who(s)
    top = [kit.text(name, "h4"), kit.text(" · ".join(x for x in (s.get("address"), _per(s), _size(s.get("size"))) if x), "caption")]
    subjects = [x for x in s.get("subjects") or [] if isinstance(x, str) and x][:3]
    if subjects:
        top.append(kit.text("最近的邮件：" + "、".join(f"「{x}」" for x in subjects), "caption"))
    why = " · ".join(x for x in (VERDICT.get(s.get("verdict")), SENDER_KIND.get(s.get("kind"))) if x)
    if why:
        top.append(kit.text("建议理由：" + why, "caption"))
    if s.get("group") == "suspicious":
        top.append(kit.text("该发件人曾发送可疑邮件：请勿点击邮件中的退订链接，建议移到垃圾邮件", "strong"))
    dec = s.get("decision") or {}
    if dec.get("status"):
        what = DECISION.get(dec["status"], "已处理") + (f"（{_day(dec.get('at'))}）" if dec.get("at") else "")
        undo = kit.button("撤销", "mail_sender_reset", {"account": acct, "key": key}, icon="undo-2", variant="borderless")
        top.append(kit.row([kit.text(what, "strong"), undo], justify="spaceBetween"))
        if s.get("still_sending"):
            top.append(kit.text("退订已满两天仍在发送。可设为今后一律删除或移到垃圾邮件", "caption"))
            top += _block_how(kit, s, acct, read)
    elif s.get("group") != "suspicious":
        top += _unsub_how(kit, s, acct)
    top.append(kit.heading("今后的来信"))
    top.append(kit.row([kit.button(label, "mail_sender_rule", {"account": acct, "key": key, "action": a}, icon=icon,
                                   variant="borderless") for a, label, icon in SENDER_RULES]))
    top.append(kit.row([kit.button("加入精选来源", "mail_digest_source",
                                   {"account": acct, "key": key, "on": True, "name": name}, icon="sparkles", variant="borderless")]))
    top.append(kit.heading("以往的来信"))
    hist = s.get("history") if isinstance(s.get("history"), dict) else None
    if hist is not None and not int(hist.get("count") or 0):
        top.append(kit.text("邮箱中已无该发件人的旧邮件", "caption"))
        return kit.messages(top)
    n = int((hist or {}).get("count") or 0)
    # 历史查得怎么样（邮件助手 `history_state`：ready / pending / error；旧一点的没有这个字段，照有没有 `history` 画）
    state = s.get("history_state") if hist is None else "ready"
    if hist is not None:
        days = hist.get("purge_days")
        top.append(kit.text(f"邮箱中还有 {n} 封" + (f"，{_size(hist.get('size'))}" if _size(hist.get('size')) else "") +
                            (f"；移到「已删除」后，邮箱 {days} 天后清空" if isinstance(days, int) and days else ""), "caption"))
    elif state == "pending":        # 邮件助手在后台查（查到的它缓存着，重读不会再发查询）：过几秒再读
        top.append(kit.text("正在统计旧邮件数量", "caption"))
    elif state == "error":
        why = _why(s.get("history_error_code"))
        top.append(kit.text("无法统计旧邮件数量" + (f"：{why}" if why else ""), "caption"))
    elif busy:
        top.append(kit.text("邮箱正忙，旧邮件数量暂未统计", "caption"))
    elif offline:
        top.append(kit.text("暂时无法连接邮箱，无法统计旧邮件数量", "caption"))
    title = f"将「{name}」以往的 {n} 封邮件移到「已删除」？" if n else f"将「{name}」以往的邮件全部移到「已删除」？"
    top.append(kit.row([kit.button("清理历史邮件", "mail_sender_history", {"account": acct, "key": key}, icon="trash-2",
                                   variant="borderless", confirm=_trash_confirm(title, _mode(read)))]))
    return kit.messages(top, refresh=3 if state == "pending" else None)


JOB_KIND = {"sync": "同步新邮件", "subscriptions": "检查订阅", "old_scan": "分析旧邮件", "clean": "清理旧邮件",
            "filter_preview": "预览 Gmail 过滤器"}


def _preview(kit: PageKit, r: dict) -> List[str]:
    """规则预演成 Gmail 过滤器的结果：这条规则过去一年会拦下几封、其中几封看着不该一起处理；放宽的写法各会拦下几封"""
    ways = [w for w in r.get("ways") or [] if isinstance(w, dict)]
    if not ways:
        return [kit.text("此规则在过去一年不会匹配任何邮件", "caption")]
    first = ways[0]

    def risk(w: dict) -> str:
        if not r.get("checked") or not w.get("judged"):
            return ""
        return f"有 {w['risky']} 封可能不应一并处理" if w.get("risky") else "均适用此处理方式"

    out = [kit.text(f"此规则在过去一年会匹配 {int(first.get('count') or 0)} 封", "strong")]
    sub = "，".join(x for x in (f"本机模型分析了其中 {first['judged']} 封" if r.get("checked") and first.get("judged") else "",
                                risk(first)) if x)
    if not r.get("checked"):
        sub = "本机模型暂时不可用，仅统计了封数"
    if sub:
        out.append(kit.text(sub, "caption"))
    ex = [x for x in first.get("examples") or [] if isinstance(x, str) and x][:3]
    if ex:
        out.append(kit.text("例如：" + "、".join(f"「{x}」" for x in ex), "caption"))
    rows = [kit.item(f"{RULE_KIND.get(w.get('kind'), '')} {w.get('value') or ''}".strip(),
                     "，".join(x for x in (f"{int(w.get('count') or 0)} 封", risk(w)) if x), strong=False) for w in ways[1:6]]
    if rows:
        out += [kit.heading("更宽松的条件"), kit.list(rows)]
    return out


def job(args: Dict[str, str], read: Read) -> List[dict]:
    """一个后台任务（弹窗，点了清理旧邮件、预演规则以后打开）：跑着的写进度、能停下，几秒刷新一次；
    跑完的写结果：清理旧邮件移了几封、几封没动成，能撤销整次；预演写会拦下几封"""
    d = read(uri("job", id=args.get("id") or "")) or {}
    kit = PageKit("job")
    if not isinstance(d, dict) or isinstance(d.get("error"), dict) or not d.get("id"):
        return kit.messages([kit.text("找不到此任务，邮件助手可能已重新启动", "caption")])
    kind, status = d.get("kind"), d.get("status")
    top = [kit.text(JOB_KIND.get(kind, "后台任务"), "h4")]
    r = d.get("result") if isinstance(d.get("result"), dict) else {}
    if status == "running":
        done, total = d.get("done"), d.get("total")
        sub = f"{done} / {total}" if isinstance(done, int) and isinstance(total, int) and total else None
        stop = kit.button("停止", "mail_job_stop", {"id": d["id"]}, icon="x", variant="borderless")
        top.append(kit.list([kit.item(_job_name(d), sub, [stop])]))
        return kit.messages(top, refresh=3)
    if status == "error":
        # 照代号写；没有代号时是原文（邮件助手没想到的出错给的是「异常类名: 原文」，类名不上屏）
        err = _why(d.get("error_code"), d.get("error"))
        top.append(kit.text(f"未完成：{err}" if err else "未完成", "caption"))
    elif status == "cancelled":
        top.append(kit.text("已停止，已完成的部分保留", "caption"))
    if kind == "filter_preview" and r:
        top += _preview(kit, r)
    elif kind == "clean" and r:
        moved, stuck = int(r.get("moved") or 0), int(r.get("stuck") or 0)
        top.append(kit.text(f"已移动 {moved} 封", "strong"))
        if stuck:
            top.append(kit.text(f"{stuck} 封未能移动，仍在原处", "caption"))
        if r.get("log_id") is not None and moved:
            top.append(kit.row([kit.button("撤销此次清理", "mail_undo_step", {"account": d.get("account"), "log_id": r["log_id"]},
                                           icon="undo-2")]))
    elif status == "done":
        top.append(kit.text("已完成", "caption"))
    return kit.messages(top)


# 一页最多列几行：一行五六个组件，应用页最多 400 个（a2ui.MAX_PAGE_COMPONENTS）。邮件助手给的处理记录一次最多 200 条，
# 全列出来整页画不了（负责人 11-14 点开「处理记录」只看到「这一页画不了」）
PAGE_ROWS = 40          # 一行八个上下，40 行 330 个左右
BY = {"habit": "按习惯", "rule": "按规则", "own": "螺壳自己的邮箱", "read": "分析后标为已读", "user": "手动",
      "plan": "按卡片方案"}
ACTIVITY_ROWS = 30      # 处理记录一行一个撤销图标、点开看是哪几封，十一个上下
INBOX_ROWS = 14         # 收件箱一行两个图标按钮、去 Gmail 的按钮加打开，二十五个上下
RULE_ROWS = 25          # 规则一行多一个「预演」，下面还有加规则的表单
DIGEST_ROWS = 20        # 精选一行多三个图标按钮和打开，十八个上下


def done(args: Dict[str, str], read: Read) -> List[dict]:
    """一次处理动了哪几封（弹窗，从今日、处理记录点一行打开）：一封一行，发件人、主题、时间，点了打开这封信"""
    account, log_id = args.get("account") or "all", args.get("log_id") or ""
    kit = PageKit("done")
    found: Optional[dict] = None
    for d in (read(uri("today", account=account)) or {}, read(uri("activity", account=account)) or {}):
        items = (d.get("handled") or d.get("items") or []) if isinstance(d, dict) else []
        found = next((h for h in items if str(h.get("log_id")) == log_id), None)
        if found:
            break
    if not found or not found.get("mails"):
        return kit.messages([kit.text("此次处理的邮件已无法列出，仍可在处理记录中撤销", "caption")])
    word = next((KIND_WORD[c] for c in found.get("categories") or [] if c in KIND_WORD), "")
    top = [kit.text(DONE.get(found.get("op"), "已处理 {n} 封{w}").format(n=found.get("count", 0), w=word), "h4")]
    if found.get("at"):
        top.append(kit.text(_when(found["at"]), "caption"))
    rows = []
    for m in found["mails"][:PAGE_ROWS]:
        acct = m.get("account") or found.get("account") or account
        go = kit.open_page("打开邮件", "mail", {"account": acct, "id": str(m.get("id"))})
        rows.append(kit.item(m.get("subject") or "（无主题）", " · ".join(x for x in (_who(m.get("from")), _when(m.get("date"))) if x),
                             [go], open=go))
    top.append(kit.list(rows))
    more = int(found.get("more") or 0)
    if more:
        top.append(kit.text(f"还有 {more} 封未列出", "caption"))
    if found.get("undoable") and not found.get("undone"):
        top.append(kit.row([kit.button("撤销此次处理", "mail_undo_step",
                                       {"account": found.get("account") or account, "log_id": found["log_id"]}, icon="undo-2")]))
    return kit.messages(top)


def activity(args: Dict[str, str], read: Read) -> List[dict]:
    """处理记录（弹窗）：一次处理一行，一个撤销图标；多的翻页（「更早的」）"""
    account = args.get("account") or "all"
    d = read(uri("activity", account=account, cursor=args.get("cursor") or None)) or {}
    kit = PageKit("activity")
    bad = _problem(kit, d)
    if bad:
        return bad
    rows = []
    items = d.get("items") or []
    for it in items[:ACTIVITY_ROWS]:
        ops = it.get("ops") or {it.get("op"): it.get("count", 0)}
        if not any(int(n or 0) > 0 for n in ops.values()):
            continue        # 一封都没动的那一次不列（负责人 11-15：「归档 0 封」是没意义的一行）
        what = " · ".join(f"{WAYS.get(op, op)} {n} 封" for op, n in ops.items() if op and int(n or 0) > 0)
        if it.get("mail"):
            what += f"（{it['mail'].get('subject') or ''}）"
        btns = []
        if it.get("undoable") and not it.get("undone"):
            btns.append(kit.button("撤销", "mail_undo_step", {"account": it.get("account") or account, "log_id": it["log_id"]},
                                   icon="undo-2", variant="borderless"))
        opened = None
        mails = it.get("mails") or []
        if len(mails) == 1 and not it.get("more"):
            opened = kit.open_page("打开邮件", "mail", {"account": mails[0].get("account") or it.get("account") or account,
                                                          "id": str(mails[0].get("id"))})
        elif mails:
            opened = kit.open_page("查看邮件", "done", {"account": it.get("account") or account, "log_id": str(it["log_id"])})
        if opened:
            btns.append(opened)
        # 第二行：谁做的、动了谁的信（旧界面有，负责人 11-15：精简不是删）
        sub = " · ".join(x for x in ("已撤销" if it.get("undone") else "", BY.get(it.get("by"), ""),
                                     "" if it.get("mail") else _names(it.get("senders") or [])) if x)
        rows.append(kit.item(f"{_when(it.get('at'))}　{what}", sub or None, btns, open=opened))
    top = [kit.list(rows)] if rows else [kit.text("暂无处理记录", "caption")]
    # 一页最多 ACTIVITY_ROWS 行：多的从这一页最后一行往前翻（邮件助手的 cursor 是一项的 log_id）
    last = items[ACTIVITY_ROWS - 1]["log_id"] if len(items) > ACTIVITY_ROWS else (d.get("cursor") if d.get("more") else None)
    if last:
        nxt = kit.open_page("更早", "activity", {"cursor": str(last), **({} if account == "all" else {"account": account})},
                            variant="borderless")
        top.append(kit.row([nxt]))
    return kit.messages(top)


SETTINGS_TABS = [("accounts", "账号"), ("rules", "规则"), ("remind", "提醒"), ("more", "更多")]
RULE_ADD_KINDS = [("sender", "发件人是"), ("domain", "发件人域名是"), ("subject", "主题包含"), ("from", "发件人包含")]
RULE_ACTIONS = [("archive", "归档"), ("follow_up", "加星标"), ("ignore", "删除"), ("spam", "移到垃圾邮件"), ("reply", "回复"),
                ("schedule", "加入日程")]
FETCH_DAYS = [("7", "最近 7 天"), ("30", "最近 30 天"), ("90", "最近 90 天"), ("365", "最近一年")]
FETCH_LIMITS = [("50", "每次 50 封"), ("100", "每次 100 封"), ("200", "每次 200 封"), ("500", "每次 500 封")]


def settings(args: Dict[str, str], read: Read) -> List[dict]:
    """设置（弹窗）：账号、规则、提醒、更多四页；账号页写完整地址和可改的显示名；规则页能加规则、导出为 Gmail 过滤器，
    下面是按习惯自动做的；更多里是处理模式、已读、往来邮件、同步范围、署名、从邮件中了解你、你的网站"""
    tab = args.get("tab") if args.get("tab") in dict(SETTINGS_TABS) else "accounts"
    d = read(uri("settings")) or {}
    kit = PageKit("settings")
    bad = _problem(kit, d)
    if bad:
        return bad
    go = kit.open_page("切换分页", "settings", {"tab": {"path": "/choices/tab/0"}})
    top = [kit.choice("tab", SETTINGS_TABS, tab, submit=go)]
    accts = (read(uri("accounts")) or {}).get("accounts") or []
    if tab == "accounts":
        top += _accounts(kit, args, accts, _providers(read))
    elif tab == "rules":
        top += _rules(kit, d, accts)
    elif tab == "remind":
        top += _remind(kit, d)
    else:
        top += _more(kit, d, accts)
    return kit.messages(top)


def _rules(kit: PageKit, d: dict, accts: List[dict]) -> List[str]:
    rows = []
    rules = d.get("rules") or []
    gmails = {a["id"] for a in accts if a.get("provider") == "gmail"}
    rows_by: Dict[str, List[str]] = {}
    for r in rules[:RULE_ROWS]:
        when = f"{RULE_KIND.get(r.get('kind'), '')} {r.get('who') or r.get('value') or ''}".strip()
        drop = kit.button("删除此规则", "mail_rule_delete", {"account": r.get("account"), "id": r["id"]}, icon="trash-2",
                          variant="borderless")
        btns = [drop]
        if r.get("account") in gmails:      # 做成 Gmail 过滤器前先看看会拦下什么（后台跑，跑完换到结果页）
            btns.insert(0, kit.button("预览", "mail_rule_preview", {"account": r["account"], "id": r["id"]}, variant="borderless",
                                      tooltip="预览作为 Gmail 过滤器时，过去一年会匹配的邮件"))
        what = dict(RULE_ACTIONS).get(r.get("action"), WAYS.get(r.get("action"), r.get("action") or ""))
        sub = "，".join(x for x in (f"已使用 {r['hits']} 次" if r.get("hits") else "",
                                    "已导出到 Gmail" if r.get("exported_at") else "") if x)
        rows.append(kit.item(f"{when} → {what}", sub or None, btns))
        rows_by.setdefault(r.get("account") or "", []).append(rows[-1])
    if rows and len(accts) > 1:
        # 几个邮箱：按邮箱分组，小标题是邮箱的显示名（负责人 11-15：看不出每条规则是哪个邮箱的）
        names = {a["id"]: _box_name(a) for a in accts}
        out = []
        for acct_id, mine in rows_by.items():
            out += [kit.heading(names.get(acct_id, acct_id or "其他")), kit.list(mine)]
    elif rows:
        out = [kit.heading("规则"), kit.list(rows)]
    else:
        out = [kit.heading("规则"), kit.list([kit.item("暂无规则", "在收件箱更改邮件的处理方式时，可同时保存为规则", strong=False)])]
    if rows:     # 不然用户以为规则在邮箱里生效。自己一组放在规则后面：放在最前面的一行小字会被窗口当成小标题，把各组并成一张卡片
        out += [kit.heading("生效范围"),
                kit.list([kit.item("规则在螺壳分析新邮件时生效" + ("；导出为 Gmail 过滤器后，由 Gmail 执行" if gmails else ""), None,
                                   strong=False)])]
    if len(rules) > RULE_ROWS:
        out.append(kit.text(f"还有 {len(rules) - RULE_ROWS} 条未列出", "caption"))
    # 加一条：照什么认、认什么、怎么做；几个邮箱时先选哪个邮箱
    if accts:
        kit.data.setdefault("fields", {})["rule_value"] = ""
        form = []
        if len(accts) > 1:
            form.append(kit.choice("rule_box", [(a["id"], _box_name(a)) for a in accts], accts[0]["id"], label="邮箱"))
        box = {"path": "/choices/rule_box/0"} if len(accts) > 1 else accts[0]["id"]
        form += [kit.choice("rule_kind", RULE_ADD_KINDS, "sender", label="匹配条件"),
                 kit.add({"id": kit._id("f"), "component": "TextField", "label": "地址、域名或关键词",
                          "value": {"path": "/fields/rule_value"}}),
                 kit.choice("rule_action", RULE_ACTIONS, "archive", label="处理方式"),
                 kit.row([kit.button("添加规则", "mail_rule_add",
                                     {"account": box, "kind": {"path": "/choices/rule_kind/0"},
                                      "value": {"path": "/fields/rule_value"}, "action": {"path": "/choices/rule_action/0"}})])]
        out.append(kit.fold("添加规则", form))
    gmail = [a for a in accts if a.get("provider") == "gmail"]
    if gmail and rules:
        out.append(kit.row([kit.button(f"导出为 Gmail 过滤器（{_box_name(a)}）" if len(gmail) > 1 else "导出为 Gmail 过滤器",
                                       "mail_gmail_filters", {"account": a["id"]}, icon="file", variant="borderless",
                                       confirm={"title": "导出为 Gmail 过滤器？",
                                                "text": "将保存为一个文件。在 Gmail 设置 ·「过滤器和已屏蔽的地址」中点击「导入过滤器」并选择该文件。"
                                                        "重复导入会产生重复项；在此删除规则不影响 Gmail 中的过滤器",
                                                "label": "导出"})
                            for a in gmail]))
    habits = [h for h in d.get("habits") or [] if h.get("text")]
    if habits:
        out += [kit.heading("按习惯自动处理"), kit.list([kit.item(h["text"], None, strong=False) for h in habits[:PAGE_ROWS]])]
    return out


def _remind(kit: PageKit, d: dict) -> List[str]:
    auto = d.get("auto") or {}
    on = bool(auto.get("enabled"))
    # 打开定时整理之前先把说明给用户看、点了确认才开（邮件助手 agent-data.md）
    sw = kit.button("定时整理", "mail_settings", {"key": "auto_enabled", "value": not on}, variant="switch", on=on,
                    confirm=None if on else {"title": "开启定时整理？", "text": "螺壳将定时在后台读取新邮件并分类：按已确认的习惯归档、标为已读、加标签，"
                                                                                  "均可在处理记录中撤销；不删除、不退订、不发信。有待处理邮件时会提醒", "label": "开启"})
    last = auto.get("last") or {}
    sub = "有待处理邮件时提醒"
    if on and last.get("at"):
        # 上次整理的时间、结果（邮件助手的原文）、几分钟后下一次
        result = str(last.get("text") or "").strip().rstrip("。")
        if not last.get("ok", True) and last.get("problem_code"):
            result = _why(last["problem_code"])              # 没成功的原因照代号写
        sub = f"上次整理：{_when(last['at'])}" + ("" if last.get("ok", True) else "，未成功") + (f"，{result}" if result else "")
        if isinstance(auto.get("next_in_min"), int):
            sub += f" · {auto['next_in_min']} 分钟后下一次"
    rows = [kit.item("定时整理", sub, [sw])]
    stalled = {"removed": "登录项已被移除，定时整理未运行", "moved": "程序位置已变更，定时整理未运行"}.get(auto.get("stalled"))
    if on and stalled:      # 开着却没在跑：再开一次会重新添加登录项
        rows.append(kit.item(stalled, None, [kit.button("重新开启", "mail_settings", {"key": "auto_enabled", "value": True})],
                             strong=False))
    if on and auto.get("intervals"):
        go2 = kit.button("更改间隔", "mail_settings", {"key": "auto_every", "value": {"path": "/choices/every/0"}})
        opts = [(str(n), f"每 {n} 分钟" if n < 60 else f"每 {n // 60} 小时") for n in auto["intervals"]]
        rows.append(kit.row([kit.text("整理间隔"), kit.choice("every", opts, str(auto.get("every") or auto["intervals"][0]),
                                                              label="整理间隔", submit=go2)], justify="spaceBetween"))
    out = [kit.list(rows)]
    if (auto.get("notify") or {}).get("authorization") == "denied":
        out.append(kit.text("系统未允许螺壳发送通知，提醒不会弹出。请在螺壳「设置 · 通用」的「提醒」中开启", "caption"))
    return out


def _switch_row(kit: PageKit, title: str, sub: Optional[str], key: str, on: bool, confirm: Optional[dict] = None) -> str:
    sw = kit.button(title, "mail_settings", {"key": key, "value": not on}, variant="switch", on=on,
                    confirm=confirm if not on else None)
    return kit.item(title, sub, [sw])


def _more(kit: PageKit, d: dict, accts: List[dict]) -> List[str]:
    """更多：处理模式、已读、往来邮件一行一个开关；同步范围两组选项；署名一个框；从邮件中了解你一个开关；你的网站能加能删"""
    more = d.get("more") or {}
    rows = [_switch_row(kit, "处理模式", "批量删除、移到垃圾邮件前需开启；每次操作仍需确认", "mode_write", bool(more.get("mode_write")),
                        {"title": "开启处理模式？", "text": "开启后可一次删除或移动多封邮件，每次操作仍需确认；已删除的邮件在邮箱清空「已删除」前可恢复。"
                                 "归档、标为已读、退订无需开启；螺壳不会发信、转发或永久删除",
                         "label": "开启"}),
            _switch_row(kit, "分析后标为已读", None, "mark_read", more.get("mark_read") is not False),
            _switch_row(kit, "提醒等待对方回复的邮件", "读取「已发送」中最近一个月的邮件，仅在本机分析", "threads", bool(more.get("threads")))]
    first = accts[0]["id"] if accts else None
    learn = more.get("learn") or {}
    if first and isinstance(learn, dict):
        on = bool(learn.get("on"))
        prog = []
        if on and int(learn.get("sent_total") or 0):
            prog.append(f"已读取 {int(learn.get('sent_done') or 0)} / {int(learn['sent_total'])} 封已发送邮件")
        if on and learn.get("learnt"):
            prog.append(f"已记录 {learn['learnt']} 条")
        if on and learn.get("waiting"):
            prog.append(f"{learn['waiting']} 条待确认")
        if on and _why(learn.get("problem_code"), learn.get("problem")):
            prog.append("已停止：" + _why(learn.get("problem_code"), learn.get("problem")))
        rows.append(kit.item("从邮件中学习偏好", " · ".join(prog) or "读取已发送的邮件，记录习惯和关注的事项，仅保存在这台 Mac 上",
                             [kit.button("从邮件中学习偏好", "mail_learn", {"account": first, "on": not on}, variant="switch", on=on)]))
    out = [kit.heading("处理和分析"), kit.list(rows)]       # 第一组也带小标题：不带的话下面几组的小标题分不出卡片
    days = str(more.get("fetch_days") or "30")
    limit = str(more.get("fetch_limit") or "100")
    pick_days = kit.button("更改同步范围", "mail_settings", {"key": "fetch_days", "value": {"path": "/choices/fetch_days/0"}})
    pick_limit = kit.button("更改每次数量", "mail_settings", {"key": "fetch_limit", "value": {"path": "/choices/fetch_limit/0"}})
    day_opts = FETCH_DAYS if any(v == days for v, _ in FETCH_DAYS) else FETCH_DAYS + [(days, f"最近 {days} 天")]
    lim_opts = FETCH_LIMITS if any(v == limit for v, _ in FETCH_LIMITS) else FETCH_LIMITS + [(limit, f"每次 {limit} 封")]
    kit.data.setdefault("fields", {})["signature"] = more.get("signature") or ""
    save_sig = kit.button("保存署名", "mail_settings", {"key": "signature", "value": {"path": "/fields/signature"}})
    # 「保存署名」画在框旁边（不写 submit：写了窗口不画这个按钮，只能回车存）
    sig = kit.add({"id": kit._id("f"), "component": "TextField", "label": "回复草稿末尾的署名（例如：小周）",
                   "value": {"path": "/fields/signature"}})
    out += [kit.heading("同步和回复"),
            kit.column([kit.row([kit.text("同步范围"), kit.choice("fetch_days", day_opts, days, label="同步范围", submit=pick_days)],
                                justify="spaceBetween"),
                        kit.row([kit.text("一次最多"), kit.choice("fetch_limit", lim_opts, limit, label="一次最多", submit=pick_limit)],
                                justify="spaceBetween"),
                        kit.row([sig, save_sig])])]
    sites = [s for s in more.get("sites") or [] if isinstance(s, dict) and s.get("url")]
    if first:
        kit.data["fields"]["site"] = ""
        add = kit.button("添加", "mail_site", {"account": first, "op": "add", "url": {"path": "/fields/site"}})
        field = kit.add({"id": kit._id("f"), "component": "TextField", "label": "网址（https://…）", "value": {"path": "/fields/site"},
                         "submit": add})
        def site_sub(x: dict) -> Optional[str]:
            # 上次打不开的标出来，带邮件助手给的原因（原文）
            why = str(x.get("error") or "").strip().rstrip("。")
            bad = ("上次无法打开" + (f"：{why}" if why and why != "无法打开" else "")) if x.get("problem") else ""
            return " · ".join(v for v in (x["url"] if x.get("title") else "", bad) if v) or None
        rows = [kit.item(s.get("title") or s["url"], site_sub(s),
                         [kit.button("移除此网站", "mail_site", {"account": first, "op": "remove", "id": s.get("id")},
                                     icon="trash-2", variant="borderless")]) for s in sites[:20]]
        out += [kit.heading("个人网站和博客"), kit.fold(f"{len(sites)} 个，用于学习偏好" if sites else "添加发表内容的网站，用于学习偏好",
                                                      ([kit.list(rows)] if rows else []) + [kit.row([field, add])])]
    if more.get("model"):
        out.append(kit.text(f"分析用的本机模型：{more['model']}", "caption"))
    return out


def _secret_field(kit: PageKit, label: str) -> str:
    """密码框（工具协议 §4 secureField）：初值是空的，只随点的那个按钮交一次"""
    kit.data.setdefault("fields", {})["secret"] = ""
    return kit.add({"id": kit._id("f"), "component": "TextField", "label": label, "variant": "obscured",
                    "value": {"path": "/fields/secret"}})


def _field(kit: PageKit, key: str, label: str, value: str = "") -> str:
    kit.data.setdefault("fields", {})[key] = value
    return kit.add({"id": kit._id("f"), "component": "TextField", "label": label, "value": {"path": f"/fields/{key}"}})


def _server_fields(kit: PageKit) -> List[str]:
    """其他邮箱：IMAP 服务器和端口，一个一行（放在一行里服务器的框只有字那么宽）"""
    return [_field(kit, "host", "IMAP 服务器（例如 imap.example.com）"), _field(kit, "port", "端口", "993")]


def _providers(read: Read) -> List[dict]:
    """邮箱类型（邮件助手 0.19.65 的 data/providers）：读不到（旧版本没给）是空的，账号页就不放添加、重新填授权码"""
    try:
        d = read(uri("providers"))
    except Exception:       # 旧版本的邮件助手没有这一样：照旧只列邮箱
        return []
    got = d.get("providers") if isinstance(d, dict) else None
    return [p for p in got or [] if isinstance(p, dict) and isinstance(p.get("key"), str) and isinstance(p.get("name"), str)]


def _words(p: dict, key: str) -> List[str]:
    v = p.get(key)
    return [x for x in v if isinstance(x, str) and x] if isinstance(v, list) else []


def _guide(kit: PageKit, p: dict, authuser: Any, trouble: bool = False) -> List[str]:
    """怎么拿授权码：一步一行，下面是步骤里说的那几个链接（`account` 的带上用户填的地址：`authuser`，
    浏览器里登录了几个账号时打开的才是这一个），再一句补充；`trouble`：连不上时看的几条"""
    out = [kit.text(f"{i}. {s}") for i, s in enumerate(_words(p, "steps"), 1)]
    links = []
    for link in p.get("links") or []:
        if not (isinstance(link, dict) and isinstance(link.get("label"), str) and a2ui.open_url_site(link.get("url"))):
            continue
        ctx: Dict[str, Any] = {"url": link["url"]}
        if link.get("account") is True:
            ctx["authuser"] = authuser
        links.append(kit.button(link["label"], "agent.open_url", ctx, icon="square-arrow-out-up-right", variant="borderless"))
    if links:
        out.append(kit.row(links))
    if isinstance(p.get("notes"), str) and p["notes"]:
        out.append(kit.text(p["notes"], "caption"))
    if trouble and _words(p, "trouble"):
        out += [kit.text("无法连接时：", "caption")] + [kit.text(f"· {t}", "caption") for t in _words(p, "trouble")]
    return out


def _secret(kit: PageKit, p: dict) -> List[str]:
    """密码框和它下面那行小字（照邮箱类型写：Gmail 是「应用专用密码」）"""
    label = p.get("secret_label") if isinstance(p.get("secret_label"), str) and p["secret_label"] else "授权码"
    out = [_secret_field(kit, label)]
    if isinstance(p.get("secret_hint"), str) and p["secret_hint"]:
        out.append(kit.text(p["secret_hint"], "caption"))
    out.append(kit.text(f"{label}只存在这台 Mac 的钥匙串里", "caption"))
    return out


def _form(kit: PageKit, providers: List[dict], picked: str, address: str, back: str, label: str, again: Dict[str, Any],
          key: Optional[str] = None, trouble: bool = False) -> List[str]:
    """添加邮箱、改一个邮箱（`key`）共用的表：邮箱类型（选了就带着 `again` 重取这一页）、地址、其他邮箱的服务器和端口、
    怎么拿授权码、密码框、取消和 `label`。改的时候地址先填好原来的；改了地址，旧地址在本机的数据邮件助手会删掉，所以写一句"""
    kind = next(p for p in providers if p["key"] == picked)
    swap = kit.open_page("切换邮箱类型", "settings", again)
    # 地址先填：步骤里的链接要带上它（打开的是这个地址的账号）；步骤说的「下方」是链接和密码框
    form = [kit.choice("provider", [(p["key"], p["name"]) for p in providers], picked, label="邮箱类型", submit=swap),
            _field(kit, "address", "邮箱地址", address)]
    if key is not None:
        form.append(kit.text("更改地址后，原地址在这台 Mac 上的数据将被删除", "caption"))
    ctx: Dict[str, Any] = {"provider": {"path": "/choices/provider"}, "address": {"path": "/fields/address"},
                           "secret": {"path": "/fields/secret"}}
    if key is not None:
        ctx["key"] = key
    if picked == "custom":
        form += _server_fields(kit)
        ctx.update(host={"path": "/fields/host"}, port={"path": "/fields/port"})
        if key is not None:
            form.append(kit.text("服务器和端口沿用原值；更换服务器需重新填写授权码", "caption"))
    form += _guide(kit, kind, {"path": "/fields/address"}, trouble=trouble)
    return form + _secret(kit, kind) + [kit.row([back, kit.button(label, "mail_connect", ctx)])]


def _accounts(kit: PageKit, args: Dict[str, str], accounts: List[dict], providers: List[dict]) -> List[str]:
    """账号页：每个邮箱写完整地址、可改的显示名、重新填授权码和移除；下面是添加邮箱、全部清除。
    这三样（mail_connect / mail_remove / mail_forget）只在这一页（邮件助手 #106）；移除、清除先问、写明是哪个。
    `edit`：正在重新填授权码的那个邮箱；`add`：在添加邮箱（值是选的邮箱类型）。
    邮箱类型、怎么拿授权码照邮件助手给的（data/providers）；没给的旧版本不放添加和重新填授权码"""
    kinds = {p["key"]: p for p in providers}
    back = kit.open_page("取消", "settings", {"tab": "accounts"}, variant="borderless")
    rows = []
    for a in accounts:
        key = f"name_{len(rows)}"
        kit.data.setdefault("fields", {})[key] = a.get("name") or ""
        # 「保存」画在框旁边（不写 submit：写了窗口就不画这个按钮，只能回车存；负责人 11-15：改完怎么保存没有提示）
        save = kit.button("保存", "mail_set_name", {"account": a["id"], "name": {"path": f"/fields/{key}"}})
        field = kit.add({"id": kit._id("f"), "component": "TextField", "label": "工作、个人……",   # 框里的提示，和左边的「显示为」不重复
                         "value": {"path": f"/fields/{key}"}})
        state = {"needs_auth": "需重新填写授权码", "error": "上次连接失败",
                 "snapshot": "数据快照，仅供查看，不连接邮箱"}.get(a.get("status"))      # 开发实例（邮件 0.19.61）
        if a.get("status") in ("needs_auth", "error") and isinstance(a.get("error_code"), str) and a["error_code"]:
            # 原因照代号写（「上次连接失败：连接邮箱超时」）；要重新填授权码的那两种原因本身就是这句话，不重复
            why = _why(a["error_code"])
            state = why if a["status"] == "needs_auth" else f"上次连接失败：{why}"
        if state is None and a.get("last_sync"):
            state = f"上次同步 {_when(a['last_sync'])}"
        address = a.get("address") or a["id"]
        drop = kit.button("移除", "mail_remove", {"account": a["id"]}, icon="trash-2", variant="borderless",
                          confirm={"title": f"移除 {address}？",
                                   "text": "将删除此邮箱的授权码，以及邮件助手在这台 Mac 上为其保存的列表、规则、清理、精选和处理记录，"
                                           "无法撤销。邮箱中的邮件和记忆不受影响。"
                                           + ("这是唯一已连接的邮箱，定时整理也将关闭" if len(accounts) == 1 else ""),
                                   "label": "移除"})
        btns = [drop]
        if kinds:
            btns.insert(0, kit.open_page("重新填写授权码", "settings", {"tab": "accounts", "edit": a["id"]}, icon="key",
                                         variant="borderless"))
        parts = [kit.item(address, state, btns)]
        parts.append(kit.row([kit.text("显示为", "caption"), field, save]))
        own = bool(a.get("own"))
        parts.append(kit.item("设为螺壳自己的邮箱", "分拣后直接归档、删除，不再确认；仅用于螺壳专用的邮箱",
                              [kit.button("设为螺壳自己的邮箱", "mail_set_own", {"account": a["id"], "own": not own}, variant="switch",
                                          on=own, confirm=None if own else {
                                              "title": f"将 {address} 设为螺壳自己的邮箱？",
                                              "text": "此邮箱中分拣后建议删除的将直接删除、建议归档的直接归档，不再确认；"
                                                      "可疑邮件和待处理邮件保留在收件箱，每封都记入处理记录，可撤销。请勿用于日常邮箱；可随时关闭",
                                              "label": "确认设置"})], strong=False))
        if kinds and args.get("edit") == a["id"]:
            # 照邮件助手自己的「修改邮箱」：类型、地址都能改，地址先填好原来的
            had = a.get("provider") if a.get("provider") in kinds else ("custom" if "custom" in kinds else providers[0]["key"])
            picked = args["kind"] if args.get("kind") in kinds else had
            parts += _form(kit, providers, picked, address, back, "保存",
                           {"tab": "accounts", "edit": a["id"], "kind": {"path": "/choices/provider/0"}},
                           key=a["id"], trouble=a.get("status") in ("needs_auth", "error"))
        rows += [kit.heading(_box_name(a)), kit.column(parts)]
    # 一个邮箱一张卡片，小标题是它的显示名（窗口按小标题分段；负责人 11-15：两个邮箱挤在一张卡片里没有分隔）
    top = rows or [kit.heading("邮箱"), kit.column([kit.text("尚未连接邮箱", "caption")])]

    if kinds and "add" in args:
        picked = args["add"] if args["add"] in kinds else providers[0]["key"]   # 先选上第一个：「选了就换」的按钮要取得到选的值
        form = _form(kit, providers, picked, "", back, "连接", {"tab": "accounts", "add": {"path": "/choices/provider/0"}})
        top += [kit.heading("添加邮箱"), kit.column(form)]
    elif kinds:
        # 自己一组、一整行（不然接在最后一个邮箱的卡片里，像是那个邮箱的按钮）
        go_add = kit.open_page("添加邮箱", "settings", {"tab": "accounts", "add": "new"})
        top += [kit.heading("添加"), kit.list([kit.item("添加邮箱", None, [go_add], open=go_add, strong=False)])]

    if accounts:
        kit.data.setdefault("fields", {})["forget_memory"] = False
        tick = kit.add({"id": kit._id("x"), "component": "CheckBox", "label": "同时清除邮件助手写入记忆的内容",
                        "value": {"path": "/fields/forget_memory"}})
        wipe = kit.button("全部清除", "mail_forget", {"memory": {"path": "/fields/forget_memory"}}, variant="borderless",
                          confirm={"title": "清除邮件助手的全部数据？",
                                   "text": "将从这台 Mac 上删除所有邮箱的授权码、邮件列表、设置、规则和处理记录，无法撤销。"
                                           "邮箱中的邮件不受影响；勾选「同时清除邮件助手写入记忆的内容」时，一并删除邮件助手写入的记忆。",
                                   "label": "全部清除"})
        top += [kit.heading("全部清除"), kit.column([kit.row([tick, wipe], justify="spaceBetween"),
                                                     kit.text("已确认、已修改或手动添加的记忆不会删除", "caption")])]
    return top


def action(name: str, ctx: Dict[str, Any]) -> Tuple[str, Dict[str, Any]]:
    """页上点按交给邮件助手前改形状：选的邮箱类型取第一个；空的服务器、端口、授权码不交（不填就用原来的、照类型的）；
    端口是数就交数；`mail_forget` 的 `memory` 只在勾上（布尔 true）时是 true（邮件助手只认布尔）"""
    if name == "mail_connect":
        out: Dict[str, Any] = {}
        p = ctx.get("provider")
        out["provider"] = p[0] if isinstance(p, list) and p else p
        out["address"] = ctx.get("address").strip() if isinstance(ctx.get("address"), str) else ctx.get("address")
        host = ctx.get("host")
        if isinstance(host, str) and host.strip():
            out["host"] = host.strip()
        port = ctx.get("port")
        if isinstance(port, str) and port.strip():
            out["port"] = int(port.strip()) if port.strip().isdigit() else port.strip()
        if isinstance(ctx.get("secret"), str) and ctx["secret"]:
            out["secret"] = ctx["secret"]
        if ctx.get("key"):
            out["key"] = ctx["key"]
        return name, out
    if name == "mail_forget":
        return name, {"memory": ctx.get("memory") is True}
    if name in ("mail_change", "mail_rule_add", "mail_digest_reading"):
        # 选的值是一列（ChoicePicker）：取第一个；「只这一封」不记成规则（邮件助手只认 sender、domain、list）
        out = {k: (v[0] if isinstance(v, list) and v and k != "ids" else v) for k, v in ctx.items()}
        if out.get("remember") in (None, "none", ""):
            out.pop("remember", None)
        if isinstance(out.get("value"), str):
            out["value"] = out["value"].strip()
        return name, out
    return name, ctx


# 点完以后底部提示的那一句：邮件助手答的几句口语换成书面的；别的照它答的，一句话的去掉句号（负责人：短句不带句号）。
# 还没有照「点的是什么」逐个写（搜索、记忆那样），邮件的动作多，先这样
SAID_REWORDED = {"好的，留着，以后不再问": "已保留，不再提示", "记下了": "已记录", "已改回默认的名字": "已恢复默认名称",
                 "开始同步": "已开始同步", "开始预演": "已开始预演", "草稿已生成": "已生成草稿"}


def said(name: str, ctx: Dict[str, Any], result: dict) -> Optional[str]:
    text = result.get("text")
    if not isinstance(text, str) or not text.strip():
        return None
    t = text.strip()
    one = t[:-1] if t.endswith("。") and "。" not in t[:-1] else t
    return SAID_REWORDED.get(one, one)


def after(name: str, result: dict) -> Optional[dict]:
    """点完换到哪一页：邮箱连上了，或已保存但连不上（邮件助手 0.19.65 的出错带 `saved: true`，邮箱照样留着、列表里写着
    上次没连上），回到账号列表，表单收起来；填得不对（没选类型、地址不对、换了服务器没填授权码）留在表单上改"""
    saved = not result.get("error") or result.get("saved") is True
    if name == "mail_connect" and saved:
        return {"page": "settings", "args": {"tab": "accounts"}}
    if name in JOB_PAGES and isinstance(result.get("job"), str) and not result.get("error"):
        return {"page": "job", "args": {"id": result["job"]}}
    return None


# 点了起一个后台任务、跑完要看结果的（清理旧邮件移了几封、能撤销；预演会拦下几封）：点完换到这个任务的页
JOB_PAGES = frozenset({"mail_old_archive", "mail_old_trash", "mail_rule_preview", "mail_sender_history"})
