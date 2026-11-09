// swift-tools-version: 6.0
// 「螺壳.app」的壳（DESIGN §1）：菜单栏、对话窗口、系统通知、画卡片、报告用户在不在；核心是 Python 子进程。
import PackageDescription

let package = Package(
    name: "LuokeAgentApp",
    platforms: [.macOS(.v14)],
    dependencies: [.package(path: "../a2ui")],
    targets: [
        .executableTarget(
            name: "Luoke",
            dependencies: [.product(name: "LuokeA2UI", package: "a2ui"), .product(name: "LuokeA2UICore", package: "a2ui")],
            swiftSettings: [.swiftLanguageMode(.v5)],
            linkerSettings: [.linkedFramework("IOKit"), .linkedFramework("UserNotifications")]),
    ]
)
