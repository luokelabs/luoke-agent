import SwiftUI

// 顶部菜单（螺壳在前台时的完整入口）和菜单栏图标的菜单。都从同一份描述来：
// 真窗口里画成系统菜单，截图时画成一样的图。

public enum MenuAction: Equatable, Sendable {
    case go(Page, String?)
    case ask
    case toggleSidebar
    case openWindow
    case pause
    case urgent(String)
    case none
}

public struct Shortcut: Equatable, Sendable {
    public let key: Character
    public let modifiers: EventModifiers
    public let label: String
}

public enum MenuIcon: Equatable, Sendable {
    case symbol(String)
    case tool(ToolIcon)
}

public struct MenuItemSpec: Identifiable, Equatable, Sendable {
    public enum Kind: Equatable, Sendable { case item, header, separator, plain }

    public let id: String
    public var title: String = ""
    public var icon: MenuIcon?
    public var shortcut: Shortcut?
    public var action: MenuAction = .none
    public var kind: Kind = .item
    public var bold = false

    static func sep(_ id: String) -> MenuItemSpec { MenuItemSpec(id: id, kind: .separator) }
    static func header(_ id: String, _ title: String) -> MenuItemSpec { MenuItemSpec(id: id, title: title, kind: .header) }
    /// 系统自带的一项（隐藏、拷贝……）：照样列出，演示里不做事
    static func plain(_ id: String, _ title: String, _ keys: String? = nil) -> MenuItemSpec {
        MenuItemSpec(id: id, title: title, shortcut: keys.map { Shortcut(key: " ", modifiers: [], label: $0) }, kind: .plain)
    }
}

public struct MenuSpec: Identifiable, Equatable, Sendable {
    public let id: String
    public let title: String
    public let items: [MenuItemSpec]
}

extension WindowModel {
    /// 顶部菜单。「前往」是完整入口；菜单只放入口，不写计数和状态。
    public var topMenus: [MenuSpec] {
        [
            MenuSpec(id: "app", title: "螺壳", items: [
                .plain("about", "关于螺壳"), .sep("s1"),
                MenuItemSpec(id: "settings", title: "设置…", shortcut: Shortcut(key: ",", modifiers: .command, label: "⌘,"), action: .go(.prefs, nil)),
                .plain("update", "检查更新…"), .sep("s2"),
                .plain("hide", "隐藏螺壳", "⌘H"), .plain("hideOthers", "隐藏其他", "⌥⌘H"), .plain("showAll", "全部显示"), .sep("s3"),
                .plain("quit", "退出螺壳", "⌘Q"),
            ]),
            MenuSpec(id: "edit", title: "编辑", items: [
                .plain("undo", "撤销", "⌘Z"), .plain("redo", "重做", "⇧⌘Z"), .sep("s1"),
                .plain("cut", "剪切", "⌘X"), .plain("copy", "拷贝", "⌘C"), .plain("paste", "粘贴", "⌘V"), .plain("all", "全选", "⌘A"),
            ]),
            MenuSpec(id: "view", title: "显示", items: [
                MenuItemSpec(id: "sidebar", title: sidebarMini ? "展开侧栏" : "收起侧栏",
                             shortcut: Shortcut(key: "s", modifiers: [.control, .command], label: "⌃⌘S"), action: .toggleSidebar),
                .sep("s1"), .plain("fullscreen", "进入全屏幕", "fn F"),
            ]),
            MenuSpec(id: "go", title: "前往", items: goItems),
            MenuSpec(id: "window", title: "窗口", items: [
                .plain("min", "最小化", "⌘M"), .plain("zoom", "缩放"), .sep("s1"), .plain("front", "前置全部窗口"), .sep("s2"), .plain("win", "✓ 螺壳"),
            ]),
            MenuSpec(id: "help", title: "帮助", items: [.plain("guide", "螺壳使用说明")]),
        ]
    }

    var goItems: [MenuItemSpec] {
        var items: [MenuItemSpec] = [
            MenuItemSpec(id: "today", title: "今天", icon: .symbol("tray"), shortcut: Shortcut(key: "1", modifiers: .command, label: "⌘1"), action: .go(.today, nil)),
            MenuItemSpec(id: "activity", title: "活动", icon: .symbol("clock.arrow.circlepath"), shortcut: Shortcut(key: "2", modifiers: .command, label: "⌘2"), action: .go(.activity, nil)),
            MenuItemSpec(id: "ask", title: features.contains(.ask) ? "搜索或问螺壳" : "搜索", icon: .symbol("sparkle"), shortcut: Shortcut(key: "k", modifiers: .command, label: "⌘K"), action: .ask),
            .sep("s1"), .header("h-apps", "应用"),
        ].filter { item in
            switch item.action {
            case .go(let p, _): return shows(p)
            case .ask: return features.contains(.ask) || features.contains(.search)
            default: return true
            }
        }
        for a in apps {
            items.append(MenuItemSpec(id: "app-\(a.tool.rawValue)", title: a.tool.name, icon: .tool(a.tool), action: .go(a.id, nil)))
        }
        items += [
            MenuItemSpec(id: "add", title: "添加应用…", icon: .symbol("plus"), action: .go(.apps, nil)),
            .sep("s2"),
            MenuItemSpec(id: "permissions", title: "权限", icon: .symbol("key"), action: .go(.prefs, PrefsTab.permissions.rawValue)),
            MenuItemSpec(id: "model", title: "模型", icon: .symbol("cpu"), action: .go(.prefs, PrefsTab.model.rawValue)),
        ]
        return items
    }

