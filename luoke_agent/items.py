"""事项：一件要跟用户说的事（CONTEXT.md）。内容和卡片也存在本机的状态库里（state.py，顶层 ADR 0013）。"""
from __future__ import annotations

import hashlib
import json
from dataclasses import asdict, dataclass, field, fields
from typing import Any, Dict, List, Optional

URGENCY = ("urgent", "normal", "low")
RANK = {"urgent": 0, "normal": 1, "low": 2}


@dataclass
class Item:
    key: str                    # <来源>/<来源里的编号>，例如 luoke-mail/new-mail/…、memory/group/term/…
    source: str                 # memory 或工具的配件标识
    kind: str                   # 来源里的类别：new-mail、suspicious、term……
    urgency: str
    title: str                  # 纯文本，通知和画不了卡片时用
    summary: str
    why_now: str
    card: List[dict]            # A2UI 消息，surfaceId 是来源自己起的
    deadline: Optional[str] = None
    expires: Optional[str] = None
    created: Optional[str] = None
    extra: Dict[str, Any] = field(default_factory=dict)   # 来源自己处理点按时要的（不出本机）

    @property
    def category(self) -> str:
        return f"{self.source}:{self.kind}"

    @property
    def card_hash(self) -> str:
        return hashlib.sha256(json.dumps(self.card, sort_keys=True, ensure_ascii=False).encode()).hexdigest()

    def to_dict(self) -> Dict[str, Any]:
        return asdict(self)

    @classmethod
    def from_dict(cls, d: Dict[str, Any]) -> "Item":
        names = {f.name for f in fields(cls)}
        return cls(**{k: v for k, v in d.items() if k in names})

    def surface_id(self) -> str:
        """agent 这边的卡片编号：来源前缀 + 来源自己起的 surfaceId（工具协议 §4）。"""
        return f"{self.source}/{tool_surface_id(self.card)}"


def tool_surface_id(card: List[dict]) -> str:
    for m in card:
        for k in ("createSurface", "updateComponents", "updateDataModel", "deleteSurface"):
            if isinstance(m, dict) and isinstance(m.get(k), dict) and isinstance(m[k].get("surfaceId"), str):
                return m[k]["surfaceId"]
    return "card"
