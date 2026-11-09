"""开发和测试用的假记忆：内容全是虚构的。只往给定的路径写，不碰真实的记忆。"""
from __future__ import annotations

from .memsource import load_luoke_mem
from .safety import refuse_real

lm = load_luoke_mem()


def make_sample_memory(path):
    """假记忆：打字来的 3 条常用说法、1 个话题，邮件助手推测的 1 条处理习惯，1 条敏感的；清单里 3 个想问的、1 条建议。"""
    refuse_real(path, "记忆", always=True)
    m = lm.Memory(path, tool="luoke-mem")
    r = [m.record("user", "statement", f"打字 {i}", topic="ime-commit") for i in range(3)]
    ids = {t: m.propose("term", t, cites=r, why="在 2 天的打字里出现 3 次") for t in ("行云", "先快后好", "螺壳")}
    ids["本地大模型"] = m.propose("interest", "本地大模型", cites=r, why="在 2 天的打字里谈到")
    mm = lm.Memory(path, tool="luoke-mail")
    # 真推测：从用户改过的建议归纳的处理习惯；别人来信推出的事实不再找用户确认
    r2 = [mm.record("user", "activity", f"把某某商城的邮件改成归档 {i}", topic="override") for i in range(3)]
    ids["习惯"] = mm.propose("preference", "某某商城的邮件通常归档", cites=r2, why="你改过 3 次建议")
    m.propose("fact", "最近在看牙医", cites=r, why="打字里提到", sensitive=["health"])
    w = lm.WholeMemory(path)
    ids["ask"] = w.ask("question", "你的网站换地址了吗？", "最近的文章都发在另一个域名上", answer={"type": "yes_no"})
    ids["pick"] = w.ask("question", "周报一般哪天发？", "发出的邮件里周报的日子不一样",
                        answer={"type": "choice", "options": ["周五", "周一"]})
    # 主动记忆的清单（顶层 ADR 0015）：问一条猜测（带 about_note）、一条建议（带依据）
    ids["q习惯"] = w.ask("question", "某某商城的邮件，你是不是通常都归档？",
                        "你几次都这样处理，想确认以后照这个习惯建议。确认后，邮件助手会照这个习惯给出处理建议。",
                        about_note=ids["习惯"], answer={"type": "yes_no"})
    ids["建议"] = w.ask("suggestion", "可以退订某某商城的推广邮件", "这类邮件你这个月都没打开过，留着只是占地方。",
                       answer={"type": "yes_no"})
    for x in (m, mm, w):
        x.db.close()
    return ids
