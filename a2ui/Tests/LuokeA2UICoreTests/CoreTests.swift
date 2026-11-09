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
            let problems = validate(c["messages"]!.array!, catalog: c["catalog"]!.string!)
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

    func testBoolsStayBools() throws {
        let v = try JSONValue.parse(#"{"t": true, "n": 1}"#)
        XCTAssertEqual(v["t"], .bool(true))
        XCTAssertEqual(v["n"], .number(1))
        XCTAssertEqual(try JSONValue.parse(v.serialized()), v)
    }
}
