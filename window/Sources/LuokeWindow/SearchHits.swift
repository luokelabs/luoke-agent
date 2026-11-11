import Foundation
import LuokeA2UICore

/// 搜索框里的一条结果：工具给的 `hits` 里的一条（工具协议 §1b），核心核过形状交来（docs/界面接口.md §7）。
/// 字都当数据，画成纯文本。按钮不带参数：点了交给核心，核心从它留下的结果里取参数转给工具（`POST /hit`）。
public struct WindowHit: Identifiable, Equatable {
    /// 出这条的应用（配件标识）
    public let app: String
    /// 工具给的编号
    public let hitID: String
    public let kind: String
    public let kindLabel: String?
    public let title: String
    public let line: String?
    public let date: String?
    public let snippet: String?
    /// 工具里的分区：邮件是收件的邮箱地址
    public let source: String?
    public let path: String?
    /// 缩略图 `thumb/<id>`：窗口经核心读（`GET /thumb`）
    public let thumb: String?
    public let actions: [HitAction]

    public var id: String { app + "\u{1}" + hitID }

    public init(app: String, hitID: String, kind: String, kindLabel: String? = nil, title: String, line: String? = nil,
                date: String? = nil, snippet: String? = nil, source: String? = nil, path: String? = nil,
                thumb: String? = nil, actions: [HitAction] = []) {
        self.app = app
        self.hitID = hitID
        self.kind = kind
        self.kindLabel = kindLabel
        self.title = title
        self.line = line
        self.date = date
        self.snippet = snippet
        self.source = source
        self.path = path
        self.thumb = thumb
        self.actions = actions
    }

    /// 核心交来的一条；没有编号、标题的不算
    init?(app: String, _ v: JSONValue) {
        guard let id = v["id"]?.string, !id.isEmpty, let title = v["title"]?.string, !title.isEmpty else { return nil }
        let text = { (k: String) -> String? in v[k]?.string.flatMap { $0.isEmpty ? nil : $0 } }
        self.init(app: app, hitID: id, kind: text("kind") ?? "other", kindLabel: text("kind_label"), title: title,
                  line: text("line"), date: text("date"), snippet: text("snippet"), source: text("source"),
                  path: text("path"), thumb: text("thumb"),
                  actions: (v["actions"]?.array ?? []).compactMap { a in
                      guard let t = a["title"]?.string, !t.isEmpty else { return nil }
                      return HitAction(title: t, primary: a["primary"]?.bool == true, reveal: a["reveal"]?.bool == true)
                  })
    }

    /// 打开（回车）：标了 primary 的，没有就第一个不是「在访达中显示」的；⌘↩：在访达中显示的那个。答它在 `actions` 里的序号
    public func actionIndex(reveal: Bool) -> Int? {
        if reveal { return actions.firstIndex { $0.reveal } }
        return actions.firstIndex { $0.primary && !$0.reveal } ?? actions.firstIndex { !$0.reveal }
    }

    /// 路径只写最后一两层文件夹（「文稿 › 报销」）：家目录以上的不写，家里常见的几个文件夹用访达里的中文名
    public var folders: String? {
        guard let path, path.hasPrefix("/") else { return nil }
        var parts = path.split(separator: "/").map(String.init).dropLast()
        if parts.count >= 2, parts[parts.startIndex] == "Users" { parts = parts.dropFirst(2) }
        let shown = parts.suffix(2).map { Self.finderNames[$0] ?? $0 }
        return shown.isEmpty ? nil : shown.joined(separator: " › ")
    }

    static let finderNames = ["Documents": "文稿", "Downloads": "下载", "Desktop": "桌面", "Pictures": "图片",
                              "Movies": "影片", "Music": "音乐", "Library": "资源库"]

    /// 日期：`2026-10-03T…` → 列表里「10-03」，预览里「2026-10-03」；看不懂的原样
    public func day(full: Bool) -> String? {
        guard let date else { return nil }
        let d = String(date.prefix(10))
        guard d.count == 10, d.dropFirst(4).first == "-" else { return date }
        return full ? d : String(d.dropFirst(5))
    }
}

