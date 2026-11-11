import Foundation
import LuokeA2UI
import LuokeA2UICore
import XCTest
@testable import LuokeWindow

/// 邮件助手录的每个场景（fixtures/luoke-mail 经真核心，Resources/samples/luoke-mail）在窗口里：卡片、每一页都过窗口自己的校验、
/// 画得出来。0.19.46 起照核心认的写法录：卡片上的「在邮件助手里看」是 `agent.open_page`（只讲一封的卡片带 `args`，工具协议 §4 pageArgs）。
/// 0.19.47 起每个邮箱一张（种类 `mailbox`，`low`）：放在「顺便看看」，分块的按钮上下文带 `part`，「查看」开收件箱时带 `box`、`list`。
@MainActor
final class MailSampleTests: XCTestCase {
    func testEveryScenarioDrawsItsCardsAndPages() throws {
        let scenarios = ToolSample.scenarios("luoke-mail")
        XCTAssertFalse(scenarios.isEmpty, "Resources/samples/luoke-mail 里要有场景")
        var openPages = 0, withArgs = 0, withList = 0, mailboxes = 0
        for sc in scenarios {
            let s = try XCTUnwrap(ToolSample.load("luoke-mail", sc))
            let m = Sample.model()
            let f = AgentFeed(model: m)
            for (e, d) in s.events { f.handle(e, d) }
            let cards = f.surfaces.filter { $0.key.hasPrefix("luoke-mail/") }
            XCTAssertFalse(cards.isEmpty, "\(sc)：有邮件助手的卡片")
            for (sid, c) in cards {
                XCTAssertEqual(c.surface.problems(), [], "\(sc) \(sid)")
                for id in c.surface.reachable() {
                    guard let (name, ctx) = try? c.surface.buttonEvent(id), name == "agent.open_page" else { continue }
                    XCTAssertTrue(s.pageIDs.contains(ctx["page"]?.string ?? ""), "\(sc) \(sid)：开的是邮件助手登记的页")
                    openPages += 1
                    if let args = ctx["args"]?.object, !args.isEmpty {
                        XCTAssertNil(A2UI.pageArgsProblem(.object(args)), "\(sc) \(sid)")
                        withArgs += 1
                        if args["box"]?.string != nil, args["list"]?.string != nil { withList += 1 }
                    }
                }
            }
            for c in f.cards where c.app == "luoke-mail" && c.kind == "mailbox" {
                mailboxes += 1
                XCTAssertEqual(c.section, "later", "\(sc) \(c.id)：邮箱里不急的放「顺便看看」")
                XCTAssertTrue(m.quiet.contains { $0.id == c.id && $0.surface != nil }, "\(sc) \(c.id)：在「顺便看看」里画成卡片")
                let surface = try XCTUnwrap(f.surfaces[c.id]).surface
                let parts = surface.reachable().compactMap { id -> String? in
                    guard let (_, ctx) = try? surface.buttonEvent(id) else { return nil }
                    return ctx["part"]?.string
                }
                XCTAssertFalse(parts.isEmpty, "\(sc) \(c.id)：分块的按钮上下文带 part")
            }
            Sample.applyAgentApps(f, mail: sc)
            for id in s.pageIDs {
                let p = m.agentPages[AgentFeed.pageKey("luoke-mail", id)]
                XCTAssertNotNil(p?.surface, "\(sc) \(id)：\(p?.error ?? "没取到")")
                XCTAssertEqual(p?.surface?.surface.problems() ?? [], [], "\(sc) \(id)")
            }
        }
        XCTAssertGreaterThan(openPages, 0, "卡片上的「在邮件助手里看」换到窗口的页")
        XCTAssertGreaterThan(withArgs, 0, "只讲一封的卡片带上那一封")
        XCTAssertGreaterThan(withList, 0, "「查看全部」开这个邮箱的那个列表（box、list）")
        XCTAssertGreaterThan(mailboxes, 0, "样例里有每个邮箱一张的卡片")
    }
}
