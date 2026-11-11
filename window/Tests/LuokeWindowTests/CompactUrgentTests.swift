import AppKit
import LuokeA2UI
import LuokeA2UICore
import SwiftUI
import XCTest
@testable import LuokeWindow

/// 紧凑的「今天」的急事（#54）：一下报两百多件急事时，同一类叠成一行、最多 3 行，一屏里每行分得清是哪一件；
/// 选择框在真窗口里和截图是同一个框（#65）
@MainActor
final class CompactUrgentTests: XCTestCase {
    /// #54 的回放（合成的）：邮件助手录的那张可疑邮件复制 200 份、每份一句不同的副标题，扫描报毒的 2 件，别的应用 3 件。
    /// `decide`：邮件助手要你决定的那张复制几份（#51 的 stress-brief-many）
    static func replay(decide: Int = 0) -> WindowModel {
        let m = Sample.model()
        let feed = AgentFeed(model: m)
        var events = Sample.agentEvents(scan: ToolSample.fullScan, mail: ToolSample.defaultMail, memory: false, extras: false)
        events = StressSample.urgentFlood(events, app: "luoke-mail", times: StressSample.urgentReplay - 5, subtitle: StressSample.mailSubtitle)
        if decide > 0 { events = StressSample.decideFlood(events, app: "luoke-mail", times: decide) }
        for (e, d) in events { feed.handle(e, d) }
        m.urgent += [
            UrgentItem(id: "x-cal", tool: .mail, title: "王经理说 10 点的会提前到 9:30", time: "09:56", primary: "知道了", primarySymbol: nil,
                       secondary: "打开邮件", kind: "meeting"),
            UrgentItem(id: "x-disk", tool: .core, title: "磁盘只剩 4 GB", time: "09:40", primary: "看看能清什么", primarySymbol: nil,
                       secondary: "稍后", kind: "disk"),
            UrgentItem(id: "x-login", tool: .mail, title: "有人在新设备上登录了你的邮箱", time: "09:12", primary: "是我", primarySymbol: nil,
                       secondary: "不是我", kind: "login"),
        ]
        return m
    }

    func testTwoHundredUrgentItemsAreAtMostThreeDistinctRows() {
        let m = Self.replay()
        XCTAssertEqual(m.urgent.count, StressSample.urgentReplay)
        let shown = TodayCompact.urgentRows(m.urgent, all: false)
        XCTAssertLessThanOrEqual(shown.stacks.count, 3, "急事最多 3 行")
        XCTAssertEqual(shown.stacks.reduce(0) { $0 + $1.count } + shown.more, m.urgent.count, "其余的都算进「还有 N 件急事」")
        XCTAssertGreaterThan(shown.more, 0)
        let rows = shown.stacks.map(TodayCompact.urgentText)
        XCTAssertEqual(Set(rows.map { "\($0.title)|\($0.sub ?? "")" }).count, rows.count, "一屏里每行分得清：\(rows)")
        let mail = shown.stacks.first { $0.count > 1 }
        XCTAssertEqual(mail?.count, StressSample.urgentReplay - 5, "200 封可疑邮件叠成一行")
        XCTAssertEqual(mail.map(TodayCompact.urgentText)?.title, "200 封可疑邮件")
        XCTAssertNotNil(mail.map(TodayCompact.urgentText)?.sub, "后面是第一件的副标题")
        let all = TodayCompact.urgentRows(m.urgent, all: true)
        XCTAssertEqual(all.more, 0, "点了「还有 N 件急事」：都列出来")
        let allRows = all.stacks.map(TodayCompact.urgentText)
        XCTAssertEqual(Set(allRows.map { "\($0.title)|\($0.sub ?? "")" }).count, allRows.count, "列全了也分得清：\(allRows)")
    }

    func testOpenedStackRowsAreTellApartBySubtitle() throws {
        let m = Self.replay()
        let stack = try XCTUnwrap(TodayCompact.urgentRows(m.urgent, all: false).stacks.first { $0.count > 1 })
        let lines = stack.map { TodayCompact.urgentText([$0]) }
        XCTAssertTrue(lines.allSatisfy { $0.sub != nil }, "点开的每一件都有副标题")
        // 一屏（760 高的窗口里不到 20 行）里的每一行分得清：任意连着的 20 行，副标题没有两行一样
        let screen = 20
        for start in 0...(lines.count - screen) {
            let rows = lines[start..<(start + screen)].map { $0.sub ?? "" }
            XCTAssertEqual(Set(rows).count, screen, "第 \(start + 1) 行起的一屏：\(rows)")
        }
    }

    func testSubtitleComesFromTheCardRoot() throws {
        let m = Self.replay()
        let u = try XCTUnwrap(m.urgent.first { $0.surface != nil && $0.tool == .mail })
        XCTAssertEqual(u.surface?.surface.subtitle, StressSample.mailSubtitle(0))
        XCTAssertEqual(TodayCompact.chooseLabel, "选一下")
    }

