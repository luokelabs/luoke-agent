"""工具这一路（DESIGN §3，docs/工具协议.md）：找到装了哪些工具，读它们的 outbox，把用户的点按转过去。"""
from __future__ import annotations

import collections
import hashlib
import http.client
import json
import math
import os
import re
import socket
import stat
import sys
import time
from typing import Any, Callable, Dict, List, Optional, Set

from . import __version__, a2ui, apps, cards
from .items import RANK, UNREAD, URGENCY, Item, tool_surface_id
from .mcp import BAD_TOKEN, NotRunning, RpcError, TimedOut, ToolClient
from .safety import refuse_real

HUB_CONTRACT = 1
# agent 自己用的编号，不给工具：记忆这一路、agent 自己的卡片、本体和主控，以及 notices 里的几个键；
# `luoke-core` 开头的（`luoke-core-dev`、`luoke-core-lab` 这些）也都留着
RESERVED = frozenset({"memory", "agent", "luoke-agent", "luoke-core", "luoke", "hub", "notifications"})
RESERVED_PREFIX = "luoke-core"
ACCESSORY_ID = re.compile(r"^[a-z0-9][a-z0-9._-]{0,63}$")
SEARCH_TIMEOUT = 10.0            # 一个工具搜多久没答就不等（docs/界面接口.md §7）


class HubRefused(Exception):
    """主控不认这个版本的 agent（配方的已验证版本里没有）。"""


class HubNotReady(Exception):
    """主控在，还没准备好：答 503（启动时 `busy`、退出时 `engine_failed`，luoke-core V1 §2）。
    `retry_after` 是主控说的多久以后再来（秒）；没说是 None。"""

    def __init__(self, path: str, retry_after: Optional[float] = None):
        super().__init__(path)
        self.retry_after = retry_after


def _retry_after(body: bytes, header: Optional[str]) -> Optional[float]:
    """拒绝的答复里主控说的多久以后再来：正文的 `retry_after`（秒），没有就看 `Retry-After` 头。认不出是 None。"""
    try:
        data = json.loads(body)
    except ValueError:
        data = None
    for v in ((data.get("retry_after") if isinstance(data, dict) else None), header):
        try:
            got = float(v) if v is not None and not isinstance(v, bool) else None
        except (TypeError, ValueError):
            got = None
        if got is not None and math.isfinite(got) and got > 0:
            return got
    return None


def hub_get(hub_socket: str, path: str, *, timeout: float = 5.0) -> Optional[dict]:
    """GET 主控的一个接口，答 200 的 JSON 对象；主控没在运行、答别的返回 None。
    不认这个版本抛 HubRefused；答 503（还在启动、正在退出）抛 HubNotReady，带上主控说的多久以后再来。"""
    refuse_real(hub_socket, "主控")
    conn = http.client.HTTPConnection("localhost", timeout=timeout)
    s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    s.settimeout(timeout)
    try:
        s.connect(hub_socket)
    except OSError:
        s.close()
        return None
    conn.sock = s
    try:
        conn.request("GET", path, headers={"X-Luoke-Accessory": f"luoke-agent/{__version__}"})
        resp = conn.getresponse()
        body = resp.read(1 << 20)
    except (OSError, http.client.HTTPException):
        return None
    finally:
        conn.close()
    if resp.status != 200:
        print(f"luoke-agent: 主控 {path} 答 {resp.status}", file=sys.stderr)
        if b"unknown_accessory" in body:
            raise HubRefused(path)
        if resp.status == 503:
            raise HubNotReady(path, _retry_after(body, resp.getheader("Retry-After")))
        return None
    try:
        data = json.loads(body)
    except ValueError:
        return None
    return data if isinstance(data, dict) else None


def hub_luoke_mem(hub_socket: str, *, tries: int = 3, wait: float = 2.0) -> Optional[str]:
    """主控带的那份 luoke_mem 在哪（`GET /tasks` 顶层的 `luoke_mem.path`，只有打着记忆的主控才有）。
    连不上多等几秒：主控换版本时我们和它一起重启，它可能还没起来。"""
    data = None
    for attempt in range(tries):
        if attempt:
            time.sleep(wait)
        try:
            data = hub_get(hub_socket, "/tasks")
        except HubRefused:
            return None
        except HubNotReady:
            data = None
        if data is not None:
            break
    lm = (data or {}).get("luoke_mem")
    path = lm.get("path") if isinstance(lm, dict) else None
    return os.path.expanduser(path) if isinstance(path, str) and path else None


