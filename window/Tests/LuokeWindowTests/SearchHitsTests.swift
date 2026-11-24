import AppKit
import Foundation
import LuokeA2UICore
import XCTest
@testable import LuokeWindow

/// 搜索框按类型分组画 hits（docs/界面接口.md §7、工具协议 §1b）
@MainActor
final class SearchHitsTests: XCTestCase {
    final class Backend: WindowBackend {
        var queries: [String] = []
        var thumbs: [String] = []
        var hits: [String] = []
        func action(surfaceId: String, componentId: String, context: JSONValue) {}
        func updateSettings(_ patch: [String: JSONValue]) {}
        func search(query: String) { queries.append(query) }
        func searchThumb(app: String, ref: String) { thumbs.append("\(app) \(ref)") }
        func searchHit(search: Int, app: String, hit: String, action: Int) { hits.append("\(search) \(app) \(hit) \(action)") }
    }

    private func searching() -> (WindowModel, AgentFeed, Backend) {
        let m = WindowModel()
        m.features = .beta2
        let b = Backend()
        m.backend = b
        return (m, AgentFeed(model: m), b)
    }

    private func hit(_ app: String, _ id: String, _ kind: String, source: String? = nil, actions: [HitAction] = []) -> WindowHit {
        WindowHit(app: app, hitID: id, kind: kind, title: id, source: source, actions: actions)
    }

    private static let answer = """
    {"search": 7, "asked": 3, "failed": [], "results": [
      {"app": "luoke-search", "name": "螺壳搜索", "messages": [], "hits": [
        {"id": "1-p3", "kind": "pdf", "kind_label": "PDF", "title": "报销.pdf", "line": "第 3 页", "path": "/Users/me/Documents/报销/报销.pdf",
         "thumb": "thumb/1-p3", "actions": [{"title": "打开", "primary": true}, {"title": "在访达中显示", "reveal": true}]},
        {"id": "2", "kind": "sheet", "kind_label": "表格", "title": "十月.xlsx", "thumb": "thumb/2", "actions": [{"title": "打开"}]},
        {"id": "", "title": "没编号的不算"},
        {"id": "3", "kind": "pdf", "title": "合同.pdf"}]},
      {"app": "luoke-mail", "name": "邮件助手", "hits": [
        {"id": "m1", "kind": "mail", "title": "发票", "source": "a@example.com", "actions": [{"title": "看", "primary": true}]}]},
      {"app": "luoke-mem", "name": "记忆", "messages": [
        {"version": "v0.9", "createSurface": {"surfaceId": "luoke-mem/search", "catalogId": "ai.luoke/a2ui/agent/1"}},
        {"version": "v0.9", "updateComponents": {"surfaceId": "luoke-mem/search", "components": [
          {"id": "root", "component": "Text", "text": "记忆里有 1 条"}]}}]}]}
    """

    func testHitsAreReadAndCardOnlyToolsStillDraw() {
        let (m, f, _) = searching()
        m.runSearch("发票")
        f.applySearch(status: 200, body: Data(Self.answer.utf8))
        let a = m.searchAnswer
        XCTAssertEqual(a?.search, 7)
        XCTAssertEqual(a?.hits.map(\.hitID), ["1-p3", "2", "3", "m1"], "没编号的不算")
        XCTAssertEqual(a?.cards.map(\.id), ["luoke-mem/search"], "只给卡片的工具照旧画卡片")
        XCTAssertEqual(a?.groups.map(\.id), ["pdf", "sheet", "mail"], "按类型跨工具分组，组的顺序按第一条出现的先后")
        XCTAssertEqual(a?.groups.first?.hits.map(\.hitID), ["1-p3", "3"], "组里照工具给的顺序")
        let first = a!.hits[0]
        XCTAssertEqual(first.actions, [HitAction(title: "打开", primary: true), HitAction(title: "在访达中显示", reveal: true)])
        XCTAssertEqual(first.folders, "文稿 › 报销")
        XCTAssertFalse(a!.allFailed)
        XCTAssertEqual(a?.lines, [], "有结果：不写「没有找到」")
    }

