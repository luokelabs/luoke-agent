import Foundation
import LuokeA2UICore

/// 压力场景的数据：不另造卡片，把工具录的卡片（场景样例经真核心）复制几份，看条目很多时窗口的样子。
@MainActor
enum StressSample {
    /// `events` 里属于 `app` 的卡片（surface 和 `feed` 里的卡片、顺序）各复制成 `times` 份：
    /// 第 k 份（k ≥ 1）的 surface id、卡片 id 后面加 `~k`，内容不变
    static func scaled(_ events: [(String, Data)], app: String, times: Int) -> [(String, Data)] {
        let prefix = app + "/"
        let kinds = ["createSurface", "updateComponents", "updateDataModel", "deleteSurface"]
        func surfaceID(_ m: JSONValue) -> String? { kinds.lazy.compactMap { m[$0]?["surfaceId"]?.string }.first }
        func renamed(_ m: JSONValue, _ k: Int) -> JSONValue {
            guard var o = m.object else { return m }
            for kind in kinds {
                if var body = o[kind]?.object, let sid = body["surfaceId"]?.string {
                    body["surfaceId"] = .string("\(sid)~\(k)")
                    o[kind] = .object(body)
                }
            }
            return .object(o)
        }
        var out: [(String, Data)] = []
        for (name, data) in events {
            guard let v = try? JSONValue.parse(data) else { out.append((name, data)); continue }
            if name == "a2ui", surfaceID(v)?.hasPrefix(prefix) == true {
                out.append((name, data))
                for k in 1..<max(times, 1) { out.append((name, renamed(v, k).serialized())) }
            } else if name == "feed", var feed = v.object {
                let cards = feed["cards"]?.array ?? []
                let mine = cards.filter { $0["app"]?.string == app }
                var extra: [JSONValue] = []
                for k in 1..<max(times, 1) {
                    for c in mine {
                        guard var o = c.object, let id = o["id"]?.string else { continue }
                        o["id"] = .string("\(id)~\(k)")
                        extra.append(.object(o))
                    }
                }
                feed["cards"] = .array(cards + extra)
                feed["order"] = .array((feed["order"]?.array ?? []) + extra.compactMap { $0["id"] })
                let urgentOrDecide = extra.filter { ["urgent", "decide"].contains($0["section"]?.string ?? "") }.count
                feed["open"] = .number((feed["open"]?.number ?? 0) + Double(urgentOrDecide))
                out.append((name, JSONValue.object(feed).serialized()))
            } else {
                out.append((name, data))
            }
        }
        return out
    }
}