    /// 菜单栏图标的菜单：只放必要的。不列应用、活动、设置。
    public var statusMenu: MenuSpec {
        var items: [MenuItemSpec] = [
            MenuItemSpec(id: "state", title: pausedUntil.map { "就绪 · 提醒暂停到 \($0)" } ?? (engineReady ? "就绪" : "在准备模型"), kind: .plain),
            .sep("s1"),
        ]
        if !urgent.isEmpty {
            items.append(.header("h-urgent", "急事"))
            for u in urgent { items.append(MenuItemSpec(id: "urgent-\(u.id)", title: u.title, icon: .tool(u.tool), action: .urgent(u.id))) }
            items.append(.sep("s2"))
        }
        items += [
            MenuItemSpec(id: "open", title: "打开螺壳", action: .openWindow, bold: true),
            MenuItemSpec(id: "pause", title: pausedUntil == nil ? "暂停提醒一小时" : "恢复提醒", icon: .symbol("bell.slash"), action: .pause),
            .sep("s3"),
            .plain("quit", "退出螺壳", "⌘Q"),
        ]
        return MenuSpec(id: "status", title: "螺壳", items: items)
    }

    /// 菜单里点了一项
    public func perform(_ action: MenuAction) {
        switch action {
        case .go(let p, let tab): go(p, tab: tab)
        case .ask: if features.contains(.ask) { go(.today); openAsk() } else { focusSearch() }
        case .toggleSidebar: toggleSidebar()
        case .openWindow: break
        case .pause: togglePause()
        case .urgent: go(.today)
        case .none: break
        }
    }
}

/// 给螺壳.app（或演示窗口）的顶部菜单。「螺壳」「编辑」「窗口」「帮助」用系统的，这里换掉侧栏那一项、加「前往」。
public struct LuokeCommands: Commands {
    @ObservedObject var model: WindowModel
    /// 菜单里的一项要打开窗口时调（例如窗口关着）
    let openWindow: () -> Void

    public init(model: WindowModel, openWindow: @escaping () -> Void = {}) {
        self.model = model
        self.openWindow = openWindow
    }

    public var body: some Commands {
        CommandGroup(replacing: .sidebar) {
            Button(model.sidebarMini ? "展开侧栏" : "收起侧栏") { model.toggleSidebar() }
                .keyboardShortcut("s", modifiers: [.control, .command])
        }
        CommandMenu("前往") {
            ForEach(model.goItems) { item in
                switch item.kind {
                case .separator: Divider()
                case .header: Text(item.title)
                default:
                    let b = Button(item.title) { openWindow(); model.perform(item.action) }
                    if let s = item.shortcut {
                        b.keyboardShortcut(KeyEquivalent(s.key), modifiers: s.modifiers)
                    } else {
                        b
                    }
                }
            }
        }
    }
}

/// 菜单栏图标点开的菜单（MenuBarExtra 的 .menu 样式里放它）
public struct StatusMenuContent: View {
    @ObservedObject var model: WindowModel
    let openWindow: () -> Void

    public init(model: WindowModel, openWindow: @escaping () -> Void) {
        self.model = model
        self.openWindow = openWindow
    }

    public var body: some View {
        ForEach(model.statusMenu.items) { item in
            switch item.kind {
            case .separator: Divider()
            case .header, .plain: Text(item.title)
            case .item:
                Button(item.title) {
                    if item.action != .pause { openWindow() }
                    model.perform(item.action)
                }
            }
        }
    }
}

// MARK: 截图里画的菜单

