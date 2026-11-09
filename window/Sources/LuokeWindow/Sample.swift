import Foundation
import LuokeA2UI
import LuokeA2UICore

/// 示例数据：和原型（docs/主窗口原型.html）里的一样。演示窗口、截图、测试都用它；接上 agent 核心以后只给它们用。
@MainActor
public enum Sample {
    /// 一张卡片的一组 A2UI 消息
    static func messages(_ id: String, _ components: [JSONValue], data: JSONValue = .object([:])) -> [JSONValue] {
        [
            .object(["version": .string(A2UI.version), "createSurface": .object(["surfaceId": .string(id), "catalogId": .string(Catalog.agent)])]),
            .object(["version": .string(A2UI.version), "updateComponents": .object(["surfaceId": .string(id), "components": .array(components)])]),
            .object(["version": .string(A2UI.version), "updateDataModel": .object(["surfaceId": .string(id), "path": .string("/"), "value": data])]),
        ]
    }

    private static func text(_ id: String, _ t: String, _ variant: String? = nil) -> JSONValue {
        var o: [String: JSONValue] = ["id": .string(id), "component": .string("Text"), "text": .string(t)]
        if let variant { o["variant"] = .string(variant) }
        return .object(o)
    }

    private static func button(_ id: String, _ label: String, _ event: String, _ ctx: [String: JSONValue] = [:], variant: String? = nil) -> [JSONValue] {
        var o: [String: JSONValue] = ["id": .string(id), "component": .string("Button"), "child": .string("\(id)-t"),
                                      "action": .object(["event": .object(["name": .string(event), "context": .object(ctx)])])]
        if let variant { o["variant"] = .string(variant) }
        return [.object(o), text("\(id)-t", label)]
    }

    private static func node(_ id: String, _ type: String, _ children: [String], justify: String? = nil) -> JSONValue {
        var o: [String: JSONValue] = ["id": .string(id), "component": .string(type), "children": .array(children.map { .string($0) })]
        if let justify { o["justify"] = .string(justify) }
        return .object(o)
    }

    private static func icon(_ id: String, _ name: String) -> JSONValue {
        .object(["id": .string(id), "component": .string("Icon"), "name": .string(name)])
    }

    private static func card(_ id: String, _ tool: ToolIcon, _ time: String?, _ comps: [JSONValue]) -> TodayCard {
        let s = try! Surface.build(messages(id, comps))
        return TodayCard(id: id, tool: tool, time: time, surface: SurfaceModel(surface: s))
    }

    static func cards() -> [TodayCard] {
        [
            card("plan", .mail, "09:02", [
                node("root", "Column", ["h", "list", "acts"]),
                text("h", "5 封新邮件", "h4"),
                node("list", "List", ["l1", "d1", "l2", "d2", "l3"]),
                node("l1", "Row", ["l1t", "l1i"], justify: "spaceBetween"), text("l1t", "王老师 · 答辩时间"), icon("l1i", "reply"),
                .object(["id": .string("d1"), "component": .string("Divider")]),
                node("l2", "Row", ["l2t", "l2i"], justify: "spaceBetween"), text("l2t", "房东 · 续租合同"), icon("l2i", "calendar"),
                .object(["id": .string("d2"), "component": .string("Divider")]),
                node("l3", "Row", ["l3t", "l3i"], justify: "spaceBetween"), text("l3t", "3 封通知"), icon("l3i", "archive"),
                node("acts", "Row", ["b1", "b2"]),
            ] + button("b1", "按这个处理", "mail_apply_plan", ["plan_id": .string("p1")], variant: "primary")
              + button("b2", "逐封看", "mail_open", ["page": .string("inbox")], variant: "borderless")),
            card("ask-mem", .mem, nil, [
                node("root", "Column", ["h", "q", "acts"]),
                text("h", "在准备硕士答辩？", "h4"),
                text("q", "「答辩定在 11 月中旬」—— 王老师", "caption"),
                node("acts", "Row", ["b1", "b2", "b3"]),
            ] + button("b1", "对", "luoke_mem_reply", ["choice": .string("yes")], variant: "primary")
              + button("b2", "不对", "luoke_mem_reply", ["choice": .string("no")])
              + button("b3", "以后再说", "luoke_mem_reply", ["choice": .string("later")], variant: "borderless")),
            card("perm-calendar", .core, nil, [
                node("root", "Column", ["h", "from", "acts"]),
                text("h", "让螺壳读写日历？", "h4"),
                text("from", "邮件助手想把「房东 · 续租合同」加进日程", "caption"),
                node("acts", "Row", ["b1", "b2"]),
            ] + button("b1", "允许", "luoke_request_access", ["permission": .string("calendar")], variant: "primary")
              + button("b2", "先不用", "agent.dismiss", [:], variant: "borderless")),
            card("ai", .scan, nil, [
                node("root", "Row", ["h", "size"], justify: "spaceBetween"),
                text("h", "AI 模型和对话记录", "h4"),
                text("size", "15.5 GB"),
            ]),
        ]
    }

