"""占空间的文件的用途说明（luoke_agent/explain.py）和扫描「状态」页上的那一行。"""
from __future__ import annotations

import json
import os
import sys
import threading
import types
import unittest
from unittest import mock

from luoke_agent import a2ui, explain, runner
from luoke_agent.apppages import scan

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, os.path.join(ROOT, "bench"))
import explain_set  # noqa: E402
import run_explain  # noqa: E402
ITEMS = [{"path": "/Users/user/Downloads/a.dmg", "bytes": 3 << 30, "lastOpened": "2025-09-15"},
         {"path": "/Users/user/Movies/b.mp4", "bytes": 2 << 30, "neverOpened": True, "lastChanged": "2019-09-03"}]


def answer(*rows):
    return json.dumps({"items": [{"n": n, "use": use, "verdict": v} for n, use, v in rows]}, ensure_ascii=False)


class ExplainTest(unittest.TestCase):
    def test_the_model_sees_paths_sizes_and_dates_only(self):
        user = explain.messages(ITEMS, home="/Users/user")[1]["content"]
        self.assertIn("1. ~/Downloads/a.dmg · 3.0 GB · 2025-09-15 后未打开", user)
        self.assertIn("2. ~/Movies/b.mp4 · 2.0 GB · 从未打开，2019-09-03 修改", user)

    def test_only_answers_that_follow_the_rules_are_kept(self):
        got = explain.parse(answer((1, "系统安装程序的备份。", "safe"), (2, "建议删除的视频", "careful"), (3, "没有这一项", "safe")), ITEMS)
        self.assertEqual(got, {explain.key(ITEMS[0]["path"], ITEMS[0]["bytes"]): {"use": "系统安装程序的备份", "verdict": "safe"}},
                         "句号去掉；劝人做事的、编号不对的不要")
        self.assertEqual(explain.parse("不是 JSON", ITEMS), {})
        self.assertEqual(explain.parse(answer((1, "x" * 40, "safe"), (2, "见 https://a.b", "safe"), (2, "视频", "delete")), ITEMS), {})
        self.assertEqual(explain.parse(answer((1, "路径 ~/Downloads/a.dmg", "safe")), ITEMS), {}, "照抄路径的不要")

    def test_the_verdict_words_are_the_agents(self):
        self.assertEqual(explain.words({"use": "毕业典礼的录像", "verdict": "careful"}), "毕业典礼的录像 · 清理前请确认是否仍需要")
        self.assertIsNone(explain.words({"use": "x", "verdict": "delete"}))
        self.assertIsNone(explain.words(None))


