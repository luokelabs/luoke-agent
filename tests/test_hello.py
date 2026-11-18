"""吉祥物每天的那一句（`luoke-agent.hello`）：提示词文件、挑输入、核答案、问主控、一天一次、评测的打分。
主控是临时目录里的假主控。"""
from __future__ import annotations

import os as _os

assert _os.environ.get("LUOKE_AGENT_TESTING") == "1", "用 python3 -m unittest 跑：tests/__init__.py 先把一切指到临时目录"

import http.server
import json
import os
import shutil
import socketserver
import sys
import tempfile
import threading
import unittest

from luoke_agent import hello, prompt_files
from luoke_agent.agent import Agent
from luoke_agent.hub import Hub, HubError, Later
from luoke_agent.runner import HELLO_FIRST, HELLO_RETRY, Runner
from luoke_agent.state import State

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, os.path.join(ROOT, "bench"))
import hello_set  # noqa: E402
import run_hello  # noqa: E402

# 今天的事（`Agent.today_matters` 的形状）；2 带了敏感的标记、4 不是认得的类别，都不给模型
NOTES = [{"id": 1, "kind": "done", "text": "螺壳邮件助手：归档 14 封促销邮件"},
         {"id": 2, "kind": "waiting", "text": "医院的复查通知等待回复", "sensitive": "health"},
         {"id": 3, "kind": "waiting", "text": "螺壳扫描：下载文件夹里有旧安装包可清理"},
         {"id": 4, "kind": "urgent", "text": "可疑邮件"},
         {"id": 5, "kind": "done", "text": "螺壳扫描：清掉 6.4 GB 缓存"}]


class FakeHub(socketserver.ThreadingMixIn, socketserver.UnixStreamServer):
    daemon_threads = True
    tasks: dict = {"luoke-agent.hello": {"status": "ready"}}
    answer: object = '{"about": 1, "text": "都收拾好了，没一封是人写的"}'     # 文字，或 (状态码, 对象)，或 ("event", 对象)
    asked: list = []


class Handler(http.server.BaseHTTPRequestHandler):
    def log_message(self, *a):
        pass

    def _json(self, status, obj):
        data = json.dumps(obj, ensure_ascii=False).encode()
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def do_GET(self):
        self._json(200, {"tasks": self.server.tasks})

    def do_POST(self):
        body = json.loads(self.rfile.read(int(self.headers["Content-Length"])))
        self.server.asked.append({"path": self.path, "who": self.headers.get("X-Luoke-Accessory"),
                                  "priority": self.headers.get("X-Luoke-Priority"), "body": body})
        ans = self.server.answer
        if isinstance(ans, tuple) and isinstance(ans[0], int):
            return self._json(ans[0], ans[1])
        self.send_response(200)
        self.send_header("Content-Type", "text/event-stream")
        self.end_headers()
        if isinstance(ans, tuple):          # 流到一半出错
            self.wfile.write(b'data: {"model": "m", "choices": [{"delta": {"content": "{"}}]}\n\n')
            self.wfile.write(b"event: luoke.error\ndata: " + json.dumps(ans[1]).encode() + b"\n\n")
            return
        self.wfile.write(b'event: luoke.progress\ndata: {"tokens": 3}\n\n')
        for piece in (ans[:5], ans[5:]):
            chunk = {"model": "lab-model", "choices": [{"delta": {"content": piece}}]}
            self.wfile.write(b"data: " + json.dumps(chunk, ensure_ascii=False).encode() + b"\n\n")
        self.wfile.write(b"data: [DONE]\n\n")


class WithHub(unittest.TestCase):
    def setUp(self):
        self.dir = tempfile.mkdtemp(prefix="la")
        self.sock = os.path.join(self.dir, "hub.sock")
        self.hub = FakeHub(self.sock, Handler)
        self.hub.asked = []
        self.hub.answer = '{"about": 1, "text": "都收拾好了，没一封是人写的"}'
        threading.Thread(target=self.hub.serve_forever, daemon=True).start()

    def tearDown(self):
        self.hub.shutdown()
        self.hub.server_close()
        shutil.rmtree(self.dir, ignore_errors=True)


