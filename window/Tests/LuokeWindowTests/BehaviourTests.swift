import LuokeA2UICore
import XCTest
@testable import LuokeWindow

/// 界面行为：照原型自带的检查（docs/主窗口原型.html 的 #selftest）一条条对过来，点的是窗口的模型，和界面上点按钮走同一条路。
@MainActor
final class BehaviourTests: XCTestCase {
    var defaults: UserDefaults!
    var m: WindowModel!

    override func setUp() async throws {
        let suite = "luoke.window.tests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suite)
        defaults.removePersistentDomain(forName: suite)
        m = Sample.model(defaults: defaults)
    }

    func button(_ card: TodayCard, _ event: String) -> (String, JSONValue) {
        let s = card.surface.surface
        let id = s.reachable().first { s.components[$0]?["component"]?.string == "Button" && s.components[$0]?["action"]?["event"]?["name"]?.string == event }!
        let (name, ctx) = try! s.action(id)
        return (name, ctx)
    }

    // MARK: 侧栏

    func testSidebarHasFourRowsAndAppsCollapsed() {
        XCTAssertFalse(m.appsExpanded)
        XCTAssertEqual(m.apps.map(\.tool), [.mail, .scan, .mem, .search])
        XCTAssertEqual(m.todayCount, 4, "只算要你决定的 4 件，和「一件件处理」一样；急事 1 件另外是红点")
        XCTAssertTrue(m.hasUrgent)
    }

    func testAppsRowLightsUpOnAppPageWhenCollapsed() {
        XCTAssertNil(m.appsNow, "在「今天」：小图标都照常")
        m.go(.scan)
        XCTAssertTrue(m.appsRowLit)
        XCTAssertEqual(m.appsNow, .scan, "小图标里扫描的亮着")
        XCTAssertEqual(m.appsNowName, "螺壳扫描")
        m.go(.apps)
        XCTAssertTrue(m.appsRowLit)
        XCTAssertNil(m.appsNow, "「添加应用」不是哪个应用：这一行亮着，小图标都照常")
        m.go(.scan)
        m.toggleApps()
        XCTAssertFalse(m.appsRowLit, "展开了就不用这一行替它亮")
        XCTAssertNil(m.appsNow)
        m.toggleApps()
        m.go(.today)
        XCTAssertFalse(m.appsRowLit)
    }

    func testSidebarCollapsesToIconRailAndRemembers() {
        m.toggleSidebar()
        XCTAssertTrue(m.sidebarMini)
        XCTAssertTrue(defaults.bool(forKey: WindowModel.sidebarKey))
        let again = Sample.model(defaults: defaults)
        XCTAssertTrue(again.sidebarMini, "收起还是展开记在这台 Mac 上")
        m.toggleApps()
        XCTAssertTrue(Sample.model(defaults: defaults).appsExpanded)
    }

    func testModelNameOpensModelSettings() {
        m.go(.activity)
        m.go(.prefs, tab: PrefsTab.model.rawValue)   // 侧栏底部的模型名就是这样跳的
        XCTAssertEqual(m.page, .prefs)
        XCTAssertEqual(m.prefsTab, .model)
    }

    // MARK: 今天

    func testApplyPlanMovesCardToDoneAndUndoBringsItBack() {
        let plan = m.cards.first { $0.id == "plan" }!
        let (name, ctx) = button(plan, "mail_apply_plan")
        XCTAssertEqual(ctx["plan_id"]?.string, "p1")
        m.tap(card: plan, name: name, context: ctx)
        XCTAssertFalse(m.cards.contains { $0.id == "plan" })
        XCTAssertEqual(m.done.first?.text, "照方案处理 5 封")
        XCTAssertEqual(m.todayCount, 3)
        XCTAssertEqual(m.toast?.canUndo, true)
        m.undoLast()
        XCTAssertTrue(m.cards.contains { $0.id == "plan" })
        XCTAssertFalse(m.done.contains { $0.text == "照方案处理 5 封" })
        XCTAssertEqual(m.cards.first?.id, "plan", "放回原来的位置")
    }

