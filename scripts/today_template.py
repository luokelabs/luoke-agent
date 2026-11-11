#!/usr/bin/env python3
"""「今天」新模板的示例：照对照稿右边那页（luoke-brand `ui/issues/2026-11-09-today/`，70c7e1e，
内容是虚构的），用 `luoke_agent/cards.py` 拼出每张卡片，存成窗口拿得到的一串 `/feed` 事件：
window/Sources/LuokeWindow/Resources/template/today.json。截图 `today-template` 照它画，看窗口能不能照对照稿画出来。

    python3 scripts/today_template.py            # 重新生成
    python3 scripts/today_template.py --check    # 生成进内存和仓库里的比，不一样退出码 1（测试里也跑）

打开网页的按钮照核心交给窗口的样子写上 `site`（工具协议 §5）。
"""
from __future__ import annotations

import argparse
import json
import os
import sys
from typing import Any, Dict, List, Tuple

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, ROOT)
from luoke_agent import a2ui, cards  # noqa: E402
from luoke_agent.cards import button, open_url_button  # noqa: E402

OUT = os.path.join(ROOT, "window", "Sources", "LuokeWindow", "Resources", "template", "today.json")
DAY = "2026-11-04"

OPT = {"flag": ("加星标", "star"), "draft": ("写草稿", "pencil-line"), "archive": ("归档", "archive"),
       "keep": ("先不动", "circle-minus"), "spam": ("移到垃圾邮件", "shield-alert")}


def options(*values: str) -> List[Tuple[str, str, str]]:
    return [(v, OPT[v][0], OPT[v][1]) for v in values]


TODO = options("flag", "draft", "archive", "keep")
SUS = options("keep", "spam")


def cal(day: str, time: str) -> dict:
    return open_url_button(f"{day} {time}", f"https://calendar.google.com/calendar/render?action=TEMPLATE&dates={day}",
                           icon="calendar-plus", tooltip="加入日程")


def more(n: int) -> dict:
    return button(f"查看全部 {n} 封", "mail_open", {"view": "all"}, icon="inbox")


def todo_item(key: str, who: str, subject: str, why: str, sel: str = "flag", **kw: Any) -> dict:
    return {"key": key, "who": who, "subject": subject, "why": why, "options": TODO, "selected": sel, **kw}


def sus_item(key: str, who: str, subject: str, why: str) -> dict:
    return {"key": key, "who": who, "subject": subject, "why": why, "options": SUS, "selected": "keep"}


def urgent_card(sid: str) -> List[dict]:
    """急事：新到的可疑信，一封一行，不用下拉"""
    c = cards.Card(sid)
    c.heading("可疑邮件", badge="ming.home@mailbox.example")
    line = [c._add({"id": "t-who", "component": "Text", "text": "Mosaic 帐户团队", "variant": "strong"}, top=False),
            c._add({"id": "t-subj", "component": "Text", "text": "个人 Mosaic 帐户安全代码", "maxLines": 1}, top=False)]
    c._add({"id": "r-line", "component": "Row", "children": line})
    c.text("发件人地址非 Mosaic 官方域名，且邮件直接提供安全代码并诱导用户输入，属于典型钓鱼行为。", caption=True)
    c.buttons(button("移到垃圾邮件", "mail_apply_plan", {"plan_id": "sus-1", "choices": {"m1": ["spam"]}},
                     icon="shield-alert", variant="destructive"),
              button("先不动", "mail_apply_plan", {"plan_id": "sus-1", "choices": {"m1": ["keep"]}}, icon="circle-minus"),
              button("在邮件助手里看", "mail_open", {"view": "suspicious"}, icon="inbox"))
    return c.messages()


def done_card(sid: str, text: str, group: dict) -> List[dict]:
    """已经替你做了：result_card 是换掉原来那张卡片的消息，这里没有原来那张，先建一张。同一组的在窗口里合成一行"""
    create = {"version": cards.VERSION, "createSurface": {"surfaceId": sid, "catalogId": cards.CATALOG}}
    return [create] + cards.result_card(sid, text, undo_event="mail_undo", undo_context={"batch": sid}, group=group)


