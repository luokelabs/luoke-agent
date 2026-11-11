import AppKit
import LuokeA2UI
import LuokeA2UICore
import SwiftUI

/// 「今天」的几段，从上到下：急事、替你做了的（每件一行，最多三行）、要你决定、顺便看看
enum TodaySection: Hashable { case urgent, done, decide, later }

extension WindowModel {
    /// 有东西的段，按显示顺序；空的段整个不出现（要你决定是空的时候画一句「今天没什么要你操心的」）
    var todaySections: [TodaySection] {
        var s: [TodaySection] = []
        if !urgent.isEmpty { s.append(.urgent) }
        if !done.isEmpty { s.append(.done) }
        s.append(.decide)
        if !quiet.isEmpty { s.append(.later) }
        return s
    }
}

/// 「今天」：标准的卡片、紧凑的表，或者「一件件处理」
struct TodayPage: View {
    @ObservedObject var model: WindowModel
    @Namespace private var ns
    @Environment(\.accessibilityReduceMotion) private var reduce

    /// 「已经替你做了」先列几行；下面有「要你决定」时只列 2 行，免得把要决定的事推出第一屏（负责人 2026-11-09 定的方案 B）
    static let doneLimit = 3
    static let doneLimitDeciding = 2
    /// 宽窗口里在侧栏时先列几行
    static let doneLimitRail = 6
    /// 急事先列几叠（相近的放成一叠，见 `TodayStack`）：一个工具一下报几十件时，「要你决定」还在第一屏（#51）
    static let urgentLimit = 3

    static func visibleUrgent(_ items: [UrgentItem], all: Bool) -> (stacks: [[UrgentItem]], more: Int) {
        let stacks = TodayStack.spread(TodayStack.urgent(items))
        if all || stacks.count <= urgentLimit { return (stacks, 0) }
        return (Array(stacks.prefix(urgentLimit)), stacks.dropFirst(urgentLimit).reduce(0) { $0 + $1.count })
    }

    /// 简报里点到的卡片收在一叠里（不是露出来的第一张）：要展开的那一叠的编号；露着的是 nil
    static func stackToOpen(for id: String, in cards: [TodayCard]) -> String? {
        guard let stack = TodayStack.spread(TodayStack.cards(cards)).first(where: { $0.contains { $0.id == id } }),
              stack.count > 1, stack[0].id != id else { return nil }
        return "c:" + TodayStack.key(stack[0].tool, stack[0].kind, stack[0].title)
    }

    static func doneRows(deciding: Bool, railed: Bool) -> Int {
        railed ? doneLimitRail : deciding ? doneLimitDeciding : doneLimit
    }

    static func visibleDone(_ rows: [DoneRow], all: Bool, deciding: Bool = false, railed: Bool = false) -> (rows: [DoneRow], more: Int) {
        let limit = doneRows(deciding: deciding, railed: railed)
        if all || rows.count <= limit + 1 { return (rows, 0) }   // 只多 1 行就列出来：一行「还有 1 件」占的地方一样大
        return (Array(rows.prefix(limit)), rows.count - limit)
    }

    /// 卡片上的「撤销」「放回」：核心认撤销也只认写着这两个字的按钮（a2ui._reachable）
    static func undoButton(in s: Surface) -> (id: String, label: String, context: JSONValue)? {
        for id in s.reachable() {
            guard let c = s.components[id], c["component"]?.string == "Button",
                  let child = c["child"]?.string, let label = s.components[child]?["text"]?.string,
                  label == "撤销" || label == "放回", !s.opensURL(id), let a = try? s.action(id) else { continue }
            return (id, label, a.context)
        }
        return nil
    }

    var body: some View {
        ZStack(alignment: .topLeading) {
            if model.focus != nil {
                FocusPanel(model: model, ns: ns)
                    .transition(.asymmetric(insertion: reduce ? .opacity : .identity,
                                            removal: reduce ? .opacity : .opacity.combined(with: .scale(scale: 0.985))))
            } else if model.density == .compact {
                TodayCompact(model: model)
                    .transition(.asymmetric(insertion: .identity, removal: .opacity.animation(Motion.exit(Motion.focusFade, reduce: reduce))))
            } else {
                TodayStandard(model: model, ns: ns)
                    .transition(.asymmetric(insertion: .identity, removal: .opacity.animation(Motion.exit(Motion.focusFade, reduce: reduce))))
            }
        }
        .animation(model.focus == nil ? Motion.exit(Motion.focusExit, reduce: reduce) : Motion.drawer(Motion.focusGrow, reduce: reduce),
                   value: model.focus != nil)
    }
}

// MARK: 标准

/// 图标的位置（「今天」那一栏里），飞的时候用。键是「card:编号」「done:编号」
struct IconFrames: PreferenceKey {
    static let defaultValue: [String: CGRect] = [:]
    static func reduce(value: inout [String: CGRect], nextValue: () -> [String: CGRect]) {
        value.merge(nextValue()) { $1 }
    }
}

extension View {
    func lkIconFrame(_ key: String) -> some View {
        background(GeometryReader { g in Color.clear.preference(key: IconFrames.self, value: [key: g.frame(in: .named(TodayStandard.space))]) })
    }

    /// 第一张卡片的底：进「一件件处理」时长成面板
    @ViewBuilder func lkHero(_ ns: Namespace.ID?) -> some View {
        if let ns { matchedGeometryEffect(id: "focus-surface", in: ns) } else { self }
    }
}

/// 答完一件：它的图标从卡片飞进「已经替你做了」新的那一行；撤销时沿原路飞回
struct Flight: Equatable {
    let tool: ToolIcon
    let cardID: String
    let rowID: String
    /// 卡片上的图标
    let from: CGRect
    /// 那一行的图标
    let to: CGRect
    /// 0 在卡片上，1 在那一行上
    var progress: Double
}

struct TodayStandard: View {
    static let space = "today"

    struct Ids: Equatable {
        var cards: [String]
        var done: [String]
    }

    /// 还等着另一头画出来的一程（去的那一行、回的那张卡片还没有位置）
    private struct Pending {
        let tool: ToolIcon
        let cardID: String
        let rowID: String
        let from: CGRect?
        let to: CGRect?
    }

    @ObservedObject var model: WindowModel
    let ns: Namespace.ID
    @Environment(\.lk) private var p
    @Environment(\.lkSnapshot) private var snapshot
    @Environment(\.accessibilityReduceMotion) private var reduce
    @Environment(\.lkLayout) private var layout
    /// 点了「还有 n 件」
    @State private var allDone = false
    /// 展开了的那几叠「要你决定」（相近的卡片放成一叠，见 `TodayStack`）；急事的在 `model.urgentOpenStacks`
    @State private var openStacks: Set<String> = []

