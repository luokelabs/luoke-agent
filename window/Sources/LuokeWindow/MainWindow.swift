import SwiftUI

/// 螺壳的主窗口：侧栏、当前页、底部的搜索和问螺壳、浮在上面的提示和权限说明。螺壳只有这一个窗口（11-10 定）：
/// 本体的界面（`HostPage`）也画在这里——占内容区、浮在上面、或者占整个窗口。
public struct MainWindowView: View {
    @ObservedObject var model: WindowModel

    public init(model: WindowModel) { self.model = model }

    public var body: some View {
        Themed { WindowBody(model: model) }
    }
}

struct WindowBody: View {
    @ObservedObject var model: WindowModel
    @Environment(\.lk) private var p

    var body: some View {
        Group {
            if let t = model.hostTakeover { HostTakeoverView(page: t, model: model) } else { main }
        }
        // 卡片浮着：底下的侧栏、页点不到，读屏也只读卡片
        .allowsHitTesting(model.hostCard == nil)
        .accessibilityHidden(model.hostCard != nil)
        .overlay { if let c = model.hostCard { HostCardView(page: c, model: model) } }
        .background(p.bg)
        // 真窗口的标题栏是透明的、内容铺满（fullSizeContentView），SwiftUI 却把标题栏当成顶上的安全区，整个窗口往下挪一个标题栏，
        // 收起侧栏的按钮就掉到红黄绿下面一行。从窗口最上沿排，和截图一样
        .ignoresSafeArea(.container, edges: .top)
    }

    private var main: some View {
        HStack(spacing: 0) {
            Sidebar(model: model)
                .frame(width: model.sidebarMini ? 72 : 220)
                .background(p.sidebar)
            Rectangle().fill(p.border).frame(width: 1)
            // 量内容区有多宽（窗口减侧栏），往下传给各页和底部的搜索框：窄、一栏、宽（两栏）三档，见 LKLayout
            GeometryReader { g in
                ZStack(alignment: .bottom) {
                    Group {
                        if let h = model.hostPage { HostPageView(page: h, model: model) } else { PageView(model: model) }
                    }
                    .frame(minWidth: 0, maxWidth: .infinity, minHeight: 0, maxHeight: .infinity, alignment: .topLeading)
                    if model.hostPage != nil {
                        // 本体的一页：底部不画搜索和问螺壳
                    } else if model.features.contains(.ask) && model.focus == nil { AskLayer(model: model) }
                    else if model.features.contains(.search) && model.focus == nil { SearchLayer(model: model) }
                    if let t = model.toast { ToastView(toast: t, model: model).padding(.bottom, model.hasBottomBar ? 84 : 24) }
                }
                .frame(width: g.size.width, height: g.size.height)
                .environment(\.lkLayout, LKLayout(width: g.size.width))
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(p.bg)
            .clipped()
        }
        .overlay(alignment: .topLeading) { WindowControls(model: model) }
        .overlay { if let s = model.sheet { PermissionSheetView(sheet: s, model: model) } }
        .animation(.easeOut(duration: 0.2), value: model.sidebarMini)
    }
}

/// 本体的一页（`HostPage.Style.page`）：占内容区，上面标题，下面是本体的界面。和 agent 自己的页一样没有「返回」：
/// 用户点侧栏（底下那一页的那一行也算）离开，或者点本体界面里自己的按钮（取消、完成、以后再说）
struct HostPageView: View {
    let page: HostPage
    @ObservedObject var model: WindowModel

    var body: some View {
        PageScroll {
            PageHeader(title: page.title)
            page.content
        }
        .id(page.id)
    }
}

/// 本体的卡片（`HostPage.Style.card`）：浮在整个窗口上，底下压暗（和要权限的说明一样），右上角 ×，Esc 同 ×
struct HostCardView: View {
    let page: HostPage
    @ObservedObject var model: WindowModel
    @Environment(\.lk) private var p
    @Environment(\.lkSnapshot) private var snapshot

