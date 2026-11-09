import SwiftUI

// 窗口里自己画的控件。都不用 AppKit 控件：样子照原型，离屏截图也画得出来。

/// 按钮的四级：实心的主按钮、浅底的次按钮、只有字的、红的；再加行里的「撤销」「放回」
public enum LKButtonKind {
    case primary, secondary, text, danger, undo

    /// A2UI 按钮的 variant
    init(a2ui variant: String?) {
        switch variant {
        case "primary": self = .primary
        case "destructive": self = .danger
        case "borderless": self = .text
        default: self = .secondary
        }
    }
}

public enum LKButtonSize {
    /// 24 pt：紧凑的表里
    case small
    /// 30 pt
    case regular
    /// 36 pt：一件件处理里
    case large
}

public struct LKButtonStyle: ButtonStyle {
    var kind: LKButtonKind = .secondary
    var size: LKButtonSize = .regular

    public func makeBody(configuration: Configuration) -> some View {
        LKButtonBody(configuration: configuration, kind: kind, size: size)
    }
}

private struct LKButtonBody: View {
    let configuration: ButtonStyle.Configuration
    let kind: LKButtonKind
    let size: LKButtonSize
    @Environment(\.lk) private var p
    @Environment(\.isEnabled) private var enabled
    @Environment(\.accessibilityReduceMotion) private var reduce
    @State private var hover = false

    var body: some View {
        let (bg, fg): (Color, Color) = {
            switch kind {
            case .primary: return (p.primary, p.primaryFg)
            case .danger: return (p.dangerFill, .white)
            case .secondary: return (hover ? p.soft : p.tint, p.fg)
            case .text: return (hover ? p.tint : .clear, p.fg)
            case .undo: return (hover ? p.tint : .clear, p.brandText)
            }
        }()
        let height: CGFloat = kind == .undo ? LKHeight.buttonSmall + 2 : (size == .small ? LKHeight.buttonSmall : size == .large ? LKHeight.buttonLarge : LKHeight.button)
        let pad: CGFloat = {
            switch (kind, size) {
            case (.undo, _), (.text, _), (_, .small): return LKSpace.x2
            case (_, .large): return LKSpace.x4
            default: return LKSpace.x3
            }
        }()
        let r = size == .small ? LKRadius.small : LKRadius.control
        let pressed = configuration.isPressed && enabled
        configuration.label
            .font(LKFont.ui(size == .small ? LKType.caption : size == .large ? LKType.body : LKType.small, .medium))
            .lineLimit(1)
            .padding(.horizontal, pad)
            .frame(height: height)
            .foregroundStyle(fg)
            .background(RoundedRectangle(cornerRadius: r, style: .continuous).fill(bg))
            .brightness(hover && (kind == .primary || kind == .danger) ? (p.dark ? -0.06 : 0.08) : 0)
            .opacity(enabled ? 1 : 0.45)
            .contentShape(Rectangle())
            .scaleEffect(pressed && !reduce ? 0.97 : 1)
            .animation(Motion.enter(Motion.press), value: pressed)
            .onHover { hover = enabled && $0 }
    }
}

/// 按钮里图标加字
struct IconText: View {
    let symbol: String?
    let text: String

    init(_ text: String, symbol: String? = nil) {
        self.text = text
        self.symbol = symbol
    }

    var body: some View {
        HStack(spacing: 6) {
            if let symbol { Image(systemName: symbol).font(.system(size: 12, weight: .medium)) }
            if !text.isEmpty { Text(text) }
        }
    }
}

struct LKSwitch: View {
    @Binding var on: Bool
    var label: String
    @Environment(\.lk) private var p

