import Foundation
import XCTest
@testable import LuokeA2UICore

final class CoreTests: XCTestCase {
    /// 和 Python 版（luoke_agent/a2ui.py）对同一批卡片的判断一样：scripts/a2ui-fixtures.py 生成。
    func testSameVerdictAsPython() throws {
        let url = try XCTUnwrap(Bundle.module.url(forResource: "cases", withExtension: "json", subdirectory: "Fixtures"))
        let cases = try XCTUnwrap(try JSONValue.parse(Data(contentsOf: url)).array)
        XCTAssertGreaterThan(cases.count, 20)
        for c in cases {
            let name = c["name"]!.string!
            let problems = validate(c["messages"]!.array!, catalog: c["catalog"]!.string!, page: c["page"]?.bool ?? false)
            XCTAssertEqual(problems.isEmpty, c["ok"]!.bool!, "\(name)：\(problems)")
        }
    }

    func plan() throws -> Surface {
        let url = try XCTUnwrap(Bundle.module.url(forResource: "cases", withExtension: "json", subdirectory: "Fixtures"))
        let cases = try XCTUnwrap(try JSONValue.parse(Data(contentsOf: url)).array)
        let msgs = cases.first { $0["name"]?.string == "plan_card" }!["messages"]!.array!
        return try Surface.build(msgs)
    }

    func button(_ s: Surface, _ event: String) -> String {
        s.reachable().first { s.components[$0]?["component"]?.string == "Button" && s.components[$0]?["action"]?["event"]?["name"]?.string == event }!
    }

    /// 卡片的副标题（§4 subtitle）：root 上写的那一句，没写是 nil
    func testSubtitleComesFromTheRoot() throws {
        let url = try XCTUnwrap(Bundle.module.url(forResource: "cases", withExtension: "json", subdirectory: "Fixtures"))
        let cases = try XCTUnwrap(try JSONValue.parse(Data(contentsOf: url)).array)
        let msgs = try XCTUnwrap(cases.first { $0["name"]?.string == "subtitle_ok" }?["messages"]?.array)
        XCTAssertEqual(try Surface.build(msgs).subtitle, "王老师 · 答辩时间")
        XCTAssertNil(try plan().subtitle)
    }

