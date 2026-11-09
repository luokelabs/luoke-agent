import SwiftUI

/// 螺壳的主窗口：侧栏、当前页、底部的搜索和问螺壳、浮在上面的提示和权限说明。
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
        HStack(spacing: 0) {
            Sidebar(model: model)
                .frame(width: model.sidebarMini ? 72 : 220)
                .background(p.sidebar)
            Rectangle().fill(p.border).frame(width: 1)
            ZStack(alignment: .bottom) {
                PageView(model: model)
                    .padding(.leading, model.sidebarMini ? 24 : 0)
                    .frame(minWidth: 0, maxWidth: .infinity, minHeight: 0, maxHeight: .infinity, alignment: .topLeading)
                if model.features.contains(.ask) && model.focus == nil { AskLayer(model: model) }
                else if model.features.contains(.search) && model.focus == nil { SearchLayer(model: model) }
                if let t = model.toast { ToastView(toast: t, model: model).padding(.bottom, model.hasBottomBar ? 84 : 24) }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(p.bg)
            .clipped()
        }
        .overlay(alignment: .topLeading) { WindowControls(model: model) }
        .overlay { if let s = model.sheet { PermissionSheetView(sheet: s, model: model) } }
        .background(p.bg)
        .animation(.easeOut(duration: 0.2), value: model.sidebarMini)
        // 真窗口的标题栏是透明的、内容铺满（fullSizeContentView），SwiftUI 却把标题栏当成顶上的安全区，整个窗口往下挪一个标题栏，
        // 收起侧栏的按钮就掉到红黄绿下面一行。从窗口最上沿排，和截图一样
        .ignoresSafeArea(.container, edges: .top)
    }
}

/// 左上角：红黄绿（真窗口里是系统画的，截图时自己画）和收起侧栏的按钮，和红黄绿在一条线上
struct WindowControls: View {
    /// 系统红黄绿的中心离窗口上沿多少（macOS 26 透明标题栏的窗口：关闭按钮 14 pt 高、上沿在 9 pt；TitlebarTests 量真按钮核对）
    static let lightsCenterY: CGFloat = 16
    static let height: CGFloat = 24

    @ObservedObject var model: WindowModel
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
            Button { model.toggleSidebar() } label: {
                Image(systemName: "sidebar.left").font(.system(size: 14)).foregroundStyle(p.mutedFg)
                    .frame(width: 28, height: Self.height).contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .focusable(false)        // 窗口一打开不抢键盘焦点（不然带着一圈蓝框，按空格就收起侧栏）；⌃⌘S 照样能收
            .focusEffectDisabled()
            .help(model.sidebarMini ? "展开侧栏（⌃⌘S）" : "收起侧栏（⌃⌘S）")
            .accessibilityLabel(model.sidebarMini ? "展开侧栏" : "收起侧栏")
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

            NavRow(model: model, title: "今天", symbol: "tray", page: .today, count: model.todayCount, ns: ns)
            if model.shows(.activity) { NavRow(model: model, title: "活动", symbol: "clock.arrow.circlepath", page: .activity, ns: ns) }
            AppsRow(model: model, ns: ns)
            if model.appsExpanded {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(model.apps) { a in NavRow(model: model, title: a.tool.name, tool: a.tool, page: a.id, sub: true, ns: ns) }
                    NavRow(model: model, title: "添加应用", symbol: "plus", page: .apps, sub: true, ns: ns)
                }
                .padding(.leading, mini ? 0 : LKSpace.x4)
            }
            NavRow(model: model, title: "设置", symbol: "gearshape", page: .prefs, ns: ns)
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

struct NavRow: View {
    @ObservedObject var model: WindowModel
    let title: String
    var symbol: String?
    var tool: ToolIcon?
    let page: Page
    var count: Int?
    var sub = false
    let ns: Namespace.ID
    @Environment(\.lk) private var p

    var body: some View {
        let on = model.page == page
        let mini = model.sidebarMini
        Button { model.go(page) } label: {
            HStack(spacing: LKSpace.x3) {
                if let tool { AppIcon(tool: tool, size: 18) } else if let symbol {
                    Image(systemName: symbol).font(.system(size: 14)).foregroundStyle(on ? p.fg : p.mutedFg).frame(width: 18)
                }
                if !mini {
                    Text(title).font(LKFont.ui(sub ? LKType.small : LKType.body, on ? .medium : .regular)).lineLimit(1)
                    Spacer(minLength: 0)
                    if let count, count > 0 { LKCount(value: count, delay: Motion.counterAt).font(LKFont.ui(LKType.caption)).foregroundStyle(p.mutedFg) }
                }
            }
            .padding(.horizontal, mini ? 0 : LKSpace.x2)
            .frame(maxWidth: .infinity, minHeight: 32, alignment: mini ? .center : .leading)
            .background { if on { NavPill(ns: ns) } }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(mini ? title : "")
        .accessibilityLabel(title)
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
                Image(systemName: "square.grid.2x2").font(.system(size: 14)).foregroundStyle(lit ? p.fg : p.mutedFg).frame(width: 18)
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
                    Image(systemName: "chevron.right").font(.system(size: 10, weight: .semibold)).foregroundStyle(p.mutedFg)
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
        .accessibilityValue(model.appsExpanded ? "展开" : model.appsNowName.map { "收起，正在看\($0)" } ?? "收起")
    }
}

/// 侧栏底部：主控的状态灯和模型名，点了进「设置 · 模型」；收成图标时只留灯
struct ModelButton: View {
    @ObservedObject var model: WindowModel
    @Environment(\.lk) private var p

    var body: some View {
        let mini = model.sidebarMini
        Button { model.go(.prefs, tab: PrefsTab.model.rawValue) } label: {
            HStack(spacing: 6) {
                LKLight(state: model.engineReady ? .ok : .warn, label: model.engineReady ? "主控就绪" : "在准备模型")
                if !mini {
                    Text(model.modelName).font(LKFont.mono(LKType.caption)).foregroundStyle(p.mutedFg)
                    Spacer(minLength: 0)
                }
            }
            .padding(.horizontal, mini ? 0 : LKSpace.x2)
            .frame(maxWidth: .infinity, minHeight: 28, alignment: mini ? .center : .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("\(model.engineReady ? "主控就绪" : "在准备模型") · \(model.modelName) · 点了去换模型")
        .accessibilityLabel("模型 \(model.modelName)，去换")
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
        case .mail, .scan, .mem, .searchApp: AppPage(model: model, page: model.page)
        case .search: SearchPage(model: model)
        case .apps: AddAppsPage(model: model)
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
        .background(RoundedRectangle(cornerRadius: LKRadius.control, style: .continuous).fill(p.primary))
        .shadow(color: .black.opacity(0.2), radius: 15, y: 10)
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
                            Image(systemName: "checkmark.shield").foregroundStyle(p.mutedFg)
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
            .background(RoundedRectangle(cornerRadius: LKRadius.sheet, style: .continuous).fill(p.card))
            .overlay(RoundedRectangle(cornerRadius: LKRadius.sheet, style: .continuous).strokeBorder(p.dark ? p.cardEdge : .clear, lineWidth: 1))
            .shadow(color: p.shadow.opacity(p.dark ? 0.6 : 0.35), radius: 20, y: 18)
        }
    }
}
