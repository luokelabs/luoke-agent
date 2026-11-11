import LuokeA2UI
import XCTest
@testable import LuokeWindow

/// 「今天」按类处理：要你决定同一类的挨着，一件件处理照页上的次序走，「按类处理」里点一类就只走这一类
@MainActor
final class DecideCategoryTests: XCTestCase {
    private var m: WindowModel!
    private var surface: SurfaceModel!

    override func setUp() async throws {
        m = Sample.model()
        surface = m.cards[0].surface
    }

    private func card(_ id: String, _ tool: ToolIcon, _ kind: String, title: String = "一件事") -> TodayCard {
        TodayCard(id: id, tool: tool, time: nil, surface: surface, title: title, kind: kind)
    }

    /// 邮件 2 件、记忆 2 件、扫描 1 件，核心给的次序是交错的
    private func mixed() -> [TodayCard] {
        [card("m1", .mail, "new-mail"), card("a1", .mem, "question"), card("m2", .mail, "new-mail"),
         card("s1", .scan, "findings"), card("a2", .mem, "question")]
    }

    func testFocusWalksKindByKindInPageOrder() {
        m.cards = mixed()
        XCTAssertEqual(m.decideCategories.map(\.ids), [["m1", "m2"], ["a1", "a2"], ["s1"]], "照第一张出现的位置，同一类的挨着")
        m.enterFocus()
        XCTAssertEqual(m.focus?.ids, ["m1", "m2", "a1", "a2", "s1"], "一类处理完再下一类，和「今天」页上一个次序")
        XCTAssertNil(m.focus?.categoryName, "从页头进来的不写类名")
    }

    func testKindNamesFromTheCoreElseTheApp() {
        m.cards = mixed()
        m.kinds = [KindSetting(id: "luoke-scan:new-mail", tool: .scan, title: "别的应用的同名类", level: .brief),
                   KindSetting(id: "luoke-mail:new-mail", tool: .mail, title: "新邮件分拣好了", level: .brief),
                   KindSetting(id: "luoke-mem:question", tool: .mem, title: WindowModel.unnamedKind, level: .brief)]
        XCTAssertEqual(m.decideCategories.map(\.name), ["新邮件分拣好了", "记忆", "螺壳扫描"],
                       "核心给的名字；核心说不出名字（「这一类事」）或没有这一类时写应用的名字；别的应用的同名类不算")
    }

    func testPicksOnlyWhenThereIsMoreThanOneKind() {
        m.cards = mixed()
        XCTAssertEqual(m.categoriesToPick.map(\.ids), [["m1", "m2"], ["a1", "a2"]], "只有一件的那一类不列：点开那张卡片就是了")
        m.cards = (1...5).map { card("m\($0)", .mail, "new-mail") }
        XCTAssertEqual(m.categoriesToPick, [], "只有一类：页头的「一件件处理」就是它")
        m.cards = [card("m1", .mail, "new-mail"), card("a1", .mem, "question"), card("s1", .scan, "findings")]
        XCTAssertEqual(m.categoriesToPick, [], "每类都只有一件：不列")
        m.cards = [card("m1", .mail, "new-mail"), card("m2", .mail, "new-mail"), card("s1", .scan, "findings")]
        XCTAssertEqual(m.categoriesToPick.map(\.ids), [["m1", "m2"]])
    }

    func testFocusOnOneKind() throws {
        m.cards = mixed()
        m.kinds = [KindSetting(id: "luoke-mem:question", tool: .mem, title: "记忆想问的事", level: .brief)]
        let mem = try XCTUnwrap(m.categoriesToPick.first { $0.tool == .mem })
        m.enterFocus(category: mem.id)
        XCTAssertEqual(m.focus?.ids, ["a1", "a2"], "只走这一类")
        XCTAssertEqual(m.focus?.categoryName, "记忆想问的事")
        XCTAssertEqual(m.focusCurrent?.id, "a1")
        m.skipFocus()
        XCTAssertEqual(m.focusCurrent?.id, "a2")
        m.skipFocus()
        XCTAssertNil(m.focusCurrent, "走完这一类就停，不接着走别的类")
        XCTAssertEqual(m.focusLeft, 2)
        XCTAssertNil(m.focusCategoryDone, "跳过的还在：说「还有 2 件留着」")

        m.focus?.tapped = ["a1", "a2"]
        m.cards.removeAll { $0.tool == .mem }   // 都点过了，记忆答完收走
        XCTAssertEqual(m.focusLeft, 0)
        XCTAssertEqual(m.focusCategoryDone, "记忆想问的事", "这一类完了，「要你决定」里还有别的")
        XCTAssertEqual(m.focusAnswered, 2)
        m.cards = []
        XCTAssertNil(m.focusCategoryDone, "什么都不剩了：照「今天没什么要你操心的」说")
    }