    private func toggle(_ key: String) {
        withAnimation(Motion.enter(Motion.reflow, reduce: reduce)) {
            if openStacks.contains(key) { openStacks.remove(key) } else { openStacks.insert(key) }
        }
    }
    /// 第一张卡片能长成面板（刚从面板回来的那一下不能）
    @State private var heroReady: Bool
    @State private var known: Ids
    @State private var frames: [String: CGRect] = [:]
    @State private var flight: Flight?
    @State private var pending: Pending?
    /// 有东西正飞进去的图标位
    @State private var hidden: Set<String> = []
    /// 点了简报里的词：那张卡片亮一圈
    @State private var ring: (id: String, token: Int)?

    init(model: WindowModel, ns: Namespace.ID) {
        _model = ObservedObject(wrappedValue: model)
        self.ns = ns
        _heroReady = State(initialValue: model.entrance != .fromFocus)
        _known = State(initialValue: Ids(cards: model.cards.map(\.id), done: model.done.map(\.id)))
    }

    private var ids: Ids { Ids(cards: model.cards.map(\.id), done: model.done.map(\.id)) }
    private var moving: Bool { !reduce && !snapshot }

    var body: some View {
        // 宽窗口：标题横跨两栏；侧栏只放已经替你做了，别的在主栏（顺便看看的卡片一封封带下拉，放侧栏太挤；docs/主窗口.md「宽窗口」）
        let railed = model.hasRail(layout)
        let all = model.todaySections
        let side: Set<TodaySection> = railed ? [.done] : []
        let main = all.filter { !side.contains($0) }
        ScrollViewReader { proxy in
            page(railed: railed, all: all, main: main, side: side, proxy: proxy)
                .onChange(of: model.urgentJump) { _, j in if let j { TodayCompact.scroll(to: j, model: model, proxy: proxy, reduce: reduce) } }
                .onAppear { if let j = model.urgentJump { TodayCompact.scroll(to: j, model: model, proxy: proxy, reduce: reduce) } }
        }
        .onPreferenceChange(IconFrames.self) { f in
            frames = f
            launchPending()
        }
        .onChange(of: ids) { old, new in changed(old, new) }
        .onAppear {
            guard !heroReady else { return }
            DispatchQueue.main.asyncAfter(deadline: .now() + Motion.focusGrow) { heroReady = true }
        }
    }

    /// 整页（`body` 包上滚动的处理）
    private func page(railed: Bool, all: [TodaySection], main: [TodaySection], side: Set<TodaySection>, proxy: ScrollViewProxy) -> some View {
        PageScroll(railed: railed) {
            VStack(alignment: .leading, spacing: 0) {
                header.lkEnter(0)
                if railed {
                    RailSplit {
                        top(proxy)
                        sections(main, from: 0, railed: true)
                    } rail: {
                        // 包成一块再挪：直接加在 ForEach 上会让段标题和下面的卡片各挪各的、叠在一起
                        VStack(alignment: .leading, spacing: 0) {
                            sections(all.filter { side.contains($0) }, from: main.count, railed: true)
                        }
                        .padding(.top, mainLeadsWithTitle ? 0 : -LKSpace.x7)
                    }
                } else {
                    top(proxy)
                    sections(all, from: 0, railed: false)
                }
            }
            .coordinateSpace(name: Self.space)
            .overlay(alignment: .topLeading) {
                if let f = flight {
                    FlyingIcon(tool: f.tool, from: f.from, to: f.to, progress: f.progress).allowsHitTesting(false)
                }
            }
            .animation(moving ? Motion.enter(Motion.reflow, delay: Motion.reflowDelay) : nil, value: ids)
            .animation(moving ? Motion.enter(Motion.briefRoom) : nil, value: model.briefNote != nil)
        }
    }

    // MARK: 几块

    /// 主栏一上来是段标题（「要你决定」，上面空 28）：侧栏的段标题和它齐平；
    /// 主栏一上来是卡片（急事、连不上、核心的几句、简报）：侧栏的段标题提上去，和那张卡片的顶齐平
    private var mainLeadsWithTitle: Bool {
        model.coreReachable && model.hostNotice == nil && model.notices.isEmpty && !model.notificationsNotAsked
            && model.briefNote == nil && model.urgent.isEmpty && !model.cards.isEmpty
    }

    /// 标题下面、各段上面：连不上螺壳、核心的几句、简报
    @ViewBuilder private func top(_ proxy: ScrollViewProxy) -> some View {
        if !model.coreReachable { offlineNote.lkEnter(0) }
        // 核心的几句（某个应用没在运行……）放在标题下面、和「连不上螺壳」同一个位置：下面少了谁的事，先说
        notices.lkEnter(0)
        if let note = model.briefNote {
            BriefNoteView(note: note, model: model) { jump(to: $0, proxy: proxy) }
                .transition(.opacity.animation(Motion.enter(Motion.briefClose, reduce: reduce)))
        }
    }

    /// 几段按顺序画。from：前面已经有几段（侧栏的接着主栏错开升上来）
    @ViewBuilder private func sections(_ list: [TodaySection], from: Int, railed: Bool) -> some View {
        ForEach(Array(list.enumerated()), id: \.element) { n, section in
            let i = from + n
            switch section {
            case .urgent: urgentBlock(i)
            case .done: doneBlock(i, railed: railed)
            case .decide: decideBlock(i)
            case .later: laterBlock(i)
            }
        }
    }

    private var header: some View {
        PageHeader(title: "今天", note: model.dateLine) {
            Button { model.enterFocus() } label: {
                HStack(spacing: LKSpace.x1 + 2) {
                    Text("一件件处理")
                    if !model.cards.isEmpty { LKCount(value: model.cards.count, delay: Motion.counterAt).foregroundStyle(p.mutedFg) }
                }
            }
            .buttonStyle(LKButtonStyle())
            .disabled(model.cards.isEmpty)
            .help(model.cards.isEmpty ? "现在没有要你决定的事" : "「要你决定」的 \(model.cards.count) 件一次只摆一件：⏎ 答，↓ 跳过，Esc 回来（急事在上面直接处理）")
        }
    }

    /// 螺壳没响应：下面的卡片是上次拿到的。窗口每 2 秒自己重连，所以不放「再试一次」；按钮照常能点，做不成会提示。
    /// 第二行说对用户的影响，不描述界面自己会怎样（「点了会提示你」）
    private var offlineNote: some View {
        let seen = model.lastSeen.map { "，下面是 \(model.seenText($0)) 的内容" } ?? ""
        return ErrorNote(text: "\(WindowModel.offlineShort)\(seen)。",
                         detail: model.offlineLong ? WindowModel.offlineAdvice : "这些卡片可能已经过时，现在点按钮办不成。")
            .lkCard()
            .padding(.bottom, LKSpace.x4)
    }

