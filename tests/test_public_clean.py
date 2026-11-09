"""仓库要能公开：提交了的文件里不能有内部信息。规则照 luoke-core 发布前查的那份（tools/public_sync.py 的 GENERIC，
加上人名、机器名）：人名、机器名、私有仓库的名字和链接、内部仓库、对负责人的旧称呼、本机路径、内部和个人邮箱、令牌、私钥。
和那边一样不查 CLAUDE.md、CLAUDE.local.md、STATUS.md（公开导出时拿掉）和 vendor/、third_party/、licenses/。
规则存成 base64，免得这个文件自己被查出来。luoke-agent 公开以后，那边的公开仓库表会加上它，这里的也要跟着加。"""
from __future__ import annotations

import base64
import json
import os
import re
import subprocess
import unittest

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
RULES = [(name, re.compile(rx, re.I)) for name, rx in json.loads(base64.b64decode(
    "W1si5Lq65ZCN44CB5py65Zmo5ZCNIiwgIm5hbmN5fGJ1bmtlcnx6aGl4aWFuKD8haW98QGx1b2tlXFwuYWkpfGpvaG56fGtlaXRofGphc29ufH"
    "N0d2l0aHxcXGJsYXkyfFxcYjEwMFxcLlxcZCtcXC5cXGQrXFwuXFxkKyJdLCBbIuengeacieS7k+W6kyIsICJsdW9rZS1bYS16XSstcHJpdmF0"
    "ZVxcYnwoPzpnaXRodWJ8Z2l0bGFiKVxcLmNvbVsvOl1sdW9rZWxhYnMvKD8hKD86bHVva2V8bHVva2UtYXRsYXN8bHVva2UtY29udHJpYnV0ZX"
    "xsdW9rZS1jb3JlfGx1b2tlLWltZXxsdW9rZS1pbnRlcm5hbC1idWlsZHN8bHVva2UtbWFpbHxsdW9rZS1tZW18bHVva2UtcmVsZWFzZXN8bHVv"
    "a2Utc2NhbikoPzpcXC5naXQpPyg/IVtcXHctXXxcXC5cXHcpKVtcXHcuLV0rfCg/PCFbXFx3Li1dKWx1b2tlbGFicy8oPyEoPzpsdW9rZXxsdW"
    "9rZS1hdGxhc3xsdW9rZS1jb250cmlidXRlfGx1b2tlLWNvcmV8bHVva2UtaW1lfGx1b2tlLWludGVybmFsLWJ1aWxkc3xsdW9rZS1tYWlsfGx1"
    "b2tlLW1lbXxsdW9rZS1yZWxlYXNlc3xsdW9rZS1zY2FuKSg/OlxcLmdpdCk/KD8hW1xcdy1dfFxcLlxcdykpbHVva2VbXFx3Li1dKiJdLCBbIu"
    "WGhemDqOS7k+W6kyIsICJsdW9rZS0oPzpvcHN8bWVldGluZ3MpXFxiIl0sIFsi5YaF6YOo56ew5ZG8IiwgIuS4u+S6uiJdLCBbIuacrOacuui3"
    "r+W+hCIsICIvVXNlcnMvKD8hKD86bWV8eW91fHh8dXNlcnw8W14+XSo+KS8pW0EtWmEtejAtOS5fLV0rLyJdLCBbIuWGhemDqOmCrueusSIsIC"
    "IoPzwhW1xcdy4lKy1dKSg/IXpoaXhpYW5AbHVva2VcXC5haVxcYilbQS1aYS16MC05Ll8lKy1dK0AoPzpbXFx3LV0rXFwuKSpsdW9rZVxcLmFp"
    "XFxiIl0sIFsi5Liq5Lq66YKu566xIiwgIig/PCFbXFx3LiUrLV0pKD8hKD86bWV8eW91fHVzZXJ8dGVzdHxkZW1vfG5ld3x3b3JrfGhvbWV8W2"
    "Etel18MTIzNDUoPzo2KD86Nyg/OjgoPzo5KD86MCk/KT8pPyk/KT8pKD86KD86XFwrfCUyQilcXHcrKT9AKVtBLVphLXowLTkuXyUrLV0rQCg/"
    "OnZpcFxcLik/KD86Z21haWx8cXF8MTYzfDEyNnxvdXRsb29rfGhvdG1haWx8aWNsb3VkfG1lfGZveG1haWx8eWFob28pXFwuY29tIl0sIFsi5L"
    "uk54mMIiwgIlxcYmdoW3BvdXNyXV9bQS1aYS16MC05XXsyMCx9fFxcYmdpdGh1Yl9wYXRfW0EtWmEtejAtOV9dezIwLH18XFxiZ2xwYXQtW0Et"
    "WmEtejAtOV8tXXsyMCx9fFxcYmhmX1tBLVphLXowLTldezMwLH18XFxic2stYW50LVtBLVphLXowLTlfLV17MjAsfXxcXGJzay0oPzpwcm9qLX"
    "xzdmNhY2N0LXxhZG1pbi0pP1tBLVphLXowLTlfLV17NDAsfSJdLCBbIuengemSpSIsICItLS0tLUJFR0lOIFtBLVogXSpQUklWQVRFIEtFWS0t"
    "LS0tIl1d"
).decode("utf-8"))]
SESSION_FILES = ("CLAUDE.md", "CLAUDE.local.md", "STATUS.md")
SKIP = re.compile(r"(^|/)(vendor|third_party|licenses|runtime-licenses)/")


