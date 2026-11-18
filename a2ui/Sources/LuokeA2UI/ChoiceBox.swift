import SwiftUI
#if os(macOS)
import AppKit
#endif

/// 自己画的选择框：一个框（`DrawnChoice`：1 pt 的边、卡片底、左边现在选的那一项的图标、右边向下的箭头），
/// 点了（或拿到键盘焦点时按空格）在框下面弹出系统的菜单列出各项，现在选的那一项打勾；方向键、回车、Esc、读屏都照系统菜单的。
/// 真窗口和截图画的是同一个框：以前真窗口里把画好的框塞进 `Menu` 的 label，macOS 的菜单按钮只留下里面的字和图，
/// 底色、边框、箭头都丢了，图标挪到最前、按原尺寸画成黑色（#65）。
/// 卡片里的 `ChoicePicker` 和窗口自己的下拉框（设置 · 提醒的简报、免打扰）都用它。
public struct ChoiceBox: View {
    public struct Option: Hashable, Sendable {
        public let value: String
        public let label: String
        /// 图标名（组件目录里的，或 Lucide 的名字）；没有是 nil
        public let icon: String?
        /// 停在上面显示的一句（§4 choiceSubmit：切换邮箱时写完整地址）
        public var tooltip: String? = nil

        public init(value: String, label: String, icon: String? = nil, tooltip: String? = nil) {
            self.tooltip = tooltip
            self.value = value
            self.label = label
            self.icon = icon
        }
    }

    let options: [Option]
    let selected: String
    /// 读屏念的名字（这一项是什么）；不写就念现在选的
    let label: String
    let colors: A2UIDrawn
    let onPick: (String) -> Void
    @Environment(\.a2uiIcon) private var iconHook
    /// 框在窗口里的位置：菜单从框的左下角弹出。放在引用里，滚动时改它不重画
    @State private var anchor = ChoiceAnchor()

    public init(options: [Option], selected: String, label: String = "", colors: A2UIDrawn, onPick: @escaping (String) -> Void) {
        self.options = options
        self.selected = selected
        self.label = label
        self.colors = colors
        self.onPick = onPick
    }

    var current: Option? { options.first { $0.value == selected } }

    public var body: some View {
        let now = current
        Button(action: open) {
            DrawnChoice(text: now?.label ?? "", icon: now?.icon.map { SurfaceView.icon($0, size: 14, hook: iconHook) },
                        chevron: SurfaceView.icon("chevron-down", size: 13, hook: iconHook), colors: colors)
        }
        .buttonStyle(.plainPointer)
        .fixedSize()
        .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { anchor.frame = $0 }
        .modifier(KeyFocusable(radius: 8))
        .accessibilityLabel(label.isEmpty ? (now?.label ?? "") : label)
        .accessibilityValue(now?.label ?? "")
        .accessibilityHint("弹出选项")
        .accessibilityActions {
            // 读屏不打开菜单也能直接换（动作菜单里一项一个）
            ForEach(options, id: \.value) { o in
                Button(o.label) { onPick(o.value) }
            }
        }
    }

    private func open() {
        #if os(macOS)
        guard let view = NSApp.keyWindow?.contentView ?? NSApp.mainWindow?.contentView else { return }
        let f = anchor.frame
        // `.global` 是窗口内容（NSHostingView）的坐标：左上角起、y 往下。内容视图不翻转时换一下
        let y = view.isFlipped ? f.maxY + 4 : view.bounds.height - f.maxY - 4
        ChoiceMenu.popUp(options, selected: selected, minWidth: f.width, hook: iconHook, pick: onPick,
                         at: NSPoint(x: f.minX, y: y), in: view)
        #endif
    }
}

/// 几个都摆出来的选项（设计规范 §18.1、§18.2，2026-11-12 定：处理方式不要点开下拉才看得到）：并排的几块，建议的那个已选中，
/// 选中的一块用品牌色的边和浅底，不再写「建议」两个字。选项不多（≤4）且字短时才用；多了、长了还是 `ChoiceBox`。
/// 读屏：每一块是一个单选按钮，念自己的字，选中的念「已选」。
public struct ChoiceChips: View {
    let options: [ChoiceBox.Option]
    let selected: String
    let label: String
    let colors: A2UIDrawn
    let onPick: (String) -> Void
    @Environment(\.a2uiIcon) private var iconHook
    @Environment(\.accessibilityReduceMotion) private var reduce
    /// 点了先在这里换过去（滑过去，和设置里的分段一样），页上的值跟上了再跟它的
    @State private var shown: String?

    /// 只画图标（每个选项都有图标时才用）：一项右边的选项组，字在悬停提示和读屏里（负责人 11-16：三个带字的选项占掉一半宽，主题被截断）
    var iconsOnly = false

    public init(options: [ChoiceBox.Option], selected: String, label: String = "", colors: A2UIDrawn, iconsOnly: Bool = false,
                onPick: @escaping (String) -> Void) {
        self.options = options
        self.selected = selected
        self.label = label
        self.colors = colors
        self.iconsOnly = iconsOnly && options.allSatisfy { $0.icon != nil }
        self.onPick = onPick
    }

    /// 摆成并排的条件：最多 7 项（走查重画稿：全部记忆一行六七个筛选），每项的字不超过 8 个
    public static func fits(_ labels: [String], each: Int = 8) -> Bool {
        labels.count >= 2 && labels.count <= 7 && labels.allSatisfy { $0.count <= each }
    }

