import Foundation
import LuokeA2UICore
import XCTest
@testable import LuokeWindow

/// 接 agent 核心的应用的页（docs/界面接口.md §6）和「设置 · 权限」（§10）：`/apps`、基础页、`/open`、`/permissions`、`/host`。
@MainActor
final class AgentAppsTests: XCTestCase {
    /// 记下窗口要后端做的每件事
    final class Recorder: WindowBackend {
        var calls: [String] = []
        func action(surfaceId: String, componentId: String, context: JSONValue) { calls.append("action \(surfaceId) \(componentId)") }
        func updateSettings(_ patch: [String: JSONValue]) { calls.append("settings") }
        func reloadApps() { calls.append("apps") }
        func reloadPage(app: String, page: String) { calls.append("page \(app) \(page)") }
        func openApp(_ app: String, page: String?) { calls.append("open \(app) \(page ?? "-")") }
        func reloadPermissions() { calls.append("permissions") }
        func permission(app: String, id: String, op: String) { calls.append("perm \(app) \(id) \(op)") }
        func reportHost(permissions: [String: JSONValue], confirmed: [String: [String: String]]?) { calls.append("host \(String(decoding: JSONValue.object(permissions).serialized(), as: UTF8.self))") }
    }

    private var keep: [AnyObject] = []

    /// 示例窗口（侧栏的应用来自主控，示例里有）加上核心答的应用、页、权限
    private func fed(backend: Recorder? = nil) -> (WindowModel, AgentFeed) {
        let m = Sample.model()
        let f = AgentFeed(model: m)
        if let backend { m.backend = backend; keep.append(backend) }
        Sample.applyAgentApps(f)
        backend?.calls = []
        return (m, f)
    }

    /// 扫描这边：它的场景样例接上真核心得来的（`ToolSample`），测试照它比，不抄它的字
    private func scanSample() throws -> ToolSample {
        try XCTUnwrap(ToolSample.load("luoke-scan", ToolSample.defaultScan), "Resources/samples/luoke-scan 里要有默认的场景")
    }

    private func buttonNames(_ page: JSONValue?) -> [String] {
        (page?["messages"]?.array ?? []).flatMap { $0["updateComponents"]?["components"]?.array ?? [] }
            .filter { $0["component"]?.string == "Button" }.compactMap { $0["action"]?["event"]?["name"]?.string }
    }

    private func row(_ m: WindowModel, _ app: String, _ id: String) -> AgentPermission {
        m.agentPermissions!.first { $0.app == app && $0.key == id }!
    }

    // MARK: 应用的页

    func testAppsListBecomesTabsAndSummary() throws {
        let (m, _) = fed()
        let scan = try XCTUnwrap(m.agentApp(for: .scan))
        XCTAssertEqual(scan.id, "luoke-scan")
        XCTAssertTrue(scan.running)
        XCTAssertEqual(scan.summary?.text, try scanSample().apps.first?["summary"]?["text"]?.string, "照核心答的写")
        XCTAssertNotNil(scan.summary?.text)
        XCTAssertEqual(scan.pages.map(\.title), ["概览", "清理记录"], "窗口里画的页")
        XCTAssertNil(scan.uiPages, "扫描没有自己的界面")
        XCTAssertFalse(scan.hasUI)
        XCTAssertEqual(m.agentApp(for: .mail)?.uiPages?.map(\.title), ["账号"], "带外链箭头、由工具自己打开的页")
        XCTAssertEqual(m.agentApp(for: .mail)?.hasUI, true)
        XCTAssertEqual(scan.needs, ["fda"])
        XCTAssertEqual(m.needsText(scan), "完全磁盘访问", "缺的权限写名字（从 /permissions 来）")
        XCTAssertEqual(m.agentApp(for: .mail)?.id, "luoke-mail")
        XCTAssertNil(m.agentApp(for: .mem), "记忆不是核心的应用：照旧画示例")
        XCTAssertNil(m.agentApp(for: .today))
        m.go(.scan, tab: "log")
        XCTAssertEqual(m.agentTab(scan), "overview", "选的标签不是它的页：画第一页")
        m.selectAppTab("cleaned")
        XCTAssertEqual(m.agentTab(scan), "cleaned")
    }

    func testNeedsWithoutPermissionTitlesSaysHowMany() throws {
        let m = WindowModel()
        let f = AgentFeed(model: m)
        f.applyApps(try JSONValue.parse(Sample.agentApps()))
        XCTAssertEqual(m.needsText(try XCTUnwrap(m.agentApp(for: .scan))), "1 项权限")
    }

