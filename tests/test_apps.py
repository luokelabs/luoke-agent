"""应用的页和权限（docs/界面接口.md §6、§10）：假的邮件工具带上清单的 service、permissions → 核心 → 界面接口。"""
from __future__ import annotations

import os as _os

assert _os.environ.get("LUOKE_AGENT_TESTING") == "1", "用 python3 -m unittest 跑：tests/__init__.py 先把一切指到临时目录"

import contextlib
import io
import json
import os
import queue
import shutil
import socket
import tempfile
import threading
import time
import unittest
from unittest import mock
from typing import Any, List, Optional, Tuple

from luoke_agent import __main__ as cli
from luoke_agent import a2ui, apps, cards
from luoke_agent import agent as agent_mod
from luoke_agent.agent import Agent
from luoke_agent.fake_tool import PERMISSIONS, SERVICE, FakeMail
from luoke_agent.mcp import BAD_TOKEN, outbox_uri
from luoke_agent.runner import Runner
from luoke_agent.state import State
from luoke_agent.toolsource import ToolSource, discover
from luoke_agent.ui import UIServer
from tests.test_hub import FakeHub, Handler

APP = "fake-mail"


def get(home: str, path: str) -> Tuple[int, Any]:
    c = cli._Conn(cli.ui_socket(home))
    try:
        c.request("GET", path)
        r = c.getresponse()
        return r.status, json.loads(r.read())
    finally:
        c.close()


def post(home: str, path: str, body: dict) -> Tuple[int, Any]:
    c = cli._Conn(cli.ui_socket(home))
    try:
        c.request("POST", path, json.dumps(body, ensure_ascii=False).encode(), {"Content-Type": "application/json"})
        r = c.getresponse()
        return r.status, json.loads(r.read())
    finally:
        c.close()


def get_raw(home: str, path: str) -> Tuple[int, str, bytes]:
    c = cli._Conn(cli.ui_socket(home))
    try:
        c.request("GET", path)
        r = c.getresponse()
        return r.status, r.getheader("Content-Type") or "", r.read()
    finally:
        c.close()


def no_search_id(data: dict) -> dict:
    """/search 的答复去掉这次搜索的编号（每次加一）。"""
    return {k: v for k, v in data.items() if k != "search"}


def buttons(messages: List[dict]) -> dict:
    """页上的按钮：动作名 → (组件编号, 组件)。"""
    out = {}
    for m in messages:
        for c in (m.get("updateComponents") or {}).get("components") or []:
            if c.get("component") == "Button":
                out[c["action"]["event"]["name"]] = (c["id"], c)
    return out


class _Base(unittest.TestCase):
    def setUp(self):
        self.dir = tempfile.mkdtemp(prefix="la")
        self.home = os.path.join(self.dir, "agent")
        self.fake = FakeMail()
        self.tool_sock = os.path.join(self.dir, "t", "agent.sock")
        self.tool_server = self.fake.server().start(self.tool_sock)
        self.state = State(self.home)
        self.src = ToolSource(APP, self.tool_sock, name="假邮件", service=SERVICE, permissions=PERMISSIONS)
        self.agent = Agent(self.state, [self.src], url_opener=lambda u: None)
        self.ui = UIServer(self.agent, cli.ui_socket(self.home), allow=lambda pid: pid == os.getpid()).start()
        self.agent.poll()
        self.q = self.agent.subscribe()
        self.events()

    def tearDown(self):
        self.ui.close()
        if self.tool_server is not None:
            self.tool_server.close()
        self.state.close()
        shutil.rmtree(self.dir, ignore_errors=True)

    def events(self, kind: Optional[str] = None) -> list:
        """取走到现在为止的事件；给了 kind 只留这一种的内容，没给就是 (事件, 内容)。"""
        out = []
        while True:
            try:
                e = self.q.get_nowait()
            except queue.Empty:
                return out
            if kind is None:
                out.append(e)
            elif e[0] == kind:
                out.append(e[1])

    def stop_tool(self):
        self.tool_server.close()
        self.tool_server = None

    def apps_entry(self) -> dict:
        status, data = get(self.home, "/apps")
        self.assertEqual(status, 200)
        return next(a for a in data["apps"] if a["id"] == APP)

    def rows(self) -> dict:
        status, data = get(self.home, "/permissions")
        self.assertEqual(status, 200)
        return {r["id"]: r for r in data["rows"] if r["app"] == APP}

    def op(self, pid: str, op: str, app: str = APP) -> dict:
        status, r = post(self.home, "/permissions", {"app": app, "id": pid, "op": op})
        self.assertEqual(status, 200, r)
        self.assertEqual(set(r) - {"url"}, {"text", "error"})
        if "url" in r:      # 只有 settings 带地址，由窗口在螺壳.app 里打开
            self.assertEqual(op, "settings")
            self.assertTrue(r["url"].startswith("x-apple.systempreferences:"))
        return r


