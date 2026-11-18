"""应用页由核心照原始数据拼（顶层 ADR 0028，luoke_agent/apppages）"""
from __future__ import annotations

import json
import os
import tempfile
import unittest

from luoke_agent import a2ui, apppages
from luoke_agent.apppages import mail, mem, scan, search

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))


def _data(tool: str, name: str) -> dict:
    with open(os.path.join(ROOT, "fixtures", "apppages", tool, name), encoding="utf-8") as f:
        return json.load(f)["data"]


class Src:
    def __init__(self, source: str, data):
        self.source = source
        self.data = data


def _components(msgs):
    return {c["id"]: c for m in msgs for c in (m.get("updateComponents") or {}).get("components", [])}


class BuilderTest(unittest.TestCase):
    def test_only_when_the_app_lists_the_data(self):
        tool_pages = [{"id": "today", "title": "今日处理"}, {"id": "subs", "title": "订阅体检"}]
        self.assertIsNone(apppages.builder(Src("luoke-mail", [])), "旧版本没列原始数据：照旧读它自己的页")
        self.assertEqual(apppages.pages(Src("luoke-mail", []), tool_pages), tool_pages)
        src = Src("luoke-mail", list(mail.NEEDS))
        self.assertIs(apppages.builder(src), mail)
        pages = apppages.pages(src, tool_pages)
        self.assertEqual([p["id"] for p in pages if not p.get("hidden")], ["inbox", "digest", "clean"], "「今日」不再是标签：整个应用已经有「今天」")
        self.assertIn({"id": "subs", "title": "订阅体检", "hidden": True}, pages, "应用自己还有的页留着，卡片上的链接去得了")
        self.assertIsNone(apppages.builder(Src("luoke-ime", ["words"])), "还没搬的应用")

    def test_mail_today_follows_the_mockup(self):
        data = _data("luoke-mail", "pages.json")
        msgs = mail.build("today", {}, lambda u: data[u])
        surface = a2ui.build(msgs, page=True)
        comps = _components(msgs)
        root = comps["root"]["children"]
        texts = [comps[i].get("text") for i in root if comps[i]["component"] == "Text"]
        self.assertEqual(texts[:2], ["今日已处理", "待确认"], "替你做了的在最上面，然后才是要你定的")
        header = [i for i in root if comps[i].get("placement") == "header"]
        self.assertEqual(len(header), 1, "两个邮箱：右上角切换")
        self.assertEqual([o["label"] for o in comps[header[0]]["options"]], ["全部邮箱", "工作", "个人"])
        self.assertEqual(comps[header[0]]["options"][1]["tooltip"], "me@company.example", "停在上面写完整地址")
        all_text = json.dumps(msgs, ensure_ascii=False)
        self.assertIn("已归档 9 封通知", all_text)
        self.assertIn("已为 2 封账单加星标", all_text)
        self.assertIn("收件箱有 4 封待回复", all_text)
        undo = [c for c in comps.values() if c.get("action", {}).get("event", {}).get("name") == "mail_undo_step"]
        self.assertEqual(len(undo), 2)
        picker = next(c for c in comps.values() if c["component"] == "ChoicePicker" and c.get("placement") is None)
        self.assertEqual(surface.data["choices"]["m4021"], ["flag"], "建议的那个已选中")
        self.assertNotIn("submit", picker, "选了不马上办（负责人 11-15）")
        do = next(c for c in comps.values() if c.get("action", {}).get("event", {}).get("name") == "mail_act")
        self.assertEqual(do["action"]["event"]["context"]["op"], {"path": "/choices/m4021/0"}, "点「处理」按选的做")

    def test_every_mail_page_builds_and_validates(self):
        spec = json.load(open(os.path.join(ROOT, "fixtures", "apppages", "luoke-mail", "pages.json"), encoding="utf-8"))
        data = spec["data"]
        for page in sorted(mail.BUILT):
            with self.subTest(page=page):
                a2ui.build(mail.build(page, dict(spec.get("args", {}).get(page, {})), lambda u: data[u]), page=True)
        for tab in ("rules", "remind"):
            a2ui.build(mail.build("settings", {"tab": tab}, lambda u: data[u]), page=True)

    def test_inbox_rows_open_the_mail_and_reply_first(self):
        data = _data("luoke-mail", "pages.json")
        comps = _components(mail.build("inbox", {}, lambda u: data[u]))
        rows = [c for c in comps.values() if c["component"] == "Row" and c.get("open")]
        self.assertEqual(len(rows), 3)
        target = comps[rows[0]["open"]]["action"]["event"]
        self.assertEqual((target["name"], target["context"]["page"]), ("agent.open_page", "mail"))
        names = [comps[b]["action"]["event"]["name"] for b in comps[rows[0]["children"][1]]["children"] if b != rows[0]["open"]]
        self.assertEqual(names, ["mail_draft", "mail_act"], "主按钮「回复」、次按钮「归档」")

    def test_page_switches_only_when_its_data_is_given(self):
        src = Src("luoke-mail", ["accounts", "today"])
        self.assertIs(apppages.builds(src, "today"), mail)
        self.assertIsNone(apppages.builds(src, "inbox"), "收件箱的原始数据还没给：照旧读邮件助手自己的页")
        src.data.append("inbox")
        self.assertIs(apppages.builds(src, "inbox"), mail)

    def test_every_submit_and_open_target_can_be_tapped(self):
        """选了就办、回车就搜、点一行就开指的按钮，核心都认得出是哪个按钮（不在页里就点不了）"""
        for tool, mod, f in (("luoke-mail", mail, "pages.json"), ("luoke-mem", mem, "built.json"), ("luoke-scan", scan, "built.json"),
                              ("luoke-search", search, "built.json")):
            spec = json.load(open(os.path.join(ROOT, "fixtures", "apppages", tool, f), encoding="utf-8"))
            for page in sorted(mod.BUILT):
                with self.subTest(tool=tool, page=page):
                    s = a2ui.build(mod.build(page, dict(spec.get("args", {}).get(page, {})), lambda u: spec["data"][u]), page=True)
                    for c in s.components.values():
                        for key in ("submit", "open"):
                            if key in c:
                                name, _ctx = s.button_event(c[key])
                                self.assertTrue(name)

    def test_one_mailbox_has_no_switch_and_empty_day_says_so(self):
        reads = {"data/accounts": {"accounts": [{"id": "me@example.com", "address": "me@example.com", "name": None}]},
                 "data/today?account=all": {"handled": [], "picked": 0, "decide": [], "replies": 0}}
        msgs = mail.build("today", {}, lambda u: reads[u])
        a2ui.build(msgs, page=True)
        comps = _components(msgs)
        self.assertFalse(any(c.get("placement") == "header" for c in comps.values()))
        self.assertIn("今日没有待确认的邮件", json.dumps(msgs, ensure_ascii=False))

    def test_mail_accounts_add_remove_and_clear(self):
        """账号页：添加邮箱、重新填授权码、移除、全部清除（邮件助手 #106）；移除和清除先问、写明哪个邮箱，授权码是密码框"""
        data = _data("luoke-mail", "pages.json")
        read = lambda u: data[u]
        acct = data["data/accounts"]["accounts"][0]

        def events(msgs):
            comps = _components(msgs)
            return comps, {c["action"]["event"]["name"]: c for c in comps.values() if c["component"] == "Button"}

        msgs = mail.build("settings", {"tab": "accounts"}, read)
        a2ui.build(msgs, page=True)
        comps, ev = events(msgs)
        drop = [c for c in comps.values() if c.get("action", {}).get("event", {}).get("name") == "mail_remove"]
        self.assertEqual(len(drop), len(data["data/accounts"]["accounts"]), "每个邮箱一个移除")
        self.assertIn(acct["address"], drop[0]["confirm"]["title"], "确认框写明是哪个邮箱")
        self.assertEqual(ev["mail_forget"]["action"]["event"]["context"], {"memory": {"path": "/fields/forget_memory"}})
        self.assertIn("confirm", ev["mail_forget"])
        self.assertNotIn("mail_connect", ev, "没点添加：不放表单")
        self.assertFalse(any(c.get("variant") == "obscured" for c in comps.values()))

        a2ui.build(mail.build("settings", {"tab": "accounts", "add": "new"}, read), page=True)   # 刚点开：先选上第一个类型
        msgs = mail.build("settings", {"tab": "accounts", "add": "custom"}, read)
        s = a2ui.build(msgs, page=True)
        comps, ev = events(msgs)
        ctx = ev["mail_connect"]["action"]["event"]["context"]
        self.assertEqual(ctx["secret"], {"path": "/fields/secret"})
        self.assertEqual(s.secure_paths(), ["/fields/secret"], "授权码是密码框，初值是空的")
        self.assertEqual(s.data["fields"]["secret"], "")
        self.assertIn("host", ctx, "其他邮箱：要填服务器")
        self.assertNotIn("host", events(mail.build("settings", {"tab": "accounts", "add": "qq"}, read))[1]["mail_connect"]
                         ["action"]["event"]["context"], "QQ 邮箱：服务器照类型的")

        # 改一个邮箱：照邮件助手自己的「修改邮箱」，类型、地址都能改，地址先填好原来的
        msgs = mail.build("settings", {"tab": "accounts", "edit": acct["id"]}, read)
        s = a2ui.build(msgs, page=True)
        comps, ev = events(msgs)
        ctx = ev["mail_connect"]["action"]["event"]["context"]
        self.assertEqual(ctx["key"], acct["id"], "改的是这个邮箱")
        self.assertEqual(ctx["address"], {"path": "/fields/address"})
        self.assertEqual(s.data["fields"]["address"], acct.get("address") or acct["id"], "地址先填好原来的")
        self.assertEqual(s.data["choices"]["provider"], [acct["provider"]], "类型是原来的")
        self.assertIn("原地址在这台 Mac 上的数据将被删除", json.dumps(msgs, ensure_ascii=False))
        swap = next(c for c in comps.values() if c["component"] == "ChoicePicker" and c.get("label") == "邮箱类型")["submit"]
        self.assertEqual(s.button_event(swap)[1]["args"], {"tab": "accounts", "edit": acct["id"], "kind": {"path": "/choices/provider/0"}},
                         "换类型：还在改这个邮箱")
        msgs = mail.build("settings", {"tab": "accounts", "edit": acct["id"], "kind": "custom"}, read)
        s = a2ui.build(msgs, page=True)
        self.assertEqual(s.data["choices"]["provider"], ["custom"])
        self.assertIn("host", events(msgs)[1]["mail_connect"]["action"]["event"]["context"])

    def test_mail_add_form_follows_the_providers_mail_gives(self):
        """添加邮箱照邮件助手给的邮箱类型（data/providers）：步骤一行一行、链接走 agent.open_url，
        account 的链接带上页上填的地址（authuser）；没给邮箱类型的旧版本不放添加和重新填授权码"""
        data = _data("luoke-mail", "pages.json")
        msgs = mail.build("settings", {"tab": "accounts", "add": "gmail"}, lambda u: data[u])
        s = a2ui.build(msgs, page=True)
        comps = _components(msgs)
        picker = next(c for c in comps.values() if c["component"] == "ChoicePicker" and c.get("label") == "邮箱类型")
        self.assertEqual([o["value"] for o in picker["options"]], ["gmail", "qq", "163", "126", "custom"])
        texts = [c.get("text") for c in comps.values() if c["component"] == "Text"]
        self.assertTrue(any(t and t.startswith("1. 打开下方「两步验证」") for t in texts), "怎么拿授权码，一步一行")
        links = [c["action"]["event"]["context"] for c in comps.values() if c.get("action", {}).get("event", {}).get("name") == "agent.open_url"]
        self.assertEqual(len(links), 2)
        self.assertEqual(links[0]["authuser"], {"path": "/fields/address"}, "带上页上填的地址")
        secret = next(c for c in comps.values() if c.get("variant") == "obscured")
        self.assertEqual(secret["label"], "应用专用密码")
        self.assertEqual(s.secure_paths(), ["/fields/secret"])

        old = {k: v for k, v in data.items() if k != "data/providers"}
        comps = _components(mail.build("settings", {"tab": "accounts", "add": "gmail"}, lambda u: old[u]))
        names = {c["action"]["event"]["name"] for c in comps.values() if c["component"] == "Button"}
        self.assertNotIn("mail_connect", names, "没给邮箱类型：不放添加")
        self.assertIn("mail_remove", names, "移除照样有")

    def test_open_url_adds_authuser_only_on_built_pages(self):
        """核心拼的页上的链接带 authuser（页上填的地址）：像地址才加，编码过；别处的 open_url 不认它"""
        from luoke_agent.agent import Agent
        opened = []
        ag = Agent.__new__(Agent)
        ag.url_opener = opened.append
        ag._open_url({"url": "https://myaccount.google.com/apppasswords", "authuser": "me+x@gmail.com"}, page=True)
        ag._open_url({"url": "https://a.example/x?y=1", "authuser": "a&evil=1@b.cn"}, page=True)
        ag._open_url({"url": "https://a.example/x", "authuser": "not an address"}, page=True)
        ag._open_url({"url": "https://a.example/x", "authuser": "me@gmail.com"})
        self.assertEqual(opened, ["https://myaccount.google.com/apppasswords?authuser=me%2Bx@gmail.com",
                                  "https://a.example/x?y=1&authuser=a%26evil%3D1@b.cn",
                                  "https://a.example/x", "https://a.example/x"])

    def test_mail_connect_and_forget_shapes(self):
        """交给邮件助手前：类型取第一个，空的服务器、端口、授权码不交，端口交数；memory 只认勾上的布尔"""
        self.assertEqual(mail.action("mail_connect", {"provider": ["custom"], "address": " a@b.cn ", "host": "imap.b.cn ",
                                                      "port": "993", "secret": "x y"}),
                         ("mail_connect", {"provider": "custom", "address": "a@b.cn", "host": "imap.b.cn", "port": 993,
                                           "secret": "x y"}))
        self.assertEqual(mail.action("mail_connect", {"provider": "qq", "address": "a@qq.com", "secret": "", "key": "a@qq.com"}),
                         ("mail_connect", {"provider": "qq", "address": "a@qq.com", "key": "a@qq.com"}), "不填授权码：用原来的")
        self.assertEqual(mail.action("mail_forget", {"memory": "true"}), ("mail_forget", {"memory": False}))
        self.assertEqual(mail.action("mail_forget", {"memory": True}), ("mail_forget", {"memory": True}))
        self.assertEqual(mail.after("mail_connect", {"text": "连接成功。", "error": False})["args"], {"tab": "accounts"})
        self.assertIsNotNone(mail.after("mail_connect", {"text": "已保存，但连不上：超时", "error": True, "saved": True}),
                             "邮箱留着：回列表")
        self.assertIsNone(mail.after("mail_connect", {"text": "已保存，但连不上：超时", "error": True}), "只认 saved，不认那句话")
        self.assertIsNone(mail.after("mail_connect", {"text": "换了服务器，请重新填写授权码。", "error": True}), "留在表单上改")

    def test_mem_later_is_its_own_choice(self):
        """「以后再说」交 mem_reply {ask, choice: later}，不带 text（同一个人的问题 answer 只认 是/不是）"""
        self.assertEqual(mem.action("mem_reply", {"ask": 7, "choice": "answer", "text": "later"}), ("mem_reply", {"ask": 7, "choice": "later"}))
        self.assertEqual(mem.action("mem_reply", {"ask": 7, "choice": "answer", "text": "是"}),
                         ("mem_reply", {"ask": 7, "choice": "answer", "text": "是"}))

    def test_scan_overview_and_detail_follow_the_mockup(self):
        with open(os.path.join(ROOT, "fixtures", "apppages", "luoke-scan", "built.json"), encoding="utf-8") as f:
            spec = json.load(f)
        read = lambda u: spec["data"][u]
        msgs = scan.build("overview", {}, read)
        a2ui.build(msgs, page=True)
        comps = _components(msgs)
        heads = [comps[i]["text"].split(" · ")[0] for i in comps["root"]["children"] if comps[i].get("variant") == "caption"]
        self.assertEqual(heads, ["检查", "安全", "清理", "已自动清理"], "安全和清理分开，安全在前（负责人 11-15）")
        text = json.dumps(comps, ensure_ascii=False)
        self.assertIn("其他 ", text)
        self.assertNotIn('"page": "mac"', text, "没有这一页，不留死链")
        events = [c["action"]["event"] for c in comps.values() if c["component"] == "Button"]
        self.assertFalse(any(e["name"] == "scan_apply" for e in events), "概览不放清理的按钮：没看过明细不让人直接删")
        self.assertIn("scan_now", [e["name"] for e in events], "能立即检查")
        no_fda = dict(spec["data"]["data/overview"], fullDiskAccess="denied", skipped=[{"rule": "x", "reason": "fda"}])
        opened = [c["action"]["event"]["context"] for c in _components(scan.build("overview", {}, lambda u: no_fda if u == "data/overview" else read(u))).values()
                  if c["component"] == "Button" and c["action"]["event"]["name"] == "scan_open_settings"]
        self.assertEqual(opened, [{"grant": "完全磁盘访问", "permission": "fda"}],
                         "扫描认的是系统设置那一页的名字（负责人 11-17：写成代号 fda，点了说「不认识这个权限」）")
        opened = [e["context"]["args"]["id"] for e in events if e["name"] == "agent.open_page" and e["context"].get("page") == "category"]
        clean = [i for i in opened if i not in scan.SECURITY_CATS and i != "large-file"]
        self.assertEqual(len(clean), scan.SHOW_CATS, "清理先列最大的三类；别的在「其他 N 类」；大文件单独一行")
        comps = _components(scan.build("category", dict(spec["args"]["category"]), read))
        header = [c for c in comps.values() if c.get("placement") == "header"]
        self.assertEqual(len(header), 1, "类名和大小是弹窗的标题")
        events = [c["action"]["event"] for c in comps.values() if c["component"] == "Button"]
        acts = [e["name"] for e in events]
        self.assertEqual(acts.count("scan_apply"), 2, "只有两个动作：移到废纸篓、此类不再提醒")
        self.assertEqual(acts.count("scan_reveal"), scan.ITEM_ROWS, "一页 25 项，每项能在访达中显示")
        self.assertEqual(acts.count("scan_ignore"), scan.ITEM_ROWS, "每项能单独设为不再提醒")
        apply = next(e for e in events if e["name"] == "scan_apply" and "how" in e["context"])
        self.assertEqual(len(apply["context"]["how"]), 41, "翻页不丢：按钮带着全部项的处理方式")
        nxt = [e["context"]["args"] for e in events if e["name"] == "agent.open_page"]
        self.assertIn({"id": "installer", "p": "2"}, nxt)
        page2 = _components(scan.build("category", {"id": "installer", "p": "2"}, read))
        self.assertEqual(sum(1 for c in page2.values() if c["component"] == "Button"
                             and c["action"]["event"]["name"] == "scan_reveal"), 41 - scan.ITEM_ROWS)

    def test_old_habit_asks_are_shown_in_interface_wording(self):
        """记忆库里以前问出来的习惯询问是口语的：画的时候换成新写法，新写法的原样"""
        from luoke_agent.apppages.mem import _formal_habit
        self.assertEqual(_formal_habit("以后「某商城」的「促销」邮件，都自动归档？",
                                       "你 2 次自己把它的邮件归档。说好以后，邮件助手会自动归档并告诉你，随时能撤回。"),
                         ("「某商城」的「促销」邮件自动归档", "已手动归档 2 次。同意后邮件助手自动归档并在「今天」中列出，可随时撤销"))
        new = ("「某商城」的「促销」邮件自动归档", "已手动归档 2 次。同意后邮件助手自动归档并在「今天」中列出，可随时撤销")
        self.assertEqual(_formal_habit(*new), new)
        self.assertEqual(_formal_habit("「张三」和「张三丰」是同一个人吗？", ""), ("「张三」和「张三丰」是同一个人吗？", ""))

    def test_the_sidebar_line_is_written_from_data(self):
        """侧栏上应用名字下面的那一行由 agent 照数字和状态写，不用应用给的句子（负责人 11-17）"""
        with open(os.path.join(ROOT, "fixtures", "apppages", "luoke-scan", "built.json"), encoding="utf-8") as f:
            spec = json.load(f)
        over = dict(spec["data"]["data/overview"])
        line = lambda d: scan.summary(lambda u: d)
        free = scan.size(sum(c.get("bytes") or 0 for c in scan._cats(over) if c.get("id") not in scan.SECURITY_CATS))
        att = over["attention"]
        self.assertEqual(line(over), f"{att['urgent']} 项需尽快处理，可释放 {free}，{att['count'] - att['urgent']} 项待查看")
        self.assertIn(f"可释放 {free}", json.dumps(scan.build("overview", {}, lambda u: spec["data"][u]), ensure_ascii=False),
                      "和扫描页「清理」写的是同一个数")
        self.assertEqual(line(dict(over, scanning={"fraction": 0.42})), "正在检查 42%")
        self.assertEqual(line(dict(over, scanned={})), "尚未检查")
        self.assertEqual(line(dict(over, attention={"count": 0, "urgent": 0}, reclaimable=[])), "未发现问题")
        self.assertIsNone(line(None), "读不到数据：照旧用应用给的")
        data = dict(_data("luoke-search", "built.json"))
        say = lambda: search.summary(lambda u: data.get(u))
        ix = dict(data["data/index"])
        self.assertEqual(say(), "正在建立索引 62%")
        data["data/index"] = dict(ix, state="ready")
        self.assertEqual(say(), "索引已是最新")
        data["data/permissions"] = dict(data["data/permissions"], photos={"on": True, "system": "denied"})
        self.assertEqual(say(), "索引已是最新，1 项权限待允许")
        data["data/index"] = dict(ix, state="paused")
        self.assertTrue(say().startswith("索引已暂停"))
        data["data/index"] = dict(ix, state="needs_setup")
        self.assertEqual(say(), "尚未选择检索范围")
        for text in (line(over), say()):
            self.assertFalse(any(w in text for w in ("你", "等", "还没", "清出")), text)

    def test_names_for_what_the_manifest_lists(self):
        from luoke_agent import apppages
        from luoke_agent.toolsource import ToolSource
        self.assertEqual(apppages.kind_name("luoke-mail", "new-mail"), "待处理邮件")
        self.assertIsNone(apppages.kind_name("luoke-mail", "brand-new"))
        self.assertIsNone(apppages.kind_name("other", "x"))
        perms = [{"id": "fda", "kind": "system", "owner": "luoke", "tcc": "SystemPolicyAllFiles", "title": "完全磁盘访问"},
                 {"id": "auto", "kind": "delegate", "on": "scan_autoclean", "title": "不用点就清 4 类"},
                 {"id": "new", "kind": "each-time", "title": "清单自己写的"}]
        src = ToolSource("luoke-scan", os.path.join(tempfile.gettempdir(), "none", "agent.sock"), permissions=perms)
        self.assertEqual([p["title"] for p in src.permissions], ["完全磁盘访问", "自动清理 4 类文件", "清单自己写的"])

    def test_scan_words_follow_what_the_plan_really_does(self):
        """按钮和确认框照实际的处理方式写（负责人 11-15：缓存是直接删，不是移到废纸篓）"""
        from luoke_agent.apppages.scan import _apply_words
        self.assertEqual(_apply_words([{"options": ["trash"], "restorable": True}]), ("移到废纸篓", "可从清理记录恢复"))
        self.assertEqual(_apply_words([{"options": ["remove"]}])[0], "删除")
        self.assertIn("无法恢复", _apply_words([{"options": ["delete"]}])[1])
        self.assertEqual(_apply_words([{"options": ["scripts-off"]}])[0], "关闭自动运行")
        self.assertEqual(_apply_words([{"options": ["trash"], "restorable": True}, {"options": ["remove"]}])[0], "清理所选")
        self.assertIn("无法", _apply_words([{"options": ["trash"], "restorable": False}])[1])
        for how in ("trash", "remove", "delete", "scripts-off", "clone"):
            ctx = {"plan_id": "p", "selected": {"a": True, "b": False}, "how": {"a": how, "b": "trash"}}
            self.assertEqual(scan.action("scan_apply", ctx), ("scan_apply", {"plan_id": "p", "choices": {"a": [how]}}))

    def test_search_page_follows_the_mockup(self):
        data = _data("luoke-search", "built.json")
        msgs = search.build("overview", {}, lambda u: data[u])
        a2ui.build(msgs, page=True)
        comps = _components(msgs)
        root = comps["root"]["children"]
        self.assertFalse(any(c["component"] == "TextField" for c in comps.values()), "搜用窗口底部的搜索框，页上不再放一个")
        heads = [comps[i]["text"] for i in root if comps[i].get("variant") == "caption"]
        self.assertEqual(heads, ["最近搜索", "检索范围", "权限", "建立索引"], "都摊开，不点进二级页")
        events = [(c["action"]["event"]["name"], c["action"]["event"]["context"]) for c in comps.values() if c["component"] == "Button"]
        self.assertIn(("agent.search", {"q": "客户名单"}), events, "点最近搜索的就搜")
        self.assertIn(("search_settings_apply", {"clear_recent": True}), events, "最近搜索能清除")
        self.assertIn(("search_settings_apply", {"add_folder": True}), events)
        self.assertIn(("search_settings_apply", {"photos": True}), events, "照片关着：点了打开")
        self.assertNotIn("4035", json.dumps(msgs, ensure_ascii=False))
        self.assertIn("正在建立索引 62%", json.dumps(msgs, ensure_ascii=False), "进度只在建立索引那一行")

    def test_search_page_states(self):
        """暂停的原因按代号写；系统没允许照片时写去哪里允许；跳过的能取消；选文件夹时自己刷新；没选范围时不放开关"""
        data = dict(_data("luoke-search", "built.json"))
        build = lambda: search.build("overview", {}, lambda u: data[u])
        text = lambda: json.dumps(build(), ensure_ascii=False)
        events = lambda: [(c["action"]["event"]["name"], c["action"]["event"]["context"]) for c in _components(build()).values()
                          if c["component"] == "Button"]
        ix = dict(data["data/index"])
        for paused, want in (({"by": "mac", "reasons": ["battery", "thermal"]}, "已暂停：使用电池、设备温度过高"),
                             ({"by": "mac", "reasons": ["low_power"]}, "已暂停：低电量模式"),
                             ({"by": "mac", "reasons": ["memory"]}, "已暂停：内存不足"),
                             ({"by": "luoke", "reasons": []}, "已暂停：螺壳已暂停后台任务"),
                             ({"by": "user", "reasons": ["manual"]}, "已暂停：手动模式，有文件等待索引"),
                             ({"by": "mac", "reasons": ["new-code"]}, "已暂停")):
            data["data/index"] = dict(ix, state="paused", paused=paused)
            self.assertIn(want, text())
        data["data/index"] = dict(ix, state="paused", mode="manual", paused={"by": "user", "reasons": ["manual"]})
        self.assertIn(("search_settings_apply", {"index_now": True}), events(), "手动：给「立即索引」")
        data["data/index"] = dict(ix, state="ready")
        perms = dict(data["data/permissions"])
        data["data/permissions"] = dict(perms, photos={"on": True, "system": "denied"})
        self.assertIn("系统未允许读取", text())
        self.assertNotIn("再问", text())
        scope = dict(data["data/scope"])
        data["data/scope"] = dict(scope, picking=True, skipped=[{"id": "s1", "path": "~/Documents/node_modules", "name": "node_modules"}],
                                  folders=[{"id": "f1", "path": "/Volumes/T7/资料", "name": "资料", "kind": "folder", "connected": False}])
        self.assertIn(("search_settings_apply", {"unskip": "s1"}), events(), "跳过的能取消")
        self.assertIn("未连接 · /Volumes/T7/资料", text())
        self.assertEqual(_components(build())["root"].get("refresh"), 2, "选文件夹的框开着：隔 2 秒再读")
        data["data/scope"] = scope
        data["data/index"] = dict(ix, state="needs_setup")
        self.assertFalse(any(set(ctx) & {"files", "photos"} for _, ctx in events()), "没选检索范围：不放点了会被拒的开关")
        self.assertIn("尚未选择检索范围", text())

    def test_window_search_is_remembered_only_by_tools_that_keep_recent(self):
        """窗口搜索框按的回车：给了「最近搜过的」的工具（螺壳搜索）带 remember 和用户的操作，别的照旧只读"""
        from luoke_agent.toolsource import ToolSource

        class Client:
            def call_tool(self, name, args, **kw):
                self.sent = (name, args, kw.get("user_action"))

        src = ToolSource.__new__(ToolSource)
        src.client, src.service = Client(), {"search": "search_query"}
        src.search("发票", 5, at="2026-11-13T00:00:00Z")
        self.assertEqual(src.client.sent, ("search_query", {"query": "发票", "limit": 5}, None))
        src.data = ["recent", "scope"]
        src.search("发票", 5, at="2026-11-13T00:00:00Z")
        self.assertEqual(src.client.sent[1], {"query": "发票", "limit": 5, "remember": True})
        self.assertEqual(src.client.sent[2]["surfaceId"], "search")

    def test_long_mail_lists_still_draw(self):
        """真邮箱的处理记录一次给 200 条、精选很多：页只列前面那些，不超过应用页的组件上限（不然整页「画不了」）"""
        from luoke_agent import a2ui
        from luoke_agent.apppages import mail
        steps = [{"log_id": i, "account": "a@b.c", "at": "2026-11-14T10:00:00", "op": "archive", "count": 1,
                  "undoable": True, "mail": {"subject": "主题"}} for i in range(200)]
        a2ui.build(mail.activity({}, lambda u: {"items": steps, "more": False}), page=True)
        picks = [{"id": i, "account": "a@b.c", "title": "t", "source": "s", "summary_text": "x"} for i in range(200)]
        a2ui.build(mail.digest({}, lambda u: {"items": picks} if "digest" in u else
                               {"accounts": [{"id": "a@b.c", "address": "a@b.c"}]}), page=True)

    def test_scan_where_reads_real_and_recorded_paths(self):
        """真机上扫描给绝对路径，录的样例里是 `~/`、`$TMPDIR/`：两样「在哪」都写得出"""
        from luoke_agent.apppages.scan import _where
        home = os.path.expanduser("~")
        self.assertEqual(_where(home + "/Downloads/a.dmg"), "下载")
        self.assertEqual(_where("~/Downloads/a.dmg"), "下载")
        self.assertEqual(_where(home + "/Library/Caches/x"), "资源库")
        self.assertEqual(_where("$TMPDIR/wings-1"), "临时文件夹")
        self.assertEqual(_where("/opt/homebrew/x"), "")
        self.assertEqual(_where(""), "")

    def test_scan_trash_sends_only_the_checked_items(self):
        """勾了哪些换成扫描认的 choices：没勾的不发；会自己重建的缓存是 remove。key 不在这张页上的不认"""
        ctx = {"plan_id": "p1", "selected": {"a": True, "b": False, "c": True, "x": True}, "how": {"a": "trash", "b": "trash", "c": "remove"}}
        self.assertEqual(scan.action("scan_apply", ctx), ("scan_apply", {"plan_id": "p1", "choices": {"a": ["trash"], "c": ["remove"]}}))
        ignore = {"plan_id": "p1", "choices": {"a": ["ignore"]}}
        self.assertEqual(scan.action("scan_apply", ignore), ("scan_apply", ignore))

    def test_mem_today_card_is_a_question_a_reason_and_a_row_of_choices(self):
        """「今天」上记忆想问的：照 data/ask 拼，一句问题、一句为什么、一排选项（是 / 不是 / 以后再说），依据收起来"""
        spec = json.load(open(os.path.join(ROOT, "fixtures", "apppages", "luoke-mem", "asks.json"), encoding="utf-8"))
        by = {k.split("#")[1]: (k.split("#")[0], v) for k, v in spec["data"].items()}
        uri, data = by["interest"]
        msgs = mem.card("luoke-mem/ask-1", "ask-1", lambda u: data if u == uri else None)
        s = a2ui.build(msgs)
        comps = _components(msgs)
        picker = next(c for c in comps.values() if c["component"] == "ChoicePicker")
        self.assertEqual([o["label"] for o in picker["options"]], ["是", "不是", "稍后"], "「以前是」「归档」「改成」不上卡片")
        self.assertFalse([c for c in comps.values() if c["component"] == "Button" and c["id"] != picker["submit"]], "没有一排字按钮")
        self.assertTrue(any(c.get("collapsed") == "依据 1 条" for c in comps.values()))
        name, ctx = s.button_event(picker["submit"])
        self.assertEqual(mem.action(name, a2ui.merge_context(ctx, {}, {"choices": {"a1": ["1"]}})),
                         ("mem_reply", {"ask": 1, "choice": "no"}), "选了「不是」交记忆给的那一种答法")
        uri, data = by["same-person"]
        msgs = mem.card("luoke-mem/ask-1", "ask-1", lambda u: data if u == uri else None)
        picker = next(c for c in _components(msgs).values() if c["component"] == "ChoicePicker")
        self.assertEqual([o["label"] for o in picker["options"]], ["是", "不是", "稍后"])
        self.assertIsNone(mem.card("luoke-mem/ask-9", "ask-9", lambda u: {"found": False}), "读不到：照旧画记忆自己的卡片")

    def test_inbox_lists_only_a_cards_own_mails(self):
        """卡片上「看是哪几封」带方案编号：只列这张卡片要动的那几封，只看，不出换组的那一排、不放回复和归档"""
        items = [{"id": 1, "account": "a@x.com", "from": {"name": "某店"}, "subject": "促销", "ask_text": None},
                 {"id": 2, "account": "a@x.com", "from": {"name": "某站"}, "subject": "周报", "ask_text": None}]
        asked = []

        def read(u):
            asked.append(u)
            return {"accounts": [{"id": "a@x.com", "address": "a@x.com"}]} if u == "data/accounts" else {"list": "plan", "items": items}
        msgs = mail.build("inbox", {"box": "a@x.com", "plan": "mailbox-1", "part": "tidy"}, read)
        a2ui.build(msgs, page=True)
        comps = _components(msgs)
        self.assertIn("data/inbox?account=a%40x.com&part=tidy&plan=mailbox-1", asked, "和邮件助手录的一样：part 原样带上")
        self.assertIn("此卡片涉及 2 封", json.dumps(msgs, ensure_ascii=False))
        self.assertFalse([c for c in comps.values() if c["component"] == "ChoicePicker"])
        names = {c["action"]["event"]["name"] for c in comps.values() if c["component"] == "Button"}
        self.assertEqual(names, {"agent.open_page"}, "只能点开看")
        done = mail.build("inbox", {"box": "a@x.com", "plan": "mailbox-1", "part": "tidy"},
                          lambda u: {"list": "plan", "items": [], "plan": {"id": "mailbox-1", "part": "tidy", "state": "handled"}})
        self.assertIn("此卡片已处理", json.dumps(done, ensure_ascii=False))



