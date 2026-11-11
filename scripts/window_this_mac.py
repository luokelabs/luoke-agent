#!/usr/bin/env python3
"""本机录一轮：照 agent 读工具的那几个请求（列工具、outbox、概览、权限、各页），问这台 Mac 上正在用的
邮件助手和螺壳扫描，答复存成场景样例的格式，再接上真核心生成窗口的示例，给 luoke-window-shots 画。

只读：不点按钮、不发 outbox_ack，工具的状态不变。
- 邮件助手：它的 agent.sock 只认螺壳的核心，不去连；在这个进程里起邮件助手的代码（和装好的同一版），数据用
  ~/.luoke-mail 的一份拷贝（设置、luoke.db），直接调它 agent socket 的处理函数（同一个 ToolServer.handle）。
  不连邮箱、不调模型、不连主控、不读钥匙串。
- 螺壳扫描：开发版的 luoke-scan 带 --this-mac --data <~/.luoke-scan 的一份拷贝>，只读拷贝，不查这台 Mac、
  不碰原来的数据目录；给了 --data 也不连真的主控（不写记忆、不调模型）。
输出只在 OUT 下（里面是真邮件和真路径），不进仓库，看完删掉。

    python3 scripts/window_this_mac.py --scan-bin <开发版 luoke-scan> --mail-repo <luoke-mail 检出> [--out 目录]
    LUOKE_WINDOW_SAMPLES=<目录>/samples LUOKE_WINDOW_SCENARIO=this-mac \
        swift run --package-path window luoke-window-shots <目录>/shots   # 画出来只在本机看

邮件助手的检出要和这台 Mac 上装的同一版（luoke-mail 的 tag），并排检出 luoke-mem（和它的测试一样）；
扫描用开发版（go build -o .build/go/luoke-scan ./cmd/luoke-scan）：装好的只认 --this-mac，不认 --data。
"""
import argparse
import datetime
import json
import os
import shutil
import subprocess
import sys
import tempfile

TEMPLATES = {"luoke-mail": "suspicious", "luoke-scan": "full-report"}
MAIL_HOME = os.path.expanduser("~/.luoke-mail")
SCAN_DATA = os.path.expanduser("~/.luoke-scan")
NAME = "this-mac"


def mail_handler(mail_repo, copy):
    """邮件助手 agent socket 的处理函数，照 Agent.start 那样建，不开 socket；数据是拷贝"""
    for f in ("config.json", "luoke.db", "account-salt"):
        if os.path.exists(os.path.join(MAIL_HOME, f)):
            shutil.copy(os.path.join(MAIL_HOME, f), copy)
    os.environ["LUOKE_MAIL_HOME"] = copy
    os.environ["LUOKE_HUB_SOCKET"] = "/nonexistent/hub.sock"
    os.environ["LUOKE_HUB_APPS"] = "/nonexistent/hub-apps"
    sys.path[:0] = [mail_repo, os.path.join(mail_repo, "tests")]
    from unittest import mock
    from luoke_mail import server, agent as agent_mod
    from luoke_mail.credstore import FileStore
    from luoke_mail.store import Store
    from test_background import FakeDesktop
    app = server.App(secret_store=FileStore(os.path.join(copy, "no-secrets.json")),
                     state_store=Store(os.path.join(copy, "luoke.db")), desktop_=FakeDesktop())
    # 有授权码的账号才算连上了：不读钥匙串，给临时的凭据文件里放个占位的（不会拿它去连邮箱）
    for m in app.cfg.get("accounts", []):
        app.secrets.set(server.MAIL_SECRET, m["address"], "placeholder-never-used")
    getattr(app, "_secret_known", {}).clear()   # 建 App 时已经按「没有授权码」记下了
    app.open_mailbox = lambda *_: (_ for _ in ()).throw(RuntimeError("录的时候不连邮箱"))
    with mock.patch.object(agent_mod._Tools, "start", lambda tools, path: tools):
        app.agent.start("/nonexistent/agent.sock")
    return lambda req: app.agent.server.handle(json.loads(json.dumps(req)))


def ask_scan(req, scan_bin, data):
    r = subprocess.run([scan_bin, "mcp", "--this-mac", "--data", data], input=json.dumps(req, ensure_ascii=False) + "\n",
                       stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True, timeout=120)
    if r.returncode != 0:
        raise SystemExit(f"luoke-scan mcp 退出码 {r.returncode}：{r.stderr[-400:]}")
    return json.loads(r.stdout.strip().splitlines()[-1])


