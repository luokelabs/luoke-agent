import Foundation

/// 一个 JSON 值。A2UI 的组件和数据模型都用它表示。
public enum JSONValue: Equatable, Hashable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])

    public static func parse(_ data: Data) throws -> JSONValue {
        try JSONDecoder().decode(JSONValue.self, from: data)
    }

    public static func parse(_ text: String) throws -> JSONValue {
        try parse(Data(text.utf8))
    }

    public func serialized() -> Data {
        let enc = JSONEncoder()
        enc.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return (try? enc.encode(self)) ?? Data("null".utf8)
    }

    public var string: String? { if case .string(let s) = self { return s }; return nil }
    public var bool: Bool? { if case .bool(let b) = self { return b }; return nil }
    public var number: Double? { if case .number(let n) = self { return n }; return nil }
    public var array: [JSONValue]? { if case .array(let a) = self { return a }; return nil }
    public var object: [String: JSONValue]? { if case .object(let o) = self { return o }; return nil }

    public subscript(key: String) -> JSONValue? { object?[key] }

    /// `{"path": "/…"}`：A2UI 的绑定。
    public var bindingPath: String? {
        if let o = object, o.count == 1, let p = o["path"]?.string { return p }
        return nil
    }

    /// 里面所有绑定的路径（按钮上下文用）。同 `luoke_agent/a2ui.py` 的 `bindings`
    public var bindingPaths: [String] {
        if let p = bindingPath { return [p] }
        switch self {
        case .object(let o): return o.values.flatMap { $0.bindingPaths }
        case .array(let a): return a.flatMap { $0.bindingPaths }
        default: return []
        }
    }
}

extension JSONValue: Codable {
    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null }
        else if let b = try? c.decode(Bool.self) { self = .bool(b) }
        else if let n = try? c.decode(Double.self) { self = .number(n) }
        else if let s = try? c.decode(String.self) { self = .string(s) }
        else if let a = try? c.decode([JSONValue].self) { self = .array(a) }
        else { self = .object(try c.decode([String: JSONValue].self)) }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .null: try c.encodeNil()
        case .bool(let b): try c.encode(b)
        case .number(let n): try c.encode(n)
        case .string(let s): try c.encode(s)
        case .array(let a): try c.encode(a)
        case .object(let o): try c.encode(o)
        }
    }
}

// MARK: - JSON 指针

public struct PathError: Error, CustomStringConvertible {
    public let path: String
    public var description: String { "取不到 \(path)" }
}

func pointerTokens(_ path: String) throws -> [String] {
    if path == "/" || path.isEmpty { return [] }
    guard path.hasPrefix("/") else { throw PathError(path: path) }
    return path.dropFirst().split(separator: "/", omittingEmptySubsequences: false).map {
        $0.replacingOccurrences(of: "~1", with: "/").replacingOccurrences(of: "~0", with: "~")
    }
}

/// 数组下标照 RFC 6901：`0`，或者不以 0 开头的 ASCII 数字，还要在数组里。别的写法（`00`、`+0`、`-0`）取不到：不然 `/l/00`
/// 取到的是 `/l/0`，密码框的路径按段比（`pointerCovers`）就拦不住它。同 `luoke_agent/a2ui.py` 的 `_index`
func pointerIndex(_ t: String, count: Int) -> Int? {
    // 位数比数组长度的位数多的一定越界，先拦下（同 Python 的 `_index`；`Int(t)` 溢出时本来也是 nil，不会崩）
    guard !t.isEmpty, t.utf8.allSatisfy({ $0 >= 0x30 && $0 <= 0x39 }), t == "0" || t.utf8.first != 0x30,
          t.utf8.count <= String(count).utf8.count, let i = Int(t), i < count else { return nil }
    return i
}

/// `outer` 取到的值里有没有 `inner`：同一个路径，或者是它上面的一层（按段比）。同 `luoke_agent/a2ui.py` 的 `_covers`
func pointerCovers(_ outer: String, _ inner: String) -> Bool {
    guard let a = try? pointerTokens(outer), let b = try? pointerTokens(inner) else { return false }
    return b.count >= a.count && Array(b.prefix(a.count)) == a
}

public extension JSONValue {
    /// 按 JSON 指针取值，取不到抛 PathError。
    func value(at path: String) throws -> JSONValue {
        var cur = self
        for t in try pointerTokens(path) {
            switch cur {
            case .object(let o):
                guard let v = o[t] else { throw PathError(path: path) }
                cur = v
            case .array(let a):
                guard let i = pointerIndex(t, count: a.count) else { throw PathError(path: path) }
                cur = a[i]
            default:
                throw PathError(path: path)
            }
        }
        return cur
    }

    /// 改过的副本（`path` 是 `/` 时整份换掉）。中间缺的对象自动补上；`value` 为 nil 是删掉。
    func setting(_ path: String, to value: JSONValue?) throws -> JSONValue {
        let toks = try pointerTokens(path)
        if toks.isEmpty {
            guard let v = value else { return .object([:]) }
            guard case .object = v else { throw PathError(path: path) }
            return v
        }
        return try JSONValue.set(self, toks[...], value, path)
    }

    private static func set(_ node: JSONValue, _ toks: ArraySlice<String>, _ value: JSONValue?, _ path: String) throws -> JSONValue {
        let head = toks.first!
        let rest = toks.dropFirst()
        switch node {
        case .array(var a):
            guard let i = pointerIndex(head, count: a.count) else { throw PathError(path: path) }
            if rest.isEmpty {
                if let v = value { a[i] = v } else { a.remove(at: i) }
            } else {
                a[i] = try set(a[i], rest, value, path)
            }
            return .array(a)
        case .object(var o):
            if rest.isEmpty {
                o[head] = value
            } else {
                o[head] = try set(o[head] ?? .object([:]), rest, value, path)
            }
            return .object(o)
        default:
            throw PathError(path: path)
        }
    }

    /// 把 `{"path": …}` 换成数据模型里的值（按钮上下文用）。
    func resolved(in data: JSONValue) throws -> JSONValue {
        if let p = bindingPath { return try data.value(at: p) }
        switch self {
        case .object(let o): return .object(try o.mapValues { try $0.resolved(in: data) })
        case .array(let a): return .array(try a.map { try $0.resolved(in: data) })
        default: return self
        }
    }
}
