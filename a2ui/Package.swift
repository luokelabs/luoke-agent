// swift-tools-version: 6.0
// LuokeA2UI：A2UI v0.9.1 的解析、校验和 SwiftUI 画法（luoke-agent DESIGN §4）。
// 自成一个包：输入法照拷 luoke_mem 的办法，把打了标签的那一版拷进自己的仓库。
import PackageDescription

let package = Package(
    name: "LuokeA2UI",
    platforms: [.macOS(.v14), .iOS(.v17)],
    products: [
        .library(name: "LuokeA2UICore", targets: ["LuokeA2UICore"]),
        .library(name: "LuokeA2UI", targets: ["LuokeA2UI"]),
    ],
    targets: [
        // 只依赖 Foundation：命令行（例如输入法的 check）也能用。
        .target(name: "LuokeA2UICore", swiftSettings: [.swiftLanguageMode(.v5)]),
        .target(name: "LuokeA2UI", dependencies: ["LuokeA2UICore"], swiftSettings: [.swiftLanguageMode(.v5)]),
        .testTarget(name: "LuokeA2UICoreTests", dependencies: ["LuokeA2UICore"], resources: [.copy("Fixtures")],
                    swiftSettings: [.swiftLanguageMode(.v5)]),
        // 画法：在 Mac 上真的量一遍、摆一遍（NSHostingView）
        .testTarget(name: "LuokeA2UITests", dependencies: ["LuokeA2UI", "LuokeA2UICore"], swiftSettings: [.swiftLanguageMode(.v5)]),
    ]
)