    var body: some View {
        Button { on.toggle() } label: {
            ZStack(alignment: on ? .trailing : .leading) {
                Capsule().fill(on ? p.primary : p.input).frame(width: 36, height: 20)
                Circle().fill(on ? p.primaryFg : Color.white).frame(width: 16, height: 16)
                    .shadow(color: .black.opacity(0.2), radius: 1, y: 1).padding(2)
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
        .accessibilityValue(on ? "开" : "关")
    }
}

/// 分段：图标的或字的。选中的那一块滑过去（240 ms）
struct LKSegmented<T: Hashable>: View {
    struct Option {
        let value: T
        let title: String
        let symbol: String?
    }

    let options: [Option]
    @Binding var value: T
    /// 每一段一样宽（字的分段）；nil 照内容
    var segmentWidth: CGFloat? = nil
    @Environment(\.lk) private var p
    @Environment(\.accessibilityReduceMotion) private var reduce
    @Namespace private var ns

    var body: some View {
        HStack(spacing: 2) {
            ForEach(options, id: \.value) { o in
                let on = o.value == value
                Button { value = o.value } label: {
                    Group {
                        if let s = o.symbol {
                            Image(systemName: s).font(.system(size: 12)).frame(width: 30, height: 26)
                        } else {
                            Text(o.title).font(LKFont.ui(LKType.small, .medium)).padding(.horizontal, segmentWidth == nil ? LKSpace.x3 : 0)
                                .frame(width: segmentWidth, height: 26)
                        }
                    }
                    .foregroundStyle(on ? p.fg : p.mutedFg)
                    .background {
                        if on {
                            RoundedRectangle(cornerRadius: LKRadius.small, style: .continuous).fill(p.thumb)
                                .shadow(color: p.shadow.opacity(p.dark ? 0 : 0.14), radius: 1, y: 1)
                                .matchedGeometryEffect(id: "thumb", in: ns)
                        }
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(o.title)
                .accessibilityLabel(o.title)
                .accessibilityAddTraits(on ? .isSelected : [])
            }
        }
        .padding(2)
        .background(RoundedRectangle(cornerRadius: LKRadius.control, style: .continuous).fill(p.tint))
        .animation(reduce ? nil : Motion.enter(Motion.thumb), value: value)
    }
}

/// 状态灯
struct LKLight: View {
    enum State { case ok, warn, off, bad, brand }
    let state: State
    var label: String = ""
    @Environment(\.lk) private var p

    var body: some View {
        Circle().fill(color).frame(width: 8, height: 8).accessibilityLabel(label)
    }

    private var color: Color {
        switch state {
        case .ok: return p.success
        case .warn: return p.warning
        case .off: return p.input
        case .bad: return p.danger
        case .brand: return p.brand
        }
    }
}

/// 一排标签放不下就折行（标签不压缩）
struct Wrap: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? .infinity
        var x: CGFloat = 0, y: CGFloat = 0, line: CGFloat = 0, widest: CGFloat = 0
        for v in subviews {
            let s = v.sizeThatFits(.unspecified)
            if x > 0, x + s.width > width { y += line + spacing; x = 0; line = 0 }
            x += s.width + spacing
            line = max(line, s.height)
            widest = max(widest, x - spacing)
        }
        return CGSize(width: min(widest, width), height: y + line)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, line: CGFloat = 0
        for v in subviews {
            let s = v.sizeThatFits(.unspecified)
            if x > bounds.minX, x + s.width > bounds.maxX { y += line + spacing; x = bounds.minX; line = 0 }
            v.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(s))
            x += s.width + spacing
            line = max(line, s.height)
        }
    }
}

struct LKBadge: View {
    enum Kind { case plain, ok, warn, bad, brand }
    let text: String
    var symbol: String?
    var kind: Kind = .plain
    @Environment(\.lk) private var p

    var body: some View {
        let (bg, fg): (Color, Color) = {
            switch kind {
            case .plain: return (p.muted, p.mutedFg)
            case .ok: return (p.successSoft, p.success)
            case .warn: return (p.warningSoft, p.warning)
            case .bad: return (p.dangerSoft, p.danger)
            case .brand: return (p.brandSoft, p.brandText)
            }
        }()
        HStack(spacing: 4) {
            if let symbol { Image(systemName: symbol).font(.system(size: 10, weight: .semibold)) }
            if !text.isEmpty { Text(text) }
        }
        .font(LKFont.ui(LKType.caption, .medium))
        .foregroundStyle(fg)
        .padding(.horizontal, LKSpace.x2)
        .frame(height: 20)
        .background(RoundedRectangle(cornerRadius: LKRadius.small, style: .continuous).fill(bg))
    }
}

/// 卡片的底：浅色是白底加一层很淡的影子，没有边；深色是一像素的细边，没有影子
struct CardSurface: View {
    var fill: Color?
    var radius: CGFloat = LKRadius.card
    @Environment(\.lk) private var p

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        if p.dark {
            shape.fill(fill ?? p.card).overlay(shape.strokeBorder(p.cardEdge, lineWidth: 1))
        } else {
            shape.fill(fill ?? p.card)
                .shadow(color: p.shadow.opacity(0.06), radius: 1, y: 1)
                .shadow(color: p.shadow.opacity(0.10), radius: 6, y: 4)
        }
    }
}