SPAM = dict(label="可疑邮件", badge="ming@harbor-tech.example")


def decide_harbor(sid: str) -> List[dict]:
    items = [
        todo_item("m1", "CareerLink 事務局", "【11/9(月)締切】11/12 インフラ領域に特化したIT交流会【残席わずか】",
                  "CareerLink 举办的 11 月 12 日 IT 交流会报名截止，需确认是否参加并支付费用。",
                  due="今天截止", due_tone="warning", extra=cal("11-12", "16:00")),
        todo_item("m2", "CareerLink 事務局", "【CareerLink】案件情報メール 新着12件/更新55件のご案内（11月03日）",
                  "CareerLink 发送 12 个新案件和 2 个更新案件，需查看并决定是否申请。"),
        todo_item("m3", "SignFlow Account", "New Device Login", "SignFlow 通知用户从新设备登录，需确认是否本人操作。"),
        todo_item("m4", "周远 via SignFlow", "Complete with SignFlow: [Harbor] 1. UG 采购合同",
                  "收到 周远 发送的 SignFlow 文件，需查看并签署以完成流程。"),
        todo_item("m5", "周远 via SignFlow", "Voided: Complete with SignFlow: [Harbor] 1. UG 采购合同",
                  "SignFlow 电子签名文件因需更新而被撤销，需联系发件人重新发送。", sel="draft"),
    ]
    return cards.plan_card(sid, "5 封要处理", items, apply_event="mail_apply_plan", plan_id="p-harbor",
                           apply_label="加星标 4 · 写草稿 1", badge="ming@harbor-tech.example", extra_buttons=[more(137)])


def decide_home(sid: str) -> List[dict]:
    whys = ["CodeHub 通知：notebook-site 项目质量检查工作流运行失败，多个测试用例报错。",
            "CodeHub 通知 notebook-site 项目质量检查工作流运行失败，需处理多个测试失败项。",
            "CodeHub 通知：notebook-site 项目的质量检查工作流运行失败，多个测试用例报错。",
            "CodeHub 通知：notebook-site 项目的质量检查工作流运行失败，多个测试任务报错。"]
    subjects = ["[mingx/notebook-site] Run failed: Quality checks", "[mingx/notebook-site] Run failed: Quality checks（共 2 封）"]
    items = [todo_item(f"m{i + 1}", "DevBot", subjects[i % 2], whys[i % 4]) for i in range(8)]
    return cards.plan_card(sid, "8 封要处理", items, apply_event="mail_apply_plan", plan_id="p-home",
                           apply_label="加星标 8", badge="ming.home@mailbox.example", extra_buttons=[more(157)])


