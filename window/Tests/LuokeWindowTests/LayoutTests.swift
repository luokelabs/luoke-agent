import Foundation
import LuokeA2UICore
import XCTest
@testable import LuokeWindow

/// 宽窗口（docs/主窗口.md「宽窗口」）：内容区分三档；哪些页、什么时候有侧栏
@MainActor
final class LayoutTests: XCTestCase {
    private var keep: [AnyObject] = []

    func testTiersFollowTheContentWidth() {
        XCTAssertEqual(LKLayout(width: 639), .narrow, "最小的窗口 860 宽、侧栏展开：内容区 639")
        XCTAssertEqual(LKLayout(width: 759), .narrow)
        XCTAssertEqual(LKLayout(width: 760), .regular)
        XCTAssertEqual(LKLayout(width: 783), .regular, "默认窗口 1004 宽")
        XCTAssertEqual(LKLayout(width: 1199), .regular)
        XCTAssertEqual(LKLayout(width: 1200), .wide)
        XCTAssertEqual(LKLayout(width: 1219), .wide, "1440 宽的窗口、侧栏展开")
    }

    func testMainColumnKeepsItsWidthNextToTheRail() {
        let one = LKColumn.width - LKInsets.column.leading - LKInsets.column.trailing
        let main = LKColumn.railedWidth - LKInsets.column.leading - LKInsets.column.trailing - LKColumn.gap - LKColumn.rail
        XCTAssertEqual(main, one, "主栏和一栏时一样宽：一行的字数不变")
        XCTAssertLessThanOrEqual(LKColumn.railedWidth, LKLayout.wideFrom, "到了 wide，主栏、侧栏和边距放得下")
        XCTAssertEqual(LKColumn.railShift * 2, LKColumn.gap + LKColumn.rail, "搜索框挪到主栏的中线上")
    }

    func testTodayHasARailOnlyWhenWideAndSomethingGoesThere() {
        let m = Sample.model()
        XCTAssertFalse(m.hasRail(.narrow))
        XCTAssertFalse(m.hasRail(.regular))
        XCTAssertTrue(m.hasRail(.wide), "示例里有已经替你做了")
        m.done = []
        XCTAssertFalse(m.hasRail(.wide), "顺便看看留在主栏：没有做了的，照旧一栏居中")
    }

    func testCompactTodayAndFocusHaveNoRail() {
        let m = Sample.model()
        m.enterFocus()
        XCTAssertFalse(m.hasRail(.wide), "一件件处理盖住「今天」")
        m.exitFocus()
        m.setDensity(.compact)
        XCTAssertFalse(m.hasRail(.wide), "紧凑是一张表，不分两栏")
    }

    func testDoneListsMoreRowsInTheRail() {
        let rows = (1...9).map { DoneRow(id: "d\($0)", tool: .mail, text: "第 \($0) 件", time: "09:0\($0)", undoLabel: "撤销") }
        let rail = TodayPage.visibleDone(rows, all: false, deciding: true, railed: true)
        XCTAssertEqual(rail.rows.count, TodayPage.doneLimitRail, "在侧栏里挤不着「要你决定」")
        XCTAssertEqual(rail.more, rows.count - TodayPage.doneLimitRail)
        XCTAssertEqual(TodayPage.visibleDone(rows, all: false, deciding: true).rows.count, TodayPage.doneLimitDeciding, "一栏时照旧")
    }

    func testAppPageRail() throws {
        let m = Sample.model()
        let f = AgentFeed(model: m)
        keep.append(f)
        Sample.applyAgentApps(f)
        m.go(.scan)
        XCTAssertTrue(m.hasRail(.wide), "第一页下面的「这个应用」放进侧栏")
        XCTAssertFalse(m.hasRail(.regular))
        m.selectAppTab("cleaned")
        XCTAssertFalse(m.hasRail(.wide), "别的页、工具没写 aside：一栏")

        let page = #"""
        {"messages": [
          {"version": "v0.9", "createSurface": {"surfaceId": "cleaned", "catalogId": "ai.luoke/a2ui/agent/1"}},
          {"version": "v0.9", "updateComponents": {"surfaceId": "cleaned", "components": [
            {"id": "root", "component": "Column", "children": ["t", "a"]},
            {"id": "t", "component": "Text", "text": "清理记录"},
            {"id": "a", "component": "Column", "placement": "aside", "children": ["d", "s"]},
            {"id": "d", "component": "Divider"},
            {"id": "s", "component": "Text", "text": "这周清掉 1.2 GB", "variant": "caption"}]}}]}
        """#
        f.applyPage(app: "luoke-scan", page: "cleaned", status: 200, body: Data(page.utf8))
        let s = try XCTUnwrap(m.agentPages["luoke-scan/page/cleaned"]?.surface)
        XCTAssertEqual(s.surface.asideSections, ["a"])
        XCTAssertTrue(m.hasRail(.wide), "工具写了 aside 的段：放进侧栏")
        XCTAssertFalse(m.hasRail(.regular), "不宽：照原来的顺序一栏画")

        m.go(.mem)
        XCTAssertFalse(m.hasRail(.wide), "没接核心的应用照旧一栏")
    }
}
