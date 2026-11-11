import AppKit
import SwiftUI
import XCTest
@testable import LuokeWindow

/// 颜色够清楚：实心按钮上的字和底色的对比度不低于 4.5（WCAG AA 正文）
final class ThemeTests: XCTestCase {
    private func luminance(_ c: Color) -> Double {
        let n = NSColor(c).usingColorSpace(.sRGB)!
        func lin(_ v: CGFloat) -> Double { let x = Double(v); return x <= 0.04045 ? x / 12.92 : pow((x + 0.055) / 1.055, 2.4) }
        return 0.2126 * lin(n.redComponent) + 0.7152 * lin(n.greenComponent) + 0.0722 * lin(n.blueComponent)
    }

    private func contrast(_ a: Color, _ b: Color) -> Double {
        let (x, y) = (luminance(a), luminance(b))
        return (max(x, y) + 0.05) / (min(x, y) + 0.05)
    }

    func testFilledButtonsAreReadable() {
        for (name, p) in [("浅色", Palette.light), ("深色", Palette.dark)] {
            XCTAssertGreaterThanOrEqual(contrast(.white, p.dangerFill), 4.5, "\(name)：红按钮上的白字")
            XCTAssertGreaterThanOrEqual(contrast(p.primaryFg, p.primary), 4.5, "\(name)：主按钮")
            XCTAssertGreaterThanOrEqual(contrast(p.fg, p.bg), 4.5, "\(name)：正文")
            XCTAssertGreaterThanOrEqual(contrast(p.brandText, p.brandSoft), 4.5, "\(name)：粉底小标签上的珊瑚红字")
            for (where_, bg) in [("页面", p.bg), ("侧栏", p.sidebar), ("卡片", p.card), ("浅底", p.muted)] {
                XCTAssertGreaterThanOrEqual(contrast(p.mutedFg, bg), 4.5, "\(name)：\(where_)上的次要字")
            }
        }
    }

    /// 主要的几个颜色
    func testBrandColours() {
        XCTAssertEqual(Palette.light.bg, .hex(0xFCFAF7))
        XCTAssertEqual(Palette.light.sidebar, .hex(0xF7F2EB))
        XCTAssertEqual(Palette.light.fg, .hex(0x3A1F14))
        XCTAssertEqual(Palette.light.primary, .hex(0x3A1F14))
        XCTAssertEqual(Palette.light.brand, .hex(0xE8556B))
        XCTAssertEqual(Palette.dark.fg, .hex(0xFFF8EE))
        XCTAssertEqual(Palette.dark.primary, .hex(0xFFF8EE))
        XCTAssertEqual(Palette.dark.primaryFg, .hex(0x3A1F14))
    }

    /// 字号只用五档，圆角只用这几档，间距在 4 pt 的格子上
    func testTokens() {
        XCTAssertEqual([LKType.title, LKType.lead, LKType.body, LKType.small, LKType.caption], [26, 15, 14, 13, 12])
        XCTAssertEqual([LKRadius.small, LKRadius.control, LKRadius.card, LKRadius.sheet], [6, 8, 14, 20])
        XCTAssertEqual(LKRadius.focus, 16)
        for v in [LKSpace.x1, LKSpace.x2, LKSpace.x3, LKSpace.x4, LKSpace.x5, LKSpace.x6, LKSpace.x7, LKSpace.x8, LKSpace.x11, LKSpace.x14] {
            XCTAssertEqual(v.truncatingRemainder(dividingBy: 4), 0, "\(v)")
        }
        XCTAssertEqual([LKHeight.button, LKHeight.buttonLarge, LKHeight.buttonSmall], [30, 36, 24])
    }

    /// 次按钮是字色的 6 %、侧栏选中 7 %（深色都是 8 %）
    func testTints() {
        func alpha(_ c: Color) -> CGFloat { NSColor(c).usingColorSpace(.sRGB)!.alphaComponent }
        XCTAssertEqual(alpha(Palette.light.tint), 0.06, accuracy: 0.001)
        XCTAssertEqual(alpha(Palette.light.selection), 0.07, accuracy: 0.001)
        XCTAssertEqual(alpha(Palette.dark.tint), 0.08, accuracy: 0.001)
    }

    /// 字色在会出现的底色上都到 4.5:1（WCAG AA 正文）：灰字、红字、绿字、珊瑚红字，在页面底、卡片、侧栏、浅灰底、急事的粉底上
    func testTextContrast() {
        func lum(_ c: Color) -> Double {
            let n = NSColor(c).usingColorSpace(.sRGB)!
            func ch(_ v: CGFloat) -> Double { let v = Double(v); return v <= 0.03928 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4) }
            return 0.2126 * ch(n.redComponent) + 0.7152 * ch(n.greenComponent) + 0.0722 * ch(n.blueComponent)
        }
        func ratio(_ a: Color, _ b: Color) -> Double {
            let (x, y) = (lum(a), lum(b))
            return (max(x, y) + 0.05) / (min(x, y) + 0.05)
        }
        for p in [Palette.light, Palette.dark] {
            for (fn, fg) in [("mutedFg", p.mutedFg), ("danger", p.danger), ("success", p.success), ("brandText", p.brandText)] {
                for (bn, bg) in [("bg", p.bg), ("card", p.card), ("sidebar", p.sidebar), ("muted", p.muted), ("dangerSoft", p.dangerSoft), ("brandSoft", p.brandSoft)] {
                    XCTAssertGreaterThanOrEqual(ratio(fg, bg), 4.5, "\(p.dark ? "深色" : "浅色") \(fn) 在 \(bn) 上")
                }
            }
        }
    }

    /// 动效的曲线和时长
    func testMotion() {
        XCTAssertEqual(Motion.press, 0.09)
        XCTAssertEqual(Motion.cardLeave, 0.13)
        XCTAssertEqual(Motion.reflow, 0.32)
        XCTAssertEqual(Motion.flight, 0.44)
        XCTAssertEqual(Motion.focusGrow, 0.42)
        XCTAssertEqual(Motion.pill, 0.28)
        XCTAssertEqual(Motion.thumb, 0.24)
        // 飞的那一程：两头在图标位上，中间往左边空白处偏，路上从 28 缩到 20
        let from = CGRect(x: 20, y: 300, width: 28, height: 28), to = CGRect(x: 16, y: 120, width: 20, height: 20)
        XCTAssertEqual(FlightPath.at(0, from: from, to: to).minX, from.minX, accuracy: 0.01)
        XCTAssertEqual(FlightPath.at(0, from: from, to: to).minY, from.minY, accuracy: 0.01)
        XCTAssertEqual(FlightPath.at(0, from: from, to: to).width, 28, accuracy: 0.01)
        XCTAssertEqual(FlightPath.at(1, from: from, to: to).minX, to.minX, accuracy: 0.01)
        XCTAssertEqual(FlightPath.at(1, from: from, to: to).minY, to.minY, accuracy: 0.01)
        XCTAssertEqual(FlightPath.at(1, from: from, to: to).width, 20, accuracy: 0.01)
        XCTAssertEqual(FlightPath.at(0.5, from: from, to: to).minX, from.minX + (to.minX - from.minX) / 2 - 36, accuracy: 0.01)
        XCTAssertLessThan(FlightPath.at(0.25, from: from, to: to).minX, from.minX, "先往左偏，不压过别的行")
    }
}
