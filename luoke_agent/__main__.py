"""luoke-agent 的核心和几个命令行小工具。

    python3 -m luoke_agent serve --home 目录 --memory 记忆文件 [--hub 主控socket] [--memory-app] [--host-stdin]
                                 [--parent-pid PID] [--brief-minutes N]
                                 [--dev [--tool 配件=socket ...] [--tool 配件=exec:程序 参数… ...]]
    python3 -m luoke_agent feed --home 目录 [--follow]       看现在的卡片（字）
    python3 -m luoke_agent tap --home 目录 卡片编号 按钮编号 [--set /路径=JSON ...]
    python3 -m luoke_agent presence --home 目录 --idle 秒 [--locked]
    python3 -m luoke_agent window --home 目录 open|close

位置都要显式给，不退回默认位置（顶层 CLAUDE.md「不碰日常在用的实例」）：壳在正式版里替你给好。

核心的 agent.sock 只认起它的那个进程（`--parent-pid`，没给就是父进程）。feed、tap、presence、window 这几个命令行
是别的进程，只对带 `--dev` 起的核心管用；`--tool` 也只在 `--dev` 时认。`--dev` 只能写在命令行上，正式版的壳不给。

`--host-stdin`：标准输入是螺壳本体给的通道（hostlink.py），由本体起的工具（`transport: "stdio"`）向它要连接。只有本体起
核心时给。开发时没有本体，用 `--tool 配件=exec:程序 参数…` 让核心自己起（每个请求一次）。
"""
from __future__ import annotations

import argparse
import http.client
import fcntl
import json
import os
import shlex
import signal
import socket
import sys
import threading
import time
from typing import Dict, Iterator, List, Optional, Tuple

from . import __version__, a2ui, textcard
from .agent import Agent
from .hostlink import HostLink, exec_opener
from .memsource import MemorySource, open_memory_app, use_hub_luoke_mem
from .runner import Runner
from .state import State
from .toolsource import ToolSource, hub_luoke_mem, id_problem
from .ui import NOT_LAUNCHER, UIServer, anyone, launcher_only

SOCKET_MAX = 103   # Unix socket 路径最长 104 字节（含结尾的 0）


def ui_socket(home: str) -> str:
    return os.path.join(home, "run", "agent.sock")


PYTHON_GONE_SECONDS = 30   # 跑着的 Python 不在这么久（不是换版本的那一刻）：主控挪了地方，也重起
RESTART_EXIT = 75   # 壳见到这个退出码就马上重起核心，不当成出错（app/Sources/Luoke/Core.swift）
LOCKED_EXIT = 3     # 同一个数据目录已经有一个核心在跑


def hold_lock(home: str) -> Optional[int]:
    """同一个数据目录只能有一个核心（docs/界面接口.md §2）：锁住 `<home>/run/lock`，进程退出时系统自己放开。
    拿不到（另一个核心正拿着）返回 None。"""
    run = os.path.join(home, "run")
    os.makedirs(run, mode=0o700, exist_ok=True)
    fd = os.open(os.path.join(run, "lock"), os.O_RDWR | os.O_CREAT, 0o600)
    try:
        fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
    except OSError:
        os.close(fd)
        return None
    return fd


def python_identity(path: Optional[str] = None) -> Optional[Tuple[int, int]]:
    """正在跑的 Python 的 (设备, inode)；看不到（例如换版本的那一刻文件不在）就是 None。
    看壳起核心时用的那个路径（壳放在 LUOKE_AGENT_PYTHON 里；有的 Python 会把 sys.executable 换成真实路径）。"""
    try:
        st = os.stat(path or os.environ.get("LUOKE_AGENT_PYTHON") or sys.executable)
    except OSError:
        return None
    return (st.st_dev, st.st_ino)


def _need_dir(path: str, what: str) -> None:
    d = os.path.dirname(os.path.abspath(os.path.expanduser(path)))
    if not os.path.isdir(d):
        sys.exit(f"{what}所在的目录不存在：{d}")


