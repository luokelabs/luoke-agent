import Foundation

// 本体（螺壳.app）给窗口的数据：「应用管理」和「设置」里本体管的那几块（docs/界面接口.md §16，设计规范 §18.6、§18.7）。
// 本体只给数据、收动作，窗口自己画；会删东西的（卸载、删除数据、卸载螺壳）由本体自己的确认页走，窗口不另弹。

// MARK: 应用管理

public struct HostApps: Equatable {
    public var rows: [HostAppRow]
    /// 做完一个动作的结果（「xx 已重新启动」「没能……：原因」），画在页底
    public var notice: HostAppsNotice?

    public init(rows: [HostAppRow], notice: HostAppsNotice? = nil) {
        self.rows = rows
        self.notice = notice
    }
}

public struct HostAppsNotice: Equatable {
    public var text: String
    public var ok: Bool
    /// 结果后面跟的一个按钮（输入法重启后的「打开键盘设置」）：标题和要做的动作，动作对的是 `app`
    public var action: (label: String, app: String, action: HostAppAction)?

    public init(text: String, ok: Bool, action: (label: String, app: String, action: HostAppAction)? = nil) {
        self.text = text
        self.ok = ok
        self.action = action
    }

    public static func == (a: HostAppsNotice, b: HostAppsNotice) -> Bool {
        a.text == b.text && a.ok == b.ok && a.action?.label == b.action?.label && a.action?.app == b.action?.app
            && a.action?.action == b.action?.action
    }
}

public enum HostAppAction: Hashable, Sendable {
    case enable, disable, restart, deleteData, uninstall
    /// 回到上一个版本（带版本号）
    case rollback(to: String)
    /// 输入法：打开系统的键盘设置
    case openKeyboardSettings

    public var title: String {
        switch self {
        case .enable: return "开启"
        case .disable: return "停用"
        case .restart: return "重新启动"
        case .deleteData: return "删除数据"
        case .uninstall: return "卸载"
        case .rollback(let v): return "回退到 \(v)"
        case .openKeyboardSettings: return "打开键盘设置"
        }
    }
}

public struct HostAppRow: Identifiable, Equatable {
    public enum Origin: Sendable { case luoke, poweredBy }
    public enum State: Equatable {
        case installed, disabled, installable
        case update(to: String)
        /// 装不了：例如内存不够这一档
        case unavailable(reason: String)
        /// 正在装、升级、下载：`progress` 0…1，不知道就是 nil
        case working(label: String, progress: Double?)
    }

    /// 配件标识：luoke-mail……
    public let id: String
    public var tool: ToolIcon
    public var name: String
    public var tagline: String
    public var version: String
    public var origin: Origin
    public var state: State
    /// 随螺壳装的：不显示卸载
    public var bundled: Bool
    /// 没装的：大小、要哪一档、要开什么（装好的不用）
    public var facts: [String]
    /// 本体按状态给出现在能做的；都收在「更多」里，卸载在最后
    public var actions: [HostAppAction]

    public init(id: String, tool: ToolIcon, name: String? = nil, tagline: String, version: String, origin: Origin = .luoke,
                state: State, bundled: Bool = false, facts: [String] = [], actions: [HostAppAction] = []) {
        self.id = id
        self.tool = tool
        self.name = name ?? tool.name
        self.tagline = tagline
        self.version = version
        self.origin = origin
        self.state = state
        self.bundled = bundled
        self.facts = facts
        self.actions = actions
    }

    public var canUninstall: Bool { !bundled && actions.contains(.uninstall) }
    /// 停用了的应用：「开启」直接放在行上（不收进「更多」）
    public var enableOnRow: Bool { state == .disabled && actions.contains(.enable) }
    /// 「更多」里的动作：行上按钮之外的都在这里，卸载放最后（随螺壳装的没有卸载）。和别的应用一样都收进菜单，
    /// 不单给卸载一个行尾图标（负责人 11-15）
    public var moreActions: [HostAppAction] {
        actions.filter { $0 != .uninstall && !($0 == .enable && enableOnRow) } + (canUninstall ? [.uninstall] : [])
    }
}

