import SwiftUI
import XCTest
@testable import LuokeWindow

/// 螺壳只有一个窗口（11-10 定）：本体的界面经 `present` 画在主窗口里——占内容区的一页、浮着的卡片、占整个窗口的。
/// 用户离开时先问本体（`hostPageCanLeave`），走了才报 `hostPageClosed`；本体自己收起的不报。
@MainActor
final class HostPageTests: XCTestCase {
    final class Host: WindowHost {
        var canLeave = true
        var asked: [String] = []
        var closed: [String] = []
        func openModelSettings() {}
        func openPrivacySettings() {}
        func openAddApps() {}
        func upgrade(app: String) {}
        func hostPageCanLeave(_ id: String) -> Bool { asked.append(id); return canLeave }
        func hostPageClosed(_ id: String) { closed.append(id) }
    }

    private func page(_ id: String, _ style: HostPage.Style = .page) -> HostPage {
        HostPage(id: id, title: id, style: style, content: AnyView(Text(id)))
    }

    private func model() -> (WindowModel, Host) {
        let m = Sample.model()
        let h = Host()
        m.host = h
        return (m, h)
    }

    func testEachStyleHasItsSlot() {
        let (m, h) = model()
        XCTAssertFalse(m.hostShowing)
        m.present(page("update"))
        m.present(page("ask-fda", .card))
        m.present(page("first-run", .takeover))
        XCTAssertEqual(m.hostPage?.id, "update")
        XCTAssertEqual(m.hostCard?.id, "ask-fda")
        XCTAssertEqual(m.hostTakeover?.id, "first-run")
        XCTAssertTrue(m.hostShowing)

        m.present(HostPage(id: "update", title: "检查更新 · 下载中", content: AnyView(Text("2/5"))))
        XCTAssertEqual(m.hostPage?.title, "检查更新 · 下载中", "同一个编号再放是换内容")

        m.present(page("update", .card))
        XCTAssertNil(m.hostPage, "换了放法：原来的位置空出来")
        XCTAssertEqual(m.hostCard?.id, "update", "卡片的位置一次一张，新的换掉旧的")

        m.dismissHost("update")
        XCTAssertNil(m.hostCard)
        m.dismissHost("first-run")
        XCTAssertNil(m.hostTakeover)
        m.dismissHost("not-there")
        XCTAssertFalse(m.hostShowing)
        XCTAssertEqual(h.closed, [], "本体自己收起的不报")
        XCTAssertEqual(h.asked, [], "本体自己收起的也不问")
    }

    func testLeavingAPageAsksTheHostFirst() {
        let (m, h) = model()
        m.go(.scan)
        m.present(page("uninstall"))
        XCTAssertFalse(m.hasBottomBar, "本体的一页：底部不画搜索、问螺壳")

        h.canLeave = false        // 正在删
        m.go(.prefs, tab: "alerts")
        m.perform(.go(.today, nil))
        m.perform(.ask)
        m.perform(.urgent("spam"))
        m.openNotification([AgentNotification.userInfoKey: "brief"])
        XCTAssertEqual(m.page, .scan, "本体不放：哪儿都不去")
        XCTAssertEqual(m.hostPage?.id, "uninstall")
        XCTAssertNil(m.briefNote)
        XCTAssertFalse(m.askOpen)
        m.go(.scan)                // 侧栏底下那一页的那一行也一样
        XCTAssertEqual(m.hostPage?.id, "uninstall")
        XCTAssertEqual(m.hostPage?.id, "uninstall")
        XCTAssertEqual(h.closed, [])
        XCTAssertFalse(h.asked.isEmpty)

        h.canLeave = true
        m.go(.prefs, tab: "alerts")
        XCTAssertNil(m.hostPage)
        XCTAssertEqual(m.page, .prefs, "放了：收起本体的页，再去用户点的地方")
        XCTAssertEqual(h.closed, ["uninstall"])
    }

