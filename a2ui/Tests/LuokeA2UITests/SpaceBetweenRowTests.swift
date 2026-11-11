#if os(macOS)
@testable import LuokeA2UI
import SwiftUI
import XCTest

/// `SpaceBetweenRow` 排得下时和原来的 HStack 摆得一样；排不下时右边那块折到下一行、靠右，左边不被切掉
@MainActor
final class SpaceBetweenRowTests: XCTestCase {
    static let long = "CareerLink 事務局 IT 交流会 今天截止报名，这一段字长得要截断或者换行才放得下"

    /// 左边的几种：不缩的字、截断的一行、占满的短字、换行的长字、不缩的长字、一行里不缩的名字加截断的主题
    static func lefts() -> [(String, AnyView)] {
        [("不缩的短字", AnyView(Text("Short").fixedSize())),
         ("截断的一行", AnyView(Text(long).lineLimit(1))),
         ("占满的短字", AnyView(Text("Short").frame(maxWidth: .infinity, alignment: .leading))),
         ("换行的长字", AnyView(Text(long).fixedSize(horizontal: false, vertical: true))),
         ("不缩的长字", AnyView(Text("CareerLink 事務局 IT 交流会 · 报名").fixedSize())),
         ("名字加截断的主题", AnyView(HStack(spacing: 6) {
             Text("CareerLink 事務局").fixedSize()
             Text(long).lineLimit(1).layoutPriority(-1)
         }.frame(maxWidth: .infinity, alignment: .leading)))]
    }

    static func right(_ f: Frames) -> some View {
        HStack(spacing: 6) {
            Color.gray.frame(width: 64, height: 22).fixedSize()
            Color.gray.frame(width: 40.5, height: 24).fixedSize()
        }.probe("right", f)
    }

    func frames(old: Bool, _ left: AnyView, width: CGFloat) -> Frames {
        let f = Frames()
        let row: AnyView = old
            ? AnyView(HStack(alignment: .center, spacing: 12) { left.probe("left", f); Spacer(minLength: 8); Self.right(f) })
            : AnyView(SpaceBetweenRow { left.probe("left", f); Self.right(f) })
        render(VStack(alignment: .leading, spacing: 0) { row.probe("row", f) }.frame(width: width, alignment: .leading), width: width)
        return f
    }

    func testLooksTheSameAsTheOldRowWhenItFits() {
        for (what, left) in Self.lefts() {
            for width in [600, 400, 320, 260] as [CGFloat] {
                let old = frames(old: true, left, width: width)
                guard let oldRow = old.at["row"], oldRow.width <= width + 0.5 else { continue }   // 原来就撑宽了的，看下一个测试
                let new = frames(old: false, left, width: width)
                for k in ["left", "right", "row"] {
                    guard let a = old.at[k], let b = new.at[k] else { XCTFail("\(what) \(width)：\(k) 没摆出来"); continue }
                    XCTAssertEqual(a.minX, b.minX, accuracy: 0.5, "\(what) \(width)：\(k) 的 x")
                    XCTAssertEqual(a.minY, b.minY, accuracy: 0.5, "\(what) \(width)：\(k) 的 y")
                    XCTAssertEqual(a.width, b.width, accuracy: 0.5, "\(what) \(width)：\(k) 的宽")
                    XCTAssertEqual(a.height, b.height, accuracy: 0.5, "\(what) \(width)：\(k) 的高")
                }
            }
        }
    }

    func testWrapsTheRightPartWhenTheLeftCannotShrink() {
        let left = Self.lefts().first { $0.0 == "不缩的长字" }!.1
        for width in [300, 240, 200] as [CGFloat] {
            let f = frames(old: false, left, width: width)
            guard let row = f.at["row"], let l = f.at["left"], let r = f.at["right"] else { return XCTFail("\(width)：没摆出来") }
            XCTAssertLessThanOrEqual(row.width, width + 0.5, "\(width)：不撑宽")
            XCTAssertEqual(l.minX, 0, accuracy: 0.5, "\(width)：左边靠左、不被切掉")
            XCTAssertEqual(r.maxX, width, accuracy: 0.5, "\(width)：右边靠右")
            XCTAssertGreaterThanOrEqual(r.minY, l.maxY, "\(width)：右边在下一行")
            XCTAssertLessThanOrEqual(r.maxY, row.maxY + 0.5, "\(width)：在量出来的高里面")
        }
    }
}
#endif
