"""照工具录下的场景样例回话的假工具（docs/工具协议.md「场景样例」）。

一个场景是工具仓库 `fixtures/agent/<场景>/` 里的一串 `{"request", "reply"}`，工具在一种用户处境下对 agent 的真实答复，
由 `scripts/sync-tool-fixtures.sh` 拷到这里的 `fixtures/<工具>/`。agent 的真核心连上它，就和连着那个工具、
在那种处境下一样；窗口的示例数据（`scripts/window_samples.py`）和对接口的测试（tests/test_tool_fixtures.py）都这样来。

- 按请求认：`resources/read` 看 uri，`tools/call` 看工具名，别的看方法。同一样东西录了好几份（点按前后的），
  照到现在点过几次会改动东西的按钮取：点过 n 次，取前 n 次点按之后录的最后那份（第 n 段）。`tools/list`
  这类说工具自己的、和处境无关，哪一段录的都算。
- 窗口该看的是场景第一次读应用页的那一段（`window_stage`）；在那之前录的点按，`Session.run` 先经核心点掉。
- 录里没有的请求答错（资源答 RESOURCE_NOT_FOUND，别的答 METHOD_NOT_FOUND），记在 `served` 里：核心问了工具没答过的，
  就是两边对不上。点过以后没再录的，答点之前那份，记成 `stale`。
- 样例里 `resources/read` 的 `contents[0].text` 解开成了 JSON 值，这里 `json.dumps` 回去。编号、路径照样例里的写法
  （`000000000001`、`~`、`$TMPDIR`），核心原样传，不用换回去。

    python3 -m luoke_agent.replay_tool --scenario fixtures/luoke-scan/decide-3 --socket /path/to/agent.sock
"""
from __future__ import annotations

import argparse
import copy
import datetime as dt
import json
import os
import signal
import socket
import sys
import tempfile
import threading
from typing import Any, Callable, Dict, List, Optional, Tuple

from .mcp import METHOD_NOT_FOUND, RESOURCE_NOT_FOUND, USER_ACTION, ToolServer, _error

MAX_LINE = 1 << 20      # 一条消息最多 1 MB，同 luoke-scan mcp

TIMEZONE = "Asia/Shanghai"   # 工具录样例时的时区（各场景的 scenario.json `produced.tz`）；核心的 iso() 照本机时区写


def load(path: str) -> Any:
    with open(path, encoding="utf-8") as f:
        return json.load(f)


def request_key(message: dict) -> Tuple[str, ...]:
    """认请求：`resources/read` 看 uri，`tools/call` 看工具名，别的看方法。"""
    method = str(message.get("method"))
    params = message.get("params") if isinstance(message.get("params"), dict) else {}
    if method == "resources/read":
        return (method, str(params.get("uri")))
    if method == "tools/call":
        return (method, str(params.get("name")))
    return (method,)


def is_stateful(message: dict) -> bool:
    """答复跟着处境变的：读资源、调工具。"""
    return request_key(message)[0] in ("resources/read", "tools/call")


def is_write(message: dict) -> bool:
    """带 `ai.luoke/user-action` 的 `tools/call`：用户点了会改动东西的按钮。"""
    params = message.get("params") if isinstance(message.get("params"), dict) else {}
    meta = params.get("_meta") if isinstance(params.get("_meta"), dict) else {}
    return message.get("method") == "tools/call" and isinstance(meta.get(USER_ACTION), dict)


def parse_clock(s: str) -> float:
    return dt.datetime.fromisoformat(s.replace("Z", "+00:00")).timestamp()


