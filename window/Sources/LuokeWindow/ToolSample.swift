import Foundation
import LuokeA2UICore

/// 工具的一个场景接上真核心以后，核心交给窗口的东西：工具录的真实答复（fixtures/<工具>/<场景>/）经
/// `scripts/window_samples.py` 跑过真核心，存在 Resources/samples/<工具>/<场景>.json。
/// 「接上核心」的截图和测试里，这个工具的部分从这里来，不手写；工具改了答复，重新拷样例、重新生成，这里跟着变。
public struct ToolSample {
    public let app: String
    public let scenario: String
    /// 场景的一句话（工具写的）
    public let title: String
    /// 工具的版本（配件清单的 `version`）
    public let version: String
    /// `/feed` 先给的那一串：（事件，内容）
    public let events: [(String, Data)]
    /// 这一刻 `GET /apps` 答的应用
    public let apps: [JSONValue]
    /// `GET /apps/<id>/pages/<页>` 的答复（`{"messages": [...]}`）
    public let pages: [String: JSONValue]
    /// `GET /permissions` 的行
    public let permissions: [JSONValue]
    /// 用户点了卡片上的按钮、工具答复的卡片（样例里的 call-*.json）：（文件名，窗口里的卡片 id，A2UI 消息，答复的那句话）
    public var replies: [(file: String, surface: String, card: [JSONValue], text: String)] = []
    /// 螺壳.app 报的、在螺壳名下的权限（`POST /host`）
    public let host: [String: String]

    /// 截图、测试默认用的扫描场景：第一次扫描、还没给完全磁盘访问（新用户最先看到的）
    public static let defaultScan = "first-run-no-fda"
    /// 截图、测试默认用的邮件助手场景
    public static var defaultMail: String { local.scenario ?? "suspicious" }
    /// 用了一阵的开发机：一轮查出一长串（一张很长的卡片）。截图里「螺壳.app 现在的样子」默认用它，和真机上常见的一样
    public static var fullScan: String { local.scenario ?? "full-report" }

    /// 本机录的一轮（只在本机看，不进仓库）：`LUOKE_WINDOW_SAMPLES=<目录>` 先从 `<目录>/<工具>/<场景>.json` 找，
    /// `LUOKE_WINDOW_SCENARIO=<场景>` 让截图默认用那个场景（邮件、扫描一样）
    static var local: (dir: String?, scenario: String?) {
        let env = ProcessInfo.processInfo.environment
        return (env["LUOKE_WINDOW_SAMPLES"].flatMap { $0.isEmpty ? nil : $0 }, env["LUOKE_WINDOW_SCENARIO"].flatMap { $0.isEmpty ? nil : $0 })
    }

    private static func dir(_ app: String) -> String { "Resources/samples/\(app)" }

    /// 这个工具有哪些场景（文件名，排好序）
    public static func scenarios(_ app: String) -> [String] {
        (ResourceBundle.bundle?.urls(forResourcesWithExtension: "json", subdirectory: dir(app)) ?? [])
            .map { $0.deletingPathExtension().lastPathComponent }.sorted()
    }

    /// 截图用：读样例时把这些字换掉（看超长文件名的样子）。只在画一张图的那一下设，画完清空
    @MainActor static var renames: [(String, String)] = []

    @MainActor public static func load(_ app: String, _ scenario: String) -> ToolSample? {
        let mine = local.dir.map { URL(fileURLWithPath: $0).appendingPathComponent(app).appendingPathComponent(scenario + ".json") }
        guard let url = mine.flatMap({ FileManager.default.fileExists(atPath: $0.path) ? $0 : nil })
                ?? ResourceBundle.bundle?.url(forResource: scenario, withExtension: "json", subdirectory: dir(app)),
              var data = try? Data(contentsOf: url) else { return nil }
        if !renames.isEmpty, var text = String(data: data, encoding: .utf8) {
            for (a, b) in renames { text = text.replacingOccurrences(of: a, with: b) }
            data = Data(text.utf8)
        }
        guard let v = try? JSONValue.parse(data) else { return nil }
        let events: [(String, Data)] = (v["events"]?.array ?? []).compactMap { e in
            guard let pair = e.array, pair.count == 2, let name = pair[0].string else { return nil }
            return (name, pair[1].serialized())
        }
        var host: [String: String] = [:]
        for (k, s) in v["host"]?.object ?? [:] { if let s = s.string { host[k] = s } }
        var sample = ToolSample(app: app, scenario: scenario, title: v["title"]?.string ?? scenario, version: v["version"]?.string ?? "", events: events,
                                apps: v["apps"]?["apps"]?.array ?? [], pages: v["pages"]?.object ?? [:],
                                permissions: v["permissions"]?["rows"]?.array ?? [], host: host)
        sample.replies = (v["replies"]?.array ?? []).compactMap { r in
            guard let f = r["file"]?.string, let sid = r["surface"]?.string, let card = r["card"]?.array else { return nil }
            return (f, sid, card, r["text"]?.string ?? "")
        }
        return sample
    }

    /// `/feed` 先给的 A2UI 消息
    public var surfaces: [(String, Data)] { events.filter { $0.0 == "a2ui" } }

    /// 这个应用的页（`GET /apps` 里它的 `pages`）
    public var pageIDs: [String] { (apps.first?["pages"]?.array ?? []).compactMap { $0["id"]?.string } }

    /// 把这个工具的卡片并进另一份 `feed`（示例里别的应用的）：卡片、顺序、要你处理的件数、提示接在后面
    public func merged(into feed: JSONValue) -> JSONValue {
        guard var out = feed.object,
              let mine = events.last(where: { $0.0 == "feed" }).flatMap({ try? JSONValue.parse($0.1) }) else { return feed }
        for key in ["order", "cards", "notices"] {
            out[key] = .array((out[key]?.array ?? []) + (mine[key]?.array ?? []))
        }
        out["open"] = .number((out["open"]?.number ?? 0) + (mine["open"]?.number ?? 0))
        return .object(out)
    }

    /// 这个场景里窗口该先看的一页：「清理记录」上能放回的时候看它，不然看第一页
    public var interestingPage: String? {
        let ids = (apps.first?["pages"]?.array ?? []).compactMap { $0["id"]?.string }
        let restorable = ids.first { id in
            (pages[id]?["messages"]?.array ?? []).contains { m in
                (m["updateComponents"]?["components"]?.array ?? []).contains { $0["component"]?.string == "Button" &&
                    $0["action"]?["event"]?["name"]?.string?.hasSuffix("_restore") == true }
            }
        }
        return restorable ?? ids.first
    }
}
