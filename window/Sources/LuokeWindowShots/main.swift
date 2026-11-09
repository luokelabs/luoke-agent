// 把每个界面截成图：luoke-window-shots <输出目录>
// 输出 <名字>-light.png、<名字>-dark.png 和 index.json（名字、标题、文件、sha256），给 scripts/ci/post_shots.py 用。
import CryptoKit
import Foundation
import LuokeWindow

@MainActor
func main() -> Int32 {
    let args = CommandLine.arguments
    guard args.count == 2 else {
        FileHandle.standardError.write(Data("用法：luoke-window-shots <输出目录>\n".utf8))
        return 2
    }
    let out = URL(fileURLWithPath: args[1], isDirectory: true)
    try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
    var index: [[String: String]] = []
    var failed = 0
    for screen in Snapshot.screens() {
        for dark in [false, true] {
            let file = "\(screen.name)-\(dark ? "dark" : "light").png"
            guard let png = Snapshot.png(screen, dark: dark) else {
                FileHandle.standardError.write(Data("画不出 \(file)\n".utf8))
                failed += 1
                continue
            }
            do {
                try png.write(to: out.appendingPathComponent(file))
            } catch {
                FileHandle.standardError.write(Data("写不进 \(file)：\(error)\n".utf8))
                failed += 1
                continue
            }
            let hash = SHA256.hash(data: png).map { String(format: "%02x", $0) }.joined()
            index.append(["name": screen.name, "title": screen.title, "theme": dark ? "dark" : "light", "file": file, "sha256": hash])
            print(file)
        }
    }
    if let data = try? JSONSerialization.data(withJSONObject: index, options: [.prettyPrinted, .sortedKeys]) {
        try? data.write(to: out.appendingPathComponent("index.json"))
    }
    return failed == 0 ? 0 : 1
}

exit(MainActor.assumeIsolated { main() })