    /// 急事：段标题「急事 N」，下面是白底的卡片（#65：和别的卡片一样，只有工具写成 danger 的按钮是浅红底红字）
    @ViewBuilder private func urgentBlock(_ i: Int) -> some View {
        // 和「要你决定 N」一样数件数：一叠里几件就算几件，收在「还有 N 件急事」里的也算
        LKSection(title: "急事", count: TodayPage.urgentCount(model.urgent), countDelay: Motion.counterAt).lkEnter(1 + i * 2)
        urgentCards.lkEnter(2 + i * 2)
    }

    private var urgentCards: some View {
        let shown = TodayPage.visibleUrgent(model.urgent, all: model.urgentAll)
        return VStack(spacing: LKSpace.x2) {
            ForEach(shown.stacks, id: \.first!.id) { stack in
                let key = TodayStack.key(stack[0].tool, stack[0].kind, stack[0].title)   // 按这一叠是哪一类记：处理掉第一张也不自己收起
                let open = model.urgentOpenStacks.contains(key)
                ForEach(open ? stack : [stack[0]]) { u in
                    UrgentBanner(item: u, model: model).stackEdge(open || stack.count == 1 ? 0 : stack.count - 1, tint: nil)
                        .id("urgent:\(u.id)")   // 菜单栏里点了这一叠滚到这里
                }
                if stack.count > 1 {
                    StackToggle(more: stack.count - 1, unit: TodayStack.unit(stack[0].tool), open: open, tint: p.danger,
                                what: TodayStack.what(stack[0].title, stack.count - 1, unit: TodayStack.unit(stack[0].tool))) {
                        withAnimation(Motion.enter(Motion.reflow, reduce: reduce)) {
                            if open { model.urgentOpenStacks.remove(key) } else { model.urgentOpenStacks.insert(key) }
                        }
                    }
                    .padding(.top, -6).padding(.bottom, 6)   // 贴着上面那一摞，离下一张远一点
                }
            }
            if shown.more > 0 {
                Button { model.urgentAll = true } label: {
                    HStack(spacing: LKSpace.x2) {
                        LKIcon("chevron-down", size: 13)
                        Text("还有 \(shown.more) 件急事")
                        Spacer(minLength: 0)
                    }
                    .font(LKFont.ui(LKType.small))
                    .foregroundStyle(p.danger)
                    .padding(.horizontal, LKSpace.x4)
                    .frame(minHeight: LKHeight.row)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .background(RoundedRectangle(cornerRadius: LKRadius.card, style: .continuous).fill(p.danger.opacity(p.dark ? 0.16 : 0.07)))
            }
        }
    }

    @ViewBuilder private func doneBlock(_ i: Int, railed: Bool) -> some View {
        let rows = DoneRow.merged(model.done)   // 同一组的合成一行（工具协议 §4 `doneGroup`）
        let shown = TodayPage.visibleDone(rows, all: allDone, deciding: !model.cards.isEmpty, railed: railed)
        LKSection(title: "已经替你做了", count: rows.count, countDelay: Motion.counterAt).lkEnter(1 + i * 2)
        VStack(spacing: 0) {
            ForEach(Array(shown.rows.enumerated()), id: \.element.id) { n, d in
                let fresh = moving && !known.done.contains(d.id)
                DoneLine(row: d, model: model, open: model.openDone.contains(d.id), first: n == 0, fresh: fresh,
                         iconHidden: fresh || hidden.contains("done:\(d.id)")) {
                    if model.openDone.contains(d.id) { model.openDone.remove(d.id) } else { model.openDone.insert(d.id) }
                }
                .transition(.asymmetric(insertion: .identity, removal: .opacity.animation(Motion.enter(Motion.undoRow, reduce: reduce))))
            }
            if shown.more > 0 || (allDone && rows.count > TodayPage.doneRows(deciding: !model.cards.isEmpty, railed: railed) + 1) {
                Button { allDone.toggle() } label: {   // 点开以后同一个位置写「收起」：做了的只是看一眼的记录，不该一直占着「要你决定」上面
                    HStack(spacing: LKSpace.x3) {   // 和摞下面的开关一个画法（⌄ 在字前面）；在卡片里对齐卡片的列：⌄ 在图标列中间
                        LKIcon(allDone ? "chevron-up" : "chevron-down", size: 13).frame(width: 28)
                        Text(allDone ? "收起" : "还有 \(shown.more) 件")
                        Spacer(minLength: 0)
                    }
                    .font(LKFont.ui(LKType.small)).foregroundStyle(p.mutedFg)
                    .frame(minHeight: LKHeight.row)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .padding(.horizontal, LKSpace.x5)
                .overlay(alignment: .top) { Rectangle().fill(p.border).frame(height: 1).padding(.horizontal, LKSpace.x5) }
            }
        }
        .background(CardSurface())
        .lkEnter(2 + i * 2)
    }

    @ViewBuilder private func decideBlock(_ i: Int) -> some View {
        // 没有的时候不写 0：数据还没到时 0 读着像「没事」，空的时候下面那句已经说了
        // 空的时候：整页只剩这一段（在准备、今天没事）才画状态那一句或插画，也不写段标题（会读成「急事不会来」、和那句重复）。
        // 页上还有别的段（有急事、有做了的）时整段不画：插画和「今天没什么要你操心的」会和上面的急事打架
        let alone = model.cards.isEmpty && model.urgent.isEmpty && model.done.isEmpty && model.quiet.isEmpty
        if !model.cards.isEmpty {
            LKSection(title: "要你决定", count: model.cards.count, countDelay: Motion.counterAt).lkEnter(1 + i * 2)
                .id(BriefNoteView.decideTarget)   // 简报里点「等」滚到这里
            let picks = model.categoriesToPick
            if !picks.isEmpty { CategoryPicks(model: model, picks: picks).lkEnter(2 + i * 2) }
        }
        if model.cards.isEmpty && !alone {
            EmptyView()
        } else if model.cards.isEmpty && model.waitingForFeed && model.coreReachable {   // 连不上时顶上那张卡说清楚了，不再一直写「正在准备…」
            // 核心的第一份数据还没到（刚打开、模型在准备）：说在准备，别像什么都没有
            HStack(alignment: .top, spacing: LKSpace.x3) {
                LKBreathing().padding(.top, 5)
                VStack(alignment: .leading, spacing: 2) {
                    Text("正在准备…").font(LKFont.ui(LKType.body))
                    Text(model.engineReady ? "在问各个应用今天有什么事，马上就好。" : "螺壳在准备，好了以后这里会列出今天的事。")
                        .font(LKFont.ui(LKType.small)).foregroundStyle(p.mutedFg)
                }
            }
            .padding(.vertical, LKSpace.x3)
            .lkEnter(2 + i * 2)
        } else if model.cards.isEmpty {
            HStack(spacing: LKSpace.x4) {
                Mascot(width: 56)
                Text("今天没什么要你操心的。").font(LKFont.ui(LKType.body)).foregroundStyle(p.mutedFg)
            }
            .padding(.vertical, LKSpace.x3)
            .lkEnter(2 + i * 2)
        } else {
            VStack(spacing: LKSpace.x3) {
                ForEach(TodayStack.spread(TodayStack.cards(model.cards)), id: \.first!.id) { stack in
                    let key = "c:" + TodayStack.key(stack[0].tool, stack[0].kind, stack[0].title)
                    let open = openStacks.contains(key)
                    ForEach(open ? stack : [stack[0]]) { c in
                        let hero = heroReady && !reduce && c.id == model.cards.first?.id
                        let back = moving && !known.cards.contains(c.id)
                        CardFrame(card: c, model: model, iconHidden: back || hidden.contains("card:\(c.id)"), hero: hero ? ns : nil)
                            .overlay {
                                if let r = ring, r.id == c.id { CardRing().id(r.token) }
                            }
                            .stackEdge(open || stack.count == 1 ? 0 : stack.count - 1, tint: nil)
                            .id("card:\(c.id)")
                            .transition(.asymmetric(insertion: Motion.cardBack(reduce: reduce || snapshot),
                                                    removal: Motion.cardLeave(reduce: reduce || snapshot)))
                    }
                    if stack.count > 1 {
                        StackToggle(more: stack.count - 1, unit: TodayStack.unit(stack[0].tool), open: open, tint: nil,
                                    what: stack[0].title.flatMap { TodayStack.what($0, stack.count - 1, unit: TodayStack.unit(stack[0].tool)) }) { toggle(key) }
                            .padding(.top, -8).padding(.bottom, 8)   // 贴着上面那一摞，离下一张远一点
                    }
                }
            }
            .lkEnter(2 + i * 2)
        }
    }

    @ViewBuilder private func laterBlock(_ i: Int) -> some View {
        LKSection(title: "顺便看看", count: model.quiet.count).lkEnter(1 + i * 2)
        // 工具写的卡片一张一张分开（一个邮箱一张，里面分几块）；窗口自己的行（有新版本这类）照旧合在一组里
        let cardsRows = model.quiet.filter { $0.surface != nil }
        let plain = model.quiet.filter { $0.surface == nil }
        VStack(spacing: LKSpace.x3) {
            ForEach(cardsRows) { q in
                if let s = q.surface {
                    // 和别的卡片同一个图标列（28）、同样的内边距：正文起点、右边线都对齐
                    HStack(alignment: .top, spacing: LKSpace.x3) {
                        AppIcon(tool: q.tool, size: 28)
                        SurfaceView(model: s) { cid, _, ctx in model.tapSurface(q.id, componentId: cid, context: ctx) }
                            .padding(.top, LKSpace.x1)
                    }
                    .padding(LKInsets.card)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(CardSurface())
                }
            }
            if !plain.isEmpty {
                LKGroup {
                    ForEach(Array(plain.enumerated()), id: \.element.id) { n, q in
                        HStack(spacing: LKSpace.x3) {
                            AppIcon(tool: q.tool, size: 20)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(q.text)
                                if let s = q.sub { Text(s).font(LKFont.ui(LKType.small)).foregroundStyle(p.mutedFg) }
                            }
                            Spacer()
                            if let a = q.action {
                                Button(a) { model.upgrade(q.tool) }.buttonStyle(LKButtonStyle())
                            } else {
                                Button { model.show("这里会打开\(q.tool.name)自己的窗口") } label: { LKIcon("chevron-right") }
                                    .buttonStyle(LKButtonStyle(kind: .text)).accessibilityLabel("看看")
                            }
                        }
                        .lkRow(first: n == 0)
                    }
                }
            }
        }
        .lkEnter(2 + i * 2)
    }

    @ViewBuilder private var notices: some View {
        let notices = (model.hostNotice.map { [$0] } ?? []) + model.notices
        if !notices.isEmpty || model.notificationsNotAsked {
            // 核心的几句和出错卡一样的画法：提示图标 + 正文色的一句。核心自己会再去读那个应用，回来了这句就没了，所以不放按钮
            VStack(alignment: .leading, spacing: LKSpace.x2) {
                ForEach(notices, id: \.self) { n in ErrorNote(text: n) }
                if model.notificationsNotAsked {
                    HStack(spacing: LKSpace.x2) {
                        Text("通知还没打开，简报和急事到不了你。").font(LKFont.ui(LKType.small)).foregroundStyle(p.mutedFg)
                        Button("打开通知") { model.host?.askNotifications() }.buttonStyle(LKButtonStyle())
                    }
                }
            }
            .lkCard()
            .padding(.bottom, LKSpace.x4)
        }
    }

    // MARK: 简报里点了一个词

    private func jump(to id: String, proxy: ScrollViewProxy) {
        if id == BriefNoteView.decideTarget {   // 简报里的「等」：滚到「要你决定」那一段
            withAnimation(Motion.enter(Motion.reflow, reduce: reduce)) { proxy.scrollTo(id, anchor: .top) }
            return
        }
        guard model.cards.contains(where: { $0.id == id }) else { return }
        // 收在一叠里的那张没画出来：先展开那一叠，下一拍再滚过去（不然点了没反应）
        if let key = TodayPage.stackToOpen(for: id, in: model.cards) {
            openStacks.insert(key)
            DispatchQueue.main.async { withAnimation(Motion.enter(Motion.reflow, reduce: reduce)) { proxy.scrollTo("card:\(id)", anchor: .center) } }
        } else {
            withAnimation(Motion.enter(Motion.reflow, reduce: reduce)) { proxy.scrollTo("card:\(id)", anchor: .center) }
        }
        let token = (ring?.token ?? 0) + 1
        DispatchQueue.main.asyncAfter(deadline: .now() + (reduce ? 0 : Motion.reflow)) { ring = (id, token) }
        DispatchQueue.main.asyncAfter(deadline: .now() + (reduce ? 0 : Motion.reflow) + Motion.ring) {
            if ring?.token == token { ring = nil }
        }
    }

    // MARK: 飞

    /// 「今天」变了：一张卡片走了、替你做了多一行，就是答了；反过来就是撤销了
    private func changed(_ old: Ids, _ new: Ids) {
        defer { known = new }
        guard moving else { return }
        let goneCards = old.cards.filter { !new.cards.contains($0) }
        let addedDone = new.done.filter { !old.done.contains($0) }
        let goneDone = old.done.filter { !new.done.contains($0) }
        let addedCards = new.cards.filter { !old.cards.contains($0) }
        if goneCards.count == 1, let row = addedDone.first(where: { $0 == goneCards[0] }) ?? (addedDone.count == 1 ? addedDone[0] : nil) {
            let card = goneCards[0]
            let shown = TodayPage.visibleDone(DoneRow.merged(model.done), all: allDone, deciding: !model.cards.isEmpty,
                                              railed: model.hasRail(layout)).rows.map(\.id)
            guard shown.contains(row), let from = frames["card:\(card)"],
                  let tool = model.done.first(where: { $0.id == row })?.tool else { return }
            hidden.insert("done:\(row)")
            pending = Pending(tool: tool, cardID: card, rowID: row, from: from, to: nil)
            launchPending()
            giveUp(card: card, row: row)
        } else if goneDone.count == 1, addedCards.count == 1 {
            let card = addedCards[0], row = goneDone[0]
            if let f = flight, f.cardID == card, f.rowID == row {
                hidden.insert("card:\(card)")
                hidden.remove("done:\(row)")
                run(f, to: 0)                                   // 还在路上：从现在的位置倒回去
            } else if let to = frames["done:\(row)"], let tool = model.cards.first(where: { $0.id == card })?.tool {
                hidden.insert("card:\(card)")
                pending = Pending(tool: tool, cardID: card, rowID: row, from: nil, to: to)
                launchPending()
                giveUp(card: card, row: row)
            }
        }
    }

    /// 另一头一直没画出来：不飞了，图标照常
    private func giveUp(card: String, row: String) {
        DispatchQueue.main.asyncAfter(deadline: .now() + Motion.flight) {
            guard let pf = pending, pf.cardID == card, pf.rowID == row else { return }
            pending = nil
            hidden.remove("done:\(row)")
            hidden.remove("card:\(card)")
        }
    }

    /// 另一头有位置了就起飞
    private func launchPending() {
        guard let pf = pending else { return }
        if let from = pf.from {
            guard let to = frames["done:\(pf.rowID)"] else { return }
            pending = nil
            start(Flight(tool: pf.tool, cardID: pf.cardID, rowID: pf.rowID, from: from, to: to, progress: 0), to: 1)
        } else if let to = pf.to {
            guard let from = frames["card:\(pf.cardID)"] else { return }
            pending = nil
            start(Flight(tool: pf.tool, cardID: pf.cardID, rowID: pf.rowID, from: from, to: to, progress: 1), to: 0)
        }
    }

    private func start(_ f: Flight, to end: Double) {
        var t = Transaction()
        t.disablesAnimations = true
        withTransaction(t) { flight = f }
        DispatchQueue.main.async { run(f, to: end) }
    }

    private func run(_ f: Flight, to end: Double) {
        withAnimation(.linear(duration: Motion.flight)) {
            flight?.progress = end
        } completion: {
            guard let now = flight, now.cardID == f.cardID, now.rowID == f.rowID, now.progress == end else { return }
            hidden.remove(end == 1 ? "done:\(f.rowID)" : "card:\(f.cardID)")
            flight = nil
        }
    }
}

/// 点了简报里的词：那张卡片外面亮一圈，慢慢淡掉
struct CardRing: View {
    @Environment(\.lk) private var p
    @Environment(\.accessibilityReduceMotion) private var reduce
    @State private var shown = false

