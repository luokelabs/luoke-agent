"""一个假的邮件工具：照工具协议报"新邮件""可疑邮件"、出方案、执行、撤销（docs/工具协议.md §10）。
也有协议 §1a 的那几样：概览（`summary`）、两页基础页、权限的状态、打开自己的界面、代你做的事的开关、
有系统弹窗的权限的申请、移除账号；清单里怎么写见 `SERVICE`、`PERMISSIONS`。

数据全是虚构的，只在内存里。给 agent 自己测，也给 luoke-mail 对照答复的样子。

    python3 -m luoke_agent.fake_tool --socket /path/to/agent.sock [--processing-off] [--slow 秒]
"""
from __future__ import annotations

import argparse
import itertools
import signal
import sys
import threading
import time
from typing import Any, Dict, List, Optional

from . import cards
from .mcp import USER_ACTION, ToolError, ToolServer

ACCESSORY = "fake-mail"
MAILBOX = "me@example.com"

ACTION_TEXT = {"archive": "归档", "trash": "移到垃圾箱", "spam": "移到垃圾邮件", "star": "加星标",
               "draft": "写好草稿", "keep": "先不动"}

# 清单 capabilities 里的 service、permissions（协议 §1a）：测试和开发时交给 ToolSource
SERVICE = {
    "summary": True,
    "pages": [{"id": "overview", "title": "概览"}, {"id": "rules", "title": "规则"}],
    "ui": {"open": "mail_ui_open", "pages": [{"id": "accounts", "title": "账号"}]},
    "ask": {"search": "mail_find"},
}
PERMISSIONS = [
    {"id": "fda", "kind": "system", "owner": "luoke", "tcc": "SystemPolicyAllFiles", "title": "完全磁盘访问",
     "facts": ["读邮件 app 存在本机的邮件", "结果不出这台 Mac"], "without": "degrade"},
    {"id": "contacts", "kind": "system", "tcc": "AddressBook", "title": "读通讯录", "request": "mail_request_contacts"},
    {"id": "mailbox", "kind": "account", "title": "邮箱", "page": "accounts", "remove": "mail_disconnect"},
    {"id": "auto", "kind": "delegate", "title": "促销邮件不用点就归档", "on": "mail_auto"},
    {"id": "send", "kind": "each-time", "title": "以你的名义发信"},
]