def discover(hub_socket: str, *, timeout: float = 5.0, home: Optional[str] = None,
             stdio: bool = False) -> Optional[List[dict]]:
    """问主控装了哪些工具（luoke-core V1 §8 `GET /accessories`）。主控没在运行返回 None，不认这个版本抛 HubRefused，
    还没准备好（启动时答 503）抛 HubNotReady。

    只要声明了本协议（`capabilities.protocol == 1`，有 socket，或 `transport: "stdio"`）的，返回 `{accessory, name, socket,
    transport, reports, service, permissions}`（后两样是清单原样的，ToolSource 再认）。`stdio`：这个核心有本体给的通道
    （`serve --host-stdin`），接 stdio 的工具。不接的见 `accessories`。
    """
    data = hub_get(hub_socket, "/accessories", timeout=timeout)
    if data is None:
        return None
    return accessories(data, home=home, stdio=stdio)


def id_problem(accessory: Any) -> Optional[str]:
    """工具的编号能不能用：要是小写字母、数字和 . _ -，不能是 agent 自己用的（RESERVED、`luoke-core` 开头的）。能用返回 None。"""
    if not isinstance(accessory, str) or not ACCESSORY_ID.match(accessory):
        return "编号不对"
    if accessory in RESERVED or accessory.startswith(RESERVED_PREFIX):
        return "编号是 agent 自己用的"
    return None


def data_dirs(accessory: str, declared: Any) -> List[str]:
    """工具的 socket 能放在哪几个目录（相对主目录）：清单 `data` 里声明的，而且是和它的编号绑在一起的几种位置
    （`~/.<编号>`、`~/.luoke/<去掉 luoke- 的部分>`、`~/Library/Application Support/<编号>`，同主控卸载时认的那几种）。
    主控的答复里没有 `data` 时就是这几种位置本身。"""
    forms = [f".{accessory}", f"Library/Application Support/{accessory}"]
    if accessory.startswith("luoke-") and len(accessory) > len("luoke-"):
        forms.append(f".luoke/{accessory[len('luoke-'):]}")
    if declared is None:
        return forms
    known = {f.casefold() for f in forms}
    rels = [os.path.normpath(d[2:]) for d in (declared if isinstance(declared, list) else [])
            if isinstance(d, str) and d.startswith("~/")]
    return [r for r in rels if r.casefold() in known]


def _inside(path: str, directory: str) -> bool:
    return path.casefold().startswith(directory.rstrip(os.sep).casefold() + os.sep)


def socket_in_data(sock: str, dirs: List[str], home: str) -> Optional[str]:
    """清单里的 socket（`~/` 开头或绝对路径）落在 `dirs` 里的哪一个下面：展开后的路径。不在（含经软链接指到外面）返回 None。"""
    if sock.startswith("~/"):
        path = os.path.join(home, sock[2:])
    elif os.path.isabs(sock):
        path = sock
    else:
        return None
    if "\0" in path:
        return None
    path = os.path.normpath(path)
    try:
        os.fsencode(path)
        real, real_home = os.path.realpath(path), os.path.realpath(home)
    except (OSError, ValueError):      # 编不成文件名的（例如落单的代理项）
        return None
    for rel in dirs:
        if _inside(path, os.path.join(os.path.normpath(home), rel)) and _inside(real, os.path.join(real_home, rel)):
            return path
    return None


def socket_problem(path: str, dirs: List[str], home: str) -> Optional[str]:
    """连工具之前再查一次 socket（发现时查过，之后可能换成了硬链接、软链接）：路径本身要是 socket（lstat，不跟软链接）、
    只有一个硬链接，realpath 还在 `dirs` 里（`socket_in_data`）。没问题返回 None；不在返回「不在」（照没在运行）。"""
    try:
        st = os.lstat(path)
    except OSError:
        return "不在"
    if not stat.S_ISSOCK(st.st_mode):
        return "socket 那个路径不是 socket（或是软链接）"
    if st.st_nlink != 1:
        return "socket 有不止一个硬链接"
    if socket_in_data(path, dirs, home) != path:
        return "socket 不在清单声明的数据目录里"
    return None


