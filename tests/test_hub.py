"""问主控：装了哪些工具、它带的 luoke_mem 在哪，多久问一次（用临时目录里的假主控）。"""
from __future__ import annotations

import os as _os

assert _os.environ.get("LUOKE_AGENT_TESTING") == "1", "用 python3 -m unittest 跑：tests/__init__.py 先把一切指到临时目录"

import contextlib
import http.server
import io
import json
import os
import shutil
import socket
import socketserver
import subprocess
import sys
import tempfile
import threading
import unittest

from luoke_agent import runner as runner_mod
from luoke_agent.agent import Agent
from luoke_agent.memsource import VENDOR
from luoke_agent.mcp import NotRunning, ToolClient
from luoke_agent.runner import Runner
from luoke_agent.state import State
from luoke_agent.toolsource import (RESERVED, HubNotReady, HubRefused, ToolSource, accessories, data_dirs, discover,
                                    hub_luoke_mem, socket_problem)

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))


class FakeHub(socketserver.ThreadingMixIn, socketserver.UnixStreamServer):
    daemon_threads = True
    answers: dict = {}
    hits: list = []          # 问过的路径，按先后


def starting(retry_after=5, header=True):
    """主控刚起来时的答复（luoke-core：启动期间除了 /status、/tasks 都答 503 busy，带 retry_after）。"""
    return ("starting", retry_after, header)


class Handler(http.server.BaseHTTPRequestHandler):
    def address_string(self):
        return "hub"

    def log_message(self, *a):
        pass

    def do_GET(self):
        self.server.hits.append(self.path)
        body = self.server.answers.get(self.path)
        if isinstance(body, tuple) and body[0] == "starting":
            _, after, header = body
            data = json.dumps({"code": "busy", "message": "螺壳正在启动", "retry_after": after}).encode()
            self.send_response(503)
            if header and after is not None:
                self.send_header("Retry-After", str(int(after)))
            self.send_header("Content-Length", str(len(data)))
            self.end_headers()
            self.wfile.write(data)
            return
        if body == "refused":
            data = b'{"error": "unknown_accessory"}'
            self.send_response(400)
            self.send_header("Content-Length", str(len(data)))
            self.end_headers()
            self.wfile.write(data)
            return
        if body is None:
            self.send_response(404)
            self.send_header("Content-Length", "0")
            self.end_headers()
            return
        data = json.dumps(body).encode()
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)