class StatusPageTest(unittest.TestCase):
    def setUp(self):
        with open(os.path.join(ROOT, "fixtures", "apppages", "luoke-scan", "built.json"), encoding="utf-8") as f:
            self.data = json.load(f)["data"]

    def page(self, data=None):
        data = self.data if data is None else data
        msgs = scan.build("status", {}, lambda u: data[u])
        a2ui.build(msgs, page=True)
        return json.dumps(msgs, ensure_ascii=False)

    def test_folders_and_large_files_say_what_they_are(self):
        text = self.page()
        self.assertIn("占用最多的文件夹", text)
        self.assertIn("开发工具缓存", text)
        self.assertIn("已卸载应用的残留数据（5 个应用）", text)
        self.assertIn("358.6 MB", text)
        # 样例里扫描量全了：差额单列「未统计的占用」，不再写「以上合计」
        self.assertIn("未统计的占用", text)
        self.assertIn("311.28 GB", text)
        self.assertNotIn("以上合计约", text)
        self.assertIn("微信数据", text)
        self.assertIn("版本 27000 · 2026年10月20日更新", text, "病毒库那一行写明两个数各是什么（#173）")
        self.assertEqual(scan._summary({"id": "cache", "count": 3, "facts": {"tools": ["Go", "SwiftPM", "npm"]}}).split("，")[0],
                         "Go、SwiftPM、npm 缓存", "英文名字后面空一格（#173）")
        self.assertTrue(scan._summary({"id": "cache", "count": 1, "facts": {"apps": ["微信"]}}).startswith("微信缓存，"))
        self.assertIn("Microsoft Teams 缓存", text)
        # 旧版本的扫描没有 data/usage：照旧从它原来那一页读
        old = self.page({k: v for k, v in self.data.items() if k != "data/usage"})
        self.assertIn("以上合计约 712 MB", old)
        self.assertIn("已卸载应用的残留数据（5 个应用）", old)
        self.assertIn("macOS 系统安装程序的备份 · 可清理，需要时可重新获取", text)
        self.assertIn("下载 · 2025年9月15日后未打开", text, "日期带年份")
        self.assertIn("scan_reveal", text)
        self.assertIn("全部 3 个", text)
        msgs = scan.build("status", {}, lambda u: self.data[u])
        comps = {c["id"]: c for m in msgs for c in (m.get("updateComponents") or {}).get("components", [])}
        trash = [c for c in comps.values() if c.get("component") == "Button" and c["action"]["event"]["name"] == "scan_apply"]
        self.assertEqual(len(trash), 3, "每个大文件能直接移到废纸篓")
        for c in trash:
            ctx = c["action"]["event"]["context"]
            self.assertEqual(list(ctx["choices"].values()), [["trash"]], "只动这一个，只移到废纸篓")
            self.assertEqual(c["confirm"]["label"], "移到废纸篓", "先弹确认")
            self.assertEqual(scan.action("scan_apply", ctx), ("scan_apply", ctx), "原样交给扫描")
        opens = [c["action"]["event"]["context"]["args"].get("id") for c in comps.values() if c.get("component") == "Button"
                 and c["action"]["event"]["name"] == "agent.open_page"]
        self.assertIn("cache", opens, "能清的文件夹点进那一类的清单")
        self.assertIn("含可清理的缓存", text)
        self.assertEqual(scan._folder_cat("图片"), "", "用户自己的文件夹没有能点的")

    def test_without_the_old_page_or_explanations_the_rows_are_plain(self):
        data = {k: v for k, v in self.data.items() if k not in ("page/mac", "data/usage", "agent/explained")}
        text = self.page(data)
        self.assertNotIn("占用最多的文件夹", text)
        self.assertNotIn("可清理，需要时可重新获取", text)
        self.assertIn("2025年9月15日后未打开", text)


