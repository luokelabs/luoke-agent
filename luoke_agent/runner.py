"""按时读来源、挑时机（DESIGN §2、§3、§5）：工具每分钟、记忆每 5 分钟、主控（装了哪些工具）每 5 分钟，
每 5 秒看一次要不要说。窗口打开时马上全读一遍。"""
from __future__ import annotations

import sys
import threading
import time
from typing import Any, Dict, Optional, Set

from .agent import Agent
from .toolsource import HubRefused, ToolSource, discover

TICK = 5.0
TOOL_EVERY = 60.0
MEMORY_EVERY = 300.0
HUB_EVERY = 300.0


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
            self.wake.wait(TICK)
            self.wake.clear()

    def step(self) -> None:
        now = self.clock()
        everything, self._now_all = self._now_all, False
        if self.hub and (everything or now - self.last.get("hub", -1e9) >= HUB_EVERY):
            self.last["hub"] = now
            self.refresh_tools()
        due = []
        for name in list(self.agent.sources):
            every = MEMORY_EVERY if name == "memory" else TOOL_EVERY
            if everything or now - self.last.get(name, -1e9) >= every:
                self.last[name] = now
                due.append(name)
        brief_due = self.agent.state.meta("brief_due")
        if brief_due and self.agent.clock() >= brief_due - TICK and "memory" in self.agent.sources \
                and "memory" not in due:
            due.append("memory")      # 简报出发前重读：待确认的可能已经自己生效了（luoke-mem 0.14）
        if due:
            self.agent.poll(due)
        self.agent.tick()

    def refresh_tools(self) -> None:
        """问主控装了哪些工具；主控没在运行就先照旧（DESIGN §3）。"""
        refused = False
        try:
            found = discover(self.hub, home=self.home, stdio=self.host is not None) if self.hub else None
        except HubRefused:
            found, refused = None, True
        with self.agent._lock:
            if found is None:
                self.agent.notices["hub"] = "这一版的 agent 还没通过螺壳的验证，暂时用不了工具。" if refused \
                    else "螺壳没在运行，暂时找不到工具。"
                return
            self.agent.notices.pop("hub", None)
        names = set()
        for f in found:
            names.add(f["accessory"])
            for r in f["reports"]:
                if isinstance(r, dict) and r.get("kind") and r.get("title"):
                    self.agent.labels[f"{f['accessory']}:{r['kind']}"] = r["title"]
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
                self.agent.add_source(ToolSource(f["accessory"], where, name=f["name"], reports=f["reports"],
                                                 socket_dirs=None if piped else f.get("socket_dirs"), home=f.get("home"),
                                                 service=f["service"], permissions=f["permissions"], opener=opener))
            elif isinstance(cur, ToolSource):
                cur.set_manifest(f["service"], f["permissions"], f["reports"])       # 升级了：基础页、权限、每类的急不急可能变了
                self.agent.app_changed(f["accessory"])
        for name in list(self.agent.sources):
            if name not in ("memory",) and name not in self.explicit and name not in names:
                self.agent.remove_source(name)   # 卸载了
