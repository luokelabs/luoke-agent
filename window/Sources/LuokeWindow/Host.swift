import AppKit
import SwiftUI

/// 本体自己的一屏（检查更新、卸载、开启搜索、首次设置……），画在主窗口里（11-10 定：螺壳只有一个窗口，本体的界面都不另开窗口）。
/// 本体调 `WindowModel.present(_:)` 放上来、`dismissHost(_:)` 收起；用户自己离开（卡片的 ×、Esc，点侧栏、「前往」）时窗口先问
/// `WindowHost.hostPageCanLeave`，走了再报 `hostPageClosed`。三种放法：
/// - `page`：占内容区，上面是标题，没有「返回」（和 agent 自己的页一样）：点侧栏离开，或者点本体界面里自己的按钮；
///   底部的搜索、问螺壳不画，侧栏哪一行都不亮。
/// - `card`：浮在整个窗口上（盖着 `takeover` 也行），底下压暗，居中一张卡片，标题右边一个 ×，Esc 同 ×；深色下描一圈细边。
/// - `takeover`：整个窗口都是它（首次设置、升级）：不画侧栏、搜索、问螺壳，没有收起侧栏的按钮，换页和「前往」都不动；
///   内容顶到窗口上沿，红黄绿压在左上角，本体的界面照 `lkHostTopInset` 让开。`title` 不画（内容自己有标题），给读屏用。
public struct HostPage {
    public enum Style: Sendable { case page, card, takeover }
    /// 本体自己认的编号（`update`、`uninstall`……）：同一个编号再放一次是换内容
    public let id: String
    public let title: String
    public let style: Style
    public let content: AnyView

    public init(id: String, title: String, style: Style = .page, content: AnyView) {
        self.id = id
        self.title = title
        self.style = style
        self.content = content
    }

    /// `.takeover` 顶到窗口上沿，红黄绿压在左上角：本体的界面在顶上让开这么高（侧栏的 logo 也在这下面）。
    /// 画进来时环境里的 `lkHostTopInset` 也是它；别的放法是 0
    public static let lightsInset: CGFloat = WindowControls.lightsCenterY + WindowControls.height / 2 + LKSpace.x3
}

private struct HostTopInsetKey: EnvironmentKey { static let defaultValue: CGFloat = 0 }

extension EnvironmentValues {
    /// 本体的界面顶上要让开多高（`.takeover` 时是 `HostPage.lightsInset`，红黄绿在那里）
    public var lkHostTopInset: CGFloat {
        get { self[HostTopInsetKey.self] }
        set { self[HostTopInsetKey.self] = newValue }
    }
}

/// 螺壳.app（本体）接进主窗口的事（luoke-core#68）：主窗口画 agent 的页（今天、应用页、「设置 · 提醒」「设置 · 权限」），
/// 模型、隐私、添加应用、升级归本体。螺壳只有一个窗口（11-10 定）：本体的界面都画在主窗口里——设置的模型、隐私
/// （`settingsContent`）、添加应用（`appsContent`），别的（检查更新、卸载、删除数据、开启搜索、要权限、首次设置、升级）经
/// `WindowModel.present(_:)`（`HostPage`）。老的本体没给界面时才打开它自己的窗口。本体实现这个协议，设到 `WindowModel.host`；
/// 没设时窗口自己画这几页（示例）。
@MainActor
public protocol WindowHost: AnyObject {
    /// 「设置」里模型、隐私这两个标签的内容：本体自己的设置界面，画在窗口的设置里（11-09 负责人定，不再另弹窗口）。
    /// nil 就照旧打开本体的窗口（`openModelSettings`、`openPrivacySettings`）
    func settingsContent(_ tab: PrefsTab) -> AnyView?
    /// 「设置 · 模型」、侧栏底部的模型名、「前往 → 模型」：本体没给界面时打开它的窗口
    func openModelSettings()
    /// 「设置 · 隐私」
    func openPrivacySettings()
    /// 「添加应用」页的内容：本体的应用目录（装、升级、开启、停用、换回上一版），画在主窗口的「添加应用」页里。
    /// nil 就照旧打开本体的窗口（`openAddApps`）
    func appsContent() -> AnyView?
    /// 「添加应用」（侧栏、「前往」菜单、应用页）：本体没给界面时打开它的窗口
    func openAddApps()
    /// 某个应用的「升级」：配件标识（luoke-mail……）。本体给了 `appsContent` 时窗口先翻到「添加应用」页再调它
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
    /// 用户要离开本体的这一屏（`HostPage` 的编号）：×、Esc、点侧栏、「前往」、点通知。答 false 窗口不动
    /// （正在删、正在升级）；答 true 窗口收起它、调 `hostPageClosed`，再去用户要去的地方
    func hostPageCanLeave(_ id: String) -> Bool
    /// 用户离开了这一屏。本体自己 `dismissHost` 收起的不调
    func hostPageClosed(_ id: String)
}

extension WindowHost {
    public func settingsContent(_ tab: PrefsTab) -> AnyView? { nil }
    public func appsContent() -> AnyView? { nil }
    public func askPermission(app: String, id: String) {}
    public func askPermission(app: String, id: String, ready: @escaping @MainActor () -> Void) { askPermission(app: app, id: id) }
    public func askSystem(id: String) {}
    public func setPermission(app: String, id: String, on: Bool) {}
    public func askNotifications() {}
    public func hostPageCanLeave(_ id: String) -> Bool { true }
    public func hostPageClosed(_ id: String) {}
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
                let item = NSMenuItem(title: spec.shortTitle, action: nil, keyEquivalent: "")
                item.toolTip = spec.fullTitleTip
                let target = MenuTarget {
                    if action != .pause { openWindow() }
                    model.perform(action)
                }
                item.target = target
                item.action = #selector(MenuTarget.fire(_:))
                item.representedObject = target      // 菜单项不留住 target，自己存一份
                if spec.bold {
                    item.attributedTitle = NSAttributedString(string: spec.shortTitle,
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

    /// 菜单栏图标要不要多一个小点（有当场说的急事没处理，主动提醒开着；暂停着照旧有）。平时不带数字。
    /// 本体在 `urgent` 变了时重画图标：核心每份 feed 都重新给 `urgent`，小点跟着那一份 feed 的 `dot`。
    public static func hasDot(_ model: WindowModel) -> Bool { model.hasDot }

    private static func image(_ icon: MenuIcon?) -> NSImage? {
        let i: NSImage?
        switch icon {
        case .tool(let t):
            i = Resources.image(t.imageName) ?? NSImage(systemSymbolName: "app", accessibilityDescription: t.name)
        case .symbol(let s):   // Lucide 的名字（菜单里的图标和窗口一套）
            i = Lucide.nsImage(s)
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
