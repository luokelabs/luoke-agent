import LuokeA2UI
import LuokeA2UICore
import SwiftUI

/// 紧凑的「今天」（设置 · 显示 · 紧凑）：一张表。顶上一条写着几件，按段分组；
/// 每行是图标、应用、事情（后面一行小字）、时间、操作
struct TodayCompact: View {
    @ObservedObject var model: WindowModel
    @Environment(\.lk) private var p
    @Environment(\.accessibilityReduceMotion) private var reduce
    @Environment(\.lkSnapshot) private var snapshot
    /// 展开了整张卡片的行（有要填、要选的卡片点「展开」）
    @State private var expanded: Set<String> = []

    /// 列宽：图标、应用、时间、操作；事情占剩下的
    static let columns: (icon: CGFloat, app: CGFloat, time: CGFloat, ops: CGFloat) = (16, 92, 64, 208)

    private var ids: [String] { model.urgent.map(\.id) + model.cards.map(\.id) + model.done.map(\.id) + model.quiet.map(\.id) }

    var body: some View {
        PageScroll(padding: EdgeInsets(top: 0, leading: 0, bottom: 96, trailing: 0)) {
            VStack(alignment: .leading, spacing: 0) {
                bar.lkEnter(0)
                if let note = model.briefNote { briefLine(note) }
                columnHeader.lkEnter(1)
                if !model.urgent.isEmpty {
                    group("急事")
                    ForEach(model.urgent) { u in
                    urgentRow(u)
                    if let s = u.surface { expandedCard(u.id, s) { cid, _, ctx in model.tapSurface(u.id, componentId: cid, context: ctx) } }
                }
                }
                group("要你决定", model.cards.count)
                ForEach(model.cards) { c in
                    VStack(spacing: 0) {
                        cardRow(c)
                        expandedCard(c.id, c.surface) { cid, name, ctx in model.tap(card: c, componentId: cid, name: name, context: ctx) }
                    }
                    .transition(Motion.cardLeave(reduce: reduce || snapshot))
                }
                if !model.done.isEmpty {
                    group("已经替你做了", model.done.count)
                    ForEach(model.done) { d in doneRow(d) }
                }
                if !model.quiet.isEmpty {
                    group("顺便看看", model.quiet.count)
                    ForEach(model.quiet) { q in
                        laterRow(q)
                        if let s = q.surface { expandedCard(q.id, s) { cid, _, ctx in model.tapSurface(q.id, componentId: cid, context: ctx) } }
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

    private func urgentRow(_ u: UrgentItem) -> some View {
        let digest = u.surface.map { SurfaceDigest($0.surface) }
        return tableRow(row {
            AppIcon(tool: u.tool, size: 16)
        } app: {
            Text(u.tool.name).foregroundStyle(p.mutedFg)
        } what: {
            Text(u.title).font(LKFont.ui(LKType.small, .semibold)).foregroundStyle(p.danger).lineLimit(1)
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
            HStack(spacing: LKSpace.x2) {
                Text(c.displayTitle).lineLimit(1)
                if !digest.detail.isEmpty {
                    Text(digest.detail).font(LKFont.ui(LKType.caption)).foregroundStyle(p.mutedFg).lineLimit(1)
                }
            }
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
            if let s = d.surface {
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

    /// 一行里卡片的按钮（最多两个）。有要填、要选的卡片不给按钮（只画按钮会按默认值交上去），给「展开」，
    /// 展开了在这一行下面画整张卡片；按钮在卡片处理一次点按时灰掉
    @ViewBuilder
    private func surfaceOps(_ id: String, _ s: SurfaceModel, _ digest: SurfaceDigest, borderless: Bool = false,
                            style: @escaping (SurfaceDigest.Action) -> LKButtonStyle = { LKButtonStyle(kind: LKButtonKind(a2ui: $0.variant), size: .small) },
                            tap: @escaping (SurfaceDigest.Action, (name: String, context: JSONValue)) -> Void) -> some View {
        if digest.hasInputs {
            let open = expanded.contains(id)
            Button(open ? "收起" : "展开") { toggle(id) }
                .buttonStyle(LKButtonStyle(size: .small))
                .accessibilityLabel(open ? "收起整张卡片" : "展开整张卡片")
        } else {
            ForEach(digest.actions.filter { borderless || $0.variant != "borderless" }.prefix(2)) { a in
                DigestButton(action: a, surface: s, style: style(a)) {
                    if let x = try? s.surface.action(a.id) { tap(a, x) }
                }
            }
        }
    }

    private func toggle(_ id: String) {
        if expanded.contains(id) { expanded.remove(id) } else { expanded.insert(id) }
    }

    /// 展开了的整张卡片：从「事情」那一列起，按钮、选项、输入都在卡片里
    @ViewBuilder
    private func expandedCard(_ id: String, _ s: SurfaceModel, onAction: @escaping (String, String, JSONValue) -> Void) -> some View {
        if expanded.contains(id) {
            SurfaceView(model: s) { cid, name, ctx in onAction(cid, name, ctx) }
                .padding(.leading, LKSpace.x6 + Self.columns.icon + LKSpace.x3 + Self.columns.app + LKSpace.x3)
                .padding(.trailing, LKSpace.x6)
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
