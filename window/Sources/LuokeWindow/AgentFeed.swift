import AppKit
import Foundation
import LuokeA2UI
import LuokeA2UICore

/// 窗口把要做的事交给谁（docs/界面接口.md）。接上 agent 核心时是 `AgentConnection`；用示例数据时没有，窗口自己演。
@MainActor
public protocol WindowBackend: AnyObject {
    /// 用户点了卡片上的按钮（§4 `POST /action`）
    func action(surfaceId: String, componentId: String, context: JSONValue)
    /// 用户改了「设置 · 提醒」（§9 `POST /settings`，只带改了的）
    func updateSettings(_ patch: [String: JSONValue])
    /// 重新取应用列表（§6 `GET /apps`）
    func reloadApps()
    /// 取一页基础页（§6 `GET /apps/<id>/pages/<页>`）
    func reloadPage(app: String, page: String)
    /// 打开工具自己的界面（§6 `POST /open`）。窗口不再调它：应用的事都在窗口里做（11-09 定）
    func openApp(_ app: String, page: String?)
    /// 重新取「设置 · 权限」（§10 `GET /permissions`）
    func reloadPermissions()
    /// 用户在权限页上点了（§10 `POST /permissions`）；op 是那一行 `can` 里的一个
    func permission(app: String, id: String, op: String)
    /// 螺壳.app 报它自己的权限状态（§10 `POST /host`）：权限 id → "granted" / "denied" / "ask" / null
    func reportHost(permissions: [String: JSONValue], confirmed: [String: [String: String]]?)
    /// 用户在搜索框按了回车（§7 `POST /search`）
    func search(query: String)
    /// 要一条结果的缩略图（§7 `GET /thumb`）；答来了调 `WindowModel.setThumb`
    func searchThumb(app: String, ref: String)
    /// 用户点了结果上的按钮、按了回车或 ⌘↩（§7 `POST /hit`）：`action` 是它在这条结果 `actions` 里的序号
    func searchHit(search: Int, app: String, hit: String, action: Int)
    /// 窗口换了一页（§11 `POST /window` 的 `page`）
    func windowPageChanged()
}

/// 只管「今天」和提醒的后端不用实现应用的页和权限
public extension WindowBackend {
    func reloadApps() {}
    func reloadPage(app: String, page: String) {}
    func openApp(_ app: String, page: String?) {}
    func reloadPermissions() {}
    func permission(app: String, id: String, op: String) {}
    func reportHost(permissions: [String: JSONValue], confirmed: [String: [String: String]]?) {}
    func search(query: String) {}
    func searchThumb(app: String, ref: String) {}
    func searchHit(search: Int, app: String, hit: String, action: Int) {}
    func windowPageChanged() {}
}

/// 核心要螺壳.app 发的一条系统通知（`/feed` 的 `notify`）
public struct AgentNotification: Equatable {
    public let id: String
    public let title: String
    public let body: String
    public let urgent: Bool
    public let silent: Bool
    public let surfaceId: String?
}

/// `GET /feed` 的事件、`/settings`、`/apps`、`/permissions` 的答复 → 窗口的「今天」、菜单栏图标的急事、「设置 · 提醒」、
/// 应用的页、「设置 · 权限」。只管数据；连接由 `AgentConnection` 管，测试直接喂事件和答复。
@MainActor
public final class AgentFeed {
    public struct Card: Equatable {
        public let id: String
        public let app: String
        public let kind: String
        public let section: String
        public let title: String
        public let time: Date?
        var hostAsk: HostAsk? = nil
    }

    public private(set) var surfaces: [String: SurfaceModel] = [:]
    public private(set) var cards: [Card] = []
    public private(set) var settings: [String: JSONValue] = [:]
    public var onNotify: ((AgentNotification) -> Void)?
    private weak var model: WindowModel?
    private var gotFeed = false
    /// 核心删了、下一份 feed 还没到的卡片：照旧画着。核心换卡片时先删旧的、再发新的、最后发 feed，
    /// 删的那一下就把它从「今天」拿掉的话，一件件处理会当成工具收走了、跳到下一件；等 feed 到了再一起换
    private var held: [String: SurfaceModel] = [:]

    public init(model: WindowModel) {
        self.model = model
    }

