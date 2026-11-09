import Foundation
import LuokeA2UICore
import UserNotifications
import XCTest
@testable import LuokeWindow

/// beta 2 的精简版（luoke-core#68）和螺壳.app 接核心要的几样：通知、通知授权、窗口状态、用户在不在。
@MainActor
final class Beta2Tests: XCTestCase {
    func testBeta2DrawsOnlyTheAgentPages() {
        let m = Sample.model()
        m.go(.activity)
        m.features = .beta2
        XCTAssertEqual(m.page, .today, "正看着的页不画了：回「今天」")
        for p in [Page.activity, .search, .chat] {
            m.go(p)
            XCTAssertEqual(m.page, .today, "\(p) 不画")
        }
        m.go(.scan)
        XCTAssertEqual(m.page, .scan, "应用页照旧")
        m.go(.prefs, tab: PrefsTab.permissions.rawValue)
        XCTAssertEqual([m.page, m.prefsTab.rawValue] as [AnyHashable], [Page.prefs, "permissions"])
        m.openAsk()
        XCTAssertFalse(m.askOpen, "问螺壳不开")
        m.perform(.ask)
        XCTAssertFalse(m.askOpen)
        let go = m.goItems.map(\.id)
        XCTAssertFalse(go.contains("activity"))
        XCTAssertEqual(m.goItems.first { $0.id == "ask" }?.title, "搜索", "只有搜索框：菜单不说问螺壳")
        XCTAssertTrue(go.contains("today") && go.contains("permissions"))
    }

    final class Searcher: WindowBackend {
        var queries: [String] = []
        var actions: [String] = []
        func action(surfaceId: String, componentId: String, context: JSONValue) { actions.append("\(surfaceId) \(componentId)") }
        func updateSettings(_ patch: [String: JSONValue]) {}
        func search(query: String) { queries.append(query) }
    }

    private static let found = """
    {"results": [{"app": "luoke-search", "name": "螺壳搜索", "messages": [
      {"version": "v0.9", "createSurface": {"surfaceId": "luoke-search/search", "catalogId": "ai.luoke/a2ui/agent/1"}},
      {"version": "v0.9", "updateComponents": {"surfaceId": "luoke-search/search", "components": [
        {"id": "root", "component": "Column", "children": ["t"]},
        {"id": "t", "component": "Text", "text": "合同.pdf"}]}}]}], "failed": ["邮件助手"]}
    """

    private func searching() -> (WindowModel, AgentFeed, Searcher) {
        let m = WindowModel()
        m.features = .beta2
        let b = Searcher()
        m.backend = b
        return (m, AgentFeed(model: m), b)
    }

    func testSearchBoxSendsTheWordsAndDrawsTheCard() throws {
        let (m, f, b) = searching()
        m.runSearch("  ")
        XCTAssertEqual(b.queries, [], "空的不搜")
        m.runSearch(" 合同 ")
        XCTAssertEqual(b.queries, ["合同"])
        XCTAssertTrue(m.searching && m.searchOpen)
        f.applySearch(status: 200, body: Data(Self.found.utf8))
        XCTAssertFalse(m.searching)
        XCTAssertEqual(m.searchAnswer?.cards.map(\.id), ["luoke-search/search"])
        XCTAssertEqual(m.searchAnswer?.failed, ["邮件助手"])
        XCTAssertNotNil(f.surface("luoke-search/search"), "点按的 busy、result 找得到结果上的卡片")
        m.tapSurface("luoke-search/search", componentId: "b1", context: .object([:]))
        XCTAssertEqual(b.actions, ["luoke-search/search b1"])
        m.go(.prefs, tab: PrefsTab.permissions.rawValue)
        XCTAssertFalse(m.searchOpen, "换页收起")
    }

