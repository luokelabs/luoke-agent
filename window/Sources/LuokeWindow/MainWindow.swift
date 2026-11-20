import LuokeA2UI
import SwiftUI

/// 螺壳的主窗口：侧栏、当前页、底部的搜索和问螺壳、浮在上面的提示和权限说明。螺壳只有这一个窗口（11-10 定）：
/// 本体的界面（`HostPage`）也画在这里——占内容区、浮在上面、或者占整个窗口。
public struct MainWindowView: View {
    @ObservedObject var model: WindowModel

    public init(model: WindowModel) { self.model = model }

    public var body: some View {
        Themed { WindowBody(model: model) }
            .modifier(AppearanceOverride(appearance: model.appearance))
            // 「显示」菜单里那一项写「进入」还是「退出」全屏幕
            .onReceive(NotificationCenter.default.publisher(for: NSWindow.didEnterFullScreenNotification)) { _ in model.fullScreen = true }
            .onReceive(NotificationCenter.default.publisher(for: NSWindow.didExitFullScreenNotification)) { _ in model.fullScreen = false }
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
        VStack(spacing: 0) {
        // 顶上一条标题栏（负责人 11-14）：红黄绿、收起侧栏的按钮、右上角的胶囊排在同一条上，和下面的颜色弱弱地分开；
        // 侧栏收起、展开都不用为了让出红黄绿那一截改底色
        Themed(layer: .home) { TitleBar(model: model) }
        HStack(spacing: 0) {
            // 侧栏展开时一直用首页那组颜色，不随页面换（界面规范 v2 §11、§17 第 1 条的默认）；
            // 收成一列图标时和内容区同一组颜色（负责人 11-13 定的 A：收起后不再上底色）
            Themed(layer: model.sidebarMini ? model.contentLayer : .home) { SidebarColumn(model: model) }
            // 内容区：首页用首页那组，别的页（本体的页也算）用工作台那组，底色跟着换
            Themed(layer: model.contentLayer) { ContentArea(model: model) }
                .frame(width: model.panelLock)
                .background(GeometryReader { g in
                    Color.clear
                        .onAppear { if model.panelLock == nil { model.contentWidth = g.size.width } }
                        .onChange(of: g.size.width) { _, w in if model.panelLock == nil { model.contentWidth = w } }
                })
            // 右边栏：独立于应用，一直用首页那组颜色；拉出时在内容区右边，不盖住底部的搜索。
            // 开、收的动画里内容区定着宽，右边栏只占窗口多出来的那一截，从左往右露出来
            if model.panelShown {
                Themed(layer: .home) {
                    HStack(spacing: 0) {
                        PanelEdge()
                        RightPanel(model: model)
                    }
                }
                // 动画里（内容区定着宽）只占窗口多出来的那一截；平时定宽，窗口长不出来（贴着屏幕宽）时挤内容区，
                // 不能反过来被内容区挤成 0 宽（负责人 11-15：点了胶囊，胶囊没了，右边栏也没出来）
                .frame(minWidth: model.panelLock == nil ? RightPanel.width + 1 : 0, maxWidth: RightPanel.width + 1,
                       alignment: .leading)
                .layoutPriority(1)
                .clipped()
            }
        }
        // 真窗口顶上有标题栏的安全区，底色（侧栏、内容区的 .background）会往上画进去，盖住标题栏：截在自己这一块里
        .clipped()
        }
        .overlay(alignment: .topLeading) { WindowControls(model: model) }
        .overlay { if let s = model.sheet { PermissionSheetView(sheet: s, model: model) } }
        .background(PanelWindowGrow(model: model, open: model.panelOpen))
        .modifier(MachineLoadSampler(model: model))
        .animation(.easeOut(duration: 0.2), value: model.sidebarMini)
        // 右边栏开、收：窗口长出、缩回带动画，内容区定着不动（PanelWindowGrow）
    }
}

