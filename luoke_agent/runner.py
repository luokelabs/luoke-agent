"""按时读来源、挑时机（DESIGN §2、§3、§5）：工具每分钟、记忆每 5 分钟，每 5 秒看一次要不要说。窗口打开时马上全读一遍。

装了哪些工具（主控的 `GET /accessories`）每 10 秒问一次：主控没有「配件变了」的通知，问一次很便宜，答得和上次一样什么都不动，
装好、开启、停用、升级、卸载以后十秒内侧栏就跟上。主控没在运行、还在启动（答 503）时先照旧，几秒后再问：2 秒起每次翻倍，
到平常的间隔为止；主控说了多久以后再来（`retry_after`）就至少等这么久。主控不认这个版本时 5 分钟才再问。"""
from __future__ import annotations

import datetime as dt
import json
import sys
import threading
import time
from typing import Any, Dict, Optional, Set

from . import hub as hubmod
from .agent import MEMORY_TOOL, Agent
from .hostlink import HostToken
from .toolsource import HubNotReady, HubRefused, ToolSource, discover

TICK = 5.0
TOOL_EVERY = 60.0
MEMORY_EVERY = 300.0
HELLO_FIRST = 60.0        # 起来多久以后才想吉祥物的那一句（先让工具接上）
EXPLAIN_FIRST = 90.0      # 起来多久以后才做占空间文件的用途说明
EXPLAIN_RETRY = 1800.0    # 没有要说明的、没做成：过多久再看
EXPLAIN_NEXT = 60.0       # 还有没说明的：隔多久问下一批
BRIEF_WORDS_RETRY = 300.0 # 简报那一段话没问成：过多久再试（主控给了时间照它的）
BRIEF_WORDS_FOR = 1800.0  # 一份简报发出去多久以内还问那一段话
HELLO_RETRY = 1800.0      # 主控说现在不行、没做成：过多久再试（它给了时间就照它的，至少这么久）
HUB_EVERY = 10.0          # 问主控装了哪些工具
HUB_RETRY = 2.0           # 问不到：先等这么久，每次翻倍，到 HUB_EVERY 为止
HUB_REFUSED_EVERY = 300.0  # 主控不认这个版本：要等主控换配方，不用勤问
HUB_WAIT_MAX = 300.0      # 主控说的 retry_after 最多信这么久


