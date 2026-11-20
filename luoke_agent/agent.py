"""agent 的核心：收事项、画卡片、挑时机说、转点按（DESIGN §2–§5）。

来源有两种：记忆（memsource.MemorySource）和工具（toolsource.ToolSource），都有
`poll(now) -> [Item] | None | UNREAD`（None 表示没在运行，UNREAD 是在运行但这一轮没读到）和 `handle(...)`。界面（ui.py）订阅事件、送点按。
事项的内容和卡片存在本机的状态库（state.py）：核心重启后答完的卡片照样在、[撤销] 还能点。
工具也是窗口上的「应用」：基础页、权限（docs/界面接口.md §6、§10），有 `refresh_app` 的来源才算。
"""
from __future__ import annotations

import copy
import datetime as dt
import hashlib
import json
import queue
import re
import subprocess
import sys
import threading
import time
import webbrowser
from concurrent.futures import ThreadPoolExecutor
from typing import Any, Callable, Dict, List, Optional, Tuple
from urllib.parse import quote

from . import a2ui, apppages, apps, cards, diskuse, searchhits
from .items import RANK, UNREAD, Item, tool_surface_id
from .mcp import NoAnswer, NotRunning, RpcError, TimedOut
from .state import DEFAULTS as STATE_DEFAULTS, State

DONE_KEEP_SECONDS = 30 * 60      # 答完的卡片（带撤销）在窗口里留多久
LOW_ONLY_GAP = 24 * 3600         # 只有不急的事时，一天最多一份简报
LOW_PER_BRIEF = 2                # 每份简报最多带几件不急的
PRESENCE_STALE = 120             # 壳多久没报"用户在不在"就当不知道
BRIEF_MODES = ("morning", "twice", "on_open")   # 设置里能选的简报（every 只给开发用）
MORNING = "08:00"                # 没设免打扰时，早上那份从几点起
EVENING = "18:00"                # 早晚各一次时，晚上那份从几点起
MODES = ("now", "brief", "window", "off")
CLASSES = ("urgent", "decide", "done")          # 提醒的三类：急事、要你决定、替你做了（设置 classes）
CLASS_MODES = ("now", "brief", "off")           # 每类：马上提醒、放进简报、不提醒
SEARCH_LIMIT = 10                # 搜索框一次要几条
THUMBS_AT_ONCE = 2               # 向一个工具同时要几张缩略图：luoke-search 同时只画两张，多的直接答没有
THUMB_QUEUE_WAIT = 10.0          # 排队等多久（加上读的 10 秒，在窗口一个请求的 30 秒以内）
HHMM = __import__("re").compile(r"^([01]\d|2[0-3]):[0-5]\d$")
# 记忆由本体当工具起（工具协议 §2a，清单写了 `capabilities`）时的应用编号；清单有 `reports` 就用它的 outbox，
# 记忆这一路（memsource，来源 "memory"）不再拼卡片，只留给更早的、清单没写 `capabilities` 的记忆
MEMORY_TOOL = "luoke-mem"
BRIEF_WORDS_KEPT = 12 * 3600    # 简报那一段话留多久：过了就是旧事，窗口照现在的样子拼
HELLO_KEPT = 28                 # 吉祥物说过的话记几条（meta hello_recent）：一天四句，够七天
# 吉祥物一天说四回（负责人 11-17：一天一句太少）：早上、下午、晚上、深夜各定一句。几点起算哪一段；凌晨 5 点以前算前一天的深夜
HELLO_PARTS = ((5, "早上"), (11, "下午"), (17, "晚上"), (22, "深夜"))


def _reveal_in_finder(path: str) -> None:
    """在访达中选中这一项（macOS 的 `open -R`）"""
    subprocess.run(["/usr/bin/open", "-R", path], check=True, timeout=10, stdin=subprocess.DEVNULL,
                   stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)


def hello_slot(ts: float) -> Tuple[str, str]:
    """这一刻是哪一天的哪一段：（「2026-11-17 晚上」，「晚上」）"""
    t = dt.datetime.fromtimestamp(ts)
    day = (t - dt.timedelta(hours=HELLO_PARTS[0][0])).strftime("%Y-%m-%d")
    part = next((name for hour, name in reversed(HELLO_PARTS) if t.hour >= hour), HELLO_PARTS[-1][1])
    return f"{day} {part}", part

MEMORY_ITEM_PAGE = "item"        # 记忆在窗口里看一条的页（`{"id": <编号>}`），核心认 pageArgs 时卡片上「在螺壳记忆里看」去这里

Event = Tuple[str, Any]
DEFAULT_CLASSES = STATE_DEFAULTS["classes"]


def item_class(it: "Item") -> str:
    """提醒按哪一类：替你做了的（auto-done）、急事（urgent）、别的都算要你决定"""
    if it.kind == "auto-done":
        return "done"
    return "urgent" if it.urgency == "urgent" else "decide"


def parse_time(s: Optional[str]) -> Optional[float]:
    """ISO 8601；不带时区的按本机时间（工具协议 §3）。"""
    if not s:
        return None
    try:
        t = dt.datetime.fromisoformat(s.replace("Z", "+00:00"))
    except ValueError:
        return None
    return t.timestamp()


ASK_LIMIT = 3     # 「今天」每天最多问几件（负责人 2026-11-12 定）：多的先攒着，第二天再问；急事不受限


def item_time(it: Optional[Item], first_seen: Optional[float]) -> Optional[float]:
    """一件事的时间：工具给的 `created`（例如邮件的收信时间），没给或读不懂退回第一次见到它的时间。
    「今天」上写的和排序用的都是它。"""
    return (parse_time(it.created) if it is not None else None) or first_seen


def sort_key(it: Item, when: Optional[float]) -> tuple:
    """「今天」里的先后：急的在前；同样急的先按截止日；再新的在上。"""
    return (RANK.get(it.urgency, 1), parse_time(it.deadline) or float("inf"), -(when or 0.0))


# 只回了用户点的那个字的（记忆的回答）：「好」「不用」……
REPLY_WORDS = frozenset({"好", "不用", "别再提", "知道了", "是", "不是", "对", "不对", "以后再说", "以前是，现在不是"})
# 记忆答完以后的那一句（apppages/mem.py 的 SAID_REPLY、SAID_NOTE，memsource 的 SAID）：只说怎么定的，没说是哪一条
VERDICTS = frozenset({"已确认", "已否定", "已否定，不再询问", "已标记为过去的情况", "已按修改保存", "已记录", "近期不再询问", "不再询问",
                      "将在数日后再次询问", "已归档", "已归档，不计为回答，不再询问", "已标记为错误", "已删除"})
# 11-17 以前存下的口语说法（记忆自己答的、memsource 写的）：画的时候换成现在的，库不改
OLD_VERDICTS = {"记下了：对": "已确认", "记下了：不对，以后不再提": "已否定，不再询问", "记下了：以前是，现在不是": "已标记为过去的情况",
                "改好了": "已按修改保存", "好，过几天再问": "将在数日后再次询问", "记下了": "已记录", "好，这阵子不再提": "近期不再询问",
                "好，不再提这个": "不再询问"}


def done_line(result: Optional[str], title: str) -> str:
    """答完的那一行（「今天」已自动处理、右边栏的「历史」）：工具回的那句。只说了怎么定的（记忆的「已确认」，以前的「好。」
    「记下了：对。」）看不出答的是哪一条，前面带上问的那件事（负责人 11-14：历史里三个「好。」；11-17：只有「对」，没有对应条目）"""
    r = (result or "").strip()
    if not r:
        return title
    word = r.rstrip("。.！!")
    word = OLD_VERDICTS.get(word, word)
    asked = title.rstrip("？?。") if title and title != r else ""
    if word in REPLY_WORDS:
        return f"{asked} · 已选「{word}」" if asked else r
    if word in VERDICTS:
        return f"{asked} · {word}" if asked else word
    return r[:-1] if r.endswith("。") and "。" not in r[:-1] else r      # 一句话的不带句号（应用回的「已归档 2 封。」）


def iso(ts: float) -> str:
    return dt.datetime.fromtimestamp(ts).astimezone().isoformat(timespec="seconds")


def _note_id(v: Any) -> Optional[str]:
    """记忆里一条的编号（正整数）写成页参数的值；不是就是 None。"""
    if isinstance(v, bool) or not isinstance(v, (int, str)):
        return None
    t = str(v)
    return t if t.isascii() and t.isdigit() and int(t) > 0 and len(t) <= 18 else None