class FakeMail:
    """一个邮箱的假状态。`processing` 是邮件助手的"处理模式"；`slow` 让写草稿多等几秒。"""

    def __init__(self, *, processing: bool = True, slow: float = 0.0):
        self.processing = processing
        self.slow = slow
        self.lock = threading.Lock()
        self.mails: Dict[str, dict] = {}
        self.items: Dict[str, dict] = {}      # outbox：编号 → 事项（不含卡片）
        self.plans: Dict[str, dict] = {}      # 方案编号 → {item, entries: {key: {mails, allowed}}}
        self.executions: Dict[str, list] = {}  # 执行编号 → [(邮件编号, 原来的状态)]
        self.shown: set = set()
        self.opened: List[str] = []           # 只读的"打开"被调过几次，测试看
        # 协议 §1a：权限的状态（工具自己看到的）、代你做的事的开关
        self.fda = "denied"                   # 清单里登记在螺壳名下：agent 不看这一项，看螺壳.app 报的
        self.contacts = "ask"
        self.mailbox = "granted"
        self.auto = False
        self.page_override: Optional[Any] = None   # 测试用：基础页换成这个（例如画不了的）
        self.page_args: List[dict] = []         # 每次读页带来的参数（协议 §4 pageArgs），测试看
        self.connected: List[bool] = []         # 加邮箱时交来的授权码对不对（协议 §4 secureField；只记对不对）
        self.export_file: Optional[Any] = None  # 测试用：导出规则答复里的 file 换成这个
        self.find_override: Optional[dict] = None  # 测试用：搜索的答复换成这个
        self.finds: List[dict] = []
        self.thumbs: Dict[str, Any] = {}      # 测试用：搜索结果的缩略图 `thumb/<id>` → 图的字节（协议 §1b）
        # 测试用：像 luoke-search 那样同时最多画几张、每张画多久；满了的那张不等，直接答没有
        self.thumb_slots: Optional[threading.Semaphore] = None
        self.thumb_delay = 0.0
        self.thumb_reads: List[str] = []      # 测试看：被读过的缩略图
        self.user_actions: List[dict] = []    # 会改动东西的调用带来的 ai.luoke/user-action，测试看
        self._ids = itertools.count(1)
        self.seed()

    # 造数据

    def _mail(self, sender: str, subject: str, summary: str = "") -> str:
        mid = f"m{next(self._ids)}"
        self.mails[mid] = {"sender": sender, "subject": subject, "summary": summary,
                           "folder": "inbox", "starred": False, "draft": False}
        return mid

    def seed(self) -> None:
        """一批新邮件（3 封要处理 + 4 封打算归档）和 1 封可疑的。"""
        with self.lock:
            need = [
                (self._mail("王老师", "答辩时间确认", "问你下周哪天方便答辩，周五前回"),
                 [("draft", "写草稿"), ("star", "待跟进"), ("keep", "先不动")], "draft"),
                (self._mail("房东李先生", "续租合同", "发来明年的续租合同，请看过后签字"),
                 [("star", "待跟进"), ("archive", "归档"), ("keep", "先不动")], "star"),
                (self._mail("某某航空", "行程单：11 月 2 日 上海—成都", "11 月 2 日 08:30 起飞"),
                 [("archive", "归档"), ("star", "待跟进"), ("keep", "先不动")], "archive"),
            ]
            rest = [self._mail(s, t) for s, t in (("某某周刊", "本周精选"), ("某某银行", "积分活动"),
                                                  ("某某商城", "双十一预告"), ("某某论坛", "你关注的话题有新回复"))]
            self._add_new_mail(need, rest)
            bad = self._mail("service@paypa1-secure.example", "您的账户已被冻结，请立即验证",
                             "冒充支付平台，要你点链接登录")
            self._add_suspicious(bad)

    def _add_new_mail(self, need: list, rest: List[str]) -> None:
        n = len(self.plans) + 1
        plan_id = f"plan-{n}"
        item_id = f"new-mail/{n}/{MAILBOX}"
        entries = {}
        rows = []
        for mid, options, selected in need:
            m = self.mails[mid]
            key = mid
            entries[key] = {"mails": [mid], "allowed": [v for v, _ in options]}
            rows.append({"key": key, "label": f"{m['sender']}：{m['subject']}", "detail": m["summary"],
                         "options": options, "selected": selected})
        if rest:
            entries["rest"] = {"mails": list(rest), "allowed": ["archive", "keep"]}
            rows.append({"key": "rest", "label": f"另外 {len(rest)} 封通知和推广",
                         "options": [("archive", "照建议归档"), ("keep", "先不动")], "selected": "archive"})
        self.plans[plan_id] = {"item": item_id, "entries": entries}
        heads = "；".join(f"{self.mails[mid]['sender']}：{self.mails[mid]['subject']}" for mid, _, _ in need[:2])
        self.items[item_id] = {
            "id": item_id, "kind": "new-mail", "urgency": "normal", "deadline": None, "expires": None,
            "created": time.strftime("%Y-%m-%dT%H:%M:%S%z"),
            "why_now": f"刚到了 {len(need)} 封要你处理的",
            "title": f"{len(need) + len(rest)} 封新邮件，{len(need)} 封要处理",
            "summary": heads + (f"；另外 {len(rest)} 封打算归档。" if rest else "。"),
            "_plan": plan_id, "_rows": rows,
            "_title": f"这 {len(need)} 封要你看，其余打算归档",
        }

    def _add_suspicious(self, mid: str) -> None:
        n = len(self.plans) + 1
        plan_id = f"plan-{n}"
        item_id = f"suspicious/{mid}/{MAILBOX}"
        m = self.mails[mid]
        self.plans[plan_id] = {"item": item_id, "entries": {mid: {"mails": [mid], "allowed": ["spam", "keep"]}}}
        self.items[item_id] = {
            "id": item_id, "kind": "suspicious", "urgency": "urgent", "deadline": None, "expires": None,
            "created": time.strftime("%Y-%m-%dT%H:%M:%S%z"),
            "why_now": "像是钓鱼邮件，别点里面的链接",
            "title": "一封可疑邮件",
            "summary": f"{m['sender']}：{m['subject']}",
            "_plan": plan_id,
            "_rows": [{"key": mid, "label": f"{m['sender']}：{m['subject']}", "detail": m["summary"],
                       "options": [("spam", "移到垃圾邮件"), ("keep", "先不动")], "selected": "spam"}],
            "_title": "这封像是钓鱼邮件",
        }

    def ask_access(self, permission: str) -> str:
        """用到才要（协议 §1a）：在 outbox 报一件 needs-access。"""
        item_id = f"needs-access/{permission}"
        card = cards.Card(f"access-{permission}")
        card.text(f"要用到「{permission}」这项权限，得先有你的允许。")
        card.buttons(cards.button("打开设置", "mail_open_settings", primary=True))
        with self.lock:
            self.items[item_id] = {
                "id": item_id, "kind": "needs-access", "urgency": "low", "permission": permission,
                "deadline": None, "expires": None, "created": time.strftime("%Y-%m-%dT%H:%M:%S%z"),
                "why_now": "要用到了", "title": "需要你允许", "summary": "给了以后能多做一些。",
                "_card": card.messages(),
            }
        return item_id

    # 协议

    def outbox(self) -> dict:
        with self.lock:
            out = []
            for it in self.items.values():
                pub = {k: v for k, v in it.items() if not k.startswith("_")}
                pub["card"] = it.get("_card") or cards.plan_card(
                    it["_plan"], it["_title"], it["_rows"], apply_event="mail_apply_plan", plan_id=it["_plan"],
                    apply_label="按选的处理",
                    extra_buttons=[cards.button("在邮件助手里看", "mail_open", {"plan_id": it["_plan"]})])
                out.append(pub)
            return {"items": out}

    def summary(self) -> dict:
        with self.lock:
            n = sum(1 for it in self.items.values() if it["kind"] != "needs-access")
        return {"count": n, "text": f"{n} 件等你处理" if n else "没有要你处理的"}

    def permission_states(self) -> dict:
        with self.lock:
            return {"fda": self.fda, "contacts": self.contacts, "mailbox": self.mailbox,
                    "auto": "on" if self.auto else "off", "send": "ask"}

    def page(self, page_id: str, args: Optional[dict] = None) -> Any:
        self.page_args.append(dict(args or {}))
        if self.page_override is not None:
            return self.page_override
        card = cards.Card(page_id)
        with self.lock:
            if page_id == "overview":
                n = len(self.items)
                card.heading("邮件助手")
                card.text(f"{n} 件等你处理" if n else "没有要你处理的")
                card.text("促销邮件：" + ("不用点就归档" if self.auto else "先问你"), caption=True)
                card.buttons(cards.button("以后先问我" if self.auto else "以后不用点就归档", "mail_auto", {"on": not self.auto}),
                             cards.button("打开设置", "mail_open_settings"),
                             cards.open_url_button("帮助", "https://help.example.com/mail"))
            else:
                card.heading("规则")
                q = (args or {}).get("q")
                if q:
                    card.text(f"搜「{q}」")
                card.text("某某商城的促销：归档")
        return card.messages()

    def _record(self, meta: dict) -> None:
        self.user_actions.append(dict(meta.get(USER_ACTION) or {}))

    def ui_open(self, args: dict, meta: dict) -> dict:
        page = args.get("page")
        if page not in (None, "accounts"):
            raise ToolError("invalid", "没有这一页。")
        self.opened.append(f"ui:{page or ''}")
        return {"text": "（假工具）这里会打开邮件助手的窗口。"}

    def set_auto(self, args: dict, meta: dict) -> dict:
        on = args.get("on")
        if not isinstance(on, bool):
            raise ToolError("invalid", "on 要是真或假")
        self._record(meta)
        with self.lock:
            self.auto = on
        text = "好，以后促销邮件不用点就归档，每次都告诉你。" if on else "好，以后促销邮件都先问你。"
        surface = (meta.get(USER_ACTION) or {}).get("surfaceId")
        return {"text": text, "card": cards.result_card(surface, text)} if isinstance(surface, str) else {"text": text}

    def request_contacts(self, args: dict, meta: dict) -> dict:
        self._record(meta)
        with self.lock:
            self.contacts = "granted"           # 假装系统弹了框、用户点了允许
        return {"text": "（假工具）系统问过了，你允许了读通讯录。"}

    def disconnect(self, args: dict, meta: dict) -> dict:
        self._record(meta)
        with self.lock:
            self.mailbox = "ask"
        return {"text": f"移除了 {MAILBOX}。"}

    def ack(self, args: dict, meta: dict) -> dict:
        state = args.get("state")
        if state not in ("shown", "answered", "dismissed"):
            raise ToolError("invalid", "state 只能是 shown、answered、dismissed")
        with self.lock:
            if state == "shown":
                self.shown.add(args["id"])
            else:
                self.items.pop(args["id"], None)
        return {"text": "好的"}

    def apply_plan(self, args: dict, meta: dict) -> dict:
        plan_id = args["plan_id"]
        choices = args.get("choices")
        if not isinstance(choices, dict):
            raise ToolError("invalid", "choices 要是对象")
        with self.lock:
            plan = self.plans.get(plan_id)
            if plan is None:
                raise ToolError("stale", "这批邮件已经处理过了。")
            if not self.processing:
                # 卡片照旧，加一句说明和"打开设置"；不替用户去开（§5）
                it = self.items[plan["item"]]
                card = cards.plan_card(
                    plan_id, it["_title"], it["_rows"], apply_event="mail_apply_plan", plan_id=plan_id,
                    apply_label="按选的处理", note="先在邮件助手的设置里开启处理模式，再回来点。",
                    extra_buttons=[cards.button("打开设置", "mail_open_settings")],
                    update=True, id_prefix=f"s{next(self._ids)}-")
                raise ToolError("needs_setup", "先在邮件助手的设置里开启处理模式。", card=card)
            picked: Dict[str, str] = {}
            for key, entry in plan["entries"].items():
                v = choices.get(key, [entry["allowed"][0]])
                if not isinstance(v, list) or len(v) != 1 or v[0] not in entry["allowed"]:
                    raise ToolError("invalid", "选项不在卡片给出的范围里。")
                picked[key] = v[0]
            unknown = set(choices) - set(plan["entries"])
            if unknown:
                raise ToolError("invalid", "选项不在卡片给出的范围里。")
        if self.slow and "draft" in picked.values():
            time.sleep(self.slow)  # 假装用模型写草稿
        with self.lock:
            if plan_id not in self.plans:
                raise ToolError("stale", "这批邮件已经处理过了。")
            done: Dict[str, int] = {}
            missing = 0
            undo = []
            for key, action in picked.items():
                for mid in self.plans[plan_id]["entries"][key]["mails"]:
                    m = self.mails[mid]
                    if action == "keep":
                        continue
                    if m["folder"] != "inbox":
                        missing += 1
                        continue
                    undo.append((mid, dict(m)))
                    if action in ("archive", "trash", "spam"):
                        m["folder"] = {"archive": "archive", "trash": "trash", "spam": "spam"}[action]
                    elif action == "star":
                        m["starred"] = True
                    elif action == "draft":
                        m["draft"] = True
                    done[action] = done.get(action, 0) + 1
            del self.plans[plan_id]
            self.items.pop(plan["item"], None)
            exec_id = f"exec-{next(self._ids)}"
            self.executions[exec_id] = undo
        parts = [f"{ACTION_TEXT[a]} {n} 封" for a, n in done.items()]
        text = ("已" + "、".join(parts) + "。") if parts else "都先不动。"
        if missing:
            text += f"有 {missing} 封已经不在收件箱里，没动它们。"
        card = cards.result_card(plan_id, text, undo_event="mail_undo" if undo else None,
                                 undo_context={"execution_id": exec_id})
        return {"text": text, "card": card, "done": True, "execution_id": exec_id}

    def undo(self, args: dict, meta: dict) -> dict:
        with self.lock:
            steps = self.executions.pop(args["execution_id"], None)
            if steps is None:
                raise ToolError("stale", "这次处理已经撤销过了。")
            for mid, before in reversed(steps):
                self.mails[mid] = before
        text = f"已撤销，{len(steps)} 封回到原来的样子。"
        out: Dict[str, Any] = {"text": text, "done": True}
        surface = (meta.get(USER_ACTION) or {}).get("surfaceId")  # 用户在哪张卡片上点的（工具自己的编号）
        if isinstance(surface, str):
            out["card"] = cards.result_card(surface, text)
        return out

    def open_mail(self, args: dict, meta: dict) -> dict:
        self.opened.append(str(args.get("plan_id")))
        return {"text": "（假工具）这里会在邮件助手里打开这批邮件。"}

    def thumb(self, ref: str) -> Any:
        """缩略图 `thumb/<id>`（协议 §1b）。给了 `thumb_slots` 时像 luoke-search：画满了的不等，答没有。"""
        self.thumb_reads.append(ref)
        slots = self.thumb_slots
        if slots is not None and not slots.acquire(blocking=False):
            return None
        try:
            if self.thumb_delay:
                time.sleep(self.thumb_delay)
            return self.thumbs.get(ref)
        finally:
            if slots is not None:
                slots.release()

    def find(self, args: dict, meta: dict) -> dict:
        """协议 §1b 的搜索：一条结果和一张带「打开」的卡片。"""
        self.finds.append(dict(args))
        if self.find_override is not None:
            return self.find_override
        card = cards.Card("find")
        card.text("某某商城的账单")
        card.buttons(cards.button("打开", "mail_open", {"plan_id": "found"}))
        return {"text": "找到 1 封。", "hits": [{"id": "found", "title": "某某商城的账单"}], "card": card.messages()}

    def open_settings(self, args: dict, meta: dict) -> dict:
        self.opened.append("settings")
        return {"text": "（假工具）这里会打开邮件助手的设置。"}

    def connect(self, args: dict, meta: dict) -> dict:
        """加邮箱（协议 §4 secureField）：授权码只用来核对，不记、不写回。"""
        self._record(meta)
        ok = args.get("code") == "abcd-efgh"
        self.connected.append(ok)
        if not ok:
            raise ToolError("failed", "授权码不对。")
        return {"text": "邮箱加上了。"}

    def export_rules(self, args: dict, meta: dict) -> dict:
        """导出规则（协议 §4 saveFile）：答复里带一个文件，窗口弹出存文件的框。"""
        f = self.export_file if self.export_file is not None else {
            "name": "gmail-filters.xml", "mediaType": "application/xml",
            "text": "<?xml version='1.0' encoding='UTF-8'?><feed><entry/></feed>"}
        return {"text": "规则文件好了，选个位置存。", "file": f}

    def server(self) -> ToolServer:
        s = ToolServer(ACCESSORY, "0")
        s.resource(f"luoke://{ACCESSORY}/outbox", self.outbox, name="要报的事")
        s.tool("outbox_ack", self.ack, title="记下 agent 说过了",
               input_schema={"type": "object", "required": ["id", "state"],
                             "properties": {"id": {"type": "string"},
                                            "state": {"enum": ["shown", "answered", "dismissed"]}}})
        s.tool("mail_apply_plan", self.apply_plan, title="按方案处理邮件", read_only=False,
               input_schema={"type": "object", "required": ["plan_id", "choices"],
                             "properties": {"plan_id": {"type": "string"}, "choices": {"type": "object"}}})
        s.tool("mail_undo", self.undo, title="撤销刚才的处理", read_only=False,
               input_schema={"type": "object", "required": ["execution_id"],
                             "properties": {"execution_id": {"type": "string"}}})
        s.tool("mail_open", self.open_mail, title="在邮件助手里看",
               input_schema={"type": "object", "properties": {"plan_id": {"type": "string"}}})
        s.tool("mail_open_settings", self.open_settings, title="打开邮件助手的设置")
        # 协议 §1a
        s.resource("summary", self.summary, name="概览")
        s.resource("permissions", self.permission_states, name="权限的状态")
        for p in SERVICE["pages"]:
            s.resource(f"page/{p['id']}", lambda a, pid=p["id"]: self.page(pid, a), name=p["title"], args=True)
        s.tool("mail_connect", self.connect, title="加邮箱", read_only=False,
               input_schema={"type": "object", "required": ["code"], "properties": {"code": {"type": "string"}}})
        s.tool("mail_export_rules", self.export_rules, title="把规则导出成 Gmail 过滤器")
        s.tool("mail_find", self.find, title="搜索邮件",
               input_schema={"type": "object", "properties": {"query": {"type": "string"}, "limit": {"type": "integer"}}})
        for i in range(1, 7):
            s.resource(f"thumb/{i}", lambda ref=f"thumb/{i}": self.thumb(ref), name="缩略图", mime_type="image/png")
        s.tool("mail_ui_open", self.ui_open, title="打开邮件助手的窗口",
               input_schema={"type": "object", "properties": {"page": {"type": "string"}}})
        s.tool("mail_auto", self.set_auto, title="开或关促销邮件不用点就归档", read_only=False,
               input_schema={"type": "object", "required": ["on"], "properties": {"on": {"type": "boolean"}}})
        s.tool("mail_request_contacts", self.request_contacts, title="请系统给读通讯录的权限", read_only=False)
        s.tool("mail_disconnect", self.disconnect, title="移除邮箱", read_only=False)
        return s


def main(argv: Optional[List[str]] = None) -> int:
    p = argparse.ArgumentParser(prog="python3 -m luoke_agent.fake_tool", description=__doc__.splitlines()[0])
    p.add_argument("--socket", required=True, help="在哪个 Unix socket 上服务（必填，不用默认位置）")
    p.add_argument("--processing-off", action="store_true", help="假装处理模式没开：执行时答 needs_setup")
    p.add_argument("--slow", type=float, default=0.0, help="写草稿时多等几秒")
    a = p.parse_args(argv)
    fake = FakeMail(processing=not a.processing_off, slow=a.slow)
    server = fake.server().start(a.socket)
    stop = threading.Event()
    for sig in (signal.SIGINT, signal.SIGTERM):
        signal.signal(sig, lambda *_: stop.set())
    print(f"假的邮件工具在 {a.socket}（{ACCESSORY}）", file=sys.stderr)
    try:
        stop.wait()
    finally:
        server.close()
    return 0


if __name__ == "__main__":
    sys.exit(main())