    /// 一条事件（名字、JSON）。认不得的、坏的不理。
    public func handle(_ event: String, _ data: Data) {
        guard let v = try? JSONValue.parse(data) else { return }
        switch event {
        case "a2ui":
            guard let sid = surfaceId(of: v), let (kind, body) = try? unwrapMessage(v) else { return }
            if kind == "createSurface" {
                guard let cat = body["catalogId"]?.string, let s = try? Surface(surfaceId: sid, catalogId: cat) else { return }
                surfaces[sid] = SurfaceModel(surface: s)
            } else if kind == "deleteSurface" {
                if held[sid] == nil { held[sid] = surfaces[sid] }
                surfaces[sid] = nil
            } else if let m = surfaces[sid] {
                try? m.receive(v)    // 核心已经整组查过
            }
        case "feed":
            cards = (v["cards"]?.array ?? []).compactMap(Self.card)
            if let o = v["order"]?.array, cards.isEmpty, !o.isEmpty {   // 老的核心（api 1）只给 order：都当要你决定
                cards = o.compactMap(\.string).map { Card(id: $0, app: String($0.split(separator: "/").first ?? ""),
                                                          kind: "", section: "decide", title: "", time: nil) }
            }
            model?.notices = (v["notices"]?.array ?? []).compactMap(\.string)
            model?.agentDot = v["dot"]?.bool         // 老的核心不给：照有没有急事
            model?.lastSeen = model?.now()
            if let p = v["paused_until"] { model?.setPausedFromAgent(Self.date(p).map(Self.hhmm)) }
            gotFeed = true
            held = [:]
            rebuild()
            model?.feedArrived()
        case "settings":
            applySettings(v)
        case "apps":
            if let app = v["app"]?.string { model?.agentAppChanged(app) }
        case "busy":
            if let sid = v["surfaceId"]?.string { surface(sid)?.busy = true }
        case "result":
            guard let sid = v["surfaceId"]?.string else { return }
            surface(sid)?.busy = false
            surface(sid)?.pressed = nil
            let text = v["text"]?.string ?? ""
            let error = v["error"]?.bool ?? false
            let replaced = v["replaced"]?.bool ?? false      // 卡片已经换成结果：那句话上面有了
            if !text.isEmpty && (error || !replaced) { model?.show(text) }
        case "notify":
            guard let id = v["id"]?.string else { return }
            onNotify?(AgentNotification(id: id, title: v["title"]?.string ?? "", body: v["body"]?.string ?? "",
                                        urgent: v["urgent"]?.bool ?? false, silent: v["silent"]?.bool ?? false,
                                        surfaceId: v["surfaceId"]?.string))
        default:
            break
        }
        if event == "a2ui", gotFeed { rebuild() }
    }

    /// `GET /settings` 的答复或 `settings` 事件：换掉「设置 · 提醒」里的值
    public func applySettings(_ v: JSONValue) {
        guard let o = v.object, let model else { return }
        settings = o
        if let b = o["proactive"]?.bool { model.alertsOn = b }
        switch o["brief"]?.string {
        case "morning": model.brief = .morning
        case "twice": model.brief = .twice
        case "on_open": model.brief = .onOpen
        default: break
        }
        if let q = o["quiet"] {
            if let s = q["start"]?.string, let e = q["end"]?.string { model.quietHours = "\(s) – \(e)" } else { model.quietHours = "关" }
        }
        if let p = o["paused_until"] { model.setPausedFromAgent(Self.date(p).map(Self.hhmm)) }
        if let ks = o["kinds"]?.array {
            model.kinds = ks.compactMap { k in
                guard let id = k["id"]?.string, let mode = k["mode"]?.string, let level = Level(rawValue: mode) else { return nil }
                return KindSetting(id: id, tool: Self.tool(k["app"]?.string ?? ""), title: k["label"]?.string ?? id, level: level)
            }
        }
    }

    /// 卡片或基础页（页上的点按也有 busy、result）
    func surface(_ sid: String) -> SurfaceModel? {
        surfaces[sid] ?? held[sid] ?? model?.agentPages[sid]?.surface ?? model?.searchAnswer?.cards.first { $0.id == sid }?.surface
    }

    // MARK: 应用的页、权限（§6、§10）

    /// 基础页的编号，同核心给的 surfaceId
    public nonisolated static func pageKey(_ app: String, _ page: String) -> String { "\(app)/page/\(page)" }

    /// `GET /apps` 的答复：换掉应用列表；正看着的应用页还没取过就去取
    public func applyApps(_ v: JSONValue) {
        guard let list = v["apps"]?.array, let model else { return }
        model.agentApps = list.compactMap(Self.app)
        model.syncAppEntries()
        model.loadVisible(onlyMissing: true)
    }