class MailReasonsTest(unittest.TestCase):
    """邮件助手停下的原因：它给代号，字由 agent 写（顶层 ADR 0002）；没有代号的旧版本退回它的原文"""

    def test_codes_are_worded_here_and_old_text_is_the_fallback(self):
        from luoke_agent.apppages import mail
        self.assertEqual(mail._why("mail_timeout", "IMAP 连接超时。"), "连接邮箱超时", "有代号照代号写，不用原文")
        self.assertEqual(mail._why("something_new"), mail.REASONS["error"], "不认识的代号当 error")
        self.assertEqual(mail._why(None, "TimeoutError: 连不上。"), "连不上", "没有代号：原文，类名和句号不上屏")
        self.assertEqual(mail._why(None, None), "")
        for code, words in mail.REASONS.items():
            plain = words.replace("「我的文件夹」", "")      # QQ 邮箱里那个功能的名字
            self.assertFalse(words.endswith("。") or any(w in plain for w in ("你", "我", "别", "一下")), code)
        self.assertEqual(mail._check_note({"model_check": {"reason": "model_error", "problem_code": "memory_full", "unchecked": 3, "of": 9}}),
                         "3 个发件人未经本机模型分析（内存不足），建议仅依据收信和阅读情况")
        self.assertEqual(mail._check_note({"model_check": {"reason": "no_model", "unchecked": 2, "of": 2}}),
                         "2 个发件人未经本机模型分析（未选择本机模型），建议仅依据收信和阅读情况")
        self.assertEqual(mail._check_note({"model_check": None, "model_note": "有 3 个发件人未能分析。"}), "有 3 个发件人未能分析")
        self.assertIsNone(mail._check_note({"model_check": None, "model_note": None}))