    var body: some View {
        RoundedRectangle(cornerRadius: LKRadius.card + 3, style: .continuous)
            .strokeBorder(p.brandText.opacity(0.45), lineWidth: 3)
            .padding(-3)
            .opacity(shown ? 1 : 0)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
            .onAppear {
                withAnimation(.linear(duration: reduce ? Motion.reduced : Motion.ring * 0.2)) { shown = true } completion: {
                    withAnimation(Motion.enter(reduce ? Motion.reduced : Motion.ring * 0.8, reduce: reduce)) { shown = false }
                }
            }
    }
}

// MARK: 简报

/// 「今天」最上面的简报：替你做了的、急事、要你决定的（点了跳到那张卡片）
struct BriefNoteView: View {
    /// `jump` 收到它就是跳到「要你决定」那一段（简报里的「等」）
    static let decideTarget = "section:decide"
    let note: BriefNote
    @ObservedObject var model: WindowModel
    let jump: (String) -> Void
    @Environment(\.lk) private var p
    @Environment(\.lkSnapshot) private var snapshot
    @Environment(\.accessibilityReduceMotion) private var reduce

    var body: some View {
        VStack(alignment: .leading, spacing: LKSpace.x1 + 2) {
            HStack(spacing: LKSpace.x2) {
                BrandBadge(size: 16)
                Text("\(note.title) · \(note.time)").font(LKFont.ui(LKType.caption)).foregroundStyle(p.mutedFg)
                Spacer(minLength: 0)
                Button("收起") { model.closeBrief() }.buttonStyle(LKButtonStyle(kind: .text, size: .small))
            }
            .lkAppear(!snapshot, Motion.enter(Motion.briefHead, delay: Motion.briefHeadAt, reduce: reduce))
            Text(Self.text(note, open: Set(model.cards.map(\.id)), p: p))
                .font(LKFont.ui(LKType.lead))
                .lineSpacing(LKSpace.x1 + 2)
                .tint(p.fg)
                .lineLimit(Self.maxLines)   // 写法已经按两行挑过（`text`），这里兜底
                .fixedSize(horizontal: false, vertical: true)
                .environment(\.openURL, OpenURLAction { url in
                    if url.host == "decide" { jump(BriefNoteView.decideTarget) }   // 「等」：跳到「要你决定」
                    else if let i = Int(url.lastPathComponent), note.pending.indices.contains(i) { jump(note.pending[i].id) }
                    return .handled
                })
                .lkAppear(!snapshot, dy: 10, Motion.soft(Motion.brief, delay: Motion.briefAt, reduce: reduce))
        }
        .padding(.bottom, LKSpace.x5)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(note.title)
    }

