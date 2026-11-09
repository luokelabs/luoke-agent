"""CI 的最后一步（.github/workflows/ci.yml 的「贴截图」）：把截图推到 ui-shots 分支，在 PR 上贴一条评论（有就更新）。

只用标准库。git、gh 走命令行，GH_TOKEN 由工作流给（git 也拿 gh 当凭证）。

--run 是 Swift 那一步的 artifact：shots/（PNG 和 index.json）、results.tsv、各步的日志。

ui-shots 分支：
  img/<sha256>.png          截图，按内容存，同一张图只存一次
  runs/<目标>/<短提交号>.json  这一次：提交、时间、测试结果、每张图的名字和 sha256
  runs/main/latest.json     main 最新的一次，PR 拿它比哪些界面变了
"""
from __future__ import annotations

import argparse
import datetime
import json
import os
import re
import shutil
import subprocess
import sys

MARK = "<!-- luoke-ui-shots -->"
BOT = "github-actions[bot]"
BOT_EMAIL = "41898282+github-actions[bot]@users.noreply.github.com"
HELPER = ["-c", "credential.helper=", "-c", "credential.helper=!gh auth git-credential"]
PYTHON_RESULT = {"success": "ok", "failure": "fail"}


def sh(*args, cwd=None, check=True):
    p = subprocess.run(list(args), cwd=cwd, text=True, capture_output=True)
    if check and p.returncode != 0:
        raise RuntimeError("%s 失败：%s" % (" ".join(args[:3]), (p.stderr or "").strip()[-500:]))
    return (p.stdout or "").strip()


def git(cwd, *args, check=True):
    return sh("git", *HELPER, "-c", "user.name=" + BOT, "-c", "user.email=" + BOT_EMAIL, *args, cwd=cwd, check=check)


def read_results(run, python):
    """Python 那一步的结果（工作流给的）加上 results.tsv 里 Swift 的几步，带从日志里数出来的测试条数"""
    out = [{"name": "Python 3.9、3.12", "result": PYTHON_RESULT.get(python, "skip"), "count": "", "log": "-"}]
    path = os.path.join(run, "results.tsv")
    if not os.path.exists(path):
        return out
    for line in open(path, encoding="utf-8"):
        name, result, _secs, log = line.rstrip("\n").split("\t")
        count = ""
        if os.path.exists(os.path.join(run, log)):
            text = open(os.path.join(run, log), encoding="utf-8", errors="replace").read()
            m = re.findall(r"Executed (\d+) tests?, with (\d+) failures?", text)
            if m:
                count = m[-1][0] if m[-1][1] == "0" else "%s，%s 项没过" % m[-1]
            if name == "截图" and os.path.isdir(os.path.join(run, "shots")):
                count = str(len([f for f in os.listdir(os.path.join(run, "shots")) if f.endswith(".png")])) + " 张"
        out.append({"name": name, "result": result, "count": count, "log": log})
    return out


def tail(run, log, n=30):
    path = os.path.join(run, log)
    if log == "-" or not os.path.exists(path):
        return ""
    lines = open(path, encoding="utf-8", errors="replace").read().splitlines()
    keep = [l for l in lines if re.search(r"error|FAIL|failed|Error|NO |画不出|AssertionError|Traceback", l)] or lines
    return "\n".join(keep[-n:])


def checkout_shots(d, repo):
    """ui-shots 分支的最新一版放进 d；分支还没有就建一个空的"""
    if not os.path.isdir(os.path.join(d, ".git")):
        os.makedirs(d, exist_ok=True)
        git(d, "init", "-q")
        git(d, "remote", "add", "origin", "https://github.com/%s.git" % repo)
    if git(d, "ls-remote", "--heads", "origin", "ui-shots"):
        git(d, "fetch", "-q", "--depth", "1", "origin", "ui-shots")
        git(d, "checkout", "-q", "-B", "ui-shots", "FETCH_HEAD")
        git(d, "reset", "-q", "--hard", "FETCH_HEAD")
        git(d, "clean", "-q", "-fd")
    else:
        git(d, "checkout", "-q", "--orphan", "ui-shots")
        with open(os.path.join(d, "README.md"), "w", encoding="utf-8") as f:
            f.write("# ui-shots\n\nluoke-agent 每个 PR 的界面截图，由 `.github/workflows/ci.yml` 推上来。"
                    "`img/` 按内容的 sha256 存，`runs/` 是每次检查的记录。不要往这个分支合别的东西。\n")
        git(d, "add", "README.md")
        git(d, "commit", "-q", "-m", "ui-shots: start")


def save(d, a, results, shots, summary):
    """截图和这一次的记录写进 d 并提交；返回 main 最新的那份截图（没有就 None）"""
    os.makedirs(os.path.join(d, "img"), exist_ok=True)
    for s in shots:
        dst = os.path.join(d, "img", s["sha256"] + ".png")
        if not os.path.exists(dst):
            shutil.copyfile(os.path.join(a.run, "shots", s["file"]), dst)
    latest = os.path.join(d, "runs", "main", "latest.json")
    base = json.load(open(latest, encoding="utf-8")).get("shots") if os.path.exists(latest) else None
    record = {"target": a.target, "sha": a.sha, "time": datetime.datetime.now().isoformat(timespec="seconds"),
              "run": a.run_url, "tests": results, "shots": shots}
    os.makedirs(os.path.join(d, "runs", a.target), exist_ok=True)
    with open(os.path.join(d, "runs", a.target, a.sha[:7] + ".json"), "w", encoding="utf-8") as f:
        json.dump(record, f, ensure_ascii=False, indent=1)
    if a.target == "main" and shots:
        with open(latest, "w", encoding="utf-8") as f:
            json.dump(record, f, ensure_ascii=False, indent=1)
    git(d, "add", "-A")
    if git(d, "status", "--porcelain"):
        git(d, "commit", "-q", "-m", "%s %s：%s" % ("main" if a.target == "main" else "PR #" + a.target, a.sha[:7], summary))
    return base