class MemCodesTest(unittest.TestCase):
    """记忆 0.44 的代号和数：理由、同类、点按的结果、没做成的原因、侧栏那一行都由 agent 照它们写；旧版本没有时照旧"""

    def test_why_is_worded_from_its_code(self):
        w = lambda **d: mem._why_words({"why": "记忆自己的那句。", "why_data": d})
        self.assertEqual(w(code="sent_mail", count=2, waiting=False), "已发送邮件中提到 2 次")
        self.assertEqual(w(code="sent_mail", waiting=False), "已发送邮件中提到")
        self.assertEqual(w(code="typing_term_pending", days=2, times=5, need_days=3, need_times=8, waiting=True),
                         "输入记录中 2 天出现 5 次，达到 3 天 8 次后记为常用词，待确认")
        self.assertEqual(w(code="sent_mail_person", relation="同事", waiting=False), "已发送邮件中提到此人（同事）")
        self.assertEqual(w(code="habit_manual", times=3, action="归档", waiting=False), "已手动归档 3 次")
        self.assertEqual(w(code="habit_overridden", times=2, action="标为已读", waiting=False), "邮件助手的建议 2 次被改为标为已读")
        self.assertEqual(w(code="frequent_contact", months=6, waiting=False), "近 6 个月经常通信")
        self.assertEqual(w(code="something_new", waiting=False), "记忆自己的那句", "不认识的代号：用它的原文")
        self.assertEqual(mem._why_words({"why": "我自己写的。", "why_data": None}), "我自己写的", "用户自己写的没有代号")
        self.assertEqual(mem._why_words({}), "")

    def test_said_follows_the_result_and_the_reason(self):
        said = lambda name, ctx, **r: mem.said(name, ctx, r)
        self.assertEqual(said("mem_note", {"op": "reject_family"}, text="否定了 2 条，以后这一类少提。", facts={"result": "reject_family", "n": 2, "of": 2}),
                         "已否定 2 条同类记忆")
        self.assertEqual(said("mem_note", {"op": "confirm"}, text="好。", facts={"result": "confirm", "was": "past"}), "已确认仍然成立")
        self.assertEqual(said("mem_reply", {"choice": "later"}, text="好。", facts={"result": "later", "days": 7, "stale": False}), "将在 7 天后再次询问")
        self.assertEqual(said("mem_reply", {"choice": "yes"}, text="好。", facts={"result": "changed", "stale": True}), mem.CHANGED,
                         "问题已失效：不写成已确认")
        self.assertEqual(said("mem_archive", {}, text="好。", facts={"result": "archive", "n": 3, "of": 4}), "已归档 3 件，1 件未处理")
        self.assertEqual(said("mem_forget_tool", {}, text="好。", facts={"result": "forget_tool", "records": 12, "notes": 3}), "已删除 12 条记录、3 条记忆")
        self.assertEqual(said("mem_note", {"op": "revise"}, text="记忆不保存密码、验证码和证件号码，改一下再点。", error=True,
                              facts={"reason": "secret"}), mem.SAID_REASONS["secret"])
        self.assertEqual(said("mem_person", {"op": "merge"}, text="随便一句没见过的话", error=True, facts={"reason": "no_choice"}), "请先选择人物")
        # 旧一点的记忆：没有 facts，照点的是什么、它说的那句话
        self.assertEqual(said("mem_note", {"op": "confirm"}, text="记下了：对。"), "已确认")
        self.assertEqual(said("mem_reply", {"choice": "yes"}, text="这条已经变了，没有照做。"), mem.CHANGED)
        self.assertEqual(said("mem_note", {"op": "revise"}, text="和原来的一样，改一下再点。", error=True), "内容未变化，请修改后重试")
        for words in list(mem.SAID_REASONS.values()) + list(mem.FAMILY.values()):
            self.assertFalse(words.endswith("。") or any(x in words for x in ("你", "我", "一下")), words)

    def test_the_sidebar_line_follows_the_state(self):
        line = lambda d: mem.summary(lambda u: d)
        self.assertEqual(line({"state": "recent", "recent": {"text": "学校：某大学计算机系"}, "kept": 23, "pending": 3, "text": "最近了解到：…"}),
                         "最近记录：学校：某大学计算机系")
        self.assertEqual(line({"state": "quiet", "kept": 23, "pending": 3}), "3 条待确认")
        self.assertEqual(line({"state": "quiet", "kept": 23, "pending": 0}), "已记录 23 条")
        self.assertEqual(line({"state": "empty"}), "尚无记忆")
        self.assertEqual(line({"state": "not_ready", "problem": "locked"}), "记忆无法打开")
        self.assertIsNone(line({"count": 0, "text": "最近了解到：…"}), "旧一点的记忆：照它自己的那一句")


