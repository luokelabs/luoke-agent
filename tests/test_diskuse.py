"""文件夹里什么最占地方（luoke_agent/diskuse.py）、扫描的「文件夹」页、在访达中显示。"""
from __future__ import annotations

import json
import os
import shutil
import tempfile
import unittest

from luoke_agent import a2ui, diskuse, replay_tool
from luoke_agent.apppages import scan

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))


def write(path: str, n: int) -> None:
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "wb") as f:
        f.write(b"x" * n)


class UsageTest(unittest.TestCase):
    def setUp(self):
        self.tmp = os.path.realpath(tempfile.mkdtemp())
        self.addCleanup(shutil.rmtree, self.tmp, True)
        self.home = os.path.join(self.tmp, "home")
        write(os.path.join(self.home, "Codes", "big", "model.bin"), 300_000)
        write(os.path.join(self.home, "Codes", "small", "a.txt"), 10)
        write(os.path.join(self.home, "Codes", "note.md"), 5_000)
        write(os.path.join(self.tmp, "outside", "secret.txt"), 10)
        os.symlink(os.path.join(self.tmp, "outside"), os.path.join(self.home, "Codes", "link"))
        self.usage = diskuse.Usage(home=self.home)

    def test_the_largest_come_first_and_links_are_not_followed(self):
        first = self.usage.look("~/Codes")
        self.assertIn(first["state"], ("measuring", "done"))
        self.usage.wait()
        u = self.usage.look("~/Codes")
        self.assertEqual(u["state"], "done")
        self.assertEqual([i["name"] for i in u["items"]][:2], ["big", "note.md"])
        big = u["items"][0]
        self.assertTrue(big["dir"])
        self.assertGreaterEqual(big["bytes"], 300_000)
        self.assertEqual(big["path"], "~/Codes/big")
        self.assertEqual(big["contains"], ["model.bin"])
        self.assertEqual(big["key"], f"{self.home}/Codes/big|{big['bytes']}", "用途说明的编号用真实路径")
        link = next(i for i in u["items"] if i["name"] == "link")
        self.assertFalse(link["dir"], "符号链接不当文件夹量")
        self.assertEqual(u["count"], 4)
        self.assertIsNone(u["parent"], "家目录下的第一层没有上一级")
        self.assertEqual(self.usage.look("~/Codes/big")["parent"], "~/Codes")

    def test_only_folders_inside_home(self):
        for bad in ("/etc", "~/../outside", os.path.join(self.tmp, "outside"), "~/Codes/link", "~/nothing", "Codes", "", None):
            self.assertEqual(self.usage.look(bad)["state"], "gone", bad)
        self.assertIsNone(self.usage.resolve("~/Codes/link/secret.txt"), "链接指到家目录外面的不认")
        self.assertEqual(self.usage.resolve("~/Codes/note.md"), os.path.join(self.home, "Codes", "note.md"))


