import Foundation
import LuokeA2UICore
import XCTest
@testable import LuokeWindow

/// 接 agent 核心（docs/界面接口.md §3、§4、§9）：`/feed` 的事件填进「今天」和「设置 · 提醒」，点按和改设置交回核心。
@MainActor
final class AgentFeedTests: XCTestCase {
    final class FakeBackend: WindowBackend {
        var actions: [(String, String)] = []
        var patches: [[String: JSONValue]] = []
        func action(surfaceId: String, componentId: String, context: JSONValue) { actions.append((surfaceId, componentId)) }
        func updateSettings(_ patch: [String: JSONValue]) { patches.append(patch) }
    }

    /// 螺壳被简报的通知拉起：窗口比核心先起来，点的时候「今天」还是空的。不拼一份「都处理完了」，等核心的第一份 feed 到了再拼
    func testBriefClickedBeforeTheCoreAnswersIsBuiltWhenTheFeedArrives() throws {
        let m = WindowModel()
        let c = AgentConnection(model: m) { _, _, _ in (200, Data("{}".utf8)) }
        m.openNotification([AgentNotification.userInfoKey: "brief"])
        XCTAssertEqual(m.page, .today)
        XCTAssertNil(m.briefNote, "核心的数据还没到：先不拼")
        for (e, d) in Sample.agentEvents() { c.feed.handle(e, d) }
        let note = try XCTUnwrap(m.briefNote, "feed 到了就拼")
        XCTAssertFalse(note.pending.isEmpty)
        XCTAssertEqual(note.pending.map(\.id), m.cards.map(\.id), "核心先给全部卡片、最后给 feed：一张不少")
        XCTAssertEqual(note.urgent, m.urgent.map(\.title))
        let first = Sample.agentEvents().first { $0.0 == "feed" }!
        c.feed.handle(first.0, first.1)
        XCTAssertEqual(m.briefNote, note, "之后再来的 feed 不重拼：简报是点的那时候的样子")
    }

    func testBriefClosedBeforeTheFeedArrivesStaysClosed() {
        let m = WindowModel()
        let c = AgentConnection(model: m) { _, _, _ in (200, Data("{}".utf8)) }
        m.openNotification([AgentNotification.userInfoKey: "brief"])
        m.closeBrief()
        for (e, d) in Sample.agentEvents() { c.feed.handle(e, d) }
        XCTAssertNil(m.briefNote, "关了就不再弹出来")
    }

    private func fed(scan: String = ToolSample.defaultScan) -> (WindowModel, AgentFeed) {
        let m = WindowModel()
        let f = AgentFeed(model: m)
        for (e, d) in Sample.agentEvents(scan: scan) { f.handle(e, d) }
        return (m, f)
    }

    /// 螺壳扫描那几张（它的场景样例经真核心）在「今天」的哪一段：照核心给的，测试不抄它的字
    private func scanCards(_ section: String, scan: String = ToolSample.defaultScan) -> [JSONValue] {
        guard let s = ToolSample.load("luoke-scan", scan),
              let feed = s.events.last(where: { $0.0 == "feed" }).flatMap({ try? JSONValue.parse($0.1) }) else { return [] }
        let cards = feed["cards"]?.array ?? []
        return (feed["order"]?.array ?? []).compactMap { id in
            cards.first { $0["id"] == id && $0["section"]?.string == section }
        }
    }

    private func scanIDs(_ section: String, scan: String = ToolSample.defaultScan) -> [String] {
        scanCards(section, scan: scan).compactMap { $0["id"]?.string }
    }

    func testFeedFillsTheFourSections() {
        let (m, _) = fed()
        XCTAssertEqual(m.urgent.map(\.id), ["luoke-mail/sus-1"])
        XCTAssertNotNil(m.urgent.first?.surface, "急事横幅画工具的那张卡片")
        XCTAssertEqual(m.urgent.first?.title, "可疑邮件：冒充招商银行")
        let scanDecide = scanIDs("decide")
        XCTAssertFalse(scanDecide.isEmpty, "第一次扫描、没给完全磁盘访问：扫描要你允许")
        XCTAssertEqual(m.cards.map(\.id), ["luoke-mail/new-1", "memory/ask-7"] + scanDecide)
        XCTAssertEqual(m.cards.map(\.tool), [.mail, .mem] + scanDecide.map { _ in .scan })
        XCTAssertEqual(m.cards.first { $0.id == "memory/ask-7" }?.time, "08:15", "今天的写时刻")
        XCTAssertEqual(m.done.map(\.id), scanIDs("done"))
        XCTAssertEqual(m.quiet.map(\.id), ["agent/less-1"] + scanIDs("later"))
        XCTAssertEqual(m.notices, ["螺壳搜索现在没在运行。"])
        XCTAssertEqual(m.todayCount, 1 + 2 + scanDecide.count, "急事加要你决定")
        XCTAssertTrue(m.hasUrgent)
        XCTAssertTrue(m.statusMenu.items.contains { $0.title == "可疑邮件：冒充招商银行" }, "菜单栏图标列出急事")
    }