    var body: some View {
        ZStack {
            Color(red: 20 / 255, green: 12 / 255, blue: 8 / 255).opacity(0.32)
                .contentShape(Rectangle())
                .onTapGesture {}           // 点底下压暗的地方不穿过去，也不关
            VStack(alignment: .leading, spacing: 0) {
                HStack(alignment: .center, spacing: LKSpace.x3) {
                    Text(page.title).font(LKFont.ui(LKType.lead, .semibold)).accessibilityAddTraits(.isHeader)
                    Spacer(minLength: LKSpace.x4)
                    Button { model.leaveHost(page.id) } label: {
                        LKIcon("x").foregroundStyle(p.mutedFg).frame(width: 28, height: 28).contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .keyboardShortcut(.cancelAction)
                    .help("关闭（Esc）")
                    .accessibilityLabel("关闭")
                }
                .padding(.bottom, LKSpace.x4)
                // 放得下就照内容的高；窗口太矮放不下时标题不动、内容滚（卡片最高是窗口减四周的边）
                ViewThatFits(in: .vertical) {
                    page.content.fixedSize(horizontal: false, vertical: true)     // 照内容本来的高，里面的 Spacer 不把卡片撑满
                    if snapshot {
                        // 截图画不出滚动区：和停在最上面一样，按内容画、多出来的从下面截掉（同 PageScroll）
                        page.content.fixedSize(horizontal: false, vertical: true)
                            .frame(minHeight: 0, maxHeight: .infinity, alignment: .top).clipped()
                    } else {
                        ScrollView { page.content }.scrollBounceBehavior(.basedOnSize)
                    }
                }
            }
            .padding(EdgeInsets(top: LKSpace.x5, leading: LKSpace.x6, bottom: LKSpace.x5, trailing: LKSpace.x5))
            .frame(minWidth: 420, maxWidth: 640)
            // 影子只给底下那块：加在整张卡片上，里面的字和按钮各带一圈模糊的影子
            .background(RoundedRectangle(cornerRadius: LKRadius.sheet, style: .continuous).fill(p.card)
                .shadow(color: p.shadow.opacity(p.dark ? 0.6 : 0.35), radius: 20, y: 18))
            .overlay { if p.dark { CardEdge() } }      // 深色下卡片和压暗的底差不多深：描一圈边才看得出边在哪
            .accessibilityElement(children: .contain)
            .accessibilityAddTraits(.isModal)
            .padding(LKSpace.x6)
        }
        .id(page.id)
    }
}

/// 浮着的卡片在深色下的边：一圈细线
struct CardEdge: View {
    @Environment(\.lk) private var p
    var body: some View {
        RoundedRectangle(cornerRadius: LKRadius.sheet, style: .continuous).strokeBorder(p.border, lineWidth: 1)
    }
}

/// 本体的界面占整个窗口（`HostPage.Style.takeover`：首次设置、升级）：没有侧栏、搜索、问螺壳；内容顶到窗口上沿，左上角压着红黄绿
struct HostTakeoverView: View {
    let page: HostPage
    @ObservedObject var model: WindowModel
    @Environment(\.lk) private var p

    var body: some View {
        ZStack(alignment: .bottom) {
            // 顶到窗口上沿，红黄绿压在上面（和侧栏一样）：本体的界面照环境里的 lkHostTopInset 在左上角让开
            page.content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .environment(\.lkHostTopInset, HostPage.lightsInset)
            if let t = model.toast { ToastView(toast: t, model: model).padding(.bottom, 24) }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(p.bg)
        .overlay(alignment: .topLeading) { WindowControls(model: model, sidebarToggle: false) }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(page.title)
        .id(page.id)
    }
}

/// 左上角：红黄绿（真窗口里是系统画的，截图时自己画）和收起侧栏的按钮，和红黄绿在一条线上
struct WindowControls: View {
    /// 系统红黄绿的中心离窗口上沿多少（macOS 26 透明标题栏的窗口：关闭按钮 14 pt 高、上沿在 9 pt；TitlebarTests 量真按钮核对）
    static let lightsCenterY: CGFloat = 16
    static let height: CGFloat = 24

