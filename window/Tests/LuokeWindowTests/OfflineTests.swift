import Foundation
import LuokeA2UI
import XCTest
@testable import LuokeWindow

/// 连不上螺壳时的几样（设计说明「出错和连不上」）和句尾不断行
@MainActor
final class OfflineTests: XCTestCase {
    func testOfflineSinceFollowsReachability() {
        let m = Sample.model()
        var t = Date(timeIntervalSince1970: 1_800_000_000)
        m.now = { t }
        XCTAssertNil(m.offlineSince)
        m.coreReachable = false
        XCTAssertEqual(m.offlineSince, t)
        XCTAssertFalse(m.offlineLong, "刚断开：窗口自己在重连")
        t += 31
        m.coreReachable = false
        XCTAssertEqual(m.offlineSince, t - 31, "一直连不上：从第一次算起")
        XCTAssertTrue(m.offlineLong, "超过 30 秒：给用户一件能做的事")
        m.coreReachable = true
        XCTAssertNil(m.offlineSince)
        XCTAssertFalse(m.offlineLong)
    }

    func testSeenTextDropsTheDateForToday() {
        let m = Sample.model()
        let cal = Calendar.current
        let now = cal.date(from: DateComponents(year: 2026, month: 11, day: 4, hour: 9, minute: 58))!
        m.now = { now }
        XCTAssertEqual(m.seenText(cal.date(from: DateComponents(year: 2026, month: 11, day: 4, hour: 9, minute: 41))!), "09:41")
        XCTAssertEqual(m.seenText(cal.date(from: DateComponents(year: 2026, month: 10, day: 20, hour: 20, minute: 0))!), "10月20日 20:00")
    }

    func testFeedRecordsWhenItWasLastSeen() {
        let m = Sample.model()
        let t = Date(timeIntervalSince1970: 1_800_000_000)
        m.now = { t }
        let f = AgentFeed(model: m)
        f.handle("feed", Data(#"{"cards": [], "notices": []}"#.utf8))
        XCTAssertEqual(m.lastSeen, t)
    }

    func testShortTailStaysOnOneLine() {
        let j = "\u{2060}"
        XCTAssertEqual(SurfaceView.keepTail("下载里的「a.scpt」可能是病毒"), "下载里的「a.scpt」可\(j)能\(j)是\(j)病\(j)毒")
        XCTAssertEqual(SurfaceView.keepTail("病毒库认出了它。"), "病毒库认出了它。", "句号结尾：不动")
        XCTAssertEqual(SurfaceView.keepTail("不是病毒"), "不是病毒", "整句都是汉字：不动")
        XCTAssertEqual(SurfaceView.keepTail("「x」要你决定的事情还有很多"), "「x」要你决定的事情还有很多", "超过 6 个字：不动")
    }

    func testStackToggleNamesTheKind() {
        XCTAssertEqual(TodayStack.what("这 1 封要你处理", 4, unit: "封"), "4 封要你处理", "不写「同类的」")
        XCTAssertEqual(TodayStack.what("1 封新邮件要处理", 4, unit: "封"), "4 封新邮件要处理", "邮件助手样例里核心给的标题")
        XCTAssertEqual(TodayStack.what("一封可疑邮件（a@b.com）", 4, unit: "封"), "4 封可疑邮件")
    }
}
