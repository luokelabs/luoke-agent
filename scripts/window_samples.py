#!/usr/bin/env python3
"""窗口的示例数据从工具的场景样例来，不手写（docs/工具协议.md「场景样例」）。

每个场景（fixtures/<工具>/<场景>/，工具录的真实答复）接上真核心（luoke_agent/replay_tool.py），把窗口这时连上来会拿到的
（`/feed` 先给的那一串、`/apps`、应用的每一页、`/permissions`）存成 window/Sources/LuokeWindow/Resources/samples/<工具>/<场景>.json。
窗口的 `Sample` 拿它画「接上核心」的截图。

    python3 scripts/window_samples.py            # 重新生成
    python3 scripts/window_samples.py --check    # 生成进内存和仓库里的比，不一样就列出来、退出码 1（测试里也跑）

核心问了样例里没有的东西（outbox_ack 除外，见 replay_tool），也退出码 1：两边对不上，要工具补录或核心改。
"""
from __future__ import annotations

import argparse
import contextlib
import io
import json
import os
import sys
import tempfile

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
FIXTURES = os.path.join(ROOT, "fixtures")
OUT = os.path.join(ROOT, "window", "Sources", "LuokeWindow", "Resources", "samples")

# 和测试一样，先把一切指到临时目录、打开"拒绝真实位置"的保护（luoke_agent/safety.py），再导入 luoke_agent
os.environ["LUOKE_AGENT_TESTING"] = "1"
_home = tempfile.mkdtemp(prefix="la-samples")
os.environ["LUOKE_HOME"] = os.path.join(_home, "luoke")
os.environ["LUOKE_HUB_SOCKET"] = os.path.join(_home, "no-hub.sock")
sys.path.insert(0, ROOT)

from luoke_agent import replay_tool  # noqa: E402


def commit_of(tool_dir: str) -> str:
    try:
        with open(tool_dir + ".VERSION", encoding="utf-8") as f:
            for line in f:
                if line.startswith("commit "):
                    return line.split()[1]
    except OSError:
        pass
    return ""


def manifest_version(scenario_dir: str) -> str:
    """配件清单里的版本（螺壳.app 报装了哪些应用时带的就是它）"""
    try:
        with open(os.path.join(scenario_dir, "manifest.json"), encoding="utf-8") as f:
            return str(json.load(f).get("version", ""))
    except (OSError, ValueError):
        return ""


def sample(scenario_dir: str) -> dict:
    tool_dir = os.path.dirname(scenario_dir)
    tool, name = os.path.basename(tool_dir), os.path.basename(scenario_dir)
    log = io.StringIO()
    s = replay_tool.Session(scenario_dir)
    try:
        with contextlib.redirect_stderr(log):   # 走到那一段之前读不到的（样例没录）核心会说一句，不是毛病
            s.run()
            snap = s.snapshot()
        stage = s.replay.window_stage
        missing = s.replay.unmatched(stage=stage)
        asked = s.replay.asked(stage)
        host = s.replay.host_report()
        clock = replay_tool.iso_utc(s.clock.t)
    finally:
        s.close()
    if missing:
        sys.stderr.write(log.getvalue())
        raise SystemExit(f"{tool}/{name}：核心问了样例里没有的 " + "、".join(
            "/".join(replay_tool.request_key(m)) for m in missing))
    return {
        "replies": replies(tool, scenario_dir),
        "_about": f"scripts/window_samples.py 用 fixtures/{tool}/{name}（{tool} {commit_of(tool_dir)[:12]}）接上真核心生成的，不要手改",
        "app": tool, "scenario": name, "title": s.replay.scenario.get("title", ""), "version": manifest_version(scenario_dir),
        # 核心读权限、读页面是并发的，先后每次不一样：排好序，--check 才不会时过时不过
        "clock": clock, "host": host, "asked": sorted(asked), **snap,
    }


def replies(tool: str, scenario_dir: str) -> list:
    """用户在卡片上点了按钮、工具答复了一张卡片的（call-*.json）：窗口截「点完以后」的样子时，把它换到那张卡片上"""
    out = []
    for f in sorted(os.listdir(scenario_dir)):
        if not (f.startswith("call-") and f.endswith(".json")):
            continue
        with open(os.path.join(scenario_dir, f), encoding="utf-8") as fh:
            d = json.load(fh)
        ua = (((d.get("request") or {}).get("params") or {}).get("_meta") or {}).get("ai.luoke/user-action") or {}
        card = ((((d.get("reply") or {}).get("result") or {}).get("structuredContent")) or {}).get("card")
        if ua.get("surfaceId") and card:
            sid = f"{tool}/{ua['surfaceId']}"
            msgs = []
            for m in card:   # 和核心转给窗口时一样：卡片 id 前面加上应用
                m = json.loads(json.dumps(m))
                for body in m.values():
                    if isinstance(body, dict) and "surfaceId" in body:
                        body["surfaceId"] = sid
                msgs.append(m)
            text = "".join(c.get("text", "") for c in ((d.get("reply") or {}).get("result") or {}).get("content") or []
                           if c.get("type") == "text")
            out.append({"file": f, "surface": sid, "card": msgs, "text": text})
    return out


def render(d: dict) -> str:
    return json.dumps(d, ensure_ascii=False, indent=1, sort_keys=True) + "\n"


def build() -> dict:
    replay_tool.use_recording_timezone()
    out = {}
    for sc in replay_tool.scenarios(FIXTURES):
        tool, name = os.path.basename(os.path.dirname(sc)), os.path.basename(sc)
        out[os.path.join(tool, name + ".json")] = render(sample(sc))
    return out


def main(argv=None) -> int:
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("--check", action="store_true", help="只比，不写")
    a = ap.parse_args(argv)
    want = build()
    have = {}
    for dirpath, _dirs, files in os.walk(OUT):
        for f in files:
            if f.endswith(".json"):
                p = os.path.join(dirpath, f)
                with open(p, encoding="utf-8") as fh:
                    have[os.path.relpath(p, OUT)] = fh.read()
    if a.check:
        bad = sorted(k for k in set(want) | set(have) if want.get(k) != have.get(k))
        if bad:
            print("窗口的示例和场景样例对不上（重新生成：python3 scripts/window_samples.py）：", file=sys.stderr)
            for k in bad:
                print("  " + ("多了 " if k not in want else "少了 " if k not in have else "变了 ") + k, file=sys.stderr)
            return 1
        print(f"窗口的示例：{len(want)} 个场景，和样例一致")
        return 0
    for k in set(have) - set(want):
        os.remove(os.path.join(OUT, k))
    for k, text in want.items():
        p = os.path.join(OUT, k)
        os.makedirs(os.path.dirname(p), exist_ok=True)
        with open(p, "w", encoding="utf-8") as fh:
            fh.write(text)
    print(f"写了 {len(want)} 个场景：{os.path.relpath(OUT, ROOT)}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
