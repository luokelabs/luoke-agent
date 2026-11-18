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
        Snapshot.missingSamples = []
        defer {
            // 截图点名的工具场景都有样例：写错了名字，图照样画得出来，只是少了那个应用（用本机录的样例时不核）
            if ToolSample.local.dir == nil && ToolSample.local.scenario == nil {
                XCTAssertEqual(Snapshot.missingSamples, [], "截图点名的场景没有样例")
            }
        }
        for s in screens {
            for dark in [false, true] { try autoreleasepool {
                // 先报正在画哪个：进程在这里退出时（CI 上 #142 起出过），日志停在哪个界面一看就知道。stderr 不缓冲
                FileHandle.standardError.write(Data("画 \(s.name)-\(dark ? "dark" : "light")\n".utf8))
                let png = try XCTUnwrap(Snapshot.png(s, dark: dark, scale: 1), "\(s.name) 画不出")
                let rep = try XCTUnwrap(NSBitmapImageRep(data: png))
                XCTAssertEqual(rep.pixelsWide, Int(s.size.width), s.name)
                XCTAssertEqual(rep.pixelsHigh, Int(s.size.height), s.name)
                XCTAssertGreaterThan(distinctColors(rep), 12, "\(s.name) 像是空白的")
                XCTAssertEqual(placeholderPixels(rep), 0, "\(s.name) 里有画不出的 AppKit 控件（黄底「禁止」）")
                if let dir { try png.write(to: dir.appendingPathComponent("\(s.name)-\(dark ? "dark" : "light").png")) }
            } }
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

    /// 同一个界面画两次，图一样（每个 PR 比较截图要靠这个）。卡片圆角上影子的几个像素，头一次画和后面画会差一两级
    /// （255 级里的 1 到 2，圆角 12 时量到 8 个像素；11-12），看不出来：所以比像素，容得下两级的差，差的像素不超过 64 个
    func testRenderingIsStable() throws {
        let s = Snapshot.screens().first { $0.name == "prefs-general" }!
        // 两张图都先画进同一种 8 位 RGBA 的位图再比。直接比 NSBitmapImageRep 的字节不可靠：整套一起跑时图有时是每通道 16 位，
        // 差 1 级的像素低字节能差到两百多（11-16 抓到的：存下的两张图逐像素只差 1 级，测试却报差 224 级）
        func pixels(_ d: Data?) throws -> [UInt8] {
            let rep = try XCTUnwrap(NSBitmapImageRep(data: try XCTUnwrap(d)))
            let cg = try XCTUnwrap(rep.cgImage)
            let w = cg.width, h = cg.height
            var buf = [UInt8](repeating: 0, count: w * h * 4)
            try buf.withUnsafeMutableBytes { raw in
                let ctx = try XCTUnwrap(CGContext(data: raw.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
                ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
            }
            return buf
        }
        let pa = Snapshot.png(s, dark: false, scale: 1), pb = Snapshot.png(s, dark: false, scale: 1)
        let a = try pixels(pa), b = try pixels(pb)
        XCTAssertEqual(a.count, b.count)
        var off = 0, worst = 0
        // 不一样的地方在哪（整套一起跑时偶发不过，11-16）：记下范围，两张图存到临时目录，好查是哪一块
        let rowBytes = Int(s.size.width) * 4
        var minX = Int.max, maxX = -1, minY = Int.max, maxY = -1
        for i in 0..<min(a.count, b.count) where a[i] != b[i] {
            // 只差 1 级的不算进「不一样的地方」：整套一起跑时，设置页右边一列控件（分段的影子）会有上千个像素差 1 级
            // （11-16 抓到的两次都是这样，最大只差 1），看不出来，也不是画错
            if abs(Int(a[i]) - Int(b[i])) > 1 { off += 1 }
            worst = max(worst, abs(Int(a[i]) - Int(b[i])))
            if abs(Int(a[i]) - Int(b[i])) > 2, rowBytes > 0 {
                let x = (i % rowBytes) / 4, y = i / rowBytes
                minX = min(minX, x); maxX = max(maxX, x); minY = min(minY, y); maxY = max(maxY, y)
            }
        }
        if worst > 2 || off > 64 {
            // 每次另存一份（按时间），前一次的不盖掉：11-16 见过一次差 224 级的，没抓到图
            let dir = FileManager.default.temporaryDirectory.appendingPathComponent("luoke-render-unstable")
                .appendingPathComponent(String(Int(Date().timeIntervalSince1970)))
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try? pa?.write(to: dir.appendingPathComponent("a.png"))
            try? pb?.write(to: dir.appendingPathComponent("b.png"))
            print("两次画的不一样：x \(minX)...\(maxX)，y \(minY)...\(maxY)，图在 \(dir.path)")
        }
        XCTAssertLessThanOrEqual(worst, 2, "两次画出来的差了不止两级")
        XCTAssertLessThanOrEqual(off, 64, "两次画出来的不一样的地方太多")
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
