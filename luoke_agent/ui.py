"""界面协议（DESIGN §1）：核心对界面（Mac 的壳，以后的手机 app）的接口，HTTP/1.1 跑在 `<数据目录>/run/agent.sock` 上。

- `GET /feed`：SSE。先给现在的全部卡片，再给变化。事件：`a2ui`（一条 A2UI 消息，surfaceId 是 agent 的编号）、
  `feed`（{order, open, notices, cards, brief, paused_until}；`cards` 是每张卡片在「今天」的哪一段）、
  `notify`（壳去发系统通知）、`busy`（卡片在处理）、`result`（点按的结果一句话）、`settings`（设置改了）、
  `apps`（{app}：这个应用的运行状态、概览、页列表、权限状态变了）。
- `GET /settings`、`POST /settings`：提醒的设置（docs/界面接口.md §9）；POST 只带要改的，答改完的全部。
- `GET /apps`、`GET /apps/<id>/pages/<页>`、`POST /open` {"app", "page"}：应用的页（docs/界面接口.md §6）。
- `GET /permissions`、`POST /permissions` {"app", "id", "op"}、`POST /host` {"permissions"}：权限（§10）。
- `POST /search`：{"query", "limit"}，问写了 `service.ask.search` 的工具；答 {"results": [{"app", "name", "messages"}], "failed", "text"}（§7）。
- `POST /action`：{"surfaceId", "sourceComponentId", "context"}，A2UI 的 action（卡片和基础页）；答复 {"text", "error"}。
- `POST /presence`：{"idle", "locked", "asleep"}，壳报告用户在不在。
- `POST /window`：{"open", "front"}，对话窗口开了、关了；`front` 是窗口在最前面（用户正看着它），不报就按 `open`。
- `POST /notifications`：{"status", "alerts"}，壳报告系统通知的授权（authorized / denied / not_determined / provisional，和 luoke-core 启动器的 `--notify-status` 同名）
  和横幅开没开；被关掉时窗口里说一句。
- `GET /status`：只有元数据。
- `POST /say`：以后的对话，现在答 501。

socket 的目录是 700、文件 600，只让本账户连；连上以后先看对端是哪个进程（`peer_pid`），只认起核心的那个
（螺壳.app 或壳，`launcher_only`），别的一律答 403，什么都不做。开发时 `serve --dev` 才认本账户的任何进程（命令行的 feed、tap，
luoke-window-demo）。手机端另有认证（DESIGN §7）。
"""
from __future__ import annotations

import json
import os
import queue
import re
import socket
import socketserver
import struct
import sys
import threading
import urllib.parse
from http.server import BaseHTTPRequestHandler
from typing import Any, Callable, Optional

from . import apps
from .agent import SEARCH_LIMIT, Agent
from .mcp import _prepare_socket

KEEPALIVE = 15.0
MAX_BODY = 1 << 20
MAX_QUERY = 200                  # 搜索框一次最多几个字
MAX_SEARCH_LIMIT = 50
PAGE_PATH = re.compile(r"^/apps/([^/?#]+)/pages/([^/?#]+)$")
SOL_LOCAL, LOCAL_PEERPID = 0, 2      # macOS <sys/un.h>
NOT_LAUNCHER = "agent.sock 只认起核心的那个进程"
REFUSED_TIMEOUT = 5.0                # 不认的连接：读请求最多等这么久

Allow = Callable[[Optional[int]], bool]


def peer_pid(conn: socket.socket) -> Optional[int]:
    """连上来的是哪个进程：macOS 用 LOCAL_PEERPID，Linux（CI）用 SO_PEERCRED。取不到是 None（不认）。"""
    try:
        if sys.platform == "darwin":
            return int(conn.getsockopt(SOL_LOCAL, LOCAL_PEERPID))
        if hasattr(socket, "SO_PEERCRED"):
            pid, _uid, _gid = struct.unpack("3i", conn.getsockopt(socket.SOL_SOCKET, socket.SO_PEERCRED, struct.calcsize("3i")))
            return pid
    except (OSError, struct.error):
        return None
    return None


def launcher_only(launcher: int) -> Allow:
    """只认起核心的那个进程：对端是它，而且它还是核心的父进程（它没了，核心就归到别的进程名下，
    这个进程号再被别人用上也不认）。"""
    return lambda pid: pid is not None and pid == launcher and os.getppid() == launcher


