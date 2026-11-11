import Foundation

/// A2UI v0.9.1 的一张卡片（surface）：按组件目录校验、应用更新、取按钮的动作。
/// 规矩和 luoke-agent 的 `luoke_agent/a2ui.py` 一条一条对应，改一边要改另一边。
public enum A2UI {
    public static let version = "v0.9"
    public static let maxComponents = 200
    /// 应用页（工具协议 §1a `page/<id>`）的上限，核心认 bigPages（§4，2026-11-10）
    public static let maxPageComponents = 400
    public static let maxText = 2000
    /// `agent.open_page` 的 args（§4 pageArgs）：最多 4 个键，值不超过 200 字（按码位数，同 Python 的 len）
    public static let maxPageArgs = 4
    public static let maxPageArg = 200
    /// 页的 root 上的 refresh（§4 pageRefresh）：几秒以后再读
    public static let refreshRange = 2...60
    /// 答复里的 file（§4 saveFile）：UTF-8 不超过 512 KB，文件名不超过 100 字
    public static let maxFileBytes = 512 * 1024
    public static let maxFileName = 100
    public static let messageKinds = ["createSurface", "updateComponents", "updateDataModel", "deleteSurface"]
    /// agent 自己处理的动作（工具协议 §5）
    public static let agentEvents: Set<String> = ["agent.open_url", "agent.open_page", "agent.dismiss", "agent.remind"]

    /// `agent.open_page` 的页 id：同清单里 service.pages 的 id（`luoke_agent/a2ui.py` 的 `PAGE_ID`），不带应用名
    public static func pageIDAcceptable(_ id: String) -> Bool {
        let s = Array(id.unicodeScalars)
        func ok(_ c: Unicode.Scalar) -> Bool { ("a"..."z").contains(c) || ("A"..."Z").contains(c) || ("0"..."9").contains(c) }
        guard let first = s.first, ok(first), s.count <= 64 else { return false }
        return s.dropFirst().allSatisfy { ok($0) || $0 == "." || $0 == "_" || $0 == "-" }
    }
    /// args 的键：小写字母开头，后面是小写字母、数字、下划线，最长 16 个字（`[a-z][a-z0-9_]{0,15}`）
    public static func pageArgKeyAcceptable(_ key: String) -> Bool {
        let s = Array(key.unicodeScalars)
        guard let first = s.first, ("a"..."z").contains(first), s.count <= 16 else { return false }
        return s.dropFirst().allSatisfy { ("a"..."z").contains($0) || ("0"..."9").contains($0) || $0 == "_" }
    }

    /// 取好值的 args（§4 pageArgs）对不对：对是 nil，不对是一句为什么。同 `luoke_agent/a2ui.py` 的 `page_args_problem`
    public static func pageArgsProblem(_ args: JSONValue) -> String? {
        guard let o = args.object else { return "args 要是对象" }
        if o.count > maxPageArgs { return "args 最多 \(maxPageArgs) 个" }
        for (k, v) in o.sorted(by: { $0.key < $1.key }) {
            guard pageArgKeyAcceptable(k) else { return "args 的键要是小写字母开头的短名字" }
            guard let s = v.string else { return "args 的 \(k) 要是文字" }
            if s.unicodeScalars.count > maxPageArg { return "args 的 \(k) 超过 \(maxPageArg) 字" }
        }
        return nil
    }

    /// 带参数读页的查询串（不带 `?`）：键按字母顺序，值按 RFC 3986 百分号编码（同 `page_uri`）
    public static func pageQuery(_ args: [String: String]) -> String {
        let unreserved = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
        return args.keys.sorted().map { k in "\(k)=\(args[k]!.addingPercentEncoding(withAllowedCharacters: unreserved) ?? "")" }
            .joined(separator: "&")
    }

    /// 答复里的 file（§4 saveFile）：形状对就是（文件名，类型，内容），不对是 nil。同 `luoke_agent/a2ui.py` 的 `save_file`
    public static func saveFile(_ v: JSONValue?) -> (name: String, mediaType: String, text: String)? {
        guard let name = v?["name"]?.string, let media = v?["mediaType"]?.string, let text = v?["text"]?.string else { return nil }
        let n = Array(name.unicodeScalars)
        guard (1...maxFileName).contains(n.count), n.first != ".", name == name.trimmingCharacters(in: .whitespacesAndNewlines) else { return nil }
        for c in n {
            if c == "/" || c == ":" || c == "\\" { return nil }
            switch c.properties.generalCategory {
            case .control, .format, .surrogate, .lineSeparator, .paragraphSeparator: return nil
            default: continue
            }
        }
        // 类型在名单里、文件名以它的扩展名结尾（不分大小写）才存：存不出 .command、.terminal 这类能执行的
        guard let ext = fileTypes[media], name.lowercased().hasSuffix(ext), n.count > ext.count,
              text.utf8.count <= maxFileBytes else { return nil }
        return (name, media, text)
    }

    /// 能存的几种文字文件和各自的扩展名（§4 saveFile）。同 `luoke_agent/a2ui.py` 的 `FILE_TYPES`
    public static let fileTypes: [String: String] = ["text/plain": ".txt", "text/csv": ".csv", "application/json": ".json",
                                                     "text/markdown": ".md", "application/xml": ".xml"]