def iso_utc(t: float) -> str:
    return dt.datetime.fromtimestamp(t, dt.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def online(reply: dict, rid: Any) -> dict:
    """样例里的答复换回线上的样子：换上这次的 id，`resources/read` 的 text 变回 JSON 文字。"""
    out = copy.deepcopy(reply)
    out["id"] = rid
    for c in ((out.get("result") or {}).get("contents") or []):
        if isinstance(c, dict) and "text" in c and not isinstance(c["text"], str):
            c["text"] = json.dumps(c["text"], ensure_ascii=False)
    return out


def scenarios(root: str) -> List[str]:
    """`fixtures/` 下的全部场景目录（`<工具>/<场景>/`，有 scenario.json 的），排好序。"""
    out = []
    for tool in sorted(os.listdir(root)) if os.path.isdir(root) else []:
        d = os.path.join(root, tool)
        if not os.path.isdir(d):
            continue
        for name in sorted(os.listdir(d)):
            if os.path.isfile(os.path.join(d, name, "scenario.json")):
                out.append(os.path.join(d, name))
    return out


class Replay(ToolServer):
    """一个场景的假工具。`records` 是照 scenario.json 的步骤排的录音，`served` 是收到的每个请求和答了哪份。"""

    def __init__(self, scenario_dir: str):
        self.dir = os.path.abspath(scenario_dir)
        self.manifest = load(os.path.join(self.dir, "manifest.json"))
        self.scenario = load(os.path.join(self.dir, "scenario.json"))
        super().__init__(str(self.manifest.get("accessory") or "tool"), str(self.manifest.get("version") or "0"))
        self.records: List[dict] = []
        stage = 0
        for step in self.scenario.get("steps") or []:
            name = step.get("file")
            if not name:
                continue
            rec = load(os.path.join(self.dir, name))
            self.records.append({"file": name, "stage": stage, "clock": step.get("clock"), "do": step.get("do", ""),
                                 "request": rec["request"], "reply": rec["reply"]})
            if is_write(rec["request"]):
                stage += 1
        self.stage = 0
        self.served: List[dict] = []
        self._lock = threading.Lock()

    @property
    def start_clock(self) -> float:
        """第一份录音的时钟：核心照这个时刻起来（之前的步骤是工具自己在查，还没人问它）。"""
        first = next((r for r in self.records if r.get("clock")), None)
        return parse_clock(first["clock"]) if first else 0.0

    @property
    def window_stage(self) -> int:
        """窗口该看的那一段：场景第一次读应用页（`page/…`）的时候；没读页就是开头。"""
        return next((r["stage"] for r in self.records if request_key(r["request"])[0] == "resources/read"
                     and request_key(r["request"])[1].startswith("page/")), 0)

    def writes(self) -> List[dict]:
        """录下的点按（会改动东西的），按先后。"""
        return [r for r in self.records if is_write(r["request"])]

    def record_for(self, message: dict) -> Optional[dict]:
        key = request_key(message)
        stateless = not is_stateful(message)
        found = [r for r in self.records if request_key(r["request"]) == key and (stateless or r["stage"] <= self.stage)]
        if not found:
            return None
        if stateless:
            return found[0]
        last = max(r["stage"] for r in found)
        return [r for r in found if r["stage"] == last][-1]

    def handle(self, message: Any) -> Optional[dict]:
        if not isinstance(message, dict) or "id" not in message or not isinstance(message.get("method"), str):
            return super().handle(message)
        with self._lock:
            rec = self.record_for(message)
            self.served.append({"file": rec["file"] if rec else None, "stage": self.stage,
                                "stale": bool(rec) and is_stateful(message) and rec["stage"] < self.stage,
                                "request": message})
            if rec is None:
                if message["method"] == "resources/read":
                    return _error(message["id"], RESOURCE_NOT_FOUND, "样例里没录这个资源",
                                  {"uri": (message.get("params") or {}).get("uri")})
                return _error(message["id"], METHOD_NOT_FOUND, "样例里没录这个请求")
            if is_write(rec["request"]):
                self.stage += 1
            return online(rec["reply"], message["id"])

    def opener(self) -> Callable[[], socket.socket]:
        """由本体起的工具（清单 `transport: "stdio"`，工具协议 §2a）：每个请求一对 socketpair，这一头在线程里答一行，
        另一头交给核心（`ToolSource(opener=...)`）。同一个 Replay 答所有请求，点按前后的状态接得上；
        `hostlink.exec_opener` 每个请求起一次新进程，做不到这一点。"""
        def open_one() -> socket.socket:
            mine, theirs = socket.socketpair(socket.AF_UNIX, socket.SOCK_STREAM)
            threading.Thread(target=self._answer_one, args=(mine,), name=f"{self.name}-stdio", daemon=True).start()
            return theirs
        return open_one

    def _answer_one(self, conn: socket.socket) -> None:
        """照 `luoke-scan mcp`：读一行请求（核心写完会关掉写的一头），答一行，关掉。"""
        with conn:
            buf = b""
            while b"\n" not in buf and len(buf) <= MAX_LINE:
                chunk = conn.recv(65536)
                if not chunk:
                    break
                buf += chunk
            try:
                message = json.loads(buf.split(b"\n", 1)[0])
            except ValueError:
                return
            reply = self.handle(message)
            if reply is not None:
                conn.sendall(json.dumps(reply, ensure_ascii=False).encode("utf-8") + b"\n")

    def unmatched(self, *, stage: Optional[int] = None, ignore: Tuple[str, ...] = ("outbox_ack",)) -> List[dict]:
        """核心问了、样例里没有的请求（给了 `stage` 只看那一段的）。`outbox_ack` 默认不算：核心在后台线程里记账，
        不看答复，工具录不录都行。"""
        with self._lock:
            return [s["request"] for s in self.served if s["file"] is None and (stage is None or s["stage"] == stage)
                    and not (request_key(s["request"])[0] == "tools/call" and request_key(s["request"])[1] in ignore)]

    def asked(self, stage: int) -> List[str]:
        """那一段核心问到了哪几份录音（去重，按先后）。"""
        out: List[str] = []
        with self._lock:
            for s in self.served:
                if s["stage"] == stage and s["file"] and s["file"] not in out:
                    out.append(s["file"])
        return out

    def host_report(self) -> Dict[str, str]:
        """螺壳.app 会报的权限（`POST /host`）：清单里登记在螺壳名下（`owner: "luoke"`）的那几项，照工具第一次读到的状态。
        工具是螺壳起的，它看到的就是螺壳有没有。"""
        mine = [p.get("id") for p in (self.manifest.get("capabilities") or {}).get("permissions") or []
                if isinstance(p, dict) and p.get("owner") == "luoke"]
        first = next((r for r in self.records if request_key(r["request"]) == ("resources/read", "permissions")), None)
        states = (((first or {}).get("reply") or {}).get("result") or {}).get("contents") or [{}]
        got = states[0].get("text") if isinstance(states[0], dict) else None
        if not isinstance(got, dict):
            return {}
        return {k: got[k] for k in mine if isinstance(k, str) and got.get(k) in ("granted", "denied", "ask")}


class Clock:
    """核心的时钟：停在给定的时刻，点按前拨到那一步的。"""

    def __init__(self, t: float):
        self.t = t

    def __call__(self) -> float:
        return self.t


def use_recording_timezone() -> None:
    """核心写的时刻（点按的 `at`、卡片的时间）照录样例时的时区。先于用到时间的东西调。"""
    os.environ["TZ"] = TIMEZONE
    try:
        import time
        time.tzset()
    except AttributeError:   # 不是 Unix
        pass


class Session:
    """一个场景接上真核心：假工具、ToolSource（清单照主控 `GET /accessories` 那条路认）、Agent。用完 `close()`。"""

    def __init__(self, scenario_dir: str, *, home: Optional[str] = None):
        from .agent import Agent
        from .state import State
        from .toolsource import ToolSource, accessories

        self._tmp = tempfile.mkdtemp(prefix="lr") if home is None else None
        base = home or self._tmp
        self.replay = Replay(scenario_dir)
        # 清单原样（socket 和 data 都照工具写的），~ 是临时目录：照主控那条路认，socket 落在 <临时目录>/.<工具>/…
        # 由本体起的工具（transport stdio）不开 socket：连接由这里在进程里给，代替本体（工具协议 §2a）
        found = accessories({"accessories": [copy.deepcopy(self.replay.manifest)]}, home=base, stdio=True)
        if not found:
            self.close()
            raise ValueError(f"{scenario_dir} 的清单没声明工具协议，或 socket 不在它声明的数据目录里")
        f = found[0]
        self.app = f["accessory"]
        if f.get("transport") == "stdio":
            where, opener, dirs = f"stdio:{f['accessory']}", self.replay.opener(), None
        else:
            self.replay.start(f["socket"])
            where, opener, dirs = f["socket"], None, f["socket_dirs"]
        self.source = ToolSource(f["accessory"], where, name=f["name"], reports=f["reports"],
                                 socket_dirs=dirs, home=f.get("home"),
                                 service=f["service"], permissions=f["permissions"], opener=opener)
        self.clock = Clock(self.replay.start_clock)
        self.state = State(os.path.join(base, "agent"))
        self.agent = Agent(self.state, [self.source], clock=self.clock, url_opener=lambda u: None)

    def start(self) -> "Session":
        """核心起来：读一遍工具，螺壳.app 报它自己的权限。"""
        self.agent.poll()
        host = self.replay.host_report()
        if host:
            self.agent.set_host(host)
        return self

    def run(self) -> "Session":
        """起来，照场景走到窗口该看的那一段：之前录的点按经核心点掉，时钟拨到那一段第一份录音的，再读一遍工具。"""
        self.start()
        target = self.replay.window_stage
        while self.replay.stage < target:
            rec = next((r for r in self.replay.writes() if r["stage"] == self.replay.stage), None)
            before = self.replay.stage
            r = self.tap_recorded(rec) if rec else {"text": "这一段没有录点按", "error": True}
            if self.replay.stage == before:
                raise RuntimeError(f"走不到窗口该看的那一段：{rec and rec['file']}：{r.get('text')}")
        first = next((r for r in self.replay.records if r["stage"] == target), None)
        if target:
            if first and first.get("clock"):
                self.clock.t = parse_clock(first["clock"])
            self.agent.poll()
        return self

    def snapshot(self) -> dict:
        """窗口这时连上来会拿到的：`/feed` 先给的那一串、`/apps`、每一页、`/permissions`。"""
        q = self.agent.subscribe()
        events = []
        while not q.empty():
            events.append(list(q.get_nowait()))
        self.agent.unsubscribe(q)
        pages = {}
        for p in self.source.service["pages"]:
            status, data = self.agent.page(self.app, p["id"])
            pages[p["id"]] = data if status == 200 else {"status": status, **data}
        out = {"events": events, "apps": self.agent.apps(), "pages": pages, "permissions": self.agent.permissions()}
        return json.loads(json.dumps(out, ensure_ascii=False))   # 和经 socket 交给窗口的一样：只剩 JSON

    def tap_recorded(self, rec: dict) -> Dict[str, Any]:
        """照样例里录的那次点按，在核心交给窗口的卡片或页上点同一个按钮（时钟拨到那一步）。"""
        from .items import tool_surface_id

        params = rec["request"]["params"]
        ua = params["_meta"][USER_ACTION]
        self.clock.t = parse_clock(rec["clock"])
        sid = None
        for s, (key, _surface) in list(self.agent.surfaces.items()):
            item = self.agent.items.get(key) or self.agent.kept.get(key)
            if item is not None and item.source == self.app and tool_surface_id(item.card) == ua["surfaceId"]:
                sid = s
        if sid is None and any(p["id"] == ua["surfaceId"] for p in self.source.service["pages"]):
            self.agent.page(self.app, ua["surfaceId"])
            sid = f"{self.app}/page/{ua['surfaceId']}"
        if sid is None:
            return {"text": f"核心交给窗口的东西里没有 {ua['surfaceId']}", "error": True}
        return self.agent.tap(sid, ua["componentId"], params.get("arguments") or {})

    def close(self) -> None:
        self.replay.close()
        if hasattr(self, "state"):
            self.state.close()
        if self._tmp:
            import shutil
            shutil.rmtree(self._tmp, ignore_errors=True)


def comparable(request: dict) -> dict:
    """比两条请求时不看的：JSON-RPC 的 id、clientInfo 的版本（样例里写 fixtures）。"""
    r = copy.deepcopy(request)
    r.pop("id", None)
    info = ((r.get("params") or {}).get("_meta") or {}).get("io.modelcontextprotocol/clientInfo")
    if isinstance(info, dict):
        info.pop("version", None)
    return r


def main(argv: Optional[List[str]] = None) -> int:
    ap = argparse.ArgumentParser(prog="python3 -m luoke_agent.replay_tool", description="照场景样例回话的假工具")
    ap.add_argument("--scenario", required=True, help="一个场景目录，例如 fixtures/luoke-scan/decide-3")
    ap.add_argument("--socket", required=True, help="在哪个 socket 上听（核心的 --tool 给同一个）")
    a = ap.parse_args(argv)
    from .safety import refuse_real
    refuse_real(a.socket, "工具的 socket", always=True)
    replay = Replay(a.scenario).start(a.socket)
    print(f"luoke-agent replay：{replay.name} · {os.path.basename(os.path.abspath(a.scenario))} 在 {a.socket}",
          file=sys.stderr, flush=True)
    stop = threading.Event()
    for sig in (signal.SIGINT, signal.SIGTERM):
        signal.signal(sig, lambda *_: stop.set())
    stop.wait()
    replay.close()
    return 0


if __name__ == "__main__":
    sys.exit(main())
