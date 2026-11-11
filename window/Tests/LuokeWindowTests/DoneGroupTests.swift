import Foundation
import LuokeA2UICore
import XCTest
@testable import LuokeWindow

/// 「已经替你做了」按工具给的分组合成一行（工具协议 §4 `doneGroup`）
@MainActor
final class DoneGroupTests: XCTestCase {
    private func row(_ id: String, _ key: String?, n: Int = 1, text: String = "x") -> DoneRow {
        let g = key.map { DoneGroup(key: $0, text: "已移到垃圾邮件 {n} 封", n: n, label: "可疑邮件", badge: "a@b.example") }
        return DoneRow(id: id, tool: .mail, text: text, time: "09:00", undoLabel: nil, group: g)
    }

    func testSameKeyMergesAndAddsUp() {
        let rows = DoneRow.merged([row("a", "box/spam", n: 2), row("b", nil, text: "清了缓存"), row("c", "box/spam", n: 3)])
        XCTAssertEqual(rows.map(\.id), ["a", "b"], "合成的一行用第一张的编号，排在第一张的位置")
        XCTAssertEqual(rows[0].text, "可疑邮件 · 已移到垃圾邮件 5 封")
        XCTAssertEqual(rows[0].members.map(\.id), ["a", "c"])
        XCTAssertEqual(rows[1].text, "清了缓存", "没分组的照旧")
        XCTAssertTrue(rows[1].members.isEmpty)
    }

    func testSingleGroupedRowUsesTheGroupWording() {
        let rows = DoneRow.merged([row("a", "box/spam")])
        XCTAssertEqual(rows.map(\.text), ["可疑邮件 · 已移到垃圾邮件 1 封"])
    }

    func testGroupComesFromTheCardRoot() throws {
        let msgs = try JSONValue.parse(Data(#"""
        [{"version": "v0.9", "createSurface": {"surfaceId": "s", "catalogId": "ai.luoke/a2ui/agent/1"}},
         {"version": "v0.9", "updateComponents": {"surfaceId": "s", "components": [
           {"id": "root", "component": "Column", "children": ["t"],
            "group": {"key": "box/spam", "label": "可疑邮件", "text": "已移到垃圾邮件 {n} 封", "n": 2, "badge": "a@b.example"}},
           {"id": "t", "component": "Text", "text": "已移到垃圾邮件 2 封"}]}}]
        """#.utf8))
        let s = try Surface.build(try XCTUnwrap(msgs.array))
        let g = try XCTUnwrap(s.doneGroup)
        XCTAssertEqual(g.key, "box/spam")
        XCTAssertEqual(g.n, 2)
        XCTAssertEqual(g.badge, "a@b.example")
    }

    func testTemplateMergesTheTwoSpamCards() {
        let m = Sample.model()
        TemplateSample.apply(m)
        let rows = DoneRow.merged(m.done)
        XCTAssertEqual(rows.count, 2, "三张做完的卡片，两张是同一个邮箱的可疑邮件")
        XCTAssertEqual(rows.first?.text, "可疑邮件 · 已移到垃圾邮件 2 封")
        XCTAssertEqual(rows.first?.members.count, 2)
    }
}
