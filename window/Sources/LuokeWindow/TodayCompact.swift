import LuokeA2UI
import LuokeA2UICore
import SwiftUI

/// 紧凑的「今天」（设置 · 显示 · 紧凑）：一张表。顶上一条写着几件，按段分组；
/// 每行是图标、应用、事情（后面一行小字：工具写的副标题，工具协议 §4 `subtitle`）、时间、操作。
/// 急事和标准的「今天」一样叠（#60）：同一个应用同一类的 3 件以上叠成一行（「8 封可疑邮件」），点「展开」一行一件列出来；
/// 最多 3 行，其余收在「还有 N 件急事」（#54：一下报两百件急事时，一屏里每行分得清，「要你决定」还在第一屏）
struct TodayCompact: View {
    @ObservedObject var model: WindowModel
    @Environment(\.lk) private var p
    @Environment(\.accessibilityReduceMotion) private var reduce
    @Environment(\.lkSnapshot) private var snapshot

    /// 急事这一段画哪几行：一叠一行（一件的就是那一件），最多 `TodayPage.urgentLimit` 行；`more` 是收起来的件数
    static func urgentRows(_ items: [UrgentItem], all: Bool) -> (stacks: [[UrgentItem]], more: Int) {
        TodayPage.visibleUrgent(items, all: all)
    }

    /// 一行急事写什么：一件的是它的标题和副标题；一叠的写「205 封可疑邮件」，后面是第一件的副标题加「等」
    @MainActor static func urgentText(_ stack: [UrgentItem]) -> (title: String, sub: String?) {
        guard let first = stack.first else { return ("", nil) }
        let sub = first.surface?.surface.subtitle
        if stack.count == 1 { return (first.title, sub) }
        return (TodayStack.countTitle(first.title, stack.count, unit: TodayStack.unit(first.tool)), sub.map { "\($0) 等" })
    }

    /// 列宽：图标、应用、时间、操作；事情占剩下的
    static let columns: (icon: CGFloat, app: CGFloat, time: CGFloat, ops: CGFloat) = (16, 92, 64, 208)

    private var ids: [String] { model.urgent.map(\.id) + model.cards.map(\.id) + model.done.map(\.id) + model.quiet.map(\.id) }

    var body: some View {
        ScrollViewReader { proxy in
            table
                .onChange(of: model.urgentJump) { _, j in if let j { Self.scroll(to: j, model: model, proxy: proxy, reduce: reduce) } }
                .onAppear { if let j = model.urgentJump { Self.scroll(to: j, model: model, proxy: proxy, reduce: reduce) } }
        }
    }