def tracked_files():
    try:
        out = subprocess.run(["git", "-c", "core.quotepath=off", "ls-files", "-z"], cwd=ROOT,
                             capture_output=True, check=True).stdout
    except (OSError, subprocess.CalledProcessError):
        return None
    return [f for f in out.decode("utf-8").split("\0") if f]


def hits_in(path: str, text: str) -> list:
    out = [f"{path}（文件名，{name}）" for name, rx in RULES if rx.search(path)]
    for i, line in enumerate(text.splitlines(), 1):
        out += [f"{path}:{i}（{name}）" for name, rx in RULES if rx.search(line)]
    return out


class PublicCleanTest(unittest.TestCase):
    def test_no_internal_words(self):
        files = tracked_files()
        if files is None:
            self.skipTest("不在 git 仓库里")
        hits = []
        for f in files:
            if os.path.basename(f) in SESSION_FILES or SKIP.search(f):
                continue
            try:
                with open(os.path.join(ROOT, f), encoding="utf-8") as fh:
                    text = fh.read()
            except (UnicodeDecodeError, IsADirectoryError, FileNotFoundError):
                text = ""   # 图片之类的只查文件名；删掉还没提交的
            hits += hits_in(f, text)
        self.assertEqual(hits, [], "这些地方有内部信息，公开前要改掉")

    def test_rules_catch_what_the_release_check_catches(self):
        bad_examples = json.loads(base64.b64decode("WyLop4EgZ2l0aHViLmNvbS9sdW9rZWxhYnMvbHVva2UtYnJhbmQvaXNzdWVzLzEiLCAibHVva2VsYWJzL2x1b2tlLWJyYW5kIzEiLCAic3NoIExheTJfU3R1ZGlvIiwgIi9Vc2Vycy9ib2IveCIsICJsdW9rZS1vcHMjMjkiLCAiYUBsdW9rZS5haSIsICLkuLvkurrlrprnmoQiXQ==").decode("utf-8"))   # 也存成 base64，理由同上
        for bad in bad_examples:
            self.assertTrue(hits_in("x.md", bad), bad)
        for ok in ["luoke-brand 的规范", "luokelabs/luoke-core#61", "me@example.com", "zhixian@luoke.ai", "zhixianio",
                   "github.com/luokelabs/luoke-scan."]:
            self.assertFalse(hits_in("x.md", ok), ok)


if __name__ == "__main__":
    unittest.main()
