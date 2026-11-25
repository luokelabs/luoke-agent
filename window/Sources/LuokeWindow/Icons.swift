import AppKit
import SwiftUI

/// 装好的应用和螺壳自己。图标是 Resources 里各应用的图，128 px（图标、吉祥物取自螺壳的品牌素材）。
public enum ToolIcon: String, CaseIterable, Sendable {
    case mail, scan, mem, search, ime, core

    public var name: String {
        switch self {
        case .mail: return "螺壳邮件助手"   // 和应用自己的名字、核心说的一样（录屏里侧栏写「邮件助手」，搜索写「螺壳邮件助手」）
        case .scan: return "螺壳扫描"
        case .mem: return "记忆"
        case .search: return "螺壳搜索"
        case .ime: return "螺壳输入法"
        case .core: return "螺壳"
        }
    }

    /// 深色下的点缀色：取自各应用图标的底色、和官网深色里同一应用用的亮色（luoke-brand 11-23）。
    /// 只用在卡片左上角的淡光、细边这类不放字的地方
    var accent: Color {
        switch self {
        case .mail: return .hex(0x8EC3EE)     // 蓝
        case .scan: return .hex(0xB9A8EE)     // 紫
        case .mem: return .hex(0xFFA77A)      // 橘
        case .search: return .hex(0xF0CF7A)   // 黄
        case .ime: return .hex(0x8FD3A2)      // 绿
        case .core: return .hex(0xFF9AA8)     // 珊瑚粉
        }
    }

    /// Resources 里的图（`<名字>.png`）
    var imageName: String {
        switch self {
        case .mem: return "memory"
        default: return rawValue
        }
    }
}

enum Resources {
    @MainActor private static var images: [String: NSImage] = [:]

    @MainActor static func image(_ name: String) -> NSImage? {
        if let i = images[name] { return i }
        guard let url = ResourceBundle.bundle?.url(forResource: name, withExtension: "png", subdirectory: "Resources"),
              let i = NSImage(contentsOf: url) else { return nil }
        images[name] = i
        return i
    }
}

/// 应用图标。图自带透明的边和圆角（照 macOS 应用图标的格子），不另外裁。
struct AppIcon: View {
    let tool: ToolIcon
    var size: CGFloat = 18
    @Environment(\.lk) private var p

    var body: some View {
        Group {
            if tool == .mem && size >= 24 {
                // 记忆不算应用（负责人 11-14）：画线条的大脑，不画应用那种彩色方块（UX-10）。大的（应用管理一行 34）垫一块浅灰圆角底，
                // 和旁边应用的方块一样有分量，不是一根细线飘着
                RoundedRectangle(cornerRadius: size * 0.22, style: .continuous).fill(p.muted)
                    .overlay { LKIcon("brain", size: size * 0.6).foregroundStyle(p.fg) }
            } else if tool == .mem {
                // 小的（右边栏任务、历史、权限按应用展开）和侧栏一样只画线条
                LKIcon("brain", size: size * 0.8).foregroundStyle(p.fg)
            } else if let image = Resources.image(tool.imageName) {
                Image(nsImage: image).resizable().interpolation(.high)
            } else {
                RoundedRectangle(cornerRadius: size * 0.22, style: .continuous).fill(p.muted)
            }
        }
        .frame(width: size, height: size)
        .accessibilityLabel(tool.name)
    }
}

/// 螺壳的标志：螺壳.app 的图标（beta 2）。badge.png 是那张图标去掉四周透明边、只留超椭圆的方块
/// （1024 画布里的 824），缩到 128 px：方块撑满 `size`，按图自己的形状画，不另裁圆角。没图时退回粉色的圆角方块
struct BrandBadge: View {
    var size: CGFloat = 32