    /// 菜单栏里点了一行急事：等展开的那几行画出来，滚到那一叠，再把请求清掉（标准的「今天」也用）
    static func scroll(to j: UrgentJump, model: WindowModel, proxy: ScrollViewProxy, reduce: Bool) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
            withAnimation(Motion.enter(Motion.reflow, reduce: reduce)) { proxy.scrollTo("urgent:\(j.id)", anchor: .top) }
            if model.urgentJump == j { model.urgentJump = nil }
        }
    }

    private var table: some View {
        // 表最宽 LKColumn.table、居中：窗口再宽，事情和时间、按钮也不隔得老远
        PageScroll(padding: EdgeInsets(top: 0, leading: 0, bottom: 96, trailing: 0), maxWidth: LKColumn.table) {
            VStack(alignment: .leading, spacing: 0) {
                bar.lkEnter(0)
                if let note = model.briefNote { briefLine(note) }
                columnHeader.lkEnter(1)
                if !model.urgent.isEmpty {
                    let shown = Self.urgentRows(model.urgent, all: model.urgentAll)
                    group("急事", model.urgent.count)
                    ForEach(shown.stacks, id: \.first!.id) { stack in
                        if stack.count == 1 {
                            urgentLines(stack[0], nested: false).id("urgent:\(stack[0].id)")
                        } else {
                            let key = TodayStack.key(stack[0].tool, stack[0].kind, stack[0].title)
                            let open = model.urgentOpenStacks.contains(key)
                            stackRow(stack, key: key, open: open).id("urgent:\(stack[0].id)")   // 菜单栏里点了这一叠滚到这里
                            if open {
                                ForEach(stack) { u in urgentLines(u, nested: true) }
                            }
                        }
                    }
                    if shown.more > 0 || (model.urgentAll && TodayStack.spread(TodayStack.urgent(model.urgent)).count > TodayPage.urgentLimit) {
                        moreUrgentRow(shown.more)
                    }
                }
                group("要你决定", model.cards.count)
                ForEach(TodayStack.cards(model.cards).flatMap { $0 }) { c in   // 同一类的挨着，和标准的「今天」、一件件处理一个次序
                    VStack(spacing: 0) {
                        cardRow(c)
                        expandedCard(c.id) { CardFrame(card: c, model: model) }
                    }
                    .transition(Motion.cardLeave(reduce: reduce || snapshot))
                }
                if !model.done.isEmpty {
                    let rows = DoneRow.merged(model.done)   // 同一组的合成一行
                    group("已经替你做了", rows.count)
                    ForEach(rows) { d in doneRow(d) }
                }
                if !model.quiet.isEmpty {
                    group("顺便看看", model.quiet.count)
                    ForEach(model.quiet) { q in
                        laterRow(q)
                        if let s = q.surface {
                            expandedCard(q.id) {
                                // 和标准的「顺便看看」里一张卡片一样画
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
                    }
                }
                notices
            }
            .animation(reduce || snapshot ? nil : Motion.enter(Motion.reflow, delay: Motion.reflowDelay), value: ids)
        }
    }

    // MARK: 顶上

    private var bar: some View {
        HStack(spacing: LKSpace.x4) {
            Text("今天").font(LKFont.ui(LKType.lead, .semibold)).accessibilityAddTraits(.isHeader)
            HStack(spacing: 0) {
                LKCount(value: model.urgent.count, delay: Motion.counterAt).foregroundStyle(p.fg).fontWeight(.semibold)
                Text(" 急事 · ")
                LKCount(value: model.cards.count, delay: Motion.counterAt).foregroundStyle(p.fg).fontWeight(.semibold)
                Text(" 要你决定 · ")
                LKCount(value: model.done.count, delay: Motion.counterAt).foregroundStyle(p.fg).fontWeight(.semibold)
                Text(" 做了")
            }
            .font(LKFont.ui(LKType.small))
            .foregroundStyle(p.mutedFg)
            Spacer(minLength: 0)
            Button { model.enterFocus() } label: {
                HStack(spacing: LKSpace.x1 + 2) {
                    Text("一件件处理")
                    LKCount(value: model.cards.count, delay: Motion.counterAt).foregroundStyle(p.mutedFg)
                }
            }
            .buttonStyle(LKButtonStyle(size: .small))
            .disabled(model.cards.isEmpty)
        }
        .padding(.horizontal, LKSpace.x6)
        .padding(.top, LKSpace.x5)
        .padding(.bottom, LKSpace.x3)
        .overlay(alignment: .bottom) { line }
    }

    private func briefLine(_ note: BriefNote) -> some View {
        HStack(spacing: LKSpace.x3) {
            BrandBadge(size: 16)
            Text(note.sentence).font(LKFont.ui(LKType.small)).foregroundStyle(p.mutedFg).lineLimit(1).truncationMode(.tail)
            Spacer(minLength: 0)
            Button("收起") { model.closeBrief() }.buttonStyle(LKButtonStyle(kind: .text, size: .small))
        }
        .padding(.horizontal, LKSpace.x6)
        .frame(minHeight: LKHeight.tableRow + 4)
        .overlay(alignment: .bottom) { line }
        .transition(.opacity)
    }

    private var columnHeader: some View {
        row {
            Color.clear
        } app: {
            Text("应用")
        } what: {
            Text("事情")
        } time: {
            Text("时间")
        } ops: {
            Text("操作")
        }
        .font(LKFont.ui(LKType.caption, .semibold))
        .foregroundStyle(p.mutedFg)
        .frame(height: 28)
        .overlay(alignment: .bottom) { line }
    }

    private func group(_ title: String, _ count: Int? = nil) -> some View {
        HStack(spacing: LKSpace.x1 + 2) {
            Text(title)
            if let count { LKCount(value: count, delay: Motion.counterAt) }
        }
        .font(LKFont.ui(LKType.caption, .semibold))
        .foregroundStyle(p.mutedFg)
        .padding(.horizontal, LKSpace.x6)
        .frame(maxWidth: .infinity, minHeight: 30, alignment: .leading)
        .background(p.sidebar)
        .overlay(alignment: .bottom) { line }
        .accessibilityAddTraits(.isHeader)
    }

    // MARK: 行

    private var line: some View { Rectangle().fill(p.border).frame(height: 1) }

    /// 一行：五列
    private func row<I: View, A: View, W: View, T: View, O: View>(@ViewBuilder icon: () -> I, @ViewBuilder app: () -> A,
                                                                   @ViewBuilder what: () -> W, @ViewBuilder time: () -> T,
                                                                   @ViewBuilder ops: () -> O) -> some View {
        let c = Self.columns
        return HStack(spacing: LKSpace.x3) {
            icon().frame(width: c.icon, height: c.icon)
            app().lineLimit(1).frame(width: c.app, alignment: .leading)
            what().frame(maxWidth: .infinity, alignment: .leading)
            time().lineLimit(1).frame(width: c.time, alignment: .leading)
            HStack(spacing: LKSpace.x1 + 2) { ops() }.frame(width: c.ops, alignment: .trailing)
        }
        .padding(.horizontal, LKSpace.x6)
    }

    private func tableRow<V: View>(_ content: V) -> some View {
        content
            .font(LKFont.ui(LKType.small))
            .frame(minHeight: LKHeight.tableRow)
            .background(p.bg)
            .overlay(alignment: .bottom) { line }
    }

    private func timeText(_ t: String?) -> some View {
        Text(t ?? "").font(LKFont.ui(LKType.caption)).foregroundStyle(p.mutedFg).monospacedDigit()
    }

    /// 事情那一列：标题，后面一行小字（副标题、说明）。放不下两段都从尾巴省略，副标题不会整个被挤掉；
    /// `lead`：前面那段先放全（叠里点开的一件，前面是分得清的副标题）
    private func what(_ title: Text, _ sub: String?, lead: Bool = false) -> some View {
        HStack(spacing: LKSpace.x2) {
            title.lineLimit(1).layoutPriority(lead ? 1 : 0)
            if let sub, !sub.isEmpty {
                Text(sub).font(LKFont.ui(LKType.caption)).foregroundStyle(p.mutedFg).lineLimit(1)
            }
        }
    }

    /// 一件急事：一行，点了「选一下」的在下面展开成标准的急事卡片。nested：叠里点开的一件，事情往右缩一格
    @ViewBuilder private func urgentLines(_ u: UrgentItem, nested: Bool) -> some View {
        urgentRow(u, nested: nested)
        if u.surface != nil { expandedCard(u.id) { UrgentBanner(item: u, model: model) } }
    }

    /// 叠成一行的急事：「205 封可疑邮件」和第一件的副标题，「展开」一行一件列出来
    private func stackRow(_ stack: [UrgentItem], key: String, open: Bool) -> some View {
        let first = stack[0]
        let (title, sub) = Self.urgentText(stack)
        return tableRow(row {
            AppIcon(tool: first.tool, size: 16)
        } app: {
            Text(first.tool.name).foregroundStyle(p.mutedFg)
        } what: {
            what(Text(title).font(LKFont.ui(LKType.small, .semibold)).foregroundStyle(p.danger), sub)
        } time: {
            timeText(first.time)
        } ops: {
            Button(open ? "收起" : "展开") {
                withAnimation(Motion.enter(Motion.reflow, reduce: reduce)) {
                    if open { model.urgentOpenStacks.remove(key) } else { model.urgentOpenStacks.insert(key) }
                }
            }
            .buttonStyle(LKButtonStyle(size: .small))
            .accessibilityLabel(open ? "收起这 \(stack.count) \(TodayStack.unit(first.tool))" : "一件件列出这 \(stack.count) \(TodayStack.unit(first.tool))")
        })
        .accessibilityElement(children: .contain)
    }

    /// 「还有 N 件急事」：点开列出其余的几叠；都列出来以后同一个位置写「收起」
    private func moreUrgentRow(_ more: Int) -> some View {
        let all = model.urgentAll
        return Button {
            withAnimation(Motion.enter(Motion.reflow, reduce: reduce)) { model.urgentAll.toggle() }
        } label: {
            HStack(spacing: LKSpace.x2) {
                LKIcon(all ? "chevron-up" : "chevron-down", size: 13).frame(width: Self.columns.icon)
                Text(all ? "收起" : "还有 \(more) 件急事")
                Spacer(minLength: 0)
            }
            .font(LKFont.ui(LKType.small))
            .foregroundStyle(p.danger)
            .padding(.horizontal, LKSpace.x6)
            .frame(maxWidth: .infinity, minHeight: LKHeight.tableRow)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background(p.bg)
        .overlay(alignment: .bottom) { line }
    }

    private func urgentRow(_ u: UrgentItem, nested: Bool = false) -> some View {
        let digest = u.surface.map { SurfaceDigest($0.surface) }
        return tableRow(row {
            AppIcon(tool: u.tool, size: 16)
        } app: {
            Text(u.tool.name).foregroundStyle(p.mutedFg)
        } what: {
            if nested, let sub = u.surface?.surface.subtitle {
                // 叠里点开的一件：标题和上面那一行同一类，分得清的是副标题，放在前面；标题跟在后面当小字
                what(Text(sub).font(LKFont.ui(LKType.small, .medium)), u.title, lead: true).padding(.leading, LKSpace.x3)
            } else {
                what(Text(u.title).font(LKFont.ui(LKType.small, .semibold)).foregroundStyle(p.danger), u.surface?.surface.subtitle)
                    .padding(.leading, nested ? LKSpace.x3 : 0)
            }
        } time: {
            timeText(u.time)
        } ops: {
            if let s = u.surface, let digest {
                surfaceOps(u.id, s, digest) { a, x in model.tapSurface(u.id, componentId: a.id, context: x.context) }
            } else {
                Button(u.primary) { model.handleUrgent(u.id, primary: true) }.buttonStyle(LKButtonStyle(kind: .danger, size: .small))
                Button(u.secondary) { model.handleUrgent(u.id, primary: false) }.buttonStyle(LKButtonStyle(size: .small))
            }
        })
    }

    private func cardRow(_ c: TodayCard) -> some View {
        let digest = SurfaceDigest(c.surface.surface)
        return tableRow(row {
            AppIcon(tool: c.tool, size: 16)
        } app: {
            Text(c.tool.name).foregroundStyle(p.mutedFg)
        } what: {
            what(Text(c.displayTitle), c.surface.surface.subtitle ?? digest.detail)
        } time: {
            timeText(c.time)
        } ops: {
            surfaceOps(c.id, c.surface, digest) { a, x in model.tap(card: c, componentId: a.id, name: x.name, context: x.context) }
        })
    }

    private func doneRow(_ d: DoneRow) -> some View {
        tableRow(row {
            AppIcon(tool: d.tool, size: 16)
        } app: {
            Text(d.tool.name).foregroundStyle(p.mutedFg)
        } what: {
            Text(d.text).foregroundStyle(p.mutedFg).strikethrough(d.undone).lineLimit(1)
        } time: {
            timeText(d.time)
        } ops: {
            if d.members.count > 1, let first = d.members.compactMap({ $0.surface.flatMap { TodayPage.undoButton(in: $0.surface) } }).first {
                Button(first.label) {   // 合成的一行：撤销合进来的每一张
                    for m in d.members {
                        guard let s = m.surface, let u = TodayPage.undoButton(in: s.surface) else { continue }
                        model.tapSurface(m.id, componentId: u.id, context: u.context)
                    }
                }
                .buttonStyle(LKButtonStyle(kind: .undo, size: .small))
            } else if let s = d.surface {
                if let u = TodayPage.undoButton(in: s.surface) {
                    Button(u.label) { model.tapSurface(d.id, componentId: u.id, context: u.context) }
                        .buttonStyle(LKButtonStyle(kind: .undo, size: .small))
                        .modifier(DisabledWhileBusy(surface: s))
                }
            } else if let label = d.undoLabel {
                Button(label) { model.undoDone(d.id) }.buttonStyle(LKButtonStyle(kind: .undo, size: .small)).disabled(d.undone)
            }
        })
    }

    private func laterRow(_ q: QuietRow) -> some View {
        tableRow(row {
            AppIcon(tool: q.tool, size: 16)
        } app: {
            Text(q.tool.name).foregroundStyle(p.mutedFg)
        } what: {
            HStack(spacing: LKSpace.x2) {
                Text(q.text).foregroundStyle(p.mutedFg).lineLimit(1)
                if let s = q.sub { Text(s).font(LKFont.ui(LKType.caption)).foregroundStyle(p.mutedFg).lineLimit(1) }
            }
        } time: {
            timeText(nil)
        } ops: {
            if let a = q.action {
                Button(a) { model.upgrade(q.tool) }.buttonStyle(LKButtonStyle(size: .small))
            } else if let s = q.surface {
                surfaceOps(q.id, s, SurfaceDigest(s.surface), borderless: true, style: { _ in LKButtonStyle(kind: .text, size: .small) }) { a, x in
                    model.tapSurface(q.id, componentId: a.id, context: x.context)
                }
            }
        })
    }

    // MARK: 卡片的按钮

    /// 一行里卡片的按钮（最多两个）。有要填、要选的卡片不给按钮（只画按钮会按默认值交上去），给「选一下」，
    /// 点了在这一行下面展开成标准的卡片；按钮在卡片处理一次点按时灰掉
    @ViewBuilder
    private func surfaceOps(_ id: String, _ s: SurfaceModel, _ digest: SurfaceDigest, borderless: Bool = false,
                            style: @escaping (SurfaceDigest.Action) -> LKButtonStyle = { LKButtonStyle(kind: LKButtonKind(a2ui: $0.variant), size: .small) },
                            tap: @escaping (SurfaceDigest.Action, (name: String, context: JSONValue)) -> Void) -> some View {
        if digest.hasInputs {
            let open = model.compactExpanded.contains(id)
            Button(open ? "收起" : Self.chooseLabel) { toggle(id) }
                .buttonStyle(LKButtonStyle(size: .small))
                .accessibilityLabel(open ? "收起这张卡片" : "选一下：展开成整张卡片")
        } else {
            ForEach(digest.actions.filter { borderless || $0.variant != "borderless" }.prefix(2)) { a in
                DigestButton(action: a, surface: s, style: style(a)) {
                    if let x = try? s.surface.action(a.id) { tap(a, x) }
                }
            }
        }
    }

    /// 有要填、要选的卡片那一行的按钮
    static let chooseLabel = "选一下"

    private func toggle(_ id: String) {
        withAnimation(Motion.enter(Motion.reflow, reduce: reduce)) {
            if model.compactExpanded.contains(id) { model.compactExpanded.remove(id) } else { model.compactExpanded.insert(id) }
        }
    }

    /// 点了「选一下」：在这一行下面画标准的卡片（和标准的「今天」里同一张：图标、时间、按钮、选项、输入都在卡片里）
    @ViewBuilder
    private func expandedCard<C: View>(_ id: String, @ViewBuilder card: () -> C) -> some View {
        if model.compactExpanded.contains(id) {
            card()
                .padding(.horizontal, LKSpace.x6)
                .padding(.vertical, LKSpace.x3)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(p.bg)
                .overlay(alignment: .bottom) { line }
                .transition(.opacity)
        }
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
            .padding(.horizontal, LKSpace.x6)
            .padding(.top, LKSpace.x4)
        }
    }
}
