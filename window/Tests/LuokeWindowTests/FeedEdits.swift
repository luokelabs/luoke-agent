import Foundation
import LuokeA2UICore
@testable import LuokeWindow

/// 改核心发来的事件（测试里造「工具收走了一张卡片」这类）
enum FeedEdits {
    /// feed 里拿掉一张卡片（`cards` 里的那张、`order` 里的编号）
    static func removing(_ feed: JSONValue, _ id: String) -> JSONValue {
        guard var o = feed.object else { return feed }
        o["cards"] = .array((o["cards"]?.array ?? []).filter { $0["id"]?.string != id })
        o["order"] = .array((o["order"]?.array ?? []).filter { $0.string != id })
        return .object(o)
    }

    /// 最后一份 feed，改过以后的
    static func lastFeed(_ events: [(String, Data)], _ change: (JSONValue) -> JSONValue) -> Data {
        let feed = events.last { $0.0 == "feed" }.flatMap { try? JSONValue.parse($0.1) } ?? .null
        return change(feed).serialized()
    }
}
