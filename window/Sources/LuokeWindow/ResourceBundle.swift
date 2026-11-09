import Foundation

/// 主窗口的资源包（图标、海螺、工具的场景样例），自己找，不用 SwiftPM 生成的 `Bundle.module`。
/// 老一点的 Swift（6.3）生成的 `Bundle.module` 只找 .app 根目录和编译时的绝对路径；螺壳.app 把资源包放在
/// Contents/Resources（根目录放东西签名过不了），到了没有编译目录的 Mac 上两处都找不到，`Bundle.module` 直接 fatalError，
/// 一打开主窗口螺壳就崩。这里按顺序找，都找不到就是 nil：图标画占位、没有样例，窗口照常开。
enum ResourceBundle {
    static let name = "LuokeWindow_LuokeWindow.bundle"

    static let bundle: Bundle? = find(in: places())

    /// 依次：螺壳.app 的 Contents/Resources；.app 根目录，或命令行程序旁边（`swift run` 的 .build/<配置>/）；
    /// 跑测试时这个模块所在的 .xctest 旁边
    static func places() -> [URL] {
        let mine = Bundle(for: Marker.self)
        return [Bundle.main.resourceURL, Bundle.main.bundleURL, mine.resourceURL, mine.bundleURL.deletingLastPathComponent()]
            .compactMap { $0 }
    }

    static func find(in places: [URL]) -> Bundle? {
        for dir in places {
            if let b = Bundle(url: dir.appendingPathComponent(name, isDirectory: true)) { return b }
        }
        return nil
    }

    private final class Marker {}
}
