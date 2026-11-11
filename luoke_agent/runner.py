"""按时读来源、挑时机（DESIGN §2、§3、§5）：工具每分钟、记忆每 5 分钟，每 5 秒看一次要不要说。窗口打开时马上全读一遍。

装了哪些工具（主控的 `GET /accessories`）每 10 秒问一次：主控没有「配件变了」的通知，问一次很便宜，答得和上次一样什么都不动，
装好、开启、停用、升级、卸载以后十秒内侧栏就跟上。主控没在运行、还在启动（答 503）时先照旧，几秒后再问：2 秒起每次翻倍，
到平常的间隔为止；主控说了多久以后再来（`retry_after`）就至少等这么久。主控不认这个版本时 5 分钟才再问。"""
from __future__ import annotations

import json
import sys
import threading
import time
from typing import Any, Dict, Optional, Set

from .agent import MEMORY_TOOL, Agent
from .hostlink import HostToken
from .toolsource import HubNotReady, HubRefused, ToolSource, discover

TICK = 5.0
TOOL_EVERY = 60.0
MEMORY_EVERY = 300.0
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
                self.agent.notices["hub"] = "这一版的 agent 还没通过螺壳的验证，暂时用不了工具。" if refused \
                    else "螺壳还没准备好，工具过一会儿列出来。" if starting else "螺壳没在运行，暂时找不到工具。"
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
            elif isinstance(cur, ToolSource):
                cur.set_manifest(f["service"], f["permissions"], f["reports"])       # 升级了：基础页、权限、每类的急不急可能变了
                self.agent.app_changed(f["accessory"])
        for name in list(self.agent.sources):
            if name not in ("memory",) and name not in self.explicit and name not in names:
                self.agent.remove_source(name)   # 卸载了
        self._hub_seen = seen
