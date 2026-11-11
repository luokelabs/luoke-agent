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
        XCTAssertTrue(m.returnPressed(text: "发票"), "没选：回车开第一条")
        XCTAssertEqual(b.hits, ["7 luoke-search 1-p3 0"])
        XCTAssertFalse(m.returnPressed(text: "合同"), "改了字：回车是重新搜")
        XCTAssertFalse(m.returnPressed(text: "合同", reveal: true), "改了字：⌘↩ 不显示上一次的结果")
        XCTAssertEqual(b.hits.count, 1)
        m.moveSearchSelection(1)
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

    private func wait(_ ok: () -> Bool) -> Bool {
        for _ in 0..<200 {
            if ok() { return true }
            RunLoop.main.run(until: Date().addingTimeInterval(0.025))
        }
        return ok()
    }
}
