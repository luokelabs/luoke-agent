import Foundation
import LuokeA2UI
import LuokeA2UICore
import SwiftUI

public enum Page: String, CaseIterable, Sendable {
    case today, activity, mail, scan, mem, searchApp, ime, search, apps, prefs, chat

    public var title: String {
        switch self {
        case .today: return "今天"
        case .activity: return "活动"
        case .mail: return ToolIcon.mail.name
        case .scan: return ToolIcon.scan.name
        case .mem: return ToolIcon.mem.name
        case .searchApp: return ToolIcon.search.name
        case .ime: return ToolIcon.ime.name
        case .search: return "搜索"
        case .apps: return "添加应用"
        case .prefs: return "设置"
        case .chat: return "对话"
        }
    }

    /// 应用的页是哪个应用的（别的页是 nil）
    var appTool: ToolIcon? {
        switch self {
        case .mail: return .mail
        case .scan: return .scan
        case .mem: return .mem
        case .searchApp: return .search
        case .ime: return .ime
        default: return nil
        }
    }
}

public enum PrefsTab: String, CaseIterable, Sendable {
    case alerts, display, permissions, model, privacy

    public var title: String {
        switch self {
        case .alerts: return "提醒"
        case .display: return "显示"
        case .permissions: return "权限"
        case .model: return "模型"
        case .privacy: return "隐私"
        }
    }
}

/// 「今天」的密度（设置 · 显示）：标准是卡片，紧凑是一张表。只记在这台 Mac 的这个窗口里
public enum Density: String, CaseIterable, Sendable {
    case standard, compact

    public var title: String { self == .standard ? "标准" : "紧凑" }
}

/// 「一件件处理」：进来时要你决定的那几件，一次摆一件。答了的从 `cards` 里走掉，跳过的记在这里
public struct FocusSession: Equatable {
    /// 这一轮的几件，进来时定下。工具换掉一张卡片时，新的那张顶在旧的位置；工具收走的从这里去掉
    public internal(set) var ids: [String]
    public internal(set) var skipped: [String] = []
    /// 用户在一件件处理里点过的：只有这些不见了才算答了
    public internal(set) var tapped: Set<String> = []
    /// 上一下是键盘上按的：换下一件只淡入淡出
    public internal(set) var viaKey = false
    /// 从「按类处理」进来的：只走这一类（`DecideCategory.id`）、顶上写它的名字；从「一件件处理」进来的是 nil，走全部
    public internal(set) var category: String? = nil
    public internal(set) var categoryName: String? = nil
}

/// 简报：从「今天」里现有的拼出来，打开时定下；答了的那件在简报里划掉
public struct BriefNote: Equatable {
    public struct Pending: Equatable, Identifiable {
        public let id: String
        public let title: String
    }

    /// 几点的简报
    public let time: String
    /// 「已经替你做了」的几行
    public let done: [String]
    /// 急事的标题
    public let urgent: [String]
    /// 要你决定的标题，点了跳到那张卡片
    public let pending: [Pending]

    /// 「今早的简报」「今晚的简报」
    public var title: String { (Int(time.prefix(2)) ?? 8) < 12 ? "今早的简报" : "今晚的简报" }

    /// 一句话（通知、设置里的预览、紧凑的那一行）：和核心发的通知一样的拼法
    public var sentence: String {
        var parts: [String] = []
        if !pending.isEmpty {
            parts.append("还有 \(pending.count) 件等你：" + pending.prefix(3).map { Self.phrase($0.title) }.joined(separator: "、")
                         + (pending.count > 3 ? "等" : ""))
        }
        if let u = urgent.first { parts.append("急事：\(Self.phrase(u))" + (urgent.count > 1 ? "等 \(urgent.count) 件" : "")) }
        if !done.isEmpty { parts.append("替你做了 \(done.count) 件") }
        return parts.isEmpty ? "要你决定的都处理完了。" : parts.joined(separator: "；") + "。"
    }

    /// 标题拼进句子里：去掉末尾的句号、分号、逗号
    static func phrase(_ t: String) -> String {
        var s = t
        while let last = s.last, "。.；;，, ？?！!".contains(last) { s.removeLast() }
        return s
    }
}

/// 下一次画出来的内容怎么进场（换了页、从「一件件处理」回来）
public enum Entrance: Sendable { case none, page, fromFocus }

/// 侧栏「应用」下面的一行：装好的应用
public struct AppEntry: Identifiable, Equatable {
    public let id: Page
    public let tool: ToolIcon
    public var version: String
    public var update: String?
}

/// 螺壳.app 装着的一个应用（`WindowModel.setInstalledApps`）：配件标识、版本、发布清单里有没有更新的
public struct InstalledApp: Equatable, Sendable {
    public let accessory: String
    public let version: String
    public let update: String?
    public init(accessory: String, version: String, update: String? = nil) {
        self.accessory = accessory
        self.version = version
        self.update = update
    }
}

/// 急事：「今天」最上面的横幅，菜单栏图标的那个点
public struct UrgentItem: Identifiable, Equatable {
    public let id: String
    public let tool: ToolIcon
    public let title: String
    public let time: String
    public let primary: String
    public let primarySymbol: String?
    public let secondary: String
    /// 接上核心时：工具写的那张卡片（按钮在卡片里）；示例数据没有，用上面的两个按钮
    public var surface: SurfaceModel? = nil
    /// 哪一类（核心的 `cards` 给的，例如邮件的 suspicious）：同一个应用同一类的放成一叠
    public var kind: String? = nil

    public static func == (a: UrgentItem, b: UrgentItem) -> Bool {
        a.id == b.id && a.tool == b.tool && a.title == b.title && a.time == b.time && a.primary == b.primary
            && a.primarySymbol == b.primarySymbol && a.secondary == b.secondary && a.surface === b.surface && a.kind == b.kind
    }
}

/// 菜单栏里点了一行急事以后，「今天」要滚到哪一叠（`token` 每次点都不一样，同一行点两次也滚）
public struct UrgentJump: Equatable, Sendable {
    public let id: String
    public let token: Int
}

/// 「要你决定」里的一张卡片：工具（或 agent）写的 A2UI，窗口画框和应用图标
public struct TodayCard: Identifiable {
    public let id: String
    public let tool: ToolIcon
    public let time: String?
    public let surface: SurfaceModel
    /// 一句话的标题（核心的 `cards` 给的），菜单和读屏用
    public var title: String? = nil
    /// 哪一类（核心的 `cards` 给的）：同一个应用同一类的放成一叠
    public var kind: String? = nil

    /// 标题：核心给的，没有就取卡片上第一行标题
    @MainActor public var displayTitle: String {
        if let t = title, !t.isEmpty { return t }
        return SurfaceDigest(surface.surface).title
    }
}

/// 相近的放一叠（负责人 11-06）：同一个应用、同一类（`kind`；没有类就看标题一样）的放在一起，先露第一张。
/// 次序照第一张出现的位置
enum TodayStack {
    static func key(_ tool: ToolIcon, _ kind: String?, _ title: String?) -> String {
        "\(tool.name)|" + ((kind?.isEmpty == false ? kind : nil).map { "k:" + $0 } ?? "t:" + (title ?? ""))
    }

    static func group<T>(_ items: [T], key: (T) -> String) -> [[T]] {
        var order: [String] = [], groups: [String: [T]] = [:]
        for x in items {
            let k = key(x)
            if groups[k] == nil { order.append(k) }
            groups[k, default: []].append(x)
        }
        return order.map { groups[$0]! }
    }

    /// 页面上最少几张才摞：两张摞起来不省地方，还要多点一下，就照常摆开（菜单里两条也合成一行，不用这个）
    static let pageMin = 3

    /// 不到 `pageMin` 张的一叠拆开，一张一叠，次序不变
    static func spread<T>(_ stacks: [[T]], min: Int = pageMin) -> [[T]] {
        stacks.flatMap { $0.count >= min ? [$0] : $0.map { [$0] } }
    }

    static func urgent(_ items: [UrgentItem]) -> [[UrgentItem]] { group(items) { key($0.tool, $0.kind, $0.title) } }
    static func cards(_ items: [TodayCard]) -> [[TodayCard]] { group(items) { key($0.tool, $0.kind, $0.title) } }

    /// 量词：邮件论封，扫描论样（和扫描页一样），别的论件
    static func unit(_ tool: ToolIcon) -> String { tool == .mail ? "封" : tool == .scan ? "样" : "件" }

