"""开发沙盒：假记忆 + 假的邮件工具 + 开发版「螺壳 agent（开发）.app」，一切都在一个临时目录里，不碰日常在用的东西。

    python3 scripts/dev_sandbox.py [--dir 目录] [--no-open]

先跑 app/build_app.sh。按 Ctrl-C 停：停掉自己起的假工具（按 PID），开发版的 app 请从菜单栏退出。
目录默认 tempfile.mkdtemp()（Unix socket 路径最长 104 字节，别放太深）。
"""
import argparse
import os
import signal
import subprocess
import sys
import tempfile
import time

HERE = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, HERE)
from luoke_agent.devdata import make_sample_memory  # noqa: E402


def main() -> int:
    p = argparse.ArgumentParser()
    p.add_argument("--dir", help="沙盒目录（默认新建一个临时目录）")
    p.add_argument("--no-open", action="store_true", help="只起假工具，不开 app")
    p.add_argument("--python", default="/usr/bin/python3", help="核心用哪个 Python（开发版必须显式给）")
    a = p.parse_args()
    d = os.path.abspath(a.dir or tempfile.mkdtemp(prefix="la-dev"))
    os.makedirs(d, exist_ok=True)
    mem = os.path.join(d, "mem.db")
    if not os.path.exists(mem):
        make_sample_memory(mem)
    tool = os.path.join(d, "t", "agent.sock")
    home = os.path.join(d, "agent")
    fake = subprocess.Popen([sys.executable, "-m", "luoke_agent.fake_tool", "--socket", tool], cwd=HERE)
    args = ["--home", home, "--memory", mem, "--tool", f"fake-mail={tool}", "--python", a.python]
    print(f"沙盒：{d}\n假工具 PID {fake.pid}：{tool}")
    print("核心的界面接口：" + os.path.join(home, "run", "agent.sock"))
    app = os.path.join(HERE, "build.noindex", "螺壳 agent.app")
    if not a.no_open:
        if not os.path.isdir(app):
            print("先跑 app/build_app.sh", file=sys.stderr)
        else:
            subprocess.run(["open", "-n", app, "--args"] + args, check=False)
            print("已打开开发版：" + app)
    print("看卡片：python3 -m luoke_agent feed --home " + home)
    stop = [False]
    signal.signal(signal.SIGINT, lambda *_: stop.__setitem__(0, True))
    signal.signal(signal.SIGTERM, lambda *_: stop.__setitem__(0, True))
    while not stop[0] and fake.poll() is None:
        time.sleep(0.5)
    if fake.poll() is None:
        fake.terminate()
        fake.wait(5)
    return 0


if __name__ == "__main__":
    sys.exit(main())
