import AppKit
import XCTest
@testable import LuokeWindow

/// 资源包自己找：螺壳.app 把它放在 Contents/Resources，老一点的 Swift 生成的 `Bundle.module`
/// 不找那里，没有编译目录的 Mac 上一打开主窗口就崩。
final class ResourceBundleTests: XCTestCase {
    private var tmp: URL!

    override func setUpWithError() throws {
        tmp = FileManager.default.temporaryDirectory.appendingPathComponent("luoke-window-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tmp)
    }

    func testFindsItWhileTesting() throws {
        let b = try XCTUnwrap(ResourceBundle.bundle, "测试时在 .xctest 旁边找得到")
        XCTAssertNotNil(b.url(forResource: "core", withExtension: "png", subdirectory: "Resources"))
        XCTAssertNotNil(b.url(forResource: "conch", withExtension: "path", subdirectory: "Resources"))
        XCTAssertFalse(ToolSample.scenarios("luoke-scan").isEmpty, "扫描的场景样例也从这里读")
    }

    /// 照螺壳.app 的样子摆：资源包只在 Contents/Resources，.app 根目录和编译目录都没有
    func testFindsItInContentsResourcesOfTheApp() throws {
        let real = try XCTUnwrap(ResourceBundle.bundle).bundleURL
        let app = tmp.appendingPathComponent("螺壳.app", isDirectory: true)
        let res = app.appendingPathComponent("Contents/Resources", isDirectory: true)
        try FileManager.default.createDirectory(at: res, withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: real, to: res.appendingPathComponent(ResourceBundle.name))

        let b = try XCTUnwrap(ResourceBundle.find(in: [res, app]))
        let icon = try XCTUnwrap(b.url(forResource: "mail", withExtension: "png", subdirectory: "Resources"))
        XCTAssertTrue(icon.resolvingSymlinksInPath().path.hasPrefix(app.resolvingSymlinksInPath().path), icon.path)
        XCTAssertNotNil(NSImage(contentsOf: icon))
    }

    func testMissingEverywhereIsNilNotACrash() {
        let app = tmp.appendingPathComponent("空的.app", isDirectory: true)
        XCTAssertNil(ResourceBundle.find(in: [app.appendingPathComponent("Contents/Resources"), app, tmp]))
    }

    /// `Bundle.module` 找不到资源包就 fatalError，窗口的代码里不用它
    func testWindowSourcesDoNotUseBundleModule() throws {
        let sources = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("../../Sources/LuokeWindow").standardizedFileURL
        let files = try FileManager.default.contentsOfDirectory(at: sources, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "swift" }
        XCTAssertFalse(files.isEmpty, sources.path)
        for f in files where f.lastPathComponent != "ResourceBundle.swift" {
            let text = try String(contentsOf: f, encoding: .utf8)
            XCTAssertFalse(text.contains("Bundle" + ".module"), "\(f.lastPathComponent) 用了 Bundle.module，换成 ResourceBundle.bundle")
        }
    }
}
