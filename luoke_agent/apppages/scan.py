# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 螺壳实验室 Luoke Labs
"""扫描的页：照它给的原始数据（luoke-scan docs/data-resources.md，`data/…`）拼，样子照批过的效果图
（走查重画稿「扫描」两块）。页上的字都在这里写，扫描只给事实和动作（顶层 ADR 0028）。"""
from __future__ import annotations

import datetime as dt
import hashlib
import json
import os
import re
from typing import Any, Callable, Dict, List, Optional, Tuple
from urllib.parse import urlencode

from . import clock
from ..a2ui import MAX_PAGE_COMPONENTS as PAGE_COMPONENTS
from .kit import PageKit

APP = "luoke-scan"
# 清单里给界面用的固定名字（提醒的类别 `reports`、权限 `permissions`）：按代号在这里起名（负责人 11-17：用语由 agent 定）；
# 这里没有的代号照清单写的
KIND_NAMES = {"security": "安全问题", "space": "磁盘空间", "findings": "扫描结果", "needs-access": "权限申请",
              "auto-done": "自动清理结果"}
PERMISSION_NAMES = {"fda": "完全磁盘访问", "auto": "自动清理 4 类文件", "admin": "删除系统目录中的项目（需输入 Mac 密码）"}
PAGE_NEEDS = {
    "overview": ("overview",),
    "category": ("category", "overview"),
    "cleaned": ("history", "settings"),
    "settings": ("settings",),
    "more": ("overview",),
    "status": ("overview", "category"),
    "folder": ("overview",),
}
NEEDS = PAGE_NEEDS["overview"]
BUILT = set(PAGE_NEEDS)

# 两个标签：概览（要处理的）、状态（这台 Mac 现在怎么样；负责人 11-17：原来的「状态」页要补回来）；
# 清理记录、设置是右上角的图标（弹窗）；一类的详情、其他几类是点开的弹窗。
# 设置也放图标（负责人 11-15：设置页做了但没有入口，自动清理的开关、不再提醒的撤销都点不到）
PAGES = [
    {"id": "overview", "title": "概览"},
    {"id": "status", "title": "状态"},
    {"id": "cleaned", "title": "清理记录", "hidden": True, "icon": "history"},
    {"id": "settings", "title": "扫描设置", "hidden": True, "icon": "settings"},
    {"id": "category", "title": "详情", "hidden": True},
    {"id": "more", "title": "其他", "hidden": True},
    {"id": "folder", "title": "文件夹", "hidden": True},
]

# 界面上的字一律用书面说法，按钮和标签不用口语（负责人 11-16）
# 类 → 名字
CAT = {"cache": "缓存", "installer": "旧安装包", "duplicate": "重复文件", "temp": "残留的临时文件夹",
       "leftover": "已删除应用的残留数据", "project": "长期未改动的项目", "large-file": "长期未打开的大文件",
       "startup": "开机启动项", "ai-plugin": "AI 插件和模型模板", "install-scripts": "依赖安装脚本",
       "malware": "疑似病毒文件", "other": "其他"}
GROUP = {"tool-cache": "工具缓存", "app-cache": "应用缓存", "logs": "日志", "model": "模型", "ipsw": "系统固件",
         "device-support": "设备支持文件", "installer": "安装包", "app-data": "应用残留数据", "partial-download": "未完成的下载",
         "intel-homebrew": "旧版 Homebrew", "duplicate": "重复文件", "temp": "临时文件夹", "project": "项目",
         "build-artifacts": "构建产物", "large-file": "大文件", "launch-agent": "启动项", "skill": "AI 插件",
         "chat-template": "对话模板", "install-scripts": "自动运行的脚本", "malware": "病毒"}
# 每一类一个图标（概览里一类一行，最左边）；没列的用「其他」的
CAT_ICON = {"cache": "refresh-cw", "installer": "package", "duplicate": "copy", "temp": "folder", "leftover": "archive",
            "project": "folder-open", "large-file": "file", "startup": "power", "ai-plugin": "puzzle",
            "install-scripts": "settings", "malware": "shield-alert", "other": "hard-drive"}
# 安全和清理是两件事，分开列，安全在上（负责人 11-16）：这几类归「安全」，别的归「清理」
SECURITY_CATS = ("malware", "startup", "ai-plugin", "install-scripts")
# 「要注意的」一项的名字：照规则代号的前缀（扫描只给代号，data-resources「不足」）
# 要注意的项只给规则代号（扫描 data-resources「attention 只给代号」）：长的前缀在前，认不出的写「需要注意的项目」
RULES = [("malware.stale-db", "病毒库过期"), ("malware.yara-missing", "病毒规则缺失"), ("malware.yara-failed", "病毒规则检查失败"),
         ("malware.too-large", "文件过大，未查病毒"), ("malware.odd-name", "文件名异常"), ("malware.partial", "病毒检查未完成"),
         ("malware.app-partial", "病毒检查未完成"), ("malware.", "疑似病毒文件"),
         ("posture.filevault", "硬盘未加密"), ("posture.screen-lock", "锁屏等待时间过长"), ("posture.sip", "系统完整性保护已关闭"),
         ("posture.gatekeeper", "应用来源检查已关闭"), ("posture.firewall", "防火墙未开启"), ("posture.", "系统安全设置"),
         ("keyboard.", "可读取键盘输入的程序"),
         ("permission.stale-grant", "已删除应用仍保留权限"), ("permission.", "应用权限"),
         ("persistence.new", "新增的开机启动项"), ("persistence.bad-signature", "开机启动项签名无效"),
         ("persistence.daemon-writable", "开机启动项可被改写"), ("persistence.path-risky", "开机启动项位置异常"),
         ("persistence.unvouched", "来源不明的开机启动项"), ("persistence.", "开机启动项异常"),
         ("apps.unsigned", "来源不明的应用"), ("apps.not-notarized", "未经 Apple 公证的应用"), ("apps.bad-signature", "签名无效的应用"),
         ("apps.", "新安装的应用"),
         ("pkg.install-scripts", "装依赖时运行包里的脚本"),
         ("process.deleted-binary", "程序文件已删除的进程"), ("process.library-deleted", "加载了已删除文件的进程"),
         ("process.library-temp", "从临时文件夹加载代码的进程"), ("process.dyld-insert", "被注入代码的进程"),
         ("process.env", "运行环境异常的进程"), ("process.pile-up", "重复堆积的进程"), ("process.orphan", "残留的后台进程"),
         ("process.", "异常进程"),
         ("browser.sideloaded-extensions", "非商店安装的浏览器扩展"), ("browser.forced-extensions", "被强制安装的浏览器扩展"),
         ("browser.native-host", "浏览器扩展可调用的本机程序"), ("browser.", "浏览器扩展"),
         ("mcp.secrets", "MCP 配置含明文密钥"), ("mcp.", "MCP 服务配置"), ("skill.", "AI 插件存在风险"),
         ("leak.", "残留的临时文件"),
         ("vitals.cpu", "长时间占用处理器的程序"), ("vitals.memory", "内存占用过高的程序"), ("vitals.battery", "电池状态异常"),
         ("vitals.thermal", "设备温度过高"), ("vitals.", "系统运行状态"),
         ("exposure.ssh", "SSH 配置存在风险"), ("exposure.listening", "对外开放的端口"), ("exposure.argv-secret", "命令行中含明文密钥"),
         ("exposure.", "对外暴露的配置"), ("secrets.", "明文存放的密钥"),
         ("supplychain.malicious", "已知的恶意依赖包"), ("supplychain.", "依赖包检查"),
         ("startup.", "启动时自动运行的项目"), ("deps.", "依赖安装脚本"), ("model.", "模型模板存在风险"),
         ("space.low", "磁盘空间不足"), ("space.growth", "磁盘占用增长过快"), ("space.", "磁盘空间")]
SEVERITY = {"high": "高风险", "medium": "中风险", "low": "低风险"}
SHOW_FIRST = 2      # 一组先列几个，多的收进「其余 N 个」
SHOW_CATS = 3       # 概览「清理」先列最大的几类，别的在「其他 N 项」里
SHOW_ATTENTION = 8  # 「安全」先列几项，多的收起来
ITEM_ROWS = 25      # 一类的详情一页最多几项；一项要的组件多时一页更少（`_item_pages`：页最多 400 个组件）
HISTORY_ROWS = 30   # 清理记录一页几批

Read = Callable[[str], Any]


def uri(name: str, **params: Optional[str]) -> str:
    q = {k: v for k, v in params.items() if v not in (None, "")}
    return f"data/{name}" + (f"?{urlencode(q)}" if q else "")


def build(page: str, args: Dict[str, str], read: Read) -> List[dict]:
    return {"overview": overview, "category": category, "cleaned": cleaned, "settings": settings, "more": more,
            "status": status, "folder": folder}[page](args, read)