    /// 一叠下面「还有 N …」写什么：标题是「一封可疑邮件（…）」这样「一X」开头的，写「4 封可疑邮件」；
    /// 「可疑邮件：某银行…」这样冒号前是一个短的类别的，写「4 封可疑邮件」；别的写不出，nil
    static func what(_ title: String, _ n: Int, unit: String = "件") -> String? {
        guard n > 0 else { return nil }
        var t = title
        if let i = t.firstIndex(of: "（"), t.hasSuffix("）") { t = String(t[..<i]) }   // 括号里是这一封的
        if t.hasPrefix("一"), let m = t.dropFirst().first, "封件个张条项".contains(m) { return "\(n) " + t.dropFirst() }
        // 「可疑邮件「某银行：账户已冻结」」（邮件助手 0.19.4x 起引这一封的标题）：书名号里是这一封的、里面也可能有冒号，
        // 前面是哪一类。只认书名号收尾的：「下载里的「a.com」可能是病毒」不算
        if t.hasSuffix("」"), let a = t.firstIndex(of: "「"), case let kind = t[..<a], (2...8).contains(kind.count),
           !kind.contains("："), !kind.hasSuffix("的") {
            return "\(n) \(unit)\(kind)"
        }
        if let i = t.firstIndex(of: "："), case let kind = t[..<i], (2...8).contains(kind.count) { return "\(n) \(unit)\(kind)" }
        // 核心给的卡片标题「1 封新邮件要处理」（或「这 1 封要你处理」）→「4 封新邮件要处理」：不写「同类的」，
        // 要往上看第一张才知道是哪一类
        if let m = t.wholeMatch(of: #/(?:这 ?)?\d+ ?([封件样张])(.{2,10})/#) { return "\(n) \(m.1)\(m.2)" }
        return nil
    }

    /// 一叠在菜单里的一行：「一封可疑邮件（…）」× 8 →「8 封可疑邮件」；「下载里的「a.com」可能是病毒」× 2 →「下载里 2 样可能是病毒」
    /// （书名号里是那一个的名字，合起来就换成个数）；别的写成「2 件：…」（菜单会截掉长字的尾巴，件数放前面）
    static func countTitle(_ title: String, _ n: Int, unit: String = "件") -> String {
        guard n > 1 else { return title }
        if let w = what(title, n, unit: unit) { return w }   // 「可疑邮件：某银行：账户已冻结」× 8 →「8 封可疑邮件」，和一叠下面写的一样
        var t = title
        if let i = t.firstIndex(of: "（"), t.hasSuffix("）") { t = String(t[..<i]) }   // 括号里是这一封的（邮箱、文件名），合起来就不对了
        if t.hasPrefix("一"), let m = t.dropFirst().first, "封件个张条项".contains(m) { return "\(n) " + t.dropFirst() }
        if let a = t.range(of: "「"), let b = t.range(of: "」", range: a.upperBound..<t.endIndex) {
            var lo = a.lowerBound
            if lo > t.startIndex, t[t.index(before: lo)] == "的" { lo = t.index(before: lo) }
            return String(t[..<lo]) + " \(n) \(unit)" + String(t[b.upperBound...])
        }
        return "\(n) \(unit)：\(t)"
    }
}

/// 「要你决定」里的一类：同一个应用、同一类（和一叠的分法一样，见 `TodayStack`）。「今天」上同一类的挨着摆，
/// 「一件件处理」照这个次序走；有两类以上时，段标题下面「按类处理」列出不止一件的那几类，点了只走那一类
public struct DecideCategory: Identifiable, Equatable {
    /// `TodayStack.key`
    public let id: String
    public let tool: ToolIcon
    /// 这一类叫什么：工具清单 `reports` 里的名字（和「设置 · 提醒 · 每类事」同一个），没有就是应用的名字
    public let name: String
    /// 这一类的卡片，次序照「今天」
    public let ids: [String]
}

/// 「已经替你做了」的一行
/// 做完的卡片的分组（工具写在卡片 root 上的 `group`，工具协议 §4）：同一个键的在「已经替你做了」里合成一行
public struct DoneGroup: Equatable {
    public let key: String
    /// 这一行怎么写，`{n}` 换成合起来的数
    public let text: String
    public let n: Int
    /// 前面的名字（可疑邮件）、后面的标签（邮箱地址）
    public let label: String?
    public let badge: String?
}

public struct DoneRow: Identifiable, Equatable {
    public let id: String
    public let tool: ToolIcon
    public var text: String
    public let time: String
    public var undoLabel: String?
    public var undone = false
    /// 接上核心时：点完的那张卡片（结果和撤销在卡片里）
    public var surface: SurfaceModel? = nil
    public var group: DoneGroup? = nil
    /// 合成一行时合进来的每一张（第一张也在里面）；撤销这一行就把它们一张张撤销
    public var members: [DoneRow] = []

    public static func == (a: DoneRow, b: DoneRow) -> Bool {
        a.id == b.id && a.tool == b.tool && a.text == b.text && a.time == b.time && a.undoLabel == b.undoLabel
            && a.undone == b.undone && a.surface === b.surface && a.group == b.group && a.members.map(\.id) == b.members.map(\.id)
    }

    /// 「已经替你做了」照显示的样子：同一组的合成一行（「可疑邮件 · 已移到垃圾邮件 4 封」，数字加起来），编号用第一张的；
    /// 没分组的照旧一张一行
    static func merged(_ rows: [DoneRow]) -> [DoneRow] {
        var out: [DoneRow] = []
        var at: [String: Int] = [:]
        for r in rows {
            guard let g = r.group else { out.append(r); continue }
            if let i = at[g.key] { out[i].members.append(r); continue }
            at[g.key] = out.count
            var first = r
            first.members = [r]
            out.append(first)
        }
        return out.map { row in
            guard let g = row.group else { return row }
            var m = row
            let n = row.members.reduce(0) { $0 + ($1.group?.n ?? 0) }
            m.text = [g.label, g.text.replacingOccurrences(of: "{n}", with: "\(n)")].compactMap { $0 }.joined(separator: " · ")
            m.undone = row.members.allSatisfy(\.undone)
            return m
        }
    }
}

/// 「顺便看看」的一行（有新版本这类主控的行，订阅精选这类不急的）
public struct QuietRow: Identifiable, Equatable {
    public let id: String
    public let tool: ToolIcon
    public let text: String
    public var sub: String?
    public var action: String?
    public var done = false
    /// 接上核心时：不急的那张卡片
    public var surface: SurfaceModel? = nil

    public static func == (a: QuietRow, b: QuietRow) -> Bool {
        a.id == b.id && a.tool == b.tool && a.text == b.text && a.sub == b.sub && a.action == b.action && a.done == b.done
            && a.surface === b.surface
    }
}

/// 「活动」时间线上的点：急事红，刚做的用强调色
public enum ActivityMark: Sendable { case plain, urgent, new }

public struct ActivityRow: Identifiable, Equatable {
    public let id: String
    public let day: String
    public let time: String
    public let tool: ToolIcon
    /// 自动做的（不是你点的）
    public let auto: Bool
    public let text: String
    public var undoLabel: String?
    public var undone = false
    public var mark: ActivityMark = .plain
}

/// 每类事怎么说
public enum Level: String, CaseIterable, Sendable {
    case now, brief, window, off

    public var title: String {
        switch self {
        case .now: return "当场说"
        case .brief: return "放进简报"
        case .window: return "只放在窗口里"
        case .off: return "不要"
        }
    }
}

public struct KindSetting: Identifiable, Equatable {
    public let id: String
    public let tool: ToolIcon
    public let title: String
    public var level: Level
}

/// 简报什么时候发（11-03 主窗口第一版：默认每天早上）
public enum BriefMode: String, CaseIterable, Sendable {
    case morning = "每天早上"
    case twice = "早晚各一次"
    case onOpen = "只在我打开时"

    /// 核心 `/settings` 里的写法
    var agentValue: String {
        switch self {
        case .morning: return "morning"
        case .twice: return "twice"
        case .onOpen: return "on_open"
        }
    }
}

public enum Energy: String, CaseIterable, Sendable {
    case quiet = "安静"
    case balanced = "均衡"
    case full = "全速"
}

public struct ModelTier: Identifiable, Equatable {
    public let id: String
    public let title: String
    public let model: String
    public let size: String
}

public enum PermState: Equatable { case granted, waiting, notYet }

public struct PermissionRow: Identifiable, Equatable {
    public let id: String
    public let owner: ToolIcon
    public let title: String
    public var sub: String?
    public var state: PermState
}

public struct DelegateRow: Identifiable, Equatable {
    public let id: String
    public let tool: ToolIcon
    public let title: String
    public var on: Bool
}

public struct EachTimeRow: Identifiable, Equatable {
    public let id: String
    public let tool: ToolIcon
    public let title: String
    public let why: String
}

public struct SearchHit: Identifiable, Equatable {
    public let id: String
    public let tool: ToolIcon
    public let title: String
    public let meta: String
    public let snippet: String
    public var similar = false
    public var reveal = false
}

public struct SearchSection: Identifiable, Equatable {
    public let id: String
    public let title: String
    public var count: Int?
    public var hits: [SearchHit]
    /// 这个来源还没允许（照片）：在结果里问
    public var needsPermission: String?
}

public enum CatalogState: Equatable { case update(String), installable, installed }

public struct CatalogApp: Identifiable, Equatable {
    public let id: String
    public let tool: ToolIcon
    public let tagline: String
    public let version: String
    public var state: CatalogState
    public var facts: [String] = []
}

/// 应用的基础页（以后由工具出 A2UI：service.pages）
public struct AppPageData: Equatable {
    public struct Stat: Equatable { public let key: String; public let value: String }
    public struct Line: Equatable, Identifiable {
        public let id: String
        public let title: String
        public var badge: String?
        public var meta: String?
        public var action: String?
        /// 第二个按钮（记忆想问的：对、不对）
        public var action2: String?
    }

    public let tabs: [(id: String, title: String, external: Bool)]
    public let stats: [Stat]
    public let listTitle: String
    public let lines: [Line]
    public var latest: Bool
    /// 应用有没有自己的界面：邮件助手、记忆有，扫描没有。窗口不打开它（11-09 定），只用来核对
    public var hasUI: Bool = true

    public static func == (a: AppPageData, b: AppPageData) -> Bool {
        a.stats == b.stats && a.listTitle == b.listTitle && a.lines == b.lines && a.latest == b.latest
            && a.tabs.map(\.id) == b.tabs.map(\.id) && a.hasUI == b.hasUI
    }
}

/// 核心连着的一个应用（docs/界面接口.md §6 `GET /apps`）。名字、图标、版本不在这里，从主控来（`AppEntry`）。
public struct AgentApp: Identifiable, Equatable {
    public struct Summary: Equatable {
        public let count: Int
        public let text: String
    }

    public struct PageRef: Equatable, Identifiable {
        public let id: String
        public let title: String
        /// 不画成标签、只由 `agent.open_page` 去的页（工具协议 §1a `hidden`，2026-11-10 加）
        public var hidden = false
    }

    /// 配件标识（`luoke-scan`）
    public let id: String
    public var running: Bool
    /// 概览一句话；工具没在运行、没写是 nil
    public let summary: Summary?
    /// 基础页（窗口里画）；`hidden` 的也在里面（`agent.open_page` 去得了），只是不画成标签
    public let pages: [PageRef]
    /// 第一个画成标签的页：没选过页、选的不在了时看的就是它，「这个应用」也画在它下面。页全是 hidden 时是 nil
    public var firstPage: String? { pages.first { !$0.hidden }?.id }
    /// 工具自己的界面能打开的深页；nil 是工具没有自己的界面；窗口不打开它们（11-09 定）
    public let uiPages: [PageRef]?
    /// 要了、还没给的权限 id
    public let needs: [String]