def serve(a: argparse.Namespace) -> int:
    launcher = a.parent_pid or os.getppid()     # 起核心的那个进程（螺壳.app、壳）：agent.sock 只认它
    home = os.path.abspath(os.path.expanduser(a.home))
    _need_dir(home, "数据目录")
    _need_dir(a.memory, "记忆文件")
    if a.hub:
        _need_dir(a.hub, "主控 socket ")
    if a.tool and not a.dev:
        sys.exit("--tool 只在开发时用：加 --dev")
    tools: Dict[str, str] = {}
    execs: Dict[str, List[str]] = {}
    for spec in a.tool or []:
        name, sep, path = spec.partition("=")
        if not sep or not name or not path:
            sys.exit(f"--tool 要写成 配件=socket 或 配件=exec:程序 参数…：{spec}")
        if id_problem(name):
            sys.exit(f"--tool {name}：{id_problem(name)}")
        if path.startswith("exec:"):
            argv = shlex.split(path[len("exec:"):])
            if not argv or not os.access(os.path.expanduser(argv[0]), os.X_OK):
                sys.exit(f"--tool {name}：exec: 后面的程序不在或不能执行：{argv[0] if argv else ''}")
            execs[name] = [os.path.abspath(os.path.expanduser(argv[0]))] + argv[1:]
            continue
        _need_dir(path, f"{name} 的 socket ")
        tools[name] = os.path.abspath(os.path.expanduser(path))
    host = None
    if a.host_stdin:
        try:
            host = HostLink.from_fd(0)
        except (OSError, ValueError) as e:
            sys.exit(f"--host-stdin：{e}")
    sock = ui_socket(home)
    if len(sock.encode()) > SOCKET_MAX:
        sys.exit(f"数据目录太深，界面的 socket 路径超过 104 字节：{sock}")
    lock = hold_lock(home)   # 在打开状态库、接管 socket 之前：另一个核心在用这个目录就不动它的东西
    if lock is None:
        print("luoke-agent：这个数据目录已经有一个核心在跑", file=sys.stderr, flush=True)
        return LOCKED_EXIT
    state = State(home)
    if a.brief_minutes is not None:
        state.set_setting("brief_minutes", a.brief_minutes)
        state.set_setting("brief", "every")      # 开发用：攒满这么久就发，不按时刻
    memory_path = os.path.abspath(os.path.expanduser(a.memory))
    if a.hub:   # 有主控就用它带的那份 luoke_mem（每次起进程都问，主控升级后旧路径会挪走）；问不到用自带的
        got = use_hub_luoke_mem(hub_luoke_mem(os.path.abspath(os.path.expanduser(a.hub))))
        print(f"luoke-agent：luoke_mem {'用主控的 ' + got if got else '用自带的'}", file=sys.stderr, flush=True)
    memory = MemorySource(memory_path, state, opener=open_memory_app if a.memory_app else None)
    sources = [memory] + [ToolSource(n, p) for n, p in tools.items()] + \
        [ToolSource(n, f"exec:{n}", opener=exec_opener(argv)) for n, argv in execs.items()]
    agent = Agent(state, sources)
    runner = Runner(agent, hub=os.path.abspath(os.path.expanduser(a.hub)) if a.hub else None,
                    explicit_tools=set(tools) | set(execs), host=host)
    ui = UIServer(agent, sock, allow=anyone if a.dev else launcher_only(launcher),
                  on_window=lambda is_open: is_open and runner.poll_soon()).start()
    runner.start()
    stop = threading.Event()
    for sig in (signal.SIGINT, signal.SIGTERM):
        signal.signal(sig, lambda *_: stop.set())
    restart = []
    python_was = python_identity()
    gone_limit = PYTHON_GONE_SECONDS
    if os.environ.get("LUOKE_AGENT_TESTING") == "1" and os.environ.get("LUOKE_AGENT_PYTHON_GONE_SECONDS"):
        gone_limit = float(os.environ["LUOKE_AGENT_PYTHON_GONE_SECONDS"])   # 测试里不等 30 秒
    missing: List[Optional[float]] = [None]   # 跑着的 Python 从什么时候起不在了（主控改名、挪走）

    def watch() -> None:
        while not stop.is_set():
            if a.parent_pid and os.getppid() != a.parent_pid:
                stop.set()   # 壳没了：自己退出
            now_is = python_identity()
            gone_since = missing[0] if now_is is None else None
            if now_is is None and gone_since is None:
                missing[0] = time.monotonic()
            elif now_is is not None:
                missing[0] = None
            moved = gone_since is not None and time.monotonic() - gone_since > gone_limit
            if python_was and ((now_is and now_is != python_was) or moved):
                # 跑着的 Python 被换掉或挪走了（主控换了版本、改了名）：退出，让壳马上找到新的那份重起
                print("luoke-agent：主控的 Python 换了，重启核心", file=sys.stderr, flush=True)
                restart.append(True)
                stop.set()
            time.sleep(2)
    threading.Thread(target=watch, daemon=True).start()
    who = "开发模式，认本账户的任何进程" if a.dev else f"只认进程 {launcher}"
    print(f"luoke-agent {__version__}：界面接口 {sock}（{who}）", file=sys.stderr, flush=True)
    try:
        stop.wait()
    finally:
        runner.stop()
        ui.close()
        memory.close()
        state.close()
    return RESTART_EXIT if restart else 0


