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

    /// 「已经替你做了」先列几行
    static let doneLimit = 3

    static func visibleDone(_ rows: [DoneRow], all: Bool) -> (rows: [DoneRow], more: Int) {
        if all || rows.count <= doneLimit { return (rows, 0) }
        return (Array(rows.prefix(doneLimit)), rows.count - doneLimit)
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
    /// 展开成整张卡片的「替你做了」
    @State private var openDone: Set<String> = []
    /// 点了「还有 n 件」
    @State private var allDone = false
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
        ScrollViewReader { proxy in
            PageScroll(padding: LKInsets.column, maxWidth: 700) {
                VStack(alignment: .leading, spacing: 0) {
                    header.lkEnter(0)
                    if let note = model.briefNote {
                        BriefNoteView(note: note, model: model) { jump(to: $0, proxy: proxy) }
                            .transition(.opacity.animation(Motion.enter(Motion.briefClose, reduce: reduce)))
                    }
                    ForEach(Array(model.todaySections.enumerated()), id: \.element) { i, section in
                        switch section {
                        case .urgent: urgentBlock.lkEnter(1 + i * 2)
                        case .done: doneBlock(i)
                        case .decide: decideBlock(i)
                        case .later: laterBlock(i)
                        }
                    }
                    notices.lkEnter(9)
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

    // MARK: 几块

    private var header: some View {
        PageHeader(title: "今天", note: model.dateLine) {
            Button { model.enterFocus() } label: {
                HStack(spacing: LKSpace.x1 + 2) {
                    Text("一件件处理")
                    LKCount(value: model.cards.count, delay: Motion.counterAt).foregroundStyle(p.mutedFg)
                }
            }
            .buttonStyle(LKButtonStyle())
            .disabled(model.cards.isEmpty)
            .help("一次只摆一件：⏎ 答，↓ 跳过，Esc 回来")
        }
    }

    private var urgentBlock: some View {
        VStack(spacing: LKSpace.x2) {
            ForEach(model.urgent) { u in UrgentBanner(item: u, model: model) }
        }
    }

    @ViewBuilder private func doneBlock(_ i: Int) -> some View {
        let shown = TodayPage.visibleDone(model.done, all: allDone)
        LKSection(title: "已经替你做了", count: model.done.count, countDelay: Motion.counterAt).lkEnter(1 + i * 2)
        VStack(spacing: 0) {
            ForEach(Array(shown.rows.enumerated()), id: \.element.id) { n, d in
                let fresh = moving && !known.done.contains(d.id)
                DoneLine(row: d, model: model, open: openDone.contains(d.id), first: n == 0, fresh: fresh,
                         iconHidden: fresh || hidden.contains("done:\(d.id)")) {
                    if openDone.contains(d.id) { openDone.remove(d.id) } else { openDone.insert(d.id) }
                }
                .transition(.asymmetric(insertion: .identity, removal: .opacity.animation(Motion.enter(Motion.undoRow, reduce: reduce))))
            }
            if shown.more > 0 {
                Button { allDone = true } label: {
                    HStack(spacing: LKSpace.x3) {
                        Color.clear.frame(width: 20, height: 20)
                        Text("还有 \(shown.more) 件").font(LKFont.ui(LKType.small)).foregroundStyle(p.mutedFg)
                        Spacer(minLength: 0)
                    }
                    .frame(minHeight: LKHeight.row)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .padding(.horizontal, LKSpace.x4)
                .overlay(alignment: .top) { Rectangle().fill(p.border).frame(height: 1).padding(.leading, LKSpace.x4 + 32) }
            }
        }
        .background(CardSurface())
        .lkEnter(2 + i * 2)
    }

    @ViewBuilder private func decideBlock(_ i: Int) -> some View {
        LKSection(title: "要你决定", count: model.cards.count, countDelay: Motion.counterAt).lkEnter(1 + i * 2)
        if model.cards.isEmpty {
            HStack(spacing: LKSpace.x4) {
                Mascot(width: 56)
                Text("今天没什么要你操心的。").font(LKFont.ui(LKType.body)).foregroundStyle(p.mutedFg)
            }
            .padding(.vertical, LKSpace.x3)
            .lkEnter(2 + i * 2)
        } else {
            VStack(spacing: LKSpace.x3) {
                ForEach(model.cards) { c in
                    let hero = heroReady && !reduce && c.id == model.cards.first?.id
                    let back = moving && !known.cards.contains(c.id)
                    CardFrame(card: c, model: model, iconHidden: back || hidden.contains("card:\(c.id)"), hero: hero ? ns : nil)
                        .overlay {
                            if let r = ring, r.id == c.id { CardRing().id(r.token) }
                        }
                        .id("card:\(c.id)")
                        .transition(.asymmetric(insertion: Motion.cardBack(reduce: reduce || snapshot),
                                                removal: Motion.cardLeave(reduce: reduce || snapshot)))
                }
            }
            .lkEnter(2 + i * 2)
        }
    }

    @ViewBuilder private func laterBlock(_ i: Int) -> some View {
        LKSection(title: "顺便看看", count: model.quiet.count).lkEnter(1 + i * 2)
        LKGroup {
            ForEach(Array(model.quiet.enumerated()), id: \.element.id) { n, q in
                if let s = q.surface {
                    HStack(alignment: .top, spacing: LKSpace.x3) {
                        AppIcon(tool: q.tool, size: 20)
                        SurfaceView(model: s) { cid, _, ctx in model.tapSurface(q.id, componentId: cid, context: ctx) }
                        Spacer(minLength: 0)
                    }
                    .lkRow(first: n == 0)
                } else {
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
                            Button { model.show("这里会打开\(q.tool.name)自己的窗口") } label: { Image(systemName: "chevron.right") }
                                .buttonStyle(LKButtonStyle(kind: .text)).accessibilityLabel("看看")
                        }
                    }
                    .lkRow(first: n == 0)
                }
            }
        }
        .lkEnter(2 + i * 2)
    }

    @ViewBuilder private var notices: some View {
        let notices = (model.hostNotice.map { [$0] } ?? []) + model.notices
        if !notices.isEmpty || model.notificationsNotAsked {
            VStack(alignment: .leading, spacing: LKSpace.x1) {
                ForEach(notices, id: \.self) { n in
                    Text(n).font(LKFont.ui(LKType.small)).foregroundStyle(p.mutedFg).fixedSize(horizontal: false, vertical: true)
                }
                if model.notificationsNotAsked {
                    HStack(spacing: LKSpace.x2) {
                        Text("通知还没打开，简报和急事到不了你。").font(LKFont.ui(LKType.small)).foregroundStyle(p.mutedFg)
                        Button("打开通知") { model.host?.askNotifications() }.buttonStyle(LKButtonStyle())
                    }
                }
            }
            .padding(.top, LKSpace.x4)
        }
    }

    // MARK: 简报里点了一个词

    private func jump(to id: String, proxy: ScrollViewProxy) {
        guard model.cards.contains(where: { $0.id == id }) else { return }
        withAnimation(Motion.enter(Motion.reflow, reduce: reduce)) { proxy.scrollTo("card:\(id)", anchor: .center) }
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
            let shown = TodayPage.visibleDone(model.done, all: allDone).rows.map(\.id)
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
                .fixedSize(horizontal: false, vertical: true)
                .environment(\.openURL, OpenURLAction { url in
                    if let i = Int(url.lastPathComponent), note.pending.indices.contains(i) { jump(note.pending[i].id) }
                    return .handled
                })
                .lkAppear(!snapshot, dy: 10, Motion.soft(Motion.brief, delay: Motion.briefAt, reduce: reduce))
        }
        .padding(.bottom, LKSpace.x5)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(note.title)
    }

    /// 那段话：替你做了的一句、急事（红字）、要你决定的几件（能点；答了的划掉）
    static func text(_ note: BriefNote, open: Set<String>, p: Palette) -> AttributedString {
        var out = AttributedString()
        if !note.done.isEmpty {
            out += AttributedString("替你做了 \(note.done.count) 件：" + note.done.prefix(3).map(BriefNote.phrase).joined(separator: "、")
                                    + (note.done.count > 3 ? "等" : "") + "。")
        }
        if let u = note.urgent.first {
            var a = AttributedString(BriefNote.phrase(u) + (note.urgent.count > 1 ? "等 \(note.urgent.count) 件急事" : ""))
            a.foregroundColor = p.danger
            a.font = LKFont.ui(LKType.lead, .semibold)
            out += a
            out += AttributedString(note.urgent.count > 1 ? "，先看这些。" : "，先看这件。")
        }
        if note.pending.isEmpty {
            out += AttributedString("要你决定的都处理完了。")
        } else {
            out += AttributedString("还有 \(note.pending.count) 件等你：")
            for (i, item) in note.pending.enumerated() {
                if i > 0 { out += AttributedString("、") }
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
            out += AttributedString("。")
        }
        return out
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

    var body: some View {
        VStack(alignment: .leading, spacing: LKSpace.x3) {
            HStack(spacing: LKSpace.x3) {
                AppIcon(tool: row.tool, size: 20)
                    .opacity(iconHidden ? 0 : 1)
                    .lkIconFrame("done:\(row.id)")
                Text(row.text).lineLimit(1).truncationMode(.tail)
                    .strikethrough(row.undone).foregroundStyle(row.undone ? p.mutedFg : p.fg)
                    .lkAppear(fresh, dx: -6, part(0))
                Spacer(minLength: LKSpace.x2)
                Text(row.time).font(LKFont.ui(LKType.caption)).foregroundStyle(p.mutedFg).monospacedDigit().fixedSize()
                    .lkAppear(fresh, dx: -6, part(1))
                Group {
                    if let s = row.surface {
                        if let u = TodayPage.undoButton(in: s.surface) {
                            Button(u.label) { model.tapSurface(row.id, componentId: u.id, context: u.context) }
                                .buttonStyle(LKButtonStyle(kind: .undo))
                                .modifier(DisabledWhileBusy(surface: s))
                        }
                    } else if let label = row.undoLabel {
                        Button(label) { model.undoDone(row.id) }.buttonStyle(LKButtonStyle(kind: .undo)).disabled(row.undone)
                    }
                }
                .lkAppear(fresh, dx: -6, part(2))
                if row.surface != nil {
                    Image(systemName: "chevron.down").font(.system(size: 11, weight: .semibold)).foregroundStyle(p.mutedFg)
                        .rotationEffect(.degrees(open ? 180 : 0))
                        .accessibilityHidden(true)
                }
            }
            .frame(minHeight: LKHeight.row)
            .contentShape(Rectangle())
            .onTapGesture { if row.surface != nil { toggle() } }
            if open, let s = row.surface {
                SurfaceView(model: s) { cid, _, ctx in model.tapSurface(row.id, componentId: cid, context: ctx) }
                    .padding(.leading, 32)
                    .padding(.bottom, LKSpace.x3)
            }
        }
        .padding(.horizontal, LKSpace.x4)
        .overlay(alignment: .top) { if !first { Rectangle().fill(p.border).frame(height: 1).padding(.leading, LKSpace.x4 + 32) } }
        .accessibilityElement(children: .contain)
        .accessibilityAction { if row.surface != nil { toggle() } }      // 默认动作：AXPress（VoiceOver、自动化）也能展开，不只认鼠标
        .accessibilityAction(named: open ? "收起" : "展开整张卡片") { if row.surface != nil { toggle() } }
    }
}

/// 急事：浅红底的横幅，没有边
struct UrgentBanner: View {
    let item: UrgentItem
    @ObservedObject var model: WindowModel
    @Environment(\.lk) private var p

    var body: some View {
        // 和卡片一样：应用图标在左，时间在最右；中间是标题和按钮（核心的是工具写的那张卡片）
        HStack(spacing: LKSpace.x3) {
            Image(systemName: "exclamationmark.shield").font(.system(size: 18)).foregroundStyle(p.danger)
            AppIcon(tool: item.tool, size: 20)
            if let s = item.surface {
                SurfaceView(model: s) { cid, _, ctx in model.tapSurface(item.id, componentId: cid, context: ctx) }
            } else {
                Text(item.title).font(LKFont.ui(LKType.lead, .semibold)).lineLimit(1)
                Spacer(minLength: LKSpace.x2)
                Button { model.handleUrgent(item.id, primary: true) } label: { IconText(item.primary, symbol: item.primarySymbol) }
                    .buttonStyle(LKButtonStyle(kind: .danger))
                Button(item.secondary) { model.handleUrgent(item.id, primary: false) }.buttonStyle(LKButtonStyle())
            }
            Text(item.time).font(LKFont.ui(LKType.caption)).foregroundStyle(p.mutedFg).monospacedDigit()
        }
        .padding(.horizontal, LKSpace.x4).padding(.vertical, LKSpace.x3)
        .background(RoundedRectangle(cornerRadius: LKRadius.card, style: .continuous).fill(p.dangerSoft))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("急事：\(item.title)")
    }
}

/// 一张卡片：窗口画框、应用图标和时间，里面是工具写的 A2UI
struct CardFrame: View {
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
            SurfaceView(model: card.surface) { cid, name, ctx in model.tap(card: card, componentId: cid, name: name, context: ctx) }
                .padding(.top, LKSpace.x1)
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
            let child = c["child"]?.string ?? ""
            labels.insert(child)
            if s.opensURL(id), s.openSite(id) == nil { continue }
            if let label = s.components[child]?["text"]?.string, !label.isEmpty {
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
                Text(site).font(LKFont.ui(LKType.caption)).foregroundStyle(p.mutedFg).lineLimit(1).truncationMode(.head)
            }
        }
    }
}

/// 卡片在处理一次点按时（`busy`）灰掉：看着那张卡片，busy 变了就重画
struct DisabledWhileBusy: ViewModifier {
    @ObservedObject var surface: SurfaceModel
    func body(content: Content) -> some View { content.disabled(surface.busy) }
}