    @ObservedObject var model: WindowModel
    /// 收起侧栏的按钮：本体的界面占着整个窗口时没有侧栏，不画
    var sidebarToggle = true
    @Environment(\.lk) private var p
    @Environment(\.lkSnapshot) private var snapshot

    var body: some View {
        HStack(spacing: 14) {
            if snapshot {
                HStack(spacing: 8) {
                    Circle().fill(Color.hex(0xE0605A)).frame(width: 12, height: 12)
                    Circle().fill(Color.hex(0xE3B341)).frame(width: 12, height: 12)
                    Circle().fill(Color.hex(0x5DB55B)).frame(width: 12, height: 12)
                }
            } else {
                Color.clear.frame(width: 52, height: 12)
            }
            if sidebarToggle {
                Button { model.toggleSidebar() } label: {
                    LKIcon("panel-left", size: 16).foregroundStyle(p.mutedFg)
                        .frame(width: 28, height: Self.height).contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .focusable(false)        // 窗口一打开不抢键盘焦点（不然带着一圈蓝框，按空格就收起侧栏）；⌃⌘S 照样能收
                .focusEffectDisabled()
                .help(model.sidebarMini ? "展开侧栏（⌃⌘S）" : "收起侧栏（⌃⌘S）")
                .accessibilityLabel(model.sidebarMini ? "展开侧栏" : "收起侧栏")
            }
        }
        .frame(height: Self.height)
        .padding(.leading, 16)
        .padding(.top, Self.lightsCenterY - Self.height / 2)
    }
}

struct Sidebar: View {
    @ObservedObject var model: WindowModel
    @Environment(\.lk) private var p
    @Environment(\.accessibilityReduceMotion) private var reduce
    @Namespace private var ns

    var body: some View {
        let mini = model.sidebarMini
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: LKSpace.x3) {
                BrandBadge(size: 32)
                if !mini { Text("螺壳").font(LKFont.ui(LKType.lead, .semibold)) }
            }
            .frame(maxWidth: .infinity, alignment: mini ? .center : .leading)
            .padding(.leading, mini ? 0 : LKSpace.x2)
            .padding(.bottom, LKSpace.x4)

            NavRow(model: model, title: "今天", symbol: "inbox", page: .today, count: model.todayCount, urgent: model.hasUrgent, ns: ns)
            if model.shows(.activity) { NavRow(model: model, title: "活动", symbol: "history", page: .activity, ns: ns) }
            AppsRow(model: model, ns: ns)
            if model.appsExpanded {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(model.apps) { a in
                        // 应用没在运行：行尾一个空心圈（和底部「连不上螺壳」同一个记号），收起时也看得出是谁停了
                        NavRow(model: model, title: a.tool.name, tool: a.tool, page: a.id, sub: true, ns: ns,
                               stopped: model.coreReachable && model.agentApp(for: a.id)?.running == false)
                    }
                    NavRow(model: model, title: "添加应用", symbol: "plus", page: .apps, sub: true, ns: ns)
                }
                .padding(.leading, mini ? 0 : LKSpace.x4)
            }
            NavRow(model: model, title: "设置", symbol: "settings", page: .prefs, ns: ns)
            Spacer(minLength: 0)
            Rectangle().fill(p.border).frame(height: 1).padding(.top, LKSpace.x3)
            ModelButton(model: model).padding(.top, LKSpace.x3)
        }
        .padding(.horizontal, LKSpace.x3)
        .padding(.top, LKSpace.x11)
        .padding(.bottom, LKSpace.x3)
        .animation(reduce ? nil : Motion.move(Motion.pill), value: model.page)
        .animation(reduce ? nil : Motion.move(Motion.pill), value: model.appsExpanded)
    }
}

/// 侧栏选中的那一行的底：换页时滑过去
struct NavPill: View {
    let ns: Namespace.ID
    @Environment(\.lk) private var p

