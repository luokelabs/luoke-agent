#if os(macOS)
import LuokeA2UICore
@testable import LuokeA2UI
import SwiftUI
import XCTest

@MainActor
final class LayoutTests: XCTestCase {
    /// 一排按钮（Row 里只有按钮，画成 FlowLayout）：给的宽比一排的总宽少不到 1 pt 时还是一行；真放不下才折行
    func testButtonsThatFitStayOnOneRow() throws {
        let m = try card(#"""
        {"id":"root","component":"Row","children":["b1","b2","b3"]},
        {"id":"b1","component":"Button","child":"t1","action":{"event":{"name":"a"}}},
        {"id":"t1","component":"Text","text":"按这个处理"},
        {"id":"b2","component":"Button","child":"t2","action":{"event":{"name":"b"}}},
        {"id":"t2","component":"Text","text":"先不动"},
        {"id":"b3","component":"Button","child":"t3","action":{"event":{"name":"c"}}},
        {"id":"t3","component":"Text","text":"在访达里显示"}
        """#)
        let one = sizeOf(m, width: nil)
        XCTAssertGreaterThan(one.width, 100)
        for short in [0, 0.3, 0.6, 0.9] as [CGFloat] {
            XCTAssertEqual(sizeOf(m, width: one.width - short).height, one.height, accuracy: 0.5, "少 \(short) pt 还是一行")
        }
        XCTAssertGreaterThan(sizeOf(m, width: one.width - 40).height, one.height + 10, "真放不下时折行")
    }

    /// 一组名字小块（§4 chips：Row 里只有 badge，最后一段 caption）：放不下就换行，不比给的宽更宽
    func testChipsWrapInsteadOfOverflowing() throws {
        let names = ["Alpha 插件", "Beta 项目", "Gamma 工具", "Delta 应用", "Epsilon", "Zeta 助手"]
        let chips = names.indices.map { #"{"id":"c\#($0)","component":"Text","text":"\#(names[$0])","variant":"badge","tone":"neutral"}"# }
        let ids = names.indices.map { #""c\#($0)""# }.joined(separator: ",")
        let m = try card(#"{"id":"root","component":"Row","children":[\#(ids),"more"]},"# + chips.joined(separator: ",")
                         + #",{"id":"more","component":"Text","text":"等 12 个","variant":"caption"}"#)
        let one = sizeOf(m, width: nil)
        let narrow = sizeOf(m, width: 150)
        XCTAssertGreaterThan(narrow.height, one.height * 2, "窄的时候折成几行")
        XCTAssertLessThanOrEqual(narrow.width, 151, "不比给的宽更宽")
    }

    /// 量出来几行就摆几行：一排的宽带小数（字量出来的宽常常是这样），放的位置也带小数；摆出来的每一块都在量出来的高里面，
    /// 也不超出给的宽（最多差 1 pt）
    func testFlowLayoutPlacesTheLinesItMeasured() {
        let widths: [CGFloat] = [61.3, 47.65, 80.45]
        let total = widths.reduce(0, +) + 8 * CGFloat(widths.count - 1)
        for (extra, lines) in [(0.6, 1), (0, 1), (-0.4, 1), (-0.9, 1), (-30, 2), (-100, 3)] as [(CGFloat, Int)] {
            for inset in [0, 0.25, 0.5, 0.75] as [CGFloat] {
                let f = Frames(), w = total + extra
                let flow = FlowLayout(spacing: 8) {
                    ForEach(widths.indices, id: \.self) { i in Color.gray.frame(width: widths[i], height: 22).probe("b\(i)", f) }
                }
                render(flow.probe("flow", f).frame(width: w, alignment: .leading).padding(.leading, inset), width: w + inset + 20)
                let what = "宽 \(w)、左边空 \(inset)"
                guard let box = f.at["flow"], widths.indices.allSatisfy({ f.at["b\($0)"] != nil }) else {
                    return XCTFail("\(what)：没摆出来")
                }
                let tops = Set(widths.indices.map { (f.at["b\($0)"]!.minY * 2).rounded() })
                XCTAssertEqual(tops.count, lines, "\(what)：摆了几行")
                XCTAssertEqual(box.height, CGFloat(lines) * 22 + CGFloat(lines - 1) * 8, accuracy: 0.5, "\(what)：量了几行")
                for i in widths.indices {
                    let b = f.at["b\(i)"]!
                    XCTAssertLessThanOrEqual(b.maxY, box.maxY + 0.5, "\(what)：第 \(i) 个画到量出来的高外面")
                    XCTAssertLessThanOrEqual(b.maxX, inset + w + 1.5, "\(what)：第 \(i) 个超出给的宽（最多差 1 pt）")
                }
            }
        }
    }

    /// 「今天」新模板里的邮件一封一行（spaceBetween）：左边发件人加标签不缩，右边是按钮。宽的时候一行、占满给的宽；
    /// 窄到左边放不下时不比给的宽更宽（原来把卡片连带整页撑宽），右边那块折到下一行
    func testSpaceBetweenRowDoesNotWidenTheCard() throws {
        let m = try card(#"""
        {"id":"root","component":"Column","children":["row"]},
        {"id":"row","component":"Row","justify":"spaceBetween","children":["who","pick","cal"]},
        {"id":"who","component":"Row","children":["s","bd"]},
        {"id":"s","component":"Text","text":"CareerLink 事務局","variant":"strong"},
        {"id":"bd","component":"Text","text":"今天截止","variant":"badge"},
        {"id":"pick","component":"Button","child":"pt","action":{"event":{"name":"a"}}},
        {"id":"pt","component":"Text","text":"加星标"},
        {"id":"cal","component":"Button","child":"ct","action":{"event":{"name":"b"}}},
        {"id":"ct","component":"Text","text":"11-12 16:00"}
        """#)
        let ideal = sizeOf(m, width: nil)
        XCTAssertGreaterThan(ideal.width, 150)
        let wide = sizeOf(m, width: ideal.width + 60)
        XCTAssertEqual(wide.width, ideal.width + 60, accuracy: 0.5, "一行占满给的宽")
        XCTAssertEqual(wide.height, ideal.height, accuracy: 0.5, "放得下是一行")
        for w in [ideal.width - 20, ideal.width - 80] {
            let narrow = sizeOf(m, width: w)
            XCTAssertLessThanOrEqual(narrow.width, w + 0.5, "给 \(w) 宽时不撑宽")
            XCTAssertGreaterThan(narrow.height, ideal.height + 10, "给 \(w) 宽时右边折到下一行")
        }
    }
}
#endif