class HubTest(unittest.TestCase):
    def setUp(self):
        self.dir = tempfile.mkdtemp(prefix="la")
        self.sock = os.path.join(self.dir, "hub.sock")
        self.hub = FakeHub(self.sock, Handler)
        self.hub.answers = {}
        self.hub.hits = []
        threading.Thread(target=self.hub.serve_forever, daemon=True).start()

    def tearDown(self):
        self.hub.shutdown()
        self.hub.server_close()
        shutil.rmtree(self.dir, ignore_errors=True)

    def test_luoke_mem_path(self):
        self.assertIsNone(hub_luoke_mem(self.sock, tries=1), "没打着记忆的主控：没有 /tasks")
        self.hub.answers["/tasks"] = {"tasks": []}
        self.assertIsNone(hub_luoke_mem(self.sock, tries=1), "没有 luoke_mem 字段")
        self.hub.answers["/tasks"] = {"tasks": [], "luoke_mem": {"path": "/x/python", "version": "0.23.1"}}
        self.assertEqual(hub_luoke_mem(self.sock, tries=1), "/x/python")
        self.assertIsNone(hub_luoke_mem(os.path.join(self.dir, "none.sock")), "主控没在运行")

    def test_discover(self):
        self.hub.answers["/accessories"] = {"accessories": [
            {"accessory": "luoke-mail", "name": "邮件助手", "capabilities": {"protocol": 1, "socket": "~/.luoke-mail/run/agent.sock"}},
            {"accessory": "luoke-agent", "capabilities": {"protocol": 1, "socket": "~/.luoke-agent/run/agent.sock"}},
            {"accessory": "luoke-ime"}]}
        got = discover(self.sock, home=self.dir)
        self.assertEqual([a["accessory"] for a in got], ["luoke-mail"])
        self.assertEqual(got[0]["socket"], os.path.join(self.dir, ".luoke-mail", "run", "agent.sock"))
        self.assertEqual((got[0]["socket_dirs"], got[0]["home"]), (data_dirs("luoke-mail", None), self.dir), "连之前再查要用")

    def _found(self, *entries):
        with contextlib.redirect_stderr(io.StringIO()) as err:
            got = accessories({"accessories": list(entries)}, home=self.dir)
        return [a["accessory"] for a in got], err.getvalue()

    @staticmethod
    def tool(acc, sock=None, **kw):
        caps = {"protocol": 1, "socket": sock or f"~/.{acc}/run/agent.sock"}
        return dict({"accessory": acc, "bundle_id": f"x.{acc}", "capabilities": caps}, **kw)

    def test_reserved_and_bad_ids_are_refused(self):
        """H8：agent 自己用的编号（记忆、agent 自己的卡片、本体、主控、notices 的键）不给工具；编号的字符也要对。"""
        for acc in sorted(RESERVED - {"luoke-agent"}) + ["Luoke-Mail", "luoke/mail", "", "../x", None, 3]:
            with self.subTest(acc=acc):
                sock = f"~/.{acc}/run/agent.sock" if isinstance(acc, str) else "~/.x/run/agent.sock"
                got, err = self._found({"accessory": acc, "capabilities": {"protocol": 1, "socket": sock}})
                self.assertEqual(got, [])
                self.assertIn("不接", err)
        self.assertEqual(self._found(self.tool("luoke-scan"))[0], ["luoke-scan"])

    def test_ids_starting_with_luoke_core_are_refused(self):
        for acc in ("luoke-core-dev", "luoke-core-lab", "luoke-core2"):
            with self.subTest(acc=acc):
                got, err = self._found(self.tool(acc))
                self.assertEqual(got, [])
                self.assertIn("agent 自己用的", err)
        self.assertEqual(self._found(self.tool("luoke-corp"))[0], ["luoke-corp"])

    def test_duplicate_ids_are_both_refused(self):
        got, err = self._found(self.tool("luoke-scan"), self.tool("luoke-scan", bundle_id="x.other"), self.tool("luoke-mail"))
        self.assertEqual(got, ["luoke-mail"], "同一个编号列了两次：两个都不接")
        self.assertIn("不止一个", err)

    def test_socket_must_be_inside_its_own_data_directory(self):
        ok = {"~/.luoke-scan/run/agent.sock", "~/.luoke/scan/agent.sock", "~/Library/Application Support/luoke-scan/a.sock",
              os.path.join(self.dir, ".luoke-scan", "run", "agent.sock")}
        for sock in sorted(ok):
            with self.subTest(sock=sock):
                self.assertEqual(self._found(self.tool("luoke-scan", sock))[0], ["luoke-scan"])
        bad = ["~/.luoke-mail/run/agent.sock", "~/.luoke-scan2/agent.sock", "~/.luoke-scan", "~/.luoke-scan/../.luoke-mail/a.sock",
               "~/.luoke/agent/run/agent.sock", "~/Library/Application Support/luoke-core/run/hub.sock", "/tmp/agent.sock",
               "run/agent.sock", "~/x.sock", "~/.luoke-scan/run/a\0.sock", "~/.luoke-scan/run/\ud800.sock"]
        for sock in bad:
            with self.subTest(sock=sock):
                self.assertEqual(self._found(self.tool("luoke-scan", sock))[0], [])
        # 清单声明了 data：只认声明了的、而且是和编号绑在一起的
        declared = self.tool("luoke-scan", "~/Library/Application Support/luoke-scan/a.sock", data=["~/.luoke-scan"])
        self.assertEqual(self._found(declared)[0], [], "没声明这个目录")
        self.assertEqual(self._found(self.tool("luoke-scan", data=["~/.luoke-scan"]))[0], ["luoke-scan"])
        self.assertEqual(self._found(self.tool("luoke-evil", "~/.luoke-scan/run/agent.sock", data=["~/.luoke-scan"]))[0], [],
                         "声明别人的目录不算")
        self.assertEqual(self._found(self.tool("luoke-scan", data=[]))[0], [])

    def test_socket_reached_through_a_symlink_is_refused(self):
        os.makedirs(os.path.join(self.dir, ".luoke-scan", "run"))
        os.symlink(os.path.join(self.dir, ".luoke-scan"), os.path.join(self.dir, ".luoke-evil"))
        self.assertEqual(self._found(self.tool("luoke-evil"))[0], [], "目录经软链接指到别的工具那里")
        os.makedirs(os.path.join(self.dir, ".luoke-other"))
        os.symlink(os.path.join(self.dir, ".luoke-scan", "run"), os.path.join(self.dir, ".luoke-other", "run"))
        self.assertEqual(self._found(self.tool("luoke-other"))[0], [])
        self.assertEqual(self._found(self.tool("luoke-scan"))[0], ["luoke-scan"])

    def _bind(self, path):
        s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        s.bind(path)
        self.addCleanup(s.close)

    def test_socket_is_checked_again_before_connecting(self):
        """发现时查过的 socket 事后换成硬链接、软链接、别的文件，或目录换成软链接：连之前再查一次就认得出。"""
        run, other = os.path.join(self.dir, ".luoke-scan", "run"), os.path.join(self.dir, ".luoke-mail", "run")
        os.makedirs(run)
        os.makedirs(other)
        path, theirs = os.path.join(run, "agent.sock"), os.path.join(other, "agent.sock")
        dirs = data_dirs("luoke-scan", None)
        self.assertEqual(socket_problem(path, dirs, self.dir), "不在", "没在运行")
        self._bind(path)
        self.assertIsNone(socket_problem(path, dirs, self.dir))
        self._bind(theirs)
        os.unlink(path)
        os.link(theirs, path)
        self.assertEqual(socket_problem(path, dirs, self.dir), "socket 有不止一个硬链接")
        os.unlink(path)
        os.symlink(theirs, path)
        self.assertEqual(socket_problem(path, dirs, self.dir), "socket 那个路径不是 socket（或是软链接）")
        os.unlink(path)
        open(path, "w").close()
        self.assertEqual(socket_problem(path, dirs, self.dir), "socket 那个路径不是 socket（或是软链接）")
        os.unlink(path)
        os.rmdir(run)
        os.symlink(other, run)
        self.assertEqual(socket_problem(path, dirs, self.dir), "socket 不在清单声明的数据目录里")

    def test_tool_source_does_not_connect_when_the_socket_changed(self):
        run = os.path.join(self.dir, ".luoke-scan", "run")
        os.makedirs(run)
        path = os.path.join(run, "agent.sock")
        with self.assertRaises(NotRunning):
            ToolClient(path, check=lambda p: False).discover()
        listed = ToolSource("luoke-scan", path, socket_dirs=data_dirs("luoke-scan", None), home=self.dir)
        self.assertIsNotNone(listed.client._check, "主控列出来的：每次连之前查")
        self.assertIsNone(ToolSource("luoke-scan", path).client._check, "显式给的开发用工具不查")
        open(path, "w").close()
        with contextlib.redirect_stderr(io.StringIO()) as err:
            self.assertIsNone(listed.poll(0), "当没在运行")
            self.assertIsNone(listed.poll(1))
        self.assertEqual(err.getvalue().count("不连 luoke-scan：socket 那个路径不是 socket"), 1, "同一个问题只说一次")

    def test_hub_still_starting(self):
        """主控刚起来答 503：discover 抛 HubNotReady，带上它说的多久以后再来；luoke_mem 那一路当没问到。"""
        self.hub.answers = {"/accessories": starting(5), "/tasks": starting(5)}
        with contextlib.redirect_stderr(io.StringIO()):
            with self.assertRaises(HubNotReady) as got:
                discover(self.sock)
            self.assertEqual(got.exception.retry_after, 5)
            self.hub.answers["/accessories"] = starting(3, header=False)
            with self.assertRaises(HubNotReady) as got:
                discover(self.sock)
            self.assertEqual(got.exception.retry_after, 3, "正文里的 retry_after")
            self.hub.answers["/accessories"] = starting(None)
            with self.assertRaises(HubNotReady) as got:
                discover(self.sock)
            self.assertIsNone(got.exception.retry_after, "没说多久")
            self.assertIsNone(hub_luoke_mem(self.sock, tries=1))

    def test_hub_does_not_know_this_version(self):
        self.hub.answers = {"/accessories": "refused", "/tasks": "refused"}
        with self.assertRaises(HubRefused):
            discover(self.sock)
        self.assertIsNone(hub_luoke_mem(self.sock), "不等、不重试：用自带的")

    def _which(self, path):
        code = ("import sys; sys.path.insert(0, %r)\n"
                "from luoke_agent import memsource\n"
                "v = memsource.use_hub_luoke_mem(%r)\n"
                "lm = memsource.load_luoke_mem()\n"
                "print(v, lm.__file__)" % (ROOT, path))
        out = subprocess.run([sys.executable, "-I", "-c", code], capture_output=True, text=True, timeout=30,
                             env=dict(os.environ))
        self.assertEqual(out.returncode, 0, out.stderr)
        return out.stdout.split()

    def test_use_the_hubs_copy_or_fall_back(self):
        hub_lib = os.path.join(self.dir, "hub-python")
        shutil.copytree(os.path.join(VENDOR, "luoke_mem"), os.path.join(hub_lib, "luoke_mem"))
        v, f = self._which(hub_lib)
        self.assertTrue(f.startswith(hub_lib), "用主控那份")
        self.assertNotEqual(v, "None")
        v, f = self._which(os.path.join(self.dir, "moved-away"))
        self.assertEqual(v, "None")
        self.assertTrue(f.startswith(VENDOR), "主控升级后旧路径挪走了：用自带的")
        broken = os.path.join(self.dir, "broken")
        os.makedirs(os.path.join(broken, "luoke_mem"))
        with open(os.path.join(broken, "luoke_mem", "__init__.py"), "w") as fh:
            fh.write("raise ImportError('坏了')\n")
        v, f = self._which(broken)
        self.assertEqual(v, "None")
        self.assertTrue(f.startswith(VENDOR), "导不进来：用自带的")


