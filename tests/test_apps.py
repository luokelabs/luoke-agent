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
import tempfile
import threading
import unittest
from typing import Any, List, Optional, Tuple

from luoke_agent import __main__ as cli
from luoke_agent import a2ui, apps, cards
from luoke_agent.agent import Agent
from luoke_agent.fake_tool import PERMISSIONS, SERVICE, FakeMail
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
        a2ui.build(data["messages"])
        return [c.get("text") for m in data["messages"] for c in (m.get("updateComponents") or {}).get("components") or []
                if c.get("component") == "Text"]

    def test_page_that_cannot_be_drawn_is_plain_text(self):
        good = self.fake.page("overview")
        bad_kind = json.loads(json.dumps(good))
        bad_kind[1]["updateComponents"]["components"][0]["component"] = "WebView"
        too_many = [good[0], {"version": "v0.9", "updateComponents": {"surfaceId": "overview", "components":
                    [{"id": "root", "component": "Column", "children": [f"t{i}" for i in range(201)]}]
                    + [{"id": f"t{i}", "component": "Text", "text": "x"} for i in range(201)]}}]
        too_long = [good[0], {"version": "v0.9", "updateComponents": {"surfaceId": "overview", "components":
                    [{"id": "root", "component": "Text", "text": "长" * 2001}]}}]
        huge = [good[0], {"version": "v0.9", "updateDataModel": {"surfaceId": "overview", "path": "/",
                                                                 "value": {"x": "大" * (1 << 20)}}}]
        for name, override in (("不在目录里的组件", bad_kind), ("超过 200 个组件", too_many), ("超过 2000 字", too_long),
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
        self.assertEqual(post(self.home, "/search", {"query": "账单"})[1], {"results": [], "failed": []})

    def test_hits_without_a_card_are_not_drawn(self):
        self.fake.find_override = {"text": "找到 1 封。", "hits": [{"id": "x", "title": "x"}], "card": []}
        self.assertEqual(post(self.home, "/search", {"query": "账单"})[1], {"results": [], "failed": []})

    def test_bad_card_counts_as_failed(self):
        self.fake.find_override = {"text": "找到 1 封。", "hits": [{"id": "x", "title": "x"}], "card": [{"nope": 1}]}
        with contextlib.redirect_stderr(io.StringIO()) as err:
            self.assertEqual(post(self.home, "/search", {"query": "账单"})[1], {"results": [], "failed": ["假邮件"]})
        self.assertIn("搜索结果画不了", err.getvalue())
        self.assertNotIn("账单", err.getvalue(), "日志不记搜了什么")

    def test_tool_stopped(self):
        self.stop_tool()
        self.assertEqual(post(self.home, "/search", {"query": "账单"})[1], {"results": [], "failed": ["假邮件"]})

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
        perms = apps.permissions([{"id": "x", "kind": "magic", "title": "t"}, {"id": "y", "kind": "delegate"},
                                  {"id": "z", "kind": "delegate", "title": "开关", "on": "agent.dismiss"}, None])
        self.assertEqual(perms, [{"id": "z", "kind": "delegate", "title": "开关"}], "agent. 开头的不是工具的动作")
        self.assertEqual(apps.summary({"count": 3.0, "text": "三"}), {"count": 3, "text": "三"})
        for bad in ({"count": True, "text": "x"}, {"count": -1, "text": "x"}, {"count": 1.5, "text": "x"}, {"count": 1}, []):
            self.assertIsNone(apps.summary(bad), bad)
        self.assertEqual(apps.states({"a": "granted", "b": "maybe", "c": 1}), {"a": "granted"})
        self.assertIsNone(apps.states(["granted"]))


if __name__ == "__main__":
    unittest.main()