/// 一个下拉菜单的样子（照原型 .menu）
struct MenuReplica: View {
    let spec: MenuSpec
    var width: CGFloat = 240
    @Environment(\.lk) private var p

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(spec.items) { item in
                switch item.kind {
                case .separator:
                    Rectangle().fill(p.border).frame(height: 1).padding(.horizontal, 8).padding(.vertical, 4)
                case .header:
                    Text(item.title).font(LKFont.ui(LKType.caption, .medium)).foregroundStyle(p.mutedFg)
                        .padding(.horizontal, 10).padding(.top, 6).padding(.bottom, 2)
                case .item, .plain:
                    HStack(spacing: 8) {
                        switch item.icon {
                        case .symbol(let s)?: Image(systemName: s).font(.system(size: 12)).frame(width: 16)
                        case .tool(let t)?: AppIcon(tool: t, size: 16)
                        case nil: EmptyView()
                        }
                        Text(item.title).font(LKFont.ui(LKType.small, item.bold ? .semibold : .regular))
                            .foregroundStyle(item.id == "state" ? p.mutedFg : p.fg)
                        Spacer(minLength: 12)
                        if let s = item.shortcut { Text(s.label).font(LKFont.ui(LKType.caption)).foregroundStyle(p.mutedFg) }
                    }
                    .padding(.horizontal, 10)
                    .frame(height: 24)
                }
            }
        }
        .padding(5)
        .frame(width: width, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: LKRadius.control, style: .continuous).fill(p.card.opacity(0.96)))
        .overlay(RoundedRectangle(cornerRadius: LKRadius.control, style: .continuous).strokeBorder(p.border, lineWidth: 1))
        .shadow(color: .black.opacity(0.2), radius: 20, y: 12)
    }
}

/// 屏幕顶部的菜单栏：螺壳在前台时（open 是哪个菜单开着），或别的程序在前台时只看螺壳的图标
struct MenuBarScene: View {
    @ObservedObject var model: WindowModel
    /// 顶部菜单开着哪个；nil 就是别的程序在前台、菜单栏图标的菜单开着
    let open: String?
    @Environment(\.lk) private var p

    var body: some View {
        let menus = model.topMenus
        let titles: [(String, String)] = open == nil
            ? [("finder", "访达"), ("f", "文件"), ("e", "编辑"), ("v", "显示"), ("g", "前往"), ("w", "窗口"), ("h", "帮助")]
            : menus.map { ($0.id, $0.title) }
        ZStack(alignment: .topLeading) {
            // 桌面：纯色（渐变会让每张截图大好几倍）
            (p.dark ? Color.hex(0x23272C) : Color.hex(0xD5D2CD))
            VStack(spacing: 0) {
                HStack(spacing: 2) {
                    ForEach(Array(titles.enumerated()), id: \.offset) { i, t in
                        Text(t.1)
                            .font(LKFont.ui(LKType.small, i == 0 ? .semibold : .regular))
                            .padding(.horizontal, 8).frame(height: 22)
                            .background(RoundedRectangle(cornerRadius: LKRadius.small, style: .continuous).fill(t.0 == open ? p.fg.opacity(0.14) : .clear))
                    }
                    Spacer()
                    ZStack(alignment: .topTrailing) {
                        ConchMark(size: 15).padding(3)
                            .background(RoundedRectangle(cornerRadius: LKRadius.small, style: .continuous).fill(open == nil ? p.fg.opacity(0.14) : .clear))
                        if model.hasUrgent {
                            Circle().fill(Color.hex(0xE0605A)).frame(width: 7, height: 7).offset(x: 2, y: -1)
                                .accessibilityLabel("有急事")
                        }
                    }
                    Image(systemName: "magnifyingglass").font(.system(size: 12)).padding(.horizontal, 10)
                    Text("周一 10:02").font(LKFont.ui(LKType.small)).monospacedDigit()
                }
                .padding(.horizontal, 14)
                .frame(height: 26)
                .background(p.card.opacity(0.72))
                Spacer()
            }
            if let open, let spec = menus.first(where: { $0.id == open }) {
                MenuReplica(spec: spec).padding(.leading, menuOffset(open, menus: menus)).padding(.top, 30)
            }
            if open == nil {
                HStack(alignment: .top, spacing: 18) {
                    Spacer()
                    MenuReplica(spec: model.statusMenu, width: 250)
                    if model.hasUrgent, let u = model.urgent.first {
                        HStack(spacing: 10) {
                            AppIcon(tool: .core, size: 34)
                            VStack(alignment: .leading, spacing: 2) {
                                Text("螺壳").font(LKFont.ui(LKType.small, .semibold))
                                Text(u.title).font(LKFont.ui(LKType.small))
                            }
                            Spacer()
                        }
                        .padding(.horizontal, 14).padding(.vertical, 12)
                        .frame(width: 330)
                        .background(RoundedRectangle(cornerRadius: LKRadius.card, style: .continuous).fill(p.card.opacity(0.95)))
                        .shadow(color: .black.opacity(0.18), radius: 15, y: 10)
                    } else {
                        Color.clear.frame(width: 330, height: 1)
                    }
                }
                .padding(.top, 30).padding(.trailing, 14)
            }
        }
        .foregroundStyle(p.fg)
    }

    private func menuOffset(_ id: String, menus: [MenuSpec]) -> CGFloat {
        // 每个菜单名大约多宽：两个汉字 26 + 两边 16 + 间距 2
        var x: CGFloat = 14
        for m in menus {
            if m.id == id { return x - 4 }
            x += CGFloat(m.title.count) * 13 + 18
        }
        return x
    }
}
