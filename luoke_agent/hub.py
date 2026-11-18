"""向螺壳主控（luoke-core）要模型：agent 自己的模型任务用（现在只有吉祥物每天的那一句，`luoke-agent.hello`）。

约定是 luoke-core `docs/V1.md` §2：Unix socket 上的 HTTP/1.1，每个请求写明谁在问
（`X-Luoke-Accessory: luoke-agent/<版本>`）和哪个任务（`/tasks/luoke-agent.<任务>/v1/chat/completions`）。
agent 定消息和输出格式；用哪个模型、输出多长、怎么采样由主控的配方定。生成一律流式（SSE）。
发出去的内容只在内存里，这里和主控都不落盘、不进日志。

这些是后台的事：主控说现在不行（忙、暂停、用户回来了、还没准备好、要用户先做什么）就抛 `Later`，
调用的过一阵再来，不在这里等。只用标准库。"""
from __future__ import annotations

import http.client
import json
import socket
from typing import List, Optional

from . import __version__
from .safety import refuse_real

ACCESSORY = "luoke-agent"
LATER = ("busy", "paused", "interrupted", "not_ready", "needs_user")   # 现在不行：过一阵再来


class HubError(Exception):
    """主控做不了或不肯做：`code` 是它给的原因代号（主控没在运行是 "unreachable"）"""

    def __init__(self, message: str, code: str = "unreachable", retry_after: Optional[float] = None):
        super().__init__(message)
        self.code, self.retry_after = code, retry_after


class Later(HubError):
    """现在不行（忙、暂停、用户回来了……）：后台的事停下，过一阵再来"""


def _refused(code: str, data: dict) -> HubError:
    retry = data.get("retry_after")
    retry = float(retry) if isinstance(retry, (int, float)) and not isinstance(retry, bool) else None
    return (Later if code in LATER else HubError)(str(data.get("message") or code), code, retry)


class _Unix(http.client.HTTPConnection):
    def __init__(self, path: str, timeout: float):
        super().__init__("localhost", timeout=timeout)
        self.unix_path = path

    def connect(self) -> None:
        s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        s.settimeout(self.timeout)
        try:
            s.connect(self.unix_path)
        except OSError:
            s.close()
            raise
        self.sock = s


class Hub:
    def __init__(self, path: str):
        refuse_real(path, "主控")
        self.path = path
        self.who = f"{ACCESSORY}/{__version__}"
        self.model = ""             # 主控这次用的模型（它的分块里写着），评测记证据用

    def _headers(self) -> dict:
        return {"X-Luoke-Accessory": self.who}

    def task(self, task: str) -> dict:
        """`GET /tasks` 里这个任务的一项（状态、参数）；配方里没有就是空的"""
        c = _Unix(self.path, 10)
        try:
            c.request("GET", "/tasks", headers=self._headers())
            r = c.getresponse()
            raw = r.read()
        except (OSError, http.client.HTTPException) as ex:
            raise HubError(f"主控没有回应：{type(ex).__name__}") from ex
        finally:
            c.close()
        try:
            data = json.loads(raw.decode("utf-8")) if raw else {}
        except ValueError:
            data = {}
        if r.status >= 400:
            raise _refused(str(data.get("code") or r.status), data if isinstance(data, dict) else {})
        tasks = data.get("tasks") if isinstance(data, dict) else None
        found = tasks.get(f"{ACCESSORY}.{task}") if isinstance(tasks, dict) else None
        return found if isinstance(found, dict) else {}

    def chat(self, task: str, messages: List[dict], schema: dict, *, items: int = 1, timeout: float = 600,
             waiting: bool = False) -> str:
        """生成：答案的文字（照 `schema` 的 JSON）。现在不行抛 Later，别的失败抛 HubError。
        `waiting`：用户正看着、在等这个结果（主控的 `user-waiting`：随时算，不因为用户在用电脑就往后排）；
        不然是后台（`background`：用户在用电脑、用电池、过热时主控会让过一阵再来）"""
        body = {"messages": messages, "stream": True, "luoke_items": max(1, int(items)),
                "response_format": {"type": "json_schema", "json_schema": {"name": task.replace("-", "_"), "schema": schema}}}
        c = _Unix(self.path, timeout)
        try:
            try:
                c.request("POST", f"/tasks/{ACCESSORY}.{task}/v1/chat/completions",
                          body=json.dumps(body, ensure_ascii=False).encode("utf-8"),
                          headers=dict(self._headers(), **{"X-Luoke-Priority": "user-waiting" if waiting else "background",
                                                           "Content-Type": "application/json"}))
                r = c.getresponse()
            except (OSError, http.client.HTTPException) as ex:
                raise HubError(f"主控没有回应：{type(ex).__name__}") from ex
            if r.status != 200:
                raw = r.read()
                try:
                    data = json.loads(raw.decode("utf-8")) if raw else {}
                except ValueError:
                    data = {}
                data = data if isinstance(data, dict) else {}
                raise _refused(str(data.get("code") or r.status), data)
            parts: List[str] = []
            event = None
            try:
                while True:
                    raw = r.readline()
                    if not raw:
                        raise HubError("回答没有完整传回", "engine_failed")
                    line = raw.decode("utf-8", "replace").rstrip("\r\n")
                    if line.startswith("event: "):
                        event = line[7:].strip()
                    elif line.startswith("data: "):
                        data = line[6:]
                        if event == "luoke.error":       # 前面传回的不要了
                            payload = json.loads(data)
                            payload = payload if isinstance(payload, dict) else {}
                            raise _refused(str(payload.get("code") or "engine_failed"), payload)
                        if event:                        # luoke.progress
                            event = None
                            continue
                        if data.strip() == "[DONE]":
                            break
                        chunk = json.loads(data)
                        self.model = chunk.get("model") or self.model
                        for ch in chunk.get("choices") or []:
                            piece = (ch.get("delta") or {}).get("content")
                            if piece:
                                parts.append(piece)
                    elif not line:
                        event = None
            except (OSError, http.client.HTTPException, ValueError) as ex:
                raise HubError(f"回答没有完整传回：{type(ex).__name__}", "engine_failed") from ex
        finally:
            c.close()
        return "".join(parts).strip()