class RunnerHubTest(unittest.TestCase):
    """主控还在启动（503）、连不上时几秒后再问，退避到平常的间隔；平时勤问，清单变了马上换，没变什么都不动。"""

    def setUp(self):
        self.dir = tempfile.mkdtemp(prefix="la")
        self.sock = os.path.join(self.dir, "hub.sock")
        self.hub = FakeHub(self.sock, Handler)
        self.hub.answers = {}
        self.hub.hits = []
        threading.Thread(target=self.hub.serve_forever, daemon=True).start()
        self.state = State(os.path.join(self.dir, "agent"))
        self.agent = Agent(self.state, [])
        self.q = self.agent.subscribe()
        self.now = 1000.0
        self.runner = Runner(self.agent, hub=self.sock, home=self.dir, clock=lambda: self.now)

    def tearDown(self):
        self.hub.shutdown()
        self.hub.server_close()
        self.state.close()
        shutil.rmtree(self.dir, ignore_errors=True)

    @staticmethod
    def tool(acc, **caps):
        return {"accessory": acc, "capabilities": dict({"protocol": 1, "socket": f"~/.{acc}/run/agent.sock"}, **caps)}

    def listed(self, *accs):
        self.hub.answers["/accessories"] = {"contract": 1, "accessories": [self.tool(a) for a in accs]}

    def refresh(self):
        with contextlib.redirect_stderr(io.StringIO()):
            self.runner.refresh_tools()

    def events(self):
        out = []
        while not self.q.empty():
            out.append(self.q.get_nowait())
        return out

    def test_retries_soon_while_the_hub_is_starting(self):
        self.hub.answers["/accessories"] = starting(5)
        self.refresh()
        self.assertEqual(self.runner.next_hub, self.now + 5, "照主控说的 retry_after")
        self.assertEqual(self.agent.notices["hub"], "螺壳还没准备好，工具过一会儿列出来。")
        self.assertIn("feed", [e for e, _ in self.events()], "那一句马上给窗口")
        self.hub.answers["/accessories"] = starting(None)
        self.refresh()
        self.assertEqual(self.runner.next_hub, self.now + runner_mod.HUB_RETRY * 2, "没说多久：2、4、8… 秒")
        self.runner.hub = os.path.join(self.dir, "gone.sock")      # 连不上
        self.refresh()
        self.assertEqual(self.runner.next_hub, self.now + 8)
        self.assertEqual(self.agent.notices["hub"], "螺壳没在运行，暂时找不到工具。")
        self.refresh()
        self.assertEqual(self.runner.next_hub, self.now + runner_mod.HUB_EVERY, "退避到平常的间隔为止")
        self.hub.answers["/accessories"] = starting(60)
        self.runner.hub = self.sock
        self.refresh()
        self.assertEqual(self.runner.next_hub, self.now + 60, "主控说的比退避长：至少等它说的")
        self.hub.answers["/accessories"] = starting(10 ** 6)
        self.refresh()
        self.assertEqual(self.runner.next_hub, self.now + runner_mod.HUB_WAIT_MAX, "说得太长的不全信")
        self.listed("luoke-scan")
        self.refresh()
        self.assertIn("luoke-scan", self.agent.sources, "主控起来了：工具马上列出来")
        self.assertNotIn("hub", self.agent.notices)
        self.assertEqual((self.runner.hub_misses, self.runner.next_hub), (0, self.now + runner_mod.HUB_EVERY))

    def test_refused_waits_long(self):
        self.hub.answers["/accessories"] = "refused"
        self.refresh()
        self.assertEqual(self.runner.next_hub, self.now + runner_mod.HUB_REFUSED_EVERY, "主控不认这一版：勤问也没用")

    def test_step_asks_when_due_and_naps_until_then(self):
        self.hub.answers["/accessories"] = starting(None)
        with contextlib.redirect_stderr(io.StringIO()):
            self.runner.step()                                   # 起来先问一次
            self.assertEqual(self.hub.hits, ["/accessories"])
            self.assertEqual(self.runner.nap(), runner_mod.HUB_RETRY, "2 秒后再问：不睡满一个 TICK")
            self.now += 1
            self.runner.step()
            self.assertEqual(len(self.hub.hits), 1, "还没到时候")
            self.now += 1
            self.runner.step()
            self.assertEqual(len(self.hub.hits), 2)
            self.listed()
            self.now += 4
            self.runner.step()
            self.assertEqual(self.runner.nap(), runner_mod.TICK, "平常：睡一个 TICK")
            self.now += runner_mod.HUB_EVERY - 1
            self.runner.step()
            self.assertEqual(len(self.hub.hits), 3)
            self.now += 1
            self.runner.step()
            self.assertEqual(len(self.hub.hits), 4, "平常每 HUB_EVERY 秒问一次")
            self.runner.poll_soon()
            self.runner.step()
            self.assertEqual(len(self.hub.hits), 5, "窗口打开：马上问")

    def test_changes_are_picked_up_and_the_same_list_does_nothing(self):
        self.listed("luoke-scan")
        self.refresh()
        scan = self.agent.sources["luoke-scan"]
        self.assertIn(("apps", {"app": "luoke-scan"}), self.events())
        calls = []
        scan.set_manifest = lambda *a, **k: calls.append(a)
        self.refresh()
        self.assertEqual((calls, self.events()), ([], []), "清单没变：什么都不动")
        self.listed("luoke-scan", "luoke-mail")
        self.refresh()
        self.assertIs(self.agent.sources["luoke-scan"], scan)
        self.assertIn("luoke-mail", self.agent.sources, "开启、装好的：下一次问就有")
        self.assertIn(("apps", {"app": "luoke-mail"}), self.events())
        self.listed("luoke-mail")
        self.refresh()
        self.assertNotIn("luoke-scan", self.agent.sources, "停用、卸载的：下一次问就撤")
        self.assertIn(("apps", {"app": "luoke-scan"}), self.events())
        self.hub.answers["/accessories"] = {"contract": 1, "accessories": [
            self.tool("luoke-mail", reports=[{"kind": "suspicious", "title": "可疑邮件", "urgency": "urgent"}])]}
        self.refresh()
        self.assertEqual(self.agent.sources["luoke-mail"].reports["suspicious"]["urgency"], "urgent", "升级了：清单跟着换")

    def test_hub_down_keeps_the_tools(self):
        self.listed("luoke-scan")
        self.refresh()
        self.runner.hub = os.path.join(self.dir, "gone.sock")
        self.refresh()
        self.assertIn("luoke-scan", self.agent.sources, "主控没在运行：先照旧")
        self.runner.hub = self.sock
        self.refresh()
        self.assertNotIn("hub", self.agent.notices)
        self.assertIn("luoke-scan", self.agent.sources)


if __name__ == "__main__":
    unittest.main()