    /// 简报那段话最多几行（#51：要决定的有 40 件时整段占掉半屏）
    static let maxLines = 2
    /// 按这么宽量几行：最窄的时候（860 的窗口、侧栏展开）「今天」那一栏放字的宽度
    static let measureWidth: CGFloat = 590
    /// 要你决定的先列几件，后面写「等」（点了跳到「要你决定」）
    static let pendingListed = 3

    /// 那段话里写多细：替你做了的列不列、急事写不写名字、要你决定的列几件
    struct Detail: Equatable {
        var doneList = true
        var urgentName = true
        var pending = BriefNoteView.pendingListed
    }

    /// 由细到粗：放得进两行的第一种
    static let details = [Detail(), Detail(doneList: false), Detail(doneList: false, pending: 2), Detail(doneList: false, pending: 1),
                          Detail(doneList: false, urgentName: false, pending: 1)]

    /// 那段话：替你做了的一句、急事（红字）、要你决定的前几件（能点；答了的划掉），再多的写「等」，点了跳到「要你决定」。
    /// 最多两行：放不下就由细到粗换写法（`details`）
    static func text(_ note: BriefNote, open: Set<String>, p: Palette) -> AttributedString {
        for d in details.dropLast() {
            let t = text(note, open: open, p: p, detail: d)
            if lines(t) <= maxLines { return t }
        }
        return text(note, open: open, p: p, detail: details.last!)
    }

