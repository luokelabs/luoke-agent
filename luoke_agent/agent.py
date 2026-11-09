"""agent 的核心：收事项、画卡片、挑时机说、转点按（DESIGN §2–§5）。

来源有两种：记忆（memsource.MemorySource）和工具（toolsource.ToolSource），都有
`poll(now) -> [Item] | None`（None 表示没在运行）和 `handle(...)`。界面（ui.py）订阅事件、送点按。
事项的内容和卡片存在本机的状态库（state.py）：核心重启后答完的卡片照样在、[撤销] 还能点。
工具也是窗口上的「应用」：基础页、「打开完整界面」、权限（docs/界面接口.md §6、§10），有 `refresh_app` 的来源才算。
"""
from __future__ import annotations

import copy
import datetime as dt
import hashlib
import json
import queue
import sys
import threading
import time
import webbrowser
from concurrent.futures import ThreadPoolExecutor
from typing import Any, Callable, Dict, List, Optional, Tuple

from . import a2ui, apps, cards
from .items import RANK, Item, tool_surface_id
from .mcp import NotRunning, RpcError, TimedOut
from .state import State

DONE_KEEP_SECONDS = 30 * 60      # 答完的卡片（带撤销）在窗口里留多久
LOW_ONLY_GAP = 24 * 3600         # 只有不急的事时，一天最多一份简报
LOW_PER_BRIEF = 2                # 每份简报最多带几件不急的
PRESENCE_STALE = 120             # 壳多久没报"用户在不在"就当不知道
BRIEF_MODES = ("morning", "twice", "on_open")   # 设置里能选的简报（every 只给开发用）
MORNING = "08:00"                # 没设免打扰时，早上那份从几点起
EVENING = "18:00"                # 早晚各一次时，晚上那份从几点起
MODES = ("now", "brief", "window", "off")
SEARCH_LIMIT = 10                # 搜索框一次要几条
HHMM = __import__("re").compile(r"^([01]\d|2[0-3]):[0-5]\d$")

Event = Tuple[str, Any]


def parse_time(s: Optional[str]) -> Optional[float]:
    """ISO 8601；不带时区的按本机时间（工具协议 §3）。"""
    if not s:
        return None
    try:
        t = dt.datetime.fromisoformat(s.replace("Z", "+00:00"))
    except ValueError:
        return None
    return t.timestamp()


def iso(ts: float) -> str:
    return dt.datetime.fromtimestamp(ts).astimezone().isoformat(timespec="seconds")


def rename(messages: List[dict], sid: str) -> List[dict]:
    """来源自己的 surfaceId 换成 agent 这边的（加来源前缀）。"""
    out = copy.deepcopy(messages)
    for m in out:
        for k in a2ui.MESSAGE_KINDS:
            if k in m:
                m[k]["surfaceId"] = sid
    return out


