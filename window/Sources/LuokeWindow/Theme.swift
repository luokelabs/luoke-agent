import LuokeA2UI
import SwiftUI

/// 原型（docs/主窗口原型.html）里的颜色。改颜色只改这里。
public struct Palette: Equatable {
    public var bg, fg, card, sidebar, primary, primaryFg, muted, mutedFg, border, input: Color
    public var brand, brandSoft, success, successSoft, warning, warningSoft, danger, dangerSoft: Color
    /// 珊瑚红当字用（粉底小标签上、撤销、简报里能点的词下面那条线）
    public var brandText: Color
    /// 实心红按钮的底色（上面是白字）
    public var dangerFill: Color
    /// 卡片上的标签（邮箱地址）：浅蓝底、蓝字；快到期的橙色标签用的字色（比 warning 深，小字也到 4.5:1）
    public var info: Color = .hex(0x2F5E9E)
    public var infoSoft: Color = .hex(0xE7EEF8)
    public var warningText: Color = .hex(0x8A5A12)
    public var dark: Bool

    /// 字色在浅底、粉底上都到 4.5:1（红字 #B83C29、绿字 #2C744B 在急事卡的粉底上 4.8；11-07 实测）
    public static let light = Palette(
        bg: .hex(0xFCFAF7), fg: .hex(0x3A1F14), card: .hex(0xFFFFFF), sidebar: .hex(0xF7F2EB),
        primary: .hex(0x3A1F14), primaryFg: .hex(0xFFF8EE), muted: .hex(0xF4EEE6), mutedFg: .hex(0x7A6558),
        border: .hex(0xECE4DA), input: .hex(0xE2D8CC), brand: .hex(0xE8556B), brandSoft: .hex(0xFCE8EA),
        success: .hex(0x2C744B), successSoft: .hex(0xE4F2E8), warning: .hex(0xA86A12), warningSoft: .hex(0xFBF0D9),
        danger: .hex(0xB83C29), dangerSoft: .hex(0xFBE9E5), brandText: .hex(0xB4364C), dangerFill: .hex(0xC2412D), dark: false)

    public static let dark = Palette(
        bg: .hex(0x15110E), fg: .hex(0xFFF8EE), card: .hex(0x201A16), sidebar: .hex(0x1A1512),
        primary: .hex(0xFFF8EE), primaryFg: .hex(0x3A1F14), muted: .hex(0x29221D), mutedFg: .hex(0xBFB2A6),
        border: .hex(0x322A24), input: .hex(0x40362F), brand: .hex(0xF2707F), brandSoft: .hex(0x3B1F24),
        success: .hex(0x5CC98A), successSoft: .hex(0x16301F), warning: .hex(0xE8B45A), warningSoft: .hex(0x33280F),
        danger: .hex(0xF07A66), dangerSoft: .hex(0x3A1A15), brandText: .hex(0xF58A97), dangerFill: .hex(0xB8412F),
        info: .hex(0x9DBCEB), infoSoft: .hex(0x1C2737), warningText: .hex(0xE8B45A), dark: true)

    /// 次一级按钮、分段的底：字色的 6 %（深色 8 %）
    public var tint: Color { (dark ? Color.hex(0xFFF8EE) : Color.hex(0x3A1F14)).opacity(dark ? 0.08 : 0.06) }
    /// 悬停：字色的 10 %
    public var soft: Color { (dark ? Color.hex(0xFFF8EE) : Color.hex(0x3A1F14)).opacity(0.10) }
    /// 侧栏选中的底：字色的 7 %（深色 8 %）
    public var selection: Color { (dark ? Color.hex(0xFFF8EE) : Color.hex(0x3A1F14)).opacity(dark ? 0.08 : 0.07) }
    /// 卡片的影子（浅色）
    public var shadow: Color { Color.hex(0x3A1F14) }
    /// 分段里选中的那一块
    public var thumb: Color { dark ? .hex(0x3A302A) : card }
}

extension Color {
    static func hex(_ v: UInt32) -> Color {
        Color(.sRGB, red: Double((v >> 16) & 0xFF) / 255, green: Double((v >> 8) & 0xFF) / 255, blue: Double(v & 0xFF) / 255)
    }
}

/// 字号：只用这五档；字重只用常规、中等、半粗
enum LKType {
    /// 页面标题、一件件处理的标题
    static let title: CGFloat = 26
    /// 卡片标题、简报、一件件处理的正文
    static let lead: CGFloat = 15
    static let body: CGFloat = 14
    static let small: CGFloat = 13
    static let caption: CGFloat = 12
}

