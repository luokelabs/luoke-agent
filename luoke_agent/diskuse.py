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
FILES = 10          # 整个文件夹里（不管在第几层）记最大的几个文件
KIND_DIRS = 8       # 每种文件列在哪几个文件夹里（占得最多的几个）

# 文件是哪一种，照扩展名分（负责人 2026-11-20：点开只看到一堆看不懂的子文件夹，不知道里面是什么）。代号，页上的字由页写
KINDS = {"video": ("mov", "mp4", "m4v", "avi", "mkv", "webm", "wmv", "flv", "ts"),
         "photo": ("jpg", "jpeg", "png", "heic", "heif", "gif", "tif", "tiff", "dng", "cr2", "cr3", "nef", "arw", "raw", "webp", "bmp", "psd"),
         "audio": ("mp3", "m4a", "wav", "flac", "aac", "aiff", "caf", "amr", "opus", "ogg"),
         "document": ("pdf", "doc", "docx", "xls", "xlsx", "ppt", "pptx", "key", "pages", "numbers", "txt", "md", "rtf", "epub", "csv"),
         "archive": ("zip", "dmg", "pkg", "tar", "gz", "tgz", "bz2", "xz", "7z", "rar", "iso", "xip", "ipsw"),
         "model": ("gguf", "safetensors", "mlmodel", "mlpackage", "onnx", "ckpt", "pt", "pth"),
         "database": ("db", "sqlite", "sqlite3", "sqlite-wal", "db-wal", "storedata", "realm")}
_KIND_OF = {ext: kind for kind, exts in KINDS.items() for ext in exts}


def kind_of(name: str) -> str:
    """文件名 → 种类的代号（认不出的是 other）"""
    return _KIND_OF.get(name.rsplit(".", 1)[-1].lower() if "." in name else "", "other")


class Tally:
    """量一项时顺手记下的：每种文件占多少、每年改的占多少、最大的几个文件"""

    def __init__(self) -> None:
        self.kinds: Dict[str, List[int]] = {}       # 种类 → [字节, 个数]
        self.years: Dict[int, int] = {}             # 哪年改的 → 字节
        self.files: List[tuple] = []                # (字节, 路径, 改的时间)，最大的 FILES 个
        # 种类 → 所在的文件夹 → [字节, 个数]（负责人 11-21：「模型 807 GB」却只看到 8 GB 的文件，要看到是哪几个模型占的）
        self.dirs: Dict[str, Dict[str, List[int]]] = {}

    def add(self, path: str, name: str, size: int, mtime: float) -> None:
        kind = kind_of(name)
        k = self.kinds.setdefault(kind, [0, 0])
        k[0] += size
        k[1] += 1
        d = self.dirs.setdefault(kind, {}).setdefault(os.path.dirname(path), [0, 0])
        d[0] += size
        d[1] += 1
        year = time.localtime(mtime).tm_year
        self.years[year] = self.years.get(year, 0) + size
        if len(self.files) < FILES or size > self.files[-1][0]:
            self.files.append((size, path, mtime))
            self.files.sort(key=lambda f: -f[0])
            del self.files[FILES:]

    def merge(self, other: "Tally") -> None:
        for kind, (b, n) in other.kinds.items():
            k = self.kinds.setdefault(kind, [0, 0])
            k[0] += b
            k[1] += n
        for year, b in other.years.items():
            self.years[year] = self.years.get(year, 0) + b
        self.files = sorted(self.files + other.files, key=lambda f: -f[0])[:FILES]
        for kind, ds in other.dirs.items():
            mine = self.dirs.setdefault(kind, {})
            for d, (b, n) in ds.items():
                m = mine.setdefault(d, [0, 0])
                m[0] += b
                m[1] += n


def _size(path: str, dev: int, deadline: float, clock: Callable[[], float], tally: Optional[Tally] = None) -> Optional[int]:
    """这一项占多大（字节，照实际占的块算）；到点没量完是 None。给了 `tally` 就顺手记下里面每个文件的种类、年份和最大的几个"""
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
                    elif tally is not None and stat.S_ISREG(st.st_mode):
                        tally.add(e.path, e.name, st.st_blocks * 512, st.st_mtime)
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
        "count": 一共几项, "bytes": 量到的合计, "partial": 有没有没量完的, "denied": 系统不让读,
        "kinds": [{"kind": 种类的代号, "bytes", "count", "dirs": [{"path", "bytes", "count"}]（这种文件占得最多的几个所在文件夹）}]（整个文件夹里每种文件占多少，大的在前）,
        "years": [{"year", "bytes"}]（哪年改的，新的在前）,
        "files": [{"name", "path", "bytes", "changed", "in": 所在的文件夹}]（不管在第几层，最大的几个文件）}。没量过就开始量"""
        real = self.resolve(path)
        if real is None or not os.path.isdir(real):
            return {"state": "gone", "path": path if isinstance(path, str) else "", "parent": None, "items": [], "count": 0,
                    "bytes": 0, "partial": False, "kinds": [], "years": [], "files": []}
        now = self.clock()
        with self._lock:
            rec = self._results.get(real)
            # 读不了的（没给权限）只记一小会儿：用户去允许了，回来再点就重新量
            if rec is None or (rec["state"] == "done" and now - rec["at"] > (DENIED_TTL if rec.get("denied") else TTL)):
                rec = {"state": "measuring", "at": now, "items": [], "count": 0, "tally": Tally()}
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
            tally: Tally = rec["tally"]
            kinds = sorted(({"kind": k, "bytes": b, "count": n,
                             "dirs": [{"path": self.short(d), "bytes": db, "count": dn} for d, (db, dn) in
                                      sorted(tally.dirs.get(k, {}).items(), key=lambda x: -x[1][0])[:KIND_DIRS] if db]}
                            for k, (b, n) in tally.kinds.items() if b), key=lambda k: -k["bytes"])
            years = [{"year": y, "bytes": b} for y, b in sorted(tally.years.items(), reverse=True) if b]
            files = [{"name": os.path.basename(f[1]), "path": self.short(f[1]), "bytes": f[0],
                      "changed": time.strftime("%Y-%m-%d", time.localtime(f[2])),
                      "in": self.short(os.path.dirname(f[1]))} for f in tally.files]
        parent = os.path.dirname(real)
        return {"state": state, "path": self.short(real),
                "parent": self.short(parent) if real != self.home and parent.startswith(self.home) and parent != self.home else None,
                "items": [dict(i, path=self.short(i["path"]), key=f"{i['path']}|{i['bytes'] if i['bytes'] is not None else ''}")
                          for i in items],
                "count": count, "bytes": sum(i["bytes"] or 0 for i in items), "partial": any(i["bytes"] is None for i in items),
                "denied": denied, "kinds": kinds, "years": years, "files": files}

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
                tally = Tally()
                if is_dir and st.st_dev == dev:
                    size = _size(e.path, dev, deadline, self.clock, tally) if self.clock() <= deadline else None
                    if size is not None:
                        size += st.st_blocks * 512
                    try:
                        contains = sorted(os.listdir(e.path))[:PEEK]
                    except OSError:
                        contains = []
                else:
                    size = st.st_blocks * 512
                    if stat.S_ISREG(st.st_mode):
                        tally.add(e.path, e.name, size, st.st_mtime)
                row = {"name": e.name, "path": e.path, "bytes": size, "dir": is_dir,
                       "changed": time.strftime("%Y-%m-%d", time.localtime(st.st_mtime)), "contains": contains}
                with self._lock:
                    rec["items"].append(row)
                    rec["tally"].merge(tally)
            with self._lock:
                rec["state"], rec["at"] = "done", self.clock()