    public var tool: ToolIcon { AgentFeed.tool(id) }
    public var hasUI: Bool { uiPages != nil }
}

/// 核心给的一页基础页（`GET /apps/<id>/pages/<页>`）：画得出的 A2UI，或者一句为什么没有
public struct AgentPage {
    public let app: String
    public let page: String
    public var surface: SurfaceModel?
    public var error: String?
    /// 连不上螺壳（不是这一页本身出错）
    public var offline = false
}

/// 「设置 · 权限」的一行（§10 `GET /permissions`）。`can` 是这一行现在能做的；`each-time` 的是 nil。
public struct AgentPermission: Identifiable, Equatable {
    public let app: String
    /// 权限 id（`fda`）
    public let key: String
    /// system / account / delegate / each-time
    public let kind: String
    /// `luoke`：列在螺壳名下（状态由螺壳.app 报）
    public let owner: String?
    public let tcc: String?
    public let title: String
    public let facts: [String]
    public let without: String?
    /// granted / denied / ask / on / off；不知道是 nil
    public let state: String?
    public let can: [String]?

    public var id: String { "\(app)#\(key)" }
    public var tool: ToolIcon { AgentFeed.tool(app) }
    public var onLuoke: Bool { owner == "luoke" }
}

/// 列在螺壳名下的一项权限：几个应用都要它，合成一行，下面写哪些应用在用、各自看什么
public struct LuokePermission: Identifiable, Equatable {
    public let id: String
    public let title: String
    public let state: String?
    /// 每个在用的应用一行
    public let rows: [AgentPermission]
    /// 几行的 `can` 合起来（同一项权限，能做的一样）
    public var can: [String] {
        var out: [String] = []
        for r in rows { for op in r.can ?? [] where !out.contains(op) { out.append(op) } }
        return out
    }
}

/// 「今天」里一张要螺壳名下权限的卡片，交给本体的那个按钮（§3 的 `host_ask`）
struct HostAsk: Equatable {
    let app: String
    /// 权限 id
    let id: String
    /// 按钮的组件 id
    let button: String
    /// 这个按钮的活要这一项（`needs`）：够了才转给工具。没有的话，这个按钮就是来要权限的
    var then = false
}

/// 螺壳自己的权限状态，螺壳.app 报给核心（§10 `POST /host`）
public enum HostPermission: String, Sendable {
    case granted, denied, ask
}

public struct Answer: Equatable {
    public struct Row: Equatable, Identifiable {
        public let id: String
        public let tool: ToolIcon
        public let title: String
        public let action: String
    }

    public let question: String
    public let text: String
    public var rows: [Row] = []
    public var primary: String?
}

public struct ChatLine: Identifiable, Equatable {
    public let id = UUID()
    public let mine: Bool
    public let text: String
}

public struct Toast: Equatable {
    public let text: String
    public let canUndo: Bool
}

public struct PermissionSheet: Equatable {
    public let key: String
    public let owner: ToolIcon
    public let title: String
    public let facts: [String]
    public var waiting = false
    /// 接上核心时：「继续」交给核心的哪一行（应用、权限 id）
    public var app: String? = nil
}

/// 这一版窗口里有哪些页（luoke-core#68：beta 2 先出精简版，只画今天、应用页、「设置 · 提醒」「设置 · 权限」）
public struct WindowFeatures: OptionSet, Sendable {
    public let rawValue: Int
    public init(rawValue: Int) { self.rawValue = rawValue }
    /// 「活动」
    public static let activity = WindowFeatures(rawValue: 1 << 0)
    /// 底部的「搜索，或者问螺壳」（⌘K）、回答和对话
    public static let ask = WindowFeatures(rawValue: 1 << 1)
    /// 底部只有搜索框（⌘K）：不问螺壳，词直接给应用，结果是应用给的卡片。和 `.ask` 只画一个
    public static let search = WindowFeatures(rawValue: 1 << 2)
    public static let all: WindowFeatures = [.activity, .ask]
    /// beta 2 的精简版：没有「活动」和问螺壳，底部只有搜索框
    public static let beta2: WindowFeatures = [.search]
}

/// 搜索框的一段结果：一个应用给的 A2UI 卡片。`id` 是核心给的 surfaceId，按钮照卡片走 `/action`
public struct SearchCard: Identifiable {
    public let id: String
    public let surface: SurfaceModel
}

/// 一次搜索的答复（docs/界面接口.md §7）
public struct SearchAnswer {
    /// 给了 `hits` 的工具的结果，窗口按类型分组自己画（工具协议 §1b）；照问的顺序、工具里照它给的顺序
    public var hits: [WindowHit] = [] {
        didSet { groups = HitGroup.make(hits) }
    }
    public private(set) var groups: [HitGroup] = []
    /// 核心给这次搜索的编号：点结果上的按钮（`POST /hit`）带上它
    public var search: Int?
    /// 只给卡片、没给 `hits` 的工具：照旧画它的卡片
    public var cards: [SearchCard] = []
    /// 没答上来的应用
    public var failed: [String] = []
    /// 问了几个应用（核心的 `asked`；旧核心不给，那时不说「都没答」）
    public var asked: Int? = nil

    /// 一个能搜的应用都没答上来：什么也没搜成，不能说「没有找到」
    public var allFailed: Bool {
        cards.isEmpty && hits.isEmpty && !failed.isEmpty && asked.map { $0 <= failed.count } == true
    }

    /// 搜完以后结果下面的几行（没搜成、连不上的那一句另外画）。都没答上来的那一句由面板画成带「再试一次」的出错提示
    public var lines: [String] {
        if allFailed { return [] }
        let missing = failed.map { "\($0)这次没有回应。" }
        if !cards.isEmpty || !hits.isEmpty { return missing }
        return [failed.isEmpty ? "没有找到。" : "其他应用里没有找到。"] + missing
    }

    /// 都没答上来时那一句：一个应用不写「都」
    public var allFailedText: String {
        "\(failed.joined(separator: "、"))这次\(failed.count > 1 ? "都" : "")没有回应，没搜成。"
    }
    /// 没搜成时说的一句话：没有能搜的应用、连不上螺壳
    public var note: String?
    /// 没搜成、可以再试一次（连不上、出错；不是「没有能搜的应用」）
    public var retry = false

    public init(hits: [WindowHit] = [], search: Int? = nil, cards: [SearchCard] = [], failed: [String] = [],
                asked: Int? = nil, note: String? = nil, retry: Bool = false) {
        self.hits = hits
        self.groups = HitGroup.make(hits)
        self.search = search
        self.cards = cards
        self.failed = failed
        self.asked = asked
        self.note = note
        self.retry = retry
    }
}

/// 主窗口的状态。界面只读它、只调它的方法；以后接 agent 核心时，数据从 agent.sock 来，点按交回去。
@MainActor
public final class WindowModel: ObservableObject {
    /// 画哪些页；螺壳.app 的 beta 2 设成 `.beta2`。正看着的页不在里面了就回「今天」
    @Published public var features: WindowFeatures = .all {
        didSet {
            if !shows(page) {
                // 本体的一页、整窗开着：只换掉底下那页，不去问本体能不能走；只有卡片浮着时照常 go
                if hostPage != nil || hostTakeover != nil { page = .today } else { go(.today) }
            }
            if !features.contains(.ask) { closeAsk() }
            if !features.contains(.search) { closeSearch() }
            syncAppEntries()
        }
    }

    // 在哪
    @Published public private(set) var page: Page = .today {
        didSet { if page != oldValue { backend?.windowPageChanged() } }     // 核心要知道用户是不是正看着「今天」（§11）
    }
    @Published public var prefsTab: PrefsTab = .alerts
    @Published public var appTab: String = "overview"
    @Published public private(set) var sidebarMini = false
    @Published public private(set) var appsExpanded = false
    /// 「今天」的密度（设置 · 显示）
    @Published public private(set) var density: Density = .standard
    /// 「一件件处理」；nil 是没在处理
    @Published public internal(set) var focus: FocusSession?
    /// 「今天」最上面的简报；nil 是收着
    @Published public private(set) var briefNote: BriefNote?
    /// 下一次画出来的内容怎么进场（只给动效用）
    public internal(set) var entrance: Entrance = .none
    /// 现在几点（截图里固定）
    public var now: () -> Date = { Date() }

    // 问螺壳
    @Published public private(set) var askOpen = false
    /// 搜索框：词发出去了、还没答
    @Published public internal(set) var searching = false
    /// 搜索框的答复；收起是 nil
    @Published public internal(set) var searchAnswer: SearchAnswer?
    /// 加一就把光标放进搜索框（⌘K、菜单）
    @Published public private(set) var searchFocus = 0
    /// 选中的那条结果（`WindowHit.id`）：右边出预览，回车打开它
    @Published public internal(set) var searchSelected: String?
    /// 只看这一类（组的编号，`HitGroup.key`）；nil 是全部
    @Published public internal(set) var searchKind: String?
    /// 读到的缩略图（应用 + `thumb/<id>`）：只在内存里，收起结果就丢（工具协议 §1b）
    @Published public internal(set) var searchThumbs: [String: NSImage] = [:]
    private var thumbsAsked: Set<String> = []
    @Published public private(set) var answer: Answer?
    @Published public var askContext: String?