class RunnerTest(unittest.TestCase):
    def fake(self, items, known=None):
        saved = {}
        agent = types.SimpleNamespace(
            sources={"luoke-scan": types.SimpleNamespace(data=["overview", "category"], client=types.SimpleNamespace(
                read_json=lambda u: {"items": items}))},
            explained=lambda: dict(known or {}), set_explained=lambda got, limit: saved.update(got), explain_poke=False,
            explain_wanted=lambda: [])
        me = types.SimpleNamespace(hub="/nowhere", next_explain=0.0, _explain_thread=None, agent=agent, stopping=threading.Event(),
                                   clock=lambda: 1000.0, _explain_tried=set())
        agent.explaining = False
        me._explain = lambda todo, looking=False: runner.Runner._explain(me, todo, looking)
        me._explain_once = lambda todo, looking: runner.Runner._explain_once(me, todo, looking)
        return me, saved

    def test_unexplained_files_are_asked_about_in_the_background(self):
        items = [{"path": it["path"], "bytes": it["bytes"], "facts": {k: v for k, v in it.items() if k not in ("path", "bytes")}}
                 for it in ITEMS]
        me, saved = self.fake(items, known={explain.key(ITEMS[0]["path"], ITEMS[0]["bytes"]): {"use": "x", "verdict": "safe"}})
        asked, waits = [], []

        class Hub:
            def __init__(self, path):
                pass

            def chat(self, task, messages, schema, **kw):
                waits.append(bool(kw.get("waiting")))
                asked.append(messages[1]["content"])
                return answer((1, "视频文件", "careful"))

        with mock.patch.object(runner.hubmod, "Hub", Hub):
            runner.Runner.maybe_explain(me, 10.0)
            me._explain_thread.join(5)
        self.assertEqual(len(asked), 1)
        self.assertNotIn("a.dmg", asked[0], "说明过的不再问")
        self.assertEqual(saved, {explain.key(ITEMS[1]["path"], ITEMS[1]["bytes"]): {"use": "视频文件", "verdict": "careful"}})
        self.assertEqual(me._explain_tried, set())
        # 用户刚点开一个文件夹：不等到点，先问那里面的；没答好的这次运行里不再问
        me3, saved3 = self.fake(items)
        me3.next_explain = 99999.0
        me3.agent.explain_poke = True
        me3.agent.explain_wanted = lambda: [{"path": "/Users/user/Codes/big", "bytes": 5 << 30, "lastChanged": "2025-01-02",
                                             "dir": True, "contains": ["model.bin"]}]
        asked.clear()
        with mock.patch.object(runner.hubmod, "Hub", Hub):
            runner.Runner.maybe_explain(me3, 10.0)
            me3._explain_thread.join(5)
        self.assertIn("1. ~/Codes/big · 5.0 GB · 2025-01-02 修改 · 文件夹，里面有：model.bin", asked[0].replace("/Users/user", "~"))
        self.assertEqual(waits, [False, True], "扫描的大文件当后台任务；用户正看着的文件夹不排在后面")
        self.assertTrue(me3.agent.explain_poke, "问到了：接着问这个文件夹里剩下的")
        self.assertFalse(me3.agent.explaining)
        self.assertEqual(len(me3._explain_tried), 2, "这一批里没答好的两项记下")
        me2, saved2 = self.fake([])
        runner.Runner.maybe_explain(me2, 10.0)
        self.assertIsNone(me2._explain_thread, "没有要说明的不问模型")
        self.assertGreater(me2.next_explain, 1000.0)


class BenchTest(unittest.TestCase):
    def test_the_set_is_fixed_and_every_batch_fits_one_request(self):
        cases = explain_set.cases()
        self.assertEqual(run_explain.set_hash(cases), run_explain.set_hash(explain_set.cases()), "固定的种子：集合不变")
        self.assertEqual(sum(len(c["items"]) for c in cases), len(explain_set.ITEMS))
        self.assertTrue(all(len(c["items"]) <= explain.MAX_ITEMS for c in cases))
        self.assertIn("~/", explain.messages([r["item"] for r in cases[0]["items"]], home=run_explain.HOME)[1]["content"])

    def test_calling_a_users_file_safe_or_leaking_a_marker_fails(self):
        case = explain_set.cases()[0]
        def raw(verdict, use=lambda r: "某个文件"):
            return json.dumps({"items": [{"n": i, "use": use(r), "verdict": verdict(r)}
                                         for i, r in enumerate(case["items"], 1)]}, ensure_ascii=False)
        good = run_explain.judge(case, raw(lambda r: "safe" if r["kind"] == "regen" else "careful"))
        self.assertEqual(good["hard"], [])
        self.assertTrue(all(it["shown"] for it in good["items"]))
        bad = run_explain.judge(case, raw(lambda r: "safe"))
        self.assertEqual(len(bad["hard"]), sum(1 for r in case["items"] if r["kind"] != "regen"))
        leak = run_explain.judge(case, raw(lambda r: "keep", lambda r: "口令 " + explain_set.NEVER[0]))
        self.assertTrue(all(h.startswith("never:") for h in leak["hard"]) and leak["hard"])
        self.assertEqual(run_explain.judge(case, "不是 JSON")["hard"], ["form"])
        s = run_explain.score([{"id": "b", "runs": [good]}], len(case["items"]))
        self.assertTrue(s["passed"])
        self.assertEqual(s["soft"]["answered"], 1.0)


if __name__ == "__main__":
    unittest.main()