def accessories(data: dict, *, home: Optional[str] = None, stdio: bool = False) -> List[dict]:
    """`GET /accessories` 的答复里认出工具（`discover` 用；重放工具的场景样例时直接给清单，`home` 是假的主目录）。

    两种工具：开 socket 的（`capabilities.socket`），和由螺壳本体起、连接向本体要的（`capabilities.transport == "stdio"`，
    §2a；`stdio` 为真时才接，没有本体给的通道就连不上）。
    不接的（stderr 说一句）：编号不对或是 agent 自己用的、同一个编号列了不止一次（都不接）、socket 不在清单声明的
    数据目录里（`data_dirs`）、stdio 的工具而这个核心没有本体的通道。"""
    home = home or os.path.expanduser("~")
    listed = [a for a in data.get("accessories") or [] if isinstance(a, dict)]
    seen = collections.Counter(a.get("accessory") for a in listed if isinstance(a.get("accessory"), str))
    out = []
    for a in listed:
        caps = a.get("capabilities")
        if not isinstance(caps, dict) or caps.get("protocol") != 1:
            continue
        piped = caps.get("transport") == "stdio"
        if not piped and not isinstance(caps.get("socket"), str):
            continue
        acc = a.get("accessory")
        if acc == "luoke-agent":
            continue
        problem = id_problem(acc)
        sock = None
        dirs: List[str] = []
        if problem is None and seen[acc] > 1:
            problem = "主控列出了不止一个，都不接"
        if problem is None and piped and not stdio:
            problem = "要螺壳本体给连接，这个核心没有本体的通道"
        if problem is None and not piped:
            dirs = data_dirs(acc, a.get("data"))
            sock = socket_in_data(caps["socket"], dirs, home)
            if sock is None:
                problem = "socket 不在清单声明的数据目录里"
        if problem is not None:
            shown = acc if isinstance(acc, str) and ACCESSORY_ID.match(acc) else "一个工具"
            print(f"luoke-agent: 不接 {shown}：{problem}", file=sys.stderr)
            continue
        out.append({"accessory": acc, "name": a.get("name") or acc, "socket": sock, "socket_dirs": dirs, "home": home,
                    "transport": "stdio" if piped else "socket",
                    "reports": caps.get("reports") if isinstance(caps.get("reports"), list) else [],
                    "service": caps.get("service"), "permissions": caps.get("permissions")})
    return out