    var body: some View {
        RoundedRectangle(cornerRadius: LKRadius.control, style: .continuous).fill(p.selection)
            .matchedGeometryEffect(id: "nav-pill", in: ns)
    }
}

/// 侧栏一行上的标记，同一时间只画一个：有急事只画红点（几件要你决定进「今天」里看），没急事才画要你决定的数。
/// 收成图标时都在图标右上角
enum SidebarMark: Equatable {
    case none, urgent, count(Int)

    static func of(count: Int?, urgent: Bool) -> SidebarMark {
        if urgent { return .urgent }
        if let count, count > 0 { return .count(count) }
        return .none
    }
}

struct NavRow: View {
    @ObservedObject var model: WindowModel
    let title: String
    var symbol: String?
    var tool: ToolIcon?
    let page: Page
    var count: Int?
    /// 有急事：只画红点，不画数字（`SidebarMark`）
    var urgent = false
    var sub = false
    let ns: Namespace.ID
    var stopped = false
    @Environment(\.lk) private var p

    /// 读屏念的、收成图标时悬停看到的：几件要你决定、有没有急事
    private var countText: String {
        [count.flatMap { $0 > 0 ? "\($0) 件要你决定" : nil }, urgent ? "有急事" : nil].compactMap { $0 }.joined(separator: "，")
    }

    private var urgentDot: some View {
        Circle().fill(p.danger).frame(width: 7, height: 7).accessibilityHidden(true)
    }

    var body: some View {
        let on = model.sidebarSelection == page        // 本体的一页、整窗盖着时哪一行都不亮
        let mini = model.sidebarMini
        let mark = SidebarMark.of(count: count, urgent: urgent)
        Button { model.go(page) } label: {
            HStack(spacing: LKSpace.x3) {
                Group {
                    if let tool { AppIcon(tool: tool, size: 18) } else if let symbol {
                        LKIcon(symbol, size: 16).foregroundStyle(on ? p.fg : p.mutedFg).frame(width: 18)
                    }
                }
                .overlay(alignment: .bottomTrailing) {
                    if mini && stopped { LKLight(state: .off, label: "没在运行").background(Circle().fill(p.sidebar).padding(-2)).offset(x: 5, y: 4) }
                }
                .overlay(alignment: .topTrailing) {
                    // 收成图标时红点、数字都在图标右上角，同一个位置（展开时在行尾）
                    if mini, mark == .urgent {
                        urgentDot.background(Circle().fill(p.sidebar).padding(-2)).offset(x: 5.5, y: -3.5)   // 中心和数字的小圆对齐
                    } else if mini, case .count(let count) = mark {
                        Text(count > 99 ? "99+" : "\(count)").font(.system(size: 9, weight: .semibold)).monospacedDigit()
                            .foregroundStyle(p.bg).padding(.horizontal, 4).frame(minWidth: 14, minHeight: 14)
                            .background(Capsule().fill(p.mutedFg))
                            .offset(x: 9, y: -7)
                            .accessibilityHidden(true)
                    }
                }
                if !mini {
                    Text(title).font(LKFont.ui(sub ? LKType.small : LKType.body, on ? .medium : .regular)).lineLimit(1)
                    Spacer(minLength: 0)
                    if mark == .urgent { urgentDot }
                    else if case .count(let count) = mark { LKCount(value: count, delay: Motion.counterAt).font(LKFont.ui(LKType.caption)).foregroundStyle(p.mutedFg) }
                    if stopped { LKLight(state: .off, label: "没在运行") }
                }
            }
            .padding(.horizontal, mini ? 0 : LKSpace.x2)
            .frame(maxWidth: .infinity, minHeight: 32, alignment: mini ? .center : .leading)
            .background { if on { NavPill(ns: ns) } }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(stopped ? "\(title)没在运行" : mini ? (countText.isEmpty ? title : "\(title)：\(countText)") : (urgent ? countText : ""))
        .accessibilityLabel(title)
        .accessibilityValue(stopped ? "没在运行" : countText)
        .accessibilityAddTraits(on ? .isSelected : [])
    }
}

/// 「应用」一行：收着时叠着几个小图标；正在看某个应用的页时这一行亮着，那个应用的小图标亮着、别的淡下去
struct AppsRow: View {
    @ObservedObject var model: WindowModel
    let ns: Namespace.ID
    @Environment(\.lk) private var p