    // 浮在上面的
    @Published public private(set) var toast: Toast?
    @Published public private(set) var sheet: PermissionSheet?
    /// 本体自己的界面（`HostPage`，11-10 定：螺壳只有一个窗口）：占内容区的一页、浮在上面的卡片、占整个窗口的。
    /// 本体 `present` 放、`dismissHost` 收；用户离开时先问本体（`WindowHost.hostPageCanLeave`）
    @Published public private(set) var hostPage: HostPage? { didSet { if hostPage?.id != oldValue?.id { backend?.windowPageChanged() } } }
    @Published public private(set) var hostCard: HostPage? { didSet { if hostCard?.id != oldValue?.id { backend?.windowPageChanged() } } }
    @Published public private(set) var hostTakeover: HostPage? { didSet { if hostTakeover?.id != oldValue?.id { backend?.windowPageChanged() } } }

    // 状态
    @Published public var engineReady = true
    /// 窗口连得上螺壳（agent 的 socket）：连不上时侧栏不写「在运行」，应用页、搜索写「连不上螺壳」和「再试一次」
    @Published public var coreReachable = true {
        didSet { if coreReachable { offlineSince = nil } else if offlineSince == nil { offlineSince = now() } }
    }
    /// 从什么时候起连不上（连得上是 nil）；最后一次拿到核心的 feed 是什么时候：没响应时写「下面是 … 的内容」
    @Published public var offlineSince: Date?
    @Published public var lastSeen: Date?
    @Published public var modelName = "Qwen3.5-9B"
    @Published public private(set) var pausedUntil: String?

    // 今天
    /// 「已经替你做了」里展开成整张卡片的那几行（放在这里，截图也能拍展开后的样子）
    @Published public var openDone: Set<String> = []
    /// 「今天」里点开了的急事叠（键同 `TodayStack.key`），和「还有 N 件急事」点开了没有：标准和紧凑共用，
    /// 菜单栏里点了一行急事也照它展开（`revealUrgent`）；放在这里，截图也能拍
    @Published public var urgentOpenStacks: Set<String> = []
    @Published public var urgentAll = false
    /// 菜单栏里点了一行急事：「今天」滚到那一叠（叠里第一件的编号）。页面滚过去以后清掉
    @Published public var urgentJump: UrgentJump?
    var urgentJumpCount = 0
    /// 紧凑的「今天」里点了「选一下」、展开成标准卡片的那几行（卡片编号）
    @Published public var compactExpanded: Set<String> = []
    @Published public var urgent: [UrgentItem] = []
    /// 核心说的菜单栏小点（`/feed` 的 `dot`：有「当场说」的急事、主动提醒开着）；nil 是没接核心，照有没有急事
    @Published public internal(set) var agentDot: Bool?
    @Published public var cards: [TodayCard] = [] {
        didSet { if focus != nil { followReplacedCards(old: oldValue) } }
    }
    @Published public var done: [DoneRow] = []
    @Published public var quiet: [QuietRow] = []
    /// 核心的几句状态（某个应用没在运行、通知被关了……），画在「今天」最下面
    @Published public var notices: [String] = []
    /// 螺壳.app 自己要说的一句（核心起不来、旧的螺壳 agent 还在跑……），画在核心那几句前面；nil 不画
    @Published public var hostNotice: String?

    // 别的页
    @Published public var activity: [ActivityRow] = []
    @Published public var activityFilter: ToolIcon?
    @Published public var apps: [AppEntry] = []
    @Published public var catalog: [CatalogApp] = []
    @Published public var appPages: [Page: AppPageData] = [:]
    @Published public var searchQuery = ""
    @Published public var searchSections: [SearchSection] = []
    @Published public var searchFilter = "all"
    @Published public var chat: [ChatLine] = []

    // 设置
    @Published public var alertsOn = true
    @Published public var brief: BriefMode = .morning
    @Published public var quietHours = "22:00 – 08:00"
    @Published public var kinds: [KindSetting] = []
    @Published public var permissions: [PermissionRow] = []
    @Published public var accounts: [PermissionRow] = []
    @Published public var delegates: [DelegateRow] = []
    @Published public var eachTime: [EachTimeRow] = []
    @Published public var tiers: [ModelTier] = []
    @Published public var currentTier = ""
    @Published public var engineVersion = "oMLX 0.7.2"
    @Published public var energy: Energy = .balanced
    @Published public var onBattery = false

    // 接上核心时（§6、§10）：nil 是还没从核心来，界面照旧画上面的示例（或主控给的）
    /// `GET /apps`
    @Published public internal(set) var agentApps: [AgentApp]?
    /// 取到的基础页，键是 `<应用>/page/<页>`（同 A2UI 的 surfaceId）
    @Published public internal(set) var agentPages: [String: AgentPage] = [:]
    /// 基础页现在带的参数（工具协议 §4 pageArgs），键同 `agentPages`：`agent.open_page` 带来的，这一页开着时再取都带上；
    /// 用户从侧栏、页列表点这一页时没了
    @Published public internal(set) var pageArgs: [String: [String: String]] = [:]
    /// `openAgentPage` 交给 `go` 的参数：只这一次
    private var openingArgs: (key: String, args: [String: String])?
    /// `GET /permissions`
    @Published public internal(set) var agentPermissions: [AgentPermission]?
    /// 点了、核心还没答的权限操作：行 id → 操作（开关先照点的画）
    @Published public internal(set) var permissionPending: [String: String] = [:]
    /// 螺壳名下的权限里用户确认过的：`<应用>#<权限 id>` → 确认的时间，键同 `AgentPermission.id`。本体给；
    /// nil 是本体没报（没接本体的壳），这时不画确认记录
    @Published public var hostConfirmed: [String: String]?
    /// 系统通知还没问过：本体报的。「今天」里留一个按钮，用户点了才问
    @Published public var notificationsNotAsked = false
    /// 「今天」里要螺壳名下权限的卡片：卡片编号 → 交给本体的那个按钮
    var hostAsks: [String: HostAsk] = [:]
    /// 应用页上交给本体的按钮，按页给（`GET /apps/<id>/pages/<页>` 的 `host_ask`）
    var pageHostAsks: [String: HostAsk] = [:]

    /// 回答，按页给（示例数据里有；以后由问螺壳出）
    public var answers: [String: Answer] = [:]
    /// 点了卡片上的按钮（卡片编号、动作名、上下文）。以后交给 agent 的 /action。
    public var onCardAction: ((WindowModel, TodayCard, String, JSONValue) -> Void)?
    /// 接上 agent 核心时，点按和改设置交给它（`AgentConnection`）；没有就用示例数据自己演
    public weak var backend: WindowBackend?
    /// 「今天」的数据从核心来、核心的第一份 feed 还没到：螺壳被通知拉起时，窗口比核心先起来
    @Published var waitingForFeed = false
    /// 那时点了简报的通知：记下点的时刻，feed 到了再拼（现在拼是空的）
    private var briefPending: String?
    /// 螺壳.app（本体）：模型、隐私、添加应用、升级交给它，打开本体现有的窗口（`Host.swift`）；没有就窗口自己画这几页
    public weak var host: WindowHost?
    /// 螺壳.app 给的已装应用；给过以后侧栏的应用照核心连着的工具列（`syncAppEntries`），没给是示例
    private(set) var installedApps: [InstalledApp]?

    private var undoAction: (() -> Void)?
    /// 示例里答完的卡片：「已经替你做了」那一行点撤销时放回去（行编号 → 放回）
    private var restores: [String: () -> Void] = [:]
    private let defaults: UserDefaults?
    private var toastTask: Task<Void, Never>?

    static let sidebarKey = "luoke.window.sidebarMini"
    static let appsKey = "luoke.window.appsExpanded"
    static let densityKey = "luoke.window.density"

    /// defaults：侧栏收起、「应用」展开、「今天」的密度记在哪（nil 就不记）
    public init(defaults: UserDefaults? = nil) {
        self.defaults = defaults
        sidebarMini = defaults?.bool(forKey: Self.sidebarKey) ?? false
        appsExpanded = defaults?.bool(forKey: Self.appsKey) ?? false
        density = Density(rawValue: defaults?.string(forKey: Self.densityKey) ?? "") ?? .standard
    }

    // MARK: 算出来的

    /// 侧栏「今天」的数：只算要你决定的，和「一件件处理」的数一样；有急事时侧栏只画红点、不画这个数（`hasUrgent`，`SidebarMark`）
    public var todayCount: Int { cards.count }
    /// 有急事（菜单栏图标的菜单里列出来）
    public var hasUrgent: Bool { !urgent.isEmpty }
    /// 菜单栏图标要不要那个点：接着核心时照它说的（放进简报、只放在窗口里的急事不点，关了主动提醒也不点）
    public var hasDot: Bool { agentDot ?? hasUrgent }
    /// 「应用」收着、正在看某个应用的页：这一行亮着，叠着的小图标里那个应用的亮着
    public var appsRowLit: Bool { !appsExpanded && sidebarSelection.map(isAppPage) == true }
    /// 叠着的小图标里亮着的那个；在「添加应用」时这一行亮着、小图标都照常
    public var appsNow: Page? { appsRowLit && page != .apps ? page : nil }
    /// 读屏和悬停时说正在看哪个
    public var appsNowName: String? { appsRowLit ? (page == .apps ? "添加应用" : page.title) : nil }

    func isAppPage(_ p: Page) -> Bool { p == .apps || apps.contains { $0.id == p } }

    /// 螺壳.app 报装着哪些应用、版本、有没有新版。侧栏「应用」下面列核心连着的、窗口里有页的那几个，
    /// 版本和「升级」照这里的；核心的应用列表还没来时先照这里的列。有新版的在「顺便看看」里有一行（`updateRows`）
    public func setInstalledApps(_ list: [InstalledApp]) {
        installedApps = list
        syncAppEntries()
        quiet = quiet.filter { !$0.id.hasPrefix(Self.updatePrefix) } + updateRows()
    }

    static let updatePrefix = "upd-"

