"""把一张卡片画成几行字：给命令行客户端看、给测试比对。不进日志。"""
from __future__ import annotations

from typing import List

from . import a2ui


def render(surface: a2ui.Surface) -> List[str]:
    comps, data = surface.components, surface.data
    lines: List[str] = []

    def val(v):
        if a2ui.is_binding(v):
            try:
                return a2ui.get_path(data, v["path"])
            except KeyError:
                return None
        return v

    def inline(cid: str) -> str:
        c = comps.get(cid) or {}
        if c.get("component") == "Button":
            label = comps.get(c.get("child"), {})
            if label.get("component") == "Row":   # 图标加字（工具协议 §4）：取那段字
                label = next((comps[k] for k in label.get("children") or []
                              if (comps.get(k) or {}).get("component") == "Text"), {})
            site = f" → {c['site']}" if isinstance(c.get("site"), str) else ""   # agent 写的去哪个网站（工具协议 §5）
            return f"[{val(label.get('text')) or '?'}]（{cid}）{site}"
        if c.get("component") == "Text":
            return str(val(c.get("text")) or "")
        return ""

    def walk(cid: str, depth: int) -> None:
        c = comps.get(cid)
        if not c:
            return
        kind = c.get("component")
        pad = "  " * depth
        if kind in ("Column", "List", "Card"):
            for child in (c.get("children") or [c.get("child")]):
                if child:
                    walk(child, depth if kind != "Card" else depth + 1)
        elif kind == "Row":
            lines.append(pad + "  ".join(inline(x) for x in c.get("children") or []))
        elif kind == "Text":
            t = str(val(c.get("text")) or "")
            lines.append(pad + ("· " + t if c.get("variant") == "caption" else
                                "# " + t if (c.get("variant") or "").startswith("h") else t))
        elif kind == "ChoicePicker":
            cur = val(c.get("value")) or []
            opts = " ".join(f"[{'x' if o['value'] in cur else ' '}] {val(o.get('label'))}" for o in c.get("options") or [])
            where = c["value"]["path"] if a2ui.is_binding(c.get("value")) else ""
            lines.append(pad + f"{val(c.get('label')) or ''}  {opts}  ← {where}")
        elif kind in ("TextField", "DateTimeInput", "CheckBox", "Slider"):
            where = c["value"]["path"] if a2ui.is_binding(c.get("value")) else ""
            lines.append(pad + f"{val(c.get('label')) or kind}：{val(c.get('value'))!r}  ← {where}")
        elif kind == "Button":
            lines.append(pad + inline(cid))
        elif kind == "Divider":
            lines.append(pad + "—" * 8)
        elif kind == "ProgressBar":
            lines.append(pad + f"{round(c.get('value', 0) * 100)}%")
        elif kind == "Icon":
            lines.append(pad + f"<{c.get('name')}>")

    walk("root", 0)
    return lines