class Agent:
    def __init__(self, state: State, sources: Optional[List[Any]] = None, *, clock: Callable[[], float] = time.time,
                 url_opener: Callable[[str], Any] = webbrowser.open, labels: Optional[Dict[str, str]] = None):
        self.state = state
        self.sources: Dict[str, Any] = {s.source: s for s in (sources or [])}
        self.clock = clock
        self.url_opener = url_opener
        self.labels = dict(labels or {})          # 类别 → 给用户看的名字（设置和"以后少说"用）
        for s in self.sources.values():
            self.labels.update(getattr(s, "labels", None) or {})
        self._lock = threading.RLock()
        self.items: Dict[str, Item] = {}          # 现在的事项
        self.kept: Dict[str, Item] = {}           # 答完了、卡片还留着的（撤销要用）
        self.surfaces: Dict[str, Tuple[str, a2ui.Surface]] = {}   # agent 的卡片编号 → (事项, 卡片)
        self.sort_keys: Dict[str, tuple] = {}
        self.done_at: Dict[str, float] = {}
        # 答完的卡片做了什么（工具答复的那句话）：「已经替你做了」那一行收起时写它，不写事项原来的标题
        self.done_text: Dict[str, str] = {}
        self.notices: Dict[str, str] = {}         # 来源 → 一句状态（"邮件助手没在运行"）
        self.presence: Optional[dict] = None
        self.window_open = False
        self.window_front = False                 # 窗口在最前面：用户正看着它（开着不等于看着）
        self.notifications: Optional[dict] = None   # 壳报的系统通知授权（只有状态）
        self.host_confirmed: Optional[Dict[str, Dict[str, str]]] = None   # 用户确认过的：{应用: {权限 id: 时间}}；没报是 None
        self.host: Dict[str, str] = {}            # 螺壳.app 报的它自己的权限状态（POST /host，只在内存里）
        self.pages: Dict[str, Tuple[str, str, a2ui.Surface]] = {}   # 基础页：<应用>/page/<页> → (应用, 页, 卡片)
        self._app_seen: Dict[str, str] = {}       # 每个应用上次报给窗口的样子：变了才发 apps 事件
        self.listeners: List["queue.Queue[Event]"] = []
        self._restore()

    def _restore(self) -> None:
        """核心重启：把答完、还留着的卡片画回去（撤销要用）。还开着的事项由来源再列一遍。"""
        now = self.clock()
        for row in self.state.kept_contents(now - DONE_KEEP_SECONDS):
            try:
                it = Item.from_dict(row["item"])
                surface = a2ui.build(row["surface"] or it.card)
            except (TypeError, a2ui.CardError):
                continue
            sid = row["sid"]
            self.kept[it.key] = it
            self.surfaces[sid] = (it.key, surface)
            st = self.state.item(it.key)
            self.sort_keys[sid] = (RANK.get(it.urgency, 1), parse_time(it.deadline) or float("inf"),
                                   st["first_seen"] if st else row["done_at"])
            self.done_at[sid] = row["done_at"]
            if isinstance(row["item"].get("done_text"), str) and row["item"]["done_text"]:
                self.done_text[sid] = row["item"]["done_text"]
        less = self.state.meta("less_notices")
        if less is None:   # 这张卡片以前不留存：已经少说了的类别补回来，用户才改得回去
            less = {c: self._label(c) for c, m in (self.state.setting("modes") or {}).items() if m == "window"}
            self.state.set_meta("less_notices", less)
        for category, label in less.items():
            self._less_card(category, label)

    def _save(self, it: Item, sid: str, done_at: Optional[float] = None) -> None:
        entry = self.surfaces.get(sid)
        d = it.to_dict()
        if sid in self.done_text:
            d["done_text"] = self.done_text[sid]     # Item.from_dict 不认这个键，读回时在 _restore 里取
        self.state.save_content(it.key, sid, d, entry[1].messages() if entry else None, done_at)

    # ---------------------------------------------------------------- 来源

    def add_source(self, src: Any) -> None:
        with self._lock:
            self.sources[src.source] = src
            self._check_app(src.source)

    def remove_source(self, name: str) -> None:
        with self._lock:
            self.sources.pop(name, None)
            self._merge(name, None, gone=True)
            for sid in [sid for sid, (app, _, _) in self.pages.items() if app == name]:
                del self.pages[sid]
            self._check_app(name)

    def poll(self, names: Optional[List[str]] = None) -> None:
        """读一遍来源（工具的 IO 不占锁）。"""
        for name, src in list(self.sources.items()):
            if names is not None and name not in names:
                continue
            try:
                items = src.poll(self.clock())
            except Exception as e:  # 一个来源出毛病不能拖垮别的
                print(f"luoke-agent: 读 {name} 出错 {type(e).__name__}", file=sys.stderr)
                items = None
            with self._lock:
                self._merge(name, items)
                self._check_app(name)

    def _merge(self, source: str, items: Optional[List[Item]], gone: bool = False) -> None:
        now = self.clock()
        src = self.sources.get(source)
        if items is None:
            if not gone:   # 暂时没在运行：卡片先收起来，状态不动，回来了照旧
                name = getattr(src, "name", source)
                self.notices[source] = f"{name}现在没在运行。" if source != "memory" else "螺壳记忆现在打不开。"
                if source == "memory" and getattr(src, "status", "") == "too_new":
                    self.notices[source] = "螺壳记忆比螺壳新，请更新螺壳。"
                elif source == "memory" and getattr(src, "status", "") == "missing":
                    self.notices.pop(source, None)     # 还没有记忆，不是出了毛病
                for key, it in list(self.items.items()):
                    if it.source == source:
                        del self.items[key]
                        if it.surface_id() not in self.done_at:
                            self._drop_surface(it.surface_id())
                self._emit_feed()
                return
            items_now: List[Item] = []
        else:
            self.notices.pop(source, None)
            items_now = [it for it in items if not self._covered(it)]   # 螺壳已经有了的权限：不再要
        keep = set()
        for it in items_now:
            exp = parse_time(it.expires)
            if exp is not None and exp <= now:
                continue
            row = self.state.remember(it.key, it.source, it.kind, it.urgency, now)
            if row["status"] == "gone" and row["outcome"] == "withdrawn":
                self.state.revive(it.key)    # 协议 §3：工具重启不丢
                row = self.state.item(it.key) or row
            if row["status"] in ("done", "gone"):
                continue
            keep.add(it.key)
            if row["status"] == "queued" and self._watching(now):
                self.state.set_status(it.key, "seen", now)   # 用户正看着窗口，不用再通知
                self._ack_shown(it)
            old = self.items.get(it.key)
            self.items[it.key] = it
            sid = it.surface_id()
            if old is not None and old.surface_id() != sid:
                self._drop_surface(old.surface_id())
            if old is None or old.card_hash != it.card_hash or sid not in self.surfaces:
                try:
                    surface = a2ui.build(it.card)
                except a2ui.CardError:
                    continue   # 来源已经查过；查不过的不画
                had = sid in self.surfaces
                self.surfaces[sid] = (it.key, surface)
                self.sort_keys[sid] = (RANK.get(it.urgency, 1), parse_time(it.deadline) or float("inf"), row["first_seen"])
                self._save(it, sid)
                if had:
                    self._emit("a2ui", {"version": a2ui.VERSION, "deleteSurface": {"surfaceId": sid}})
                for m in self._present(sid, surface):
                    self._emit("a2ui", m)
        if items is not None:   # 盘上还开着、来源这次没再列出的（例如核心重启前就撤下了）：算撤回
            for row in self.state.open_items():
                if row["source"] == source and row["key"] not in keep and row["key"] not in self.items:
                    self.state.set_status(row["key"], "gone", now, "withdrawn")
        for key, it in list(self.items.items()):
            if it.source != source or key in keep:
                continue
            del self.items[key]
            row = self.state.item(key)
            if row and row["status"] not in ("done", "gone"):
                expired = (parse_time(it.expires) or float("inf")) <= now
                self.state.set_status(key, "gone", now, "expired" if expired else "withdrawn")
                if expired and row["status"] == "notified" and self.state.mark_batch_counted(row):
                    self._ignored(it)
            sid = it.surface_id()
            if sid not in self.done_at:
                self._drop_surface(sid)
        self._emit_feed()

    def _drop_surface(self, sid: str) -> None:
        entry = self.surfaces.get(sid)
        if entry is not None and sid in self.done_at:
            self.state.unkeep(entry[0])
        if self.surfaces.pop(sid, None) is not None:
            self.sort_keys.pop(sid, None)
            self.done_at.pop(sid, None)
            self.done_text.pop(sid, None)
            self._emit("a2ui", {"version": a2ui.VERSION, "deleteSurface": {"surfaceId": sid}})

    # ---------------------------------------------------------------- 给界面的

    def _present(self, sid: str, surface: a2ui.Surface) -> List[dict]:
        """给界面画的消息：编号换成 agent 的；打开网页的按钮带上 `site`（去哪个网站，punycode），
        由界面画在按钮外面（工具协议 §5）。`site` 只由这里写：来源自己写的一律去掉。"""
        msgs = rename(surface.messages(), sid)
        for m in msgs:
            for c in (m.get("updateComponents") or {}).get("components") or []:
                c.pop("site", None)
                action = c.get("action")
                event = action.get("event") if isinstance(action, dict) else None
                if c.get("component") == "Button" and isinstance(event, dict) and event.get("name") == "agent.open_url":
                    ctx = event.get("context")
                    got = a2ui.open_url_site(ctx.get("url") if isinstance(ctx, dict) else None)
                    if got is not None:
                        c["site"] = got[0]
        return msgs

    def order(self) -> List[str]:
        return sorted(self.surfaces, key=lambda sid: self.sort_keys.get(sid, (9,)))

    def _section(self, sid: str, it: Optional[Item]) -> str:
        """这张卡片放在「今天」的哪一段（docs/界面接口.md §3）。"""
        if sid in self.done_at or (it is not None and it.kind == "auto-done"):
            return "done"
        if it is not None and it.urgency == "urgent":
            return "urgent"
        if it is not None and it.kind == "needs-access":
            return "decide"      # 要权限是要用户定的事：放「要你决定」，不管工具报的急不急（协议 §1a 默认 low）
        if it is not None and it.urgency == "low":
            return "later"
        return "decide"

    def _cards(self) -> List[dict]:
        out = []
        for sid in self.order():
            key = self.surfaces[sid][0]
            it = self.items.get(key) or self.kept.get(key)
            row = self.state.item(key)
            when = self.done_at.get(sid) or (row["first_seen"] if row else None)
            out.append({"id": sid, "app": it.source if it else key.split("/", 1)[0], "kind": it.kind if it else "",
                        "section": self._section(sid, it),
                        "title": self.done_text.get(sid) or (it.title if it else ""),
                        "time": iso(when) if when else None})
            ask = self._host_ask(it, sid)
            if ask is not None:
                out[-1]["host_ask"] = ask
        return out

    def _host_ask(self, it: Optional[Item], sid: str) -> Optional[dict]:
        """这张卡片要的是螺壳名下的系统权限：哪个按钮要它（docs/界面接口.md §3）。窗口把这个按钮交给螺壳.app，不转给工具。
        认工具的主按钮；没写主按钮时认唯一的工具按钮；认不出来不给，点了照旧转给工具。"""
        if it is None or it.kind != "needs-access" or sid in self.done_at:
            return None
        src = self._app(it.source)
        perm = src.permission(it.extra.get("permission")) if src is not None else None
        if perm is None or perm.get("owner") != "luoke" or perm["kind"] != "system":
            return None
        surface = self.surfaces[sid][1]
        buttons = []
        for cid in surface.components:
            try:
                name, _ = surface.button_event(cid)
            except a2ui.CardError:
                continue      # 不是按钮，或者现在没画着
            if not name.startswith("agent."):
                buttons.append(cid)
        primary = [cid for cid in buttons if surface.components[cid].get("variant") == "primary"]
        got = primary[0] if primary else buttons[0] if len(buttons) == 1 else None
        return {"permission": perm["id"], "button": got} if got else None

    def _page_host_ask(self, src: Any, surface: a2ui.Surface) -> Optional[dict]:
        """页上要螺壳名下系统权限的按钮：工具在按钮的 context 里写 `permission`，或者写 `needs`（按钮的活要这一项，
        够了才转给工具，`then`）（docs/界面接口.md §6）。页不像 needs-access 卡片有事项可认，所以要工具写明。
        别的按钮照旧转给工具。"""
        for cid in surface.components:
            try:
                _, context = surface.button_event(cid)
            except a2ui.CardError:
                continue
            perm = src.permission(context.get("permission"))
            then = perm is None
            if then:
                perm = src.permission(context.get("needs"))
            if perm is not None and perm.get("owner") == "luoke" and perm["kind"] == "system":
                return {"permission": perm["id"], "button": cid, "then": True} if then else {"permission": perm["id"], "button": cid}
        return None

    def _feed(self) -> dict:
        rows = {r["key"]: r for r in self.state.open_items()}
        waiting = sum(1 for k in self.items if k in rows)
        nxt = self._next_brief(self.clock())
        paused = self._paused_until(self.clock())
        return {"order": self.order(), "open": waiting, "notices": list(self.notices.values()), "cards": self._cards(),
                "brief": {"next": iso(nxt) if nxt else None}, "paused_until": iso(paused) if paused else None}

    def _emit(self, event: str, data: Any) -> None:
        for q in list(self.listeners):
            q.put((event, data))

    def _emit_feed(self) -> None:
        self._emit("feed", self._feed())

    def subscribe(self) -> "queue.Queue[Event]":
        """新的界面连上来：先给它现在的全部卡片，再给之后的变化。"""
        q: "queue.Queue[Event]" = queue.Queue()
        with self._lock:
            for sid in self.order():
                for m in self._present(sid, self.surfaces[sid][1]):
                    q.put(("a2ui", m))
            q.put(("feed", self._feed()))
            self.listeners.append(q)
        return q

    def unsubscribe(self, q: "queue.Queue[Event]") -> None:
        with self._lock:
            if q in self.listeners:
                self.listeners.remove(q)

    def status(self) -> dict:
        """只有元数据，给命令行和检查用。"""
        with self._lock:
            return {"api": 2, "items": len(self.items), "surfaces": len(self.surfaces), "notices": list(self.notices.values()),
                    "sources": {n: getattr(s, "status", "running" if getattr(s, "running", True) else "down")
                                for n, s in self.sources.items()},
                    "brief_due": self.state.meta("brief_due"), "window_open": self.window_open,
                    "window_front": self.window_front,
                    "notifications": self.notifications,
                    "present": self._is_present(self.clock())}

    # ---------------------------------------------------------------- 用户在不在、窗口

    def set_presence(self, idle_seconds: float, locked: bool = False, asleep: bool = False) -> None:
        with self._lock:
            self.presence = {"idle": float(idle_seconds), "locked": bool(locked), "asleep": bool(asleep),
                             "at": self.clock()}
        self.tick()

    def _is_present(self, now: float) -> bool:
        p = self.presence
        if not p or now - p["at"] > PRESENCE_STALE:
            return False
        idle = p["idle"] + (now - p["at"])
        return not p["locked"] and not p["asleep"] and idle < float(self.state.setting("away_seconds"))

    def set_notifications(self, status: str, alerts: bool = True) -> None:
        """系统通知被关掉了（用户在系统设置里拒了、或者横幅关了）：简报和急事都到不了用户，窗口里说一句怎么打开。
        不替用户改系统设置。"""
        with self._lock:
            old = self.notifications
            self.notifications = {"status": status, "alerts": bool(alerts)}
            if status == "not_determined":        # 窗口里有「打开通知」的按钮，用户点了才问（界面接口 §10）
                self.notices.pop("notifications", None)
            elif not self._can_notify():
                self.notices["notifications"] = "系统通知被关掉了，螺壳的简报和急事提醒你收不到。要收的话，在系统设置 → 通知 里找到「螺壳 agent」，打开“允许通知”。"
            else:
                self.notices.pop("notifications", None)
            if old != self.notifications:
                print(f"luoke-agent: 系统通知 {status}{'' if alerts else '（横幅关着）'}", file=sys.stderr, flush=True)
                self._emit_feed()

    def set_window(self, is_open: bool, front: Optional[bool] = None) -> None:
        """`front`：窗口在最前面（壳报；老的壳不报，开着就算）。用户看着窗口时，现在的事项都算看过了。"""
        with self._lock:
            self.window_open = is_open
            self.window_front = is_open if front is None else bool(front) and is_open
            self._see(self.clock())
            self._emit_feed()

    def _watching(self, now: float) -> bool:
        """用户正看着窗口：窗口在最前面，人也在（没报过在不在时信窗口）。最小化、切到别的应用、人走开都不算。"""
        return self.window_front and (self.presence is None or self._is_present(now))

    def _see(self, now: float) -> None:
        if not self._watching(now):
            return
        for key, it in self.items.items():
            row = self.state.item(key)
            self.state.set_status(key, "seen", now)
            if row is not None and row["status"] == "queued":
                self._ack_shown(it)
        self.state.set_meta("brief_unopened", None)

    def _can_notify(self) -> bool:
        """系统通知到得了用户。到不了就不算说过：事项排着，窗口里有一句怎么打开（壳没报过时照常发）。"""
        n = self.notifications
        return n is None or (n["status"] in ("authorized", "provisional", "ephemeral") and n["alerts"])

    # ---------------------------------------------------------------- 挑时机（DESIGN §5）

    def mode(self, it: Item) -> str:
        modes = self.state.setting("modes") or {}
        return modes.get(it.category) or ("now" if it.urgency == "urgent" else "brief")

    def _quiet(self, now: float) -> bool:
        q = self.state.setting("quiet")
        if not q:
            return False
        t = dt.datetime.fromtimestamp(now).strftime("%H:%M")
        start, end = q["start"], q["end"]
        return start <= t < end if start <= end else (t >= start or t < end)

    def _paused_until(self, now: float) -> Optional[float]:
        p = self.state.setting("paused_until")
        return float(p) if p and float(p) > now else None

    def _may_speak(self, now: float) -> bool:
        """主动提醒开着、没在暂停：可以发通知和简报。"""
        return bool(self.state.setting("proactive")) and self._paused_until(now) is None

    def _slot_times(self) -> List[str]:
        mode = self.state.setting("brief")
        q = self.state.setting("quiet")
        morning = q["end"] if q else MORNING
        return [morning, EVENING] if mode == "twice" else [morning]

    def _slots_around(self, now: float) -> List[float]:
        """昨天、今天、明天的每个简报时刻（时间戳，按本机时间），从早到晚。"""
        day = dt.datetime.fromtimestamp(now).replace(hour=0, minute=0, second=0, microsecond=0)
        out = []
        for d in (-1, 0, 1):
            base = day + dt.timedelta(days=d)
            for hhmm in self._slot_times():
                h, m = (int(x) for x in hhmm.split(":"))
                out.append(base.replace(hour=h, minute=m).timestamp())
        return sorted(out)

    def _last_slot(self, now: float) -> float:
        return max((t for t in self._slots_around(now) if t <= now), default=0.0)

    def _next_brief(self, now: float) -> Optional[float]:
        """下一份简报大约什么时候：只在设置里说一句。"""
        mode = self.state.setting("brief")
        if mode == "on_open" or not self.state.setting("proactive"):
            return None
        if mode == "every":
            due = self.state.meta("brief_due")
            return float(due) if due else None
        last = float(self.state.meta("last_brief", 0))
        slot = self._last_slot(now)
        if slot > last:        # 这一时段还没发：等用户回到 Mac 前
            return slot
        return min(t for t in self._slots_around(now) if t > now)

    # ---------------------------------------------------------------- 设置（docs/界面接口.md §9）

    def settings(self) -> dict:
        with self._lock:
            modes = dict(self.state.setting("modes") or {})
            seen = {f"{c['source']}:{c['kind']}": c["urgent"] for c in self.state.categories()}
            for cat in list(self.labels) + list(modes):
                seen.setdefault(cat, False)
            kinds = []
            for cat, urgent in sorted(seen.items()):
                default = "now" if urgent else "brief"
                kinds.append({"id": cat, "app": cat.split(":", 1)[0], "label": self._label(cat),
                              "mode": modes.get(cat, default), "default": default})
            paused = self._paused_until(self.clock())
            return {"proactive": bool(self.state.setting("proactive")), "brief": self.state.setting("brief"),
                    "quiet": self.state.setting("quiet"), "paused_until": iso(paused) if paused else None,
                    "kinds": kinds, "modes": modes}

    def update_settings(self, patch: Dict[str, Any]) -> dict:
        """只改给了的几项；认不得的、值不对的抛 ValueError，什么都不改。"""
        if not isinstance(patch, dict):
            raise ValueError("要是对象")
        known = {"proactive", "brief", "quiet", "paused_until", "modes"}
        bad = sorted(set(patch) - known)
        if bad:
            raise ValueError(f"认不得：{'、'.join(bad)}")
        todo: Dict[str, Any] = {}
        if "proactive" in patch:
            if not isinstance(patch["proactive"], bool):
                raise ValueError("proactive 要是 true 或 false")
            todo["proactive"] = patch["proactive"]
        if "brief" in patch:
            if patch["brief"] not in BRIEF_MODES:
                raise ValueError("brief 只能是 " + "、".join(BRIEF_MODES))
            todo["brief"] = patch["brief"]
        if "quiet" in patch:
            q = patch["quiet"]
            if q is not None and not (isinstance(q, dict) and set(q) == {"start", "end"}
                                      and all(isinstance(q[k], str) and HHMM.match(q[k]) for k in q) and q["start"] != q["end"]):
                raise ValueError("quiet 要是 null 或 {start, end}（HH:MM，不一样）")
            todo["quiet"] = q
        if "paused_until" in patch:
            p = patch["paused_until"]
            if p is None:
                todo["paused_until"] = None
            else:
                t = parse_time(p) if isinstance(p, str) else None
                if t is None or t <= self.clock() or t > self.clock() + 7 * 24 * 3600:
                    raise ValueError("paused_until 要是 null 或以后七天内的时间（ISO 8601）")
                todo["paused_until"] = t
        if "modes" in patch:
            m = patch["modes"]
            if not isinstance(m, dict) or not all(isinstance(k, str) and ":" in k and (v is None or v in MODES)
                                                  for k, v in m.items()):
                raise ValueError("modes 要是 {\"来源:类别\": now / brief / window / off / null}")
            modes = dict(self.state.setting("modes") or {})
            for k, v in m.items():
                if v is None:
                    modes.pop(k, None)
                else:
                    modes[k] = v
                self.state.react(k, "reset")        # 用户自己定了：「连着没理」重新数
            todo["modes"] = modes
        with self._lock:
            for k, v in todo.items():
                self.state.set_setting(k, v)
            if "brief" in todo or "quiet" in todo:
                self.state.set_meta("brief_due", None)
            self._emit_settings()
            self._emit_feed()
        self.tick()
        return self.settings()

    def _emit_settings(self) -> None:
        self._emit("settings", self.settings())

    def tick(self) -> None:
        now = self.clock()
        with self._lock:
            self._expire(now)
            self._see(now)
            present = self._is_present(now)
            rows = {r["key"]: r for r in self.state.open_items()}
            pending = [it for k, it in self.items.items() if rows.get(k, {}).get("status") == "queued"]
            speak = present and self._can_notify() and self._may_speak(now)
            urgent = [it for it in pending if self.mode(it) == "now"] if speak else []
            if len(urgent) == 1:   # 急事：当场说，照系统的专注模式（壳用时效性通知）
                it = urgent[0]
                self._notify(it.key, it.title, it.why_now or it.summary, urgent=True, surface=it.surface_id())
            elif urgent:           # 同时来了几件急事：合成一条，不连着打断几次
                titles = [it.title for it in urgent]
                body = "；".join(titles[:3]) + (f"；还有 {len(titles) - 3} 件" if len(titles) > 3 else "")
                self._notify("urgent", f"{len(urgent)} 件急事", body, urgent=True, surface=urgent[0].surface_id())
            self._mark_notified(urgent, now)
            self._brief(now, present, [it for it in pending if self.mode(it) == "brief"])

    def _brief(self, now: float, present: bool, pending: List[Item]) -> None:
        due = self.state.meta("brief_due")
        normal = [it for it in pending if it.urgency != "low"]
        low = [it for it in pending if it.urgency == "low"]
        low_ok = now - float(self.state.meta("last_low_brief", 0)) >= LOW_ONLY_GAP
        if not normal and not (low and low_ok):
            if due is not None:
                self.state.set_meta("brief_due", None)
            if present and not self._quiet(now) and self._last_slot(now) > float(self.state.meta("last_brief", 0)):
                self.state.set_meta("last_brief", now)   # 到了时刻、用户在、没什么可说：这一份就不发了
            return
        mode = self.state.setting("brief")
        if mode == "on_open" or not self._may_speak(now):
            return          # 只在打开时看、关了主动提醒、暂停着：不发；打开窗口时「今天」排好
        if mode == "every":   # 开发用：第一件进来时开始计时，攒满 brief_minutes 就发
            if due is None:
                self.state.set_meta("brief_due", now + 60 * float(self.state.setting("brief_minutes")))
                return
            if now < due:
                return
        elif self._last_slot(now) <= float(self.state.meta("last_brief", 0)):
            return          # 这一时段的已经发过了（或者那时用户在、没什么可说），等下一个时刻
        if not present or self._quiet(now) or not self._can_notify():
            return          # 不在 Mac 前、免打扰时段、系统通知到不了：等
        batch = sorted(normal, key=lambda it: self.sort_keys.get(it.surface_id(), (9,))) + low[:LOW_PER_BRIEF]
        for row in self.state.notified_unseen():      # 上一份说了、用户一直没打开看的：算没理
            it = self.items.get(row["key"])
            if it is None:
                self.state.mark_counted(row["key"])
            elif self.state.mark_batch_counted(row):
                self._ignored(it)
        waiting, urgent, done = self._brief_parts(batch)
        self._notify("brief", f"{len(waiting) + len(urgent) + len(done)} 件事", self._brief_body(waiting, urgent, done),
                     silent=bool(self.state.meta("brief_unopened")))
        self._mark_notified(batch, now)
        if not normal:
            self.state.set_meta("last_low_brief", now)
        self.state.set_meta("brief_due", None)
        self.state.set_meta("last_brief", now)
        self.state.set_meta("brief_unopened", True)

    def _brief_parts(self, batch: List[Item]) -> Tuple[List[Item], List[Item], List[Item]]:
        """简报说的三样：等你的、还没处理的急事（只算这一类没关掉提醒的，即 now、brief）、替你做了的（auto-done）。
        标题的件数就是这三样加起来，和正文对得上。"""
        urgent = [it for it in self.items.values()
                  if it.urgency == "urgent" and it.kind != "auto-done" and self.mode(it) in ("now", "brief")]
        waiting = [it for it in batch if it.kind != "auto-done" and it.urgency != "urgent"]
        done = [it for it in batch if it.kind == "auto-done"]
        return waiting, urgent, done

    @staticmethod
    def _brief_body(waiting: List[Item], urgent: List[Item], done: List[Item]) -> str:
        """简报通知的正文，照模板拼一句：等你的几件（前三件的标题）、还没处理的急事、替你做了几件。"""
        def phrase(title: str) -> str:
            return title.rstrip("。.；;，, ？?！!")
        parts = []
        if waiting:
            names = "、".join(phrase(it.title) for it in waiting[:3]) + ("等" if len(waiting) > 3 else "")
            parts.append(f"还有 {len(waiting)} 件等你：{names}")
        if urgent:
            parts.append(f"急事：{phrase(urgent[0].title)}" + (f"等 {len(urgent)} 件" if len(urgent) > 1 else ""))
        if done:
            parts.append(f"替你做了 {len(done)} 件")
        return "；".join(parts) + "。" if parts else ""

    def _mark_notified(self, items: List[Item], now: float) -> None:
        for it in items:
            row = self.state.item(it.key)
            self.state.set_status(it.key, "notified", now)
            self.state.react(it.category, "shown")
            if row is not None and row["status"] == "queued":
                self._ack_shown(it)

    def _ack_shown(self, it: Item) -> None:
        """告诉工具这件已经说过了（简报、急事的通知，或窗口开着时用户看得到）；每件只回一次。"""
        src = self.sources.get(it.source)
        if src is not None and hasattr(src, "ack"):
            threading.Thread(target=src.ack, args=(it, "shown"), daemon=True).start()

    def _notify(self, nid: str, title: str, body: str, *, urgent: bool = False, silent: bool = False,
                surface: Optional[str] = None) -> None:
        self._emit("notify", {"id": nid, "title": title, "body": body, "urgent": urgent, "silent": silent,
                              "surfaceId": surface})

    def _expire(self, now: float) -> None:
        for key, it in list(self.items.items()):
            exp = parse_time(it.expires)
            if exp is not None and exp <= now:
                self._merge_one_gone(key, it, now)
        if not self.window_open:
            for sid, t in list(self.done_at.items()):
                if now - t > DONE_KEEP_SECONDS:
                    ik = self.surfaces.get(sid, ("",))[0]
                    self.kept.pop(ik, None)
                    self._drop_surface(sid)
            self.state.forget_old(now - 30 * 24 * 3600)

    def _merge_one_gone(self, key: str, it: Item, now: float) -> None:
        del self.items[key]
        row = self.state.item(key)
        self.state.set_status(key, "gone", now, "expired")
        if row and row["status"] == "notified" and self.state.mark_batch_counted(row):
            self._ignored(it)
        self._drop_surface(it.surface_id())
        self._emit_feed()

    def _ignored(self, it: Item) -> None:
        """说了没理：连着几次就不再为这一类发通知，只放窗口，并说一次（DESIGN §5）。"""
        streak = self.state.react(it.category, "ignored")
        if streak < int(self.state.setting("ignore_limit")) or self.mode(it) != "brief":
            return
        modes = dict(self.state.setting("modes") or {})
        modes[it.category] = "window"
        self.state.set_setting("modes", modes)
        self._emit_settings()
        label = self._label(it.category)
        less = dict(self.state.meta("less_notices") or {})
        less[it.category] = label
        self.state.set_meta("less_notices", less)
        sid = self._less_card(it.category, label)
        for m in self._present(sid, self.surfaces[sid][1]):
            self._emit("a2ui", m)

    def _label(self, category: str) -> str:
        return self.labels.get(category) or "这一类事"

    def _less_card(self, category: str, label: str) -> str:
        """"以后少提醒"的卡片；用户点了才收起，核心重启也画回来（设置页还没有，这是改回去的唯一入口）。"""
        card = cards.Card("less-" + hashlib.sha256(category.encode()).hexdigest()[:12])
        card.text(f"「{label}」你最近都没看，以后只放在这里，不再提醒。")
        card.buttons(cards.button("还是提醒我", "agent.remind", {"category": category}),
                     cards.button("好", "agent.dismiss"))
        notice = Item(key=f"agent/less/{category}", source="agent", kind="less", urgency="low",
                      title=f"以后少提醒「{label}」", summary="", why_now="", card=card.messages())
        self.items[notice.key] = notice
        self.state.remember(notice.key, "agent", "less", "low", self.clock())
        self.state.set_status(notice.key, "seen", self.clock())   # 它自己不发通知，只放窗口
        sid = notice.surface_id()
        self.surfaces[sid] = (notice.key, a2ui.build(notice.card))
        self.sort_keys[sid] = (RANK["low"], float("inf"), self.clock())
        return sid

    def _less_answered(self, item: Item) -> None:
        less = dict(self.state.meta("less_notices") or {})
        less.pop(item.key.split("/", 2)[2], None)
        self.state.set_meta("less_notices", less)

    # ---------------------------------------------------------------- 点按

    def tap(self, sid: str, component_id: str, client_context: Optional[dict] = None) -> Dict[str, Any]:
        """用户在卡片上点了一下。写死的上下文只认卡片上声明的（a2ui.merge_context）。"""
        with self._lock:
            on_page = sid not in self.surfaces and sid in self.pages
        if on_page:
            return self._tap_page(sid, component_id, client_context)
        now = self.clock()
        with self._lock:
            entry = self.surfaces.get(sid)
            if entry is None:
                return {"text": "这张卡片已经没有了。", "error": True}
            key, surface = entry
            item = self.items.get(key) or self.kept.get(key)
            try:
                name, declared = surface.button_event(component_id)
                ctx = a2ui.merge_context(declared, client_context or {}, surface.data)
            except (a2ui.CardError, KeyError):
                return {"text": "这个按钮已经不在了。", "error": True}
            if item is None:
                return {"text": "这件事已经没有了。", "error": True}
            src = self.sources.get(item.source)
            self._emit("busy", {"surfaceId": sid})
        if name.startswith("agent."):
            result = self._agent_action(item, sid, name, ctx)
        elif item.source == "memory" and src is not None:
            result = src.handle(item, name, ctx, now)
        elif src is not None:
            result = src.handle(item, name, ctx, {"componentId": component_id, "at": iso(now)})
        else:
            result = {"text": "这件事的来源现在不在了。", "error": True}
        with self._lock:
            self._apply(item, sid, result, now)
        return result

    def _apply(self, item: Item, sid: str, result: Dict[str, Any], now: float) -> None:
        entry = self.surfaces.get(sid)
        replaced = False
        if entry is not None and result.get("card"):
            try:
                updated = a2ui.update(entry[1], result["card"])
            except a2ui.CardError:
                updated = None
            if updated is not None:
                replaced = True
                self.surfaces[sid] = (entry[0], updated)
                for m in rename(result["card"], sid):
                    if "updateComponents" in m:
                        m = self._present_update(m)
                    self._emit("a2ui", m)
        if result.get("done"):
            first_time = item.key in self.items
            self.state.set_status(item.key, "done", now, result.get("outcome", "answered"))
            if first_time:
                self.state.react(item.category, "ignored" if result.get("outcome") == "dismissed" else "answered")
                self.kept[item.key] = self.items.pop(item.key)
                src = self.sources.get(item.source)
                if src is not None and hasattr(src, "ack"):
                    threading.Thread(target=src.ack, args=(item, result.get("outcome", "answered")), daemon=True).start()
            if result.get("drop"):
                self.kept.pop(item.key, None)
                self._drop_surface(sid)
                self.state.unkeep(item.key)
            elif sid in self.surfaces:
                self.done_at[sid] = now
                text = result.get("text")
                if isinstance(text, str) and text.strip() and not result.get("error"):
                    self.done_text[sid] = text.strip()[:200]
                self._save(item, sid, self.done_at[sid])
        elif replaced and item.key in self.kept:   # 例如撤销以后：卡片又变了，存下现在的样子
            text = result.get("text")
            if sid in self.done_at and isinstance(text, str) and text.strip() and not result.get("error"):
                self.done_text[sid] = text.strip()[:200]      # 那一行也写最新做了什么（「放回去了」）
            self._save(item, sid, self.done_at.get(sid, now))
        # 卡片已经换成了结果：那句话卡片上有了，界面就不用再写一遍（replaced）
        self._emit("result", {"surfaceId": sid, "text": result.get("text", ""), "error": bool(result.get("error")),
                              "replaced": replaced})
        self._emit_feed()

    def _present_update(self, m: dict) -> dict:
        sid = m["updateComponents"]["surfaceId"]
        fake = a2ui.Surface(sid, a2ui.AGENT_CATALOG)
        fake.components = {c["id"]: c for c in m["updateComponents"]["components"]}
        out = self._present(sid, fake)
        return next(x for x in out if "updateComponents" in x)

    def _open_url(self, ctx: dict) -> Dict[str, Any]:
        """打开的网址照显示网站时那次解析重新拼出来（a2ui.open_url_site），不原样交出去。"""
        got = a2ui.open_url_site(ctx.get("url"))
        if got is None:
            return {"text": "这个网址打不开。", "error": True}
        site, url = got
        self.url_opener(url)
        return {"text": f"在浏览器里打开了 {site}。"}

    def _agent_action(self, item: Item, sid: str, name: str, ctx: dict) -> Dict[str, Any]:
        if name == "agent.open_url":
            return self._open_url(ctx)
        if name == "agent.dismiss":
            if item.kind == "less" and item.source == "agent":
                self._less_answered(item)
            return {"text": "好。", "done": True, "outcome": "dismissed" if item.source != "agent" else "answered",
                    "drop": True}
        if name == "agent.remind" and item.source == "agent":
            modes = dict(self.state.setting("modes") or {})
            modes.pop(str(ctx.get("category")), None)
            self.state.set_setting("modes", modes)
            self.state.react(str(ctx.get("category")), "reset")
            self._emit_settings()
            self._less_answered(item)
            return {"text": "好，照旧提醒。", "done": True, "drop": True}
        return {"text": "不认识这个按钮。", "error": True}

    # ---------------------------------------------------------------- 应用的页（docs/界面接口.md §6）

    def _apps(self) -> List[Any]:
        """窗口上的应用：连着的工具（记忆不算）。"""
        return [s for s in self.sources.values() if hasattr(s, "refresh_app")]

    def _app(self, name: str) -> Optional[Any]:
        src = self.sources.get(name)
        return src if src is not None and hasattr(src, "refresh_app") else None

    def _app_entry(self, src: Any) -> dict:
        ui = src.service["ui"]
        needs = [p["id"] for p in src.permissions   # 要了（outbox 里有它的 needs-access）、还没给的
                 if p["kind"] in ("system", "account") and p["id"] in src.asking
                 and self._perm_state(src, p) not in apps.CONNECTED]
        return {"id": src.source, "running": bool(src.running), "summary": src.summary if src.running else None,
                "pages": [dict(p) for p in src.service["pages"]], "ui": {"pages": [dict(p) for p in ui["pages"]]} if ui else None,
                "needs": needs}

    def apps(self) -> dict:
        """GET /apps：每个连着的工具一项。概览和权限状态是上次读 outbox 时一起读的。"""
        with self._lock:
            return {"apps": [self._app_entry(s) for s in self._apps()]}

    def _check_app(self, name: str) -> None:
        """这个应用的运行状态、概览、页列表、权限状态变了：发 apps 事件，窗口重新取（持锁调）。"""
        src = self._app(name)
        snap = None if src is None else json.dumps([self._app_entry(src), self._perm_rows(src)], sort_keys=True,
                                                     ensure_ascii=False)
        if snap == self._app_seen.get(name):
            return
        if snap is None:
            self._app_seen.pop(name, None)
        else:
            self._app_seen[name] = snap
        self._emit("apps", {"app": name})

    def app_changed(self, name: str) -> None:
        """清单换了（主控那边升级了）之类：看看要不要告诉窗口。"""
        with self._lock:
            self._check_app(name)

    def page(self, app: str, page: str) -> Tuple[int, dict]:
        """GET /apps/<id>/pages/<页>：读工具的 `page/<页>`，校验和上限同卡片；画不了的换成一句纯文本。
        surfaceId 换成 `<应用>/page/<页>`，页上的按钮照卡片走 /action。"""
        with self._lock:
            src = self._app(app)
            spec = next((p for p in src.service["pages"] if p["id"] == page), None) if src is not None else None
        if src is None:
            return 404, {"error": "没有这个应用"}
        if spec is None:
            return 404, {"error": "没有这一页"}
        try:
            surface = a2ui.build(src.read_page(page))
        except NotRunning:
            return 503, {"error": f"{src.name}现在没在运行。"}
        except (RpcError, a2ui.CardError) as e:
            n = len(e.problems) if isinstance(e, a2ui.CardError) else 1
            print(f"luoke-agent: {app} 的页 {page} 画不了：{n} 处问题", file=sys.stderr)
            card = cards.Card(page)
            card.heading(spec["title"])
            card.text("这一页画不了。", caption=True)
            surface = a2ui.build(card.messages())
        sid = f"{app}/page/{page}"
        src.refresh_app()        # 页是现读的；标题旁的概览也照工具现在报的，不等下一轮读 outbox（不然两处数字对不上）
        with self._lock:
            self.pages[sid] = (app, page, surface)
            self._check_app(app)
            reply = {"messages": self._present(sid, surface)}
            ask = self._page_host_ask(src, surface)
            if ask is not None:
                reply["host_ask"] = ask
            return 200, reply

    def search(self, query: str, limit: int = SEARCH_LIMIT) -> dict:
        """POST /search：问每个写了 `service.ask.search` 的工具，不经模型（docs/界面接口.md §7）。
        工具给的 A2UI 卡片校验过交给窗口，surfaceId 是 `<应用>/search`，卡片上的按钮照基础页走 /action。
        只给结果不给卡片的工具这一版不画。日志不记搜了什么、命中了什么。"""
        with self._lock:
            sources = [s for s in self._apps() if s.service["search"]]
        if not sources:
            return {"results": [], "failed": [], "text": "还没有能搜的应用。"}
        with ThreadPoolExecutor(max_workers=len(sources)) as pool:
            answers = list(pool.map(lambda s: self._search_one(s, query, limit), sources))
        results: List[dict] = []
        failed: List[str] = []
        with self._lock:
            for src, surface in zip(sources, answers):
                if surface is False:
                    failed.append(src.name)
                elif surface is not None:
                    sid = f"{src.source}/search"
                    self.pages[sid] = (src.source, "search", surface)
                    results.append({"app": src.source, "name": src.name, "messages": self._present(sid, surface)})
        return {"results": results, "failed": failed}

    def _search_one(self, src: Any, query: str, limit: int) -> Any:
        """一个工具的答复：画得了的卡片；没搜到或没给卡片是 None；没答上来是 False。"""
        try:
            result = src.search(query, limit)
            if result.is_error:
                return False
            if not result.card or result.structured.get("hits") == []:
                return None
            return a2ui.build(result.card)
        except (NotRunning, TimedOut, RpcError):
            return False
        except a2ui.CardError as e:
            print(f"luoke-agent: {src.source} 的搜索结果画不了：{len(e.problems)} 处问题", file=sys.stderr)
            return False

    def _tap_page(self, sid: str, component_id: str, client_context: Optional[dict]) -> Dict[str, Any]:
        """基础页上的点按：转给出这一页的工具，user_action 的 surfaceId 是页 id。工具回的卡片不画：
        窗口点完会重新取这一页（docs/界面接口.md §6）。"""
        now = self.clock()
        with self._lock:
            entry = self.pages.get(sid)
            if entry is None:
                return {"text": "这一页已经没有了。", "error": True}
            app, page, surface = entry
            try:
                name, declared = surface.button_event(component_id)
                ctx = a2ui.merge_context(declared, client_context or {}, surface.data)
            except (a2ui.CardError, KeyError):
                return {"text": "这个按钮已经不在了。", "error": True}
            src = self._app(app)
            self._emit("busy", {"surfaceId": sid})
        if name == "agent.open_url":
            result = self._open_url(ctx)
        elif name.startswith("agent."):
            result = {"text": "不认识这个按钮。", "error": True}
        elif src is None:
            result = {"text": "这个应用现在不在了。", "error": True}
        else:
            result = src.call(page, name, ctx, {"componentId": component_id, "at": iso(now)})
            src.refresh_app()        # 点完，概览和权限可能变了
        out = {"text": result.get("text", ""), "error": bool(result.get("error"))}
        with self._lock:
            self._emit("result", dict(out, surfaceId=sid, replaced=False))
            self._check_app(app)
        return out

    def open_ui(self, app: str, page: Optional[str] = None) -> Dict[str, Any]:
        """POST /open：用户点了「打开完整界面」或深页。调工具的 `service.ui.open`（只读，由工具自己打开窗口）。"""
        with self._lock:
            src = self._app(app)
        if src is None:
            return {"text": "没有这个应用。", "error": True}
        ui = src.service["ui"]
        if ui is None:
            return {"text": f"{src.name}没有自己的界面。", "error": True}
        if page is not None and page not in [p["id"] for p in ui["pages"]]:
            return {"text": "没有这一页。", "error": True}
        r = src.call("open", ui["open"], {"page": page} if page else {},
                     {"componentId": page or "open", "at": iso(self.clock())})
        return {"text": r.get("text", ""), "error": bool(r.get("error"))}

    # ---------------------------------------------------------------- 权限（docs/界面接口.md §10）

    def _perm_state(self, src: Any, perm: dict) -> Optional[str]:
        """在螺壳名下的照螺壳.app 报的（POST /host），别的照工具报的；不知道是 None。"""
        if perm.get("owner") == "luoke":
            return self.host.get(perm["id"])
        return (src.perm_states or {}).get(perm["id"])

    def _perm_rows(self, src: Any) -> List[dict]:
        out = []
        for p in src.permissions:
            st = self._perm_state(src, p)
            out.append(apps.row(src.source, p, st, apps.can(p, st, running=bool(src.running),
                                                            ui_open=src.service["ui"] is not None)))
        return out

    def permissions(self) -> dict:
        """GET /permissions：每个应用的每项权限一行。先问一遍工具现在的状态（不缓存成"已授权"，协议 §1a）。"""
        with self._lock:
            srcs = [s for s in self._apps() if s.permissions]
        for s in srcs:
            s.refresh_app(summary=False)
        with self._lock:
            rows: List[dict] = []
            for s in self._apps():
                rows += self._perm_rows(s)
                self._check_app(s.source)
            return {"rows": rows}

    def permission_op(self, app: str, pid: str, op: str) -> Dict[str, Any]:
        """POST /permissions：用户在权限页上点了。`op` 只认这一行现在的 `can`；会改动东西的带 user_action。"""
        with self._lock:
            src = self._app(app)
        if src is None:
            return {"text": "没有这个应用。", "error": True}
        perm = src.permission(pid)
        if perm is None:
            return {"text": "没有这一项权限。", "error": True}
        src.refresh_app(summary=False)       # 照工具现在报的定能做什么
        with self._lock:
            self._check_app(app)
            state = self._perm_state(src, perm)
            ui = src.service["ui"]
            ops = apps.can(perm, state, running=bool(src.running), ui_open=ui is not None)
        if op in apps.TOOL_OPS and not src.running:
            return {"text": f"{src.name}现在没在运行。", "error": True}
        if not ops or op not in ops:
            return {"text": "这一项现在不能这样改。", "error": True}
        if op == "settings":
            pane = apps.settings_pane(perm.get("tcc"))
            if pane is None:     # can 里本来就不会有；再核一遍
                return {"text": "不知道系统设置的哪一页。", "error": True}
            # 核心不自己开：把对照表里的地址交给窗口，由螺壳.app 打开（luoke-core#68）
            return {"text": f"在系统设置里打开「{pane[1]}」。", "error": False, "url": pane[0]}
        ua = {"componentId": pid, "at": iso(self.clock())}
        if op == "request":
            r = src.call("permissions", perm["request"], {}, ua, write=True)
        elif op in ("on", "off"):
            r = src.call("permissions", perm["on"], {"on": op == "on"}, ua, write=True)
        elif op == "remove":
            r = src.call("permissions", perm["remove"], {}, ua, write=True)
        else:   # open：去工具自己的界面（账号）
            page = perm.get("page")
            args = {"page": page} if page in [p["id"] for p in ui["pages"]] else {}
            r = src.call("permissions", ui["open"], args, ua)
        src.refresh_app()
        with self._lock:
            self._check_app(app)
        return {"text": r.get("text", ""), "error": bool(r.get("error"))}

    def set_host(self, raw: Any, confirmed: Any = None) -> None:
        """POST /host：螺壳.app 报它自己的权限状态（只在内存里；null 是不再报这一项）和用户确认过哪些。在螺壳名下的权限
        螺壳已经有了、这个应用也确认过：工具为它报的 `needs-access` 撤下；不再是这样，下次读 outbox 时回来。不对抛 ValueError。"""
        got = apps.host_states(raw)
        ok = apps.host_confirmed(confirmed)
        with self._lock:
            if ok is not None:
                self.host_confirmed = ok
            for k, v in got.items():
                if v is None:
                    self.host.pop(k, None)
                else:
                    self.host[k] = v
            now = self.clock()
            for key, it in list(self.items.items()):
                if self._covered(it):
                    self._withdraw(key, it, now)
            for s in self._apps():
                self._check_app(s.source)
            self._emit_feed()

    def _covered(self, it: Item) -> bool:
        """工具要的这项权限在螺壳名下（`owner: "luoke"`），螺壳已经有了，用户也让这个应用用。"""
        if it.kind != "needs-access":
            return False
        src = self._app(it.source)
        perm = src.permission(it.extra.get("permission")) if src is not None else None
        if perm is None or perm.get("owner") != "luoke" or self.host.get(perm["id"]) != "granted":
            return False
        return self.host_confirmed is None or perm["id"] in self.host_confirmed.get(it.source, {})

    def _withdraw(self, key: str, it: Item, now: float) -> None:
        del self.items[key]
        row = self.state.item(key)
        if row and row["status"] not in ("done", "gone"):
            self.state.set_status(key, "gone", now, "withdrawn")
        sid = it.surface_id()
        if sid not in self.done_at:
            self._drop_surface(sid)