    /// 「顺便看看」里的「有新版本」（界面接口 §1：主控的，窗口照螺壳.app 报的画）：每个有新版的应用一行，点「升级」交给本体。
    /// 接着核心时接在核心给的那几行后面；螺壳.app 没报过是空的（示例自己带着这一行）
    func updateRows() -> [QuietRow] {
        var seen = Set<ToolIcon>()
        return (installedApps ?? []).compactMap { i in
            let tool = AgentFeed.tool(i.accessory)
            guard let to = i.update, tool != .core, seen.insert(tool).inserted else { return nil }
            return QuietRow(id: Self.updatePrefix + tool.rawValue, tool: tool, text: "\(tool.name)可以升级到 \(to)",
                            sub: "螺壳来装，你点了才升", action: "升级")
        }
    }

    func syncAppEntries() {
        guard let installed = installedApps else { return }
        let ids = agentApps?.map(\.id) ?? installed.map(\.accessory)
        var seen = Set<Page>()
        apps = ids.compactMap { id in
            let tool = AgentFeed.tool(id)
            guard let page = Page.allCases.first(where: { $0.appTool == tool }), shows(page), seen.insert(page).inserted else { return nil }
            let i = installed.first { AgentFeed.tool($0.accessory) == tool }
            return AppEntry(id: page, tool: tool, version: i?.version ?? "", update: i?.update)
        }
    }

    /// 这一版画不画这一页（`features`）
    public func shows(_ p: Page) -> Bool {
        switch p {
        case .activity: return features.contains(.activity)
        case .search, .chat: return features.contains(.ask)
        default: return true
        }
    }

    // MARK: 去哪

    /// 卡片或页上的「去扫描页看 N 项」（工具协议 §5 `agent.open_page`）：换到这个应用的应用页的那一页；侧栏里没有它就不动。
    /// `args`（§4 pageArgs）：核心核过的参数，读这一页时带上
    public func openAgentPage(app: String, page: String, args: [String: String] = [:]) {
        let tool = AgentFeed.tool(app)
        guard tool != .core, let entry = apps.first(where: { $0.tool == tool }) else { return }
        openingArgs = (AgentFeed.pageKey(app, page), args)
        go(entry.id, tab: page)
    }

    /// 这一页的参数换掉（`openAgentPage` 带来的），或者用户自己点进来、没了
    private func takePageArgs(for p: Page) {
        let opening = openingArgs
        openingArgs = nil
        if let app = agentApp(for: p) {
            let prefix = AgentFeed.pageKey(app.id, "")
            pageArgs = pageArgs.filter { !$0.key.hasPrefix(prefix) }
        }
        if let opening, !opening.args.isEmpty { pageArgs[opening.key] = opening.args }
    }

    /// 密码框里填的字（工具协议 §4 secureField）：离开一页时清掉，只在内存里也不留
    func clearSecureFields() {
        for p in agentPages.values { p.surface?.clearSecureFields() }
    }

    /// 正看着的基础页，键同 `agentPages`（不是核心的应用页是 nil）。本体的一页、整窗盖着时是 nil：用户看不见它，
    /// 带 `refresh` 的页不再重取（报给核心的页名也是 `host`）；浮着的卡片不算，底下那页照旧
    public var visibleAgentPageKey: String? {
        guard hostPage == nil, hostTakeover == nil else { return nil }
        guard let app = agentApp(for: page), let tab = agentTab(app) else { return nil }
        return AgentFeed.pageKey(app.id, tab)
    }

    public func go(_ p: Page, tab: String? = nil) {
        guard mayNavigate() else { openingArgs = nil; return }
        if handOff(p, tab: tab) { openingArgs = nil; return }
        let p = shows(p) ? p : .today
        if p != page || focus != nil { entrance = .page }
        focus = nil
        clearSecureFields()
        takePageArgs(for: p)
        page = p
        if let tab {
            if p == .prefs, let t = PrefsTab(rawValue: tab) { prefsTab = t } else { appTab = tab }
        } else if p != .prefs {
            appTab = "overview"
        }
        closeAsk()
        closeSearch()
        askContext = nil
        loadVisible()
    }

    /// 应用页上换标签（窗口里画的那几页）：用户自己点的，这一页不带参数
    public func selectAppTab(_ id: String) {
        clearSecureFields()
        if let app = agentApp(for: page) { pageArgs[AgentFeed.pageKey(app.id, id)] = nil }
        appTab = id
        loadVisible()
    }

    /// 设置里换标签
    public func selectPrefsTab(_ t: PrefsTab) {
        if handOff(.prefs, tab: t.rawValue) { return }
        prefsTab = t
        loadVisible()
    }

    // MARK: 应用的页（接上核心时，§6）

    /// 这一页是核心的哪个应用（没接核心、核心没连着这个应用是 nil）
    public func agentApp(for p: Page) -> AgentApp? {
        guard let list = agentApps, let tool = p.appTool else { return nil }
        return list.first { $0.tool == tool }
    }

    /// 这个应用正看着哪一页：选过的不在它的页里，就是第一个画成标签的页（`hidden` 的只由 `agent.open_page` 去）
    public func agentTab(_ app: AgentApp) -> String? {
        app.pages.contains { $0.id == appTab } ? appTab : app.firstPage
    }

    /// 接上核心时，取正看着的那一页要的数据。onlyMissing：取过的不再取（应用列表刚来时）
    func loadVisible(onlyMissing: Bool = false) {
        guard let backend else { return }
        if page == .prefs {
            if prefsTab == .permissions && !(onlyMissing && agentPermissions != nil) { backend.reloadPermissions() }
            return
        }
        guard let app = agentApp(for: page) else { return }
        if let tab = agentTab(app), !(onlyMissing && agentPages[AgentFeed.pageKey(app.id, tab)] != nil) {
            backend.reloadPage(app: app.id, page: tab)
        }
        if !app.needs.isEmpty && agentPermissions == nil { backend.reloadPermissions() }   // 要写出缺的是哪一项
    }

    /// 「再试一次」：重新要正看着的那一页
    public func retryPage() { loadVisible(onlyMissing: false) }

    /// 「10月20日 20:00」；今天的只写「09:41」
    public func seenText(_ d: Date) -> String {
        let cal = Calendar.current
        let hm = String(format: "%02d:%02d", cal.component(.hour, from: d), cal.component(.minute, from: d))
        if cal.isDate(d, inSameDayAs: now()) { return hm }
        return "\(cal.component(.month, from: d))月\(cal.component(.day, from: d))日 \(hm)"
    }

    /// 连不上超过 30 秒：窗口每 2 秒自己重连，到这时多半是螺壳的核心出了事，给用户一件能做的事
    public var offlineLong: Bool { offlineSince.map { now().timeIntervalSince($0) > 30 } ?? false }
    public static let offlineAdvice = "如果还是不行，点屏幕右上角菜单栏里的螺壳图标，选「退出螺壳」，再重新打开。"
    /// 断开时的说法：一律是「螺壳暂时没响应」，不说「连不上」「重试」这类系统腔（文案经 Gemini 网页版打磨，2026-11-09）
    public static let offlineShort = "螺壳暂时没响应"
    /// 断开时点了按钮
    public static let offlineFailed = "螺壳暂时没响应，这会儿做不成。"

    /// `/feed` 的 `apps` 事件：这个应用变了。重新取应用列表；正看着它的页就重新取那一页；正看着权限就重新取权限。
    func agentAppChanged(_ app: String) {
        guard let backend else { return }
        backend.reloadApps()
        if let a = agentApp(for: page), a.id == app, let tab = agentTab(a) { backend.reloadPage(app: app, page: tab) }
        if page == .prefs && prefsTab == .permissions { backend.reloadPermissions() }
    }

    /// 应用缺的权限叫什么（没取到权限就只说几项）
    public func needsText(_ app: AgentApp) -> String {
        let names = app.needs.compactMap { k in agentPermissions?.first { $0.app == app.id && $0.key == k }?.title }
        return names.count == app.needs.count ? names.joined(separator: "、") : "\(app.needs.count) 项权限"
    }

    // MARK: 「设置 · 权限」（接上核心时，§10）

    /// 列在螺壳名下的：同一个权限 id 合成一行
    public var luokePermissions: [LuokePermission] {
        var out: [LuokePermission] = []
        for r in agentPermissions ?? [] where r.onLuoke {
            if let i = out.firstIndex(where: { $0.id == r.key }) {
                out[i] = LuokePermission(id: r.key, title: out[i].title, state: out[i].state ?? r.state, rows: out[i].rows + [r])
            } else {
                out.append(LuokePermission(id: r.key, title: r.title, state: r.state, rows: [r]))
            }
        }
        return out
    }

    /// 不在螺壳名下的某一种（system、account、delegate、each-time）
    public func agentPermissionRows(_ kind: String) -> [AgentPermission] {
        (agentPermissions ?? []).filter { !$0.onLuoke && $0.kind == kind }
    }

    /// 这一项是不是应用正要、还没给的（`/apps` 的 `needs`）
    public func isNeeded(_ r: AgentPermission) -> Bool {
        agentApps?.first { $0.id == r.app }?.needs.contains(r.key) ?? false
    }

    /// 用户在权限页上点了一行的按钮或开关。只认这一行 `can` 里有的；螺壳名下的系统权限问用户的事交给本体（没接本体时照下面走）；
    /// `request` 先出说明，点了「继续」才交给核心。
    public func permissionAction(_ r: AgentPermission, _ op: String) {
        guard let can = r.can, can.contains(op), permissionPending[r.id] == nil else { return }
        if let host, r.onLuoke, r.kind == "system" {
            if op == "settings", r.state == "ask" { host.askSystem(id: r.key); return }     // 系统设置里还没有这一项：先问系统
            if op == "request" || op == "settings" && r.state == "denied" && hostPermissionOn(r) {
                host.askPermission(app: r.app, id: r.key)       // 本体直接打开系统设置，等着给了接着做
                return
            }
        }
        guard let backend else { return }
        if op == "request" {
            sheet = PermissionSheet(key: r.key, owner: r.tool, title: r.title, facts: r.facts, app: r.app)
            return
        }
        permissionPending[r.id] = op
        backend.permission(app: r.app, id: r.key, op: op)
    }