    /// Icon 能用的名字（工具协议 §4「图标」）：Lucide 的名字，和以前的名字（照旧认，画成对应的 Lucide 图标）
    public static let lucideIcons: Set<String> = ["app-window", "archive", "brain", "calendar", "calendar-plus", "check", "chevron-down",
                                                  "chevron-right", "circle-help", "circle-minus", "clock", "copy", "cpu", "eye", "file", "folder",
                                                  "folder-open", "globe", "hard-drive", "inbox", "info", "key", "keyboard", "lightbulb", "link",
                                                  "lock", "mail", "package", "pencil-line", "power", "puzzle", "refresh-cw", "reply", "settings",
                                                  "shield-alert", "shield-check", "sparkles", "square-arrow-out-up-right", "star", "trash-2",
                                                  "trending-up", "triangle-alert", "user", "x"]
    public static let iconAliases: [String: String] = ["warning": "triangle-alert", "close": "x", "trash": "trash-2", "person": "user",
                                                       "memory": "brain", "question": "circle-help", "open": "square-arrow-out-up-right"]
    public static var icons: Set<String> { lucideIcons.union(iconAliases.keys) }
    /// 图标名换成 Lucide 的名字（以前的名字照旧认）；不认得的是 nil
    public static func lucide(_ name: String?) -> String? {
        guard let name else { return nil }
        if lucideIcons.contains(name) { return name }
        return iconAliases[name]
    }
    public static let textVariants: Set<String> = ["h1", "h2", "h3", "h4", "h5", "body", "caption", "strong", "badge"]
    /// 标签（variant badge）的颜色：不写是浅蓝，danger 红，warning 橙，neutral 米色（大小这类不分好坏的，§4 neutralBadge）
    public static let tones: Set<String> = ["danger", "warning", "neutral"]
    /// 应用页里一段的位置（工具协议 §4「宽窗口的侧栏」）：只有 aside，写在根 Column 下面一层的 Column 上
    public static let placements: Set<String> = ["aside"]
    /// 应用页怎么排（工具协议 §4 pageSections）：只有 sections，写在页的根 Column 上
    public static let layouts: Set<String> = ["sections"]

    /// `agent.open_url` 的网址认不认得：规矩同 `luoke_agent/a2ui.py` 的 `open_url_site`，一样按码位（Unicode scalar）看。
    /// 不认：不是 https、反斜杠、空白和控制字符、userinfo（@）、空主机、主机里有 %、[、]，看着像数字却不是规范的 IPv4。
    /// 这边不转 punycode（非 ASCII 的那段只查不空）：去哪个网站一律用 agent 核心写在按钮上的 `site`。
    public static func openURLAcceptable(_ url: String) -> Bool {
        let all = Array(url.unicodeScalars)
        let scheme = Array("https://".unicodeScalars)
        guard all.starts(with: scheme), all.count <= maxText, !all.contains("\\") else { return false }
        for s in all {
            switch s.properties.generalCategory {
            case .control, .format, .surrogate, .spaceSeparator, .lineSeparator, .paragraphSeparator: return false
            default: continue
            }
        }
        let rest = all[scheme.count...]
        let authority = rest[..<(rest.firstIndex { $0 == "/" || $0 == "?" || $0 == "#" } ?? rest.endIndex)]
        guard !authority.contains("@") else { return false }
        var host = authority
        if let colon = authority.lastIndex(of: ":") {
            host = authority[..<colon]
            let port = authority[(colon + 1)...]
            guard (1...5).contains(port.count), port.allSatisfy({ ("0"..."9").contains($0) }) else { return false }
            let n = port.reduce(0) { $0 * 10 + Int($1.value) - 48 }
            guard n > 0, n < 65536 else { return false }
        }
        guard !host.isEmpty, !host.contains(where: { $0 == "%" || $0 == "[" || $0 == "]" }) else { return false }
        let ascii = host.allSatisfy { $0.isASCII }
        var dots: Set<Unicode.Scalar> = ["."]
        if !ascii { dots.formUnion(["\u{3002}", "\u{FF0E}", "\u{FF61}"]) }   // 同 Python 的 idna 编码按哪几种点分段
        let labels: [[Unicode.Scalar]] = host.split(omittingEmptySubsequences: false) { dots.contains($0) }
            .map { label in label.map { ("A"..."Z").contains($0) ? Unicode.Scalar($0.value + 32)! : $0 } }
        for label in labels where label.allSatisfy({ $0.isASCII }) {     // 空的那段也在这里拒掉
            guard hostLabel(label) else { return false }
        }
        if let last = labels.last, last.allSatisfy({ $0.isASCII }), numeric(last) {
            return labels.count == 4 && labels.allSatisfy { ipv4Part($0) }
        }
        return true
    }

    private static func hostLabel(_ s: [Unicode.Scalar]) -> Bool {
        let ok: (Unicode.Scalar) -> Bool = { ("a"..."z").contains($0) || ("0"..."9").contains($0) || $0 == "_" }
        guard let first = s.first, let last = s.last, s.count <= 63, ok(first), ok(last) else { return false }
        return s.allSatisfy { ok($0) || $0 == "-" }
    }

    private static func numeric(_ s: [Unicode.Scalar]) -> Bool {
        if s.starts(with: ["0", "x"]) {
            return s.dropFirst(2).allSatisfy { ("0"..."9").contains($0) || ("a"..."f").contains($0) }
        }
        return !s.isEmpty && s.allSatisfy { ("0"..."9").contains($0) }
    }

    private static func ipv4Part(_ s: [Unicode.Scalar]) -> Bool {
        guard (1...3).contains(s.count), s.allSatisfy({ ("0"..."9").contains($0) }), s.count == 1 || s.first != "0" else {
            return false
        }
        return s.reduce(0) { $0 * 10 + Int($1.value) - 48 } <= 255
    }
}

/// 组件目录：标识 → 放行哪些组件。渲染器支持全集，按目录只放行一部分。
public enum Catalog {
    public static let agent = "ai.luoke/a2ui/agent/1"
    /// 输入法的目录：它接 LuokeA2UI 之前，以 luoke-ime 的 Manifest.swift 为准
    public static let ime = "ai.luoke/a2ui/ime/1"
    public static let all: [String: Set<String>] = [
        agent: ["Text", "Row", "Column", "List", "Card", "Divider", "Button", "CheckBox", "ChoicePicker",
                "TextField", "DateTimeInput", "Icon", "ProgressBar"],
        ime: ["Text", "CheckBox", "ChoicePicker", "Slider", "TextField", "Button", "Divider", "Row", "Column"],
    ]
}

public struct A2UIError: Error, CustomStringConvertible {
    public let problems: [String]
    public init(_ problems: [String]) { self.problems = problems }
    public var description: String { problems.joined(separator: "；") }
}

/// 一条消息拆开：哪一种、正文。
public func unwrapMessage(_ m: JSONValue) throws -> (kind: String, body: [String: JSONValue]) {
    guard let o = m.object else { throw A2UIError(["消息要是对象"]) }
    guard o["version"]?.string == A2UI.version else { throw A2UIError(["消息的 version 要是 \(A2UI.version)"]) }
    let kinds = A2UI.messageKinds.filter { o[$0] != nil }
    guard kinds.count == 1, let body = o[kinds[0]]?.object else {
        throw A2UIError(["每条消息恰好是 createSurface、updateComponents、updateDataModel、deleteSurface 之一"])
    }
    return (kinds[0], body)
}