class AppsTest(_Base):
    """§6：GET /apps、基础页、POST /open、apps 事件。"""

    def test_apps_lists_each_tool(self):
        bare = ToolSource("bare-tool", os.path.join(self.dir, "none", "agent.sock"))
        self.agent.add_source(bare)
        status, data = get(self.home, "/apps")
        self.assertEqual(status, 200)
        self.assertEqual([a["id"] for a in data["apps"]], [APP, "bare-tool"], "每个连着的工具一项")
        self.assertEqual(data["apps"][0], {
            "id": APP, "running": True, "summary": {"count": 2, "text": "2 件等你处理"},
            "pages": [{"id": "overview", "title": "概览"}, {"id": "rules", "title": "规则"}],
            "ui": {"pages": [{"id": "accounts", "title": "账号"}]}, "needs": []})
        self.assertEqual(data["apps"][1], {"id": "bare-tool", "running": False, "summary": None, "pages": [],
                                           "ui": None, "needs": []}, "清单里没写的：null 或空")

    def test_needs_is_asked_and_not_granted(self):
        self.assertEqual(self.apps_entry()["needs"], [], "清单里登记了、工具还没要：不算")
        self.fake.ask_access("fda")
        self.fake.ask_access("auto")       # 代你做的事是开关，不是要授权的
        self.agent.poll()
        self.assertEqual(self.apps_entry()["needs"], ["fda"])
        self.assertEqual(self.events("apps"), [{"app": APP}])
        self.fake.contacts = "granted"
        self.fake.ask_access("contacts")
        self.agent.poll()
        self.assertEqual(self.apps_entry()["needs"], ["fda"], "要了、已经给了的不算")

    def test_apps_event_only_when_something_changed(self):
        self.agent.poll()
        self.assertEqual(self.events("apps"), [], "什么都没变：不发")
        self.fake.ack({"id": next(iter(self.fake.items)), "state": "dismissed"}, {})
        self.agent.poll()
        self.assertEqual(self.events("apps"), [{"app": APP}], "概览变了")
        self.assertEqual(self.apps_entry()["summary"]["count"], 1)
        self.fake.auto = True
        self.agent.poll()
        self.assertEqual(self.events("apps"), [{"app": APP}], "权限状态变了")
        self.src.set_manifest(dict(SERVICE, pages=SERVICE["pages"][:1]), PERMISSIONS)
        self.agent.app_changed(APP)
        self.assertEqual(self.events("apps"), [{"app": APP}], "页列表变了")
        self.assertEqual([p["id"] for p in self.apps_entry()["pages"]], ["overview"])
        self.stop_tool()
        self.agent.poll()
        self.assertEqual(self.events("apps"), [{"app": APP}], "不在运行了")
        entry = self.apps_entry()
        self.assertFalse(entry["running"])
        self.assertIsNone(entry["summary"], "没在运行：不知道，不留旧的")

    def test_apps_event_when_installed_or_removed(self):
        self.agent.remove_source(APP)
        self.assertEqual(self.events("apps"), [{"app": APP}])
        self.assertEqual(get(self.home, "/apps")[1], {"apps": []})

    def test_page(self):
        status, data = get(self.home, f"/apps/{APP}/pages/overview")
        self.assertEqual(status, 200)
        msgs = data["messages"]
        self.assertTrue(all(next(iter(m[k] for k in a2ui.MESSAGE_KINDS if k in m))["surfaceId"] == f"{APP}/page/overview"
                            for m in msgs), "surfaceId 是 <id>/page/<页 id>")
        a2ui.build(msgs)
        texts = [c.get("text") for m in msgs for c in (m.get("updateComponents") or {}).get("components") or []]
        self.assertIn("2 件等你处理", texts)
        self.assertIn("帮助", texts)
        sites = [c.get("site") for m in msgs for c in (m.get("updateComponents") or {}).get("components") or []
                 if c.get("component") == "Button" and c["action"]["event"]["name"] == "agent.open_url"]
        self.assertEqual(sites, ["help.example.com"], "打开网页的按钮写明去哪个网站，同卡片")
        status, data = get(self.home, f"/apps/{APP}/pages/rules")
        self.assertEqual(status, 200)
        self.assertEqual(data["messages"][0]["createSurface"]["surfaceId"], f"{APP}/page/rules")

    def test_hidden_page_is_listed_with_its_flag_and_reachable(self):
        """`hidden: true` 的页（协议 §1a，2026-11-10 加）：`/apps` 照列、带上 `hidden`，窗口不画成标签；
        照样能读，`agent.open_page` 照样去得了（它是登记过的页）。"""
        pages = [{"id": "overview", "title": "概览"}, {"id": "rules", "title": "一条规则", "hidden": True}]
        self.src.set_manifest(dict(SERVICE, pages=pages), PERMISSIONS)
        self.agent.app_changed(APP)
        self.assertEqual(self.apps_entry()["pages"], pages)
        status, data = get(self.home, f"/apps/{APP}/pages/rules?item=r1")
        self.assertEqual(status, 200)
        self.assertEqual(data["messages"][0]["createSurface"]["surfaceId"], f"{APP}/page/rules")
        from luoke_agent.items import Item
        item = Item(key=f"{APP}/x", source=APP, kind="k", urgency="normal", title="", summary="", why_now="", card=[], extra={})
        self.assertEqual(self.agent._agent_action(item, "s", "agent.open_page", {"page": "rules", "args": {"item": "r1"}})["page"],
                         {"app": APP, "page": "rules", "args": {"item": "r1"}})
        self.src.set_manifest(dict(SERVICE, pages=[{"id": "rules", "title": "一条规则", "hidden": True}]), PERMISSIONS)
        self.agent.app_changed(APP)
        self.assertEqual(self.apps_entry()["pages"], [{"id": "rules", "title": "一条规则", "hidden": True}],
                         "页全是 hidden 也照收：应用页上没有标签")

    def test_reading_a_page_refreshes_the_summary(self):
        """页是现读的：工具那边概览变了（新一轮扫完），读页的同时标题旁的概览也跟上，不等下一轮读 outbox。"""
        self.assertEqual(self.apps_entry()["summary"]["count"], 2)
        self.fake.ack({"id": next(iter(self.fake.items)), "state": "dismissed"}, {})     # 没 poll
        status, _ = get(self.home, f"/apps/{APP}/pages/overview")
        self.assertEqual(status, 200)
        self.assertEqual(self.events("apps"), [{"app": APP}], "概览变了：告诉窗口重新取")
        self.assertEqual(self.apps_entry()["summary"]["count"], 1)
        get(self.home, f"/apps/{APP}/pages/overview")
        self.assertEqual(self.events("apps"), [], "没变：不发")

    def test_page_refusals(self):
        self.assertEqual(get(self.home, "/apps/nobody/pages/overview")[0], 404)
        self.assertEqual(get(self.home, f"/apps/{APP}/pages/accounts")[0], 404, "深页不是基础页")
        self.assertEqual(get(self.home, f"/apps/{APP}/pages/nope")[0], 404)
        self.assertEqual(get(self.home, f"/apps/{APP}/pages/")[0], 404)

    def _fallback(self, override) -> List[str]:
        self.fake.page_override = override
        status, data = get(self.home, f"/apps/{APP}/pages/overview")
        self.assertEqual(status, 200)
        a2ui.build(data["messages"], page=True)
        return [c.get("text") for m in data["messages"] for c in (m.get("updateComponents") or {}).get("components") or []
                if c.get("component") == "Text"]

    def test_page_that_cannot_be_drawn_is_plain_text(self):
        good = self.fake.page("overview")
        bad_kind = json.loads(json.dumps(good))
        bad_kind[1]["updateComponents"]["components"][0]["component"] = "WebView"
        too_many = [good[0], {"version": "v0.9", "updateComponents": {"surfaceId": "overview", "components":
                    [{"id": "root", "component": "Column", "children": [f"t{i}" for i in range(401)]}]
                    + [{"id": f"t{i}", "component": "Text", "text": "x"} for i in range(401)]}}]
        too_long = [good[0], {"version": "v0.9", "updateComponents": {"surfaceId": "overview", "components":
                    [{"id": "root", "component": "Text", "text": "长" * 2001}]}}]
        huge = [good[0], {"version": "v0.9", "updateDataModel": {"surfaceId": "overview", "path": "/",
                                                                 "value": {"x": "大" * (1 << 20)}}}]
        for name, override in (("不在目录里的组件", bad_kind), ("超过 400 个组件（页的上限，§4 bigPages）", too_many), ("超过 2000 字", too_long),
                               ("超过 1 MB", huge), ("不是 JSON", "<html>"), ("不是消息数组", {"a": 1})):
            with self.subTest(name):
                self.assertEqual(self._fallback(override), ["概览", "这一页画不了。"], "退回纯文本，不带工具的内容")

    def test_page_of_a_tool_not_running(self):
        self.stop_tool()
        status, data = get(self.home, f"/apps/{APP}/pages/overview")
        self.assertEqual(status, 503)
        self.assertEqual(data["error"], "假邮件现在没在运行。")

    def test_page_buttons_go_through_action(self):
        _, data = get(self.home, f"/apps/{APP}/pages/overview")
        sid = f"{APP}/page/overview"
        auto_id, _ = buttons(data["messages"])["mail_auto"]
        status, r = post(self.home, "/action", {"surfaceId": sid, "sourceComponentId": auto_id, "context": {"on": False}})
        self.assertEqual(status, 200)
        self.assertEqual(r, {"text": "好，以后促销邮件不用点就归档，每次都告诉你。", "error": False})
        self.assertTrue(self.fake.auto, "写死的值只认页上的：界面送来的 false 不算")
        ua = self.fake.user_actions[-1]
        self.assertEqual((ua["surfaceId"], ua["componentId"]), ("overview", auto_id), "user_action 的 surfaceId 是页 id")
        self.assertEqual(self.events("busy"), [{"surfaceId": sid}])
        _, data = get(self.home, f"/apps/{APP}/pages/overview")
        settings_id, _ = buttons(data["messages"])["mail_open_settings"]
        n = len(self.fake.user_actions)
        r = self.agent.tap(sid, settings_id, {})
        self.assertFalse(r["error"], r)
        self.assertEqual(self.fake.opened, ["settings"])
        self.assertEqual(len(self.fake.user_actions), n, "只读的不带 user_action")
        self.assertEqual(self.agent.tap(sid, "nope", {})["text"], "这个按钮已经不在了。")

    def test_open_page_opens_only_a_page_of_this_app(self):
        """agent.open_page：页上、卡片上的按钮只开这个应用自己登记的页；别的应用的页、没登记的页都拒（工具协议 §5）。"""
        card = cards.Card("overview")
        card.heading("邮件助手")
        card.buttons(cards.button("看规则", "agent.open_page", {"page": "rules"}),
                     cards.button("看扫描的清理记录", "agent.open_page", {"page": "cleaned"}),
                     cards.button("看账号", "agent.open_page", {"page": "accounts"}))
        self.fake.page_override = card.messages()
        _, data = get(self.home, f"/apps/{APP}/pages/overview")
        sid = f"{APP}/page/overview"
        ids = [c["id"] for m in data["messages"] for c in (m.get("updateComponents") or {}).get("components") or []
               if c.get("component") == "Button"]
        self.assertEqual(len(ids), 3, data)
        status, r = post(self.home, "/action", {"surfaceId": sid, "sourceComponentId": ids[0], "context": {"page": "cleaned"}})
        self.assertEqual(status, 200)
        self.assertEqual(r, {"text": "", "error": False, "page": {"app": APP, "page": "rules"}},
                         "页 id 只认按钮上写死的，界面送来的不算")
        for cid in ids[1:]:       # 扫描的页（别的应用的），邮件助手自己界面里的页（不在 service.pages 里）
            status, r = post(self.home, "/action", {"surfaceId": sid, "sourceComponentId": cid, "context": {}})
            self.assertEqual((status, r), (200, {"text": "这一页打不开。", "error": True}))
        self.assertEqual(self.fake.user_actions, [], "不转给工具")
        # 卡片上的：同样只开出这张卡片的应用自己的页
        from luoke_agent.items import Item
        item = Item(key=f"{APP}/x", source=APP, kind="k", urgency="normal", title="", summary="", why_now="", card=[], extra={})
        self.assertEqual(self.agent._agent_action(item, "s", "agent.open_page", {"page": "rules"})["page"],
                         {"app": APP, "page": "rules"})
        self.assertTrue(self.agent._agent_action(item, "s", "agent.open_page", {"page": "cleaned"})["error"])
        other = Item(key="agent/x", source="agent", kind="k", urgency="normal", title="", summary="", why_now="", card=[], extra={})
        self.assertTrue(self.agent._agent_action(other, "s", "agent.open_page", {"page": "rules"})["error"],
                        "不是应用出的卡片：没有自己的页")

    def test_page_tap_events(self):
        _, data = get(self.home, f"/apps/{APP}/pages/overview")
        sid = f"{APP}/page/overview"
        self.events()
        self.agent.tap(sid, buttons(data["messages"])["mail_auto"][0], {})
        got = self.events()
        self.assertEqual([e for e, _ in got], ["busy", "result", "apps"])
        self.assertEqual(got[1][1], {"surfaceId": sid, "text": "好，以后促销邮件不用点就归档，每次都告诉你。", "error": False,
                                     "replaced": False}, "工具回的卡片不画：窗口点完重新取这一页")
        self.assertEqual(got[2][1], {"app": APP})

    def test_page_tap_when_tool_stopped(self):
        _, data = get(self.home, f"/apps/{APP}/pages/overview")
        self.stop_tool()
        r = self.agent.tap(f"{APP}/page/overview", buttons(data["messages"])["mail_auto"][0], {})
        self.assertEqual(r, {"text": "假邮件现在没在运行。", "error": True})

    def test_open(self):
        status, r = post(self.home, "/open", {"app": APP})
        self.assertEqual((status, r["error"]), (200, False))
        status, r = post(self.home, "/open", {"app": APP, "page": "accounts"})
        self.assertEqual((status, r["error"]), (200, False))
        self.assertEqual(self.fake.opened, ["ui:", "ui:accounts"])
        self.assertEqual(self.fake.user_actions, [], "打开是只读的")
        self.assertEqual(post(self.home, "/open", {"app": APP, "page": "overview"})[1],
                         {"text": "没有这一页。", "error": True}, "只认 service.ui.pages 里的")
        self.assertEqual(post(self.home, "/open", {"app": "nobody"})[1], {"text": "没有这个应用。", "error": True})
        self.assertEqual(post(self.home, "/open", {"page": "accounts"})[0], 400)
        self.assertEqual(post(self.home, "/open", {"app": APP, "page": 3})[0], 400)
        self.assertEqual(self.fake.opened, ["ui:", "ui:accounts"])
        self.src.set_manifest({"summary": True}, PERMISSIONS)
        self.assertEqual(post(self.home, "/open", {"app": APP})[1], {"text": "假邮件没有自己的界面。", "error": True})
        self.src.set_manifest(SERVICE, PERMISSIONS)
        self.stop_tool()
        self.assertEqual(post(self.home, "/open", {"app": APP})[1], {"text": "假邮件现在没在运行。", "error": True})