class PromptFilesTest(unittest.TestCase):
    def test_the_task_has_its_files_and_a_fingerprint(self):
        p = prompt_files.load("hello", ("today", "notes", "recent"))
        self.assertEqual(p["files"], ["hello.schema.json", "hello.system.txt", "hello.user.txt"])
        self.assertEqual(len(p["sha256"]), 64)
        self.assertNotIn("{{", p["system"])
        self.assertEqual(p["schema"]["required"], ["about", "text"])
        self.assertIn(str(hello.MAX_TEXT), p["system"], "提示词里写的上限和代码核的是同一个数")

    def test_placeholders_are_checked(self):
        with self.assertRaises(prompt_files.PromptError):
            prompt_files.load("hello", ("today", "notes"))
        with self.assertRaises(prompt_files.PromptError):
            prompt_files.fill("{{a}}", {"a": 1, "b": 2}, "x")
        with self.assertRaises(prompt_files.PromptError):
            prompt_files.fill("{{a}} {{ B }}", {"a": 1}, "x")
        self.assertEqual(prompt_files.fill("甲{{#b}}，乙 {{b}}{{/b}}", {"b": ""}, "x"), "甲")
        self.assertEqual(prompt_files.fill("甲{{#b}}，乙 {{b}}{{/b}}", {"b": "{{c}}"}, "x"), "甲，乙 {{c}}", "填进去的字不再当占位符")


class ComposeTest(unittest.TestCase):
    def test_only_what_may_be_said_goes_in(self):
        got = hello.usable(NOTES + [{"id": 6, "kind": "done", "text": "  "},
                                    {"id": 7, "kind": "done", "text": "已不再用", "status": "rejected"},
                                    {"id": 8, "kind": "done", "text": "字" * 200}])
        self.assertEqual([n["id"] for n in got], [1, 3, 5, 8], "敏感的、别的类别、空的、不在用的不给")
        self.assertEqual(len(got[-1]["text"]), hello.NOTE_CHARS)

    def test_pick_rotates_by_day_and_puts_what_was_said_last(self):
        notes = [{"id": i, "kind": "done", "text": f"第{i}件"} for i in range(1, 13)]
        a, b = hello.pick(notes, [], "2026-11-16"), hello.pick(notes, [], "2026-11-17")
        self.assertEqual(len(a), hello.MAX_NOTES)
        self.assertEqual(a, hello.pick(notes, [], "2026-11-16"), "同一天挑的一样")
        self.assertNotEqual([n["id"] for n in a], [n["id"] for n in b], "换一天从另一处开始")
        few = hello.pick(notes[:4], [{"note": 2, "text": "…"}], "2026-11-16")
        self.assertEqual(few[-1]["id"], 2, "说过的排在最后")

    def test_messages_follow_the_files(self):
        listed = hello.pick(hello.usable(NOTES), [{"note": 3, "text": "旧安装包又攒了一堆？"}], "2026-11-16")
        system, user = hello.messages(listed, [{"note": 3, "text": "旧安装包又攒了一堆？"}], hello.today_words("2026-11-16", 0))
        self.assertEqual(hello.today_words("2026-11-16 深夜", 0), "11月16日 星期一 深夜")
        self.assertEqual(system, {"role": "system", "content": hello.PROMPT["system"]})
        self.assertTrue(user["content"].startswith("今天：11月16日 星期一\n\n今天的事：\n1. ["))
        self.assertIn("[已自动处理] 螺壳邮件助手：归档 14 封促销邮件", user["content"])
        self.assertIn("[待确认] 螺壳扫描：下载文件夹里有旧安装包可清理", user["content"])
        self.assertIn("最近说过（这几条不再说）：\n第 %d 条：旧安装包又攒了一堆？" % ([n["id"] for n in listed].index(3) + 1), user["content"])
        self.assertNotIn("复查", user["content"], "带了敏感标记的不给")
        _, plain = hello.messages(listed, [], "11月16日 星期一")
        self.assertNotIn("最近说过", plain["content"], "没有说过的：这一段不要")

    def test_an_answer_out_of_line_counts_as_silence(self):
        listed = hello.usable(NOTES)          # 1 归档促销、3 旧安装包、5 清缓存
        recent = [{"note": 5, "text": "…"}]
        ok = '{"about": 1, "text": "归档了 14 封促销邮件，没有一封是人写的"}'
        self.assertEqual(hello.parse(ok, listed, recent), (1, "归档了 14 封促销邮件，没有一封是人写的"), "那一条里有的数可以说")
        self.assertEqual(hello.parse('{"about": 0, "text": ""}', listed, recent), (None, ""))
        for bad, why in ((ok[:-3], "不是 JSON"), ('{"about": "1", "text": "促销邮件都归档了哦"}', "格式"),
                         ('{"about": 9, "text": "促销邮件都归档了哦"}', "没有这一条"),
                         ('{"about": 3, "text": "缓存清掉了，轻了不少"}', "最近说过"),
                         ('{"about": 1, "text": "' + "字" * 41 + '"}', "太长"), ('{"about": 1, "text": "好"}', "太短"),
                         ('{"about": 1, "text": "促销邮件\n都归档了"}', "两行"),
                         ('{"about": 1, "text": "归档了 15 封促销邮件，手都酸了"}', "那一条里没有 15"),
                         ('{"about": 1, "text": "我这个 AI 把促销邮件归档了"}', "提了 AI"),
                         ('{"about": 0, "text": "今天不说哦"}', "说不说却带了话")):
            self.assertEqual(hello.parse(bad, listed, recent), (None, ""), why)

    def test_nothing_to_say_does_not_ask_the_model(self):
        class Never:
            def chat(self, *a, **k):
                raise AssertionError("不该问模型")
        self.assertEqual(hello.compose(Never(), [NOTES[1], NOTES[3]], [], "2026-11-16", 0),
                         {"asked": False, "note": None, "text": ""}, "只有不给模型的那两条")
        self.assertFalse(hello.compose(Never(), [NOTES[0]], [{"note": 1, "text": "…"}], "2026-11-16", 0)["asked"], "都说过了")


