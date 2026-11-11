"""向螺壳本体要工具的连接（docs/工具协议.md §2a、docs/界面接口.md §15）。

有的工具不开 socket，由螺壳本体当子进程起，标准输入输出就是连接（螺壳扫描的 Go 版：`luoke-scan mcp`）。本体起 agent 核心时
给它一条私有通道：一对 Unix socketpair 的一端当核心的标准输入（`serve --host-stdin`）。没有文件路径，只有本体和它起的这个核心
拿得到。核心要连这样的工具时，在通道上写一行 `{"id": N, "open": "<配件>"}`；本体核对过（是它带着的、用户开着、签名对）就起一次
工具，把连到工具标准输入输出的那一端随回复 `{"id": N, "ok": true}` 一起交过来（SCM_RIGHTS），不给就回 `{"id": N, "error": "…"}`。
每个请求要一次（§2：每个请求一条连接）：写完请求就关掉写的一头（工具读到结尾就退出），读完回复再关。
本体交出去以后，自己那一份要留到工具进程退出再关：交出去马上关的话，macOS 可能把还在路上的 socket 当没人要的收掉，
这边拿到的就是一条断了的连接（11-05 测过：马上关时 960 次里断 14 次，留着 3840 次一次没断）。

螺壳搜索是常驻的，自己开 socket，但发布版只认带着口令的请求（本体每次起它时新生成一个）：核心在同一条通道上写
`{"id": N, "token": "luoke-search"}` 要，本体回 `{"id": N, "token": "…"}`（不带 ok，不会和 open 的回复搞混），
每个请求在 `_meta` 里带上（mcp.py 的 TOKEN_META）。搜索重起过口令就换了，它答「口令不对」时再要一次（HostToken）。

开发和测试时没有本体：`serve --dev --tool 配件=exec:程序 参数…` 由核心自己起（`exec_opener`）。
"""
from __future__ import annotations

import itertools
import json
import os
import socket
import stat
import subprocess
import threading
from collections import deque
from typing import Callable, Deque, List, Optional, Tuple

from .mcp import NotRunning

OPEN_TIMEOUT = 10.0     # 本体起一个工具进程、交回连接最多等这么久
MAX_LINE = 1 << 16