    public var body: some View {
        // 一条选项组（处理方式、「全部 / 工作 / 个人」）：浅底的槽，选中的那一块是卡片底加边，和设置里的分段一样
        HStack(spacing: 2) {
            ForEach(options, id: \.value) { o in
                let on = o.value == (shown ?? selected)
                Button {
                    withAnimation(reduce ? nil : .spring(response: 0.28, dampingFraction: 0.86)) { shown = o.value }
                    onPick(o.value)
                    // 工具没照点的换（拒了、出错）：过一会儿照页上的
                    DispatchQueue.main.asyncAfter(deadline: .now() + 4) { if shown == o.value { shown = nil } }
                } label: {
                    HStack(spacing: 4) {
                        if let icon = o.icon { SurfaceView.icon(icon, size: 14, hook: iconHook) }
                        if !iconsOnly { Text(o.label).lineLimit(1) }
                    }
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(on ? colors.fg : colors.mutedFg)
                    .padding(.horizontal, iconsOnly ? 9 : 11)
                    .frame(height: 26)
                    // 选中的那一块和设置里的分段一个样子（负责人 11-14：几组看着像的按钮有三种样子）：卡片底、一圈次要字色的边
                    .contentShape(Rectangle())
                    // 选中的那一段把自己的位置报上去，底块照它摆（见下面 backgroundPreferenceValue）
                    .anchorPreference(key: ChoiceThumbKey.self, value: .bounds) { on ? $0 : nil }
                }
                .buttonStyle(.plainPointer)
                .fixedSize()
                .modifier(KeyFocusable(radius: 8))
                .help(o.tooltip ?? (iconsOnly ? o.label : ""))
                .accessibilityLabel(o.label)
                .accessibilityValue(on ? "已选" : "")
                .accessibilityAddTraits(on ? [.isSelected] : [])
            }
        }
        .padding(2)
        // 选中的底块是按钮组自己的一块，照量出来的位置摆、跟着滑，按钮组把它裁在里面
        // （负责人 11-15、11-16：以前每段各画一块、靠 matchedGeometryEffect 接，页面重画时各段宽度一变，底块会滑到按钮组外面）
        .backgroundPreferenceValue(ChoiceThumbKey.self) { anchor in
            GeometryReader { g in
                if let anchor {
                    let r = g[anchor]
                    RoundedRectangle(cornerRadius: 6, style: .continuous).fill(colors.card)
                        .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous).strokeBorder(colors.mutedFg, lineWidth: 1))
                        .shadow(color: .black.opacity(0.08), radius: 1, y: 1)
                        .frame(width: r.width, height: r.height)
                        .offset(x: r.minX, y: r.minY)
                        .animation(reduce ? nil : .spring(response: 0.28, dampingFraction: 0.86), value: r)
                }
            }
        }
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(colors.fg.opacity(0.06)))
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .fixedSize()
        // 页上的值跟上点的了，才不再自己记着。中间重画来的还是旧值时不跟（负责人 11-15：切「今天 / 本周」选中的那块先弹回去再过来）
        .onChange(of: selected) { _, new in if shown == nil || new == shown { shown = nil } }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(label)
    }
}

/// 选中的那一段在按钮组里的位置
private struct ChoiceThumbKey: PreferenceKey {
    static let defaultValue: Anchor<CGRect>? = nil
    static func reduce(value: inout Anchor<CGRect>?, nextValue: () -> Anchor<CGRect>?) { value = value ?? nextValue() }
}

/// 框在窗口里的位置（`ChoiceBox` 用；引用类型，改它不触发重画）
final class ChoiceAnchor {
    var frame: CGRect = .zero
}

#if os(macOS)
/// 选择框弹出的菜单：一项一行，现在选的打勾，有图标的带 14 pt 的模板图（跟着菜单的字色）
@MainActor
enum ChoiceMenu {
    /// 弹出菜单，用户选了或按 Esc 才回来（系统菜单自己跟踪鼠标、键盘）
    static func popUp(_ options: [ChoiceBox.Option], selected: String, minWidth: CGFloat, hook: ((String) -> Image?)?,
                      pick: @escaping (String) -> Void, at point: NSPoint, in view: NSView) {
        let target = Target(pick: pick)
        let menu = make(options, selected: selected, minWidth: minWidth, hook: hook, target: target)
        withExtendedLifetime(target) { _ = menu.popUp(positioning: nil, at: point, in: view) }   // 菜单项只弱引用 target
    }

    static func make(_ options: [ChoiceBox.Option], selected: String, minWidth: CGFloat,
                     hook: ((String) -> Image?)?, target: Target) -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false
        menu.font = NSFont.systemFont(ofSize: 13)
        menu.minimumWidth = minWidth
        for o in options {
            let item = NSMenuItem(title: o.label, action: #selector(Target.choose(_:)), keyEquivalent: "")
            item.target = target
            item.representedObject = o.value
            item.state = o.value == selected ? .on : .off
            if let icon = o.icon { item.image = image(icon, hook: hook) }
            menu.addItem(item)
        }
        return menu
    }

    /// 选项的图标画成模板图（只取形状，颜色跟着菜单）
    static func image(_ name: String, hook: ((String) -> Image?)?) -> NSImage? {
        let r = ImageRenderer(content: SurfaceView.icon(name, size: 14, hook: hook).foregroundStyle(Color.black))
        r.scale = NSScreen.main?.backingScaleFactor ?? 2
        guard let img = r.nsImage else { return nil }
        img.isTemplate = true
        return img
    }

    final class Target: NSObject {
        let pick: (String) -> Void
        init(pick: @escaping (String) -> Void) { self.pick = pick }
        @objc func choose(_ item: NSMenuItem) {
            if let v = item.representedObject as? String { pick(v) }
        }
    }
}
#endif