    /// 应用页分段画（§4 pageSections）：页头不画卡片，一排数每格一张小卡片，一段一张卡片、开头的小标题提到外面，
    /// 分隔线不画（段开头的也不画，后面的小标题照样认得出）；分两栏时主栏、侧栏各挑自己的段；卡片上、没写 layout 的页都是 nil
    func testPageBlocksFollowTheSections() throws {
        func page(layout: String? = "sections") throws -> [JSONValue] {
            let l = layout.map { #", "layout": "\#($0)""# } ?? ""
            return try JSONValue.parse(Data(#"""
            [{"version":"v0.9","createSurface":{"surfaceId":"s","catalogId":"ai.luoke/a2ui/agent/1"}},
             {"version":"v0.9","updateComponents":{"surfaceId":"s","components":[
               {"id":"root","component":"Column","children":["head","nums","d1","look","d2","auto"]\#(l)},
               {"id":"head","component":"Row","justify":"spaceBetween","children":["title","go"]},
               {"id":"title","component":"Text","text":"扫描","variant":"h3"},
               {"id":"go","component":"Button","child":"got","action":{"event":{"name":"scan_now","context":{}}}},
               {"id":"got","component":"Text","text":"现在查一下"},
               {"id":"nums","component":"Row","justify":"spaceEvenly","children":["n1","n2","n3"]},
               {"id":"n1","component":"Text","text":"45 GB"},{"id":"n2","component":"Text","text":"0 个"},{"id":"n3","component":"Text","text":"4 样"},
               {"id":"d1","component":"Divider"},
               {"id":"look","component":"Column","children":["lt","items"]},
               {"id":"lt","component":"Row","children":["li","lx","ln"]},
               {"id":"li","component":"Icon","name":"eye"},
               {"id":"lx","component":"Text","text":"要你看看"},
               {"id":"ln","component":"Text","text":"4","variant":"caption"},
               {"id":"items","component":"List","children":["i1"]},
               {"id":"i1","component":"Text","text":"登录项：Helper"},
               {"id":"d2","component":"Divider"},
               {"id":"auto","component":"Column","placement":"aside","children":["d3","at","ax"]},
               {"id":"d3","component":"Divider"},
               {"id":"at","component":"Text","text":"自动清理","variant":"h5"},
               {"id":"ax","component":"Text","text":"关着"}]}}]
            """#.utf8)).array!
        }
        let s = try Surface.build(try page(), page: true)
        let look = PageBlock.card("look", title: SectionTitle(icon: "eye", text: .string("要你看看"), count: .string("4")), skip: 1)
        let auto = PageBlock.card("auto", title: SectionTitle(icon: nil, text: .string("自动清理"), count: nil), skip: 2)
        XCTAssertEqual(s.pageBlocks(), [.bare("head"), .tiles(["n1", "n2", "n3"]), look, auto])
        XCTAssertEqual(s.pageBlocks(aside: false), [.bare("head"), .tiles(["n1", "n2", "n3"]), look])
        XCTAssertEqual(s.pageBlocks(aside: true), [auto])
        XCTAssertNil(try Surface.build(try page(layout: nil), page: true).pageBlocks(), "没写 layout：照整页一张卡片")
        XCTAssertFalse(validate(try page(), page: false).isEmpty, "卡片上写了整张不画")
        XCTAssertFalse(validate(try page(layout: "cards"), page: true).isEmpty)
    }

    /// 画成开关的按钮还是按钮：点了发原来的动作，`on` 只管画
    func testSwitchButtonSendsItsAction() throws {
        let msgs = try JSONValue.parse(Data("""
        [{"version":"v0.9","createSurface":{"surfaceId":"s","catalogId":"ai.luoke/a2ui/agent/1"}},
         {"version":"v0.9","updateComponents":{"surfaceId":"s","components":[
           {"id":"root","component":"Button","child":"t","variant":"switch","on":true,
            "action":{"event":{"name":"do","context":{"x":1}}}},
           {"id":"t","component":"Text","text":"也搜照片"}]}}]
        """.utf8)).array!
        let s = try Surface.build(msgs)
        XCTAssertEqual(s.components["root"]?["on"]?.bool, true)
        let (name, ctx) = try s.action("root")
        XCTAssertEqual(name, "do")
        XCTAssertEqual(ctx["x"]?.number, 1)
    }

    /// 打开网页的按钮去哪个网站，只认 agent 核心写在这个按钮上的 `site`（工具协议 §5）；没写就是 nil，界面不让点。
    func testOpenSiteComesFromTheCore() throws {
        func card(site: String?) throws -> Surface {
            let s = site.map { #", "site": "\#($0)""# } ?? ""
            return try Surface.build(try JSONValue.parse(#"""
            [{"version": "v0.9", "createSurface": {"surfaceId": "s", "catalogId": "ai.luoke/a2ui/agent/1"}},
             {"version": "v0.9", "updateComponents": {"surfaceId": "s", "components": [
               {"id": "root", "component": "Row", "children": ["go", "do"]},
               {"id": "go", "component": "Button", "child": "t1"\#(s), "action": {"event": {"name": "agent.open_url", "context": {"url": "https://bücher.example/"}}}},
               {"id": "t1", "component": "Text", "text": "打开"},
               {"id": "do", "component": "Button", "child": "t2", "site": "evil.example", "action": {"event": {"name": "mail_apply_plan", "context": {}}}},
               {"id": "t2", "component": "Text", "text": "好"}]}}]
            """#).array!)
        }
        let s = try card(site: "xn--bcher-kva.example")
        XCTAssertTrue(s.opensURL("go"))
        XCTAssertEqual(s.openSite("go"), "xn--bcher-kva.example")
        XCTAssertFalse(s.opensURL("do"))
        XCTAssertNil(s.openSite("do"), "别的按钮上的 site 不算")
        XCTAssertNil(try card(site: nil).openSite("go"))
        XCTAssertNil(try card(site: "").openSite("go"))
        XCTAssertTrue(A2UI.openURLAcceptable("https://bücher.example/路径"))
        XCTAssertFalse(A2UI.openURLAcceptable("https://example.com\\@evil.example/"))
        XCTAssertFalse(A2UI.openURLAcceptable("https://user@evil.example/"))
    }

    /// §4 countLabel：按钮字里的 {n} 是这组选择里选了 value 的项数，跟着选择变；没写 count 的按钮照旧
    func testCountLabelFollowsTheChoices() throws {
        var s = try Surface.build(try JSONValue.parse(#"""
        [{"version": "v0.9", "createSurface": {"surfaceId": "s", "catalogId": "ai.luoke/a2ui/agent/1"}},
         {"version": "v0.9", "updateComponents": {"surfaceId": "s", "components": [
           {"id": "root", "component": "Row", "children": ["go", "other"]},
           {"id": "go", "component": "Button", "child": "t1", "count": {"path": "/choices", "value": "trash"},
            "action": {"event": {"name": "scan_apply", "context": {"choices": {"path": "/choices"}}}}},
           {"id": "t1", "component": "Text", "text": "移到废纸篓 {n} 项"},
           {"id": "other", "component": "Button", "child": "t2", "action": {"event": {"name": "x", "context": {}}}},
           {"id": "t2", "component": "Text", "text": "{n} 不换"}]}},
         {"version": "v0.9", "updateDataModel": {"surfaceId": "s", "path": "/", "value": {"choices": {"i0": ["trash"], "i1": ["keep"]}}}}]
        """#).array!)
        XCTAssertEqual(s.buttonCount("go"), 1)
        XCTAssertEqual(s.buttonLabel("go").text, "移到废纸篓 1 项")
        s.data = try s.data.setting("/choices/i1", to: .array([.string("trash")]))
        XCTAssertEqual(s.buttonLabel("go").text, "移到废纸篓 2 项")
        s.data = try s.data.setting("/choices", to: .object(["i0": .array([.string("keep")])]))
        XCTAssertEqual(s.buttonCount("go"), 0, "0 项：界面把按钮灰掉")
        XCTAssertNil(s.buttonCount("other"))
        XCTAssertEqual(s.buttonLabel("other").text, "{n} 不换")
        XCTAssertFalse(s.buttonCountAllows("go"))
        XCTAssertTrue(s.buttonCountAllows("other"), "没写 count 的照常能点")
    }

    /// §4 countWeights：一项合了好几样时 {n} 按 weights 算；不写算 1；weights 里有、选择里没有的键不管；also 照旧
    func testCountWeightsCountWhatAGroupHolds() throws {
        var s = try Surface.build(try JSONValue.parse(#"""
        [{"version": "v0.9", "createSurface": {"surfaceId": "s", "catalogId": "ai.luoke/a2ui/agent/1"}},
         {"version": "v0.9", "updateComponents": {"surfaceId": "s", "components": [
           {"id": "root", "component": "Button", "child": "t",
            "count": {"path": "/choices", "value": "trash", "weights": {"g-pkg": 41, "gone": 7}, "also": ["ignore"], "alsoLabel": "按上面的选择清理"},
            "action": {"event": {"name": "scan_apply", "context": {"choices": {"path": "/choices"}}}}},
           {"id": "t", "component": "Text", "text": "移到废纸篓 {n} 项"}]}},
         {"version": "v0.9", "updateDataModel": {"surfaceId": "s", "path": "/", "value": {"choices": {"g-pkg": ["keep"], "i1": ["keep"]}}}}]
        """#).array!)
        func pick(_ g: String, _ i: String) throws {
            s.data = try s.data.setting("/choices", to: .object(["g-pkg": .array([.string(g)]), "i1": .array([.string(i)])]))
        }
        try pick("trash", "keep")
        XCTAssertEqual(s.buttonCount("root"), 41, "合成一行的那一组移到废纸篓：算它的 41 样")
        XCTAssertEqual(s.buttonLabel("root").text, "移到废纸篓 41 项")
        try pick("trash", "trash")
        XCTAssertEqual(s.buttonCount("root"), 42, "一组加一项：加起来")
        try pick("keep", "trash")
        XCTAssertEqual(s.buttonCount("root"), 1, "没写 weights 的键算 1；gone 不在选择里，不管")
        try pick("keep", "keep")
        XCTAssertFalse(s.buttonCountAllows("root"))
        try pick("ignore", "keep")
        XCTAssertTrue(s.buttonCountAllows("root"), "also 照旧")
        XCTAssertEqual(s.buttonLabel("root").text, "按上面的选择清理")
    }

    /// §4 countAlso：选了 also 里的值（以后别提、换成克隆）时按钮能点、字换成 alsoLabel；{n} 照样只数 value
    func testCountAlsoLetsOtherChoicesThrough() throws {
        var s = try Surface.build(try JSONValue.parse(#"""
        [{"version": "v0.9", "createSurface": {"surfaceId": "s", "catalogId": "ai.luoke/a2ui/agent/1"}},
         {"version": "v0.9", "updateComponents": {"surfaceId": "s", "components": [
           {"id": "root", "component": "Button", "child": "t",
            "count": {"path": "/choices", "value": "trash", "also": ["ignore", "clone"], "alsoLabel": "按上面的选择清理（移到废纸篓 {n} 项）"},
            "action": {"event": {"name": "scan_apply", "context": {"choices": {"path": "/choices"}}}}},
           {"id": "t", "component": "Text", "text": "移到废纸篓 {n} 项"}]}},
         {"version": "v0.9", "updateDataModel": {"surfaceId": "s", "path": "/", "value": {"choices": {"i0": ["keep"], "i1": ["keep"]}}}}]
        """#).array!)
        func pick(_ a: String, _ b: String) throws {
            s.data = try s.data.setting("/choices", to: .object(["i0": .array([.string(a)]), "i1": .array([.string(b)])]))
        }
        try pick("ignore", "keep")
        XCTAssertTrue(s.buttonCountAllows("root"), "只选了以后别提：0 项也能点")
        XCTAssertEqual(s.buttonLabel("root").text, "按上面的选择清理（移到废纸篓 0 项）")
        try pick("trash", "clone")
        XCTAssertTrue(s.buttonCountAllows("root"))
        XCTAssertEqual(s.buttonLabel("root").text, "按上面的选择清理（移到废纸篓 1 项）", "混着选：alsoLabel，{n} 只数移到废纸篓的")
        try pick("keep", "keep")
        XCTAssertFalse(s.buttonCountAllows("root"), "都先不动：0 项灰掉")
        XCTAssertEqual(s.buttonLabel("root").text, "移到废纸篓 0 项")
        try pick("trash", "trash")
        XCTAssertTrue(s.buttonCountAllows("root"))
        XCTAssertEqual(s.buttonLabel("root").text, "移到废纸篓 2 项", "只选了移到废纸篓：原来的字")
        XCTAssertTrue(A2UI.pageIDAcceptable("overview"))
        XCTAssertFalse(A2UI.pageIDAcceptable("luoke-mail/accounts"))
        XCTAssertFalse(A2UI.pageIDAcceptable("../x"))
        XCTAssertFalse(A2UI.pageIDAcceptable(""))
    }

    func testActionResolvesCurrentData() throws {
        var s = try plan()
        s.data = try s.data.setting("/choices/m1", to: .array([.string("keep")]))
        let (name, ctx) = try s.action(button(s, "mail_apply_plan"))
        XCTAssertEqual(name, "mail_apply_plan")
        XCTAssertEqual(ctx, try JSONValue.parse(#"{"plan_id": "p1", "choices": {"m1": ["keep"], "rest": ["archive"]}}"#))
        XCTAssertThrowsError(try s.action("root"))
    }

    func testUpdateIsCheckedAndOriginalKept() throws {
        let s = try plan()
        let bad = try JSONValue.parse(#"[{"version": "v0.9", "updateComponents": {"surfaceId": "p1", "components": [{"id": "root", "component": "Image"}]}}]"#)
        XCTAssertThrowsError(try s.updated(with: bad.array!))
        let good = try JSONValue.parse(#"[{"version": "v0.9", "updateComponents": {"surfaceId": "p1", "components": [{"id": "root", "component": "Column", "children": ["r1"]}, {"id": "r1", "component": "Text", "text": "已归档 4 封。"}]}}]"#)
        let after = try s.updated(with: good.array!)
        XCTAssertEqual(after.reachable(), ["root", "r1"])
        XCTAssertEqual(after.data["choices"]?["m1"], .array([.string("draft")]), "数据模型留着")
        XCTAssertEqual(s.reachable().count, try plan().reachable().count)
    }

    func testPointers() throws {
        let d = try JSONValue.parse(#"{"a": {"b": [1, {"c": 2}]}, "x~y/z": 3}"#)
        XCTAssertEqual(try d.value(at: "/a/b/1/c"), .number(2))
        XCTAssertEqual(try d.value(at: "/x~0y~1z"), .number(3))
        XCTAssertThrowsError(try d.value(at: "/a/nope"))
        let e = try d.setting("/new/deep", to: .number(1))
        XCTAssertEqual(e["new"], .object(["deep": .number(1)]))
        XCTAssertNil(try e.setting("/new", to: nil)["new"])
        XCTAssertEqual(try JSONValue.parse(#"{"k": [{"path": "/a/b/0"}, "lit"]}"#).resolved(in: d),
                       try JSONValue.parse(#"{"k": [1, "lit"]}"#))
    }

    /// 数组下标照 RFC 6901：只认 0 或不以 0 开头的 ASCII 数字；别的写法取不到、写不了、删不了（同 a2ui.py 的 `_index`）
    func testListIndexesAreStrict() throws {
        let d = JSONValue.object(["l": .array((0...10).map { .string("v\($0)") }), "o": .object(["00": .string("key")])])
        XCTAssertEqual(try d.value(at: "/l/0"), .string("v0"))
        XCTAssertEqual(try d.value(at: "/l/10"), .string("v10"))
        XCTAssertEqual(try d.value(at: "/o/00"), .string("key"))
        for bad in ["00", "01", "+0", "-0", "٠", "²", "０", "", " 0", "0 ", "11", "99999999999999999999"] {
            XCTAssertThrowsError(try d.value(at: "/l/" + bad), "取 \(bad)")
            XCTAssertThrowsError(try d.setting("/l/" + bad, to: .string("x")), "写 \(bad)")
            XCTAssertThrowsError(try d.setting("/l/" + bad, to: nil), "删 \(bad)")
            XCTAssertThrowsError(try d.setting("/l/\(bad)/deep", to: .string("x")), "往下写 \(bad)")
        }
        let e = try d.setting("/l/10", to: .string("new"))
        XCTAssertEqual(try e.value(at: "/l/10"), .string("new"))
        XCTAssertEqual(try e.setting("/l/0", to: nil).value(at: "/l/0"), .string("v1"))
    }

    /// 5000 位的下标和越界一样：取不到、写不了、删不了，整页照常报「在数据模型里没有」（同 Python 的 test_a_huge_list_index_is_just_out_of_range）
    func testAHugeListIndexIsJustOutOfRange() throws {
        let huge = String(repeating: "1", count: 5000)
        let d = JSONValue.object(["l": .array([.string("v0"), .string("v1")])])
        XCTAssertThrowsError(try d.value(at: "/l/" + huge))
        XCTAssertThrowsError(try d.setting("/l/" + huge, to: .string("x")))
        XCTAssertThrowsError(try d.setting("/l/" + huge, to: nil))
        XCTAssertThrowsError(try d.setting("/l/\(huge)/deep", to: .string("x")))
        let msgs = try JSONValue.parse(Data("""
        [{"version": "v0.9", "createSurface": {"surfaceId": "s", "catalogId": "ai.luoke/a2ui/agent/1"}},
         {"version": "v0.9", "updateComponents": {"surfaceId": "s", "components": [
           {"id": "root", "component": "Text", "text": {"path": "/l/\(huge)"}}]}},
         {"version": "v0.9", "updateDataModel": {"surfaceId": "s", "path": "/", "value": {"l": ["v0", "v1"]}}}]
        """.utf8)).array!
        XCTAssertThrowsError(try Surface.build(msgs, page: true)) { error in
            let problems = (error as? A2UIError)?.problems ?? []
            XCTAssertTrue(problems.contains { $0.contains("在数据模型里没有") }, "\(problems)")
        }
    }

    func testBoolsStayBools() throws {
        let v = try JSONValue.parse(#"{"t": true, "n": 1}"#)
        XCTAssertEqual(v["t"], .bool(true))
        XCTAssertEqual(v["n"], .number(1))
        XCTAssertEqual(try JSONValue.parse(v.serialized()), v)
    }

    /// 应用页 2026-11-10 加的几样（工具协议 §4）：查询串、文件、refresh、密码框的路径，同 Python 的 page_uri、save_file
    func testPageAdditionsHelpers() throws {
        XCTAssertEqual(A2UI.pageQuery(["q": "发票 x+y/&=", "cursor": "2~a"]), "cursor=2~a&q=%E5%8F%91%E7%A5%A8%20x%2By%2F%26%3D")
        XCTAssertNil(A2UI.pageArgsProblem(.object(["q": .string(String(repeating: "长", count: 200))])))
        XCTAssertNotNil(A2UI.pageArgsProblem(.object(["q": .string(String(repeating: "长", count: 201))])))
        XCTAssertNotNil(A2UI.pageArgsProblem(.object(["Q": .string("1")])))
        XCTAssertNotNil(A2UI.pageArgsProblem(.array([])))
        let good: JSONValue = .object(["name": .string("gmail-filters.xml"), "mediaType": .string("application/xml"), "text": .string("<feed/>")])
        XCTAssertEqual(A2UI.saveFile(good)?.name, "gmail-filters.xml")
        func with(_ k: String, _ v: JSONValue) -> JSONValue { var o = good.object!; o[k] = v; return .object(o) }
        XCTAssertNotNil(A2UI.saveFile(with("name", .string("规则 导出.xml"))))
        XCTAssertNotNil(A2UI.saveFile(with("text", .string(String(repeating: "x", count: A2UI.maxFileBytes)))))
        for (media, name) in [("text/plain", "a.txt"), ("text/csv", "a.CSV"), ("application/json", "a.json"), ("text/markdown", "说明.md")] {
            XCTAssertNotNil(A2UI.saveFile(with("mediaType", .string(media)).object.map { var o = $0; o["name"] = .string(name); return JSONValue.object(o) }),
                            "\(media) \(name)")
        }
        for (k, v) in [("name", "x.command"), ("name", "x.terminal"), ("name", "x.xml.command"), ("name", ".xml"), ("name", "xml"),
                       ("mediaType", "application/octet-stream"), ("mediaType", "text/html"), ("mediaType", "text/plain"),
                       ("name", "../x.xml"), ("name", ".zshrc"), ("name", "a:b"), ("name", ""), ("name", " x.xml"), ("name", "x\u{202E}.xml"),
                       ("name", String(repeating: "x", count: 101)), ("mediaType", "xml"), ("mediaType", "Application/XML"),
                       ("mediaType", "a/b/c"), ("text", String(repeating: "x", count: A2UI.maxFileBytes + 1))] {
            XCTAssertNil(A2UI.saveFile(with(k, .string(v))), "\(k) \(v.prefix(20))")
        }
        XCTAssertNil(A2UI.saveFile(nil))
        let msgs = try JSONValue.parse(Data(#"""
        [{"version": "v0.9", "createSurface": {"surfaceId": "s", "catalogId": "ai.luoke/a2ui/agent/1"}},
         {"version": "v0.9", "updateComponents": {"surfaceId": "s", "components": [
           {"id": "root", "component": "Column", "children": ["f"], "refresh": 5},
           {"id": "f", "component": "TextField", "label": "授权码", "variant": "obscured", "value": {"path": "/fields/code"}}]}},
         {"version": "v0.9", "updateDataModel": {"surfaceId": "s", "path": "/", "value": {"fields": {"code": ""}}}}]
        """#.utf8)).array!
        let page = try Surface.build(msgs, page: true)
        XCTAssertEqual(page.refreshSeconds, 5)
        XCTAssertEqual(page.secureFieldPaths, ["/fields/code"])
        XCTAssertThrowsError(try Surface.build(msgs), "卡片上 refresh、密码框都不认")
    }

    /// 密码框（§4 secureField）：交给工具的按钮只能正好引用它；agent. 的动作、别的绑定都不能碰它。点完只清交出去的
    func testSecureFieldOnlyByItsOwnPath() throws {
        func page(_ extra: String) throws -> Surface {
            try Surface.build(try JSONValue.parse(Data("""
            [{"version": "v0.9", "createSurface": {"surfaceId": "s", "catalogId": "ai.luoke/a2ui/agent/1"}},
             {"version": "v0.9", "updateComponents": {"surfaceId": "s", "components": [
               {"id": "root", "component": "Column", "children": ["code", "pin", "add", "x"]},
               {"id": "code", "component": "TextField", "label": "授权码", "variant": "obscured", "value": {"path": "/fields/code"}},
               {"id": "pin", "component": "TextField", "label": "PIN", "variant": "obscured", "value": {"path": "/fields/pin"}},
               {"id": "add", "component": "Button", "child": "add-t", "action": {"event": {"name": "mail_connect", "context": {"code": {"path": "/fields/code"}}}}},
               {"id": "add-t", "component": "Text", "text": "加上"},
               \(extra)]}},
             {"version": "v0.9", "updateDataModel": {"surfaceId": "s", "path": "/", "value": {"fields": {"code": "", "pin": "", "name": ""}, "q": ""}}}]
            """.utf8)).array!, page: true)
        }
        var ok = try page(#"{"id": "x", "component": "Text", "text": {"path": "/fields/name"}}"#)
        ok.data = try JSONValue.parse(#"{"fields": {"code": "abcd", "pin": "1234", "name": "王"}, "q": ""}"#)
        XCTAssertEqual(try ok.action("add").context, try JSONValue.parse(#"{"code": "abcd"}"#))
        XCTAssertEqual(ok.sentSecureFieldPaths("add"), ["/fields/code"])
        func button(_ name: String, _ ctx: String) -> String {
            #"{"id": "x", "component": "Button", "child": "add-t2", "action": {"event": {"name": "\#(name)", "context": \#(ctx)}}}, {"id": "add-t2", "component": "Text", "text": "去"}"#
        }
        for bad in [button("mail_find", #"{"all": {"path": "/fields"}}"#), button("mail_find", #"{"all": {"path": "/"}}"#),
                    button("agent.open_page", #"{"page": "notes", "args": {"q": {"path": "/fields/code"}}}"#),
                    button("agent.open_page", #"{"page": "notes", "args": {"q": {"path": "/fields"}}}"#),
                    #"{"id": "x", "component": "Text", "text": {"path": "/fields/code"}}"#,
                    #"{"id": "x", "component": "TextField", "label": "看", "value": {"path": "/fields/pin"}}"#] {
            XCTAssertThrowsError(try page(bad), bad)
        }
        XCTAssertNoThrow(try page(button("agent.open_page", #"{"page": "notes", "args": {"q": {"path": "/q"}}}"#)))
        XCTAssertNoThrow(try page(#"{"id": "x", "component": "TextField", "label": "再填一次", "variant": "obscured", "value": {"path": "/fields/code"}}"#),
                         "几个密码框绑同一个路径不算")
    }
}
