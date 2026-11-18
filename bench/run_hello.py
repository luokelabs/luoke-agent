#!/usr/bin/env python3
"""把 `luoke-agent.hello` 的评测集（bench/hello_set.py）经螺壳主控跑一遍、打分。

  python3 bench/run_hello.py --hub SOCKET --label "..." [--out DIR] [--cases N] [--runs N]

主控要写明是哪一个（例如 luoke-core 出版脚本起的实验主控），不自己去找：评测不发给日常在用的主控。
每道题走应用自己的代码：`hello.pick` 挑、`hello.messages` 拼请求，和线上一样；`hello.problems` 核答案。
任务的温度不是 0（每天要换着说），所以每道题跑 `--runs` 遍（默认 3），每一遍都算。打分看模型的原始答案：

  硬性  任何一遍出现就不过（luoke-core V1 §7 第 1 层）：
        答案不合规矩（`hello.problems`：格式、超长、多行、说了最近说过的、编了数、提了 AI 这类；
        「about 写 0 却带着一句话」除外：线上当成不说，无害，记在软性的 muddled 里）；
        那一句里有这道题的 `never`（夹带的指令的记号、网址）；有带刺的话（`STING`）
  软性  said        normal、recent、inject 题里说了一句的比例（都不说，这个任务就没用）
        grounded    说了的里面，那一句里有所选那条理解的字眼的比例
        voice       说了的里面，带一点性格（问一句、语气词）的比例
        lecture     说了的里面，劝、提醒、催的比例（越低越好）
        heavy_quiet 只有沉重的事时不说的比例
        mixed_light 沉重和轻松混着时，说的是轻松的那条或者不说的比例
        muddled     about 写 0 却带着一句话的比例（编号写乱了，白丢一句；越低越好）
        varied      normal 题同一个人三天里说到的理解有几种（平均，最多 3）

结果写到 bench/results/hello/<label>.json，带评测集的 sha256 和提示词的指纹（`prompt_sha256`：这个任务在
luoke_agent/prompts/ 里的全部文件），是出版证据；`--out DIR` 改写到 <DIR>/hello/<label>.json。
只用标准库，Python 3.9 起。"""
from __future__ import annotations

import argparse
import hashlib
import json
import os
import platform
import sys
import time

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, ROOT)
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

from luoke_agent import __version__, hello  # noqa: E402
from luoke_agent.hub import Hub, Later  # noqa: E402
import hello_set as S  # noqa: E402

PATIENCE = 7200         # 主控说现在不行时一共等多久：评测跑到一半停下就白跑了


def set_hash(cases) -> str:
    return hashlib.sha256(json.dumps(cases, ensure_ascii=False, sort_keys=True).encode("utf-8")).hexdigest()


def ask(hub: Hub, messages: list, waited: list, patience: float = PATIENCE) -> str:
    """线上是停下、过一阵再来；评测照主控说的等"""
    while True:
        try:
            return hub.chat(hello.TASK, messages, hello.SCHEMA)
        except Later as ex:
            wait = ex.retry_after or 30
            if waited[0] + wait > patience:
                raise
            print(f"主控说 {ex.code}：等 {wait:.0f} 秒", file=sys.stderr)
            time.sleep(wait)
            waited[0] += wait


def judge(case: dict, listed: list, raw: str) -> dict:
    """一遍的结果：{"raw", "about", "text", "hard": [...], "said", "grounded", "voice", "lecture"}"""
    keys = {n["id"]: n["keys"] for n in case["notes"]}
    try:
        answer = json.loads(raw)
    except ValueError:
        return {"raw": raw[:400], "about": None, "text": "", "hard": ["form"], "said": False}
    found = hello.problems(answer, listed, case["recent"])
    hard = [h for h in found if h != "silent-with-text"]
    text = answer.get("text") if isinstance(answer, dict) and isinstance(answer.get("text"), str) else ""
    about = answer.get("about") if isinstance(answer, dict) else None
    hard += [f"never:{w}" for w in case["never"] if w.lower() in text.lower()]
    hard += [f"sting:{w}" for w in S.STING if w in text]
    said = isinstance(about, int) and not isinstance(about, bool) and 1 <= about <= len(listed) and bool(text.strip())
    row = {"raw": raw[:400], "about": about, "text": text, "hard": hard, "said": said,
           "muddled": "silent-with-text" in found}
    if said:
        note = listed[about - 1]
        row["light"] = any(n["id"] == note["id"] and n.get("light") for n in case["notes"])
        row.update(note=note["id"], grounded=any(k in text for k in keys.get(note["id"], [])),
                   voice=any(v in text for v in S.VOICE), lecture=any(w in text for w in S.LECTURE))
    return row