def mailbox_harbor(sid: str) -> List[dict]:
    todo = [
        todo_item("t1", "Workplace Suite 团队", "[通知] 管理控制台中可能存在未解决的安全风险",
                  "Workplace Suite 通知组织存在安全风险，需立即处理未解决的安全漏洞。", due="09-20 已过", due_tone="danger"),
        todo_item("t2", "CareerLink 事務局", "【9/7(月)締切】AI領域に特化したIT交流会のご案内【参加者25社超/残席わずか】",
                  "CareerLink 邀请参加 9 月 10 日的 AI 领域 IT 交流会，需确认是否出席。", due="09-07 已过", due_tone="danger",
                  extra=cal("09-10", "16:00")),
        todo_item("t3", "Noteflow", "[Noteflow] Welcome Back—data restoration is ready",
                  "Noteflow 服务恢复通知，提示用户可立即恢复数据并领取回归奖励。", due="08-25 已过", due_tone="danger"),
    ]
    sus = [
        sus_item("s1", "CoinPath Team", "💥 BTC is down to $75k! Huge $2.3T stock market wipeout",
                 "邮件内容包含夸张的市场恐慌信息、可疑的优惠代码，且发件人地址与域名不匹配，符合诈骗特征。"),
        sus_item("s2", "Daily Brief", "City council weighs new transit plan", "发件人地址与主题不符，且包含诱导点击的隐藏链接和可疑内容。"),
        sus_item("s3", "ChainNews", "💸 Exchange-Hack: Ist dein Geld noch sicher?", "发件人非官方，包含大量可疑链接，试图诱导用户点击钓鱼网站。"),
        sus_item("s4", "LinguaPal", "🎃 八五折优惠活动今日盛大开启 🎃", "这是典型的群发广告邮件，包含大量可疑的短链接，无需处理。"),
    ]
    parts = [
        {"icon": "inbox", "title": "待处理", "items": todo,
         "buttons": [button("加星标 3", "mail_apply_plan", {"plan_id": "p-harbor-low", "choices": cards.CHOICES},
                            primary=True, icon="check"), more(137)]},
        {"icon": "archive", "title": "可以整理", "note": "多是 CoinDigest、Pinlane、Tasklane",
         "buttons": [button("归档 2089 · 移到垃圾箱 24", "mail_apply_plan", {"plan_id": "tidy-harbor"}, primary=True,
                            icon="archive"),
                     button("先不动", "mail_dismiss", {"plan_id": "tidy-harbor"}, icon="circle-minus")]},
        {"icon": "shield-alert", "title": "判为可疑", "collapsed": "206 封，都先不动", "items": sus,
         "buttons": [button("按选的处理", "mail_apply_plan", {"plan_id": "sus-harbor", "choices": cards.CHOICES},
                            primary=True, icon="check"),
                     button("其余 202 封去邮件助手看", "mail_open", {"view": "suspicious"}, icon="inbox")]},
    ]
    return cards.mailbox_card(sid, "邮箱", parts, badge="ming@harbor-tech.example")


def mailbox_small(sid: str, badge: str, note: str, label: str, n_sus: int = 0) -> List[dict]:
    parts = [{"icon": "archive", "title": "可以整理", "note": note,
              "buttons": [button(label, "mail_apply_plan", {"plan_id": "tidy-" + sid}, primary=True, icon="archive"),
                          button("先不动", "mail_dismiss", {"plan_id": "tidy-" + sid}, icon="circle-minus")]}]
    if n_sus:
        parts.append({"icon": "shield-alert", "title": "判为可疑", "collapsed": f"{n_sus} 封，都先不动",
                      "items": [sus_item("s1", "北辰银行", "50元刷卡金期待与你相遇！[AD]",
                                         "邮件主题为促销广告，包含可疑短链接，且用户习惯归档此类促销邮件。")],
                      "buttons": [button("按选的处理", "mail_apply_plan", {"plan_id": "sus-" + sid, "choices": cards.CHOICES},
                                         primary=True, icon="check")]})
    return cards.mailbox_card(sid, "邮箱", parts, badge=badge)


def scan_card(sid: str) -> List[dict]:
    c = cards.Card(sid)
    c.heading("照建议清理能清出 45.67 GB")
    c.text("「清理」会删掉 9 样会自动重建的缓存。另外 101 样在「螺壳扫描」里等你看，其中 21 样先不动，等你定。", caption=True)
    c.buttons(button("清理 9 样缓存", "scan_apply", {"plan_id": "scan-1"}, primary=True, icon="trash-2"),
              button("打开自动清理", "scan_autoclean", {"on": True}, icon="sparkles"))
    return c.messages()


def with_site(messages: List[dict]) -> List[dict]:
    """照核心交给窗口的样子：打开网页的按钮写上 `site`（§5）"""
    for m in messages:
        for comp in (m.get("updateComponents") or {}).get("components") or []:
            ev = ((comp.get("action") or {}).get("event") or {})
            if comp.get("component") == "Button" and ev.get("name") == "agent.open_url":
                got = a2ui.open_url_site((ev.get("context") or {}).get("url"))
                if got:
                    comp["site"] = got[0]
    return messages