def unwrap(reply):
    """和工具的样例一样：resources/read 的 contents[0].text 解开成 JSON 值"""
    for c in ((reply.get("result") or {}).get("contents") or []):
        if c.get("mimeType") == "application/json" and isinstance(c.get("text"), str):
            try:
                c["text"] = json.loads(c["text"])
            except ValueError:
                pass
    return reply


def record_tool(tool, template_dir, dest, ask):
    sc = json.load(open(os.path.join(template_dir, "scenario.json"), encoding="utf-8"))
    now = datetime.datetime.now(datetime.timezone.utc).replace(microsecond=0).isoformat().replace("+00:00", "Z")
    steps = [{"clock": now, "do": "这台 Mac 现在的样子（本机录的，只读）"}]
    os.makedirs(dest, exist_ok=True)
    shutil.copy(os.path.join(template_dir, "manifest.json"), dest)
    for st in sc["steps"]:
        f = st.get("file")
        if not f:
            continue
        if f.startswith("call-"):
            break            # 第一次点按以前的都是读的；点按不录
        req = json.load(open(os.path.join(template_dir, f), encoding="utf-8"))["request"]
        reply = unwrap(ask(req))
        if "error" in reply:
            print(f"  {tool} {f}：工具答了错误 {reply['error'].get('message')}", file=sys.stderr)
        json.dump({"request": req, "reply": reply}, open(os.path.join(dest, f), "w", encoding="utf-8"), ensure_ascii=False, indent=2, sort_keys=True)
        steps.append({"clock": now, "do": st.get("do", ""), "file": f})
    tz = os.path.realpath("/etc/localtime").split("zoneinfo/")[-1]
    sc.update(id=NAME, title="这台 Mac 现在的样子", steps=steps)
    sc.setdefault("produced", {})["tz"] = tz
    json.dump(sc, open(os.path.join(dest, "scenario.json"), "w", encoding="utf-8"), ensure_ascii=False, indent=2)
    print(f"{tool}：录了 {len(steps) - 1} 个请求")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--agent", default=os.path.dirname(os.path.dirname(os.path.abspath(__file__))), help="luoke-agent 的检出（默认这个）")
    ap.add_argument("--scan-bin", required=True)
    ap.add_argument("--mail-repo", required=True, help="luoke-mail 的检出（和装好的同一版）")
    ap.add_argument("--out", default=os.path.expanduser("~/Library/Caches/luoke-window-this-mac"), help="输出（真邮件、真路径）：不要放进仓库")
    a = ap.parse_args()
    fixtures = os.path.join(a.out, "fixtures")
    shutil.rmtree(fixtures, ignore_errors=True)
    copy = tempfile.mkdtemp(prefix="luoke-scan-copy-")
    try:
        shutil.copytree(SCAN_DATA, os.path.join(copy, "d"), symlinks=True,
                        ignore=shutil.ignore_patterns("*.lock"))
        scan_data = os.path.join(copy, "d")
        mail_copy = os.path.join(copy, "mail")
        os.makedirs(mail_copy)
        record_tool("luoke-mail", os.path.join(a.agent, "fixtures", "luoke-mail", TEMPLATES["luoke-mail"]),
                    os.path.join(fixtures, "luoke-mail", NAME), mail_handler(a.mail_repo, mail_copy))
        record_tool("luoke-scan", os.path.join(a.agent, "fixtures", "luoke-scan", TEMPLATES["luoke-scan"]),
                    os.path.join(fixtures, "luoke-scan", NAME), lambda req: ask_scan(req, a.scan_bin, scan_data))
    finally:
        shutil.rmtree(copy, ignore_errors=True)
    # 接上真核心：和 scripts/window_samples.py 一样（它一导入就把核心指到临时目录、打开拒绝真实位置的保护）
    sys.path.insert(0, os.path.join(a.agent, "scripts"))
    import window_samples  # noqa: E402
    from luoke_agent import replay_tool  # noqa: E402
    replay_tool.TIMEZONE = os.path.realpath("/etc/localtime").split("zoneinfo/")[-1]
    replay_tool.use_recording_timezone()
    samples = os.path.join(a.out, "samples")
    shutil.rmtree(samples, ignore_errors=True)
    for tool in TEMPLATES:
        d = window_samples.sample(os.path.join(fixtures, tool, NAME))
        os.makedirs(os.path.join(samples, tool), exist_ok=True)
        open(os.path.join(samples, tool, NAME + ".json"), "w", encoding="utf-8").write(window_samples.render(d))
        print(f"{tool}：窗口的示例写好了")
    print(f"画：LUOKE_WINDOW_SAMPLES={samples} LUOKE_WINDOW_SCENARIO={NAME} swift run --package-path window luoke-window-shots {a.out}/shots")


if __name__ == "__main__":
    main()
