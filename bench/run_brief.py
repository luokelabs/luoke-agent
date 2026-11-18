#!/usr/bin/env python3
"""把 `luoke-agent.brief` 的评测集（bench/brief_set.py）经螺壳主控跑一遍、打分。

  python3 bench/run_brief.py --hub SOCKET --label "..." [--out DIR] [--cases N] [--runs N]

主控要写明是哪一个，不自己去找：评测不发给日常在用的主控。每道题走应用自己的代码：`brief.messages` 拼请求，
和线上一样；`brief.problems` 核答案。每道题跑 `--runs` 遍（默认 3），每一遍都算。打分看模型的原始答案：

  硬性  任何一遍出现就不过：答案不合规矩（`brief.problems`：格式、超长、多行、编了数、提了 AI 这类）；
        那一段里有这道题的 `never`（夹带的指令的记号、网址）；有带刺的话（`STING`）
  软性  grounded     那一段里说到了列表里某一条（有它的字眼）的比例
        urgent_said  有急事的题里，那一段说到了急事的比例
        urgent_first 说到了急事的里面，急事的字眼出现在前半段的比例
        voice        带一点口气（问一句、语气词）的比例
        lecture      劝、提醒、催的比例（越低越好）

结果写到 bench/results/brief/<label>.json，带评测集的 sha256 和提示词的指纹，是出版证据。只用标准库，Python 3.9 起。"""
from __future__ import annotations

import argparse
import json
import os
import platform
import sys
import time

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, ROOT)
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

from luoke_agent import __version__, brief, hello  # noqa: E402
from luoke_agent.hub import Hub, Later  # noqa: E402
import brief_set as S  # noqa: E402
from hello_set import LECTURE, STING, VOICE  # noqa: E402
from run_hello import PATIENCE, rate, set_hash  # noqa: E402


def judge(case: dict, raw: str) -> dict:
    """一遍的答案：硬性错和几个软性的记号"""
    try:
        answer = json.loads(raw)
    except ValueError:
        return {"text": "", "hard": ["form"]}
    hard = list(brief.problems(answer, case["matters"]))
    text = " ".join(answer["text"].split()) if isinstance(answer, dict) and isinstance(answer.get("text"), str) else ""
    hard += [f"never:{w}" for w in case["never"] if w.lower() in text.lower()]
    hard += [f"sting:{w}" for w in STING if w in text]
    urgent = [m for m in case["matters"] if m["kind"] == "urgent"]
    at = min((text.find(k) for m in urgent for k in m["keys"] if k in text), default=-1)
    return {"text": text, "hard": hard,
            "grounded": any(k in text for m in case["matters"] for k in m["keys"] if k not in case["never"]),
            "urgent_said": at >= 0, "urgent_first": 0 <= at <= len(text) // 2,
            "voice": any(v in text for v in VOICE), "lecture": any(w in text for w in LECTURE)}


def score(results: list) -> dict:
    every = [r for c in results for r in c["runs"]]
    hard = [f"{c['id']}：{h}" for c in results for r in c["runs"] for h in r["hard"]]
    urgent = [r for c in results if c["kind"] == "urgent" for r in c["runs"]]
    return {"hard_failures": hard, "passed": not hard, "runs": len(every),
            "soft": {"grounded": rate(every, "grounded"), "urgent_said": rate(urgent, "urgent_said"),
                     "urgent_first": rate([r for r in urgent if r.get("urgent_said")], "urgent_first"),
                     "voice": rate(every, "voice"), "lecture": rate(every, "lecture")}}


def ask(hub: Hub, messages: list, waited: list) -> str:
    while True:
        try:
            return hub.chat(brief.TASK, messages, brief.SCHEMA)
        except Later as ex:
            wait = ex.retry_after or 30
            if waited[0] + wait > PATIENCE:
                raise
            print(f"主控说 {ex.code}：等 {wait:.0f} 秒", file=sys.stderr)
            time.sleep(wait)
            waited[0] += wait


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--hub", required=True, help="主控的 socket（写明哪一个；评测不发给日常在用的）")
    ap.add_argument("--label", required=True)
    ap.add_argument("--out")
    ap.add_argument("--cases", type=int, help="只跑前几道（试跑用，结果不算证据）")
    ap.add_argument("--runs", type=int, default=3)
    a = ap.parse_args()
    cases = S.cases()
    todo = cases[:a.cases] if a.cases else cases
    hub = Hub(a.hub)
    info = hub.task(brief.TASK)
    if not info:
        print("主控的配方里没有 luoke-agent.brief", file=sys.stderr)
        return 2
    waited, started, results = [0.0], time.time(), []
    for n, case in enumerate(todo, 1):
        messages = brief.messages(case["matters"], hello.today_words(case["day"], case["weekday"]))
        runs = [judge(case, ask(hub, messages, waited)) for _ in range(a.runs)]
        results.append({"id": case["id"], "kind": case["kind"], "runs": runs})
        print(f"[{n}/{len(todo)}] {case['id']}: {runs[-1]['text'] or '（没有）'} {runs[-1]['hard'] or ''}", file=sys.stderr)
    record = {"task": f"luoke-agent.{brief.TASK}", "label": a.label, "version": __version__, "model": hub.model,
              "task_info": info, "set_sha256": set_hash(cases), "prompt_sha256": brief.PROMPT["sha256"],
              "prompt_files": brief.PROMPT["files"], "cases": len(todo), "of": len(cases), "runs_per_case": a.runs,
              "partial": len(todo) != len(cases), "seconds": round(time.time() - started, 1),
              "waited_seconds": round(waited[0], 1), "machine": platform.machine(), "python": platform.python_version(),
              "score": score(results), "results": results}
    out = os.path.join(a.out or os.path.join(ROOT, "bench", "results"), "brief")
    os.makedirs(out, exist_ok=True)
    path = os.path.join(out, a.label.replace("/", "_").replace(" ", "_") + ".json")
    with open(path, "w", encoding="utf-8") as f:
        json.dump(record, f, ensure_ascii=False, indent=1)
    s = record["score"]
    print(json.dumps({"passed": s["passed"], "hard_failures": len(s["hard_failures"]), "soft": s["soft"], "file": path},
                     ensure_ascii=False))
    return 0 if s["passed"] else 1


if __name__ == "__main__":
    sys.exit(main())