    /// 和 agent 核心推的一样的一串 `/feed` 事件，加上 `feed` 和 `settings`。截图「今天 · 接上核心」和测试用。
    /// 螺壳扫描的卡片是它的场景样例接上真核心得来的（`ToolSample`，默认 `ToolSample.defaultScan`）；
    /// 给了 `mail`（邮件助手录的场景，截图用 `ToolSample.defaultMail`）就用它的，手写的邮件卡片不要；没给照旧手写；记忆、agent 自己的还是手写的
    /// （今天的时刻，截图每天一样）：急事、要你决定、不急的。
    /// `openURL`：多一张带「加入日程」（打开网页）按钮的邮件卡片，按钮上带核心写的 `site`（工具协议 §5）；只在手写邮件时有。
    /// `memory`：带不带记忆那张手写的卡片（beta 2 不带记忆）
    public static func agentEvents(scan: String = ToolSample.defaultScan, mail: String? = nil,
                                   openURL: Bool = false, memory: Bool = true) -> [(String, Data)] {
        func at(_ h: Int, _ m: Int) -> JSONValue {
            let d = Calendar.current.date(bySettingHour: h, minute: m, second: 0, of: Date()) ?? Date()
            return .string(AgentFeed.iso(d))
        }
        func surface(_ id: String, _ comps: [JSONValue]) -> [(String, Data)] {
            messages(id, comps).map { ("a2ui", $0.serialized()) }
        }
        var out: [(String, Data)] = []
        out += surface("luoke-mail/sus-1", [
            node("root", "Row", ["h", "acts"], justify: "spaceBetween"),
            text("h", "可疑邮件：冒充招商银行", "h4"),
            node("acts", "Row", ["b1", "b2"]),
        ] + button("b1", "移到垃圾邮件", "mail_move_junk", ["mail": .string("m9")], variant: "destructive")
          + button("b2", "不是可疑", "mail_not_suspicious", ["mail": .string("m9")]))
        out += surface("luoke-mail/new-1", [
            node("root", "Column", ["h", "list", "acts"]),
            text("h", "4 封新邮件", "h4"),
            node("list", "List", ["l1", "d1", "l2"]),
            node("l1", "Row", ["l1t", "l1i"], justify: "spaceBetween"), text("l1t", "王老师 · 答辩时间"), icon("l1i", "reply"),
            .object(["id": .string("d1"), "component": .string("Divider")]),
            node("l2", "Row", ["l2t", "l2i"], justify: "spaceBetween"), text("l2t", "3 封通知"), icon("l2i", "archive"),
            node("acts", "Row", ["b1", "b2"]),
        ] + button("b1", "按这个处理", "mail_apply_plan", ["plan_id": .string("p2")], variant: "primary")
          + button("b2", "逐封看", "mail_open", ["page": .string("inbox")], variant: "borderless"))
        out += surface("memory/ask-7", [
            node("root", "Column", ["h", "q", "acts"]),
            text("h", "在准备硕士答辩？", "h4"),
            text("q", "「答辩定在 11 月中旬」—— 王老师", "caption"),
            node("acts", "Row", ["b1", "b2"]),
        ] + button("b1", "对", "luoke_mem_reply", ["choice": .string("yes")], variant: "primary")
          + button("b2", "不对", "luoke_mem_reply", ["choice": .string("no")]))
        out += surface("agent/less-1", [
            node("root", "Column", ["t", "acts"]),
            text("t", "「订阅精选」你最近都没看，以后只放在这里，不再提醒。"),
            node("acts", "Row", ["b1", "b2"]),
        ] + button("b1", "还是提醒我", "agent.remind", ["category": .string("luoke-mail:digest")])
          + button("b2", "好", "agent.dismiss"))
        func card(_ id: String, _ app: String, _ kind: String, _ section: String, _ title: String, _ t: JSONValue) -> JSONValue {
            .object(["id": .string(id), "app": .string(app), "kind": .string(kind), "section": .string(section),
                     "title": .string(title), "time": t])
        }
        var order = ["luoke-mail/sus-1", "luoke-mail/new-1", "memory/ask-7", "agent/less-1"]
        var cards = [
            card("luoke-mail/sus-1", "luoke-mail", "suspicious", "urgent", "可疑邮件：冒充招商银行", at(9, 41)),
            card("luoke-mail/new-1", "luoke-mail", "new-mail", "decide", "4 封新邮件", at(9, 2)),
            card("memory/ask-7", "memory", "ask", "decide", "在准备硕士答辩？", at(8, 15)),
            card("agent/less-1", "agent", "less", "later", "以后少提醒「订阅精选」", at(7, 50)),
        ]
        if openURL {
            var go = button("b1", "加入日程", "agent.open_url",
                            ["url": .string("https://calendar.google.com/calendar/render?action=TEMPLATE")])
            if case .object(var o) = go[0] { o["site"] = .string("calendar.google.com"); go[0] = .object(o) }
            out += surface("luoke-mail/cal-1", [
                node("root", "Column", ["h", "q", "acts"]),
                text("h", "答辩定在 11 月 14 日下午", "h4"),
                text("q", "王老师 · 答辩时间", "caption"),
                node("acts", "Row", ["b1"]),
            ] + go)
            order.insert("luoke-mail/cal-1", at: 2)
            cards.insert(card("luoke-mail/cal-1", "luoke-mail", "event", "decide", "答辩定在 11 月 14 日下午", at(9, 5)), at: 2)
        }
        if !memory {
            out.removeAll { e in (try? JSONValue.parse(e.1)).map { m in
                ["createSurface", "updateComponents", "updateDataModel"].contains { m[$0]?["surfaceId"]?.string?.hasPrefix("memory/") == true }
            } ?? false }
            order.removeAll { $0.hasPrefix("memory/") }
            cards.removeAll { $0["app"]?.string == "memory" }
        }
        let mailSample = mail.flatMap { ToolSample.load("luoke-mail", $0) }
        if mailSample != nil {   // 邮件助手的从它的样例来：手写的那几张拿掉
            func handwrittenMail(_ e: (String, Data)) -> Bool {
                guard let m = try? JSONValue.parse(e.1) else { return false }
                let sid = ["createSurface", "updateComponents", "updateDataModel"].lazy.compactMap { m[$0]?["surfaceId"]?.string }.first
                return sid?.hasPrefix("luoke-mail/") == true
            }
            out.removeAll(where: handwrittenMail)
            order.removeAll { $0.hasPrefix("luoke-mail/") }
            cards.removeAll { $0["app"]?.string == "luoke-mail" }
        }
        var feed: JSONValue = .object([
            "order": .array(order.map { .string($0) }),
            "open": .number(Double(order.count - 1)),
            "notices": .array([.string("螺壳搜索现在没在运行。")]),
            "cards": .array(cards),
            "brief": .object(["next": at(8, 0)]),
            "paused_until": .null,
        ])
        for s in [mailSample, ToolSample.load("luoke-scan", scan)].compactMap({ $0 }) {
            out += s.surfaces
            feed = s.merged(into: feed)
        }
        out.append(("feed", feed.serialized()))
        let settings: JSONValue = .object([
            "proactive": .bool(true), "brief": .string("twice"), "quiet": .object(["start": .string("23:00"), "end": .string("07:30")]),
            "paused_until": .null, "modes": .object(["luoke-mail:digest": .string("window")]),
            "kinds": .array([
                .object(["id": .string("luoke-mail:suspicious"), "app": .string("luoke-mail"), "label": .string("可疑邮件"),
                         "mode": .string("now"), "default": .string("now")]),
                .object(["id": .string("luoke-mail:digest"), "app": .string("luoke-mail"), "label": .string("订阅精选"),
                         "mode": .string("window"), "default": .string("brief")]),
                .object(["id": .string("memory:ask"), "app": .string("memory"), "label": .string("记忆想问的"),
                         "mode": .string("brief"), "default": .string("brief")]),
            ]),
        ])
        out.append(("settings", settings.serialized()))
        return out
    }

