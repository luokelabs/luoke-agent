import SwiftUI

// 宿主可以换掉的画法。螺壳的窗口用它们把卡片画成窗口自己的样子；不设就是系统样式（输入法等照旧）。

/// 任意一种按钮样式（ButtonStyle 有关联类型，环境里要放擦掉类型的）。
public struct AnyA2UIButtonStyle: ButtonStyle {
    private let make: (Configuration) -> AnyView

    public init<S: ButtonStyle>(_ style: S) {
        make = { AnyView(style.makeBody(configuration: $0)) }
    }

    public func makeBody(configuration: Configuration) -> some View { make(configuration) }
}

/// 自己画的控件用的颜色。设了它，勾选框、单选、输入框、分隔线都不用 AppKit 控件，离屏截图也画得出来。
public struct A2UIDrawn {
    public var fg: Color
    public var mutedFg: Color
    public var card: Color
    public var muted: Color
    public var border: Color
    public var input: Color
    public var primary: Color
    public var primaryFg: Color
    /// 输入框画成静态的（截图时用：离屏画不出系统的输入框）。选择框不管它，真窗口和截图是同一个框（`ChoiceBox`）
    public var staticFields: Bool
    /// 标签（`Text` 的 variant badge）的字色和底色：不写 tone 是 info（浅蓝），danger 红，warning 橙
    public var info, infoSoft, warning, warningSoft, danger, dangerSoft: Color

    public init(fg: Color, mutedFg: Color, card: Color, muted: Color, border: Color, input: Color,
                primary: Color, primaryFg: Color, staticFields: Bool = false,
                info: Color = .blue, infoSoft: Color = Color.blue.opacity(0.12),
                warning: Color = .orange, warningSoft: Color = Color.orange.opacity(0.14),
                danger: Color = .red, dangerSoft: Color = Color.red.opacity(0.12)) {
        self.fg = fg
        self.mutedFg = mutedFg
        self.card = card
        self.muted = muted
        self.border = border
        self.input = input
        self.primary = primary
        self.primaryFg = primaryFg
        self.staticFields = staticFields
        self.info = info
        self.infoSoft = infoSoft
        self.warning = warning
        self.warningSoft = warningSoft
        self.danger = danger
        self.dangerSoft = dangerSoft
    }

    /// 这个 tone 的标签用什么字色、底色
    func badge(_ tone: String?) -> (fg: Color, bg: Color) {
        switch tone {
        case "danger": return (danger, dangerSoft)
        case "warning": return (warning, warningSoft)
        case "neutral": return (fg, muted)       // 大小这类不分好坏的（§4 neutralBadge）
        default: return (info, infoSoft)
        }
    }
}

/// 键盘焦点画成一圈看得见的环；在滚动区里看不到时请滚动区滚过去（`a2uiRevealFocus`）。
/// 录屏（11-09，打开键盘导航）：选择框、深色按钮拿到焦点时看不出来；焦点走到第一屏下面时页面不跟着滚
public struct KeyFocusRing: ViewModifier {
    let focused: Bool
    var radius: CGFloat = 7
    @Environment(\.a2uiRevealFocus) private var reveal
    @State private var id = UUID()

    public init(focused: Bool, radius: CGFloat = 7) {
        self.focused = focused
        self.radius = radius
    }

    /// 系统的键盘焦点色；只有 macOS 有，别的平台用强调色
    #if os(macOS)
    static let ringColor = Color(nsColor: .keyboardFocusIndicatorColor)
    #else
    static let ringColor = Color.accentColor
    #endif

    public func body(content: Content) -> some View {
        content
            .overlay {
                RoundedRectangle(cornerRadius: radius + 3, style: .continuous)
                    .strokeBorder(Self.ringColor, lineWidth: 3)
                    .padding(-3)
                    .opacity(focused ? 1 : 0)
                    .allowsHitTesting(false)
            }
            .id(id)
            .onChange(of: focused) { _, now in if now { reveal?(id) } }
    }
}

/// 选择框这类自己拿焦点的控件：用 `@FocusState` 知道有没有焦点，再画 `KeyFocusRing`
public struct KeyFocusable: ViewModifier {
    var radius: CGFloat = 7
    @FocusState private var focused: Bool

