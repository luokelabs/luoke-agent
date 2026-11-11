import LuokeA2UICore
import XCTest
@testable import LuokeWindow

/// 协议认的每个 Lucide 图标名（工具协议 §4）窗口都带着图；以前的名字换成的也在
@MainActor
final class LucideTests: XCTestCase {
    func testEveryProtocolIconHasItsSVG() {
        for name in A2UI.lucideIcons.sorted() {
            XCTAssertNotNil(Lucide.nsImage(name), "Resources/lucide/\(name).svg")
        }
        for (old, new) in A2UI.iconAliases {
            XCTAssertTrue(A2UI.lucideIcons.contains(new), "\(old) → \(new)")
        }
    }
}