    /// hits 一条动作都没带、又有卡片：画卡片（卡片上的「打开」不能跟着没了）；没卡片的照旧画 hits
    func testHitsWithoutActionsKeepTheToolsCard() {
        let (m, f, _) = searching()
        m.runSearch("账单")
        f.applySearch(status: 200, body: Data("""
        {"search": 3, "asked": 2, "failed": [], "results": [
          {"app": "luoke-mail", "name": "邮件助手", "hits": [{"id": "found", "title": "某某商城的账单"}], "messages": [
            {"version": "v0.9", "createSurface": {"surfaceId": "luoke-mail/search", "catalogId": "ai.luoke/a2ui/agent/1"}},
            {"version": "v0.9", "updateComponents": {"surfaceId": "luoke-mail/search", "components": [
              {"id": "root", "component": "Text", "text": "某某商城的账单"}]}}]},
          {"app": "luoke-search", "name": "螺壳搜索", "messages": [], "hits": [{"id": "1", "kind": "pdf", "title": "账单.pdf"}]}]}
        """.utf8))
        XCTAssertEqual(m.searchAnswer?.cards.map(\.id), ["luoke-mail/search"])
        XCTAssertEqual(m.searchAnswer?.hits.map(\.hitID), ["1"], "没有卡片：没动作的 hits 也画")
        XCTAssertEqual(m.searchAnswer?.failed, [])
    }

    /// 顶上「最相关」（工具协议 §1b，负责人 11-13 定的 A）：各应用 strong 的，每个应用最多两条；
    /// 下面有 strong 的那几组排前面，一条都不是的收成一行；筛了一类时「最相关」里的照样算在那一类里
    func testMostRelevantOnTopAndQuietGroupsFold() {
        let a = SearchSample.answer()
        XCTAssertEqual(a.top.map(\.title), ["发票开具说明.pdf", "酒店发票.pdf", "您的行程电子发票已开具", "10 月账单与发票"])
        XCTAssertEqual(a.groups.filter { !$0.quiet }.map(\.id), ["pdf", "mail"])
        XCTAssertEqual(Set(a.groups.filter(\.quiet).map(\.id)), ["sheet", "image", "video"])
        XCTAssertEqual(a.allGroups.first { $0.id == "pdf" }?.hits.count, 5, "筛 PDF 时五个都在")
        XCTAssertFalse(a.groups.flatMap(\.hits).contains { h in a.top.contains { $0.id == h.id } }, "「最相关」里的不在下面再出一次")
        var none = SearchSample.hits
        for i in none.indices { none[i].strong = false }
        let b = SearchAnswer(hits: none, search: 1, failed: [], asked: 2)
        XCTAssertTrue(b.top.isEmpty)
        XCTAssertFalse(b.groups.contains(where: \.quiet), "一条都不 strong：照旧全摆出来，不收")
    }

    func testGroupsAndHowManyAreShownFirst() {
        let hits = (1...6).map { hit("s", "p\($0)", "pdf") } + [hit("s", "i1", "screenshot"), hit("s", "i2", "photo"),
                                                                hit("m", "m1", "mail", source: "b"), hit("m", "m2", "mail", source: "a"),
                                                                hit("m", "m3", "mail", source: "b"), hit("s", "x", "note")]
        let groups = HitGroup.make(hits)
        XCTAssertEqual(groups.map(\.id), ["pdf", "image", "mail", "note"], "截图、照片都算图片")
        XCTAssertEqual(groups.map(\.grid), [true, true, false, false])
        XCTAssertEqual(groups[1].label, "图片")
        XCTAssertEqual(groups[3].label, "其他", "不认得的类型、也没给 kind_label：其他")
        XCTAssertEqual(HitGroup.make([hit("s", "r", "memory")]).map(\.label), ["记忆"], "记忆自己一组")
        XCTAssertEqual(groups[2].mailboxes.map(\.address), ["b", "a"], "邮件按收件的邮箱分块，照第一封的先后")
        XCTAssertEqual(groups[2].mailboxes[0].hits.map(\.hitID), ["m1", "m3"])
        let pdf = groups[0]
        XCTAssertEqual(SearchLayout.shown(pdf, filtered: false, previewing: false).count, 4, "一行四个")
        XCTAssertEqual(SearchLayout.shown(pdf, filtered: false, previewing: true).count, 3, "出预览：一行三个")
        XCTAssertEqual(SearchLayout.shown(pdf, filtered: false, previewing: true, selected: "s\u{1}p5").map(\.hitID),
                       ["p1", "p2", "p3", "p4", "p5"], "选中的那条排在后面也列出来")
        XCTAssertEqual(SearchLayout.shown(pdf, filtered: true, previewing: false).count, 6, "筛了这一类：全列")
        XCTAssertEqual(SearchLayout.order(groups, filter: "mail", previewing: false).map(\.hitID), ["m1", "m3", "m2"],
                       "上下走的顺序是画出来的顺序（邮件按邮箱）")
    }