    /// 这个应用的「允许」开着没有：用户同意了才放行
    func hostPermissionOn(_ r: AgentPermission) -> Bool { hostConfirmed.map { $0[r.id] != nil } ?? true }

    /// 用户扳了「允许」。扳开先出本体的窗口，用户在那里确认了才算开，开关等本体报了再变；扳关直接关
    func setHostPermission(_ r: AgentPermission, on: Bool) {
        guard r.onLuoke, r.kind == "system", hostPermissionOn(r) != on else { return }
        if on, let host {
            host.askPermission(app: r.app, id: r.key)
            return
        }
        var now = hostConfirmed ?? [:]
        now[r.id] = on ? ISO8601DateFormatter().string(from: Date()) : nil
        hostConfirmed = now
        host?.setPermission(app: r.app, id: r.key, on: on)
    }

    /// 点的是要螺壳名下权限的按钮、接着本体：交给本体。`then` 的按钮等本体说够了，再转给工具（`run`）
    private func askedHost(_ surfaceId: String, _ componentId: String, run: @escaping @MainActor () -> Void) -> Bool {
        guard let host, let a = hostAsks[surfaceId] ?? pageHostAsks[surfaceId], a.button == componentId else { return false }
        if a.then { host.askPermission(app: a.app, id: a.id, ready: run) } else { host.askPermission(app: a.app, id: a.id) }
        return true
    }

    /// 核心答了一次权限操作（`POST /permissions`）：提示答的那句话
    func permissionAnswered(app: String, id: String, op: String, text: String, error: Bool) {
        permissionPending["\(app)#\(id)"] = nil
        if op == "request", sheet?.app == app, sheet?.key == id { sheet = nil }
        if !text.isEmpty { show(text) } else if error { show("没改成。") }
    }

    /// 螺壳.app 报它自己的权限（§10 `POST /host`）：启动时报一次，变了再报（例如用户从系统设置回来）。
    /// 键是权限 id，和工具清单里 `owner: "luoke"` 那一项对上（完全磁盘访问是 `fda`）；nil 是不再报这一项。
    /// 怎么查出螺壳有没有这项权限是螺壳.app 的事，这里只转给核心；没接核心时什么都不做。
    /// `confirmed` 是用户确认过的（{应用: {权限 id: 时间}}），整份给；窗口画权限页要，核心决定卡片留不留要
    public func reportHostPermissions(_ states: [String: HostPermission?], confirmed: [String: [String: String]]? = nil) {
        if let confirmed {
            hostConfirmed = Dictionary(uniqueKeysWithValues: confirmed.flatMap { app, ids in ids.map { ("\(app)#\($0.key)", $0.value) } })
        }
        backend?.reportHost(permissions: states.mapValues { $0.map { .string($0.rawValue) } ?? .null }, confirmed: confirmed)
    }

    public func toggleSidebar() { setSidebar(mini: !sidebarMini) }

    public func setSidebar(mini: Bool) {
        sidebarMini = mini
        defaults?.set(mini, forKey: Self.sidebarKey)
    }

    public func toggleApps() {
        appsExpanded.toggle()
        defaults?.set(appsExpanded, forKey: Self.appsKey)
    }

    // MARK: 问螺壳

    public func openAsk() {
        guard features.contains(.ask) else { return }
        let key: String
        switch page {
        case .today: key = "today"
        case .scan: key = "scan"
        case .mail: key = "mail"
        case .search: key = "search"
        default: key = "default"
        }
        let a = answers[key] ?? answers["default"] ?? Answer(question: "", text: "")
        answer = Answer(question: askContext.map { "\($0)：\(a.question)" } ?? a.question, text: a.text, rows: a.rows, primary: a.primary)
        askOpen = true
    }

    /// 结果面板开着：在搜，或者有答复
    public var searchOpen: Bool { searching || searchAnswer != nil }

    /// 底部有一条（问螺壳或搜索框）：提示要让开
    public var hasBottomBar: Bool {
        focus == nil && hostPage == nil && hostTakeover == nil && (features.contains(.ask) || features.contains(.search))
    }

    public func focusSearch() {
        if features.contains(.search) { searchFocus += 1 }
    }

    /// 用户按了回车：词直接给应用，不经模型
    public func runSearch(_ query: String) {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard features.contains(.search), !q.isEmpty else { return }
        searchQuery = q          // 「再试一次」搜同一句；搜不成时面板里写出是哪一句
        searchAnswer = nil
        clearSearchState()
        searching = true
        backend?.search(query: q)
    }

    /// 收起结果；还没到的答复不要了
    public func closeSearch() {
        searching = false
        searchAnswer = nil
        clearSearchState()
    }

    private func clearSearchState() {
        searchSelected = nil
        searchKind = nil
        searchThumbs = [:]
        thumbsAsked = []
    }

    /// 结果的缩略图的键（应用 + `thumb/<id>`）
    nonisolated static func thumbKey(_ hit: WindowHit) -> String? { hit.thumb.map { hit.app + "\u{1}" + $0 } }

    /// 格子画出来时要它的缩略图：每张只要一次
    public func loadThumb(_ hit: WindowHit) {
        guard let ref = hit.thumb, let key = Self.thumbKey(hit), !thumbsAsked.contains(key) else { return }
        thumbsAsked.insert(key)
        backend?.searchThumb(app: hit.app, ref: ref)
    }

    /// 核心答来的缩略图（`GET /thumb`）；收起或换了一次搜索以后才到的不要
    public func setThumb(app: String, ref: String, image: NSImage) {
        let key = app + "\u{1}" + ref
        guard thumbsAsked.contains(key) else { return }
        searchThumbs[key] = image
    }

    /// 现在画出来、上下键走的那些结果
    public var searchOrder: [WindowHit] {
        SearchLayout.order(searchAnswer?.groups ?? [], filter: searchKind, previewing: searchSelected != nil,
                           selected: searchSelected)
    }

    public var selectedHit: WindowHit? {
        guard let id = searchSelected else { return nil }
        return searchAnswer?.hits.first { $0.id == id }
    }

    /// 点了一格、一行：选中它（再点一次收起预览）
    public func selectHit(_ hit: WindowHit) {
        searchSelected = searchSelected == hit.id ? nil : hit.id
    }

    /// ↓ ↑：没选中时 ↓ 选第一条；到头了不动
    public func moveSearchSelection(_ step: Int) {
        let order = searchOrder
        guard !order.isEmpty else { return }
        guard let id = searchSelected, let i = order.firstIndex(where: { $0.id == id }) else {
            if step > 0 { searchSelected = order[0].id }
            return
        }
        searchSelected = order[max(0, min(order.count - 1, i + step))].id
    }

    /// 顶上那一行：只看一类，再点一次（或点「全部」）回到全部
    public func filterSearch(_ kind: String?) {
        searchKind = searchKind == kind ? nil : kind
        if let id = searchSelected, !searchOrder.contains(where: { $0.id == id }) { searchSelected = nil }
    }

    /// 回车：结果开着、框里还是搜的那一句时，打开选中的那条（没选中是第一条），答 true；不然是要搜，答 false
    public func returnPressed(text: String, reveal: Bool = false) -> Bool {
        guard let answer = searchAnswer, !answer.hits.isEmpty,
              text.trimmingCharacters(in: .whitespacesAndNewlines) == searchQuery,
              let hit = selectedHit ?? searchOrder.first else { return false }
        openHit(hit, reveal: reveal)
        return true
    }

    /// 打开一条结果（或在访达中显示）：交给核心，核心转给出这条结果的工具（§7 `POST /hit`）
    public func openHit(_ hit: WindowHit, reveal: Bool = false, action: Int? = nil) {
        guard let search = searchAnswer?.search, let i = action ?? hit.actionIndex(reveal: reveal),
              hit.actions.indices.contains(i) else { return }
        backend?.searchHit(search: search, app: hit.app, hit: hit.hitID, action: i)
    }

    public func closeAsk() {
        askOpen = false
        answer = nil
    }

    /// 钉到今天：变成「要你决定」最上面的一张
    public func pinAnswer() {
        guard let a = answer else { return }
        var comps: [JSONValue] = [
            .object(["id": .string("root"), "component": .string("Column"), "children": .array([.string("q"), .string("a")])]),
            .object(["id": .string("q"), "component": .string("Text"), "text": .string(a.question), "variant": .string("h4")]),
            .object(["id": .string("a"), "component": .string("Text"), "text": .string(a.text)]),
        ]
        comps.append(contentsOf: [])
        if let s = try? Surface.build(Sample.messages("pin-\(cards.count)", comps)) {
            cards.insert(TodayCard(id: "pin-\(UUID().uuidString.prefix(6))", tool: .core, time: nil, surface: SurfaceModel(surface: s)), at: 0)
        }
        closeAsk()
        show("钉到今天了")
    }

    /// 展开成整页对话
    public func expandAnswer() {
        guard let a = answer else { return }
        chat.append(ChatLine(mine: true, text: a.question))
        chat.append(ChatLine(mine: false, text: a.text))
        go(.chat)
    }

    // MARK: 「今天」的样子

    public func setDensity(_ d: Density) {
        density = d
        defaults?.set(d.rawValue, forKey: Self.densityKey)
    }