    /// 要你决定的列哪几件：标题一样的只列一次（同一类一下来很多件时不写成「A、A、A」）；给出在 `pending` 里的位置
    static func listed(_ pending: [BriefNote.Pending], limit: Int) -> [Int] {
        var seen = Set<String>(), out: [Int] = []
        for (i, item) in pending.enumerated() where out.count < limit && seen.insert(BriefNote.phrase(item.title)).inserted {
            out.append(i)
        }
        return out
    }

    static func text(_ note: BriefNote, open: Set<String>, p: Palette, detail d: Detail) -> AttributedString {
        var out = AttributedString()
        if !note.done.isEmpty {
            out += AttributedString(d.doneList
                ? "替你做了 \(note.done.count) 件：" + note.done.prefix(3).map(BriefNote.phrase).joined(separator: "、") + (note.done.count > 3 ? "等" : "") + "。"
                : "替你做了 \(note.done.count) 件。")
        }
        if let u = note.urgent.first {
            var a = AttributedString(d.urgentName ? BriefNote.phrase(u) + (note.urgent.count > 1 ? "等 \(note.urgent.count) 件急事" : "")
                                                  : "\(note.urgent.count) 件急事")
            a.foregroundColor = p.danger
            a.font = LKFont.ui(LKType.lead, .semibold)
            out += a
            out += AttributedString(note.urgent.count > 1 ? "，先看这些。" : "，先看这件。")
        }
        if note.pending.isEmpty {
            out += AttributedString("要你决定的都处理完了。")
        } else {
            out += AttributedString("还有 \(note.pending.count) 件等你：")
            let shown = listed(note.pending, limit: d.pending)
            for (n, i) in shown.enumerated() {
                let item = note.pending[i]
                if n > 0 { out += AttributedString("、") }
                var a = AttributedString(BriefNote.phrase(item.title))
                if open.contains(item.id) {
                    a.link = URL(string: "luoke-brief://card/\(i)")
                    a.underlineStyle = Text.LineStyle(pattern: .solid, color: p.brandText.opacity(0.45))
                } else {
                    a.strikethroughStyle = Text.LineStyle.single
                    a.foregroundColor = p.fg.opacity(0.5)
                }
                out += a
            }
            if note.pending.count > shown.count {
                // 没列出来的：「等」能点，跳到「要你决定」那一段
                out += AttributedString(" ")
                var more = AttributedString("等")
                more.link = URL(string: "luoke-brief://decide")
                more.underlineStyle = Text.LineStyle(pattern: .solid, color: p.brandText.opacity(0.45))
                out += more
            }
            out += AttributedString("。")
        }
        return out
    }

    /// 这段话在 `measureWidth` 宽里折成几行（字号、行距和画出来的一样；急事那段是半粗，整段按半粗量，宁多勿少）
    static func lines(_ t: AttributedString) -> Int {
        let s = String(t.characters)
        let para = NSMutableParagraphStyle()
        para.lineSpacing = LKSpace.x1 + 2
        let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: LKType.lead, weight: .semibold), .paragraphStyle: para]
        func height(_ x: String) -> CGFloat {
            NSAttributedString(string: x, attributes: attrs)
                .boundingRect(with: NSSize(width: measureWidth, height: 100_000), options: [.usesLineFragmentOrigin, .usesFontLeading]).height
        }
        let one = height("螺壳 Ag")
        return Int(((height(s) + para.lineSpacing) / (one + para.lineSpacing)).rounded())
    }
}

// MARK: 行和卡片

/// 「已经替你做了」的一行：做了什么、几点、撤销或放回。接上核心时点这一行展开成工具写的那张卡片
/// （和急事横幅一样，卡片收起来就是这一行）。新的一行：图标飞进来，字错开着出现
struct DoneLine: View {
    let row: DoneRow
    @ObservedObject var model: WindowModel
    let open: Bool
    var first = true
    var fresh = false
    var iconHidden = false
    let toggle: () -> Void
    @Environment(\.lk) private var p
    @Environment(\.accessibilityReduceMotion) private var reduce

    private func part(_ n: Int) -> Animation {
        Motion.enter(Motion.rowParts, delay: Motion.rowPartsAt + Motion.stagger * Double(n), reduce: reduce)
    }

    /// 展开有没有用：工具的答复比这一行多出东西（别的字、别的按钮、要填的）才能展开；只有这一句加「撤销」的不画 ›
    private var expandable: Bool {
        guard row.members.count <= 1, let s = row.surface else { return false }
        let d = SurfaceDigest(s.surface)
        return !d.detail.isEmpty || d.hasInputs || d.actions.contains { $0.label != "撤销" && $0.label != "放回" }
    }

    @State private var hover = false

