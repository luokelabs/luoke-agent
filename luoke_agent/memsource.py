"""记忆这一路（DESIGN §2）：读记忆给的清单（想问的、建议），画成卡片，依据的原文直接放在卡片上；
把用户的回答交回 luoke_mem。

用自带的一份 luoke_mem（vendor/，scripts/vendor-luoke-mem.sh 拷的），工具标识 `luoke-agent`。
记忆文件不存在就什么都不做，绝不替它建一个。
"""
from __future__ import annotations

import os
import subprocess
import sys
from typing import Any, Callable, Dict, List, Optional

from . import cards
from .cards import Card, button
from .items import Item
from .safety import refuse_real

VENDOR = os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))), "vendor")

CITES_SHOWN = 3                      # 卡片上直接给几条依据原文（顶层 ADR 0013）
CITE_CHARS = 120
CHANGED = "这条已经变了（可能已经生效，或者在别处答过了）。"
NOT_KEPT = "记忆不保存密码、验证码和证件号码，改一下再点。"
SAID = {"yes": "记下了：对。", "no": "记下了：不对，以后不再提。", "past": "记下了：以前是，现在不是。", "revise": "改好了。", "later": "好，过几天再问。",
        "answer": "记下了。", "useful": "好。", "useless": "好，这阵子不再提。", "never": "好，不再提这个。",
        "archive": "归档了：不算回答，也不会自己再问。"}
CANT_ARCHIVE = "这一版的螺壳记忆还不能归档，先不答就行。"


_from_hub: Optional[str] = None    # 主控带的那份 luoke_mem 所在的目录（use_hub_luoke_mem 设）


def use_hub_luoke_mem(path: Optional[str]) -> Optional[str]:
    """进程起来时、第一次 import 之前调一次：用主控带的那份 luoke_mem（主控 GET /tasks 报的位置，每次新起进程都问，
    不缓存）。那份不在、导不进来就退回自带的。返回实际用的那份的版本，用自带的返回 None。"""
    global _from_hub
    if not path or not os.path.isfile(os.path.join(path, "luoke_mem", "__init__.py")) or "luoke_mem" in sys.modules:
        return None
    sys.path.insert(0, path)
    try:
        import luoke_mem
    except Exception:    # 主控那份坏了：清掉，用自带的
        sys.path.remove(path)
        for name in [m for m in sys.modules if m == "luoke_mem" or m.startswith("luoke_mem.")]:
            del sys.modules[name]
        return None
    _from_hub = path
    return str(getattr(luoke_mem, "__version__", "?"))


def load_luoke_mem() -> Any:
    """主控带的那份（use_hub_luoke_mem 设过的话），不然用自带的；不用别处装的。"""
    if _from_hub is None and VENDOR not in sys.path:
        sys.path.insert(0, VENDOR)
    import luoke_mem
    return luoke_mem


def open_memory_app(note: Optional[int]) -> bool:
    """正式版：打开记忆，定位到这条。用主控注册的 `luoke://memory?note=N`；还没有处理它的（旧的主控）
    就退回单独的螺壳记忆.app。"""
    query = f"?note={int(note)}" if note else ""
    if subprocess.run(["open", "luoke://memory" + query], check=False, timeout=10, capture_output=True).returncode == 0:
        return True
    extra = ["--note", str(note)] if note else []
    args = ["open", "-b", "ai.luoke.memory"] + (["--args"] + extra if extra else [])
    return subprocess.run(args, check=False, timeout=10, capture_output=True).returncode == 0


def memory_ui_opener(path: str) -> Callable[[Optional[int]], bool]:
    """开发、测试用的记忆文件：不打开日常在用的螺壳记忆。agent 只带工具用的三个模块，没有记忆的页面；
    要看这份临时记忆，在 luoke-mem 仓库里跑 `python3 -m luoke_mem ui --path <文件> --open`。"""
    def opener(note: Optional[int]) -> bool:
        print(f"luoke-agent（开发）：在螺壳记忆里看——这份记忆的页面请用 luoke-mem 的 ui 命令打开（理解 {note}）",
              file=sys.stderr)
        return False
    return opener