# ---------------------------------------------------------------- 命令行客户端


class _Conn(http.client.HTTPConnection):
    def __init__(self, path: str, timeout: Optional[float] = 10):
        super().__init__("localhost", timeout=timeout)
        self._path = path

    def connect(self) -> None:
        s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        try:
            s.settimeout(self.timeout)
            s.connect(self._path)
        except OSError:
            s.close()
            raise
        self.sock = s


def _refused(resp: http.client.HTTPResponse) -> None:
    if resp.status == 403:
        sys.exit(f"{NOT_LAUNCHER}：命令行只对带 --dev 起的核心管用")


def _post(home: str, path: str, body: dict) -> dict:
    c = _Conn(ui_socket(home))
    try:
        c.request("POST", path, json.dumps(body, ensure_ascii=False).encode(), {"Content-Type": "application/json"})
        resp = c.getresponse()
        _refused(resp)
        return json.loads(resp.read() or b"{}")
    finally:
        c.close()


def events(home: str, timeout: Optional[float] = 10) -> Iterator[Tuple[str, object]]:
    c = _Conn(ui_socket(home), timeout=timeout)
    c.request("GET", "/feed")
    resp = c.getresponse()
    event = None
    try:
        _refused(resp)
        while True:
            line = resp.fp.readline()
            if not line:
                return
            line = line.decode("utf-8").rstrip("\n")
            if line.startswith("event: "):
                event = line[7:]
            elif line.startswith("data: ") and event:
                yield event, json.loads(line[6:])
                event = None
    finally:
        c.close()


def snapshot(home: str) -> Tuple[Dict[str, a2ui.Surface], dict]:
    """连上界面接口，收到第一份 feed 为止：现在的全部卡片。"""
    surfaces: Dict[str, a2ui.Surface] = {}
    for event, data in events(home):
        if event == "a2ui":
            _apply(surfaces, data)  # type: ignore[arg-type]
        elif event == "feed":
            return surfaces, data  # type: ignore[return-value]
    return surfaces, {}


def _apply(surfaces: Dict[str, a2ui.Surface], m: dict) -> None:
    if "createSurface" in m:
        b = m["createSurface"]
        surfaces[b["surfaceId"]] = a2ui.Surface(b["surfaceId"], b["catalogId"])
        return
    sid = next(m[k]["surfaceId"] for k in a2ui.MESSAGE_KINDS if k in m)
    if "deleteSurface" in m:
        surfaces.pop(sid, None)
    elif sid in surfaces:
        surfaces[sid].apply(m)


def feed(a: argparse.Namespace) -> int:
    surfaces, info = snapshot(a.home)
    _print(surfaces, info)
    if a.follow:
        for event, data in events(a.home, timeout=None):
            if event == "a2ui":
                _apply(surfaces, data)  # type: ignore[arg-type]
            elif event == "feed":
                info = data  # type: ignore[assignment]
                _print(surfaces, info)
            elif event in ("notify", "result"):
                print(f"〔{event}〕{json.dumps(data, ensure_ascii=False)}", flush=True)
    return 0