    var body: some View {
        VStack(alignment: .leading, spacing: LKSpace.x3) {
            HStack(spacing: LKSpace.x3) {
                AppIcon(tool: row.tool, size: 20)
                    .opacity(iconHidden ? 0 : 1)
                    .lkIconFrame("done:\(row.id)")
                    .frame(width: 28)   // 和卡片同一个 28pt 图标列：字从卡片正文的起点开始
                // 一行的字不带句号（工具答的那句常以「。」结尾）：这一段统一，› 跟在字后面读成一个能点开的整体
                Text(row.text.hasSuffix("。") ? String(row.text.dropLast()) : row.text).lineLimit(1).truncationMode(.tail)
                    .strikethrough(row.undone).foregroundStyle(row.undone ? p.mutedFg : p.fg)
                    .lkAppear(fresh, dx: -6, part(0))
                // 字后面的 › 是「原地展开」（展开后朝下）；行尾的 › 是「进下一页」（应用页「这个应用」）。点这一行展开工具答复的整张卡片
                if let b = row.group?.badge { LKBadge(text: b, kind: .info).lineLimit(1).fixedSize() }   // 哪个邮箱
                if expandable {
                    LKIcon("chevron-right", size: 12).foregroundStyle(p.mutedFg)
                        .rotationEffect(.degrees(open ? 90 : 0))
                        .accessibilityHidden(true)
                }
                Spacer(minLength: LKSpace.x2)
                // 「撤销」是「一句话 + 按钮」里的按钮：次要按钮，贴内容的右边线；时间在最右边的日期列，和上下卡片的日期对齐
                Group {
                    if row.members.count > 1, let first = row.members.compactMap({ $0.surface.flatMap { TodayPage.undoButton(in: $0.surface) } }).first {
                        // 合成的一行：一次撤销，把合进来的每一张卡片的撤销都点
                        Button(first.label) {
                            for m in row.members {
                                guard let s = m.surface, let u = TodayPage.undoButton(in: s.surface) else { continue }
                                model.tapSurface(m.id, componentId: u.id, context: u.context)
                            }
                        }
                        .buttonStyle(LKButtonStyle())
                    } else if let s = row.surface {
                        // 展开以后卡片里有同一个「撤销」：行尾的不再画，免得一屏两个
                        if !(open && expandable), let u = TodayPage.undoButton(in: s.surface) {
                            Button(u.label) { model.tapSurface(row.id, componentId: u.id, context: u.context) }
                                .buttonStyle(LKButtonStyle())
                                .modifier(DisabledWhileBusy(surface: s))
                        }
                    } else if let label = row.undoLabel {
                        Button(label) { model.undoDone(row.id) }.buttonStyle(LKButtonStyle()).disabled(row.undone)
                    }
                }
                .lkAppear(fresh, dx: -6, part(2))
                Text(row.time).font(LKFont.ui(LKType.caption)).foregroundStyle(p.mutedFg).monospacedDigit().fixedSize()
                    .frame(minWidth: 54, alignment: .trailing)
                    .lkAppear(fresh, dx: -6, part(1))
            }
            .frame(minHeight: LKHeight.row)
            .contentShape(Rectangle())
            .background {   // 能展开的行：悬停时整行浅一档，看得出整行能点
                if hover && expandable {
                    RoundedRectangle(cornerRadius: LKRadius.control, style: .continuous).fill(p.tint).padding(.horizontal, -LKSpace.x2)
                }
            }
            .onHover { hover = $0 }
            .onTapGesture { if expandable { toggle() } }
            if open && expandable, let s = row.surface {
                SurfaceView(model: s) { cid, _, ctx in model.tapSurface(row.id, componentId: cid, context: ctx) }
                    .padding(.leading, 40)
                    .padding(.bottom, LKSpace.x3)
            }
        }
        .padding(.horizontal, LKSpace.x5)   // 左右和卡片一样留 20：图标列、字、日期列都和卡片对齐
        .overlay(alignment: .top) { if !first { Rectangle().fill(p.border).frame(height: 1).padding(.horizontal, LKSpace.x5) } }
        .accessibilityElement(children: .contain)
        .accessibilityAction { if expandable { toggle() } }      // 默认动作：AXPress（VoiceOver、自动化）也能展开，不只认鼠标
        .accessibilityAction(named: open ? "收起" : "展开整张卡片") { if expandable { toggle() } }
    }
}

/// 急事的一张卡片：和别的卡片一样白底，应用图标右下角一个红色角标
struct UrgentBanner: View {
    let item: UrgentItem
    @ObservedObject var model: WindowModel
    @Environment(\.lk) private var p

    var body: some View {
        // 和卡片一样：应用图标在左，时间在最右；中间是标题和按钮（核心的是工具写的那张卡片）
        // 顶对齐、图标列和普通卡片一样宽（28）：卡片再高，图标也跟着标题第一行，正文起点和别的卡片对齐。
        // 急事的红盾牌做成应用图标右下角的角标，不再单占一列
        HStack(alignment: .top, spacing: LKSpace.x3) {
            AppIcon(tool: item.tool, size: 28)
                .overlay(alignment: .bottomTrailing) {
                    LKIcon("circle-alert", size: 12)   // 红底白圈：Lucide 没有实心的，白线画在红圆上
                        .foregroundStyle(.white)
                        .padding(1)
                        .background(Circle().fill(p.danger))
                        .background(Circle().fill(p.card).padding(-1.5))     // 和卡片底同色的一圈，把角标和图标隔开
                        .offset(x: 4, y: 4)
                        .accessibilityHidden(true)
                }
            if let s = item.surface {
                SurfaceView(model: s) { cid, _, ctx in model.tapSurface(item.id, componentId: cid, context: ctx) }
                    .padding(.top, LKSpace.x1)
                    .environment(\.a2uiFirstLineInset, CardFrame.timeInset)
            } else {
                Text(item.title).font(LKFont.ui(LKType.lead, .semibold)).lineLimit(1)
                Spacer(minLength: LKSpace.x2)
                Button { model.handleUrgent(item.id, primary: true) } label: { IconText(item.primary, symbol: item.primarySymbol) }
                    .buttonStyle(LKButtonStyle(kind: .danger))
                Button(item.secondary) { model.handleUrgent(item.id, primary: false) }.buttonStyle(LKButtonStyle())
                Text(item.time).font(LKFont.ui(LKType.caption)).foregroundStyle(p.mutedFg).monospacedDigit()
            }
        }
        .overlay(alignment: .topTrailing) {   // 工具写的卡片：时间在右上角，只占第一行
            if item.surface != nil {
                Text(item.time).font(LKFont.ui(LKType.caption)).foregroundStyle(p.mutedFg).monospacedDigit().padding(.top, 6)
            }
        }
        .padding(LKInsets.card)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background { CardSurface() }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("急事：\(item.title)")
    }
}

/// 一张卡片：窗口画框、应用图标和时间，里面是工具写的 A2UI
struct CardFrame: View {
    /// 右上角的时间（「10月20日」「14:33」）连同和标题之间的空：卡片第一行让出这么宽
    static let timeInset: CGFloat = 76

    let card: TodayCard
    @ObservedObject var model: WindowModel
    var iconHidden = false
    /// 第一张：进「一件件处理」时长成面板
    var hero: Namespace.ID? = nil
    @Environment(\.lk) private var p

    var body: some View {
        HStack(alignment: .top, spacing: LKSpace.x3) {
            AppIcon(tool: card.tool, size: 28)
                .opacity(iconHidden ? 0 : 1)
                .lkIconFrame("card:\(card.id)")
            // 时间在右上角，只占第一行（标题那一行让出来），下面一封封的列表照满宽画
            SurfaceView(model: card.surface) { cid, name, ctx in model.tap(card: card, componentId: cid, name: name, context: ctx) }
                .padding(.top, LKSpace.x1)
                .environment(\.a2uiFirstLineInset, card.time == nil ? 0 : CardFrame.timeInset)
        }
        .overlay(alignment: .topTrailing) {
            if let t = card.time {
                Text(t).font(LKFont.ui(LKType.caption)).foregroundStyle(p.mutedFg).monospacedDigit().padding(.top, 6)
            }
        }
        .padding(LKInsets.card)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background { CardSurface().lkHero(hero) }
        .accessibilityElement(children: .contain)
    }
}