if __name__ == "__main__":
    unittest.main()


class MailHandledTest(unittest.TestCase):
    """「今天」上「已自动处理」照 data/today 拼（负责人 11-16：和邮件助手的「今日」用同一份数）"""

    HANDLED = [
        {"log_id": 1, "at": "2026-11-16 08:40:11", "by": "habit", "op": "archive", "count": 1, "account": "me@example.com",
         "senders": [{"name": "某某商城"}], "undoable": True, "more": 0,
         "mails": [{"id": 4030, "account": "me@example.com", "from": {"name": "某某商城"}, "subject": "周末促销"}]},
        {"log_id": 2, "at": "2026-11-16 09:02:00", "by": "read", "op": "read", "count": 5, "account": "me@example.com",
         "senders": [{"name": "甲"}, {"name": "乙"}], "undoable": True, "more": 0,
         "mails": [{"id": i, "from": {"name": "甲"}, "subject": f"第 {i} 封"} for i in range(5)]},
        {"log_id": 3, "at": "2026-11-16 09:30:00", "op": "archive", "count": 2, "undone": True},
    ]

    def read(self, u):
        return {"day": "2026-11-16", "handled": self.HANDLED} if u.startswith("data/today") else None

    def test_one_item_a_day_with_the_same_numbers(self):
        from luoke_agent.items import Item
        tool = [Item(key="luoke-mail/auto-done/x", source="luoke-mail", kind="auto-done", urgency="normal", title="已自动处理 1 封",
                     summary="", why_now="", card=[]),
                Item(key="luoke-mail/new-mail/y", source="luoke-mail", kind="new-mail", urgency="low", title="t", summary="",
                     why_now="", card=[])]
        out = mail.items(tool, self.read)
        self.assertEqual([it.key for it in out], ["luoke-mail/new-mail/y", "luoke-mail/handled/2026-11-16"],
                         "邮件助手自己报的 auto-done 换成核心拼的一件")
        it = out[-1]
        self.assertEqual((it.kind, it.title), ("auto-done", "归档 1 封 · 标为已读 5 封"), "撤销了的不算")
        a2ui.build(it.card)
        comps = _components(it.card)
        text = json.dumps(it.card, ensure_ascii=False)
        self.assertIn("某某商城 · 周末促销", text, "只动了一封：发件人和主题")
        opens = [c["action"]["event"]["context"] for c in comps.values() if c.get("action", {}).get("event", {}).get("name") == "agent.open_page"]
        self.assertIn({"page": "mail", "args": {"account": "me@example.com", "id": "4030"}}, opens, "点开这封信")
        self.assertIn({"page": "done", "args": {"account": "me@example.com", "log_id": "2"}}, opens, "几封的点开列出来")
        undo = [c for c in comps.values() if c.get("action", {}).get("event", {}).get("name") == "mail_undo_step"]
        self.assertEqual(len(undo), 2)
        self.assertNotIn("撤销", [comps[c["child"]].get("text") for c in comps.values() if c.get("component") == "Button" and "child" in c],
                         "每项各有撤销，不叫「撤销」：窗口那一行行尾不替整张卡片画一个")

    def test_nothing_handled_or_unreadable(self):
        from luoke_agent.items import Item
        tool = [Item(key="luoke-mail/auto-done/x", source="luoke-mail", kind="auto-done", urgency="normal", title="t",
                     summary="", why_now="", card=[])]
        self.assertEqual(mail.items(tool, lambda u: {"day": "2026-11-16", "handled": []}), tool, "数据里今天没处理过：不换")
        self.assertEqual(mail.items(tool, lambda u: None), tool, "读不到：照邮件助手自己报的")


class MailRound3Test(unittest.TestCase):
    """负责人第三轮走查（11-16）邮件助手这一批"""

    def test_inbox_opens_on_the_first_group_with_mail_and_writes_counts(self):
        asked = []

        def read(u):
            asked.append(u)
            if u.startswith("data/accounts"):
                return {"accounts": [{"id": "a@x.com"}], "model": {"status": "downloading", "progress": 0.4, "text": "螺壳正在下载模型（40%）。"}}
            counts = {"reply": 0, "needs": 2, "suspicious": 0}
            if "list=needs" in u:
                return {"list": "needs", "counts": counts, "items": [
                    {"id": 1, "account": "a@x.com", "from": {"name": "甲"}, "subject": "账单", "ask_text": "下月还款",
                     "date": "2026-11-12 16:20:00", "due": "2026-11-18", "kind": "follow_up",
                     "open_url": "https://mail.google.com/x"}]}
            return {"list": "reply", "counts": counts, "items": []}
        msgs = mail.build("inbox", {}, read)
        a2ui.build(msgs, page=True)
        comps = _components(msgs)
        picker = next(c for c in comps.values() if c["component"] == "ChoicePicker")
        self.assertEqual([o["label"] for o in picker["options"]], ["待回复 0", "待处理 2", "全部"], "每组写封数")
        self.assertTrue(any("list=needs" in u for u in asked), "「待回复」是空的：停在第一个不空的组")
        texts = [c.get("text") for c in comps.values() if c["component"] == "Text"]
        self.assertIn("11-18 截止", texts, "截止日是小标签")
        self.assertIn("11-12", texts, "来信时间")
        self.assertIn("正在下载模型 40%，完成后自动开始分析", texts, "分析不了的原因在页顶：照状态的代号写，不用邮件助手的原文")
        self.assertIn("Gmail", texts, "去 Gmail 的按钮写网站名，写短")
        asked.clear()
        mail.build("inbox", {"list": "reply"}, read)
        self.assertFalse(any("list=needs" in u for u in asked), "用户自己选了「待回复」：空的也停在这里")

    def test_the_last_group_is_tried_first_and_left_when_empty(self):
        def read(u):
            if u.startswith("data/accounts"):
                return {"accounts": [{"id": "a@x.com"}]}
            counts = {"reply": 1, "needs": 0, "suspicious": 0}
            one = {"id": 1, "account": "a@x.com", "from": {"name": "甲"}, "subject": "s", "kind": "reply"}
            return {"counts": counts, "items": [] if "list=needs" in u else [one]}
        comps = _components(mail.build("inbox", {"_last_list": "needs"}, read))
        self.assertIn("s", [c.get("text") for c in comps.values()], "上次停在「待处理」，现在空了：换到不空的「待回复」")
        self.assertEqual(mail.REMEMBER_ARGS["inbox"], ("list",))

    def test_digest_opens_on_the_week_when_today_is_empty(self):
        asked = []

        def read(u):
            asked.append(u)
            if u.startswith("data/accounts"):
                return {"accounts": [{"id": "a@x.com"}]}
            return {"items": [] if "range=today" in u else [{"id": 7, "title": "一篇", "picked": True}], "counts": {}}
        text = json.dumps(mail.build("digest", {}, read), ensure_ascii=False)
        self.assertIn("一篇", text, "「今天」是空的：换到「本周」")
        asked.clear()
        self.assertNotIn("一篇", json.dumps(mail.build("digest", {"range": "today"}, read), ensure_ascii=False), "自己选了「今天」：不换")

    def test_activity_skips_steps_that_moved_nothing(self):
        d = {"items": [{"log_id": 1, "at": "2026-11-16 08:00:00", "op": "archive", "count": 0, "by": "user"},
                       {"log_id": 2, "at": "2026-11-16 09:00:00", "op": "archive", "count": 3, "by": "user"}]}
        text = json.dumps(mail.build("activity", {}, lambda u: d), ensure_ascii=False)
        self.assertNotIn("归档 0 封", text)
        self.assertIn("归档 3 封", text)
        self.assertIn("手动", text)
        self.assertNotIn("你点的", text)

    def test_timed_tidy_says_its_result_and_why_it_is_not_running(self):
        d = {"auto": {"enabled": True, "every": 30, "intervals": [15, 30], "next_in_min": 12, "stalled": "removed",
                      "last": {"at": "2026-11-15 08:00", "ok": True, "text": "归档 3 封。"}}}

        def read(u):
            return {"accounts": [{"id": "a@x.com"}]} if u.startswith("data/accounts") else d
        text = json.dumps(mail.build("settings", {"tab": "remind"}, read), ensure_ascii=False)
        self.assertIn("归档 3 封 · 12 分钟后下一次", text)
        self.assertIn("登录项已被移除，定时整理未运行", text)
        self.assertIn("重新开启", text)


