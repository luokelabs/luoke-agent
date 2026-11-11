import Foundation
import LuokeA2UI
import LuokeA2UICore
import XCTest
@testable import LuokeWindow

/// 应用页 2026-11-10 加的几样（工具协议 §4、界面接口 §4、§6）：页带参数、密码框、页的刷新、存文件。
@MainActor
final class PageAdditionsTests: XCTestCase {
    /// 记下发出去的请求（方法、路径、正文）；答复按路径给
    final class Wire: @unchecked Sendable {
        let lock = NSLock()
        var sent: [(String, String, Data)] = []
        var replies: [String: Data] = [:]
        func add(_ m: String, _ p: String, _ d: Data) { lock.lock(); sent.append((m, p, d)); lock.unlock() }
        func paths(_ method: String) -> [String] { lock.lock(); defer { lock.unlock() }; return sent.filter { $0.0 == method }.map(\.1) }
        func bodies(_ path: String) -> [Data] { lock.lock(); defer { lock.unlock() }; return sent.filter { $0.1 == path }.map(\.2) }
        func set(_ path: String, _ d: Data) { lock.lock(); replies[path] = d; lock.unlock() }
        func reply(_ path: String) -> Data {
            lock.lock(); defer { lock.unlock() }
            let base = path.split(separator: "?").first.map(String.init) ?? path
            return replies[path] ?? replies[base] ?? Data("{}".utf8)
        }
    }

    private func connected() -> (WindowModel, AgentConnection, Wire) {
        let wire = Wire()
        let m = Sample.model()
        let c = AgentConnection(model: m) { method, path, body in
            wire.add(method, path, body ?? Data())
            return (200, wire.reply(path))
        }
        Sample.applyAgentApps(c.feed)
        for p in ToolSample.load("luoke-scan", ToolSample.defaultScan)?.pageIDs ?? [] {     // 再取时答示例里的那一页
            if let d = Sample.agentPage("luoke-scan", p) { wire.set("/apps/luoke-scan/pages/\(p)", d) }
        }
        return (m, c, wire)
    }

    private func wait(_ ok: () -> Bool) -> Bool {
        for _ in 0..<200 {
            if ok() { return true }
            RunLoop.main.run(until: Date().addingTimeInterval(0.025))
        }
        return ok()
    }