    func testSearchWhenNothingCanAnswer() {
        let (m, f, _) = searching()
        m.runSearch("合同")
        f.applySearch(status: 0, body: Data())
        XCTAssertEqual(m.searchAnswer?.note, "没连上螺壳的核心。")
        m.runSearch("合同")
        f.applySearch(status: 200, body: Data(#"{"results": [], "failed": [], "text": "还没有能搜的应用。"}"#.utf8))
        XCTAssertEqual(m.searchAnswer?.note, "还没有能搜的应用。")
        XCTAssertEqual(m.searchAnswer?.cards.count, 0)
    }

    func testAnswerAfterClosingIsDropped() {
        let (m, f, _) = searching()
        m.runSearch("合同")
        m.closeSearch()
        f.applySearch(status: 200, body: Data(Self.found.utf8))
        XCTAssertFalse(m.searchOpen)
    }

    func testSearchBoxOnlyInBeta2() {
        let m = Sample.model()
        let b = Searcher()
        m.backend = b
        m.runSearch("合同")
        XCTAssertEqual(b.queries, [], "完整窗口是问螺壳那一条")
        XCTAssertEqual(m.goItems.first { $0.id == "ask" }?.title, "搜索或问螺壳")
    }

    func testTurningAskOffClosesIt() {
        let m = Sample.model()
        m.openAsk()
        XCTAssertTrue(m.askOpen)
        m.features = .beta2
        XCTAssertFalse(m.askOpen)
    }

    func testFullWindowIsTheDefault() {
        let m = WindowModel()
        XCTAssertEqual(m.features, .all, "演示和截图照旧画全部")
        m.go(.activity)
        XCTAssertEqual(m.page, .activity)
    }

    func testNotificationContent() {
        let n = AgentNotification(id: "brief-am", title: "早上的简报", body: "3 件事", urgent: true, silent: false, surfaceId: "luoke-mail/x")
        let c = n.content()
        XCTAssertEqual([c.title, c.body], ["早上的简报", "3 件事"])
        XCTAssertEqual(c.interruptionLevel, .active, "beta 2 不加时效性通知")
        XCTAssertNotNil(c.sound)
        XCTAssertEqual(n.content(timeSensitive: true).interruptionLevel, .timeSensitive)
        let clicked = AgentNotification.clicked(c.userInfo)
        XCTAssertTrue(clicked.isAgent)
        XCTAssertEqual(clicked.surfaceId, "luoke-mail/x")
        XCTAssertFalse(AgentNotification.clicked(["notes": "beta1"]).isAgent, "本体自己的通知不归窗口")
        let quiet = AgentNotification(id: "q", title: "", body: "", urgent: false, silent: true, surfaceId: nil)
        XCTAssertNil(quiet.content().sound)
        XCTAssertEqual(AgentNotification.authName(.denied), "denied")
    }

    /// 报过的窗口状态、通知授权记着：核心重启、重新连上时再报一遍
    func testReportsAreResentOnReconnect() {
        final class Log: @unchecked Sendable {
            let lock = NSLock()
            var posts: [(String, Data)] = []
            func add(_ p: String, _ d: Data) { lock.lock(); posts.append((p, d)); lock.unlock() }
            func bodies(_ p: String) -> [Data] { lock.lock(); defer { lock.unlock() }; return posts.filter { $0.0 == p }.map(\.1) }
        }
        let log = Log()
        let m = WindowModel()
        let c = AgentConnection(model: m) { method, path, body in
            if method == "POST" { log.add(path, body ?? Data()) }
            return (200, Data("{}".utf8))
        }
        c.reportWindow(open: true, front: false)
        c.reportNotifications(status: "denied", alerts: true)
        XCTAssertTrue(wait { log.bodies("/window").count == 1 && log.bodies("/notifications").count == 1 })
        XCTAssertEqual(try JSONValue.parse(log.bodies("/notifications")[0]), .object(["status": .string("denied"), "alerts": .bool(true)]))
        c.setConnected(true)
        XCTAssertTrue(wait { log.bodies("/window").count == 2 && log.bodies("/notifications").count == 2 })
        XCTAssertEqual(try JSONValue.parse(log.bodies("/window")[1]), .object(["open": .bool(true), "front": .bool(false)]))
        XCTAssertTrue(log.bodies("/presence").isEmpty, "没让它看着用户在不在就不报")
    }

    func testHostNoticeComesFirstAndIsKept() {
        let m = WindowModel()
        let f = AgentFeed(model: m)
        m.hostNotice = "螺壳的核心起不来。"
        f.handle("feed", Data(#"{"order":[],"open":0,"notices":["螺壳搜索现在没在运行。"],"cards":[]}"#.utf8))
        XCTAssertEqual(m.hostNotice, "螺壳的核心起不来。", "核心的几句换掉的是它自己的")
        XCTAssertEqual(m.notices, ["螺壳搜索现在没在运行。"])
    }

    private func wait(_ ok: () -> Bool) -> Bool {
        for _ in 0..<200 {
            if ok() { return true }
            RunLoop.main.run(until: Date().addingTimeInterval(0.025))
        }
        return ok()
    }
}

/// 侧栏的应用：螺壳.app 给了装着的应用以后，照核心连着的工具列，版本从螺壳.app 来
@MainActor
final class InstalledAppsTests: XCTestCase {
    func testSidebarFollowsTheCoreOnceTheHostSaysWhatIsInstalled() {
        let m = WindowModel()
        m.features = .beta2
        m.setInstalledApps([InstalledApp(accessory: "luoke-mail", version: "0.18.11", update: "0.18.12"),
                            InstalledApp(accessory: "luoke-scan", version: "0.1.0"),
                            InstalledApp(accessory: "luoke-search", version: "0.4.2"),
                            InstalledApp(accessory: "luoke-ime", version: "0.1.12")])
        XCTAssertEqual(m.apps.map(\.id), [.mail, .scan, .searchApp], "核心还没来：先照装着的列，窗口里没有页的不列")
        XCTAssertEqual(m.apps.first?.update, "0.18.12")
        let f = AgentFeed(model: m)
        f.applyApps(.object(["apps": .array([
            .object(["id": .string("luoke-scan"), "running": .bool(true), "pages": .array([]), "needs": .array([])]),
        ])]))
        XCTAssertEqual(m.apps.map(\.id), [.scan], "核心来了：照它连着的工具列")
        XCTAssertEqual(m.apps.first?.version, "0.1.0")
    }

    func testSampleKeepsItsOwnApps() {
        let m = Sample.model()
        let before = m.apps
        Sample.applyAgentApps(AgentFeed(model: m))
        XCTAssertEqual(m.apps, before, "没给装着的应用：侧栏照旧（演示、截图）")
    }
}