    /// `GET /apps/<id>/pages/<页>` 的答复（status 0 是没连上）：画得出就换上，画不出、拿不到写一句为什么。
    /// `args`：这次是带着什么参数取的（工具协议 §4 pageArgs）；这一页现在的参数已经换了，这份就不要了
    public func applyPage(app: String, page: String, status: Int, body: Data, args: [String: String] = [:]) {
        guard let model else { return }
        let key = Self.pageKey(app, page)
        if (model.pageArgs[key] ?? [:]) != args { return }
        let v = try? JSONValue.parse(body)
        var out = AgentPage(app: app, page: page, surface: nil, error: nil)
        let old = model.agentPages[key]?.surface
        if status == 200, let msgs = v?["messages"]?.array, let s = try? Surface.build(msgs, page: true) {
            let fresh = SurfaceModel(surface: s)
            // 同一页重新取（点完按钮、定时刷新）：用户填了、这次没交出去的密码框照留（§4 secureField）。工具给的初值只能是空的，
            // 留不留由窗口定；交出去的点按时已经清了，离开这一页时全清了，都不会带过来
            for p in s.secureFieldPaths {
                if let v = old?.value(p), v != .string(""), (try? s.data.value(at: p)) != nil { fresh.set(p, v) }
            }
            out.surface = fresh
        } else if status == 200 {
            out.error = "这一页画不了。"
        } else if status == 0 {
            out.error = "\(WindowModel.offlineShort)，打不开这一页。"
            out.offline = true
        } else {
            out.error = v?["error"]?.string ?? "这一页现在拿不到。"
        }
        model.coreReachable = status != 0
        if out.surface == nil, model.agentPages[key]?.surface != nil, status == 0 { return }   // 断了：先留着上次的
        old?.clearSecureFields()          // 换下来的那份不留填的字（要留的上面已经搬到新的里）
        model.agentPages[key] = out
        if let p = v?["host_ask"]?["permission"]?.string, let b = v?["host_ask"]?["button"]?.string {
            model.pageHostAsks[key] = HostAsk(app: app, id: p, button: b, then: v?["host_ask"]?["then"]?.bool == true)
        } else {
            model.pageHostAsks[key] = nil
        }
    }

    /// `POST /search` 的答复（status 0 是没连上）。收起以后才到的不要
    public func applySearch(status: Int, body: Data) {
        guard let model, model.searching else { return }
        let v = try? JSONValue.parse(body)
        var out = SearchAnswer()
        if status == 200, let results = v?["results"]?.array {
            out.search = v?["search"]?.number.map { Int($0) }
            var hits: [WindowHit] = []
            for r in results {
                // 给了 hits 的：窗口按类型分组自己画（工具协议 §1b）；没给的画它的卡片。
                // hits 一条动作都没带、又有卡片的，也画卡片：不然卡片上的「打开」跟着没了，结果打不开
                let app = r["app"]?.string
                let got = app.map { app in (r["hits"]?.array ?? []).compactMap { WindowHit(app: app, $0) } } ?? []
                let card = r["messages"]?.array.flatMap { try? Surface.build($0) }
                if !got.isEmpty, card == nil || got.contains(where: { !$0.actions.isEmpty }) {
                    hits += got
                } else if let app, let card {
                    out.cards.append(SearchCard(id: "\(app)/search", surface: SurfaceModel(surface: card)))
                } else if let name = r["name"]?.string {
                    out.failed.append(name)
                }
            }
            out.hits = hits
            out.failed += (v?["failed"]?.array ?? []).compactMap(\.string)
            out.asked = v?["asked"]?.number.map { Int($0) }
            out.note = v?["text"]?.string
        } else {
            let q = model.searchQuery.isEmpty ? "" : "「\(model.searchQuery)」"
            out.note = status == 0 ? "\(WindowModel.offlineShort)，搜不了\(q)。" : (v?["error"]?.string ?? "没能搜成\(q)。")
            out.retry = true
        }
        model.searching = false
        model.searchAnswer = out
    }

    /// `GET /permissions` 的答复
    public func applyPermissions(_ v: JSONValue) {
        guard let rows = v["rows"]?.array, let model else { return }
        model.agentPermissions = rows.compactMap(Self.permission)
    }

    static func app(_ v: JSONValue) -> AgentApp? {
        guard let id = v["id"]?.string else { return nil }
        func refs(_ a: JSONValue?) -> [AgentApp.PageRef] {
            (a?.array ?? []).compactMap { p in
                guard let id = p["id"]?.string, let t = p["title"]?.string else { return nil }
                return AgentApp.PageRef(id: id, title: t, hidden: p["hidden"]?.bool == true)
            }
        }
        var summary: AgentApp.Summary?
        if let s = v["summary"], let t = s["text"]?.string { summary = .init(count: Int(s["count"]?.number ?? 0), text: t) }
        let ui = v["ui"].flatMap { $0.object == nil ? nil : refs($0["pages"]) }
        return AgentApp(id: id, running: v["running"]?.bool ?? false, summary: summary, pages: refs(v["pages"]),
                        uiPages: ui, needs: (v["needs"]?.array ?? []).compactMap(\.string))
    }

