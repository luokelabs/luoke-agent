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
import datetime
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


def sample(scenario_dir: str, tries: int = 3) -> dict:
    """一个场景接上真核心得来的样例。偶尔有一页读成「没在运行」（503：核心读页面时没连上回放的工具，原因还没找到，
    几十次里一次），样例就和上次的不一样：这种重来一遍，几次都这样才照实写下"""
    for n in range(tries):
        out = _sample(scenario_dir)
        flaky = any(isinstance(p, dict) and p.get("status") == 503 for p in out.get("pages", {}).values()) or \
            any(a.get("running") is False for a in (out.get("apps") or {}).get("apps", []))   # 同一回事：这一下没连上回放的工具
        if not flaky:
            return out
        sys.stderr.write(f"{os.path.basename(scenario_dir)}：有一页读成没在运行，重来（第 {n + 1} 次）\n")
    return out


def _sample(scenario_dir: str) -> dict:
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
    out.update(page_previews(out))
    return out


def page_previews(samples: dict) -> dict:
    """核心照原始数据拼的页（ADR 0028，luoke_agent/apppages）还没有应用录的样例时，用 fixtures/apppages 里照接口草案手写的数据
    拼出来看：拿一个录好的场景当底，标签和搬过来的页换成核心拼的"""
    from luoke_agent import a2ui, apppages
    from luoke_agent.apppages import clock
    # 钉住「现在」：页上写「今天」「昨天」、扫描算「本周」，不钉的话过一天示例就和重新生成的对不上
    clock.NOW = SAMPLE_NOW
    try:
        return _page_previews(samples, a2ui, apppages)
    finally:
        clock.NOW = None


# 拼示例页时的「现在」：照手写的原始数据那一天（fixtures/apppages 里的时间都在这之前）
SAMPLE_NOW = datetime.datetime(2026, 11, 13, 12, 0)


def _page_previews(samples: dict, a2ui, apppages) -> dict:
    out = {}
    base_dir = os.path.join(ROOT, "fixtures", "apppages")
    for tool in sorted(os.listdir(base_dir)) if os.path.isdir(base_dir) else []:
        mod = apppages.BUILDERS.get(tool)
        for f in sorted(os.listdir(os.path.join(base_dir, tool))):
            if mod is None or not f.endswith(".json"):
                continue
            with open(os.path.join(base_dir, tool, f), encoding="utf-8") as fh:
                spec = json.load(fh)
            if "base" not in spec:
                continue        # 只给测试用的原始数据（记忆的 data/ask），不拼成窗口的示例
            base = spec["base"] if "/" in spec["base"] else f"{tool}/{spec['base']}"
            d = json.loads(samples[base + ".json"])
            data = spec["data"]
            if not base.startswith(tool + "/"):
                # 应用自己还没有录好的场景（螺壳搜索）：借别的应用的场景当底，只留应用清单里这一个应用和核心拼的页
                d.update(app=tool, events=[], replies=[], asked=[], version=spec.get("version", ""), title=spec["_about"][:40])
                d["apps"] = {"apps": [dict({"id": tool, "needs": [], "pages": [], "running": True, "ui": None,
                                            "summary": {"count": 0, "text": ""}}, **spec.get("app", {}))]}
                d["pages"] = {}

            class Src:
                source = tool

            src = Src()
            src.data = [k.split("?")[0][len("data/"):] for k in data if k.startswith("data/")]
            d["apps"]["apps"][0]["pages"] = apppages.pages(src, d["apps"]["apps"][0]["pages"])
            for page in sorted(mod.BUILT):
                msgs = mod.build(page, dict(spec.get("args", {}).get(page, {})), lambda u: data[u])
                a2ui.build(msgs, page=True)        # 画不了就停：拼的页要过校验
                sid = f"{tool}/page/{page}"
                for m in msgs:
                    for body in m.values():
                        if isinstance(body, dict) and "surfaceId" in body:
                            body["surfaceId"] = sid
                d["pages"][page] = {"messages": msgs}
            d["_about"] = f"scripts/window_samples.py 用 fixtures/apppages/{tool}/{f} 照原始数据拼的页（{spec['_about']}），不要手改"
            d["scenario"] = f[:-5]
            out[os.path.join(tool, f)] = render(d)
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