class PageAdditionsTest(_Base):
    """应用页 2026-11-10 加的几样（工具协议 §4）：页带参数、大页、密码框、页的刷新、存文件。"""

    SID = f"{APP}/page/rules"

    def page_with(self, card: "cards.Card") -> List[dict]:
        self.fake.page_override = card.messages()
        status, data = get(self.home, f"/apps/{APP}/pages/rules")
        self.assertEqual(status, 200, data)
        return data["messages"]

    def test_core_says_it_knows_them(self):
        get(self.home, f"/apps/{APP}/pages/rules")
        feats = a2ui.A2UI_FEATURES
        for f in ("pageArgs", "bigPages", "secureField", "pageRefresh", "saveFile"):
            self.assertIn(f, feats)

    def test_page_read_with_args(self):
        status, data = get(self.home, f"/apps/{APP}/pages/rules?q=%E5%8F%91%E7%A5%A8%20x%2By&cursor=2")
        self.assertEqual(status, 200, data)
        self.assertEqual(self.fake.page_args[-1], {"cursor": "2", "q": "发票 x+y"}, "工具拿到的是解开的参数")
        texts = [c.get("text") for m in data["messages"] for c in (m.get("updateComponents") or {}).get("components") or []]
        self.assertIn("搜「发票 x+y」", texts)
        self.assertEqual(data["messages"][0]["createSurface"]["surfaceId"], self.SID, "surfaceId 不带参数：一页一份")
        get(self.home, f"/apps/{APP}/pages/rules")
        self.assertEqual(self.fake.page_args[-1], {}, "不带参数就是不带")
        get(self.home, f"/apps/{APP}/pages/rules?q=")
        self.assertEqual(self.fake.page_args[-1], {"q": ""}, "空的值照样交过去")

    def test_logs_name_the_page_not_its_args(self):
        """带参数读页：核心的日志只记页 id，不记查询串（参数里是用户填的字），转述工具出错时也一样；工具的日志也只记页"""
        secret = "%E7%8E%8B%E8%80%81%E5%B8%88%E7%9A%84%E4%BF%A1"           # 「王老师的信」
        for why in ("画不了", "工具出错", "读不了"):
            with self.subTest(why):
                err = io.StringIO()
                with contextlib.redirect_stderr(err):
                    if why == "画不了":
                        self.fake.page_override = [{"version": "v0.9", "createSurface": {"surfaceId": "x"}}]
                        status, _ = get(self.home, f"/apps/{APP}/pages/rules?q={secret}&cursor=2")
                        self.assertEqual(status, 200)
                    elif why == "工具出错":
                        self.fake.page_override = None
                        real = self.fake.page
                        self.fake.page = lambda pid, a=None: (_ for _ in ()).throw(ValueError("王老师的信"))
                        try:
                            status, _ = get(self.home, f"/apps/{APP}/pages/rules?q={secret}")
                        finally:
                            self.fake.page = real
                        self.assertEqual(status, 200, "照样答一页「这一页画不了」")
                    else:
                        self.src._read(f"page/nope?q={secret}", lambda v: v)    # 读不了的资源：toolsource 的那一句
                log = err.getvalue()
                self.assertNotIn("王老师", log)
                self.assertNotIn(secret, log)
                self.assertNotIn("cursor", log)
                self.assertNotIn("?", log)
                self.assertIn("nope" if why == "读不了" else "rules", log, "记下是哪一页")

    def test_page_read_refuses_bad_args(self):
        n = len(self.fake.page_args)
        for query in ("a=1&b=2&c=3&d=4&e=5", "Q=1", "q=1&q=2", "q", "q=" + "%E9%95%BF" * 201, "item%0A=1"):
            with self.subTest(query):
                status, data = get(self.home, f"/apps/{APP}/pages/rules?{query}")
                self.assertEqual(status, 400, data)
                self.assertIn("参数", data["error"])
        self.assertEqual(len(self.fake.page_args), n, "不合的不去读工具")
        self.assertEqual(get(self.home, f"/apps/{APP}/pages/nope?q=1")[0], 404)

    def test_open_page_with_args(self):
        card = cards.Card("rules")
        card.text_field("q", "搜规则")
        card.buttons(cards.button("搜", "agent.open_page", {"page": "rules", "args": {"q": {"path": "/fields/q"}}}),
                     cards.button("下一页", "agent.open_page", {"page": "rules", "args": {"cursor": "2"}}),
                     cards.button("别的应用的页", "agent.open_page", {"page": "cleaned", "args": {"cursor": "2"}}))
        ids = [i for i, _ in sorted(((c["id"], c) for m in self.page_with(card)
                                     for c in (m.get("updateComponents") or {}).get("components") or []
                                     if c.get("component") == "Button"), key=lambda x: int(x[0].lstrip("b")))]
        search, nxt, other = ids
        status, r = post(self.home, "/action", {"surfaceId": self.SID, "sourceComponentId": search,
                                                 "context": {"page": "overview", "args": {"q": "发票", "x": "1"}}})
        self.assertEqual((status, r), (200, {"text": "", "error": False,
                                             "page": {"app": APP, "page": "rules", "args": {"q": "发票"}}}),
                         "绑定的值用界面送来的；页 id 和别的键只认按钮上写的")
        status, r = post(self.home, "/action", {"surfaceId": self.SID, "sourceComponentId": search, "context": {}})
        self.assertEqual(r["page"]["args"], {"q": ""}, "界面没送就用这边的数据模型")
        status, r = post(self.home, "/action", {"surfaceId": self.SID, "sourceComponentId": search,
                                                 "context": {"args": {"q": "长" * 201}}})
        self.assertEqual(r, {"text": "填的字太长了，最多 200 个字。", "error": True})
        status, r = post(self.home, "/action", {"surfaceId": self.SID, "sourceComponentId": search,
                                                 "context": {"args": {"q": ["x"]}}})
        self.assertEqual(r, {"text": "这一页打不开。", "error": True})
        status, r = post(self.home, "/action", {"surfaceId": self.SID, "sourceComponentId": nxt, "context": {"args": {"cursor": "9"}}})
        self.assertEqual(r["page"], {"app": APP, "page": "rules", "args": {"cursor": "2"}}, "写死的值只认页上的")
        status, r = post(self.home, "/action", {"surfaceId": self.SID, "sourceComponentId": other, "context": {}})
        self.assertEqual(r, {"text": "这一页打不开。", "error": True})
        self.assertEqual(self.fake.user_actions, [], "不转给工具")
        from luoke_agent.items import Item
        item = Item(key=f"{APP}/x", source=APP, kind="k", urgency="normal", title="", summary="", why_now="", card=[], extra={})
        self.assertEqual(self.agent._agent_action(item, "s", "agent.open_page", {"page": "overview", "args": {"item": "m1"}})["page"],
                         {"app": APP, "page": "overview", "args": {"item": "m1"}}, "卡片上的也能带")
        self.assertNotIn("args", self.agent._agent_action(item, "s", "agent.open_page", {"page": "overview", "args": {}})["page"])

    def test_text_field_on_a_page_reaches_the_tool(self):
        """改写一条理解这类：页上的输入框，按钮的上下文绑着它，填的字随点按交给工具。"""
        card = cards.Card("rules")
        card.text_field("q", "搜邮件", "原来的字")
        card.buttons(cards.button("搜", "mail_find", {"query": {"path": "/fields/q"}}))
        msgs = self.page_with(card)
        bid = buttons(msgs)["mail_find"][0]
        r = self.agent.tap(self.SID, bid, {"query": "某某商城"})
        self.assertFalse(r["error"], r)
        self.assertEqual(self.fake.finds[-1]["query"], "某某商城")
        self.agent.tap(self.SID, bid, {})
        self.assertEqual(self.fake.finds[-1]["query"], "原来的字", "界面没送就用页上的")

    def test_secure_field_goes_only_to_the_tool(self):
        card = cards.Card("rules")
        card.text_field("code", "IMAP 授权码", secure=True)
        card.buttons(cards.button("加上", "mail_connect", {"code": {"path": "/fields/code"}}, primary=True))
        msgs = self.page_with(card)
        field = next(c for m in msgs for c in (m.get("updateComponents") or {}).get("components") or []
                     if c.get("component") == "TextField")
        self.assertEqual(field["variant"], "obscured", "原样交给窗口画成密码框")
        bid = buttons(msgs)["mail_connect"][0]
        err = io.StringIO()
        with contextlib.redirect_stderr(err):
            status, r = post(self.home, "/action", {"surfaceId": self.SID, "sourceComponentId": bid,
                                                     "context": {"code": "abcd-efgh"}})
            self.assertEqual((status, r), (200, {"text": "邮箱加上了。", "error": False}))
            status, r = post(self.home, "/action", {"surfaceId": self.SID, "sourceComponentId": bid,
                                                     "context": {"code": "wxyz-0000"}})
            self.assertEqual(r, {"text": "授权码不对。", "error": True})
        self.assertEqual(self.fake.connected, [True, False])
        self.assertEqual(self.fake.user_actions[-1]["componentId"], bid, "写入照常带 user-action")
        self.assertEqual(self.agent.pages[self.SID][2].data["fields"]["code"], "", "核心这边的数据模型里没有")
        self.assertNotIn("abcd", err.getvalue())
        events = json.dumps(self.events(), ensure_ascii=False)
        self.assertNotIn("abcd", events, "发给界面的事件里没有")
        for root, _, files in os.walk(self.dir):       # 记下的状态（连 -wal）、日志：都没有
            for f in files:
                if not os.path.isfile(os.path.join(root, f)):
                    continue                              # socket
                with open(os.path.join(root, f), "rb") as fh:
                    data = fh.read()
                self.assertNotIn(b"abcd-efgh", data, f"不写盘：{f}")
                self.assertNotIn(b"wxyz-0000", data, f"不写盘：{f}")

    def test_secure_field_goes_only_by_its_own_path(self):
        """按钮引用的是密码框上面一层（`/fields`）的页不画：那样会连授权码整个交出去；正好引用的照交"""
        card = cards.Card("rules")
        card.text_field("code", "IMAP 授权码", secure=True)
        card.text_field("name", "名字", "")
        card.buttons(cards.button("搜", "mail_find", {"query": {"path": "/fields/name"}, "all": {"path": "/fields"}}))
        with contextlib.redirect_stderr(io.StringIO()):
            msgs = self.page_with(card)
        texts = [c.get("text") for m in msgs for c in (m.get("updateComponents") or {}).get("components") or []]
        self.assertIn("这一页画不了。", texts)
        self.assertNotIn("mail_find", buttons(msgs), "没有能点的按钮")
        card = cards.Card("rules")
        card.text_field("code", "IMAP 授权码", secure=True)
        card.buttons(cards.button("加上", "mail_connect", {"code": {"path": "/fields/code"}}, primary=True))
        connect = buttons(self.page_with(card))["mail_connect"][0]
        status, r = post(self.home, "/action", {"surfaceId": self.SID, "sourceComponentId": connect,
                                                 "context": {"code": "abcd-efgh"}})
        self.assertEqual(r, {"text": "邮箱加上了。", "error": False}, "正好引用它的照交")

    def test_button_arguments_are_not_kept(self):
        """按钮调用的 arguments（用户在卡片、页上填的、选的）只交给工具：不进结果存档（状态库）、活动（发给界面的事件，
        「活动」照它们记）和日志（随诊断导出）。卡片做完照常存档，存的是工具回的那一句和卡片"""
        draft, query = "给王老师的回信：周五下午可以", "王老师的答辩安排"
        card = cards.Card("reply")
        card.text("王老师：答辩时间？")
        card.text_field("draft", "回信")
        card.buttons(cards.button("发出去", "mail_find", {"query": {"path": "/fields/draft"}}))
        with self.fake.lock:
            self.fake.items["reply/1"] = {"id": "reply/1", "kind": "new-mail", "urgency": "normal", "deadline": None,
                                          "expires": None, "created": "2026-11-10T09:00:00+0800", "why_now": "刚到",
                                          "title": "王老师的信", "summary": "", "_card": card.messages()}
        self.fake.find_override = {"text": "回好了。", "done": True}
        err = io.StringIO()
        with contextlib.redirect_stderr(err):
            self.agent.poll()
            sid = next(s for s, (k, _) in self.agent.surfaces.items() if k == f"{APP}/reply/1")
            bid = buttons(self.agent.surfaces[sid][1].messages())["mail_find"][0]
            status, r = post(self.home, "/action", {"surfaceId": sid, "sourceComponentId": bid, "context": {"query": draft}})
            self.assertEqual((status, r["error"]), (200, False), r)
            page = cards.Card("rules")
            page.text_field("q", "搜邮件")
            page.buttons(cards.button("搜", "mail_find", {"query": {"path": "/fields/q"}}))
            pid = buttons(self.page_with(page))["mail_find"][0]
            status, r = post(self.home, "/action", {"surfaceId": self.SID, "sourceComponentId": pid, "context": {"query": query}})
            self.assertEqual(status, 200, r)
        self.assertEqual([f["query"] for f in self.fake.finds[-2:]], [draft, query], "交给了工具")
        kept = self.state.kept_contents(0)
        self.assertTrue(any(row["key"] == f"{APP}/reply/1" for row in kept), "做完的卡片照常存档")
        stored = json.dumps(kept, ensure_ascii=False)
        events = json.dumps(self.events(), ensure_ascii=False)
        self.assertIn("回好了。", stored + events, "存的、发给界面的是工具回的那一句")
        for value in (draft, query):
            self.assertNotIn(value, stored, "结果存档里没有")
            self.assertNotIn(value, events, "活动（发给界面的事件）里没有")
            self.assertNotIn(value, err.getvalue(), "日志里没有")
        for root, _, files in os.walk(self.home):     # 状态库连 -wal、日志：都没有
            for f in files:
                path = os.path.join(root, f)
                if os.path.isfile(path):
                    with open(path, "rb") as fh:
                        data = fh.read()
                    for value in (draft, query):
                        self.assertNotIn(value.encode(), data, f"不写盘：{f}")

    def test_secure_field_on_a_card_is_refused(self):
        card = cards.Card("c")
        card.text_field("code", "授权码", secure=True)
        self.assertTrue(a2ui.validate(card.messages()), "卡片（outbox、搜索结果）上不认")

    def test_big_page_and_refresh_pass_through(self):
        card = cards.Card("rules")
        card.refresh = 5
        for i in range(300):
            card.text(f"第 {i} 封")
        msgs = self.page_with(card)
        comps = [c for m in msgs for c in (m.get("updateComponents") or {}).get("components") or []]
        self.assertEqual(len(comps), 301, "超过 200 个也画")
        self.assertEqual(next(c for c in comps if c["id"] == "root")["refresh"], 5)
        card = cards.Card("rules")
        for i in range(400):
            card.text(f"第 {i} 封")
        texts = [c.get("text") for m in self.page_with(card) for c in (m.get("updateComponents") or {}).get("components") or []
                 if c.get("component") == "Text"]
        self.assertEqual(texts, ["规则", "这一页画不了。"], "超过 400 个照旧退回纯文本")

    def test_file_in_the_answer(self):
        card = cards.Card("rules")
        card.buttons(cards.button("导出成 Gmail 过滤器", "mail_export_rules"))
        bid = buttons(self.page_with(card))["mail_export_rules"][0]
        status, r = post(self.home, "/action", {"surfaceId": self.SID, "sourceComponentId": bid, "context": {}})
        self.assertEqual(status, 200)
        self.assertEqual(r["text"], "规则文件好了，选个位置存。")
        self.assertEqual(r["file"]["name"], "gmail-filters.xml")
        self.assertEqual(r["file"]["mediaType"], "application/xml")
        self.assertTrue(r["file"]["text"].startswith("<?xml"))
        for bad in ({"name": "../.zshrc", "mediaType": "text/plain", "text": "x"},
                    {"name": "a.txt", "mediaType": "text/plain", "text": "x" * (a2ui.MAX_FILE_BYTES + 1)}, "x"):
            self.fake.export_file = bad
            with contextlib.redirect_stderr(io.StringIO()):
                status, r = post(self.home, "/action", {"surfaceId": self.SID, "sourceComponentId": bid, "context": {}})
            self.assertEqual((status, r), (200, {"text": "规则文件好了，选个位置存。", "error": False}), "形状不对：只交那句话")