    var body: some View {
        let lit = model.appsRowLit
        let mini = model.sidebarMini
        Button { model.toggleApps() } label: {
            HStack(spacing: LKSpace.x3) {
                LKIcon("layout-grid", size: 16).foregroundStyle(lit ? p.fg : p.mutedFg).frame(width: 18)
                if !mini {
                    Text("应用").font(LKFont.ui(LKType.body, lit ? .medium : .regular)).lineLimit(1)
                    Spacer(minLength: 0)
                    if !model.appsExpanded {
                        let edge = p.sidebar
                        HStack(spacing: -4) {
                            ForEach(model.apps.prefix(4)) { a in
                                let dim = model.appsNow != nil && model.appsNow != a.id
                                AppIcon(tool: a.tool, size: 15)
                                    .overlay(RoundedRectangle(cornerRadius: LKRadius.small, style: .continuous).fill(edge.opacity(dim ? 0.6 : 0)))   // 淡下去但不透明，叠着的不透出来
                                    .overlay(RoundedRectangle(cornerRadius: LKRadius.small, style: .continuous).strokeBorder(edge, lineWidth: 1.5))
                                    .zIndex(model.appsNow == a.id ? 1 : 0)
                            }
                        }
                    }
                    LKIcon("chevron-right", size: 12).foregroundStyle(p.mutedFg)
                        .rotationEffect(.degrees(model.appsExpanded ? 90 : 0))
                }
            }
            .padding(.horizontal, mini ? 0 : LKSpace.x2)
            .frame(maxWidth: .infinity, minHeight: 32, alignment: mini ? .center : .leading)
            .background { if lit { NavPill(ns: ns) } }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(mini ? "应用" : model.appsNowName.map { "正在看\($0)" } ?? "")
        .accessibilityLabel("应用")
        .accessibilityValue(model.appsExpanded ? "已展开" : model.appsNowName.map { "已收起，正在看\($0)" } ?? "已收起")   // 状态不是动作：念「收起」像要去收起它
    }
}

/// 侧栏底部：螺壳的状态（灯加一句话），点了进「设置 · 模型」；收成图标时只留灯，意思在悬停提示和读屏里
struct ModelButton: View {
    @ObservedObject var model: WindowModel
    @Environment(\.lk) private var p

    private var footText: String { !model.coreReachable ? WindowModel.offlineShort : model.engineReady ? "螺壳在运行" : "螺壳在准备" }
    private var footState: LKLight.State { !model.coreReachable ? .off : model.engineReady ? .ok : .warn }

