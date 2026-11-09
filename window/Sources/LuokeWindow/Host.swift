import AppKit
import SwiftUI

/// 螺壳.app（本体）接进主窗口的事（luoke-core#68，周五的精简版）：主窗口只画 agent 的页（今天、应用页、「设置 · 提醒」「设置 · 权限」），
/// 模型、隐私、添加应用、升级交给本体，打开本体现有的窗口。本体实现这个协议，设到 `WindowModel.host`；没设时窗口自己画这几页（示例）。
@MainActor
public protocol WindowHost: AnyObject {
    /// 「设置 · 模型」、侧栏底部的模型名、「前往 → 模型」
    func openModelSettings()
    /// 「设置 · 隐私」
    func openPrivacySettings()
    /// 「添加应用」（侧栏、「前往」菜单、应用页）
    func openAddApps()
    /// 某个应用的「升级」：配件标识（luoke-mail……）
    func upgrade(app: String)
    /// 用户点了要螺壳名下的一项系统权限（权限页的按钮、`needs-access` 卡片的按钮）：本体开自己的窗口问用户，再去问系统。
    /// `app` 是配件标识，`id` 是权限 id（`fda`）。给没给由本体经 `reportHostPermissions` 报。
    func askPermission(app: String, id: String)
    /// 同上，这个按钮的活要这一项：缺什么本体接着要，都有了调 `ready`，窗口这才把活转给工具。用户没给就不调。
    func askPermission(app: String, id: String, ready: @escaping @MainActor () -> Void)
    /// 权限页上螺壳那一行，系统还没问过：本体只问系统，不问用户，不动各应用的「允许」
    func askSystem(id: String)
    /// 用户在权限页上扳了「允许」：这个应用用不用螺壳名下的这一项。窗口只在接着本体、扳关时调；扳开走 `askPermission`，用户在本体的窗口里确认。这是用户和螺壳的约定，系统不管这一层。
    func setPermission(app: String, id: String, on: Bool)
    /// 用户点了「今天」里的「打开通知」：系统的询问框紧跟这一下，别的时候不问
    func askNotifications()
}

extension WindowHost {
    public func askPermission(app: String, id: String) {}
    public func askPermission(app: String, id: String, ready: @escaping @MainActor () -> Void) { askPermission(app: app, id: id) }
    public func askSystem(id: String) {}
    public func setPermission(app: String, id: String, on: Bool) {}
    public func askNotifications() {}
}

extension ToolIcon {
    /// 配件标识（主控和核心里用的名字）
    public var accessory: String {
        switch self {
        case .mail: return "luoke-mail"
        case .scan: return "luoke-scan"
        case .mem: return "luoke-mem"
        case .search: return "luoke-search"
        case .ime: return "luoke-ime"
        case .core: return "luoke-core"
        }
    }
}

/// 本体菜单栏图标的菜单里，agent 这边加的几项（luoke-core#68：用本体的菜单，加急事、打开螺壳、暂停提醒一小时）。
/// 本体在菜单每次打开前（`menuNeedsUpdate`）重新取，插在自己的状态行下面；退出、主控的状态由本体自己放。
@MainActor
public enum StatusMenuItems {
    /// 有急事时：「急事」标题、每一件、一条分隔线；然后「打开螺壳」「暂停提醒一小时」（暂停着是「恢复提醒」）。
    /// `openWindow`：本体打开主窗口（点急事、点「打开螺壳」时先调它，再让窗口去「今天」）。
    public static func items(model: WindowModel, openWindow: @escaping () -> Void) -> [NSMenuItem] {
        var out: [NSMenuItem] = []
        for spec in model.statusMenu.items where !["state", "quit"].contains(spec.id) {
            switch spec.kind {
            case .separator:
                if let last = out.last, !last.isSeparatorItem { out.append(.separator()) }
            case .header:
                out.append(NSMenuItem.sectionHeader(title: spec.title))
            case .plain:
                continue
            case .item:
                let action = spec.action
                let item = NSMenuItem(title: spec.title, action: nil, keyEquivalent: "")
                let target = MenuTarget {
                    if action != .pause { openWindow() }
                    model.perform(action)
                }
                item.target = target
                item.action = #selector(MenuTarget.fire(_:))
                item.representedObject = target      // 菜单项不留住 target，自己存一份
                if spec.bold {
                    item.attributedTitle = NSAttributedString(string: spec.title,
                                                              attributes: [.font: NSFont.menuFont(ofSize: 0).bold])
                }
                item.image = image(spec.icon)
                out.append(item)
            }
        }
        while out.last?.isSeparatorItem == true { out.removeLast() }
        while out.first?.isSeparatorItem == true { out.removeFirst() }
        return out
    }

    /// 菜单栏图标要不要多一个小点（有当场说的急事没处理）。平时不带数字。
    public static func hasDot(_ model: WindowModel) -> Bool { model.hasUrgent }

    private static func image(_ icon: MenuIcon?) -> NSImage? {
        let i: NSImage?
        switch icon {
        case .tool(let t):
            i = Resources.image(t.imageName) ?? NSImage(systemSymbolName: "app", accessibilityDescription: t.name)
        case .symbol(let s):
            i = NSImage(systemSymbolName: s, accessibilityDescription: nil)
        case nil:
            i = nil
        }
        guard let copy = i?.copy() as? NSImage else { return nil }
        copy.size = NSSize(width: 16, height: 16)
        return copy
    }
}

private final class MenuTarget: NSObject {
    let run: () -> Void
    init(_ run: @escaping () -> Void) { self.run = run }
    @MainActor @objc func fire(_ sender: Any?) { run() }
}

private extension NSFont {
    var bold: NSFont { NSFontManager.shared.convert(self, toHaveTrait: .boldFontMask) }
}
