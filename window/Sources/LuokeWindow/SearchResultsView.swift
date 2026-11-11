import AppKit
import LuokeA2UI
import SwiftUI

/// 搜索框上面的结果，给了 `hits` 的工具的（docs/界面接口.md §7、工具协议 §1b）：顶上一行类型和数量，按类型分组（不按工具），
/// PDF、表格、图片、视频画成缩略图格子，邮件按收件的邮箱分块。列表里没有简介、没有按钮；选中一条（点、↓）列表收窄，
/// 右边出预览和按钮。不标黄（按意思搜，对上的那段里多半没有打的字）。字比正文小一号：名字 12，路径、日期 11。
struct SearchResults: View {
    @ObservedObject var model: WindowModel
    let answer: SearchAnswer
    /// 离屏截图：系统的滚动视图画不出来，平铺、截掉多的
    let snapshot: Bool
    @Environment(\.lk) private var p

    static let name: CGFloat = 12
    static let small: CGFloat = 11
    static let height: CGFloat = 520

    var body: some View {
        VStack(spacing: 0) {
            filters
            Rectangle().fill(p.border).frame(height: 1)
            HStack(alignment: .top, spacing: 0) {
                scrolling(list)
                if let hit = model.selectedHit {
                    Rectangle().fill(p.border).frame(width: 1)
                    scrolling(SearchPreview(model: model, hit: hit)).frame(width: 300)
                }
            }
            .frame(maxHeight: Self.height - 92)
            .fixedSize(horizontal: false, vertical: true)
            Rectangle().fill(p.border).frame(height: 1)
            footer
        }
    }