/// 窗口看得见的时候每 2 秒读一次这台 Mac 多忙（右上角的圆环、右边栏顶上用）；截图时不读，用示例给的
private struct MachineLoadSampler: ViewModifier {
    @ObservedObject var model: WindowModel
    @Environment(\.lkSnapshot) private var snapshot

    func body(content: Content) -> some View {
        content.task {
            guard !snapshot else { return }
            while !Task.isCancelled {
                let load = await Task.detached(priority: .utility) { MachineLoad.sample() }.value
                if model.machineLoad != load { model.machineLoad = load }
                try? await Task.sleep(for: .seconds(2))
            }
        }
    }
}

/// 拉出右边栏时窗口往外长出一栏宽，内容区不变窄；收起时缩回去（负责人 11-13：挤中间容易把中间挤乱）。
/// 屏幕右边放不下就整个窗口往左挪；整块屏幕都放不下才挤内容区。全屏、缩放到最大时不动窗口。
/// 窗口起来时右边栏本来就开着（记在这台 Mac 上的）不算拉出，不长。
/// 长、缩带动画（负责人 11-15）：动画里内容区定着宽（`panelLock`），右边栏只占多出来的那一截；完了放开
private struct PanelWindowGrow: NSViewRepresentable {
    let model: WindowModel
    let open: Bool

    static let duration = 0.22

    final class Coordinator {
        var last: Bool?
        /// 拉出时长了多宽、往左挪了多少：收起时照这个还回去
        var grew: CGFloat = 0
        var shifted: CGFloat = 0
        /// 第几次开、收：动画没完又点了，前一次的收尾不再放开
        var turn = 0
    }

    func makeCoordinator() -> Coordinator { Coordinator() }
    func makeNSView(context: Context) -> NSView { NSView() }

    func updateNSView(_ view: NSView, context: Context) {
        let c = context.coordinator
        // 先记下这一次开没开：窗口还没挂上、第一次画时也要记，不然下一次开、收认不出变了没有，
        // 内容区定住的宽和「正在收」放不开（负责人 11-15：点了胶囊，胶囊没了，右边栏也没出来）
        let prev = c.last
        c.last = open
        // 起来时右边栏本来就开着：上次拉出时长了多少记在这台 Mac 上，读回来，收起时照样缩回去
        // （负责人 11-15：不读的话每次「开着退出、再打开、收起」窗口就宽一栏）
        if prev == nil, open, let g = model.panelGrowth { c.grew = g.grew; c.shifted = g.shifted }
        guard let w = view.window, let last = prev else { release(c, turn: c.turn); return }
        guard last != open else { return }
        c.turn += 1
        let turn = c.turn
        guard !w.styleMask.contains(.fullScreen) else { release(c, turn: turn); return }
        var f = w.frame
        if open {
            let vis = w.screen?.visibleFrame ?? f
            f.size.width = min(f.width + RightPanel.width + 1, vis.width)
            if f.maxX > vis.maxX { f.origin.x = max(vis.minX, vis.maxX - f.width) }
            c.grew = f.width - w.frame.width
            c.shifted = w.frame.minX - f.minX
            model.panelGrowth = c.grew > 0 ? (c.grew, c.shifted) : nil
        } else {
            model.panelGrowth = nil
            guard c.grew > 0 else { release(c, turn: turn); return }
            // 不缩到比窗口的最小宽度还窄
            let shrink = min(c.grew, max(0, f.width - w.minSize.width))
            f.size.width -= shrink
            f.origin.x += min(c.shifted, shrink)
            c.grew = 0
            c.shifted = 0
        }
        guard f != w.frame else { release(c, turn: turn); return }
        // 先让这一轮把内容区定住的宽画上，下一轮再动窗口
        DispatchQueue.main.async {
            let reduce = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
            if reduce {
                w.setFrame(f, display: true, animate: false)
                release(c, turn: turn)
                return
            }
            NSAnimationContext.runAnimationGroup({ ctx in
                ctx.duration = Self.duration
                ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
                w.animator().setFrame(f, display: true)
            }, completionHandler: { release(c, turn: turn) })
            // 动画没跑（窗口在后台、系统不给动画）也不能卡在半路：到点没到位就直接放到位，再放开内容区
            DispatchQueue.main.asyncAfter(deadline: .now() + Self.duration + 0.3) {
                guard turn == c.turn else { return }
                if w.frame != f { w.setFrame(f, display: true, animate: false) }
                release(c, turn: turn)
            }
        }
    }

