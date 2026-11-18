import XCTest
@testable import LuokeWindow

/// 「今天」的「待确认」：急事在最上面，要你决定的先摆三叠（原型 11-12）
@MainActor
final class TodayAskTests: XCTestCase {
    func testAskLimitIsThree() {
        XCTAssertEqual(TodayPage.askLimit, 3)
    }

    func testHelloSaysUrgentFirstThenWhatWasDone() {
        let now = Date()
        let u = UrgentItem(id: "u1", tool: .mail, title: "银行：异常登录提醒", time: "09:10", primary: "看看", primarySymbol: nil, secondary: "不用")
        let d1 = DoneRow(id: "d1", tool: .mail, text: "已自动处理 1 封（a@x.com）", time: "10:42")
        let d2 = DoneRow(id: "d2", tool: .scan, text: "清掉 3 样缓存", time: "11:00")
        XCTAssertEqual(TodayHello.line(urgent: [u], done: [d1], now: now), "有件急事要你看：银行：异常登录提醒", "急事先说")
        XCTAssertNil(TodayHello.line(urgent: [], done: [d1, d2], now: now), "替你做了什么下面写着：不再说一遍")
        XCTAssertNil(TodayHello.line(urgent: [], done: [], now: now), "没有值得说的就不说")
    }

    func testHelloOnlyStatesWhatCanBeCounted() {
        let m = Sample.model()
        m.coreReachable = false
        XCTAssertNil(TodayHello(model: m).line, "连不上螺壳：不说今天的事")
        m.coreReachable = true
        m.done = []; m.cards = []; m.urgent = []
        XCTAssertNil(TodayHello(model: m).line, "什么都没有：页上自己有「今天没什么要你操心的」")
        m.helloLine = "上午归档了 14 封促销邮件，没有一封是人写的"
        XCTAssertEqual(TodayHello(model: m).line, "上午归档了 14 封促销邮件，没有一封是人写的", "核心定的那一句（今天的事，带一点性格）")
        m.urgent = [UrgentItem(id: "u1", tool: .mail, title: "银行：异常登录提醒", time: "09:10", primary: "看看", primarySymbol: nil, secondary: "不用")]
        XCTAssertEqual(TodayHello(model: m).line, "有件急事要你看：银行：异常登录提醒", "有急事先说急事")
    }
}