// MARK: 设置

public struct HostSettings: Equatable {
    public var general: HostGeneral
    public var models: HostModels
    public var privacy: HostPrivacy

    public init(general: HostGeneral, models: HostModels, privacy: HostPrivacy) {
        self.general = general
        self.models = models
        self.privacy = privacy
    }
}

public enum HostLoginItem: Equatable, Sendable {
    case on, off
    /// 要用户去「系统设置 › 通用 › 登录项」允许一次
    case requiresApproval
    case error(String)
}

public enum HostPowerMode: String, CaseIterable, Sendable {
    case full, balanced, quiet

    public var title: String {
        switch self {
        case .full: return "全速"
        case .balanced: return "均衡"
        case .quiet: return "静音"
        }
    }
}

public enum HostBatteryMode: String, CaseIterable, Sendable {
    case normal, light
    case noLargeModel = "no_large_model"

    public var title: String {
        switch self {
        case .normal: return "照常运行"
        case .light: return "降低负载"
        case .noLargeModel: return "不运行大模型"
        }
    }
}

public struct HostGeneral: Equatable {
    public var loginItem: HostLoginItem
    /// 显示用的版本（本机版写「local-…（本机版，没上传）」）
    public var currentVersion: String
    public var latestVersion: String?
    public var lastChecked: Date?
    public var powerMode: HostPowerMode
    public var batteryMode: HostBatteryMode
    /// 每天自动检查更新开没开（2026-11-16 加）；旧的本体不给是 nil，这一行不画
    public var autoCheck: Bool?
    /// 低电量模式时暂停后台开没开（2026-11-21 加）；旧的本体不给是 nil，这一行不画
    public var pauseOnLowPower: Bool?

    public init(loginItem: HostLoginItem, currentVersion: String, latestVersion: String? = nil, lastChecked: Date? = nil,
                powerMode: HostPowerMode, batteryMode: HostBatteryMode, autoCheck: Bool? = nil, pauseOnLowPower: Bool? = nil) {
        self.loginItem = loginItem
        self.currentVersion = currentVersion
        self.latestVersion = latestVersion
        self.lastChecked = lastChecked
        self.powerMode = powerMode
        self.batteryMode = batteryMode
        self.autoCheck = autoCheck
        self.pauseOnLowPower = pauseOnLowPower
    }
}

public struct HostTier: Identifiable, Equatable {
    public enum State: Equatable {
        case inUse
        /// 已选了，下好后自动切换
        case switching(progress: Double?)
        /// 没下载：要下载多少 GB
        case available(needGB: Double)
        case failed(reason: String)
    }

    /// 这一档是什么（主控照配方挑：这台 Mac 跑得动的最大的底座是 full，更小的是 lighter）；名字和一句话由窗口照它写
    public enum Kind: String, Sendable { case full, lighter }

    public let id: String
    /// 主控写的名字（旧的本体给；有了 `kind` 窗口不再用它）
    public var title: String
    public var model: String
    public var sizeGB: Double
    public var state: State
    public var kind: Kind
    /// 现在用的就是这一档（2026-11-16 加）：在补下模型、没下成时也照样标「使用中」
    public var current: Bool
    /// 没下成时再下一次有没有用（磁盘不够的没用）
    public var canRetry: Bool

    public init(id: String, title: String, model: String, sizeGB: Double, state: State, kind: Kind = .full,
                current: Bool = false, canRetry: Bool = true) {
        self.id = id
        self.title = title
        self.model = model
        self.sizeGB = sizeGB
        self.state = state
        self.kind = kind
        self.current = current || state == .inUse
        self.canRetry = canRetry
    }

    /// 设置 · 模型上的名字和一句话（走查重画稿：「精简版 · 更省电、更快」「完整版 · 更懂复杂的事」）
    public var shownTitle: String { kind == .full ? "完整版" : "精简版" }
    public var blurb: String { kind == .full ? "更懂复杂的事" : "更省电、更快" }
}

