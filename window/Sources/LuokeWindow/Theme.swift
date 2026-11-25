import LuokeA2UI
import SwiftUI

/// 原型（docs/主窗口原型.html）里的颜色。改颜色只改这里。
public struct Palette: Equatable {
    public var bg, fg, card, sidebar, primary, primaryFg, muted, mutedFg, border, input: Color
    public var brand, brandSoft, success, successSoft, warning, warningSoft, danger, dangerSoft: Color
    /// 珊瑚红当字用（粉底小标签上、撤销、简报里能点的词下面那条线）
    public var brandText: Color
    /// 实心红按钮的底色（destructive）；上面的字用 `dangerFillFg`，不用白字（§2「危险按钮上的字」）
    public var dangerFill: Color
    /// 卡片上的标签（邮箱地址）：浅蓝底、蓝字；快到期的橙色标签用的字色（比 warning 深，小字也到 4.5:1）
    public var info: Color = .hex(0x2F5E9E)
    public var infoSoft: Color = .hex(0xE7EEF8)
    public var warningText: Color = .hex(0x8A5A12)
    /// 绿色当字用：浅色压深一档（#2F7A4F 在浅底、粉底上不到 4.5:1），深色就是 success
    public var successText: Color = .hex(0x2C744B)
    public var dark: Bool
    /// 卡片、一组行、横幅的圆角：工作台 12，首页 18（界面规范 v2 §2、§11）
    public var cardRadius: CGFloat = 12
    /// 按钮、输入框、侧栏选中的圆角：工作台 10，首页 12
    public var controlRadius: CGFloat = 10

    /// 工作台那一组（界面规范 v2 §2 的表）：设置、应用页、活动、搜索结果，和主控画的页是同一份值，两边都照抄，不各自调。
    /// `danger`、`brandText`、`warningText` 是 §2「用状态色写的字」压深一档的值；`dangerFill` 就是 destructive。
    /// 标签的蓝（`info`、`infoSoft`）规范里还没有
    public static let light = Palette(
        bg: .hex(0xFCFAF7), fg: .hex(0x2B1A12), card: .hex(0xFFFFFF), sidebar: .hex(0xF7F2EB),
        primary: .hex(0x3A1F14), primaryFg: .hex(0xFDF8F1), muted: .hex(0xF4EEE6), mutedFg: .hex(0x7A6558),
        border: .hex(0xECE4DA), input: .hex(0xE2D8CC), brand: .hex(0xE8556B), brandSoft: .hex(0xFCE8EA),
        success: .hex(0x2F7A4F), successSoft: .hex(0xE4F2E8), warning: .hex(0xA86A12), warningSoft: .hex(0xFBF0D9),
        danger: .hex(0xB33A27), dangerSoft: .hex(0xF9ECEA), brandText: .hex(0xBF2D45), dangerFill: .hex(0xC2412D),
        warningText: .hex(0x8F590C), dark: false)

    /// 深色是带一点暖的灰（石色）的底、近白的字，不用棕（luoke-brand 11-23：深色模式不用棕，和官网深色一致）。
    /// 彩色的浅底（品牌、成功、警告、危险、标签）保留各自色相，不再偏棕。深色下用状态色写的字直接用原色
    public static let dark = Palette(
        bg: .hex(0x1C1B19), fg: .hex(0xFAF8F5), card: .hex(0x262422), sidebar: .hex(0x22211F),
        primary: .hex(0xF2707F), primaryFg: .hex(0x1C1B19), muted: .hex(0x2F2D2A), mutedFg: .hex(0xB5AFA8),
        border: .hex(0x353330), input: .hex(0x45423E), brand: .hex(0xF2707F), brandSoft: .hex(0x3F2329),
        success: .hex(0x5CC98A), successSoft: .hex(0x16301F), warning: .hex(0xE8B45A), warningSoft: .hex(0x352D1C),
        danger: .hex(0xF07A66), dangerSoft: .hex(0x45282A), brandText: .hex(0xF2707F), dangerFill: .hex(0xF07A66),
        info: .hex(0x9DBCEB), infoSoft: .hex(0x1E2838), warningText: .hex(0xE8B45A), successText: .hex(0x5CC98A), dark: true)