class MemRound3Test(unittest.TestCase):
    """负责人第三轮走查（11-16）记忆这一批"""

    def setUp(self):
        self.data = _data("luoke-mem", "built.json")
        self.read = lambda u: self.data[u]

    def events(self, msgs, name):
        return [c["action"]["event"]["context"] for c in _components(msgs).values()
                if c.get("action", {}).get("event", {}).get("name") == name]

    def test_asks_have_their_own_replies_none_picked_and_a_confirm_button(self):
        msgs = mem.build("overview", {}, self.read)
        surface = a2ui.build(msgs, page=True)
        comps = _components(msgs)
        picker = next(c for c in comps.values() if c["component"] == "ChoicePicker")
        self.assertEqual([o["label"] for o in picker["options"]], ["是", "不是", "稍后"], "照这件事能怎么答给选项")
        self.assertNotIn("submit", picker, "选了不马上办")
        self.assertEqual(surface.data["choices"]["ask1"], [], "默认都不选")
        reply = self.events(msgs, "mem_reply")[0]
        self.assertEqual(reply["replies"]["0"], {"choice": "answer", "text": "是"})
        self.assertEqual(mem.action("mem_reply", {"ask": 1, "pick": ["2"], "replies": reply["replies"]}),
                         ("mem_reply", {"choice": "later", "ask": 1}))
        self.assertEqual(mem.action("mem_reply", {"ask": 1, "pick": [], "replies": reply["replies"]})[1]["choice"], "",
                         "没选就点「确定」：记忆会拒绝")
        text = json.dumps(msgs, ensure_ascii=False)
        for word in ("以后再说", "想确认一下", "最近了解到的", "不对", "看依据"):
            self.assertNotIn(f'"{word}', text, "按钮和标签不用口语")

    def test_not_ready_says_why_and_what_next(self):
        for problem, word in (("too_new", "更新螺壳"), ("links", "符号链接"), ("broken", "备份"), ("locked", "正在整理")):
            text = json.dumps(mem.build("overview", {}, lambda u: {"ready": False, "problem": problem}), ensure_ascii=False)
            self.assertIn(word, text, problem)
        self.assertIn("暂时无法打开", json.dumps(mem.build("all", {}, lambda u: {"ready": False, "problem": "x"}), ensure_ascii=False))

    def test_a_note_shows_its_state_and_can_be_revised_and_split(self):
        msgs = mem.build("item", {"id": "25"}, self.read)
        a2ui.build(msgs, page=True)
        text = json.dumps(msgs, ensure_ascii=False)
        self.assertIn("有效 · 置信度中 · 推断", text, "状态、置信度、怎么来的")
        self.assertIn("来源：邮件助手", text, "依据写来源")
        ops = {c["op"]: c for c in self.events(msgs, "mem_note")}
        self.assertEqual(set(ops), {"reject", "forget", "revise", "split"}, "改写、拆出并进来的表述回来了")
        self.assertEqual(ops["revise"]["text"], {"path": "/fields/revise"})
        self.assertEqual(ops["split"]["note"], 3)

    def test_a_person_can_be_renamed_split_merged_and_rejected(self):
        msgs = mem.build("person", {"id": "1"}, self.read)
        a2ui.build(msgs, page=True)
        ops = [c["op"] for c in self.events(msgs, "mem_person")]
        self.assertEqual(sorted(set(ops)), ["forget", "merge", "reject", "rename", "split"])
        self.assertGreater(ops.count("split"), 1, "每个称呼都能拆出去")
        merge = next(c for c in self.events(msgs, "mem_person") if c["op"] == "merge")
        self.assertEqual(merge["other"], {"path": "/choices/merge_other"})

    def test_all_notes_has_every_filter_with_notes_and_a_search_box(self):
        d = {"ready": True, "items": [], "counts": {"rejected": 2, "dislike": 1, "term": 3, "fact": 4}, "page": 2, "pages": 3}
        msgs = mem.build("all", {"filter": "rejected"}, lambda u: d)
        comps = _components(msgs)
        picker = next(c for c in comps.values() if c["component"] == "ChoicePicker")
        self.assertEqual([o["label"] for o in picker["options"]], ["全部", "个人信息", "不感兴趣", "常用词", "已否定"])
        self.assertTrue(any(c["component"] == "TextField" for c in comps.values()), "页内能搜")
        pages = [c["args"] for c in self.events(msgs, "agent.open_page") if "p" in c.get("args", {})]
        self.assertEqual(sorted(a["p"] for a in pages), ["1", "3"])
        self.assertTrue(all(a.get("filter") == "rejected" for a in pages), "翻页留着筛选")

    def test_family_can_be_rejected_and_forgetting_an_app_says_exact_numbers(self):
        note = dict(self.data["data/note?id=25"], family={"head": "学校", "notes": [25, 26]})
        msgs = mem.build("item", {"id": "25"}, lambda u: note)
        a2ui.build(msgs, page=True)
        fam = next(c for c in self.events(msgs, "mem_note") if c["op"] == "reject_family")
        self.assertEqual(fam["family"], [25, 26], "交回记忆数的那几条")
        d = dict(self.data)
        tool = d["data/sources"]["items"][0]["tool"]
        d[f"data/forget?tool={tool}"] = {"found": True, "known": True, "records": 7, "notes": 2, "kept": 3}
        text = json.dumps(mem.build("settings", {"tab": "data"}, lambda u: d[u]), ensure_ascii=False)
        self.assertIn("将删除 7 条记录和 2 条记忆", text)
        self.assertIn("另有 3 条记忆保留", text)

    def test_what_the_window_says_after_a_tap_is_written_here(self):
        self.assertEqual(mem.said("mem_note", {"op": "confirm"}, {"text": "记下了：对。"}), "已确认")
        self.assertEqual(mem.said("mem_person", {"op": "rename"}, {"text": "改好了：以后就叫「磊哥」。"}), "已重命名")
        self.assertEqual(mem.said("mem_reply", {"choice": "later"}, {"text": "好，过几天再问。"}), "将在数日后再次询问")
        self.assertEqual(mem.said("mem_note", {"op": "revise"}, {"text": "先在上面写好。", "error": True}), "请先填写内容",
                         "没做成的：记忆的口语说法换成书面的")
        self.assertIsNone(mem.said("mem_note", {"op": "revise"}, {"text": "别的原因。", "error": True}), "不认得的照记忆说的")
        self.assertEqual(mem.said("mem_reply", {"choice": "yes"}, {"text": "这条已经变了（可能已经生效，或者在别处答过了）。", "done": True}),
                         "此条已变更，未执行", "已经失效的不写成「已确认」")

    def test_the_card_asks_in_the_agent_s_words(self):
        note = {"type": "note", "basis": "guess", "note": {"kind": "interest", "text": "开源许可"}, "text": "你在关注「开源许可」吗？",
                "why": "你最近常提到「开源许可」，想确认是不是你长期关注的"}
        self.assertEqual(mem._card_words(note), ("是否关注「开源许可」？", "依据近期记录推断，确认后生效"))
        self.assertEqual(mem._card_words(dict(note, basis="quiet"))[0], "「开源许可」是否仍然成立？")
        unsub = {"type": "unsubscribe", "facts": {"sender": "某商城", "times": 3, "count": 41}, "text": "要不要退订？", "why": "你一直没留"}
        self.assertEqual(mem._card_words(unsub), ("建议退订「某商城」", "近期已手动清理其邮件 3 次，共 41 封"))
        own = {"type": "own", "text": "周报一般哪天发？", "why": "发出的邮件里周报的日子不一样"}
        self.assertEqual(mem._card_words(own), ("周报一般哪天发？", "发出的邮件里周报的日子不一样"), "别的应用托记忆问的是内容，照原样")


class MailWordsTest(unittest.TestCase):
    def test_job_and_tap_lines(self):
        self.assertEqual(mail._job_name({"kind": "learn", "stage": "正在阅读你发出的邮件"}), "正在从邮件中学习偏好")
        self.assertEqual(mail._job_name({"kind": "新的", "stage": "x"}), "后台处理中")
        self.assertEqual(mail.said("mail_old", {}, {"text": "好的，留着，以后不再问。"}), "已保留，不再提示")
        self.assertEqual(mail.said("mail_act", {}, {"text": "已归档 2 封。"}), "已归档 2 封")
        self.assertEqual(mail.said("mail_x", {}, {"text": "连接成功。收件箱共 3 封，未读 1 封。"}), "连接成功。收件箱共 3 封，未读 1 封。")
        self.assertIsNone(mail.said("mail_x", {}, {"text": ""}))

    def test_people_page_and_search(self):
        d = {"ready": True, "items": [{"id": 1, "name": "王磊"}], "page": 1, "pages": 2}
        asked = []

        def read(u):
            asked.append(u)
            return d
        msgs = mem.build("people", {"p": "2", "q": "王"}, read)
        self.assertIn("p=2", asked[0])
        self.assertIn("第 1 / 2 页", json.dumps(msgs, ensure_ascii=False))


