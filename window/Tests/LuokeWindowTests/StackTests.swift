import XCTest
@testable import LuokeWindow

/// 相近的放一叠（`TodayStack`）、急事有上限（#51）、在准备时说在准备
@MainActor
final class StackTests: XCTestCase {
    /// 「急事 N」数件数：同一类 3 件放成一叠，段标题还是 3（和「要你决定」一样，#65）
    func testUrgentHeaderCountsItemsNotStacks() {
        let three = [urgent("m1"), urgent("m2"), urgent("m3")]
        XCTAssertEqual(TodayPage.visibleUrgent(three, all: false).stacks.count, 1, "同一类放成一叠")
        XCTAssertEqual(TodayPage.urgentCount(three), 3)
        XCTAssertEqual(TodayPage.urgentCount(three + [urgent("v1", kind: "virus", title: "病毒库认出一个文件")]), 4)
    }

    private func urgent(_ id: String, _ tool: ToolIcon = .mail, kind: String? = "suspicious", title: String = "一封可疑邮件（me@example.com）") -> UrgentItem {
        UrgentItem(id: id, tool: tool, title: title, time: "09:00", primary: "", primarySymbol: nil, secondary: "", kind: kind)
    }

    func testSameAppAndKindStackTogetherInOrder() {
        let items = [urgent("m1"), urgent("v1", .scan, kind: "security", title: "下载里有病毒"), urgent("m2"), urgent("m3")]
        let stacks = TodayStack.urgent(items)
        XCTAssertEqual(stacks.map { $0.map(\.id) }, [["m1", "m2", "m3"], ["v1"]], "照第一张出现的位置排，同类的收在一起")
    }

    func testNoKindSameTitleStacks() {
        let items = [urgent("a", kind: nil, title: "一封可疑邮件"), urgent("b", kind: nil, title: "一封可疑邮件"), urgent("c", kind: nil, title: "别的")]
        XCTAssertEqual(TodayStack.urgent(items).map(\.count), [2, 1])
    }

    func testTwoDoNotStackOnThePage() {
        let two = [urgent("m1"), urgent("v1", .scan, kind: "security", title: "下载里有病毒"), urgent("m2")]
        XCTAssertEqual(TodayPage.visibleUrgent(two, all: true).stacks.map { $0.map(\.id) }, [["m1"], ["m2"], ["v1"]],
                       "两张摞起来不省地方：摆开，同类的还挨着")
        let three = two + [urgent("m3")]
        XCTAssertEqual(TodayPage.visibleUrgent(three, all: true).stacks.map(\.count), [3, 1])
    }

    func testUrgentCapCountsStacks() {
        let many = (0..<40).map { urgent("m\($0)") }
        XCTAssertEqual(TodayPage.visibleUrgent(many, all: false).stacks.count, 1, "40 封可疑邮件是一叠")
        let kinds = (0..<5).map { urgent("k\($0)", .scan, kind: "kind\($0)", title: "第 \($0) 件") }
        let shown = TodayPage.visibleUrgent(kinds, all: false)
        XCTAssertEqual(shown.stacks.count, TodayPage.urgentLimit)
        XCTAssertEqual(shown.more, 5 - TodayPage.urgentLimit)
        XCTAssertEqual(TodayPage.visibleUrgent(kinds, all: true).more, 0)
    }

    func testStackTitleInMenu() {
        XCTAssertEqual(TodayStack.countTitle("一封可疑邮件（me@example.com）", 8), "8 封可疑邮件", "括号里是那一封的，合起来去掉")
        XCTAssertEqual(TodayStack.countTitle("下载里有病毒", 2), "2 件：下载里有病毒", "菜单截掉长字的尾巴：件数在前")
        XCTAssertEqual(TodayStack.countTitle("下载里的「eicar-test.com」可能是病毒", 2, unit: "样"), "下载里 2 样可能是病毒", "书名号里是那一个的名字：换成个数")
        XCTAssertEqual(TodayStack.countTitle("一封可疑邮件（me@example.com）", 1), "一封可疑邮件（me@example.com）")
    }