    var body: some View {
        Group {
            if let image = Resources.image("badge") {
                Image(nsImage: image).resizable().interpolation(.high)
            } else {
                RoundedRectangle(cornerRadius: size * 0.22, style: .continuous).fill(Color.hex(0xE8556B))
            }
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}

/// 带字的主 logo：品牌 media-kit 的横排组合（海螺加字标 luoke），浅色、深色各一版，用现成的图，不自己拼。
/// `height` 是海螺的高（也就是整张图的高）
public struct BrandLockup: View {
    var height: CGFloat
    @Environment(\.lk) private var p

    public init(height: CGFloat = 20) { self.height = height }

    public var body: some View {
        if let image = Resources.image(p.dark ? "lockup-dark" : "lockup-light") {
            Image(nsImage: image).resizable().interpolation(.high)
                .aspectRatio(image.size.width / max(image.size.height, 1), contentMode: .fit)
                .frame(height: height)
                .accessibilityLabel("螺壳")
        }
    }
}

/// 螺壳的海螺（原型 conch 符号的路径，viewBox 171 141 916 916；只有 M、C、Z）
struct Conch: Shape {
    nonisolated(unsafe) static let base: Path = {
        guard let url = ResourceBundle.bundle?.url(forResource: "conch", withExtension: "path", subdirectory: "Resources"),
              let d = try? String(contentsOf: url, encoding: .utf8) else { return Path() }
        return parse(d)
    }()

    func path(in rect: CGRect) -> Path {
        let s = min(rect.width, rect.height) / 916
        return Conch.base.applying(CGAffineTransform(translationX: -171, y: -141)
            .concatenating(CGAffineTransform(scaleX: s, y: s))
            .concatenating(CGAffineTransform(translationX: rect.minX, y: rect.minY)))
    }

    static func parse(_ d: String) -> Path {
        var path = Path()
        var nums: [CGFloat] = []
        var cmd: Character = " "
        var token = ""
        func flushNumber() {
            if !token.isEmpty, let v = Double(token) { nums.append(CGFloat(v)) }
            token = ""
        }
        func run() {
            switch cmd {
            case "M":
                var i = 0
                while i + 1 < nums.count {
                    let pt = CGPoint(x: nums[i], y: nums[i + 1])
                    if i == 0 { path.move(to: pt) } else { path.addLine(to: pt) }
                    i += 2
                }
            case "C":
                var i = 0
                while i + 5 < nums.count {
                    path.addCurve(to: CGPoint(x: nums[i + 4], y: nums[i + 5]),
                                  control1: CGPoint(x: nums[i], y: nums[i + 1]),
                                  control2: CGPoint(x: nums[i + 2], y: nums[i + 3]))
                    i += 6
                }
            case "L":
                var i = 0
                while i + 1 < nums.count { path.addLine(to: CGPoint(x: nums[i], y: nums[i + 1])); i += 2 }
            case "Z":
                path.closeSubpath()
            default:
                break
            }
            nums = []
        }
        for ch in d {
            if ch.isLetter {
                flushNumber()
                run()
                cmd = ch
            } else if ch == " " || ch == "," || ch == "\n" {
                flushNumber()
            } else if ch == "-" && !token.isEmpty {
                flushNumber()
                token = "-"
            } else {
                token.append(ch)
            }
        }
        flushNumber()
        run()
        return path
    }
}

struct ConchMark: View {
    var size: CGFloat = 22

    var body: some View {
        Conch().fill(style: FillStyle(eoFill: true)).frame(width: size, height: size).accessibilityHidden(true)
    }
}

/// 吉祥物（探出头的海螺）：「今天」没有要你决定的、逐件处理都答完了
struct Mascot: View {
    var width: CGFloat = 56

    var body: some View {
        Group {
            if let image = Resources.image("conch-peek") {
                Image(nsImage: image).resizable().interpolation(.high).aspectRatio(contentMode: .fit)
            } else {
                ConchMark(size: width)
            }
        }
        .frame(width: width)
        .accessibilityHidden(true)
    }
}