class MailFeaturesBackTest(unittest.TestCase):
    """负责人 11-15：精简是合并标签、收起少用的，不是删功能。旧界面能做的，页上都有入口（luoke-mail origin/main 的
    window/pages），每页照 A2UI 校验画得出、不超过组件上限"""

    def setUp(self):
        self.data = _data("luoke-mail", "pages.json")

    def read(self, extra=None):
        data = dict(self.data, **(extra or {}))

        def read(u):
            if u in data:
                return data[u]
            name = u.split("?")[0]
            return next((v for k, v in data.items() if k.split("?")[0] == name), {})
        return read

    def page(self, name, args=None, extra=None):
        msgs = mail.build(name, dict(args or {}), self.read(extra))
        a2ui.build(msgs, page=True)
        self.assertLessEqual(len(_components(msgs)), a2ui.MAX_PAGE_COMPONENTS)
        return msgs

    @staticmethod
    def events(msgs):
        return [c["action"]["event"]["name"] for c in _components(msgs).values() if c.get("action")]

    def test_every_page_draws(self):
        for name, args in [("today", {}), ("inbox", {}), ("inbox", {"list": "needs"}), ("inbox", {"list": "suspicious"}),
                           ("digest", {}), ("digest", {"range": "saved"}), ("digest", {"range": "archived"}),
                           ("clean", {}), ("activity", {}), ("settings", {"tab": "accounts"}), ("settings", {"tab": "rules"}),
                           ("settings", {"tab": "remind"}), ("settings", {"tab": "more"})]:
            with self.subTest(page=name, args=args):
                self.page(name, args)

    def test_clean_offers_the_checks_when_never_run(self):
        never = {"scanned_at": None, "groups": [], "total": 0, "judged": 0}
        msgs = self.page("clean", extra={"data/clean?account=all": {"subscriptions": None, "archive": None},
                                         "data/old?account=me%40company.example": never, "data/old?account=me%40mail.example": never})
        ev = self.events(msgs)
        self.assertIn("mail_subscriptions_check", ev, "没检查过订阅：给「检查订阅」")
        self.assertIn("mail_old_scan", ev, "没看过旧邮件：给「看一遍」")
        self.assertNotIn("暂无可清理的邮件", json.dumps(msgs, ensure_ascii=False), "还没查过不能说没有要清的")

    def test_subscription_check_shows_every_group_and_takes_decisions_back(self):
        msgs = self.page("subs", {"group": "handled"})
        comps = _components(msgs)
        picker = next(c for c in comps.values() if c["component"] == "ChoicePicker" and c["value"]["path"] == "/choices/group")
        self.assertEqual([o["value"] for o in picker["options"]], ["unsubscribe", "no_way", "suspicious", "handled", "keep"])
        self.assertIn("mail_sender_reset", self.events(msgs), "已处理的能撤回")
        self.assertIn("退订后仍在发送", json.dumps(msgs, ensure_ascii=False))
        clean = json.dumps(self.page("clean"), ensure_ascii=False)
        self.assertIn("建议退订 3、无法退订 1、可疑 1、已处理 1、建议保留 1", clean)

    def test_sender_says_how_much_history_and_how_to_unsubscribe_by_mail(self):
        msgs = self.page("sender", {"account": "me@mail.example", "key": "from:notice@forum.example"})
        text = json.dumps(msgs, ensure_ascii=False)
        self.assertIn("邮箱中还有 25 封，3.4 MB；移到「已删除」后，邮箱 30 天后清空", text)
        self.assertIn("正文填写「TD」", text)
        self.assertIn("mail_sender_unsubscribed", self.events(msgs))
        hist = next(c for c in _components(msgs).values() if c.get("action", {}).get("event", {}).get("name") == "mail_sender_history")
        self.assertIn("25 封", hist["confirm"]["title"])

    def test_sender_draws_from_the_check_when_the_mailbox_is_busy(self):
        # #167：data/sender 现去邮箱查历史，邮箱忙时等不到；其余的照体检的结果画，只有旧邮件数量写「暂未统计」
        read = self.read()
        asked = []
        read.within = lambda u, seconds: asked.append((u.split("?")[0], seconds)) or None
        msgs = mail.build("sender", {"account": "me@mail.example", "key": "from:notice@forum.example"}, read)
        a2ui.build(msgs, page=True)
        text = json.dumps(msgs, ensure_ascii=False)
        self.assertEqual(asked, [("data/sender", mail.SENDER_WAIT)], "只等几秒")
        self.assertIn("邮箱正忙，旧邮件数量暂未统计", text)
        self.assertNotIn("邮箱中还有", text)
        for name in ("mail_sender_rule", "mail_digest_source", "mail_sender_history"):
            self.assertIn(name, self.events(msgs))

    def test_sender_history_still_being_counted_or_failed(self):
        # 邮件助手后台查历史：没查完不带 `history`、给 `history_state`；页上写在统计，过几秒再读；查不了写原因
        u = "data/sender?" + mail.urlencode({"account": "me@mail.example", "key": "from:notice@forum.example"})
        base = dict(self.read()(u))
        base.pop("history", None)
        args = {"account": "me@mail.example", "key": "from:notice@forum.example"}
        msgs = self.page("sender", args, {u: dict(base, history_state="pending")})
        self.assertIn("正在统计旧邮件数量", json.dumps(msgs, ensure_ascii=False))
        self.assertIn('"refresh": 3', json.dumps(msgs))
        msgs = self.page("sender", args, {u: dict(base, history_state="error", history_error_code="login_refused")})
        text = json.dumps(msgs, ensure_ascii=False)
        self.assertIn("无法统计旧邮件数量：" + mail.REASONS["login_refused"], text)
        self.assertNotIn('"refresh"', json.dumps(msgs))
        self.assertIn("mail_sender_history", self.events(msgs))

    def test_clean_bulk_rows_name_the_mailbox_and_the_unlisted_groups(self):
        # #165：一个邮箱、一种做法一行（不是一排主按钮）；写整个地址、几组几封、其中几组没列在上面
        from luoke_agent.apppages.kit import PageKit
        kit = PageKit("clean")
        groups = [{"account": "1234567@mail.example", "key": f"a{i}", "action": "archive", "count": 10, "title": f"甲{i}"} for i in range(3)]
        groups += [{"account": "me@mail.example", "key": f"t{i}", "action": "trash", "count": 5, "title": f"乙{i}"} for i in range(2)]
        groups += [{"account": "me@mail.example", "key": "one", "action": "archive", "count": 1, "title": "丙"}]
        rows = mail._old_bulk_rows(kit, groups, "inbox", 2)
        msgs = kit.messages([kit.list(rows)])
        a2ui.build(msgs, page=True)
        text = json.dumps(msgs, ensure_ascii=False)
        self.assertEqual(len(rows), 2, "只有一组的不另给")
        self.assertIn("1234567@mail.example", text)
        self.assertIn("建议归档 3 组，共 30 封，含未列出的 1 组", text)
        self.assertIn("建议移到已删除 2 组，共 10 封，含未列出的 2 组", text)
        btns = [c for c in _components(msgs).values() if c["component"] == "Button"]
        self.assertTrue(all(c.get("confirm") and c.get("variant") != "primary" for c in btns))

    def test_old_mail_has_every_kind_and_scope(self):
        msgs = self.page("old")
        comps = _components(msgs)
        pickers = {c["value"]["path"]: [o["value"] for o in c["options"]] for c in comps.values() if c["component"] == "ChoicePicker"}
        self.assertEqual(pickers["/choices/scope"], ["inbox", "archive"])
        self.assertEqual(pickers["/choices/part"], ["suggested", "unsure", "pending", "kept"])
        bulk = [c for c in comps.values() if c.get("variant") == "primary"]
        self.assertEqual({c["action"]["event"]["name"] for c in bulk}, {"mail_old_trash"}, "建议删除的两组一次做完")
        self.assertTrue(all(c.get("confirm") for c in bulk))
        self.assertIn("星标和按标签保留的 37 封不处理", json.dumps(msgs, ensure_ascii=False))
        kept = self.page("old", {"part": "kept"})
        keep = [c["action"]["event"]["context"] for c in _components(kept).values()
                if c.get("action", {}).get("event", {}).get("name") == "mail_old_keep"]
        self.assertEqual([k["on"] for k in keep], [False], "留着的能不再留着")

    def test_jobs_show_their_result_and_actions_open_them(self):
        text = json.dumps(self.page("job", {"id": "j1"}), ensure_ascii=False)
        self.assertIn("此规则在过去一年会匹配 24 封", text)
        self.assertIn("有 3 封可能不应一并处理", text)
        done = {"id": "j2", "kind": "clean", "account": "me@company.example", "status": "done",
                "result": {"ok": True, "moved": 310, "stuck": 2, "log_id": 5521}}
        msgs = self.page("job", {"id": "j2"}, extra={"data/job?id=j2": done})
        self.assertIn("mail_undo_step", self.events(msgs))
        running = dict(done, status="running", done=3, total=10, result=None)
        msgs = self.page("job", {"id": "j2"}, extra={"data/job?id=j2": running})
        root = next(c for c in _components(msgs).values() if c["id"] == "root")
        self.assertEqual(root.get("refresh"), 3, "跑着的几秒刷新一次")
        self.assertEqual(mail.after("mail_old_trash", {"text": "", "job": "j2"}), {"page": "job", "args": {"id": "j2"}})
        self.assertIsNone(mail.after("mail_old_trash", {"text": "", "error": True}))

    def test_mail_with_several_events_adds_each(self):
        msgs = self.page("mail", {"account": "me@company.example", "id": "4019"})
        cal = [c["action"]["event"]["context"] for c in _components(msgs).values()
               if c.get("action", {}).get("event", {}).get("name") == "mail_calendar"]
        self.assertEqual([c.get("index") for c in cal], [1], "加过的不再给按钮，没加的带 index")
        self.assertIn("boss@company.example", json.dumps(msgs, ensure_ascii=False))

    def test_opening_a_piece_reads_it_so_it_counts_as_opened(self):
        seen = []
        item = dict(self.read()("data/digest?account=all&range=today")["items"][0])
        uri = f"data/piece?account=me%40company.example&id={item['id']}"
        read = self.read({uri: item})
        mail.build("piece", {"account": "me@company.example", "id": str(item["id"])}, lambda u: seen.append(u) or read(u))
        self.assertEqual(seen, [uri], "一条精选只读 data/piece")

    def test_every_mailbox_at_once_and_sources(self):
        ctx = [c["action"]["event"]["context"] for c in _components(self.page("inbox")).values()
               if c.get("action", {}).get("event", {}).get("name") == "mail_sync"]
        self.assertEqual(ctx, [{"account": "all"}], "几个邮箱一个按钮")
        self.assertIn("精选来源：2 个发件人", json.dumps(self.page("digest", {"range": "week"}), ensure_ascii=False))
        out = [c["action"]["event"]["context"] for c in _components(self.page("sources")).values()
               if c.get("action", {}).get("event", {}).get("name") == "mail_digest_source"]
        self.assertEqual([c["on"] for c in out], [False, False])

    def test_long_lists_stay_under_the_page_limit(self):
        """邮件助手一次给 200 项：页上只画前一段、能往后翻，不超过组件上限（负责人 11-15 点「全部」只看到「这一页画不了」）"""
        inbox = self.read()("data/inbox?account=all")
        one = dict(inbox["items"][0], open_url="https://mail.google.com/x")
        many = dict(inbox, items=[dict(one, id=i) for i in range(200)], more=False)
        msgs = self.page("inbox", {"list": "all"}, extra={"data/inbox?account=all&list=all": many})
        nxt = [c["action"]["event"]["context"] for c in _components(msgs).values()
               if c.get("action", {}).get("event", {}).get("context", {}).get("args", {}).get("cursor")]
        self.assertEqual(nxt[0]["args"]["cursor"], str(mail.INBOX_ROWS), "下一页从第 INBOX_ROWS 封起")
        act = self.read()("data/activity?account=all")
        row = dict(act["items"][0], undoable=True, undone=False,
                   mails=[{"id": 1, "subject": "s", "from": {"name": "n"}}])
        self.page("activity", extra={"data/activity?account=all": dict(act, items=[dict(row, log_id=i) for i in range(200)])})

    def test_a_sender_has_every_old_action(self):
        clean = self.read()("data/clean?account=all")
        key = clean["subscriptions"]["senders"][0]["key"]
        ev = self.events(self.page("sender", {"key": key}))
        for name in ("mail_sender_keep", "mail_sender_rule", "mail_digest_source", "mail_sender_history"):
            self.assertIn(name, ev)

    def test_opened_mail_has_all_ways_draft_and_rule(self):
        args = {"account": "me@company.example", "id": "4019"}
        uri = "data/mail?account=me%40company.example&id=4019"
        one = dict(self.read()(uri), ways=["draft", "archive", "trash", "flag", "skip"],
                   draft_text="王老师您好：周五下午可以。")
        msgs = self.page("mail", args, extra={uri: one})
        ev = self.events(msgs)
        for name in ("mail_draft", "mail_act", "mail_draft_save", "mail_change"):
            self.assertIn(name, ev)
        comps = _components(msgs)
        self.assertTrue(any(c.get("collapsed") for c in comps.values()), "改成别的处理方式收起来")
        self.assertTrue(any(c.get("variant") == "longText" for c in comps.values()), "草稿是几行高的框")

    def test_settings_more_and_rules(self):
        ev = self.events(self.page("settings", {"tab": "more"}))
        for name in ("mail_settings", "mail_learn", "mail_site"):
            self.assertIn(name, ev)
        self.assertIn("mail_rule_add", self.events(self.page("settings", {"tab": "rules"})))
        self.assertIn("mail_set_own", self.events(self.page("settings", {"tab": "accounts"})))

    def test_change_drops_only_this_one(self):
        self.assertEqual(mail.action("mail_change", {"account": "a", "ids": [1], "action": ["archive"], "remember": ["none"]}),
                         ("mail_change", {"account": "a", "ids": [1], "action": "archive"}))
        self.assertEqual(mail.action("mail_change", {"account": "a", "ids": [1], "action": ["ignore"], "remember": ["sender"]})[1]["remember"],
                         "sender")