    func testPermissionCardOpensSheetAndGrantClearsIt() {
        let card = m.cards.first { $0.id == "perm-calendar" }!
        let (name, ctx) = button(card, "luoke_request_access")
        m.tap(card: card, name: name, context: ctx)
        XCTAssertEqual(m.sheet?.title, "读写日历")
        m.continueSheet()
        XCTAssertNil(m.sheet)
        XCTAssertFalse(m.cards.contains { $0.id == "perm-calendar" })
        XCTAssertEqual(m.permissions.first { $0.id == "calendar" }?.state, .granted)
    }

    func testUndoDoneRow() {
        m.undoDone("d1")
        XCTAssertTrue(m.done.first { $0.id == "d1" }!.undone)
        XCTAssertEqual(m.toast?.text, "放回了")
        m.undoLast()
        XCTAssertFalse(m.done.first { $0.id == "d1" }!.undone)
    }

    // MARK: 今天的顺序

    func testDoneComesBeforeDecide() {
        XCTAssertEqual(m.todaySections, [.urgent, .done, .decide, .later], "急事、替你做了、要你决定、顺便看看")
        m.done = []
        XCTAssertEqual(m.todaySections, [.urgent, .decide, .later], "没替你做过事，这一段不出现")
    }

    func testDoneShowsThreeRowsThenMore() {
        let rows = (1...5).map { DoneRow(id: "d\($0)", tool: .mail, text: "第 \($0) 件", time: "09:0\($0)", undoLabel: "撤销") }
        let few = TodayPage.visibleDone(rows, all: false)
        XCTAssertEqual(few.rows.map(\.id), ["d1", "d2", "d3"])
        XCTAssertEqual(few.more, 2, "多的写「还有 2 件」")
        let all = TodayPage.visibleDone(rows, all: true)
        XCTAssertEqual(all.rows.count, 5)
        XCTAssertEqual(all.more, 0)
        XCTAssertEqual(TodayPage.visibleDone(Array(rows.prefix(3)), all: false).more, 0, "三件以内不写「还有」")
    }

    func testDoneShowsTwoRowsWhenSomethingWaitsForTheUser() {
        let rows = (1...5).map { DoneRow(id: "d\($0)", tool: .mail, text: "第 \($0) 件", time: "09:0\($0)", undoLabel: "撤销") }
        let few = TodayPage.visibleDone(rows, all: false, deciding: true)
        XCTAssertEqual(few.rows.map(\.id), ["d1", "d2"], "下面有「要你决定」：只露 2 行")
        XCTAssertEqual(few.more, 3)
        XCTAssertEqual(TodayPage.visibleDone(Array(rows.prefix(3)), all: false, deciding: true).more, 0, "只多 1 件就列出来，不写「还有 1 件」")
        XCTAssertEqual(TodayPage.visibleDone(rows, all: true, deciding: true).rows.count, 5)
    }

    func testEveryAppHasItsIcon() {
        for t in ToolIcon.allCases { XCTAssertNotNil(Resources.image(t.imageName), "\(t.name) 的图标") }
        XCTAssertNotNil(Resources.image("badge"), "侧栏顶上的粉底方块")
        XCTAssertNotNil(Resources.image("conch-peek"), "吉祥物")
        XCTAssertEqual(ToolIcon.search.name, "螺壳搜索")
    }

    func testUndoOnTheDoneRowBringsTheCardBack() {
        let plan = m.cards.first { $0.id == "plan" }!
        let (name, ctx) = button(plan, "mail_apply_plan")
        m.tap(card: plan, name: name, context: ctx)
        XCTAssertEqual(m.done.first?.id, "done-plan")
        XCTAssertEqual(m.activity.first?.mark, .new, "「活动」里记一条，点是强调色")
        m.undoDone("done-plan")
        XCTAssertEqual(m.cards.first?.id, "plan", "卡片回到原来的位置")
        XCTAssertFalse(m.done.contains { $0.id == "done-plan" })
        XCTAssertFalse(m.activity.contains { $0.id == "act-done-plan" })
        m.undoLast()
        XCTAssertEqual(m.cards.filter { $0.id == "plan" }.count, 1, "提示上的撤销不再放一次")
    }

    func testEmptyDecideStillShowsItsSection() {
        m.cards = []
        XCTAssertEqual(m.todaySections, [.urgent, .done, .decide, .later], "要你决定空了画一句「今天没什么要你操心的」")
    }

    // MARK: 一件件处理