public func surfaceId(of m: JSONValue) -> String? {
    guard let (_, body) = try? unwrapMessage(m) else { return nil }
    return body["surfaceId"]?.string
}

public struct Surface {
    public let surfaceId: String
    public let catalogId: String
    public private(set) var components: [String: [String: JSONValue]] = [:]
    public var data: JSONValue = .object([:])
    public private(set) var deleted = false
    /// 应用页（工具协议 §1a `page/<id>`），不是卡片：上限 400 个组件，能写 refresh、密码框（§4，2026-11-10）
    public let page: Bool

    public init(surfaceId: String, catalogId: String, page: Bool = false) throws {
        guard Catalog.all[catalogId] != nil else { throw A2UIError(["不认识的组件目录：\(catalogId)"]) }
        self.surfaceId = surfaceId
        self.catalogId = catalogId
        self.page = page
    }

    /// 一组新卡片的消息（第一条是 createSurface）→ 查过的卡片。`page`：这是应用页，照页的规矩查。
    public static func build(_ messages: [JSONValue], catalog: String = Catalog.agent, page: Bool = false) throws -> Surface {
        guard let first = messages.first else { throw A2UIError(["卡片要是非空的消息数组"]) }
        let (kind, body) = try unwrapMessage(first)
        guard kind == "createSurface" else { throw A2UIError(["第一条消息要是 createSurface"]) }
        guard let sid = body["surfaceId"]?.string, !sid.isEmpty else { throw A2UIError(["createSurface 要有 surfaceId"]) }
        guard body["catalogId"]?.string == catalog else { throw A2UIError(["catalogId 要是 \(catalog)"]) }
        var s = try Surface(surfaceId: sid, catalogId: catalog, page: page)
        for m in messages.dropFirst() { try s.apply(m) }
        try s.check()
        return s
    }

    /// 查过再换上；不行抛错，原卡片不变。
    public func updated(with messages: [JSONValue]) throws -> Surface {
        var s = self
        for m in messages { try s.apply(m) }
        try s.check()
        return s
    }

    /// 只应用不查（渲染器边收边画时用；整组收完再 check）。
    public mutating func apply(_ message: JSONValue) throws {
        let (kind, body) = try unwrapMessage(message)
        guard body["surfaceId"]?.string == surfaceId else { throw A2UIError(["\(kind) 的 surfaceId 不是 \(surfaceId)"]) }
        switch kind {
        case "createSurface":
            throw A2UIError(["这张卡片已经建过了"])
        case "deleteSurface":
            deleted = true
        case "updateComponents":
            guard let comps = body["components"]?.array, !comps.isEmpty else {
                throw A2UIError(["updateComponents 的 components 要是非空数组"])
            }
            var new = components
            for c in comps {
                guard let o = c.object, let id = o["id"]?.string, !id.isEmpty else { throw A2UIError(["组件要是带 id 的对象"]) }
                new[id] = o
            }
            components = new
        default:   // updateDataModel
            let path = body["path"]?.string ?? "/"
            do {
                data = try data.setting(path, to: body["value"])
            } catch {
                throw A2UIError(["updateDataModel 写不进 \(path)"])
            }
        }
    }

    /// 从 root 走得到的组件，按走到的顺序；遇到环不会死循环。
    public func reachable() -> [String] {
        var seen: [String] = []
        var marked = Set<String>()
        var stack = ["root"]
        while let id = stack.popLast() {
            if marked.contains(id) { continue }
            guard let c = components[id] else { continue }
            marked.insert(id)
            seen.append(id)
            var ignore: [String] = []
            stack.append(contentsOf: childIds(c, &ignore, id).reversed())
        }
        return seen
    }

    public func check() throws {
        let p = problems()
        if !p.isEmpty { throw A2UIError(p) }
    }

    /// 整张卡片画得了吗：组件在目录里、属性类型对、引用和环、绑定的路径在、上限。
    public func problems() -> [String] {
        if deleted { return [] }
        guard components["root"] != nil else { return ["没有 id 为 root 的组件"] }
        var problems: [String] = []
        let shown = reachable()
        let limit = page ? A2UI.maxPageComponents : A2UI.maxComponents
        if shown.count > limit { problems.append("组件超过 \(limit) 个") }
        if components.count > 5 * limit { problems.append("这张卡片累积的组件太多了，重新建一张") }
        let allowed = Catalog.all[catalogId] ?? []
        var parents: [String: String] = [:]
        for id in shown {
            let c = components[id]!
            let type = c["component"]?.string ?? "（缺失）"
            guard allowed.contains(type) else {
                problems.append("组件 \(id) 的类型 \(type) 不在目录 \(catalogId) 里，可用的有：" + allowed.sorted().joined(separator: "、"))
                continue
            }
            for child in childIds(c, &problems, id) {
                if components[child] == nil {
                    problems.append("组件 \(id) 引用的 \(child) 不存在")
                } else if child == "root" {
                    problems.append("root 不能是别的组件的子组件")
                } else if let other = parents[child] {
                    problems.append("组件 \(child) 有两个父组件（\(other)、\(id)）")
                } else {
                    parents[child] = id
                }
            }
            checkProps(id, type, c, &problems)
            if type == "Button", c["action"]?["event"]?["name"]?.string == "agent.open_url" {
                if !literalLabel(components[c["child"]?.string ?? ""]) {
                    problems.append("按钮 \(id)：agent.open_url 按钮的子组件要是写死文字的 Text，或一行「图标 + 写死文字的 Text」")
                }
            }
        }
        let rootIsColumn = components["root"]?["component"]?.string == "Column"
        for id in shown {
            if let g = components[id]?["group"] { checkGroup(id, g, &problems) }
            if let v = components[id]?["subtitle"] { checkSubtitle(id, v, &problems) }
        }
        for id in shown {
            guard let c = components[id], let v = c["placement"] else { continue }
            if !(v.string.map { A2UI.placements.contains($0) } ?? false) {
                problems.append("组件 \(id)：placement 只能是 " + A2UI.placements.sorted().joined(separator: "、"))
            } else if c["component"]?.string != "Column" || parents[id] != "root" || !rootIsColumn {
                problems.append("组件 \(id)：placement 只能写在根 Column 下面一层的 Column 上")
            }
        }
        for id in shown {
            guard let n = components[id]?["refresh"] else { continue }
            if id != "root" || !page {
                problems.append("组件 \(id)：refresh 只能写在应用页的 root 上")
            } else if !(n.number.map { $0 == $0.rounded() && Double(A2UI.refreshRange.lowerBound)...Double(A2UI.refreshRange.upperBound) ~= $0 } ?? false) {
                problems.append("root 的 refresh 要是 \(A2UI.refreshRange.lowerBound) 到 \(A2UI.refreshRange.upperBound) 的整数（秒）")
            }
        }
        for id in shown {
            guard let c = components[id], let v = c["layout"] else { continue }
            if id != "root" || !page || c["component"]?.string != "Column" {
                problems.append("组件 \(id)：layout 只能写在应用页的根 Column 上")
            } else if !(v.string.map { A2UI.layouts.contains($0) } ?? false) {
                problems.append("root 的 layout 只能是 " + A2UI.layouts.sorted().joined(separator: "、"))
            }
        }
        // 密码框的路径别处不能碰（§4 secureField）
        let secure = page ? secureFieldPaths : []
        if !secure.isEmpty {
            for id in shown {
                for p in secureProblems(id, components[id]!, secure) where !problems.contains(p) { problems.append(p) }
            }
        }
        problems += cycles(Set(shown))
        checkTextLengths(data, &problems)
        return problems
    }