/// 间距：4 pt 的格子
enum LKSpace {
    static let x1: CGFloat = 4
    static let x2: CGFloat = 8
    static let x3: CGFloat = 12
    static let x4: CGFloat = 16
    static let x5: CGFloat = 20
    static let x6: CGFloat = 24
    static let x7: CGFloat = 28
    static let x8: CGFloat = 32
    static let x11: CGFloat = 44
    static let x14: CGFloat = 56
}

/// 圆角
enum LKRadius {
    /// 小按钮、小标签、键帽
    static let small: CGFloat = 6
    /// 按钮、输入框、侧栏选中
    static let control: CGFloat = 8
    /// 卡片、一组行、横幅
    static let card: CGFloat = 14
    /// 浮在上面的面板（要权限）
    static let sheet: CGFloat = 20
    /// 一件件处理的面板
    static let focus: CGFloat = 16
}

/// 高度
enum LKHeight {
    static let button: CGFloat = 30
    static let buttonLarge: CGFloat = 36
    static let buttonSmall: CGFloat = 24
    static let row: CGFloat = 44
    static let tableRow: CGFloat = 36
}

private struct PaletteKey: EnvironmentKey { static let defaultValue = Palette.light }
private struct SnapshotKey: EnvironmentKey { static let defaultValue = false }
private struct ScrolledToEndKey: EnvironmentKey { static let defaultValue = false }
private struct LiveControlsKey: EnvironmentKey { static let defaultValue = false }

public extension EnvironmentValues {
    var lk: Palette {
        get { self[PaletteKey.self] }
        set { self[PaletteKey.self] = newValue }
    }

    /// 在画截图：滚动区平铺、输入框画成静态的、窗口的红黄绿自己画、不放动画
    var lkSnapshot: Bool {
        get { self[SnapshotKey.self] }
        set { self[SnapshotKey.self] = newValue }
    }

    /// 截图里滚动区停在最下面（看滚到底时最后一项和底部搜索框的关系）
    var lkScrolledToEnd: Bool {
        get { self[ScrolledToEndKey.self] }
        set { self[ScrolledToEndKey.self] = newValue }
    }

    /// 截图里卡片的控件照真窗口那条路画（`A2UIDrawn.staticFields` 关着）：量得出真窗口里选择框的样子（#65）
    var lkLiveControls: Bool {
        get { self[LiveControlsKey.self] }
        set { self[LiveControlsKey.self] = newValue }
    }
}

enum LKFont {
    static func ui(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font { .system(size: size, weight: weight) }
    static func mono(_ size: CGFloat) -> Font { .system(size: size, design: .monospaced) }
}

/// 卡片上的字：标题 15 半粗，正文 14，说明 13
func lkCardFont(_ variant: String?) -> Font {
    switch variant {
    case "h1", "h2", "h3", "h4": return LKFont.ui(LKType.lead, .semibold)
    case "h5": return LKFont.ui(LKType.body, .medium)
    case "caption": return LKFont.ui(LKType.small)
    default: return LKFont.ui(LKType.body)
    }
}

/// 按深浅色挑一套颜色，把卡片渲染器的样式也接上。窗口里所有东西都包在它里面。
struct Themed<Content: View>: View {
    @Environment(\.colorScheme) private var scheme
    @Environment(\.lkSnapshot) private var snapshot
    @Environment(\.lkLiveControls) private var live
    @ViewBuilder var content: Content

    var body: some View {
        let p = scheme == .dark ? Palette.dark : Palette.light
        content
            .environment(\.lk, p)
            .environment(\.a2uiButtonStyle, { AnyA2UIButtonStyle(LKButtonStyle(kind: LKButtonKind(a2ui: $0))) })
            .environment(\.a2uiDrawn, A2UIDrawn(fg: p.fg, mutedFg: p.mutedFg, card: p.card, muted: p.muted, border: p.border,
                                                input: p.input, primary: p.primary, primaryFg: p.primaryFg, staticFields: snapshot && !live,
                                                info: p.info, infoSoft: p.infoSoft, warning: p.warningText, warningSoft: p.warningSoft,
                                                danger: p.danger, dangerSoft: p.dangerSoft))
            .environment(\.a2uiIcon, { Lucide.image($0) })
            .environment(\.a2uiCardChrome, false)
            .environment(\.a2uiFont, { lkCardFont($0) })
            .foregroundStyle(p.fg)
            .font(LKFont.ui(LKType.body))
            .tint(p.primary)
    }
}
