import Foundation
import LuokeA2UICore
import XCTest
@testable import LuokeWindow

/// 一件件处理时工具换掉、收走卡片，照核心真发事件的顺序喂 `AgentFeed`：先删旧卡片（`deleteSurface`），
/// 再发新卡片的 a2ui，最后发 `feed`。只给 `m.cards` 赋值的测试（`BehaviourTests`）绕过了中间那几下
@MainActor
final class FocusReplaceTests: XCTestCase {
    final class FakeBackend: WindowBackend {
        var actions: [String] = []
        func action(surfaceId: String, componentId: String, context: JSONValue) { actions.append(surfaceId) }
        func updateSettings(_ patch: [String: JSONValue]) {}
    }

    private let mail = "luoke-mail/new-1"
    private var backend: FakeBackend!     // 窗口只弱引用它

    private func fed() -> (WindowModel, AgentFeed, [(String, Data)]) {
        let m = WindowModel()
        let f = AgentFeed(model: m)
        let events = Sample.agentEvents()
        for (e, d) in events { f.handle(e, d) }
        backend = FakeBackend()
        m.backend = backend      // 没接核心时示例自己演，点了就拿掉：这里要照核心来
        return (m, f, events)
    }

    // MARK: 造事件

    /// 把 JSON 里所有等于 `from` 的字符串换成 `to`（编号、标题都行）
    static func replacing(_ v: JSONValue, _ from: String, _ to: String) -> JSONValue {
        switch v {
        case .string(let s): return .string(s == from ? to : s)
        case .array(let a): return .array(a.map { replacing($0, from, to) })
        case .object(let o): return .object(o.mapValues { replacing($0, from, to) })
        default: return v
        }
    }

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

    private func delete(_ sid: String) -> (String, Data) {
        ("a2ui", JSONValue.object(["version": .string(A2UI.version), "deleteSurface": .object(["surfaceId": .string(sid)])]).serialized())
    }

    /// `sid` 那张卡片的 a2ui 消息，改过以后的（换编号、换标题）
    private func surfaceEvents(_ events: [(String, Data)], of sid: String, _ change: (JSONValue) -> JSONValue) -> [(String, Data)] {
        events.compactMap { e in
            guard e.0 == "a2ui", let m = try? JSONValue.parse(e.1),
                  A2UI.messageKinds.contains(where: { m[$0]?["surfaceId"]?.string == sid }) else { return nil }
            return ("a2ui", change(m).serialized())
        }
    }

    // MARK: 测试

    /// 换成新编号（邮件的方案重算时就会这样）：一直停在这一件，feed 到了摆新的那张，顶在原来的位置
    func testANewIdTakesTheSamePlaceThroughTheRealEventOrder() throws {
        let (m, f, events) = fed()
        m.enterFocus()
        let ids = try XCTUnwrap(m.focus?.ids)
        XCTAssertEqual(ids.first, mail)
        XCTAssertEqual(m.focusCurrent?.id, mail)
        let new = "luoke-mail/new-2"
        let steps = [delete(mail)]
            + surfaceEvents(events, of: mail) { Self.replacing($0, self.mail, new) }
            + [("feed", Self.lastFeed(events) { Self.replacing($0, self.mail, new) })]
        XCTAssertGreaterThan(steps.count, 3, "删、新卡片的几条、feed")
        for (i, (e, d)) in steps.enumerated() {
            f.handle(e, d)
            XCTAssertTrue([mail, new].contains(m.focusCurrent?.id ?? ""),
                          "第 \(i + 1) 条（\(e)）以后还在这一件，摆的是 \(m.focusCurrent?.id ?? "空")")
        }
        XCTAssertEqual(m.focusCurrent?.id, new, "摆换上来的那张")
        XCTAssertEqual(m.focus?.ids, [new] + ids.dropFirst(), "新的顶在原来的位置，别的不动")
        XCTAssertEqual(m.focusAnswered, 0, "用户没点，不算答了")
        XCTAssertFalse(m.cards.contains { $0.id == mail })
    }

    /// 同编号换内容（工具改了卡片）：一直停在这一件，feed 到了换成新内容
    func testTheSameIdWithNewContentStaysPut() throws {
        let (m, f, events) = fed()
        m.enterFocus()
        let ids = try XCTUnwrap(m.focus?.ids)
        let before = try XCTUnwrap(m.focusCurrent)
        XCTAssertEqual(before.id, mail)
        XCTAssertEqual(SurfaceDigest(before.surface.surface).title, "4 封新邮件")
        let steps = [delete(mail)]
            + surfaceEvents(events, of: mail) { Self.replacing($0, "4 封新邮件", "5 封新邮件") }
            + [("feed", Self.lastFeed(events) { Self.replacing($0, "4 封新邮件", "5 封新邮件") })]
        for (i, (e, d)) in steps.enumerated() {
            f.handle(e, d)
            XCTAssertEqual(m.focusCurrent?.id, mail, "第 \(i + 1) 条（\(e)）以后还在这一件")
            if e == "a2ui" {
                XCTAssertEqual(SurfaceDigest(try XCTUnwrap(m.focusCurrent).surface.surface).title, "4 封新邮件",
                               "feed 到之前摆的还是原来那张，不露出没画完的新卡片")
            }
        }
        let after = try XCTUnwrap(m.focusCurrent)
        XCTAssertFalse(after.surface === before.surface, "feed 到了换成新的那张")
        XCTAssertEqual(SurfaceDigest(after.surface.surface).title, "5 封新邮件")
        XCTAssertEqual(m.focus?.ids, ids, "这一轮不变")
        XCTAssertEqual(m.focusAnswered, 0, "用户没点，不算答了")
    }

    /// 工具收走（下一份 feed 里没有，也没有同一个应用新出的）：从这一轮里去掉，摆下一件，不算答了
    func testATakenBackCardLeavesTheRound() throws {
        let (m, f, events) = fed()
        m.enterFocus()
        let ids = try XCTUnwrap(m.focus?.ids)
        XCTAssertEqual(m.focusCurrent?.id, mail)
        f.handle(delete(mail).0, delete(mail).1)
        f.handle("feed", Self.lastFeed(events) { Self.removing($0, self.mail) })
        XCTAssertEqual(m.focus?.ids, Array(ids.dropFirst()), "收走的从这一轮里去掉")
        XCTAssertEqual(m.focusCurrent?.id, ids[1], "摆下一件")
        XCTAssertEqual(m.focusAnswered, 0, "用户没点：工具收走的不算答了")
    }

    /// 点过以后核心收走：算答了；接着摆下一件
    func testATappedCardTheCoreRemovesCountsAsAnswered() throws {
        let (m, f, events) = fed()
        m.enterFocus()
        let ids = try XCTUnwrap(m.focus?.ids)
        m.answerFocusPrimary()
        XCTAssertEqual(backend.actions, [mail], "点按交给核心")
        XCTAssertEqual(m.focusCurrent?.id, mail, "核心还没答：还摆着")
        f.handle(delete(mail).0, delete(mail).1)
        f.handle("feed", Self.lastFeed(events) { Self.removing($0, self.mail) })
        XCTAssertEqual(m.focusAnswered, 1, "点过、走掉了：算答了")
        XCTAssertEqual(m.focusCurrent?.id, ids[1])
    }
}