    /// 和核心的 `GET /apps` 一样的答复：邮件助手（手写，有自己的界面），螺壳扫描（场景样例接上真核心得来的；
    /// 清单里没有 `service.ui`，没有自己的界面）
    public static func agentApps(scan: String = ToolSample.defaultScan, mail: String? = nil) -> Data {
        func refs(_ r: [(String, String)]) -> JSONValue {
            .array(r.map { .object(["id": .string($0.0), "title": .string($0.1)]) })
        }
        func app(_ id: String, _ count: Int, _ summary: String, _ pages: [(String, String)], _ ui: [(String, String)]?,
                 needs: [String]) -> JSONValue {
            .object(["id": .string(id), "running": .bool(true),
                     "summary": .object(["count": .number(Double(count)), "text": .string(summary)]),
                     "pages": refs(pages), "ui": ui.map { .object(["pages": refs($0)]) } ?? .null,
                     "needs": .array(needs.map { .string($0) })])
        }
        let mailApps = mail.flatMap { ToolSample.load("luoke-mail", $0) }?.apps
            ?? [app("luoke-mail", 2, "2 件等你处理", [("overview", "概览"), ("rules", "规则")], [("accounts", "账号")], needs: [])]
        return JSONValue.object(["apps": .array(mailApps + (ToolSample.load("luoke-scan", scan)?.apps ?? []))]).serialized()
    }