    static func permission(_ v: JSONValue) -> AgentPermission? {
        guard let app = v["app"]?.string, let key = v["id"]?.string, let kind = v["kind"]?.string,
              let title = v["title"]?.string else { return nil }
        return AgentPermission(app: app, key: key, kind: kind, owner: v["owner"]?.string, tcc: v["tcc"]?.string, title: title,
                               facts: (v["facts"]?.array ?? []).compactMap(\.string), without: v["without"]?.string,
                               state: v["state"]?.string, can: kind == "each-time" ? nil : (v["can"]?.array ?? []).compactMap(\.string))
    }

    /// 按 `cards` 的分段，把有卡片的放进「今天」的四段。删了、feed 还没到的画删之前那张：同编号换内容时，
    /// 新的那张在 feed 到了以后才换上，不会先露出一张还没画完的
    func rebuild() {
        guard let model else { return }
        var urgent: [UrgentItem] = [], decide: [TodayCard] = [], done: [DoneRow] = [], later: [QuietRow] = []
        for c in cards {
            guard let s = held[c.id] ?? surfaces[c.id] else { continue }
            let tool = Self.tool(c.app)
            let time = c.time.map(Self.display) ?? ""
            switch c.section {
            case "urgent":
                urgent.append(UrgentItem(id: c.id, tool: tool, title: c.title, time: time, primary: "", primarySymbol: nil,
                                         secondary: "", surface: s, kind: c.kind))
            case "done":
                let g = s.surface.doneGroup.map { DoneGroup(key: $0.key, text: $0.text, n: $0.n, label: $0.label, badge: $0.badge) }
                done.append(DoneRow(id: c.id, tool: tool, text: c.title, time: time, undoLabel: nil, surface: s, group: g))
            case "later":
                later.append(QuietRow(id: c.id, tool: tool, text: c.title, surface: s))
            default:
                decide.append(TodayCard(id: c.id, tool: tool, time: c.time.map(Self.display), surface: s, title: c.title, kind: c.kind))
            }
        }
        model.hostAsks = Dictionary(cards.compactMap { c in c.hostAsk.map { (c.id, $0) } }, uniquingKeysWith: { a, _ in a })
        model.urgent = urgent
        model.cards = decide
        model.done = done
        model.quiet = later + model.updateRows()      // 「有新版本」是本体报的，接在核心给的后面
    }

    // MARK: 小工具

    static func card(_ v: JSONValue) -> Card? {
        guard let id = v["id"]?.string else { return nil }
        let app = v["app"]?.string ?? ""
        var ask: HostAsk?
        if let p = v["host_ask"]?["permission"]?.string, let b = v["host_ask"]?["button"]?.string {
            ask = HostAsk(app: app, id: p, button: b)
        }
        return Card(id: id, app: app, kind: v["kind"]?.string ?? "", section: v["section"]?.string ?? "decide",
                    title: v["title"]?.string ?? "", time: v["time"].flatMap(date), hostAsk: ask)
    }

    /// 来源 → 图标（记忆是 memory，agent 自己的是 agent）
    nonisolated static func tool(_ app: String) -> ToolIcon {
        switch app {
        case "luoke-mail", "fake-mail": return .mail
        case "luoke-scan", "luoke-audit": return .scan
        case "memory", "luoke-mem": return .mem
        case "luoke-search": return .search
        case "luoke-ime": return .ime
        default: return .core
        }
    }

    static func date(_ v: JSONValue) -> Date? {
        guard let s = v.string else { return nil }
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        if let d = f.date(from: s) { return d }
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f.date(from: s)
    }

    static func hhmm(_ d: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "zh_CN")
        f.dateFormat = "HH:mm"
        return f.string(from: d)
    }

    /// 今天的写时刻，别的日子写几月几日
    static func display(_ d: Date) -> String {
        if Calendar.current.isDateInToday(d) { return hhmm(d) }
        if Calendar.current.isDateInYesterday(d) { return "昨天 " + hhmm(d) }
        let f = DateFormatter()
        f.locale = Locale(identifier: "zh_CN")
        // 工具给的时间可能是往年的（例如很早收到的信）：不是今年的带上年份
        f.dateFormat = Calendar.current.isDate(d, equalTo: Date(), toGranularity: .year) ? "M月d日" : "yyyy年M月d日"
        return f.string(from: d)
    }

    static func iso(_ d: Date) -> String {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        f.timeZone = .current
        return f.string(from: d)
    }
}

/// 连着 agent 核心：订阅 `/feed`，取应用的页和权限，点按、改设置、权限页上的操作交回去。
/// 螺壳.app（和演示窗口）拿着它；窗口经 `WindowBackend` 用它。
@MainActor
public final class AgentConnection: WindowBackend {
    /// 发一次请求：（状态码，正文）。默认走 Unix socket；测试换成假的。
    public typealias Transport = @Sendable (_ method: String, _ path: String, _ body: Data?) throws -> (Int, Data)