class SearchTest(_Base):
    """搜索框（docs/界面接口.md §7）：词直接给工具，不经模型；卡片校验过交给窗口，按钮走 /action。"""

    def test_search_returns_the_tools_card(self):
        status, data = post(self.home, "/search", {"query": " 账单 "})
        self.assertEqual(status, 200)
        self.assertEqual(self.fake.finds, [{"query": "账单", "limit": 10}])
        self.assertEqual(data["failed"], [])
        (r,) = data["results"]
        self.assertEqual((r["app"], r["name"]), (APP, "假邮件"))
        a2ui.build(r["messages"])
        self.assertEqual(r["messages"][0]["createSurface"]["surfaceId"], f"{APP}/search")

    def test_search_button_goes_through_action(self):
        _, data = post(self.home, "/search", {"query": "账单", "limit": 3})
        self.assertEqual(self.fake.finds[-1]["limit"], 3)
        sid = f"{APP}/search"
        button, _ = buttons(data["results"][0]["messages"])["mail_open"]
        self.events()
        status, r = post(self.home, "/action", {"surfaceId": sid, "sourceComponentId": button, "context": {}})
        self.assertEqual(status, 200)
        self.assertFalse(r["error"], r)
        self.assertEqual(self.fake.opened, ["found"])
        self.assertEqual(self.events("busy"), [{"surfaceId": sid}])

    def test_new_search_replaces_the_buttons(self):
        _, first = post(self.home, "/search", {"query": "账单"})
        old, _ = buttons(first["results"][0]["messages"])["mail_open"]
        card = cards.Card("find")
        card.text("换了一张")
        self.fake.find_override = {"text": "找到 1 封。", "hits": [{"id": "x", "title": "x"}], "card": card.messages()}
        post(self.home, "/search", {"query": "别的"})
        self.assertEqual(self.agent.tap(f"{APP}/search", old, {})["text"], "这个按钮已经不在了。")

    def test_nothing_found(self):
        card = cards.Card("find")
        card.text("没有找到")
        self.fake.find_override = {"text": "没有找到。", "hits": [], "card": card.messages()}
        self.assertEqual(no_search_id(post(self.home, "/search", {"query": "账单"})[1]), {"results": [], "failed": [], "asked": 1})

    def test_hits_without_a_card_are_drawn_from_the_hits(self):
        hit = {"id": "a|1", "title": "某某商城的账单", "line": "某某商城", "date": "2026-11-02", "snippet": "…本月账单…",
               "actions": [{"name": "mail_open", "title": "打开", "args": {"id": "a|1"}, "primary": True},
                           {"name": "agent.open_url", "title": "去网站", "args": {"url": "https://example.com"}}]}
        self.fake.find_override = {"text": "找到 1 封。", "hits": [hit, {"id": "bad"}, "junk"], "card": []}
        data = post(self.home, "/search", {"query": "账单"})[1]
        self.assertEqual(data["failed"], [])
        (r,) = data["results"]
        surface = a2ui.build(r["messages"])
        texts = [c.get("text") for c in r["messages"][1]["updateComponents"]["components"] if c.get("component") == "Text"]
        self.assertEqual(texts, ["某某商城的账单", "某某商城 · 2026-11-02", "…本月账单…", "打开"], "没标题的、不是一条的不画")
        self.assertEqual(list(buttons(r["messages"])), ["mail_open"], "agent 自己的动作不从工具的结果里认")
        self.assertIsNotNone(surface)
        button, _ = buttons(r["messages"])["mail_open"]
        status, out = post(self.home, "/action", {"surfaceId": f"{APP}/search", "sourceComponentId": button, "context": {}})
        self.assertEqual((status, out["error"]), (200, False), out)

    def test_hits_that_cannot_be_drawn_count_as_failed(self):
        self.fake.find_override = {"text": "找到 1 封。", "hits": [{"id": "x"}], "card": []}
        with contextlib.redirect_stderr(io.StringIO()) as err:
            self.assertEqual(no_search_id(post(self.home, "/search", {"query": "账单"})[1]), {"results": [], "failed": ["假邮件"], "asked": 1},
                             "说搜到了却一条都画不了：不能说成没找到")
        self.assertIn("搜索结果画不了", err.getvalue())

    def test_bad_card_with_good_hits_keeps_the_hits(self):
        hit = {"id": "x", "title": "某某商城的账单", "actions": [{"name": "mail_open", "title": "打开", "args": {"plan_id": "x"}}]}
        self.fake.find_override = {"text": "找到 1 封。", "hits": [hit], "card": [{"nope": 1}]}
        with contextlib.redirect_stderr(io.StringIO()) as err:
            data = post(self.home, "/search", {"query": "账单"})[1]
        self.assertEqual(data["failed"], [])
        (r,) = data["results"]
        self.assertEqual([h["id"] for h in r["hits"]], ["x"], "只丢卡片，hits 照给")
        a2ui.build(r["messages"])
        self.assertEqual(list(buttons(r["messages"])), ["mail_open"], "旧窗口照 hits 画")
        self.assertIn("搜索卡片画不了", err.getvalue())
        self.assertNotIn("账单", err.getvalue(), "日志不记搜了什么")

    def test_bad_card_without_usable_hits_counts_as_failed(self):
        self.fake.find_override = {"text": "找到 1 封。", "hits": [{"id": "x"}], "card": [{"nope": 1}]}
        with contextlib.redirect_stderr(io.StringIO()) as err:
            self.assertEqual(no_search_id(post(self.home, "/search", {"query": "账单"})[1]), {"results": [], "failed": ["假邮件"], "asked": 1})
        self.assertIn("搜索结果画不了", err.getvalue())
        self.assertNotIn("账单", err.getvalue(), "日志不记搜了什么")

    def test_actions_the_tool_does_not_have_are_dropped(self):
        hit = {"id": "x", "title": "x", "actions": [{"name": "mail_nope", "title": "没这个", "primary": True},
                                                    {"name": "mail_open", "title": "打开", "args": {"plan_id": "x"}}]}
        self.fake.find_override = {"text": "找到 1 封。", "hits": [hit], "card": []}
        (r,) = post(self.home, "/search", {"query": "账单"})[1]["results"]
        self.assertEqual(r["hits"][0]["actions"], [{"name": "mail_open", "title": "打开"}], "不在 tools/list 里的不画")
        self.assertEqual(list(buttons(r["messages"])), ["mail_open"])

    def test_tool_stopped(self):
        self.stop_tool()
        self.assertEqual(no_search_id(post(self.home, "/search", {"query": "账单"})[1]), {"results": [], "failed": ["假邮件"], "asked": 1})

    def test_hits_go_to_the_window_as_given(self):
        hit = {"id": "a|1", "kind": "mail", "title": " 某某商城的账单 ", "line": "某某商城", "date": "2026-11-02",
               "source": "ming@example.com", "snippet": "…本月账单…", "strong": True, "thumb": "thumb/1",
               "score": 0.9, "secret": "不该交给窗口",
               "actions": [{"name": "mail_open", "title": "打开", "args": {"plan_id": "found"}, "primary": True},
                           {"name": "agent.open_url", "title": "去网站", "args": {"url": "https://example.com"}},
                           {"name": "mail_open", "title": "x" * 40}]}
        bad_thumb = {"id": "b", "title": "b", "thumb": "https://example.com/x.png"}
        self.fake.find_override = {"text": "找到 2 封。", "hits": [hit, {"id": "bad"}, "junk", bad_thumb, dict(hit)],
                                   "card": []}
        data = post(self.home, "/search", {"query": "账单"})[1]
        self.assertIsInstance(data["search"], int)
        (r,) = data["results"]
        self.assertEqual(r["hits"], [
            {"id": "a|1", "kind": "mail", "title": "某某商城的账单", "line": "某某商城", "date": "2026-11-02",
             "snippet": "…本月账单…", "source": "ming@example.com", "strong": True, "thumb": "thumb/1",
             "actions": [{"name": "mail_open", "title": "打开", "primary": True},
                         {"name": "mail_open", "title": "x" * 20}]},
            {"id": "b", "title": "b", "actions": []}],
            "只留认得的字段；没标题的、编号重复的、agent 自己的动作、不是 thumb/ 的图都不交；args 留在 agent")
        a2ui.build(r["messages"])        # 旧窗口照旧画卡片

    def test_a_tool_that_only_gives_a_card_has_no_hits(self):
        (r,) = post(self.home, "/search", {"query": "账单"})[1]["results"]
        self.assertEqual(r["hits"], [{"id": "found", "title": "某某商城的账单", "actions": []}])
        card = cards.Card("find")
        card.text("只有卡片")
        self.fake.find_override = {"text": "找到 1 封。", "card": card.messages()}
        (r,) = post(self.home, "/search", {"query": "账单"})[1]["results"]
        self.assertNotIn("hits", r)
        a2ui.build(r["messages"])

    def _search_with_actions(self) -> dict:
        hit = {"id": "a|1", "title": "某某商城的账单", "thumb": "thumb/1",
               "actions": [{"name": "mail_open", "title": "打开", "args": {"plan_id": "one"}, "primary": True},
                           {"name": "mail_open", "title": "在邮件助手里看", "args": {"plan_id": "two"}}]}
        self.fake.find_override = {"text": "找到 1 封。", "hits": [hit], "card": []}
        return post(self.home, "/search", {"query": "账单"})[1]

    def test_hit_buttons_go_to_the_tool_with_the_hits_own_args(self):
        data = self._search_with_actions()
        status, out = post(self.home, "/hit", {"search": data["search"], "app": APP, "hit": "a|1", "action": 1,
                                               "args": {"plan_id": "从窗口来的"}})
        self.assertEqual((status, out["error"]), (200, False), out)
        self.assertEqual(self.fake.opened, ["two"], "同名的动作按序号分，参数从结果里取")
        post(self.home, "/hit", {"search": data["search"], "app": APP, "hit": "a|1", "action": 0})
        self.assertEqual(self.fake.opened, ["two", "one"])

    def test_hit_buttons_only_for_this_search(self):
        data = self._search_with_actions()
        for body in ({"search": data["search"] + 1, "app": APP, "hit": "a|1", "action": 0},
                     {"search": data["search"], "app": APP, "hit": "a|2", "action": 0},
                     {"search": data["search"], "app": "别的", "hit": "a|1", "action": 0},
                     {"search": data["search"], "app": APP, "hit": "a|1", "action": 2},
                     {"search": data["search"], "app": APP, "hit": "a|1", "action": True},
                     {"search": data["search"], "app": APP, "hit": "a|1", "action": "mail_open"}):
            status, out = post(self.home, "/hit", body)
            self.assertEqual((status, out["error"]), (200, True), body)
        post(self.home, "/search", {"query": "别的"})
        out = post(self.home, "/hit", {"search": data["search"], "app": APP, "hit": "a|1", "action": 0})[1]
        self.assertEqual(out, {"text": "这次搜索的结果已经换了，再搜一次。", "error": True})
        self.assertEqual(self.fake.opened, [])

    def test_window_gets_reveal_not_args(self):
        hit = {"id": "a|1", "title": "报销.pdf",
               "actions": [{"name": "mail_open", "title": "打开", "args": {"id": "a|1", "path": "/Users/me/报销.pdf"}, "primary": True},
                           {"name": "mail_open", "title": "在访达中显示", "args": {"id": "a|1", "reveal": True}},
                           {"name": "mail_open", "title": "别的", "args": {"reveal": "yes"}}]}
        self.fake.find_override = {"text": "找到 1 个。", "hits": [hit], "card": []}
        (r,) = post(self.home, "/search", {"query": "报销"})[1]["results"]
        self.assertEqual(r["hits"][0]["actions"], [
            {"name": "mail_open", "title": "打开", "primary": True},
            {"name": "mail_open", "title": "在访达中显示", "reveal": True},
            {"name": "mail_open", "title": "别的"}])
        self.assertEqual(self.agent.search_hits[APP]["a|1"]["actions"][1]["args"], {"id": "a|1", "reveal": True},
                         "参数留在 agent，点的时候从这里取")

    def test_overlapping_searches_keep_the_newer_results(self):
        """先搜的工具慢、后搜的先答完：先搜的答完不能盖掉后搜的（编号问工具之前就领）。"""
        slow_started, let_slow_go = threading.Event(), threading.Event()
        ask = self.agent._search_one

        def search_one(src, query, limit):
            if query == "慢":
                slow_started.set()
                let_slow_go.wait(5)
            return ask(src, query, limit)
        self.agent._search_one = search_one
        old = {"id": "old", "title": "慢的结果", "thumb": "thumb/1",
               "actions": [{"name": "mail_open", "title": "打开", "args": {"plan_id": "old"}}]}
        new = {"id": "new", "title": "快的结果", "thumb": "thumb/2",
               "actions": [{"name": "mail_open", "title": "打开", "args": {"plan_id": "new"}}]}
        self.fake.find_override = {"text": "找到 1 封。", "hits": [old], "card": []}
        slow: dict = {}
        t = threading.Thread(target=lambda: slow.update(self.agent.search("慢")))
        t.start()
        self.assertTrue(slow_started.wait(5))
        self.fake.find_override = {"text": "找到 1 封。", "hits": [new], "card": []}
        fast = self.agent.search("快")
        # 放慢的那次去问工具：假工具这时照旧答「慢」的结果
        self.fake.find_override = {"text": "找到 1 封。", "hits": [old], "card": []}
        let_slow_go.set()
        t.join(5)
        self.assertEqual(fast["search"], slow["search"] + 1, "编号按发起的先后领")
        self.assertEqual([h["id"] for h in slow["results"][0]["hits"]], ["old"])
        self.assertEqual(self.agent.search_hits[APP].keys(), {"new"}, "先发起、后答完的不换留下的结果")
        out = post(self.home, "/hit", {"search": fast["search"], "app": APP, "hit": "new", "action": 0})[1]
        self.assertEqual(out["error"], False, out)
        self.assertEqual(self.fake.opened, ["new"])
        self.assertEqual(post(self.home, "/hit", {"search": slow["search"], "app": APP, "hit": "old", "action": 0})[1],
                         {"text": "这次搜索的结果已经换了，再搜一次。", "error": True})
        png = b"\x89PNG\r\n\x1a\n" + b"\x00\x00\x00\rIHDR" + (40).to_bytes(4, "big") + (30).to_bytes(4, "big") + b"\x08\x02"
        self.fake.thumbs.update({"thumb/1": png, "thumb/2": png})
        self.assertEqual(get_raw(self.home, f"/thumb?app={APP}&ref=thumb/2")[0], 200)
        self.assertEqual(get_raw(self.home, f"/thumb?app={APP}&ref=thumb/1")[0], 404)

    def test_hit_waits_for_a_search_to_finish(self):
        """新的一次搜索还没答完时，窗口还画着上一次的：上一次的按钮照旧能点。"""
        data = self._search_with_actions()
        started, go = threading.Event(), threading.Event()
        ask = self.agent._search_one

        def search_one(src, query, limit):
            started.set()
            go.wait(5)
            return ask(src, query, limit)
        self.agent._search_one = search_one
        t = threading.Thread(target=lambda: self.agent.search("别的"))
        t.start()
        self.assertTrue(started.wait(5))
        out = post(self.home, "/hit", {"search": data["search"], "app": APP, "hit": "a|1", "action": 0})[1]
        go.set()
        t.join(5)
        self.assertEqual(out["error"], False, out)
        self.assertEqual(self.fake.opened, ["one"])
        self.assertEqual(post(self.home, "/hit", {"search": True, "app": APP, "hit": "a|1", "action": 0})[1]["error"], True)

    def test_thumbnails_read_from_the_tool(self):
        png = b"\x89PNG\r\n\x1a\n" + b"\x00\x00\x00\rIHDR" + (400).to_bytes(4, "big") + (300).to_bytes(4, "big") + b"\x08\x02"
        self.fake.thumbs["thumb/1"] = png
        self.fake.thumbs["thumb/2"] = png
        self._search_with_actions()
        status, mime, body = get_raw(self.home, f"/thumb?app={APP}&ref=thumb%2F1")
        self.assertEqual((status, mime, body), (200, "image/png", png))
        # 这次搜索没给过的、别的应用的、不是图的、太大的、太宽的：404
        self.assertEqual(get_raw(self.home, f"/thumb?app={APP}&ref=thumb/2")[0], 404, "没在结果里给过")
        self.assertEqual(get_raw(self.home, "/thumb?app=x&ref=thumb/1")[0], 404)
        self.assertEqual(get_raw(self.home, f"/thumb?app={APP}")[0], 404)
        for bad in (b"GIF89a", b"\xff\xd8\xff" + b"\x00" * (256 * 1024), png[:16] + (4096).to_bytes(4, "big") + png[20:], None):
            self.fake.thumbs["thumb/1"] = bad
            self.assertEqual(get_raw(self.home, f"/thumb?app={APP}&ref=thumb/1")[0], 404)
        self.stop_tool()
        self.assertEqual(get_raw(self.home, f"/thumb?app={APP}&ref=thumb/1")[0], 404)

    def test_many_thumbnails_at_once_all_arrive(self):
        # 窗口一屏的格子同时要缩略图；luoke-search 同时只画两张，第三张直接答没有。核心排着队要，一张都不丢
        png = b"\x89PNG\r\n\x1a\n" + b"\x00\x00\x00\rIHDR" + (400).to_bytes(4, "big") + (300).to_bytes(4, "big") + b"\x08\x02"
        refs = [f"thumb/{i}" for i in range(1, 7)]
        self.fake.thumbs.update({r: png for r in refs})
        self.fake.thumb_slots = threading.Semaphore(2)
        self.fake.thumb_delay = 0.3
        self.fake.find_override = {"text": "找到 6 个。", "card": [],
                                   "hits": [{"id": str(i), "title": f"图{i}.jpg", "kind": "image", "thumb": r}
                                            for i, r in enumerate(refs, 1)]}
        post(self.home, "/search", {"query": "护照"})
        got = {}

        def ask(ref: str) -> None:
            got[ref] = get_raw(self.home, f"/thumb?app={APP}&ref={ref}")[0]
        ts = [threading.Thread(target=ask, args=(r,)) for r in refs]
        for t in ts:
            t.start()
        for t in ts:
            t.join(10)
        self.assertEqual(got, {r: 200 for r in refs})

    def _queued_thumbs(self, n: int, delay: float, meanwhile) -> List[int]:
        """同时要 n 张、工具每张画 delay 秒；核心先读的两张开始画了，调 meanwhile()，答回各张的状态码（排好序）。"""
        png = b"\x89PNG\r\n\x1a\n" + b"\x00\x00\x00\rIHDR" + (400).to_bytes(4, "big") + (300).to_bytes(4, "big") + b"\x08\x02"
        refs = [f"thumb/{i}" for i in range(1, n + 1)]
        self.fake.thumbs.update({r: png for r in refs})
        self.fake.thumb_delay = delay
        self.fake.find_override = {"text": f"找到 {n} 个。", "card": [],
                                   "hits": [{"id": str(i), "title": f"图{i}.jpg", "kind": "image", "thumb": r}
                                            for i, r in enumerate(refs, 1)]}
        post(self.home, "/search", {"query": "护照"})
        got = {}

        def ask(ref: str) -> None:
            got[ref] = get_raw(self.home, f"/thumb?app={APP}&ref={ref}")[0]
        ts = [threading.Thread(target=ask, args=(r,)) for r in refs]
        for t in ts:
            t.start()
        deadline = time.monotonic() + 5
        while len(self.fake.thumb_reads) < 2 and time.monotonic() < deadline:
            time.sleep(0.01)
        meanwhile()
        for t in ts:
            t.join(10)
        return sorted(got.values())

    def test_queued_thumbnail_after_new_search_is_not_read(self):
        # 排到时窗口已经重新搜了：这张答 404，不再向工具读
        def new_search():
            self.fake.find_override = {"text": "找到 0 个。", "card": [], "hits": []}
            post(self.home, "/search", {"query": "别的"})
        self.assertEqual(self._queued_thumbs(3, 0.5, new_search), [200, 200, 404])
        self.assertEqual(len(self.fake.thumb_reads), 2)

    def test_thumbnail_queued_too_long_gets_404(self):
        # 排队超过 THUMB_QUEUE_WAIT：答 404，也不再读
        with mock.patch.object(agent_mod, "THUMB_QUEUE_WAIT", 0.2):
            self.assertEqual(self._queued_thumbs(3, 1.0, lambda: None), [200, 200, 404])
        self.assertEqual(len(self.fake.thumb_reads), 2)

    def test_no_tool_can_search(self):
        self.src.service["search"] = None
        data = post(self.home, "/search", {"query": "账单"})[1]
        self.assertEqual(data, {"results": [], "failed": [], "text": "还没有能搜的应用。"})
        self.assertEqual(self.fake.finds, [])

    def test_refusals(self):
        for body in ({}, {"query": ""}, {"query": "  "}, {"query": 1}, {"query": "字" * 201},
                     {"query": "账单", "limit": 0}, {"query": "账单", "limit": 51}, {"query": "账单", "limit": True}):
            self.assertEqual(post(self.home, "/search", body)[0], 400, body)
        self.assertEqual(self.fake.finds, [])

    def test_manifest(self):
        self.assertEqual(apps.service({"ask": {"search": "mail_find"}})["search"], "mail_find")
        self.assertIsNone(apps.service({})["search"])
        self.assertIsNone(apps.service({"ask": "mail_find"})["search"])