class MemorySource:
    source = "memory"

    def __init__(self, path: str, state: Any, *, opener: Optional[Callable[[Optional[int]], Optional[bool]]] = None,
                 names: Optional[Dict[str, str]] = None):
        refuse_real(path, "记忆")
        self.path = path
        self.state = state
        self.opener = opener or memory_ui_opener(path)
        lm = load_luoke_mem()
        self.labels = {"memory:question": "记忆想问的事", "memory:suggestion": "记忆的建议"}
        self.kind_names = dict(lm.KIND_NAMES)              # 类别和工具的显示名只有一份，在 luoke_mem（0.15.4）
        self.names = dict(lm.TOOL_NAMES, **(names or {}))
        self.status = "missing"   # missing 还没有记忆 / ok / too_new 记忆比自带的库新 / error
        self._mem: Any = None

    def _open(self) -> Any:
        if self._mem is not None:
            return self._mem
        if not os.path.exists(self.path):
            self.status = "missing"
            return None
        lm = load_luoke_mem()
        try:
            self._mem = lm.Memory(self.path, tool="luoke-agent")
        except lm.TooNew:
            self.status = "too_new"
            return None
        self.status = "ok"
        return self._mem

    def close(self) -> None:
        if self._mem is not None:
            self._mem.db.close()
            self._mem = None

    # 读

    def poll(self, now: float) -> Optional[List[Item]]:
        mem = self._open()
        if mem is None:
            return None            # 暂时读不到不等于记忆把这些撤了：卡片收起，状态不动
        # 只读记忆给的清单（顶层 ADR 0015）：想问的（question）和建议（suggestion），该不该问、每天几条都由记忆定
        # "以后再说"之后什么时候再问也由记忆定（它把这条收起，过 7 天作为新的一条再问）
        # 归档（luoke_mem 0.34 起有 Memory.archive）：先收起来、不作答；更早的记忆没有，卡片上就不给这个按钮
        archivable = hasattr(mem, "archive")
        return [self._ask_item(a, self._cites(mem, a.get("about_note")), archivable) for a in mem.asks(status=["open"])]

    def _cites(self, mem: Any, note: Optional[int]) -> List[str]:
        """这条理解的依据原文，新的在前，最多几条：谁、哪天、原话（顶层 ADR 0013：本机里不再按工具藏）。"""
        if not note:
            return []
        n = mem.note(int(note))
        if not n:
            return []
        out = []
        for c in (n.get("cites") or [])[:CITES_SHOWN]:
            text = " ".join(str(c.get("text") or "").split())
            if len(text) > CITE_CHARS:
                text = text[:CITE_CHARS] + "…"
            if text:
                out.append(f"{self._who(c.get('tool', ''))} · {str(c.get('happened_at') or '')[:10]}：{text}")
        return out

    def _who(self, tool: str) -> str:
        return self.names.get(tool, tool)

    def _ask_item(self, a: dict, cites: List[str] = (), archivable: bool = False) -> Item:
        aid = a["id"]
        question = a["kind"] == "question"
        answer = a.get("answer") or {"type": "text"}
        note = a.get("about_note")
        card = Card(f"ask-{aid}")
        card.heading("记忆想问你" if question else "记忆有个建议")
        card.text(a["text"])
        if a.get("why"):
            card.text(a["why"])                     # 真正的理由：哪里不确定、确认了有什么用（记忆给）
        if cites:                                   # 依据的原文直接给（顶层 ADR 0013）
            card.text("依据", caption=True)
            for c in cites:
                card.text(c, caption=True)
        elif a.get("evidence"):
            card.text(f"依据：{a['evidence']}", caption=True)
        look = [button("在螺壳记忆里看", "mem.open", {"note": note})] if note else []
        if archivable:   # 每种卡片最后一个，不带边框：不算回答，不是「以后再说」也不是「别再提」（luoke_mem 0.34）
            look.append(button("归档", "mem.reply", {"ask": aid, "choice": "archive"}, variant="borderless"))
        if not question:                            # 建议（含处理习惯）：agent 不动手，执行是工具的事
            habit = ((a.get("action") or {}).get("capability") == "habit")
            if answer.get("type") == "yes_no" or habit:   # 例如"以后 X 都归档？"：好 / 不用 / 别再提
                card.buttons(button("好", "mem.reply", {"ask": aid, "choice": "useful"}, primary=True),
                             button("不用", "mem.reply", {"ask": aid, "choice": "useless"}),
                             button("别再提", "mem.reply", {"ask": aid, "choice": "never"}), *look)
            else:                                    # 信息性的
                card.buttons(button("知道了", "mem.reply", {"ask": aid, "choice": "useful"}, primary=True),
                             button("别再提", "mem.reply", {"ask": aid, "choice": "never"}), *look)
        elif note:                                  # 问一条猜测：回答直接给那条理解定档（luoke-mem reply）
            card.text_field("revise", "不太对的话，改成")
            card.buttons(button("对", "mem.reply", {"ask": aid, "choice": "yes"}, primary=True),
                         button("不对", "mem.reply", {"ask": aid, "choice": "no"}),
                         button("以前是，现在不是", "mem.reply", {"ask": aid, "choice": "past"}),
                         button("按我改的", "mem.reply", {"ask": aid, "choice": "revise", "text": {"path": "/fields/revise"}}),
                         button("以后再说", "mem.reply", {"ask": aid, "choice": "later"}), *look)
        elif answer.get("type") == "choice" and answer.get("options"):
            opts = [str(o) for o in answer["options"]]
            card.choice("reply", "选一个", [(o, o) for o in opts], opts[0])
            card.buttons(button("交回", "mem.reply", {"ask": aid, "choice": "answer", "text": {"path": "/choices/reply"}},
                                primary=True), button("以后再说", "mem.reply", {"ask": aid, "choice": "later"}), *look)
        elif answer.get("type") == "yes_no":
            card.buttons(button("是", "mem.reply", {"ask": aid, "choice": "answer", "text": "是"}, primary=True),
                         button("不是", "mem.reply", {"ask": aid, "choice": "answer", "text": "不是"}),
                         button("以后再说", "mem.reply", {"ask": aid, "choice": "later"}), *look)
        else:
            card.text_field("reply", "你的回答")
            card.buttons(button("交回", "mem.reply", {"ask": aid, "choice": "answer", "text": {"path": "/fields/reply"}},
                                primary=True), button("以后再说", "mem.reply", {"ask": aid, "choice": "later"}), *look)
        urgency = a.get("urgency") if a.get("urgency") in ("urgent", "normal", "low") else "low"
        return Item(key=f"memory/ask/{aid}", source="memory", kind=a["kind"], urgency=urgency,
                    title=("记忆想问：" if question else "记忆建议：") + a["text"][:100], summary=a.get("why") or "",
                    why_now=a.get("why") or "不急，有空看看", card=card.messages(), created=a.get("created_at"),
                    expires=a.get("expires_at"), extra={"ask": aid, "note": note, "archive": archivable})

    # 交回

    def handle(self, item: Item, name: str, ctx: dict, now: float) -> Dict[str, Any]:
        mem = self._open()
        if mem is None:
            return {"text": "螺壳记忆现在打不开。", "error": True}
        lm = load_luoke_mem()
        sid = item.card and item.card[0]["createSurface"]["surfaceId"]
        try:
            if name == "mem.open":
                note = ctx.get("note")
                if self.opener(int(note) if note else None) is False:
                    return {"text": "开发版没有打开螺壳记忆（这是一份临时记忆）。"}
                return {"text": "在螺壳记忆里打开了。"}
            if name == "mem.reply":
                aid = int(ctx["ask"])
                if aid != item.extra.get("ask"):
                    return {"text": "这张卡片上没有这个问题。", "error": True}
                choice = str(ctx.get("choice") or "")
                text = ctx.get("text")
                text = text[0] if isinstance(text, list) and text else text
                text = " ".join(str(text or "").split()) or None
                allowed = ({"useful", "useless", "never"} if item.kind == "suggestion" else
                           {"yes", "no", "past", "revise", "later"} if item.extra.get("note") else {"answer", "later"})
                if item.extra.get("archive"):       # 只有画了「归档」的卡片才认
                    allowed = allowed | {"archive"}
                if choice not in allowed:
                    return {"text": "不认识这个回答。", "error": True}
                if choice == "archive" and not hasattr(mem, "archive"):   # 画卡片以后换成了更早的记忆
                    return {"text": CANT_ARCHIVE, "error": True}
                if choice in ("revise", "answer") and not text:
                    return {"text": "先在上面写好。", "error": True}
                try:
                    self._reply(mem, item, choice, text)
                except ValueError:
                    if choice == "later" and not item.extra.get("note"):   # 主控带的 luoke_mem 0.23.4 以前不收
                        return {"text": "这个问题现在还不能往后放，先不答就行。", "error": True}
                    if choice in ("revise", "answer") and any(a["id"] == item.extra["ask"] for a in mem.asks(status=["open"])):
                        return {"text": NOT_KEPT, "error": True}   # 记忆不收这句话，问题还开着：卡片留着改
                    raise
                text = SAID.get(choice, "记下了。")
            else:
                return {"text": "不认识这个按钮。", "error": True}
        except ValueError:
            return {"text": CHANGED, "card": cards.result_card(sid, CHANGED), "done": True}
        return {"text": text, "card": cards.result_card(sid, text), "done": True}

    def _reply(self, mem: Any, item: Item, choice: str, text: Optional[str]) -> None:
        """交回一个回答（顶层 ADR 0015）：luoke_mem 有 reply 就一个调用交回，记忆直接定档；
        自带的库还没有 reply（0.16.1 及以前）就折算成老接口。"""
        aid = item.extra["ask"]
        if choice == "archive":     # luoke_mem 0.34：reply 认 archive；那条理解刚在别处定了的，只把问题关掉
            mem.reply(aid, "archive", None)
            return
        if hasattr(mem, "reply"):
            mem.reply(aid, choice, text)
            return
        note = item.extra.get("note")
        if choice == "yes":
            mem.confirm(note)
        elif choice == "no":
            mem.reject(note)
        elif choice == "revise":
            mem.revise(note, text, sensitive=load_luoke_mem().sensitive_kinds(text))
        elif choice == "later":
            if note:
                mem.later(note)
        elif choice == "answer":
            mem.answer(aid, text)
        elif choice == "useful":
            mem.answer(aid, "知道了")
        else:   # useless / never
            mem.dismiss(aid)