    /// 放开内容区的宽；收完了右边栏不再画
    private func release(_ c: Coordinator, turn: Int) {
        DispatchQueue.main.async {
            guard turn == c.turn else { return }
            if model.panelLock != nil { model.panelLock = nil }
            if model.panelClosing { model.panelClosing = false }
        }
    }
}

/// 右边栏左边的线
private struct PanelEdge: View {
    @Environment(\.lk) private var p
    var body: some View { Rectangle().fill(p.border).frame(width: 1) }
}

/// 侧栏那一列和它右边的线
private struct SidebarColumn: View {
    @ObservedObject var model: WindowModel
    @Environment(\.lk) private var p

    var body: some View {
        HStack(spacing: 0) {
            Sidebar(model: model)
                .frame(width: model.sidebarMini ? WindowControls.sidebarMiniWidth : WindowControls.sidebarWidth)
                .background(model.sidebarMini ? p.bg : p.sidebar)
            Rectangle().fill(p.border).frame(width: 1)
        }
    }
}

/// 内容区：当前页、底部的搜索和问螺壳、提示
private struct ContentArea: View {
    @ObservedObject var model: WindowModel
    @Environment(\.lk) private var p

    var body: some View {
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
                else if model.searchBarShown { SearchLayer(model: model) }
                // 应用的隐藏页、设置底下的链接：弹窗盖在内容区中间（走查重画稿）
                if model.sheet == nil, let d = model.appDialog { AppDialogView(model: model, app: d.app, ref: d.page) }
                else if model.sheet == nil, model.page == .prefs, let d = model.settingsDialog { SettingsDialogView(model: model, dialog: d) }
                if let t = model.toast { ToastView(toast: t, model: model).padding(.bottom, model.hasBottomBar ? 84 : 24) }
            }
            .frame(width: g.size.width, height: g.size.height)
            .environment(\.lkLayout, LKLayout(width: g.size.width))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(p.bg)
        .clipped()
    }
}

/// 顶上的标题栏：红黄绿（系统画，截图里 `WindowControls` 画）、收起侧栏的按钮、右上角的胶囊。底色是侧栏那一层，
/// 下沿一条线，和下面的内容区弱弱地分开
struct TitleBar: View {
    @ObservedObject var model: WindowModel
    @Environment(\.lk) private var p

