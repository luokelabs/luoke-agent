# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 螺壳实验室 Luoke Labs
"""拼应用页的小帮手：核心照各应用给的原始数据拼页（顶层 ADR 0028），出的是窗口画的 A2UI。

页的样子照批过的效果图（走查重画稿）：页从一个灰的小标题开始，下面一组一张卡片（窗口按小标题分段，
`Surface.headedBlocks`）；一组里一样一行：左边标题和一行小字，右边小按钮（只有图标的画成浅底小方块）；
点一行就打开的写 `open`（§4 rowOpen）；选了就办的写 `submit`（§4 choiceSubmit）；放在标题那一行的写
`placement: header`（§4 headerPlacement）。
"""
from __future__ import annotations

from typing import Any, Dict, Iterable, List, Optional, Sequence, Tuple

VERSION = "v0.9"
CATALOG = "ai.luoke/a2ui/agent/1"


class PageKit:
    def __init__(self, surface_id: str):
        self.surface_id = surface_id
        self.components: List[dict] = []
        self.data: Dict[str, Any] = {}
        self._n = 0

    def _id(self, prefix: str) -> str:
        self._n += 1
        return f"{prefix}{self._n}"

    def add(self, comp: dict) -> str:
        self.components.append(comp)
        return comp["id"]

    # 字

    def text(self, text: str, variant: Optional[str] = None) -> str:
        comp: Dict[str, Any] = {"id": self._id("t"), "component": "Text", "text": text}
        if variant:
            comp["variant"] = variant
        return self.add(comp)

    def heading(self, text: str) -> str:
        """卡片上面的小标题（灰的小字）：「替你处理了 · 今天」「待确认 · 1」"""
        return self.text(text, "caption")

    # 按钮

    def button(self, label: str, event: str, context: Optional[dict] = None, *, icon: Optional[str] = None,
               variant: Optional[str] = None, tooltip: Optional[str] = None, confirm: Optional[dict] = None,
               on: Optional[bool] = None) -> str:
        """`variant="switch"` 加 `on`：画成开关（§4），`on` 是现在开没开"""
        bid = self._id("b")
        tid = bid + "-text"
        comp: Dict[str, Any] = {"id": bid, "component": "Button", "child": tid,
                                "action": {"event": {"name": event, "context": context or {}}}}
        if variant:
            comp["variant"] = variant
        if tooltip:
            comp["tooltip"] = tooltip
        if confirm:
            comp["confirm"] = confirm
        if on is not None:
            comp["on"] = on
        if icon:
            rid = bid + "-row"
            comp["child"] = rid
            self.add(comp)
            self.add({"id": bid + "-icon", "component": "Icon", "name": icon})
            self.add({"id": tid, "component": "Text", "text": label})
            self.add({"id": rid, "component": "Row", "children": [bid + "-icon", tid]})
        else:
            self.add(comp)
            self.add({"id": tid, "component": "Text", "text": label})
        return bid

    def open_page(self, label: str, page: str, args: Optional[dict] = None, **kw: Any) -> str:
        ctx: Dict[str, Any] = {"page": page}
        if args:
            ctx["args"] = args
        return self.button(label, "agent.open_page", ctx, **kw)

    # 排

    def row(self, children: Sequence[str], *, justify: Optional[str] = None, open: Optional[str] = None) -> str:
        comp: Dict[str, Any] = {"id": self._id("r"), "component": "Row", "children": list(children)}
        if justify:
            comp["justify"] = justify
        if open:
            comp["open"] = open
        return self.add(comp)

    def column(self, children: Sequence[str]) -> str:
        return self.add({"id": self._id("c"), "component": "Column", "children": list(children)})

    def list(self, children: Sequence[str]) -> str:
        """一组一行一项的（处理记录、记忆、人物、收件箱……）：项和项之间一条细线（界面规范 §6「列表组」divide-y；
        负责人 11-14：有的列表没有分隔，看着怪）"""
        return self.add({"id": self._id("l"), "component": "List", "children": list(children)})

    def fold(self, summary: str, children: Sequence[str]) -> str:
        """收起来的一块（工具协议 §4 collapsed）：先只显示这一句和一个箭头，点开才画里面的。少用的选项放这里
        （走查重画稿：说明和少用的选项收起来，不删）"""
        return self.add({"id": self._id("c"), "component": "Column", "children": list(children), "collapsed": summary})

    def item(self, title: str, sub: Optional[str] = None, buttons: Sequence[str] = (), *,
             open: Optional[str] = None, strong: bool = True, icon: Optional[str] = None) -> str:
        """一行：左边标题（加粗）和一行小字，右边几个小按钮。`open` 是点这一行就点的那个按钮（放在 `buttons` 里，窗口不画它，画箭头）。
        `icon`：这一行最左边的图标（§4 itemIcons：一行里只有一个图标和一列字）"""
        left = [self.text(title, "strong" if strong else None)]
        if sub:
            left.append(self.text(sub.rstrip("。"), "caption"))      # 一行小字句尾不带句号（数据里的摘要常带）
        col = self.column(left)
        kids = [self.row([self.add({"id": self._id("i"), "component": "Icon", "name": icon}), col]) if icon else col]
        btns = list(buttons) + ([open] if open and open not in buttons else [])
        if btns:
            kids.append(self.row(btns))
        return self.row(kids, justify="spaceBetween", open=open)

    def mail_item(self, sender: str, subject: str, sub: Optional[str] = None, buttons: Sequence[str] = (), *,
                  open: Optional[str] = None, badge: Optional[str] = None, when: Optional[str] = None) -> str:
        """一封信一行：发件人加粗、主题不加粗（放不下省略）、截止日的小标签、来信时间；下面一行小字，右边几个小按钮"""
        subj: Dict[str, Any] = {"id": self._id("t"), "component": "Text", "text": subject, "maxLines": 1}
        head = [self.text(sender, "strong"), self.add(subj)]
        if badge:
            head.append(self.text(badge, "badge"))
        if when:
            head.append(self.text(when, "caption"))
        left = [self.row(head)]
        if sub:
            cap: Dict[str, Any] = {"id": self._id("t"), "component": "Text", "text": sub.rstrip("。"), "variant": "caption", "maxLines": 1}
            left.append(self.add(cap))
        kids = [self.column(left)]
        btns = list(buttons) + ([open] if open and open not in buttons else [])
        if btns:
            kids.append(self.row(btns))
        return self.row(kids, justify="spaceBetween", open=open)

    def link(self, text: str, button: str, sub: Optional[str] = None) -> str:
        """点了就去别处的一行（「收件箱里有 4 封在等你回复 ›」）：画成列表组里正常行高的一行，右边箭头。
        负责人 11-15：要点的入口做成一行小字，行高和普通的字一样，看不出能点、也不好点"""
        return self.list([self.item(text, sub, [button], open=button, strong=False)])

    # 选

    def choice(self, key: str, options: Iterable[Tuple[str, ...]], selected: str, *, label: str = "",
               submit: Optional[str] = None, placement: Optional[str] = None) -> str:
        """一组选项：`options` 是（值，字[，图标[，停在上面的一句]]）。值放在数据模型的 `/choices/<key>`。
        `submit`：选了就点这个按钮（按钮的上下文用 `{"path": "/choices/<key>/0"}` 取选的值）"""
        opts = []
        for o in options:
            opt: Dict[str, Any] = {"value": o[0], "label": o[1]}
            if len(o) > 2 and o[2]:
                opt["icon"] = o[2]
            if len(o) > 3 and o[3]:
                opt["tooltip"] = o[3]
            opts.append(opt)
        self.data.setdefault("choices", {})[key] = [selected] if selected else []     # 空的：一个都没选（「今天」上记忆想问的）
        comp: Dict[str, Any] = {"id": self._id("k"), "component": "ChoicePicker", "options": opts,
                                "value": {"path": f"/choices/{key}"}}
        if label:
            comp["label"] = label
        if submit:
            comp["submit"] = submit
        if placement:
            comp["placement"] = placement
        return self.add(comp)

    # 出

    def messages(self, top: Sequence[str], refresh: Optional[int] = None) -> List[dict]:
        """`refresh`：页看得见时过几秒再读（§4 pageRefresh，2 到 60），给后台在跑的任务看进度"""
        root: Dict[str, Any] = {"id": "root", "component": "Column", "children": list(top)}
        if refresh:
            root["refresh"] = refresh
        out = [{"version": VERSION, "createSurface": {"surfaceId": self.surface_id, "catalogId": CATALOG}},
               {"version": VERSION, "updateComponents": {"surfaceId": self.surface_id,
                                                         "components": [root] + self.components}}]
        if self.data:
            out.append({"version": VERSION, "updateDataModel": {"surfaceId": self.surface_id, "path": "/",
                                                                "value": self.data}})
        return out
