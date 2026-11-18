import AppKit
import SwiftUI
import XCTest
@testable import LuokeWindow

/// 真窗口的左上角。螺壳.app 的主窗口是透明标题栏、内容铺满（fullSizeContentView）；截图测试里没有标题栏，看不出按钮的位置。
/// 这里照那样离屏建一个窗口（不显示），把内容画成图，找内容区左上角收起侧栏的按钮，和系统红黄绿的位置比。
@MainActor
final class TitlebarTests: XCTestCase {
    func testSidebarToggleLinesUpWithTheTrafficLights() throws {
        _ = NSApplication.shared
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1004, height: 760),
                         styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                         backing: .buffered, defer: false)
        MainWindowChrome.apply(to: w)       // 螺壳.app 也这样调：红黄绿到最上面一行（52）的正中
        w.isReleasedWhenClosed = false
        defer { w.close() }
        let host = NSHostingView(rootView: MainWindowView(model: Sample.model(defaults: nil)))
        w.contentView = host
        host.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))      // 红黄绿是排完标题栏以后才挪回去的
        XCTAssertGreaterThan(host.safeAreaInsets.top, 0, "这样的窗口顶上有标题栏的安全区")

        // 红黄绿：上沿量起的中心高度、最右边（host 的坐标，换成从上往下量）
        let close = try XCTUnwrap(w.standardWindowButton(.closeButton))
        let zoom = try XCTUnwrap(w.standardWindowButton(.zoomButton))
        let lights = close.convert(close.bounds, to: host).union(zoom.convert(zoom.bounds, to: host))
        let lightsMid = host.isFlipped ? lights.midY : host.bounds.height - lights.midY

        XCTAssertEqual(lightsMid, WindowControls.lightsCenterY, accuracy: 1.5, "红黄绿在最上面一行的正中")

        // 收起侧栏的按钮：标题栏里、红黄绿右边 50 pt 内，和标题栏底色差得多的像素（标题栏下沿那条线不算）
        let rep = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: rep)
        let scale = CGFloat(rep.pixelsWide) / host.bounds.width
        let contentLeft = WindowControls.toggleMinX - 2
        // 标题栏的底色：取一块空着的地方（按钮和胶囊之间）
        let bg = try XCTUnwrap(rep.colorAt(x: Int((WindowControls.sidebarWidth + 60) * scale), y: Int(4 * scale))?.usingColorSpace(.sRGB))
        var xs: [CGFloat] = [], ys: [CGFloat] = []
        for py in 0..<Int((WindowControls.height - 2) * scale) {
            for px in Int(contentLeft * scale)..<Int((contentLeft + 50) * scale) {
                guard let c = rep.colorAt(x: px, y: py)?.usingColorSpace(.sRGB) else { continue }
                let d = abs(c.redComponent - bg.redComponent) + abs(c.greenComponent - bg.greenComponent) + abs(c.blueComponent - bg.blueComponent)
                if d > 0.25 { xs.append(CGFloat(px) / scale); ys.append(CGFloat(py) / scale) }
            }
        }
        XCTAssertFalse(ys.isEmpty, "最上面一行里找不到收起侧栏的按钮（掉到下面去了？）")
        guard let top = ys.min(), let bottom = ys.max(), let left = xs.min() else { return }
        XCTAssertEqual((top + bottom) / 2, lightsMid, accuracy: 2, "和红黄绿在一条线上（按钮 \(top)–\(bottom) pt，红黄绿中心 \(lightsMid) pt）")
        XCTAssertGreaterThan(left, WindowControls.lightsLeading + WindowControls.lightsWidth, "在红黄绿右边，不和它们挤在一起")
        XCTAssertEqual(lights.minX, WindowControls.lightsLeading, accuracy: 1, "截图里自己画的红黄绿和真的在同一个位置")
        XCTAssertEqual(lights.width, WindowControls.lightsWidth, accuracy: 1)
    }
}