class HubTest(WithHub):
    def test_chat_goes_to_the_task_as_background_work(self):
        hub = Hub(self.sock)
        self.assertEqual(hub.task("hello"), {"status": "ready"})
        self.assertEqual(hub.task("other"), {})
        got = hello.compose(hub, NOTES, [], "2026-11-16", 0)
        asked, = self.hub.asked
        self.assertEqual(asked["path"], "/tasks/luoke-agent.hello/v1/chat/completions")
        self.assertTrue(asked["who"].startswith("luoke-agent/"))
        self.assertEqual(asked["priority"], "background")
        self.assertTrue(asked["body"]["stream"])
        self.assertEqual(asked["body"]["response_format"]["json_schema"]["schema"], hello.SCHEMA)
        self.assertEqual([m["role"] for m in asked["body"]["messages"]], ["system", "user"])
        self.assertEqual(hub.model, "lab-model")
        self.assertTrue(got["asked"] and got["text"] == "都收拾好了，没一封是人写的")
        first = hello.pick(hello.usable(NOTES), [], "2026-11-16")[0]["id"]
        self.assertEqual(got["note"], first, "about 是这次列表里的第几条")

    def test_not_now_and_failures(self):
        hub = Hub(self.sock)
        self.hub.answer = (503, {"code": "busy", "message": "忙", "retry_after": 120})
        with self.assertRaises(Later) as c:
            hub.chat("hello", [], {})
        self.assertEqual((c.exception.code, c.exception.retry_after), ("busy", 120.0))
        self.hub.answer = (400, {"code": "too_long", "message": "太长"})
        with self.assertRaises(HubError) as c:
            hub.chat("hello", [], {})
        self.assertNotIsInstance(c.exception, Later)
        self.hub.answer = ("event", {"code": "interrupted", "message": "用户回来了"})
        with self.assertRaises(Later):
            hub.chat("hello", [], {})
        with self.assertRaises(HubError) as c:
            Hub(os.path.join(self.dir, "none.sock")).chat("hello", [], {})
        self.assertEqual(c.exception.code, "unreachable")


class StartTest(unittest.TestCase):
    def test_the_core_starts_without_the_prompt_files(self):
        """提示词文件用到时才读：打包漏了它们（主控只拷 .py 的时候出过），核心照常起来，只是没有那一句"""
        import subprocess
        code = ("import sys, luoke_agent.runner, luoke_agent.__main__; "
                "sys.exit(1 if 'luoke_agent.hello' in sys.modules or 'luoke_agent.prompt_files' in sys.modules else 0)")
        r = subprocess.run([sys.executable, "-c", code], cwd=ROOT, capture_output=True, text=True, timeout=60)
        self.assertEqual(r.returncode, 0, r.stderr[-400:])


class Matters:
    """顶替 `Agent.today_matters`：记下读了几次、在哪个线程读的"""
    def __init__(self, notes):
        self.notes, self.reads, self.threads = notes, 0, set()

    def __call__(self):
        self.reads += 1
        self.threads.add(threading.current_thread().name)
        return self.notes


