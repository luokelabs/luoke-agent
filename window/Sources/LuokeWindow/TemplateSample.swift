import Foundation
import LuokeA2UICore

/// 「今天」新模板的示例（Resources/template/today.json）：scripts/today_template.py 用 luoke_agent/cards.py 照对照稿拼的卡片，
/// 一串 `/feed` 事件。截图 `today-template` 照它画，看窗口能不能把对照稿画出来。
enum TemplateSample {
    @MainActor static func apply(_ m: WindowModel) {
        guard let url = ResourceBundle.bundle?.url(forResource: "today", withExtension: "json", subdirectory: "Resources/template"),
              let data = try? Data(contentsOf: url), let v = try? JSONValue.parse(data) else { return }
        let feed = AgentFeed(model: m)
        for e in v["events"]?.array ?? [] {
            guard let pair = e.array, pair.count == 2, let name = pair[0].string else { continue }
            feed.handle(name, pair[1].serialized())
        }
    }
}