def _print(surfaces: Dict[str, a2ui.Surface], info: dict) -> None:
    print(f"—— {info.get('open', 0)} 件事", flush=True)
    for sid in info.get("order", []):
        if sid in surfaces:
            print(f"\n〔{sid}〕")
            for line in textcard.render(surfaces[sid]):
                print("  " + line)
    for n in info.get("notices", []):
        print(f"\n（{n}）")
    print(flush=True)


def tap(a: argparse.Namespace) -> int:
    surfaces, _ = snapshot(a.home)
    s = surfaces.get(a.surface)
    if s is None:
        sys.exit(f"没有这张卡片：{a.surface}")
    for spec in a.set or []:
        path, sep, value = spec.partition("=")
        if not sep:
            sys.exit(f"--set 要写成 /路径=JSON：{spec}")
        s.data = a2ui.set_path(s.data, path, json.loads(value))
    _, ctx = s.find_action(a.component)
    r = _post(a.home, "/action", {"surfaceId": a.surface, "sourceComponentId": a.component, "context": ctx})
    print(("没成：" if r.get("error") else "") + str(r.get("text", "")))
    return 1 if r.get("error") else 0


def main(argv: Optional[List[str]] = None) -> int:
    p = argparse.ArgumentParser(prog="python3 -m luoke_agent")
    sub = p.add_subparsers(dest="cmd", required=True)
    s = sub.add_parser("serve", help="跑核心")
    s.add_argument("--home", required=True, help="agent 的数据目录（正式版 ~/.luoke/agent）")
    s.add_argument("--memory", required=True, help="记忆文件（正式版 ~/.luoke/mem.db）；不存在就先不读")
    s.add_argument("--hub", help="主控的 socket：经它找装了哪些工具")
    s.add_argument("--tool", action="append",
                   help="直接指定一个工具：配件=socket，或 配件=exec:程序 参数…（由核心自己起，开发、测试用）")
    s.add_argument("--host-stdin", action="store_true",
                   help="标准输入是螺壳本体给的通道：由本体起的工具向它要连接（只有本体起核心时给）")
    s.add_argument("--memory-app", action="store_true", help="看依据时打开装好的螺壳记忆（正式版）")
    s.add_argument("--parent-pid", type=int, help="壳的进程号：它没了就退出")
    s.add_argument("--brief-minutes", type=float, help="开发用：简报攒满多久（分钟）就发，不按时刻；写进设置")
    s.add_argument("--dev", action="store_true",
                   help="开发用：agent.sock 认本账户的任何进程（feed、tap、luoke-window-demo），认 --tool。正式版的壳不给")
    f = sub.add_parser("feed", help="看现在的卡片")
    f.add_argument("--home", required=True)
    f.add_argument("--follow", action="store_true")
    t = sub.add_parser("tap", help="点一个按钮（只对带 --dev 起的核心管用）")
    t.add_argument("--home", required=True)
    t.add_argument("surface")
    t.add_argument("component")
    t.add_argument("--set", action="append", help="先改数据模型：/路径=JSON")
    pr = sub.add_parser("presence", help="报告用户在不在")
    pr.add_argument("--home", required=True)
    pr.add_argument("--idle", type=float, default=0)
    pr.add_argument("--locked", action="store_true")
    w = sub.add_parser("window", help="窗口开了、关了")
    w.add_argument("--home", required=True)
    w.add_argument("state", choices=("open", "close"))
    a = p.parse_args(argv)
    if a.cmd == "serve":
        return serve(a)
    if a.cmd == "feed":
        return feed(a)
    if a.cmd == "tap":
        return tap(a)
    if a.cmd == "presence":
        _post(a.home, "/presence", {"idle": a.idle, "locked": a.locked})
        return 0
    _post(a.home, "/window", {"open": a.state == "open"})
    return 0


if __name__ == "__main__":
    sys.exit(main())