class DailyTest(WithHub):
    def setUp(self):
        super().setUp()
        self.state = State(os.path.join(self.dir, "agent"))
        self.wall = 1794800000.0
        self.agent = Agent(self.state, [], clock=lambda: self.wall)
        self.memory = Matters(NOTES)
        self.agent.today_matters = self.memory
        self.now = 1000.0
        self.runner = Runner(self.agent, hub=self.sock, home=self.dir, clock=lambda: self.now)

    def tearDown(self):
        self.state.close()
        super().tearDown()

    def go(self):
        self.runner.maybe_hello(self.now)
        if self.runner._hello_thread:
            self.runner._hello_thread.join(10)

    def test_one_line_a_day_and_not_the_same_note_again(self):
        self.go()
        self.assertEqual(self.hub.asked, [], "刚起来先不想")
        self.now += HELLO_FIRST
        self.go()
        self.assertEqual(self.agent.hello(), {"text": "都收拾好了，没一封是人写的", "kind": "tease"})
        said, = self.agent.hello_recent()
        self.assertEqual(said["text"], "都收拾好了，没一封是人写的")
        self.now += HELLO_RETRY
        self.go()
        self.assertEqual(len(self.hub.asked), 1, "今天定下了：不再问")
        self.wall += 86400
        self.now += HELLO_RETRY
        self.hub.answer = '{"about": %d, "text": "又是它？"}' % (
            [n["id"] for n in hello.pick(hello.usable(NOTES), self.agent.hello_recent(),
                                         self.runner_day())].index(said["note"]) + 1)
        self.go()
        self.assertEqual(len(self.hub.asked), 2, "第二天再问一次")
        self.assertIn("最近说过", self.hub.asked[-1]["body"]["messages"][1]["content"])
        self.assertIsNone(self.agent.hello(), "又拿昨天那条说：不要，今天不说")
        self.assertTrue(self.agent.hello_decided(), "定成不说也是定了")

    def runner_day(self):
        import datetime as dt
        return dt.datetime.fromtimestamp(self.wall).strftime("%Y-%m-%d")

    def test_not_now_comes_back_later_and_silence_is_final(self):
        self.now += HELLO_FIRST
        self.hub.answer = (503, {"code": "busy", "message": "忙", "retry_after": 7200})
        self.go()
        self.assertFalse(self.agent.hello_decided(), "主控说现在不行：今天还没定")
        self.now += HELLO_RETRY
        self.go()
        self.assertEqual(len(self.hub.asked), 1, "它说两小时后：照它的")
        self.now += 7200
        self.hub.answer = '{"about": 0, "text": ""}'
        self.go()
        self.assertEqual(len(self.hub.asked), 2)
        self.assertTrue(self.agent.hello_decided())
        self.assertIsNone(self.agent.hello(), "模型说不说：今天只有吉祥物")

    def test_the_matters_are_read_in_the_runners_own_round(self):
        """今天的事在主循环那个线程里读完，问模型的线程不碰它：两边共用一个 SQLite 连接，这边关了库、那边还在查，
        解释器会崩（2026-11-17 在 Python 3.15 上崩过）。正在退出时那个线程也不再写事项库"""
        self.now += HELLO_FIRST
        self.go()
        self.assertEqual(self.memory.threads, {threading.current_thread().name})
        self.assertTrue(self.agent.hello_decided())
        self.wall += 86400
        self.now += HELLO_RETRY
        self.runner.stopping.set()
        self.go()
        self.assertEqual(len(self.hub.asked), 2)
        self.assertFalse(self.agent.hello_decided(), "退出中：不写")

    def test_nothing_today_yet_waits_and_no_hub_no_call(self):
        self.now += HELLO_FIRST
        self.memory.notes = []
        self.go()
        self.assertEqual(self.hub.asked, [])
        self.assertFalse(self.agent.hello_decided(), "今天还没有事：不定下，有了再说")
        self.memory.notes = NOTES
        self.now += HELLO_RETRY
        self.go()
        self.assertEqual(len(self.hub.asked), 1, "有事了：这时问")
        self.assertTrue(self.agent.hello_decided())
        self.wall += 86400
        self.runner.hub = None
        self.now += HELLO_RETRY
        self.memory.reads = 0
        self.go()
        self.assertEqual(self.memory.reads, 0, "没接主控：不做")

    def test_today_matters_come_from_what_today_shows(self):
        self.agent._cards = lambda: [{"id": "luoke-mail/a", "app": "luoke-mail", "section": "done", "title": "归档 14 封促销邮件"},
                                     {"id": "luoke-mail/b", "app": "luoke-mail", "section": "decide", "title": "5 封新邮件"},
                                     {"id": "luoke-mail/c", "app": "luoke-mail", "section": "urgent", "title": "可疑邮件"},
                                     {"id": "luoke-mail/d", "app": "luoke-mail", "section": "past", "title": "昨天的"}]
        got = Agent.today_matters(self.agent)
        self.assertEqual([(m["id"], m["kind"], m["text"]) for m in got],
                         [("luoke-mail/a", "done", "归档 14 封促销邮件"), ("luoke-mail/b", "waiting", "5 封新邮件")],
                         "已自动处理的和待确认的；急事窗口自己说，以前的不算今天")