    public let feed: AgentFeed
    public private(set) var connected = false
    private let model: WindowModel
    private let socketPath: String?
    private let transport: Transport
    private var stream: FeedStream?
    /// 正在取的（应用列表、某一页、权限）：取着的时候又要取，等这次回来再取一次
    private var loading: Set<String> = []
    private var again: Set<String> = []
    private var searchSerial = 0
    /// 螺壳.app 报过的它自己的权限（只在内存里）：核心重启后连上时再报一遍
    private var host: [String: JSONValue] = [:]
    private var hostConfirmed: [String: [String: String]]?
    /// 最近报过的窗口状态、通知授权：核心重启后连上时再报一遍
    private var lastWindow: JSONValue?
    private var lastNotifications: JSONValue?
    private var presence: Presence?
    private var presenceTimer: Timer?
    /// 每一页最近一次定的再读（工具协议 §4 pageRefresh）：只认最近定的那次
    private var refreshSerial: [String: Int] = [:]
    /// 过一会儿再做（页的 refresh）；测试换成自己拨的钟
    public var after: (TimeInterval, @escaping @MainActor () -> Void) -> Void = { delay, work in
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { MainActor.assumeIsolated { work() } }
    }
    /// 点按的答复带了文件（工具协议 §4 saveFile）：弹出存文件的框。nil 用 NSSavePanel；测试换成自己的
    public var fileSaver: ((_ name: String, _ text: String) -> Void)?

    /// socketPath：核心的 `<数据目录>/run/agent.sock`
    public convenience init(socketPath: String, model: WindowModel) {
        let path = socketPath
        self.init(model: model, socketPath: path) { method, p, body in try UnixHTTP.request(path, method, p, body: body) }
    }

    public init(model: WindowModel, socketPath: String? = nil, transport: @escaping Transport) {
        self.model = model
        self.socketPath = socketPath
        self.transport = transport
        self.feed = AgentFeed(model: model)
        model.backend = self
        model.waitingForFeed = true      // 数据从这个核心来：第一份 feed 到之前「今天」是空的
    }

    /// 开始订阅；断了自己重连，连上时重新取一次设置
    public func start() {
        guard let socketPath, stream == nil else { return }
        let s = FeedStream(socketPath: socketPath,
                           onEvent: { [weak self] e, d in self?.feed.handle(e, d) },
                           onConnected: { [weak self] ok in self?.setConnected(ok) })
        stream = s
        s.start()
    }

    public func stop() {
        stream?.stop()
        stream = nil
        presenceTimer?.invalidate()
        presenceTimer = nil
        presence?.stop()
        presence = nil
    }

    func setConnected(_ ok: Bool) {
        let was = connected
        connected = ok
        model.coreReachable = ok
        if ok && !was {
            reloadSettings()
            reloadApps()          // 来了以后，正看着的应用页没取过就取
            if !host.isEmpty { postHost(host) }
            if let w = lastWindow { send("POST", "/window", w.serialized()) { _, _ in } }
            if let n = lastNotifications { send("POST", "/notifications", n.serialized()) { _, _ in } }
            reportPresenceNow()
            model.loadVisible()   // 重连：正看着的那一页、权限再取一遍
        }
        if !ok && was { model.notices = [] }   // 核心的那几句是断开前的；「今天」顶上有「连不上螺壳」那一张
    }

    public func reloadSettings() {
        send("GET", "/settings", nil) { [weak self] status, body in
            guard status == 200, let v = try? JSONValue.parse(body) else { return }
            self?.feed.applySettings(v)
        }
    }

    // MARK: WindowBackend

    public func action(surfaceId: String, componentId: String, context: JSONValue) {
        // 上一下点按还没答完：不再发（快按两次 ⏎、连点两下都只交一次）
        if feed.surface(surfaceId)?.busy == true { return }
        feed.surface(surfaceId)?.busy = true
        feed.surface(surfaceId)?.pressed = componentId
        let page = model.agentPages[surfaceId]
        let body = JSONValue.object(["surfaceId": .string(surfaceId), "sourceComponentId": .string(componentId), "context": context])
        // 密码框里填的字（工具协议 §4 secureField）只随这一次交出去：交了的就清掉，不管成没成；这个按钮没交的照留
        if let s = feed.surface(surfaceId) { s.clearSecureFields(only: s.surface.sentSecureFieldPaths(componentId)) }
        send("POST", "/action", body.serialized()) { [weak self] status, reply in
            guard let self else { return }
            self.feed.surface(surfaceId)?.busy = false
            self.feed.surface(surfaceId)?.pressed = nil
            if status == 0 { self.model.show(WindowModel.offlineFailed) }
            // 答复带了文件（工具协议 §4 saveFile）：用户选了位置才存
            if status == 200, let file = Self.savedFile(reply) { self.saveFile(file.name, file.text) }
            // agent.open_page（工具协议 §5）：核心核过是这个应用自己的页，换过去（带 args 时读这一页带上，§4 pageArgs）
            if status == 200, let (app, p, args) = Self.openedPage(reply) {
                self.model.openAgentPage(app: app, page: p, args: args)
                if let page, page.app == app, page.page == p { return }   // 换到的就是这一页：换页时已经重新取了
            }
            // 基础页上点完：工具答复里的卡片不画，重新取这一页（§6）
            if let page, status != 0 { self.reloadPage(app: page.app, page: page.page) }
        }
    }