    /// 页标题旁边的日期：「11月4日 星期三」
    public var dateLine: String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "zh_CN")
        f.dateFormat = "M月d日 EEEE"
        return f.string(from: now())
    }

    // MARK: 简报

    /// 照「今天」现在的样子拼一份简报：替你做了的、急事、要你决定的
    public func makeBrief(time: String? = nil) -> BriefNote {
        BriefNote(time: time ?? AgentFeed.hhmm(now()), done: done.filter { !$0.undone }.map(\.text), urgent: urgent.map(\.title),
                  pending: cards.map { BriefNote.Pending(id: $0.id, title: $0.displayTitle) })
    }

    /// 点了简报的通知：回「今天」，简报放在最上面。核心的数据还没到时，到了再拼
    public func openBrief(time: String? = nil) {
        guard mayNavigate() else { return }
        if page != .today || focus != nil { entrance = .page }
        focus = nil
        if page != .today { go(.today) }
        if waitingForFeed {
            briefNote = nil
            briefPending = time ?? AgentFeed.hhmm(now())
            return
        }
        briefNote = makeBrief(time: time)
    }

    /// 核心的第一份 feed 到了，「今天」已经照它排好：等着的简报这时拼。核心先给全部卡片、最后给 feed，所以一张不少
    func feedArrived() {
        waitingForFeed = false
        guard let time = briefPending else { return }
        briefPending = nil
        briefNote = makeBrief(time: time)
    }

    public func closeBrief() {
        briefNote = nil
        briefPending = nil
    }

    /// 点了核心发的通知：简报（编号 brief）打开「今天」最上面的简报，别的打开「今天」。不是核心发的不管
    public func openNotification(_ userInfo: [AnyHashable: Any]) {
        guard AgentNotification.clicked(userInfo).isAgent else { return }
        if userInfo[AgentNotification.userInfoKey] as? String == "brief" { openBrief() } else { go(.today) }
    }

    // MARK: 一件件处理

    /// 进「一件件处理」：从要你决定的第一件开始，次序和「今天」页上一样（同一类的挨着，一类处理完再下一类）。
    /// 给了 `category`（「按类处理」里点的那一类）就只走这一类；这一类已经没有卡片了就不进
    public func enterFocus(category: String? = nil) {
        let all = decideCategories
        let picked = category.map { id in all.filter { $0.id == id } } ?? all
        let ids = picked.flatMap(\.ids)
        guard !ids.isEmpty else { return }
        closeAsk()
        focus = FocusSession(ids: ids, category: category, categoryName: category == nil ? nil : picked.first?.name)
    }

    /// 「要你决定」分成的几类，次序照「今天」页上（第一张出现的位置）
    public var decideCategories: [DecideCategory] {
        TodayStack.cards(cards).map { g in
            DecideCategory(id: TodayStack.key(g[0].tool, g[0].kind, g[0].title), tool: g[0].tool,
                           name: categoryName(tool: g[0].tool, kind: g[0].kind), ids: g.map(\.id))
        }
    }

    /// 「按类处理」列哪几类：有两类以上时，不止一件的那几类（只有一类时页头的「一件件处理」就是它；
    /// 一类只有一件时点开那张卡片就是了）
    public var categoriesToPick: [DecideCategory] {
        let all = decideCategories
        guard all.count > 1 else { return [] }
        return all.filter { $0.ids.count > 1 }
    }

    /// 一类事的名字：核心推来的每类事（`kinds`，编号是「应用:类」）里的，核心给不出名字时（「这一类事」）写应用的名字
    func categoryName(tool: ToolIcon, kind: String?) -> String {
        if let k = kind, !k.isEmpty,
           let s = kinds.first(where: { $0.tool == tool && ($0.id == k || $0.id.hasSuffix(":" + k)) }),
           !s.title.isEmpty, s.title != Self.unnamedKind {
            return s.title
        }
        return tool.name
    }

    /// 核心没有这一类的名字时写的（luoke_agent/agent.py `_label`）
    static let unnamedKind = "这一类事"

    /// 回「今天」
    public func exitFocus() {
        guard focus != nil else { return }
        entrance = .fromFocus
        focus = nil
    }

    /// 正摆着的那一件：进来时的那几件里，还没答、没跳过的第一件
    public var focusCurrent: TodayCard? {
        guard let f = focus else { return nil }
        for id in f.ids where !f.skipped.contains(id) {
            if let c = cards.first(where: { $0.id == id }) { return c }
        }
        return nil
    }

    /// 进来以后答了几件：用户点过、已经不在要你决定里的。工具换掉、收走的不算
    public var focusAnswered: Int {
        guard let f = focus else { return 0 }
        return f.ids.filter { id in f.tapped.contains(id) && !cards.contains { $0.id == id } }.count
    }

    /// 一件件处理时要你决定的变了：用户没点就不见了的那件，同一类（同一个应用、同一类事，`TodayStack.key`，
    /// 也就是 `DecideCategory.id`）这次新出了一张，就是工具把它换掉了，新的顶在原来的位置（正看着的就还是这一件，不跳）；
    /// 没有同一类的顶上，是工具收走了，从这一轮里去掉。同一个应用别的类的新卡片不算换上来的：只走一类时这一轮里
    /// 不混进别的类，走全部时也不在同一个应用里换到别的类上
    private func followReplacedCards(old: [TodayCard]) {
        guard var f = focus else { return }
        let present = Set(cards.map(\.id))
        let before = Set(old.map(\.id))
        let key = { (c: TodayCard) in TodayStack.key(c.tool, c.kind, c.title) }
        var fresh = cards.filter { !before.contains($0.id) && !f.ids.contains($0.id) }
        var ids: [String] = []
        for id in f.ids {
            if present.contains(id) || f.tapped.contains(id) { ids.append(id); continue }
            guard let gone = old.first(where: { $0.id == id }).map(key), f.category.map({ $0 == gone }) ?? true,
                  let i = fresh.firstIndex(where: { key($0) == gone }) else { continue }
            let new = fresh.remove(at: i).id
            ids.append(new)
            if f.skipped.contains(id) { f.skipped.append(new) }
        }
        guard ids != f.ids else { return }
        f.ids = ids
        focus = f
    }

    /// 只走了一类、这一类都答完了，「要你决定」里还有别的事：这一类的名字（一件件处理的最后一屏照它说「这一类完了」）
    public var focusCategoryDone: String? {
        guard let name = focus?.categoryName, focusCurrent == nil, focusLeft == 0, !cards.isEmpty else { return nil }
        return name
    }

    /// 跳过了、还在要你决定里的
    public var focusLeft: Int {
        guard let f = focus else { return 0 }
        return f.ids.filter { id in cards.contains { $0.id == id } }.count
    }

    public func skipFocus(viaKey: Bool = false) {
        guard var f = focus, let c = focusCurrent else { return }
        f.skipped.append(c.id)
        f.viaKey = viaKey
        focus = f
    }

    /// 点了正摆着那件的一个按钮（键盘的 ⏎ 是标了 primary 的那个）；这张卡片正在处理上一下点按时不算
    public func answerFocus(_ actionId: String, viaKey: Bool = false) {
        guard var f = focus, let c = focusCurrent, !c.surface.busy,
              let (name, ctx) = try? c.surface.surface.action(actionId) else { return }
        f.viaKey = viaKey
        f.tapped.insert(c.id)
        focus = f
        tap(card: c, componentId: actionId, name: name, context: ctx)
    }

    /// ⏎：答标了 primary 的那个按钮，没标的不答
    public func answerFocusPrimary(viaKey: Bool = true) {
        guard let c = focusCurrent, let a = SurfaceDigest(c.surface.surface).primary else { return }
        answerFocus(a.id, viaKey: viaKey)
    }

    // MARK: 今天里的点按

    public func handleUrgent(_ id: String, primary: Bool) {
        guard let i = urgent.firstIndex(where: { $0.id == id }) else { return }
        let item = urgent.remove(at: i)
        show(primary ? "已移到垃圾邮件" : "标成不可疑") { [weak self] in self?.urgent.insert(item, at: min(i, self?.urgent.count ?? 0)) }
    }

    public func tap(card: TodayCard, name: String, context: JSONValue) {
        tap(card: card, componentId: "", name: name, context: context)
    }

    public func tap(card: TodayCard, componentId: String, name: String, context: JSONValue) {
        if askedHost(card.id, componentId, run: { [weak self] in self?.backend?.action(surfaceId: card.id, componentId: componentId, context: context) }) { return }
        if let backend { backend.action(surfaceId: card.id, componentId: componentId, context: context); return }
        onCardAction?(self, card, name, context)
    }

    /// 急事横幅、「已经替你做了」「顺便看看」里那几张核心的卡片被点了
    public func tapSurface(_ id: String, componentId: String, context: JSONValue) {
        // 等权限时页可能重画过，组件 id 会变：转的时候按现在这一页的
        if askedHost(id, componentId, run: { [weak self] in
            guard let self else { return }
            self.backend?.action(surfaceId: id, componentId: self.pageHostAsks[id]?.button ?? componentId, context: context)
        }) { return }
        backend?.action(surfaceId: id, componentId: componentId, context: context)
    }

    /// 收走一张卡片，提示带撤销
    public func removeCard(_ id: String, toast text: String, undo: (() -> Void)? = nil) {
        guard let i = cards.firstIndex(where: { $0.id == id }) else { return }
        let c = cards.remove(at: i)
        show(text) { [weak self] in
            guard let self else { return }
            self.cards.insert(c, at: min(i, self.cards.count))
            undo?()
        }
    }

    /// 示例里答完一张卡片：卡片收走，「已经替你做了」最上面多一行，「活动」里记一条；撤销（提示上的、那一行上的）放回原处
    public func moveToDone(_ cardID: String, row: DoneRow, toast text: String) {
        guard let i = cards.firstIndex(where: { $0.id == cardID }) else { return }
        let c = cards.remove(at: i)
        done.insert(row, at: 0)
        let actID = "act-\(row.id)"
        activity.insert(ActivityRow(id: actID, day: "今天", time: row.time, tool: row.tool, auto: false, text: row.text,
                                    undoLabel: row.undoLabel, mark: .new), at: 0)
        let restore: () -> Void = { [weak self] in
            guard let self, self.restores[row.id] != nil else { return }
            self.restores[row.id] = nil
            self.done.removeAll { $0.id == row.id }
            self.activity.removeAll { $0.id == actID }
            self.cards.insert(c, at: min(i, self.cards.count))
        }
        restores[row.id] = restore
        show(text, undo: restore)
    }

    public func undoDone(_ id: String) {
        if let r = restores[id] {
            r()
            show("撤销了")
            return
        }
        guard let i = done.firstIndex(where: { $0.id == id }), !done[i].undone else { return }
        done[i].undone = true
        let label = done[i].undoLabel ?? "撤销"
        show(label == "放回" ? "放回了" : "撤销了") { [weak self] in
            if let j = self?.done.firstIndex(where: { $0.id == id }) { self?.done[j].undone = false }
        }
    }

    public func undoActivity(_ id: String) {
        guard let i = activity.firstIndex(where: { $0.id == id }), !activity[i].undone else { return }
        activity[i].undone = true
        show(activity[i].undoLabel == "放回" ? "放回了" : "撤销了") { [weak self] in
            if let j = self?.activity.firstIndex(where: { $0.id == id }) { self?.activity[j].undone = false }
        }
    }

    // MARK: 本体的界面（HostPage）

    /// 本体的界面开着（哪一种都算）：用户看的不是底下那页。报给核心的页名是 `host`（§11），新来的事项不算看过
    public var hostShowing: Bool { hostPage != nil || hostCard != nil || hostTakeover != nil }

    /// 侧栏亮哪一行：本体的一页、整窗盖着时一行都不亮（用户看的不是底下那页）；浮着的卡片不算，底下那页照旧亮
    public var sidebarSelection: Page? { hostPage != nil || hostTakeover != nil ? nil : page }

    /// 本体放上一屏：按 `style` 放进对应的位置。同一个编号再放是换内容（不算离开、不调 `hostPageClosed`）；
    /// 换了放法的，原来那个位置上的收掉
    public func present(_ p: HostPage) {
        if hostPage?.id == p.id && p.style != .page { hostPage = nil }
        if hostCard?.id == p.id && p.style != .card { hostCard = nil }
        if hostTakeover?.id == p.id && p.style != .takeover { hostTakeover = nil }
        switch p.style {
        case .card:
            hostCard = p
        case .page, .takeover:
            let fresh = (p.style == .page ? hostPage : hostTakeover)?.id != p.id
            if fresh {
                entrance = .page
                clearSecureFields()          // 底下那页看不见了：密码框里填的字照「离开一页」清掉（工具协议 §4 secureField）
                closeAsk()
                closeSearch()
            }
            if p.style == .page { hostPage = p } else { hostTakeover = p }
        }
    }

    /// 本体自己收起这一屏（做完了、换成别的了）：不调 `hostPageClosed`
    public func dismissHost(_ id: String) {
        var under = false
        if hostPage?.id == id { hostPage = nil; under = true }
        if hostTakeover?.id == id { hostTakeover = nil; under = true }
        if hostCard?.id == id { hostCard = nil }
        if under { uncovered() }
    }

    /// 用户离开本体的这一屏（卡片的 ×、Esc，或去了别处）：先问本体，走不开（正在删、正在升级）答 false、什么都不动；
    /// 走得开就收起、告诉本体，答 true
    @discardableResult func leaveHost(_ id: String) -> Bool {
        guard [hostPage, hostCard, hostTakeover].contains(where: { $0?.id == id }) else { return true }
        if let host, !host.hostPageCanLeave(id) { return false }
        var under = false
        if hostPage?.id == id { hostPage = nil; under = true }
        if hostTakeover?.id == id { hostTakeover = nil; under = true }
        if hostCard?.id == id { hostCard = nil }
        host?.hostPageClosed(id)
        if under { uncovered() }
        return true
    }

    /// 换页、去「今天」、开简报之前：整个窗口是本体的界面时哪儿都不去；内容区是本体的一页时先离开它（本体不放就不换）。
    /// 浮着的卡片不管：它盖着整个窗口，侧栏点不到；菜单、通知换了底下的页，卡片照旧浮着等用户答
    func mayNavigate() -> Bool {
        if hostTakeover != nil { return false }
        if let p = hostPage { return leaveHost(p.id) }
        return true
    }

    /// 本体的一页、整窗的界面收起了：底下那页重新进场，核心的数据重读一遍（盖着的时候没读）
    private func uncovered() {
        entrance = .page
        loadVisible()
    }

    /// 接着本体时，这几页在本体没给界面时由本体的窗口打开（luoke-core#68）：添加应用，「设置」的模型、隐私。
    /// 交出去了返回 true，窗口留在原来那页。
    func handOff(_ p: Page, tab: String?) -> Bool {
        guard let host else { return false }
        if p == .apps {
            guard host.appsContent() == nil else { return false }
            host.openAddApps()
            return true
        }
        guard p == .prefs, let t = tab.flatMap(PrefsTab.init(rawValue:)), prefsTabOpensElsewhere(t) else { return false }
        if t == .model { host.openModelSettings() } else { host.openPrivacySettings() }
        return true
    }

    /// 「设置」的哪几个标签是本体的窗口（标签上画「在别处打开」的小图标）：本体给了界面的画在设置里，不算
    public func prefsTabOpensElsewhere(_ t: PrefsTab) -> Bool {
        guard let host, t == .model || t == .privacy else { return false }
        return host.settingsContent(t) == nil
    }

    /// 升级应用（交给主控：接着本体时由本体升；示例里直接升好）
    public func upgrade(_ tool: ToolIcon) {
        if let host {
            if host.appsContent() != nil { go(.apps) }      // 升级在主窗口的「添加应用」页里做
            host.upgrade(app: tool.accessory)
            return
        }
        guard let i = apps.firstIndex(where: { $0.tool == tool }), let to = apps[i].update else { return }
        apps[i].version = to
        apps[i].update = nil
        quiet.removeAll { $0.id == "upd-\(tool.rawValue)" }
        if let j = catalog.firstIndex(where: { $0.tool == tool }) { catalog[j].state = .installed }
        show("\(tool.name)升到 \(to)")
    }

    // MARK: 权限

    public func requestPermission(_ key: String) {
        guard let row = permissions.first(where: { $0.id == key }) else { return }
        let facts = key == "calendar" ? ["加入日程时写一个事件", "只在这台 Mac 上"] : ["让它也能搜到", "只在这台 Mac 上"]
        sheet = PermissionSheet(key: key, owner: row.owner, title: key == "calendar" ? "读写日历" : "读取\(row.title)", facts: facts)
    }

    public func closeSheet() { sheet = nil }

    /// 点了「继续」：系统授权框由应用自己弹；接上核心时交给核心（`POST /permissions` 的 `request`），示例里直接算允许了
    public func continueSheet() {
        guard var s = sheet, !s.waiting else { return }
        s.waiting = true
        sheet = s
        if let app = s.app {
            permissionPending["\(app)#\(s.key)"] = "request"
            backend?.permission(app: app, id: s.key, op: "request")
            return
        }
        grant(s.key)
    }

    public func grant(_ key: String) {
        if let i = permissions.firstIndex(where: { $0.id == key }) { permissions[i].state = .granted }
        cards.removeAll { $0.id == "perm-\(key)" }
        for i in searchSections.indices where searchSections[i].needsPermission == key { searchSections[i].needsPermission = nil }
        sheet = nil
        show("已允许")
    }

    // MARK: 设置

    public func setLevel(_ id: String, _ level: Level) {
        if let i = kinds.firstIndex(where: { $0.id == id }) { kinds[i].level = level }
        backend?.updateSettings(["modes": .object([id: .string(level.rawValue)])])
    }

    public func setAlerts(_ on: Bool) {
        alertsOn = on
        backend?.updateSettings(["proactive": .bool(on)])
    }

    public func setBrief(_ b: BriefMode) {
        brief = b
        backend?.updateSettings(["brief": .string(b.agentValue)])
    }

    /// 免打扰：「22:00 – 08:00」这样写，或者「关」
    public func setQuiet(_ label: String) {
        quietHours = label
        let parts = label.components(separatedBy: " – ")
        let value: JSONValue = parts.count == 2 ? .object(["start": .string(parts[0]), "end": .string(parts[1])]) : .null
        backend?.updateSettings(["quiet": value])
    }

    /// 「免打扰」能选的：常用的两档、关，加上现在的（核心里设的可能不在这几档里）
    public var quietOptions: [String] {
        var o = ["22:00 – 08:00", "23:00 – 07:00", "关"]
        if !o.contains(quietHours) { o.insert(quietHours, at: 0) }
        return o
    }

    /// 核心说的暂停到几点（`paused_until`）
    func setPausedFromAgent(_ hhmm: String?) { pausedUntil = hhmm }

    public func setDelegate(_ id: String, on: Bool) {
        if let i = delegates.firstIndex(where: { $0.id == id }) { delegates[i].on = on }
        show(on ? "开了" : "关了")
    }

    public func setTier(_ id: String) {
        guard id != currentTier, let t = tiers.first(where: { $0.id == id }) else { return }
        currentTier = id
        show("换到\(t.title)：空闲时下载，下完再换")
    }

    // MARK: 菜单栏图标

    public func togglePause() {
        if let backend {
            let until = pausedUntil == nil ? JSONValue.string(AgentFeed.iso(Date().addingTimeInterval(3600))) : .null
            pausedUntil = pausedUntil == nil ? AgentFeed.hhmm(Date().addingTimeInterval(3600)) : nil
            backend.updateSettings(["paused_until": until])
            show(pausedUntil != nil ? "一小时内不弹通知，事情照样放进「今天」" : "提醒恢复了")
            return
        }
        if pausedUntil == nil {
            pausedUntil = "11:02"
            show("一小时内不弹通知，事情照样放进「今天」")
        } else {
            pausedUntil = nil
            show("提醒恢复了")
        }
    }

    // MARK: 提示

    public func show(_ text: String, undo: (() -> Void)? = nil) {
        undoAction = undo
        toast = Toast(text: text, canUndo: undo != nil)
        toastTask?.cancel()
        toastTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 3_200_000_000)
            if !Task.isCancelled { self?.toast = nil }
        }
    }

    public func undoLast() {
        let u = undoAction
        undoAction = nil
        toast = nil
        u?()
    }

    public func dismissToast() {
        toastTask?.cancel()
        toast = nil
    }
}