SPOKEN = ("你", "我", "别再", "别提", "别点", "还没", "看看", "一下", "等你", "清出", "就好", "吗？")


def _card_words(card):
    comps = _components(card)
    texts = [c["text"] for c in comps.values() if c["component"] == "Text"]
    events = [(c["action"]["event"]["name"], c["action"]["event"]["context"]) for c in comps.values() if c["component"] == "Button"]
    return texts, events


class MailOldPagesTest(unittest.TestCase):
    def test_the_mail_tool_s_old_pages_lead_to_the_built_ones(self):
        class Src:
            source = "luoke-mail"
            data = sorted({n for needs in mail.PAGE_NEEDS.values() for n in needs})
        self.assertEqual(apppages.alias(Src, "legacy-settings"), "settings")
        self.assertEqual(apppages.alias(Src, "sweep"), "clean")
        self.assertEqual(apppages.alias(Src, "inbox"), "inbox")
        Src.data = []
        self.assertEqual(apppages.alias(Src, "legacy-settings"), "legacy-settings", "核心拼不出来的照旧去它自己的页")


class ScanDiskRowTest(unittest.TestCase):
    def test_the_status_page_says_how_this_mac_is(self):
        """原来的「状态」页（负责人 11-17）：硬盘用量带一条进度、没开的安全设置逐项、大文件、病毒库；概览里不重复硬盘"""
        d = {"scanned": {"finished": "2026-11-10T17:00:00+08:00"}, "disk": {"free": 460_800_000_000, "total": 2_000_000_000_000},
             "attention": {"count": 2, "items": [{"rule": "posture.firewall", "severity": "medium"},
                                                  {"rule": "malware.eicar", "severity": "high", "urgent": True}]},
             "largeFiles": {"count": 14, "bytes": 23_070_000_000}, "virusDb": {"version": "27812", "date": "2026-11-09"}}
        msgs = scan.build("status", {}, lambda u: d)
        a2ui.build(msgs, page=True)
        comps = _components(msgs)
        text = json.dumps(msgs, ensure_ascii=False)
        self.assertIn("已用 1.54 TB，共 2 TB", text)
        self.assertIn("可用 460.8 GB", text)
        bar = next(c for c in comps.values() if c["component"] == "ProgressBar")
        self.assertAlmostEqual(bar["value"], 0.7696, places=3)
        self.assertIn("安全设置 · 1 项未开启", text)
        self.assertIn("防火墙未开启", text)
        self.assertNotIn("疑似病毒", text, "不是系统设置的不在这一页")
        self.assertIn("14 个，共 23.07 GB", text)
        self.assertIn("27812 · 2026-11-09", text)
        self.assertIn("状态", [p["title"] for p in scan.PAGES if not p.get("hidden")])
        self.assertNotIn("硬盘", json.dumps(scan.build("overview", {}, lambda u: d), ensure_ascii=False), "概览里不重复")
        empty = json.dumps(scan.build("status", {}, lambda u: {}), ensure_ascii=False)
        self.assertIn("暂时无法读取硬盘用量", empty)
        self.assertIn("尚未检查", empty)

    def test_checks_skipped_before_access_was_given_ask_for_a_rescan_not_for_access(self):
        def page(fda):
            d = {"scanned": {"finished": "2026-11-17T11:32:00+08:00"}, "fullDiskAccess": fda,
                 "skipped": [{"rule": f"r{i}", "reason": "fda"} for i in range(12)]}
            return json.dumps(scan.build("overview", {}, lambda u: d), ensure_ascii=False)
        self.assertIn("12 项无法检查", page("denied"))
        self.assertIn("打开系统设置", page("denied"))
        now = page("granted")
        self.assertIn("12 项上次未检查", now)
        self.assertNotIn("打开系统设置", now, "权限已经开了：不再让去系统设置")
        self.assertNotIn("无法检查", now)


class ScanDataCardsTest(unittest.TestCase):
    """扫描的事项和动作结果照它带的 `data` 写（顶层 ADR 0028）：句子、按钮上的字是 agent 的，参数照数据给的发"""

    def words(self, data):
        w = scan.item(data, "s-1")
        self.assertIsNotNone(w, data)
        a2ui.build(w["card"])
        texts, events = _card_words(w["card"])
        for t in texts + [w["title"], w["summary"], w["why_now"]]:
            self.assertFalse(any(x in t for x in SPOKEN), t)
        return w, texts, events

    def test_malware(self):
        w, texts, events = self.words({"type": "malware", "finding": "malware.clamav/1", "name": "a.com", "place": "downloads",
                                       "plan": {"id": "p-1", "key": "i0"}})
        self.assertEqual(w["title"], "下载中的「a.com」疑似病毒")
        self.assertEqual(events, [("scan_apply", {"plan_id": "p-1", "choices": {"i0": ["trash"]}}),
                                  ("scan_ignore", {"finding_id": "malware.clamav/1"})])
        w, _, events = self.words({"type": "malware", "finding": "f", "name": "a.com", "place": "", "plan": None})
        self.assertEqual((w["title"], [e[0] for e in events]), ("「a.com」疑似病毒", ["scan_ignore"]), "移不了：只有标为误报")

    def test_a_new_startup_item_by_where_it_comes_from(self):
        base = {"type": "startup-new", "finding": "persistence.new/1", "submitted": False, "app": "", "program": "odd",
                "reveal": True, "stop": None, "settings": False}
        w, texts, events = self.words(dict(base, scope="user-agent", stop={"id": "p-2", "key": "i0"}))
        self.assertEqual(w["title"], "新增开机启动项「odd」")
        self.assertIn("可停用", texts[1])
        self.assertEqual(events, [("scan_ignore", {"finding_id": "persistence.new/1"}), ("scan_reveal", {"finding_id": "persistence.new/1"}),
                                  ("scan_apply", {"plan_id": "p-2", "choices": {"i0": ["trash"]}})])
        w, texts, events = self.words(dict(base, scope="login-item", app="Example Sync", settings=True))
        self.assertEqual(w["title"], "新增开机启动项「Example Sync」")
        self.assertIn(("scan_open_settings", {"grant": "登录项"}), events)
        self.assertIn("登录项与扩展", texts[1])
        _, texts, _ = self.words(dict(base, scope="cron"))
        self.assertIn("自行添加", texts[1])
        _, texts, _ = self.words(dict(base, scope="daemon"))
        self.assertIn("需输入密码", texts[1])
        w, texts, events = self.words(dict(base, scope="login-item", submitted=True, app="Chat", program="Updater"))
        self.assertEqual(w["title"], "「Chat」在后台启动了程序「Updater」")
        self.assertIn("重启后不会自动启动", texts[1])
        self.assertNotIn("scan_open_settings", [e[0] for e in events], "交给系统运行的不在登录项里")
        w, _, _ = self.words(dict(base, scope="x", submitted=True, program=""))
        self.assertEqual(w["title"], "后台出现新程序")

    def test_a_malicious_package(self):
        d = {"type": "malicious-package", "finding": "f", "package": "left-pad-evil", "count": 3, "more": False, "reveal": True}
        w, _, events = self.words(d)
        self.assertEqual(w["title"], "3 处使用了已知恶意软件包「left-pad-evil」")
        self.assertEqual([e[0] for e in events], ["scan_reveal", "scan_ignore"])
        self.assertEqual(self.words(dict(d, count=1))[0]["title"], "使用了已知恶意软件包「left-pad-evil」")
        w, _, events = self.words(dict(d, more=True, count=12, package="", reveal=False))
        self.assertEqual((w["title"], [e[0] for e in events]), ("另有 12 个已知恶意软件包", ["scan_ignore"]))

    def test_low_space(self):
        d = {"type": "space-low", "free": 4_000_000_000, "total": 494_000_000_000, "swap": 2_000_000_000, "caches": 62_914_560,
             "plan": {"id": "p-3", "choices": {"i0": ["remove"], "i1": ["remove"]}}}
        w, texts, events = self.words(d)
        self.assertEqual(w["title"], "可用空间仅剩 4 GB")
        self.assertEqual(events, [("scan_apply", {"plan_id": "p-3", "choices": {"i0": ["remove"], "i1": ["remove"]}})])
        self.assertIn("62.9 MB", texts[1])
        w, texts, events = self.words(dict(d, plan=None, swap=None))
        self.assertEqual((texts[1], events), ("磁盘共 494 GB", []))
        self.assertIsNone(scan.item(dict(d, free=None), "s"), "没有数：照扫描自己的")

    def test_what_is_not_known_falls_back(self):
        self.assertIsNone(scan.item({"type": "brand-new"}, "s"))
        self.assertIsNone(scan.item({"type": "needs-access", "permission": "camera"}, "s"))
        self.assertIsNone(scan.result("scan_x", {"type": "brand-new"}, "s", True))
        self.assertIsNone(scan.result("scan_apply", {"type": "applied", "password": True}, "s", True),
                          "要密码的那份方案还等着：这张卡片 agent 画不了，照扫描的")

    def test_sizes_are_written_as_the_finder_writes_them(self):
        self.assertEqual([scan.size(n) for n in (0, 999, 1000, 62_914_560, 601_800_000, 6_440_000_000, 999_950_000)],
                         ["0 KB", "999 字节", "1 KB", "62.9 MB", "601.8 MB", "6.44 GB", "1 GB"])

    def test_answers(self):
        applied = {"type": "applied", "moved": {"count": 2, "bytes": 131_072_000}, "removed": {"count": 1, "bytes": 62_914_560},
                   "cloned": {"count": 0, "bytes": 0}, "links": 0, "scriptsOff": 0, "partly": 1, "ignored": 0, "gone": 0,
                   "skipped": 0, "unchanged": 0, "left": ["Xcode 的缓存：未删完"], "trashed": True, "restore": "p-9",
                   "retry": {"plan": "p-9", "choices": {"i0": ["trash"]}}, "unrecorded": ["x.dmg"], "password": False, "round": None}
        r = scan.result("scan_apply", applied, "s-1", True)
        self.assertEqual(r["text"], "已移到废纸篓 2 项（131.1 MB），已删除可重建的缓存 1 项（释放 62.9 MB），1 项部分完成。Xcode 的缓存：未删完")
        texts, events = _card_words(r["card"])
        self.assertIn("清空废纸篓后才真正释放空间", texts)
        self.assertEqual(events, [("scan_apply", {"plan_id": "p-9", "choices": {"i0": ["trash"]}}), ("scan_restore", {"id": "p-9"})])
        self.assertNotIn("createSurface", json.dumps(r["card"]), "换掉原来那张卡片，不新建")
        self.assertEqual(scan.result("scan_apply", applied, "page", False), {"text": r["text"]}, "页上点的：只有那一句")
        nothing = dict(applied, moved={"count": 0, "bytes": 0}, removed={"count": 0, "bytes": 0}, partly=0, left=[], trashed=False,
                       restore=None, retry=None, unrecorded=[])
        self.assertEqual(scan.result("scan_apply", nothing, "s", False)["text"], "未作改动")
        self.assertEqual(scan.result("scan_restore", {"type": "restored", "back": 3, "left": 1, "before": 2, "notes": [], "round": None},
                                     "s", False)["text"], "已恢复 3 项，1 项未恢复，2 项此前已恢复")
        ig = scan.result("scan_ignore", {"type": "ignored", "finding": "f", "undo": False, "rule": "apps.unsigned", "name": ""}, "s", True)
        self.assertEqual(ig["text"], "来源不明的应用不再提醒")
        self.assertEqual(_card_words(ig["card"])[1], [("scan_ignore", {"finding_id": "f", "undo": True})])
        self.assertEqual(scan.result("scan_ignore", {"type": "ignored", "finding": "f", "undo": True, "rule": "", "name": "a.com"},
                                     "s", False)["text"], "已撤销，「a.com」会继续提醒")
        on = scan.result("scan_autoclean", {"type": "autoclean", "on": True, "kinds": ["cache", "temp"], "keptOff": ["installer"],
                                            "round": None}, "s", False)["text"]
        self.assertEqual(on, "已开启自动清理：可重建的缓存、测试工具遗留的临时文件夹检查到即清理，移到废纸篓的可恢复；已安装应用的安装包曾被恢复，仍先询问")
        self.assertEqual(scan.result("scan_now", {"type": "scan-started", "already": False}, "s", False)["text"], "检查已开始，通常需要几分钟")
        self.assertEqual(scan.result("scan_open_settings", {"type": "opened", "what": "LoginItems", "activityMonitor": False}, "s", False)["text"],
                         "已打开系统设置")
        for t in (r["text"].split("。")[0], on, ig["text"]):
            self.assertFalse(any(x in t for x in SPOKEN), t)

    def test_the_tool_source_draws_from_data_and_keeps_the_tools_own_otherwise(self):
        from luoke_agent import cards
        from luoke_agent.toolsource import ToolSource
        src = ToolSource("luoke-scan", os.path.join(tempfile.gettempdir(), "none", "agent.sock"))
        theirs = cards.Card("security-abc")
        theirs.heading("下载里的「a.com」可能是病毒")
        raw = {"id": "security/1", "kind": "security", "urgency": "urgent", "title": "下载里的「a.com」可能是病毒", "summary": "…",
               "why_now": "这一轮刚认出来；建议先不要打开", "card": theirs.messages(),
               "data": {"type": "malware", "finding": "malware.clamav/1", "name": "a.com", "place": "downloads", "plan": None}}
        it = src._item(raw)
        self.assertEqual((it.title, it.why_now), ("下载中的「a.com」疑似病毒", "本轮检查新识别"))
        self.assertEqual(it.card[0]["createSurface"]["surfaceId"], "security-abc", "还是扫描那张卡片的 surfaceId：点按照旧交给它")
        for data in (None, {"type": "brand-new"}, "x"):
            it = src._item(dict(raw, data=data))
            self.assertEqual(it.title, "下载里的「a.com」可能是病毒", "没带 data、认不出：照扫描带的")
        out = {"text": "移到废纸篓 1 项（4 KB）。", "card": ["theirs"]}
        src._own_result(out, "scan_ignore", {"type": "ignored", "finding": "f", "undo": False, "rule": "", "name": "a.com"}, "security-abc", True)
        self.assertEqual(out["text"], "「a.com」不再提醒")
        self.assertEqual(out["card"][0]["updateComponents"]["surfaceId"], "security-abc")
        out = {"text": "原来的", "card": ["theirs"]}
        src._own_result(out, "scan_x", {"type": "brand-new"}, "s", True)
        self.assertEqual(out, {"text": "原来的", "card": ["theirs"]})