def build() -> Dict[str, Any]:
    plan: List[Tuple[str, str, str, str, str, Any]] = [
        # 编号、应用、种类、段、时刻、卡片
        ("luoke-mail/sus-1", "luoke-mail", "suspicious", "urgent", "05:13", urgent_card),
        ("luoke-mail/done-1", "luoke-mail", "auto-done", "done", "09:31",
         lambda s: done_card(s, "已移到垃圾邮件 1 封", cards.done_group("harbor/spam", "已移到垃圾邮件 {n} 封", 1, **SPAM))),
        ("luoke-mail/done-1b", "luoke-mail", "auto-done", "done", "09:20",
         lambda s: done_card(s, "已移到垃圾邮件 1 封", cards.done_group("harbor/spam", "已移到垃圾邮件 {n} 封", 1, **SPAM))),
        ("luoke-mail/done-2", "luoke-mail", "auto-done", "done", "09:12",
         lambda s: done_card(s, "已归档 190 封", cards.done_group("telmail/new", "已归档 {n} 封；已加星标 2 封", 190, label="新邮件",
                                                                  badge="ming.mobile@telmail.example"))),
        ("luoke-mail/new-harbor", "luoke-mail", "new-mail", "decide", "14:33", decide_harbor),
        ("luoke-mail/new-home", "luoke-mail", "new-mail", "decide", "14:33", decide_home),
        ("luoke-mail/box-harbor", "luoke-mail", "mailbox", "later", "14:33", mailbox_harbor),
        ("luoke-mail/box-home", "luoke-mail", "mailbox", "later", "14:33",
         lambda s: mailbox_small(s, "ming.home@mailbox.example", "多是南浦银行信用卡、Scholarly、DevBot", "归档 855 · 移到垃圾箱 1", 38)),
        ("luoke-mail/box-shop", "luoke-mail", "mailbox", "later", "14:33",
         lambda s: mailbox_small(s, "ming.shop@netmail.example", "多是邮箱服务中心", "归档 1")),
        ("luoke-scan/plan", "luoke-scan", "plan", "later", "14:43", scan_card),
    ]
    events: List[list] = []
    feed_cards = []
    for sid, app, kind, section, hm, make in plan:
        msgs = with_site(make(sid))
        problems = a2ui.validate(msgs)
        if problems:
            raise SystemExit(f"{sid} 画不了：{problems}")
        events.extend(["a2ui", m] for m in msgs)
        texts = [c for m in msgs for c in (m.get("updateComponents") or {}).get("components") or [] if c.get("component") == "Text"]
        title = next((c["text"] for c in texts if c.get("variant") == "h4"), texts[0]["text"] if texts else "")
        feed_cards.append({"app": app, "id": sid, "kind": kind, "section": section,
                           "time": f"{DAY}T{hm}:00+08:00", "title": title})
    events.append(["feed", {"brief": {}, "cards": feed_cards, "notices": [], "open": len(feed_cards),
                            "order": [c["id"] for c in feed_cards], "paused_until": None}])
    return {"_about": "「今天」新模板的示例，scripts/today_template.py 用 luoke_agent/cards.py 照对照稿拼的（内容虚构），别手改",
            "events": events}


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--check", action="store_true")
    a = ap.parse_args()
    text = json.dumps(build(), ensure_ascii=False, indent=1) + "\n"
    if a.check:
        with open(OUT, encoding="utf-8") as f:
            same = f.read() == text
        print("「今天」新模板的示例" + ("和仓库里的一样" if same else "和仓库里的不一样，重跑 scripts/today_template.py"))
        return 0 if same else 1
    os.makedirs(os.path.dirname(OUT), exist_ok=True)
    with open(OUT, "w", encoding="utf-8") as f:
        f.write(text)
    print(f"写了 {OUT}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