    func testStatusMenuStaysShort() {
        let m = WindowModel()
        m.urgent = (0..<40).map { urgent("m\($0)") } + (0..<6).map { urgent("s\($0)", .scan, kind: "k\($0)", title: "扫描的第 \($0) 件") }
        let rows = m.statusMenu.items.drop { $0.id != "h-urgent" }.dropFirst().prefix { $0.kind != .separator }
        XCTAssertLessThanOrEqual(rows.count, WindowModel.urgentMenuRows)
        XCTAssertEqual(rows.first?.title, "40 封可疑邮件")
        XCTAssertEqual(rows.last?.title, "还有 3 件急事…", "4 行（可疑邮件 1 行、扫描 3 行），剩下 3 件合成一行")
        XCTAssertTrue(m.statusMenu.items.contains { $0.id == "open" }, "「打开螺壳」还在")
    }

    func testWaitingLooksDifferentFromEmpty() throws {
        let screens = Snapshot.screens()
        let waiting = try XCTUnwrap(screens.first { $0.name == "stress-today-waiting" })
        let empty = try XCTUnwrap(screens.first { $0.name == "stress-today-empty" })
        XCTAssertNotEqual(Snapshot.png(waiting, dark: false, scale: 1), Snapshot.png(empty, dark: false, scale: 1),
                          "数据还没到时说在准备，不像什么都没有的第一天")
    }

    /// 一叠下面写清是什么：「还有 4 封可疑邮件」；写不出就是 nil（照旧「同类的」）
    func testStackSaysWhatIsUnderneath() {
        XCTAssertEqual(TodayStack.what("一封可疑邮件（me@example.com）", 4), "4 封可疑邮件")
        XCTAssertEqual(TodayStack.what("一封可疑邮件", 1), "1 封可疑邮件")
        XCTAssertNil(TodayStack.what("病毒库认出 eicar-test.com", 1))
        XCTAssertNil(TodayStack.what("一封可疑邮件", 0))
        XCTAssertEqual(TodayStack.what("可疑邮件：某银行：账户已冻结", 4, unit: "封"), "4 封可疑邮件")
        // 邮件助手 0.19.4x 起引这一封的标题：书名号里的冒号不当分隔
        XCTAssertEqual(TodayStack.what("可疑邮件「某银行：账户已冻结」", 4, unit: "封"), "4 封可疑邮件")
        XCTAssertEqual(TodayStack.what("1 封邮件要你处理", 3, unit: "封"), "3 封邮件要你处理")
    }

    // review #60 第 3、4、5 条

    private func card(_ id: String, kind: String = "suspicious", title: String = "可疑邮件：某银行：账户已冻结") -> TodayCard {
        let surface = Sample.model().cards[0].surface
        return TodayCard(id: id, tool: .mail, time: nil, surface: surface, title: title, kind: kind)
    }

    func testJumpOpensTheStackHidingTheCard() {
        let cards = [card("a"), card("b"), card("c"), card("x", kind: "plan", title: "这 1 封要你处理")]
        XCTAssertEqual(TodayPage.stackToOpen(for: "b", in: cards), "c:" + TodayStack.key(.mail, "suspicious", "可疑邮件：某银行：账户已冻结"),
                       "收在一叠里的：先展开那一叠")
        XCTAssertNil(TodayPage.stackToOpen(for: "a", in: cards), "露着的第一张不用展开")
        XCTAssertNil(TodayPage.stackToOpen(for: "x", in: cards), "自己一张")
    }

    func testStackKeySurvivesTheFirstCardGoing() {
        let before = TodayStack.spread(TodayStack.cards([card("a"), card("b"), card("c"), card("d")]))[0]
        let after = TodayStack.spread(TodayStack.cards([card("b"), card("c"), card("d")]))[0]
        XCTAssertEqual(TodayStack.key(before[0].tool, before[0].kind, before[0].title), TodayStack.key(after[0].tool, after[0].kind, after[0].title),
                       "处理掉第一张，展开的那一叠不该自己收起")
    }

    func testMenuTitleForColonTitles() {
        XCTAssertEqual(TodayStack.countTitle("可疑邮件：某银行：账户已冻结", 8, unit: "封"), "8 封可疑邮件",
                       "不写成「8 件：可疑邮件：某银行：账户已冻结」（只露出一封的主题）")
        XCTAssertEqual(TodayStack.countTitle("可疑邮件「某银行：账户已冻结」", 8, unit: "封"), "8 封可疑邮件",
                       "引的标题里有冒号：不写成「8 封可疑邮件「某银行」")
        XCTAssertEqual(TodayStack.countTitle("下载里的「eicar-test.com」可能是病毒", 2, unit: "样"), "下载里 2 样可能是病毒",
                       "书名号不在末尾的照旧")
    }
}