    /// 和核心的 `GET /apps/<id>/pages/<页>` 一样的答复（`{"messages": [...]}`）；没有这一页是 nil。
    /// 螺壳扫描的页是场景样例接上真核心得来的。
    public static func agentPage(_ app: String, _ page: String, scan: String = ToolSample.defaultScan,
                                 mail: String? = nil) -> Data? {
        if app == "luoke-scan" { return ToolSample.load(app, scan)?.pages[page]?.serialized() }
        if app == "luoke-mail", let s = mail.flatMap({ ToolSample.load(app, $0) }) { return s.pages[page]?.serialized() }
        let sid = AgentFeed.pageKey(app, page)
        var comps: [JSONValue]
        switch (app, page) {
        case ("luoke-mail", "overview"):
            comps = [
                node("root", "Column", ["h", "t", "acts"]),
                text("h", "邮件助手", "h4"),
                text("t", "2 件等你处理"),
                node("acts", "Row", ["b1"]),
            ] + button("b1", "以后不用点就归档", "mail_auto", ["on": .bool(true)])
        default:
            return nil
        }
        return JSONValue.object(["messages": .array(messages(sid, comps))]).serialized()
    }

    /// 和核心的 `GET /permissions` 一样的答复：邮件助手的（手写）完全磁盘访问在螺壳名下、通讯录要系统弹框、一个账号、
    /// 一件代你做的事、一件每次都问的；螺壳扫描的从场景样例来。螺壳名下的那几项照场景里螺壳.app 报的写，两个应用一样。
    public static func agentPermissions(scan: String = ToolSample.defaultScan, mail: String? = nil) -> Data {
        let sample = ToolSample.load("luoke-scan", scan)
        let mailSample = mail.flatMap { ToolSample.load("luoke-mail", $0) }
        func row(_ app: String, _ id: String, _ kind: String, _ title: String, state: String?, can: [String]?,
                 owner: String? = nil, tcc: String? = nil, facts: [String] = []) -> JSONValue {
            var o: [String: JSONValue] = ["app": .string(app), "id": .string(id), "kind": .string(kind), "title": .string(title),
                                          "state": state.map { .string($0) } ?? .null]
            if let owner { o["owner"] = .string(owner) }
            if let tcc { o["tcc"] = .string(tcc) }
            if !facts.isEmpty { o["facts"] = .array(facts.map { .string($0) }) }
            if let can { o["can"] = .array(can.map { .string($0) }) }
            return .object(o)
        }
        let handwrittenMail = [
            row("luoke-mail", "fda", "system", "完全磁盘访问", state: sample?.host["fda"] ?? "denied", can: ["settings"], owner: "luoke",
                tcc: "SystemPolicyAllFiles", facts: ["读邮件 app 存在本机的邮件"]),
            row("luoke-mail", "contacts", "system", "读通讯录", state: "ask", can: ["request"], tcc: "AddressBook",
                facts: ["认出常联系的人", "只在这台 Mac 上"]),
            row("luoke-mail", "mailbox", "account", "me@example.com", state: "granted", can: ["open", "remove"]),
            row("luoke-mail", "auto", "delegate", "促销邮件不用点就归档", state: "off", can: ["on"]),
            row("luoke-mail", "send", "each-time", "以你的名义发信", state: "ask", can: nil),
        ]
        return JSONValue.object(["rows": .array((mailSample?.permissions ?? handwrittenMail) + (sample?.permissions ?? []))]).serialized()
    }

