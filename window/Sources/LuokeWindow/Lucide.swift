import AppKit
import LuokeA2UI
import SwiftUI

/// Lucide 的图标（lucide-static 1.64.0，ISC，见 Resources/lucide/LICENSE）。卡片和窗口里的图标都用它：SVG 原样放在资源包里，
/// 系统按矢量画，当模板图跟着字色。资源包没带上就是 nil，卡片退回最接近的系统符号。
enum Lucide {
    private static var cache: [String: NSImage] = [:]
    private static let lock = NSLock()

    static func nsImage(_ name: String) -> NSImage? {
        lock.lock()
        defer { lock.unlock() }
        if let hit = cache[name] { return hit }
        guard name.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "-" }),
              let url = ResourceBundle.bundle?.url(forResource: name, withExtension: "svg", subdirectory: "Resources/lucide"),
              let img = NSImage(contentsOf: url) else { return nil }
        img.isTemplate = true
        cache[name] = img
        return img
    }

    static func image(_ name: String) -> Image? { nsImage(name).map { Image(nsImage: $0) } }
}

/// 窗口里的一个图标：Lucide 的名字，默认 16 pt（DESIGN.md 第 5 节），跟着字色
struct LKIcon: View {
    let name: String
    var size: CGFloat = 16

    init(_ name: String, size: CGFloat = 16) {
        self.name = name
        self.size = size
    }

    var body: some View {
        if let img = Lucide.image(name) {
            img.resizable().renderingMode(.template).aspectRatio(contentMode: .fit).frame(width: size, height: size)
        } else {
            Image(systemName: SurfaceView.symbol(name)).font(.system(size: size * 0.85)).frame(width: size, height: size)
        }
    }
}