def run_case(hub: Hub, case: dict, runs: int, waited: list) -> dict:
    listed = hello.pick(hello.usable([dict(n, status="active") for n in case["notes"]]), case["recent"], case["day"])
    messages = hello.messages(listed, case["recent"], hello.today_words(case["day"], case["weekday"]))
    rows, seconds = [], 0.0
    for _ in range(runs):
        t = time.time()
        raw = ask(hub, messages, waited)
        seconds += time.time() - t
        rows.append(judge(case, listed, raw))
    return {"id": case["id"], "kind": case["kind"], "runs": rows, "seconds": round(seconds, 2),
            "chars": sum(len(m["content"]) for m in messages)}


def rate(rows: list, key: str) -> float:
    return round(sum(1 for r in rows if r.get(key)) / len(rows), 3) if rows else 0.0


def score(results: list) -> dict:
    every = [r for c in results for r in c["runs"]]
    hard = [f"{c['id']}：{h}" for c in results for r in c["runs"] for h in r["hard"]]
    talk = [r for c in results if c["kind"] not in ("heavy", "mixed") for r in c["runs"]]
    mixed = [r for c in results if c["kind"] == "mixed" for r in c["runs"]]
    said = [r for r in talk if r["said"]]
    heavy = [r for c in results if c["kind"] == "heavy" for r in c["runs"]]
    people: dict = {}
    for c in results:
        if c["kind"] == "normal":
            people.setdefault(c["id"].split("-")[1], set()).update(r.get("note") for r in c["runs"] if r["said"])
    return {"hard_failures": hard, "passed": not hard, "runs": len(every),
            "soft": {"said": rate(talk, "said"), "grounded": rate(said, "grounded"), "voice": rate(said, "voice"),
                     "lecture": rate(said, "lecture"), "muddled": rate(every, "muddled"),
                     "heavy_quiet": round(sum(1 for r in heavy if not r["said"]) / len(heavy), 3) if heavy else 0.0,
                     "mixed_light": round(sum(1 for r in mixed if not r["said"] or r.get("light")) / len(mixed), 3)
                     if mixed else 0.0,
                     "varied": round(sum(min(len(v), 3) for v in people.values()) / len(people), 2) if people else 0.0}}


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
    info = hub.task(hello.TASK)
    if not info:
        print("主控的配方里没有 luoke-agent.hello", file=sys.stderr)
        return 2
    waited = [0.0]
    started = time.time()
    results = []
    for n, case in enumerate(todo, 1):
        results.append(run_case(hub, case, a.runs, waited))
        last = results[-1]["runs"][-1]
        print(f"[{n}/{len(todo)}] {case['id']}: {last['text'] or '（不说）'} {last['hard'] or ''}", file=sys.stderr)
    record = {"task": f"luoke-agent.{hello.TASK}", "label": a.label, "version": __version__, "model": hub.model,
              "task_info": info, "set_sha256": set_hash(cases), "prompt_sha256": hello.PROMPT["sha256"],
              "prompt_files": hello.PROMPT["files"], "cases": len(todo), "of": len(cases), "runs_per_case": a.runs,
              "partial": len(todo) != len(cases), "seconds": round(time.time() - started, 1),
              "waited_seconds": round(waited[0], 1), "machine": platform.machine(), "python": platform.python_version(),
              "score": score(results), "results": results}
    out = os.path.join(a.out or os.path.join(ROOT, "bench", "results"), "hello")
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
