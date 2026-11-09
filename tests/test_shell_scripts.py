"""shell 脚本里紧跟中文标点的变量要加花括号。macOS 自带的 /bin/sh、/bin/bash 是 bash 3.2：UTF-8 下它把变量后面的
「（」「，」也读成变量名的一部分，`set -u` 时报没定义、退出 1（internal 版出包时 app/build_app.sh 因此失败，agent 被当成
可缺配件拿掉过）。"""
from __future__ import annotations

import os
import re
import unittest

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
BARE = re.compile(r"\$[A-Za-z_][A-Za-z0-9_]*(?=[^\x00-\x7f])")
SKIP = {"vendor", "third_party", "licenses", "build.noindex", "node_modules"}


def scripts():
    for d, dirs, files in os.walk(ROOT):
        dirs[:] = sorted(x for x in dirs if x not in SKIP and not x.startswith("."))
        for f in sorted(files):
            p = os.path.join(d, f)
            if f.endswith(".sh"):
                yield p
            elif "." not in f:
                try:
                    with open(p, "rb") as fh:
                        head = fh.readline()
                except OSError:
                    continue
                if head.startswith(b"#!") and re.search(rb"\b(?:ba)?sh\b", head):
                    yield p


class ShellScriptTests(unittest.TestCase):
    def test_variables_before_wide_punctuation_are_braced(self):
        bad = []
        for p in scripts():
            with open(p, encoding="utf-8") as f:
                for n, line in enumerate(f, 1):
                    if line.lstrip().startswith("#"):
                        continue
                    bad += [f"{os.path.relpath(p, ROOT)}:{n}: {m.group(0)}" for m in BARE.finditer(line)]
        self.assertEqual(bad, [], "紧跟中文标点的变量写成 ${名字}")

    def test_the_rule_catches_the_line_that_broke(self):
        self.assertTrue(BARE.search('echo "$app（$bundle_id $version）"'))
        self.assertIsNone(BARE.search('echo "${app}（${bundle_id} ${version}）"'))
        self.assertTrue(any(p.endswith(os.path.join("app", "build_app.sh")) for p in scripts()))


if __name__ == "__main__":
    unittest.main()