    @ViewBuilder private func scrolling(_ content: some View) -> some View {
        if snapshot {
            content.fixedSize(horizontal: false, vertical: true).frame(maxHeight: Self.height - 92, alignment: .top)
                .fixedSize(horizontal: false, vertical: true).clipped()
        } else {
            ScrollViewReader { proxy in
                // 不画滚动条（.never：接了鼠标也不画）。画了的话，鼠标放上去它出来占一条宽，内容重排变高变矮，
                // 它又收回去，来回抖
                ScrollView { content }.scrollIndicators(.never)
                    .onChange(of: model.searchSelected) { _, id in     // ↓ ↑ 走到看不见的地方：滚过去
                        if let id { withAnimation(.easeOut(duration: 0.15)) { proxy.scrollTo(id) } }
                    }
            }
            .frame(maxHeight: Self.height - 92).fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: 顶上一行

    private var filters: some View {
        HStack(spacing: 6) {
            chip("全部", answer.hits.count, on: model.searchKind == nil) { model.filterSearch(nil) }
            ForEach(answer.groups) { g in
                chip(g.label, g.hits.count, on: model.searchKind == g.id) { model.filterSearch(g.id) }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
    }

    private func chip(_ label: String, _ n: Int, on: Bool, tap: @escaping () -> Void) -> some View {
        Button(action: tap) {
            HStack(spacing: 4) {
                Text(label).font(LKFont.ui(Self.name, .semibold))
                Text("\(n)").font(LKFont.ui(Self.name)).opacity(on ? 0.8 : 1).foregroundStyle(on ? p.primaryFg : p.mutedFg)
            }
            .foregroundStyle(on ? p.primaryFg : p.fg)
            .padding(.horizontal, 9).frame(height: 24)
            .background(Capsule().fill(on ? p.primary : p.tint))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(label) \(n) 条")
        .accessibilityAddTraits(on ? .isSelected : [])
    }

    // MARK: 各组

    private var list: some View {
        let previewing = model.searchSelected != nil
        return VStack(alignment: .leading, spacing: 18) {
            ForEach(SearchLayout.visible(answer.groups, filter: model.searchKind)) { g in
                let shown = SearchLayout.shown(g, filtered: model.searchKind != nil, previewing: previewing,
                                               selected: model.searchSelected)
                VStack(alignment: .leading, spacing: 8) {
                    header(g, more: g.hits.count - shown.count)
                    if g.grid {
                        grid(shown, columns: previewing ? 3 : 4)
                    } else if g.id == "mail" {
                        mail(HitGroup(id: g.id, label: g.label, icon: g.icon, grid: false, hits: shown))
                    } else {
                        rows(shown, icon: g.icon)
                    }
                }
            }
            // 只给卡片的工具：照旧画它的卡片
            if model.searchKind == nil {
                ForEach(answer.cards) { s in
                    SurfaceView(model: s.surface) { cid, _, ctx in model.tapSurface(s.id, componentId: cid, context: ctx) }
                }
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func header(_ g: HitGroup, more: Int) -> some View {
        HStack(spacing: 6) {
            LKIcon(g.icon, size: 14).foregroundStyle(p.mutedFg)
            Text(g.label).font(LKFont.ui(LKType.small, .semibold)).foregroundStyle(p.fg)
            Text("\(g.hits.count)").font(LKFont.ui(LKType.small)).foregroundStyle(p.mutedFg)
            Spacer(minLength: 0)
            if more > 0 {
                Button { model.filterSearch(g.id) } label: {
                    HStack(spacing: 2) {
                        Text("还有 \(more) 个")
                        LKIcon("chevron-right", size: 12)
                    }
                    .font(LKFont.ui(Self.name)).foregroundStyle(p.mutedFg)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 2)
    }

    private func grid(_ hits: [WindowHit], columns: Int) -> some View {
        let rows = stride(from: 0, to: hits.count, by: columns).map { Array(hits[$0..<min($0 + columns, hits.count)]) }
        return VStack(alignment: .leading, spacing: 10) {
            ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                HStack(alignment: .top, spacing: 10) {
                    ForEach(row) { h in SearchCell(model: model, hit: h).id(h.id) }
                    ForEach(0..<(columns - row.count), id: \.self) { _ in Color.clear.frame(minWidth: 0, maxWidth: .infinity, maxHeight: 1) }
                }
            }
        }
    }

    private func mail(_ g: HitGroup) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(g.mailboxes, id: \.address) { box in
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(box.address.isEmpty ? "邮件" : box.address).font(LKFont.ui(Self.name, .medium)).foregroundStyle(p.info)
                            .lineLimit(1).truncationMode(.middle)
                        Text("\(box.hits.count)").font(LKFont.ui(Self.name)).foregroundStyle(p.mutedFg)
                    }
                    .padding(.horizontal, 8).padding(.bottom, 2)
                    ForEach(box.hits) { h in
                        SearchRow(model: model, hit: h, icon: nil, mail: true).id(h.id)
                    }
                }
                .padding(.vertical, 8).padding(.horizontal, 4)
                .background(RoundedRectangle(cornerRadius: LKRadius.control, style: .continuous).fill(p.tint))
            }
        }
    }

    private func rows(_ hits: [WindowHit], icon: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(hits) { h in SearchRow(model: model, hit: h, icon: icon, mail: false).id(h.id) }
        }
    }

    // MARK: 页脚

    private var footer: some View {
        HStack(spacing: 14) {
            Text("找到 \(answer.hits.count) 条").font(LKFont.ui(Self.name, .medium)).foregroundStyle(p.mutedFg)
            ForEach(Array(missing.enumerated()), id: \.offset) { _, line in
                Text(line).font(LKFont.ui(Self.small)).foregroundStyle(p.mutedFg).lineLimit(1)
            }
            Spacer(minLength: 0)
            if model.searchSelected == nil {
                hint("↑↓", "选一条看详情")
                hint("↩", "打开第一条")
            } else {
                hint("↩", "打开")
                if model.selectedHit?.actionIndex(reveal: true) != nil { hint("⌘↩", "在访达中显示") }
                hint("↑↓", "选择")
            }
        }
        .padding(.horizontal, 14).frame(height: 34)
    }

    /// 没答上来的应用（一句话）
    private var missing: [String] { answer.lines }

    private func hint(_ key: String, _ text: String) -> some View {
        HStack(spacing: 4) {
            Text(key).font(LKFont.ui(Self.small, .medium))
            Text(text).font(LKFont.ui(Self.small))
        }
        .foregroundStyle(p.mutedFg)
    }
}

/// 一格：缩略图（角上写第几页、哪个工作表），下面只有名字和最后一两层文件夹
struct SearchCell: View {
    @ObservedObject var model: WindowModel
    let hit: WindowHit
    @Environment(\.lk) private var p

    var body: some View {
        let on = model.searchSelected == hit.id
        Button { model.selectHit(hit) } label: {
            VStack(alignment: .leading, spacing: 3) {
                SearchThumb(model: model, hit: hit, badge: true)
                    .padding(.bottom, 3)
                Text(hit.title).font(LKFont.ui(SearchResults.name, .medium)).foregroundStyle(p.fg).lineLimit(1)
                Text(hit.folders ?? " ").font(LKFont.ui(SearchResults.small)).foregroundStyle(p.mutedFg).lineLimit(1)
            }
            .padding(5)
            .background(RoundedRectangle(cornerRadius: LKRadius.control, style: .continuous).fill(on ? p.infoSoft : .clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .frame(minWidth: 0, maxWidth: .infinity)     // 一行几格一样宽，不看名字长短
        .accessibilityLabel([hit.title, hit.line, hit.folders].compactMap { $0 }.joined(separator: "，"))
        .accessibilityAddTraits(on ? .isSelected : [])
    }
}

/// 一行：名字、文件夹（或邮件的发件人和主题）、日期
struct SearchRow: View {
    @ObservedObject var model: WindowModel
    let hit: WindowHit
    let icon: String?
    let mail: Bool
    @Environment(\.lk) private var p

    var body: some View {
        let on = model.searchSelected == hit.id
        Button { model.selectHit(hit) } label: {
            HStack(spacing: 8) {
                if let icon { LKIcon(icon, size: 14).foregroundStyle(p.mutedFg) }
                if mail {
                    // 邮件：发件人（`line`）和主题（`title`）
                    (Text(hit.line.map { $0 + "  " } ?? "").font(LKFont.ui(SearchResults.name, .semibold))
                        + Text(hit.title).font(LKFont.ui(SearchResults.name)))
                        .foregroundStyle(p.fg).lineLimit(1)
                } else {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(hit.title).font(LKFont.ui(SearchResults.name, .medium)).foregroundStyle(p.fg).lineLimit(1)
                            .truncationMode(.middle)
                        let sub = [hit.folders, hit.line].compactMap { $0 }.joined(separator: " · ")
                        if !sub.isEmpty {
                            Text(sub).font(LKFont.ui(SearchResults.small)).foregroundStyle(p.mutedFg).lineLimit(1)
                        }
                    }
                }
                Spacer(minLength: 8)
                if let d = hit.day(full: false) {
                    Text(d).font(LKFont.ui(SearchResults.small)).foregroundStyle(p.mutedFg).monospacedDigit()
                }
            }
            .padding(.horizontal, 8).padding(.vertical, 6)
            .background(RoundedRectangle(cornerRadius: LKRadius.small, style: .continuous).fill(on ? p.infoSoft : .clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(on ? .isSelected : [])
    }
}

/// 缩略图：读到了画图，没读到（还在读、读不了）画占位框和类型的图标。宽 4 高 3，图不撑大格子
struct SearchThumb: View {
    @ObservedObject var model: WindowModel
    let hit: WindowHit
    let badge: Bool
    @Environment(\.lk) private var p

    /// 角上那一行字：第几页；工作表写短一点（「第 2 个工作表」→「工作表 2」），格子窄也放得下
    static func badge(_ line: String) -> String {
        if line.hasPrefix("第 "), line.hasSuffix(" 个工作表") {
            return "工作表 " + line.dropFirst(2).dropLast(5)
        }
        return line
    }

    var body: some View {
        let image = WindowModel.thumbKey(hit).flatMap { model.searchThumbs[$0] }
        let fit = hit.kind == "pdf" || hit.kind == "sheet"
        RoundedRectangle(cornerRadius: LKRadius.control, style: .continuous).fill(p.muted)
            .aspectRatio(4 / 3, contentMode: .fit)
            .frame(minWidth: 0, maxWidth: .infinity)
            .overlay {
                if let image {
                    Image(nsImage: image).resizable().interpolation(.high)
                        .aspectRatio(contentMode: fit ? .fit : .fill)
                        .padding(fit ? 6 : 0)
                        .frame(minWidth: 0, maxWidth: .infinity, minHeight: 0, maxHeight: .infinity)
                        .clipped()
                } else {
                    LKIcon(HitGroup.known[HitGroup.key(hit.kind)]?.icon ?? "file", size: 22).foregroundStyle(p.mutedFg.opacity(0.6))
                }
            }
            .overlay(alignment: .bottomLeading) {
                if badge, let line = hit.line {
                    Text(Self.badge(line)).font(LKFont.ui(SearchResults.small, .semibold)).foregroundStyle(p.primaryFg).lineLimit(1)
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(RoundedRectangle(cornerRadius: LKRadius.small, style: .continuous).fill(p.primary.opacity(0.85)))
                        .padding(6)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: LKRadius.control, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: LKRadius.control, style: .continuous).strokeBorder(p.border, lineWidth: 1))
            .onAppear { model.loadThumb(hit) }
            .accessibilityHidden(true)
    }
}

/// 右边的预览：大缩略图、名字、文件夹、类型 · 日期 · 出处、对上的那段原文、按钮
struct SearchPreview: View {
    @ObservedObject var model: WindowModel
    let hit: WindowHit
    @Environment(\.lk) private var p

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if hit.thumb != nil {
                SearchThumb(model: model, hit: hit, badge: true)
            }
            VStack(alignment: .leading, spacing: 3) {
                Text(hit.title).font(LKFont.ui(LKType.body, .semibold)).foregroundStyle(p.fg).fixedSize(horizontal: false, vertical: true)
                if hit.kind == "mail", let from = hit.line {
                    Text(from).font(LKFont.ui(SearchResults.name)).foregroundStyle(p.mutedFg)
                } else if let f = hit.folders {
                    Text(f).font(LKFont.ui(SearchResults.name)).foregroundStyle(p.mutedFg)
                }
                let meta = [hit.kindLabel ?? HitGroup.known[HitGroup.key(hit.kind)]?.label, hit.day(full: true),
                            hit.kind == "mail" ? hit.source : hit.line].compactMap { $0 }
                if !meta.isEmpty {
                    Text(meta.joined(separator: " · ")).font(LKFont.ui(SearchResults.name)).foregroundStyle(p.mutedFg)
                        .lineLimit(1).truncationMode(.middle)
                }
            }
            if let snippet = hit.snippet {
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 5) {
                        LKIcon("search", size: 12)
                        Text(hit.line.map { hit.kind == "mail" ? "对上的文字" : "对上了\($0)的文字" } ?? "对上的文字")
                    }
                    .font(LKFont.ui(SearchResults.name, .semibold)).foregroundStyle(p.fg)
                    Text(snippet).font(LKFont.ui(SearchResults.name)).foregroundStyle(p.mutedFg)
                        .fixedSize(horizontal: false, vertical: true).lineSpacing(2)
                }
            }
            if !hit.actions.isEmpty {
                HStack(spacing: 8) {
                    ForEach(Array(hit.actions.enumerated()), id: \.offset) { i, a in
                        Button { model.openHit(hit, action: i) } label: {
                            IconText(a.title, symbol: a.reveal ? "folder" : (a.primary ? "arrow-up-right" : nil))
                        }
                        .buttonStyle(LKButtonStyle(kind: a.primary ? .primary : .secondary))
                    }
                }
                .padding(.top, 2)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