    func testFocusShowsOneCardAtATime() {
        XCTAssertNil(m.focus)
        m.enterFocus()
        XCTAssertEqual(m.focus?.ids, ["plan", "ask-mem", "perm-calendar", "ai"])
        XCTAssertEqual(m.focusCurrent?.id, "plan")
        m.skipFocus(viaKey: true)
        XCTAssertEqual(m.focusCurrent?.id, "ask-mem", "↓ 跳过")
        XCTAssertEqual(m.focus?.viaKey, true)
        m.answerFocusPrimary()
        XCTAssertFalse(m.cards.contains { $0.id == "ask-mem" }, "⏎ 答主要的那个（对）")
        XCTAssertEqual(m.done.first?.text, "记下了：在准备硕士答辩")
        XCTAssertEqual(m.focusAnswered, 1)
        XCTAssertEqual(m.focusCurrent?.id, "perm-calendar")
        m.skipFocus()
        m.skipFocus()
        XCTAssertNil(m.focusCurrent, "过完一遍")
        XCTAssertEqual(m.focusLeft, 3, "跳过的三件还在「今天」里")
        m.exitFocus()
        XCTAssertNil(m.focus)
        XCTAssertEqual(m.page, .today)
    }

    func testFocusEndsWithNothingLeftWhenAllAnswered() throws {
        m.enterFocus()
        for id in try XCTUnwrap(m.focus?.ids) {   // 有按钮的都点一下；工具还没答完的先跳过
            guard let c = m.focusCurrent, c.id == id, let a = SurfaceDigest(c.surface.surface).actions.first else { continue }
            m.answerFocus(a.id)
            if m.focusCurrent?.id == id { m.skipFocus() }
        }
        XCTAssertEqual(m.focus?.tapped, ["plan", "ask-mem", "perm-calendar"], "「ai」那张没有按钮，点不了")
        m.cards = []   // 工具都答完了，收走
        XCTAssertNil(m.focusCurrent)
        XCTAssertEqual(m.focusLeft, 0)
        XCTAssertEqual(m.focusAnswered, 3, "点过的三件算答了；没点过的「ai」被收走不算")
    }

    func testFocusDoesNotCountCardsTheToolsTookBack() {
        m.enterFocus()
        m.cards = []
        XCTAssertNil(m.focusCurrent)
        XCTAssertEqual(m.focusLeft, 0)
        XCTAssertEqual(m.focusAnswered, 0, "用户没点：工具收走的不算答了")
        XCTAssertEqual(m.focus?.ids, [], "收走的从这一轮里去掉")
    }

    func testFocusStaysPutWhenAToolReplacesTheCard() throws {
        m.enterFocus()
        m.skipFocus()
        let c = try XCTUnwrap(m.focusCurrent)
        XCTAssertEqual(c.id, "ask-mem")
        // 工具把正看着的这张换成新编号（邮件的方案重算时就会这样）
        var cards = m.cards
        let i = try XCTUnwrap(cards.firstIndex { $0.id == c.id })
        cards[i] = TodayCard(id: "ask-mem-2", tool: c.tool, time: c.time, surface: c.surface)
        m.cards = cards
        XCTAssertEqual(m.focusAnswered, 0, "用户没点，不算答了")
        XCTAssertEqual(m.focusCurrent?.id, "ask-mem-2", "还在这一件，摆换上来的那张")
        XCTAssertEqual(m.focus?.ids, ["plan", "ask-mem-2", "perm-calendar", "ai"], "新的顶在原来的位置")
        // 跳过了的被换掉，换上来的照旧算跳过
        cards = m.cards
        let j = try XCTUnwrap(cards.firstIndex { $0.id == "plan" })
        cards[j] = TodayCard(id: "plan-2", tool: cards[j].tool, time: cards[j].time, surface: cards[j].surface)
        m.cards = cards
        XCTAssertEqual(m.focus?.skipped.contains("plan-2"), true)
        XCTAssertEqual(m.focusCurrent?.id, "ask-mem-2")
        // 点了以后不见了，才算答了
        m.answerFocusPrimary()
        XCTAssertEqual(m.focusAnswered, 1)
        XCTAssertEqual(m.focusCurrent?.id, "perm-calendar")
    }