class HostLink:
    """本体给的通道。线程安全：同一时间只有一个「要连接」在等回复（本体起进程很快）。"""

    def __init__(self, sock: socket.socket):
        self._sock = sock
        self._lock = threading.Lock()
        self._ids = itertools.count(1)
        self._buf = bytearray()
        self._fds: Deque[int] = deque()      # 收到、还没对上回复的连接（按到达的顺序，和回复一一对应）
        self._gone: Optional[str] = None

    @classmethod
    def from_fd(cls, fd: int = 0) -> "HostLink":
        """`serve --host-stdin`：标准输入得是本体给的 socket，不是就报错（命令行里误加了这个参数）。"""
        if not stat.S_ISSOCK(os.fstat(fd).st_mode):
            raise ValueError("标准输入不是 socket：--host-stdin 只给螺壳本体起核心时用")
        return cls(socket.socket(fileno=os.dup(fd)))

    def open(self, accessory: str, timeout: float = OPEN_TIMEOUT) -> socket.socket:
        """要一条到 `accessory` 的连接。给不了（本体不在、没带、用户没开、本体没答）就是 NotRunning。"""
        msg, fd = self._ask({"open": accessory}, timeout)
        if fd is not None:
            return socket.socket(fileno=fd)
        raise NotRunning(str(msg.get("error") or "螺壳本体没给连接"))

    def token(self, accessory: str, timeout: float = OPEN_TIMEOUT) -> Optional[str]:
        """常驻工具的口令（现在只有螺壳搜索）：`{"id": N, "token": "<配件>"}` → `{"id": N, "token": "…"}`。
        本体没给（不是要口令的工具、没开、还没起来）是 None；本体不在、没答是 NotRunning。"""
        msg, fd = self._ask({"token": accessory}, timeout)
        if fd is not None:          # 口令的答复不带连接；带了就是错配的，不用
            _drop(fd)
        t = msg.get("token")
        return t if isinstance(t, str) and t else None

    def _ask(self, request: dict, timeout: float) -> Tuple[dict, Optional[int]]:
        """发一个请求，等到 id 对上的那行回复；随它来的连接一起交回。之前等不及的请求后来才到的回复跳过，随它来的连接关掉。"""
        with self._lock:
            if self._gone:
                raise NotRunning(self._gone)
            rid = next(self._ids)
            self._sock.settimeout(timeout)
            try:
                self._sock.sendall(json.dumps({"id": rid, **request}).encode("utf-8") + b"\n")
                while True:
                    msg = self._reply()
                    fd = self._fds.popleft() if msg.get("ok") is True and self._fds else None
                    if msg.get("id") == rid:
                        return msg, fd
                    if fd is not None:      # 之前等不及的那次，本体后来才给的连接：不用了
                        _drop(fd)
            except socket.timeout:
                raise NotRunning("螺壳本体没答") from None
            except (OSError, ValueError):
                self._gone = "螺壳本体不在了"
                raise NotRunning(self._gone) from None

    def _reply(self) -> dict:
        """下一行回复；随它来的连接放进 _fds。通道断了是 OSError，不是 JSON 是 ValueError。"""
        while True:
            i = self._buf.find(b"\n")
            if i >= 0:
                line = bytes(self._buf[:i])
                del self._buf[:i + 1]
                msg = json.loads(line)
                if not isinstance(msg, dict):
                    raise ValueError("回复不是对象")
                return msg
            if len(self._buf) > MAX_LINE:
                raise ValueError("回复太长")
            data, fds, _flags, _addr = socket.recv_fds(self._sock, MAX_LINE, 4)
            self._fds.extend(fds)
            if not data:
                raise OSError("通道断了")
            self._buf += data

    def close(self) -> None:
        self._sock.close()
        while self._fds:
            _drop(self._fds.popleft())


class HostToken:
    """向本体要一个常驻工具的口令，记着用（ToolClient 的 `token`）。`get(fresh=True)`：工具说口令不对（它重起过）时再要一次。
    要不到也记着（None），等工具说不对再要：不是要口令的工具就只问这一次。"""

    def __init__(self, link: HostLink, accessory: str):
        self._link = link
        self._accessory = accessory
        self._lock = threading.Lock()
        self._asked = False
        self._value: Optional[str] = None

    def get(self, fresh: bool = False) -> Optional[str]:
        with self._lock:
            if fresh or not self._asked:
                try:
                    self._value = self._link.token(self._accessory)
                except NotRunning:
                    self._value = None
                self._asked = True
            return self._value


def _drop(fd: int) -> None:
    """不用的连接：先关掉两个方向再关。本体还留着它那份（§2a），只关描述符的话，工具等不到结尾，要等它自己超时"""
    s = socket.socket(fileno=fd)
    try:
        s.shutdown(socket.SHUT_RDWR)
    except OSError:
        pass
    s.close()


def exec_opener(argv: List[str], stderr: Optional[int] = None) -> Callable[[], socket.socket]:
    """开发和测试用：每个请求自己起一次 `argv`，它的标准输入输出接到一对 socketpair 的另一端。进程在后台收尸。"""
    def opener() -> socket.socket:
        mine, theirs = socket.socketpair()
        try:
            proc = subprocess.Popen(argv, stdin=theirs, stdout=theirs,
                                    stderr=stderr if stderr is not None else subprocess.DEVNULL, close_fds=True)
        except OSError:
            mine.close()
            raise
        finally:
            theirs.close()
        threading.Thread(target=proc.wait, daemon=True).start()
        return mine
    return opener