class PermissionsTest(_Base):
    """§10：GET、POST /permissions，POST /host。"""

    def test_rows(self):
        status, data = get(self.home, "/permissions")
        self.assertEqual(status, 200)
        self.assertEqual(data["rows"], [
            {"app": APP, "id": "fda", "kind": "system", "owner": "luoke", "tcc": "SystemPolicyAllFiles", "title": "完全磁盘访问",
             "facts": ["读邮件 app 存在本机的邮件", "结果不出这台 Mac"], "without": "degrade", "state": None, "can": ["settings"]},
            {"app": APP, "id": "contacts", "kind": "system", "tcc": "AddressBook", "title": "读通讯录", "state": "ask",
             "can": ["request"]},
            {"app": APP, "id": "mailbox", "kind": "account", "title": "邮箱", "state": "granted", "can": ["open", "remove"]},
            {"app": APP, "id": "auto", "kind": "delegate", "title": "促销邮件不用点就归档", "state": "off", "can": ["on"]},
            {"app": APP, "id": "send", "kind": "each-time", "title": "以你的名义发信", "state": "ask"},
        ])
        self.assertNotIn("can", data["rows"][-1], "每次都问的只列出来")
        self.assertEqual(self.fake.fda, "denied", "螺壳名下的不看工具自己报的")

    def test_rows_read_the_tool_now(self):
        self.fake.contacts = "denied"     # 没等下一轮读 outbox
        row = self.rows()["contacts"]
        self.assertEqual((row["state"], row["can"]), ("denied", ["settings"]), "系统框已经问过、被拒了：只能去系统设置")
        self.assertEqual(self.events("apps"), [{"app": APP}])

    def test_delegate_on_off(self):
        r = self.op("auto", "on")
        self.assertEqual(r, {"text": "好，以后促销邮件不用点就归档，每次都告诉你。", "error": False})
        self.assertTrue(self.fake.auto)
        ua = self.fake.user_actions[-1]
        self.assertEqual((ua["surfaceId"], ua["componentId"]), ("permissions", "auto"), "带 ai.luoke/user-action")
        self.assertEqual(self.events("apps"), [{"app": APP}])
        self.assertEqual(self.rows()["auto"]["can"], ["off"])
        n = len(self.fake.user_actions)
        self.assertEqual(self.op("auto", "on"), {"text": "这一项现在不能这样改。", "error": True}, "开着了：只能关")
        self.assertEqual(len(self.fake.user_actions), n, "不在 can 里的不转给工具")
        self.assertFalse(self.op("auto", "off")["error"])
        self.assertFalse(self.fake.auto)

    def test_request_then_only_settings(self):
        self.assertFalse(self.op("contacts", "request")["error"])
        self.assertEqual(self.fake.contacts, "granted")
        self.assertEqual(self.fake.user_actions[-1]["componentId"], "contacts")
        row = self.rows()["contacts"]
        self.assertEqual((row["state"], row["can"]), ("granted", ["settings"]), "要收回：去系统设置")
        self.assertTrue(self.op("contacts", "request")["error"])
        r = self.op("contacts", "settings")
        self.assertFalse(r["error"])
        self.assertEqual(r["url"], "x-apple.systempreferences:com.apple.preference.security?Privacy_Contacts")

    def test_account_open_and_remove(self):
        self.assertFalse(self.op("mailbox", "open")["error"])
        self.assertEqual(self.fake.opened, ["ui:accounts"], "去工具自己的界面，带 page")
        self.assertEqual(self.fake.user_actions, [], "打开是只读的")
        r = self.op("mailbox", "remove")
        self.assertEqual(r, {"text": "移除了 me@example.com。", "error": False})
        self.assertEqual(self.fake.user_actions[-1]["surfaceId"], "permissions")
        self.assertEqual(self.rows()["mailbox"]["can"], ["open"], "移除了：只剩去设置")
        self.assertTrue(self.op("mailbox", "remove")["error"])

    def test_settings_opens_only_registered_panes(self):
        r = self.op("fda", "settings")
        self.assertEqual(r, {"text": "在系统设置里打开「完全磁盘访问」。", "error": False,
                             "url": "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles"},
                         "核心不自己开，地址交给窗口")
        perms = [dict(p, tcc="x-apple.systempreferences:evil") if p["id"] == "fda" else p for p in PERMISSIONS]
        perms += [{"id": "bt", "kind": "system", "tcc": "Bluetooth", "title": "蓝牙"}]
        self.src.set_manifest(SERVICE, perms)
        rows = self.rows()
        self.assertEqual((rows["fda"]["can"], rows["bt"]["can"]), ([], []), "没登记的 tcc 键：没有 settings")
        self.assertEqual(self.op("fda", "settings"), {"text": "这一项现在不能这样改。", "error": True})
        self.assertEqual(self.op("bt", "settings"), {"text": "这一项现在不能这样改。", "error": True})

    def test_refusals(self):
        self.assertEqual(self.op("send", "on"), {"text": "这一项现在不能这样改。", "error": True}, "每次都问的没有开关")
        self.assertEqual(self.op("auto", "remove"), {"text": "这一项现在不能这样改。", "error": True})
        self.assertEqual(self.op("auto", "on", app="nobody"), {"text": "没有这个应用。", "error": True})
        self.assertEqual(self.op("nope", "on"), {"text": "没有这一项权限。", "error": True})
        for body in ({"app": APP, "id": "auto", "op": "delete"}, {"app": APP, "id": "auto"}, {"app": APP, "id": 1, "op": "on"}):
            with self.subTest(body=body):
                self.assertEqual(post(self.home, "/permissions", body)[0], 400)
        self.assertFalse(self.fake.auto)
        self.assertEqual(self.fake.user_actions, [])

    def test_tool_not_running(self):
        self.stop_tool()
        self.agent.poll()
        rows = self.rows()
        self.assertEqual({k: (r["state"], r.get("can")) for k, r in rows.items()}, {
            "fda": (None, ["settings"]), "contacts": (None, ["settings"]), "mailbox": (None, []), "auto": (None, []),
            "send": (None, None)}, "工具没在运行：不知道状态，只能去系统设置")
        self.assertEqual(self.op("auto", "off"), {"text": "假邮件现在没在运行。", "error": True})
        self.assertEqual(self.op("mailbox", "open"), {"text": "假邮件现在没在运行。", "error": True})
        self.assertFalse(self.op("fda", "settings")["error"], "系统设置的地址由 agent 给，工具不用在运行")

    def test_host_reports_luoke_permissions(self):
        self.fake.ask_access("fda")
        self.fake.ask_access("contacts")
        self.agent.poll()
        self.assertIn(f"{APP}/access-fda", self.agent.order())
        self.assertEqual(self.apps_entry()["needs"], ["fda", "contacts"])
        self.events()
        self.assertEqual(post(self.home, "/host", {"permissions": {"fda": "granted"}}), (200, {}))
        self.assertNotIn(f"{APP}/access-fda", self.agent.order(), "螺壳已经有了：撤掉要权限的卡片")
        self.assertIn(f"{APP}/access-contacts", self.agent.order(), "工具自己名下的不管")
        got = self.events()
        self.assertIn(("a2ui", {"version": "v0.9", "deleteSurface": {"surfaceId": f"{APP}/access-fda"}}), got)
        self.assertIn(("apps", {"app": APP}), got)
        self.assertEqual(got[-1][0], "feed")
        self.assertEqual(self.rows()["fda"]["state"], "granted")
        self.assertEqual(self.apps_entry()["needs"], ["contacts"])
        self.agent.poll()
        self.assertNotIn(f"{APP}/access-fda", self.agent.order(), "工具还列着：照样不画")
        self.assertEqual(self.state.item(f"{APP}/needs-access/fda")["outcome"], "withdrawn")
        self.assertEqual(post(self.home, "/host", {"permissions": {"fda": "denied"}}), (200, {}))
        self.agent.poll()
        self.assertIn(f"{APP}/access-fda", self.agent.order(), "又没有了：卡片回来")
        self.assertEqual(self.rows()["fda"]["state"], "denied")
        post(self.home, "/host", {"permissions": {"fda": None}})
        self.assertIsNone(self.rows()["fda"]["state"], "null：不再报这一项")

    def ask_of(self, sid: str) -> Optional[dict]:
        return next(c for c in self.agent._feed()["cards"] if c["id"] == sid).get("host_ask")

    def custom_access(self, permission: str, *buttons: dict) -> str:
        """要权限的卡片，按钮自己定。"""
        item_id = self.fake.ask_access(permission)
        card = cards.Card(f"access-{permission}")
        card.text("要用到。")
        card.buttons(*buttons)
        self.fake.items[item_id]["_card"] = card.messages()
        self.agent.poll()
        return f"{APP}/access-{permission}"

    def test_host_ask_names_the_button_for_luoke_permissions(self):
        self.fake.ask_access("fda")
        self.fake.ask_access("contacts")
        self.agent.poll()
        sid = f"{APP}/access-fda"
        ask = self.ask_of(sid)
        self.assertEqual(ask["permission"], "fda")
        self.assertEqual(self.agent.surfaces[sid][1].button_event(ask["button"])[0], "mail_open_settings")
        self.assertIsNone(self.ask_of(f"{APP}/access-contacts"), "工具自己名下的：点了照旧转给工具")

    def test_page_button_that_needs_a_permission_runs_after_it(self):
        card = cards.Card("overview")
        card.buttons(cards.button("也用", "mail_auto", context={"needs": "fda", "on": True}))
        self.fake.page_override = card.messages()
        status, data = get(self.home, f"/apps/{APP}/pages/overview")
        self.assertEqual(status, 200)
        self.assertEqual(data["host_ask"]["permission"], "fda")
        self.assertIs(data["host_ask"]["then"], True)

    def test_page_host_ask_names_the_button_the_tool_marked(self):
        def page(permission: str) -> list:
            card = cards.Card("overview")
            card.text("要用到。")
            card.buttons(cards.button("别的", "mail_auto"),
                         cards.button("允许", "mail_open_settings", context={"permission": permission}))
            return card.messages()
        self.fake.page_override = page("fda")
        status, data = get(self.home, f"/apps/{APP}/pages/overview")
        self.assertEqual(status, 200)
        sid = f"{APP}/page/overview"
        self.assertEqual(data["host_ask"]["permission"], "fda")
        self.assertEqual(self.agent.pages[sid][2].button_event(data["host_ask"]["button"])[0], "mail_open_settings")
        self.assertNotIn("then", data["host_ask"], "这个按钮就是来要权限的")
        self.fake.page_override = page("contacts")
        self.assertNotIn("host_ask", get(self.home, f"/apps/{APP}/pages/overview")[1], "工具自己名下的：照旧转给工具")
        self.fake.page_override = None
        self.assertNotIn("host_ask", get(self.home, f"/apps/{APP}/pages/overview")[1], "没写明的不算")

    def test_host_ask_picks_the_primary_or_the_only_tool_button(self):
        sid = self.custom_access("fda", cards.button("以后再说", "mail_open"),
                                 cards.button("去允许", "mail_open_settings", primary=True))
        self.assertEqual(self.agent.surfaces[sid][1].button_event(self.ask_of(sid)["button"])[0], "mail_open_settings")
        self.custom_access("fda", cards.button("去允许", "mail_open_settings"), cards.button("不用了", "agent.dismiss"))
        self.assertEqual(self.agent.surfaces[sid][1].button_event(self.ask_of(sid)["button"])[0], "mail_open_settings",
                         "agent 的按钮不算")
        self.custom_access("fda", cards.button("这个", "mail_open"), cards.button("那个", "mail_open_settings"))
        self.assertIsNone(self.ask_of(sid), "认不出来：不给，点了转给工具")

    def test_host_card_stays_until_the_user_confirmed(self):
        """螺壳有这项权限还不够：这个应用没确认过，卡片留着，用户点了才问；确认了才撤。"""
        self.fake.ask_access("fda")
        self.agent.poll()
        self.assertEqual(post(self.home, "/host", {"permissions": {"fda": "granted"}, "confirmed": {}}), (200, {}))
        self.assertIn(f"{APP}/access-fda", self.agent.order(), "没确认：卡片留着")
        self.assertEqual(post(self.home, "/host", {"permissions": {}, "confirmed": {APP: {"fda": "2026-11-06T07:00:00Z"}}}), (200, {}))
        self.assertNotIn(f"{APP}/access-fda", self.agent.order(), "确认了：撤掉")
        self.assertEqual(post(self.home, "/host", {"permissions": {}, "confirmed": {}}), (200, {}))
        self.agent.poll()
        self.assertIn(f"{APP}/access-fda", self.agent.order(), "用户关掉了：再用到时卡片回来")
        code, _ = post(self.home, "/host", {"permissions": {}, "confirmed": {APP: ["fda"]}})
        self.assertEqual(code, 400)

    def test_host_refusals(self):
        for body in ({}, {"permissions": []}, {"permissions": {"fda": "yes"}}, {"permissions": {"../x": "granted"}},
                     {"permissions": {"fda": True}}):
            with self.subTest(body=body):
                self.assertEqual(post(self.home, "/host", body)[0], 400)
        self.assertEqual(self.agent.host, {}, "不对的什么都不改")

    def test_owner_is_optional(self):
        perms = [{k: v for k, v in p.items() if k != "owner"} for p in PERMISSIONS]
        self.src.set_manifest(SERVICE, perms)
        self.agent.set_host({"fda": "granted"})
        row = self.rows()["fda"]
        self.assertNotIn("owner", row)
        self.assertEqual(row["state"], "denied", "不在螺壳名下：照工具自己报的")


