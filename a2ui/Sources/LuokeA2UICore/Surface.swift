import Foundation

/// A2UI v0.9.1 的一张卡片（surface）：按组件目录校验、应用更新、取按钮的动作。
/// 规矩和 luoke-agent 的 `luoke_agent/a2ui.py` 一条一条对应，改一边要改另一边。
public enum A2UI {
    public static let version = "v0.9"
    public static let maxComponents = 200
    public static let maxText = 2000
    public static let messageKinds = ["createSurface", "updateComponents", "updateDataModel", "deleteSurface"]
    /// agent 自己处理的动作（工具协议 §5）
    public static let agentEvents: Set<String> = ["agent.open_url", "agent.dismiss", "agent.remind"]
    public static let icons: Set<String> = ["mail", "calendar", "warning", "check", "close", "trash", "archive", "star",
                                            "reply", "clock", "info", "person", "link", "memory", "question", "lightbulb"]
    public static let textVariants: Set<String> = ["h1", "h2", "h3", "h4", "h5", "body", "caption"]

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

    public init(surfaceId: String, catalogId: String) throws {
        guard Catalog.all[catalogId] != nil else { throw A2UIError(["不认识的组件目录：\(catalogId)"]) }
        self.surfaceId = surfaceId
        self.catalogId = catalogId
    }

    /// 一组新卡片的消息（第一条是 createSurface）→ 查过的卡片。
    public static func build(_ messages: [JSONValue], catalog: String = Catalog.agent) throws -> Surface {
        guard let first = messages.first else { throw A2UIError(["卡片要是非空的消息数组"]) }
        let (kind, body) = try unwrapMessage(first)
        guard kind == "createSurface" else { throw A2UIError(["第一条消息要是 createSurface"]) }
        guard let sid = body["surfaceId"]?.string, !sid.isEmpty else { throw A2UIError(["createSurface 要有 surfaceId"]) }
        guard body["catalogId"]?.string == catalog else { throw A2UIError(["catalogId 要是 \(catalog)"]) }
        var s = try Surface(surfaceId: sid, catalogId: catalog)
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
        if shown.count > A2UI.maxComponents { problems.append("组件超过 \(A2UI.maxComponents) 个") }
        if components.count > 5 * A2UI.maxComponents { problems.append("这张卡片累积的组件太多了，重新建一张") }
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
                let label = components[c["child"]?.string ?? ""]
                if label?["component"]?.string != "Text" || label?["text"]?.string == nil {
                    problems.append("按钮 \(id)：agent.open_url 按钮的子组件要是写死文字的 Text")
                }
            }
        }
        problems += cycles(Set(shown))
        checkTextLengths(data, &problems)
        return problems
    }

    /// 现在画着的按钮声明的动作：（动作名，没解析的上下文）。
    public func buttonEvent(_ id: String) throws -> (name: String, context: JSONValue) {
        guard reachable().contains(id), let c = components[id] else { throw A2UIError(["\(id) 不在这张卡片上"]) }
        guard c["component"]?.string == "Button", let event = c["action"]?["event"], let name = event["name"]?.string else {
            throw A2UIError(["\(id) 不是按钮"])
        }
        return (name, event["context"] ?? .object([:]))
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
    public func action(_ id: String) throws -> (name: String, context: JSONValue) {
        let (name, ctx) = try buttonEvent(id)
        do {
            return (name, try ctx.resolved(in: data))
        } catch {
            throw A2UIError(["按钮 \(id) 的上下文取不到值"])
        }
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
        case "Button":
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
                problems.append("按钮 \(id)：agent.open_url 不能画成开关，要去的网站得写在按钮外面")
            }
            if name == "agent.open_url", !A2UI.openURLAcceptable(ctx["url"]?.string ?? "") {
                problems.append("按钮 \(id)：agent.open_url 的 url 要是写死的 https 地址（不带反斜杠、空白、控制字符、userinfo，主机不空）")
            }
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
                    if o["label"]?.bindingPath == nil, o["label"]?.string == nil { problems.append("组件 \(id)：每个选项要有 label") }
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
public func validate(_ messages: [JSONValue], catalog: String = Catalog.agent) -> [String] {
    do {
        _ = try Surface.build(messages, catalog: catalog)
        return []
    } catch let e as A2UIError {
        return e.problems
    } catch {
        return ["\(error)"]
    }
}