    /// 首页那一组（v2 §2「首页和小精灵换的值」）：首页和共用的侧栏。底更暖；别的同工作台。主按钮原来用品牌粉，负责人 11-17 定回深棕（粉的像删除、提示条像报错），品牌粉只留给吉祥物和强调
    public static let homeLight = Palette.light.with(bg: 0xFFF8EE, sidebar: 0xFBEEDC, card: 0xFFFFFF, muted: 0xF6ECDF,
                                                     border: 0xF0E4D4)
    public static let homeDark = Palette.dark.with(bg: 0x1F1E1C, sidebar: 0x161514, card: 0x2A2826, muted: 0x33312E,
                                                   border: 0x393734)

    private func with(bg: UInt32, sidebar: UInt32, card: UInt32, muted: UInt32, border: UInt32) -> Palette {
        var p = self
        p.bg = .hex(bg); p.sidebar = .hex(sidebar); p.card = .hex(card); p.muted = .hex(muted)
        p.border = .hex(border)
        p.cardRadius = 18; p.controlRadius = 12
        return p
    }

    /// 哪一组：首页和侧栏用首页那组，内容区里别的页用工作台那组（v2 §11，和 luoke-core 11-12 商定）
    public enum Layer: Sendable { case home, workbench }

    public static func of(_ layer: Layer, dark: Bool) -> Palette {
        switch layer {
        case .home: return dark ? .homeDark : .homeLight
        case .workbench: return dark ? .dark : .light
        }
    }

    /// 实心红按钮上的字：工作台的 primary-foreground（浅色奶白、深色暖灰），首页那组也是这个
    public var dangerFillFg: Color { dark ? .hex(0x1C1B19) : .hex(0xFDF8F1) }
    /// 次一级按钮、分段的底：字色的 6 %（深色 8 %）
    public var tint: Color { fg.opacity(dark ? 0.08 : 0.06) }
    /// 悬停：字色的 10 %
    public var soft: Color { fg.opacity(0.10) }
    /// 侧栏选中的底：字色的 7 %（深色 8 %）
    public var selection: Color { fg.opacity(dark ? 0.08 : 0.07) }
    /// 卡片的影子（浅色）
    public var shadow: Color { Color.hex(0x2B1A12) }
    /// 分段里选中的那一块
    public var thumb: Color { dark ? input : card }
}

extension Color {
    static func hex(_ v: UInt32) -> Color {
        Color(.sRGB, red: Double((v >> 16) & 0xFF) / 255, green: Double((v >> 8) & 0xFF) / 255, blue: Double(v & 0xFF) / 255)
    }
}

/// 字号：只用这五档；字重只用常规、中等、半粗
enum LKType {
    /// 页面标题、逐件处理的标题
    static let title: CGFloat = 26
    /// 卡片标题、简报、逐件处理的正文
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

/// 圆角。卡片和按钮的圆角跟着哪一组走，在 `Palette.cardRadius`、`Palette.controlRadius`
enum LKRadius {
    /// 小按钮、小标签、键帽
    static let small: CGFloat = 6
    /// 浮在上面的面板（要权限）
    static let sheet: CGFloat = 20
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

    /// 在画截图：滚动区平铺、输入框画成静态的、窗口的红黄绿自己画、不放动画（进场的一下也没有）。
    /// 公开给本体离屏截主窗口用（`--render-ui`）：设了就不用等动画走完
    public var lkSnapshot: Bool {
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

/// 按深浅色和哪一组（首页、工作台）挑一套颜色，把卡片渲染器的样式也接上。窗口里所有东西都包在它里面；
/// 侧栏和首页再包一层首页那组。
struct Themed<Content: View>: View {
    var layer: Palette.Layer = .workbench
    @Environment(\.colorScheme) private var scheme
    @Environment(\.lkSnapshot) private var snapshot
    @Environment(\.lkLiveControls) private var live
    @ViewBuilder var content: Content

    var body: some View {
        let p = Palette.of(layer, dark: scheme == .dark)
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
