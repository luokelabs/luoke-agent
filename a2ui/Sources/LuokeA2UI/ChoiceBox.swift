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

        public init(value: String, label: String, icon: String? = nil) {
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
        .buttonStyle(.plain)
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
