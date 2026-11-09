"""开发和测试不碰日常在用的实例（顶层 CLAUDE.md）。

核心从不退回默认位置：数据目录、记忆文件、主控和工具的 socket 都由调用方显式给。测试时（环境变量
`LUOKE_AGENT_TESTING=1`，tests/__init__.py 在导入任何东西之前设好）再加一道：碰到日常在用的那些位置直接拒绝。
"""
from __future__ import annotations

import os

REAL_PLACES = ("~/.luoke", "~/.luoke-mail", "~/Library/Application Support/luoke-core", "~/Applications",
               "~/Library/Input Methods")


def testing() -> bool:
    return os.environ.get("LUOKE_AGENT_TESTING") == "1"


def refuse_real(path: str, what: str, *, always: bool = False) -> None:
    """测试里（或 `always`：造假数据的开发工具）给了日常在用的位置就抛 RuntimeError。"""
    if not (always or testing()):
        return
    p = os.path.realpath(os.path.expanduser(path))
    for place in REAL_PLACES:
        r = os.path.realpath(os.path.expanduser(place))
        if p == r or p.startswith(r + os.sep):
            raise RuntimeError(f"测试里不能用日常在用的{what}：{path}")
