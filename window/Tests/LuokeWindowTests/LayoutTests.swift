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
        XCTAssertEqual(LKLayout(width: 1219), .regular, "1440 宽的窗口、侧栏展开：一栏 860 放下了，第二栏放不下")
        XCTAssertEqual(LKLayout(width: 1279), .regular)
        XCTAssertEqual(LKLayout(width: 1280), .wide)
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
        XCTAssertFalse(m.hasRail(.wide), "第一页没有 aside 段时不再留出空白右侧栏")
        XCTAssertFalse(m.hasRail(.regular))
        m.selectAppTab("status")
        XCTAssertFalse(m.hasRail(.wide), "别的页、工具没写 aside：一栏")

        let page = #"""
        {"messages": [
          {"version": "v0.9", "createSurface": {"surfaceId": "status", "catalogId": "ai.luoke/a2ui/agent/1"}},
          {"version": "v0.9", "updateComponents": {"surfaceId": "status", "components": [
            {"id": "root", "component": "Column", "children": ["t", "a"]},
            {"id": "t", "component": "Text", "text": "状态"},
            {"id": "a", "component": "Column", "placement": "aside", "children": ["d", "s"]},
            {"id": "d", "component": "Divider"},
            {"id": "s", "component": "Text", "text": "这周清掉 1.2 GB", "variant": "caption"}]}}]}
        """#
        f.applyPage(app: "luoke-scan", page: "status", status: 200, body: Data(page.utf8))
        let s = try XCTUnwrap(m.agentPages["luoke-scan/page/status"]?.surface)
        XCTAssertEqual(s.surface.asideSections, ["a"])
        XCTAssertTrue(m.hasRail(.wide), "工具写了 aside 的段：放进侧栏")
        XCTAssertFalse(m.hasRail(.regular), "不宽：照原来的顺序一栏画")

        m.go(.mem)
        XCTAssertFalse(m.hasRail(.wide), "没接核心的应用照旧一栏")
    }
}