    public init(radius: CGFloat = 7) { self.radius = radius }

    public func body(content: Content) -> some View {
        content.focused($focused).focusEffectDisabled().modifier(KeyFocusRing(focused: focused, radius: radius))
    }
}

/// 输入框自己画光标和框：不再加环，只在拿到焦点时滚到看得见
public struct KeyFocusRevealing: ViewModifier {
    @FocusState private var focused: Bool
    @Environment(\.a2uiRevealFocus) private var reveal
    @State private var id = UUID()

    public init() {}

    public func body(content: Content) -> some View {
        content.focused($focused).id(id).onChange(of: focused) { _, now in if now { reveal?(id) } }
    }
}

private struct RevealFocusKey: EnvironmentKey {
    static let defaultValue: ((AnyHashable) -> Void)? = nil
}

private struct ButtonStyleKey: EnvironmentKey {
    static let defaultValue: ((String?) -> AnyA2UIButtonStyle)? = nil
}

private struct DrawnKey: EnvironmentKey {
    static let defaultValue: A2UIDrawn? = nil
}

private struct CardChromeKey: EnvironmentKey {
    static let defaultValue = true
}

private struct FontKey: EnvironmentKey {
    static let defaultValue: ((String?) -> Font?)? = nil
}

private struct IconKey: EnvironmentKey {
    static let defaultValue: ((String) -> Image?)? = nil
}

private struct FirstLineInsetKey: EnvironmentKey {
    static let defaultValue: CGFloat = 0
}

public extension EnvironmentValues {
    /// 滚动区给的：把这个编号的控件滚到看得见（键盘焦点到了第一屏外面）
    var a2uiRevealFocus: ((AnyHashable) -> Void)? {
        get { self[RevealFocusKey.self] }
        set { self[RevealFocusKey.self] = newValue }
    }

    /// 按钮的样式，按 A2UI 的 variant（primary、borderless、destructive，或没有）给
    var a2uiButtonStyle: ((String?) -> AnyA2UIButtonStyle)? {
        get { self[ButtonStyleKey.self] }
        set { self[ButtonStyleKey.self] = newValue }
    }

    var a2uiDrawn: A2UIDrawn? {
        get { self[DrawnKey.self] }
        set { self[DrawnKey.self] = newValue }
    }

    /// Card 组件要不要画框；宿主已经给卡片画了框时关掉
    var a2uiCardChrome: Bool {
        get { self[CardChromeKey.self] }
        set { self[CardChromeKey.self] = newValue }
    }

    /// 文字的字体，按 A2UI 的 variant（h1…h5、body、caption）给；回 nil 用默认
    var a2uiFont: ((String?) -> Font?)? {
        get { self[FontKey.self] }
        set { self[FontKey.self] = newValue }
    }

    /// 卡片第一行右边让出多少（宿主把时间画在卡片右上角时给）：只有第一行让，下面的照满宽画
    var a2uiFirstLineInset: CGFloat {
        get { self[FirstLineInsetKey.self] }
        set { self[FirstLineInsetKey.self] = newValue }
    }

    /// 图标：Lucide 的名字 → 一张模板图（跟着字色）。宿主带着 Lucide 的图时给；不给或回 nil 就用最接近的系统符号
    var a2uiIcon: ((String) -> Image?)? {
        get { self[IconKey.self] }
        set { self[IconKey.self] = newValue }
    }
}

/// 自己画的勾选框
struct DrawnCheckBox: View {
    let label: String
    @Binding var on: Bool
    let colors: A2UIDrawn