    var body: some View {
        HStack(spacing: 0) {
            // 「逐件处理」开着时先不画收起按钮（返回今天再收起侧栏）
            if model.focus == nil {
                SidebarToggle(model: model).padding(.leading, WindowControls.toggleMinX)
            }
            Spacer(minLength: 0)
            // 右上角的胶囊：右边栏收着、不是本体的一页占着时才有
            if !model.panelOpen && model.hostPage == nil && model.focus == nil {
                OutputPill(model: model).padding(.trailing, LKSpace.x3)
            }
        }
        .frame(height: WindowControls.height)
        .frame(maxWidth: .infinity)
        .background(p.sidebar)
        .overlay(alignment: .bottom) { Rectangle().fill(p.border).frame(height: 1) }
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
/// 外观选了浅色或深色：整个窗口照它画，不跟系统。弹出的确认框、菜单是另开的小窗，跟的是窗口的 AppKit 外观，
/// 只改 SwiftUI 的 colorScheme 它们还照系统画（系统深色、螺壳浅色时，确认框深底配浅色主题的灰字，几乎看不见），所以窗口的外观也一起设
struct AppearanceOverride: ViewModifier {
    let appearance: Appearance
    func body(content: Content) -> some View {
        Group {
            switch appearance {
            case .system: content
            case .light: content.environment(\.colorScheme, .light)
            case .dark: content.environment(\.colorScheme, .dark)
            }
        }
        .background(WindowAppearance(appearance: appearance))
    }
}

/// 把螺壳选的外观设到所在的窗口上（跟随系统时放回 nil）
struct WindowAppearance: NSViewRepresentable {
    let appearance: Appearance

    var named: NSAppearance? {
        switch appearance {
        case .system: return nil
        case .light: return NSAppearance(named: .aqua)
        case .dark: return NSAppearance(named: .darkAqua)
        }
    }

    final class Probe: NSView {
        var wanted: NSAppearance?
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let window, window.appearance?.name != wanted?.name { window.appearance = wanted }
        }
    }

    func makeNSView(context: Context) -> Probe { Probe() }

    func updateNSView(_ v: Probe, context: Context) {
        v.wanted = named
        if let window = v.window, window.appearance?.name != named?.name { window.appearance = named }
    }
}

/// 弹窗的外框：压暗底下，中间一张卡片，标题和 ×（Esc）
struct LKDialog<Content: View>: View {
    let title: String
    let close: () -> Void
    @ViewBuilder var content: Content
    @Environment(\.lk) private var p
    @Environment(\.lkSnapshot) private var snapshot

    /// 卡片的上沿离内容区顶上多远：定在一处，卡片往下长。照内容的高矮上下居中的话，同一个弹窗里换标签、内容变高变矮，
    /// 标题和标签栏跟着上下挪，连着点会点空（#175）
    static func top(in height: CGFloat) -> CGFloat { max(LKSpace.x8, (height * 0.12).rounded()) }

    var body: some View {
        GeometryReader { geo in card(top: LKDialog.top(in: geo.size.height)) }
            .accessibilityAddTraits(.isModal)
    }

    private func card(top: CGFloat) -> some View {
        ZStack(alignment: .top) {
            Color(red: 20 / 255, green: 12 / 255, blue: 8 / 255).opacity(0.32)
                .contentShape(Rectangle())
                .onTapGesture { close() }
            VStack(alignment: .leading, spacing: 0) {
                HStack(alignment: .center, spacing: LKSpace.x3) {
                    Text(title).font(LKFont.ui(LKType.lead, .semibold)).accessibilityAddTraits(.isHeader)
                    Spacer(minLength: LKSpace.x4)
                    Button(action: close) {
                        LKIcon("x").foregroundStyle(p.mutedFg).frame(width: 28, height: 28).contentShape(Rectangle())
                    }
                    .buttonStyle(.plainPointer)
                    .keyboardShortcut(.cancelAction)
                    .help("关闭（Esc）")
                    .accessibilityLabel("关闭")
                }
                .padding(.bottom, LKSpace.x3)
                ViewThatFits(in: .vertical) {
                    content.fixedSize(horizontal: false, vertical: true)
                    if snapshot {
                        content.fixedSize(horizontal: false, vertical: true)
                            .frame(minHeight: 0, maxHeight: .infinity, alignment: .top).clipped()
                    } else {
                        ScrollView { content }.scrollBounceBehavior(.basedOnSize)
                    }
                }
            }
            .padding(EdgeInsets(top: LKSpace.x5, leading: LKSpace.x6, bottom: LKSpace.x5, trailing: LKSpace.x5))
            // 不定最小宽度：右边栏拉出来、窗口窄时内容区可能不到 460，定了最小宽度弹窗会比内容区宽，左边被切掉、右边伸出去
            .frame(maxWidth: 600)
            .background(RoundedRectangle(cornerRadius: LKRadius.sheet, style: .continuous).fill(p.card)
                .shadow(color: p.shadow.opacity(p.dark ? 0.6 : 0.35), radius: 20, y: 18))
            .overlay { if p.dark { RoundedRectangle(cornerRadius: LKRadius.sheet, style: .continuous).strokeBorder(p.border, lineWidth: 1) } }
            .padding(EdgeInsets(top: top, leading: LKSpace.x8, bottom: LKSpace.x8, trailing: LKSpace.x8))
        }
    }
}

/// 应用的隐藏页以弹窗打开（走查重画稿：邮件助手的设置和处理记录、记忆设置、扫描一类的详情）：
/// 压暗底下，中间一张卡片，标题和 ×（Esc）；里面是工具给的这一页
struct AppDialogView: View {
    @ObservedObject var model: WindowModel
    let app: AgentApp
    let ref: AgentApp.PageRef
    @Environment(\.lk) private var p