    func testFoldersAndDays() {
        func at(_ path: String?) -> WindowHit { WindowHit(app: "s", hitID: "1", kind: "pdf", title: "t", date: "2026-10-03T10:00:00+0800", path: path) }
        XCTAssertEqual(at("/Users/me/Downloads/a.pdf").folders, "下载")
        XCTAssertEqual(at("/Users/me/Documents/合同/2026/a.pdf").folders, "合同 › 2026", "最后两层")
        XCTAssertEqual(at("/Volumes/盘/a.pdf").folders, "Volumes › 盘")
        XCTAssertNil(at("/Users/me/a.pdf").folders, "家目录里直接放的：不写")
        XCTAssertNil(at(nil).folders)
        XCTAssertEqual(at(nil).day(full: false), "10-03")
        XCTAssertEqual(at(nil).day(full: true), "2026-10-03")
        XCTAssertEqual(WindowHit(app: "s", hitID: "1", kind: "pdf", title: "t", date: "昨天").day(full: false), "昨天", "看不懂的原样")
    }

    func testKeyboardSelectsOpensAndReveals() {
        let (m, f, b) = searching()
        m.runSearch("发票")
        f.applySearch(status: 200, body: Data(Self.answer.utf8))
        XCTAssertNil(m.selectedHit)
        XCTAssertFalse(m.returnPressed(text: "发票"), "没选：回车是重新搜，不替用户打开第一条（rc3）")
        XCTAssertFalse(m.returnPressed(text: "发票", reveal: true), "没选：⌘↩ 也不开")
        XCTAssertTrue(m.showsResults(for: " 发票 "), "⌘↩ 没选中时什么都不做，不当重新搜")
        XCTAssertTrue(b.hits.isEmpty)
        XCTAssertFalse(m.returnPressed(text: "合同"), "改了字：回车是重新搜")
        XCTAssertFalse(m.returnPressed(text: "合同", reveal: true), "改了字：⌘↩ 不显示上一次的结果")
        XCTAssertFalse(m.showsResults(for: "合同"))
        m.moveSearchSelection(1)
        XCTAssertTrue(m.returnPressed(text: "发票"), "↓ 选中以后回车打开它")
        XCTAssertEqual(b.hits, ["7 luoke-search 1-p3 0"])
        XCTAssertFalse(m.returnPressed(text: "合同"), "选中了、改了字：回车是搜新词（rc3：看着详情输入新词回车）")
        XCTAssertEqual(b.hits.count, 1)
        XCTAssertEqual(m.selectedHit?.hitID, "1-p3", "↓ 选第一条")
        m.moveSearchSelection(1)
        XCTAssertEqual(m.selectedHit?.hitID, "3", "↓ 照画出来的顺序：同组的下一条")
        m.moveSearchSelection(5)
        XCTAssertEqual(m.selectedHit?.hitID, "m1", "到底停住")
        m.moveSearchSelection(-1)
        XCTAssertEqual(m.selectedHit?.hitID, "2")
        XCTAssertTrue(m.returnPressed(text: "发票"))
        XCTAssertEqual(b.hits.last, "7 luoke-search 2 0", "没标 primary：第一个不是在访达中显示的")
        m.moveSearchSelection(-5)
        XCTAssertTrue(m.returnPressed(text: "发票", reveal: true))
        XCTAssertEqual(b.hits.last, "7 luoke-search 1-p3 1", "⌘↩：在访达中显示的那个序号")
        m.moveSearchSelection(1)
        let before = b.hits.count
        XCTAssertTrue(m.returnPressed(text: "发票", reveal: true))
        XCTAssertEqual(b.hits.count, before, "没有在访达中显示的：⌘↩ 什么都不做")
        m.selectHit(m.selectedHit!)
        XCTAssertNil(m.searchSelected, "再点一下取消选中")
    }