class Runner(threading.Thread):
    def __init__(self, agent: Agent, *, hub: Optional[str] = None, explicit_tools: Optional[Set[str]] = None,
                 clock=time.monotonic, home: Optional[str] = None, host: Any = None):
        super().__init__(name="agent-runner", daemon=True)
        self.agent = agent
        self.hub = hub
        self.host = host                     # 本体给的通道（hostlink.HostLink）：有它才接 stdio 的工具
        self.home = home                     # 清单里 ~ 展开成哪（测试用；平时是本账户的主目录）
        self.explicit = set(explicit_tools or ())
        self.clock = clock
        self.last: Dict[str, float] = {}
        self.wake = threading.Event()
        self.stopping = threading.Event()
        self._now_all = True
        self.next_hub = 0.0                  # 什么时候再问主控（self.clock 的时间）
        self.hub_misses = 0                  # 连着几次没问到
        self._hub_seen: Optional[str] = None  # 上次换上的工具清单：一样就不动
        self.next_hello = clock() + HELLO_FIRST   # 什么时候再想吉祥物的那一句
        self._hello_thread: Optional[threading.Thread] = None
        self.next_brief_words = 0.0               # 简报那一段话什么时候再问
        self._brief_thread: Optional[threading.Thread] = None
        self._brief_waited: Optional[float] = None    # 哪一份简报已经按「用户在等」补问过
        self.next_explain = clock() + EXPLAIN_FIRST   # 什么时候再做占空间文件的用途说明
        self._explain_thread: Optional[threading.Thread] = None
        self._explain_tried: set = set()

    def poll_soon(self) -> None:
        self._now_all = True
        self.wake.set()

    def stop(self) -> None:
        self.stopping.set()
        self.wake.set()

    def run(self) -> None:
        while not self.stopping.is_set():
            try:
                self.step()
            except Exception as e:  # 一轮出错不停
                print(f"luoke-agent: 这一轮出错 {type(e).__name__}", file=sys.stderr)
            self.wake.wait(self.nap())
            self.wake.clear()

    def nap(self) -> float:
        """睡多久：平时一个 TICK，主控那边要早点再问时睡到那时。"""
        if not self.hub:
            return TICK
        return max(0.5, min(TICK, self.next_hub - self.clock()))

    def step(self) -> None:
        now = self.clock()
        everything, self._now_all = self._now_all, False
        if self.hub and (everything or now >= self.next_hub):
            self.refresh_tools()
        due = []
        for name in list(self.agent.sources):
            every = MEMORY_EVERY if name in ("memory", MEMORY_TOOL) else TOOL_EVERY   # 记忆的事不急：本体起的记忆也照它
            if everything or now - self.last.get(name, -1e9) >= every:
                self.last[name] = now
                due.append(name)
        if due:
            self.agent.poll(due)
        self.agent.tick()
        self.maybe_hello(now)
        self.maybe_brief_words(now)
        self.maybe_explain(now)

    def maybe_explain(self, now: float) -> None:
        """占空间的文件的用途说明（`explain.py`，扫描「状态」页）：接着主控、扫描给了大文件的清单、里面有还没说明的，
        在另一个线程里问一次模型（一次几项）。问到的记下，下次打开那一页就带上；没做成过 `EXPLAIN_RETRY` 再试"""
        poked = bool(getattr(self.agent, "explain_poke", False))     # 用户刚点开一个文件夹：不等到点
        if not self.hub or (now < self.next_explain and not poked) or (self._explain_thread and self._explain_thread.is_alive()):
            return
        self.agent.explain_poke = False
        self.next_explain = now + EXPLAIN_RETRY
        scan = self.agent.sources.get("luoke-scan")
        try:
            from . import explain   # 用到时才读提示词文件
            known = self.agent.explained()
            # 先问用户正在看的（核心自己量的文件夹里的项），再问扫描的大文件
            tried = self._explain_tried
            todo = [it for it in (self.agent.explain_wanted() if hasattr(self.agent, "explain_wanted") else [])
                    if explain.key(it["path"], it.get("bytes")) not in tried][:explain.MAX_ITEMS]
            looking = bool(todo) and poked      # 这一批是用户刚点开的文件夹里的：他正看着，不当后台任务排
            d = scan.client.read_json("data/category?id=large-file") \
                if scan is not None and "category" in (getattr(scan, "data", None) or []) and len(todo) < explain.MAX_ITEMS else None
            for it in (d.get("items") if isinstance(d, dict) else None) or []:
                if len(todo) >= explain.MAX_ITEMS:
                    break
                path = it.get("path") if isinstance(it, dict) else None
                if not isinstance(path, str) or not path or explain.key(path, it.get("bytes")) in known \
                        or explain.key(path, it.get("bytes")) in tried:
                    continue
                todo.append(dict({"path": path, "bytes": it.get("bytes")}, **{k: v for k, v in (it.get("facts") or {}).items()
                                                                         if k in ("lastOpened", "neverOpened", "lastChanged")}))
                if len(todo) >= explain.MAX_ITEMS:
                    break
            if not todo:
                return
        except Exception as e:
            print(f"luoke-agent: 用途说明没准备成（{type(e).__name__}）", file=sys.stderr)
            return
        self.next_explain = now + EXPLAIN_NEXT      # 还有没说明的：这一批做完接着下一批
        self.agent.explaining = True
        self._explain_thread = threading.Thread(target=self._explain, args=(todo, looking), name="agent-explain", daemon=True)
        self._explain_thread.start()

    def _explain(self, todo: list, looking: bool = False) -> None:
        try:
            self._explain_once(todo, looking)
        finally:
            self.agent.explaining = False

    def _explain_once(self, todo: list, looking: bool) -> None:
        try:
            from . import explain
            got = explain.ask(hubmod.Hub(self.hub), todo, waiting=True) if looking else explain.ask(hubmod.Hub(self.hub), todo)
            if self.stopping.is_set():
                return
            if looking and got:
                self.agent.explain_poke = True      # 这个文件夹里还有没说明的：接着问下一批，不等一分钟
            # 答得合规矩的记下；没答好的不记，下次再问
            self.agent.set_explained(got, explain.KEPT)
            # 这一次没答好的，这次运行里不再问（不然每分钟白问一遍）；重启以后再试
            self._explain_tried.update(k for k in (explain.key(it["path"], it.get("bytes")) for it in todo) if k not in got)
            if len(got) < len(todo):
                self.next_explain = max(self.next_explain, self.clock() + EXPLAIN_RETRY)   # 有几项没答好：不马上重问
        except hubmod.Later as e:
            self.next_explain = max(self.next_explain, self.clock() + (e.retry_after or EXPLAIN_RETRY))
        except hubmod.HubError as e:
            self.next_explain = max(self.next_explain, self.clock() + EXPLAIN_RETRY)
            print(f"luoke-agent: 用途说明没做成（{e.code}）", file=sys.stderr)   # 只记原因代号，不带内容
        except Exception as e:
            print(f"luoke-agent: 用途说明没做成（{type(e).__name__}）", file=sys.stderr)

    def maybe_brief_words(self, now: float) -> None:
        """简报那一段话（`brief.py`）：刚发了一份简报的通知、接着主控，就在另一个线程里按后台任务问一次模型
        （那一刻没有人在等）。今天的事在这一轮里（这个线程）读好。主控说现在不行就照它说的过一阵再问，
        这一份发出去超过 `BRIEF_WORDS_FOR` 还没问成就算了：窗口照模板拼。
        还没问成用户就打开了「今天」：这时人在等，不等到点，补问一次「用户在等」（一份简报只补问一次）"""
        sent = getattr(self.agent, "brief_wanted", None)
        if sent is None or not self.hub or (self._brief_thread and self._brief_thread.is_alive()):
            return
        if self.agent.clock() - sent > BRIEF_WORDS_FOR:
            self.agent.brief_wanted = None
            return
        waiting = self._brief_waited != sent and self.agent.watching_today()
        if not waiting and now < self.next_brief_words:
            return
        if waiting:
            self._brief_waited = sent
        self.next_brief_words = now + BRIEF_WORDS_RETRY
        try:
            from . import brief, hello      # 用到时才读提示词文件：包里缺了它们，只是没有这一段
            from .agent import hello_slot
            matters = self.agent.today_matters(urgent=True)
            if not brief.usable(matters):
                self.agent.brief_wanted = None
                return
            day = hello_slot(self.agent.clock())[0]
            today = hello.today_words(day, dt.date.fromisoformat(day[:10]).weekday())
        except Exception as e:
            self.agent.brief_wanted = None
            print(f"luoke-agent: 简报那一段没准备成（{type(e).__name__}）", file=sys.stderr)
            return
        self._brief_thread = threading.Thread(target=self._brief_words, args=(sent, matters, today, waiting), name="agent-brief", daemon=True)
        self._brief_thread.start()

    def _brief_words(self, sent: float, matters: list, today: str, waiting: bool = False) -> None:
        try:
            from . import brief
            text = brief.ask(hubmod.Hub(self.hub), matters, today, waiting=waiting)
            if self.stopping.is_set():
                return                                  # 正在退出：库可能已经关了，不写
            if self.agent.brief_wanted == sent:
                self.agent.brief_wanted = None          # 问到了（答得不合规矩也算）：这一份不再问
            self.agent.set_brief_words(text, sent)
        except hubmod.Later as e:
            if e.retry_after:
                self.next_brief_words = max(self.next_brief_words, self.clock() + e.retry_after)
        except hubmod.HubError as e:
            if self.agent.brief_wanted == sent:
                self.agent.brief_wanted = None
            print(f"luoke-agent: 简报那一段没做成（{e.code}）", file=sys.stderr)   # 只记原因代号，不带内容
        except Exception as e:
            print(f"luoke-agent: 简报那一段出错 {type(e).__name__}", file=sys.stderr)

    def maybe_hello(self, now: float) -> None:
        """吉祥物这一段的那一句（`hello.py`）：这一段还没定、接着主控、今天有事可说时，在另一个线程里问一次模型
        （生成要几秒到几十秒，不挡这一轮）。主控说现在不行、没做成、今天还没有事，过 `HELLO_RETRY` 再试；定下了这一段就不再问"""
        if not self.hub or now < self.next_hello or (self._hello_thread and self._hello_thread.is_alive()):
            return
        self.next_hello = now + HELLO_RETRY
        if self.agent.hello_decided():
            return
        # 事项库在这一轮里（这个线程）读写：另一个线程只问主控，问到了才回来写一次那一句。
        # 两边共用 SQLite 连接，这边关了库、那边还在查，解释器会崩（2026-11-17 在 Python 3.15 上崩过）
        try:
            from . import hello     # 用到时才读提示词文件（luoke_agent/prompts/）：包里缺了它们，只是没有这一句
            notes = self.agent.today_matters()
            from .agent import hello_slot
            today = dt.datetime.fromtimestamp(self.agent.clock())
            # 一天四段各一句：照「哪一天的哪一段」轮着挑，提示里也写上是哪一段
            day, recent = hello_slot(self.agent.clock())[0], self.agent.hello_recent(hello.RECENT_DAYS)
            listed = hello.prepare(notes, recent, day)
            if not listed:
                return                                  # 今天还没有能说的事（或者都说过了）：不问模型，也不定下，过一阵有了事再来
        except Exception as e:
            print(f"luoke-agent: 吉祥物的那一句没准备成（{type(e).__name__}）", file=sys.stderr)
            return
        self._hello_thread = threading.Thread(target=self._hello, args=(listed, recent, day, dt.date.fromisoformat(day[:10]).weekday()),
                                              name="agent-hello", daemon=True)
        self._hello_thread.start()

    def _hello(self, listed: list, recent: list, day: str, weekday: int) -> None:
        try:
            from . import hello
            note, text = hello.ask(hubmod.Hub(self.hub), listed, recent, day, weekday)
            if self.stopping.is_set():
                return                                  # 正在退出：库可能已经关了，不写
            # 模型说不说、答得不合规矩：今天也定成不说（宁缺毋滥，不重试）
            self.agent.set_hello(text, note=note)
        except hubmod.Later as e:
            if e.retry_after:
                self.next_hello = max(self.next_hello, self.clock() + e.retry_after)
        except hubmod.HubError as e:
            print(f"luoke-agent: 吉祥物的那一句没做成（{e.code}）", file=sys.stderr)   # 只记原因代号，不带内容
        except Exception as e:
            print(f"luoke-agent: 吉祥物的那一句出错 {type(e).__name__}", file=sys.stderr)

    def refresh_tools(self) -> None:
        """问主控装了哪些工具，变了才换（DESIGN §3）。问不到就先照旧，定好下次什么时候再问（见文件头）。"""
        refused, starting, wait = False, False, None
        try:
            found = discover(self.hub, home=self.home, stdio=self.host is not None) if self.hub else None
        except HubRefused:
            found, refused = None, True
        except HubNotReady as e:
            found, starting, wait = None, True, e.retry_after
        now = self.clock()
        if found is None:
            self.hub_misses += 1
            delay = HUB_REFUSED_EVERY if refused else min(HUB_EVERY, HUB_RETRY * 2 ** min(self.hub_misses - 1, 16))
            if wait is not None:
                delay = max(delay, min(wait, HUB_WAIT_MAX))
            self.next_hub = now + delay
        else:
            self.hub_misses = 0
            self.next_hub = now + HUB_EVERY
        with self.agent._lock:
            was = self.agent.notices.get("hub")
            if found is None:
                self.agent.notices["hub"] = "此版本未通过螺壳验证，暂时无法使用应用" if refused \
                    else "螺壳正在准备，应用稍后列出" if starting else "螺壳未运行，暂时找不到应用"
                self.agent.notice_kinds["hub"] = "hub"
            else:
                self.agent.notices.pop("hub", None)
            if self.agent.notices.get("hub") != was:
                self.agent._emit_feed()       # 「今天」里那一句跟着换，不等下一件事
        if found is None:
            return
        seen = json.dumps(found, sort_keys=True, ensure_ascii=False, default=str)
        if seen == self._hub_seen:
            return
        names = set()
        for f in found:
            names.add(f["accessory"])
            self.agent.set_labels(f["accessory"], f["reports"])
            cur = self.agent.sources.get(f["accessory"])
            if f["accessory"] in self.explicit:
                if isinstance(cur, ToolSource):     # 显式给的只换 socket，清单照主控的
                    if f["service"] is not None or f["permissions"] is not None:
                        cur.set_manifest(f["service"], f["permissions"])
                    cur.set_reports(f["reports"])
                    self.agent.app_changed(f["accessory"])
                continue
            piped = f.get("transport") == "stdio"
            where = f"stdio:{f['accessory']}" if piped else f["socket"]
            if cur is None or getattr(cur, "socket_path", None) != where:
                opener = (lambda acc=f["accessory"]: self.host.open(acc)) if piped else None
                # 开 socket 的工具：有本体的通道就向它要口令（只有螺壳搜索有，别的问一次要不到就不再问，hostlink.HostToken）
                token = HostToken(self.host, f["accessory"]).get if self.host is not None and not piped else None
                self.agent.add_source(ToolSource(f["accessory"], where, name=f["name"], reports=f["reports"],
                                                 socket_dirs=None if piped else f.get("socket_dirs"), home=f.get("home"),
                                                 service=f["service"], permissions=f["permissions"], opener=opener,
                                                 token=token))
                self.agent.sources[f["accessory"]].data = f.get("data") or []
            elif isinstance(cur, ToolSource):
                cur.set_manifest(f["service"], f["permissions"], f["reports"])       # 升级了：基础页、权限、每类的急不急可能变了
                cur.data = f.get("data") or []
                self.agent.app_changed(f["accessory"])
        for name in list(self.agent.sources):
            if name not in ("memory",) and name not in self.explicit and name not in names:
                self.agent.remove_source(name)   # 卸载了
        self._hub_seen = seen