    var body: some View {
        LKDialog(title: title, close: { model.closeAppDialog() }) { body(AgentFeed.pageKey(app.id, ref.id)) }
    }

    /// 页上放在标题那一行的一段字（「旧安装包 · 205 MB」）就是弹窗的标题；没有就用页名
    private var title: String {
        guard let s = model.agentPages[AgentFeed.pageKey(app.id, ref.id)]?.surface?.surface,
              let id = s.headerItems.first, let c = s.components[id], c["component"]?.string == "Text",
              let t = c["text"]?.string, !t.isEmpty else { return ref.title }
        return t
    }

    @ViewBuilder private func body(_ sid: String) -> some View {
        if let s = model.agentPages[sid]?.surface {
            if let blocks = s.surface.pageBlocks(aside: nil) ?? s.surface.headedBlocks() {
                PageSections(model: s, blocks: blocks) { cid, _, ctx in model.tapPage(sid, componentId: cid, context: ctx) }
                    .environment(\.lkInDialog, true)
            } else {
                SurfaceView(model: s, part: .all) { cid, _, ctx in model.tapPage(sid, componentId: cid, context: ctx) }
            }
        } else if let err = model.agentPages[sid]?.error {
            ErrorNote(text: err, detail: WindowModel.autoRetrying)       // 自己每 3 秒再取，不放「重试」
        } else {
            // 等的时候占一块固定的高，不缩成一小条再撑开（负责人 11-16）
            LoadingNote().frame(maxWidth: .infinity, minHeight: 220)
        }
    }
}

/// 页、弹窗还没取到时：转圈加「正在加载」
struct LoadingNote: View {
    @Environment(\.lk) private var p

    var body: some View {
        HStack(spacing: LKSpace.x2) {
            PanelSpinner().frame(width: 14, height: 14)
            Text("正在加载").font(LKFont.ui(LKType.small)).foregroundStyle(p.mutedFg)
        }
        .accessibilityElement(children: .combine)
    }
}

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
                    .buttonStyle(.plainPointer)
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
        .overlay(alignment: .topLeading) { WindowControls(model: model) }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(page.title)
        .id(page.id)
    }
}

/// 左上角：红黄绿（真窗口里是系统画的，截图时自己画）。最上面一行高 52，只放它们（带字的 logo 在侧栏左下角，11-12 定）；
/// 内容区顶上那一条（收起侧栏的按钮、右上角那一粒）和它们在一条线上。
/// 红黄绿的位置是螺壳.app 的窗口定的：它要把红黄绿放到这一行的正中（`lightsCenterY`）
struct WindowControls: View {
    /// 红黄绿的中心离窗口上沿多少：最上面一行（52）的正中。系统默认是 16（关闭按钮 14 pt 高、上沿在 9 pt），
    /// 螺壳.app 的窗口要照这个数把它们往下放
    static let lightsCenterY: CGFloat = 19
    /// 标题栏的高（负责人 11-14：52 太厚）
    static let height: CGFloat = 38
    /// 侧栏展开时的宽
    static let sidebarWidth: CGFloat = 220
    /// 收成一列图标时的宽（负责人 11-13：72 还是宽；红黄绿不再受它限制，放在顶上一行）
    static let sidebarMiniWidth: CGFloat = 60
    /// 收起侧栏的按钮离窗口左边至少多远：红黄绿（到 79）右边空 13
    static let toggleMinX: CGFloat = 92
    /// 红黄绿从哪到哪（`MainWindowChrome` 那样的窗口里系统放的位置：x 19–79）
    static let lightsLeading: CGFloat = 19
    static let lightsWidth: CGFloat = 60

