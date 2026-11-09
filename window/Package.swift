// swift-tools-version: 6.0
// LuokeWindow：螺壳的主窗口（docs/主窗口.md）。SwiftUI 画，卡片和基础页用 LuokeA2UI。
// 自成一个包：螺壳.app 引它；luoke-window-demo 用示例数据开一个窗口；luoke-window-shots 把每个界面截成图。
import PackageDescription

let v5: [SwiftSetting] = [.swiftLanguageMode(.v5)]

let package = Package(
    name: "LuokeWindow",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "LuokeWindow", targets: ["LuokeWindow"]),
        .executable(name: "luoke-window-demo", targets: ["LuokeWindowDemo"]),
        .executable(name: "luoke-window-shots", targets: ["LuokeWindowShots"]),
    ],
    dependencies: [.package(path: "../a2ui")],
    targets: [
        .target(name: "LuokeWindow",
                dependencies: [.product(name: "LuokeA2UI", package: "a2ui"), .product(name: "LuokeA2UICore", package: "a2ui")],
                resources: [.copy("Resources")], swiftSettings: v5),
        .executableTarget(name: "LuokeWindowDemo", dependencies: ["LuokeWindow"], swiftSettings: v5),
        .executableTarget(name: "LuokeWindowShots", dependencies: ["LuokeWindow"], swiftSettings: v5),
        .testTarget(name: "LuokeWindowTests", dependencies: ["LuokeWindow", .product(name: "LuokeA2UICore", package: "a2ui")],
                    swiftSettings: v5),
    ]
)