class ManifestTest(unittest.TestCase):
    """清单的 service、permissions 从主控来（GET /accessories）；认不得的丢掉。"""

    def test_discover_and_runner_carry_the_manifest(self):
        d = tempfile.mkdtemp(prefix="la")
        self.addCleanup(shutil.rmtree, d, True)
        sock = os.path.join(d, "hub.sock")
        hub = FakeHub(sock, Handler)
        threading.Thread(target=hub.serve_forever, daemon=True).start()
        self.addCleanup(hub.server_close)
        self.addCleanup(hub.shutdown)
        caps = {"protocol": 1, "socket": f"~/.{APP}/run/agent.sock", "service": SERVICE, "permissions": PERMISSIONS,
                "reports": [{"kind": "suspicious", "title": "可疑邮件", "urgency": "urgent"}]}
        hub.answers = {"/accessories": {"accessories": [{"accessory": APP, "capabilities": caps}]}}
        found = discover(sock, home=d)
        self.assertEqual((found[0]["service"], found[0]["permissions"]), (SERVICE, PERMISSIONS))
        state = State(os.path.join(d, "agent"))
        self.addCleanup(state.close)
        agent = Agent(state, [])
        q = agent.subscribe()
        Runner(agent, hub=sock, home=d).refresh_tools()
        self.assertEqual(agent.apps()["apps"][0]["pages"], SERVICE["pages"])
        self.assertIn(("apps", {"app": APP}), [q.get_nowait() for _ in range(q.qsize())])
        self.assertTrue(agent.sources[APP].capped, "主控列出来的：急不急以清单为上限")
        caps["service"] = {"summary": True}
        caps["reports"] = [{"kind": "suspicious", "title": "可疑邮件", "urgency": "normal"}]
        Runner(agent, hub=sock, home=d).refresh_tools()
        self.assertEqual(agent.apps()["apps"][0]["pages"], [], "升级了：页列表跟着换")
        self.assertEqual(agent.sources[APP].reports["suspicious"]["urgency"], "normal", "每类的急不急也跟着换")
        self.assertIn(("apps", {"app": APP}), [q.get_nowait() for _ in range(q.qsize())])
        explicit = ToolSource(APP, os.path.join(d, "dev", "agent.sock"))
        self.assertFalse(explicit.capped, "开发时显式给的没有清单")
        agent.add_source(explicit)
        caps["service"] = SERVICE
        Runner(agent, hub=sock, explicit_tools={APP}, home=d).refresh_tools()
        self.assertIs(agent.sources[APP], explicit, "显式给的 socket 不换")
        self.assertEqual(explicit.service["pages"], SERVICE["pages"], "清单照主控的")
        self.assertTrue(explicit.capped, "主控也列了它：照清单设上限")
        hub.answers = {"/accessories": {"accessories": [{"accessory": APP, "capabilities": caps},
                                                        {"accessory": APP, "capabilities": dict(caps, socket="~/.x/a.sock")}]}}
        with contextlib.redirect_stderr(io.StringIO()):
            Runner(agent, hub=sock, home=d).refresh_tools()
        self.assertNotIn(APP, agent.sources, "主控列了两个同样的编号：都不接，原来接着的也撤掉")

    def test_kind_labels_reach_a_window_that_asked_before_the_hub_answered(self):
        """「设置 · 提醒」的每类事：窗口一连上就取设置，那时主控还没答（在启动），出过事的几类只能写「这一类事」。
        主控答了、清单里每类的名字到了，要再推一次 settings，每一行写清单里的名字（扫描的五类）。"""
        d = tempfile.mkdtemp(prefix="la")
        self.addCleanup(shutil.rmtree, d, True)
        sock = os.path.join(d, "hub.sock")
        hub = FakeHub(sock, Handler)
        threading.Thread(target=hub.serve_forever, daemon=True).start()
        self.addCleanup(hub.server_close)
        self.addCleanup(hub.shutdown)
        state = State(os.path.join(d, "agent"))
        self.addCleanup(state.close)
        for kind, urgency in (("findings", "low"), ("needs-access", "low")):   # 上次开着时扫描报过的两类
            state.remember(f"luoke-scan/{kind}/1", "luoke-scan", kind, urgency, 0.0)
        agent = Agent(state, [])
        q = agent.subscribe()
        before = {k["id"]: k["label"] for k in agent.settings()["kinds"] if k["app"] == "luoke-scan"}
        self.assertEqual(before, {"luoke-scan:findings": "这一类事", "luoke-scan:needs-access": "这一类事"},
                         "主控还没答：只知道出过事的两类，没有名字")
        reports = [{"kind": "security", "title": "安全问题", "urgency": "urgent"},
                   {"kind": "space", "title": "空间被吃掉", "urgency": "normal"},
                   {"kind": "findings", "title": "扫描结果", "urgency": "low"},
                   {"kind": "needs-access", "title": "需要你允许", "urgency": "low"},
                   {"kind": "auto-done", "title": "自动清掉的", "urgency": "normal"}]
        caps = {"protocol": 1, "transport": "stdio", "reports": reports}
        hub.answers = {"/accessories": {"accessories": [{"accessory": "luoke-scan", "capabilities": caps}]}}
        Runner(agent, hub=sock, home=d, host=object()).refresh_tools()
        pushed = [data for event, data in [q.get_nowait() for _ in range(q.qsize())] if event == "settings"]
        self.assertTrue(pushed, "名字到了：推一次 settings，窗口不用再取")
        after = {k["id"]: k["label"] for k in pushed[-1]["kinds"] if k["app"] == "luoke-scan"}
        self.assertEqual(after, {f"luoke-scan:{r['kind']}": r["title"] for r in reports}, "每一行是清单里的名字")
        self.assertNotIn("这一类事", [k["label"] for k in pushed[-1]["kinds"]])
        Runner(agent, hub=sock, home=d, host=object()).refresh_tools()
        self.assertFalse([e for e, _ in [q.get_nowait() for _ in range(q.qsize())] if e == "settings"],
                         "名字没变：不再推")

    def test_urgency_is_capped_by_the_manifest(self):
        """H8：一件事急不急不超过清单 reports 里那一类的；清单里没有的那一类最多 normal。没有清单（开发时显式给的）照工具说的。"""
        reports = [{"kind": "security", "title": "安全问题", "urgency": "urgent"},
                   {"kind": "findings", "title": "扫描结果", "urgency": "low"}]
        src = ToolSource(APP, os.path.join(tempfile.gettempdir(), "none", "agent.sock"), reports=reports)

        def urgency(kind, said=None):
            r = {"id": "x", "title": "t", "kind": kind, "card": None}
            if said is not None:
                r["urgency"] = said
            with contextlib.redirect_stderr(io.StringIO()):
                return src._item(r).urgency

        self.assertEqual(urgency("security"), "urgent")
        self.assertEqual(urgency("security", "low"), "low", "比上限低可以")
        self.assertEqual(urgency("findings", "urgent"), "low", "不比清单里这一类急")
        self.assertEqual(urgency("findings", "normal"), "low")
        self.assertEqual(urgency("other", "urgent"), "normal", "清单里没有的一类：最多 normal")
        self.assertEqual(urgency("other"), "normal")
        self.assertEqual(urgency("other", "bogus"), "normal")
        src.set_reports([])
        self.assertEqual(urgency("security", "urgent"), "normal", "清单换了：照新的")
        dev = ToolSource(APP, os.path.join(tempfile.gettempdir(), "none", "agent.sock"))
        r = {"id": "x", "title": "t", "kind": "security", "urgency": "urgent", "card": None}
        with contextlib.redirect_stderr(io.StringIO()):
            self.assertEqual(dev._item(r).urgency, "urgent", "没有清单：照工具说的（只有 serve --dev --tool 这样起）")

    def test_normalizing(self):
        svc = apps.service({"summary": "yes", "pages": [{"id": "a b", "title": "x"}, {"id": "ok", "title": "好"},
                                                        {"id": "ok", "title": "重复"}, "junk"],
                            "ui": {"pages": [{"id": "p", "title": "页"}]}})
        self.assertEqual(svc, {"summary": False, "pages": [{"id": "ok", "title": "好"}], "ui": None, "search": None},
                         "没有 open 就没有 ui")
        hidden = apps.service({"pages": [{"id": "a", "title": "甲", "hidden": True}, {"id": "b", "title": "乙", "hidden": False},
                                         {"id": "c", "title": "丙", "hidden": "yes"}, {"id": "d", "title": "丁", "hidden": 1}]})
        self.assertEqual(hidden["pages"], [{"id": "a", "title": "甲", "hidden": True}, {"id": "b", "title": "乙"}],
                         "hidden 只认布尔：false 不写出来，写成别的这一页不认")
        perms = apps.permissions([{"id": "x", "kind": "magic", "title": "t"}, {"id": "y", "kind": "delegate"},
                                  {"id": "z", "kind": "delegate", "title": "开关", "on": "agent.dismiss"}, None])
        self.assertEqual(perms, [{"id": "z", "kind": "delegate", "title": "开关"}], "agent. 开头的不是工具的动作")
        self.assertEqual(apps.summary({"count": 3.0, "text": "三"}), {"count": 3, "text": "三"})
        for bad in ({"count": True, "text": "x"}, {"count": -1, "text": "x"}, {"count": 1.5, "text": "x"}, {"count": 1}, []):
            self.assertIsNone(apps.summary(bad), bad)
        self.assertEqual(apps.states({"a": "granted", "b": "maybe", "c": 1}), {"a": "granted"})
        self.assertIsNone(apps.states(["granted"]))