    /// §4 countWeights：窗口里按钮的字（卡片里、紧凑的表和一件件处理另画的按钮）照 weights 数，选一下就跟着变
    func testWeightedCountLabelInTheWindow() throws {
        let msgs = try JSONValue.parse(Data("""
        [{"version":"v0.9","createSurface":{"surfaceId":"s","catalogId":"ai.luoke/a2ui/agent/1"}},
         {"version":"v0.9","updateComponents":{"surfaceId":"s","components":[
           {"id":"root","component":"Button","child":"t","count":{"path":"/choices","value":"trash","weights":{"g-pkg":41}},
            "action":{"event":{"name":"scan_apply","context":{"choices":{"path":"/choices"}}}}},
           {"id":"t","component":"Text","text":"移到废纸篓 {n} 项"}]}},
         {"version":"v0.9","updateDataModel":{"surfaceId":"s","path":"/","value":{"choices":{"g-pkg":["trash"],"i1":["trash"]}}}}]
        """.utf8)).array!
        let s = SurfaceModel(surface: try Surface.build(msgs))
        XCTAssertEqual(SurfaceDigest(s.surface).actions.first?.label, "移到废纸篓 42 项")
        s.set("/choices/g-pkg", .array([.string("keep")]))
        XCTAssertEqual(SurfaceDigest(s.surface).actions.first?.label, "移到废纸篓 1 项")
    }

    // MARK: 选择框（#65）

    private func render<V: View>(_ name: String, _ v: V, live: Bool, dark: Bool = false, size: CGSize) throws -> NSBitmapImageRep {
        let view = Themed { v }
            .frame(width: size.width, height: size.height)
            .background(dark ? Palette.dark.bg : Palette.light.bg)
            .environment(\.colorScheme, dark ? .dark : .light)
            .environment(\.lkSnapshot, true)
            .environment(\.lkLiveControls, live)
        let r = ImageRenderer(content: view)
        r.scale = 2   // 1 pt 的边在 2 倍图里至少有一行整像素
        let rep = NSBitmapImageRep(cgImage: try XCTUnwrap(r.cgImage))
        if let dir = ProcessInfo.processInfo.environment["LUOKE_SHOTS_DIR"] {
            let name = "test-\(name)-\(live ? "live" : "static")-\(dark ? "dark" : "light").png"
            try rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: dir).appendingPathComponent(name))
        }
        return rep
    }

    /// 和这个颜色差不多的像素有几个
    private func count(_ rep: NSBitmapImageRep, near c: (Int, Int, Int), tolerance: Int = 16) -> Int {
        var n = 0
        for y in 0..<rep.pixelsHigh {
            for x in 0..<rep.pixelsWide {
                guard let p = rep.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) else { continue }
                let r = Int(p.redComponent * 255), g = Int(p.greenComponent * 255), b = Int(p.blueComponent * 255)
                if abs(r - c.0) <= tolerance && abs(g - c.1) <= tolerance && abs(b - c.2) <= tolerance { n += 1 }
            }
        }
        return n
    }

    private func choiceCard() throws -> SurfaceModel {
        let msgs = try JSONValue.parse(Data("""
        [{"version":"v0.9","createSurface":{"surfaceId":"s","catalogId":"ai.luoke/a2ui/agent/1"}},
         {"version":"v0.9","updateComponents":{"surfaceId":"s","components":[
           {"id":"root","component":"Column","children":["c"]},
           {"id":"c","component":"ChoicePicker","label":"下载里的 setup.pkg","value":{"path":"/choices/a"},
            "options":[{"value":"trash","label":"移到废纸篓","icon":"trash-2"},{"value":"keep","label":"先不动","icon":"circle-minus"}]}]}},
         {"version":"v0.9","updateDataModel":{"surfaceId":"s","path":"/","value":{"choices":{"a":["keep"]}}}}]
        """.utf8)).array!
        return SurfaceModel(surface: try Surface.build(msgs))
    }

    /// 真窗口里的选择框和截图里的一模一样（以前真窗口里塞进 `Menu` 的 label，只剩字和一个黑色的大图标），框有 1 pt 的边
    func testLiveChoiceBoxIsTheSameBoxAsTheScreenshot() throws {
        let s = try choiceCard()
        for dark in [false, true] {
            let card = SurfaceView(model: s) { _, _, _ in }.padding(12)
            let live = try render("choice", card, live: true, dark: dark, size: CGSize(width: 460, height: 60))
            let shot = try render("choice", card, live: false, dark: dark, size: CGSize(width: 460, height: 60))
            XCTAssertEqual(live.representation(using: .png, properties: [:]), shot.representation(using: .png, properties: [:]),
                           "真窗口那条路画的和截图一样（\(dark ? "深色" : "浅色")）")
            let input = dark ? (0x40, 0x36, 0x2F) : (0xE2, 0xD8, 0xCC)
            XCTAssertGreaterThan(count(live, near: input), 30, "框的边画出来了（\(dark ? "深色" : "浅色")）")
        }
    }

    /// 设置 · 提醒的下拉框（简报、免打扰）也是这个框：有边，箭头在字后面
    func testSettingsSelectIsTheSameBox() throws {
        let select = LKSelect(value: "每天早上", options: BriefMode.allCases.map(\.rawValue), label: "简报") { _ in }.padding(12)
        let live = try render("select", select, live: true, size: CGSize(width: 200, height: 52))
        let shot = try render("select", select, live: false, size: CGSize(width: 200, height: 52))
        XCTAssertEqual(live.representation(using: .png, properties: [:]), shot.representation(using: .png, properties: [:]))
        XCTAssertGreaterThan(count(live, near: (0xE2, 0xD8, 0xCC)), 30, "框的边画出来了")
    }
}