// MARK: 卡片里有什么

/// 从一张卡片里取出标题、其余的字、按钮（紧凑的表、简报、一件件处理用）
struct SurfaceDigest {
    struct Action: Identifiable, Equatable {
        let id: String
        let label: String
        let variant: String?
        /// 打开网页的按钮去哪个网站（agent 核心写在按钮上的 `site`），画在按钮后面；别的按钮是 nil
        let site: String?
    }

    /// 要填、要选的组件：卡片外面只画按钮的话，会按默认值交上去
    static let inputs: Set<String> = ["CheckBox", "ChoicePicker", "TextField", "DateTimeInput", "Slider"]

    let title: String
    let detail: String
    /// 打开网页、又没写 `site` 的按钮不列（卡片里也点不了）
    let actions: [Action]
    /// 卡片里有要填、要选的：这种卡片不在外面画按钮，展开整张
    let hasInputs: Bool

    /// ⏎ 答的那个：只认标了 primary 的
    var primary: Action? { actions.first { $0.variant == "primary" } }

    init(_ s: Surface) {
        var actions: [Action] = []
        var labels = Set<String>()
        var hasInputs = false
        let order = s.reachable()
        for id in order {
            guard let c = s.components[id], let type = c["component"]?.string else { continue }
            if Self.inputs.contains(type) { hasInputs = true }
            guard type == "Button" else { continue }
            labels.formUnion(s.buttonParts(id))
            if s.opensURL(id), s.openSite(id) == nil { continue }
            let label = s.buttonLabel(id).text
            if !label.isEmpty {
                actions.append(Action(id: id, label: label, variant: c["variant"]?.string, site: s.openSite(id)))
            }
        }
        var title: String?
        var texts: [String] = []
        for id in order where !labels.contains(id) {
            guard let c = s.components[id], c["component"]?.string == "Text", let t = c["text"]?.string, !t.isEmpty else { continue }
            let heading = ["h1", "h2", "h3", "h4", "h5"].contains(c["variant"]?.string ?? "")
            if title == nil && heading { title = t } else { texts.append(t) }
        }
        if title == nil, !texts.isEmpty { title = texts.removeFirst() }
        self.title = title ?? ""
        self.detail = texts.joined(separator: " · ")
        self.actions = actions
        self.hasInputs = hasInputs
    }
}

/// 卡片外面另画的一个按钮（紧凑的表、一件件处理）：这张卡片在处理一次点按时灰掉；打开网页的，网站写在按钮后面
struct DigestButton: View {
    let action: SurfaceDigest.Action
    @ObservedObject var surface: SurfaceModel
    let style: LKButtonStyle
    let tap: () -> Void
    @Environment(\.lk) private var p

    var body: some View {
        HStack(spacing: 6) {
            Button(action.label, action: tap).buttonStyle(style).disabled(surface.busy)
            if let site = action.site {
                Text("会打开 \(site) 网页").font(LKFont.ui(LKType.caption)).foregroundStyle(p.mutedFg).lineLimit(1).truncationMode(.head)
            }
        }
    }
}

/// 卡片在处理一次点按时（`busy`）灰掉：看着那张卡片，busy 变了就重画
struct DisabledWhileBusy: ViewModifier {
    @ObservedObject var surface: SurfaceModel
    func body(content: Content) -> some View { content.disabled(surface.busy) }
}

/// 一叠下面那一行：「还有 7 封」展开、「收起」
/// 「要你决定」段标题下面的「按类处理」：不止一件的那几类，每类一块（应用图标、名字、件数），点了进「一件件处理」只走这一类
struct CategoryPicks: View {
    @ObservedObject var model: WindowModel
    let picks: [DecideCategory]
    @Environment(\.lk) private var p

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: LKSpace.x3) {
            Text("按类处理").font(LKFont.ui(LKType.small)).foregroundStyle(p.mutedFg).fixedSize()
            Wrap(spacing: LKSpace.x2) {
                ForEach(picks) { c in
                    LKChip(on: false, action: { model.enterFocus(category: c.id) }) {
                        AppIcon(tool: c.tool, size: 14)
                        Text(c.name).lineLimit(1)
                        LKCount(value: c.ids.count).foregroundStyle(p.mutedFg)
                    }
                    .help("「\(c.name)」的 \(c.ids.count) 件一次只摆一件：⏎ 答，↓ 跳过，Esc 回来")
                    .accessibilityLabel("一件件处理「\(c.name)」的 \(c.ids.count) 件")
                }
            }
        }
        .padding(.bottom, LKSpace.x3)
    }
}

struct StackToggle: View {
    let more: Int
    let unit: String
    let open: Bool
    let tint: Color?
    /// 这一叠是什么：卡片标题是「一封可疑邮件…」这样的，写成「4 封可疑邮件」；写不出就是 nil，照旧写「同类的」
    var what: String? = nil
    let action: () -> Void
    @Environment(\.lk) private var p

    var body: some View {
        Button(action: action) {
            HStack(spacing: LKSpace.x2) {
                LKIcon(open ? "chevron-up" : "chevron-down", size: 13)
                Text(open ? "收起" : what.map { "还有 \($0)" } ?? "还有 \(more) \(unit)同类的")
                Spacer(minLength: 0)
            }
            .font(LKFont.ui(LKType.small))
            .foregroundStyle(tint ?? p.mutedFg)
            .padding(.horizontal, LKSpace.x4)
            .frame(minHeight: 30)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(open ? "收起" : "展开另外 \(more) \(unit)")
    }
}

extension View {
    /// 收着的一叠：下面露出一两层边，看得出后面还压着几张
    func stackEdge(_ hidden: Int, tint: Color?) -> some View {
        modifier(StackEdge(hidden: hidden, tint: tint))
    }
}

private struct StackEdge: ViewModifier {
    let hidden: Int
    let tint: Color?
    @Environment(\.lk) private var p

    func body(content: Content) -> some View {
        content.background(alignment: .bottom) {
            if hidden > 0 {
                ZStack(alignment: .bottom) {
                    if hidden > 1 { layer.padding(.horizontal, 20).offset(y: 10).opacity(0.5) }
                    layer.padding(.horizontal, 10).offset(y: 5).opacity(0.8)
                }
            }
        }
        .padding(.bottom, hidden > 0 ? (hidden > 1 ? 10 : 5) : 0)
    }

    private var layer: some View {
        CardSurface(fill: tint.map { $0.opacity(p.dark ? 0.18 : 0.08) })   // 和卡片同一种底，不描边
            .frame(height: 24)
    }
}

extension TodayPage {
    /// 「急事 N」的 N：急事的件数，不是叠数（和「要你决定」一样）
    static func urgentCount(_ urgent: [UrgentItem]) -> Int { urgent.count }
}
