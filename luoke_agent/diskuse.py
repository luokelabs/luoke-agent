"""一个文件夹里什么最占地方（扫描「状态」页点开一个文件夹；负责人 2026-11-17：占得最多的文件夹要能点开看）。

只看、不动：列出文件夹下面一层的每一项有多大，大的在前。扫描给出文件夹里的内容以前，由核心自己量。

- 只量家目录里面的文件夹（解析掉符号链接以后还在家目录里）；不跟符号链接，不跨到别的磁盘。
- 量在另一个线程里做，一次一个文件夹；量到哪算到哪，页面隔几秒重读就看到新的数；一个文件夹最多量 `BUDGET` 秒，
  到点没量完的那几项标成没量完。
- 结果只放在内存里（最多 `KEEP` 个文件夹、`TTL` 秒），不落盘、不进日志。

只用标准库。"""
from __future__ import annotations

import os
import stat
import threading
import time
from typing import Any, Callable, Dict, List, Optional

BUDGET = 120.0      # 一个文件夹最多量多久
TTL = 1800.0        # 量好的结果留多久
DENIED_TTL = 20.0   # 读不了的文件夹记多久
KEEP = 40           # 最多记着几个文件夹
SHOW = 12           # 一页列最大的几项
PEEK = 5            # 一个子文件夹里先看几个名字（给用途说明用）


def _size(path: str, dev: int, deadline: float, clock: Callable[[], float]) -> Optional[int]:
    """这一项占多大（字节，照实际占的块算）；到点没量完是 None"""
    total = 0
    stack = [path]
    n = 0
    while stack:
        p = stack.pop()
        try:
            with os.scandir(p) as it:
                for e in it:
                    n += 1
                    if n % 2000 == 0 and clock() > deadline:
                        return None
                    try:
                        st = e.stat(follow_symlinks=False)
                    except OSError:
                        continue
                    if st.st_dev != dev:
                        continue
                    total += st.st_blocks * 512
                    if stat.S_ISDIR(st.st_mode):
                        stack.append(e.path)
        except OSError:
            continue
    return total


class Usage:
    def __init__(self, home: Optional[str] = None, clock: Callable[[], float] = time.time):
        self.home = os.path.realpath(home or os.path.expanduser("~"))
        self.clock = clock
        self._lock = threading.Lock()
        self._results: Dict[str, dict] = {}
        self._queue: List[str] = []
        self._thread: Optional[threading.Thread] = None

    def resolve(self, path: Any) -> Optional[str]:
        """页上给的路径（`~/…` 或绝对路径）→ 家目录里面真实的路径；不在家目录里、不存在的是 None"""
        if not isinstance(path, str) or not path or "\x00" in path:
            return None
        if path == "~" or path.startswith("~/"):
            path = self.home + path[1:]
        if not os.path.isabs(path):
            return None
        real = os.path.realpath(path)
        if real != self.home and not real.startswith(self.home.rstrip("/") + "/"):
            return None
        return real if os.path.lexists(real) else None

    def short(self, real: str) -> str:
        return "~" + real[len(self.home):] if real == self.home or real.startswith(self.home + "/") else real

    def look(self, path: Any) -> dict:
        """这个文件夹现在量到哪了：{"state": "measuring" / "done" / "gone", "path": "~/…", "parent": "~/…" 或 None,
        "items": [{"name", "path", "key"（用途说明的编号）, "bytes"（没量完是 None）, "dir", "changed": "YYYY-MM-DD",
        "contains": [...]}]（大的在前）,
        "count": 一共几项, "bytes": 量到的合计, "partial": 有没有没量完的, "denied": 系统不让读}。没量过就开始量"""
        real = self.resolve(path)
        if real is None or not os.path.isdir(real):
            return {"state": "gone", "path": path if isinstance(path, str) else "", "parent": None, "items": [], "count": 0,
                    "bytes": 0, "partial": False}
        now = self.clock()
        with self._lock:
            rec = self._results.get(real)
            # 读不了的（没给权限）只记一小会儿：用户去允许了，回来再点就重新量
            if rec is None or (rec["state"] == "done" and now - rec["at"] > (DENIED_TTL if rec.get("denied") else TTL)):
                rec = {"state": "measuring", "at": now, "items": [], "count": 0}
                self._results[real] = rec
                if len(self._results) > KEEP:
                    for old in sorted((k for k in self._results if k != real), key=lambda k: self._results[k]["at"])[:len(self._results) - KEEP]:
                        self._results.pop(old, None)
                self._queue.append(real)
                if self._thread is None or not self._thread.is_alive():
                    self._thread = threading.Thread(target=self._work, name="agent-diskuse", daemon=True)
                    self._thread.start()
            items = sorted((dict(i) for i in rec["items"]), key=lambda i: -(i["bytes"] or 0))
            state, count, denied = rec["state"], rec["count"], bool(rec.get("denied"))
        parent = os.path.dirname(real)
        return {"state": state, "path": self.short(real),
                "parent": self.short(parent) if real != self.home and parent.startswith(self.home) and parent != self.home else None,
                "items": [dict(i, path=self.short(i["path"]), key=f"{i['path']}|{i['bytes'] if i['bytes'] is not None else ''}")
                          for i in items],
                "count": count, "bytes": sum(i["bytes"] or 0 for i in items), "partial": any(i["bytes"] is None for i in items),
                "denied": denied}

    def known_items(self) -> List[dict]:
        """量好的各个文件夹里最大的几项（给用途说明挑要问的）：真实路径"""
        with self._lock:
            out = []
            for rec in self._results.values():
                out += sorted((dict(i) for i in rec["items"] if i["bytes"]), key=lambda i: -i["bytes"])[:SHOW]
            return out

    def wait(self, timeout: float = 10.0) -> None:
        """等手头的量完（测试用）"""
        t = self._thread
        if t is not None:
            t.join(timeout)

    def _work(self) -> None:
        while True:
            with self._lock:
                if not self._queue:
                    self._thread = None
                    return
                real = self._queue.pop(0)
                rec = self._results.get(real)
            if rec is None:
                continue
            deadline = self.clock() + BUDGET
            try:
                dev = os.stat(real).st_dev
                with os.scandir(real) as it:
                    entries = list(it)
                denied = False
            except OSError as e:
                # 系统不让读（没有完全磁盘访问、没允许这个文件夹）和「里面是空的」是两回事
                entries, dev, denied = [], -1, isinstance(e, PermissionError)
            with self._lock:
                rec["count"] = len(entries)
                rec["denied"] = denied
            for e in entries:
                try:
                    st = e.stat(follow_symlinks=False)
                except OSError:
                    continue
                is_dir = stat.S_ISDIR(st.st_mode)
                contains: List[str] = []
                if is_dir and st.st_dev == dev:
                    size = _size(e.path, dev, deadline, self.clock) if self.clock() <= deadline else None
                    if size is not None:
                        size += st.st_blocks * 512
                    try:
                        contains = sorted(os.listdir(e.path))[:PEEK]
                    except OSError:
                        contains = []
                else:
                    size = st.st_blocks * 512
                row = {"name": e.name, "path": e.path, "bytes": size, "dir": is_dir,
                       "changed": time.strftime("%Y-%m-%d", time.localtime(st.st_mtime)), "contains": contains}
                with self._lock:
                    rec["items"].append(row)
            with self._lock:
                rec["state"], rec["at"] = "done", self.clock()
