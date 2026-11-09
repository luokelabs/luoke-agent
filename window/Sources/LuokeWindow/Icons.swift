import AppKit
import SwiftUI

/// 装好的应用和螺壳自己。图标是 Resources 里各应用的图，128 px（图标、吉祥物取自 luoke-brand media-kit e297db2）。
public enum ToolIcon: String, CaseIterable, Sendable {
    case mail, scan, mem, search, ime, core

    public var name: String {
        switch self {
        case .mail: return "邮件助手"
        case .scan: return "螺壳扫描"
        case .mem: return "记忆"
        case .search: return "螺壳搜索"
        case .ime: return "输入法"
        case .core: return "螺壳"
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
            if let image = Resources.image(tool.imageName) {
                Image(nsImage: image).resizable().interpolation(.high)
            } else {
                RoundedRectangle(cornerRadius: size * 0.22, style: .continuous).fill(p.muted)
            }
        }
        .frame(width: size, height: size)
        .accessibilityLabel(tool.name)
    }
}

/// 螺壳的标志：粉底方块，加约 22% 的连续圆角。
struct BrandBadge: View {
    var size: CGFloat = 32

    var body: some View {
        Group {
            if let image = Resources.image("badge") {
                Image(nsImage: image).resizable().interpolation(.high)
            } else {
                Color.hex(0xE8556B)
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: size * 0.22, style: .continuous))
        .accessibilityHidden(true)
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

/// 吉祥物（探出头的海螺）：「今天」没有要你决定的、一件件处理都答完了
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