    var body: some View {
        Button { on.toggle() } label: {
            HStack(spacing: 8) {
                RoundedRectangle(cornerRadius: 4)
                    .fill(on ? colors.primary : colors.card)
                    .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(on ? colors.primary : colors.input, lineWidth: 1))
                    .overlay(Image(systemName: "checkmark").font(.system(size: 10, weight: .bold))
                        .foregroundStyle(colors.primaryFg).opacity(on ? 1 : 0))
                    .frame(width: 16, height: 16)
                Text(label).foregroundStyle(colors.fg).frame(maxWidth: .infinity, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(on ? .isSelected : [])
    }
}

/// 进度条：只画进度，数字由工具放在旁边的 Text 里
struct DrawnProgress: View {
    let value: Double
    let colors: A2UIDrawn?

    var body: some View {
        Group {
            if let colors {
                ZStack(alignment: .leading) {
                    Capsule().fill(colors.input)
                    Capsule().fill(colors.primary).frame(width: 160 * min(max(value, 0), 1))
                }
                .frame(height: 6)
            } else {
                ProgressView(value: min(max(value, 0), 1))
            }
        }
        .frame(width: 160)
        .accessibilityLabel("进度")
        .accessibilityValue("\(Int((min(max(value, 0), 1) * 100).rounded()))%")
    }
}

/// 画成开关的按钮（Button 的 `variant: switch`）
struct DrawnSwitch: View {
    let label: String
    let on: Bool
    let colors: A2UIDrawn?
    let tap: () -> Void

    var body: some View {
        if let colors {
            Button(action: tap) {
                ZStack(alignment: on ? .trailing : .leading) {
                    Capsule().fill(on ? colors.primary : colors.input).frame(width: 36, height: 20)
                    Circle().fill(on ? colors.primaryFg : Color.white).frame(width: 16, height: 16)
                        .shadow(color: .black.opacity(0.2), radius: 1, y: 1).padding(2)
                }
            }
            .buttonStyle(.plain)
            .accessibilityLabel(label)
            .accessibilityValue(on ? "开" : "关")
        } else {
            Toggle(label, isOn: Binding(get: { on }, set: { _ in tap() })).labelsHidden()
                #if os(macOS)
                .toggleStyle(.switch)
                #endif
        }
    }
}

/// 选择框的样子：1 pt 的边、白底、高 28、宽度随字；左边是现在选的那一项的图标，右边一个向下的箭头（点了弹菜单的是 `ChoiceBox`）
struct DrawnChoice: View {
    let text: String
    var icon: AnyView? = nil
    var chevron: AnyView? = nil
    let colors: A2UIDrawn

    var body: some View {
        HStack(spacing: 4) {
            if let icon { icon.foregroundStyle(colors.mutedFg) }
            Text(text).lineLimit(1)
            Group {
                if let chevron { chevron } else { Image(systemName: "chevron.down").font(.system(size: 10, weight: .semibold)) }
            }
            .foregroundStyle(colors.mutedFg)
            .padding(.leading, 2)
        }
        .font(.system(size: 13))
        .foregroundStyle(colors.fg)
        .padding(.leading, 8).padding(.trailing, 6)
        .frame(height: 28)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(colors.card))
        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(colors.input, lineWidth: 1))
        .fixedSize()
        .contentShape(Rectangle())
    }
}

/// 标签（`Text` 的 variant badge）：圆角 6、12 号半粗、浅底深字，放在一行字后面（邮箱地址、截止日）
struct DrawnBadge: View {
    let text: String
    let tone: String?
    let colors: A2UIDrawn?

    var body: some View {
        let c = colors?.badge(tone) ?? (fg: Color.secondary, bg: Color.secondary.opacity(0.12))
        Text(text)
            .font(.system(size: 11.5, weight: .semibold))
            .foregroundStyle(c.fg)
            .lineLimit(1)
            .padding(.horizontal, 7)
            .frame(height: 20)
            .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(c.bg))
            .fixedSize()
    }
}

/// 自己画的框（下拉框、静态的输入框）
struct DrawnBox: View {
    let text: String
    let placeholder: Bool
    let chevron: Bool
    let colors: A2UIDrawn

    var body: some View {
        HStack(spacing: 6) {
            Text(text).foregroundStyle(placeholder ? colors.mutedFg : colors.fg).lineLimit(1)
            if chevron {
                Spacer(minLength: 6)
                Image(systemName: "chevron.down").font(.system(size: 10, weight: .semibold)).foregroundStyle(colors.mutedFg)
            }
        }
        .font(.system(size: 13))
        .padding(.horizontal, 10)
        .frame(minWidth: chevron ? 120 : 200, minHeight: 30, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 8).fill(colors.card))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(colors.input, lineWidth: 1))
        .fixedSize(horizontal: chevron, vertical: false)
    }
}
