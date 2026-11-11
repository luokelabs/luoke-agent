import XCTest
@testable import LuokeWindow

/// #51：菜单栏里点一行急事，「今天」展开那一叠（收在「还有 N 件急事」后面的先全展开）再滚过去；
/// 侧栏「今天」只数要你决定的、急事另一个红点；简报列前 3 件加「等」、最多两行
@MainActor
final class UrgentJumpTests: XCTestCase {
    private func row(_ m: WindowModel, _ match: (MenuItemSpec) -> Bool) throws -> MenuItemSpec {
        try XCTUnwrap(m.statusMenu.items.first(where: match))
    }

    func testMenuRowOpensItsStack() throws {
        let m = CompactUrgentTests.replay()
        m.go(.prefs)
        let mail = try XCTUnwrap(m.urgent.first { $0.tool == .mail && $0.surface != nil })
        m.perform(try row(m) { $0.title == "200 封可疑邮件" }.action)
        XCTAssertEqual(m.page, .today, "回「今天」")
        XCTAssertTrue(m.urgentOpenStacks.contains(TodayStack.key(mail.tool, mail.kind, mail.title)), "那一叠展开")
        XCTAssertFalse(m.urgentAll, "这一叠露在前 3 行里：不用把急事全展开")
        XCTAssertEqual(m.urgentJump?.id, mail.id, "滚到这一叠（第一件）")
        let first = m.urgentJump
        m.perform(try row(m) { $0.title == "200 封可疑邮件" }.action)
        XCTAssertNotEqual(m.urgentJump, first, "同一行再点一次也滚")
    }

    func testMenuRowBehindMoreExpandsAllUrgentFirst() throws {
        let m = CompactUrgentTests.replay()
        XCTAssertFalse(TodayPage.visibleUrgent(m.urgent, all: false).stacks.contains { $0.contains { $0.id == "x-login" } },
                       "「有人在新设备上登录」收在「还有 N 件急事」后面")
        m.perform(try row(m) { $0.id == "urgent-x-login" }.action)
        XCTAssertTrue(m.urgentAll, "先把急事全展开")
        XCTAssertEqual(m.urgentJump?.id, "x-login")
        XCTAssertTrue(TodayPage.visibleUrgent(m.urgent, all: m.urgentAll).stacks.contains { $0.contains { $0.id == "x-login" } })
        XCTAssertTrue(TodayCompact.urgentRows(m.urgent, all: m.urgentAll).stacks.contains { $0.contains { $0.id == "x-login" } },
                      "紧凑的表也一样")
    }

    func testMenuMoreRowGoesToTheFirstUnlistedStack() throws {
        let m = WindowModel()
        func u(_ id: String, _ kind: String, _ title: String) -> UrgentItem {
            UrgentItem(id: id, tool: .scan, title: title, time: "09:00", primary: "", primarySymbol: nil, secondary: "", kind: kind)
        }
        m.urgent = (0..<6).map { u("s\($0)", "k\($0)", "扫描的第 \($0) 件") }
        m.perform(try row(m) { $0.id == "urgent-more" }.action)
        XCTAssertEqual(m.urgentJump?.id, "s4", "菜单列了 4 行：滚到没列出的第一件")
        XCTAssertTrue(m.urgentAll)
    }

    func testSidebarTodayCountsOnlyDecisions() {
        let m = CompactUrgentTests.replay(decide: 40)
        XCTAssertEqual(m.urgent.count, StressSample.urgentReplay)
        XCTAssertEqual(m.todayCount, m.cards.count, "侧栏「今天」和「一件件处理」是同一个数")
        XCTAssertTrue(m.hasUrgent, "急事另外是红点")
    }

    /// 侧栏一行同一时间只有一个标记：有急事只画红点，没急事才画数
    func testSidebarShowsOneMarkAtATime() {
        XCTAssertEqual(SidebarMark.of(count: 3, urgent: true), .urgent)
        XCTAssertEqual(SidebarMark.of(count: 0, urgent: true), .urgent)
        XCTAssertEqual(SidebarMark.of(count: 3, urgent: false), .count(3))
        XCTAssertEqual(SidebarMark.of(count: 0, urgent: false), SidebarMark.none)
        XCTAssertEqual(SidebarMark.of(count: nil, urgent: false), SidebarMark.none)
    }

    func testBriefListsThreeThenEtcInTwoLines() throws {
        let m = CompactUrgentTests.replay(decide: 40)
        m.openBrief(time: "08:00")
        let note = try XCTUnwrap(m.briefNote)
        XCTAssertEqual(note.pending.count, 40)
        let text = BriefNoteView.text(note, open: Set(m.cards.map(\.id)), p: .light)
        let s = String(text.characters)
        XCTAssertLessThanOrEqual(BriefNoteView.lines(text), BriefNoteView.maxLines, s)
        XCTAssertTrue(s.contains("还有 \(note.pending.count) 件等你："), s)
        XCTAssertTrue(s.hasSuffix(" 等。"), s)
        let links = text.runs.compactMap { r in r.link.map { (String(text[r.range].characters), $0) } }
        XCTAssertEqual(links.last?.1, URL(string: "luoke-brief://decide"), "「等」跳到「要你决定」")
        XCTAssertEqual(links.last?.0, "等")
        let cards = links.dropLast().map(\.0)
        XCTAssertLessThanOrEqual(cards.count, BriefNoteView.pendingListed)
        XCTAssertEqual(Set(cards).count, cards.count, "一样的标题只列一次：\(cards)")
        for d in BriefNoteView.details {   // 哪一种写法都把「等」留着
            XCTAssertTrue(String(BriefNoteView.text(note, open: [], p: .light, detail: d).characters).hasSuffix(" 等。"))
        }
    }
}