    @ObservedObject var model: WindowModel
    @Environment(\.lkSnapshot) private var snapshot

    var body: some View {
        Group {
            if snapshot {
                // 和真窗口里系统画的一样大、一样的间隔（14 pt 的圆，隔 9；TitlebarTests 量过：x 19–79）
                HStack(spacing: 9) {
                    Circle().fill(Color.hex(0xE0605A)).frame(width: 14, height: 14)
                    Circle().fill(Color.hex(0xE3B341)).frame(width: 14, height: 14)
                    Circle().fill(Color.hex(0x5DB55B)).frame(width: 14, height: 14)
                }
            } else {
                Color.clear.frame(width: Self.lightsWidth, height: 14)
            }
        }
        .frame(height: Self.height)
        .padding(.leading, Self.lightsLeading)
        .padding(.top, Self.lightsCenterY - Self.height / 2)
    }
}

/// 收起、展开侧栏的按钮：在内容区顶上那一条的左端（原型 11-12：不和 logo 挤在一行）
struct SidebarToggle: View {
    @ObservedObject var model: WindowModel
    @Environment(\.lk) private var p

    var body: some View {
        Button { model.toggleSidebar() } label: {
            LKIcon("panel-left", size: 16).foregroundStyle(p.mutedFg)
                .frame(width: 30, height: 30).contentShape(Rectangle())
        }
        .buttonStyle(.plainPointer)
        .focusable(false)        // 窗口一打开不抢键盘焦点（不然带着一圈蓝框，按空格就收起侧栏）；⌃⌘S 照样能收
        .focusEffectDisabled()
        .help(model.sidebarMini ? "展开侧栏（⌃⌘S）" : "收起侧栏（⌃⌘S）")
        .accessibilityLabel(model.sidebarMini ? "展开侧栏" : "收起侧栏")
    }
}

struct Sidebar: View {
    /// 左下角 logo 的高（海螺的高）
    static let logoHeight: CGFloat = 20

    @ObservedObject var model: WindowModel
    @Environment(\.lk) private var p
    @Environment(\.accessibilityReduceMotion) private var reduce
    @Namespace private var ns

    var body: some View {
        let mini = model.sidebarMini
        VStack(alignment: .leading, spacing: 2) {

            NavRow(model: model, title: "今天", symbol: "inbox", page: .today, count: model.todayCount, urgent: model.hasUrgent, ns: ns)
            // 「活动」并进右边栏的「历史」（原型 11-12 定稿）：侧栏不再单列
            AppsRow(model: model, ns: ns)
            if model.appsExpanded {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(model.apps.filter { $0.id != .mem }) { a in
                        // 应用没在运行：行尾一个空心圈（和底部「连不上螺壳」同一个记号），收起时也看得出是谁停了
                        NavRow(model: model, title: a.tool.name, tool: a.tool, page: a.id, sub: true, ns: ns,
                               stopped: model.coreReachable && model.agentApp(for: a.id)?.running == false)
                    }
                    // 「应用」那一行是四格，这一行换成包裹：收成一列图标时两个不重复（负责人 11-13）
                    NavRow(model: model, title: "应用管理", symbol: "package", page: .apps, sub: true, ns: ns)
                }
                .padding(.leading, mini ? 0 : LKSpace.x4)
            }
            // 记忆不算应用，单独一个一级入口，在应用下面、设置上面（负责人 11-14）
            if model.apps.contains(where: { $0.id == .mem }) {
                NavRow(model: model, title: "记忆", symbol: "brain", page: .mem, ns: ns,   // 一级入口都用线条图标（负责人 11-15）
                       stopped: model.coreReachable && model.agentApp(for: .mem)?.running == false)
            }
            NavRow(model: model, title: "设置", symbol: "settings", page: .prefs, ns: ns)
            Spacer(minLength: 0)
            // 左下角一行：左边是带字的 logo（高 20），右边是状态（平时没有；有新版本、已暂停、连不上螺壳这类才出现）。
            // 收成图标时是粉底方块，有事时右上角一个小灯
            SidebarFoot(model: model)
                .padding(.top, LKSpace.x3)
                .padding(.bottom, LKSpace.x1)
        }
        .padding(.horizontal, mini ? LKSpace.x2 + 2 : LKSpace.x3)     // 收起时一格 40 宽（宽 60）
        .padding(.top, LKSpace.x3)
        .padding(.bottom, LKSpace.x3)
        .animation(reduce ? nil : Motion.move(Motion.pill), value: model.page)
        .animation(reduce ? nil : Motion.move(Motion.pill), value: model.appsExpanded)
    }
}