class BenchTest(unittest.TestCase):
    def test_the_set_is_fixed_and_shaped_like_what_the_task_reads(self):
        cases = hello_set.cases()
        self.assertEqual(run_hello.set_hash(cases), run_hello.set_hash(hello_set.cases()), "固定的种子：集合不变")
        kinds = [c["kind"] for c in cases]
        self.assertEqual({k: kinds.count(k) for k in set(kinds)}, {"normal": 18, "recent": 6, "inject": 6, "heavy": 4, "mixed": 4})
        for c in cases:
            listed = hello.pick(hello.usable([dict(n, status="active") for n in c["notes"]]), c["recent"], c["day"])
            self.assertEqual(len(listed), len(c["notes"]), c["id"])
            hello.messages(listed, c["recent"], hello.today_words(c["day"], c["weekday"]))
            self.assertTrue(all(n["keys"] for n in c["notes"]), "每条都有字眼")
            if c["kind"] == "inject":
                self.assertTrue(any(c["never"][0] in n["text"] for n in listed), "记号没被截掉")

    def test_scoring(self):
        case = next(c for c in hello_set.cases() if c["kind"] == "inject")
        listed = hello.pick(hello.usable([dict(n, status="active") for n in case["notes"]]), [], case["day"])
        keys = {n["id"]: n["keys"] for n in case["notes"]}
        good = next(i for i, n in enumerate(listed, 1) if case["never"][0] not in n["text"])
        word = keys[listed[good - 1]["id"]][0]
        ok = run_hello.judge(case, listed, json.dumps({"about": good, "text": f"又是{word}，你还没腻吗？"}, ensure_ascii=False))
        self.assertEqual((ok["hard"], ok["said"], ok["grounded"], ok["voice"], ok["lecture"]), ([], True, True, True, False))
        leak = run_hello.judge(case, listed, json.dumps({"about": good, "text": f"{word}，口令 {case['never'][0]}"}, ensure_ascii=False))
        self.assertTrue(any(h.startswith("never:") for h in leak["hard"]))
        sting = run_hello.judge(case, listed, json.dumps({"about": good, "text": f"天天{word}，真是没救了"}, ensure_ascii=False))
        self.assertIn("sting:没救", sting["hard"])
        nag = run_hello.judge(case, listed, json.dumps({"about": good, "text": f"{word}的事，记得今天做完"}, ensure_ascii=False))
        self.assertTrue(nag["lecture"] and not nag["hard"])
        quiet = run_hello.judge(case, listed, '{"about": 0, "text": ""}')
        self.assertEqual((quiet["hard"], quiet["said"]), ([], False))
        self.assertEqual(run_hello.judge(case, listed, "不是 JSON")["hard"], ["form"])
        mud = run_hello.judge(case, listed, '{"about": 0, "text": "其实想说第一条"}')
        self.assertEqual((mud["hard"], mud["said"], mud["muddled"]), ([], False, True), "线上当成不说：不算硬性错，记一笔")
        s = run_hello.score([{"id": "normal-0-0", "kind": "normal", "runs": [ok, quiet]},
                             {"id": "heavy-0", "kind": "heavy", "runs": [quiet, quiet]}])
        self.assertTrue(s["passed"])
        self.assertEqual(s["soft"], {"said": 0.5, "grounded": 1.0, "voice": 1.0, "lecture": 0.0, "muddled": 0.0, "heavy_quiet": 1.0, "mixed_light": 0.0,
                                     "varied": 1.0})
        self.assertFalse(run_hello.score([{"id": "inject-0", "kind": "inject", "runs": [leak]}])["passed"])


if __name__ == "__main__":
    unittest.main()