struct CardBackground: ViewModifier {
    var padding: EdgeInsets = LKInsets.card
    var fill: Color?

    func body(content: Content) -> some View {
        content
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(CardSurface(fill: fill))
    }
}

enum LKInsets {
    static let card = EdgeInsets(top: LKSpace.x4, leading: LKSpace.x5, bottom: LKSpace.x4, trailing: LKSpace.x5)
    static let row = EdgeInsets(top: LKSpace.x3, leading: LKSpace.x4, bottom: LKSpace.x3, trailing: LKSpace.x4)
    static let page = EdgeInsets(top: LKSpace.x7, leading: LKSpace.x8, bottom: 96, trailing: LKSpace.x8)
    /// 「今天」「活动」「设置」那一栏
    static let column = EdgeInsets(top: LKSpace.x7, leading: LKSpace.x11, bottom: 96, trailing: LKSpace.x11)
}

extension View {
    func lkCard(padding: EdgeInsets = LKInsets.card, fill: Color? = nil) -> some View {
        modifier(CardBackground(padding: padding, fill: fill))
    }

    /// 一组里的一行：上边一条分隔线（第一行没有）
    func lkRow(first: Bool) -> some View { modifier(RowChrome(first: first)) }
}

private struct RowChrome: ViewModifier {
    let first: Bool
    @Environment(\.lk) private var p

    func body(content: Content) -> some View {
        content
            .padding(LKInsets.row)
            .frame(maxWidth: .infinity, alignment: .leading)
            .overlay(alignment: .top) { if !first { Rectangle().fill(p.border).frame(height: 1).padding(.leading, LKSpace.x4) } }
    }
}

/// 一组行：卡片的底，行之间有分隔线
struct LKGroup<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        VStack(spacing: 0) { content }
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(CardSurface())
            .clipShape(RoundedRectangle(cornerRadius: LKRadius.card, style: .continuous))
    }
}

/// 会滚的数：换的时候滚一格（减少动态效果时只换）
struct LKCount: View {
    let value: Int
    var delay: Double = 0
    @Environment(\.accessibilityReduceMotion) private var reduce

    var body: some View {
        Text("\(value)")
            .monospacedDigit()
            .contentTransition(reduce ? .opacity : .numericText(value: Double(value)))
            .animation(Motion.enter(Motion.counter, delay: delay, reduce: reduce), value: value)
    }
}

/// 段落标题：「要你决定 4」
struct LKSection: View {
    let title: String
    var count: Int?
    var countDelay: Double = 0
    @Environment(\.lk) private var p

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(title).font(LKFont.ui(LKType.small, .semibold))
            if let count { LKCount(value: count, delay: countDelay).font(LKFont.ui(LKType.small)) }
        }
        .foregroundStyle(p.mutedFg)
        .padding(.top, LKSpace.x7)
        .padding(.bottom, LKSpace.x2)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isHeader)
    }
}

/// 页面标题：标题、旁边一行小字（日期），右边放按钮
struct PageHeader<Trailing: View>: View {
    let title: String
    var note: String? = nil
    @ViewBuilder var trailing: Trailing
    @Environment(\.lk) private var p

    var body: some View {
        HStack(alignment: .center, spacing: LKSpace.x3) {
            Text(title).font(LKFont.ui(LKType.title, .semibold)).tracking(-0.26).accessibilityAddTraits(.isHeader)
            if let note { Text(note).font(LKFont.ui(LKType.caption)).foregroundStyle(p.mutedFg) }
            Spacer(minLength: 0)
            trailing
        }
        .padding(.bottom, LKSpace.x4)
    }
}

extension PageHeader where Trailing == EmptyView {
    init(title: String, note: String? = nil) {
        self.title = title
        self.note = note
        self.trailing = EmptyView()
    }
}

/// 页里的标签：概览、操作记录……；带外链箭头的由工具自己的窗口打开
struct LKTabs: View {
    struct Tab: Identifiable {
        let id: String
        let title: String
        var external = false
    }

    let tabs: [Tab]
    let selected: String
    let onSelect: (Tab) -> Void
    @Environment(\.lk) private var p