class FolderPageTest(unittest.TestCase):
    def setUp(self):
        with open(os.path.join(ROOT, "fixtures", "apppages", "luoke-scan", "built.json"), encoding="utf-8") as f:
            self.spec = json.load(f)

    def comps(self, msgs):
        return {c["id"]: c for m in msgs for c in (m.get("updateComponents") or {}).get("components", [])}

    def test_a_folder_lists_what_takes_the_most_and_only_looks(self):
        msgs = scan.build("folder", dict(self.spec["args"]["folder"]), lambda u: self.spec["data"][u])
        a2ui.build(msgs, page=True)
        text = json.dumps(msgs, ensure_ascii=False)
        self.assertIn("Final Cut Pro 的剪辑工程 · 清理前请确认是否仍需要", text)
        self.assertIn("文件 · 2019年10月5日修改", text)
        self.assertIn("此处仅供查看，删除请在访达中操作", text)
        events = [c["action"]["event"] for c in self.comps(msgs).values() if c.get("component") == "Button"]
        self.assertEqual({e["name"] for e in events}, {"agent.reveal", "agent.open_page"}, "没有会删东西的按钮")
        self.assertIn({"item": "~/Movies/TV"}, [e["context"] for e in events if e["name"] == "agent.reveal"])
        self.assertIn({"page": "folder", "args": {"dir": "~/Movies/TV"}}, [e["context"] for e in events])

    def test_measuring_rereads_and_a_missing_folder_says_so(self):
        busy = {"state": "measuring", "path": "~/Codes", "parent": None, "items": [], "count": 0, "bytes": 0, "partial": False}
        msgs = scan.build("folder", {"dir": "~/Codes"}, lambda u: busy if u.startswith("agent/usage") else {})
        a2ui.build(msgs, page=True)
        self.assertEqual(self.comps(msgs)["root"].get("refresh"), 3)
        self.assertIn("正在统计大小", json.dumps(msgs, ensure_ascii=False))
        gone = scan.build("folder", {"dir": "/etc"}, lambda u: {"state": "gone", "items": []})
        self.assertIn("无法打开此文件夹", json.dumps(gone, ensure_ascii=False))

    def test_growth_is_a_line_of_its_own(self):
        page = [{"updateComponents": {"components": [
            {"id": "root", "component": "Column", "children": ["t", "r"]},
            {"id": "t", "component": "Text", "text": "占地方最多的文件夹"},
            {"id": "r", "component": "Row", "children": ["a", "b", "p"]},
            {"id": "a", "component": "Text", "text": "Codes"},
            {"id": "b", "component": "Text", "text": "197.9 GB，这周多了 10.3 GB"},
            {"id": "p", "component": "ProgressBar", "value": 0.2}]}}]
        _, rows, _ = scan._mac_folders(lambda u: page)
        self.assertEqual(rows, [("Codes", "197.9 GB", 0.2, "", "~/Codes", "近 7 天增加 10.3 GB")])

    def test_rows_of_the_users_own_folders_open(self):
        self.assertEqual(scan._folder_path("图片"), "~/Pictures")
        self.assertEqual(scan._folder_path("Codes"), "~/Codes")
        self.assertEqual(scan._folder_path("omlx 的文件夹"), "~/.omlx")
        self.assertEqual(scan._folder_path("资源库里的「Audio」"), "~/Library/Audio")
        for unsure in ("开发工具的缓存", "微信的数据", "临时文件", "已经删掉的应用留下的数据（5 个应用）", "../x"):
            self.assertEqual(scan._folder_path(unsure), "", unsure)
        msgs = scan.build("status", {}, lambda u: self.spec["data"][u])
        opens = [c["action"]["event"]["context"] for c in self.comps(msgs).values() if c.get("component") == "Button"
                 and c["action"]["event"]["name"] == "agent.open_page"]
        self.assertIn({"page": "folder", "args": {"dir": "~/Movies"}}, opens)


class RevealTest(unittest.TestCase):
    """接着回放的扫描：点开文件夹页、点「在访达中显示」"""
    def setUp(self):
        self.tmp = os.path.realpath(tempfile.mkdtemp())
        self.addCleanup(shutil.rmtree, self.tmp, True)
        self.home = os.path.join(self.tmp, "home")
        write(os.path.join(self.home, "Codes", "big", "model.bin"), 300_000)
        self.s = replay_tool.Session(os.path.join(ROOT, "fixtures", "luoke-scan", "full-report"))
        self.addCleanup(self.s.close)
        self.s.run()
        self.agent = self.s.agent
        self.agent.usage = diskuse.Usage(home=self.home)
        self.shown = []
        self.agent.reveal_in_finder = self.shown.append

    def page(self):
        code, body = self.agent.page("luoke-scan", "folder", {"dir": "~/Codes"})
        self.assertEqual(code, 200)
        return body

    def test_reveal_shows_only_what_is_inside_home(self):
        self.page()
        self.agent.usage.wait()
        body = self.page()
        self.assertTrue(self.agent.explain_poke, "点开了文件夹、量出来了：用途说明早点来问")
        self.assertEqual([i["path"] for i in self.agent.explain_wanted()], [os.path.join(self.home, "Codes", "big")])
        root = next(c for m in body["messages"] for c in (m.get("updateComponents") or {}).get("components", []) if c["id"] == "root")
        self.assertEqual(root.get("refresh"), 5, "用途说明还在问：页面隔几秒重读")
        sid = "luoke-scan/page/folder"
        comps = self.agent.pages[sid][2].components
        reveal = next(cid for cid, c in comps.items() if c.get("component") == "Button"
                      and c["action"]["event"]["name"] == "agent.reveal")
        out = self.agent.tap(sid, reveal)
        self.assertFalse(out.get("error"), out)
        self.assertEqual(self.shown, [os.path.join(self.home, "Codes", "big")])
        self.assertTrue(self.agent._reveal({"item": "/etc/hosts"})["error"], "家目录外面的不显示")
        self.assertTrue(self.agent._reveal({"item": "~/Codes/gone"})["error"])
        self.assertEqual(len(self.shown), 1)


if __name__ == "__main__":
    unittest.main()