    /// 把上面三样像核心答的一样交给窗口（截图「螺壳扫描 · 接上核心」「设置 · 权限 · 接上核心」用）
    public static func applyAgentApps(_ feed: AgentFeed, scan: String = ToolSample.defaultScan, mail: String? = nil) {
        if let v = try? JSONValue.parse(agentApps(scan: scan, mail: mail)) { feed.applyApps(v) }
        let scanPages = ToolSample.load("luoke-scan", scan)?.pageIDs ?? []
        let mailPages = mail.flatMap { ToolSample.load("luoke-mail", $0) }?.pageIDs ?? ["overview"]
        for (app, page) in mailPages.map({ ("luoke-mail", $0) }) + scanPages.map({ ("luoke-scan", $0) }) {
            if let d = agentPage(app, page, scan: scan, mail: mail) { feed.applyPage(app: app, page: page, status: 200, body: d) }
        }
        if let v = try? JSONValue.parse(agentPermissions(scan: scan, mail: mail)) { feed.applyPermissions(v) }
    }

    /// 示例里点卡片按钮会怎样（以后由 agent 和工具决定）
    static func handle(_ m: WindowModel, _ card: TodayCard, _ name: String, _ ctx: JSONValue) {
        switch name {
        case "mail_apply_plan":
            m.moveToDone(card.id, row: DoneRow(id: "done-\(card.id)", tool: card.tool, text: "照方案处理 5 封", time: "现在", undoLabel: "撤销"),
                         toast: "照方案处理了 5 封")
        case "luoke_mem_reply":
            switch ctx["choice"]?.string {
            case "yes":
                m.moveToDone(card.id, row: DoneRow(id: "done-\(card.id)", tool: card.tool, text: "记下了：在准备硕士答辩", time: "现在", undoLabel: "撤销"),
                             toast: "记下了")
            case "no":
                m.moveToDone(card.id, row: DoneRow(id: "done-\(card.id)", tool: card.tool, text: "记下了：不在准备答辩", time: "现在", undoLabel: "撤销"),
                             toast: "记下了")
            default:
                m.removeCard(card.id, toast: "以后再问")
            }
        case "luoke_request_access":
            m.requestPermission(ctx["permission"]?.string ?? "")
        case "agent.dismiss":
            m.removeCard(card.id, toast: "先不用了，用到时再问")
        default:
            m.show("这里会打开\(card.tool.name)自己的窗口")
        }
    }