DOWN = "假邮件现在没在运行，它的事恢复后会自动列回来，不用你做什么。"


class OutboxErrorTest(_Base):
    """工具读 outbox 答了错误（例如没给 outbox 的工具答 -32002）不算没在运行（工具协议 §2）：
    这一轮没读到，上一轮的事不撤、不新加，「今天」上不说它没在运行。"""

    def no_outbox(self):
        """工具那头的 outbox 拿掉：读它答 -32002「没有这个资源」。"""
        self.tool_server._resources.pop(outbox_uri(APP))

    def test_an_error_answer_is_not_down(self):
        before = self.agent.order()
        self.assertTrue(before, "开头读到过事")
        self.no_outbox()
        with contextlib.redirect_stderr(io.StringIO()) as err:
            self.agent.poll()
        self.assertTrue(self.src.running)
        self.assertNotIn(APP, self.agent.notices, "不出「没在运行」那句")
        self.assertEqual(self.agent.order(), before, "这一轮没读到：上一轮的事不撤")
        self.assertIn(f"{APP} 的outbox读不了（-32002）", err.getvalue(), "日志照旧记一行：资源和错误码")
        entry = self.apps_entry()
        self.assertTrue(entry["running"])
        self.assertIsNotNone(entry["summary"], "概览照它自己读到的")
        n = len(self.fake.items)
        self.fake._add_suspicious(self.fake._mail("x@example.com", "又一封可疑邮件"))
        self.assertEqual(len(self.fake.items), n + 1, "工具那边多了一件")
        with contextlib.redirect_stderr(io.StringIO()):
            self.agent.poll()
        self.assertEqual(self.agent.order(), before, "也不新加")

    def test_down_then_an_error_answer_drops_the_down_notice(self):
        self.stop_tool()
        self.agent.poll()
        self.assertEqual(self.agent.notices.get(APP), DOWN, "真没在运行：照旧说")
        self.assertFalse(self.src.running)
        self.events()
        self.tool_server = self.fake.server().start(self.tool_sock)
        self.no_outbox()
        with contextlib.redirect_stderr(io.StringIO()):
            self.agent.poll()
        self.assertTrue(self.src.running)
        self.assertNotIn(APP, self.agent.notices)
        self.assertNotIn(DOWN, self.events("feed")[-1]["notices"], "回来了，只是读不到 outbox：那句收起来")