    func testDoneRowsFromTheCore() throws {
        let (m, _) = fed(scan: "autoclean-done")
        let done = scanCards("done", scan: "autoclean-done")
        XCTAssertFalse(done.isEmpty, "不用点就清了：在「已经替你做了」")
        XCTAssertEqual(m.done.map(\.id), done.compactMap { $0["id"]?.string })
        XCTAssertEqual(m.done.first?.tool, .scan)
        let at = try XCTUnwrap(AgentFeed.date(try XCTUnwrap(done.first?["time"])))
        XCTAssertEqual(m.done.first?.time, AgentFeed.display(at), "不是今天的写几月几日")
        // 收起成一行时，卡片上的「放回」照样能点：点的是卡片里那个按钮，带它自己的上下文
        let s = try XCTUnwrap(m.done.first?.surface).surface
        let undo = try XCTUnwrap(TodayPage.undoButton(in: s), "自动清的卡片上有「放回」")
        XCTAssertEqual(undo.label, "放回")
        XCTAssertEqual(try s.action(undo.id).name, "scan_restore")
        XCTAssertNotNil(undo.context["id"]?.string, "放回哪一批")
    }

    func testSettingsFromTheCore() {
        let (m, _) = fed()
        XCTAssertEqual(m.brief, .twice)
        XCTAssertEqual(m.quietHours, "23:00 – 07:30")
        XCTAssertEqual(m.quietOptions.first, "23:00 – 07:30", "核心里的值不在常用几档里也能显示")
        XCTAssertTrue(m.alertsOn)
        XCTAssertEqual(m.kinds.map(\.id), ["luoke-mail:suspicious", "luoke-mail:digest", "memory:ask"])
        XCTAssertEqual(m.kinds.map(\.level), [.now, .window, .brief])
        XCTAssertEqual(m.kinds.map(\.tool), [.mail, .mail, .mem])
    }

    func testTapsAndSettingsGoToTheBackend() {
        let (m, _) = fed()
        let b = FakeBackend()
        m.backend = b
        m.tap(card: m.cards[0], componentId: "b1", name: "mail_apply_plan", context: .object([:]))
        m.tapSurface("luoke-mail/sus-1", componentId: "b2", context: .object([:]))
        XCTAssertEqual(b.actions.map { "\($0.0)#\($0.1)" }, ["luoke-mail/new-1#b1", "luoke-mail/sus-1#b2"])
        XCTAssertEqual(m.cards.count, 2 + scanIDs("decide").count, "交给核心：卡片等核心说了再变")
        m.setLevel("memory:ask", .window)
        m.setBrief(.onOpen)
        m.setQuiet("关")
        m.setQuiet("22:00 – 08:00")
        m.setAlerts(false)
        XCTAssertEqual(b.patches, [
            ["modes": .object(["memory:ask": .string("window")])],
            ["brief": .string("on_open")],
            ["quiet": .null],
            ["quiet": .object(["start": .string("22:00"), "end": .string("08:00")])],
            ["proactive": .bool(false)],
        ])
        m.togglePause()
        XCTAssertNotNil(m.pausedUntil)
        XCTAssertNotNil(b.patches.last?["paused_until"]?.string, "暂停一小时：带上到几点")
        m.togglePause()
        XCTAssertEqual(b.patches.last?["paused_until"], .null)
    }

    func testSampleModelStillActsAlone() {
        let m = Sample.model()
        let n = m.cards.count
        m.tap(card: m.cards[0], componentId: "b1", name: "mail_apply_plan", context: .object([:]))
        XCTAssertEqual(m.cards.count, n - 1, "没接核心：示例自己演")
    }