public struct HostModelRow: Identifiable, Equatable {
    public var id: String { name }
    public var name: String
    /// 主控写的用途（旧的本体给；有了 `base`、`accessories` 窗口照它们写）
    public var purpose: String
    public var params: String
    public var quant: String
    public var sizeGB: Double
    /// 是哪一档的底座（不是底座是 nil）
    public var base: HostTier.Kind?
    /// 专用给哪些配件（配件标识，按配方顺序）
    public var accessories: [String]

    public init(name: String, purpose: String, params: String, quant: String, sizeGB: Double,
                base: HostTier.Kind? = nil, accessories: [String] = []) {
        self.name = name
        self.purpose = purpose
        self.params = params
        self.quant = quant
        self.sizeGB = sizeGB
        self.base = base
        self.accessories = accessories
    }

    /// 配件标识 → 模型清单「用途」里的词
    static let useWords = ["luoke-mail": "邮件", "luoke-mem": "记忆", "luoke-ime": "输入法", "luoke-search": "搜索", "luoke-scan": "扫描"]

    /// 设置 · 模型 · 模型清单的用途（走查重画稿：「邮件、记忆、对话」「搜索」「输入法」）：底座是邮件、记忆、对话，专用的写配件
    public var shownPurpose: String {
        var words: [String] = base == nil ? [] : ["邮件", "记忆", "对话"]
        for a in accessories { if let w = Self.useWords[a], !words.contains(w) { words.append(w) } }
        return words.isEmpty ? purpose : words.joined(separator: "、")
    }
}

public struct HostLocalAPI: Equatable {
    public var enabled: Bool
    public var address: String
    public var port: Int
    public var models: [String]
    /// 密钥不进数据：只告诉窗口有没有
    public var hasKey: Bool
    public var error: String?

    public init(enabled: Bool, address: String, port: Int, models: [String] = [], hasKey: Bool = false, error: String? = nil) {
        self.enabled = enabled
        self.address = address
        self.port = port
        self.models = models
        self.hasKey = hasKey
        self.error = error
    }
}

public struct HostModels: Equatable {
    public var tiers: [HostTier]
    public var catalog: [HostModelRow]
    /// 按流量计费或低数据模式：不自动下载
    public var metered: Bool
    public var advanced: HostLocalAPI

    public init(tiers: [HostTier], catalog: [HostModelRow], metered: Bool = false, advanced: HostLocalAPI) {
        self.tiers = tiers
        self.catalog = catalog
        self.metered = metered
        self.advanced = advanced
    }
}

public struct HostSystemCheck: Equatable {
    /// 是哪一种权限：和应用清单里权限的 `id` 同一套（`fda`、`photos`），通知是 `notifications`。
    /// 权限页按它去重、认通知那一行，不按显示的名字比
    public var key: String?
    public var name: String
    public var ok: Bool
    public var detail: String?

    public init(key: String? = nil, name: String, ok: Bool, detail: String? = nil) {
        self.key = key
        self.name = name
        self.ok = ok
        self.detail = detail
    }

    /// 通知那一行的 key
    public static let notifications = "notifications"
    /// 通知设置的那一页
    public static let notificationSettings = URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension")!
}

public struct HostPrivacy: Equatable {
    /// 最上面那一句：数据在哪
    public var dataLine: String
    public var systemChecks: [HostSystemCheck]
    public var canExport: Bool

    public init(dataLine: String, systemChecks: [HostSystemCheck] = [], canExport: Bool = true) {
        self.dataLine = dataLine
        self.systemChecks = systemChecks
        self.canExport = canExport
    }
}

/// 用户在设置里改了一项：类型对不上编译就报（不用等主控回 400）
public enum HostSettingChange: Equatable, Sendable {
    case loginItem(Bool)
    case powerMode(HostPowerMode)
    case batteryMode(HostBatteryMode)
    case tier(String)
    case localAPI(Bool)
    /// 每天自动检查更新（2026-11-16 加）
    case autoCheckUpdates(Bool)
    /// 低电量模式时暂停后台（2026-11-21 加）
    case pauseOnLowPower(Bool)
}