/// 一条结果上的一个按钮；参数在核心那里
public struct HitAction: Equatable {
    public let title: String
    public let primary: Bool
    /// 「在访达中显示」（agent 交来的动作上标了 `reveal: true`）：⌘↩ 按的是它
    public let reveal: Bool

    public init(title: String, primary: Bool = false, reveal: Bool = false) {
        self.title = title
        self.primary = primary
        self.reveal = reveal
    }
}

/// 按类型的一组（不按工具）：PDF、表格、文档、图片（截图、照片）、录音、视频、邮件、记忆；别的类型各自一组
public struct HitGroup: Identifiable, Equatable {
    public let id: String
    public let label: String
    public let icon: String
    /// 画成缩略图格子（PDF、表格、图片、视频）；别的一行一条
    public let grid: Bool
    public var hits: [WindowHit]

    /// 组的编号：截图、照片都算图片
    public static func key(_ kind: String) -> String {
        switch kind {
        case "image", "screenshot", "photo": return "image"
        default: return kind
        }
    }

    static let known: [String: (label: String, icon: String, grid: Bool)] = [
        "pdf": ("PDF", "file-text", true), "sheet": ("表格", "sheet", true), "doc": ("文档", "file", false),
        "image": ("图片", "image", true), "video": ("视频", "video", true), "audio": ("录音", "mic", false),
        "mail": ("邮件", "mail", false), "memory": ("记忆", "brain", false),
    ]

    /// 分组：跨工具合在一起；组的顺序按每组第一条出现的先后（各工具照问的顺序、工具里照它给的顺序），组里照工具给的顺序
    public static func make(_ hits: [WindowHit]) -> [HitGroup] {
        var out: [HitGroup] = []
        var at: [String: Int] = [:]
        for h in hits {
            let k = key(h.kind)
            if let i = at[k] {
                out[i].hits.append(h)
            } else {
                let spec = known[k] ?? (h.kindLabel ?? "其他", "file", false)
                at[k] = out.count
                out.append(HitGroup(id: k, label: spec.label, icon: spec.icon, grid: spec.grid, hits: [h]))
            }
        }
        return out
    }

    /// 邮件按收件的邮箱分块（`source` 是邮箱地址），照第一封出现的先后
    public var mailboxes: [(address: String, hits: [WindowHit])] {
        var out: [(address: String, hits: [WindowHit])] = []
        for h in hits {
            let a = h.source ?? ""
            if let i = out.firstIndex(where: { $0.address == a }) { out[i].hits.append(h) } else { out.append((a, [h])) }
        }
        return out
    }
}

/// 搜索框结果的样子：先列几个、选中的那条、筛选。只是算法，界面照它画，测试直接测它
public enum SearchLayout {
    /// 每组先列几个：一行的格子数（没选中四个，选中时右边出预览、一行三个）；一行一条的先列四条
    /// 选中的那条排在后面时照样列出来（不然右边出预览、一行变三个时它就不见了）
    public static func shown(_ group: HitGroup, filtered: Bool, previewing: Bool, selected: String? = nil) -> [WindowHit] {
        if filtered { return group.hits }
        var n = group.grid ? (previewing ? 3 : 4) : 4
        if let selected, let i = group.hits.firstIndex(where: { $0.id == selected }) { n = max(n, i + 1) }
        return Array(group.hits.prefix(n))
    }

    /// 现在画出来的各组（筛了一类就只有那一类）
    public static func visible(_ groups: [HitGroup], filter: String?) -> [HitGroup] {
        guard let filter else { return groups }
        return groups.filter { $0.id == filter }
    }

    /// 键盘上下走的顺序：画出来的顺序
    public static func order(_ groups: [HitGroup], filter: String?, previewing: Bool, selected: String? = nil) -> [WindowHit] {
        visible(groups, filter: filter).flatMap { g -> [WindowHit] in
            let s = shown(g, filtered: filter != nil, previewing: previewing, selected: selected)
            return g.id == "mail" ? HitGroup(id: g.id, label: g.label, icon: g.icon, grid: false, hits: s).mailboxes.flatMap(\.hits) : s
        }
    }
}