    func testResultsAndChanges() {
        let (m, f) = fed()
        f.handle("busy", Data(#"{"surfaceId":"luoke-mail/new-1"}"#.utf8))
        XCTAssertTrue(f.surfaces["luoke-mail/new-1"]?.busy ?? false)
        f.handle("result", Data(#"{"surfaceId":"luoke-mail/new-1","text":"已归档 3 封。","error":false,"replaced":true}"#.utf8))
        XCTAssertFalse(f.surfaces["luoke-mail/new-1"]?.busy ?? true)
        XCTAssertNil(m.toast, "卡片已经换成结果：不再提示一遍")
        f.handle("result", Data(#"{"surfaceId":"memory/ask-7","text":"记下了：对。","error":false,"replaced":false}"#.utf8))
        XCTAssertEqual(m.toast?.text, "记下了：对。")
        f.handle("a2ui", Data(#"{"version":"v0.9","deleteSurface":{"surfaceId":"memory/ask-7"}}"#.utf8))
        XCTAssertEqual(m.cards.map(\.id), ["luoke-mail/new-1"] + scanIDs("decide"), "卡片删了就收走")
        var got: [AgentNotification] = []
        f.onNotify = { got.append($0) }
        f.handle("notify", Data(#"{"id":"brief","title":"2 件事","body":"标题","urgent":false,"silent":true}"#.utf8))
        XCTAssertEqual(got.map(\.title), ["2 件事"])
        XCTAssertTrue(got[0].silent)
        f.handle("feed", Data(#"{"order":[],"open":0,"notices":[],"cards":[],"paused_until":"2030-01-01T10:00:00+08:00"}"#.utf8))
        XCTAssertEqual(m.todayCount, 0)
        XCTAssertNotNil(m.pausedUntil, "暂停到几点照核心的")
        f.handle("feed", Data("not json".utf8))
        XCTAssertEqual(m.todayCount, 0, "坏的事件不理")
    }

    /// 走真的 Unix socket：一个假核心推 /feed、答 /settings，收 /action
    func testConnectionOverTheSocket() throws {
        let path = "/tmp/lkw-\(getpid()).sock"
        let core = try MiniCore(path: path, events: Sample.agentEvents(),
                                settings: Sample.agentEvents().first { $0.0 == "settings" }!.1)
        defer { core.stop() }
        let m = WindowModel()
        let c = AgentConnection(socketPath: path, model: m)
        c.start()
        defer { c.stop() }
        let n = 2 + scanIDs("decide").count
        XCTAssertTrue(wait { m.cards.count == n && m.brief == .twice }, "订阅到了「今天」，连上时取了设置")
        XCTAssertTrue(c.connected)
        m.tap(card: m.cards[0], componentId: "b1", name: "mail_apply_plan", context: .object(["x": .number(1)]))
        XCTAssertTrue(wait { core.posted("/action") != nil })
        let body = try JSONValue.parse(core.posted("/action")!)
        XCTAssertEqual(body["surfaceId"], .string("luoke-mail/new-1"))
        XCTAssertEqual(body["sourceComponentId"], .string("b1"))
        m.setBrief(.morning)
        XCTAssertTrue(wait { core.posted("/settings") != nil })
        XCTAssertEqual(try JSONValue.parse(core.posted("/settings")!), .object(["brief": .string("morning")]))
    }

    private func wait(_ ok: () -> Bool) -> Bool {
        for _ in 0..<200 {
            if ok() { return true }
            RunLoop.main.run(until: Date().addingTimeInterval(0.025))
        }
        return ok()
    }
}

/// 很小的假核心：`GET /feed` 推一串事件后连着不断（`push` 再推），`GET /settings` 答设置，`route` 登记的照登记的答，
/// 别的 POST 记下来答一句空话。
final class MiniCore: @unchecked Sendable {
    private let path: String
    private let events: [(String, Data)]
    private let settings: Data
    private var fd: Int32 = -1
    private var stopped = false
    private var bodies: [String: Data] = [:]
    private var postLog: [(String, Data)] = []
    private var getCounts: [String: Int] = [:]
    private var routes: [String: (Int, Data)] = [:]
    private var outbox: [(String, Data)] = []
    private let lock = NSLock()

    init(path: String, events: [(String, Data)], settings: Data) throws {
        self.path = path
        self.events = events
        self.settings = settings
        unlink(path)
        fd = socket(AF_UNIX, SOCK_STREAM, 0)
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8)
        withUnsafeMutableBytes(of: &addr.sun_path) { $0.copyBytes(from: bytes); $0[bytes.count] = 0 }
        let r = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        guard r == 0, listen(fd, 8) == 0 else { throw UnixHTTP.Failure(reason: "bind") }
        let listener = fd
        Thread.detachNewThread { [self] in
            while true {
                let c = accept(listener, nil, nil)
                if c < 0 { return }
                Thread.detachNewThread { self.serve(c) }
            }
        }
    }

    func posted(_ p: String) -> Data? { lock.lock(); defer { lock.unlock() }; return bodies[p] }
    /// 这个地址收到的全部 POST 正文（先后顺序）
    func posts(_ p: String) -> [Data] { lock.lock(); defer { lock.unlock() }; return postLog.filter { $0.0 == p }.map(\.1) }
    /// 这个地址被 GET 了几次
    func gets(_ p: String) -> Int { lock.lock(); defer { lock.unlock() }; return getCounts[p] ?? 0 }
    /// 「方法 地址」答什么
    func route(_ method: String, _ p: String, status: Int = 200, _ body: Data) {
        lock.lock(); routes["\(method) \(p)"] = (status, body); lock.unlock()
    }
    /// 往连着的 `/feed` 再推一条事件
    func push(_ event: String, _ data: Data) { lock.lock(); outbox.append((event, data)); lock.unlock() }

    func stop() {
        lock.lock(); stopped = true; lock.unlock()
        shutdown(fd, SHUT_RDWR)
        close(fd)
        unlink(path)
    }

    private func serve(_ c: Int32) {
        defer { close(c) }
        var all = Data()
        var buf = [UInt8](repeating: 0, count: 65536)
        var headEnd: Range<Data.Index>?
        while headEnd == nil {
            let n = read(c, &buf, buf.count)
            if n <= 0 { return }
            all.append(buf, count: n)
            headEnd = all.range(of: Data("\r\n\r\n".utf8))
        }
        let head = String(data: all[..<headEnd!.lowerBound], encoding: .utf8) ?? ""
        let first = head.split(separator: "\r\n").first?.split(separator: " ") ?? []
        guard first.count >= 2 else { return }
        let method = String(first[0]), p = String(first[1])
        let length = head.split(separator: "\r\n").compactMap { l -> Int? in
            l.lowercased().hasPrefix("content-length:") ? Int(l.split(separator: ":")[1].trimmingCharacters(in: .whitespaces)) : nil
        }.first ?? 0
        var body = Data(all[headEnd!.upperBound...])
        while body.count < length {
            let n = read(c, &buf, buf.count)
            if n <= 0 { break }
            body.append(buf, count: n)
        }
        func reply(_ d: Data, status: Int = 200) {
            var out = Data("HTTP/1.1 \(status) X\r\nContent-Type: application/json\r\nContent-Length: \(d.count)\r\nConnection: close\r\n\r\n".utf8)
            out.append(d)
            _ = out.withUnsafeBytes { write(c, $0.baseAddress!, $0.count) }
        }
        func sse(_ list: [(String, Data)]) -> Data {
            var out = Data()
            for (e, d) in list { out.append(Data("event: \(e)\ndata: ".utf8)); out.append(d); out.append(Data("\n\n".utf8)) }
            return out
        }
        lock.lock()
        if method == "GET" { getCounts[p, default: 0] += 1 } else { bodies[p] = body; postLog.append((p, body)) }
        let routed = routes["\(method) \(p)"]
        lock.unlock()
        if method == "GET" && p == "/feed" {
            var out = Data("HTTP/1.1 200 OK\r\nContent-Type: text/event-stream\r\nConnection: close\r\n\r\n".utf8)
            out.append(sse(events.filter { $0.0 != "settings" }))
            _ = out.withUnsafeBytes { write(c, $0.baseAddress!, $0.count) }
            while true {
                lock.lock(); let s = stopped; let more = outbox; outbox = []; lock.unlock()
                if s { return }
                if !more.isEmpty { let d = sse(more); _ = d.withUnsafeBytes { write(c, $0.baseAddress!, $0.count) } }
                Thread.sleep(forTimeInterval: 0.05)
            }
        } else if let (status, d) = routed {
            reply(d, status: status)
        } else if method == "GET" && p == "/settings" {
            reply(settings)
        } else if method == "GET" {
            reply(Data(#"{"error":"没有这个地址"}"#.utf8), status: 404)
        } else {
            reply(Data(#"{"text":"","error":false}"#.utf8))
        }
    }
}