def img_url(repo, h):
    return "https://github.com/%s/blob/ui-shots/img/%s.png?raw=true" % (repo, h)


def comment_body(repo, sha, results, shots, base, run, run_url):
    lines = [MARK, "### 界面截图和测试（`%s`）" % sha[:7], ""]
    marks = {"ok": "✓", "fail": "✗", "skip": "–"}
    lines.append(" · ".join("%s %s%s" % (r["name"], marks.get(r["result"], "?"), (" " + r["count"]) if r["count"] else "")
                            for r in results))
    for r in results:
        if r["result"] == "fail":
            t = tail(run, r["log"])
            lines += ["", "<details open><summary>%s 没过</summary>" % r["name"], ""]
            lines += ["```", t, "```"] if t else ["看[这一次的日志](%s)。" % run_url]
            lines += ["</details>"]
    if not shots:
        lines += ["", "这次没有截图，看[这一次的日志](%s)。" % run_url]
    else:
        by = {}
        for s in shots:
            by.setdefault(s["name"], {"title": s["title"]})[s["theme"]] = s["sha256"]
        base_by = {(s["name"], s["theme"]): s["sha256"] for s in base or []}
        changed = [n for n, v in by.items() if base is not None
                   and any(base_by.get((n, t)) not in (None, v.get(t)) for t in ("light", "dark"))]
        new = [n for n in by if base is not None and not any((n, t) in base_by for t in ("light", "dark"))]

        def table(names):
            rows = ["| 界面 | 浅色 | 深色 |", "|---|---|---|"]
            for n in names:
                v = by[n]
                cells = []
                for t in ("light", "dark"):
                    h = v.get(t)
                    cells.append('<a href="%s"><img src="%s" width="420"></a>' % (img_url(repo, h), img_url(repo, h)) if h else "")
                rows.append("| %s<br>`%s` | %s | %s |" % (v["title"], n, cells[0], cells[1]))
            return rows

        lines.append("")
        if base is None:
            lines.append("main 还没有截图可比。")
        elif not changed and not new:
            lines.append("和 main 比：%d 个界面都没变。" % len(by))
        else:
            parts = (["变了 %d 个" % len(changed)] if changed else []) + (["新加 %d 个" % len(new)] if new else [])
            lines.append("和 main 比：" + "，".join(parts) + "（共 %d 个界面）。" % len(by))
            lines += ["", "<details open><summary>变了的和新加的</summary>", ""] + table(changed + new) + ["", "</details>"]
        lines += ["", "<details><summary>全部 %d 个界面（浅色、深色）</summary>" % len(by), ""] + table(list(by)) + ["", "</details>"]
    lines += ["", "<sub>每次推新提交后由 GitHub Actions 自动跑（[这一次](%s)）；截图在 `ui-shots` 分支。%s</sub>"
              % (run_url, datetime.datetime.now(datetime.timezone(datetime.timedelta(hours=8))).strftime("%m-%d %H:%M"))]
    return "\n".join(lines)


def upsert_comment(repo, pr, body, run):
    path = os.path.join(run, "comment.md")
    with open(path, "w", encoding="utf-8") as f:
        f.write(body)
    ids = sh("gh", "api", "--paginate", "repos/%s/issues/%s/comments" % (repo, pr), "--jq",
             '.[] | select(.user.login == "%s" and (.body | startswith("%s"))) | .id' % (BOT, MARK)).split()
    if ids:
        sh("gh", "api", "-X", "PATCH", "repos/%s/issues/comments/%s" % (repo, ids[-1]), "-F", "body=@" + path)
    else:
        sh("gh", "api", "-X", "POST", "repos/%s/issues/%s/comments" % (repo, pr), "-F", "body=@" + path)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--run", required=True, help="Swift 那一步的 artifact 目录")
    ap.add_argument("--work", required=True, help="放 ui-shots 分支的临时目录")
    ap.add_argument("--target", required=True, help="PR 号或 main")
    ap.add_argument("--sha", required=True)
    ap.add_argument("--repo", required=True)
    ap.add_argument("--python", default="", help="Python 那一步的结果（success、failure…）")
    ap.add_argument("--run-url", default="")
    a = ap.parse_args()

    os.makedirs(a.run, exist_ok=True)
    results = read_results(a.run, a.python)
    index_path = os.path.join(a.run, "shots", "index.json")
    shots = json.load(open(index_path, encoding="utf-8")) if os.path.exists(index_path) else []
    failed = [r["name"] for r in results if r["result"] == "fail"]
    summary = ("没过：" + "、".join(failed)) if failed else ("都过了，%d 张截图" % len(shots))

    base = None
    for attempt in range(4):  # 别的 PR 同时在推：拿最新的重做一遍
        checkout_shots(a.work, a.repo)
        base = save(a.work, a, results, shots, summary)
        if subprocess.run(["git", *HELPER, "push", "-q", "origin", "ui-shots"], cwd=a.work).returncode == 0:
            break
    else:
        raise RuntimeError("推 ui-shots 一直没成")

    body = comment_body(a.repo, a.sha, results, shots, base, a.run, a.run_url)
    if a.target != "main":
        upsert_comment(a.repo, a.target, body, a.run)
    summary_file = os.environ.get("GITHUB_STEP_SUMMARY")
    if summary_file:
        with open(summary_file, "a", encoding="utf-8") as f:
            f.write(body.replace(MARK, "") + "\n")
    print(summary)
    return 0


if __name__ == "__main__":
    sys.exit(main())
