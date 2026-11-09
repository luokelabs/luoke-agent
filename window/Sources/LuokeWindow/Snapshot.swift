import AppKit
import LuokeA2UICore
import SwiftUI

/// 把界面画成图（离屏，不开窗口、不要图形会话，CI 的机器和远程开发机上都能跑）。每个 PR 都把下面列的每个界面截一遍。
@MainActor
public enum Snapshot {
    public static let windowSize = CGSize(width: 1004, height: 760)
    public static let menuSize = CGSize(width: 1004, height: 470)
    public static let statusSize = CGSize(width: 1004, height: 300)
    /// 截图里的「现在」：每天截出来一样
    static let fixedNow: Date = DateComponents(calendar: Calendar(identifier: .gregorian), year: 2026, month: 11, day: 4, hour: 9, minute: 58).date ?? Date()

    public struct Screen {
        public let name: String
        public let title: String
        public let size: CGSize
        public let build: () -> AnyView
    }

    /// 全部界面。名字是文件名（再加 -light、-dark）。
    public static func screens() -> [Screen] {
        func window(_ name: String, _ title: String, size: CGSize = windowSize, _ setup: @escaping (WindowModel) -> Void) -> Screen {
            Screen(name: name, title: title, size: size) {
                let m = Sample.model()
                m.now = { fixedNow }
                setup(m)
                return AnyView(MainWindowView(model: m))
            }
        }
        func scene(_ name: String, _ title: String, size: CGSize, open: String?, _ setup: @escaping (WindowModel) -> Void = { _ in }) -> Screen {
            Screen(name: name, title: title, size: size) {
                let m = Sample.model()
                setup(m)
                return AnyView(Themed { MenuBarScene(model: m, open: open) })
            }
        }
        /// 接上核心：邮件助手、螺壳扫描是它们录的场景样例（经真核心），记忆和 agent 自己的是手写的示例。
        /// `beta2`：螺壳.app 现在发的样子（beta 2 精简版：今天、应用页、设置，底部只有搜索；不带记忆）；
        /// `scale`：邮件助手的卡片复制几份（看条目很多时的样子，卡片内容还是录的）
        func fed(_ m: WindowModel, scan: String, mail: String, beta2: Bool, scale: Int = 1, openURL: Bool = false, pages: Bool = true) {
            let feed = AgentFeed(model: m)
            var events = Sample.agentEvents(scan: scan, mail: mail, openURL: openURL, memory: !beta2)
            if scale > 1 { events = StressSample.scaled(events, app: "luoke-mail", times: scale) }
            for (e, d) in events { feed.handle(e, d) }
            if pages {
                Sample.applyAgentApps(feed, scan: scan, mail: mail)
            } else {   // 应用清单拿到了，页面一次也没拿到（没连上核心）
                if let v = try? JSONValue.parse(Sample.agentApps(scan: scan, mail: mail)) { feed.applyApps(v) }
                for a in m.agentApps ?? [] {
                    for p in a.pages { feed.applyPage(app: a.id, page: p.id, status: 0, body: Data()) }
                }
            }
            guard beta2 else { return }
            m.features = .beta2
            // 螺壳.app 报装了哪些应用（beta 2 随包带邮件助手和螺壳扫描），侧栏「应用」照它列
            m.setInstalledApps([("luoke-mail", mail), ("luoke-scan", scan)].map { app, sc in
                InstalledApp(accessory: app, version: ToolSample.load(app, sc)?.version ?? "")
            })
        }
        /// 螺壳.app 现在发的样子，侧栏的「应用」展开；扫描默认是「用了一阵的开发机」那一轮（一张很长的卡片），和真机上常见的一样
        func shipped(_ name: String, _ title: String, scan: String = ToolSample.fullScan, mail: String = ToolSample.defaultMail,
                     appsOpen: Bool = true, scale: Int = 1, pages: Bool = true, size: CGSize = windowSize,
                     _ then: @escaping (WindowModel) -> Void = { _ in }) -> Screen {
            window(name, title, size: size) { m in
                fed(m, scan: scan, mail: mail, beta2: true, scale: scale, pages: pages)
                if m.appsExpanded != appsOpen { m.toggleApps() }
                then(m)
            }
        }
        /// 整页：窗口拉到 `height` 高，往下滚才看得到的也画出来（截图里滚动区平铺、多出来的从下面截掉）
        func whole(_ name: String, _ title: String, height: CGFloat, _ then: @escaping (WindowModel) -> Void = { _ in }) -> Screen {
            shipped(name + "-whole", title + " · 整页（往下滚看到的全部）", size: CGSize(width: windowSize.width, height: height), then)
        }
        func menu(_ name: String, _ title: String, size: CGSize, open: String?, _ setup: @escaping (WindowModel) -> Void = { _ in }) -> Screen {
            scene(name, title, size: size, open: open) { m in
                fed(m, scan: ToolSample.fullScan, mail: ToolSample.defaultMail, beta2: true)
                setup(m)
            }
        }
        /// 完整版（beta 2 还没有的页和功能）：手写的示例数据，名字前面加 full-
        func full(_ name: String, _ title: String, _ setup: @escaping (WindowModel) -> Void) -> Screen {
            window("full-" + name, "完整版（beta 2 没有）· " + title, setup)
        }
        /// 压力：条目很多、什么都没有、还在等、出错、窗口大小（卡片还是录的，只是复制了几份）
        func stress(_ name: String, _ title: String, mail: String = ToolSample.defaultMail, scale: Int = 1, pages: Bool = true,
                    size: CGSize = windowSize, _ then: @escaping (WindowModel) -> Void = { _ in }) -> Screen {
            shipped("stress-" + name, "压力 · " + title, mail: mail, scale: scale, pages: pages, size: size, then)
        }
        // 扫描、邮件助手的每个场景各一张
        let scanScenes = ToolSample.scenarios("luoke-scan").filter { $0 != ToolSample.fullScan }.compactMap { sc -> Screen? in
            guard let s = ToolSample.load("luoke-scan", sc) else { return nil }
            return shipped("scan-agent-\(sc)", "螺壳扫描 · \(s.title)", scan: sc) { m in
                m.go(.scan)
                if let page = s.interestingPage { m.selectAppTab(page) }
            }
        }
        let mailScenes = ToolSample.scenarios("luoke-mail").filter { $0 != ToolSample.defaultMail }.compactMap { sc -> Screen? in
            guard let s = ToolSample.load("luoke-mail", sc) else { return nil }
            return shipped("today-mail-\(sc)", "今天 · 邮件助手：\(s.title)", mail: sc)
        }
        let many = 5   // 邮件助手的卡片复制 5 份：急事 40 多张、要你决定 5 张
        return [
            shipped("today", "今天"),
            whole("today", "今天", height: 5600),
            shipped("today-apps-closed", "今天 · 侧栏「应用」收起", appsOpen: false),
            shipped("today-mini", "侧栏收成图标") { $0.setSidebar(mini: true) },
            shipped("today-no-fda", "今天 · 第一次扫描，还没给完全磁盘访问", scan: "first-run-no-fda"),
            shipped("today-malware", "今天 · 下载里有报毒的文件", scan: "malware"),
        ] + mailScenes + [
            shipped("today-brief", "今天 · 点开简报") { $0.openBrief(time: "08:00") },
            shipped("host-notice", "今天 · 旧的「螺壳 agent」还在运行") { m in
                m.hostNotice = "旧的「螺壳 agent」还在运行：退出它以后，这里接上。"
            },
            shipped("focus", "一件件处理") { $0.enterFocus() },
            whole("focus", "一件件处理", height: 1600) { $0.enterFocus() },
            shipped("focus-end", "一件件处理 · 都答完了") { m in
                m.enterFocus()
                m.cards = []
            },
            shipped("focus-left", "一件件处理 · 跳过了几件") { m in
                m.enterFocus()
                for _ in m.cards { m.skipFocus() }
            },
            shipped("permission", "要权限") { $0.requestPermission("calendar") },
            shipped("scan", "螺壳扫描") { $0.go(.scan) },
            shipped("mail", "邮件助手") { $0.go(.mail) },
        ] + scanScenes + [
            shipped("apps", "添加应用") { $0.go(.apps) },
            shipped("prefs-alerts", "设置 · 提醒") { $0.go(.prefs, tab: "alerts") },
            shipped("prefs-permissions", "设置 · 权限") { $0.go(.prefs, tab: "permissions") },
            shipped("prefs-permissions-off", "设置 · 权限 · 关了「允许」") { m in
                m.hostConfirmed = [:]
                m.go(.prefs, tab: "permissions")
            },
            shipped("search-running", "搜索 · 正在搜") { $0.runSearch("合同") },
            shipped("search-failed", "搜索 · 没连上核心") { $0.searchAnswer = SearchAnswer(note: "没连上螺壳的核心。") },
            shipped("search-nothing", "搜索 · 没找到、两个应用没答复") { $0.searchAnswer = SearchAnswer(failed: ["邮件助手", "记忆"]) },
            menu("menu-go", "顶部菜单 · 前往", size: menuSize, open: "go"),
            menu("menu-app", "顶部菜单 · 螺壳", size: menuSize, open: "app"),
            menu("menu-view", "顶部菜单 · 显示", size: menuSize, open: "view"),
            // 急事多时菜单长：比平常的菜单栏图标截图高
            menu("status", "菜单栏图标 · 有急事", size: menuSize, open: nil),
            menu("status-quiet", "菜单栏图标 · 没有急事、暂停提醒", size: statusSize, open: nil) { m in
                m.urgent = []
                m.togglePause()
                m.dismissToast()
            },
            // 压力
            stress("today-many", "今天 · 邮件的卡片多 5 倍（急事 40 多张）", scale: many),
            stress("today-mini-many", "侧栏收成图标 · 卡片多 5 倍", scale: many) { $0.setSidebar(mini: true) },
            stress("focus-many", "一件件处理 · 5 件", scale: many) { $0.enterFocus() },
            stress("today-empty", "今天 · 第一天，什么都没有", mail: "no-account") { m in
                m.urgent = []; m.cards = []; m.done = []; m.quiet = []; m.notices = []
            },
            stress("today-waiting", "今天 · 模型在准备、核心的数据还没到") { m in
                m.urgent = []; m.cards = []; m.done = []; m.quiet = []; m.notices = []
                m.engineReady = false
                m.waitingForFeed = true
            },
            stress("scan-unreachable", "螺壳扫描 · 页面一次也没拿到（没连上核心）", pages: false) { $0.go(.scan) },
            stress("small-window", "小窗口 860×600（螺壳.app 允许的最小）", size: CGSize(width: 860, height: 600)),
            stress("large-window", "大窗口 1440×900", size: CGSize(width: 1440, height: 900)),
            // 完整版：beta 2 还没有的（活动、问螺壳、对话、记忆、显示和模型、隐私），用手写的示例
            full("today", "今天") { _ in },
            full("today-compact", "今天 · 紧凑") { $0.setDensity(.compact) },
            full("today-done", "照方案处理以后") { m in
                if let c = m.cards.first { m.tap(card: c, name: "mail_apply_plan", context: .object([:])) }
            },
            full("ask", "问螺壳") { $0.openAsk() },
            full("chat", "对话") { m in m.openAsk(); m.expandAnswer() },
            full("activity", "活动") { $0.go(.activity) },
            full("mem", "记忆") { $0.go(.mem) },
            full("search", "搜索结果") { $0.go(.search) },
            full("search-ask", "搜索 · 问螺壳") { $0.go(.search); $0.openAsk() },
            full("prefs-display", "设置 · 显示") { $0.go(.prefs, tab: "display") },
            full("prefs-model", "设置 · 模型") { $0.go(.prefs, tab: "model") },
            full("prefs-privacy", "设置 · 隐私") { $0.go(.prefs, tab: "privacy") },
            scene("full-menu-go", "完整版（beta 2 没有）· 顶部菜单 · 前往", size: menuSize, open: "go"),
        ]
    }

    /// 画成 PNG。scale 2 和 Retina 屏一样清楚。
    public static func png(_ screen: Screen, dark: Bool, scale: CGFloat = 2) -> Data? {
        let view = screen.build()
            .frame(width: screen.size.width, height: screen.size.height)
            .environment(\.colorScheme, dark ? .dark : .light)
            .environment(\.lkSnapshot, true)
            .environment(\.locale, Locale(identifier: "zh_CN"))
        let r = ImageRenderer(content: view)
        r.scale = scale
        r.proposedSize = ProposedViewSize(screen.size)
        guard let cg = r.cgImage else { return nil }
        return NSBitmapImageRep(cgImage: cg).representation(using: .png, properties: [:])
    }
}