def size(n: Optional[int]) -> str:
    """「6.44 GB」「62.9 MB」「12 KB」：照 macOS 给文件写大小的办法（1000 进位，和访达、扫描自己的换算一样）：
    KB 不带小数，MB 一位，GB 以上两位，末尾的 0 不写；四舍五入，够 1000 就进到下一个单位"""
    if n is None:
        return "大小未知"
    n = int(n)
    if n < 1000:
        return f"{n} 字节" if n else "0 KB"
    unit = 1000
    for i, (name, decimals) in enumerate((("KB", 0), ("MB", 1), ("GB", 2), ("TB", 2), ("PB", 2))):
        scale = 10 ** decimals
        scaled = (n * scale * 2 // unit + 1) // 2
        if scaled >= 1000 * scale and i < 4:
            unit *= 1000
            continue
        whole, frac = divmod(scaled, scale)
        tail = f"{frac:0{decimals}d}".rstrip("0") if decimals else ""
        return f"{whole}.{tail} {name}" if tail else f"{whole} {name}"
    return f"{n} 字节"


def _day(s: Optional[str]) -> str:
    if not s or len(s) < 10:
        return ""
    return f"{int(s[5:7])}月{int(s[8:10])}日"


def _when(s: Optional[str]) -> str:
    """扫描给的是 UTC 的时刻（`2026-10-20T12:00:00Z`）：换成本机时间，「今天 09:58」「11月12日 20:10」"""
    if not s:
        return ""
    try:
        t = dt.datetime.strptime(s[:19], "%Y-%m-%dT%H:%M:%S").replace(tzinfo=dt.timezone.utc).astimezone()
    except ValueError:
        return _day(s)
    today = clock.now().date()
    if t.date() == today:
        return f"今天 {t:%H:%M}"
    if t.date() == today - dt.timedelta(days=1):
        return f"昨天 {t:%H:%M}"
    return f"{t.month}月{t.day}日 {t:%H:%M}"


def _summary(c: dict) -> str:
    """一类下面那一句：为什么能清，后面是大小。一句话，不列条数（界面规范：说明一句话、只留对用户有意义的数；
    负责人 11-19：灰色说明不要把知道的都列上去）"""
    f = c.get("facts") or {}
    n, kind = c.get("count") or 0, c.get("id")
    tools, apps = f.get("tools") or [], f.get("apps") or []
    if kind == "cache":
        names = [str(x) for x in (tools or apps)[:3]]
        more = len(tools or apps) > 3
        # 英文名字和后面的字之间空一格（#173：「npm的缓存」）
        gap = " " if names and names[-1][-1:].isascii() and not more else ""
        who = "、".join(names) + (" 等" if more else "")
        text = f"{who}{gap}缓存，可自动重建" if who else f"{n} 项缓存，可自动重建"
    elif kind == "installer":
        got = f.get("appsInstalled") or 0
        text = "对应的应用均已安装" if got and got >= n else f"其中 {got} 个对应的应用已安装" if got else "较早下载的安装包"
    elif kind == "duplicate":
        text = "其他位置仍保留一份"
    elif kind == "temp":
        text = "测试工具运行后未删除"
    elif kind == "leftover":
        text = "应用已删除" if f.get("appsMissing") else "不再使用的数据"
    elif kind == "project":
        text = "均已推送或可重新生成"
    else:
        text = f"{n} 项"
    return f"{text} · {size(c.get('bytes'))}" if c.get("bytes") else text


def _rule_name(rule: Optional[str]) -> str:
    return next((name for prefix, name in RULES if (rule or "").startswith(prefix)), "需要注意的项目")


# 每一类要注意的事一句说明：是什么、不处理会怎样（照规则写，不经模型；负责人 11-20：每条写清是什么、为什么有风险）
WHY = [("malware.stale-db", "病毒库长期未更新，新出现的病毒无法识别"), ("malware.yara", "文件内容与已知恶意程序的特征一致，打开后可能窃取密码或文件"),
       ("malware.too-large", "文件超过检查上限，未做病毒检查"), ("malware.", "病毒库已识别此文件，打开后可能损害这台 Mac"),
       ("posture.filevault", "Mac 丢失后他人可直接读取全部文件"), ("posture.screen-lock", "离开后他人可直接使用这台 Mac"),
       ("posture.sip", "恶意程序可修改系统文件"), ("posture.gatekeeper", "未经验证的应用可直接运行"),
       ("posture.firewall", "同一网络中的设备可连接这台 Mac 的服务"),
       ("keyboard.", "此程序可读取全部键盘输入，包括密码；来源未经验证"),
       ("permission.stale-grant", "应用已删除，授予它的权限仍然有效；同名程序可沿用这些权限"),
       ("persistence.daemon-writable", "此程序开机时以管理员身份运行，其文件可被其他程序改写，可被用来在开机时运行恶意代码"),
       ("persistence.bad-signature", "此程序开机时自动运行，内容可能已被修改"),
       ("persistence.path-risky", "此程序开机时自动运行，位于临时或可被任意改写的位置"),
       ("persistence.", "此程序开机时自动运行，来源未经验证"), ("startup.", "此项目在启动时自动运行"),
       ("apps.bad-signature", "内容可能已被修改"), ("apps.", "无法确认开发者，内容未经 Apple 检查"),
       ("process.deleted-binary", "进程仍在运行，其程序文件已被删除，无法核对来源"), ("process.dyld-insert", "进程启动时被注入了额外的代码"),
       ("process.", "进程的运行方式异常"),
       ("browser.", "扩展不是从浏览器商店安装的，可读取网页内容"),
       ("mcp.secrets", "配置文件中以明文保存密钥，可被本机其他程序读取"), ("mcp.", "MCP 服务的配置存在风险"),
       ("skill.", "插件的说明或脚本中含高风险指令，AI 助手使用它时可能执行"), ("model.", "模型模板中含额外指令，对话时会被执行"),
       ("leak.", "程序退出后未清理的临时文件，持续占用空间"),
       ("exposure.ssh", "SSH 配置允许风险较高的登录方式"), ("exposure.listening", "此端口对网络中的其他设备开放"),
       ("exposure.", "配置中的内容对外可见"), ("secrets.", "文件中以明文保存密钥，可被本机其他程序读取"),
       ("supplychain.malicious", "项目依赖中有已知的恶意软件包，安装或运行时会执行恶意代码"),
       ("pkg.install-scripts", "装到恶意的包时，包里的脚本会用你的权限运行；这是包管理器的默认行为，不是配置出了问题"),
       ("deps.", "安装依赖时会自动运行软件包自带的脚本"), ("space.low", "可用空间不足，系统和应用可能无法正常运行")]
SETTINGS_PANE = [("posture.filevault", "FileVault", "打开 FileVault 设置"), ("keyboard.", "输入监控", "打开「输入监控」设置"),
                 ("persistence.", "登录项", "在登录项中管理"), ("startup.", "登录项", "在登录项中管理")]
SHOW_ADVICE = 5     # 「建议处理」先列几条，多的收起来（一条最多约 20 个组件，一页最多 400 个）
SHOW_LOOSE = 8      # 一条建议里点开最多列几项


def _why_rule(rule: Optional[str]) -> str:
    return next((w for prefix, w in WHY if (rule or "").startswith(prefix)), "")


def _short(path: str) -> str:
    return path if len(path) <= 72 else "…" + path[-70:]


# 没有 `category` 的发现归到哪一类里看（扫描的 attention 不给 skill、启动项这些的类；那一类在就点进去处理）
FAMILY = [("skill.", "ai-plugin"), ("model.", "ai-plugin"), ("persistence.", "startup"), ("startup.", "startup"),
          ("deps.", "install-scripts"), ("malware.", "malware")]


def _family(rule: Optional[str], cats: Any) -> Optional[str]:
    return next((c for prefix, c in FAMILY if (rule or "").startswith(prefix) and c in cats), None)


def _advice(items: List[dict], cats: Dict[str, dict]) -> List[Tuple[Optional[str], List[dict]]]:
    """要注意的项并成一条条建议（负责人 11-21：4 个有风险的插件不是 4 条一样的提示，也不和类别放在同一层）：
    (能进去处理的那一类或 None, 这一条里的各项)。有对应的一类的，整类一条（各项在那一类的详情里）；
    没有的，同一种事一条；急的（病毒）一个文件一条"""
    groups: List[Tuple[Optional[str], List[dict]]] = []
    at: Dict[str, int] = {}
    for a in items:
        cat = a.get("category") or _family(a.get("rule"), cats)
        key = "cat:" + cat if cat else _rule_name(a.get("rule"))
        if a.get("urgent"):
            groups.append((cat, [a]))
        elif key in at:
            groups[at[key]][1].append(a)
        else:
            at[key] = len(groups)
            groups.append((cat, [a]))
    return groups


def _advice_rows(kit: PageKit, cat: Optional[str], g: List[dict], cats: Dict[str, dict]) -> List[str]:
    """一条建议画成的几行。头一行：图标、是什么（加粗）、风险多高和为什么、在哪；右边是只画图标的动作（悬停显示名称），
    能进一类处理的点整行进去。好几项的右边写几项；没有对应的一类时各项收在下面一行里点开看"""
    a = g[0]
    rule = a.get("rule") or ""
    whole = cat is not None and not a.get("urgent")        # 整类一条：名字用类名，数的是这一类里的加上只能看的
    loose = [x for x in g if not x.get("category")]
    n = (int((cats.get(cat) or {}).get("count") or 0) + len(loose)) if whole else len(g)
    left = [kit.text(CAT.get(cat, cat) if whole else _rule_name(rule), "strong")]
    level = "需尽快处理" if a.get("urgent") else SEVERITY.get(a.get("severity"), "")
    why = " · ".join(x for x in (level, _why_rule(rule)) if x)
    if why:
        left.append(kit.text(why, "caption"))
    if n == 1 and a.get("path"):
        left.append(kit.text(_short(a["path"]), "caption"))
    btns: List[str] = _item_buttons(kit, a) if len(g) == 1 and not whole else []
    opened = kit.open_page("查看并处理", "category", {"id": cat}) if cat else None
    if opened:
        btns.append(opened)
    icon = "shield-alert" if a.get("urgent") or a.get("severity") == "high" else "triangle-alert"
    kids = [kit.row([kit.add({"id": kit._id("i"), "component": "Icon", "name": icon}), kit.column(left)])]
    if n > 1:
        kids.append(kit.text(f"{n} 项", "badge"))
    if btns:
        kids.append(kit.row(btns))
    rows = [kit.row(kids, justify="spaceBetween", open=opened)]
    if len(g) > 1 and not cat:
        rows.append(kit.fold(f"查看 {len(g)} 项", [kit.list(_loose_rows(kit, g))]))
    return rows


def _plugin_of(path: str) -> str:
    """`…/plugins/<插件>/skills/<skill>` 里的插件名；不是插件里的是空的"""
    parts = path.rstrip("/").split("/")
    return parts[-3] if len(parts) >= 4 and parts[-2] == "skills" and parts[-4] == "plugins" else ""


def _loose_head(items: List[dict]) -> Optional[Tuple[str, str]]:
    """「无法在螺壳中移除」那几项上面的说明：为什么不能在这里移除、去哪里管、风险是什么"""
    why = _why_rule(items[0].get("rule"))
    plugins = sorted({_plugin_of(a.get("path") or "") for a in items} - {""})
    if plugins:
        names = "、".join(plugins[:3]) + (" 等" if len(plugins) > 3 else "")
        return (f"属于 Claude Code 插件 {names}",
                "单独删除插件中的某一项会在插件更新时恢复，也可能让插件无法使用。如需处理，在 Claude Code 中输入 /plugin 停用或卸载整个插件，"
                "不必在访达中删除" + (f"。风险：{why}" if why else ""))
    return ("扫描不提供移除，可在访达中查看后自行处理", f"风险：{why}") if why else None


def _loose_rows(kit: PageKit, items: List[dict]) -> List[str]:
    """不在哪一类清单里的各项，一项一行：名字、位置，能在访达中显示、设为不再提醒"""
    named = [x for x in items if x.get("path")]
    rows = []
    for x in named[:SHOW_LOOSE]:
        path = x["path"]
        rows.append(kit.item(path.rstrip("/").split("/")[-1], _short(path), _item_buttons(kit, x), strong=False))
    if len(named) > SHOW_LOOSE:
        rows.append(kit.item(f"另有 {len(named) - SHOW_LOOSE} 项未列出", None, strong=False))
    if len(items) > len(named):
        # 扫描没给位置和名字的（按应用标识记的权限）：一行一行列只有同一个标题，只写几项
        rows.append(kit.item(f"{len(items) - len(named)} 项未提供名称", None, strong=False))
    return rows


def _item_buttons(kit: PageKit, a: dict) -> List[str]:
    """一项的动作，只画图标：系统设置里对应的那一栏（有的话）、在访达中显示、不再提醒（病毒是标为误报）"""
    rule = a.get("rule") or ""
    btns = []
    pane = next(((grant, label) for prefix, grant, label in SETTINGS_PANE if rule.startswith(prefix)), None)
    if pane:
        btns.append(kit.button(pane[1], "scan_open_settings", {"grant": pane[0]}, icon="settings", variant="borderless"))
    if not a.get("finding"):
        return btns
    if a.get("reveal"):
        btns.append(kit.button("在访达中显示", "scan_reveal", {"finding_id": a["finding"]}, icon="folder", variant="borderless"))
    btns.append(kit.button("标为误报" if rule.startswith("malware.") else "不再提醒", "scan_ignore",
                           {"finding_id": a["finding"]}, icon="bell-off", variant="borderless"))
    return btns


def _size_row(kit: PageKit, title: str, sub: Optional[str], bytes_: Any, go: str, icon: str) -> str:
    """一类一行：图标、名字和一句判断，右边大小的标签，点整行进去"""
    lead = kit.row([kit.add({"id": kit._id("i"), "component": "Icon", "name": icon}),
                    kit.column([kit.text(title, "strong")] + ([kit.text(sub, "caption")] if sub else []))])
    kids = [lead]
    if bytes_:
        kids.append(kit.add({"id": kit._id("t"), "component": "Text", "text": size(bytes_), "variant": "badge"}))
    kids.append(kit.row([go]))
    return kit.row(kids, justify="spaceBetween", open=go)


def _reason(c: dict) -> str:
    """一类那一句判断，不带大小（大小在右边的标签里）"""
    return _summary(dict(c, bytes=0))


def overview(args: Dict[str, str], read: Read) -> List[dict]:
    """扫描（负责人 11-20 定的方向：不按类别列清单，先给结论和建议）：
    结论（要处理几件事、能释放多少，上次什么时候查的、现在查一次、没查成的）；建议处理（每条写清是什么、为什么要处理、
    在哪，带能直接点的动作）；可直接清理（不用选的几类）；需确认（别的几类和大文件，每类一句判断）；已自动清理"""
    d = read(uri("overview")) or {}
    kit = PageKit("overview")
    top: List[str] = []

    att = d.get("attention") or {}
    items = sorted(att.get("items") or [], key=lambda a: (not a.get("urgent"), {"high": 0, "medium": 1, "low": 2}.get(a.get("severity"), 3)))
    n_att = int(att.get("count") or len(items))
    cats = _cats(d)
    sec_cats = [c for c in cats if c.get("id") in SECURITY_CATS]
    clean_cats = [c for c in cats if c.get("id") not in SECURITY_CATS]
    lf = d.get("largeFiles") or {}
    total = sum(c.get("bytes") or 0 for c in clean_cats)

    # 结论：一句；下面是检查的状态（上次什么时候查的、没查成的几项和原因）
    scanning, scanned = d.get("scanning"), d.get("scanned") or {}
    if isinstance(scanning, dict):
        frac = scanning.get("fraction")
        head = "正在检查" + (f" {round(frac * 100)}%" if isinstance(frac, (int, float)) else "")
    elif not scanned.get("finished"):
        head = "尚未检查"
    else:
        head = "，".join(x for x in (f"{n_att} 项安全问题建议处理" if n_att else "未发现安全问题",
                                    f"可释放 {size(total)}" if total else "") if x)
    now = [] if isinstance(scanning, dict) else [kit.button("立即检查", "scan_now", {}, icon="refresh-cw", variant="borderless")]
    check_rows = [kit.item(head, f"上次检查：{_when(scanned.get('finished'))}" if scanned.get("finished") else None, now)]
    skipped = d.get("skipped") or []
    need_fda = [s for s in skipped if s.get("reason") == "fda"]
    if need_fda and d.get("fullDiskAccess") == "granted":
        # 上一次检查时还没有权限、现在已经开了（负责人 11-17：系统里开了，页面还说要开）：不再让去系统设置，重新检查一次就补上
        again = [] if isinstance(scanning, dict) else [kit.button("立即检查", "scan_now", {})]
        check_rows.append(kit.item(f"{len(need_fda)} 项上次未检查", "当时未开启「完全磁盘访问」，重新检查后补上", again, strong=False))
    elif need_fda or d.get("fullDiskAccess") in ("denied", "ask"):
        title = f"{len(need_fda)} 项无法检查" if need_fda else "部分文件夹无法检查"
        check_rows.append(kit.item(title, "需要「完全磁盘访问」权限", [kit.button("打开系统设置", "scan_open_settings", {"grant": FULL_DISK, "permission": "fda"})],
                                   strong=False))
    other = [s for s in skipped if s.get("reason") != "fda"]
    if other:
        check_rows.append(kit.item(f"{len(other)} 项检查未完成", "将在下次检查时重试", strong=False))
    # 建议处理：急的在前；同一种事并成一条；能进一类处理的不再另列那一类
    by_id = {c.get("id"): c for c in sec_cats}
    groups = _advice(items, by_id)
    shown: List[str] = []
    extra: List[str] = []
    used = set()
    for i, (cat, g) in enumerate(groups[:SHOW_ADVICE * 2]):
        used.add(cat)
        (shown if i < SHOW_ADVICE else extra).extend(_advice_rows(kit, cat, g, by_id))
    if len(groups) > SHOW_ADVICE * 2:
        extra.append(kit.item(f"另有 {len(groups) - SHOW_ADVICE * 2} 条未列出", "处理上面的项目后重新检查", strong=False))
    if extra:
        shown.append(kit.fold(f"其余 {len(groups) - SHOW_ADVICE} 条", [kit.list(extra)]))
    shown += [_cat_row(kit, c) for c in sec_cats if c.get("id") not in used]
    top.append(kit.list(check_rows))        # 最上面这一块不加小标题：第一行就是结论（负责人 11-21：「结论」当标题奇怪）
    if shown:
        top.append(kit.heading(f"建议处理 · {n_att}" if n_att else "建议处理"))
        top.append(kit.list(shown))

    # 可直接清理：扫描判断不用选的几类（能自动清理的那几类），一句说明为什么，下面一类一行
    auto = [c for c in clean_cats if c.get("auto")]
    ask = [c for c in clean_cats if not c.get("auto")]
    if auto:
        b = sum(c.get("suggestedBytes") or c.get("bytes") or 0 for c in auto)
        top.append(kit.heading(f"可直接清理 · {size(b)}" if b else "可直接清理"))
        rows = []
        if not d.get("autoclean"):
            names = "、".join(CAT.get(c["id"], c["id"]) for c in auto)
            rows.append(kit.column([kit.text("均可重建、重新下载或另有一份", "strong"),
                                    kit.text(f"{names}，清理后不影响使用；移到废纸篓的可在清理记录中恢复", "caption"),
                                    kit.row([kit.button("开启自动清理", "scan_autoclean", {"on": True}, variant="primary")])]))
        for c in auto:
            go = kit.open_page("查看并清理", "category", {"id": c["id"]})
            rows.append(_size_row(kit, CAT.get(c["id"], c["id"]), _reason(c), c.get("bytes"), go, CAT_ICON.get(c["id"], CAT_ICON["other"])))
        top.append(kit.list(rows))

    # 需确认：别的几类和大文件，每类一句判断，点进去挑
    if ask or lf.get("count"):
        b = sum(c.get("bytes") or 0 for c in ask) + (lf.get("bytes") or 0)
        top.append(kit.heading(f"需确认 · {size(b)}" if b else "需确认"))
        rows = []
        for c in ask[:SHOW_CATS]:
            go = kit.open_page("查看详情", "category", {"id": c["id"]})
            rows.append(_size_row(kit, CAT.get(c["id"], c["id"]), _reason(c), c.get("bytes"), go, CAT_ICON.get(c["id"], CAT_ICON["other"])))
        if lf.get("count"):
            go = kit.open_page("大文件", "category", {"id": "large-file"})
            rows.append(_size_row(kit, CAT["large-file"], "长期未打开，不会自动清理", lf.get("bytes"), go, CAT_ICON["large-file"]))
        if len(ask) > SHOW_CATS:
            go = kit.open_page("其他", "more")
            rest = ask[SHOW_CATS:]
            rows.append(kit.item(f"其他 {len(rest)} 类", size(sum(c.get("bytes") or 0 for c in rest)), [go], open=go, strong=False))
        top.append(kit.list(rows))
    if not clean_cats and not lf.get("count") and scanned.get("finished"):
        top += [kit.heading("清理"), kit.list([kit.item("暂无可清理的项目", None, strong=False)])]

    # 已自动清理：最近 7 天
    week_ago = (clock.utcnow() - dt.timedelta(days=7)).strftime("%Y-%m-%dT%H:%M:%SZ")
    autos = [a for a in d.get("autoCleaned") or [] if (a.get("at") or "") >= week_ago] or (d.get("autoCleaned") or [])[:1]
    if autos:
        n = sum(k.get("count", 0) for a in autos for k in a.get("kinds") or [])
        b = sum(a.get("bytes") or 0 for a in autos)
        kinds = {k.get("kind") for a in autos for k in a.get("kinds") or []}
        what = CAT[next(iter(kinds))] if len(kinds) == 1 and next(iter(kinds)) in CAT else ""
        sub = "均可自动重建" if kinds <= {"cache"} else "可从清理记录恢复"
        go = kit.open_page("清理记录", "cleaned")
        top += [kit.heading("已自动清理"),
                kit.list([kit.item(f"本周自动清理 {n} 项{what}，释放 {size(b)}", sub, [go], open=go, strong=False)])]
    return kit.messages(top, refresh=3 if isinstance(scanning, dict) else None)


def summary(read: Read) -> Optional[str]:
    """侧栏上扫描名字下面的那一行，照原始数据写（负责人 11-17：应用只给数字和状态，怎么说由 agent 定；
    扫描自己的 `summary.text` 不用）。大小和扫描页「清理 · 可释放」是同一个数。读不到数据返回 None，照旧用应用给的"""
    d = read(uri("overview"))
    if not isinstance(d, dict):
        return None
    scanning, scanned = d.get("scanning"), d.get("scanned") or {}
    if isinstance(scanning, dict):
        frac = scanning.get("fraction")
        return f"正在检查 {round(frac * 100)}%" if isinstance(frac, (int, float)) and not isinstance(frac, bool) else "正在检查"
    if not scanned.get("finished"):
        return "尚未检查"
    att = d.get("attention") or {}
    urgent, count = int(att.get("urgent") or 0), int(att.get("count") or 0)
    free = sum(c.get("bytes") or 0 for c in _cats(d) if c.get("id") not in SECURITY_CATS)
    parts = []
    if urgent:
        parts.append(f"{urgent} 项需尽快处理")
    if free:
        parts.append(f"可释放 {size(free)}")
    if count - urgent > 0:
        parts.append(f"{count - urgent} 项待查看")
    return "，".join(parts) if parts else "未发现问题"


FOLDER_WORDS = (("已经删掉的应用留下的数据", "已卸载应用的残留数据"), ("几个应用共用的数据", "多个应用共用的数据"),
                ("开发工具的缓存", "开发工具缓存"), (" 的缓存", " 缓存"), ("的缓存", "缓存"), (" 的数据", " 数据"), ("的数据", "数据"),
                (" 的文件夹", " 文件夹"), ("的文件夹", "文件夹"))
SHOW_BIG = 5        # 「状态」页先列最大的几个大文件，全部在清单页


def _folder_cat(name: str) -> str:
    """这个文件夹里能清的东西在哪一类（照扫描起的名字认；认不出是空的：用户自己的文件夹，扫描没有给能清什么）"""
    if name.startswith("临时文件"):
        return "temp"
    if name.startswith("已经删掉的应用留下的数据"):
        return "leftover"
    if name == "下载":
        return "installer"
    if name.endswith("的缓存"):
        return "cache"
    return ""


# 扫描起的名字 → 家目录下的哪个文件夹（照它起名的规则反过来；扫描给了路径以后不用）
FOLDER_PLACES = {"桌面": "Desktop", "文稿": "Documents", "下载": "Downloads", "影片": "Movies", "音乐": "Music", "图片": "Pictures",
                 "公共": "Public", "自己装的应用": "Applications", "应用的缓存": "Library/Caches", "应用的数据": "Library/Application Support",
                 "应用的数据（沙盒里的）": "Library/Containers", "开发工具的数据": "Library/Developer", "邮件": "Library/Mail",
                 "信息": "Library/Messages", "照片的数据": "Library/Photos", "iCloud 云盘": "Library/Mobile Documents",
                 "命令行工具的缓存": ".cache", "命令行工具的数据": ".local/share", "Ollama 的模型": ".ollama", "Docker 的数据": ".docker",
                 "几个应用共用的数据": "Library/Group Containers", "日志": "Library/Logs", "字体": "Library/Fonts",
                 "Safari 的数据": "Library/Safari", "日历": "Library/Calendars"}


def _folder_path(name: str) -> str:
    """这一行是家目录下的哪个文件夹（`~/…`）；说不准的是空的（几个文件夹合成的一行、按应用名起的）。
    只照名字推，不看磁盘：点开时核心再核一遍在不在"""
    if name in FOLDER_PLACES:
        return "~/" + FOLDER_PLACES[name]
    if name.startswith("资源库里的「") and name.endswith("」"):
        return "~/Library/" + name[len("资源库里的「"):-1]
    if name.endswith(" 的文件夹"):
        return "~/." + name[:-len(" 的文件夹")]
    if name.endswith("的文件夹"):
        return "~/." + name[:-len("的文件夹")]
    if any(name.endswith(w) for w in ("的缓存", "的数据")) or name.startswith(("临时文件", "已经删掉的应用")) or "（" in name:
        return ""
    return "~/" + name if name and not name.startswith((".", "/", "~")) and ".." not in name else ""


FOLDER_HAS = {"cache": "含可清理的缓存", "temp": "含可清理的临时文件夹", "leftover": "含可清理的残留数据",
              "installer": "含可清理的旧安装包"}


def _mac_folders(read: Read) -> Tuple[str, List[Tuple[str, str, float, str, str, str]], str]:
    """占用最多的文件夹：（范围的说明，[(名字, 大小, 占列出来的合计的多少, 能清的在哪一类, 是家目录下的哪个文件夹, 近 7 天涨了多少)]，合计的那一句里的大小）。
    扫描还没有把这份数据放进 `data/`，先从它原来的那一页（`page/mac`）里读：标题那一行后面连着的几行，
    每行是名字、大小、一条比例。读不到、认不出就是空的。等扫描给了路径和里面有什么，改读数据"""
    try:
        msgs = read("page/mac")
    except Exception:
        return "", [], ""
    comps: Dict[str, dict] = {}
    for m in msgs if isinstance(msgs, list) else []:
        for c in ((m.get("updateComponents") or {}).get("components") or []) if isinstance(m, dict) else []:
            if isinstance(c, dict) and isinstance(c.get("id"), str):
                comps[c["id"]] = c
    root = next((c for c in comps.values() if c.get("id") == "root"), None) or next(iter(comps.values()), None)
    kids = [comps.get(k) or {} for k in (root or {}).get("children") or []] if root else []
    rows: List[Tuple[str, str, float, str, str, str]] = []
    scope, total, on = "", "", False
    for c in kids:
        text = c.get("text") if c.get("component") == "Text" else None
        if not on:
            if isinstance(text, str) and text.startswith("占地方最多的文件夹"):
                on, scope = True, text[len("占地方最多的文件夹"):].strip("（）")
            continue
        if c.get("component") != "Row":
            if isinstance(text, str) and text.startswith("这些加起来约 "):
                total = text[len("这些加起来约 "):].split("。", 1)[0]
            break
        parts = [comps.get(k) or {} for k in c.get("children") or []]
        texts = [x.get("text") for x in parts if x.get("component") == "Text" and isinstance(x.get("text"), str)]
        bar = next((x.get("value") for x in parts if x.get("component") == "ProgressBar"), None)
        if len(texts) >= 2 and isinstance(bar, (int, float)) and not isinstance(bar, bool):
            name = texts[0]
            for old, new in FOLDER_WORDS:       # 扫描起的名字里的口语换成书面说法
                name = name.replace(old, new)
            sz, _, grew = texts[1].partition("，")
            grew = grew.strip()
            for old in ("这周多了", "一周多了", "本周多了"):
                if grew.startswith(old):
                    grew = "近 7 天增加 " + grew[len(old):].strip()
            rows.append((name[:60], sz.strip()[:20], min(max(float(bar), 0.0), 1.0), _folder_cat(texts[0]), _folder_path(texts[0]),
                         grew[:30]))
    return scope, rows[:8], total


# `data/usage` 里 `known` 的代号（相对家目录的路径）→ 页上的叫法
USAGE_KNOWN = {"Desktop": "桌面", "Documents": "文稿", "Downloads": "下载", "Movies": "影片", "Music": "音乐", "Pictures": "图片",
               "Public": "公共", "Applications": "用户安装的应用", "Library/Caches": "应用缓存",
               "Library/Application Support": "应用数据", "Library/Containers": "应用数据（沙盒）",
               "Library/Developer": "开发工具数据", "Library/Mail": "邮件", "Library/Messages": "信息",
               "Library/Photos": "照片数据", "Library/Mobile Documents": "iCloud 云盘", ".cache": "命令行工具缓存",
               ".local/share": "命令行工具数据", ".Trash": "废纸篓", ".ollama": "Ollama 模型", ".docker": "Docker 数据",
               "Library/Group Containers": "多个应用共用的数据", "Library/Logs": "日志",
               "Library/Saved Application State": "应用窗口状态", "Library/Fonts": "字体", "Library/Safari": "Safari 数据",
               "Library/Calendars": "日历", "Library/Metadata": "系统索引数据"}
# `unseen` 的代号 → 页上的叫法（没有完全磁盘访问时上一轮没量的地方）
USAGE_UNSEEN = {"Desktop": "桌面", "Documents": "文稿", "Downloads": "下载", "Music": "音乐", "Movies/TV": "视频 App 的资料库",
                "Library/Photos": "照片数据", "Library/Mobile Documents": "iCloud 云盘", "Library/CloudStorage": "云盘同步文件夹",
                "Library/Containers": "应用数据（沙盒）", "Library/Daemon Containers": "系统服务数据",
                "Library/Group Containers": "多个应用共用的数据"}
USAGE_GREW = 1_000_000_000      # 近 7 天涨了不到这么多的不写


def _usage_name(f: dict) -> str:
    kind, name = f.get("kind"), str(f.get("name") or "")
    if kind == "known":
        return USAGE_KNOWN.get(str(f.get("id") or ""), str(f.get("id") or "").rsplit("/", 1)[-1])
    gap = " " if name and name[-1].isascii() else ""       # 英文名字后面空一格，中文的不空（「微信数据」「Teams 缓存」）
    if kind == "app":
        return f"{name}{gap}缓存" if f.get("holds") == "cache" else f"{name}{gap}数据"
    if kind == "hidden":
        return f"{name}{gap}文件夹"
    if kind == "library":
        return f"资源库中的「{name}」"
    if kind == "folder":
        return name
    if kind == "removed-apps":
        n = f.get("apps")
        return "已卸载应用的残留数据" + (f"（{n} 个应用）" if isinstance(n, int) and not isinstance(n, bool) and n > 0 else "")
    return {"temp": "临时文件", "dev-caches": "开发工具缓存"}.get(str(kind), name)


def _usage_cat(f: dict) -> str:
    kind, fid = f.get("kind"), f.get("id")
    if kind == "temp":
        return "temp"
    if kind == "removed-apps":
        return "leftover"
    if kind == "known" and fid == "Downloads":
        return "installer"
    if kind == "dev-caches" or (kind == "app" and f.get("holds") == "cache") or (kind == "known" and fid in ("Library/Caches", ".cache")):
        return "cache"
    return ""


USAGE_WHAT = {"Downloads": "下载的文件，多数可重新获取", "Movies": "影片和剪辑工程", "Pictures": "照片图库和图片", "Library/Caches": "应用的缓存，可重建", ".cache": "工具的缓存，可重建",
              "Library/Messages": "「信息」的聊天记录和附件", "Library/Mobile Documents": "iCloud 云盘中的文件",
              "Library/Developer": "Xcode 的模拟器和构建产物", "Library/Containers": "各应用自己的数据",
              "Library/Application Support": "各应用自己的数据", ".Trash": "废纸篓，清空后释放"}


def _usage_what(f: dict) -> str:
    """这一行是什么（一句，照代号写；负责人 11-20：每个占用大的文件夹要说清是什么）。认不出的不写"""
    kind, fid = f.get("kind"), f.get("id")
    if kind == "known" and isinstance(fid, str):
        return USAGE_WHAT.get(fid, "")
    if kind == "app":
        return "应用的缓存，可重建" if f.get("holds") == "cache" else ""      # 名字已经写了「某应用数据」，不重复
    return {"temp": "程序运行时产生的临时文件", "dev-caches": "开发工具下载的依赖和构建缓存，可重建",
            "removed-apps": "对应的应用已卸载"}.get(str(kind), "")


def _usage_path(f: dict) -> str:
    """这一行背后只有一个家目录里的文件夹时是 `~/…`（点开看里面）；合并的行、临时文件夹是空的"""
    paths = [x for x in f.get("paths") or [] if isinstance(x, str)]
    if len(paths) != 1 or f.get("pathsMore") or f.get("kind") == "temp":
        return ""
    path = paths[0]
    if path.startswith("/Users/"):
        rest = path[len("/Users/"):].split("/", 1)
        path = "~/" + rest[1] if len(rest) == 2 and rest[1] else ""
    return path if path.startswith("~/") and ".." not in path else ""


def _usage_folders(read: Read) -> Optional[Tuple[str, List[Tuple[str, str, float, str, str, str]], str]]:
    """占用最多的文件夹，照扫描的 `data/usage` 写（名字、类别、路径、近 7 天涨了多少都由这里照代号和数写）：
    （这一轮没量的地方的说明，各行，合计）。不是这一轮量的行写明是哪天统计的（#169：没有完全磁盘访问时，
    以前量过的文稿照样列着，页上要看得出它不是这一轮的数）。扫描没有这份数据（旧版本）：None，照旧从 `page/mac` 读"""
    try:
        u = read(uri("usage"))
    except Exception:
        return None
    if not isinstance(u, dict) or not isinstance(u.get("folders"), list):
        return None
    listed = u.get("listedBytes") if isinstance(u.get("listedBytes"), int) and u["listedBytes"] > 0 else 0
    round_day = ""
    try:
        fin = (u.get("scanned") or {}).get("finished")
        round_day = (dt.datetime.strptime(fin[:19], "%Y-%m-%dT%H:%M:%S").replace(tzinfo=dt.timezone.utc).astimezone()
                     .strftime("%Y-%m-%d"))
    except (TypeError, ValueError, AttributeError):
        round_day = ""
    rows: List[Tuple[str, str, float, str, str, str]] = []
    for f in u["folders"]:
        if not isinstance(f, dict) or not isinstance(f.get("bytes"), int) or isinstance(f.get("bytes"), bool):
            continue
        name = _usage_name(f)
        if not name:
            continue
        notes = [_usage_what(f)] if _usage_what(f) else []
        day = f.get("day") if isinstance(f.get("day"), str) else ""
        if day and round_day and day < round_day and _ymd(day):
            notes.append(f"{_ymd(day)}统计，本轮未重新统计")
        grew = f.get("grew7d")
        if isinstance(grew, int) and not isinstance(grew, bool) and grew >= USAGE_GREW:
            notes.append(f"近 7 天增加 {size(grew)}")
        # 这一行里能清出多少（扫描 0.3.44 起的 `reclaim`，#219）
        rec = (f.get("reclaim") or {}).get("bytes") if isinstance(f.get("reclaim"), dict) else None
        if isinstance(rec, int) and not isinstance(rec, bool) and rec > 0:
            notes.append(f"可释放 {size(rec)}")
        rows.append((name[:60], size(f["bytes"]), min(max(f["bytes"] / listed, 0.0), 1.0) if listed else 0.0, _usage_cat(f),
                     _usage_path(f), " · ".join(notes)))
    note = ""
    if u.get("complete") is False:
        names = [USAGE_UNSEEN[x] for x in u.get("unseen") or [] if x in USAGE_UNSEEN]
        note = "未开启完全磁盘访问，" + ("、".join(names[:4]) + ("等位置" if len(names) > 4 else "") if names else "部分位置") + "本轮未统计"
    return note, rows[:8], size(listed) if listed else ""


# 未统计的占用超过这么多就点出可能的原因（macOS 和常用应用一般几十 GB）
GAP_BIG = 100 * 10**9
UNSEEN_BIG_NOTE = "高于常见水平，可能是 Spotlight 索引异常、本地快照或文稿的历史版本"
GAP_BIG_NOTE = "高于常见水平，可能是 Spotlight 索引异常、本地快照或虚拟机磁盘"
GAP_BIG_HOW = ("Spotlight 索引计入「系统设置 → 通用 → 储存空间」中的「系统数据」。在「系统设置 → Spotlight」中将代码、模型等"
               "文件很多的文件夹设为不搜索，可减小索引；索引损坏时需要重建，重建期间 Spotlight 搜索结果不完整")


CLONE_NOTE = "部分文件是同一份数据的副本（APFS 克隆），各文件夹分别计算，合计大于实际占用；删除其中一份释放的空间可能很少"


def _usage_raw(read: Read) -> Optional[dict]:
    try:
        u = read(uri("usage"))
    except Exception:
        return None
    return u if isinstance(u, dict) else None


def _usage_gap(read: Read, disk: dict) -> Optional[int]:
    """硬盘已用减去扫描这一轮量到的（`measuredBytes`），可能是负数（APFS 克隆按每份算，量到的比已用还多）；
    量得不全（没有完全磁盘访问）、读不到：None"""
    u = _usage_raw(read)
    if not u or u.get("complete") is not True:
        return None
    measured = u.get("measuredBytes")
    total, free = disk.get("total"), disk.get("free")
    if not all(isinstance(x, (int, float)) and not isinstance(x, bool) for x in (measured, total, free)) or measured <= 0:
        return None
    return int(total - free - measured)


def _reconcile(read: Read) -> Optional[dict]:
    """扫描 0.3.46 起的对账（`data/usage` 的 `reconcile`，luoke-scan#226/#227）：量全了才用，否则 None（照旧用 `_usage_gap`）"""
    r = (_usage_raw(read) or {}).get("reconcile")
    if not isinstance(r, dict) or r.get("complete") is not True:
        return None
    parts = [p for p in r.get("parts") or [] if isinstance(p, dict) and isinstance(p.get("bytes"), (int, float))]
    return {"elsewhere": int(sum(p["bytes"] for p in parts if p.get("id") != "home")),
            "unexplained": int(r.get("unexplained") or 0), "over": r.get("over") is True,
            "unmeasured": [u.get("id") for u in r.get("unmeasured") or [] if isinstance(u, dict)]}


def _ymd(s: Any) -> str:
    """「2025年9月15日」：带年份（#165：只写月日的像是今年）"""
    try:
        return f"{int(s[:4])}年{int(s[5:7])}月{int(s[8:10])}日"
    except (TypeError, ValueError):
        return ""


FOLDER_ROWS = 12    # 一个文件夹里先列最大的几项
FOLDER_FILES = 6    # 整个文件夹里最大的文件列几个
FOLDER_KINDS = 5    # 构成列几种
FILE_KIND = {"video": "视频", "photo": "照片和图片", "audio": "音频", "document": "文档", "archive": "压缩包和安装包",
             "model": "模型文件", "database": "数据库", "other": "其他"}
# 认得的几个文件夹：是什么、怎么减（照系统和应用自己的办法；负责人 11-20：打开访达只看到一堆看不懂的文件夹，不知道从何清理）
FOLDER_ADVICE = [
    ("~/Library/Messages", "「信息」的聊天记录和附件",
     "附件按内部编号分散存放，不适合在访达中逐个删除。在「信息」的设置中将「保留信息」改为一年，更早的信息和附件由系统删除，删除后无法恢复"),
    ("~/Pictures/Photos Library.photoslibrary", "「照片」的图库",
     "已开启 iCloud 照片时，在「照片」的设置中开启「优化 Mac 储存空间」，原片保留在 iCloud，本机只留较小的版本"),
    ("~/Library/Mobile Documents", "iCloud 云盘中的文件",
     "在系统设置的 iCloud 云盘中开启「优化 Mac 储存空间」，较少使用的文件只保留在 iCloud"),
    ("~/Library/Developer", "Xcode 的模拟器、构建产物和设备支持文件",
     "DerivedData 可删除，下次构建时重建；不用的模拟器在 Xcode 的设置中删除"),
    ("~/Library/Containers/com.docker.docker", "Docker 的镜像、卷和构建缓存",
     "在 Docker Desktop 中清理未使用的镜像和构建缓存；卷中可能有数据库，清理前请确认"),
    ("~/Library/Application Support/MobileSync", "iPhone 和 iPad 的本机备份",
     "在访达的设备页中管理备份，删除不再需要的旧设备备份"),
    ("~/Library/Caches", "应用的缓存", "删除后应用会重新生成，首次打开稍慢"),
    ("~/.Trash", "废纸篓", "清空废纸篓后才真正释放空间"),
]


def folder(args: Dict[str, str], read: Read) -> List[dict]:
    """一个文件夹里什么最占地方（弹窗；负责人 11-17：占得最多的文件夹要能点开看）。核心自己量（`agent/usage`），
    量着的时候隔几秒重读；每项写是什么（用途说明，没有就写文件夹还是文件、哪天改的）、多大，能在访达中显示，
    是文件夹的能再点进去。只看：这里不删东西，清理在访达里做"""
    from .. import explain
    path = args.get("dir") or ""
    kit = PageKit("folder")
    try:
        u = read("agent/usage?" + urlencode({"path": path}))
    except Exception:
        u = None
    u = u if isinstance(u, dict) else {"state": "gone", "items": []}
    shown = u.get("path") or path
    name = shown.rstrip("/").rsplit("/", 1)[-1] or shown
    # 家目录下认得的那几个用系统里的叫法（影片、图片……）
    name = next((n for n, rel in FOLDER_PLACES.items() if shown == "~/" + rel and "/" not in rel and not rel.startswith(".")), name)
    title = kit.text(name[:60], "h4")
    kit.components[-1]["placement"] = "header"
    top = [title]
    if u.get("state") == "gone":
        return kit.messages(top + [kit.text("无法打开此文件夹", "caption")])
    if args.get("kind"):
        return _folder_kind(kit, top, u, shown, args["kind"])
    try:
        known = read("agent/explained")
    except Exception:
        known = None
    known = known if isinstance(known, dict) else {}
    items = [i for i in u.get("items") or [] if isinstance(i, dict) and isinstance(i.get("path"), str)]
    measuring = u.get("state") == "measuring"
    head = [kit.text(shown, "caption")]
    if measuring:
        head.append(kit.text("正在统计大小", "caption"))
    elif items:
        head.append(kit.text(f"共 {u.get('count') or len(items)} 项，{size(u.get('bytes'))}" + ("（部分未统计完）" if u.get("partial") else ""),
                             "caption"))
    top.append(kit.column(head))

    # 认得的文件夹：是什么、怎么减
    tip = next((t for t in FOLDER_ADVICE if shown == t[0] or shown.startswith(t[0] + "/")), None)
    if tip:
        top += [kit.heading("说明"), kit.list([kit.column([kit.text(tip[1], "strong"), kit.text(tip[2])])])]

    # 构成：整个文件夹里（不管在第几层）每种文件占多少；较早的文件占得多时写一句
    kinds = [k for k in u.get("kinds") or [] if isinstance(k, dict) and isinstance(k.get("bytes"), int) and k["bytes"] > 0]
    whole = sum(k["bytes"] for k in kinds)
    if len(kinds) > 1 and whole:
        top.append(kit.heading("构成"))
        krows = []
        for k in kinds[:FOLDER_KINDS]:
            pb = kit.add({"id": kit._id("p"), "component": "ProgressBar", "value": round(k["bytes"] / whole, 4)})
            # 点开看这种文件在哪几个文件夹里（负责人 11-21：按类列了大小却不能操作，没有意义）
            go = kit.open_page("查看所在文件夹", "folder", {"dir": shown, "kind": str(k.get("kind"))})
            krows.append(kit.item(FILE_KIND.get(k.get("kind"), FILE_KIND["other"]), f"{k.get('count') or 0:,} 个",
                                  [kit.text(size(k["bytes"]), "caption"), pb, go], open=go, strong=False))
        top.append(kit.list(krows))
        this_year = clock.utcnow().year
        old = sum(y["bytes"] for y in u.get("years") or [] if isinstance(y, dict) and isinstance(y.get("year"), int)
                  and y["year"] <= this_year - 2 and isinstance(y.get("bytes"), int))
        if old >= whole * 0.3:
            top.append(kit.text(f"其中 {size(old)} 为 {this_year - 2} 年及更早的文件", "caption"))

    # 最大的文件：真实的文件名和所在位置（子文件夹只是内部编号时，按文件夹列看不出是什么）
    files = [f for f in u.get("files") or [] if isinstance(f, dict) and isinstance(f.get("path"), str) and isinstance(f.get("bytes"), int)]
    if any(f.get("in") != shown for f in files):
        top.append(kit.heading("最大的文件"))
        frows = []
        for f in files[:FOLDER_FILES]:
            inside = str(f.get("in") or "")
            inside = inside[len(shown):].lstrip("/") if inside.startswith(shown) else inside
            sub = " · ".join(x for x in (f"{_ymd(f.get('changed'))}修改" if _ymd(f.get("changed")) else "", _short(inside)[:60]) if x)
            badge = kit.add({"id": kit._id("t"), "component": "Text", "text": size(f["bytes"]), "variant": "badge"})
            show = kit.button("在访达中显示", "agent.reveal", {"item": f["path"]}, icon="folder", variant="borderless")
            frows.append(kit.row([kit.column([kit.text(str(f.get("name") or "")[:80], "strong")] + ([kit.text(sub, "caption")] if sub else [])),
                                  badge, kit.row([show])], justify="spaceBetween"))
        top.append(kit.list(frows))

    rows = []
    if items and (tip or len(kinds) > 1 or len(top) > 2):
        top.append(kit.heading("按文件夹"))
    if u.get("parent"):
        up = kit.open_page("上一级", "folder", {"dir": u["parent"]})
        rows.append(kit.item("上一级", None, [up], open=up, strong=False))
    for it in items[:FOLDER_ROWS]:
        why = explain.words(known.get(it.get("key")))
        what = "文件夹" if it.get("dir") else "文件"
        sub = " · ".join(x for x in (what, f"{_ymd(it.get('changed'))}修改" if _ymd(it.get("changed")) else "") if x)
        # 大小是标签、按钮单独一排：按钮那一排里只有按钮，窗口才画成只有图标（负责人 11-21：按钮还是带了字）
        badge = kit.add({"id": kit._id("t"), "component": "Text",
                         "text": size(it["bytes"]) if isinstance(it.get("bytes"), int) else "未统计完", "variant": "badge"})
        btns = [kit.button("在访达中显示", "agent.reveal", {"item": it["path"]}, icon="folder", variant="borderless")]
        left = [kit.text(str(it.get("name") or "")[:80], "strong")] + ([kit.text(why, "caption")] if why else []) + [kit.text(sub, "caption")]
        if it.get("dir"):
            go = kit.open_page("查看内容", "folder", {"dir": it["path"]})
            rows.append(kit.row([kit.column(left), badge, kit.row(btns + [go])], justify="spaceBetween", open=go))
        else:
            rows.append(kit.row([kit.column(left), badge, kit.row(btns)], justify="spaceBetween"))
    if not items and not measuring:
        # 系统不让读的不说成空的（#169）
        rows.append(kit.item("无权限查看此文件夹的内容", "需在「系统设置 › 隐私与安全性 › 完全磁盘访问权限」中允许螺壳", strong=False)
                    if u.get("denied") else kit.item("此文件夹为空", None, strong=False))
    if rows:
        top.append(kit.list(rows))
    if len(items) > FOLDER_ROWS:
        top.append(kit.text(f"另有 {len(items) - FOLDER_ROWS} 项较小的未列出", "caption"))
    top.append(kit.text("此处仅供查看，删除请在访达中操作", "caption"))
    # 量着的时候、用途说明正在问的时候隔几秒重读
    return kit.messages(top, refresh=3 if measuring else 5 if u.get("explaining") else None)


def _folder_kind(kit: PageKit, top: List[str], u: dict, shown: str, kind: str) -> List[dict]:
    """文件夹里某一种文件在哪几个文件夹里：占得最多的几个，各多大、几个文件，能在访达中显示、点进去看"""
    k = next((x for x in u.get("kinds") or [] if isinstance(x, dict) and x.get("kind") == kind), None)
    name = FILE_KIND.get(kind, FILE_KIND["other"])
    # 返回是一个按钮，不是整行点开（负责人 11-22：「返回」那行带向右的箭头，看着像要再往里走）
    back = kit.open_page("返回", "folder", {"dir": shown}, icon="undo-2", variant="borderless")
    head = [kit.text(f"{name} · {size(k['bytes'])}" if k else name, "strong")]
    if k:
        head.append(kit.text(f"{k.get('count') or 0:,} 个，按所在文件夹合计", "caption"))
    top.append(kit.column([kit.row([kit.column(head), kit.row([back])], justify="spaceBetween")]))
    if u.get("state") == "measuring":
        return kit.messages(top + [kit.text("正在统计大小", "caption")], refresh=3)
    rows = []
    dirs = [d for d in (k or {}).get("dirs") or []
            if isinstance(d, dict) and isinstance(d.get("path"), str) and isinstance(d.get("bytes"), int)]
    # 名字是内部编号（哈希）的文件夹排在有名字的后面，名字缩短（负责人 11-22）；各自仍按大小
    dirs.sort(key=lambda d: _hashy(os.path.basename(d["path"].rstrip("/"))))
    for d in dirs:
        rel = d["path"][len(shown):].lstrip("/") if d["path"].startswith(shown) else d["path"]
        rel = _hash_short(rel)
        badge = kit.add({"id": kit._id("t"), "component": "Text", "text": size(d["bytes"]), "variant": "badge"})
        show = kit.button("在访达中显示", "agent.reveal", {"item": d["path"]}, icon="folder", variant="borderless")
        go = kit.open_page("查看内容", "folder", {"dir": d["path"]})
        rows.append(kit.row([kit.column([kit.text(_short(rel or d["path"])[:80], "strong"), kit.text(f"{d.get('count') or 0:,} 个文件", "caption")]),
                             badge, kit.row([show, go])], justify="spaceBetween", open=go))
    # 小标题隔开：上面是这一种文件和「返回」，下面一组放进卡片（不加时这一组贴着上面那行、没有卡片）
    top += [kit.heading("所在文件夹"), kit.list(rows)] if rows else [kit.text("没有这种文件", "caption")]
    return kit.messages(top)


_HASH = re.compile(r"[0-9a-fA-F]{16,}|(?=[A-Za-z0-9_-]*\d)(?=[A-Za-z0-9_-]*[A-Za-z])[A-Za-z0-9_-]{24,}")


def _hashy(name: str) -> bool:
    """文件夹名是不是内部编号（git 对象、模型分片、缓存键这类哈希）：人看不出是什么"""
    return bool(_HASH.fullmatch(name))


def _hash_short(path: str) -> str:
    """路径里的哈希段只留前 8 位（「models--x/blobs/1a2b3c4d…」）"""
    return "/".join(p[:8] + "…" if _hashy(p) else p for p in path.split("/"))


def _opened(facts: dict) -> str:
    if facts.get("lastOpened") and _ymd(facts["lastOpened"]):
        return f"{_ymd(facts['lastOpened'])}后未打开"
    if facts.get("neverOpened"):
        return "从未打开" + (f"，{_ymd(facts['lastChanged'])}修改" if _ymd(facts.get("lastChanged")) else "")
    return ""


def status(args: Dict[str, str], read: Read) -> List[dict]:
    """状态：这台 Mac 的硬盘被什么占着（负责人 11-17：最要看的是哪些文件占地方、能不能清，AI 讲一下它们是做什么的）。
    硬盘用量；占用最多的文件夹；长期未打开的大文件，每个下面一行用途说明（`explain.py`，核心在后台问模型记下的，
    没有就写在哪、多久没打开），每个能在访达中显示、直接移到废纸篓（先确认）；能清的文件夹点进那一类的清单；
    页底是安全设置和病毒库"""
    from .. import explain
    d = read(uri("overview")) or {}
    kit = PageKit("status")
    top: List[str] = []

    def bar(v: float) -> str:
        return kit.add({"id": kit._id("p"), "component": "ProgressBar", "value": round(v, 4)})

    disk = d.get("disk") or {}
    scanning, scanned = d.get("scanning"), d.get("scanned") or {}
    top.append(kit.heading("硬盘"))
    rows = []
    if isinstance(disk.get("free"), (int, float)) and isinstance(disk.get("total"), (int, float)) and disk["total"] > 0:
        used = min(max(0, disk["total"] - disk["free"]), disk["total"])
        rows.append(kit.item(f"可用 {size(disk['free'])}", None,
                             [kit.text(f"已用 {size(used)}，共 {size(disk['total'])}", "caption"), bar(used / disk["total"])]))
    else:
        rows.append(kit.item("暂时无法读取硬盘用量", None, strong=False))
    if isinstance(scanning, dict):
        frac = scanning.get("fraction")
        rows.append(kit.item("正在检查" + (f" {round(frac * 100)}%" if isinstance(frac, (int, float)) else ""), None, strong=False))
    else:
        rows.append(kit.item(f"上次检查：{_when(scanned.get('finished'))}" if scanned.get("finished") else "尚未检查", None,
                             [kit.button("立即检查", "scan_now", {}, icon="refresh-cw", variant="borderless")], strong=False))
    top.append(kit.list(rows))

    usage = _usage_folders(read)
    scope, folders, total = _mac_folders(read) if usage is None else ("", usage[1], usage[2])
    if folders:
        top.append(kit.heading("占用最多的文件夹" + (f"（{scope}）" if scope else "")))
        # 能清的那几行点进那一类的清单（在那里勾选、清理）；用户自己的文件夹扫描还没给里面有什么，只能看
        have = {c.get("id") for c in _cats(d) if c.get("count")}
        rows = []
        for name, sz, frac, cid, path, grew in folders:
            right = [kit.text(sz, "caption"), bar(frac)]
            if cid in have:
                go = kit.open_page("查看可清理项", "category", {"id": cid})
                rows.append(kit.item(name, " · ".join(x for x in (grew, FOLDER_HAS[cid]) if x), right + [go], open=go, strong=False))
            elif path:
                go = kit.open_page("查看内容", "folder", {"dir": path})      # 点开看里面什么最占地方（核心自己量）
                rows.append(kit.item(name, grew or None, right + [go], open=go, strong=False))
            else:
                rows.append(kit.item(name, grew or None, right, strong=False))
        # 对账：硬盘已用减去扫描量到的，剩下的单列一行（负责人 11-23：看不见的占用要能看到；量全了才算，
        # 没有完全磁盘访问时差额里混着没量的文件夹，不列）
        rec = _reconcile(read)
        gap = None if rec else _usage_gap(read, disk)
        over = gap is not None and gap < 0
        gap = None if gap is None or gap <= 0 else gap
        if rec:
            # 扫描对过账：家目录外量得到的（应用、资源库、macOS 本身……）一行，量不到的说不清的一行（只有系统能看的地方）
            listed = (_usage_raw(read) or {}).get("listedBytes") or 0
            frac = lambda b: min(b / listed, 1.0) if listed else 0.0
            if rec["elsewhere"] > 0:
                rows.append(kit.item("macOS、应用和其他位置", None, [kit.text(size(rec["elsewhere"]), "caption"), bar(frac(rec["elsewhere"]))],
                                     strong=False))
            if rec["unexplained"] > 0:
                sub = UNSEEN_BIG_NOTE if rec["over"] else "只有系统能读取的位置，如 Spotlight 索引、本地快照"
                rows.append(kit.item("无法统计的占用", sub, [kit.text(size(rec["unexplained"]), "caption"), bar(frac(rec["unexplained"]))],
                                     strong=False))
        elif gap is not None:
            listed = (_usage_raw(read) or {}).get("listedBytes") or 0
            sub = GAP_BIG_NOTE if gap >= GAP_BIG else "macOS、应用和其他未统计的位置"
            rows.append(kit.item("未统计的占用", sub, [kit.text(size(gap), "caption"), bar(min(gap / listed, 1.0) if listed else 0.0)],
                                 strong=False))
        top.append(kit.list(rows))
        if (rec and rec["over"]) or (gap is not None and gap >= GAP_BIG):
            top.append(kit.fold("如何查看", [kit.text(GAP_BIG_HOW)]))
        elif over:
            # 负责人的 Mac 实测（11-23）：同一个模型克隆在 5 个文件夹里，各算一份，量到的比已用多 167 GB
            top.append(kit.text(CLONE_NOTE, "caption"))
        elif total and gap is None and not rec:
            top.append(kit.text(f"以上合计约 {total}，其余为未列出的小文件夹、系统和应用", "caption"))
    if usage is not None and usage[0]:
        if not folders:
            top.append(kit.heading("占用最多的文件夹"))
        top.append(kit.text(usage[0], "caption"))

    lf = d.get("largeFiles") or {}
    top.append(kit.heading("长期未打开的大文件"))
    rows = []
    if lf.get("count"):
        cat = None
        try:
            cat = read(uri("category", id="large-file"))
        except Exception:
            cat = None
        try:
            known = read("agent/explained")
        except Exception:
            known = None
        known = known if isinstance(known, dict) else {}
        items = [it for it in ((cat or {}).get("items") or []) if isinstance(it, dict) and isinstance(it.get("path"), str)]
        items.sort(key=lambda it: -(it.get("bytes") or 0))
        for it in items[:SHOW_BIG]:
            facts = it.get("facts") or {}
            why = explain.words(known.get(explain.key(it["path"], it.get("bytes"))))
            sub = " · ".join(x for x in (_where(it["path"]), _opened(facts)) if x)
            right = [kit.text(size(it.get("bytes")), "caption")]
            name = it["path"].rstrip("/").rsplit("/", 1)[-1] or it["path"]
            if it.get("finding"):
                right.append(kit.button("在访达中显示", "scan_reveal", {"finding_id": it["finding"]}, icon="folder",
                                        variant="borderless"))
            if "trash" in (it.get("options") or []) and it.get("plan") and it.get("key"):
                # 这一个直接移到废纸篓：先弹确认，点了才交给扫描；能不能从清理记录恢复照扫描说的写
                right.append(kit.button("移到废纸篓", "scan_apply", {"plan_id": it["plan"], "choices": {it["key"]: ["trash"]}},
                                        icon="trash-2",
                                        confirm={"title": f"将「{name[:40]}」移到废纸篓？",
                                                 "text": "可从清理记录恢复" if it.get("restorable") else "移走后无法从清理记录恢复",
                                                 "label": "移到废纸篓"}))
            left = [kit.text(name, "strong")] + ([kit.text(why, "caption")] if why else []) + ([kit.text(sub, "caption")] if sub else [])
            rows.append(kit.row([kit.column(left), kit.row(right)], justify="spaceBetween"))
        go = kit.open_page("查看清单", "category", {"id": "large-file"})
        rows.append(kit.item(f"全部 {lf['count']} 个，共 {size(lf.get('bytes'))}", "在清单中批量选择", [go], open=go,
                             strong=False))
    else:
        rows.append(kit.item("暂无", None, strong=False))
    top.append(kit.list(rows))

    # 系统的安全设置：没开的逐项列出（上一轮检查看到的）；没查过就说没查过
    att = d.get("attention") or {}
    off = [a for a in att.get("items") or [] if str(a.get("rule") or "").startswith("posture.")]
    top.append(kit.heading(f"安全设置 · {len(off)} 项未开启" if off else "安全设置"))
    if off:
        top.append(kit.list([_attention_row(kit, a) for a in off]))
    else:
        top.append(kit.list([kit.item("未发现未开启的安全设置" if scanned.get("finished") else "尚未检查", None, strong=False)]))
    db = d.get("virusDb") or {}
    if db.get("version") or db.get("date"):
        # 写明两个数各是什么（#173：只有「28186 · 2026-11-18」看不懂）
        words = [f"版本 {db['version']}" if db.get("version") else "",
                 f"{_ymd(db.get('date'))}更新" if _ymd(db.get("date")) else ""]
        top += [kit.heading("病毒库"), kit.list([kit.item(" · ".join(x for x in words if x) or "已安装", None, strong=False)])]
    return kit.messages(top)


def _attention_row(kit: PageKit, a: dict) -> str:
    """要注意的一项：是什么、风险多高、在哪；点进能处理它的那一类；能在访达中显示、设为不再提醒"""
    name = _rule_name(a.get("rule"))
    where = _fact_detail(a) or (a.get("path") or "").rstrip("/").split("/")[-1]
    sub = " · ".join(x for x in ("需尽快处理" if a.get("urgent") else SEVERITY.get(a.get("severity"), ""), where) if x)
    btns = []
    grant = (a.get("facts") or {}).get("grant") if str(a.get("rule") or "").startswith("posture.") else None
    if isinstance(grant, str) and grant:
        btns.append(kit.button("打开系统设置", "scan_open_settings", {"grant": grant}, icon="settings", variant="borderless"))
    if a.get("reveal") and a.get("finding"):
        btns.append(kit.button("在访达中显示", "scan_reveal", {"finding_id": a["finding"]}, icon="folder", variant="borderless"))
    if a.get("finding"):
        btns.append(kit.button("标为误报" if (a.get("rule") or "").startswith("malware.") else "不再提醒", "scan_ignore",
                               {"finding_id": a["finding"]}, icon="bell-off", variant="borderless"))
    opened = kit.open_page("查看详情", "category", {"id": a["category"]}) if a.get("category") else None
    if not opened and (a.get("rule") or "").startswith(("persistence.", "startup.")):
        # 没有能清的那一类时，开机启动的项目在系统设置的「登录项」里关（扫描的 scan_open_settings；负责人 11-20：只有显示和不再提醒）
        btns.insert(0, kit.button("在登录项中管理", "scan_open_settings", {"grant": LOGIN_ITEMS}, icon="settings", variant="borderless"))
    if opened:
        btns.append(opened)
    return kit.item(name, sub or None, btns, open=opened,
                    icon="shield-alert" if a.get("urgent") or a.get("severity") == "high" else "triangle-alert")


SIGNATURE_WORD = {"adhoc": "临时签名", "unsigned": "没有签名", "invalid": "签名后被改过", "script": "脚本",
                  "missing": "程序已不在", "deleted": "程序已删除", "unknown": "未查看签名"}


def _names(xs: Any, n: int = 3) -> str:
    """几个名字：前 n 个用顿号连起来，多的写「等 N 个」"""
    xs = [x.rstrip("/").rsplit("/", 1)[-1] for x in xs or [] if isinstance(x, str) and x]
    return "、".join(xs[:n]) + (f" 等 {len(xs)} 个" if len(xs) > n else "")


def _fact_detail(a: dict) -> str:
    """要注意的一项下面那行里写的具体情况（扫描的 facts，#212）：几分钟、几天、哪几个程序；没有就空"""
    f, rule = a.get("facts") or {}, str(a.get("rule") or "")
    if not isinstance(f, dict) or not f:
        return ""
    num = lambda k: f.get(k) if isinstance(f.get(k), int) else None
    if rule == "posture.screen-lock-delay" and num("delaySeconds"):
        return f"{num('delaySeconds') // 60} 分钟后才要求密码"
    if rule == "posture.pending-updates" and num("pending"):
        return f"{num('pending')} 个更新待安装" + (f"，{num('uptimeDays')} 天未重启" if num("uptimeDays") else "")
    if rule == "posture.xprotect-stale" and _ymd(f.get("updated")):
        return f"{_ymd(f.get('updated'))}更新"
    if rule == "posture.trusted-roots" and f.get("certs"):
        more = (num("certsMore") or 0) + len(f["certs"])
        return "、".join(str(c) for c in f["certs"][:3]) + (f" 等 {more} 个" if more > 3 else "")
    if rule == "keyboard.watchers":
        return _names(f.get("programs"))
    if rule == "keyboard.unvouched":
        sig = SIGNATURE_WORD.get(((f.get("signature") or {}).get("kind")) or "", "")
        return " · ".join(x for x in (_names([f.get("program")]), sig) if x)
    if rule.startswith("process."):
        who = _names([f.get("program") or f.get("library")]) or _names([o.get("name") for o in f.get("oldest") or []
                                                                         if isinstance(o, dict)])
        return " · ".join(x for x in (who, f"{num('count')} 个进程" if (num("count") or 0) > 1 else "") if x)
    return ""


def _cats(d: dict) -> List[dict]:
    """能处理的几类，大的在前（大文件不会自动清理，单独一行）。是一项设置、不是能清出来的地方的几类（install-scripts），
    扫描放在 `settings` 里（旧版扫描放在 `reclaimable` 里），并进来一样画；两边都有的只算一次"""
    cats: List[dict] = []
    seen = {"large-file"}
    for c in (d.get("reclaimable") or []) + (d.get("settings") or []):
        if c.get("id") not in seen:
            seen.add(c.get("id"))
            cats.append(c)
    return sorted(cats, key=lambda c: -(c.get("bytes") or 0))


def _cat_row(kit: PageKit, c: dict) -> str:
    go = kit.open_page("查看详情", "category", {"id": c["id"]})
    return kit.item(CAT.get(c["id"], c["id"]), _summary(c), [go], open=go, icon=CAT_ICON.get(c["id"], CAT_ICON["other"]))


def more(args: Dict[str, str], read: Read) -> List[dict]:
    """「其他 N 类」（弹窗）：概览「需确认」里没列的几类，一样点进详情"""
    kit = PageKit("more")
    rest = [c for c in _cats(read(uri("overview")) or {}) if c.get("id") not in SECURITY_CATS and not c.get("auto")][SHOW_CATS:]
    if not rest:
        return kit.messages([kit.text("没有其他类别", "caption")])
    return kit.messages([kit.list([_cat_row(kit, c) for c in rest])])


def _judgement(c: dict) -> str:
    """这一类的判断：这些是什么、删了有什么影响、有没有用户自己的东西（照事实拼，不经模型）"""
    f = c.get("facts") or {}
    parts = []
    if f.get("rebuilds"):
        parts.append("缓存删除后会自动重建，仅首次打开稍慢" if f["rebuilds"] == c.get("count") else f"其中 {f['rebuilds']} 项删除后会自动重建")
    if f.get("appsInstalled"):
        parts.append(f"{f['appsInstalled']} 个安装包对应的应用均已安装" if c.get("id") == "installer"
                     else f"{f['appsInstalled']} 项属于已安装的应用")
    if f.get("appsMissing"):
        parts.append(f"{f['appsMissing']} 个应用已不在这台 Mac 上")
    if c.get("id") not in SECURITY_CATS:
        parts.append({"none": "未发现个人文档", "maybe": "可能包含个人文件，建议确认后再清理",
                      "yes": "这些是个人文件，删除前请确认"}.get(f.get("userFiles"), ""))
    if f.get("password"):
        parts.append(f"{f['password']} 项需输入 Mac 密码才能移除")
    return "；".join(p for p in parts if p)


def _where(path: str) -> str:
    """文件在哪：家目录下的第一层（「下载」「资源库」……），临时文件夹写「临时文件夹」。
    真机上扫描给的是绝对路径；录的样例把家目录换成 `~`、临时目录换成 `$TMPDIR`，两样都认"""
    home = os.path.expanduser("~").rstrip("/") + "/"
    tmp = (os.environ.get("TMPDIR") or "").rstrip("/") + "/"
    if path.startswith("$TMPDIR/") or (tmp != "/" and path.startswith(tmp)):
        return "临时文件夹"
    rel = path[len(home):] if path.startswith(home) else path[2:] if path.startswith("~/") else ""
    top = rel.split("/")[0] if "/" in rel else ""
    return {"Downloads": "下载", "Library": "资源库", "Documents": "文稿", "Desktop": "桌面", "Movies": "影片",
            "Pictures": "图片", "Music": "音乐"}.get(top, top)


# 插件查到的每一种事：一行里写的短句，和「为什么有风险」里的说明（照扫描的种类代号写，不经模型；
# 负责人 11-21：只写「会下载并执行代码」看不出为什么有风险、官方插件为什么也被标出来）
SKILL_DETAIL = {
    "download-exec": ("会下载并执行代码", "脚本中有从网上下载程序后直接运行的写法。下载的内容未经检查就运行，来源一旦被替换，就可能装上恶意程序。官方插件安装自家的命令行工具时也常这样写"),
    "exfil": ("会向外发送对话内容", "脚本或说明会把对话或文件内容发到外部网站。调用自家服务的插件也会这样做，需确认发往的网站是否可信"),
    "md": ("说明文件含可疑指令", "说明文件中有让 AI 助手执行高风险操作的指令，AI 助手使用这个插件时可能照做"),
    "persistence": ("会设置自动运行", "会在系统中添加开机或定时自动运行的程序，插件删除后它仍可能继续运行"),
    "agent-tamper": ("会修改 AI 助手的设置", "会改写 AI 助手的配置、记忆或长期指令，影响它以后的行为"),
    "escalation": ("会请求管理员权限", "会以管理员身份运行命令，可修改系统文件"),
    "destructive": ("含删除数据的命令", "含可能大量删除文件或抹掉磁盘的命令"),
    "injection": ("含诱导 AI 的指令", "说明中有让 AI 助手忽略原有指令或隐瞒操作的写法"),
    "permission": ("权限过宽", "允许 AI 助手不经确认运行任意命令"),
    "supply-chain": ("安装的软件包未固定版本", "安装依赖时未固定版本，软件包被替换后会装上不同的代码"),
    "unreadable": ("部分文件未能检查", "有文件无法读取，未做检查"),
}
SKILL_KINDS = {k: v[0] for k, v in SKILL_DETAIL.items()}
TEMPLATE_DETAIL = ("模型文件自带的对话模板中有标准对话格式以外的文字。每次对话时这些文字都会交给模型，可能改变它的回答。"
                   "从模型官方发布处下载的通常无需处理")
# 不能在螺壳里移除的插件，去哪里管（照扫描给的 facts.agent）
SKILL_MANAGE = {"Claude Code 插件": "在 Claude Code 中输入 /plugin 停用或卸载此插件"}


TEMPLATE_SIGNS = {
    "ignore-rules": ("要求模型忽略原有规则", "模板中有要求模型不遵守既定规则的文字"),
    "impersonate": ("以系统身份下达指令", "模板中有冒充系统向模型下达指令的文字"),
    "conceal": ("要求对用户隐瞒", "模板中有要求模型不向用户说明某些内容的文字"),
    "exfil": ("要求向外发送对话", "模板中有要求模型将对话内容发往外部的文字"),
    "steer": ("固定推荐某些内容", "模板中有要求模型始终推荐某项内容或链接的文字"),
    "hidden": ("含不可见字符", "模板中有不显示的字符，可用于隐藏指令"),
}


def _template_signs(it: dict) -> List[Tuple[str, str]]:
    """对话模板里检出了哪几种文字（扫描的 `facts.kinds`）：[（叫什么，是什么意思）]"""
    return [TEMPLATE_SIGNS[k] for k in (it.get("facts") or {}).get("kinds") or [] if k in TEMPLATE_SIGNS]


def _risk_detail(it: dict) -> List[str]:
    """「为什么有风险」里的几句：查到的每一种事各一句；不能在这里移除的写去哪里管"""
    f, r = it.get("facts") or {}, it.get("reason")
    lines: List[str] = []
    if r == "template-extra":
        lines += [f"{name}：{what}" for name, what in _template_signs(it)]
        lines.append(TEMPLATE_DETAIL)
    elif r in SKILL_DETAIL or f.get("kinds"):
        for k in f.get("kinds") or [r]:
            if k in SKILL_DETAIL:
                lines.append(f"{SKILL_DETAIL[k][0]}：{SKILL_DETAIL[k][1]}")
        if lines:
            lines.append("以上由扫描规则按写法判断，不代表插件一定有恶意；来源可信、用途相符的可设为不再提醒")
    lines += _hit_lines(it)
    manage = SKILL_MANAGE.get(str(f.get("agent") or ""))
    if lines and manage and "trash" not in (it.get("options") or []):
        lines.append(manage)
    return lines


SHOW_HITS = 5   # 「为什么有风险」里最多列几处
TEMPLATE_PART = {"template": "对话模板", "system": "默认系统提示", "messages": "预设对话"}


def _hit_lines(it: dict) -> List[str]:
    """规则在哪里查到的（扫描的 `facts.hits`，luoke-agent#212）：一处一句，写哪种、哪个文件第几行；
    说明里写明了要做的标出来。只有代号、文件名和行号，没有原文"""
    f = it.get("facts") or {}
    hits = [h for h in f.get("hits") or [] if isinstance(h, dict)]
    out: List[str] = []
    for h in hits[:SHOW_HITS]:
        kinds = [k for k in h.get("kinds") or [] if isinstance(k, str)]
        what = "、".join((TEMPLATE_SIGNS.get(k) or (None,))[0] or k for k in kinds) if h.get("part") \
            else "、".join(SKILL_KINDS.get(k, k) for k in kinds)
        files = [x for x in h.get("files") or [] if isinstance(x, str)]
        where = "、".join(files[:3]) + (f" 等 {len(files)} 个文件" if len(files) > 3 else "")
        if h.get("part") in TEMPLATE_PART:
            where = f"{where}（{TEMPLATE_PART[h['part']]}）" if where else TEMPLATE_PART[h["part"]]
        ln = [str(n) for n in h.get("lines") or [] if isinstance(n, int)]
        if ln:
            more = h.get("linesMore") or 0
            where += f" 第 {'、'.join(ln)} 行" + (f"等 {len(ln) + more} 处" if more else "")
        line = "：".join(x for x in (what, where or "整个插件") if x)
        if h.get("declared"):
            line += "（插件说明中已写明）"
        out.append(line)
    rest = len(hits) - len(out) + (f.get("hitsMore") or 0)
    if rest > 0:
        out.append(f"另有 {rest} 处")
    return (["查到的位置"] + out) if out else []


def _model_notes(it: dict) -> List[str]:
    """本机模型对这一项写的说明（扫描的 `modelNotes`）：是内容不是结论，原样放、写明是本机模型写的"""
    notes = [n.get("text").strip() for n in it.get("modelNotes") or []
             if isinstance(n, dict) and n.get("source") == "local-model" and isinstance(n.get("text"), str) and n["text"].strip()]
    return [f"本机模型的说明（仅供参考）：{t[:300]}" for t in notes[:3]]


CHIPS = 6       # 一项下面最多画几个名字小块

# 包管理器装依赖时运行包里的脚本（install-scripts）：扫描给的是一项设置的现状，不是哪个文件有问题。
# 每项没有 path；为什么列出来、关掉的代价都是代号，这里照代号写
SCRIPTS_CAUSE = {"default-on": "装依赖时会运行包里自带的安装脚本", "setting-on": "设置里打开了运行依赖的安装脚本",
                 "old-store": "只有旧版留下的仓库，旧版装依赖时会运行包里自带的安装脚本", "allow-all-builds": "设置里允许所有依赖运行安装脚本",
                 "built-from-source": "从源码装包时会运行包里自带的构建脚本"}
SCRIPTS_COST = {"own-scripts-off": "关闭后项目自己的 prepare 等脚本也不会自动运行",
                "no-wheel-fails": "关闭后没有现成安装包的包会装不上",
                "no-wheel-deps-fail": "关闭后没有现成安装包的依赖会装不上"}
SCRIPTS_MANUAL = {"link": "配置文件是链接，需要自己改", "link-on-path": "配置文件所在的路径有链接，需要自己改",
                  "change-value": "配置里已有这项设置，需要自己改", "add-at-top": "需要自己加在配置文件最前面",
                  "add-in-global": "需要自己加在 [global] 里", "remove-setting": "需要自己删掉这项设置",
                  "upgrade": "升级后默认不再运行"}


def _item_name(it: dict) -> str:
    """一项叫什么：文件名；设置的现状（没有 path）写工具的名字"""
    f = it.get("facts") or {}
    if it.get("group") == "install-scripts" and (f.get("name") or f.get("tool")):
        return str(f.get("name") or f.get("tool"))
    return (it.get("path") or "").split("/")[-1] or it["key"]


def _scripts_why(f: dict) -> str:
    """装依赖时运行脚本那一项的一行说明：是什么 · 看到的依据 · 关掉的代价或为什么不能一键关"""
    parts = [SCRIPTS_CAUSE.get(str(f.get("cause") or ""), "安装依赖时自动运行脚本")]
    seen = f.get("built") or f.get("packages") or []
    if seen:
        parts.append(("已编译过 " if f.get("built") else "要运行脚本的有 ") + "、".join(str(x) for x in seen[:3])
                     + (f" 等 {len(seen)} 个" if len(seen) > 3 else ""))
    if f.get("canApply") is False and f.get("manual") in SCRIPTS_MANUAL:
        note = ""
        if f["manual"] == "upgrade" and f.get("fixedIn"):
            note = f"（{f['fixedIn']}）"
        elif f["manual"] == "remove-setting" and f.get("files"):      # 写明在哪个文件、哪一项
            where = "、".join(_short(str(p)) for p in f["files"][:2]) + (f" 等 {len(f['files'])} 处" if len(f["files"]) > 2 else "")
            note = f"（{where}" + (f" 里的 {f['setting']}" if f.get("setting") else "") + "）"
        parts.append(SCRIPTS_MANUAL[f["manual"]] + note)
    elif f.get("cost") in SCRIPTS_COST:
        parts.append(SCRIPTS_COST[f["cost"]])
    return " · ".join(parts)


def _why(it: dict, with_size: bool = True) -> str:
    """一项为什么列在这里：在哪 · 多大 · 原因。每一类都写原因（负责人 11-15：病毒、开机自启、AI 插件这几类只剩位置和大小）"""
    f, r = it.get("facts") or {}, it.get("reason")
    where = _where(it.get("path") or "")
    # 一项一句：在哪 · 为什么能清。下载日期、版本号、个数这些不影响决定的不写
    why = {"installed": "应用已安装",
           "old-download": f"{f.get('days', 0)} 天前下载", "rebuilds": "可自动重建", "app-rebuilds": "可自动重建",
           "copy-kept": "其他位置仍保留一份", "left-behind": "测试工具运行后未删除",
           "app-removed": "应用已删除", "unfinished": "下载未完成", "pushed": "已推送", "regenerable": "可重新生成",
           "not-opened": f"{_day(f.get('lastOpened'))}后未打开" if f.get("lastOpened") else "从未打开",
           "redownload": "需要时可重新下载", "logs": "日志", "newer-version": "已有更新的版本",
           "intel-homebrew": "Intel 版 Homebrew，已不再使用",
           "signature": "病毒库检出" + (f"：{f.get('signature') or f.get('rule')}" if f.get("signature") or f.get("rule") else ""),
           "program-missing": "启动的程序已不存在",
           "new": "新增的开机启动项" + (f"：{f.get('name') or f.get('app') or f.get('label')}" if f.get("name") or f.get("app") or f.get("label") else ""),
           "scripts-on": "安装依赖时自动运行脚本"}.get(r, "")
    if r == "scripts-on":
        why = _scripts_why(f)
    if r == "template-extra":       # 写检出的是哪几种（负责人 11-21：「对话模板包含额外内容」看不明白）
        why = "、".join(name for name, _ in _template_signs(it)) or "对话模板包含额外内容"
    if not why and r in SKILL_KINDS:
        kinds = [SKILL_KINDS[k] for k in f.get("kinds") or [r] if k in SKILL_KINDS]
        why = "、".join(kinds) or SKILL_KINDS[r]
    if where == GROUP.get(it.get("group") or ""):      # 位置和上面的组名是同一个词：不重复
        where = ""
    return " · ".join(x for x in (where, size(it.get("bytes")) if with_size and it.get("bytes") is not None else "", why) if x)


# 一项怎么处理（扫描 data-resources 的 `options`）：按钮和确认框照实际会做的写
# （负责人 11-15：按钮一律写「移到废纸篓」「能放回」，但缓存是直接删，病毒、启动项放不回）
HOW = ("trash", "remove", "delete", "scripts-off")


TITLES = {"移到废纸篓": "将所选项目移到废纸篓？", "删除": "删除所选项目？", "关闭自动运行": "关闭所选项目的自动运行？",
          "清理所选": "清理所选项目？"}


def _how(it: dict) -> str:
    opts = it.get("options") or []
    return next((h for h in HOW if h in opts), "trash")


def _apply_words(its: List[dict]) -> Tuple[str, str]:
    """（按钮上的字，确认框里的说明）：照这几项实际怎么处理、能不能恢复"""
    hows = {_how(i) for i in its}
    back = all(i.get("restorable") for i in its)
    none_back = not any(i.get("restorable") for i in its)
    if hows == {"trash"}:
        return "移到废纸篓", "可从清理记录恢复" if back else "部分项目移走后无法从清理记录恢复" if not none_back else "移走后无法从清理记录恢复"
    if hows == {"remove"}:
        return "删除", "直接删除，需要时会自动重建"
    if hows == {"scripts-off"}:
        return "关闭自动运行", "修改包管理器的设置，可在设置文件中改回"
    if hows == {"delete"}:
        return "删除", "直接删除，无法恢复"
    return "清理所选", "可恢复的移到废纸篓；缓存和失效的链接直接删除"


def _tilde(path: str) -> str:
    """路径写成 `~/…`：真机上扫描给的是绝对路径，录的样例已经是 `~`"""
    home = os.path.expanduser("~").rstrip("/") + "/"
    return "~/" + path[len(home):] if path.startswith(home) else path


KEEP_CHOICES = 12      # 一组重复文件最多几份能在这里选留哪份；再多的照扫描定的留


def _members(it: dict) -> List[str]:
    """重复文件这一组的每一份（扫描的 `facts.members`，第一份是扫描建议留的）；份数超过 KEEP_CHOICES 或没给时是 []"""
    m = [p for p in (it.get("facts") or {}).get("members") or [] if isinstance(p, str) and p]
    return m if 2 <= len(m) <= KEEP_CHOICES else []


def _copies(kit: PageKit, it: dict) -> List[str]:
    """重复文件的一项：几份各在哪、留哪一份。扫描给了全部几份（`facts.members`）时画成单选，默认选扫描建议的那份，
    用户能换（负责人 11-24 定）；没给时照写扫描定的留哪份（`paths`、`facts.keep`）。
    扫描没给留下的那一份时返回 []，照别的类画"""
    members = _members(it)
    if members:
        return [kit.text(f"重复的 {len(members)} 份，选择保留哪一份", "caption"),
                kit.choice(f"keep-{it['key']}", [(p, _short(_tilde(p))) for p in members], members[0])]
    keep = (it.get("facts") or {}).get("keep")
    paths = [p for p in it.get("paths") or [] if isinstance(p, str) and p] or ([it["path"]] if it.get("path") else [])
    if not isinstance(keep, str) or not keep or not paths:
        return []
    total = len(paths) + (it.get("pathsMore") or 0)
    lines = [kit.text(f"重复的 {total} 份", "caption")]
    lines += [kit.text(_short(_tilde(p))) for p in paths[:CHIPS]]
    if total > CHIPS:
        lines.append(kit.text(f"等 {total} 份", "caption"))
    return lines + [kit.text("保留的一份", "caption"), kit.text(_short(_tilde(keep)))]


def _item_row(kit: PageKit, it: dict, ignore_word: str) -> str:
    """详情里的一项：勾选框和名字、含哪几处、为什么列在这里，右边是大小和两个只画图标的按钮"""
    box = kit.add({"id": kit._id("x"), "component": "CheckBox", "label": _item_name(it),
                   "value": {"path": f"/checks/{it['key']}"}})
    btns = []
    if it.get("reveal") or it.get("group") != "install-scripts":      # 设置的现状没有可显示的文件
        btns.append(kit.button("在访达中显示", "scan_reveal", {"finding_id": it["finding"]}, icon="folder", variant="borderless"))
    btns.append(kit.button(ignore_word, "scan_ignore", {"finding_id": it["finding"]}, icon="bell-off", variant="borderless"))
    # 大小画成这一项右边的米色标签（§4 neutralBadge；负责人 11-19：没有它看不出这个文件占多少），不再混在下面那行小字里；一项含好几处时名字画成一组小块（§4 chips）
    badge = [kit.add({"id": kit._id("t"), "component": "Text", "text": size(it["bytes"]), "variant": "badge",
                      "tone": "neutral"})] if it.get("bytes") is not None else []
    left = [box]
    copies = _copies(kit, it) if it.get("group") == "duplicate" else []
    if copies:
        left += copies
    else:
        names = [p.rstrip("/").split("/")[-1] for p in it.get("paths") or [] if isinstance(p, str) and p]
        if len(names) > 1 and it.get("group") != "install-scripts":
            chips = [kit.text(n[:40], "badge") for n in names[:CHIPS]]
            if len(names) > CHIPS:
                chips.append(kit.text(f"等 {len(names)} 个", "caption"))
            left.append(kit.row(chips))
        left.append(kit.text(_why(it, with_size=False), "caption"))
    detail = _risk_detail(it)
    if detail:
        left.append(kit.fold("为什么有风险", [kit.text(x, "caption") for x in detail]))
    left += [kit.text(x, "caption") for x in _model_notes(it)]
    # 标签单独一块、按钮一排单独一块：按钮那一排里只有按钮，窗口才把它们画成只有图标（字是悬停提示）
    return kit.row([kit.column(left)] + badge + [kit.row(btns)], justify="spaceBetween")


def _item_pages(items: List[dict], ignore_word: str, room: int) -> List[List[dict]]:
    """各项分到几页：一页最多 ITEM_ROWS 项，画出来的组件也不超过 `room` 个。一项要几个组件不一样
    （含好几处的多一排名字，插件多一段「为什么有风险」），只按项数分会超过页的上限，整页画不出来"""
    pages: List[List[dict]] = [[]]
    used = 0
    for it in items:
        scratch = PageKit("category")
        _item_row(scratch, it, ignore_word)
        cost = len(scratch.components)
        if pages[-1] and (len(pages[-1]) >= ITEM_ROWS or used + cost > room):
            pages.append([])
            used = 0
        pages[-1].append(it)
        used += cost
    return pages


HOME_DIRS = {"Downloads": "下载", "Desktop": "桌面", "Documents": "文稿", "Movies": "影片", "Music": "音乐", "Pictures": "图片"}


def _compared(c: Any) -> str:
    """重复文件这一轮比了哪些地方（扫描的 `compared`，luoke-scan#234）：测试者知道有 5 份、这里只列了 2 份时，看得出另几份在哪儿没比"""
    if not isinstance(c, dict):
        return ""
    name = lambda xs: "".join(f"「{HOME_DIRS.get(x, x)}」" for x in xs if isinstance(x, str))
    places, no = c.get("places") or [], c.get("noAccess") or []
    mb = (c.get("minBytes") or 0) // (1024 * 1024)
    parts = []
    if places:
        parts.append(f"只比较了{name(places)}中" + (f" {mb} MB 以上" if mb else "") + "的文件")
    if no:
        parts.append(f"{name(no)}需开启完全磁盘访问后才会比较")
    if c.get("partial"):
        parts.append(f"{name(c['partial'])}文件太多，只比较了一部分")
    if c.get("finished") is False:
        parts.append("这一轮还没比较完，列出的是上一轮的结果")
    return "；".join(parts)


def category(args: Dict[str, str], read: Read) -> List[dict]:
    """一类的详情（弹窗）：最上面是判断；下面逐项（在哪、多大、为什么），默认按建议勾选、可以取消，每项能在访达中显示、设为不再提醒；
    一页最多 25 项，多的翻页（勾选管全部）；按钮照实际怎么处理写，每份方案一个按钮（要密码的另一份也有），重复文件能换成克隆。
    每一页都有：标题、判断、各组的小标题（个数和大小算全部页的）、翻页那一行、「无法在螺壳中移除」、底下的按钮。
    只在第一页：一组先列 SHOW_FIRST 个、多的收进「其余 N 个」（翻到后面的页是来看这一页的，全部展开）。
    只在最后一页：「另有 N 项较小的未列出」"""
    cid = args.get("id") or ""
    d = read(uri("category", id=cid)) or {}
    kit = PageKit("category")
    if not d.get("known"):
        return kit.messages([kit.text("此类别已不存在", "caption")])
    # 不占空间的（安全的几类）不写「0 字节」
    title = kit.text(f"{CAT.get(cid, cid)} · {size(d.get('bytes'))}" if d.get("bytes") else CAT.get(cid, cid), "h4")
    kit.components[-1]["placement"] = "header"      # 弹窗的标题
    top = [title]
    items = d.get("items") or []
    # 清完了（或这一类已经没有要处理的）：不再写对这一批的判断（「未发现个人文档」读着像查了没东西；#181）
    judge = _judgement(d) if items else ""
    if judge:
        top.append(kit.column([kit.text("判断", "caption"), kit.text(judge)]))
    scope = _compared(d.get("compared")) if cid == "duplicate" else ""
    if scope:
        top.append(kit.text(scope, "caption"))
    plans: Dict[str, List[dict]] = {}
    for it in items:        # 勾选管全部：没画在这一页的也在数据里，照建议勾着
        plans.setdefault(it["plan"], []).append(it)
        kit.data.setdefault("checks", {})[it["key"]] = it.get("suggested") not in (None, "keep", "ignore")
        if _members(it):        # 留哪一份：没画在这一页的照扫描建议的留
            kit.data.setdefault("choices", {})[f"keep-{it['key']}"] = [_members(it)[0]]
    whole: Dict[str, List[dict]] = {}      # 组标题上的个数和大小算全部页的，不只这一页
    for it in items:
        whole.setdefault(it.get("group") or "", []).append(it)
    ignore_word = "标为误报" if cid == "malware" else "不再提醒"
    # 列表后面的两块（每一页都有）先拼好，才知道一页里留给各项的组件还有多少
    # 归这一类、扫描没放进清单的各项（不能在这里移除的）：列在下面，能在访达中显示、设为不再提醒
    try:
        att = ((read(uri("overview")) or {}).get("attention") or {}).get("items") or []
    except Exception:
        att = []
    loose = [a for a in att if not a.get("category") and not a.get("urgent") and _family(a.get("rule"), (cid,)) == cid]
    tail: List[str] = []
    if not items and not loose:
        top.append(kit.text("清理完成"))
    if loose:
        # 扫描不在这里移除的（官方插件里的 skill：单删一个会在插件更新时回来，也可能让插件出错）：先说为什么、去哪里管，再逐项
        # （负责人 11-21：「需自行处理」是指哪些、为什么不能清、是不是要自己去访达里删）
        tail.append(kit.heading(f"无法在螺壳中移除 · {len(loose)}"))
        head = _loose_head(loose)
        tail.append(kit.list(([kit.column([kit.text(head[0], "strong"), kit.text(head[1], "caption")])] if head else []) +
                             _loose_rows(kit, loose)))
    btns = []
    for plan, its in plans.items():
        word, note = _apply_words(its)
        needs_pw = any(i.get("password") for i in its)
        label = f"{word}（需输入密码的 {len(its)} 项）" if needs_pw and len(plans) > 1 else word
        # 只有一个方案时按钮上写勾了几项、跟着勾选变（§4 countChecks），一项没勾时不画；几个方案各管一部分的照旧不写数
        counted = len(plans) == 1
        bid = kit.button(f"{label} {{n}} 项" if counted else label, "scan_apply",
                         dict({"plan_id": plan, "selected": {"path": "/checks"}, "how": {i["key"]: _how(i) for i in its}},
                              **({"keep": {"path": "/choices"}} if any(_members(i) for i in its) else {})),
                         variant="primary" if not btns else None,
                         confirm={"title": TITLES.get(word, f"{word}所选项目？"), "text": note + ("；需要输入 Mac 密码" if needs_pw else ""),
                                  "label": word})
        if counted:
            next(c for c in kit.components if c["id"] == bid)["count"] = {"path": "/checks", "value": True}
        btns.append(bid)
        clones = [i for i in its if "clone" in (i.get("options") or [])]
        if clones:      # 重复文件：换成克隆（不占空间，两份都留着）
            btns.append(kit.button("替换为克隆", "scan_apply", {"plan_id": plan, "selected": {"path": "/checks"},
                                                               "how": {i["key"]: "clone" for i in clones}},
                                   confirm={"title": "将所选重复文件替换为克隆？", "text": "两份文件都保留，不再重复占用空间",
                                            "label": "替换"}))
    # 不再放「此类不再提醒」：它只是把这一批逐项设为不再提醒，不是能开关的设置（负责人 11-21）；逐项的在每一行，撤销在扫描设置
    if btns:
        tail.append(kit.row(btns))
        kit.components[-1]["placement"] = "footer"      # §4 footerPlacement：固定在弹窗底部，列表滚动时不动
    # 留给各项的：页的上限减去已经拼好的、root、翻页那一行（6）、「另有 N 项」（1），每组的小标题、列表、「其余 N 个」（3）
    room = PAGE_COMPONENTS - len(kit.components) - 8 - 3 * len(whole)
    paged = _item_pages(items, ignore_word, room)
    pages = len(paged)
    try:
        page = max(1, int(args.get("p") or 1))
    except ValueError:
        page = 1
    page = min(page, pages)
    groups: Dict[str, List[dict]] = {}
    for it in paged[page - 1]:
        groups.setdefault(it.get("group") or "", []).append(it)
    for g, its in groups.items():
        total = sum(i.get("bytes") or 0 for i in whole[g])
        # 只有一组时合计已经在标题上，这里不重复
        top.append(kit.heading(" · ".join([GROUP.get(g, g), f"{len(whole[g])} 个"] + ([size(total)] if total and len(groups) > 1 else []))))
        rows = [_item_row(kit, it, ignore_word) for it in its]
        if page == 1 and len(rows) > SHOW_FIRST:
            rows = rows[:SHOW_FIRST] + [kit.fold(f"其余 {len(rows) - SHOW_FIRST} 个", rows[SHOW_FIRST:])]
        top.append(kit.list(rows))
    if d.get("more") and page == pages:
        top.append(kit.text(f"另有 {d['more']} 项较小的未列出，不会被处理", "caption"))
    if pages > 1:
        turn = []
        if page > 1:
            turn.append(kit.open_page("上一页", "category", {"id": cid, "p": str(page - 1)}, variant="borderless"))
        if page < pages:
            turn.append(kit.open_page("下一页", "category", {"id": cid, "p": str(page + 1)}, variant="borderless"))
        top.append(kit.row([kit.text(f"第 {page} / {pages} 页 · 共 {len(items)} 项，其他页已勾选的项目一并处理", "caption")] + turn,
                           justify="spaceBetween"))
    return kit.messages(top + tail)


def action(name: str, ctx: Dict[str, Any]) -> Tuple[str, Dict[str, Any]]:
    """页上点按交给扫描前改形状：详情里勾了哪些（`selected`，key → 勾没勾）换成扫描认的
    `{"plan_id", "choices": {"<key>": ["trash" / "remove" / "delete" / "scripts-off" / "clone"]}}`，没勾的不发（扫描当先不动）"""
    if name == "scan_apply" and isinstance(ctx.get("selected"), dict):
        how = ctx.get("how") if isinstance(ctx.get("how"), dict) else {}
        ok = HOW + ("clone",)
        picked = {k: [how[k] if how.get(k) in ok else "trash"] for k, on in ctx["selected"].items() if on is True and k in how}
        out = {"plan_id": ctx.get("plan_id"), "choices": picked}
        # 重复文件选了留哪一份：只对勾了、移到废纸篓的项发（扫描的 `keep`，luoke-scan#234）；扫描执行前再核一遍
        chose = ctx.get("keep") if isinstance(ctx.get("keep"), dict) else {}
        keep = {k: v[0] for k, v in ((key[len("keep-"):], val) for key, val in chose.items() if isinstance(key, str) and key.startswith("keep-"))
                if picked.get(k) == ["trash"] and isinstance(v, list) and len(v) == 1 and isinstance(v[0], str)}
        if keep:
            out["keep"] = keep
        return name, out
    return name, ctx


def cleaned(args: Dict[str, str], read: Read) -> List[dict]:
    """清理记录（弹窗）：一批一行：时间、清了什么、多大；还能恢复的给「恢复」；一页 30 批，多的翻页"""
    d = read(uri("history")) or {}
    kit = PageKit("cleaned")
    batches = d.get("batches") or []
    try:
        page = max(1, int(args.get("p") or 1))
    except ValueError:
        page = 1
    pages = max(1, -(-len(batches) // HISTORY_ROWS))
    page = min(page, pages)
    rows = []
    for b in batches[(page - 1) * HISTORY_ROWS:page * HISTORY_ROWS]:
        what = "、".join(f"{CAT.get(c['id'], c['id'])} {c.get('count', 0)} 项" for c in b.get("categories") or [])
        title = f"{_when(b.get('at'))} · {'自动清理' if b.get('auto') else '手动清理'}：{what}"
        notes = [size(b.get("bytes"))]
        if b.get("restored"):
            notes.append(f"已恢复 {b['restored']} 项")
        if b.get("deleted"):
            notes.append(f"{b['deleted']} 项直接删除，无法恢复")
        btns = []
        if b.get("restorable"):
            btns.append(kit.button("恢复", "scan_restore", {"id": b["batch"]}, icon="undo-2", variant="borderless",
                                   tooltip=f"恢复 {b['restorable']} 项"))
        rows.append(kit.item(title, " · ".join(notes), btns, strong=False))
    top = [kit.list(rows)] if rows else [kit.text("暂无清理记录", "caption")]
    try:
        ignored = len((read(uri("settings")) or {}).get("ignored") or [])
    except Exception:
        ignored = 0
    if ignored and page == 1:       # 不再提醒的不算清理，这里只留一个入口，在扫描设置里恢复（负责人 11-21）
        go = kit.open_page("扫描设置", "settings")
        top.append(kit.list([kit.item(f"不再提醒的项目 · {ignored}", "可在扫描设置中恢复提醒", [go], open=go, strong=False)]))
    if pages > 1:
        btns = []
        if page > 1:
            btns.append(kit.open_page("上一页", "cleaned", {"p": str(page - 1)}, variant="borderless"))
        if page < pages:
            btns.append(kit.open_page("下一页", "cleaned", {"p": str(page + 1)}, variant="borderless"))
        top.append(kit.row([kit.text(f"第 {page} / {pages} 页", "caption")] + btns, justify="spaceBetween"))
    if d.get("more"):
        top.append(kit.text(f"更早的 {d['more']} 批未列出", "caption"))
    return kit.messages(top)


def settings(args: Dict[str, str], read: Read) -> List[dict]:
    """扫描设置（弹窗，概览右上角的图标）：自动清理的开关；不再提醒的那些，能撤销"""
    d = read(uri("settings")) or {}
    kit = PageKit("settings")
    on = bool((d.get("autoclean") or {}).get("on"))
    sw = kit.button("自动清理", "scan_autoclean", {"on": not on}, variant="switch", on=on)
    off = [CAT.get(k["kind"], k["kind"]) for k in d.get("kinds") or [] if k.get("off")]
    sub = "缓存、旧安装包、重复的下载文件、临时文件夹四类无需确认即清理，可从清理记录恢复"
    if off:
        sub += f"；{'、'.join(off)}曾被恢复，今后清理前先确认"
    top = [kit.heading("清理"), kit.list([kit.item("自动清理", sub, [sw])])]
    # 不再提醒的：一直有这一节，空的时候也写明（负责人 11-21：撤销的入口放在设置或记录里）
    ignored = d.get("ignored") or []
    # 设为不再提醒的都在这里，按类分开（负责人 11-21：撤销要有固定的入口），每项能恢复提醒；一直有这一节，空的时候也写明
    top.append(kit.heading(f"不再提醒 · {len(ignored)}" if ignored else "不再提醒"))
    if not ignored:
        top.append(kit.list([kit.item("暂无不再提醒的项目", "设为不再提醒的项目列在此处，可恢复提醒", strong=False)]))
    by: Dict[str, List[dict]] = {}
    for g in ignored[:40]:
        by.setdefault(CAT.get(g.get("category")) or _rule_name(g.get("rule")), []).append(g)
    for cname, gs in by.items():
        rows = []
        for g in gs:
            undo = kit.button("恢复提醒", "scan_ignore", {"finding_id": g["finding"], "undo": True}, icon="undo-2", variant="borderless")
            # 没有路径的（设置的现状：装依赖时运行脚本）写是哪个工具的，不然几项都只有规则名，分不出来；
            # 扫描给了 name 才写得出，没给照旧只写规则名
            name = (g.get("path") or "").rstrip("/").split("/")[-1] or _rule_name(g.get("rule"))
            if not g.get("path") and g.get("name"):
                name = f"{g['name']}：{_rule_name(g.get('rule'))}"
            rows.append(kit.item(name, _short(g["path"]) if g.get("path") else None, [undo], strong=False))
        top += [kit.text(f"{cname} · {len(gs)}", "caption"), kit.list(rows)]
    if len(ignored) > 40:
        top.append(kit.text(f"另有 {len(ignored) - 40} 项未列出", "caption"))
    return kit.messages(top)
    return kit.messages(top)


# ---------------------------------------------------------------- 「今天」的卡片和点按后的结果，照数据写
#
# 顶层 ADR 0028：扫描只给「是哪一种事、涉及什么、数字多少、能做哪些动作和参数」（outbox 每件事的 `data`、动作答复的
# `structuredContent.data`，扫描的 docs/data-resources.md「事项和动作结果里的 data」），句子、按钮上的字在这里写。
# 认不出的 `type`、拼的时候出错：返回 None，照旧用扫描带的卡片和文字。

PLACE = {"downloads": "下载", "desktop": "桌面", "documents": "文稿", "pictures": "图片", "movies": "影片", "music": "音乐"}
MOVED_KIND = {"cache": "可重建的缓存", "installer": "已安装应用的安装包", "duplicate": "下载文件夹中的重复文件",
              "temp": "测试工具遗留的临时文件夹"}
AUTO_KIND = {"cache": "可重建的缓存", "installer": "已安装应用的安装包", "duplicate": "下载文件夹中的重复文件",
             "temp": "测试工具遗留的临时文件夹"}
LOGIN_ITEMS = "登录项"            # scan_open_settings 认的名字（扫描 settingsPane）
FULL_DISK = "完全磁盘访问"


def _n(v: Any) -> int:
    return int(v) if isinstance(v, (int, float)) and not isinstance(v, bool) else 0


def _join(names: Any) -> str:
    return "、".join(str(n) for n in names or [] if n)


def item(data: dict, surface_id: str) -> Optional[dict]:
    """outbox 的一件事照它的 `data` 写：{"title", "summary", "why_now", "card"}；认不出是哪一种返回 None"""
    from .. import cards
    build = {"malware": _malware, "startup-new": _startup, "malicious-package": _package, "space-low": _space,
             "needs-access": _access, "round": _round}.get(data.get("type"))
    if build is None:
        return None
    card = cards.Card(surface_id)
    words = build(card, data, cards)
    if words is None:
        return None
    title, summary, why = words
    return {"title": title, "summary": summary, "why_now": why, "card": card.messages()}


def _malware(card: Any, d: dict, cards: Any) -> Optional[Tuple[str, str, str]]:
    place = PLACE.get(d.get("place") or "")
    title = f"{place}中的「{d['name']}」疑似病毒" if place else f"「{d['name']}」疑似病毒"
    advice = "病毒库已识别此文件，建议移到废纸篓，请勿打开"
    card.heading(title)
    card.text(advice)
    btns = []
    plan = d.get("plan")
    if isinstance(plan, dict):
        btns.append(cards.button("移到废纸篓", "scan_apply", {"plan_id": plan["id"], "choices": {plan["key"]: ["trash"]}},
                                 primary=True, icon="trash"))
    btns.append(cards.button("标为误报", "scan_ignore", {"finding_id": d["finding"]}))
    card.buttons(*btns)
    return title, f"{title}。{advice}", "本轮检查新识别"


def _startup(card: Any, d: dict, cards: Any) -> Optional[Tuple[str, str, str]]:
    app, program, scope = d.get("app") or "", d.get("program") or "", d.get("scope") or ""
    if d.get("submitted"):
        if app:
            title = f"「{app}」在后台启动了程序" + (f"「{program}」" if program and program != app else "")
            body = f"由「{app}」运行时交给系统运行，重启后不会自动启动，因此不在「登录项」中"
        else:
            title = "后台出现新程序" + (f"「{program}」" if program else "")
            body = "由运行中的应用交给系统运行，重启后不会自动启动，因此不在「登录项」中"
        advice = "若为已安装应用所启动，可标为已知；不认识时可在访达中查看是哪个程序"
        why = "本轮检查新出现的后台程序"
    else:
        title = "新增开机启动项" + (f"「{app or program}」" if app or program else "")
        body = "随电脑启动，本轮检查新出现"
        advice = {"user-agent": "若为自行安装，可标为已知；不认识时可停用，其配置移到废纸篓，可随时恢复",
                  "login-item": "若为自行安装，可标为已知；不认识时可在「系统设置 › 通用 › 登录项与扩展」中关闭",
                  "cron": "若为自行添加，可标为已知；不认识时可在访达中查看它运行的程序，并将该程序移到废纸篓",
                  }.get(scope, "若为自行安装，可标为已知；不认识时可在访达中找到并移到废纸篓（需输入密码）")
        why = "本轮检查新出现的开机启动项"
    card.heading(title)
    card.text(f"{body}。{advice}")
    btns = [cards.button("标为已知", "scan_ignore", {"finding_id": d["finding"]}, primary=True)]
    if d.get("reveal"):
        btns.append(cards.button("在访达中显示", "scan_reveal", {"finding_id": d["finding"]}))
    stop = d.get("stop")
    if isinstance(stop, dict):
        btns.append(cards.button("停用", "scan_apply", {"plan_id": stop["id"], "choices": {stop["key"]: ["trash"]}}))
    if d.get("settings"):
        btns.append(cards.button("打开「登录项」设置", "scan_open_settings", {"grant": LOGIN_ITEMS}))
    card.buttons(*btns)
    return title, f"{title}。{body}。{advice}", why


def _package(card: Any, d: dict, cards: Any) -> Optional[Tuple[str, str, str]]:
    count, name = _n(d.get("count")), f"「{d['package']}」" if d.get("package") else ""
    if d.get("more"):
        title = f"另有 {count} 个已知恶意软件包"
        advice = "应视为密码和登录凭据已泄露：请更换重要密码，相关项目暂勿打开"
    else:
        title = f"{count} 处使用了已知恶意软件包{name}" if count > 1 else f"使用了已知恶意软件包{name}"
        advice = "应视为密码和登录凭据已泄露：请更换重要密码；可在访达中查看是哪个项目使用了它，该项目暂勿打开"
    card.heading(title)
    card.text(advice)
    btns = []
    if d.get("reveal"):
        btns.append(cards.button("在访达中显示", "scan_reveal", {"finding_id": d["finding"]}, primary=True))
    btns.append(cards.button("已处理，不再提醒", "scan_ignore", {"finding_id": d["finding"]}))
    card.buttons(*btns)
    return title, f"{title}。{advice}", "本轮与恶意软件包名单比对所得"


def _space(card: Any, d: dict, cards: Any) -> Optional[Tuple[str, str, str]]:
    if not isinstance(d.get("free"), (int, float)):
        return None
    title = f"可用空间仅剩 {size(_n(d['free']))}"
    whole = ""
    if isinstance(d.get("total"), (int, float)):
        whole = f"磁盘共 {size(_n(d['total']))}" + (f"，交换文件占用 {size(_n(d['swap']))}" if isinstance(d.get("swap"), (int, float)) else "")
    card.heading(title)
    plan = d.get("plan")
    if isinstance(plan, dict):
        line = f"可重建的工具缓存可立即释放 {size(_n(d.get('caches')))}，删除后不影响使用"
        card.text(line)
        card.buttons(cards.button(f"释放 {size(_n(d.get('caches')))}", "scan_apply",
                                  {"plan_id": plan["id"], "choices": plan["choices"]}, primary=True))
        summary = "。".join(x for x in (title, whole, line) if x)
    else:
        if whole:
            card.text(whole, caption=True)
        summary = "。".join(x for x in (title, whole) if x)
    return title, summary, "可用空间不足会影响其他程序"


def _access(card: Any, d: dict, cards: Any) -> Optional[Tuple[str, str, str]]:
    if d.get("permission") != "fda":
        return None
    title = "下载、文稿、桌面尚未检查"
    body = "为「螺壳」开启「完全磁盘访问」后即可检查，已删除应用的残留数据和权限也会一并检查"
    card.heading(title)
    card.text(body, caption=True)
    card.buttons(cards.button("打开系统设置", "scan_open_settings", {"grant": FULL_DISK}, primary=True))
    return title, body, "本轮有检查项因缺少此权限未完成"


def _clean_words(c: dict) -> Tuple[str, List[str], List[str]]:
    """一次自动清理：（标题，正文的几句，下面的几行小字）"""
    moved = [m for m in c.get("moved") or [] if isinstance(m, dict)]
    count, total = sum(_n(m.get("count")) for m in moved), sum(_n(m.get("bytes")) for m in moved)
    tools, freed = c.get("tools") or [], _n(c.get("bytes"))
    if not moved and not freed:
        title = "自动清理缓存未成功"
    elif not moved:
        title = f"已自动清理 {size(freed)} 工具缓存"
    else:
        title = f"已自动移到废纸篓 {count} 项（{size(total)}）" + (f"，清理 {size(freed)} 工具缓存" if tools else "")
    body = []
    if tools:
        body.append(f"清理工具缓存 {size(freed)}（{_join(tools)}），需要时会重新下载")
    if moved:
        body.append("移到废纸篓：" + "、".join(f"{MOVED_KIND.get(m.get('kind'), '其他')} {_n(m.get('count'))} 项（{size(_n(m.get('bytes')))}）"
                                             for m in moved))
    if c.get("partial"):
        body.append(f"{_join(c['partial'])} 的缓存仅清理了一部分（有文件无法删除），下次重试")
    if c.get("failed"):
        body.append(f"{_join(c['failed'])} 的缓存未能清理（有文件无法删除），下次重试")
    notes = []
    for m in moved:
        names: List[str] = []
        for n in m.get("names") or []:
            shown = f"{n['tool']} 遗留的临时文件夹" if n.get("tool") else str(n.get("name") or "")
            if shown and shown not in names:
                names.append(shown)
        if names:
            shown = "、".join(names)
            if _n(m.get("count")) > len(names):     # 「…临时文件夹等 21 项」：汉字后面不空格，英文名后面空一格
                shown += ("" if "\u4e00" <= shown[-1] <= "\u9fff" else " ") + f"等 {_n(m.get('count'))} 项"
            notes.append(f"{MOVED_KIND.get(m.get('kind'), '其他')}：{shown}")
    if c.get("unrecorded"):
        notes.append(f"以下项目未记入清理记录，恢复需在访达中打开废纸篓：{_join(c['unrecorded'])}")
    return title, body, notes


def _round_body(card: Any, d: dict, cards: Any) -> Tuple[List[str], List[str]]:
    """这一轮的卡片画进 `card`：（各段的标题，摘要的几句）。点按后的结果里重画时也用它"""
    titles, summary = [], []
    cleans = [c for c in d.get("cleans") or [] if isinstance(c, dict)]
    for i, c in enumerate(cleans):
        if i:
            card.divider()
        title, body, notes = _clean_words(c)
        card.heading(title)
        if body:
            card.text("。".join(body))
        for n in notes:
            card.text(n, caption=True)
        btns = []
        if c.get("restorable") and c.get("batch"):
            btns.append(cards.button("恢复", "scan_restore", {"id": c["batch"]}))
        if c.get("offerStop"):
            btns.append(cards.button("关闭自动清理", "scan_autoclean", {"on": False}))
        if btns:
            card.buttons(*btns)
        titles.append(title)
        summary += body
    if _n(d.get("moreCleans")):
        line = f"更早还有 {_n(d['moreCleans'])} 次自动清理，见清理记录"
        card.text(line, caption=True)
        summary.append(line)
    decide = d.get("decide")
    if isinstance(decide, dict):
        if cleans:
            card.divider()
        trash, free, rest = _n(decide.get("trash")), _n(decide.get("bytes")), _n(decide.get("rest"))
        head = f"可释放 {size(free)}" if trash and free else f"可清理 {trash} 项" if trash else ""
        # 不写「N 项」：应用数的是单项（安全的每一项、缓存以外能清的每一项），扫描页按类列、一类一行，
        # 两边的数对不上（负责人 11-21 复验）。能清多少照旧写，其余只说有、去扫描页看
        card.heading(head or "有项目待处理")
        parts = []
        if _n(decide.get("cleaned")):
            parts.append(f"已删除可重建的缓存 {_n(decide['cleaned'])} 项" +
                         (f"（释放 {size(_n(decide.get('freed')))}）" if _n(decide.get("freed")) else ""))
        if _n(decide.get("caches")):
            parts.append(f"可重建的缓存 {_n(decide['caches'])} 项，无需选择")
        if parts:
            card.text("；".join(parts), caption=True)
        btns = []
        plan = decide.get("plan")
        if isinstance(plan, dict) and plan.get("caches"):
            btns.append(cards.button(f"清理 {len(plan['caches'])} 项缓存", "scan_apply",
                                     {"plan_id": plan["id"], "choices": {k: ["remove"] for k in plan["caches"]}}, primary=True))
        if rest > 0:
            btns.append(cards.button("在扫描页查看", "agent.open_page", {"page": "overview"}, primary=not btns))
        if decide.get("offerAuto"):
            btns.append(cards.button("开启自动清理", "scan_autoclean", {"on": True}))
        if btns:
            card.buttons(*btns)
        titles.append((f"{head}，另有项目待处理" if head else "有项目待处理") if rest > 0 else head)
        summary += parts
        skipped = decide.get("skipped") or {}
        if _n(skipped.get("fda")):
            summary.append(f"{_n(skipped['fda'])} 项需开启「完全磁盘访问」后才能检查")
        if _n(skipped.get("virusDb")):
            summary.append("病毒库尚在准备，就绪后再检查")
        if _n(skipped.get("other")):
            summary.append(f"{_n(skipped['other'])} 项本次未检查成功，下一轮重试")
    if d.get("failed"):
        line = f"{_join(d['failed'])} 的缓存未能清理（有文件无法删除），下次重试"
        card.text(line, caption=True)
        summary.append(line)
    return [t for t in titles if t], summary


def _round(card: Any, d: dict, cards: Any) -> Optional[Tuple[str, str, str]]:
    titles, summary = _round_body(card, d, cards)
    if not titles:
        return None
    return "；".join(titles), "。".join(summary), "自动清理的结果" if d.get("cleans") else "本轮检查已完成"


def _applied_text(d: dict) -> str:
    def part(key: str, words: str, freed: str = "") -> Optional[str]:
        v = d.get(key) or {}
        n, b = (_n(v.get("count")), _n(v.get("bytes"))) if isinstance(v, dict) else (_n(v), 0)
        if not n:
            return None
        return words.format(n=n) + (f"（{freed}{size(b)}）" if b else "")
    parts = [part("moved", "已移到废纸篓 {n} 项"), part("removed", "已删除可重建的缓存 {n} 项", "释放 "),
             part("cloned", "已替换为克隆 {n} 项", "释放 "), part("links", "已删除 {n} 个失效链接"),
             part("scriptsOff", "已修改 {n} 个包管理器的设置，安装依赖时不再运行脚本"), part("partly", "{n} 项部分完成"),
             part("ignored", "{n} 项不再提醒"), part("gone", "{n} 项已不存在，已跳过"), part("skipped", "{n} 项未能清理"),
             part("unchanged", "{n} 项未能更改")]
    return "，".join(p for p in parts if p) or "未作改动"


def result(name: str, data: dict, surface_id: str, has_card: bool) -> Optional[dict]:
    """动作的答复照它的 `data` 写：{"text"}，扫描带了卡片（`has_card`）时再加 {"card"}（把那张卡片换成结果）。
    认不出的、画不了的（要密码的那份方案还等着）返回 None，照旧用扫描带的"""
    from .. import cards
    kind = data.get("type")
    # 换掉同一张卡片要用没用过的组件编号：照答复的内容取一个前缀（同样的答复同样的前缀，示例和测试才稳定）
    digest = hashlib.sha256(json.dumps(data, sort_keys=True, ensure_ascii=False).encode()).hexdigest()[:8]
    card = cards.Card(surface_id, id_prefix=f"r{digest}-")
    rnd = data.get("round") if isinstance(data.get("round"), dict) else None
    if kind == "applied":
        if data.get("password"):
            return None
        text = _applied_text(data)
        left = [str(x) for x in data.get("left") or []]
        said = text + ("。" + "；".join(left) if 0 < len(left) <= 2 else "")
        if rnd is not None:                     # 从这一轮的卡片点的、卡片还留着：只画它现在的样子
            if not _round_body(card, rnd, cards)[0]:
                return None
            return {"text": said, "card": card.update_messages()} if has_card else {"text": said}
        card.text(text)
        for line in left:                       # 没做成的每一项和原因：扫描给的还是句子（原因还没有代号）
            card.text(line, caption=True)
        if data.get("trashed"):
            card.text("清空废纸篓后才真正释放空间", caption=True)
        btns = []
        retry = data.get("retry")
        if isinstance(retry, dict):
            btns.append(cards.button("重试", "scan_apply", {"plan_id": retry["plan"], "choices": retry["choices"]}, primary=True))
        if data.get("restore"):
            btns.append(cards.button("恢复", "scan_restore", {"id": data["restore"]}))
        if btns:
            card.buttons(*btns)
        if data.get("unrecorded"):
            card.text(f"以下项目未记入清理记录，恢复需在访达中打开废纸篓：{_join(data['unrecorded'])}", caption=True)
        return {"text": said, "card": card.update_messages()} if has_card else {"text": said}
    if kind == "restored":
        parts = [w.format(n=_n(data.get(k))) for k, w in (("back", "已恢复 {n} 项"), ("left", "{n} 项未恢复"),
                                                          ("before", "{n} 项此前已恢复")) if _n(data.get(k))]
        text = "，".join(parts) or "未作改动"
        card.text(text)
        for line in data.get("notes") or []:
            card.text(str(line), caption=True)
    elif kind == "ignored":
        what = f"「{data['name']}」" if data.get("name") else _rule_name(data.get("rule")) if data.get("rule") else "此项"
        if data.get("undo"):
            text = f"已撤销，{what}会继续提醒"
            card.text(text)
        else:
            text = f"{what}不再提醒"
            card.text(text)
            card.buttons(cards.button("撤销", "scan_ignore", {"finding_id": data.get("finding"), "undo": True}))
        return {"text": text, "card": card.update_messages()} if has_card else {"text": text}
    elif kind == "autoclean":
        if data.get("on"):
            kinds = "、".join(AUTO_KIND.get(k, k) for k in data.get("kinds") or [])
            text = f"已开启自动清理：{kinds}检查到即清理，移到废纸篓的可恢复" if kinds else "已开启自动清理"
            if data.get("keptOff"):
                text += "；" + "、".join(AUTO_KIND.get(k, k) for k in data["keptOff"]) + "曾被恢复，仍先询问"
        else:
            text = "已关闭自动清理，清理前会先询问"
        card.text(text)
    elif kind == "scan-started":
        return {"text": "检查正在进行，完成后结果会更新" if data.get("already") else "检查已开始，通常需要几分钟"}
    elif kind == "revealed":
        return {"text": f"已在访达中选中 {data.get('path') or ''}".rstrip()}
    elif kind == "opened":
        return {"text": "已打开活动监视器" if data.get("activityMonitor") else "已打开系统设置"}
    else:
        return None
    if rnd is not None:                         # 放回、开关自动清理：答复下面接着这一轮的卡片
        card.divider()
        _round_body(card, rnd, cards)
    return {"text": text, "card": card.update_messages()} if has_card else {"text": text}