    /// `POST /action` 的答复里的文件（`{"file": {"name", "mediaType", "text"}}`，界面接口 §4）：形状不对是 nil
    nonisolated static func savedFile(_ body: Data) -> (name: String, mediaType: String, text: String)? {
        guard let v = try? JSONValue.parse(body) else { return nil }
        return A2UI.saveFile(v["file"])
    }

    private func saveFile(_ name: String, _ text: String) {
        if let fileSaver { return fileSaver(name, text) }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = name
        panel.canCreateDirectories = true
        // 螺壳只有一个窗口（11-10 定）：存文件的框挂在主窗口上（点按就在这个窗口里），不单独浮着；窗口不在时才单独开
        if let w = NSApp.keyWindow ?? NSApp.mainWindow, w.isVisible {
            panel.beginSheetModal(for: w) { [weak self] r in
                guard r == .OK, !AgentConnection.write(text, to: panel.url) else { return }
                MainActor.assumeIsolated { self?.model.show("没存成。") }
            }
        } else {
            panel.begin { [weak self] r in
                guard r == .OK, !AgentConnection.write(text, to: panel.url) else { return }
                MainActor.assumeIsolated { self?.model.show("没存成。") }
            }
        }
    }

    /// 把要存的字写进用户选的位置；没给位置不算没存成
    nonisolated static func write(_ text: String, to url: URL?) -> Bool {
        guard let url else { return true }
        do {
            try Data(text.utf8).write(to: url, options: .atomic)
            return true
        } catch {
            return false
        }
    }

    public func search(query: String) {
        searchSerial += 1
        let serial = searchSerial
        let body = JSONValue.object(["query": .string(query), "limit": .number(Double(Self.searchLimit))]).serialized()
        send("POST", "/search", body) { [weak self] status, body in
            guard let self, serial == self.searchSerial else { return }     // 又搜了别的：这个不要了
            self.feed.applySearch(status: status, body: body)
        }
    }

    /// 一次要几条：每组先列四个，「还有 N 个」要有得数（§7 limit 1 到 50）
    nonisolated static let searchLimit = 20

    public func searchThumb(app: String, ref: String) {
        // 查询串里只留 ASCII 字母、数字和 -._~，别的（+ & = / 和非 ASCII）都编码
        send("GET", "/thumb?app=\(Self.segment(app))&ref=\(Self.segment(ref))", nil) { [weak self] status, body in
            guard let self, status == 200, let image = Self.thumbImage(body) else { return }   // 读不到：占位框
            self.model.setThumb(app: app, ref: ref, image: image)
        }
    }

    /// 核心已经核过；这里再看一遍是 JPEG、PNG，不超过 256 KB、长边不超过 2048（工具协议 §1b）
    nonisolated static func thumbImage(_ data: Data) -> NSImage? {
        let jpeg = data.starts(with: [0xFF, 0xD8, 0xFF]), png = data.starts(with: [0x89, 0x50, 0x4E, 0x47])
        guard (jpeg || png), data.count <= 256 * 1024, let rep = NSBitmapImageRep(data: data),
              rep.pixelsWide > 0, rep.pixelsHigh > 0, max(rep.pixelsWide, rep.pixelsHigh) <= 2048 else { return nil }
        let image = NSImage(size: NSSize(width: rep.pixelsWide, height: rep.pixelsHigh))
        image.addRepresentation(rep)
        return image
    }

    public func searchHit(search: Int, app: String, hit: String, action: Int) {
        let body = JSONValue.object(["search": .number(Double(search)), "app": .string(app), "hit": .string(hit),
                                     "action": .number(Double(action))]).serialized()
        send("POST", "/hit", body) { [weak self] status, body in
            guard let self else { return }
            let v = try? JSONValue.parse(body)
            if status != 200 || v?["error"]?.bool == true {
                self.model.show(status == 0 ? WindowModel.offlineFailed : (v?["text"]?.string ?? "没打开。"))
            }
        }
    }

    public func updateSettings(_ patch: [String: JSONValue]) {
        send("POST", "/settings", JSONValue.object(patch).serialized()) { [weak self] status, body in
            guard let self else { return }
            let v = try? JSONValue.parse(body)
            if status == 200, let v {
                self.feed.applySettings(v)
            } else {
                self.model.show(status == 0 ? WindowModel.offlineFailed : (v?["error"]?.string ?? "没改成。"))
                self.reloadSettings()       // 改回核心里现在的值
            }
        }
    }