def rename(messages: List[dict], sid: str) -> List[dict]:
    """来源自己的 surfaceId 换成 agent 这边的（加来源前缀）。"""
    out = copy.deepcopy(messages)
    for m in out:
        for k in a2ui.MESSAGE_KINDS:
            if k in m:
                m[k]["surfaceId"] = sid
    return out


# 工具连着答错误（在运行、读不到它的事）这么久，「今天」上提一句（每分钟读一次，约 3 轮）
UNREAD_NOTICE_AFTER = 180.0



_ADDRESS = re.compile(r"^[^@\s]{1,64}@[A-Za-z0-9.-]{1,253}$")


def _looks_like_address(s: str) -> bool:
    """`authuser` 只认像邮箱地址的（一个 @，没有空白和控制字符）：别的字不往网址上拼"""
    return len(s) <= 254 and _ADDRESS.match(s) is not None and s.isprintable()

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
        self.repoll_after_tap = True     # 点完马上再读一遍那个应用；回放录好的场景时关掉（那里一步一步照录的顺序读）
        self.undone: set = set()     # 撤销过的卡片：不算做完的（「今天」不画），历史里标「已撤销」
        self.notices: Dict[str, str] = {}         # 来源 → 一句状态（「邮件助手未运行」）
        self._tapping: set = set()                # 正在处理点按的卡片
        self.notice_kinds: Dict[str, str] = {}    # 来源 → 是哪一种（stopped、stale、memory、memory_too_new、notifications、hub）
        self._unread_since: Dict[str, float] = {}  # 来源 → 从什么时候起一直读不到它的事（在运行，答了错误）
        # 记忆改由自己的 outbox 报时，旧路已经说过、看过的事：新编号列出来时回一次 shown（旧路没有 ack，记忆还不知道）
        self._owe_shown: set = set()
        self.presence: Optional[dict] = None
        self.window_open = False
        self.window_front = False                 # 窗口在最前面：用户正看着它（开着不等于看着）
        self.window_page: Optional[str] = None    # 窗口开在哪一页（today、app:<id>……）；没报是 None，当「今天」
        self.notifications: Optional[dict] = None   # 壳报的系统通知授权（只有状态）
        self.host_confirmed: Optional[Dict[str, Dict[str, str]]] = None   # 用户确认过的：{应用: {权限 id: 时间}}；没报是 None
        self.host: Dict[str, str] = {}            # 螺壳.app 报的它自己的权限状态（POST /host，只在内存里）
        self.pages: Dict[str, Tuple[str, str, a2ui.Surface]] = {}   # 基础页：<应用>/page/<页> → (应用, 页, 卡片)
        self._app_seen: Dict[str, str] = {}       # 每个应用上次报给窗口的样子：变了才发 apps 事件
        # 搜索框的结果（§7）。每次搜索问工具之前先领一个编号（search_seq 是最近领出去的）；
        # 答完时只有它还是最新的一次，才把每个应用交给窗口的 hits（应用 → 结果编号 → 结果）换上，记下它的编号（search_shown）。
        # 两次搜索同时在跑、先搜的后答完，不会盖掉后搜的。点结果上的按钮（POST /hit）、读缩略图（GET /thumb）只认 search_shown 这次的
        self.search_seq = 0
        self.search_shown = 0
        self.search_hits: Dict[str, Dict[str, dict]] = {}
        self._thumb_slots: Dict[str, threading.BoundedSemaphore] = {}   # 应用 → 向它要缩略图的名额
        self.listeners: List["queue.Queue[Event]"] = []
        self.usage = diskuse.Usage()            # 文件夹里什么最占地方（扫描「状态」页点开的文件夹）
        self.brief_wanted: Optional[float] = None   # 刚发的那一份简报（发出的时刻）：那一段话还没让模型写
        self.explain_poke = False               # 有新的要说明用途的：runner 下一轮就问，不等到点
        self.explaining = False                 # runner 正在问模型用途说明
        self.reveal_in_finder = _reveal_in_finder
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
            self.sort_keys[sid] = sort_key(it, item_time(it, st["first_seen"] if st else row["done_at"]))
            self.done_at[sid] = row["done_at"]
            if isinstance(row["item"].get("done_text"), str) and row["item"]["done_text"]:
                self.done_text[sid] = row["item"]["done_text"]
            if row["item"].get("undone") is True:
                self.undone.add(sid)
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
        if sid in self.undone:
            d["undone"] = True                       # 同上：撤销过了（负责人 11-16：撤销了的不算做完的，历史里留原来那一句）
        self.state.save_content(it.key, sid, d, entry[1].messages() if entry else None, done_at)

    # ---------------------------------------------------------------- 来源

    def add_source(self, src: Any) -> None:
        with self._lock:
            self.sources[src.source] = src
            self._check_app(src.source)

    def remove_source(self, name: str) -> None:
        with self._lock:
            self.sources.pop(name, None)
            self._unread_since.pop(name, None)
            self._merge(name, None, gone=True)
            for sid in [sid for sid, (app, _, _) in self.pages.items() if app == name]:
                del self.pages[sid]
            self._check_app(name)

    def poll(self, names: Optional[List[str]] = None) -> None:
        """读一遍来源（工具的 IO 不占锁）。"""
        for name, src in list(self.sources.items()):
            if names is not None and name not in names:
                continue
            if name == "memory" and self.memory_by_tool():
                with self._lock:          # 记忆自己报：这一路的卡片撤下，用户定过的提醒方式搬过去
                    self._hand_memory_over()
                continue
            try:
                items = src.poll(self.clock())
            except Exception as e:  # 一个来源出毛病不能拖垮别的
                print(f"luoke-agent: 读 {name} 出错 {type(e).__name__}", file=sys.stderr)
                items = None
            if isinstance(items, list):
                # 核心照原始数据拼的那几件（ADR 0028，apppages 的 `items`：邮件「已自动处理」）换掉应用自己报的
                mod = apppages.cards(src)
                if mod is not None and hasattr(mod, "items"):
                    try:
                        items = mod.items(items, src.client.read_json)
                    except Exception as e:
                        print(f"luoke-agent: {name} 的事项没拼成（{type(e).__name__}），照它自己报的", file=sys.stderr)
            with self._lock:
                if name == MEMORY_TOOL and getattr(src, "reports", None):
                    # 新出现的记忆当轮就读，旧的 memory 那一路最多要等 5 分钟才轮到：先在这里交接，同一件事不会两张卡
                    self._hand_memory_over()
                if items is UNREAD:
                    self._unread(name, src)
                else:
                    self._unread_since.pop(name, None)
                    self._merge(name, items)
                self._check_app(name)

    def _unread(self, name: str, src: Any) -> None:
        """在运行，这一轮没读到它的事（工具答了错误，工具协议 §2），持锁调：事不撤、不新加，不说它没在运行。
        连着读不到 UNREAD_NOTICE_AFTER 秒，提一句列着的可能不是最新的；读到一次（或者真没在运行）就换掉。"""
        now = self.clock()
        since = self._unread_since.setdefault(name, now)
        text = (f"{getattr(src, 'name', name)}暂时无法读取新事项"
                if now - since >= UNREAD_NOTICE_AFTER else None)
        if self.notices.get(name) != text:
            if text is None:
                self.notices.pop(name, None)
            else:
                self.notices[name] = text
                self.notice_kinds[name] = "stale"
            self._emit_feed()

    def memory_by_tool(self) -> bool:
        """记忆的事由它自己的 outbox 报：本体起的记忆（`luoke-mem`）连着这个核心，清单里有 `reports`（清单写了
        `capabilities.reports` 的工具，事都由它自己的 outbox 报，工具协议 §3）。没在运行也算：那时窗口照别的工具说它没在运行，
        不退回这边再拼一份。"""
        with self._lock:
            src = self.sources.get(MEMORY_TOOL)
            return src is not None and bool(getattr(src, "reports", None))

    def _hand_memory_over(self) -> None:
        """记忆改由它自己的 outbox 报，旧的 memory 那一路交出去（持锁调）。读到带 `reports` 的 luoke-mem 时、轮到 memory 那一路时
        都调，哪个先到哪个做，做过一遍再调什么都不变：
        - 旧路还开着的事，新编号（`luoke-mem/ask/3` 对 `memory/ask/3`，记忆的问题编号两路一样）照它到了哪一步记下：
          说过、看过的不再说一遍，在「今天」里的位置也不变；新编号已经记下的不动；
        - 旧路的卡片撤下（算撤回，只撤一次）；
        - 「设置 · 提醒」里记忆那几类改用清单 `reports` 的（`luoke-mem:question` 这些）：用户给 `memory:<类>` 定过的方式
          搬到 `luoke-mem:<类>`，那边已经定过的不动。"""
        old = [r for r in self.state.open_items() if r["source"] == "memory"]
        for row in old:
            new = MEMORY_TOOL + row["key"][len("memory"):]
            if self.state.carry(row["key"], new, MEMORY_TOOL) and row["status"] in ("notified", "seen"):
                self._owe_shown.add(new)
        if old or "memory" in self.notices or any(it.source == "memory" for it in self.items.values()):
            self._merge("memory", [])
        modes = dict(self.state.setting("modes") or {})
        old = [c for c in modes if c.startswith("memory:")]
        if not old:
            return
        for cat in old:
            modes.setdefault(MEMORY_TOOL + cat[len("memory"):], modes[cat])
            del modes[cat]
        self.state.set_setting("modes", modes)
        self._emit_settings()

    def memory_item_page(self) -> bool:
        """卡片上「在螺壳记忆里看」能不能换到窗口里记忆的那一条：核心认 pageArgs（页能带参数），记忆经本体连着、
        清单的页里有 `item`。不能就照旧打开记忆自己的界面。"""
        if "pageArgs" not in a2ui.A2UI_FEATURES:
            return False
        with self._lock:
            src = self._app(MEMORY_TOOL)
            return src is not None and any(p["id"] == MEMORY_ITEM_PAGE for p in src.service["pages"])

    def _card_of(self, src: Any, it: Item) -> List[dict]:
        """这件事画成什么卡片：核心照原始数据拼的（ADR 0028，apppages.cards；记忆想问的事），拼不出来就是来源自己的卡片"""
        mod = apppages.cards(src) if src is not None else None
        if mod is None:
            return it.card
        try:
            own = mod.card(it.key, tool_surface_id(it.card), src.client.read_json)
            if own is not None:
                a2ui.build(own)       # 拼的也要过校验：过不了就照旧
                return own
        except Exception as e:        # 读不到、拼不出来：照旧画来源自己的卡片，不让一件事没了
            print(f"luoke-agent: {it.source} 的卡片没拼成（{type(e).__name__}），照它自己的画", file=sys.stderr)
        return it.card

    def _merge(self, source: str, items: Optional[List[Item]], gone: bool = False) -> None:
        now = self.clock()
        src = self.sources.get(source)
        if items is None:
            if not gone:   # 暂时没在运行：卡片先收起来，状态不动，回来了照旧
                name = getattr(src, "name", source)
                # 界面上的一行提示：短句，不带句号；窗口照 kind 在右边放按钮（界面接口 §3 `notice_rows`）
                self.notices[source] = f"{name}未运行" if source != "memory" else "螺壳记忆无法打开"
                self.notice_kinds[source] = "stopped" if source != "memory" else "memory"
                if source == "memory" and getattr(src, "status", "") == "too_new":
                    self.notices[source] = "螺壳记忆版本较新，需更新螺壳"
                    self.notice_kinds[source] = "memory_too_new"
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
            if row["status"] == "done" and it.surface_id() in self.undone:
                # 做完以后撤销了，来源又把这一件列了出来（负责人 11-17：撤销归档以后没有回到让我选的样子）：重新开着，
                # 卡片照来源现在给的画；做完的那一句、撤销的记号都清掉
                sid = it.surface_id()
                self.state.reopen(it.key)
                self.undone.discard(sid)
                self.done_at.pop(sid, None)
                self.done_text.pop(sid, None)
                self.kept.pop(it.key, None)
                if self.surfaces.pop(sid, None) is not None:
                    self._emit("a2ui", {"version": a2ui.VERSION, "deleteSurface": {"surfaceId": sid}})
                row = self.state.item(it.key) or row
            if row["status"] in ("done", "gone"):
                continue
            keep.add(it.key)
            if it.key in self._owe_shown:     # 旧路说过、看过的（_hand_memory_over）：告诉记忆一次
                self._owe_shown.discard(it.key)
                self._ack_shown(it)
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
                    surface = a2ui.build(self._card_of(src, it))
                except a2ui.CardError:
                    continue   # 来源已经查过；查不过的不画
                had = sid in self.surfaces
                self.surfaces[sid] = (it.key, surface)
                self.sort_keys[sid] = sort_key(it, item_time(it, row["first_seen"]))
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
            self.undone.discard(sid)
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
        if sid in self.undone:
            return "undone"      # 撤销过的：不算「已自动处理」，窗口不画；右边栏「历史」里留着
        if sid in self.done_at or (it is not None and it.kind == "auto-done"):
            return "done"
        if it is not None and it.kind == "needs-access":
            return "decide"      # 要权限是要用户定的事：放「要你决定」，不管工具报的急不急（协议 §1a 默认 low）
        if it is not None and it.urgency == "urgent":
            return "urgent"
        if it is not None and it.urgency == "low":
            return "later"
        return "decide"

    def _asked_today(self, candidates: List[str]) -> set:
        """今天问哪几件：按先后挑，最多 ASK_LIMIT 件；挑过的今天一直算（答完了也占着名额，第二天重新数；
        工具撤回、过期的把名额让出来）。
        candidates：现在要问的事项（「要你决定」那一段的），已经排好先后。返回今天问的事项编号的集合。
        记在 meta 里（`asked`：{"day": "2026-11-12", "keys": […]}），没改表。"""
        day = dt.datetime.fromtimestamp(self.clock()).strftime("%Y-%m-%d")
        rec = self.state.meta("asked") or {}
        keys = list(rec["keys"]) if rec.get("day") == day and isinstance(rec.get("keys"), list) else []
        changed = rec.get("day") != day
        # 被撤回、过期的不占名额（#165：记忆从旧编号 memory/ask/N 换成 luoke-mem/ask/N，旧编号撤回了还占着三个名额，
        # 新编号被压到第二天）；用户答过、忽略的照旧占着
        held = []
        for key in keys:
            row = self.state.item(key)
            if row is not None and row["status"] == "gone" and row["outcome"] in ("withdrawn", "expired"):
                changed = True
            else:
                held.append(key)
        keys = held
        for key in candidates:
            if len(keys) >= ASK_LIMIT:
                break
            if key not in keys:
                keys.append(key)
                changed = True
        if changed:
            self.state.set_meta("asked", {"day": day, "keys": keys})
        return set(keys)

    def _cards(self) -> List[dict]:
        out = []
        order = self.order()
        # 「要你决定」的先后：今天已经问过的不动，新来的按轻重往后排，名额满了的先攒着（section 写 held，窗口不画）
        deciding = []
        for sid in order:
            key = self.surfaces[sid][0]
            it = self.items.get(key) or self.kept.get(key)
            if self._section(sid, it) == "decide":
                deciding.append(key)
        asked = self._asked_today(deciding)
        today = dt.datetime.fromtimestamp(self.clock())
        midnight = today.replace(hour=0, minute=0, second=0, microsecond=0).timestamp()
        for sid in order:
            key = self.surfaces[sid][0]
            it = self.items.get(key) or self.kept.get(key)
            row = self.state.item(key)
            when = self.done_at.get(sid) or item_time(it, row["first_seen"] if row else None)
            section = self._section(sid, it)
            if section == "decide" and key not in asked:
                section = "held"
            if section == "done" and when is not None and when < midnight:
                section = "past"     # 「已自动处理」只算今天零点以后的；以前的在右边栏「历史」里
            out.append({"id": sid, "app": it.source if it else key.split("/", 1)[0], "kind": it.kind if it else "",
                        "section": section,
                        "title": done_line(self.done_text.get(sid), it.title if it else ""),
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
        hello = self.hello()
        notice_rows = [{"id": k, "kind": self.notice_kinds.get(k, "info"), "text": t} for k, t in self.notices.items()]
        return {"order": self.order(), "open": waiting, "notices": list(self.notices.values()), "notice_rows": notice_rows,
                "hello": hello, "cards": self._cards(),
                "brief": {"next": iso(nxt) if nxt else None, "words": self.brief_words()}, "paused_until": iso(paused) if paused else None,
                "dot": self._dot()}

    def today_matters(self, urgent: bool = False) -> List[dict]:
        """今天的事，给吉祥物挑着说：「今天」上已自动处理的、待确认的各一行
        （{"id": 卡片编号, "kind": "done" | "waiting", "text": 「应用名：那一行」}）。平时那一句（`hello.py`）不带急事：
        窗口自己先说急事；简报那一段（`brief.py`）带上（`urgent=True`，kind 是 "urgent"）"""
        out = []
        kinds = {"done": "done", "decide": "waiting"}
        if urgent:
            kinds["urgent"] = "urgent"
        for row in self._cards():
            kind = kinds.get(row.get("section"))
            title = " ".join(str(row.get("title") or "").split())
            if not kind or not title:
                continue
            src = self._app(row.get("app") or "")
            name = getattr(src, "name", "") if src is not None else ""
            out.append({"id": row["id"], "kind": kind, "text": f"{name}：{title}" if name else title})
        return out

    def hello(self) -> Optional[dict]:
        """「今天」最上面吉祥物的那一句（界面规范 §14「它的一句话」：从今天的事里挑一件说，带一点性格）：这一段（早上、下午、晚上、
        深夜，`hello_slot`）定下的那一句，过了这一段就没有。句子由 `set_hello` 定（用模型照 `today_matters` 写）；
        没定就是 None，窗口只画吉祥物。记在 meta 里（`hello`：{"day"（哪一天的哪一段）, "text", "kind"}），没改表"""
        rec = self.state.meta("hello") or {}
        day = hello_slot(self.clock())[0]
        if rec.get("day") != day or not isinstance(rec.get("text"), str) or not rec["text"].strip():
            return None
        return {"text": rec["text"], "kind": rec.get("kind") or "tease"}

    def set_hello(self, text: str, kind: str = "tease", note: Any = None) -> None:
        """定下这一段的那一句（一段只说一句；空的就是这一段不说）。最长 80 个字，多的不要：宁缺毋滥。
        `note`：说的是今天的哪件事（`hello.py`，卡片编号）；记进最近说过的（meta `hello_recent`），几天内不再拿它说"""
        text = " ".join(str(text or "").split())
        text = text if 0 < len(text) <= 80 else ""
        slot = hello_slot(self.clock())[0]
        with self._lock:
            self.state.set_meta("hello", {"day": slot, "text": text, "kind": kind})
            if text and note is not None:
                kept = [r for r in self.hello_recent() if r.get("slot", r.get("day")) != slot]
                self.state.set_meta("hello_recent",
                                    (kept + [{"day": slot[:10], "slot": slot, "note": note, "text": text}])[-HELLO_KEPT:])
            self._emit_feed()

    def brief_words(self) -> Optional[str]:
        """最近这一份简报模型写的那一段话（`brief.py`）：发简报的通知以后问模型写的，记在 meta `brief_words`
        （{"brief": 哪一份（发出的时刻）, "text"}，没改表）。不是最近这一份的、过了 `BRIEF_WORDS_KEPT` 的不给；
        没有时窗口照模板拼"""
        rec = self.state.meta("brief_words") or {}
        last = float(self.state.meta("last_brief", 0))
        if not isinstance(rec.get("text"), str) or not rec["text"].strip() or rec.get("brief") != last:
            return None
        return rec["text"] if self.clock() - last <= BRIEF_WORDS_KEPT else None

    def set_brief_words(self, text: str, brief: float) -> None:
        """记下模型给 `brief` 那一份简报写的那一段；这期间又发了新的一份就不要了"""
        text = " ".join(str(text or "").split())
        with self._lock:
            if not text or len(text) > 120 or float(self.state.meta("last_brief", 0)) != brief:
                return
            self.state.set_meta("brief_words", {"brief": brief, "text": text})
            self._emit_feed()

    def explained(self) -> Dict[str, dict]:
        """占空间的文件的用途说明（`explain.py`）：{编号: {"use", "verdict", "at"}}。存在 meta `explained` 里，没改表"""
        rec = self.state.meta("explained")
        return rec if isinstance(rec, dict) else {}

    def set_explained(self, new: Dict[str, dict], limit: int = 300) -> None:
        """记下新问到的几项；多于 `limit` 项时丢最早的"""
        if not new:
            return
        now = self.clock()
        with self._lock:
            rec = dict(self.explained())
            for k, v in new.items():
                rec[k] = {"use": v["use"], "verdict": v["verdict"], "at": now}
            if len(rec) > limit:
                rec = dict(sorted(rec.items(), key=lambda kv: kv[1].get("at") or 0)[-limit:])
            self.state.set_meta("explained", rec)

    def explain_wanted(self) -> List[dict]:
        """核心自己量过的文件夹里还没说明用途的项（`explain.line` 认的形状；路径是真实路径）"""
        known = self.explained()
        from . import explain
        out = []
        for it in self.usage.known_items():
            if explain.key(it["path"], it["bytes"]) not in known:
                out.append({"path": it["path"], "bytes": it["bytes"], "lastChanged": it.get("changed"),
                            "dir": bool(it.get("dir")), "contains": list(it.get("contains") or [])})
        return out

    def _page_read(self, src: Any) -> Any:
        """拼页时读数据：应用的资源照旧向应用读；`agent/explained` 是核心自己记的用途说明"""
        def read(uri: str) -> Any:
            if uri == "agent/explained":
                return self.explained()
            if uri.startswith("agent/usage?"):
                # 一个文件夹里什么最占地方（`diskuse.py`，核心自己量）；看了就让用途说明早点来问这几项
                from urllib.parse import parse_qs
                path = (parse_qs(uri.split("?", 1)[1]).get("path") or [""])[0]
                out = self.usage.look(path)
                if any(i["bytes"] and i["key"] not in self.explained() for i in out["items"][:diskuse.SHOW]):
                    self.explain_poke = True
                # 用途说明正在问：页面隔几秒重读，问到了就带上
                out["explaining"] = bool(self.explain_poke or self.explaining)
                return out
            return src.client.read_json(uri)

        def within(uri: str, seconds: float) -> Any:
            """慢的数据（应用现去别处查的）只等这么久：没等到答 None，页上其余的照画"""
            try:
                return src.client.read_json(uri, timeout=seconds)
            except NoAnswer:
                return None
        read.within = within        # type: ignore[attr-defined]
        return read

    def hello_decided(self) -> bool:
        """这一段的那一句定过了没有（定成不说也算）：定过就不再问模型"""
        rec = self.state.meta("hello") or {}
        return rec.get("day") == hello_slot(self.clock())[0]

    def hello_recent(self, days: int = 7) -> List[dict]:
        """最近几天说过的：[{"day", "note", "text"}]，旧的在前"""
        since = (dt.datetime.fromtimestamp(self.clock()) - dt.timedelta(days=days)).strftime("%Y-%m-%d")
        return [r for r in self.state.meta("hello_recent") or [] if isinstance(r, dict) and str(r.get("day") or "") > since]

    def _dot(self) -> bool:
        """菜单栏图标要不要小点（docs/界面接口.md §3）：急事那一段里有「当场说」的那几类，主动提醒开着。
        暂停着照旧有（§9）；放进简报、只放在窗口里的急事在横幅里，不点小点。"""
        if not self.state.setting("proactive"):
            return False
        for sid, (key, _) in self.surfaces.items():
            it = self.items.get(key)
            if it is not None and self._section(sid, it) == "urgent" and self.mode(it) == "now":
                return True
        return False

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
                    "window_front": self.window_front, "window_page": self.window_page,
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
                self.notices["notifications"] = "系统通知已关闭，无法收到简报和急事提醒"
                self.notice_kinds["notifications"] = "notifications"
            else:
                self.notices.pop("notifications", None)
            if old != self.notifications:
                print(f"luoke-agent: 系统通知 {status}{'' if alerts else '（横幅关着）'}", file=sys.stderr, flush=True)
                self._emit_feed()

    def set_window(self, is_open: bool, front: Optional[bool] = None, page: Optional[str] = None) -> None:
        """`front`：窗口在最前面（壳报；老的壳不报，开着就算）。`page`：窗口开在哪一页（docs/界面接口.md §11；
        不报当「今天」）。用户看着「今天」时，现在的事项都算看过了。"""
        with self._lock:
            self.window_open = is_open
            self.window_front = is_open if front is None else bool(front) and is_open
            self.window_page = page
            self._see(self.clock())
            self._emit_feed()

    def _watching(self, now: float) -> bool:
        """用户正看着「今天」：窗口在最前面、开在「今天」，人也在（没报过在不在时信窗口）。
        最小化、切到别的应用、在别的页上、人走开都不算。"""
        return self.window_front and self.window_page in (None, "today") \
            and (self.presence is None or self._is_present(now))

    def watching_today(self) -> bool:
        """用户此刻正看着「今天」（`_watching`）"""
        with self._lock:
            return self._watching(self.clock())

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
        """这件事怎么说：逐类设过的照逐类；没设的照它属于的那一类（`classes`），「不提醒」是只放在窗口里"""
        modes = self.state.setting("modes") or {}
        return modes.get(it.category) or self._class_mode(item_class(it))

    def _class_mode(self, cls: str) -> str:
        classes = {**DEFAULT_CLASSES, **(self.state.setting("classes") or {})}
        m = classes.get(cls, "brief")
        return "window" if m == "off" else m

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
        morning = self.state.setting("brief_time") or (q["end"] if q else MORNING)
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
            # 应用的清单里已经没有的旧类别不列（邮件以前的 `tidy`：事项库里还留着几件，清单里没有它，也就没有名字，
            # 列出来是一行「这一类事」）。清单还没拿到的应用（一类名字都没有）照旧全列；现在还开着的事的那一类也留着
            declared = {c.split(":", 1)[0] for c in self.labels}
            live = {it.category for it in self.items.values()}
            seen = {c: u for c, u in seen.items() if c in self.labels or c in live or c.split(":", 1)[0] not in declared}
            if self.memory_by_tool():        # 记忆那几类照它清单的 reports（luoke-mem:…），不再列这一路的
                seen = {c: u for c, u in seen.items() if not c.startswith("memory:")}
            kinds = []
            for cat, urgent in sorted(seen.items()):
                default = self._class_mode("done" if cat.endswith(":auto-done") else "urgent" if urgent else "decide")
                kinds.append({"id": cat, "app": cat.split(":", 1)[0], "label": self._label(cat),
                              "mode": modes.get(cat, default), "default": default})
            paused = self._paused_until(self.clock())
            q = self.state.setting("quiet")
            return {"proactive": bool(self.state.setting("proactive")), "brief": self.state.setting("brief"),
                    "brief_time": self.state.setting("brief_time") or (q["end"] if q else MORNING),
                    "classes": {**DEFAULT_CLASSES, **(self.state.setting("classes") or {})},
                    "quiet": q, "paused_until": iso(paused) if paused else None,
                    "kinds": kinds, "modes": modes}

    def update_settings(self, patch: Dict[str, Any]) -> dict:
        """只改给了的几项；认不得的、值不对的抛 ValueError，什么都不改。"""
        if not isinstance(patch, dict):
            raise ValueError("要是对象")
        known = {"proactive", "brief", "brief_time", "classes", "quiet", "paused_until", "modes"}
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
        if "brief_time" in patch:
            t = patch["brief_time"]
            if t is not None and not (isinstance(t, str) and HHMM.match(t)):
                raise ValueError("brief_time 要是 null 或 HH:MM")
            todo["brief_time"] = t
        if "classes" in patch:
            c = patch["classes"]
            if not isinstance(c, dict) or not c or not all(k in CLASSES and v in CLASS_MODES for k, v in c.items()):
                raise ValueError("classes 要是 {urgent / decide / done: now / brief / off}")
            todo["classes"] = {**DEFAULT_CLASSES, **(self.state.setting("classes") or {}), **c}
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
            if "brief" in todo or "quiet" in todo or "brief_time" in todo:
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
            reread = ("memory" in self.sources or MEMORY_TOOL in self.sources) and self._brief_now(now, self._is_present(now))
        if reread:      # 简报这一下就要发：先重读记忆，待确认的可能已经自己生效了（luoke-mem 0.14）
            self.poll(["memory", MEMORY_TOOL])
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
        if self.state.setting("brief") == "every" and due is None and self._may_speak(now):
            # 开发用：第一件进来时开始计时，攒满 brief_minutes 就发
            self.state.set_meta("brief_due", now + 60 * float(self.state.setting("brief_minutes")))
            return
        if not self._brief_now(now, present):
            return
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
        self.brief_wanted = now      # 这一份的那一段话让模型写（`runner.maybe_brief_words`）

    def _brief_now(self, now: float, present: bool) -> bool:
        """有要说的话时，这一下就发简报（`_brief`；`tick` 据此先重读记忆）。不发的时候：只在打开时看、关了主动提醒、
        暂停着（打开窗口时「今天」排好）；还没攒满（开发用的 every）；这一时段的已经发过了（或者那时用户在、没什么可说），
        等下一个时刻；不在 Mac 前、免打扰时段、系统通知到不了：等。"""
        mode = self.state.setting("brief")
        if mode == "on_open" or not self._may_speak(now):
            return False
        if mode == "every":
            due = self.state.meta("brief_due")
            if due is None or now < due:
                return False
        elif self._last_slot(now) <= float(self.state.meta("last_brief", 0)):
            return False
        return present and not self._quiet(now) and self._can_notify()

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
        if src is not None and hasattr(src, "ack") and not it.extra.get("core"):    # 核心自己拼的事项工具不认识
            threading.Thread(target=src.ack, args=(it, "shown"), daemon=True).start()

    def _notify(self, nid: str, title: str, body: str, *, urgent: bool = False, silent: bool = False,
                surface: Optional[str] = None) -> None:
        self._emit("notify", {"id": nid, "title": title, "body": body, "urgent": urgent, "silent": silent,
                              "surfaceId": surface})

    def _expire(self, now: float) -> None:
        """过期的事项、答完留够了的卡片（窗口关着时）收走。收走了就在最后发一份 `feed`，收走几张都只发一次：
        窗口照 `feed` 才把删掉的卡片拿下来（docs/界面接口.md §3）。"""
        dropped = False
        for key, it in list(self.items.items()):
            exp = parse_time(it.expires)
            if exp is not None and exp <= now:
                self._merge_one_gone(key, it, now)
                dropped = True
        if not self.window_open:
            for sid, t in list(self.done_at.items()):
                if now - t > DONE_KEEP_SECONDS:
                    ik = self.surfaces.get(sid, ("",))[0]
                    self.kept.pop(ik, None)
                    self._drop_surface(sid)
                    dropped = True
            self.state.forget_old(now - 30 * 24 * 3600)
        if dropped:
            self._emit_feed()

    def _merge_one_gone(self, key: str, it: Item, now: float) -> None:
        """过期了：收走（`feed` 由 `_expire` 最后发）。"""
        del self.items[key]
        row = self.state.item(key)
        self.state.set_status(key, "gone", now, "expired")
        if row and row["status"] == "notified" and self.state.mark_batch_counted(row):
            self._ignored(it)
        self._drop_surface(it.surface_id())

    def _ignored(self, it: Item) -> None:
        """说了没理、放下了：连着几次就不再为这一类发通知，只放窗口，并说一次（DESIGN §5）。"""
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

    def set_labels(self, source: str, reports: Any) -> None:
        """清单 `reports` 里每一类的名字（「设置 · 提醒」的每类事、「以后少提醒」用）。有变的再推一次 settings：
        窗口一连上就取一次设置，那时主控可能还没答（刚开机、主控在启动，见 runner），不推的话这几行一直是「这一类事」，
        也少了没出过事的几类。"""
        new = {f"{source}:{r['kind']}": apppages.kind_name(source, r["kind"]) or r["title"]
               for r in (reports if isinstance(reports, list) else [])
               if isinstance(r, dict) and isinstance(r.get("kind"), str) and r["kind"]
               and isinstance(r.get("title"), str) and r["title"].strip()}
        with self._lock:
            changed = {k: v for k, v in new.items() if self.labels.get(k) != v}
            if not changed:
                return
            self.labels.update(changed)
            self._emit_settings()

    def _less_card(self, category: str, label: str) -> str:
        """"以后少提醒"的卡片；用户点了才收起，核心重启也画回来。卡片上的「还是提醒我」和「设置 · 提醒」里这一类的方式都能改回去。"""
        card = cards.Card("less-" + hashlib.sha256(category.encode()).hexdigest()[:12])
        card.text(f"「{label}」近期未查看，已改为仅在此处列出，不再提醒")
        card.buttons(cards.button("继续提醒", "agent.remind", {"category": category}),
                     cards.button("确定", "agent.dismiss"))
        notice = Item(key=f"agent/less/{category}", source="agent", kind="less", urgency="low",
                      title=f"已减少提醒：「{label}」", summary="", why_now="", card=card.messages())
        self.items[notice.key] = notice
        self.state.remember(notice.key, "agent", "less", "low", self.clock())
        self.state.set_status(notice.key, "seen", self.clock())   # 它自己不发通知，只放窗口
        sid = notice.surface_id()
        self.surfaces[sid] = (notice.key, a2ui.build(notice.card))
        self.sort_keys[sid] = sort_key(notice, self.clock())
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
        # 同一张卡片上一次点按还没做完：这一次不交给工具（窗口会把按钮灰掉，别的进程直接连上来的不会）
        with self._lock:
            if sid in self._tapping:
                return {"text": "正在处理", "error": True}
            self._tapping.add(sid)
        try:
            return self._tap_card(sid, component_id, client_context)
        finally:
            with self._lock:
                self._tapping.discard(sid)

    def _tap_card(self, sid: str, component_id: str, client_context: Optional[dict]) -> Dict[str, Any]:
        now = self.clock()
        with self._lock:
            entry = self.surfaces.get(sid)
            if entry is None:
                return {"text": "此卡片已失效", "error": True}
            key, surface = entry
            item = self.items.get(key) or self.kept.get(key)
            try:
                name, declared = surface.button_event(component_id)
                ctx = a2ui.merge_context(declared, client_context or {}, surface.data)
            except (a2ui.CardError, KeyError):
                return {"text": "此按钮已失效", "error": True}
            if item is None:
                return {"text": "此事项已不存在", "error": True}
            src = self.sources.get(item.source)
            undo = self._undo_button(sid)
            is_undo = sid in self.done_at and undo is not None and undo["componentId"] == component_id
            self._emit("busy", {"surfaceId": sid})
        if name.startswith("agent."):
            result = self._agent_action(item, sid, name, ctx)
        elif item.source == "memory" and name == "mem.open" and _note_id(ctx.get("note")) and self.memory_item_page():
            # 「在螺壳记忆里看」：窗口换到记忆的那一条（同 agent.open_page，带参数），不再打开记忆自己的界面
            result = self._open_page(MEMORY_TOOL, {"page": MEMORY_ITEM_PAGE, "args": {"id": _note_id(ctx.get("note"))}})
        elif item.source == "memory" and src is not None:
            result = src.handle(item, name, ctx, now)
        elif src is not None:
            mod = apppages.cards(src)
            if mod is not None and hasattr(mod, "action"):
                name, ctx = mod.action(name, ctx)     # 核心拼的卡片：选了哪一种答法，换成应用认的形状
            result = src.handle(item, name, ctx, {"componentId": component_id, "at": iso(now)})
        else:
            result = {"text": "此事项的来源当前不可用", "error": True}
        with self._lock:
            self._apply(item, sid, result, now, undo=is_undo)
        if self.repoll_after_tap and not name.startswith("agent.") and item.source != "memory" and not result.get("error") \
                and (item.extra.get("core") or result.get("done") or is_undo):
            # 点完马上再读一遍这个应用：核心拼的那一件（邮件「已自动处理」）卡片跟着换；应用的卡片做完了一部分，
            # 剩下的它会另报一件（邮箱卡片归档以后剩下的待处理），撤销了它会把原来那件重新报上来，都不等下一轮
            threading.Thread(target=self._poll_quietly, args=(item.source,), name="agent-repoll", daemon=True).start()
        return result

    def _poll_quietly(self, source: str) -> None:
        """点完以后另起的那一次读：核心正在退出（库已经关了）时不报错"""
        try:
            self.poll([source])
        except Exception as e:      # noqa: BLE001
            print(f"luoke-agent: 点完以后重读 {source} 没成（{type(e).__name__}）", file=sys.stderr)

    def _apply(self, item: Item, sid: str, result: Dict[str, Any], now: float, undo: bool = False) -> None:
        entry = self.surfaces.get(sid)
        replaced = False
        if entry is not None and result.get("card"):
            try:
                updated = a2ui.update(entry[1], result["card"])
            except a2ui.CardError:
                updated = None
            if updated is not None and updated.deleted:
                self._drop_surface(sid)       # 结果是把卡片删掉：撤卡，不留在表里（留着的话窗口重连会再画出来）
            elif updated is not None:
                replaced = True
                if undo and not result.get("error"):
                    self.undone.add(sid)      # 做完的那一句、时间都留原来的
                self.surfaces[sid] = (entry[0], updated)
                for m in rename(result["card"], sid):
                    if "updateComponents" in m:
                        m = self._present_update(m)
                    self._emit("a2ui", m)
        if result.get("done"):
            first_time = item.key in self.items
            self.state.set_status(item.key, "done", now, result.get("outcome", "answered"))
            if first_time:
                if result.get("outcome") == "dismissed":
                    self._ignored(item)        # 放下也算没理：连着够数了，这一类同样少说
                else:
                    self.state.react(item.category, "answered")
                self.kept[item.key] = self.items.pop(item.key)
                src = self.sources.get(item.source)
                if src is not None and hasattr(src, "ack") and not item.extra.get("core"):
                    threading.Thread(target=src.ack, args=(item, result.get("outcome", "answered")), daemon=True).start()
            if result.get("drop"):
                self.kept.pop(item.key, None)
                self._drop_surface(sid)
                self.state.unkeep(item.key)
            elif sid in self.surfaces:
                if sid not in self.undone:
                    self.done_at[sid] = now
                    text = result.get("text")
                    if isinstance(text, str) and text.strip() and not result.get("error"):
                        self.done_text[sid] = text.strip()[:200]
                self._save(item, sid, self.done_at.get(sid, now))
        elif replaced and item.key in self.kept:   # 例如撤销以后：卡片又变了，存下现在的样子
            text = result.get("text")
            if (sid in self.done_at and sid not in self.undone and isinstance(text, str) and text.strip()
                    and not result.get("error")):
                self.done_text[sid] = text.strip()[:200]      # 那一行也写最新做了什么
            self._save(item, sid, self.done_at.get(sid, now))
        # 卡片已经换成了结果：那句话卡片上有了，界面就不用再写一遍（replaced）
        self._emit("result", {"surfaceId": sid, "text": result.get("text", ""), "error": bool(result.get("error")),
                              "replaced": replaced})
        self._emit_feed()

    # ---------------------------------------------------------------- 历史（右边栏，docs/界面接口.md §5）

    UNDO_LABELS = ("撤销", "恢复", "放回")       # 「放回」是扫描自己那张卡片上的写法（没带 data 的旧版本）

    def activity(self, before: Optional[float] = None, app: Optional[str] = None, limit: int = 50) -> dict:
        """做过的事，从新到旧。那一句是点完以后工具回的话（卡片存下时一起存的 done_text），没有就是标题。
        卡片还在窗口里、上面有撤销（放回）的，带上要点的那个按钮"""
        with self._lock:
            rows = self.state.history(before, app, limit)
            out = []
            for r in rows[:limit]:
                item = r.get("content") or {}
                sid = r.get("sid")
                outcome = "auto" if r["kind"] == "auto-done" else "done"
                text = done_line((self.done_text.get(sid) if sid else None) or item.get("done_text"), item.get("title") or "")
                row = {"id": r["key"], "app": r["source"], "kind": r["kind"], "time": iso(r["at"]),
                       "text": text, "outcome": outcome}
                if sid is not None and sid in self.surfaces:
                    row["surface"] = sid      # 卡片还在：窗口点这一行展开它，看明细（哪几封、点得开信）
                if (sid is not None and sid in self.undone) or item.get("undone") is True:
                    row["undone"] = True      # 撤销过：那一句还是原来做了什么，不再带撤销按钮
                else:
                    undo = self._undo_button(sid)
                    if undo:
                        row["undo"] = undo
                out.append(row)
            return {"rows": out, "more": len(rows) > limit}

    def _undo_button(self, sid: Optional[str]) -> Optional[dict]:
        """卡片上写着「撤销」「放回」的那个按钮（工具的动作，不是 agent 自己的）"""
        entry = self.surfaces.get(sid) if sid else None
        if entry is None:
            return None
        comps = entry[1].components
        for cid in a2ui._reachable(comps):     # 只看画得出来的：换成结果以后旧按钮还在表里，但不在树上
            c = comps[cid]
            action = c.get("action") if isinstance(c.get("action"), dict) else {}
            event = action.get("event") if isinstance(action.get("event"), dict) else {}
            if c.get("component") != "Button" or not isinstance(event.get("name"), str) or event["name"].startswith("agent."):
                continue
            label = comps.get(c.get("child") or "", {})
            if label.get("component") == "Text" and label.get("text") in self.UNDO_LABELS:
                return {"surfaceId": sid, "componentId": cid, "label": label["text"]}
        return None

    def _present_update(self, m: dict) -> dict:
        sid = m["updateComponents"]["surfaceId"]
        fake = a2ui.Surface(sid, a2ui.AGENT_CATALOG)
        fake.components = {c["id"]: c for c in m["updateComponents"]["components"]}
        out = self._present(sid, fake)
        return next(x for x in out if "updateComponents" in x)

    def _open_url(self, ctx: dict, page: bool = False) -> Dict[str, Any]:
        """打开的网址照显示网站时那次解析重新拼出来（a2ui.open_url_site），不原样交出去。
        `page`：核心拼的页上的（界面接口 §4）：上下文多一个 `authuser`（用户在页上填的邮箱地址）时加在网址后面，
        打开的是这个地址的账号（邮件助手 data/providers 里 `account` 的链接）；没填、不像地址的不加。"""
        url = ctx.get("url")
        who = ctx.get("authuser") if page else None
        if isinstance(url, str) and isinstance(who, str) and _looks_like_address(who.strip()):
            url += ("&" if "?" in url else "?") + "authuser=" + quote(who.strip(), safe="@")
        got = a2ui.open_url_site(url)
        if got is None:
            return {"text": "这个网址打不开。", "error": True}
        site, url = got
        self.url_opener(url)
        return {"text": f"在浏览器里打开了 {site}。"}

    def _reveal(self, ctx: dict) -> Dict[str, Any]:
        """`agent.reveal`：在访达中显示一个文件或文件夹。路径重新核一遍（`diskuse.Usage.resolve`：家目录里面、存在）"""
        real = self.usage.resolve(ctx.get("item"))      # 不叫 path：按钮上下文里 {"path": …} 是取数据模型的写法
        if real is None:
            return {"text": "此项目已不存在", "error": True}
        try:
            self.reveal_in_finder(real)
        except Exception as e:
            print(f"luoke-agent: 在访达中显示没成（{type(e).__name__}）", file=sys.stderr)
            return {"text": "无法在访达中显示", "error": True}
        return {"text": ""}

    def _open_page(self, app: str, ctx: dict) -> Dict[str, Any]:
        """`agent.open_page`：只开出这张卡片、这一页的应用自己的页（清单 service.pages 里的）；别的应用的、没登记的不开。
        答复里的 `page` 交给窗口，窗口换到那一页（界面接口 §4）。`args`（§4 pageArgs）已经按点的时候的数据模型取好值，
        这里再核一遍形状，窗口读这一页时带上。"""
        page = ctx.get("page")
        with self._lock:
            src = self._app(app)
        page = apppages.alias(src, page, ctx.get("args")) if src is not None else page
        known = [p["id"] for p in apppages.pages(src, src.service["pages"])] if src is not None else []
        if not isinstance(page, str) or page not in known or not set(ctx) <= {"page", "args"}:
            return {"text": "此页无法打开", "error": True}
        args = ctx.get("args") or {}
        if a2ui.page_args_problem(args) is not None:
            long = isinstance(args, dict) and any(isinstance(v, str) and len(v) > a2ui.MAX_PAGE_ARG for v in args.values())
            return {"text": f"输入过长，最多 {a2ui.MAX_PAGE_ARG} 个字" if long else "此页无法打开", "error": True}
        out: Dict[str, Any] = {"app": app, "page": page}
        if args:
            out["args"] = dict(args)
        return {"text": "", "page": out}

    def _agent_action(self, item: Item, sid: str, name: str, ctx: dict) -> Dict[str, Any]:
        if name == "agent.open_url":
            return self._open_url(ctx)
        if name == "agent.open_page":
            return self._open_page(item.source, ctx)
        if name == "agent.dismiss":
            if item.kind == "less" and item.source == "agent":
                self._less_answered(item)
            return {"text": "已忽略", "done": True, "outcome": "dismissed" if item.source != "agent" else "answered",
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
                "pages": apppages.pages(src, [dict(p) for p in src.service["pages"]]), "ui": {"pages": [dict(p) for p in ui["pages"]]} if ui else None,
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

    def page(self, app: str, page: str, args: Optional[Dict[str, str]] = None) -> Tuple[int, dict]:
        """GET /apps/<id>/pages/<页>：读工具的 `page/<页>`，照页的规矩校验（§4：上限 400 个组件，能写 refresh、密码框）；
        画不了的换成一句纯文本。surfaceId 换成 `<应用>/page/<页>`，页上的按钮照卡片走 /action。
        `args`：带参数读（§4 pageArgs，界面接口 §6），由 ui.py 核过形状；读工具的 `page/<页>?<键>=<值>&…`。"""
        with self._lock:
            src = self._app(app)
        if src is None:
            return 404, {"error": "没有这个应用"}
        spec = next((p for p in apppages.pages(src, src.service["pages"]) if p["id"] == page), None)
        if spec is None:
            return 404, {"error": "没有这一页"}
        mod = apppages.builds(src, page)
        try:
            if mod is not None:
                # 核心照应用的原始数据拼的页（ADR 0028）
                surface = a2ui.build(mod.build(page, self._with_last(app, page, mod, dict(args or {})), self._page_read(src)),
                                     page=True)
            else:
                surface = a2ui.build(src.read_page(page, args), page=True)
        except NoAnswer:            # 在运行，只是这次读得慢：不说「未运行」
            return 503, {"error": f"{src.name}未响应"}
        except NotRunning:
            return 503, {"error": f"{src.name}未运行"}
        except (RpcError, a2ui.CardError) as e:
            n = len(e.problems) if isinstance(e, a2ui.CardError) else 1
            print(f"luoke-agent: {app} 的页 {page} 画不了：{n} 处问题", file=sys.stderr)
            card = cards.Card(page)
            card.heading(spec["title"])
            card.text("此页无法显示", caption=True)
            surface = a2ui.build(card.messages(), page=True)
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

    def _with_last(self, app: str, page: str, mod: Any, args: Dict[str, str]) -> Dict[str, str]:
        """记住这一页上次看的是哪一组（模块的 `REMEMBER_ARGS`：页 → 参数名；负责人 11-16：收件箱记住上次停在哪一组）。
        这次带了就记下；没带就把上次的放进 `_last_<名>` 交给拼页的，由它决定用不用（那一组空了可以换）。
        记在 meta 里（`page_last`），没改表"""
        keys = (getattr(mod, "REMEMBER_ARGS", None) or {}).get(page) or ()
        if not keys:
            return args
        last = dict(self.state.meta("page_last") or {})
        mine = dict(last.get(f"{app}/{page}") or {})
        given = {k: args[k] for k in keys if isinstance(args.get(k), str) and args[k]}
        if given:
            if any(mine.get(k) != v for k, v in given.items()):
                mine.update(given)
                last[f"{app}/{page}"] = mine
                self.state.set_meta("page_last", last)
            return args
        return dict(args, **{f"_last_{k}": v for k, v in mine.items() if k in keys and isinstance(v, str)})

    def search(self, query: str, limit: int = SEARCH_LIMIT) -> dict:
        """POST /search：问每个写了 `service.ask.search` 的工具，不经模型（docs/界面接口.md §7）。
        给了 `hits` 的，核过形状原样交给窗口（窗口按类型分组自己画），按钮走 POST /hit、缩略图走 GET /thumb；
        工具的 A2UI 卡片照旧校验过一起给（surfaceId 是 `<应用>/search`，按钮照基础页走 /action），只给卡片的工具窗口画卡片。
        只给结果不给卡片的工具、给的卡片画不了的工具，核心照核过的 hits 画成一张纯文本的卡片（`_hits_card`）。日志不记搜了什么、命中了什么。"""
        with self._lock:
            sources = [s for s in self._apps() if s.service["search"]]
            if not sources:
                return {"results": [], "failed": [], "text": "暂无可搜索的应用"}
            seq = self.search_seq = self.search_seq + 1
        with ThreadPoolExecutor(max_workers=len(sources)) as pool:
            answers = list(pool.map(lambda s: self._search_one(s, query, limit), sources))
        results: List[dict] = []
        failed: List[str] = []
        with self._lock:
            latest = seq == self.search_seq    # 答完前又搜了一次：这次的结果窗口不画，留下的按钮、缩略图也不换
            if latest:
                self.search_shown = seq
                self.search_hits = {}
            for src, answer in zip(sources, answers):
                if answer is False:
                    failed.append(src.name)
                elif answer is not None:
                    surface, hits = answer
                    sid = f"{src.source}/search"
                    if latest:
                        self.pages[sid] = (src.source, "search", surface)
                    r = {"app": src.source, "name": src.name, "messages": self._present(sid, surface)}
                    if hits:
                        r["hits"] = searchhits.for_window(hits)
                        if latest:
                            self.search_hits[src.source] = {h["id"]: h for h in hits}
                    results.append(r)
            return {"search": seq, "results": results, "failed": failed, "asked": len(sources)}

    def _search_one(self, src: Any, query: str, limit: int) -> Any:
        """一个工具的答复：(画得了的卡片, 核过的 hits)，只给 hits 的卡片照 hits 画；没搜到是 None；没答上来是 False。"""
        try:
            result = src.search(query, limit, at=iso(self.clock()))
            if result.is_error:
                return False
            raw = result.structured.get("hits")
            if raw == [] or (not result.card and not raw):
                return None
            hits = searchhits.hits(raw, limit)
            if any(h["actions"] for h in hits):
                hits = searchhits.only_tools(hits, src.tool_names(a["name"] for h in hits for a in h["actions"]))
            hits = [apppages.hit_words(src.source, h) for h in hits]    # 类型、位置、按钮上的字由核心写（顶层 ADR 0028）
            surface = None
            if result.card:
                try:
                    surface = a2ui.build(result.card)
                except a2ui.CardError as e:
                    if not hits:
                        raise
                    # 卡片画不了、hits 是好的：只丢卡片，旧窗口照 hits 画（新窗口有 hits 时本来就不画卡片）
                    print(f"luoke-agent: {src.source} 的搜索卡片画不了：{len(e.problems)} 处问题，照结果画", file=sys.stderr)
            return (surface if surface is not None else a2ui.build(self._hits_card(hits))), hits
        except (NotRunning, TimedOut, RpcError):
            return False
        except a2ui.CardError as e:
            print(f"luoke-agent: {src.source} 的搜索结果画不了：{len(e.problems)} 处问题", file=sys.stderr)
            return False

    def search_hit(self, search: Any, app: Any, hit: Any, action: Any) -> Dict[str, Any]:
        """POST /hit：用户点了窗口画的一条结果上的按钮（打开、在访达中显示……），或者按了回车、⌘↩。
        只认窗口正画着的那次搜索（search_shown）里这条结果给过的动作（`action` 是它在 `actions` 里的序号：同名的动作参数可以不同），
        参数从留下的结果里取，不从窗口来；转给出这条结果的工具，带 user_action。"""
        now = self.clock()
        with self._lock:
            if search != self.search_shown or isinstance(search, bool):
                return {"text": "这次搜索的结果已经换了，再搜一次。", "error": True}
            h = self.search_hits.get(app, {}).get(hit) if isinstance(app, str) and isinstance(hit, str) else None
            acts = h["actions"] if h is not None else []
            if h is None or not isinstance(action, int) or isinstance(action, bool) or not 0 <= action < len(acts):
                return {"text": "这条结果上没有这个按钮了。", "error": True}
            src = self._app(app)
            act = acts[action]
        if src is None:
            return {"text": "这个应用现在不在了。", "error": True}
        result = src.call(f"{app}/search", act["name"], dict(act["args"]), {"componentId": f"hit-{action}", "at": iso(now)})
        return {"text": result.get("text", ""), "error": bool(result.get("error"))}

    def search_thumb(self, app: str, ref: str) -> Optional[Tuple[bytes, str]]:
        """GET /thumb：窗口正画着的那次搜索里这个应用给过的缩略图，向工具读（`resources/read`，blob）。
        不是 JPEG、PNG，超过 256 KB，长边超过 2048，或者读不到，都是 None（窗口画占位框）。不写磁盘。
        窗口一屏的格子同时要，工具画满了的那张直接答没有、窗口也不再要：所以向一个工具同时最多要 THUMBS_AT_ONCE 张，
        别的在这里排队；排到时这次搜索已经换了就不要了。"""
        def given() -> bool:
            return any(h.get("thumb") == ref for h in self.search_hits.get(app, {}).values())

        with self._lock:
            src = self._app(app) if given() else None
            client = getattr(src, "client", None)
            if client is None or not searchhits.THUMB_REF.fullmatch(ref):
                return None
            # 只给真给过这张图的应用建名额：随便传一个 app= 不留东西
            slots = self._thumb_slots.setdefault(app, threading.BoundedSemaphore(THUMBS_AT_ONCE))
        if not slots.acquire(timeout=THUMB_QUEUE_WAIT):
            return None
        try:
            with self._lock:
                if not given():
                    return None
            data = client.read_blob(ref)
        except (NotRunning, TimedOut, RpcError):
            return None
        finally:
            slots.release()
        mime = searchhits.thumb_ok(data)
        return (data, mime) if mime else None

    @staticmethod
    def _hits_card(hits: List[dict]) -> List[dict]:
        """旧窗口用的卡片：工具只给 `hits` 不给卡片（工具协议 §1b 里 `card` 只是后备），或者给的卡片画不了。
        照 `searchhits.hits` 核过的结果画（和交给新窗口的是同一份）：文字一律是纯文本，每条前两个动作画成按钮，
        点了照样经 /action 转给工具。一张卡片最多 15 条，免得超过组件上限。没有结果是空的（算没答上来）。"""
        card = cards.Card("search")
        for i, h in enumerate(hits[:15]):
            if i:
                card.divider()
            card.text(h["title"])
            line = " · ".join(h[k] for k in ("line", "date") if k in h)
            if line:
                card.text(line, caption=True)
            if "snippet" in h:
                card.text(h["snippet"][:300], caption=True)
            acts = [cards.button(a["title"], a["name"], a["args"]) for a in h["actions"][:2]]
            if acts:
                card.buttons(*[dict(b, variant="borderless") for b in acts])
        return card.messages() if hits else []

    def _tap_page(self, sid: str, component_id: str, client_context: Optional[dict]) -> Dict[str, Any]:
        """基础页上的点按：转给出这一页的工具，user_action 的 surfaceId 是页 id。工具回的卡片不画：
        窗口点完会重新取这一页（docs/界面接口.md §6）。"""
        now = self.clock()
        with self._lock:
            entry = self.pages.get(sid)
            if entry is None:
                return {"text": "此页已不存在", "error": True}
            app, page, surface = entry
            try:
                name, declared = surface.button_event(component_id)
                ctx = a2ui.merge_context(declared, client_context or {}, surface.data)
            except (a2ui.CardError, KeyError):
                return {"text": "此按钮已失效", "error": True}
            src = self._app(app)
            self._emit("busy", {"surfaceId": sid})
        if name == "agent.open_url":
            result = self._open_url(ctx, page=src is not None and apppages.builds(src, page) is not None)
        elif name == "agent.reveal":
            # 在访达中显示：只认核心自己拼的页上的（应用给的页、卡片不认），只显示家目录里面有的
            result = self._reveal(ctx) if src is not None and apppages.builds(src, page) is not None \
                else {"text": "此按钮无法识别", "error": True}
        elif name == "agent.open_page":
            result = self._open_page(app, ctx)
        elif name == "agent.search":
            q = ctx.get("q").strip() if isinstance(ctx.get("q"), str) else ""
            result = {"text": "", "search": q} if q else {"text": "请输入搜索内容", "error": True}
        elif name.startswith("agent."):
            result = {"text": "此按钮无法识别", "error": True}
        elif src is None:
            result = {"text": "此应用当前不可用", "error": True}
        else:
            mod = apppages.builds(src, page)
            if mod is not None and hasattr(mod, "action"):
                name, ctx = mod.action(name, ctx)       # 核心拼的页：一组选项里选的不同，交给应用的形状不同（记忆的「以后再说」）
            result = src.call(page, name, ctx, {"componentId": component_id, "at": iso(now)})
            if mod is not None and hasattr(mod, "said"):
                words = mod.said(name, ctx, result)      # 做成了的那一句由核心写（书面说法）；没做成的照应用说的
                if words:
                    result = dict(result, text=words)
            src.refresh_app()        # 点完，概览和权限可能变了
            go = mod.after(name, result) if mod is not None and hasattr(mod, "after") else None
            if go is not None:       # 核心拼的页：点完换到哪一页（邮件加好邮箱，回到账号列表）
                moved = self._open_page(app, go)
                if moved.get("page"):
                    result = dict(result, page=moved["page"])
        out = {"text": result.get("text", ""), "error": bool(result.get("error"))}
        with self._lock:
            self._emit("result", dict(out, surfaceId=sid, replaced=False))
            self._check_app(app)
        if result.get("page"):
            out["page"] = result["page"]
        if result.get("file"):
            out["file"] = result["file"]          # 存文件（§4 saveFile）：toolsource 核过形状
        if result.get("search"):
            out["search"] = result["search"]      # agent.search：窗口拿这句去底部的搜索里搜
        return out

    def open_ui(self, app: str, page: Optional[str] = None) -> Dict[str, Any]:
        """POST /open：调工具的 `service.ui.open`（只读，由工具自己打开窗口）。
        窗口从 11-09 起不再调（应用的事都在窗口的页里做），邮件、记忆的页做好以后再看删不删。"""
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
            return {"text": f"{src.name}未运行", "error": True}
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