    /// 本体的一页没有「返回」（和 agent 自己的页一样）：点侧栏离开，点的正是底下那一页的那一行也算
    func testSidebarRowUnderneathLeavesThePage() {
        let (m, h) = model()
        m.go(.scan)
        m.present(page("update"))
        m.go(.scan)
        XCTAssertNil(m.hostPage)
        XCTAssertEqual(m.page, .scan)
        XCTAssertEqual(h.closed, ["update"])

        m.present(page("update"))
        m.go(.today)
        XCTAssertNil(m.hostPage)
        XCTAssertEqual(m.page, .today)
        XCTAssertEqual(h.closed, ["update", "update"])
    }

    /// 本体的一页、整窗盖着时侧栏哪一行都不亮；浮着的卡片不算
    func testSidebarLightsNoRowUnderAHostPage() {
        let (m, _) = model()
        m.go(.scan)
        XCTAssertEqual(m.sidebarSelection, .scan)
        if m.appsExpanded { m.toggleApps() }
        XCTAssertTrue(m.appsRowLit, "收着时正在看应用页：「应用」一行亮")
        m.present(page("update"))
        XCTAssertNil(m.sidebarSelection)
        XCTAssertFalse(m.appsRowLit)
        m.dismissHost("update")
        m.present(page("first-run", .takeover))
        XCTAssertNil(m.sidebarSelection)
        m.dismissHost("first-run")
        m.present(page("ask-fda", .card))
        XCTAssertEqual(m.sidebarSelection, .scan, "卡片浮着：底下那页照旧亮")
        XCTAssertTrue(m.appsRowLit)
    }

    /// 整窗的内容顶到窗口上沿：让开红黄绿的高度在红黄绿下面
    func testTakeoverInsetClearsTheLights() {
        XCTAssertGreaterThanOrEqual(HostPage.lightsInset, WindowControls.lightsCenterY + WindowControls.height / 2)
        XCTAssertEqual(EnvironmentValues().lkHostTopInset, 0, "别的放法不让")
    }

    func testCardClosesOnlyWhenTheHostLetsGo() {
        let (m, h) = model()
        m.present(page("ask-fda", .card))
        m.go(.prefs, tab: "alerts")
        XCTAssertEqual(m.page, .prefs, "卡片不挡菜单、通知换页")
        XCTAssertEqual(m.hostCard?.id, "ask-fda", "卡片照旧浮着等用户答")
        XCTAssertEqual(h.asked, [])

        h.canLeave = false
        XCTAssertFalse(m.leaveHost("ask-fda"))      // × 和 Esc
        XCTAssertEqual(m.hostCard?.id, "ask-fda")
        h.canLeave = true
        XCTAssertTrue(m.leaveHost("ask-fda"))
        XCTAssertNil(m.hostCard)
        XCTAssertEqual(h.closed, ["ask-fda"])
    }

    func testTakeoverBlocksGoingAnywhere() {
        let (m, h) = model()
        m.present(page("first-run", .takeover))
        m.go(.prefs, tab: "alerts")
        m.perform(.go(.scan, nil))
        m.perform(.ask)
        m.perform(.urgent("spam"))
        m.perform(.toggleSidebar)
        m.openBrief()
        XCTAssertEqual(m.page, .today)
        XCTAssertFalse(m.sidebarMini)
        XCTAssertNil(m.briefNote)
        XCTAssertEqual(m.hostTakeover?.id, "first-run")
        XCTAssertEqual(h.asked, [], "占整个窗口的不问、不离开：只有本体自己收")
        XCTAssertFalse(m.hasBottomBar)

        m.perform(.pause)
        XCTAssertNotNil(m.pausedUntil, "暂停提醒照做")

        m.present(page("ask-admin", .card))
        XCTAssertEqual(m.hostCard?.id, "ask-admin", "卡片可以浮在整窗的界面上")

        m.dismissHost("first-run")
        m.go(.prefs, tab: "alerts")
        XCTAssertEqual(m.page, .prefs)
        XCTAssertEqual(h.closed, [])
    }