    /// 邮件助手的两类：可疑邮件 2 封、新邮件 2 封
    private func twoMailKinds() -> [TodayCard] {
        [card("s1", .mail, "spam"), card("s2", .mail, "spam"), card("r1", .mail, "new-mail"), card("r2", .mail, "new-mail")]
    }

    private func enterSpam() throws {
        m.cards = twoMailKinds()
        m.kinds = [KindSetting(id: "luoke-mail:spam", tool: .mail, title: "可疑邮件", level: .brief)]
        let spam = try XCTUnwrap(m.categoriesToPick.first { $0.name == "可疑邮件" })
        m.enterFocus(category: spam.id)
        XCTAssertEqual(m.focus?.ids, ["s1", "s2"])
        XCTAssertEqual(m.focusCurrent?.id, "s1")
    }

    func testOneKindNeverTakesAnotherKindsNewCard() throws {
        try enterSpam()
        // 工具收走了正看着的 s1，同时来了一封别类的新邮件 r3：不是换上来的
        m.cards = [card("s2", .mail, "spam"), card("r1", .mail, "new-mail"), card("r2", .mail, "new-mail"),
                   card("r3", .mail, "new-mail")]
        XCTAssertEqual(m.focus?.ids, ["s2"], "只走可疑邮件：别类的新卡片不进这一轮")
        XCTAssertEqual(m.focusCurrent?.id, "s2", "跳到这一类的下一件，不是 r3")
        XCTAssertEqual(m.focus?.categoryName, "可疑邮件", "顶上的类名照旧")
        // 这一类的也被收走、又来一封别类的：这一类完了，不换成别类的
        m.cards = [card("r1", .mail, "new-mail"), card("r2", .mail, "new-mail"), card("r3", .mail, "new-mail"),
                   card("r4", .mail, "new-mail")]
        XCTAssertEqual(m.focus?.ids, [])
        XCTAssertNil(m.focusCurrent)
        XCTAssertEqual(m.focusCategoryDone, "可疑邮件", "「这一类都处理完了」那一屏")
    }

    func testOneKindFollowsItsOwnReplacement() throws {
        try enterSpam()
        // 工具把 s1 换成 s3，同时来了一封别类的 r3（排在前面）：接上的是同一类的 s3
        m.cards = [card("r3", .mail, "new-mail"), card("s3", .mail, "spam"), card("s2", .mail, "spam"),
                   card("r1", .mail, "new-mail"), card("r2", .mail, "new-mail")]
        XCTAssertEqual(m.focus?.ids, ["s3", "s2"], "新的顶在原来的位置")
        XCTAssertEqual(m.focusCurrent?.id, "s3")
        XCTAssertEqual(m.focus?.categoryName, "可疑邮件")
    }

    func testAllKindsDoNotSwitchKindsWithinOneApp() throws {
        m.cards = twoMailKinds()
        m.enterFocus()
        XCTAssertEqual(m.focus?.ids, ["s1", "s2", "r1", "r2"])
        // 收走 s1、来了一封新邮件 r3：不算 s1 换成了 r3
        m.cards = [card("r3", .mail, "new-mail"), card("s2", .mail, "spam"), card("r1", .mail, "new-mail"),
                   card("r2", .mail, "new-mail")]
        XCTAssertEqual(m.focus?.ids, ["s2", "r1", "r2"], "同一个应用别的类的新卡片不顶上来")
        XCTAssertEqual(m.focusCurrent?.id, "s2")
        // 同一类的照旧接上：r1 换成 r4，另外来的 s5 不算
        m.cards = [card("s5", .mail, "spam"), card("r4", .mail, "new-mail"), card("s2", .mail, "spam"),
                   card("r2", .mail, "new-mail"), card("r3", .mail, "new-mail")]
        XCTAssertEqual(m.focus?.ids, ["s2", "r4", "r2"])
    }

    func testUnknownOrEmptyKindDoesNotEnter() {
        m.cards = mixed()
        m.enterFocus(category: "nope")
        XCTAssertNil(m.focus, "没有这一类（刚答完、工具收走了）：不进")
        m.cards = []
        m.enterFocus()
        XCTAssertNil(m.focus)
    }

    func testShippedFocusOrderUnchangedWhenEveryCardIsItsOwnKind() {
        XCTAssertEqual(m.categoriesToPick, [], "示例的四张各是一类：不出「按类处理」")
        m.enterFocus()
        XCTAssertEqual(m.focus?.ids, ["plan", "ask-mem", "perm-calendar", "ai"])
    }

    func testKindScreensHaveSomethingToPick() {
        let names = Set(Snapshot.screens().map(\.name))
        for n in ["stress-today-kinds", "stress-focus-kind", "stress-focus-kind-end"] {
            XCTAssertTrue(names.contains(n), n)
        }
    }
}