class ToolSource:
    """一个工具。`poll` 读 outbox（没在运行返回 None，答了错误返回 UNREAD），`handle` 转点按。

    也是窗口上的一个「应用」（docs/界面接口.md §6、§10）：清单的 `service`、`permissions`，工具报的概览
    （`summary`）和权限状态（`perm_states`），以及它在 outbox 里要了哪几项权限（`asking`，`needs-access` 的 `permission`）。
    概览和权限状态每次读 outbox 时一起读；读不到就是不知道（None），不留旧的。
    """

    def __init__(self, accessory: str, socket_path: str, *, name: Optional[str] = None,
                 reports: Optional[List[dict]] = None, service: Any = None, permissions: Any = None,
                 socket_dirs: Optional[List[str]] = None, home: Optional[str] = None,
                 opener: Optional[Callable[[], socket.socket]] = None,
                 token: Optional[Callable[[bool], Optional[str]]] = None):
        """`token`：工具要的口令从哪儿拿（hostlink.HostToken.get，ToolClient 带在每个请求里）。`opener`：连接不是连 socket，而是每个请求向它要一条（本体给的、或开发时自己起的，hostlink.py）；
        这时 `socket_path` 只是个名字（`stdio:<配件>`、`exec:<配件>`）。"""
        if opener is None:
            refuse_real(socket_path, "工具")
        self.source = accessory
        self.name = name or accessory
        self.socket_path = socket_path
        self.reports: Dict[Any, dict] = {}
        self.capped = False            # 有清单的（主控列出来的）：一件事急不急不超过清单里那一类的
        if reports is not None:
            self.set_reports(reports)
        # 主控列出来的（有清单的）：每次连之前再查一次 socket（socket_problem）；显式给的开发用工具不查
        self._socket_dirs = socket_dirs
        self._home = home or os.path.expanduser("~")
        self._socket_said: Optional[str] = None
        self.client = ToolClient(socket_path, client_version=__version__, opener=opener, token=token,
                                 check=self._socket_ok if socket_dirs is not None and opener is None else None)
        self.read_only: Dict[str, bool] = {}
        self.running = False
        self.service = apps.service(service)
        self.permissions = apps.permissions(permissions)
        self.summary: Optional[dict] = None
        self.perm_states: Optional[Dict[str, str]] = None
        self.asking: Set[str] = set()

    def _socket_ok(self, path: str) -> bool:
        problem = socket_problem(path, self._socket_dirs or [], self._home)
        if problem not in (None, "不在") and problem != self._socket_said:
            print(f"luoke-agent: 不连 {self.source}：{problem}", file=sys.stderr)
        self._socket_said = problem
        return problem is None

    def set_manifest(self, service: Any, permissions: Any, reports: Any = None) -> None:
        """主控那边的清单变了（升级了）：换上新的 `service`、`permissions`（给了 `reports` 也换）。"""
        self.service = apps.service(service)
        self.permissions = apps.permissions(permissions)
        if reports is not None:
            self.set_reports(reports)

    def set_reports(self, reports: Any) -> None:
        """清单的 `reports`：每一类默认急不急，也是这一类的上限。只有显式给的开发用工具（`serve --dev --tool`）没有清单、不设上限。"""
        self.reports = {r.get("kind"): r for r in (reports if isinstance(reports, list) else []) if isinstance(r, dict)}
        self.capped = True

    def permission(self, pid: Any) -> Optional[dict]:
        return next((p for p in self.permissions if p["id"] == pid), None)

    def _tools(self, refresh: bool = False) -> Dict[str, bool]:
        if refresh or not self.read_only:
            self.read_only = {t["name"]: bool((t.get("annotations") or {}).get("readOnlyHint", False))
                              for t in self.client.list_tools() if isinstance(t.get("name"), str)}
        return self.read_only

    def poll(self, now: float) -> Any:
        """这一轮的事（`[Item]`）；没在运行是 None；答了错误是 UNREAD。"""
        what = "outbox"
        try:
            raw = self.client.outbox(self.source)
            what = "工具列表"
            self._tools()
        except NotRunning:          # 口令重新要过还不对，ToolClient 也当成这个（§2「口令」）
            self._down()
            return None
        except RpcError as e:
            print(f"luoke-agent: {self.source} 的{what}读不了（{e.code}）", file=sys.stderr)
            if e.code == BAD_TOKEN:  # 要口令，却没处要（§2「口令」）：照旧当它没在运行
                self._down()
                return None
            # 答了错误不算没在运行（§2）：这一轮没读到。上一轮的事不撤、不新加，outbox 里要的权限也照上一轮的；
            # 概览、权限状态照它们自己读到的
            self.running = True
            self.refresh_app()
            return UNREAD if self.running else None
        self.running = True
        self.asking = {r["permission"] for r in raw if r.get("kind") == "needs-access" and isinstance(r.get("permission"), str)}
        self.refresh_app()
        out = []
        for r in raw:
            item = self._item(r)
            if item:
                out.append(item)
        return out

    def _down(self) -> None:
        self.running = False
        self.summary = self.perm_states = None
        self.asking = set()

    def refresh_app(self, *, summary: bool = True) -> None:
        """读工具现在的概览和权限状态（协议 §1a）：照它报的，不猜；读不到就是不知道。"""
        try:
            if summary:
                self.summary = self._read("summary", apps.summary) if self.service["summary"] else None
            if self.permissions:
                self.perm_states = self._read("permissions", apps.states)
        except NotRunning:
            self._down()

    def _read(self, uri: str, parse: Any) -> Any:
        try:
            value = parse(self.client.read_json(uri))
        except RpcError as e:      # 只记资源本身，不记查询串（带参数读的页，参数里是用户填的字；工具协议 §1a）
            print(f"luoke-agent: {self.source} 的 {uri.split('?', 1)[0]} 读不了（{e.code}）", file=sys.stderr)
            return None
        self.running = True
        return value

    def read_page(self, page: str, args: Optional[Dict[str, str]] = None) -> Any:
        """基础页 `page/<id>` 的 A2UI 消息（没查过）。`args`：带参数读（`page/<id>?<键>=<值>&…`，§4 pageArgs），
        已经核过形状。没在运行抛 NotRunning，读不了抛 RpcError。"""
        return self.client.read_json(a2ui.page_uri(page, args))

    def tool_names(self, want: Any = ()) -> Set[str]:
        """这个工具 `tools/list` 里的名字；`want` 里有没列过的，重新列一次（工具升过级）。"""
        tools = self._tools()
        if not set(want) <= set(tools):
            tools = self._tools(refresh=True)
        return set(tools)

    def search(self, query: str, limit: int) -> Any:
        """问一次清单 `service.ask.search` 写的工具（docs/界面接口.md §7）。只读，不带 user_action。
        答 ToolResult；没在运行抛 NotRunning，超时抛 TimedOut，出错抛 RpcError。"""
        return self.client.call_tool(self.service["search"], {"query": query, "limit": limit}, timeout=SEARCH_TIMEOUT)

    def _item(self, r: dict) -> Optional[Item]:
        if not isinstance(r.get("id"), str) or not r["id"] or not isinstance(r.get("title"), str) or not r["title"]:
            return None
        kind = r.get("kind") if isinstance(r.get("kind"), str) else "other"
        declared = (self.reports.get(kind) or {}).get("urgency")
        default = declared if declared in URGENCY else "normal"      # 清单里没有这一类：最多是 normal
        urgency = r.get("urgency") if r.get("urgency") in URGENCY else default
        if self.capped and RANK[urgency] < RANK[default]:
            urgency = default                                        # 不比清单里这一类急
        card = r.get("card")
        try:
            a2ui.build(card)
        except a2ui.CardError as e:
            print(f"luoke-agent: {self.source} 的一张卡片画不了：{len(e.problems)} 处问题", file=sys.stderr)
            card = self._fallback(r)
        text = lambda k: r[k] if isinstance(r.get(k), str) else None  # noqa: E731
        extra = {"id": r["id"]}
        if kind == "needs-access" and text("permission"):
            extra["permission"] = r["permission"]   # 要的是哪一项权限（协议 §1a「用到才要」）
        return Item(key=f"{self.source}/{r['id']}", source=self.source, kind=kind, urgency=urgency,
                    title=r["title"], summary=text("summary") or "", why_now=text("why_now") or "",
                    card=card, deadline=text("deadline"), expires=text("expires"), created=text("created"),
                    extra=extra)

    def _fallback(self, r: dict) -> List[dict]:
        """卡片画不了：只显示纯文本的标题和摘要（工具协议 §4）。"""
        card = cards.Card("plain-" + hashlib.sha256(r["id"].encode()).hexdigest()[:12])
        card.text(r["title"])
        if isinstance(r.get("summary"), str) and r["summary"]:
            card.text(r["summary"], caption=True)
        card.text(f"这张卡片画不了，请在{self.name}里看。", caption=True)
        return card.messages()

    def handle(self, item: Item, name: str, ctx: dict, user_action: dict) -> Dict[str, Any]:
        """转一次卡片上的点按。会改动东西的带上 user_action（工具协议 §5）。"""
        return self.call(tool_surface_id(item.card), name, ctx, user_action)

    def call(self, surface: str, name: str, ctx: dict, user_action: dict, *, write: Optional[bool] = None) -> Dict[str, Any]:
        """转一次用户的点按：卡片、基础页（`surface` 是页 id）、权限页和打开工具自己的界面（`POST /open`）。
        `write`：不按工具的 readOnlyHint，直接定带不带 user_action（权限的开关、申请、移除照协议 §1a 都是写入）。"""
        try:
            tools = self._tools()
            if name not in tools:
                tools = self._tools(refresh=True)
            if name not in tools:
                return {"text": f"{self.name}没有这个动作。", "error": True}
            read_only = tools[name] if write is None else not write
            ua = dict(user_action, surfaceId=surface)
            result = self.client.call_tool(name, ctx, user_action=None if read_only else ua)
        except NotRunning:
            return {"text": f"{self.name}现在没在运行。", "error": True}
        except TimedOut:
            return {"text": f"{self.name}还没答复，结果不明；稍后在{self.name}里看看。", "error": True}
        except RpcError:
            return {"text": f"{self.name}出错了。", "error": True}
        out: Dict[str, Any] = {"text": result.text or ("没做成。" if result.is_error else "好了。"),
                               "error": result.is_error, "done": result.done and not result.is_error}
        if result.card:
            out["card"] = result.card
        if result.code:
            out["code"] = result.code
        if "file" in result.structured and not result.is_error:   # 存文件（§4 saveFile）：形状对才交给窗口
            f = a2ui.save_file(result.structured["file"])
            if f is not None:
                out["file"] = f
            else:
                print(f"luoke-agent: {self.source} 的 {name} 答复里的文件交不了（形状不对或太大）", file=sys.stderr)
        return out

    def ack(self, item: Item, state: str) -> None:
        """告诉工具这件说过了、答了、放下了（工具可以不实现）。"""
        try:
            if "outbox_ack" in self._tools():
                self.client.call_tool("outbox_ack", {"id": item.extra.get("id"), "state": state})
        except (NotRunning, TimedOut, RpcError):
            pass
