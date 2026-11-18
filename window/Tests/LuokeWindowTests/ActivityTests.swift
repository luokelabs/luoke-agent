import Foundation
import LuokeA2UICore
import XCTest
@testable import LuokeWindow

/// 右边栏的「历史」接核心（docs/界面接口.md §5）：行照核心的列，按天分；撤销就是点卡片上的那个按钮。
@MainActor
final class ActivityTests: XCTestCase {
    final class Backend: WindowBackend {
        var actions: [String] = []
        var reloads = 0
        func action(surfaceId: String, componentId: String, context: JSONValue) { actions.append("\(surfaceId)#\(componentId)") }
        func updateSettings(_ patch: [String: JSONValue]) {}
        func reloadActivity() { reloads += 1 }
    }

    private func at(_ h: Int, _ m: Int, daysAgo: Int = 0) -> JSONValue {
        let day = Calendar.current.date(byAdding: .day, value: -daysAgo, to: Date())!
        return .string(AgentFeed.iso(Calendar.current.date(bySettingHour: h, minute: m, second: 0, of: day)!))
    }

    private func rows() -> JSONValue {
        .object(["more": .bool(false), "rows": .array([
            .object(["id": .string("luoke-scan/clean-3"), "app": .string("luoke-scan"), "kind": .string("auto-done"),
                     "time": at(9, 12), "text": .string("清掉 6.4 GB"), "outcome": .string("auto"),
                     "undo": .object(["surfaceId": .string("luoke-scan/clean-3"), "componentId": .string("res-b2"),
                                      "label": .string("放回")])]),
            .object(["id": .string("memory/ask-7"), "app": .string("memory"), "kind": .string("ask"),
                     "time": at(21, 4, daysAgo: 1), "text": .string("记下了：对。"), "outcome": .string("done")]),
            .object(["id": .string("bad"), "app": .string("x")]),       // 没有时间的不画
        ])])
    }

    func testRowsFromTheCore() {
        let m = WindowModel()
        AgentFeed(model: m).applyActivity(rows())
        XCTAssertEqual(m.activity.map(\.id), ["luoke-scan/clean-3", "memory/ask-7"])
        let a = m.activity[0], b = m.activity[1]
        XCTAssertEqual([a.day, a.time, b.day, b.time], ["今天", "09:12", "昨天", "21:04"])
        XCTAssertEqual([a.tool, b.tool], [.scan, .mem])
        XCTAssertEqual([a.auto, b.auto], [true, false], "工具自己做的标出来")
        XCTAssertEqual(a.undoLabel, "放回")
        XCTAssertNil(b.undoLabel, "卡片不在了：不能撤销")
        XCTAssertEqual(days(m.activity), ["今天", "昨天"])
    }

    func testUndoTapsTheCardButton() {
        let m = WindowModel()
        let be = Backend()
        m.backend = be
        AgentFeed(model: m).applyActivity(rows())
        m.undoActivity("luoke-scan/clean-3")
        XCTAssertEqual(be.actions, ["luoke-scan/clean-3#res-b2"])
        XCTAssertTrue(m.activity[0].undone)
        m.undoActivity("luoke-scan/clean-3")
        m.undoActivity("memory/ask-7")
        XCTAssertEqual(be.actions.count, 1, "撤销过的、没有撤销按钮的不再交给核心")
    }

    func testReloadsWhileLookingAtIt() {
        let m = WindowModel()
        let be = Backend()
        m.backend = be
        let f = AgentFeed(model: m)
        let feed = Data(#"{"order":[],"open":0,"notices":[],"cards":[]}"#.utf8)
        f.handle("feed", feed)
        XCTAssertEqual(be.reloads, 0, "没看着「历史」不取")
        m.openPanel(.tasks)
        XCTAssertEqual(be.reloads, 0, "右边栏在「任务」页签：不取")
        m.panelTab = .history
        XCTAssertEqual(be.reloads, 1, "换到「历史」时取一次")
        f.handle("feed", feed)
        XCTAssertEqual(be.reloads, 2, "看着的时候事情变了再取")
        m.closePanel()
        m.openPanel()
        XCTAssertEqual(be.reloads, 3, "收起再拉出来，还在「历史」：再取")
        m.closePanel()
        f.handle("feed", feed)
        XCTAssertEqual(be.reloads, 3, "收起了不取")
    }

    func testSampleStillActsAlone() {
        let m = Sample.model()
        m.undoActivity("a1")
        XCTAssertTrue(m.activity.first { $0.id == "a1" }?.undone ?? false)
    }
}