    func testFocusNeedsSomethingToDecideAndLeavesOnNavigation() {
        let cards = m.cards
        m.cards = []
        m.enterFocus()
        XCTAssertNil(m.focus, "没有要你决定的：按钮是灰的，也进不去")
        m.cards = cards
        m.enterFocus()
        m.go(.prefs)
        XCTAssertNil(m.focus, "去别的页就收起")
    }

    func testCardDigestFindsTitleDetailAndPrimary() {
        let plan = SurfaceDigest(m.cards[0].surface.surface)
        XCTAssertEqual(plan.title, "5 封新邮件")
        XCTAssertEqual(plan.detail, "王老师 · 答辩时间 · 房东 · 续租合同 · 3 封通知")
        XCTAssertEqual(plan.actions.map(\.label), ["按这个处理", "逐封看"])
        XCTAssertEqual(plan.primary?.label, "按这个处理")
        let ask = SurfaceDigest(m.cards[1].surface.surface)
        XCTAssertEqual(ask.primary?.label, "对", "标了 primary 的")
        XCTAssertEqual(m.cards[1].displayTitle, "在准备硕士答辩？")
        XCTAssertFalse(plan.hasInputs)
    }

    func testCardDigestListsSitesAndSeesInputs() throws {
        let messages = try JSONValue.parse(#"""
        [{"version": "v0.9", "createSurface": {"surfaceId": "t1", "catalogId": "ai.luoke/a2ui/agent/1"}},
         {"version": "v0.9", "updateComponents": {"surfaceId": "t1", "components": [
           {"id": "root", "component": "Column", "children": ["h", "f", "acts"]},
           {"id": "h", "component": "Text", "text": "交回什么", "variant": "h4"},
           {"id": "f", "component": "TextField", "label": "内容", "value": {"path": "/note"}},
           {"id": "acts", "component": "Row", "children": ["b1", "b2", "b3"]},
           {"id": "b1", "component": "Button", "child": "b1-t", "action": {"event": {"name": "mem.reply", "context": {"text": {"path": "/note"}}}}},
           {"id": "b1-t", "component": "Text", "text": "交回"},
           {"id": "b2", "component": "Button", "child": "b2-t", "site": "example.com", "action": {"event": {"name": "agent.open_url", "context": {"url": "https://example.com/a"}}}},
           {"id": "b2-t", "component": "Text", "text": "打开网页"},
           {"id": "b3", "component": "Button", "child": "b3-t", "action": {"event": {"name": "agent.open_url", "context": {"url": "https://example.org/"}}}},
           {"id": "b3-t", "component": "Text", "text": "没写网站"}]}},
         {"version": "v0.9", "updateDataModel": {"surfaceId": "t1", "path": "/", "value": {"note": ""}}}]
        """#).array!
        let d = SurfaceDigest(try Surface.build(messages))
        XCTAssertTrue(d.hasInputs, "有输入框：紧凑的表里这一行不给按钮，给「展开」")
        XCTAssertEqual(d.actions.map(\.label), ["交回", "打开网页"], "打开网页、没写 site 的不列")
        XCTAssertEqual(d.actions.map(\.site), [nil, "example.com"], "网站画在按钮后面")
        XCTAssertNil(d.primary, "没标 primary：⏎ 不答")
    }

    func testFocusAnswersOnceWhileTheCardIsBusy() throws {
        m.enterFocus()
        m.skipFocus()
        let c = try XCTUnwrap(m.focusCurrent)
        XCTAssertEqual(c.id, "ask-mem")
        c.surface.busy = true
        m.answerFocusPrimary()
        m.answerFocus("b2")
        XCTAssertTrue(m.cards.contains { $0.id == "ask-mem" }, "上一下点按还没答完：⏎、按钮都不再交")
        XCTAssertEqual(m.focusAnswered, 0)
        c.surface.busy = false
        m.answerFocusPrimary()
        XCTAssertFalse(m.cards.contains { $0.id == "ask-mem" })
    }

    // MARK: 简报

    func testBriefIsBuiltFromToday() {
        m.go(.activity)
        m.openBrief(time: "08:00")
        XCTAssertEqual(m.page, .today, "点了简报的通知回「今天」")
        let note = try! XCTUnwrap(m.briefNote)
        XCTAssertEqual(note.title, "今早的简报")
        XCTAssertEqual(note.done, ["清掉 6.4 GB", "归档 7 · 加标签 2"])
        XCTAssertEqual(note.urgent, ["可疑邮件：冒充招商银行"])
        XCTAssertEqual(note.pending.map(\.id), ["plan", "ask-mem", "perm-calendar", "ai"])
        XCTAssertEqual(note.sentence, "还有 4 件等你：5 封新邮件、在准备硕士答辩、让螺壳读写日历等；急事：可疑邮件：冒充招商银行；替你做了 2 件。")
        m.closeBrief()
        XCTAssertNil(m.briefNote)
    }

    func testBriefTextStrikesWhatWasAnswered() {
        m.openBrief(time: "08:00")
        let note = m.briefNote!
        let plan = m.cards.first { $0.id == "plan" }!
        let (name, ctx) = button(plan, "mail_apply_plan")
        m.tap(card: plan, name: name, context: ctx)
        let text = BriefNoteView.text(note, open: Set(m.cards.map(\.id)), p: .light)
        let runs = text.runs.filter { String(text[$0.range].characters) == "5 封新邮件" }
        XCTAssertEqual(runs.count, 1)
        XCTAssertNil(runs.first?.link, "答了的不能点了")
        XCTAssertNotNil(text.runs.first { String(text[$0.range].characters) == "在准备硕士答辩" }?.link, "还没答的能点")
        XCTAssertFalse(String(text.characters).contains("？、"), "列在一起的标题不带问号")
        XCTAssertTrue(String(text.characters).hasPrefix("替你做了 2 件：清掉 6.4 GB、归档 7 · 加标签 2。可疑邮件：冒充招商银行，先看这件。还有 4 件等你："))
    }

    func testBriefNotificationOpensTheBrief() {
        m.go(.prefs)
        m.openNotification([AgentNotification.userInfoKey: "brief"])
        XCTAssertEqual(m.page, .today)
        XCTAssertNotNil(m.briefNote)
        m.closeBrief()
        m.openNotification([AgentNotification.userInfoKey: "luoke-mail/sus-1", "surfaceId": "luoke-mail/sus-1"])
        XCTAssertNil(m.briefNote, "急事的通知只回「今天」")
        m.go(.prefs)
        m.openNotification(["notes": "beta1"])
        XCTAssertEqual(m.page, .prefs, "不是核心发的不管")
    }

    // MARK: 设置 · 显示

    func testDensityIsRememberedForThisWindow() {
        XCTAssertEqual(m.density, .standard)
        m.setDensity(.compact)
        XCTAssertEqual(defaults.string(forKey: WindowModel.densityKey), "compact")
        XCTAssertEqual(Sample.model(defaults: defaults).density, .compact, "下次打开还是紧凑")
        XCTAssertEqual(Sample.model().density, .standard, "别的窗口照旧")
        XCTAssertEqual(PrefsTab.allCases.map(\.title), ["提醒", "显示", "权限", "模型", "隐私"])
    }

    // MARK: 活动

    func testActivityMarksUrgentAndNew() {
        XCTAssertEqual(m.activity.first?.mark, .urgent)
        XCTAssertEqual(days(m.activity), ["今天", "昨天"])
    }

    func testUpgradeRemovesUpdateEverywhere() {
        m.upgrade(.mail)
        XCTAssertNil(m.apps.first { $0.tool == .mail }?.update)
        XCTAssertFalse(m.quiet.contains { $0.id == "upd-mail" })
        XCTAssertEqual(m.catalog.first { $0.tool == .mail }?.state, .installed)
    }

    // MARK: 问螺壳

    func testAskAnswersByPageAndPins() {
        m.go(.scan)
        m.openAsk()
        XCTAssertTrue(m.askOpen)
        XCTAssertTrue(m.answer!.text.contains("11.5 GB"))
        let before = m.cards.count
        m.pinAnswer()
        XCTAssertFalse(m.askOpen)
        XCTAssertEqual(m.cards.count, before + 1)
        XCTAssertEqual(m.cards.first?.tool, .core)
    }

    func testGoingSomewhereClosesAsk() {
        m.openAsk()
        m.go(.search)
        XCTAssertFalse(m.askOpen)
        m.openAsk()
        XCTAssertTrue(m.answer!.text.contains("第 3 页"), "在搜索页问，回答带出处")
    }

    func testExpandAnswerOpensChat() {
        m.openAsk()
        m.expandAnswer()
        XCTAssertEqual(m.page, .chat)
        XCTAssertEqual(m.chat.count, 2)
    }

    // MARK: 设置

    func testBriefDefaultsToMorning() {
        XCTAssertEqual(m.brief, .morning)
        XCTAssertEqual(BriefMode.allCases.map(\.rawValue), ["每天早上", "早晚各一次", "只在我打开时"])
        XCTAssertEqual(m.kinds.filter { $0.level == .now }.map(\.title), ["可疑邮件", "安全问题"], "默认只有这两类当场说")
    }

    func testSettingsChanges() {
        m.setLevel("sorted", .off)
        XCTAssertEqual(m.kinds.first { $0.id == "sorted" }?.level, .off)
        m.setTier("128")
        XCTAssertEqual(m.currentTier, "128")
        m.setDelegate("confirm", on: true)
        XCTAssertEqual(m.delegates.first { $0.id == "confirm" }?.on, true)
    }

    // MARK: 顶部菜单和菜单栏图标

    func testGoMenuIsTheFullSetOfEntries() {
        let go = m.topMenus.first { $0.id == "go" }!
        let titles = go.items.filter { $0.kind == .item }.map(\.title)
        XCTAssertEqual(titles, ["今天", "活动", "搜索或问螺壳", "螺壳邮件助手", "螺壳扫描", "记忆", "螺壳搜索", "添加应用…", "权限", "模型"])
        XCTAssertEqual(m.topMenus.map(\.title), ["螺壳", "编辑", "显示", "前往", "窗口", "帮助"])
    }

    func testTopMenusCarryNoCountsOrState() {
        let all = m.topMenus.flatMap(\.items).map(\.title).joined()
        for word in ["有新版本", "等你", "想问你", "急事"] { XCTAssertFalse(all.contains(word), word) }
    }

    func testGoMenuItemsGoToTheirPages() {
        let go = m.topMenus.first { $0.id == "go" }!
        m.perform(go.items.first { $0.title == "螺壳扫描" }!.action)
        XCTAssertEqual(m.page, .scan)
        m.perform(go.items.first { $0.title == "权限" }!.action)
        XCTAssertEqual(m.page, .prefs)
        XCTAssertEqual(m.prefsTab, .permissions)
        m.perform(go.items.first { $0.title == "模型" }!.action)
        XCTAssertEqual(m.prefsTab, .model)
        m.perform(go.items.first { $0.title == "搜索或问螺壳" }!.action)
        XCTAssertEqual(m.page, .today)
        XCTAssertTrue(m.askOpen)
    }

    func testViewMenuTogglesSidebarAndRenames() {
        let item = { self.m.topMenus.first { $0.id == "view" }!.items.first { $0.id == "sidebar" }! }
        XCTAssertEqual(item().title, "收起侧栏")
        m.perform(item().action)
        XCTAssertTrue(m.sidebarMini)
        XCTAssertEqual(item().title, "展开侧栏")
    }

    func testStatusMenuOnlyHasWhatMatters() {
        let ids = m.statusMenu.items.filter { $0.kind != .separator }.map(\.id)
        XCTAssertEqual(ids, ["state", "h-urgent", "urgent-spam", "open", "pause", "quit"])
        XCTAssertTrue(m.hasUrgent)
        m.handleUrgent("spam", primary: true)
        XCTAssertFalse(m.hasUrgent)
        XCTAssertFalse(m.statusMenu.items.contains { $0.id.hasPrefix("urgent") })
        m.undoLast()
        XCTAssertTrue(m.hasUrgent, "撤销以后急事回来")
    }

    func testPauseShowsUntilWhen() {
        m.perform(.pause)
        XCTAssertEqual(m.statusMenu.items.first?.title, "螺壳在运行 · 提醒暂停到 11:02")
        XCTAssertEqual(m.statusMenu.items.first { $0.id == "pause" }?.title, "恢复提醒")
        m.perform(.pause)
        XCTAssertNil(m.pausedUntil)
    }

    func testInstalledAppsShowUpInGoMenu() {
        m.apps.append(AppEntry(id: .apps, tool: .ime, version: "0.1.20"))
        XCTAssertTrue(m.topMenus.first { $0.id == "go" }!.items.contains { $0.title == "螺壳输入法" })
    }
}