    /// `group`：做完的卡片在「已经替你做了」里和同一组的合成一行（工具协议 §4「后加的写法」）。只写在 root 上
    func checkGroup(_ id: String, _ g: JSONValue, _ problems: inout [String]) {
        guard id == "root" else { problems.append("组件 \(id)：group 只能写在 root 上"); return }
        guard g.object != nil else { problems.append("root 的 group 要是对象"); return }
        for k in ["key", "text"] {
            if !(g[k]?.string.map { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && $0.count <= A2UI.maxText } ?? false) {
                problems.append("root 的 group.\(k) 要是不空的文字")
            }
        }
        if !(g["n"]?.number.map { $0 == $0.rounded() && $0 >= 1 } ?? false) { problems.append("root 的 group.n 要是正整数") }
        for k in ["label", "badge"] where g[k] != nil && !(g[k]?.string.map { $0.count <= A2UI.maxText } ?? false) {
            problems.append("root 的 group.\(k) 要是文字")
        }
    }

    /// `subtitle`：卡片的副标题，一句分得清是哪一件的字（工具协议 §4「后加的写法」）。只写在 root 上，一句不空的文字
    func checkSubtitle(_ id: String, _ v: JSONValue, _ problems: inout [String]) {
        guard id == "root" else { problems.append("组件 \(id)：subtitle 只能写在 root 上"); return }
        guard let s = v.string, !s.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            problems.append("root 的 subtitle 要是一句不空的文字"); return
        }
        if s.count > A2UI.maxText { problems.append("root 的 subtitle 超过 \(A2UI.maxText) 字") }
    }

    /// 卡片的副标题（root 上的 `subtitle`，工具填的发件人、文件名这类）：紧凑的「今天」里跟在标题后面，同一类的几件分得清
    public var subtitle: String? {
        guard let s = components["root"]?["subtitle"]?.string, !s.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return s
    }

    /// 做完的卡片的分组（root 上的 `group`）：键、这一行怎么写（`{n}` 换成合起来的数）、数、前面的名字、后面的标签
    public var doneGroup: (key: String, text: String, n: Int, label: String?, badge: String?)? {
        guard let g = components["root"]?["group"], let key = g["key"]?.string, let text = g["text"]?.string,
              let n = g["n"]?.number, n >= 1 else { return nil }
        return (key, text, Int(n), g["label"]?.string, g["badge"]?.string)
    }

    /// 打开网页的按钮上的字是写死的：一个 Text，或一行里几个图标加一个 Text（工具协议 §5）
    func literalLabel(_ label: [String: JSONValue]?) -> Bool {
        func literal(_ x: [String: JSONValue]?) -> Bool { x?["component"]?.string == "Text" && x?["text"]?.string != nil }
        if literal(label) { return true }
        guard let label, label["component"]?.string == "Row", let ids = label["children"]?.array else { return false }
        let kids = ids.map { $0.string.flatMap { components[$0] } }
        let texts = kids.filter { $0?["component"]?.string == "Text" }
        return texts.count == 1 && literal(texts[0])
            && kids.allSatisfy { ["Icon", "Text"].contains($0?["component"]?.string ?? "") }
    }

    /// 应用页的 root 写的 refresh（§4 pageRefresh）：这一页看得见时过几秒再读；没写、不是页是 nil
    public var refreshSeconds: Int? {
        guard page, let n = components["root"]?["refresh"]?.number, n == n.rounded(),
              Double(A2UI.refreshRange.lowerBound)...Double(A2UI.refreshRange.upperBound) ~= n else { return nil }
        return Int(n)
    }

    /// 密码框（`TextField` 的 `"variant": "obscured"`，§4 secureField）绑定的路径：点完按钮、离开这一页时清掉
    public var secureFieldPaths: [String] {
        reachable().compactMap { id in
            guard let c = components[id], c["component"]?.string == "TextField", c["variant"]?.string == "obscured" else { return nil }
            return c["value"]?.bindingPath
        }
    }

    /// 根 Column 下面写了 `"placement": "aside"` 的段，按顺序。宽窗口里应用页把它们画进侧栏，别的时候照原来的位置画
    public var asideSections: [String] {
        guard let root = components["root"], root["component"]?.string == "Column" else { return [] }
        return (root["children"]?.array ?? []).compactMap { $0.string }.filter {
            components[$0]?["component"]?.string == "Column" && components[$0]?["placement"]?.string == "aside"
        }
    }

    /// 应用页分段画（工具协议 §4 pageSections）时根下面一层的每一样怎么画；根没写 `"layout": "sections"` 时是 nil。
    /// `aside`：nil 是整页（一栏），true、false 只要侧栏、主栏的段（`placement`）。`Divider` 不画，所以不在里面；
    /// 一段开头的分隔线（原来整页一张卡片时隔开上一段用的）也算在 skip 里不画，跟在它后面的小标题照样提到外面
    public func pageBlocks(aside: Bool? = nil) -> [PageBlock]? {
        guard page, let root = components["root"], root["component"]?.string == "Column",
              root["layout"]?.string == "sections" else { return nil }
        let side = Set(asideSections)
        return (root["children"]?.array ?? []).compactMap { $0.string }.compactMap { id -> PageBlock? in
            guard let c = components[id], let type = c["component"]?.string, type != "Divider" else { return nil }
            if let aside, side.contains(id) != aside { return nil }
            switch type {
            case "Column", "List":
                let kids = (c["children"]?.array ?? []).compactMap { $0.string }
                let lead = kids.prefix { components[$0]?["component"]?.string == "Divider" }.count
                if lead < kids.count, let title = sectionTitle(kids[lead]) {
                    return .card(id, title: title, skip: lead + 1)
                }
                return .card(id, title: nil, skip: lead)
            case "Row" where c["justify"]?.string == "spaceEvenly":
                return .tiles((c["children"]?.array ?? []).compactMap { $0.string })
            default:
                return .bare(id)
            }
        }
    }

    /// 一段开头的小标题（§4 pageSections）：一行 `Row`，一个 `Icon` 加一段字，可以再跟一段字写数；或者一段 `h4`、`h5`
    func sectionTitle(_ id: String) -> SectionTitle? {
        guard let c = components[id], let type = c["component"]?.string else { return nil }
        if type == "Text", ["h4", "h5"].contains(c["variant"]?.string ?? "") {
            return SectionTitle(icon: nil, text: c["text"] ?? .string(""), count: nil)
        }
        let kids = (c["children"]?.array ?? []).compactMap { $0.string }.compactMap { components[$0] }
        guard type == "Row", c["justify"] == nil, (2...3).contains(kids.count), kids[0]["component"]?.string == "Icon",
              kids.dropFirst().allSatisfy({ $0["component"]?.string == "Text" && $0["variant"]?.string != "badge" }) else { return nil }
        return SectionTitle(icon: kids[0]["name"]?.string, text: kids[1]["text"] ?? .string(""), count: kids.count == 3 ? kids[2]["text"] : nil)
    }

    /// 现在画着的按钮声明的动作：（动作名，没解析的上下文）。
    public func buttonEvent(_ id: String) throws -> (name: String, context: JSONValue) {
        guard reachable().contains(id), let c = components[id] else { throw A2UIError(["\(id) 不在这张卡片上"]) }
        guard c["component"]?.string == "Button", let event = c["action"]?["event"], let name = event["name"]?.string else {
            throw A2UIError(["\(id) 不是按钮"])
        }
        return (name, event["context"] ?? .object([:]))
    }

    /// 按钮上的字和图标：子组件是 `Text`，或是一行 `Row`（里面一个 `Icon` 加一个 `Text`，工具协议 §4）。
    /// 字总是有（悬停提示、读屏、卡片外面另画的按钮都用它）；没有图标时 icon 是 nil。
    public func buttonLabel(_ id: String) -> (text: String, icon: String?) {
        var (text, icon) = rawButtonLabel(id)
        guard let n = buttonCount(id) else { return (text, icon) }
        // §4 countAlso：选了 also 里的值（以后别提、换成克隆）时换成 alsoLabel
        if buttonCountAlso(id), let also = components[id]?["count"]?["alsoLabel"]?.string { text = also }
        return (text.replacingOccurrences(of: "{n}", with: String(n)), icon)   // §4 countLabel：字里的 {n} 换成现在数出的项数
    }

    /// 按钮上的数（工具协议 §4 countLabel）：`count` 指的那组选择里，选了 `value` 的有几项；按钮没写 count 是 nil。
    /// §4 countWeights：写了 `weights` 的键按它算几样（不写算 1），`weights` 里有、选择里没有的键不管
    public func buttonCount(_ id: String) -> Int? {
        guard let count = components[id]?["count"]?.object, let p = count["path"]?.string, let v = count["value"]?.string else { return nil }
        guard let chosen = (try? data.value(at: p))?.object else { return 0 }
        let weights = count["weights"]?.object ?? [:]
        return chosen.filter { ($0.value.array ?? []).contains { $0.string == v } }
            .reduce(0) { n, kv in n + (weights[kv.key]?.number.flatMap { Int(exactly: min(max($0, 1), 1e9).rounded()) } ?? 1) }   // 大得离谱的数不让它溢出
    }

    /// §4 countAlso：`count` 那组选择里有没有哪一项选了 `also` 里的值（`luoke_agent/a2ui.py` 的 `count_also`）
    public func buttonCountAlso(_ id: String) -> Bool {
        guard let count = components[id]?["count"]?.object, let p = count["path"]?.string,
              let also = count["also"]?.array?.compactMap(\.string), !also.isEmpty,
              let chosen = (try? data.value(at: p))?.object else { return false }
        return chosen.values.contains { ($0.array ?? []).contains { $0.string.map(also.contains) ?? false } }
    }

    /// 按钮能不能点（只看 count）：没写 count、数出来不是 0、或者选了 also 里的值（§4 countLabel、countAlso）
    public func buttonCountAllows(_ id: String) -> Bool {
        guard let n = buttonCount(id) else { return true }
        return n > 0 || buttonCountAlso(id)
    }

    private func rawButtonLabel(_ id: String) -> (text: String, icon: String?) {
        guard let child = components[id]?["child"]?.string, let c = components[child] else { return ("", nil) }
        if c["component"]?.string == "Text" { return (c["text"]?.string ?? "", nil) }
        guard c["component"]?.string == "Row" else { return ("", nil) }
        var text = "", icon: String?
        for k in c["children"]?.array ?? [] {
            guard let kid = k.string, let x = components[kid] else { continue }
            switch x["component"]?.string {
            case "Text": if text.isEmpty { text = x["text"]?.string ?? "" }
            case "Icon": if icon == nil { icon = x["name"]?.string }
            default: break
            }
        }
        return (text, text.isEmpty ? nil : icon)   // 只有图标、没写字的不画成图标按钮：没有字可念
    }

    /// 和这个按钮在同一行的按钮有几个（连它自己）。只有图标的按钮要有带字的邻居才看得懂；一行里就它一个，照旧写字
    public func buttonsInRow(_ id: String) -> Int {
        for (_, c) in components where c["component"]?.string == "Row" {
            let kids = (c["children"]?.array ?? []).compactMap { $0.string }
            if kids.contains(id) { return kids.filter { components[$0]?["component"]?.string == "Button" }.count }
        }
        return 1
    }

    /// 这个组件是不是在某一行 `Row` 里
    public func inRow(_ id: String) -> Bool {
        components.values.contains { $0["component"]?.string == "Row" && ($0["children"]?.array ?? []).contains { $0.string == id } }
    }

    /// 按钮里面的组件（字、图标、那一行）：卡片的其余文字里不算它们
    public func buttonParts(_ id: String) -> [String] {
        guard let child = components[id]?["child"]?.string else { return [] }
        return [child] + (components[child]?["children"]?.array ?? []).compactMap { $0.string }
    }

    /// 这个按钮是不是打开网页的（`agent.open_url`）。
    public func opensURL(_ id: String) -> Bool {
        guard let c = components[id], c["component"]?.string == "Button" else { return false }
        return c["action"]?["event"]?["name"]?.string == "agent.open_url"
    }

    /// 打开网页的按钮去哪个网站：agent 核心写在按钮上的 `site`（punycode，工具协议 §5），界面画在按钮外面。
    /// 不是这种按钮、没写、是空的都是 nil（界面不让点）。
    public func openSite(_ id: String) -> String? {
        guard opensURL(id), let site = components[id]?["site"]?.string, !site.isEmpty else { return nil }
        return site
    }

    /// 用户点了按钮：动作名和按当前数据模型解析好的上下文（A2UI 的 action 消息里就送它）。
    /// 密码框（§4 secureField）只有上下文正好引用它时才在里面：引用它上面一层的页校验时就不认（`secureProblems`）
    public func action(_ id: String) throws -> (name: String, context: JSONValue) {
        let (name, ctx) = try buttonEvent(id)
        do {
            return (name, try ctx.resolved(in: data))
        } catch {
            throw A2UIError(["按钮 \(id) 的上下文取不到值"])
        }
    }

    /// 点这个按钮会交出去的密码框：上下文正好引用了的那几个（§4 secureField）。点完窗口只清这几个
    public func sentSecureFieldPaths(_ id: String) -> [String] {
        guard let (_, ctx) = try? buttonEvent(id) else { return [] }
        let exact = Set(ctx.bindingPaths)
        return secureFieldPaths.filter { exact.contains($0) }
    }

    /// 整张卡片现在的样子，作为一组新建消息。
    public func messages() -> [JSONValue] {
        var out: [JSONValue] = [.object(["version": .string(A2UI.version),
                                         "createSurface": .object(["surfaceId": .string(surfaceId), "catalogId": .string(catalogId)])])]
        if !components.isEmpty {
            out.append(.object(["version": .string(A2UI.version), "updateComponents": .object([
                "surfaceId": .string(surfaceId), "components": .array(components.keys.sorted().map { .object(components[$0]!) })])]))
        }
        out.append(.object(["version": .string(A2UI.version), "updateDataModel": .object([
            "surfaceId": .string(surfaceId), "path": .string("/"), "value": data])]))
        return out
    }

    // MARK: - 细节

    func childIds(_ c: [String: JSONValue], _ problems: inout [String], _ id: String) -> [String] {
        switch c["component"]?.string {
        case "Row", "Column", "List":
            if c["children"]?.object != nil { problems.append("组件 \(id)：children 不支持模板，写成编号数组"); return [] }
            guard let arr = c["children"]?.array, arr.allSatisfy({ $0.string != nil }) else {
                problems.append("组件 \(id)：children 要是编号数组"); return []
            }
            return arr.compactMap { $0.string }
        case "Card", "Button":
            guard let child = c["child"]?.string else { problems.append("组件 \(id)：child 要是一个编号"); return [] }
            return [child]
        default:
            return []
        }
    }

    func cycles(_ ids: Set<String>) -> [String] {
        var found: [String] = []
        var state: [String: Int] = [:]
        func walk(_ id: String) {
            state[id] = 1
            var ignore: [String] = []
            for child in childIds(components[id]!, &ignore, id) where ids.contains(child) {
                if state[child] == 1 { found.append("组件 \(id) 和 \(child) 之间有环") }
                else if state[child] == nil { walk(child) }
            }
            state[id] = 2
        }
        for id in ids.sorted() where state[id] == nil { walk(id) }
        return found
    }

    func checkTextLengths(_ v: JSONValue, _ problems: inout [String]) {
        switch v {
        case .string(let s): if s.count > A2UI.maxText { problems.append("数据模型里有超过 \(A2UI.maxText) 字的文字") }
        case .array(let a): a.forEach { checkTextLengths($0, &problems) }
        case .object(let o): o.values.forEach { checkTextLengths($0, &problems) }
        default: break
        }
    }

    func bound(_ v: JSONValue?, _ id: String, _ problems: inout [String]) -> Bool {
        guard let p = v?.bindingPath else { return false }
        if (try? data.value(at: p)) == nil { problems.append("组件 \(id) 绑定的 \(p) 在数据模型里没有") }
        return true
    }

    func checkText(_ name: String, required: Bool, _ id: String, _ type: String, _ c: [String: JSONValue], _ problems: inout [String]) {
        guard let v = c[name] else {
            if required { problems.append("组件 \(id)（\(type)）缺 \(name)") }
            return
        }
        if bound(v, id, &problems) { return }
        guard let s = v.string else { problems.append("组件 \(id)：\(name) 要是文字或 {\"path\"}"); return }
        if s.count > A2UI.maxText { problems.append("组件 \(id)：\(name) 超过 \(A2UI.maxText) 字") }
    }

    /// `agent.open_page` 的上下文：`page`（这个应用自己的页 id），可以带 `args`（§4 pageArgs）
    func checkOpenPage(_ id: String, _ ctx: JSONValue, _ problems: inout [String]) {
        let keys = Set(ctx.object.map { Array($0.keys) } ?? [])
        guard keys.contains("page"), keys.isSubset(of: ["page", "args"]), A2UI.pageIDAcceptable(ctx["page"]?.string ?? "") else {
            problems.append("按钮 \(id)：agent.open_page 只开这个应用自己的页，context 只写 page（页 id，不带应用名）和 args"); return
        }
        guard let args = ctx["args"] else { return }
        guard let o = args.object, o.count <= A2UI.maxPageArgs else {
            problems.append("按钮 \(id)：agent.open_page 的 args 要是对象，最多 \(A2UI.maxPageArgs) 个"); return
        }
        for (k, v) in o.sorted(by: { $0.key < $1.key }) {
            if !A2UI.pageArgKeyAcceptable(k) {
                problems.append("按钮 \(id)：agent.open_page 的 args 的键要是小写字母开头的短名字")
            } else if v.bindingPath == nil, !(v.string.map { $0.unicodeScalars.count <= A2UI.maxPageArg } ?? false) {
                problems.append("按钮 \(id)：agent.open_page 的 args 的 \(k) 要是不超过 \(A2UI.maxPageArg) 字的文字或 {\"path\"}")
            }
        }
    }

    /// 按钮的 count（§4 countLabel）：`{"path": 一组选择, "value": 数哪个}`，path 指向「键 → 选了的值的数组」
    func checkCount(_ v: JSONValue, _ id: String, _ problems: inout [String]) {
        guard let o = v.object, Set(["path", "value"]).isSubset(of: o.keys),
              Set(o.keys).isSubset(of: ["path", "value", "also", "alsoLabel", "weights"]), let p = o["path"]?.string,
              let val = o["value"]?.string, !val.isEmpty else {
            problems.append("按钮 \(id)：count 要是 {\"path\", \"value\"}（数一组选择里选了 value 的项）"); return
        }
        // §4 countAlso：also（不空的一组值）和 alsoLabel（一句不空的文字）一起写
        if (o["also"] != nil) != (o["alsoLabel"] != nil) { problems.append("按钮 \(id)：count 的 also 和 alsoLabel 要一起写") }
        if let also = o["also"], !(also.array.map { !$0.isEmpty && $0.allSatisfy { !($0.string ?? "").isEmpty } } ?? false) {
            problems.append("按钮 \(id)：count.also 要是不空的一组值（文字）")
        }
        // §4 countWeights：选择的键 → 正整数
        if let w = o["weights"], !(w.object.map { $0.values.allSatisfy { $0.number.map { $0 == $0.rounded() && $0 >= 1 } ?? false } } ?? false) {
            problems.append("按钮 \(id)：count.weights 要是对象，每个键（选择的键）对一个正整数")
        }
        if let label = o["alsoLabel"] {
            if let s = label.string, !s.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                if s.count > A2UI.maxText { problems.append("按钮 \(id)：count.alsoLabel 超过 \(A2UI.maxText) 字") }
            } else {
                problems.append("按钮 \(id)：count.alsoLabel 要是一句不空的文字")
            }
        }
        guard let chosen = try? data.value(at: p) else { problems.append("按钮 \(id)：count 绑定的 \(p) 在数据模型里没有"); return }
        if chosen.object == nil { problems.append("按钮 \(id)：count 的 path 要指向一组选择（键 → 选了的值的数组）") }
    }

    /// 一个组件碰没碰密码框（§4 secureField）的路径。同 `luoke_agent/a2ui.py` 的 `_secure_problems`：
    /// 交给工具的按钮只能正好引用密码框的路径、不能引用它上面一层；`agent.` 开头的动作不能引用它、它上面或下面一层；
    /// 别的绑定（字、普通输入框、label、选择的值、按钮的 count……）不能是它或它上面一层。几个密码框绑同一个路径不算
    func secureProblems(_ id: String, _ c: [String: JSONValue], _ secure: [String]) -> [String] {
        var out: [String] = []
        let type = c["component"]?.string
        if type == "Button", let name = c["action"]?["event"]?["name"]?.string {
            for b in (c["action"]?["event"]?["context"] ?? .object([:])).bindingPaths {
                for p in secure {
                    if name.hasPrefix("agent.") {
                        if pointerCovers(b, p) || pointerCovers(p, b) { out.append("按钮 \(id)：\(name) 不能引用密码框的路径 \(p)") }
                    } else if b != p && pointerCovers(b, p) {
                        out.append("按钮 \(id)：上下文引用的 \(b) 里有密码框（\(p)），只能正好引用 \(p)")
                    }
                }
            }
        }
        var rest = c
        rest["action"] = nil
        if type == "TextField", c["variant"]?.string == "obscured" { rest["value"] = nil }
        var shown = JSONValue.object(rest).bindingPaths
        if type == "Button", let cp = c["count"]?["path"]?.string { shown.append(cp) }
        for b in shown {
            for p in secure where pointerCovers(b, p) { out.append("组件 \(id)：绑定的 \(b) 会把密码框（\(p)）里的字显示出来") }
        }
        return out
    }

    func checkBindings(_ v: JSONValue, _ id: String, _ problems: inout [String]) {
        if let p = v.bindingPath {
            if (try? data.value(at: p)) == nil { problems.append("按钮 \(id) 的上下文绑定的 \(p) 在数据模型里没有") }
            return
        }
        switch v {
        case .object(let o): o.values.forEach { checkBindings($0, id, &problems) }
        case .array(let a): a.forEach { checkBindings($0, id, &problems) }
        default: break
        }
    }

    func checkProps(_ id: String, _ type: String, _ c: [String: JSONValue], _ problems: inout [String]) {
        switch type {
        case "Text":
            checkText("text", required: true, id, type, c, &problems)
            if let v = c["variant"], !(v.string.map { A2UI.textVariants.contains($0) } ?? false) {
                problems.append("组件 \(id)：variant 只能是 " + A2UI.textVariants.sorted().joined(separator: "、"))
            }
            if let t = c["tone"], c["variant"]?.string != "badge" || !(t.string.map { A2UI.tones.contains($0) } ?? false) {
                problems.append("组件 \(id)：tone 只能写在 variant badge 上，只能是 " + A2UI.tones.sorted().joined(separator: "、"))
            }
            if let n = c["maxLines"], !(n.number.map { $0 == $0.rounded() && (1...20).contains($0) } ?? false) {
                problems.append("组件 \(id)：maxLines 要是 1 到 20 的整数")
            }
        case "Column":
            if let v = c["collapsed"] {
                if let s = v.string, !s.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    if s.count > A2UI.maxText { problems.append("组件 \(id)：collapsed 超过 \(A2UI.maxText) 字") }
                } else {
                    problems.append("组件 \(id)：collapsed 要是一句不空的文字（收起时显示的那一行）")
                }
            }
        case "Button":
            checkText("tooltip", required: false, id, type, c, &problems)
            guard let event = c["action"]?["event"], let name = event["name"]?.string, !name.isEmpty else {
                problems.append("按钮 \(id) 要有 action.event.name"); return
            }
            let ctx = event["context"] ?? .object([:])
            guard ctx.object != nil else { problems.append("按钮 \(id) 的 context 要是对象"); return }
            checkBindings(ctx, id, &problems)
            if name.hasPrefix("agent."), !A2UI.agentEvents.contains(name) {
                problems.append("按钮 \(id)：agent. 开头的动作只有 " + A2UI.agentEvents.sorted().joined(separator: "、"))
            }
            if name == "agent.open_url", c["variant"]?.string == "switch" {
                problems.append("按钮 \(id)：agent.open_url 不能画成开关：开关上看不到会去哪个网站")
            }
            if name == "agent.open_url", !A2UI.openURLAcceptable(ctx["url"]?.string ?? "") {
                problems.append("按钮 \(id)：agent.open_url 的 url 要是写死的 https 地址（不带反斜杠、空白、控制字符、userinfo，主机不空）")
            }
            if name == "agent.open_page" {
                checkOpenPage(id, ctx, &problems)
                if c["variant"]?.string == "switch" { problems.append("按钮 \(id)：agent.open_page 不能画成开关") }
            }
            if let count = c["count"] { checkCount(count, id, &problems) }
        case "ProgressBar":
            if !(c["value"]?.number.map { (0...1).contains($0) } ?? false) {
                problems.append("组件 \(id)：value 要是 0 到 1 的数")
            }
        case "CheckBox":
            checkText("label", required: true, id, type, c, &problems)
            if !bound(c["value"], id, &problems), c["value"]?.bool == nil {
                problems.append("组件 \(id)：value 要是真假或 {\"path\"}")
            }
        case "ChoicePicker":
            checkText("label", required: false, id, type, c, &problems)
            var values: [String] = []
            if let opts = c["options"]?.array, !opts.isEmpty {
                for o in opts {
                    guard let v = o["value"]?.string else { problems.append("组件 \(id)：每个选项要有字符串的 value"); continue }
                    values.append(v)
                    if !bound(o["label"], id, &problems), o["label"]?.string == nil { problems.append("组件 \(id)：每个选项要有 label") }
                    if let i = o["icon"], !(i.string.map { A2UI.icons.contains($0) } ?? false) {
                        problems.append("组件 \(id)：选项的图标名只能是 " + A2UI.icons.sorted().joined(separator: "、"))
                    }
                }
            } else {
                problems.append("组件 \(id)：options 要是非空数组")
            }
            if let p = c["value"]?.bindingPath {
                if let cur = try? data.value(at: p) {
                    if let arr = cur.array, arr.allSatisfy({ $0.string != nil }) {
                        if !values.isEmpty, arr.contains(where: { !values.contains($0.string!) }) {
                            problems.append("组件 \(id)：当前值不在选项里")
                        }
                    } else {
                        problems.append("组件 \(id)：ChoicePicker 的值要是字符串数组（单选也一样）")
                    }
                } else {
                    problems.append("组件 \(id) 绑定的 \(p) 在数据模型里没有")
                }
            } else if !(c["value"]?.array?.allSatisfy({ $0.string != nil }) ?? false) {
                problems.append("组件 \(id)：ChoicePicker 的值要是字符串数组（单选也一样）或 {\"path\"}")
            }
        case "TextField":
            checkText("label", required: true, id, type, c, &problems)
            checkText("value", required: false, id, type, c, &problems)
            if c["variant"]?.string == "obscured" {     // 密码框（§4 secureField）：只在页上，绑定数据模型，工具给的值只能是空的
                if !page {
                    problems.append("组件 \(id)：密码框（variant obscured）只能用在应用页上")
                } else if let p = c["value"]?.bindingPath {
                    if let cur = try? data.value(at: p), cur != .string("") { problems.append("组件 \(id)：密码框的初值只能是空字符串") }
                } else {
                    problems.append("组件 \(id)：密码框的 value 要绑定数据模型（{\"path\"}）")
                }
            }
        case "DateTimeInput":
            checkText("value", required: true, id, type, c, &problems)
        case "Slider":
            for k in ["min", "max"] where c[k] != nil && c[k]?.number == nil { problems.append("组件 \(id)：\(k) 要是数") }
            if !bound(c["value"], id, &problems), c["value"]?.number == nil {
                problems.append("组件 \(id)：value 要是数或 {\"path\"}")
            }
            checkText("label", required: false, id, type, c, &problems)
        case "Icon":
            if !(c["name"]?.string.map { A2UI.icons.contains($0) } ?? false) {
                problems.append("组件 \(id)：图标名只能是 " + A2UI.icons.sorted().joined(separator: "、"))
            }
        default:
            break
        }
    }
}

/// 给命令行和测试：没问题返回 []。
public func validate(_ messages: [JSONValue], catalog: String = Catalog.agent, page: Bool = false) -> [String] {
    do {
        _ = try Surface.build(messages, catalog: catalog, page: page)
        return []
    } catch let e as A2UIError {
        return e.problems
    } catch {
        return ["\(error)"]
    }
}

/// 应用页分段画时的一样（工具协议 §4 pageSections）
public enum PageBlock: Equatable {
    /// 不画卡片的（页头那一行：标题、「上次查 …」、主按钮）
    case bare(String)
    /// 一排几个数（`spaceEvenly` 的 `Row`）：每一格一张小卡片
    case tiles([String])
    /// 一段一张卡片：有小标题时画在卡片外面，卡片里从第 `skip` 个子组件起
    case card(String, title: SectionTitle?, skip: Int)
}

/// 一段的小标题：图标、字、数（字和数可能绑着数据模型，由画的人取）
public struct SectionTitle: Equatable {
    public let icon: String?
    public let text: JSONValue
    public let count: JSONValue?
}