class SearchDataCardsTest(unittest.TestCase):
    """搜索的事项照它带的 `data` 写；搜索结果上的类型、位置、按钮，点按后的那一句，照代号和点的是什么写（顶层 ADR 0028）"""

    def words(self, data):
        w = search.item(data, "s-1")
        self.assertIsNotNone(w, data)
        a2ui.build(w["card"])
        texts, events = _card_words(w["card"])
        for t in texts + [w["title"], w["summary"], w["why_now"]]:
            self.assertFalse(any(x in t for x in SPOKEN), t)
        return w, texts, events

    def test_setup(self):
        d = {"type": "needs-setup", "plan": "plan-1", "protected": True, "choices": [
            {"key": "folder0", "on": True, "photos": False, "place": "home", "name": ""},
            {"key": "folder1", "on": True, "photos": False, "place": "", "name": "资料"},
            {"key": "photos", "on": False, "photos": True, "place": "", "name": ""}]}
        w, texts, events = self.words(d)
        self.assertEqual(w["title"], "尚未选择检索范围")
        comps = _components(w["card"])
        boxes = [(c["label"], c["value"]["path"]) for c in comps.values() if c["component"] == "CheckBox"]
        self.assertEqual(boxes, [("个人文件夹", "/checks/folder0"), ("资料", "/checks/folder1"),
                                 ("照片图库中的照片和视频（需允许读取照片）", "/checks/photos")])
        model = next(m["updateDataModel"]["value"] for m in w["card"] if "updateDataModel" in m)
        self.assertEqual(model["checks"], {"folder0": True, "folder1": True, "photos": False}, "默认勾选照数据给的")
        self.assertEqual(events, [("search_settings_apply", {"plan_id": "plan-1", "checks": {"path": "/checks"}}), ("agent.dismiss", {})])
        self.assertIn("macOS 会先询问是否允许读取这些文件夹", texts)
        self.assertIsNone(search.item(dict(d, choices=[]), "s"))

    def test_access_and_ready(self):
        w, _, events = self.words({"type": "needs-access", "what": "folder", "pane": "files", "place": "downloads", "name": ""})
        self.assertEqual((w["title"], events), ("无法读取「下载」", [("search_open_system_settings", {"pane": "files"})]))
        w, _, events = self.words({"type": "needs-access", "what": "photos", "pane": "photos", "refused": False})
        self.assertEqual((w["title"], [e[0] for e in events]), ("需要允许读取照片图库", ["search_open_system_settings", "agent.dismiss"]))
        w, _, _ = self.words({"type": "needs-access", "what": "photos", "pane": "photos", "refused": True})
        self.assertEqual(w["title"], "无法读取照片图库")
        w, texts, events = self.words({"type": "index-ready", "total": 4035, "waiting_for_media": 0, "not_on_this_mac": 3})
        self.assertEqual((texts[1], events), ("已索引 4035 个文件，另有 3 个文件不在这台 Mac 上，回到本机后再读取", []))
        self.assertIsNone(search.item({"type": "brand-new"}, "s"))

    def test_a_hit_is_worded_from_codes(self):
        h = {"id": "1", "title": "a.pdf", "kind": "pdf", "kind_label": "PDF 文档", "line": "第三页", "where": {"page": 3},
             "actions": [{"name": "search_open", "title": "打开看看", "args": {"id": "1"}, "primary": True},
                         {"name": "search_open", "title": "在访达里显示", "args": {"id": "1", "reveal": True}},
                         {"name": "search_similar", "title": "找相似的", "args": {"id": "1"}}]}
        out = search.hit_words(h)
        self.assertEqual((out["kind_label"], out["line"]), ("PDF", "第 3 页"))
        self.assertEqual([a["title"] for a in out["actions"]], ["打开", "在访达中显示", "找相似的"], "不认识的动作照搜索给的")
        self.assertEqual(search.hit_words(dict(h, kind="video", where={"time": 65.4}))["line"], "1:05")
        self.assertEqual(search.hit_words(dict(h, kind="sheet", where={"sheet": 2}))["line"], "第 2 个工作表")
        self.assertEqual(search.hit_words({"id": "2", "title": "x", "kind": "other", "kind_label": "别的", "line": "原来的", "actions": []})["line"],
                         "原来的", "没给位置：照搜索带的")
        from luoke_agent import apppages, searchhits
        kept = searchhits.hit(dict(h, where={"page": 3, "bad": "x", "time": True}))
        self.assertEqual(kept["where"], {"page": 3}, "位置只留认得的、是数的")
        self.assertNotIn("where", searchhits.for_window([kept])[0], "位置不交给窗口，那一行字核心写好了")
        self.assertEqual(apppages.hit_words("luoke-mail", h), h, "别的应用的结果原样")

    def test_a_video_s_length_goes_to_the_window_as_a_number(self):
        from luoke_agent import searchhits
        base = {"id": "1", "title": "a.mov", "kind": "video", "actions": []}
        kept = searchhits.hit(dict(base, duration=83.4))
        self.assertEqual(searchhits.for_window([kept])[0]["duration"], 83.4)
        for bad in ("83", True, -1, float("inf"), float("nan"), 10 ** 9, None):
            self.assertNotIn("duration", searchhits.hit(dict(base, duration=bad)), repr(bad))

    def test_what_a_tap_did_is_said_by_the_agent(self):
        say = lambda ctx, name="search_settings_apply", r=None: search.said(name, ctx, r or {})   # noqa: E731
        self.assertEqual([say({"files": True}), say({"files": False}), say({"photos": True}), say({"mode": "manual"}),
                          say({"index_now": True}), say({"clear_recent": True}), say({"unskip": "s1"}), say({"plan_id": "p", "checks": {}})],
                         ["已开启文件搜索", "已关闭文件搜索，已读取的内容保留", "已开启照片搜索", "已改为手动建立索引", "已开始建立索引",
                          "已清除最近搜索", "已取消跳过，其中的内容将在后台读取", "检索范围已保存，新加入的位置将在后台建立索引"])
        self.assertEqual(say({"id": "1", "reveal": True}, "search_open"), "已在访达中显示")
        self.assertIsNone(say({"files": True}, r={"error": True}), "没做成：照搜索说的")
        from luoke_agent.toolsource import ToolSource
        src = ToolSource("luoke-search", os.path.join(tempfile.gettempdir(), "none", "agent.sock"))
        out = {"text": "好了，设置改好了。", "done": True, "card": ["theirs"]}
        src._own_said(out, "search_settings_apply", {"plan_id": "p"}, "s-p")
        self.assertEqual(out["text"], "检索范围已保存，新加入的位置将在后台建立索引")
        self.assertEqual(out["card"][0]["updateComponents"]["surfaceId"], "s-p", "做完的结果卡片也只写这一句")
        mem_src = ToolSource("luoke-mem", os.path.join(tempfile.gettempdir(), "none", "agent.sock"))
        out = {"text": "记下了：对。", "done": True, "card": ["theirs"]}
        mem_src._own_said(out, "mem_reply", {"choice": "yes"}, "ask-1")
        self.assertEqual(out["text"], "已确认", "记忆的卡片上点完的那一句也由核心写（11-17）")
        mail_src = ToolSource("luoke-mail", os.path.join(tempfile.gettempdir(), "none", "agent.sock"))
        out = {"text": "归档了 1 封。", "done": True, "card": ["theirs"]}
        mail_src._own_said(out, "mail_apply_plan", {}, "m-1")
        self.assertEqual(out, {"text": "归档了 1 封。", "done": True, "card": ["theirs"]}, "没声明的应用：卡片上的点按照它自己的")
