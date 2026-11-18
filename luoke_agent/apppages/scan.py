# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 螺壳实验室 Luoke Labs
"""扫描的页：照它给的原始数据（luoke-scan docs/data-resources.md，`data/…`）拼，样子照批过的效果图
（走查重画稿「扫描」两块）。页上的字都在这里写，扫描只给事实和动作（顶层 ADR 0028）。"""
from __future__ import annotations

import datetime as dt
import hashlib
import json
import os
from typing import Any, Callable, Dict, List, Optional, Tuple
from urllib.parse import urlencode

from . import clock
from .kit import PageKit

APP = "luoke-scan"
# 清单里给界面用的固定名字（提醒的类别 `reports`、权限 `permissions`）：按代号在这里起名（负责人 11-17：用语由 agent 定）；
# 这里没有的代号照清单写的
KIND_NAMES = {"security": "安全问题", "space": "磁盘空间", "findings": "扫描结果", "needs-access": "权限申请",
              "auto-done": "自动清理结果"}
PERMISSION_NAMES = {"fda": "完全磁盘访问", "auto": "自动清理 4 类文件", "admin": "删除系统目录中的项目（需输入 Mac 密码）"}
PAGE_NEEDS = {
    "overview": ("overview",),
    "category": ("category",),
    "cleaned": ("history",),
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
ITEM_ROWS = 25      # 一类的详情一页几项（一项六七个组件，页最多 400 个；负责人 11-15：约 42 项就超）
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
    """一类下面那一句：说清是什么，后面是大小"""
    f = c.get("facts") or {}
    n, kind = c.get("count") or 0, c.get("id")
    tools, apps = f.get("tools") or [], f.get("apps") or []
    if kind == "cache":
        who = "、".join((tools or apps)[:3]) + (" 等" if len(tools or apps) > 3 else "")
        text = f"{who}的缓存，可自动重建" if who else f"{n} 项缓存，可自动重建"
    elif kind == "installer":
        text = f"{n} 个安装包，其中 {f.get('appsInstalled', 0)} 个对应的应用已安装" if f.get("appsInstalled") else f"{n} 个较早下载的安装包"
    elif kind == "duplicate":
        text = f"{n} 个，其他位置仍保留一份"
    elif kind == "temp":
        text = f"{c.get('files') or n} 个文件夹，测试工具运行后未删除"
    elif kind == "leftover":
        text = f"{f.get('appsMissing', 0)} 个已删除应用的残留数据" if f.get("appsMissing") else f"{n} 项不再使用的数据"
    elif kind == "project":
        text = f"{n} 项，均已推送或可重新生成"
    else:
        text = f"{n} 项"
    return f"{text} · {size(c.get('bytes'))}" if c.get("bytes") else text


def _rule_name(rule: Optional[str]) -> str:
    return next((name for prefix, name in RULES if (rule or "").startswith(prefix)), "需要注意的项目")


def overview(args: Dict[str, str], read: Read) -> List[dict]:
    """扫描：检查（上次什么时候、现在查一次、没查成的）；安全（要注意的每一项，急的在前）；清理（按类，每类一句、点进详情）；
    已自动清理。安全和清理分开，安全在上（负责人 11-16）。每个入口一整行"""
    d = read(uri("overview")) or {}
    kit = PageKit("overview")
    top: List[str] = []

    # 检查：上次什么时候查的、现在查一次；没查成的几项和原因（负责人 11-15：没有「现在查一下」，也不写上次什么时候查的）
    scanning, scanned = d.get("scanning"), d.get("scanned") or {}
    check_rows = []
    if isinstance(scanning, dict):
        frac = scanning.get("fraction")
        check_rows.append(kit.item("正在检查" + (f" {round(frac * 100)}%" if isinstance(frac, (int, float)) else ""), None, strong=False))
    else:
        title = f"上次检查：{_when(scanned.get('finished'))}" if scanned.get("finished") else "尚未检查"
        check_rows.append(kit.item(title, None, [kit.button("立即检查", "scan_now", {}, icon="refresh-cw", variant="borderless")],
                                   strong=False))
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
    top += [kit.heading("检查"), kit.list(check_rows)]

    # 安全：要注意的每一项，一项一行（急的在前）；能在某一类里处理的点进那一类，有位置的能在访达中显示，每项能设为不再提醒
    att = d.get("attention") or {}
    items = sorted(att.get("items") or [], key=lambda a: (not a.get("urgent"), {"high": 0, "medium": 1, "low": 2}.get(a.get("severity"), 3)))
    cats = _cats(d)
    sec_cats = [c for c in cats if c.get("id") in SECURITY_CATS]
    n_att = int(att.get("count") or len(items))
    top.append(kit.heading(f"安全 · {n_att}" if n_att else "安全"))
    rows = [_attention_row(kit, a) for a in items[:SHOW_ATTENTION]]
    if len(items) > SHOW_ATTENTION:
        rows.append(kit.fold(f"其余 {len(items) - SHOW_ATTENTION} 项", [kit.list([_attention_row(kit, a) for a in items[SHOW_ATTENTION:SHOW_ATTENTION * 3]])]))
    listed = {a.get("category") for a in items}
    rows += [_cat_row(kit, c) for c in sec_cats if c.get("id") not in listed]
    if not rows:
        rows = [kit.item("未发现安全问题", None, strong=False)]
    top.append(kit.list(rows))

    # 清理：按类，大的在前；大文件、其余几类各一整行
    clean_cats = [c for c in cats if c.get("id") not in SECURITY_CATS]
    lf = d.get("largeFiles") or {}
    if clean_cats or lf.get("count"):
        total = sum(c.get("bytes") or 0 for c in clean_cats)
        top.append(kit.heading(f"清理 · 可释放 {size(total)}" if clean_cats else "清理"))
        rows = [_cat_row(kit, c) for c in clean_cats[:SHOW_CATS]]
        if lf.get("count"):
            go = kit.open_page("大文件", "category", {"id": "large-file"})
            rows.append(kit.item(CAT["large-file"], f"{lf['count']} 个 · {size(lf.get('bytes'))} · 不会自动清理", [go], open=go))
        if len(clean_cats) > SHOW_CATS:
            go = kit.open_page("其他", "more")
            rest = clean_cats[SHOW_CATS:]
            rows.append(kit.item(f"其他 {len(rest)} 类", size(sum(c.get("bytes") or 0 for c in rest)), [go], open=go, strong=False))
        top.append(kit.list(rows))
    elif scanned.get("finished"):
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


def _ymd(s: Any) -> str:
    """「2025年9月15日」：带年份（#165：只写月日的像是今年）"""
    try:
        return f"{int(s[:4])}年{int(s[5:7])}月{int(s[8:10])}日"
    except (TypeError, ValueError):
        return ""


FOLDER_ROWS = 12    # 一个文件夹里先列最大的几项


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
    rows = []
    if u.get("parent"):
        up = kit.open_page("上一级", "folder", {"dir": u["parent"]})
        rows.append(kit.item("上一级", None, [up], open=up, strong=False))
    for it in items[:FOLDER_ROWS]:
        why = explain.words(known.get(it.get("key")))
        what = "文件夹" if it.get("dir") else "文件"
        sub = " · ".join(x for x in (what, f"{_ymd(it.get('changed'))}修改" if _ymd(it.get("changed")) else "") if x)
        right = [kit.text(size(it["bytes"]) if isinstance(it.get("bytes"), int) else "未统计完", "caption"),
                 kit.button("在访达中显示", "agent.reveal", {"item": it["path"]}, icon="folder", variant="borderless")]
        left = [kit.text(str(it.get("name") or "")[:80], "strong")] + ([kit.text(why, "caption")] if why else []) + [kit.text(sub, "caption")]
        if it.get("dir"):
            go = kit.open_page("查看内容", "folder", {"dir": it["path"]})
            rows.append(kit.row([kit.column(left), kit.row(right + [go])], justify="spaceBetween", open=go))
        else:
            rows.append(kit.row([kit.column(left), kit.row(right)], justify="spaceBetween"))
    if not items and not measuring:
        rows.append(kit.item("此文件夹为空", None, strong=False))
    if rows:
        top.append(kit.list(rows))
    if len(items) > FOLDER_ROWS:
        top.append(kit.text(f"另有 {len(items) - FOLDER_ROWS} 项较小的未列出", "caption"))
    top.append(kit.text("此处仅供查看，删除请在访达中操作", "caption"))
    # 量着的时候、用途说明正在问的时候隔几秒重读
    return kit.messages(top, refresh=3 if measuring else 5 if u.get("explaining") else None)


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

    scope, folders, total = _mac_folders(read)
    if folders:
        top.append(kit.heading("占用最多的文件夹" + (f"（{scope}）" if scope else "")))
        # 能清的那几行点进那一类的清单（在那里勾选、清理）；用户自己的文件夹扫描还没给里面有什么，只能看
        have = {c.get("id") for c in _cats(d) if c.get("count")}
        rows = []
        for name, sz, frac, cid, path, grew in folders:
            right = [kit.text(sz, "caption"), bar(frac)]
            if cid in have:
                go = kit.open_page("查看可清理项", "category", {"id": cid})
                rows.append(kit.item(name, " · ".join(x for x in (FOLDER_HAS[cid], grew) if x), right + [go], open=go, strong=False))
            elif path:
                go = kit.open_page("查看内容", "folder", {"dir": path})      # 点开看里面什么最占地方（核心自己量）
                rows.append(kit.item(name, grew or None, right + [go], open=go, strong=False))
            else:
                rows.append(kit.item(name, grew or None, right, strong=False))
        top.append(kit.list(rows))
        if total:
            top.append(kit.text(f"以上合计约 {total}，其余为未列出的小文件夹、系统和应用", "caption"))

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
        top += [kit.heading("病毒库"),
                kit.list([kit.item(" · ".join(str(x) for x in (db.get("version"), db.get("date")) if x), None, strong=False)])]
    return kit.messages(top)


def _attention_row(kit: PageKit, a: dict) -> str:
    """要注意的一项：是什么、风险多高、在哪；点进能处理它的那一类；能在访达中显示、设为不再提醒"""
    name = _rule_name(a.get("rule"))
    where = (a.get("path") or "").rstrip("/").split("/")[-1]
    sub = " · ".join(x for x in ("需尽快处理" if a.get("urgent") else SEVERITY.get(a.get("severity"), ""), where) if x)
    btns = []
    if a.get("reveal") and a.get("finding"):
        btns.append(kit.button("在访达中显示", "scan_reveal", {"finding_id": a["finding"]}, icon="folder", variant="borderless"))
    if a.get("finding"):
        btns.append(kit.button("标为误报" if (a.get("rule") or "").startswith("malware.") else "不再提醒", "scan_ignore",
                               {"finding_id": a["finding"]}, icon="bell-off", variant="borderless"))
    opened = kit.open_page("查看详情", "category", {"id": a["category"]}) if a.get("category") else None
    if opened:
        btns.append(opened)
    return kit.item(name, sub or None, btns, open=opened)


def _cats(d: dict) -> List[dict]:
    """能处理的几类，大的在前（大文件不会自动清理，单独一行）"""
    cats = [c for c in d.get("reclaimable") or [] if c.get("id") not in ("large-file",)]
    return sorted(cats, key=lambda c: -(c.get("bytes") or 0))


def _cat_row(kit: PageKit, c: dict) -> str:
    go = kit.open_page("查看详情", "category", {"id": c["id"]})
    return kit.item(CAT.get(c["id"], c["id"]), _summary(c), [go], open=go)


def more(args: Dict[str, str], read: Read) -> List[dict]:
    """「其他 N 类」（弹窗）：概览「清理」里没列的几类，一样点进详情"""
    kit = PageKit("more")
    rest = [c for c in _cats(read(uri("overview")) or {}) if c.get("id") not in SECURITY_CATS][SHOW_CATS:]
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


SKILL_KINDS = {"download-exec": "会下载并执行代码", "exfil": "会向外发送对话内容", "md": "说明文件含可疑指令"}


def _why(it: dict) -> str:
    """一项为什么列在这里：在哪 · 多大 · 原因。每一类都写原因（负责人 11-15：病毒、开机自启、AI 插件这几类只剩位置和大小）"""
    f, r = it.get("facts") or {}, it.get("reason")
    where = _where(it.get("path") or "")
    why = {"installed": f"{_day(f.get('added'))}下载，应用已安装" + (f"，当前版本 {f['appVersion']}" if f.get("appVersion") else ""),
           "old-download": f"{f.get('days', 0)} 天前下载", "rebuilds": "可自动重建", "app-rebuilds": "可自动重建",
           "copy-kept": "其他位置仍保留一份", "left-behind": f"{f.get('count', 1)} 个，测试工具运行后未删除",
           "app-removed": "应用已删除", "unfinished": "下载未完成", "pushed": "已推送", "regenerable": "可重新生成",
           "not-opened": f"{_day(f.get('lastOpened'))}后未打开" if f.get("lastOpened") else "从未打开",
           "redownload": "需要时可重新下载", "logs": "日志", "newer-version": "已有更新的版本",
           "intel-homebrew": "Intel 版 Homebrew，已不再使用",
           "signature": "病毒库检出" + (f"：{f.get('signature') or f.get('rule')}" if f.get("signature") or f.get("rule") else ""),
           "program-missing": "启动的程序已不存在",
           "new": "新增的开机启动项" + (f"：{f.get('name') or f.get('app') or f.get('label')}" if f.get("name") or f.get("app") or f.get("label") else ""),
           "template-extra": "对话模板包含额外内容", "scripts-on": "安装依赖时自动运行脚本"}.get(r, "")
    if not why and r in SKILL_KINDS:
        kinds = [SKILL_KINDS[k] for k in f.get("kinds") or [r] if k in SKILL_KINDS]
        why = "、".join(kinds) or SKILL_KINDS[r]
    return " · ".join(x for x in (where, size(it.get("bytes")) if it.get("bytes") is not None else "", why) if x)


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


def category(args: Dict[str, str], read: Read) -> List[dict]:
    """一类的详情（弹窗）：最上面是判断；下面逐项（在哪、多大、为什么），默认按建议勾选、可以取消，每项能在访达中显示、设为不再提醒；
    一页 25 项，多的翻页（勾选管全部）；按钮照实际怎么处理写，每份方案一个按钮（要密码的另一份也有），重复文件能换成克隆"""
    cid = args.get("id") or ""
    d = read(uri("category", id=cid)) or {}
    kit = PageKit("category")
    if not d.get("known"):
        return kit.messages([kit.text("此类别已不存在", "caption")])
    # 不占空间的（安全的几类）不写「0 字节」
    title = kit.text(f"{CAT.get(cid, cid)} · {size(d.get('bytes'))}" if d.get("bytes") else CAT.get(cid, cid), "h4")
    kit.components[-1]["placement"] = "header"      # 弹窗的标题
    top = [title]
    judge = _judgement(d)
    if judge:
        top.append(kit.column([kit.text("判断", "caption"), kit.text(judge)]))
    items = d.get("items") or []
    try:
        page = max(1, int(args.get("p") or 1))
    except ValueError:
        page = 1
    pages = max(1, -(-len(items) // ITEM_ROWS))
    page = min(page, pages)
    shown = items[(page - 1) * ITEM_ROWS:page * ITEM_ROWS]
    plans: Dict[str, List[dict]] = {}
    for it in items:        # 勾选管全部：没画在这一页的也在数据里，照建议勾着
        plans.setdefault(it["plan"], []).append(it)
        kit.data.setdefault("checks", {})[it["key"]] = it.get("suggested") not in (None, "keep", "ignore")
    groups: Dict[str, List[dict]] = {}
    for it in shown:
        groups.setdefault(it.get("group") or "", []).append(it)
    whole: Dict[str, List[dict]] = {}      # 组标题上的个数和大小算全部页的，不只这一页
    for it in items:
        whole.setdefault(it.get("group") or "", []).append(it)
    ignore_word = "标为误报" if cid == "malware" else "不再提醒"
    for g, its in groups.items():
        total = sum(i.get("bytes") or 0 for i in whole[g])
        top.append(kit.heading(" · ".join([GROUP.get(g, g), f"{len(whole[g])} 个"] + ([size(total)] if total else []))))
        rows = []
        for it in its:
            key = it["key"]
            box = kit.add({"id": kit._id("x"), "component": "CheckBox", "label": (it.get("path") or "").split("/")[-1] or key,
                           "value": {"path": f"/checks/{key}"}})
            btns = [kit.button("在访达中显示", "scan_reveal", {"finding_id": it["finding"]}, icon="folder", variant="borderless"),
                    kit.button(ignore_word, "scan_ignore", {"finding_id": it["finding"]}, icon="bell-off", variant="borderless")]
            rows.append(kit.row([kit.column([box, kit.text(_why(it), "caption")]), kit.row(btns)], justify="spaceBetween"))
        first, rest = rows[:SHOW_FIRST], rows[SHOW_FIRST:]
        if rest:
            first.append(kit.fold(f"其余 {len(rest)} 个", rest))
        top.append(kit.list(first))
    if d.get("more"):
        top.append(kit.text(f"另有 {d['more']} 项较小的未列出，不会被处理", "caption"))
    if pages > 1:
        btns = []
        if page > 1:
            btns.append(kit.open_page("上一页", "category", {"id": cid, "p": str(page - 1)}, variant="borderless"))
        if page < pages:
            btns.append(kit.open_page("下一页", "category", {"id": cid, "p": str(page + 1)}, variant="borderless"))
        top.append(kit.row([kit.text(f"第 {page} / {pages} 页 · 共 {len(items)} 项，其他页已勾选的项目一并处理", "caption")] + btns,
                           justify="spaceBetween"))
    btns = []
    for plan, its in plans.items():
        word, note = _apply_words(its)
        needs_pw = any(i.get("password") for i in its)
        label = f"{word}（需输入密码的 {len(its)} 项）" if needs_pw and len(plans) > 1 else word
        btns.append(kit.button(label, "scan_apply", {"plan_id": plan, "selected": {"path": "/checks"},
                                                     "how": {i["key"]: _how(i) for i in its}},
                               variant="primary" if not btns else None,
                               confirm={"title": TITLES.get(word, f"{word}所选项目？"), "text": note + ("；需要输入 Mac 密码" if needs_pw else ""),
                                        "label": word}))
        clones = [i for i in its if "clone" in (i.get("options") or [])]
        if clones:      # 重复文件：换成克隆（不占空间，两份都留着）
            btns.append(kit.button("替换为克隆", "scan_apply", {"plan_id": plan, "selected": {"path": "/checks"},
                                                               "how": {i["key"]: "clone" for i in clones}},
                                   confirm={"title": "将所选重复文件替换为克隆？", "text": "两份文件都保留，不再重复占用空间",
                                            "label": "替换"}))
    if plans:
        first_plan, its = next(iter(plans.items()))
        btns.append(kit.button("此类不再提醒", "scan_apply", {"plan_id": first_plan, "choices": {i["key"]: ["ignore"] for i in its}}))
    if btns:
        top.append(kit.row(btns))
    return kit.messages(top)


def action(name: str, ctx: Dict[str, Any]) -> Tuple[str, Dict[str, Any]]:
    """页上点按交给扫描前改形状：详情里勾了哪些（`selected`，key → 勾没勾）换成扫描认的
    `{"plan_id", "choices": {"<key>": ["trash" / "remove" / "delete" / "scripts-off" / "clone"]}}`，没勾的不发（扫描当先不动）"""
    if name == "scan_apply" and isinstance(ctx.get("selected"), dict):
        how = ctx.get("how") if isinstance(ctx.get("how"), dict) else {}
        ok = HOW + ("clone",)
        picked = {k: [how[k] if how.get(k) in ok else "trash"] for k, on in ctx["selected"].items() if on is True and k in how}
        return name, {"plan_id": ctx.get("plan_id"), "choices": picked}
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
    ignored = d.get("ignored") or []
    if ignored:
        top.append(kit.heading(f"不再提醒 · {len(ignored)}"))
        rows = []
        for g in ignored[:40]:
            undo = kit.button("撤销", "scan_ignore", {"finding_id": g["finding"], "undo": True}, icon="undo-2", variant="borderless")
            name = (g.get("path") or "").rstrip("/").split("/")[-1] or CAT.get(g.get("category")) or _rule_name(g.get("rule"))
            rows.append(kit.item(name, CAT.get(g.get("category")) or _rule_name(g.get("rule")), [undo], strong=False))
        top.append(kit.list(rows))
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
        card.heading(head or f"{_n(decide.get('toLook'))} 项待处理")
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
            btns.append(cards.button(f"在扫描页查看 {rest} 项", "agent.open_page", {"page": "overview"}, primary=not btns))
        if decide.get("offerAuto"):
            btns.append(cards.button("开启自动清理", "scan_autoclean", {"on": True}))
        if btns:
            card.buttons(*btns)
        titles.append((f"{head}，另有 {rest} 项待处理" if head else f"{rest} 项待处理") if rest > 0 else head)
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
