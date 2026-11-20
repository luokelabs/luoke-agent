"""工具的场景样例（fixtures/<工具>/，工具录的真实答复）对着真核心（docs/工具协议.md「场景样例」）：

- 核心在窗口该看的那一刻问的，工具都录过答复；
- 在核心交给窗口的卡片和页上点样例里录的那几下，核心发给工具的和工具录下的一样；
- 卡片和页上的 `agent.open_page` 点了换到这个工具登记的页，参数照按钮写的，不交给工具；
- 窗口的示例（window/Sources/LuokeWindow/Resources/samples）跟得上样例。

不过就是两边对不上：看是工具改了（重新拷样例：scripts/sync-tool-fixtures.sh）还是核心改了。"""
from __future__ import annotations

import os as _os

assert _os.environ.get("LUOKE_AGENT_TESTING") == "1", "用 python3 -m unittest 跑：tests/__init__.py 先把一切指到临时目录"

import contextlib
import io
import os
import subprocess
import sys
import time
import unittest

from luoke_agent import apppages, a2ui, replay_tool

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SCENARIOS = replay_tool.scenarios(os.path.join(ROOT, "fixtures"))

# 工具录的和核心实际会发的不一样、已经告诉工具的。这里照样点一下：还不一样就跳过（这个场景后面的也不点），
# 一样了测试不过，提醒从这里删掉。
KNOWN: dict = {
    # (场景, 录音文件): 为什么对不上、告诉谁了
}


# 工具录的卡片现在由核心照原始数据换成了自己拼的那一件（apppages 的 `items`）：录的按钮不在了，不点
REPLACED = {
    ("luoke-mail/auto-done", "call-mail_undo-card.json"),    # 邮件「已自动处理」照 data/today 拼，撤销走 mail_undo_step
}


def name(sc: str) -> str:
    return os.path.relpath(sc, os.path.join(ROOT, "fixtures"))


def _event(surface, cid):
    try:
        return surface.button_event(cid)[0]
    except a2ui.CardError:
        return None


class ToolFixturesTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls._tz = os.environ.get("TZ")
        replay_tool.use_recording_timezone()

    @classmethod
    def tearDownClass(cls):
        if cls._tz is None:
            os.environ.pop("TZ", None)
        else:
            os.environ["TZ"] = cls._tz
        time.tzset()

    def session(self, sc: str) -> replay_tool.Session:
        s = replay_tool.Session(sc)
        self.addCleanup(s.close)
        return s

    def test_there_are_scenarios(self):
        self.assertIn("luoke-scan/first-run-no-fda", [name(sc) for sc in SCENARIOS], "fixtures/ 里要有扫描的样例")

    def test_core_asks_only_what_the_tool_recorded(self):
        for sc in SCENARIOS:
            with self.subTest(name(sc)):
                s = self.session(sc)
                with contextlib.redirect_stderr(io.StringIO()):   # 走到那一段之前样例没录的，核心会说一句
                    s.run()
                    s.snapshot()
                stage = s.replay.window_stage
                self.assertEqual([replay_tool.request_key(m) for m in s.replay.unmatched(stage=stage)], [],
                                 "核心问了工具没录的")
                self.assertEqual([x["file"] for x in s.replay.served if x["stage"] == stage and x["stale"]], [],
                                 "核心问的是点按之前的旧答复")
                self.assertIn("read-outbox", " ".join(s.replay.asked(stage)), "读了 outbox")

    def test_taps_send_what_the_tool_recorded(self):
        taps = 0
        for sc in SCENARIOS:
            s = self.session(sc)
            with contextlib.redirect_stderr(io.StringIO()):
                s.start()
                for rec in s.replay.writes():
                    page = ((rec["request"]["params"].get("_meta") or {}).get("ai.luoke/user-action") or {}).get("surfaceId")
                    if page and apppages.builds(s.source, page) is not None:
                        # 工具旧页上的点按：这一页现在由核心照原始数据拼（ADR 0028），录的按钮不在了。照录的发给工具，
                        # 后面的步骤才接得上（邮件 due：先在收件箱归档，「即将截止」的卡片才出来）
                        s.replay.handle(dict(rec["request"], id=f"setup-{rec['file']}"))
                        s.agent.poll()
                        continue
                    if (name(sc), rec["file"]) in REPLACED:
                        continue
                    with self.subTest(f"{name(sc)} {rec['file']}"):
                        before = len(s.replay.served)
                        r = s.tap_recorded(rec)
                        sent = [x for x in s.replay.served[before:] if x["request"].get("method") == "tools/call"
                                and replay_tool.is_write(x["request"])]
                        if not sent and r.get("text") == "此按钮已失效" and apppages.cards(s.source) is not None:
                            continue    # 这张卡片现在由核心照原始数据拼（apppages 的 `card`），工具录的按钮不在了
                        if (name(sc), rec["file"]) in KNOWN:
                            same = len(sent) == 1 and replay_tool.comparable(sent[0]["request"]) == \
                                replay_tool.comparable(rec["request"])
                            self.assertFalse(same, "对上了：从 KNOWN 里删掉这一条")
                            break
                        self.assertEqual(len(sent), 1, f"点了没交给工具：{r.get('text')}")
                        self.assertEqual(sent[0]["file"], rec["file"])
                        self.assertEqual(replay_tool.comparable(sent[0]["request"]), replay_tool.comparable(rec["request"]),
                                         "核心发给工具的和工具录下的不一样")
                        # 工具录的就是一次拒绝（记忆：没勾「我知道删了找不回来」、改成的话里有密码），核心照样说没做成
                        refused = bool(((rec.get("reply") or {}).get("result") or {}).get("isError"))
                        self.assertEqual(bool(r.get("error")), refused, r.get("text"))
                        taps += 1
                    s.agent.poll()   # 点完以后核心再读一遍（runner 平时一分钟内会读）
        self.assertGreaterEqual(taps, 1)

    def test_open_page_buttons_go_to_the_tools_own_pages(self):
        """核心交给窗口的卡片和页上的 `agent.open_page`（工具协议 §5；带 `args` 的是 §4 pageArgs）：点了换到这个工具登记的那一页，
        参数照按钮写的，不交给工具"""
        opened, with_args = 0, 0
        for sc in SCENARIOS:
            s = self.session(sc)
            with contextlib.redirect_stderr(io.StringIO()):
                s.run()
                s.snapshot()            # 每一页都取一遍：页上的按钮也点得到
            # 工具登记的页，加上核心照它的原始数据拼的页（ADR 0028，apppages）
            pages = {p["id"] for p in apppages.pages(s.source, s.source.service["pages"])}
            shown = [(sid, surface) for sid, (_key, surface) in s.agent.surfaces.items()] + \
                    [(sid, surface) for sid, (_app, _page, surface) in s.agent.pages.items()]
            for sid, surface in shown:
                for cid in sorted(surface.components):
                    try:
                        event, ctx = surface.button_event(cid)
                    except a2ui.CardError:
                        continue        # 不是按钮，或不在画着的那一棵树上
                    if event != "agent.open_page":
                        continue
                    with self.subTest(f"{name(sc)} {sid} {cid}"):
                        before = len(s.replay.served)
                        r = s.agent.tap(sid, cid, {})
                        self.assertFalse(r.get("error"), r.get("text"))
                        self.assertIn(ctx.get("page"), pages, "开的是这个工具登记的页")
                        args = ctx.get("args") or {}
                        # 应用自己的旧页换成核心拼的那一页（apppages.alias：邮件的旧设置、规则、清扫）
                        # 带着 id 去收件箱的换成打开那一封（apppages 的 `ARG_PAGES`）
                        want = {"app": s.app, "page": apppages.alias(s.source, ctx["page"], args)}
                        if args:
                            if all(isinstance(v, str) for v in args.values()):
                                want["args"] = args
                            else:       # 有取数据模型的值（{"path": …}）：只比键
                                self.assertEqual(sorted(r.get("page", {}).get("args", {})), sorted(args))
                                want["args"] = r["page"]["args"]
                        self.assertEqual(r.get("page"), want)
                        self.assertEqual([x["file"] for x in s.replay.served[before:]
                                          if x["request"].get("method") == "tools/call"], [], "核心自己换页，不交给工具")
                        opened += 1
                        with_args += bool(args)
        self.assertGreaterEqual(opened, 1)
        self.assertGreaterEqual(with_args, 1, "样例里有带参数的（邮件助手只讲一封的卡片上的「在邮件助手里看」）")

    def test_a_one_mail_cards_view_button_opens_that_mail(self):
        """邮件助手只讲一封的卡片上「在邮件助手中查看」带 `id` 去收件箱：打开的是这一封（已归档的不在收件箱的任何一组里）"""
        sc = next((x for x in SCENARIOS if name(x) == "luoke-mail/due"), None)
        if sc is None:
            self.skipTest("没有邮件助手的 due 场景")
        s = self.session(sc)
        with contextlib.redirect_stderr(io.StringIO()):
            s.run()
        sid, surface = next((sid, sf) for sid, (_k, sf) in s.agent.surfaces.items() if "/due-" in sid)
        cid = next(c for c in sorted(surface.components) if _event(surface, c) == "agent.open_page")
        r = s.agent.tap(sid, cid, {})
        self.assertEqual(r.get("page"), {"app": "luoke-mail", "page": "mail", "args": {"id": "2"}})
        s.agent.page(s.app, "mail", r["page"]["args"])
        texts = [c.get("text") for c in s.agent.pages["luoke-mail/page/mail"][2].components.values()]
        self.assertIn("重新登记奖赏计划", texts)
        self.assertIn("完成", texts)

    def test_window_samples_are_current(self):
        r = subprocess.run([sys.executable, "-B", os.path.join(ROOT, "scripts", "window_samples.py"), "--check"],
                           capture_output=True, text=True, timeout=300)
        self.assertEqual(r.returncode, 0, r.stderr)


if __name__ == "__main__":
    unittest.main()