def anyone(pid: Optional[int]) -> bool:
    """开发用（`serve --dev`）：本账户的任何进程（socket 文件的权限照旧只让本账户连）。"""
    return True


class UIServer:
    def __init__(self, agent: Agent, socket_path: str, *, allow: Allow,
                 on_window: Optional[Callable[[bool], None]] = None):
        """`allow`：对端的进程号 → 认不认（`launcher_only(pid)`；开发时 `anyone`）。没有默认值：要调用方想清楚。"""
        self.agent = agent
        self.socket_path = socket_path
        self.allow = allow
        self.on_window = on_window
        self.stopping = threading.Event()
        self._server: Optional[_Server] = None
        self._thread: Optional[threading.Thread] = None

    def start(self) -> "UIServer":
        _prepare_socket(self.socket_path)
        self._server = _Server(self.socket_path, _Handler)
        os.chmod(self.socket_path, 0o600)
        self._server.ui = self
        self._ino = os.lstat(self.socket_path).st_ino
        self._thread = threading.Thread(target=self._server.serve_forever, name="agent-ui", daemon=True)
        self._thread.start()
        return self

    def close(self) -> None:
        self.stopping.set()
        if self._server is None:
            return
        self._server.shutdown()
        self._server.server_close()
        try:
            if os.lstat(self.socket_path).st_ino == self._ino:
                os.unlink(self.socket_path)
        except FileNotFoundError:
            pass
        self._server = None


class _Server(socketserver.ThreadingMixIn, socketserver.UnixStreamServer):
    daemon_threads = True
    ui: UIServer


    def handle_error(self, request: Any, client_address: Any) -> None:
        exc = sys.exc_info()[1]
        if not isinstance(exc, (BrokenPipeError, ConnectionResetError)):
            print(f"luoke-agent: 界面接口出错 {type(exc).__name__}", file=sys.stderr)