    /// rc3：看着详情、输入新词按回车，第一下搜新词；连按的第二下落在新结果上也只是再搜一次，不打开第一条
    func testDoubleReturnNeverOpensTheFirstHit() {
        let (m, f, b) = searching()
        m.runSearch("发票")
        f.applySearch(status: 200, body: Data(Self.answer.utf8))
        m.selectHit(m.searchAnswer!.hits[0])
        XCTAssertNotNil(m.selectedHit, "点了一条看详情")
        for _ in 0..<2 {        // 改成新词，回车两下；结果马上就回来了
            if !m.returnPressed(text: "合同") { m.runSearch("合同") }
            f.applySearch(status: 200, body: Data(Self.answer.utf8))
        }
        XCTAssertEqual(b.queries, ["发票", "合同", "合同"], "两下都是搜")
        XCTAssertTrue(b.hits.isEmpty, "什么都没打开")
        XCTAssertNil(m.selectedHit, "新结果里没有选中的")
    }

    /// rc3：模型还在加载、只按字词搜时没找到，写出原因、能重试，不只是「未找到结果」
    func testNothingFoundSaysWhy() {
        let (m, f, b) = searching()
        m.runSearch("怎么索赔")
        f.applySearch(status: 200, body: Data(#"""
        {"search": 4, "asked": 2, "failed": ["邮件助手"], "results": [],
         "partial": [{"app": "luoke-search", "name": "螺壳搜索", "text": "螺壳还在加载模型，这次只按字词搜"}, {"text": ""}, {"app": "x"}]}
        """#.utf8))
        let a = m.searchAnswer!
        XCTAssertEqual(a.partial, ["螺壳还在加载模型，这次只按字词搜"], "空的、没字的不算")
        XCTAssertEqual(a.partialNote, "螺壳还在加载模型，这次只按字词搜")
        XCTAssertEqual(a.lines, ["邮件助手未响应"], "不写「未找到结果」那一行：原因那里写")
        XCTAssertFalse(a.allFailed)
        // 有结果时原因不另外写
        var found = SearchAnswer(hits: [hit("luoke-search", "1", "pdf")])
        found.partial = ["螺壳还在加载模型，这次只按字词搜"]
        XCTAssertNil(found.partialNote)
        // 旧核心不给 partial：照旧
        m.runSearch("怎么索赔")
        f.applySearch(status: 200, body: Data(#"{"search": 5, "asked": 1, "failed": [], "results": []}"#.utf8))
        XCTAssertNil(m.searchAnswer?.partialNote)
        XCTAssertEqual(m.searchAnswer?.lines, ["未找到结果"])
        XCTAssertEqual(b.queries, ["怎么索赔", "怎么索赔"])
    }

    /// rc3：点「最近搜索」的一条，框里换成那一句再搜
    func testSearchFromThePageFillsTheBox() {
        let (m, _, b) = searching()
        XCTAssertEqual(m.searchFill, SearchFill())
        m.searchFromPage(" 海边 ")
        XCTAssertEqual(m.searchFill, SearchFill(serial: 1, text: "海边"))
        XCTAssertEqual(b.queries, ["海边"])
        XCTAssertEqual(m.searchQuery, "海边")
        m.searchFromPage("海边")
        XCTAssertEqual(m.searchFill.serial, 2, "同一句再点也换（框里可能已经改过）")
        m.searchFromPage("  ")
        XCTAssertEqual(m.searchFill.serial, 2, "空的不搜")
        XCTAssertEqual(b.queries, ["海边", "海边"])
    }

    /// rc3：搜完以后正看着的螺壳搜索页重新取（「最近搜索」立刻更新）；看着别的页不取
    func testSearchReloadsTheSearchPage() throws {
        let path = "/tmp/lkw-srch-\(getpid()).sock"
        let core = try MiniCore(path: path, events: Sample.agentEvents(),
                                settings: Sample.agentEvents().first { $0.0 == "settings" }!.1)
        defer { core.stop() }
        core.route("GET", "/apps", Data(#"""
        {"apps": [{"id": "luoke-search", "running": true, "pages": [{"id": "overview", "title": "概览"}]},
                  {"id": "luoke-mail", "running": true, "pages": [{"id": "overview", "title": "概览"}]}]}
        """#.utf8))
        let page = Sample.messages("luoke-search/page/overview", [
            .object(["id": .string("root"), "component": .string("Text"), "text": .string("最近搜索")])])
        core.route("GET", "/apps/luoke-search/pages/overview", JSONValue.object(["messages": .array(page)]).serialized())
        core.route("GET", "/apps/luoke-mail/pages/overview", JSONValue.object(["messages": .array(
            Sample.messages("luoke-mail/page/overview", [.object(["id": .string("root"), "component": .string("Text"),
                                                                   "text": .string("邮件")])]))]).serialized())
        core.route("POST", "/search", Data(#"{"search": 1, "asked": 1, "failed": [], "results": []}"#.utf8))
        let m = Sample.model()
        m.features = .beta2
        let c = AgentConnection(socketPath: path, model: m)
        c.start()
        defer { c.stop() }
        XCTAssertTrue(wait { m.agentApps?.count == 2 })
        m.go(.searchApp)
        XCTAssertTrue(wait { core.gets("/apps/luoke-search/pages/overview") >= 1 })
        let before = core.gets("/apps/luoke-search/pages/overview")
        m.runSearch("海边")
        XCTAssertTrue(wait { core.posts("/search").count == 1 && core.gets("/apps/luoke-search/pages/overview") > before },
                      "搜完重新取搜索页")
        m.go(.mail)
        XCTAssertTrue(wait { core.gets("/apps/luoke-mail/pages/overview") >= 1 })
        let search = core.gets("/apps/luoke-search/pages/overview"), mail = core.gets("/apps/luoke-mail/pages/overview")
        m.runSearch("海边")
        XCTAssertTrue(wait { core.posts("/search").count == 2 })
        XCTAssertTrue(settle { core.gets("/apps/luoke-search/pages/overview") == search
                               && core.gets("/apps/luoke-mail/pages/overview") == mail }, "看着别的页：不取")
    }

    func testFilterKeepsOnlyThatKind() {
        let (m, f, _) = searching()
        m.runSearch("发票")
        f.applySearch(status: 200, body: Data(Self.answer.utf8))
        m.moveSearchSelection(1)
        m.filterSearch("mail")
        XCTAssertEqual(m.searchOrder.map(\.hitID), ["m1"])
        XCTAssertNil(m.searchSelected, "选中的那条筛掉了：不选")
        m.filterSearch("mail")
        XCTAssertNil(m.searchKind, "再点一下：全部")
        m.runSearch("合同")
        XCTAssertNil(m.searchAnswer)
        XCTAssertNil(m.searchKind)
    }

    func testThumbnailsAskedOnceAndOnlyForThisSearch() {
        let (m, f, b) = searching()
        m.runSearch("发票")
        f.applySearch(status: 200, body: Data(Self.answer.utf8))
        let h = m.searchAnswer!.hits[0]
        m.loadThumb(h)
        m.loadThumb(h)
        XCTAssertEqual(b.thumbs, ["luoke-search thumb/1-p3"], "只问一次")
        m.setThumb(app: "luoke-search", ref: "thumb/9", image: NSImage(size: NSSize(width: 4, height: 3)))
        XCTAssertTrue(m.searchThumbs.isEmpty, "没问过的不收")
        m.setThumb(app: "luoke-search", ref: "thumb/1-p3", image: NSImage(size: NSSize(width: 4, height: 3)))
        XCTAssertEqual(m.searchThumbs.count, 1)
        m.runSearch("合同")
        m.setThumb(app: "luoke-search", ref: "thumb/1-p3", image: NSImage(size: NSSize(width: 4, height: 3)))
        XCTAssertTrue(m.searchThumbs.isEmpty, "上一次搜的图晚到了：不要")
    }

    /// 没读到的缩略图（工具还在生成）过一会儿再要，最多再要两次；读到了、换了一次搜索就不再要
    func testAThumbnailThatFailedIsAskedAgainTwice() {
        let (m, f, b) = searching()
        m.thumbRetryDelay = 0.02
        m.runSearch("发票")
        f.applySearch(status: 200, body: Data(Self.answer.utf8))
        let h = m.searchAnswer!.hits[0]
        m.loadThumb(h)
        m.thumbFailed(app: "luoke-search", ref: "thumb/9")
        m.thumbFailed(app: "luoke-search", ref: "thumb/1-p3")
        XCTAssertTrue(wait { b.thumbs.count == 2 }, "再要一次")
        m.thumbFailed(app: "luoke-search", ref: "thumb/1-p3")
        XCTAssertTrue(wait { b.thumbs.count == 3 }, "再要第二次")
        m.thumbFailed(app: "luoke-search", ref: "thumb/1-p3")
        XCTAssertFalse(settle { b.thumbs.count > 3 }, "到此为止；没问过的那张也不要")
        m.runSearch("合同")
        f.applySearch(status: 200, body: Data(Self.answer.utf8))
        m.loadThumb(h)
        m.thumbFailed(app: "luoke-search", ref: "thumb/1-p3")
        m.runSearch("别的")
        XCTAssertFalse(settle { b.thumbs.count > 4 }, "换了一次搜索：上一次的不再要")
    }

    func testAVideoCarriesItsLength() {
        let v = try! JSONValue.parse(#"{"id": "v", "title": "a.mov", "kind": "video", "duration": 83.4, "actions": []}"#)
        XCTAssertEqual(WindowHit(app: "s", v)?.clock, "1:23")
        var h = hit("s", "v", "video")
        XCTAssertNil(h.clock)
        h.duration = 3723
        XCTAssertEqual(h.clock, "1:02:03")
        h.duration = 5
        XCTAssertEqual(h.clock, "0:05")
        h.duration = -.infinity
        XCTAssertNil(h.clock)
    }

    func testThumbImageOnlyTakesSmallPngOrJpeg() {
        func png(_ w: Int, _ h: Int) -> Data {
            let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: w, pixelsHigh: h, bitsPerSample: 8, samplesPerPixel: 4,
                                       hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
            return rep.representation(using: .png, properties: [:])!
        }
        XCTAssertNotNil(AgentConnection.thumbImage(png(40, 30)))
        XCTAssertNil(AgentConnection.thumbImage(png(2049, 2)), "长边超过 2048")
        XCTAssertNil(AgentConnection.thumbImage(Data("<svg/>".utf8)), "不是 PNG、JPEG")
        XCTAssertNil(AgentConnection.thumbImage(Data()))
    }

    /// 发给核心的数是整数（Python 那边要 int）：/search 的 limit、/hit 的 search 和 action
    func testNumbersGoOutAsIntegers() throws {
        final class Log: @unchecked Sendable {
            let lock = NSLock()
            var posts: [(String, Data)] = []
            func add(_ p: String, _ d: Data) { lock.lock(); posts.append((p, d)); lock.unlock() }
            func body(_ p: String) -> String? {
                lock.lock(); defer { lock.unlock() }
                return posts.first { $0.0 == p }.map { String(decoding: $0.1, as: UTF8.self) }
            }
        }
        let log = Log()
        let m = WindowModel()
        let c = AgentConnection(model: m) { method, path, body in
            log.add(method == "POST" ? path : "\(method) \(path)", body ?? Data())
            return (200, Data("{}".utf8))
        }
        c.search(query: "发票")
        c.searchHit(search: 7, app: "luoke-search", hit: "1-p3", action: 1)
        c.searchThumb(app: "luoke-search", ref: "thumb/1-p3")
        XCTAssertTrue(wait { log.body("/search") != nil && log.body("/hit") != nil
            && log.body("GET /thumb?app=luoke-search&ref=thumb%2F1-p3") != nil }, "缩略图的 ref 里的 / 编码")
        XCTAssertTrue(log.body("/search")!.contains(#""limit":20"#), log.body("/search")!)
        let hit = log.body("/hit")!
        XCTAssertTrue(hit.contains(#""search":7"#) && hit.contains(#""action":1"#), hit)
    }

    func testNewIconsAreBundled() {
        for name in ["file-text", "sheet", "image", "mic", "video", "file", "mail"] {
            XCTAssertNotNil(Lucide.nsImage(name), name)
        }
        for g in HitGroup.known.values { XCTAssertNotNil(Lucide.nsImage(g.icon), g.icon) }
    }

    /// 等上一小会儿（重试的间隔的好几倍），看有没有不该来的
    private func settle(_ happened: () -> Bool) -> Bool {
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))
        return happened()
    }

    private func wait(_ ok: () -> Bool) -> Bool {
        for _ in 0..<200 {
            if ok() { return true }
            RunLoop.main.run(until: Date().addingTimeInterval(0.025))
        }
        return ok()
    }
}
