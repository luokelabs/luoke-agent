import XCTest
@testable import LuokeWindow

/// 右边栏（界面规范 v2 §14，原型 11-12 定稿）
@MainActor
final class RightPanelTests: XCTestCase {
    func testPanelStartsClosedAndRemembersItsState() {
        let suite = UserDefaults(suiteName: "ai.luoke.window.test.panel")!
        suite.removePersistentDomain(forName: "ai.luoke.window.test.panel")
        let m = WindowModel(defaults: suite)
        XCTAssertFalse(m.panelOpen, "默认收起")
        m.openPanel(.history)
        XCTAssertTrue(m.panelOpen)
        XCTAssertEqual(m.panelTab, .history)
        XCTAssertTrue(WindowModel(defaults: suite).panelOpen, "记在这台 Mac 上")
        m.togglePanel()
        XCTAssertFalse(m.panelOpen)
        XCTAssertFalse(WindowModel(defaults: suite).panelOpen)
    }

    func testPillShowsTheRunningTaskElseTheDaysOutput() {
        let m = WindowModel()
        XCTAssertNil(m.runningTask, "没有任务在跑：右上角写今天的产出")
        m.tasks = [TaskRow(id: "a", tool: .mail, title: "生成摘要", state: .queued(wait: nil)),
                   TaskRow(id: "b", tool: .search, title: "读取合同", state: .running(fraction: 0.4, note: nil))]
        XCTAssertEqual(m.runningTask?.id, "b", "排着的不算在做")
    }

    func testOutputFallsBackToCountingTodaysActivity() {
        let m = WindowModel()
        XCTAssertEqual(m.tasksDone, 0)
        m.outputStats = OutputStats(tokensToday: 184_000)
        XCTAssertEqual(m.tasksDone, 0, "主控没给完成几件：照活动记录数")
        m.outputStats = OutputStats(tasksToday: 23, tokensToday: 184_000)
        XCTAssertEqual(m.tasksDone, 23, "主控给了就用主控的")
    }

    func testWaitLabels() {
        XCTAssertNil(TaskRow.Wait.soon.label, "马上就轮到的不标")
        // #171：不是今天的带上日子
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "Asia/Shanghai")!
        let now = cal.date(from: DateComponents(year: 2026, month: 11, day: 18, hour: 19, minute: 23))!
        func at(_ day: Int, _ h: Int, _ m: Int) -> TaskRow.Wait { .time(cal.date(from: DateComponents(year: 2026, month: 11, day: day, hour: h, minute: m))!) }
        XCTAssertEqual(at(18, 21, 5).label(now: now, calendar: cal), "21:05 起")
        XCTAssertEqual(at(19, 15, 25).label(now: now, calendar: cal), "明天 15:25 起")
        XCTAssertEqual(at(20, 15, 25).label(now: now, calendar: cal), "11月20日 15:25 起")
        XCTAssertEqual(TaskRow.Wait.power.label, "接电源时")
        XCTAssertEqual(TaskRow.Wait.busy.label, "排队中")
        XCTAssertEqual(TaskRow.Wait.quiet.label, "空闲时")
        XCTAssertEqual(TaskRow.Wait.thermal.label, "降温后")
    }

    func testTokenNumbersAreShortAndHumane() {
        // K、M、B，四舍五入，不带小数，单位大写（负责人 11-13）
        XCTAssertEqual(OutputStats.tokens(860), "860")
        XCTAssertEqual(OutputStats.tokens(8_200), "8K")
        XCTAssertEqual(OutputStats.tokens(184_300), "184K")
        XCTAssertEqual(OutputStats.tokens(999_600), "1M")
        XCTAssertEqual(OutputStats.tokens(3_120_000), "3M")
        XCTAssertEqual(OutputStats.tokens(2_400_000_000), "2B")
    }

    func testRingSaysWhatIsGoingOn() {
        let m = Sample.model()
        m.outputStats = OutputStats(tasksToday: 23, tokensToday: 184_300)
        m.tasks = [TaskRow(id: "a", tool: .scan, title: "全盘检查", state: .running(fraction: 0.4, note: nil)),
                   TaskRow(id: "b", tool: .mem, title: "整理本周记忆", state: .queued(wait: .quiet))]
        XCTAssertEqual(OutputPill.summary(m), "今天完成 23 件 · 生成 184K token · 进行中：全盘检查 · 排队 1 件")
        XCTAssertTrue(OutputPill.waiting(m.tasks[1]), "在等你不用时：另一种颜色")
    }

    func testStatusChipCarriesItsExplanation() {
        let m = WindowModel()
        m.sidebarNotice = SidebarNotice(id: "paused", kind: .paused, text: "已暂停", detail: "正在用电池。")
        XCTAssertEqual(m.sidebarNews?.detail, "正在用电池。", "点了先弹出为什么、怎么办")
        m.sidebarNotice = SidebarNotice(id: "update", kind: .update, text: "有新版本")
        XCTAssertNil(m.sidebarNews?.detail, "没有说明的直接去该去的地方")
        m.coreReachable = false
        XCTAssertEqual(m.sidebarNews?.text, "没响应", "连不上螺壳排在本体给的前面")
    }

    /// 「排队」照预计什么时候能开始排，不照应用排（#165）：马上的最前，钟点从早到晚，等条件的在后，暂停的最后
    func testQueueIsOrderedByExpectedStart() {
        let t = Date(timeIntervalSince1970: 1_800_000_000)
        func row(_ id: String, _ w: TaskRow.Wait?) -> TaskRow { TaskRow(id: id, tool: .mem, title: id, state: .queued(wait: w)) }
        let rows = [row("late", .time(t.addingTimeInterval(7200))), row("quiet", .quiet), row("paused", .paused), row("soon", .soon),
                    row("early", .time(t)), row("power", .power), row("busy", .busy), row("soon2", .soon)]
        XCTAssertEqual(TaskRow.queueOrder(rows).map(\.id), ["soon", "soon2", "busy", "early", "late", "quiet", "power", "paused"])
    }

    func testViewMenuTogglesRightPanel() {
        let m = WindowModel()
        let viewMenu = m.topMenus.first { $0.id == "view" }
        XCTAssertEqual(viewMenu?.items.first { $0.id == "panel" }?.title, "显示任务与历史")
        m.perform(.togglePanel)
        XCTAssertTrue(m.panelOpen)
        XCTAssertEqual(m.topMenus.first { $0.id == "view" }?.items.first { $0.id == "panel" }?.title, "收起任务与历史")
        m.perform(.togglePanel)
        XCTAssertFalse(m.panelOpen)
    }
}
