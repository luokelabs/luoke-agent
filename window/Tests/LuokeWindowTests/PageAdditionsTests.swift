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

    // MARK: 页上的点按排队（负责人 11-17：归档一封时别的操作不该都被禁用）

    private func buttons(_ list: [(String, String)], nav: Bool = true) -> String {
        var comps = [#"{"id": "root", "component": "Column", "children": [\#((list.map { "\"\($0.0)\"" } + (nav ? ["\"go\""] : [])).joined(separator: ", "))]}"#]
        for (id, mail) in list {
            comps.append(#"{"id": "\#(id)", "component": "Button", "child": "\#(id)-t", "action": {"event": {"name": "tool_do", "context": {"mail": "\#(mail)"}}}}"#)
            comps.append(#"{"id": "\#(id)-t", "component": "Text", "text": "归档"}"#)
        }
        if nav {
            comps.append(#"{"id": "go", "component": "Button", "child": "go-t", "action": {"event": {"name": "agent.open_page", "context": {"page": "cleaned"}}}}"#)
            comps.append(#"{"id": "go-t", "component": "Text", "text": "待处理"}"#)
        }
        return "[" + comps.joined(separator: ", ") + "]"
    }

    func testTapsOnAPageQueueAndFindTheirButtonsAgain() throws {
        let gate = DispatchSemaphore(value: 0)
        let wire = Wire()
        let m = Sample.model()
        let c = AgentConnection(model: m) { method, path, body in
            wire.add(method, path, body ?? Data())
            if path == "/action", !String(decoding: body ?? Data(), as: UTF8.self).contains(#""go""#) { gate.wait() }
            return (200, wire.reply(path))
        }
        defer { withExtendedLifetime(c) {} }
        Sample.applyAgentApps(c.feed)
        let sid = "luoke-scan/page/overview", path = "/apps/luoke-scan/pages/overview"
        wire.set(path, page(sid, buttons([("b1", "a"), ("b2", "b"), ("b3", "c")])))
        m.go(.scan, tab: "overview")
        XCTAssertTrue(wait { m.agentPages[sid]?.surface?.surface.components["b3"] != nil })
        let s = try XCTUnwrap(m.agentPages[sid]?.surface)
        XCTAssertTrue(s.queues)
        func tap(_ id: String) throws {
            let now = try XCTUnwrap(m.agentPages[sid]?.surface)
            c.action(surfaceId: sid, componentId: id, context: try now.surface.action(id).context)
        }
        func sentIDs() -> [String] {
            wire.bodies("/action").compactMap { (try? JSONValue.parse($0))?["sourceComponentId"]?.string }
        }
        try tap("b1")
        try tap("b2")
        try tap("b3")
        try tap("b2")
        XCTAssertTrue(s.busy && !s.locked, "在等答复，别的按钮不灰")
        XCTAssertEqual(s.queued, ["b2", "b3"], "后点的排着，同一个不排两次")
        XCTAssertTrue(s.waiting("b1") && s.waiting("b2") && !s.waiting("go"))
        try tap("go")
        XCTAssertTrue(wait { sentIDs() == ["b1", "go"] }, "换页不排队，前一个还在做也照发：\(sentIDs())")
        // 第一封做完，页重新取：a 不在了，b 的按钮换了编号，c 也不在了
        wire.set(path, page(sid, buttons([("x1", "b")])))
        gate.signal()
        XCTAssertTrue(wait { sentIDs() == ["b1", "go", "x1"] }, "排着的在新的页上重新找到按钮再发：\(sentIDs())")
        XCTAssertTrue(wait { m.toast?.text == "1 项操作的对象已变化，未执行" }, "找不到的不发，说一声：\(m.toast?.text ?? "")")
        XCTAssertEqual(m.agentPages[sid]?.surface?.queued, [])
        gate.signal()
        XCTAssertTrue(wait { m.agentPages[sid]?.surface?.busy == false && wire.paths("GET").filter { $0 == path }.count >= 3 })
        XCTAssertEqual(sentIDs().count, 3, "队列空了，不再发")
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

    func testOpeningADialogKeepsTheArgsOfThePageUnderIt() throws {
        let (m, c, _) = connected()
        defer { withExtendedLifetime(c) {} }
        c.feed.applyApps(try scanPages(#"[{"id": "overview", "title": "概览"}, {"id": "cleaned", "title": "清理记录"}, {"id": "item", "title": "一项", "hidden": true}]"#))
        m.openAgentPage(app: "luoke-scan", page: "cleaned", args: ["group": "todo", "cursor": "2"])
        m.openAgentPage(app: "luoke-scan", page: "item", args: ["id": "f-1"])
        XCTAssertEqual(m.pageArgs["luoke-scan/page/cleaned"], ["group": "todo", "cursor": "2"], "弹窗底下那一页的参数留着")
        XCTAssertTrue(wait { m.agentPages["luoke-scan/page/item"] != nil }, "弹窗的内容取到了")
        m.openAgentPage(app: "luoke-scan", page: "item", args: ["id": "f-2"])
        XCTAssertNotNil(m.agentPages["luoke-scan/page/item"], "弹窗开着时在里面换参数：留着现在的内容等新的，不闪「正在加载」")
        XCTAssertEqual(m.pageArgs["luoke-scan/page/item"], ["id": "f-2"])
        m.closeAppDialog()
        m.openAgentPage(app: "luoke-scan", page: "item", args: ["id": "f-3"])
        XCTAssertNil(m.agentPages["luoke-scan/page/item"], "关了再开另一项：上一项的内容不留着顶")
        XCTAssertEqual(m.pageArgs["luoke-scan/page/cleaned"], ["group": "todo", "cursor": "2"], "弹窗里再开一个弹窗也留着")
        m.closeAppDialog()
        XCTAssertEqual(m.visibleAppTab, "cleaned")
        XCTAssertEqual(m.pageArgs["luoke-scan/page/cleaned"], ["group": "todo", "cursor": "2"])
        m.openAgentPage(app: "luoke-scan", page: "overview")
        XCTAssertNil(m.pageArgs["luoke-scan/page/cleaned"], "去别的标签：不留")
    }

    func testNestedAppDialogsKeepReturnStackAndArgs() throws {
        let (m, c, _) = connected()
        defer { withExtendedLifetime(c) {} }
        c.feed.applyApps(try scanPages(#"[{"id": "overview", "title": "概览"}, {"id": "subs", "title": "订阅体检", "hidden": true}, {"id": "sender", "title": "发件人", "hidden": true}]"#))
        m.openAgentPage(app: "luoke-scan", page: "overview")
        m.openAgentPage(app: "luoke-scan", page: "subs", args: ["group": "unsubscribe"])
        XCTAssertFalse(m.canGoBackInAppDialog, "第一层弹窗没有上一级弹窗")
        m.openAgentPage(app: "luoke-scan", page: "sender", args: ["key": "news@example.com"])
        XCTAssertTrue(m.canGoBackInAppDialog, "从弹窗打开另一个弹窗后可返回上一级")
        XCTAssertEqual(m.appDialog?.page.id, "sender")
        m.popAppDialog()
        XCTAssertEqual(m.appDialog?.page.id, "subs", "返回到上一张弹窗")
        XCTAssertEqual(m.pageArgs["luoke-scan/page/subs"], ["group": "unsubscribe"], "上一张弹窗的参数一并恢复")
        XCTAssertFalse(m.canGoBackInAppDialog)
        // 再进一层后点关闭：直接清空栈回到主标签
        m.openAgentPage(app: "luoke-scan", page: "sender", args: ["key": "news@example.com"])
        m.closeAppDialog()
        XCTAssertNil(m.appDialog)
        XCTAssertTrue(m.appDialogStack.isEmpty)
        XCTAssertEqual(m.visibleAppTab, "overview")
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

    /// 一页上点完，这个应用别的取过的标签、弹窗底下那一页也重新取（负责人 11-20：清理完成之后页面还是清理之前的状态）
    func testOtherFetchedPagesAreReadAgainAfterATap() throws {
        let (m, c, wire) = connected()
        let reads = { (p: String) in wire.paths("GET").filter { $0.split(separator: "?").first.map(String.init) == "/apps/luoke-scan/pages/\(p)" }.count }
        m.go(.scan)
        XCTAssertTrue(wait { reads("overview") == 1 && reads("status") == 1 }, "别的标签先取好")
        // 在弹窗（隐藏页）里点：弹窗那一页、底下的概览、别的标签都重新取
        let sid = "luoke-scan/page/cleaned"
        wire.set("/apps/luoke-scan/pages/cleaned", page(sid, secureComponents, data: #"{"fields": {"code": ""}}"#))
        m.openAgentPage(app: "luoke-scan", page: "cleaned")
        XCTAssertTrue(wait { m.agentPages[sid]?.surface?.surface.secureFieldPaths == ["/fields/code"] })
        XCTAssertNotNil(m.appDialog)
        let before = (reads("overview"), reads("status"), reads("cleaned"))
        let s = try XCTUnwrap(m.agentPages[sid]?.surface)
        c.action(surfaceId: sid, componentId: "b", context: try s.surface.action("b").context)
        XCTAssertTrue(wait { reads("overview") == before.0 + 1 && reads("status") == before.1 + 1 && reads("cleaned") == before.2 + 1 })
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

    // MARK: 重新取时留下用户改过的选择

    private func choices(_ title1: String, extra: String = "") -> String {
        #"""
        [{"id": "root", "component": "Column", "children": ["a", "b", "c", "go", "only"\#(extra.isEmpty ? "" : ", \"x\"")]},
         {"id": "a", "component": "ChoicePicker", "label": "\#(title1)", "value": {"path": "/choices/i1"},
          "options": [{"value": "trash", "label": "移到废纸篓"}, {"value": "keep", "label": "先不动"}]},
         {"id": "b", "component": "ChoicePicker", "label": "很久没动过的项目", "value": {"path": "/choices/i2"},
          "options": [{"value": "trash", "label": "移到废纸篓"}, {"value": "keep", "label": "先不动"}]},
         {"id": "c", "component": "ChoicePicker", "label": "家庭录像", "value": {"path": "/choices/i3"},
          "options": [{"value": "trash", "label": "移到废纸篓"}, {"value": "keep", "label": "先不动"}]},
         {"id": "go", "component": "Button", "child": "gt", "count": {"path": "/choices", "value": "trash"},
          "action": {"event": {"name": "scan_apply", "context": {"choices": {"path": "/choices"}}}}},
         {"id": "gt", "component": "Text", "text": "移到废纸篓 {n} 项"},
         {"id": "only", "component": "Button", "child": "ot", "action": {"event": {"name": "scan_apply", "context": {"choices": {"i0": ["remove"]}}}}},
         {"id": "ot", "component": "Text", "text": "清理"}\#(extra)]
        """#
    }

    /// 点了另一个按钮（只清缓存的「清理」），重新取这一页：用户改过的选择照留，没改过的照工具新给的；
    /// 同一个路径换成了别的东西（标题不一样）的、新页上没画的，不带过去（internal-1110-5：「移到废纸篓 0 项」又变回 4）
    func testChangedChoicesStayWhenThePageIsReadAgain() throws {
        let (m, c, wire) = connected()
        let sid = "luoke-scan/page/overview"
        let data = #"{"choices": {"i0": ["keep"], "i1": ["trash"], "i2": ["trash"], "i3": ["keep"]}}"#
        wire.set("/apps/luoke-scan/pages/overview", page(sid, choices("ModelBox 的安装包"), data: data))
        let reads = { wire.paths("GET").filter { $0 == "/apps/luoke-scan/pages/overview" }.count }
        m.go(.scan)
        XCTAssertTrue(wait { m.agentPages[sid]?.surface?.surface.choiceShapes.count == 3 })
        let s = try XCTUnwrap(m.agentPages[sid]?.surface)
        XCTAssertEqual(s.surface.buttonLabel("go").text, "移到废纸篓 2 项")
        s.set("/choices/i1", .array([.string("keep")]))      // 用户改成「先不动」
        s.set("/choices/i3", .array([.string("trash")]))     // 这个改成「移到废纸篓」
        XCTAssertEqual(s.surface.buttonLabel("go").text, "移到废纸篓 2 项")
        // 工具这回给的：i2 做完了换成「先不动」，i3 那一行换成了别的东西（标题不一样），多了一行 x
        let extra = #"""
        , {"id": "x", "component": "ChoicePicker", "label": "新的一行", "value": {"path": "/choices/i4"},
           "options": [{"value": "trash", "label": "移到废纸篓"}, {"value": "keep", "label": "先不动"}]}
        """#
        let again = choices("ModelBox 的安装包", extra: extra).replacingOccurrences(of: "家庭录像", with: "下载里的重复文件")
        wire.set("/apps/luoke-scan/pages/overview",
                 page(sid, again, data: #"{"choices": {"i0": ["keep"], "i1": ["trash"], "i2": ["keep"], "i3": ["keep"], "i4": ["trash"]}}"#))
        c.action(surfaceId: sid, componentId: "only", context: try s.surface.action("only").context)
        XCTAssertTrue(wait { reads() == 2 && m.agentPages[sid]?.surface !== s })
        let now = try XCTUnwrap(m.agentPages[sid]?.surface)
        XCTAssertEqual(now.value("/choices/i1"), .array([.string("keep")]), "用户改的照留")
        XCTAssertEqual(now.value("/choices/i2"), .array([.string("keep")]), "用户没改过的照工具新给的")
        XCTAssertEqual(now.value("/choices/i3"), .array([.string("keep")]), "同一个路径换成了别的东西：不带过去")
        XCTAssertEqual(now.value("/choices/i4"), .array([.string("trash")]))
        XCTAssertEqual(now.surface.buttonLabel("go").text, "移到废纸篓 1 项")
        XCTAssertFalse(now.changed("/choices/i2"))
        XCTAssertTrue(now.changed("/choices/i1"), "带过来的算用户改过的：再取一次也留")
    }

    /// 改了选择没交出去就离开这一页（去「今天」），再回来：照工具给的，不带过去（设置页「整理间隔」改成 60 不保存，回来还显示 60）
    func testChangedChoicesGoWhenLeavingThePage() throws {
        let (m, c, wire) = connected()
        defer { withExtendedLifetime(c) {} }   // 连接放掉了窗口就不再取页
        let sid = "luoke-scan/page/overview"
        let comps = #"""
        [{"id": "root", "component": "Column", "children": ["every", "save"]},
         {"id": "every", "component": "ChoicePicker", "label": "整理间隔", "value": {"path": "/settings/every"},
          "options": [{"value": "30", "label": "30 分钟"}, {"value": "60", "label": "60 分钟"}]},
         {"id": "save", "component": "Button", "child": "st", "action": {"event": {"name": "save", "context": {"every": {"path": "/settings/every"}}}}},
         {"id": "st", "component": "Text", "text": "保存"}]
        """#
        wire.set("/apps/luoke-scan/pages/overview", page(sid, comps, data: #"{"settings": {"every": ["30"]}}"#))
        let reads = { wire.paths("GET").filter { $0 == "/apps/luoke-scan/pages/overview" }.count }
        m.go(.scan)
        XCTAssertTrue(wait { m.agentPages[sid]?.surface?.surface.choiceShapes.count == 1 })
        let s = try XCTUnwrap(m.agentPages[sid]?.surface)
        s.set("/settings/every", .array([.string("60")]))      // 改了，没点「保存」
        m.go(.today)
        XCTAssertEqual(s.value("/settings/every"), .array([.string("30")]), "离开这一页：放回工具给的")
        XCTAssertFalse(s.changed("/settings/every"))
        m.go(.scan)
        XCTAssertTrue(wait { reads() == 2 && m.agentPages[sid]?.surface !== s })
        let back = try XCTUnwrap(m.agentPages[sid]?.surface)
        XCTAssertEqual(back.value("/settings/every"), .array([.string("30")]), "回来再取：照工具给的")
        XCTAssertFalse(back.changed("/settings/every"))
    }

    /// 输入框里填了、点了按钮没成（「添加邮箱」连不上），重新取这一页：填的字照留，不用重填；工具改了值的（保存过的显示名）照工具的；
    /// 离开这一页：放回工具给的
    func testTypedTextStaysWhenThePageIsReadAgain() throws {
        let (m, c, wire) = connected()
        let sid = "luoke-scan/page/overview"
        let comps = #"""
        [{"id": "root", "component": "Column", "children": ["addr", "name", "go"]},
         {"id": "addr", "component": "TextField", "label": "邮箱地址", "value": {"path": "/fields/address"}},
         {"id": "name", "component": "TextField", "label": "显示为", "value": {"path": "/fields/name"}},
         {"id": "go", "component": "Button", "child": "gt", "action": {"event": {"name": "connect", "context": {"address": {"path": "/fields/address"}}}}},
         {"id": "gt", "component": "Text", "text": "连接"}]
        """#
        wire.set("/apps/luoke-scan/pages/overview", page(sid, comps, data: #"{"fields": {"address": "", "name": "旧名"}}"#))
        let reads = { wire.paths("GET").filter { $0 == "/apps/luoke-scan/pages/overview" }.count }
        m.go(.scan)
        XCTAssertTrue(wait { m.agentPages[sid]?.surface?.surface.textFieldLabels.count == 2 })
        let s = try XCTUnwrap(m.agentPages[sid]?.surface)
        s.set("/fields/address", .string("a@example.com"))
        s.set("/fields/name", .string("新名"))
        wire.set("/apps/luoke-scan/pages/overview", page(sid, comps, data: #"{"fields": {"address": "", "name": "存好的名"}}"#))
        c.action(surfaceId: sid, componentId: "go", context: try s.surface.action("go").context)
        XCTAssertTrue(wait { reads() == 2 && m.agentPages[sid]?.surface !== s })
        let now = try XCTUnwrap(m.agentPages[sid]?.surface)
        XCTAssertEqual(now.value("/fields/address"), .string("a@example.com"), "没成：填的地址照留")
        XCTAssertEqual(now.value("/fields/name"), .string("存好的名"), "工具改了的照工具的")
        m.go(.today)
        XCTAssertEqual(now.value("/fields/address"), .string(""), "离开这一页：放回工具给的")
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
        wire.set("/action", Data(#"{"text": "已完成", "error": false, "file": {"name": "../.zshrc", "mediaType": "text/plain", "text": "x"}}"#.utf8))
        c.action(surfaceId: sid, componentId: button, context: .object([:]))
        XCTAssertTrue(wait { wire.bodies("/action").count == 2 && reads() == 3 })
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        XCTAssertEqual(saved.count, 1, "名字不对：不存")
        XCTAssertNil(AgentConnection.savedFile(Data(#"{"text": "好"}"#.utf8)))
        XCTAssertNotNil(AgentConnection.savedFile(Data(#"{"file": {"name": "a.xml", "mediaType": "application/xml", "text": "x"}}"#.utf8)))
    }
}
