import AppKit
import LuokeA2UI
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
                 openURL: Bool = false, pages: Bool = true, mem: String? = nil, search: String? = nil,
                 ime: String? = nil) {
            for (app, sc) in [("luoke-scan", scan), ("luoke-mail", mail)] where ToolSample.load(app, sc) == nil {
                missingSamples.insert("\(app)/\(sc)")
            }
            let feed = AgentFeed(model: m)
            if m.machineLoad == nil { m.machineLoad = MachineLoad(ram: 0.62, gpu: 0.18) }
            var events = Sample.agentEvents(scan: scan, mail: mail, openURL: openURL, memory: !beta2,
                                            extras: ToolSample.local.scenario == nil)
            if scale > 1 { events = StressSample.scaled(events, app: "luoke-mail", times: scale) }
            if flood > 0 { events = StressSample.urgentFlood(events, app: "luoke-mail", times: flood, subtitle: StressSample.mailSubtitle) }
            if decide > 0 { events = StressSample.decideFlood(events, app: "luoke-mail", times: decide) }
            for (e, d) in events { feed.handle(e, d) }
            if pages {
                Sample.applyAgentApps(feed, scan: scan, mail: mail, mem: mem, search: search, ime: ime)
            } else {   // 应用清单拿到了，页面一次也没拿到（没连上核心）
                if let v = try? JSONValue.parse(Sample.agentApps(scan: scan, mail: mail)) { feed.applyApps(v) }
                for a in m.agentApps ?? [] {
                    for p in a.pages { feed.applyPage(app: a.id, page: p.id, status: 0, body: Data()) }
                }
            }
            guard beta2 else { return }
            m.features = .beta2
            // 螺壳.app 报装了哪些应用（beta 2 随包带邮件助手和螺壳扫描），侧栏「应用」照它列
            m.setInstalledApps(([("luoke-mail", mail), ("luoke-scan", scan)] + (mem.map { [("luoke-mem", $0)] } ?? [])
                                + (search.map { [("luoke-search", $0)] } ?? [])
                                + (ime.map { [("luoke-ime", $0)] } ?? [])).map { app, sc in
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
        /// 搜索的结果层：搜索框只在螺壳搜索的页上（还没有问螺壳时），先到那一页
        func searched(_ name: String, _ title: String, _ then: @escaping (WindowModel) -> Void) -> Screen {
            window(name, title) { m in
                fed(m, scan: ToolSample.fullScan, mail: ToolSample.defaultMail, beta2: true,
                    search: ToolSample.load("luoke-search", "built") == nil ? nil : "built")
                if !m.appsExpanded { m.toggleApps() }
                m.go(.searchApp)
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
        // 设置类的页上「标题 + 一排 n 选 1」：选项组放在这一条右边，和开关一样（#165；输入法「各应用」那页是这个写法，
        // 这里手写一页只看画法，借扫描的位置放）
        let pickRows = shipped("render-pick-rows", "画法 · 设置页的选项组在右边") { m in
            m.go(.scan)
            let key = AgentFeed.pageKey("luoke-scan", "overview")
            guard let v = try? JSONValue.parse(Data(#"""
            [{"version": "v0.9", "createSurface": {"surfaceId": "s", "catalogId": "ai.luoke/a2ui/agent/1"}}, {"version": "v0.9", "updateComponents": {"surfaceId": "s", "components": [{"id": "root", "component": "Column", "children": ["a", "b", "c"]}, {"id": "a", "component": "Column", "children": ["at", "a1", "a2"]}, {"id": "at", "component": "Text", "text": "输入方式", "variant": "h4"}, {"id": "a1", "component": "Text", "text": "输入方案"}, {"id": "a2", "component": "Row", "children": ["a2a", "a2b", "a2c"]}, {"id": "a2a", "component": "Button", "child": "a2a-t", "action": {"event": {"name": "ime_set", "context": {"key": "k", "value": "a2a"}}}, "variant": "primary"}, {"id": "a2a-t", "component": "Text", "text": "全拼"}, {"id": "a2b", "component": "Button", "child": "a2b-t", "action": {"event": {"name": "ime_set", "context": {"key": "k", "value": "a2b"}}}}, {"id": "a2b-t", "component": "Text", "text": "小鹤双拼"}, {"id": "a2c", "component": "Button", "child": "a2c-t", "action": {"event": {"name": "ime_set", "context": {"key": "k", "value": "a2c"}}}}, {"id": "a2c-t", "component": "Text", "text": "自然码双拼"}, {"id": "b", "component": "Column", "children": ["bd", "bt", "b1", "b2", "b3"]}, {"id": "bd", "component": "Divider"}, {"id": "bt", "component": "Text", "text": "语音", "variant": "h4"}, {"id": "b1", "component": "Text", "text": "语音输入按键"}, {"id": "b2", "component": "Row", "children": ["b2a", "b2b", "b2c"]}, {"id": "b2a", "component": "Button", "child": "b2a-t", "action": {"event": {"name": "ime_set", "context": {"key": "v", "value": "b2a"}}}, "variant": "primary"}, {"id": "b2a-t", "component": "Text", "text": "右 ⌥(Alt)"}, {"id": "b2b", "component": "Button", "child": "b2b-t", "action": {"event": {"name": "ime_set", "context": {"key": "v", "value": "b2b"}}}}, {"id": "b2b-t", "component": "Text", "text": "右 ⌘"}, {"id": "b2c", "component": "Button", "child": "b2c-t", "action": {"event": {"name": "ime_set", "context": {"key": "v", "value": "b2c"}}}}, {"id": "b2c-t", "component": "Text", "text": "右 ⌃"}, {"id": "b3", "component": "Text", "text": "使用外接 Windows 键盘或在系统设置中对调过修饰键时，右 Alt 可能被识别为右 ⌘，此时请选择右 ⌘", "variant": "caption"}, {"id": "c", "component": "Column", "children": ["cd", "ct", "c1", "c2", "c3", "c4"]}, {"id": "cd", "component": "Divider"}, {"id": "ct", "component": "Text", "text": "应用单独设置", "variant": "h4"}, {"id": "c1", "component": "Text", "text": "默认输入模式"}, {"id": "c2", "component": "Row", "children": ["c2a", "c2b", "c2c"]}, {"id": "c2a", "component": "Button", "child": "c2a-t", "action": {"event": {"name": "ime_set", "context": {"key": "m", "value": "c2a"}}}, "variant": "primary"}, {"id": "c2a-t", "component": "Text", "text": "跟随全局（中文）"}, {"id": "c2b", "component": "Button", "child": "c2b-t", "action": {"event": {"name": "ime_set", "context": {"key": "m", "value": "c2b"}}}}, {"id": "c2b-t", "component": "Text", "text": "中文"}, {"id": "c2c", "component": "Button", "child": "c2c-t", "action": {"event": {"name": "ime_set", "context": {"key": "m", "value": "c2c"}}}}, {"id": "c2c-t", "component": "Text", "text": "英文"}, {"id": "c3", "component": "Text", "text": "拼音显示位置"}, {"id": "c4", "component": "Row", "children": ["c4a", "c4b", "c4c"]}, {"id": "c4a", "component": "Button", "child": "c4a-t", "action": {"event": {"name": "ime_set", "context": {"key": "p", "value": "c4a"}}}, "variant": "primary"}, {"id": "c4a-t", "component": "Text", "text": "跟随全局（候选窗口）"}, {"id": "c4b", "component": "Button", "child": "c4b-t", "action": {"event": {"name": "ime_set", "context": {"key": "p", "value": "c4b"}}}}, {"id": "c4b-t", "component": "Text", "text": "输入框"}, {"id": "c4c", "component": "Button", "child": "c4c-t", "action": {"event": {"name": "ime_set", "context": {"key": "p", "value": "c4c"}}}}, {"id": "c4c-t", "component": "Text", "text": "候选窗口"}]}}]
            """#.utf8)), let msgs = v.array, let s = try? Surface.build(msgs, page: true) else { return }
            m.agentPages[key]?.surface = SurfaceModel(surface: s)
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
        /// 核心照邮件助手的原始数据拼的页（ADR 0028）：fixtures/apppages 手写的数据，等邮件助手录了 data/… 换掉
        let mailBuilt: [Screen] = ToolSample.load("luoke-mail", "pages") == nil ? [] :
            [("inbox", "收件箱"), ("digest", "精选"), ("clean", "清理")].map { id, title in
                shipped("mail-built-\(id)", "邮件助手 · \(title)（核心照原始数据拼）", mail: "pages") { m in
                    m.go(.mail)
                    m.selectAppTab(id)
                }
            } + [("settings", "设置"), ("activity", "处理记录"), ("mail", "一封信"), ("piece", "一条精选"),
                 // 负责人 11-16：弹窗也要对图，都加进来
                 ("subs", "订阅体检"), ("old", "旧邮件"), ("sender", "发件人"), ("sources", "精选来源"), ("job", "后台任务"),
                 ("done", "已处理的邮件")].map { id, title in
                shipped("mail-built-\(id)", "邮件助手 · \(title)（弹窗，核心照原始数据拼）", mail: "pages") { m in
                    m.go(.mail)
                    m.selectAppTab(id)
                }
            }
        /// 核心照扫描的原始数据拼的页（ADR 0028）
        let scanBuilt: [Screen] = ToolSample.load("luoke-scan", "built") == nil ? [] :
            [("overview", "概览"), ("status", "状态"), ("category", "一类的详情（弹窗）"), ("folder", "文件夹里什么最占地方（弹窗）"), ("cleaned", "清理记录（弹窗）"), ("settings", "设置（弹窗）")].map { id, title in
                shipped("scan-built-\(id)", "扫描 · \(title)（核心照原始数据拼）", scan: "built") { m in
                    m.go(.scan)
                    m.selectAppTab(id)
                }
            }
        let scanStatusWhole: [Screen] = ToolSample.load("luoke-scan", "built") == nil ? [] : [
            shipped("scan-built-status-whole", "扫描 · 状态（核心照原始数据拼） · 整页", scan: "built",
                    size: CGSize(width: windowSize.width, height: 1500)) { m in
                m.go(.scan)
                m.selectAppTab("status")
            }]
        /// 窄的时候的弹窗：最小的窗口、右边栏拉出来，内容区不到 460（负责人 11-13 试开发版看到弹窗左边被切掉）
        let dialogNarrow: [Screen] = ToolSample.load("luoke-mail", "pages") == nil ? [] : [
            shipped("stress-dialog-narrow", "小窗口 860×600 · 右边栏拉出 · 弹窗（邮件助手设置）", mail: "pages",
                    size: CGSize(width: 860, height: 600)) { m in
                m.go(.mail)
                m.selectAppTab("settings")
                m.panelOpen = true
            },
        ]
        /// 核心照搜索的原始数据拼的应用页（ADR 0028）
        let searchBuilt: [Screen] = ToolSample.load("luoke-search", "built") == nil ? [] : [
            window("search-built-overview", "搜索 · 应用页（核心照原始数据拼）") { m in
                fed(m, scan: ToolSample.fullScan, mail: ToolSample.defaultMail, beta2: true, search: "built")
                if !m.appsExpanded { m.toggleApps() }
                m.go(.searchApp)
            },
        ]
        /// 输入法的设置页和「各应用」，核心照它录的 data/settings、data/apps 拼（ADR 0028；设置页归主窗口，负责人 11-19）：平常的、空的，各带一张整页
        let imeBuilt: [Screen] = ToolSample.scenarios("luoke-ime").flatMap { sc -> [Screen] in
            guard let s = ToolSample.load("luoke-ime", sc) else { return [] }
            return [("settings", "设置", "", "", windowSize),
                    ("settings", "设置", "-whole", " · 整页", CGSize(width: windowSize.width, height: 2200)),
                    ("apps", "各应用", "", "", windowSize)].map { page, tab, suffix, note, size in
                window("ime-\(page)-\(sc)\(suffix)", "输入法 · \(tab)：\(s.title)\(note)", size: size) { m in
                    fed(m, scan: ToolSample.fullScan, mail: ToolSample.defaultMail, beta2: true, ime: sc)
                    if !m.appsExpanded { m.toggleApps() }
                    m.go(.ime)
                    m.selectAppTab(page)
                }
            }
        }
        /// 从输入法菜单的「此应用的设置」带着应用进来、它还没单独设置过：排在最前，写明尚未单独设置
        let imeTarget: [Screen] = (ToolSample.load("luoke-ime", "normal")?.views["apps-target"]).map { view in
            [window("ime-apps-target", "输入法 · 各应用：从菜单点进来的应用还没单独设置过") { m in
                fed(m, scan: ToolSample.fullScan, mail: ToolSample.defaultMail, beta2: true, ime: "normal")
                if !m.appsExpanded { m.toggleApps() }
                m.go(.ime)
                m.selectAppTab(view.page)
                if let s = try? Surface.build(view.messages, page: true) {
                    m.agentPages[AgentFeed.pageKey("luoke-ime", view.page)]?.surface = SurfaceModel(surface: s)
                }
            }]
        } ?? []
        /// 核心照记忆的原始数据拼的页（ADR 0028）
        let memBuilt: [Screen] = ToolSample.load("luoke-mem", "built") == nil ? [] :
            [("overview", "概览"), ("all", "全部记忆"), ("people", "人物"), ("settings", "设置（弹窗）"), ("item", "一条记忆（弹窗）"),
             ("person", "一个人（弹窗）")].map { id, title in
                window("mem-built-\(id)", "记忆 · \(title)（核心照原始数据拼）") { m in
                    fed(m, scan: ToolSample.fullScan, mail: ToolSample.defaultMail, beta2: true, mem: "built")
                    if !m.appsExpanded { m.toggleApps() }
                    m.go(.mem)
                    m.selectAppTab(id)
                }
            }
        /// 记忆的页（记忆录的 window 场景，设计规范 §18.3）：概览、全部记忆、人物，设置是齿轮打开的隐藏页
        let memPages: [Screen] = {
            guard let s = ToolSample.load("luoke-mem", "window") else { return [] }
            let titles = Dictionary((s.apps.first?["pages"]?.array ?? []).compactMap { p -> (String, String)? in
                guard let id = p["id"]?.string else { return nil }
                return (id, p["title"]?.string ?? id)
            }, uniquingKeysWith: { a, _ in a })
            return s.pageIDs.map { id in
                window("mem-\(id)", "记忆 · \(titles[id] ?? id)") { m in
                    fed(m, scan: ToolSample.fullScan, mail: ToolSample.defaultMail, beta2: true, mem: "window")
                    if !m.appsExpanded { m.toggleApps() }
                    m.go(.mem)
                    m.selectAppTab(id)
                }
            } + (ToolSample.load("luoke-mem", "people") == nil ? [] : [
                // 记忆的 people 场景：「两个称呼是不是同一个人」的提问（luoke-mem 0.39）在概览的「想跟你确认」里
                window("mem-people-overview", "记忆 · 人物场景 · 概览的「想跟你确认」") { m in
                    fed(m, scan: ToolSample.fullScan, mail: ToolSample.defaultMail, beta2: true, mem: "people")
                    if !m.appsExpanded { m.toggleApps() }
                    m.go(.mem)
                    m.selectAppTab("overview")
                },
            ])
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
            DoneRow(id: "x-d5", tool: .scan, text: "把下载里重复的 4 个安装包移到了废纸篓", time: "07:00", undoLabel: "恢复"),
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
                    m.kinds.append(KindSetting(id: "luoke-mem:question", tool: .mem, title: "记忆的待确认事项", level: .brief))
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
            shipped("mail-mini", "侧栏收成图标 · 应用页（内容区是工作台那组颜色）") { m in
                m.setSidebar(mini: true)
                m.go(.mail)
            },
            shipped("today-no-fda", "今天 · 第一次扫描，还没给完全磁盘访问", scan: "first-run-no-fda"),
            shipped("today-malware", "今天 · 下载里有报毒的文件", scan: "malware"),
            shipped("today-malware-ignored", "今天 · 在「update.scpt」上点了「不是病毒」（工具答复的那一行，带撤销）", scan: "malware") {
                answered($0, scan: "malware", "call-scan_ignore.json")
            },
        ] + mailScenes + [
            shipped("today-brief", "今天 · 点开简报") {
                $0.briefWords = "有 3 件急事先看：一封冒充银行的邮件，两个下载的文件疑似病毒。另外替你把 2 封邮件标成了已读，还有 1 封等你处理"
                $0.openBrief(time: "08:00")
            },
            shipped("today-brief-template", "今天 · 点开简报（模型没写，照模板拼）") { $0.openBrief(time: "08:00") },
            shipped("host-notice", "今天 · 旧的「螺壳 agent」还在运行") { m in
                m.hostNotice = "旧的「螺壳 agent」还在运行：退出它以后，这里接上。"
            },
            whole("today-update", "今天 · 螺壳.app 报邮件助手有新版本（「顺便看看」里一行）", height: 1100) { m in
                m.setInstalledApps((m.installedApps ?? []).map {
                    $0.accessory == "luoke-mail" ? InstalledApp(accessory: $0.accessory, version: $0.version, update: "0.19.0") : $0
                })
            },
            shipped("focus", "逐件处理") { $0.enterFocus() },
            whole("focus", "逐件处理", height: 1600) { $0.enterFocus() },
            shipped("focus-end", "逐件处理 · 都答完了") { m in
                m.enterFocus()
                m.focus?.tapped = Set(m.cards.map(\.id))   // 都点过了，工具答完收走
                m.cards = []
            },
            shipped("focus-left", "逐件处理 · 跳过了几件") { m in
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
        ] + mailPages + mailBuilt + memBuilt + scanBuilt + scanStatusWhole + searchBuilt + imeBuilt + imeTarget + dialogNarrow + memPages + scanScenes + macScenes + macExtra + [scanBusy, pickRows] + scanScenes.filter { (x: Screen) -> Bool in x.name == "scan-agent-decide-3" }.map { (x: Screen) -> Screen in end(x) }
          + scanScenes.filter { (x: Screen) -> Bool in x.name == "scan-agent-decide-3" }.map { (x: Screen) -> Screen in live(x) } + [
            shipped("apps", "应用管理") { $0.go(.apps) },
            shipped("apps-open", "应用管理 · 展开两个应用（权限、去权限设置和应用设置的入口）") { m in
                m.go(.apps)
                m.openedApps = Set(m.appRows.filter { $0.tool == .scan || $0.tool == .search }.map(\.id))
            },
            shipped("apps-host", "应用管理 · 本体给的数据（停用、装不了、在下载、更多、做完一个动作的结果）") { m in
                m.host = SnapshotDataHost.shared      // WindowModel 只弱引用本体
                m.go(.apps)
            },
            // 吉祥物的那一句（逗一下）：句子是界面规范 §15 的例子，真的由核心用模型从记忆里写
            shipped("today-hello", "今天 · 吉祥物逗一下（示意的句子）") { m in
                m.urgent = []
                m.helloLine = "上午归档了 14 封促销邮件，没有一封是人写的"
            },
            shipped("prefs-general", "设置 · 通用") { $0.go(.prefs, tab: "general") },
            shipped("prefs-offline", "设置 · 通用 · 连不上螺壳（页顶说明，提醒那一组变灰）") { m in
                m.go(.prefs, tab: "general")
                m.coreReachable = false
            },
            whole("prefs-general-more", "设置 · 通用 · 有新版本、登录项要允许、逐类设置提醒（弹窗）", height: 1700) { m in
                m.sampleSettings?.general.latestVersion = "0.9.4"
                m.sampleSettings?.general.loginItem = .requiresApproval
                m.go(.prefs, tab: "general")
                m.settingsDialog = .alerts
            },
            shipped("prefs-models", "设置 · 模型") { $0.go(.prefs, tab: "model") },
            whole("prefs-models-more", "设置 · 模型 · 下载中、下载出错、已下载能切换、按流量计费、高级（弹窗）", height: 1300) { m in
                m.sampleSettings?.models.tiers[1].state = .switching(progress: 0.42)
                m.sampleSettings?.models.tiers.append(HostTier(id: "max", title: "旗舰版", model: "Gemma 4 26B · 8-bit", sizeGB: 27.8,
                                                               state: .failed(reason: "磁盘空间不够，还差 6 GB")))
                m.sampleSettings?.models.tiers.append(HostTier(id: "lite", title: "轻量版", model: "Gemma 4 E4B · 4-bit", sizeGB: 3.1,
                                                               state: .available(needGB: 0), kind: .lighter))
                m.sampleSettings?.models.metered = true
                m.sampleSettings?.models.advanced.enabled = true
                m.go(.prefs, tab: "model")
                m.settingsDialog = .advanced
            },
            shipped("prefs-privacy", "设置 · 隐私与权限") { $0.go(.prefs, tab: "privacy") },
            whole("prefs-privacy", "设置 · 隐私与权限 · 整页", height: 1400) { m in
                m.go(.prefs, tab: "privacy")
            },
            stress("prefs-privacy-empty", "设置 · 隐私与权限 · 没有权限的行（没有行的一节不画标题）") { m in
                m.agentPermissions = nil
                m.permissions = []; m.accounts = []; m.delegates = []; m.eachTime = []
                m.go(.prefs, tab: "privacy")
            },
            shipped("prefs-permissions-off", "设置 · 隐私与权限 · 关了「允许」") { m in
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
            shipped("today-pill-busy", "右上角 · 有任务在做") { m in m.tasks = Snapshot.sampleTasks },
            shipped("today-pill", "右上角的胶囊 · 完成几件、生成多少 token，在做一件、排着三件") { m in
                m.outputStats = Snapshot.sampleStats
                m.tasks = Snapshot.sampleTasks
            },
            shipped("panel-tasks", "右边栏 · 任务") { m in
                m.tasks = Snapshot.sampleTasks
                m.outputStats = Snapshot.sampleStats
                m.openPanel(.tasks)
            },
            shipped("panel-history", "右边栏 · 历史") { m in
                m.outputStats = Snapshot.sampleStats
                m.openPanel(.history)
            },
            shipped("panel-empty", "右边栏 · 没有任务") { m in
                m.openPanel(.tasks)
            },
            shipped("panel-mail-page", "右边栏 · 在应用页里拉出") { m in
                m.tasks = Snapshot.sampleTasks
                m.outputStats = Snapshot.sampleStats
                m.go(.mail)
                m.openPanel(.history)
            },
            shipped("today-notice-update", "左下角 · 有新版本") { m in
                m.sidebarNotice = SidebarNotice(id: "update", kind: .update, text: "有新版本")
            },
            shipped("today-notice-paused", "左下角 · 已暂停") { m in
                m.sidebarNotice = SidebarNotice(id: "paused", kind: .paused, text: "已暂停",
                                                detail: "正在用电池，后台先不做，免得费电。想让它在电池上也做，在「设置 · 通用」里改。")
            },
            shipped("host-takeover", "本体占整个窗口 · 首次设置") { m in
                m.present(HostPage(id: "first-run", title: "欢迎使用螺壳", style: .takeover, content: AnyView(HostSample.welcome)))
            },
            searched("search-running", "搜索 · 正在搜") { $0.runSearch("合同") },
            searched("search-failed", "搜索 · 连不上螺壳") { m in
                m.lastSeen = fixedNow.addingTimeInterval(-2 * 60)
                m.coreReachable = false
                m.searchQuery = "发票"
                m.searchAnswer = SearchAnswer(note: "螺壳暂时没响应，搜不了「发票」。", retry: true)
            },
            searched("search-nothing", "搜索 · 记忆没找到、邮件助手没回应") { $0.searchAnswer = SearchAnswer(failed: ["螺壳邮件助手"], asked: 2) },
            searched("search-all-failed", "搜索 · 能搜的两个应用都没回应") { $0.searchAnswer = SearchAnswer(failed: ["螺壳邮件助手", "记忆"], asked: 2) },
            searched("search-nothing-partial", "搜索 · 没找到，螺壳搜索说模型还在加载（带重试）") { m in
                var a = SearchAnswer(asked: 2)
                a.partial = ["螺壳还在加载模型，这次只按字词搜"]
                m.searchAnswer = a
            },
            // 按类型分组（工具协议 §1b 的 hits，窗口自己画）：示例是编的，缩略图在 SearchSample 里画
            searched("search-hits", "搜索 · 按类型分组") { searchHits($0) },
            searched("search-hits-selected", "搜索 · 选中一条，右边出预览") { m in
                searchHits(m)
                m.moveSearchSelection(1)
            },
            searched("search-hits-mail-selected", "搜索 · 只看邮件、选中一封") { m in
                searchHits(m)
                m.filterSearch("mail")
                m.searchSelected = SearchSample.hits.first { $0.kind == "mail" }?.id
            },
            searched("search-hits-pdf", "搜索 · 只看 PDF") { m in
                searchHits(m)
                m.filterSearch("pdf")
            },
            searched("search-hits-video-selected", "搜索 · 只看视频、选中一个（封面上的播放标和时长）") { m in
                searchHits(m)
                m.filterSearch("video")
                m.searchSelected = SearchSample.hits.first { $0.kind == "video" }?.id
            },
            searched("search-hits-and-card", "搜索 · 一个工具只给卡片、一个没回应") { m in
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
            stress("focus-many", "逐件处理 · 5 件", scale: many) { $0.enterFocus() },
            stress("focus-small-window", "逐件处理 · 小窗口 860×600 · 8 封的方案卡片（手写的示意；中间滚动，按钮在底部）",
                   size: CGSize(width: 860, height: 600)) { m in
                m.cards.insert(Sample.longPlanCard(8), at: 0)
                m.enterFocus()
            },
            whole("focus-long", "逐件处理 · 8 封的方案卡片（手写的示意）", height: 1400) { m in
                m.cards.insert(Sample.longPlanCard(8), at: 0)
                m.enterFocus()
            },
            kinds("today-kinds", "今天 · 要你决定有两类，各不止一件（段标题下面「按类处理」；同一类的排在一起）"),
            kinds("focus-kind", "逐件处理 · 只走一类（在「按类处理」里点了「记忆的待确认事项」）") { m in
                m.enterFocus(category: m.categoriesToPick.last?.id)
            },
            kinds("focus-kind-end", "逐件处理 · 只走一类，这一类都答完了，还有别的事") { m in
                let ids = m.categoriesToPick.last?.ids ?? []
                m.enterFocus(category: m.categoriesToPick.last?.id)
                m.focus?.tapped = Set(ids)   // 都点过了，记忆答完收走
                m.cards.removeAll { ids.contains($0.id) }
            },
            stress("focus-progress-many", "逐件处理 · 邮件的卡片多 15 倍（进度是一整条加数字）", scale: many * 3) { $0.enterFocus() },
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
                m.notices = ["螺壳邮件助手未运行"]; m.noticeRows = [NoticeRow(id: "luoke-mail", kind: "stopped", text: "螺壳邮件助手未运行")]   // agent.py `_merge` 的说法
                if let i = m.agentApps?.firstIndex(where: { $0.id == "luoke-mail" }) { m.agentApps?[i].running = false }
            },
            end(stress("today-app-stopped", "今天 · 邮件助手没在运行（核心的提示）") { m in
                m.urgent.removeAll { $0.tool == .mail }; m.cards.removeAll { $0.tool == .mail }
                m.done.removeAll { $0.tool == .mail }; m.quiet.removeAll { $0.tool == .mail }
                m.notices = ["螺壳邮件助手未运行"]; m.noticeRows = [NoticeRow(id: "luoke-mail", kind: "stopped", text: "螺壳邮件助手未运行")]
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
                m.notices = ["螺壳邮件助手未运行"]; m.noticeRows = [NoticeRow(id: "luoke-mail", kind: "stopped", text: "螺壳邮件助手未运行")]
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
            live(shipped("prefs-general", "设置 · 通用") { $0.go(.prefs, tab: "general") }),
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
            scene("full-menu-go", "完整版（beta 2 没有）· 顶部菜单 · 前往", size: menuSize, open: "go"),
        ]
    }

    /// 示例：任务队列和今天的产出
    static var sampleTasks: [TaskRow] {
        [TaskRow(id: "t1", tool: .search, title: "读取合同 PDF", state: .running(fraction: 0.4, note: "第 2 份，共 5 份")),
         TaskRow(id: "t2", tool: .mail, title: "生成订阅摘要", state: .queued(wait: .busy)),
         TaskRow(id: "t3", tool: .mem, title: "整理本周记忆", state: .queued(wait: .quiet)),
         TaskRow(id: "t4", tool: .scan, title: "全盘检查", state: .queued(wait: .power))]
    }

    static var sampleStats: OutputStats { OutputStats(tasksToday: 23, tokensToday: 184_000, tokensTotal: 3_120_000, since: "11 月 12 日") }

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


/// 截图用的本体：只给「应用管理」的数据（`HostApps`），别的都用默认
@MainActor
private final class SnapshotDataHost: WindowHost {
    static let shared = SnapshotDataHost()
    func openModelSettings() {}
    func openPrivacySettings() {}
    func openAddApps() {}
    func upgrade(app: String) {}
    func appsSnapshot() -> HostApps? {
        HostApps(rows: [
            HostAppRow(id: "luoke-mail", tool: .mail, tagline: "守着收件箱", version: "0.18.12", state: .installed,
                       actions: [.disable, .rollback(to: "0.18.11"), .deleteData, .uninstall]),
            HostAppRow(id: "luoke-ime", tool: .ime, tagline: "越用越懂你说话的方式", version: "0.1.20", state: .installed,
                       actions: [.restart, .disable, .uninstall]),
            HostAppRow(id: "luoke-scan", tool: .scan, tagline: "清掉不会丢东西的", version: "0.1.0", state: .disabled, actions: [.enable, .uninstall]),
            HostAppRow(id: "luoke-search", tool: .search, tagline: "答案带出处", version: "0.4.2", state: .working(label: "正在下载 · 40%", progress: 0.4)),
            HostAppRow(id: "luoke-mem", tool: .mem, tagline: "让每个应用更懂你", version: "0.26.0", state: .installed, bundled: true, actions: [.deleteData]),
        ], notice: HostAppsNotice(text: "输入法已重新启动", ok: true,
                                  action: (label: "打开键盘设置", app: "luoke-ime", action: .openKeyboardSettings)))
    }
}
