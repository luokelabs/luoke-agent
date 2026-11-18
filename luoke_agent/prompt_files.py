"""模型任务的提示词，放成文件（顶层 ADR 0019）：`luoke_agent/prompts/<任务>.system.txt`（固定说明）、
`<任务>.user.txt`（每次输入的措辞和顺序）、`<任务>.schema.json`（输出格式），有重试的任务再加 `<任务>.retry.txt`，
共用的句子放 `_shared.txt`。代码只读文件、填占位符，不在代码里写提示词。

文件里 `{{名字}}` 是要填的；`{{#名字}}…{{/名字}}` 是可选段，值为空整段不要。要填的没填、填了的文件里没有，
加载和填的时候就报错，不发出带窟窿的提示词。文件末尾的那个换行不算提示词的一部分。
`sha256` 是这个任务全部文件的指纹（评测证据里的 `prompt_sha256`）。只用标准库。"""
from __future__ import annotations

import hashlib
import json
import os
import re
from typing import Dict, List, Set, Tuple

DIR = os.path.join(os.path.dirname(os.path.abspath(__file__)), "prompts")
KINDS = (".system.txt", ".user.txt", ".retry.txt", ".schema.json")
PLACEHOLDER = re.compile(r"\{\{([a-z_]+)\}\}")
SECTION = re.compile(r"\{\{#([a-z_]+)\}\}(.*?)\{\{/\1\}\}", re.S)


class PromptError(ValueError):
    pass


def read(name: str) -> str:
    with open(os.path.join(DIR, name), encoding="utf-8") as f:
        text = f.read()
    return text[:-1] if text.endswith("\n") else text


def names(template: str, where: str) -> Set[str]:
    """模板里的占位符和可选段；`{{ }}` 里是别的写法就报错"""
    found = {m.group(1) for m in SECTION.finditer(template)} | set(PLACEHOLDER.findall(template))
    if "{{" in PLACEHOLDER.sub("", SECTION.sub(lambda m: m.group(2), template)):
        raise PromptError(f"{where}：有认不出的占位符")
    return found


def fill(template: str, values: Dict[str, object], where: str) -> str:
    """填好的模板：可选段照值留或去，每个 `{{名字}}` 填上。占位符和给的值要一一对上；填进去的字不再当占位符读"""
    wanted = names(template, where)
    if wanted != set(values):
        missing, extra = sorted(wanted - set(values)), sorted(set(values) - wanted)
        raise PromptError(f"{where}：" + "；".join(([f"没填 {missing}"] if missing else []) +
                                                  ([f"文件里没有 {extra}"] if extra else [])))
    kept = SECTION.sub(lambda m: m.group(2) if values[m.group(1)] else "", template)
    return PLACEHOLDER.sub(lambda m: str(values[m.group(1)]), kept)


def files(task: str) -> List[str]:
    """这个任务的文件，排好序：指纹算的就是这几个（编辑器留下的备份不算）"""
    return sorted(f for f in os.listdir(DIR) if f in {task + k for k in KINDS} or f == "_shared.txt")


def load(task: str, user: Tuple[str, ...]) -> dict:
    """一个任务发请求要的：{"system", "user"（模板）, "schema", "retry"（没有是 None）, "sha256", "files"}。
    `user` 是代码在 user.txt 里填的占位符：文件里要正好是这几个"""
    system = read(f"{task}.system.txt")
    if names(system, f"{task}.system.txt"):
        raise PromptError(f"{task}.system.txt：没有要填的，不能有占位符")
    template = read(f"{task}.user.txt")
    have = names(template, f"{task}.user.txt")
    if have != set(user):
        raise PromptError(f"{task}.user.txt：占位符是 {sorted(have)}，代码填的是 {sorted(user)}")
    h = hashlib.sha256()
    for f in files(task):
        with open(os.path.join(DIR, f), "rb") as fh:
            h.update(f.encode() + b"\0" + fh.read() + b"\0")
    retry = os.path.join(DIR, f"{task}.retry.txt")
    return {"system": system, "user": template, "schema": json.loads(read(f"{task}.schema.json")),
            "retry": read(f"{task}.retry.txt") if os.path.exists(retry) else None, "sha256": h.hexdigest(),
            "files": files(task)}
