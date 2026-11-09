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
    /// 输入框、下拉框画成静态的（截图时用）
    public var staticFields: Bool

    public init(fg: Color, mutedFg: Color, card: Color, muted: Color, border: Color, input: Color,
                primary: Color, primaryFg: Color, staticFields: Bool = false) {
        self.fg = fg
        self.mutedFg = mutedFg
        self.card = card
        self.muted = muted
        self.border = border
        self.input = input
        self.primary = primary
        self.primaryFg = primaryFg
        self.staticFields = staticFields
    }
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

public extension EnvironmentValues {
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

/// 自己画的分段单选（选项少、字短时）
struct DrawnSegments: View {
    let options: [(value: String, label: String)]
    @Binding var value: String
    let colors: A2UIDrawn

    var body: some View {
        HStack(spacing: 2) {
            ForEach(options, id: \.value) { o in
                Button { value = o.value } label: {
                    Text(o.label)
                        .font(.system(size: 12))
                        .foregroundStyle(o.value == value ? colors.fg : colors.mutedFg)
                        .padding(.horizontal, 10)
                        .frame(height: 26)
                        .background(RoundedRectangle(cornerRadius: 6).fill(o.value == value ? colors.card : .clear)
                            .shadow(color: .black.opacity(o.value == value ? 0.08 : 0), radius: 1, y: 1))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(o.value == value ? .isSelected : [])
            }
        }
        .padding(2)
        .background(RoundedRectangle(cornerRadius: 8).fill(colors.muted))
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