    var body: some View {
        let mini = model.sidebarMini
        Button { model.go(.prefs, tab: PrefsTab.model.rawValue) } label: {
            HStack(spacing: 6) {
                LKLight(state: footState, label: footText)
                if !mini {
                    // 写状态，不写模型名（技术细节）：模型名在悬停提示和「设置 · 模型」里
                    Text(footText)   // 和菜单栏同一个说法
                        .font(LKFont.ui(LKType.caption)).foregroundStyle(p.mutedFg)
                    Spacer(minLength: 0)
                }
            }
            .padding(.horizontal, mini ? 0 : LKSpace.x2)
            .frame(maxWidth: .infinity, minHeight: 28, alignment: mini ? .center : .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(model.coreReachable ? "\(footText)，用的模型是 \(model.modelName) · 点了去换模型" : "螺壳暂时没响应，窗口在等它恢复")
        .accessibilityLabel("\(footText)，去设置里看模型")
    }
}

/// 当前页。换页时旧的 130 ms 淡出，新的各块错开升上来（`lkEnter`）
struct PageView: View {
    @ObservedObject var model: WindowModel
    @Environment(\.accessibilityReduceMotion) private var reduce

    var body: some View {
        ZStack(alignment: .topLeading) {
            page
                .id(model.page)
                .transition(.asymmetric(insertion: .identity, removal: .opacity))
                .environment(\.lkEntrance, model.entrance)
        }
        .animation(Motion.exit(Motion.pageOut, reduce: reduce), value: model.page)
    }

    @ViewBuilder private var page: some View {
        switch model.page {
        case .today: TodayPage(model: model)
        case .activity: ActivityPage(model: model)
        case .mail, .scan, .mem, .searchApp, .ime: AppPage(model: model, page: model.page)
        case .search: SearchPage(model: model)
        case .apps:
            if let apps = model.host?.appsContent() {        // 接着本体：本体的应用目录画在这一页
                PageScroll { PageHeader(title: "应用"); apps }
            } else {
                AddAppsPage(model: model)
            }
        case .prefs: SettingsPage(model: model)
        case .chat: ChatPage(model: model)
        }
    }
}

struct ToastView: View {
    let toast: Toast
    @ObservedObject var model: WindowModel
    @Environment(\.lk) private var p

    var body: some View {
        HStack(spacing: 14) {
            Text(toast.text)
            if toast.canUndo {
                Button { model.undoLast() } label: { Text("撤销").underline().font(LKFont.ui(LKType.small, .medium)) }
                    .buttonStyle(.plain)
            }
        }
        .font(LKFont.ui(LKType.small))
        .foregroundStyle(p.primaryFg)
        .padding(.horizontal, LKSpace.x4).padding(.vertical, LKSpace.x3 - 2)
        .background(RoundedRectangle(cornerRadius: LKRadius.control, style: .continuous).fill(p.primary)
            .shadow(color: .black.opacity(0.2), radius: 15, y: 10))      // 同上：影子只给底
        .accessibilityElement(children: .combine)
    }
}

/// 要权限：先说清楚，点「继续」才让应用去弹系统的授权框
struct PermissionSheetView: View {
    let sheet: PermissionSheet
    @ObservedObject var model: WindowModel
    @Environment(\.lk) private var p

    var body: some View {
        ZStack {
            Color(red: 20 / 255, green: 12 / 255, blue: 8 / 255).opacity(0.32)
            VStack(alignment: .leading, spacing: 0) {
                AppIcon(tool: sheet.owner, size: 40)
                Text(sheet.title).font(LKFont.ui(LKType.lead, .semibold)).padding(.top, LKSpace.x3).padding(.bottom, LKSpace.x4)
                VStack(alignment: .leading, spacing: LKSpace.x3) {
                    ForEach(sheet.facts, id: \.self) { f in
                        HStack(alignment: .top, spacing: LKSpace.x3) {
                            LKIcon("shield-check").foregroundStyle(p.mutedFg)
                            Text(f).font(LKFont.ui(LKType.small))
                        }
                    }
                }
                HStack(spacing: LKSpace.x2) {
                    if sheet.waiting {
                        ProgressView().controlSize(.small)
                        Text("等系统的授权框…").font(LKFont.ui(LKType.small)).foregroundStyle(p.mutedFg)
                    }
                    Spacer()
                    Button("先不用") { model.closeSheet() }.buttonStyle(LKButtonStyle(kind: .text))
                    Button("继续") { model.continueSheet() }.buttonStyle(LKButtonStyle(kind: .primary))
                }
                .padding(.top, LKSpace.x4)
            }
            .padding(EdgeInsets(top: LKSpace.x6, leading: LKSpace.x6, bottom: LKSpace.x5, trailing: LKSpace.x6))
            .frame(width: 460)
            // 影子只给底下那块：加在整张卡片上，里面的字和按钮各带一圈模糊的影子
            .background(RoundedRectangle(cornerRadius: LKRadius.sheet, style: .continuous).fill(p.card)
                .shadow(color: p.shadow.opacity(p.dark ? 0.6 : 0.35), radius: 20, y: 18))
            .overlay { if p.dark { CardEdge() } }      // 深色下卡片和压暗的底差不多深：描一圈边才看得出边在哪
        }
    }
}