/// 侧栏选中的那一行的底：换页时滑过去
/// 侧栏一行：鼠标停上去底色深一层，不换手形（负责人 11-14：侧栏照系统的边栏，停上去变暗）。选中的那行有自己的底
struct NavButtonStyle: ButtonStyle {
    let selected: Bool
    func makeBody(configuration: Configuration) -> some View { NavButtonBody(configuration: configuration, selected: selected) }
}

private struct NavButtonBody: View {
    let configuration: ButtonStyle.Configuration
    let selected: Bool
    @Environment(\.lk) private var p
    @State private var hover = false

    var body: some View {
        configuration.label
            .background {
                if !selected && (hover || configuration.isPressed) {
                    RoundedRectangle(cornerRadius: p.controlRadius, style: .continuous).fill(p.fg.opacity(configuration.isPressed ? 0.10 : 0.06))
                }
            }
            .onHover { hover = $0 }
    }
}

struct NavPill: View {
    let ns: Namespace.ID
    @Environment(\.lk) private var p

    var body: some View {
        RoundedRectangle(cornerRadius: p.controlRadius, style: .continuous).fill(p.selection)
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
        [count.flatMap { $0 > 0 ? "\($0) 件待确认" : nil }, urgent ? "有急事" : nil].compactMap { $0 }.joined(separator: "，")
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
                    if mini && stopped { LKLight(state: .off, label: "未运行").background(Circle().fill(p.sidebar).padding(-2)).offset(x: 5, y: 4) }
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
                    if stopped { LKLight(state: .off, label: "未运行") }
                }
            }
            .padding(.horizontal, mini ? 0 : LKSpace.x2)
            .frame(maxWidth: .infinity, minHeight: 32, alignment: mini ? .center : .leading)
            .background { if on { NavPill(ns: ns) } }
            .contentShape(Rectangle())
        }
        .buttonStyle(NavButtonStyle(selected: on))
        .help(stopped ? "\(title)未运行" : mini ? (countText.isEmpty ? title : "\(title)：\(countText)") : (urgent ? countText : ""))
        .accessibilityLabel(title)
        .accessibilityValue(stopped ? "未运行" : countText)
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
                            ForEach(model.apps.filter { $0.id != .mem }.prefix(4)) { a in
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
        .buttonStyle(NavButtonStyle(selected: lit))
        .help(mini ? "应用" : model.appsNowName.map { "正在看\($0)" } ?? "")
        .accessibilityLabel("应用")
        .accessibilityValue(model.appsExpanded ? "已展开" : model.appsNowName.map { "已收起，正在看\($0)" } ?? "已收起")   // 状态不是动作：念「收起」像要去收起它
    }
}

