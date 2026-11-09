"""scripts/vendor-luoke-mem.sh：拷完先单独导入一遍，导入不了就报错、vendor/ 里原来那份不动。
luoke_mem 0.28.0 只带三个模块导入不了（导入时要读 prompts/labels.json），之前的脚本照样拷进来、退出 0，
要到 agent 退回自带的那份时才出错。这里用一个假的 luoke-mem 仓库，不碰真的 vendor/。"""
from __future__ import annotations

import os
import shutil
import subprocess
import sys
import tempfile
import unittest

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SCRIPT = os.path.join(ROOT, "scripts", "vendor-luoke-mem.sh")

GOOD_MEMORY = 'from .sensitive import kinds\nLABELS = {"a": "甲"}\n'
# 0.28.0 那样：导入时就去读包里的 prompts/labels.json，只拷三个模块就没有这个文件
BAD_MEMORY = ('import json, os\nfrom .sensitive import kinds\n'
              'with open(os.path.join(os.path.dirname(os.path.abspath(__file__)), "prompts", "labels.json")) as f:\n'
              '    LABELS = json.load(f)\n')


def git(cwd: str, *args: str) -> str:
    return subprocess.run(["git", "-c", "user.name=test", "-c", "user.email=test@example.invalid", "-c", "commit.gpgsign=false",
                           *args], cwd=cwd, check=True, capture_output=True, text=True).stdout.strip()


@unittest.skipUnless(shutil.which("git"), "要 git")
class VendorMemTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.mkdtemp()
        self.addCleanup(shutil.rmtree, self.tmp)
        # 假的 agent 仓库：只有脚本和一份旧的 vendor
        self.agent = os.path.join(self.tmp, "agent")
        os.makedirs(os.path.join(self.agent, "scripts"))
        shutil.copy(SCRIPT, os.path.join(self.agent, "scripts"))
        self.vendor = os.path.join(self.agent, "vendor")
        os.makedirs(os.path.join(self.vendor, "luoke_mem"))
        self.write(os.path.join(self.vendor, "luoke_mem", "__init__.py"), '__version__ = "0.1.0"\n')
        self.write(os.path.join(self.vendor, "luoke_mem.VERSION"), "luoke_mem 0.1.0\ncommit old\n")
        # 假的 luoke-mem 仓库：先是好的一版，再是导入时要读 prompts/ 的一版
        self.mem = os.path.join(self.tmp, "luoke-mem")
        os.makedirs(os.path.join(self.mem, "luoke_mem", "prompts"))
        git(self.mem, "init", "-q")
        self.write(os.path.join(self.mem, "LICENSE"), "MIT\n")
        self.write(os.path.join(self.mem, "luoke_mem", "__init__.py"), '__version__ = "0.2.0"\nfrom .memory import LABELS\n')
        self.write(os.path.join(self.mem, "luoke_mem", "sensitive.py"), "kinds = ()\n")
        self.write(os.path.join(self.mem, "luoke_mem", "memory.py"), GOOD_MEMORY)
        self.write(os.path.join(self.mem, "luoke_mem", "prompts", "labels.json"), '{"a": "甲"}\n')
        git(self.mem, "add", "-A")
        git(self.mem, "commit", "-q", "-m", "good")
        self.good = git(self.mem, "rev-parse", "HEAD")
        self.write(os.path.join(self.mem, "luoke_mem", "__init__.py"), '__version__ = "0.3.0"\nfrom .memory import LABELS\n')
        self.write(os.path.join(self.mem, "luoke_mem", "memory.py"), BAD_MEMORY)
        git(self.mem, "commit", "-q", "-am", "bad")
        self.bad = git(self.mem, "rev-parse", "HEAD")

    @staticmethod
    def write(path: str, text: str) -> None:
        with open(path, "w", encoding="utf-8") as f:
            f.write(text)

    @staticmethod
    def read(path: str) -> str:
        with open(path, encoding="utf-8") as f:
            return f.read()

    def run_script(self, rev: str) -> subprocess.CompletedProcess:
        env = dict(os.environ, PYTHON=sys.executable)
        return subprocess.run(["/bin/sh", os.path.join(self.agent, "scripts", "vendor-luoke-mem.sh"), self.mem, rev],
                              env=env, capture_output=True, text=True, timeout=60)

    def leftovers(self):
        return [n for n in os.listdir(self.vendor) if n.startswith(".luoke_mem.")]

    def test_copy_that_cannot_import_is_refused_and_old_copy_kept(self):
        r = self.run_script(self.bad)
        self.assertNotEqual(r.returncode, 0, r.stdout + r.stderr)
        self.assertIn("导入不了", r.stderr)
        self.assertIn("labels.json", r.stderr)
        self.assertEqual(self.read(os.path.join(self.vendor, "luoke_mem", "__init__.py")), '__version__ = "0.1.0"\n')
        self.assertEqual(self.read(os.path.join(self.vendor, "luoke_mem.VERSION")), "luoke_mem 0.1.0\ncommit old\n")
        self.assertEqual(self.leftovers(), [])

    def test_good_copy_replaces_vendor_with_three_modules_and_license(self):
        r = self.run_script(self.good)
        self.assertEqual(r.returncode, 0, r.stdout + r.stderr)
        self.assertEqual(sorted(os.listdir(os.path.join(self.vendor, "luoke_mem"))),
                         ["LICENSE", "__init__.py", "memory.py", "sensitive.py"])
        self.assertEqual(self.read(os.path.join(self.vendor, "luoke_mem.VERSION")), f"luoke_mem 0.2.0\ncommit {self.good}\n")
        self.assertEqual(self.leftovers(), [])


if __name__ == "__main__":
    unittest.main()