    /// 一页的答复（`{"messages": [...]}`）
    private func page(_ sid: String, _ components: String, data: String = "{}") -> Data {
        Data(#"""
        {"messages": [
          {"version": "v0.9", "createSurface": {"surfaceId": "\#(sid)", "catalogId": "ai.luoke/a2ui/agent/1"}},
          {"version": "v0.9", "updateComponents": {"surfaceId": "\#(sid)", "components": \#(components)}},
          {"version": "v0.9", "updateDataModel": {"surfaceId": "\#(sid)", "path": "/", "value": \#(data)}}]}
        """#.utf8)
    }

    // MARK: 页带参数（pageArgs）

    func testActionAnswerCarriesArgs() throws {
        let got = try XCTUnwrap(AgentConnection.openedPage(Data(#"{"text": "", "error": false, "page": {"app": "luoke-scan", "page": "cleaned", "args": {"cursor": "2"}}}"#.utf8)))
        XCTAssertEqual(got.0, "luoke-scan")
        XCTAssertEqual(got.1, "cleaned")
        XCTAssertEqual(got.2, ["cursor": "2"])
        XCTAssertEqual(try XCTUnwrap(AgentConnection.openedPage(Data(#"{"page": {"app": "a", "page": "p"}}"#.utf8))).2, [:])
        XCTAssertNil(AgentConnection.openedPage(Data(#"{"page": {"app": "a", "page": "p", "args": {"Q": "1"}}}"#.utf8)), "参数不对：整个不认")
        XCTAssertNil(AgentConnection.openedPage(Data(#"{"page": {"app": "a", "page": "p", "args": {"q": 1}}}"#.utf8)))
    }

    func testOpenPageWithArgsReadsThePageWithThem() {
        let (m, c, wire) = connected()
        defer { withExtendedLifetime(c) {} }       // 窗口只弱引用它
        m.openAgentPage(app: "luoke-scan", page: "cleaned", args: ["q": "发票 x+y", "cursor": "2"])
        XCTAssertEqual(m.page, .scan)
        XCTAssertEqual(m.appTab, "cleaned")
        XCTAssertEqual(m.pageArgs["luoke-scan/page/cleaned"], ["q": "发票 x+y", "cursor": "2"])
        let withArgs = "/apps/luoke-scan/pages/cleaned?cursor=2&q=%E5%8F%91%E7%A5%A8%20x%2By"
        XCTAssertTrue(wait { wire.paths("GET").contains(withArgs) }, "\(wire.paths("GET"))")
        m.retryPage()
        XCTAssertTrue(wait { wire.paths("GET").filter { $0 == withArgs }.count == 2 }, "这一页开着时再取都带上")
        m.selectAppTab("cleaned")
        XCTAssertNil(m.pageArgs["luoke-scan/page/cleaned"], "用户在页列表里点这一页：参数没了")
        XCTAssertTrue(wait { wire.paths("GET").last == "/apps/luoke-scan/pages/cleaned" })
        m.openAgentPage(app: "luoke-scan", page: "cleaned", args: ["cursor": "3"])
        m.go(.today)
        m.go(.scan, tab: "cleaned")
        XCTAssertNil(m.pageArgs["luoke-scan/page/cleaned"], "从侧栏、菜单回来：不带")
    }

    func testAnAnswerForOtherArgsIsDropped() throws {
        let (m, c, _) = connected()
        m.openAgentPage(app: "luoke-scan", page: "cleaned", args: ["cursor": "3"])
        let sid = "luoke-scan/page/cleaned"
        let before = m.agentPages[sid]?.surface?.surface.components.count
        c.feed.applyPage(app: "luoke-scan", page: "cleaned", status: 200,
                         body: page(sid, #"[{"id": "root", "component": "Text", "text": "第 2 页"}]"#), args: ["cursor": "2"])
        XCTAssertEqual(m.agentPages[sid]?.surface?.surface.components.count, before, "参数已经换了：这份不要")
        c.feed.applyPage(app: "luoke-scan", page: "cleaned", status: 200,
                         body: page(sid, #"[{"id": "root", "component": "Text", "text": "第 3 页"}]"#), args: ["cursor": "3"])
        XCTAssertEqual(m.agentPages[sid]?.surface?.surface.components["root"]?["text"]?.string, "第 3 页")
    }

    // MARK: 只由 agent.open_page 去的页（hidden）

    /// 应用列表里换成带 `hidden` 页的扫描（`/apps` 的形状，界面接口 §6）
    private func scanPages(_ pages: String) throws -> JSONValue {
        try JSONValue.parse(Data(#"{"apps": [{"id": "luoke-scan", "running": true, "summary": null, "pages": \#(pages), "ui": null, "needs": []}]}"#.utf8))
    }

    func testHiddenPageIsNotATabButOpenPageReachesIt() throws {
        let (m, c, wire) = connected()
        defer { withExtendedLifetime(c) {} }
        c.feed.applyApps(try scanPages(#"[{"id": "overview", "title": "概览"}, {"id": "cleaned", "title": "清理记录"}, {"id": "item", "title": "一项", "hidden": true}]"#))
        let app = try XCTUnwrap(m.agentApps?.first { $0.id == "luoke-scan" })
        XCTAssertEqual(app.pages.map(\.hidden), [false, false, true])
        XCTAssertEqual(app.firstPage, "overview")
        XCTAssertEqual(AgentAppBody.tabs(app).map(\.id), ["overview", "cleaned"], "hidden 的不画成标签")
        m.go(.scan)
        XCTAssertEqual(m.agentTab(app), "overview")
        m.openAgentPage(app: "luoke-scan", page: "item", args: ["id": "f-1"])
        XCTAssertEqual(m.page, .scan)
        XCTAssertEqual(m.agentTab(app), "item", "agent.open_page 去得了")
        XCTAssertEqual(m.visibleAgentPageKey, "luoke-scan/page/item")
        XCTAssertTrue(wait { wire.paths("GET").contains("/apps/luoke-scan/pages/item?id=f-1") }, "\(wire.paths("GET"))")
        XCTAssertEqual(AgentAppBody.tabs(app, current: "item").map(\.id), ["overview", "cleaned", "item"],
                       "正看着它：临时排在最后，是选中的那个")
        m.selectAppTab("cleaned")
        XCTAssertEqual(m.agentTab(app), "cleaned", "点别的标签就离开")
        XCTAssertEqual(AgentAppBody.tabs(app, current: m.agentTab(app)).map(\.id), ["overview", "cleaned"])
        m.go(.today)
        m.go(.scan)
        XCTAssertEqual(m.agentTab(app), "overview", "从侧栏回来：第一个画成标签的页")
    }

    func testAllPagesHiddenShowsNoPageUntilOpened() throws {
        let (m, c, wire) = connected()
        defer { withExtendedLifetime(c) {} }
        c.feed.applyApps(try scanPages(#"[{"id": "item", "title": "一项", "hidden": true}]"#))
        let app = try XCTUnwrap(m.agentApps?.first { $0.id == "luoke-scan" })
        XCTAssertNil(app.firstPage)
        m.go(.scan)
        XCTAssertNil(m.agentTab(app), "没有画成标签的页：只有「这个应用」")
        XCTAssertNil(m.visibleAgentPageKey)
        XCTAssertTrue(AgentAppBody.tabs(app).isEmpty)
        m.openAgentPage(app: "luoke-scan", page: "item")
        XCTAssertEqual(m.agentTab(app), "item")
        XCTAssertTrue(wait { wire.paths("GET").contains("/apps/luoke-scan/pages/item") })
        XCTAssertEqual(AgentAppBody.tabs(app, current: "item").count, 1, "只有它一个：不画标签行")
    }

    func testHiddenOnlyWhenTrue() throws {
        let apps = try scanPages(#"[{"id": "a", "title": "甲", "hidden": false}, {"id": "b", "title": "乙", "hidden": "yes"}]"#)
        let app = try XCTUnwrap(AgentFeed.app(try XCTUnwrap(apps["apps"]?.array?.first)))
        XCTAssertEqual(app.pages.map(\.hidden), [false, false])
    }

    // MARK: 页的刷新（pageRefresh）

    func testRefreshRereadsOnlyWhileThePageIsSeen() {
        let (m, c, wire) = connected()
        var later: [(TimeInterval, @MainActor () -> Void)] = []
        c.after = { later.append(($0, $1)) }
        let sid = "luoke-scan/page/overview"
        wire.set("/apps/luoke-scan/pages/overview", page(sid, #"[{"id": "root", "component": "Text", "text": "清理中…", "refresh": 5}]"#))
        c.reportWindow(open: true, front: true)
        m.go(.scan)
        let reads = { wire.paths("GET").filter { $0 == "/apps/luoke-scan/pages/overview" }.count }
        XCTAssertTrue(wait { reads() == 1 && later.count == 1 })
        XCTAssertEqual(later[0].0, 5)
        later.removeFirst().1()
        XCTAssertTrue(wait { reads() == 2 && later.count == 1 }, "看得见：再取一次，再定下一次")
        m.go(.today)
        later.removeFirst().1()
        RunLoop.main.run(until: Date().addingTimeInterval(0.2))
        XCTAssertEqual(reads(), 2, "换了页：不取")
        m.go(.scan)
        XCTAssertTrue(wait { reads() == 3 && later.count == 1 }, "回来照常取，接着定")
        c.reportWindow(open: false, front: false)
        later.removeFirst().1()
        RunLoop.main.run(until: Date().addingTimeInterval(0.2))
        XCTAssertEqual(reads(), 3, "窗口关了：不取")
        wire.set("/apps/luoke-scan/pages/overview", page(sid, #"[{"id": "root", "component": "Text", "text": "清完了"}]"#))
        c.reportWindow(open: true, front: true)
        m.retryPage()
        XCTAssertTrue(wait { reads() == 4 })
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        XCTAssertTrue(later.isEmpty, "做完了不写 refresh：不再定")
    }

    // MARK: 密码框（secureField）

    private let secureComponents = #"""
    [{"id": "root", "component": "Column", "children": ["f", "b"]},
     {"id": "f", "component": "TextField", "label": "IMAP 授权码", "variant": "obscured", "value": {"path": "/fields/code"}},
     {"id": "b", "component": "Button", "child": "bt", "action": {"event": {"name": "mail_connect", "context": {"code": {"path": "/fields/code"}}}}},
     {"id": "bt", "component": "Text", "text": "加上"}]
    """#

    func testSecureFieldGoesOnceAndIsCleared() throws {
        let (m, c, wire) = connected()
        let sid = "luoke-scan/page/overview"
        wire.set("/apps/luoke-scan/pages/overview", page(sid, secureComponents, data: #"{"fields": {"code": ""}}"#))
        m.go(.scan)
        XCTAssertTrue(wait { m.agentPages[sid]?.surface?.surface.secureFieldPaths == ["/fields/code"] })
        let s = try XCTUnwrap(m.agentPages[sid]?.surface)
        s.set("/fields/code", .string("abcd-efgh"))
        c.action(surfaceId: sid, componentId: "b", context: try s.surface.action("b").context)
        XCTAssertEqual(s.value("/fields/code"), .string(""), "交了就清掉，不等答复")
        XCTAssertTrue(wait { wire.bodies("/action").count == 1 })
        XCTAssertEqual(try JSONValue.parse(wire.bodies("/action")[0])["context"]?["code"], .string("abcd-efgh"), "只随这一次交出去")
        XCTAssertTrue(wait { wire.paths("GET").filter { $0 == "/apps/luoke-scan/pages/overview" }.count == 2 }, "点完重新取这一页")
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        let now = try XCTUnwrap(m.agentPages[sid]?.surface)
        now.set("/fields/code", .string("wxyz"))
        m.go(.today)
        XCTAssertEqual(now.value("/fields/code"), .string(""), "离开这一页：清掉")
    }

    /// 点下去、在等答复：记下是哪个按钮（它画转圈），答复回来就清掉（luoke-scan#152）
    func testPressedButtonIsKnownUntilTheAnswer() throws {
        let (m, c, wire) = connected()
        let sid = "luoke-scan/page/overview"
        wire.set("/apps/luoke-scan/pages/overview", page(sid, secureComponents, data: #"{"fields": {"code": ""}}"#))
        m.go(.scan)
        XCTAssertTrue(wait { m.agentPages[sid]?.surface?.surface.secureFieldPaths == ["/fields/code"] })
        let s = try XCTUnwrap(m.agentPages[sid]?.surface)
        c.action(surfaceId: sid, componentId: "b", context: try s.surface.action("b").context)
        XCTAssertTrue(s.busy)
        XCTAssertEqual(s.pressed, "b")
        XCTAssertTrue(wait { wire.bodies("/action").count == 1 && !s.busy })
        XCTAssertNil(s.pressed)
    }

    /// 点完只清这次交出去的那个框（按钮正好引用的），没交的照留（点完重新取这一页也留）；离开这一页全清
    func testOnlyTheSentSecureFieldIsCleared() throws {
        let (m, c, wire) = connected()
        let sid = "luoke-scan/page/overview"
        let comps = #"""
        [{"id": "root", "component": "Column", "children": ["code", "pin", "b", "f"]},
         {"id": "code", "component": "TextField", "label": "IMAP 授权码", "variant": "obscured", "value": {"path": "/fields/code"}},
         {"id": "pin", "component": "TextField", "label": "SMTP 授权码", "variant": "obscured", "value": {"path": "/fields/pin"}},
         {"id": "b", "component": "Button", "child": "bt", "action": {"event": {"name": "mail_connect", "context": {"code": {"path": "/fields/code"}}}}},
         {"id": "bt", "component": "Text", "text": "加上"},
         {"id": "f", "component": "Button", "child": "ft", "action": {"event": {"name": "mail_find", "context": {"q": {"path": "/q"}}}}},
         {"id": "ft", "component": "Text", "text": "试一下"}]
        """#
        wire.set("/apps/luoke-scan/pages/overview", page(sid, comps, data: #"{"fields": {"code": "", "pin": ""}, "q": "发票"}"#))
        let reads = { wire.paths("GET").filter { $0 == "/apps/luoke-scan/pages/overview" }.count }
        m.go(.scan)
        XCTAssertTrue(wait { m.agentPages[sid]?.surface?.surface.secureFieldPaths.count == 2 })
        let s = try XCTUnwrap(m.agentPages[sid]?.surface)
        s.set("/fields/code", .string("abcd-efgh"))
        s.set("/fields/pin", .string("1234"))
        c.action(surfaceId: sid, componentId: "f", context: try s.surface.action("f").context)
        XCTAssertEqual(s.value("/fields/code"), .string("abcd-efgh"), "没交出去的不清")
        XCTAssertTrue(wait { wire.bodies("/action").count == 1 && reads() == 2 })
        XCTAssertEqual(try JSONValue.parse(wire.bodies("/action")[0])["context"], try JSONValue.parse(#"{"q": "发票"}"#),
                       "没引用密码框的按钮：一个都不交")
        XCTAssertTrue(wait { m.agentPages[sid]?.surface !== s })
        let now = try XCTUnwrap(m.agentPages[sid]?.surface)
        XCTAssertEqual(now.value("/fields/code"), .string("abcd-efgh"), "点完重新取这一页：没交出去的照留")
        XCTAssertEqual(now.value("/fields/pin"), .string("1234"))
        XCTAssertEqual(s.value("/fields/code"), .string(""), "换下来的那份不留字")
        c.action(surfaceId: sid, componentId: "b", context: try now.surface.action("b").context)
        XCTAssertEqual(now.value("/fields/code"), .string(""), "交了的清掉")
        XCTAssertEqual(now.value("/fields/pin"), .string("1234"), "这个按钮没交的照留")
        XCTAssertTrue(wait { wire.bodies("/action").count == 2 && reads() == 3 })
        XCTAssertEqual(try JSONValue.parse(wire.bodies("/action")[1])["context"]?["code"], .string("abcd-efgh"))
        XCTAssertTrue(wait { m.agentPages[sid]?.surface !== now })
        let later = try XCTUnwrap(m.agentPages[sid]?.surface)
        XCTAssertEqual(later.value("/fields/code"), .string(""))
        XCTAssertEqual(later.value("/fields/pin"), .string("1234"))
        m.go(.today)
        XCTAssertEqual(later.value("/fields/pin"), .string(""), "离开这一页：全清")
    }

    func testSecureFieldOnlyOnPages() throws {
        let msgs = try XCTUnwrap(try JSONValue.parse(page("s", secureComponents, data: #"{"fields": {"code": ""}}"#))["messages"]?.array)
        XCTAssertNoThrow(try Surface.build(msgs, page: true))
        XCTAssertThrowsError(try Surface.build(msgs), "卡片上不认")
    }

    // MARK: 存文件（saveFile）

    func testFileInTheAnswerGoesToTheSavePanel() throws {
        let (m, c, wire) = connected()
        var saved: [(String, String)] = []
        c.fileSaver = { saved.append(($0, $1)) }
        wire.set("/action", Data(#"{"text": "规则文件好了，选个位置存。", "error": false, "file": {"name": "gmail-filters.xml", "mediaType": "application/xml", "text": "<feed/>"}}"#.utf8))
        let sid = "luoke-scan/page/overview"
        let reads = { wire.paths("GET").filter { $0 == "/apps/luoke-scan/pages/overview" }.count }
        m.go(.scan)
        XCTAssertTrue(wait { reads() == 1 })
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        let s = try XCTUnwrap(m.agentPages[sid]?.surface)
        let button = try XCTUnwrap(s.surface.reachable().first { s.surface.components[$0]?["component"]?.string == "Button" })
        c.action(surfaceId: sid, componentId: button, context: .object([:]))
        XCTAssertTrue(wait { saved.count == 1 })
        XCTAssertEqual(saved[0].0, "gmail-filters.xml")
        XCTAssertEqual(saved[0].1, "<feed/>")
        XCTAssertTrue(wait { reads() == 2 }, "点完照常重新取这一页")
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        wire.set("/action", Data(#"{"text": "好了。", "error": false, "file": {"name": "../.zshrc", "mediaType": "text/plain", "text": "x"}}"#.utf8))
        c.action(surfaceId: sid, componentId: button, context: .object([:]))
        XCTAssertTrue(wait { wire.bodies("/action").count == 2 && reads() == 3 })
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        XCTAssertEqual(saved.count, 1, "名字不对：不存")
        XCTAssertNil(AgentConnection.savedFile(Data(#"{"text": "好"}"#.utf8)))
        XCTAssertNotNil(AgentConnection.savedFile(Data(#"{"file": {"name": "a.xml", "mediaType": "application/xml", "text": "x"}}"#.utf8)))
    }
}