/// 侧栏最底下一行：logo 在左，状态在右。状态平时没有；有事才出现，点了去该去的地方
struct SidebarFoot: View {
    @ObservedObject var model: WindowModel
    @Environment(\.lk) private var p
    @Environment(\.lkSnapshot) private var snapshot
    /// 有说明的状态：点了先弹出为什么、怎么办
    @State private var explaining = false

    private func tap(_ news: SidebarNews) {
        if news.detail != nil { explaining = true } else { news.open() }
    }

    var body: some View {
        let mini = model.sidebarMini
        let news = model.sidebarNews
        HStack(spacing: LKSpace.x2) {
            if mini {
                BrandBadge(size: Sidebar.logoHeight + 4)
                    .overlay(alignment: .topTrailing) {
                        if let news {
                            LKLight(state: news.light, label: news.text)
                                .background(Circle().fill(p.sidebar).padding(-2)).offset(x: 4, y: -4)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .center)
                    .contentShape(Rectangle())
                    .modifier(PointerIf(on: news != nil))
                    .onTapGesture { if let news { tap(news) } }
                    .help(news?.text ?? "")
                    .popover(isPresented: $explaining, arrowEdge: .trailing) { if let news { explanation(news) } }
            } else {
                BrandLockup(height: Sidebar.logoHeight)
                Spacer(minLength: LKSpace.x2)
                if let news {
                    Button { tap(news) } label: {
                        HStack(spacing: 6) {
                            LKLight(state: news.light, label: news.text)
                            Text(news.text).font(LKFont.ui(LKType.caption)).foregroundStyle(p.mutedFg).lineLimit(1)
                        }
                        .padding(.horizontal, LKSpace.x2)
                        .frame(height: 24)
                        .background(RoundedRectangle(cornerRadius: LKRadius.small, style: .continuous).fill(p.tint))
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plainPointer)
                    .help(news.help)
                    .accessibilityLabel(news.help)
                    .popover(isPresented: $explaining, arrowEdge: .top) { explanation(news) }
                }
            }
        }
        .padding(.leading, mini ? 0 : LKSpace.x2)
        .frame(minHeight: 28)
    }

    /// 为什么是这样、在哪里改：一两句话和一个按钮
    private func explanation(_ news: SidebarNews) -> some View {
        VStack(alignment: .leading, spacing: LKSpace.x3) {
            Text(news.text).font(LKFont.ui(LKType.body, .semibold))
            if let detail = news.detail {
                Text(detail).font(LKFont.ui(LKType.small)).foregroundStyle(p.mutedFg)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Button(news.actionLabel) { explaining = false; news.open() }.buttonStyle(LKButtonStyle())
        }
        .padding(LKSpace.x4)
        .frame(width: 260, alignment: .leading)
    }
}

/// 当前页。换页时旧的马上撤掉，新的各块错开升上来（`lkEntrance`）。不再让旧的淡出：两页叠在一起，
/// 字和卡片像墨水屏一样留残影（负责人 11-13）
struct PageView: View {
    @ObservedObject var model: WindowModel

    var body: some View {
        ZStack(alignment: .topLeading) {
            page
                .id(model.page)
                .transition(.identity)
                .environment(\.lkEntrance, model.entrance)
        }
    }

    @ViewBuilder private var page: some View {
        switch model.page {
        case .today: TodayPage(model: model)
        case .activity: ActivityPage(model: model)
        case .mail, .scan, .mem, .searchApp, .ime: AppPage(model: model, page: model.page)
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
                    .buttonStyle(.plainPointer)
            }
        }
        .font(LKFont.ui(LKType.small))
        .foregroundStyle(p.primaryFg)
        .padding(.horizontal, LKSpace.x4).padding(.vertical, LKSpace.x3 - 2)
        .background(RoundedRectangle(cornerRadius: p.controlRadius, style: .continuous).fill(p.primary)
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
                    Button("暂不") { model.closeSheet() }.buttonStyle(LKButtonStyle(kind: .text))
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
