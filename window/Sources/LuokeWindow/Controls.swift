import SwiftUI
import LuokeA2UI

// 窗口里自己画的控件。都不用 AppKit 控件：样子照原型，离屏截图也画得出来。

/// 按钮的四级：实心的主按钮、浅底的次按钮、只有字的、浅红底红字的（不好撤回的：移到垃圾邮件）；再加行里的「撤销」「放回」
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
            case .danger: return (p.dangerSoft, p.danger)       // 对照稿的 .btn.danger（工具协议 §4 destructive）
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
            .font(LKFont.ui(size == .small ? LKType.caption : size == .large ? LKType.body : LKType.small, kind == .danger ? .semibold : .medium))
            .lineLimit(1)
            .padding(.horizontal, pad)
            .frame(height: height)
            .foregroundStyle(fg)
            .background(RoundedRectangle(cornerRadius: r, style: .continuous).fill(bg))
            .brightness(!hover ? 0 : kind == .primary ? (p.dark ? -0.06 : 0.08) : kind == .danger ? (p.dark ? 0.06 : -0.03) : 0)
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
            if let symbol { LKIcon(symbol, size: 14) }
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

/// 分段：图标加字的或只有字的，或者每段前面一个单选的圈（`radio`）。选中的那一块滑过去（240 ms）。
/// 选中的一块：卡片底加一圈次要字色的边，和轨道分得开（边和轨道浅色 4.9:1、深色 6.6:1，WCAG 1.4.11 要 3:1；
/// 以前只靠白一点的底，选中和轨道只有 1.15:1、深色 1.10:1，#54）；单选的圈选中的是实心的（圈里一个点，主色）
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
    /// 每段前面画单选的圈（设置 · 提醒的每类事）：选中的实心，没选的空心
    var radio = false
    /// 读屏念的这一组的名字（「密度」）：每一段还是念自己的字（标准、紧凑）。不要在外面加 accessibilityLabel，
    /// 那样每一段都念成组的名字
    var label: String? = nil
    @Environment(\.lk) private var p
    @Environment(\.accessibilityReduceMotion) private var reduce
    @Namespace private var ns

    var body: some View {
        HStack(spacing: 2) {
            ForEach(options, id: \.value) { o in
                let on = o.value == value
                Button { value = o.value } label: {
                    Group {
                        if radio || o.symbol != nil {
                            // 图标后面跟着字：只有图标时要悬停才知道是哪一档
                            HStack(spacing: LKSpace.x1 + 2) {
                                if radio { LKRadio(on: on) } else if let s = o.symbol { LKIcon(s, size: 14) }
                                Text(o.title).font(LKFont.ui(LKType.small, .medium)).lineLimit(1)
                            }
                            .padding(.horizontal, LKSpace.x2 + 2)
                            .frame(height: 26)
                        } else {
                            Text(o.title).font(LKFont.ui(LKType.small, .medium)).padding(.horizontal, segmentWidth == nil ? LKSpace.x3 : 0)
                                .frame(width: segmentWidth, height: 26)
                        }
                    }
                    .foregroundStyle(on ? p.fg : p.mutedFg)
                    .background {
                        if on {
                            RoundedRectangle(cornerRadius: LKRadius.small, style: .continuous).fill(p.thumb)
                                .overlay(RoundedRectangle(cornerRadius: LKRadius.small, style: .continuous).strokeBorder(p.mutedFg, lineWidth: 1))
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
        .modifier(GroupLabel(label: label))
    }
}

/// 一组控件的名字：包成一组（`contain`），组念这个名字，里面每一个照念自己的
struct GroupLabel: ViewModifier {
    let label: String?

    func body(content: Content) -> some View {
        if let label {
            content.accessibilityElement(children: .contain).accessibilityLabel(label)
        } else {
            content
        }
    }
}

/// 单选的圈：选中的是主色的圈里一个实心点，没选的是次要字色的空心圈（都和底到 3:1 以上）
struct LKRadio: View {
    let on: Bool
    @Environment(\.lk) private var p

    var body: some View {
        Circle().strokeBorder(on ? p.primary : p.mutedFg, lineWidth: 1.5)
            .overlay(Circle().fill(p.primary).padding(3.5).opacity(on ? 1 : 0))
            .frame(width: 14, height: 14)
            .accessibilityHidden(true)
    }
}

/// 状态灯
struct LKLight: View {
    enum State { case ok, warn, off, bad, brand }
    let state: State
    var label: String = ""
    @Environment(\.lk) private var p

    /// 形状也分开，不只靠颜色（侧栏收起时只剩这个灯）：在运行是实心，在准备是圈里一个小点，连不上是空心圈
    var body: some View {
        Group {
            switch state {
            case .warn:
                ZStack {
                    Circle().strokeBorder(color, lineWidth: 1.5)
                    Circle().fill(color).frame(width: 3, height: 3)
                }
            case .off:
                Circle().strokeBorder(p.mutedFg, lineWidth: 1.5)
            default:
                Circle().fill(color)
            }
        }
        .frame(width: 8, height: 8).accessibilityLabel(label)
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

/// 呼吸灯：在等、在做，慢慢亮暗。截图、减少动态效果时静止
struct LKBreathing: View {
    var color: Color? = nil
    @Environment(\.lk) private var p
    @Environment(\.lkSnapshot) private var snapshot
    @Environment(\.accessibilityReduceMotion) private var reduce
    @State private var dim = false

    var body: some View {
        // 和侧栏「在准备」的灯同一个颜色、同一个形状（圈里一个点；实心是「在运行」）；红色像出错
        ZStack {
            Circle().strokeBorder(color ?? p.warning, lineWidth: 1.5)
            Circle().fill(color ?? p.warning).frame(width: 4, height: 4)
        }
        .frame(width: 10, height: 10)
            .opacity(dim ? 0.3 : 1)
            .onAppear {
                guard !snapshot && !reduce else { return }
                withAnimation(.easeInOut(duration: 1.2).repeatForever(autoreverses: true)) { dim = true }
            }
            .accessibilityHidden(true)
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
    enum Kind { case plain, ok, warn, bad, brand, info }
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
            case .info: return (p.infoSoft, p.info)
            }
        }()
        HStack(spacing: 4) {
            if let symbol { LKIcon(symbol, size: 12) }
            if !text.isEmpty { Text(text) }
        }
        .font(LKFont.ui(LKType.caption, .medium))
        .foregroundStyle(fg)
        .padding(.horizontal, LKSpace.x2)
        .frame(height: 20)
        .background(RoundedRectangle(cornerRadius: LKRadius.small, style: .continuous).fill(bg))
    }
}

/// 出错的一句话：细线的提示图标、正文色的结论，下面可以再有一句，右边一个写字的「再试一次」。和平常的灰字分开，一眼看得出是出了问题
struct ErrorNote: View {
    let text: String
    var detail: String? = nil
    var retry: (() -> Void)? = nil
    @Environment(\.lk) private var p

    var body: some View {
        // 图标放在和卡片同一个 28pt 图标列里，字从卡片正文的起点开始。字在按钮左边放得下（每句一行）才把按钮放右边；
        // 放不下就按钮回到字下面，不折出「螺壳。」这样两三个字的尾巴（设计说明·版式规则）
        HStack(alignment: .firstTextBaseline, spacing: LKSpace.x3) {
            LKIcon("circle-alert").foregroundStyle(p.warning).frame(width: 28).accessibilityHidden(true)
            if let retry {
                ViewThatFits(in: .horizontal) {
                    HStack(alignment: .firstTextBaseline, spacing: LKSpace.x3) {
                        texts(oneLine: true)
                        Spacer(minLength: LKSpace.x3)
                        Button("再试一次", action: retry).buttonStyle(LKButtonStyle())
                    }
                    VStack(alignment: .leading, spacing: 6) {
                        texts(oneLine: false)
                        Button("再试一次", action: retry).buttonStyle(LKButtonStyle())
                    }
                }
            } else {
                texts(oneLine: false)
                Spacer(minLength: 0)
            }
        }
        .accessibilityElement(children: .combine)
    }

    private func texts(oneLine: Bool) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(text).font(LKFont.ui(LKType.body)).foregroundStyle(p.fg)
            if let detail {
                ForEach(detail.components(separatedBy: "\n"), id: \.self) { line in
                    Text(line).font(LKFont.ui(LKType.small)).foregroundStyle(p.mutedFg)
                        .lineLimit(oneLine ? 1 : nil).fixedSize(horizontal: oneLine, vertical: true)
                }
            }
        }
        .fixedSize(horizontal: oneLine, vertical: true)
    }
}

/// 卡片的底：浅色是白底加一层很淡的影子；深色只靠比底色亮一档的卡片色分层。都不描边（设计说明「禁用 1px 灰描边」）
struct CardSurface: View {
    var fill: Color?
    var radius: CGFloat = LKRadius.card
    @Environment(\.lk) private var p

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        if p.dark {
            shape.fill(fill ?? p.card)
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
    /// 底部留白要盖过搜索框那一段（离底 18 + 框 48 + 实底 20 + 渐隐 13 ≈ 100）再多一点：滚到底时最后一行在渐隐上面
    static let column = EdgeInsets(top: LKSpace.x7, leading: LKSpace.x11, bottom: 128, trailing: LKSpace.x11)
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
            .overlay(alignment: .top) { if !first { Rectangle().fill(p.border).frame(height: 1).padding(.horizontal, LKSpace.x4) } }   // 左右都缩到内容边
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
                        if t.external { LKIcon("square-arrow-out-up-right", size: 12) }
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

/// 下拉框：和卡片里的选择框是同一个控件（`ChoiceBox`：自己画的框，点了在下面弹系统菜单，现在选的打勾），
/// 真窗口和截图一个样。以前把框塞进 `Menu` 的 label，真窗口里只剩字和一个大箭头、跑到字前面，没有框
struct LKSelect: View {
    let value: String
    let options: [String]
    /// 读屏念的名字（简报、免打扰）
    var label: String = ""
    let onPick: (String) -> Void
    @Environment(\.lk) private var p
    @Environment(\.a2uiDrawn) private var drawn

    var body: some View {
        ChoiceBox(options: options.map { ChoiceBox.Option(value: $0, label: $0) }, selected: value, label: label,
                  colors: drawn ?? A2UIDrawn(fg: p.fg, mutedFg: p.mutedFg, card: p.card, muted: p.muted, border: p.border,
                                             input: p.input, primary: p.primary, primaryFg: p.primaryFg),
                  onPick: onPick)
    }
}

/// 滚动区；截图时平铺（离屏画不出系统的滚动视图）。maxWidth：内容那一栏最宽多少（连边距）
/// 各页共用一栏（`LKColumn.width`）：今天、应用页、设置……同样的边距、同样最宽（搜索框和它对齐，见 SearchLayer）。
/// 窄的时候两边边距收窄；`railed`（宽窗口里这一页有侧栏，见 `WindowModel.hasRail`）时一组放得下主栏和侧栏，页自己用 `RailSplit` 分
struct PageScroll<Content: View>: View {
    var padding: EdgeInsets = LKInsets.column
    var maxWidth: CGFloat? = LKColumn.width
    var railed = false
    @ViewBuilder var content: Content
    @Environment(\.lkSnapshot) private var snapshot
    @Environment(\.lkScrolledToEnd) private var atEnd
    @Environment(\.lkLayout) private var layout

    var body: some View {
        let inner = VStack(alignment: .leading, spacing: 0) { content }
            .padding(layout == .narrow && padding == LKInsets.column ? LKInsets.columnNarrow : padding)
            .frame(maxWidth: railed ? LKColumn.railedWidth : maxWidth ?? .infinity, alignment: .topLeading)
            .frame(maxWidth: .infinity, alignment: .top)   // 一栏在内容区居中，和底部的搜索框同一条中线
        if snapshot {
            // 按内容的高度画、顶对齐，多出来的从下面截掉（和滚动区停在最上面一样）
            // 最小、最大都设上，框才取窗口给的高度，不跟着内容长高
            inner.fixedSize(horizontal: false, vertical: true)
                .frame(minWidth: 0, maxWidth: .infinity, minHeight: 0, maxHeight: .infinity, alignment: atEnd ? .bottom : .top)
                .clipped()
        } else {
            ScrollViewReader { proxy in   // 键盘焦点到了看不见的地方：滚过去（KeyFocusRing）
                ScrollView { inner }.scrollIndicators(.never)
                    // 滚到中间：底部浮着搜索框，滚到底边会被它挡住
                    .environment(\.a2uiRevealFocus) { id in withAnimation(.easeOut(duration: 0.2)) { proxy.scrollTo(id, anchor: .center) } }
            }
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