class _Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"
    server_version = "luoke-agent"
    sys_version = ""

    def log_message(self, format: str, *args: Any) -> None:
        pass

    def address_string(self) -> str:
        return "unix"

    @property
    def ui(self) -> UIServer:
        return self.server.ui  # type: ignore[attr-defined]

    def setup(self) -> None:
        """accept 之后先看对端是哪个进程。不认的照样把请求读完（不读完就断，对端可能只见到连接被重置），
        然后一律答 403，不碰 agent（`_refuse`）。"""
        super().setup()
        pid = peer_pid(self.connection)
        self.refused = not self.ui.allow(pid)
        if self.refused:
            self.connection.settimeout(REFUSED_TIMEOUT)
            print(f"luoke-agent: 界面接口不认这个连接（进程 {pid}）", file=sys.stderr, flush=True)

    def _refuse(self) -> None:
        try:
            n = int(self.headers.get("Content-Length") or "0")
        except ValueError:
            n = 0
        if 0 < n <= MAX_BODY:
            self.rfile.read(n)
        self._json(403, {"error": NOT_LAUNCHER})

    def do_GET(self) -> None:
        if self.refused:
            return self._refuse()
        if self.path == "/feed":
            return self._feed()
        if self.path == "/status":
            return self._json(200, self.ui.agent.status())
        if self.path == "/settings":
            return self._json(200, self.ui.agent.settings())
        if self.path == "/apps":
            return self._json(200, self.ui.agent.apps())
        if self.path == "/permissions":
            return self._json(200, self.ui.agent.permissions())
        m = PAGE_PATH.match(self.path)
        if m:
            status, data = self.ui.agent.page(urllib.parse.unquote(m.group(1)), urllib.parse.unquote(m.group(2)))
            return self._json(status, data)
        self._json(404, {"error": "没有这个地址"})

    def do_POST(self) -> None:
        if self.refused:
            return self._refuse()
        body = self._body()
        if body is None:
            return
        agent = self.ui.agent
        if self.path == "/action":
            sid, cid = body.get("surfaceId"), body.get("sourceComponentId")
            if not isinstance(sid, str) or not isinstance(cid, str):
                return self._json(400, {"error": "要有 surfaceId 和 sourceComponentId"})
            ctx = body.get("context") if isinstance(body.get("context"), dict) else {}
            r = agent.tap(sid, cid, ctx)
            return self._json(200, {"text": r.get("text", ""), "error": bool(r.get("error"))})
        if self.path == "/presence":
            try:
                agent.set_presence(float(body.get("idle", 0)), bool(body.get("locked")), bool(body.get("asleep")))
            except (TypeError, ValueError):
                return self._json(400, {"error": "idle 要是秒数"})
            return self._json(200, {})
        if self.path == "/window":
            is_open = bool(body.get("open"))
            agent.set_window(is_open, body.get("front"))
            if self.ui.on_window:
                self.ui.on_window(is_open)
            return self._json(200, {})
        if self.path == "/notifications":
            status = body.get("status")
            if not isinstance(status, str) or len(status) > 40:
                return self._json(400, {"error": "要有 status"})
            agent.set_notifications(status, body.get("alerts") is not False)
            return self._json(200, {})
        if self.path == "/settings":
            try:
                return self._json(200, agent.update_settings(body))
            except ValueError as e:
                return self._json(400, {"error": str(e)})
        if self.path == "/open":       # 只在用户点了「打开完整界面」、深页以后调
            app, page = body.get("app"), body.get("page")
            if not isinstance(app, str) or not (page is None or isinstance(page, str)):
                return self._json(400, {"error": "要有 app，page 可以不带"})
            return self._json(200, agent.open_ui(app, page or None))
        if self.path == "/permissions":   # 只在用户点了以后调
            app, pid, op = body.get("app"), body.get("id"), body.get("op")
            if not all(isinstance(v, str) for v in (app, pid, op)) or op not in apps.OPS:
                return self._json(400, {"error": "要有 app、id 和 op（" + "、".join(apps.OPS) + "）"})
            return self._json(200, agent.permission_op(app, pid, op))
        if self.path == "/host":
            try:
                agent.set_host(body.get("permissions"), body.get("confirmed"))
            except ValueError as e:
                return self._json(400, {"error": str(e)})
            return self._json(200, {})
        if self.path == "/search":     # 只在用户按了回车以后调
            query, limit = body.get("query"), body.get("limit", SEARCH_LIMIT)
            if not isinstance(query, str) or not query.strip() or len(query) > MAX_QUERY \
                    or not isinstance(limit, int) or isinstance(limit, bool) or not 1 <= limit <= MAX_SEARCH_LIMIT:
                return self._json(400, {"error": f"要有 query（不超过 {MAX_QUERY} 字），limit 是 1 到 {MAX_SEARCH_LIMIT}"})
            return self._json(200, agent.search(query.strip(), limit))
        if self.path == "/say":
            return self._json(501, {"text": "还不能打字问螺壳。"})
        self._json(404, {"error": "没有这个地址"})

    def _body(self) -> Optional[dict]:
        try:
            n = int(self.headers.get("Content-Length") or "0")
        except ValueError:
            n = -1
        if n < 0 or n > MAX_BODY:
            self._json(413 if n > MAX_BODY else 400, {"error": "请求体不对"})
            return None
        raw = self.rfile.read(n) if n else b"{}"
        try:
            data = json.loads(raw)
        except ValueError:
            self._json(400, {"error": "不是 JSON"})
            return None
        if not isinstance(data, dict):
            self._json(400, {"error": "要是对象"})
            return None
        return data

    def _json(self, status: int, data: Any) -> None:
        body = json.dumps(data, ensure_ascii=False).encode("utf-8")
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Connection", "close")
        self.end_headers()
        self.wfile.write(body)
        self.close_connection = True

    def _feed(self) -> None:
        self.send_response(200)
        self.send_header("Content-Type", "text/event-stream")
        self.send_header("Cache-Control", "no-cache")
        self.send_header("Connection", "close")
        self.end_headers()
        self.close_connection = True
        q = self.ui.agent.subscribe()
        try:
            while not self.ui.stopping.is_set():
                try:
                    event, data = q.get(timeout=KEEPALIVE)
                except queue.Empty:
                    self.wfile.write(b": ping\n\n")
                    self.wfile.flush()
                    continue
                payload = json.dumps(data, ensure_ascii=False)
                self.wfile.write(f"event: {event}\ndata: {payload}\n\n".encode("utf-8"))
                self.wfile.flush()
        except (BrokenPipeError, ConnectionResetError, OSError):
            pass
        finally:
            self.ui.agent.unsubscribe(q)