    public func reloadApps() {
        once("apps", "/apps") { [weak self] status, body in
            guard status == 200, let v = try? JSONValue.parse(body) else { return }
            self?.feed.applyApps(v)
        }
    }

    /// `POST /action` 的答复里要换去的页（`{"page": {"app", "page", "args"}}`，界面接口 §4）。`args` 不对的整个不认
    nonisolated static func openedPage(_ body: Data) -> (String, String, [String: String])? {
        guard let v = try? JSONValue.parse(body), let app = v["page"]?["app"]?.string, let page = v["page"]?["page"]?.string,
              !app.isEmpty, !page.isEmpty else { return nil }
        guard let a = v["page"]?["args"] else { return (app, page, [:]) }
        guard A2UI.pageArgsProblem(a) == nil, let o = a.object else { return nil }
        return (app, page, o.compactMapValues { $0.string })
    }

    /// 取一页基础页；这一页带着参数（§4 pageArgs）时带上。画出来的页写了 `refresh` 时，看得见就过一会儿再取
    public func reloadPage(app: String, page: String) {
        let key = AgentFeed.pageKey(app, page)
        let args = model.pageArgs[key] ?? [:]
        let query = args.isEmpty ? "" : "?" + A2UI.pageQuery(args)
        let path = "/apps/\(Self.segment(app))/pages/\(Self.segment(page))" + query
        once("page:" + key + query, path) { [weak self] status, body in
            guard let self else { return }
            self.feed.applyPage(app: app, page: page, status: status, body: body, args: args)
            self.refreshLater(app: app, page: page)
        }
    }

    /// 页的 root 写了 `refresh`（工具协议 §4 pageRefresh）：过这么久，这一页还看得见（窗口开着、正开在这一页）就再取。
    /// 只认最近定的那次；还没答完的不再取（`once`）
    private func refreshLater(app: String, page: String) {
        let key = AgentFeed.pageKey(app, page)
        let serial = (refreshSerial[key] ?? 0) + 1
        refreshSerial[key] = serial
        guard let n = model.agentPages[key]?.surface?.surface.refreshSeconds else { return }
        after(TimeInterval(n)) { [weak self] in
            guard let self, self.refreshSerial[key] == serial, self.model.visibleAgentPageKey == key,
                  self.lastWindow?["open"]?.bool != false else { return }
            self.reloadPage(app: app, page: page)
        }
    }

    public func openApp(_ app: String, page: String?) {
        var b: [String: JSONValue] = ["app": .string(app)]
        if let page { b["page"] = .string(page) }
        send("POST", "/open", JSONValue.object(b).serialized()) { [weak self] status, body in
            guard let self else { return }
            let (text, error) = Self.answer(status, body)
            if !text.isEmpty { self.model.show(text) } else if error { self.model.show("没打开。") }
        }
    }

    public func reloadPermissions() {
        once("permissions", "/permissions") { [weak self] status, body in
            guard status == 200, let v = try? JSONValue.parse(body) else { return }
            self?.feed.applyPermissions(v)
        }
    }

    /// 打开系统设置的一页（`settings` 的答复里核心给的地址）。螺壳.app 打开，核心不自己开（luoke-core#68）；测试里换掉。
    public var settingsOpener: (URL) -> Void = { NSWorkspace.shared.open($0) }

    public func permission(app: String, id: String, op: String) {
        let body = JSONValue.object(["app": .string(app), "id": .string(id), "op": .string(op)])
        send("POST", "/permissions", body.serialized()) { [weak self] status, data in
            guard let self else { return }
            let (text, error) = Self.answer(status, data)
            // 只认系统设置的地址：核心的对照表里登记过的那几页
            if op == "settings", !error, let s = (try? JSONValue.parse(data))?["url"]?.string,
               s.hasPrefix("x-apple.systempreferences:"), let url = URL(string: s) {
                self.settingsOpener(url)
            }
            self.model.permissionAnswered(app: app, id: id, op: op, text: text, error: error)
            if status != 0 { self.reloadPermissions() }     // 状态照核心现在的画
        }
    }

    /// 螺壳.app 报它自己的权限状态（§10 `POST /host`），也可以经 `WindowModel.reportHostPermissions` 报。
    /// 只报变了的几项；记在内存里，核心重启后连上时整份再报一遍。
    public func reportHost(permissions: [String: JSONValue], confirmed: [String: [String: String]]? = nil) {
        for (k, v) in permissions { host[k] = v == .null ? nil : v }
        if let confirmed { hostConfirmed = confirmed }
        postHost(permissions)
    }