    /// 一份完整的示例窗口
    public static func model(defaults: UserDefaults? = nil) -> WindowModel {
        let m = WindowModel(defaults: defaults)
        m.onCardAction = { handle($0, $1, $2, $3) }
        m.urgent = [UrgentItem(id: "spam", tool: .mail, title: "可疑邮件：冒充招商银行", time: "09:41",
                               primary: "移到垃圾邮件", primarySymbol: "trash", secondary: "不是可疑")]
        m.cards = cards()
        m.done = [
            DoneRow(id: "d1", tool: .scan, text: "清掉 6.4 GB", time: "09:12", undoLabel: "放回"),
            DoneRow(id: "d2", tool: .mail, text: "归档 7 · 加标签 2", time: "08:30", undoLabel: "撤销"),
        ]
        m.quiet = [
            QuietRow(id: "upd-mail", tool: .mail, text: "邮件助手可以升级到 0.18.12", sub: "螺壳来装，你点了才升", action: "升级"),
            QuietRow(id: "digest", tool: .mail, text: "订阅精选 3 篇"),
        ]
        m.activity = [
            ActivityRow(id: "a0", day: "今天", time: "09:41", tool: .mail, auto: true, text: "发现一封冒充招商银行的邮件，放进了「急事」", mark: .urgent),
            ActivityRow(id: "a1", day: "今天", time: "09:12", tool: .scan, auto: true, text: "清掉 6.4 GB", undoLabel: "放回"),
            ActivityRow(id: "a2", day: "今天", time: "08:30", tool: .mail, auto: true, text: "归档 7 · 加标签 2", undoLabel: "撤销"),
            ActivityRow(id: "a3", day: "今天", time: "08:05", tool: .mem, auto: false, text: "在准备答辩：对"),
            ActivityRow(id: "a4", day: "昨天", time: "21:04", tool: .scan, auto: false, text: "3 个安装包 → 废纸篓", undoLabel: "放回"),
            ActivityRow(id: "a5", day: "昨天", time: "20:00", tool: .mail, auto: true, text: "每日复查 · 12 封"),
            ActivityRow(id: "a6", day: "昨天", time: "14:22", tool: .scan, auto: false, text: "放回下载里的重复文件"),
        ]
        m.apps = [
            AppEntry(id: .mail, tool: .mail, version: "0.18.11", update: "0.18.12"),
            AppEntry(id: .scan, tool: .scan, version: "0.1.0"),
            AppEntry(id: .mem, tool: .mem, version: "0.26.0"),
            AppEntry(id: .searchApp, tool: .search, version: "0.4.2"),
        ]
        m.catalog = [
            CatalogApp(id: "mail", tool: .mail, tagline: "守着收件箱", version: "0.18.11 → 0.18.12", state: .update("0.18.12")),
            CatalogApp(id: "ime", tool: .ime, tagline: "越用越懂你说话的方式", version: "0.1.20", state: .installable,
                       facts: ["120 MB", "16 GB 档起", "要启用输入源"]),
            CatalogApp(id: "scan", tool: .scan, tagline: "清掉不会丢东西的", version: "0.1.0", state: .installed),
            CatalogApp(id: "mem", tool: .mem, tagline: "让每个应用更懂你", version: "0.26.0", state: .installed),
            CatalogApp(id: "search", tool: .search, tagline: "答案带出处", version: "0.4.2", state: .installed),
        ]
        m.appPages = [
            .mail: AppPageData(
                tabs: [("overview", "概览", false), ("log", "操作记录", false), ("inbox", "收件箱", true), ("rules", "规则", true)],
                stats: [.init(key: "今天处理", value: "12"), .init(key: "要你回", value: "2"), .init(key: "自动归档", value: "7")],
                listTitle: "要你回",
                lines: [.init(id: "m1", title: "王老师 · 答辩时间", badge: "周五", action: "起草"),
                        .init(id: "m2", title: "房东 · 续租合同", action: "起草")],
                latest: false),
            .scan: AppPageData(
                tabs: [("overview", "概览", false), ("log", "清理记录", false)],
                stats: [.init(key: "这周清掉", value: "6.4 GB"), .init(key: "要你决定", value: "26.6 GB"), .init(key: "可用", value: "38 GB")],
                listTitle: "要你决定",
                lines: [.init(id: "s1", title: "AI 模型和对话记录", meta: "15.5 GB"),
                        .init(id: "s2", title: "很久没打开的大文件", meta: "6.3 GB"),
                        .init(id: "s3", title: "很久没改的项目", meta: "4.8 GB")],
                latest: true, hasUI: false),
            .mem: AppPageData(
                tabs: [("overview", "概览", false), ("recent", "最近记下的", false)],
                stats: [.init(key: "记下的", value: "1,284"), .init(key: "理解", value: "46"), .init(key: "想问你", value: "1")],
                listTitle: "想问你",
                lines: [.init(id: "q1", title: "在准备硕士答辩？", action: "对", action2: "不对")],
                latest: true),
        ]
        m.searchQuery = "租房合同"
        m.searchSections = [
            SearchSection(id: "top", title: "最相关", hits: [
                SearchHit(id: "h1", tool: .search, title: "租房合同.pdf", meta: "第 3 页 · 10-03", snippet: "…押金两个月，退租前 30 天书面通知…", reveal: true),
                SearchHit(id: "h2", tool: .mail, title: "房东 · 续租合同", meta: "10-24", snippet: "合同 11 月底到期，续租的话押金不变…"),
            ]),
            SearchSection(id: "files", title: "文件", count: 12, hits: [
                SearchHit(id: "h3", tool: .search, title: "租房合同（旧）.docx", meta: "2025-10-02", snippet: "…甲方：…乙方：…租期一年…", similar: true),
                SearchHit(id: "h4", tool: .search, title: "押金收据.png", meta: "截图 · 10-05", snippet: "…收到押金 ¥9,000…", similar: true),
            ]),
            SearchSection(id: "mail", title: "邮件 · me@example.com", count: 3, hits: [
                SearchHit(id: "h5", tool: .mail, title: "中介 · 房源确认", meta: "2025-09-28", snippet: "…合同下周一签，带身份证…"),
            ]),
            SearchSection(id: "photos", title: "照片和视频", hits: [], needsPermission: "photos"),
        ]
        m.kinds = [
            KindSetting(id: "spam", tool: .mail, title: "可疑邮件", level: .now),
            KindSetting(id: "security", tool: .scan, title: "安全问题", level: .now),
            KindSetting(id: "sorted", tool: .mail, title: "新邮件分拣好了", level: .brief),
            KindSetting(id: "cleaned", tool: .scan, title: "清理结果", level: .brief),
            KindSetting(id: "asks", tool: .mem, title: "记忆想问你的", level: .brief),
        ]
        m.permissions = [
            PermissionRow(id: "calendar", owner: .core, title: "日历", state: .waiting),
            PermissionRow(id: "fda", owner: .core, title: "完全磁盘访问", sub: "螺壳扫描、螺壳搜索在用", state: .granted),
            PermissionRow(id: "photos", owner: .search, title: "照片", state: .notYet),
        ]
        m.accounts = [PermissionRow(id: "mailbox", owner: .mail, title: "me@example.com", sub: "授权码在钥匙串里", state: .granted)]
        m.delegates = [
            DelegateRow(id: "autoclean", tool: .scan, title: "不用点就清 4 类", on: true),
            DelegateRow(id: "archive", tool: .mail, title: "按习惯归档促销邮件", on: true),
            DelegateRow(id: "confirm", tool: .mail, title: "替你回确认类邮件", on: false),
        ]
        m.eachTime = [
            EachTimeRow(id: "admin", tool: .scan, title: "删系统目录里的东西", why: "每次都要输入 Mac 的密码"),
            EachTimeRow(id: "send", tool: .mail, title: "以你的名义发信", why: "每次都要你点"),
        ]
        m.tiers = [
            ModelTier(id: "16", title: "16 GB 档", model: "Qwen3.5-9B", size: "10 GB"),
            ModelTier(id: "32", title: "32 GB 档", model: "Qwen3.5-9B", size: "20 GB"),
            ModelTier(id: "128", title: "128 GB 档", model: "gemma-4-26B", size: "48 GB"),
        ]
        m.currentTier = "32"
        m.answers = [
            "today": Answer(question: "今天先做哪件？", text: "先处理可疑邮件，再回王老师（周五前）。",
                            rows: [.init(id: "r1", tool: .mail, title: "可疑邮件", action: "移到垃圾邮件"),
                                   .init(id: "r2", tool: .mail, title: "王老师 · 答辩时间", action: "起草")]),
            "scan": Answer(question: "这 15.5 GB 里哪些能删？", text: "3 样能动，腾出 11.5 GB。",
                           rows: [.init(id: "r1", tool: .scan, title: "Ollama · llama3.1:8b  4.7 GB", action: ""),
                                  .init(id: "r2", tool: .scan, title: "Hugging Face · Qwen3.5-9B  5.6 GB", action: ""),
                                  .init(id: "r3", tool: .scan, title: "Claude Code · 90 天前  1.2 GB", action: "")],
                           primary: "按这个处理"),
            "mail": Answer(question: "王老师那封怎么回？", text: "王老师好，\n周五下午三点以后我都可以，材料周四发您。\n谢谢！", primary: "放进草稿箱"),
            "search": Answer(question: "押金怎么退？", text: "押金是两个月，退租前 30 天书面通知房东，交房后退（合同第 3 页）。",
                             rows: [.init(id: "r1", tool: .search, title: "租房合同.pdf · 第 3 页", action: "打开"),
                                    .init(id: "r2", tool: .mail, title: "房东 · 续租合同", action: "打开")]),
            "default": Answer(question: "这个是什么？", text: "这是演示：在「今天」「螺壳扫描」「邮件助手」上问，回答不一样。"),
        ]
        return m
    }
}
