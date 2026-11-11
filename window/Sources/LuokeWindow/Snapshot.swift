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
    /// 截图里点了名、却没有样例的场景（`工具/场景`）。名字写错了，那张图只是少一个应用，照样画得出来，所以记下来，
    /// 由 ScreenshotTests 核对它是空的
    static var missingSamples: Set<String> = []

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
        /// `flood`：邮件助手的急事复制几份，每份带一句不同的副标题（#54 的回放，`StressSample.urgentFlood`）；
        /// `decide`：邮件助手要你决定的卡片复制几份（#51 的 `stress-brief-many`）
        func fed(_ m: WindowModel, scan: String, mail: String, beta2: Bool, scale: Int = 1, flood: Int = 0, decide: Int = 0,
                 openURL: Bool = false, pages: Bool = true) {
            for (app, sc) in [("luoke-scan", scan), ("luoke-mail", mail)] where ToolSample.load(app, sc) == nil {
                missingSamples.insert("\(app)/\(sc)")
            }
            let feed = AgentFeed(model: m)
            var events = Sample.agentEvents(scan: scan, mail: mail, openURL: openURL, memory: !beta2,
                                            extras: ToolSample.local.scenario == nil)
            if scale > 1 { events = StressSample.scaled(events, app: "luoke-mail", times: scale) }
            if flood > 0 { events = StressSample.urgentFlood(events, app: "luoke-mail", times: flood, subtitle: StressSample.mailSubtitle) }
            if decide > 0 { events = StressSample.decideFlood(events, app: "luoke-mail", times: decide) }
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
                     appsOpen: Bool = true, scale: Int = 1, flood: Int = 0, decide: Int = 0, pages: Bool = true, size: CGSize = windowSize,
                     _ then: @escaping (WindowModel) -> Void = { _ in }) -> Screen {
            window(name, title, size: size) { m in
                fed(m, scan: scan, mail: mail, beta2: true, scale: scale, flood: flood, decide: decide, pages: pages)
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
        /// 滚到底：窗口大小不变，滚动区停在最下面（带着底部的搜索框）
        func end(_ s: Screen) -> Screen {
            Screen(name: s.name + "-end", title: s.title + " · 滚到底", size: s.size) { AnyView(s.build().environment(\.lkScrolledToEnd, true)) }
        }
        /// 压力：条目很多、什么都没有、还在等、出错、窗口大小（卡片还是录的，只是复制了几份）
        func stress(_ name: String, _ title: String, mail: String = ToolSample.defaultMail, scale: Int = 1, flood: Int = 0,
                    decide: Int = 0, pages: Bool = true, size: CGSize = windowSize, _ then: @escaping (WindowModel) -> Void = { _ in }) -> Screen {
            shipped("stress-" + name, "压力 · " + title, mail: mail, scale: scale, flood: flood, decide: decide, pages: pages, size: size, then)
        }
        /// 真窗口那条路：卡片里的控件不画成截图用的静态样子（`lkLiveControls`），量得出真窗口里选择框、下拉框的样子
        func live(_ s: Screen) -> Screen {
            Screen(name: "live-" + s.name, title: s.title + " · 真窗口的控件", size: s.size) {
                AnyView(s.build().environment(\.lkLiveControls, true))
            }
        }
        // 扫描、邮件助手的每个场景各一张
        let scanScenes = ToolSample.scenarios("luoke-scan").filter { $0 != ToolSample.fullScan }.compactMap { sc -> Screen? in
            guard let s = ToolSample.load("luoke-scan", sc) else { return nil }
            return shipped("scan-agent-\(sc)", "螺壳扫描 · \(s.title)", scan: sc) { m in
                m.go(.scan)
                if let page = s.interestingPage { m.selectAppTab(page) }
            }
        }
        // 扫描的「状态」页（luoke-scan#124）：给了完全磁盘访问的、没给的；长页滚到底；小窗口
        let macScenes = ["full-report", "first-run-no-fda", "fda-granted"].compactMap { sc -> Screen? in
            guard let s = ToolSample.load("luoke-scan", sc) else { return nil }
            return shipped("scan-mac-\(sc)", "螺壳扫描 · 状态：\(s.title)", scan: sc) { m in
                m.go(.scan)
                m.selectAppTab("mac")
            }
        }
        let macSmall = shipped("scan-mac-small-window", "螺壳扫描 · 状态 · 小窗口 860×600", scan: "full-report", size: CGSize(width: 860, height: 600)) { m in
            m.go(.scan)
            m.selectAppTab("mac")
        }
        let macSmallNoFDA = shipped("scan-mac-small-window-no-fda", "螺壳扫描 · 状态 · 没允许完全磁盘访问 · 小窗口 860×600", scan: "first-run-no-fda",
                                    size: CGSize(width: 860, height: 600)) { m in
            m.go(.scan)
            m.selectAppTab("mac")
        }
        // 点了扫描页上缓存那一行的「清理」、在等答复：那个按钮画转圈，别的灰掉（luoke-scan#152：只是灰掉，看不出在做）
        let scanBusy = shipped("scan-busy", "螺壳扫描 · 点了「清理」、在等") { m in
            m.go(.scan)
            guard let s = m.agentPages[AgentFeed.pageKey("luoke-scan", "overview")]?.surface,
                  let id = s.surface.components.keys.sorted().first(where: { s.surface.components[$0]?["component"]?.string == "Button"
                      && s.surface.buttonLabel($0).text == "清理" }) else { return }
            s.busy = true
            s.pressed = id
        }
        let macExtra = macScenes.map { end($0) } + [macSmall, end(macSmall), macSmallNoFDA, end(macSmallNoFDA)]
        // 每个场景一张窗口大小的，一张整页：每个邮箱一张的卡片在「顺便看看」里，往下滚才看得到
        let mailScenes = ToolSample.scenarios("luoke-mail").filter { $0 != ToolSample.defaultMail }.flatMap { sc -> [Screen] in
            guard let s = ToolSample.load("luoke-mail", sc) else { return [] }
            return [shipped("today-mail-\(sc)", "今天 · 邮件助手：\(s.title)", mail: sc),
                    shipped("today-mail-\(sc)-whole", "今天 · 邮件助手：\(s.title) · 整页（往下滚看到的全部）", mail: sc,
                            size: CGSize(width: windowSize.width, height: 2400))]
        }
        // 邮件助手应用页的每一页各一张（第一页是「邮件助手」那张）：页是它录的场景样例里的（0.19.45 起八页）
        let mailPages: [Screen] = {
            guard let s = ToolSample.load("luoke-mail", ToolSample.defaultMail) else { return [] }
            let titles = Dictionary((s.apps.first?["pages"]?.array ?? []).compactMap { p -> (String, String)? in
                guard let id = p["id"]?.string else { return nil }
                return (id, p["title"]?.string ?? id)
            }, uniquingKeysWith: { a, _ in a })
            return s.pageIDs.dropFirst().map { id in
                shipped("mail-\(id)", "邮件助手 · \(titles[id] ?? id)") { m in
                    m.go(.mail)
                    m.selectAppTab(id)
                }
            }
        }()
        let many = 5   // 邮件助手的卡片复制 5 份：急事 40 多张、要你决定 5 张
        /// 超长文件名：读样例时把文件名换成很长的一个
        let longName = "2026年第四季度财务报表_最终版_请勿外传_改了又改的副本（3）.scpt"
        func renamed(_ s: Screen, _ name: String, _ title: String) -> Screen {
            Screen(name: name, title: title, size: s.size) {
                ToolSample.renames = [("update.scpt", longName)]
                defer { ToolSample.renames = [] }
                return s.build()
            }
        }
        /// 点完以后：把工具录的答复卡片（样例里的 call-<file>.json）换到窗口里那张卡片上。工具答 done 时，核心把它挪进
        /// 「已经替你做了」，那一行写答复的那句话（agent.py `done_text`），卡片里的「撤销」画在行尾：这里照样挪
        func answered(_ m: WindowModel, scan: String, _ file: String) {
            guard let r = ToolSample.load("luoke-scan", scan)?.replies.first(where: { $0.file == file }) else { return }
            let target = m.urgent.first { $0.id == r.surface }?.surface ?? m.cards.first { $0.id == r.surface }?.surface
            try? target?.apply(r.card)
            if let i = m.urgent.firstIndex(where: { $0.id == r.surface }) {
                let u = m.urgent.remove(at: i)
                m.done.insert(DoneRow(id: u.id, tool: u.tool, text: r.text, time: AgentFeed.hhmm(fixedNow), undoLabel: nil,
                                      surface: u.surface), at: 0)
            }
        }
        /// 连不上螺壳：上次拿到 feed 是 17 分钟前（09:41），断开了 `since` 秒
        func offline(_ m: WindowModel, since: TimeInterval) {
            m.lastSeen = fixedNow.addingTimeInterval(-17 * 60)
            m.coreReachable = false
            m.offlineSince = fixedNow.addingTimeInterval(-since)
        }
        /// 「已经替你做了」手写的示意行（核心真发的只有点完「不是病毒」那一行；这几行看多行的排法）
        let moreDone = [
            DoneRow(id: "x-d1", tool: .mail, text: "把 3 封订阅邮件归档了", time: "09:30", undoLabel: "撤销"),
            DoneRow(id: "x-d2", tool: .scan, text: "清了 1.2 GB 的工具缓存", time: "08:00"),
            DoneRow(id: "x-d3", tool: .mail, text: "给王老师的回信草稿写好了，在「草稿」里等你看", time: "07:45", undoLabel: "撤销"),
            DoneRow(id: "x-d4", tool: .mail, text: "把 2 封账单放进了「账单」", time: "07:30"),
            DoneRow(id: "x-d5", tool: .scan, text: "把下载里重复的 4 个安装包移到了废纸篓", time: "07:00", undoLabel: "放回"),
        ]
        /// 急事 4 组以上：报毒的两个（扫描）、可疑邮件一摞，再加三件别的应用、别的类
        func moreUrgent(_ m: WindowModel) {
            m.urgent += [
                UrgentItem(id: "x-cal", tool: .mail, title: "王经理说 10 点的会提前到 9:30，就在 2 分钟后", time: "09:56",
                           primary: "知道了", primarySymbol: nil, secondary: "打开邮件", kind: "meeting"),
                UrgentItem(id: "x-disk", tool: .core, title: "磁盘只剩 4 GB，下载可能会失败", time: "09:40",
                           primary: "看看能清什么", primarySymbol: nil, secondary: "稍后", kind: "disk"),
                UrgentItem(id: "x-login", tool: .mail, title: "有人在新设备上登录了你的邮箱", time: "09:12",
                           primary: "是我", primarySymbol: nil, secondary: "不是我", kind: "login"),
            ]
        }
        /// 按类处理：邮件要你决定的复制 2 份，再插 3 件记忆想问的（手写的示意：记忆还没有录的样例），和邮件交错着来
        func kinds(_ name: String, _ title: String, _ then: @escaping (WindowModel) -> Void = { _ in }) -> Screen {
            stress(name, title, decide: 2) { m in
                if let ask = Sample.model().cards.first(where: { $0.tool == .mem }) {
                    let asks = (1...3).map { TodayCard(id: "ask-mem-\($0)", tool: .mem, time: ask.time, surface: ask.surface, kind: "question") }
                    m.cards.insert(asks[0], at: min(1, m.cards.count))
                    m.cards.append(contentsOf: asks.dropFirst())
                    m.kinds.append(KindSetting(id: "luoke-mem:question", tool: .mem, title: "记忆想问的事", level: .brief))
                }
                then(m)
            }
        }
        /// 紧凑的「今天」急事的回放（#54）：邮件助手 200 件可疑邮件（每件一句不同的副标题）+ 扫描报毒的 2 件 + 别的应用 3 件 = 205 件
        func flood(_ name: String, _ title: String, _ then: @escaping (WindowModel) -> Void = { _ in }) -> Screen {
            stress(name, title, flood: StressSample.urgentReplay - 5) { m in
                moreUrgent(m)
                m.setDensity(.compact)
                then(m)
            }
        }
        return [
            shipped("today", "今天"),
            whole("today", "今天", height: 2400),
            shipped("today-apps-closed", "今天 · 侧栏「应用」收起", appsOpen: false),
            shipped("today-mini", "侧栏收成图标") { $0.setSidebar(mini: true) },
            shipped("today-no-fda", "今天 · 第一次扫描，还没给完全磁盘访问", scan: "first-run-no-fda"),
            shipped("today-malware", "今天 · 下载里有报毒的文件", scan: "malware"),
            shipped("today-malware-ignored", "今天 · 在「update.scpt」上点了「不是病毒」（工具答复的那一行，带撤销）", scan: "malware") {
                answered($0, scan: "malware", "call-scan_ignore.json")
            },
        ] + mailScenes + [
            shipped("today-brief", "今天 · 点开简报") { $0.openBrief(time: "08:00") },
            shipped("host-notice", "今天 · 旧的「螺壳 agent」还在运行") { m in
                m.hostNotice = "旧的「螺壳 agent」还在运行：退出它以后，这里接上。"
            },
            whole("today-update", "今天 · 螺壳.app 报邮件助手有新版本（「顺便看看」里一行）", height: 1100) { m in
                m.setInstalledApps((m.installedApps ?? []).map {
                    $0.accessory == "luoke-mail" ? InstalledApp(accessory: $0.accessory, version: $0.version, update: "0.19.0") : $0
                })
            },
            shipped("focus", "一件件处理") { $0.enterFocus() },
            whole("focus", "一件件处理", height: 1600) { $0.enterFocus() },
            shipped("focus-end", "一件件处理 · 都答完了") { m in
                m.enterFocus()
                m.focus?.tapped = Set(m.cards.map(\.id))   // 都点过了，工具答完收走
                m.cards = []
            },
            shipped("focus-left", "一件件处理 · 跳过了几件") { m in
                m.enterFocus()
                for _ in m.cards { m.skipFocus() }
            },
            shipped("permission", "要权限") { $0.requestPermission("calendar") },
            shipped("scan", "螺壳扫描") { $0.go(.scan) },
            whole("scan", "螺壳扫描", height: 2400) { $0.go(.scan) },
            end(shipped("scan", "螺壳扫描") { $0.go(.scan) }),
            end(shipped("today", "今天")),
            end(shipped("today-mini", "侧栏收成图标") { $0.setSidebar(mini: true) }),
            shipped("mail", "邮件助手") { $0.go(.mail) },
        ] + mailPages + scanScenes + macScenes + macExtra + [scanBusy] + scanScenes.filter { (x: Screen) -> Bool in x.name == "scan-agent-decide-3" }.map { (x: Screen) -> Screen in end(x) }
          + scanScenes.filter { (x: Screen) -> Bool in x.name == "scan-agent-decide-3" }.map { (x: Screen) -> Screen in live(x) } + [
            shipped("apps", "添加应用") { $0.go(.apps) },
            shipped("prefs-alerts", "设置 · 提醒") { $0.go(.prefs, tab: "alerts") },
            shipped("prefs-permissions", "设置 · 权限") { $0.go(.prefs, tab: "permissions") },
            shipped("prefs-permissions-off", "设置 · 权限 · 关了「允许」") { m in
                m.hostConfirmed = [:]
                m.go(.prefs, tab: "permissions")
            },
            // 本体的界面画在主窗口里（11-10：螺壳只有一个窗口）。内容是示意，真的由螺壳.app 给
            shipped("host-page", "本体的一页 · 检查更新") { m in
                m.go(.scan)
                m.present(HostPage(id: "update", title: "检查更新", content: AnyView(HostSample.update)))
            },
            shipped("host-card", "本体的卡片 · 要权限") { m in
                m.present(HostPage(id: "ask-fda", title: "开启螺壳扫描", style: .card, content: AnyView(HostSample.permission)))
            },
            shipped("host-card-tall", "本体的卡片 · 内容比窗口高（标题不动、内容滚）", size: CGSize(width: 860, height: 600)) { m in
                m.present(HostPage(id: "ask-fda", title: "开启螺壳扫描", style: .card, content: AnyView(HostSample.tall)))
            },
            shipped("host-takeover", "本体占整个窗口 · 首次设置") { m in
                m.present(HostPage(id: "first-run", title: "欢迎使用螺壳", style: .takeover, content: AnyView(HostSample.welcome)))
            },
            shipped("search-running", "搜索 · 正在搜") { $0.runSearch("合同") },
            shipped("search-failed", "搜索 · 连不上螺壳") { m in
                m.lastSeen = fixedNow.addingTimeInterval(-2 * 60)
                m.coreReachable = false
                m.searchQuery = "发票"
                m.searchAnswer = SearchAnswer(note: "螺壳暂时没响应，搜不了「发票」。", retry: true)
            },
            shipped("search-nothing", "搜索 · 记忆没找到、邮件助手没回应") { $0.searchAnswer = SearchAnswer(failed: ["螺壳邮件助手"], asked: 2) },
            shipped("search-all-failed", "搜索 · 能搜的两个应用都没回应") { $0.searchAnswer = SearchAnswer(failed: ["螺壳邮件助手", "记忆"], asked: 2) },
            // 按类型分组（工具协议 §1b 的 hits，窗口自己画）：示例是编的，缩略图在 SearchSample 里画
            shipped("search-hits", "搜索 · 按类型分组") { searchHits($0) },
            shipped("search-hits-selected", "搜索 · 选中一条，右边出预览") { m in
                searchHits(m)
                m.moveSearchSelection(1)
            },
            shipped("search-hits-mail-selected", "搜索 · 只看邮件、选中一封") { m in
                searchHits(m)
                m.filterSearch("mail")
                m.searchSelected = SearchSample.hits.first { $0.kind == "mail" }?.id
            },
            shipped("search-hits-pdf", "搜索 · 只看 PDF") { m in
                searchHits(m)
                m.filterSearch("pdf")
            },
            shipped("search-hits-and-card", "搜索 · 一个工具只给卡片、一个没回应") { m in
                searchHits(m)
                let card = SearchSample.card()
                m.searchAnswer?.hits = SearchSample.hits.filter { $0.app == SearchSample.search }
                m.searchAnswer?.cards = card.map { [$0] } ?? []
                m.searchAnswer?.failed = ["记忆"]
                m.searchAnswer?.asked = 3
            },
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
            stress("focus-small-window", "一件件处理 · 小窗口 860×600 · 8 封的方案卡片（手写的示意；中间滚动，按钮在底部）",
                   size: CGSize(width: 860, height: 600)) { m in
                m.cards.insert(Sample.longPlanCard(8), at: 0)
                m.enterFocus()
            },
            whole("focus-long", "一件件处理 · 8 封的方案卡片（手写的示意）", height: 1400) { m in
                m.cards.insert(Sample.longPlanCard(8), at: 0)
                m.enterFocus()
            },
            kinds("today-kinds", "今天 · 要你决定有两类，各不止一件（段标题下面「按类处理」；同一类的排在一起）"),
            kinds("focus-kind", "一件件处理 · 只走一类（在「按类处理」里点了「记忆想问的事」）") { m in
                m.enterFocus(category: m.categoriesToPick.last?.id)
            },
            kinds("focus-kind-end", "一件件处理 · 只走一类，这一类都答完了，还有别的事") { m in
                let ids = m.categoriesToPick.last?.ids ?? []
                m.enterFocus(category: m.categoriesToPick.last?.id)
                m.focus?.tapped = Set(ids)   // 都点过了，记忆答完收走
                m.cards.removeAll { ids.contains($0.id) }
            },
            stress("focus-progress-many", "一件件处理 · 邮件的卡片多 15 倍（进度是一整条加数字）", scale: many * 3) { $0.enterFocus() },
            stress("today-empty", "今天 · 第一天，什么都没有", mail: "no-mailbox") { m in
                m.urgent = []; m.cards = []; m.done = []; m.quiet = []; m.notices = []
            },
            stress("today-waiting", "今天 · 模型在准备、核心的数据还没到") { m in
                m.urgent = []; m.cards = []; m.done = []; m.quiet = []; m.notices = []
                m.engineReady = false
                m.waitingForFeed = true
            },
            stress("today-urgent-groups", "今天 · 急事 4 组以上（报毒、可疑邮件、会议、磁盘、登录）") { moreUrgent($0) },
            renamed(shipped("today", "今天", scan: "malware"), "stress-today-long-name", "压力 · 今天 · 超长文件名"),
            renamed(shipped("scan", "螺壳扫描", scan: "malware") { $0.go(.scan) }, "stress-scan-long-name", "压力 · 螺壳扫描 · 超长文件名"),
            stress("scan-unreachable", "螺壳扫描 · 页面一次也没拿到，连不上螺壳超过 30 秒", pages: false) { m in
                offline(m, since: 17 * 60)
                m.go(.scan)
            },
            stress("scan-small-window", "螺壳扫描 · 小窗口 860×600", size: CGSize(width: 860, height: 600)) { $0.go(.scan) },
            shipped("scan-agent-autoclean-on", "螺壳扫描 · 自动清理开着（概览页）", scan: "autoclean-done") { $0.go(.scan) },
            stress("today-offline", "今天 · 连不上螺壳（刚断开）") { offline($0, since: 5) },
            stress("today-offline-long", "今天 · 连不上螺壳超过 30 秒") { offline($0, since: 17 * 60) },
            stress("today-app-stopped", "今天 · 邮件助手没在运行（核心的提示）") { m in
                m.urgent.removeAll { $0.tool == .mail }; m.cards.removeAll { $0.tool == .mail }
                m.done.removeAll { $0.tool == .mail }; m.quiet.removeAll { $0.tool == .mail }
                m.notices = ["螺壳邮件助手现在没在运行，它的事恢复后会自动列回来，不用你做什么。"]   // agent.py `_merge` 的说法
                if let i = m.agentApps?.firstIndex(where: { $0.id == "luoke-mail" }) { m.agentApps?[i].running = false }
            },
            end(stress("today-app-stopped", "今天 · 邮件助手没在运行（核心的提示）") { m in
                m.urgent.removeAll { $0.tool == .mail }; m.cards.removeAll { $0.tool == .mail }
                m.done.removeAll { $0.tool == .mail }; m.quiet.removeAll { $0.tool == .mail }
                m.notices = ["螺壳邮件助手现在没在运行，它的事恢复后会自动列回来，不用你做什么。"]
                if let i = m.agentApps?.firstIndex(where: { $0.id == "luoke-mail" }) { m.agentApps?[i].running = false }
            }),
            end(shipped("scan-agent-autoclean-on", "螺壳扫描 · 自动清理开着（概览页）", scan: "autoclean-done") { $0.go(.scan) }),
            stress("today-mini-offline", "侧栏收成图标 · 连不上螺壳") { m in
                m.setSidebar(mini: true)
                offline(m, since: 5)
            },
            stress("today-mini-waiting", "侧栏收成图标 · 螺壳在准备（核心的数据还没到）") { m in
                m.urgent = []; m.cards = []; m.done = []; m.quiet = []; m.notices = []
                m.setSidebar(mini: true)
                m.engineReady = false
                m.waitingForFeed = true
            },
            stress("today-no-decide", "今天 · 有急事、没有要你决定的（应用都在运行）") { m in
                m.cards = []
            },
            end(stress("today-many", "今天 · 邮件的卡片多 5 倍（急事 40 多张）", scale: many)),
            shipped("stress-today-done-more", "压力 · 今天 · 「已经替你做了」6 行，露 3 行（另 5 行是手写的示意）", scan: "malware") { m in
                answered(m, scan: "malware", "call-scan_ignore.json")
                m.done += moreDone
            },
            stress("today-mini-app-stopped", "侧栏收成图标 · 邮件助手没在运行") { m in
                m.setSidebar(mini: true)
                m.urgent.removeAll { $0.tool == .mail }; m.cards.removeAll { $0.tool == .mail }
                m.done.removeAll { $0.tool == .mail }; m.quiet.removeAll { $0.tool == .mail }
                m.notices = ["螺壳邮件助手现在没在运行，它的事恢复后会自动列回来，不用你做什么。"]
                if let i = m.agentApps?.firstIndex(where: { $0.id == "luoke-mail" }) { m.agentApps?[i].running = false }
            },
            stress("small-window-done-many-whole", "860 宽 · 「已经替你做了」4 行 · 整页（看窄的时候一行挤不挤）", size: CGSize(width: 860, height: 1500)) { m in
                m.done += Array(moreDone.prefix(4))
            },
            stress("small-window-done-many", "小窗口 860×600 · 「已经替你做了」4 行", size: CGSize(width: 860, height: 600)) { m in
                answered(m, scan: ToolSample.fullScan, "call-scan_ignore.json")
                m.done += [
                    DoneRow(id: "x-d1", tool: .mail, text: "把 3 封订阅邮件归档了", time: "09:30", undoLabel: "撤销"),
                    DoneRow(id: "x-d2", tool: .scan, text: "清了 1.2 GB 的工具缓存", time: "08:00"),
                    DoneRow(id: "x-d3", tool: .mail, text: "给王老师的回信草稿写好了", time: "07:45", undoLabel: "撤销"),
                    DoneRow(id: "x-d4", tool: .mail, text: "把 2 封账单放进了「账单」", time: "07:30"),
                ]
            },
            shipped("stress-today-done-many", "压力 · 今天 · 「已经替你做了」4 行（点完「不是病毒」，另 3 行是手写的示意）", scan: "malware") { m in
                answered(m, scan: "malware", "call-scan_ignore.json")
                m.done += [
                    DoneRow(id: "x-d1", tool: .mail, text: "把 3 封订阅邮件归档了", time: "09:30", undoLabel: "撤销"),
                    DoneRow(id: "x-d2", tool: .scan, text: "清了 1.2 GB 的工具缓存", time: "08:00"),
                    DoneRow(id: "x-d3", tool: .mail, text: "给王老师的回信草稿写好了", time: "07:45", undoLabel: "撤销"),
                ]
            },
            stress("small-window", "小窗口 860×600（螺壳.app 允许的最小）", size: CGSize(width: 860, height: 600)),
            end(stress("small-window", "小窗口 860×600（螺壳.app 允许的最小）", size: CGSize(width: 860, height: 600))),
            stress("large-window", "大窗口 1440×900", size: CGSize(width: 1440, height: 900)),
            // 「今天」新模板：scripts/today_template.py 用 cards.py 照对照稿拼的卡片，看窗口照不照得出对照稿
            shipped("today-template", "今天 · 新模板（对照稿右边那页，cards.py 拼的）") { TemplateSample.apply($0) },
            whole("today-template", "今天 · 新模板", height: 5600) { TemplateSample.apply($0) },
            // 宽窗口（docs/主窗口.md「宽窗口」）：1440 起内容区够宽，有侧栏的页分两栏；2560 是外接显示器铺满，一组还是那么宽、居中
            stress("wide-scan", "宽窗口 1728×1080 · 螺壳扫描（「这个应用」在侧栏）", size: CGSize(width: 1728, height: 1080)) { $0.go(.scan) },
            stress("wide-today-mini", "宽窗口 1440×900 · 侧栏收起", size: CGSize(width: 1440, height: 900)) { $0.toggleSidebar() },
            stress("wide-today-2560", "宽窗口 2560×1440 · 今天", size: CGSize(width: 2560, height: 1440)),
            stress("wide-scan-2560", "宽窗口 2560×1440 · 螺壳扫描", size: CGSize(width: 2560, height: 1440)) { $0.go(.scan) },
            stress("wide-compact-2560", "宽窗口 2560×1440 · 今天 · 紧凑（表最宽 1080）", size: CGSize(width: 2560, height: 1440)) { $0.setDensity(.compact) },
            // 宽窗口的应用页：侧栏里「这个应用 → 权限」写出等的是哪一项（只有灯时看不出是什么）
            shipped("stress-wide-scan-no-fda", "压力 · 宽窗口 1440×900 · 螺壳扫描 · 没允许完全磁盘访问（侧栏「这个应用 → 权限」）",
                    scan: "first-run-no-fda", size: CGSize(width: 1440, height: 900)) { $0.go(.scan) },
            // #51：急事 205 件的回放（标准的「今天」）、要你决定 40 件的简报。侧栏「今天」只数要你决定的、急事另一个红点；
            // 简报列前 3 件加「等」（点了跳到「要你决定」），最多两行；菜单栏里点一行急事，展开那一叠、收在「还有」后面的先全展开
            shipped("stress-brief-many", "压力 · 简报 · 要你决定 40 件（列前 3 件加「等」，最多两行）",
                    scan: "decide-3", decide: 40) { $0.openBrief(time: "08:00") },
            stress("urgent-205-brief", "急事 205 件 + 要你决定 40 件 · 简报（侧栏「今天」只数要你决定，急事是红点）",
                   flood: StressSample.urgentReplay - 5, decide: 40) { m in
                moreUrgent(m)
                m.openBrief(time: "08:00")
            },
            stress("urgent-205-mini", "急事 205 件 · 侧栏收成图标（红点在图标左上角）", flood: StressSample.urgentReplay - 5) { m in
                moreUrgent(m)
                m.setSidebar(mini: true)
            },
            stress("urgent-205-menu-hidden-whole", "急事 205 件 · 菜单栏里点了「有人在新设备上登录了你的邮箱」（收在「还有 3 件急事」后面：急事先全展开）· 整页",
                   flood: StressSample.urgentReplay - 5, size: CGSize(width: windowSize.width, height: 1500)) { m in
                moreUrgent(m)
                if let row = m.statusMenu.items.first(where: { $0.id == "urgent-x-login" }) { m.perform(row.action) }
            },
            stress("urgent-205-menu-stack-whole", "急事 205 件 · 菜单栏里点了「200 封可疑邮件」（那一叠展开）· 整页",
                   flood: StressSample.urgentReplay - 5, size: CGSize(width: windowSize.width, height: 1500)) { m in
                moreUrgent(m)
                if let row = m.statusMenu.items.first(where: { $0.title == "200 封可疑邮件" }) { m.perform(row.action) }
            },
            // 紧凑的「今天」：急事 205 件的回放（#54）。同一类叠成一行、最多 3 行，其余在「还有 N 件急事」；
            // 点开一叠一行一件，靠副标题（§4 subtitle）分清；有选项的卡片只给「选一下」，点了展开成标准卡片
            flood("compact-urgent-205", "紧凑 · 急事 205 件（同一类叠成一行，最多 3 行）"),
            flood("compact-urgent-205-open", "紧凑 · 急事 205 件 · 点开 200 封可疑邮件那一叠") { m in
                if let u = m.urgent.first(where: { $0.tool == .mail && $0.surface != nil }) {
                    m.urgentOpenStacks.insert(TodayStack.key(u.tool, u.kind, u.title))
                }
            },
            flood("compact-urgent-205-all", "紧凑 · 急事 205 件 · 点了「还有 N 件急事」") { $0.urgentAll = true },
            stress("compact-choose", "紧凑 · 有选项的卡片点了「选一下」（展开成标准卡片）") { m in
                m.setDensity(.compact)
                if let c = m.cards.first(where: { SurfaceDigest($0.surface.surface).hasInputs }) { m.compactExpanded.insert(c.id) }
            },
            // 真窗口那条路（#65）：选择框、设置的下拉框和截图用的是同一个框
            live(stress("compact-choose", "紧凑 · 「选一下」展开的卡片") { m in
                m.setDensity(.compact)
                if let c = m.cards.first(where: { SurfaceDigest($0.surface.surface).hasInputs }) { m.compactExpanded.insert(c.id) }
            }),
            live(shipped("today-template", "今天 · 新模板") { TemplateSample.apply($0) }),
            live(shipped("prefs-alerts", "设置 · 提醒") { $0.go(.prefs, tab: "alerts") }),
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
            full("search-empty", "搜索 · 没有结果") { m in m.searchSections = []; m.go(.search) },
            full("search-ask", "搜索 · 问螺壳") { $0.go(.search); $0.openAsk() },
            full("prefs-display", "设置 · 显示") { $0.go(.prefs, tab: "display") },
            full("prefs-model", "设置 · 模型") { $0.go(.prefs, tab: "model") },
            full("prefs-privacy", "设置 · 隐私") { $0.go(.prefs, tab: "privacy") },
            scene("full-menu-go", "完整版（beta 2 没有）· 顶部菜单 · 前往", size: menuSize, open: "go"),
        ]
    }

    /// 画成 PNG。scale 2 和 Retina 屏一样清楚。
    /// 搜「发票」的示例结果，缩略图已经读到
    static func searchHits(_ m: WindowModel) {
        m.searchQuery = "发票"
        m.searchAnswer = SearchSample.answer()
        m.searchThumbs = SearchSample.thumbs()
    }

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

/// 截图里本体的界面（示意：真的由螺壳.app 经 `HostPage` 给）
@MainActor
enum HostSample {
    static var update: some View {
        HostSampleBody(lines: ["螺壳 0.4.2 可以升级了。升级时螺壳会先退出，换好新版后自己重新打开，大约一分钟。",
                               "你的数据和下载过的模型都不动。"], button: "升级")
    }
    static var permission: some View {
        HostSampleBody(lines: ["螺壳扫描要「完全磁盘访问」才看得到下载、桌面、文稿里的东西。",
                               "这项授权给的是螺壳；扫描只在这台 Mac 上看，不传出去。"], button: "去系统设置打开")
    }
    static var tall: some View {
        HostSampleBody(lines: (1...30).map { "第 \($0) 行：螺壳扫描要「完全磁盘访问」才看得到下载、桌面、文稿里的东西。" }, button: "去系统设置打开")
    }
    static var welcome: some View {
        VStack(spacing: LKSpace.x4) {
            BrandBadge(size: 64)
            Text("欢迎使用螺壳").font(LKFont.ui(LKType.title, .semibold))
            HostSampleBody(lines: ["先选要装的应用，再准备模型。都在这台 Mac 上运行。"], button: "开始", center: true)
        }
        .frame(maxWidth: 520)
    }
}

struct HostSampleBody: View {
    let lines: [String]
    let button: String
    var center = false
    @Environment(\.lk) private var p

    var body: some View {
        VStack(alignment: center ? .center : .leading, spacing: LKSpace.x3) {
            ForEach(lines, id: \.self) { Text($0).font(LKFont.ui(LKType.small)).foregroundStyle(p.mutedFg) }
            HStack {
                if !center { Spacer() }
                Button(button) {}.buttonStyle(LKButtonStyle(kind: .primary))
            }
            .padding(.top, LKSpace.x2)
        }
    }
}