    /// 本体的界面开着时 features 变了：只换掉底下那页，不去问本体
    func testFeatureChangeUnderAHostPageDoesNotAskTheHost() {
        let (m, h) = model()
        m.go(.activity)
        m.present(page("update"))
        m.features = .beta2
        XCTAssertEqual(m.page, .today)
        XCTAssertEqual(m.hostPage?.id, "update")
        XCTAssertEqual(h.asked, [])
    }

    /// 只有卡片浮着时 features 变了：照常 go（侧栏、页都在卡片底下照旧）
    func testFeatureChangeUnderACardGoesTheUsualWay() {
        let (m, h) = model()
        m.go(.activity, tab: "recent")
        m.present(page("ask-fda", .card))
        m.features = .beta2
        XCTAssertEqual(m.page, .today)
        XCTAssertEqual(m.appTab, "overview", "走的是 go：标签也回到第一页")
        XCTAssertEqual(m.hostCard?.id, "ask-fda", "卡片照旧浮着")
        XCTAssertEqual(h.asked, [])
    }

    /// 带 refresh 的页：本体的一页、整窗盖着时不再重取，收起后接着取；只有卡片浮着时照旧取
    func testRefreshStopsUnderAPageOrTakeoverButNotUnderACard() {
        for (style, keeps) in [(HostPage.Style.page, false), (.takeover, false), (.card, true)] {
            let wire = PageAdditionsTests.Wire()
            let m = Sample.model()
            let c = AgentConnection(model: m) { method, path, body in
                wire.add(method, path, body ?? Data())
                return (200, wire.reply(path))
            }
            Sample.applyAgentApps(c.feed)
            var later: [(TimeInterval, @MainActor () -> Void)] = []
            c.after = { later.append(($0, $1)) }
            let sid = "luoke-scan/page/overview"
            wire.set("/apps/luoke-scan/pages/overview", Data(#"""
            {"messages": [
              {"version": "v0.9", "createSurface": {"surfaceId": "\#(sid)", "catalogId": "ai.luoke/a2ui/agent/1"}},
              {"version": "v0.9", "updateComponents": {"surfaceId": "\#(sid)", "components": [{"id": "root", "component": "Text", "text": "清理中…", "refresh": 5}]}},
              {"version": "v0.9", "updateDataModel": {"surfaceId": "\#(sid)", "path": "/", "value": {}}}]}
            """#.utf8))
            c.reportWindow(open: true, front: true)
            m.go(.scan)
            let reads = { wire.paths("GET").filter { $0 == "/apps/luoke-scan/pages/overview" }.count }
            XCTAssertTrue(wait { reads() == 1 && later.count == 1 }, "\(style)")

            m.present(page("x", style))
            XCTAssertEqual(m.visibleAgentPageKey == nil, !keeps, "\(style)")
            later.removeFirst().1()
            if keeps {
                XCTAssertTrue(wait { reads() == 2 && later.count == 1 }, "卡片浮着：底下那页照旧取")
            } else {
                RunLoop.main.run(until: Date().addingTimeInterval(0.2))
                XCTAssertEqual(reads(), 1, "\(style) 盖着：不取")
                XCTAssertTrue(later.isEmpty, "\(style) 盖着：也不再定下一次")
                m.dismissHost("x")
                XCTAssertTrue(wait { reads() == 2 && later.count == 1 }, "\(style) 收起：重新取，接着定")
            }
        }
    }

    private func wait(_ ok: () -> Bool) -> Bool {
        for _ in 0..<200 {
            if ok() { return true }
            RunLoop.main.run(until: Date().addingTimeInterval(0.025))
        }
        return ok()
    }

    func testAnOldHostLetsGoAtOnce() {
        let m = Sample.model()
        m.host = HostTests.OldHost()
        m.present(page("update"))
        m.go(.prefs, tab: "alerts")
        XCTAssertNil(m.hostPage, "没写这两样的本体：默认放行")
        XCTAssertEqual(m.page, .prefs)
    }
}