    func testPageIsRenderedFromTheMessages() throws {
        let (m, f) = fed()
        let sid = "luoke-scan/page/overview"
        let s = try XCTUnwrap(m.agentPages[sid]?.surface, "画得出")
        XCTAssertEqual(s.surface.surfaceId, sid)
        let buttons = s.surface.reachable().filter { s.surface.components[$0]?["component"]?.string == "Button" }
        let want = buttonNames(try scanSample().pages["overview"])
        XCTAssertFalse(want.isEmpty, "扫描的概览上有按钮")
        XCTAssertEqual(buttons.map { try! s.surface.action($0).name }.sorted(), want.sorted())
        XCTAssertNotNil(m.agentPages["luoke-scan/page/cleaned"]?.surface)

        f.applyPage(app: "luoke-mail", page: "overview", status: 503, body: Data(#"{"error":"邮件助手现在没在运行。"}"#.utf8))
        XCTAssertNil(m.agentPages["luoke-mail/page/overview"]?.surface)
        XCTAssertEqual(m.agentPages["luoke-mail/page/overview"]?.error, "邮件助手现在没在运行。")
        f.applyPage(app: "luoke-mail", page: "rules", status: 200, body: Data(#"{"messages":[{"nope":1}]}"#.utf8))
        XCTAssertEqual(m.agentPages["luoke-mail/page/rules"]?.error, "这一页画不了。", "校验不过的不画")
        f.applyPage(app: "luoke-scan", page: "overview", status: 0, body: Data())
        XCTAssertNotNil(m.agentPages[sid]?.surface, "连不上：先留着上次的")
    }

    func testGoingToAnAppPageFetchesItsPage() {
        let b = Recorder()
        let (m, _) = fed(backend: b)
        m.go(.scan)
        XCTAssertEqual(b.calls, ["page luoke-scan overview"], "权限取过了：不再取")
        b.calls = []
        m.selectAppTab("cleaned")
        XCTAssertEqual(b.calls, ["page luoke-scan cleaned"])
        b.calls = []
        m.go(.mem)
        m.go(.today)
        XCTAssertEqual(b.calls, [], "不是核心的应用、不是应用页：不取")
        m.go(.prefs, tab: PrefsTab.permissions.rawValue)
        XCTAssertEqual(b.calls, ["permissions"], "打开「设置 · 权限」时取一遍")
        b.calls = []
        m.selectPrefsTab(.alerts)
        m.selectPrefsTab(.permissions)
        XCTAssertEqual(b.calls, ["permissions"])
    }

    func testAppsListArrivingFetchesTheVisiblePageOnce() throws {
        let b = Recorder()
        let m = Sample.model()
        let f = AgentFeed(model: m)
        m.backend = b
        m.go(.scan)
        XCTAssertEqual(b.calls, [], "应用列表还没来")
        f.applyApps(try JSONValue.parse(Sample.agentApps()))
        XCTAssertEqual(b.calls, ["page luoke-scan overview", "permissions"], "列表来了：取正看着的页；缺权限要写名字，取权限")
        f.applyPage(app: "luoke-scan", page: "overview", status: 200, body: Sample.agentPage("luoke-scan", "overview")!)
        b.calls = []
        f.applyApps(try JSONValue.parse(Sample.agentApps()))
        XCTAssertEqual(b.calls, ["permissions"], "取过的页不再取")
    }

    func testAppsEventRefetchesListAndTheShownPage() {
        let b = Recorder()
        let (m, f) = fed(backend: b)
        m.go(.scan)
        b.calls = []
        f.handle("apps", Data(#"{"app":"luoke-scan"}"#.utf8))
        XCTAssertEqual(b.calls, ["apps", "page luoke-scan overview"])
        b.calls = []
        f.handle("apps", Data(#"{"app":"luoke-mail"}"#.utf8))
        XCTAssertEqual(b.calls, ["apps"], "别的应用变了：只取列表")
        m.go(.prefs, tab: PrefsTab.permissions.rawValue)
        b.calls = []
        f.handle("apps", Data(#"{"app":"luoke-mail"}"#.utf8))
        XCTAssertEqual(b.calls, ["apps", "permissions"], "正看着权限：权限也重新取")
    }

    func testOpenFullUIOnlyWhenTheToolHasOne() throws {
        let b = Recorder()
        let (m, f) = fed(backend: b)
        m.go(.mail)
        b.calls = []
        m.openAppUI()
        m.openAppUI(page: "accounts")
        XCTAssertEqual(b.calls, ["open luoke-mail -", "open luoke-mail accounts"])
        m.go(.scan)
        b.calls = []
        m.openAppUI()
        XCTAssertEqual(b.calls, [], "工具没有自己的界面：没有「打开完整界面」")
        f.applyApps(try JSONValue.parse(#"{"apps":[{"id":"luoke-mail","running":true,"summary":null,"pages":[],"ui":null,"needs":[]}]}"#))
        XCTAssertFalse(try XCTUnwrap(m.agentApp(for: .mail)).hasUI)
        XCTAssertNil(m.agentApp(for: .mail)?.summary)
        m.go(.mail)
        b.calls = []
        m.openAppUI()
        XCTAssertEqual(b.calls, [], "工具不再报自己的界面：也没有了")
    }

    func testPageButtonsGoThroughTheActionPath() {
        let b = Recorder()
        let (m, f) = fed(backend: b)
        m.go(.scan)
        b.calls = []
        m.tapSurface("luoke-scan/page/overview", componentId: "b1", context: .object([:]))
        XCTAssertEqual(b.calls, ["action luoke-scan/page/overview b1"])
        f.handle("busy", Data(#"{"surfaceId":"luoke-scan/page/overview"}"#.utf8))
        XCTAssertTrue(m.agentPages["luoke-scan/page/overview"]!.surface!.busy, "页上的按钮也先灰掉")
        f.handle("result", Data(#"{"surfaceId":"luoke-scan/page/overview","text":"开始逐项看。","error":false,"replaced":false}"#.utf8))
        XCTAssertFalse(m.agentPages["luoke-scan/page/overview"]!.surface!.busy)
        XCTAssertEqual(m.toast?.text, "开始逐项看。")
    }

    // MARK: 设置 · 权限

    func testPermissionRowsAreGrouped() throws {
        let (m, _) = fed()
        let luoke = m.luokePermissions
        XCTAssertEqual(luoke.map(\.id), ["fda"], "螺壳名下的同一项合成一行")
        XCTAssertEqual(luoke[0].rows.map(\.tool), [.mail, .scan], "写哪些应用在用")
        let scanFDA = try scanSample().permissions.first { $0["id"]?.string == "fda" }
        XCTAssertEqual(luoke[0].rows.last?.facts, scanFDA?["facts"]?.array?.compactMap(\.string))
        XCTAssertEqual(luoke[0].can, ["settings"])
        XCTAssertEqual(m.agentPermissionRows("system").map(\.key), ["contacts"])
        XCTAssertEqual(m.agentPermissionRows("account").map(\.key), ["mailbox"])
        XCTAssertEqual(m.agentPermissionRows("delegate").map(\.id), ["luoke-mail#auto", "luoke-scan#auto"])
        XCTAssertEqual(m.agentPermissionRows("each-time").map(\.key), ["send", "admin"])
        XCTAssertTrue(m.agentPermissionRows("each-time").allSatisfy { $0.can == nil }, "每次都问的没有按钮")
        XCTAssertTrue(m.isNeeded(row(m, "luoke-scan", "fda")))
        XCTAssertFalse(m.isNeeded(row(m, "luoke-mail", "contacts")))
        XCTAssertEqual(AgentPermissionsTab.light("system", "denied", needed: true).1, "没允许")
        XCTAssertEqual(AgentPermissionsTab.light("system", "ask", needed: true).1, "等你允许")
        XCTAssertEqual(AgentPermissionsTab.light("account", "granted", needed: false).1, "连着")
        XCTAssertEqual(AgentPermissionsTab.light("system", nil, needed: false).1, "现在不知道")
    }

    func testPermissionOpsOnlyOnClickAndOnlyWhatTheRowCan() {
        let b = Recorder()
        let (m, _) = fed(backend: b)
        m.go(.prefs, tab: PrefsTab.permissions.rawValue)
        XCTAssertEqual(b.calls, ["permissions"], "取来、画出来都不改动东西")
        b.calls = []
        m.permissionAction(row(m, "luoke-mail", "contacts"), "settings")
        m.permissionAction(row(m, "luoke-mail", "send"), "remove")
        m.permissionAction(row(m, "luoke-scan", "auto"), "off")     // 样例里不用点就清是关着的（扫描 0.1.4 起默认关）
        XCTAssertEqual(b.calls, [], "不在这一行的 can 里：不交给核心")

        m.permissionAction(row(m, "luoke-scan", "fda"), "settings")
        m.permissionAction(row(m, "luoke-scan", "fda"), "settings")
        XCTAssertEqual(b.calls, ["perm luoke-scan fda settings"], "等核心答的时候再点不算")
        XCTAssertEqual(m.permissionPending["luoke-scan#fda"], "settings")
        m.permissionAnswered(app: "luoke-scan", id: "fda", op: "settings", text: "打开了系统设置的「完全磁盘访问」。", error: false)
        XCTAssertNil(m.permissionPending["luoke-scan#fda"])
        XCTAssertEqual(m.toast?.text, "打开了系统设置的「完全磁盘访问」。")

        b.calls = []
        m.permissionAction(row(m, "luoke-scan", "auto"), "on")
        XCTAssertEqual(m.permissionPending["luoke-scan#auto"], "on", "开关先照点的画")
        m.permissionAction(row(m, "luoke-mail", "mailbox"), "open")
        m.permissionAction(row(m, "luoke-mail", "mailbox"), "remove")
        XCTAssertEqual(b.calls, ["perm luoke-scan auto on", "perm luoke-mail mailbox open"], "同一行等着答的时候不再交")
    }

    func testRequestExplainsFirstAndContinueAsks() {
        let b = Recorder()
        let (m, _) = fed(backend: b)
        m.permissionAction(row(m, "luoke-mail", "contacts"), "request")
        XCTAssertEqual(b.calls, [], "先说明，不弹系统的框")
        XCTAssertEqual(m.sheet?.title, "读通讯录")
        XCTAssertEqual(m.sheet?.facts, ["认出常联系的人", "只在这台 Mac 上"])
        XCTAssertEqual(m.sheet?.owner, .mail)
        m.closeSheet()
        XCTAssertEqual(b.calls, [], "「先不用」什么都不交")
        m.permissionAction(row(m, "luoke-mail", "contacts"), "request")
        m.continueSheet()
        m.continueSheet()
        XCTAssertEqual(b.calls, ["perm luoke-mail contacts request"], "点了「继续」才交给核心，一次")
        XCTAssertEqual(m.sheet?.waiting, true)
        m.permissionAnswered(app: "luoke-mail", id: "contacts", op: "request", text: "系统问过了，你允许了读通讯录。", error: false)
        XCTAssertNil(m.sheet)
        XCTAssertEqual(m.toast?.text, "系统问过了，你允许了读通讯录。")
    }

    // MARK: 螺壳名下的系统权限：交给本体

    private func hosted(_ b: Recorder, scan: String = ToolSample.defaultScan) -> (WindowModel, HostTests.FakeHost) {
        let m = Sample.model()
        let f = AgentFeed(model: m)
        m.backend = b
        keep += [b, f]
        for (e, d) in Sample.agentEvents(scan: scan) { f.handle(e, d) }
        Sample.applyAgentApps(f, scan: scan)
        let h = HostTests.FakeHost()
        keep.append(h)
        m.host = h
        b.calls = []
        return (m, h)
    }

    private func luokeRow(can: [String], kind: String = "system", owner: String? = "luoke") -> AgentPermission {
        AgentPermission(app: "luoke-scan", key: "x", kind: kind, owner: owner, tcc: nil, title: "某项", facts: [], without: nil,
                        state: "ask", can: can)
    }

    func testLuokePermissionButtonsGoToTheHost() {
        let b = Recorder()
        let (m, h) = hosted(b)
        m.reportHostPermissions([:], confirmed: [:])
        b.calls = []
        let denied = AgentPermission(app: "luoke-scan", key: "fda", kind: "system", owner: "luoke", tcc: nil, title: "某项", facts: [],
                                     without: nil, state: "denied", can: ["settings"])
        m.permissionAction(denied, "settings")
        XCTAssertEqual(h.calls, [], "没确认过、系统拒绝过：「打开系统设置」就是去系统设置，确认是开关的事")
        XCTAssertEqual(b.calls, ["perm luoke-scan fda settings"], "地址由核心给")
        m.permissionAnswered(app: "luoke-scan", id: "fda", op: "settings", text: "", error: false)
        m.permissionAction(luokeRow(can: ["settings"]), "settings")
        XCTAssertEqual(h.calls, ["system x"], "系统还没问过：系统设置里没有这一项，本体只问系统，不问用户")
        m.reportHostPermissions([:], confirmed: ["luoke-scan": ["fda": "2026-11-06T10:00:00Z"]])
        m.permissionAction(denied, "settings")
        XCTAssertEqual(h.calls.last, "ask luoke-scan fda", "确认过又被拒绝：交给本体，给了权限后的事本体接着做")
        h.calls = []
        b.calls = []
        let granted = AgentPermission(app: "luoke-scan", key: "fda", kind: "system", owner: "luoke", tcc: nil, title: "某项", facts: [],
                                      without: nil, state: "granted", can: ["settings"])
        m.permissionAction(granted, "settings")
        XCTAssertEqual(h.calls, [], "已经授权：只是去系统设置看，不出本体的窗口")
        XCTAssertEqual(b.calls, ["perm luoke-scan fda settings"])
        m.permissionAnswered(app: "luoke-scan", id: "fda", op: "settings", text: "", error: false)
        m.permissionAction(luokeRow(can: ["request"]), "request")
        XCTAssertEqual(h.calls.last, "ask luoke-scan x")
        XCTAssertNil(m.sheet, "说明由本体的窗口写，窗口不再出一层")

        h.calls = []
        b.calls = []
        m.permissionAction(luokeRow(can: ["settings"]), "request")
        XCTAssertEqual(h.calls, [], "不在这一行的 can 里：不算")
        m.permissionAction(luokeRow(can: ["on"], kind: "delegate"), "on")
        XCTAssertEqual(h.calls, [], "只管系统权限")
        XCTAssertEqual(b.calls, ["perm luoke-scan x on"])
    }

    func testPermissionsNotOwnedByLuokeStayAsTheyWere() {
        let b = Recorder()
        let (m, h) = hosted(b)
        m.permissionAction(row(m, "luoke-mail", "contacts"), "request")
        XCTAssertEqual(m.sheet?.title, "读通讯录", "工具自己的 request：窗口先说明")
        m.continueSheet()
        XCTAssertEqual(b.calls, ["perm luoke-mail contacts request"])
        b.calls = []
        m.permissionAction(luokeRow(can: ["settings"], owner: nil), "settings")
        XCTAssertEqual(b.calls, ["perm luoke-scan x settings"], "系统设置的地址照旧由核心给")
        XCTAssertEqual(h.calls, [])
    }

    func testNoHostMeansLuokeRowsGoToTheCore() {
        let b = Recorder()
        let (m, _) = fed(backend: b)
        m.permissionAction(row(m, "luoke-scan", "fda"), "settings")
        XCTAssertEqual(b.calls, ["perm luoke-scan fda settings"])
    }

    func testNeedsAccessCardButtonGoesToTheHost() throws {
        let b = Recorder()
        let (m, h) = hosted(b)
        let sid = "luoke-scan/access-000000000003"
        let card = try XCTUnwrap(m.cards.first { $0.id == sid }, "扫描的场景里没给完全磁盘访问：有一张要权限的卡片")
        XCTAssertEqual(m.hostAsks[sid], HostAsk(app: "luoke-scan", id: "fda", button: "b3"), "核心从工具录的卡片上认出来的")
        m.tap(card: card, componentId: "b3", name: "scan_open_settings", context: .object([:]))
        XCTAssertEqual(h.calls, ["ask luoke-scan fda"])
        XCTAssertEqual(b.calls, [], "不转给工具")
        XCTAssertEqual(m.cards.filter { $0.id == sid }.count, 1, "卡片留着，等本体报了 granted 由核心撤下")

        m.tapSurface(sid, componentId: "b3", context: .object([:]))
        XCTAssertEqual(h.calls.last, "ask luoke-scan fda", "画在别的段里也一样")
        h.calls = []
        m.tap(card: card, componentId: "b9", name: "scan_later", context: .object([:]))
        XCTAssertEqual(b.calls, ["action \(sid) b9"], "卡片上别的按钮照旧")
        XCTAssertEqual(h.calls, [])

        b.calls = []
        m.host = nil
        m.tap(card: card, componentId: "b3", name: "scan_open_settings", context: .object([:]))
        XCTAssertEqual(b.calls, ["action \(sid) b3"], "没接本体：照旧转给工具")
    }

    func testCardsWithoutHostAskGoToTheBackend() throws {
        let b = Recorder()
        let (m, h) = hosted(b)
        let card = try XCTUnwrap(m.cards.first { m.hostAsks[$0.id] == nil })
        m.tap(card: card, componentId: "b3", name: "x", context: .object([:]))
        XCTAssertEqual(b.calls, ["action \(card.id) b3"])
        XCTAssertEqual(h.calls, [])
    }

    func testHostAskFollowsTheFeed() {
        let m = Sample.model()
        let f = AgentFeed(model: m)
        keep.append(f)
        func feed(_ ask: String) {
            f.handle("feed", Data(#"{"cards": [{"id": "a/1", "app": "a", "kind": "needs-access", "section": "decide"\#(ask)}]}"#.utf8))
        }
        feed(#", "host_ask": {"permission": "fda", "button": "b1"}"#)
        XCTAssertEqual(m.hostAsks, ["a/1": HostAsk(app: "a", id: "fda", button: "b1")])
        feed("")
        XCTAssertEqual(m.hostAsks, [:], "核心不给了：不再交给本体")
    }

    func testPageButtonGoesToTheHost() {
        let b = Recorder()
        let (m, h) = hosted(b)
        let key = AgentFeed.pageKey("a", "p")
        m.pageHostAsks[key] = HostAsk(app: "a", id: "fda", button: "b1")
        m.tapSurface(key, componentId: "b1", context: .object([:]))
        XCTAssertEqual(h.calls, ["ask a fda"])
        XCTAssertEqual(b.calls, [])
        m.tapSurface(key, componentId: "b2", context: .object([:]))
        XCTAssertEqual(b.calls, ["action \(key) b2"], "别的按钮照旧转给工具")
    }

    func testButtonThatNeedsAPermissionRunsOnceTheHostSaysSo() {
        let b = Recorder()
        let (m, h) = hosted(b)
        let key = AgentFeed.pageKey("a", "p")
        m.pageHostAsks[key] = HostAsk(app: "a", id: "photos", button: "b1", then: true)
        m.tapSurface(key, componentId: "b1", context: .object([:]))
        XCTAssertEqual(h.calls, ["ready a photos"])
        XCTAssertEqual(b.calls, [], "用户还没给：活不转给工具")
        h.ready?()
        XCTAssertEqual(b.calls, ["action \(key) b1"], "本体说够了才转")
        b.calls = []
        m.tapSurface(key, componentId: "b1", context: .object([:]))
        m.pageHostAsks[key] = HostAsk(app: "a", id: "photos", button: "b7", then: true)
        h.ready?()
        XCTAssertEqual(b.calls, ["action \(key) b7"], "等的时候页重画了：按现在这一页的按钮转")
    }

    func testPageHostAskFollowsThePage() {
        let m = Sample.model()
        let f = AgentFeed(model: m)
        keep.append(f)
        let key = AgentFeed.pageKey("a", "p")
        func page(_ ask: String) {
            f.applyPage(app: "a", page: "p", status: 200, body: Data(#"{"messages": []\#(ask)}"#.utf8))
        }
        page(#", "host_ask": {"permission": "fda", "button": "b1"}"#)
        XCTAssertEqual(m.pageHostAsks[key], HostAsk(app: "a", id: "fda", button: "b1"))
        page("")
        XCTAssertNil(m.pageHostAsks[key], "这一页不再要了：不再交给本体")
    }

    func testUseSwitchIsPerApp() {
        let b = Recorder()
        let (m, h) = hosted(b)
        let fda = row(m, "luoke-scan", "fda")
        XCTAssertTrue(m.hostPermissionOn(fda), "本体没报时不说没放行")
        m.reportHostPermissions([:], confirmed: [:])
        XCTAssertEqual(m.hostConfirmed, [:])
        XCTAssertFalse(m.hostPermissionOn(fda), "用户同意了才放行")
        m.setHostPermission(fda, on: false)
        XCTAssertEqual(h.calls, [], "没变不交")
        m.setHostPermission(fda, on: true)
        XCTAssertEqual(h.calls, ["ask luoke-scan fda"], "扳开先出本体的窗口")
        XCTAssertFalse(m.hostPermissionOn(fda), "用户在窗口里确认了才算开")
        m.reportHostPermissions([:], confirmed: ["luoke-scan": ["fda": "2026-11-06T10:00:00Z"]])
        XCTAssertNotNil(m.hostConfirmed?["luoke-scan#fda"], "键同 AgentPermission.id")
        XCTAssertTrue(m.hostPermissionOn(fda))
        m.setHostPermission(fda, on: false)
        XCTAssertEqual(h.calls.last, "use luoke-scan fda false")
        XCTAssertEqual(m.hostConfirmed, [:])

        h.calls = []
        m.setHostPermission(row(m, "luoke-mail", "contacts"), on: true)
        m.setHostPermission(luokeRow(can: [], kind: "delegate"), on: true)
        XCTAssertEqual(h.calls, [], "只有螺壳名下的系统权限有这个开关")

        m.reportHostPermissions([:], confirmed: ["luoke-scan": ["fda": "2026-11-06T07:00:00Z"]])
        XCTAssertTrue(m.hostPermissionOn(fda), "本体给的")
        XCTAssertEqual(h.calls, [], "本体给的不再交回本体")
        XCTAssertFalse(AgentPermissionsTab.hostOffText.contains("系统"), "这是约定：不说系统拦着")
    }

    func testErrorsShowAsToast() {
        let (m, _) = fed(backend: Recorder())
        m.permissionAnswered(app: "luoke-mail", id: "auto", op: "on", text: "这一项现在不能这样改。", error: true)
        XCTAssertEqual(m.toast?.text, "这一项现在不能这样改。")
        m.permissionAnswered(app: "luoke-mail", id: "auto", op: "on", text: "", error: true)
        XCTAssertEqual(m.toast?.text, "没改成。")
        XCTAssertEqual(AgentConnection.answer(0, Data()).0, "没连上螺壳的核心。")
        XCTAssertTrue(AgentConnection.answer(400, Data(#"{"error":"要有 app、id 和 op"}"#.utf8)).1)
        XCTAssertEqual(AgentConnection.answer(400, Data(#"{"error":"要有 app、id 和 op"}"#.utf8)).0, "要有 app、id 和 op")
        XCTAssertFalse(AgentConnection.answer(200, Data(#"{"text":"好","error":false}"#.utf8)).1)
    }

    func testHostReportGoesToTheBackend() {
        let b = Recorder()
        let (m, _) = fed(backend: b)
        m.reportHostPermissions(["fda": .granted])
        m.reportHostPermissions(["fda": nil])
        XCTAssertEqual(b.calls, [#"host {"fda":"granted"}"#, #"host {"fda":null}"#])
    }

    // MARK: 没接核心

    func testSampleUnchangedWithoutTheCore() {
        let m = Sample.model()
        XCTAssertNil(m.agentApps)
        XCTAssertNil(m.agentPermissions)
        m.go(.scan)
        XCTAssertNil(m.agentApp(for: .scan))
        XCTAssertNotNil(m.appPages[.scan], "螺壳扫描画示例")
        m.openAppUI()
        m.reportHostPermissions(["fda": .granted])
        XCTAssertEqual(m.permissions.map(\.state), [.waiting, .granted, .notYet], "示例的权限不动")
        m.requestPermission("calendar")
        m.continueSheet()
        XCTAssertEqual(m.permissions.first?.state, .granted, "示例里「继续」照旧直接算允许了")
    }

    // MARK: 走真的 socket

    /// 假核心答 /apps、页、/open、/permissions、/host，推 apps 事件
    func testAppsAndPermissionsOverTheSocket() throws {
        let path = "/tmp/lkw-apps-\(getpid()).sock"
        let core = try MiniCore(path: path, events: Sample.agentEvents(),
                                settings: Sample.agentEvents().first { $0.0 == "settings" }!.1)
        defer { core.stop() }
        core.route("GET", "/apps", Sample.agentApps())
        core.route("GET", "/apps/luoke-scan/pages/overview", Sample.agentPage("luoke-scan", "overview")!)
        core.route("GET", "/permissions", Sample.agentPermissions())
        core.route("POST", "/open", Data(#"{"text":"邮件助手打开了自己的窗口。","error":false}"#.utf8))
        core.route("POST", "/permissions", Data(#"{"text":"这一项现在不能这样改。","error":true}"#.utf8))
        core.route("POST", "/host", Data("{}".utf8))
        let m = Sample.model()
        let c = AgentConnection(socketPath: path, model: m)
        c.start()
        defer { c.stop() }
        XCTAssertTrue(wait { m.agentApps?.count == 2 }, "连上时取了应用列表")

        m.go(.scan)
        XCTAssertTrue(wait { m.agentPages["luoke-scan/page/overview"]?.surface != nil }, "打开应用页时取了那一页")
        XCTAssertTrue(wait { m.agentPermissions != nil }, "缺权限：取了权限好写名字")
        let pageGets = core.gets("/apps/luoke-scan/pages/overview")

        core.push("apps", Data(#"{"app":"luoke-scan"}"#.utf8))
        XCTAssertTrue(wait { core.gets("/apps") >= 2 && core.gets("/apps/luoke-scan/pages/overview") > pageGets },
                      "apps 事件：重新取列表和正看着的页")

        let before = core.gets("/apps/luoke-scan/pages/overview")
        m.tapSurface("luoke-scan/page/overview", componentId: "b1", context: .object([:]))
        XCTAssertTrue(wait { core.posted("/action") != nil })
        XCTAssertEqual(try JSONValue.parse(core.posted("/action")!)["surfaceId"], .string("luoke-scan/page/overview"))
        XCTAssertTrue(wait { core.gets("/apps/luoke-scan/pages/overview") > before }, "页上点完重新取这一页")

        m.openAppUI()
        XCTAssertTrue(core.posts("/open").isEmpty, "扫描没有自己的界面：不发 /open")
        m.go(.mail)
        m.openAppUI()
        XCTAssertTrue(wait { m.toast?.text == "邮件助手打开了自己的窗口。" })
        XCTAssertEqual(try JSONValue.parse(core.posted("/open")!), .object(["app": .string("luoke-mail")]))
        m.openAppUI(page: "accounts")
        XCTAssertTrue(wait { core.posts("/open").count == 2 })
        XCTAssertEqual(try JSONValue.parse(core.posts("/open")[1]), .object(["app": .string("luoke-mail"), "page": .string("accounts")]))

        m.go(.prefs, tab: PrefsTab.permissions.rawValue)
        XCTAssertTrue(core.posts("/permissions").isEmpty, "只看不点：不改")
        let permGets = core.gets("/permissions")
        m.permissionAction(row(m, "luoke-scan", "fda"), "settings")
        XCTAssertTrue(wait { m.toast?.text == "这一项现在不能这样改。" }, "核心说不行：底部提示")
        XCTAssertEqual(try JSONValue.parse(core.posted("/permissions")!),
                       .object(["app": .string("luoke-scan"), "id": .string("fda"), "op": .string("settings")]))
        XCTAssertTrue(wait { m.permissionPending.isEmpty && core.gets("/permissions") > permGets }, "答了以后照核心的状态重画")

        m.reportHostPermissions(["fda": .granted])
        XCTAssertTrue(wait { core.posted("/host") != nil })
        XCTAssertEqual(try JSONValue.parse(core.posted("/host")!), .object(["permissions": .object(["fda": .string("granted")])]))
    }

    /// 螺壳.app 报过的权限记在内存里：核心重启、重新连上时整份再报；报了 null 的不再报
    func testHostReportIsResentOnReconnect() {
        final class Log: @unchecked Sendable {
            let lock = NSLock()
            var hosts: [Data] = []
            func add(_ d: Data) { lock.lock(); hosts.append(d); lock.unlock() }
            var count: Int { lock.lock(); defer { lock.unlock() }; return hosts.count }
            var last: Data? { lock.lock(); defer { lock.unlock() }; return hosts.last }
        }
        let log = Log()
        let m = WindowModel()
        let c = AgentConnection(model: m) { method, path, body in
            if method == "POST" && path == "/host" { log.add(body ?? Data()) }
            return (200, Data("{}".utf8))
        }
        m.reportHostPermissions(["fda": .granted, "calendar": .ask])
        XCTAssertTrue(wait { log.count == 1 })
        c.setConnected(true)
        XCTAssertTrue(wait { log.count == 2 })
        XCTAssertEqual(try JSONValue.parse(log.last!), .object(["permissions": .object(["fda": .string("granted"), "calendar": .string("ask")])]))
        m.reportHostPermissions(["calendar": nil])
        XCTAssertTrue(wait { log.count == 3 })
        c.setConnected(false)
        c.setConnected(true)
        XCTAssertTrue(wait { log.count == 4 })
        XCTAssertEqual(try JSONValue.parse(log.last!), .object(["permissions": .object(["fda": .string("granted")])]))
    }

    private func wait(_ ok: () -> Bool) -> Bool {
        for _ in 0..<200 {
            if ok() { return true }
            RunLoop.main.run(until: Date().addingTimeInterval(0.025))
        }
        return ok()
    }
}
