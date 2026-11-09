"""主控换了版本、核心跑着的 Python 被换掉：核心自己退出（退出码 75），壳马上用新的那份重起。"""
from __future__ import annotations

import os as _os

assert _os.environ.get("LUOKE_AGENT_TESTING") == "1", "用 python3 -m unittest 跑：tests/__init__.py 先把一切指到临时目录"

import os
import shutil
import subprocess
import sys
import tempfile
import time
import unittest

from luoke_agent.__main__ import LOCKED_EXIT, RESTART_EXIT, hold_lock, python_identity

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))


class RestartTest(unittest.TestCase):
    def setUp(self):
        self.dir = tempfile.mkdtemp(prefix="la")

    def tearDown(self):
        shutil.rmtree(self.dir, ignore_errors=True)

    def test_identity_changes_when_the_file_is_replaced(self):
        f = os.path.join(self.dir, "py")
        with open(f, "w") as fh:
            fh.write("a")
        before = python_identity(f)
        tmp = f + ".new"
        with open(tmp, "w") as fh:
            fh.write("b")
        os.replace(tmp, f)
        self.assertNotEqual(python_identity(f), before)
        os.remove(f)
        self.assertIsNone(python_identity(f), "换版本的那一刻不在：不算换了")

    def test_one_core_per_data_directory(self):
        home = os.path.join(self.dir, "agent")
        os.makedirs(home)
        first = hold_lock(home)
        self.assertIsNotNone(first)
        self.assertIsNone(hold_lock(home), "另一个核心拿着：拿不到")
        p = subprocess.run([sys.executable, "-B", "-m", "luoke_agent", "serve", "--home", home,
                            "--memory", os.path.join(self.dir, "mem.db")],
                           cwd=ROOT, capture_output=True, text=True, timeout=30)
        self.assertEqual(p.returncode, LOCKED_EXIT, p.stderr)
        self.assertIn("已经有一个核心在跑", p.stderr)
        self.assertFalse(os.path.exists(os.path.join(home, "state.db")), "不碰正在跑的那个的状态库")
        os.close(first)
        again = hold_lock(home)
        self.assertIsNotNone(again, "那个退出了：就能拿到")
        os.close(again)

    def test_core_exits_for_a_restart_when_its_python_is_replaced(self):
        py = os.path.join(self.dir, "python3")
        os.symlink(os.path.realpath(sys.executable), py)
        home = os.path.join(self.dir, "agent")
        os.makedirs(home)
        p = subprocess.Popen([py, "-B", "-m", "luoke_agent", "serve", "--home", home,
                              "--memory", os.path.join(self.dir, "mem.db")],
                             cwd=ROOT, env=dict(os.environ, LUOKE_AGENT_PYTHON=py), stdout=subprocess.DEVNULL, stderr=subprocess.PIPE)
        try:
            time.sleep(1.5)
            self.assertIsNone(p.poll(), "核心起来了")
            other = os.path.join(self.dir, "other")
            shutil.copy(os.path.realpath(sys.executable), other)    # 内容一样、文件换了，像换版本那样
            tmp = py + ".new"
            os.symlink(other, tmp)
            os.replace(tmp, py)
            code = p.wait(timeout=15)
        finally:
            if p.poll() is None:
                p.kill()
                p.wait()
            p.stderr.close()
        self.assertEqual(code, RESTART_EXIT)

    def test_core_exits_for_a_restart_when_its_python_moves_away(self):
        """主控改名、挪了地方：原来的路径一直不在，过一会儿也退出重起（壳按 bundle id 重新找主控）。"""
        py = os.path.join(self.dir, "python3")
        os.symlink(os.path.realpath(sys.executable), py)
        home = os.path.join(self.dir, "agent")
        os.makedirs(home)
        p = subprocess.Popen([py, "-B", "-m", "luoke_agent", "serve", "--home", home,
                              "--memory", os.path.join(self.dir, "mem.db")], cwd=ROOT,
                             env=dict(os.environ, LUOKE_AGENT_PYTHON=py, LUOKE_AGENT_PYTHON_GONE_SECONDS="3"),
                             stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        try:
            time.sleep(1.5)
            self.assertIsNone(p.poll())
            os.remove(py)
            code = p.wait(timeout=20)
        finally:
            if p.poll() is None:
                p.kill()
                p.wait()
        self.assertEqual(code, RESTART_EXIT)


if __name__ == "__main__":
    unittest.main()