    private func postHost(_ permissions: [String: JSONValue]) {
        var fields: [String: JSONValue] = ["permissions": .object(permissions)]
        if let hostConfirmed {
            fields["confirmed"] = .object(hostConfirmed.mapValues { .object($0.mapValues { .string($0) }) })
        }
        let body = JSONValue.object(fields)
        send("POST", "/host", body.serialized()) { _, _ in }
    }

    /// 螺壳.app 报窗口开没开、在不在最前面（§11）。开着：没关（最小化也算）；在最前面：用户正看着它。
    /// 开着时带上窗口开在哪一页（`page`），换页时这边自己再报（`windowPageChanged`），螺壳.app 不用管
    public func reportWindow(open: Bool, front: Bool) {
        var body: [String: JSONValue] = ["open": .bool(open), "front": .bool(front)]
        if open { body["page"] = .string(model.hostShowing ? "host" : Self.wirePage(model.page)) }   // 本体的界面盖着：不算看着「今天」
        let v = JSONValue.object(body)
        lastWindow = v
        send("POST", "/window", v.serialized()) { _, _ in }
    }

    public func windowPageChanged() {
        guard let w = lastWindow, w["open"]?.bool == true else { return }
        reportWindow(open: true, front: w["front"]?.bool ?? false)
    }

    /// §11 的页名：`today`、`activity`、`app:<配件标识>`、`search`、`settings`、`apps`（添加应用）、`chat`；
    /// 本体的界面（`HostPage`）盖着时报 `host`（`reportWindow`）
    static func wirePage(_ p: Page) -> String {
        if let tool = p.appTool { return "app:" + tool.accessory }
        switch p {
        case .prefs: return "settings"
        case .apps: return "apps"
        default: return p.rawValue
        }
    }

    /// 螺壳.app 报系统通知的授权（§11）：被拒、横幅关着时核心在「今天」里说一句。
    /// status 用 `AgentNotification.authName`；alerts：横幅没被关掉
    public func reportNotifications(status: String, alerts: Bool) {
        let body = JSONValue.object(["status": .string(status), "alerts": .bool(alerts)])
        lastNotifications = body
        send("POST", "/notifications", body.serialized()) { _, _ in }
    }

    /// 看着用户在不在 Mac 前（锁屏、屏幕睡着、空闲多久）：变了马上报，平时每 30 秒报一次，连上时也报（§11）
    public func watchPresence() {
        guard presence == nil else { return }
        let p = Presence()
        p.onChange = { [weak self] in self?.reportPresenceNow() }
        presence = p
        presenceTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.reportPresenceNow() }
        }
        reportPresenceNow()
    }

    private func reportPresenceNow() {
        guard let p = presence else { return }
        reportPresence(idle: p.idleSeconds, locked: p.locked, asleep: p.asleep)
    }

    /// 螺壳.app 报用户在不在（空闲秒数、锁屏、屏幕睡眠）
    public func reportPresence(idle: Double, locked: Bool, asleep: Bool) {
        let body = JSONValue.object(["idle": .number(idle), "locked": .bool(locked), "asleep": .bool(asleep)])
        send("POST", "/presence", body.serialized()) { _, _ in }
    }

    /// 同一样东西同时只取一次；取着的时候又要取，回来以后再取一次（拿到的是最新的）
    private func once(_ key: String, _ path: String, done: @escaping @MainActor (Int, Data) -> Void) {
        if loading.contains(key) { again.insert(key); return }
        loading.insert(key)
        send("GET", path, nil) { [weak self] status, body in
            done(status, body)
            guard let self else { return }
            self.loading.remove(key)
            if self.again.remove(key) != nil { self.once(key, path, done: done) }
        }
    }

    /// `{"text", "error"}` 的答复；连不上、答复不对算出错
    static func answer(_ status: Int, _ body: Data) -> (String, Bool) {
        if status == 0 { return (WindowModel.offlineFailed, true) }
        let v = try? JSONValue.parse(body)
        let text = v?["text"]?.string ?? v?["error"]?.string ?? ""
        return (text, status != 200 || (v?["error"]?.bool ?? false) || v?["error"]?.string != nil)
    }

    /// 路径里的一段（应用、页的 id 本来就只有字母、数字、点、横线、下划线）
    static func segment(_ s: String) -> String {
        let ok = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
        return s.addingPercentEncoding(withAllowedCharacters: ok) ?? s
    }

    /// 在后台发请求，答复回到主线程；连不上时状态码是 0
    private func send(_ method: String, _ path: String, _ body: Data?, done: @escaping @MainActor (Int, Data) -> Void) {
        let transport = self.transport
        DispatchQueue.global(qos: .userInitiated).async {
            let r = (try? transport(method, path, body)) ?? (0, Data())
            DispatchQueue.main.async { MainActor.assumeIsolated { done(r.0, r.1) } }
        }
    }
}