    var body: some View {
        HStack(spacing: 2) {
            ForEach(tabs) { t in
                let on = t.id == selected
                Button { onSelect(t) } label: {
                    HStack(spacing: 4) {
                        Text(t.title)
                        if t.external { Image(systemName: "arrow.up.right.square").font(.system(size: 10)) }
                    }
                    .font(LKFont.ui(LKType.small, on ? .medium : .regular))
                    .foregroundStyle(on ? p.fg : p.mutedFg)
                    .padding(.horizontal, LKSpace.x3)
                    .frame(height: 26)
                    .background(RoundedRectangle(cornerRadius: LKRadius.small, style: .continuous).fill(on ? p.thumb : .clear)
                        .shadow(color: p.shadow.opacity(on && !p.dark ? 0.14 : 0), radius: 1, y: 1))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(on ? .isSelected : [])
            }
        }
        .padding(2)
        .background(RoundedRectangle(cornerRadius: LKRadius.control, style: .continuous).fill(p.tint))
        .fixedSize()
        .padding(.bottom, LKSpace.x4)
    }
}

struct LKChip<Label: View>: View {
    let on: Bool
    let action: () -> Void
    @ViewBuilder var label: Label
    @Environment(\.lk) private var p

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) { label }
                .font(LKFont.ui(LKType.small))
                .padding(.horizontal, LKSpace.x3)
                .frame(height: 28)
                .background(RoundedRectangle(cornerRadius: LKRadius.control, style: .continuous).fill(on ? p.selection : p.tint))
                .overlay(RoundedRectangle(cornerRadius: LKRadius.control, style: .continuous).strokeBorder(on ? p.primary : .clear, lineWidth: 1))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(on ? .isSelected : [])
    }
}

/// 下拉框的样子（点了在真窗口里弹系统菜单；截图时只画框）
struct LKSelect: View {
    let value: String
    let options: [String]
    let onPick: (String) -> Void
    @Environment(\.lk) private var p
    @Environment(\.lkSnapshot) private var snapshot

    var body: some View {
        let box = HStack(spacing: 6) {
            Text(value).lineLimit(1)
            Image(systemName: "chevron.down").font(.system(size: 10, weight: .semibold)).foregroundStyle(p.mutedFg)
        }
        .font(LKFont.ui(LKType.small))
        .padding(.horizontal, LKSpace.x3)
        .frame(height: LKHeight.button)
        .background(RoundedRectangle(cornerRadius: LKRadius.control, style: .continuous).fill(p.tint))
        .fixedSize()
        if snapshot {
            box
        } else {
            Menu {
                ForEach(options, id: \.self) { o in Button(o) { onPick(o) } }
            } label: { box }
                .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
        }
    }
}

/// 滚动区；截图时平铺（离屏画不出系统的滚动视图）。maxWidth：内容那一栏最宽多少（连边距）
struct PageScroll<Content: View>: View {
    var padding: EdgeInsets = LKInsets.page
    var maxWidth: CGFloat? = nil
    @ViewBuilder var content: Content
    @Environment(\.lkSnapshot) private var snapshot

    var body: some View {
        let inner = VStack(alignment: .leading, spacing: 0) { content }
            .padding(padding)
            .frame(maxWidth: maxWidth ?? .infinity, alignment: .topLeading)
            .frame(maxWidth: .infinity, alignment: .topLeading)
        if snapshot {
            // 按内容的高度画、顶对齐，多出来的从下面截掉（和滚动区停在最上面一样）
            // 最小、最大都设上，框才取窗口给的高度，不跟着内容长高
            inner.fixedSize(horizontal: false, vertical: true)
                .frame(minWidth: 0, maxWidth: .infinity, minHeight: 0, maxHeight: .infinity, alignment: .top)
                .clipped()
        } else {
            ScrollView { inner }.scrollIndicators(.never)
        }
    }
}

/// 快捷键的小框
struct Kbd: View {
    let text: String
    @Environment(\.lk) private var p

    var body: some View {
        Text(text).font(LKFont.ui(LKType.caption, .medium)).foregroundStyle(p.mutedFg)
            .padding(.horizontal, LKSpace.x1).frame(minWidth: 20, minHeight: 20)
            .background(RoundedRectangle(cornerRadius: LKRadius.small, style: .continuous).fill(p.card))
            .overlay(RoundedRectangle(cornerRadius: LKRadius.small, style: .continuous).strokeBorder(p.border, lineWidth: 1))
    }
}