class BadTokenTest(unittest.TestCase):
    """口令（工具协议 §2）：工具对什么都答 -32001。再要一次还不对、或者没处要口令，照旧当它没在运行。"""

    def setUp(self):
        self.dir = tempfile.mkdtemp(prefix="la")
        self.state = State(os.path.join(self.dir, "agent"))

    def tearDown(self):
        self.state.close()
        shutil.rmtree(self.dir, ignore_errors=True)

    def opener(self) -> socket.socket:
        mine, theirs = socket.socketpair()

        def answer():
            with theirs, theirs.makefile("rb") as f:
                req = json.loads(f.readline())
                reply = {"jsonrpc": "2.0", "id": req["id"], "error": {"code": BAD_TOKEN, "message": "口令不对"}}
                theirs.sendall(json.dumps(reply).encode() + b"\n")
        threading.Thread(target=answer, daemon=True).start()
        return mine

    def test_a_token_still_wrong_is_down(self):
        for label, token in (("再要一次还不对", lambda fresh: "older" if fresh else "old"), ("没处要口令", None)):
            with self.subTest(label):
                src = ToolSource(APP, f"stdio:{APP}", name="假邮件", service=SERVICE, permissions=PERMISSIONS,
                                 opener=self.opener, token=token)
                agent = Agent(self.state, [src], url_opener=lambda u: None)
                with contextlib.redirect_stderr(io.StringIO()):
                    agent.poll()
                self.assertFalse(src.running)
                self.assertEqual(agent.notices.get(APP), DOWN)


if __name__ == "__main__":
    unittest.main()
