import AppKit
import SwiftUI
import XCTest
@testable import LuokeWindow

/// 每个界面都画得出来，而且不是空白、没有画不出的控件（离屏画不出 AppKit 控件时会是一块黄底的「禁止」符号）。
/// 设了 LUOKE_SHOTS_DIR 就把图写进去，方便本机看。
@MainActor
final class ScreenshotTests: XCTestCase {
    func testEveryScreenRenders() throws {
        let screens = Snapshot.screens()
        XCTAssertGreaterThanOrEqual(screens.count, 25)
        XCTAssertEqual(Set(screens.map(\.name)).count, screens.count, "名字不能重")
        let dir = ProcessInfo.processInfo.environment["LUOKE_SHOTS_DIR"].map { URL(fileURLWithPath: $0) }
        for s in screens {
            for dark in [false, true] {
                let png = try XCTUnwrap(Snapshot.png(s, dark: dark, scale: 1), "\(s.name) 画不出")
                let rep = try XCTUnwrap(NSBitmapImageRep(data: png))
                XCTAssertEqual(rep.pixelsWide, Int(s.size.width), s.name)
                XCTAssertEqual(rep.pixelsHigh, Int(s.size.height), s.name)
                XCTAssertGreaterThan(distinctColors(rep), 12, "\(s.name) 像是空白的")
                XCTAssertEqual(placeholderPixels(rep), 0, "\(s.name) 里有画不出的 AppKit 控件（黄底「禁止」）")
                if let dir { try png.write(to: dir.appendingPathComponent("\(s.name)-\(dark ? "dark" : "light").png")) }
            }
        }
    }

    /// 上面那条检测真能认出画不出的系统控件（系统开关离屏会画成「禁止」）
    func testDetectsUndrawableControls() throws {
        let r = ImageRenderer(content: Toggle("开关", isOn: .constant(true)).toggleStyle(.switch).padding(20).frame(width: 200, height: 80))
        let cg = try XCTUnwrap(r.cgImage)
        XCTAssertGreaterThan(placeholderPixels(NSBitmapImageRep(cgImage: cg)), 0)
    }

    /// 深浅两套确实不一样
    func testDarkDiffersFromLight() throws {
        let s = Snapshot.screens().first { $0.name == "today" }!
        let light = try XCTUnwrap(Snapshot.png(s, dark: false, scale: 1))
        let dark = try XCTUnwrap(Snapshot.png(s, dark: true, scale: 1))
        XCTAssertNotEqual(light, dark)
    }

    /// 同一个界面画两次，图一样（每个 PR 比较截图要靠这个）
    func testRenderingIsStable() throws {
        let s = Snapshot.screens().first { $0.name == "prefs-alerts" }!
        XCTAssertEqual(Snapshot.png(s, dark: false, scale: 1), Snapshot.png(s, dark: false, scale: 1))
    }

    /// 离屏画不出的 AppKit 控件会画成黄底红圈的「禁止」：数那种黄（r≈255、g≈210、b≈0）
    private func placeholderPixels(_ rep: NSBitmapImageRep) -> Int {
        var n = 0
        var y = 0
        while y < rep.pixelsHigh {
            var x = 0
            while x < rep.pixelsWide {
                if let c = rep.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) {
                    let r = c.redComponent * 255, g = c.greenComponent * 255, b = c.blueComponent * 255
                    if r > 242, g > 195, g < 225, b < 40 { n += 1 }
                }
                x += 3
            }
            y += 3
        }
        return n
    }

    private func distinctColors(_ rep: NSBitmapImageRep) -> Int {
        var seen = Set<UInt32>()
        let w = rep.pixelsWide, h = rep.pixelsHigh
        var y = 0
        while y < h {
            var x = 0
            while x < w {
                if let c = rep.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) {
                    let v = (UInt32(c.redComponent * 255) << 16) | (UInt32(c.greenComponent * 255) << 8) | UInt32(c.blueComponent * 255)
                    seen.insert(v)
                }
                x += 7
            }
            y += 7
        }
        return seen.count
    }
}
