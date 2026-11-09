import AppKit
import Foundation

/// 去哪儿找核心、记忆、主控和工具。正式版（ai.luoke.agent）用固定的位置；开发版（.dev）必须全部显式给，
/// 不退回日常在用的位置（顶层 CLAUDE.md「不碰日常在用的实例」）。
struct Config {
    static let releaseBundleId = "ai.luoke.agent"
    static let hubBundleId = "ai.luoke.core"

    var resident = false
    var home: String
    var memory: String
    var hub: String?
    var tools: [String] = []          // 配件=socket（开发、测试用）
    var python: String?
    var pythonFromHub = false         // 借的是主控的 Python：每次起核心都按 bundle id 重新找（主控换版本、改名会挪位置）
    var coreDir: String
    var memoryApp: Bool
    /// 核心带 --dev 起：agent.sock 也认命令行的 feed、tap 和 luoke-window-demo，认 --tool。只有开发版（不是本机试用的那份）给，
    /// 只看 bundle id 和 app 里有没有 trial.json，不看命令行和环境变量
    var dev = false
    var problem: String?              // 找不到要的东西：窗口里照实说

    var socket: String { (home as NSString).appendingPathComponent("run/agent.sock") }
    var version: String { Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0" }

    static func load(arguments: [String] = CommandLine.arguments) -> Config {
        var given: [String: String] = [:]
        var tools: [String] = []
        var resident = false
        var i = 1
        while i < arguments.count {
            let a = arguments[i]
            if a == "--resident" { resident = true }
            else if a.hasPrefix("--"), i + 1 < arguments.count, !arguments[i + 1].hasPrefix("--") {
                if a == "--tool" { tools.append(arguments[i + 1]) } else { given[String(a.dropFirst(2))] = arguments[i + 1] }
                i += 1
            }
            i += 1
        }
        let release = Bundle.main.bundleIdentifier == releaseBundleId
        let homeDir = NSHomeDirectory()
        let trialURL = release ? nil : Bundle.main.url(forResource: "trial", withExtension: "json")
        // 本机试用的开发版：位置写在 app 里的 trial.json，命令行给的优先
        if let url = trialURL, let data = try? Data(contentsOf: url),
           let trial = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] {
            for key in ["home", "memory", "python", "hub", "core"] where given[key] == nil {
                guard let v = trial[key] as? String else { continue }
                if key == "python" && v == "hub" { given["python-from-hub"] = "1" }
                given[key] = key == "python" && v == "hub" ? hubPython() : (v as NSString).expandingTildeInPath
            }
            if trial["memoryApp"] as? Bool == true { given["memory-app"] = "1" }
        }
        let bundledCore = Bundle.main.resourceURL?.appendingPathComponent("core").path ?? ""
        var c = Config(resident: resident,
                       home: given["home"] ?? (release ? "\(homeDir)/.luoke/agent" : ""),
                       memory: given["memory"] ?? (release ? "\(homeDir)/.luoke/mem.db" : ""),
                       hub: given["hub"] ?? (release ? "\(homeDir)/Library/Application Support/luoke-core/run/hub.sock" : nil),
                       tools: tools,
                       python: given["python"] ?? (release ? hubPython() : nil),
                       coreDir: given["core"] ?? bundledCore,
                       memoryApp: release || given["memory-app"] != nil)
        c.pythonFromHub = given["python-from-hub"] != nil || (release && given["python"] == nil)
        c.dev = !release && trialURL == nil
        if !c.dev && !tools.isEmpty {
            c.problem = "--tool 只在开发版里用。"
        } else if c.home.isEmpty || c.memory.isEmpty {
            c.problem = "开发版要显式给 --home 和 --memory（不用日常在用的位置）。"
        } else if c.python == nil {
            c.problem = release ? "找不到螺壳：螺壳 agent 要借它的 Python 运行。" : "开发版要显式给 --python。"
        } else if !FileManager.default.fileExists(atPath: (c.coreDir as NSString).appendingPathComponent("luoke_agent/__main__.py")) {
            c.problem = "找不到螺壳的核心：\(c.coreDir)"
        }
        return c
    }

    /// 借主控的 Python（luoke-core V1 §8）：按 bundle id 找到主控。
    static func hubPython() -> String? {
        guard let app = NSWorkspace.shared.urlForApplication(withBundleIdentifier: hubBundleId) else { return nil }
        let p = app.appendingPathComponent("Contents/Resources/python/bin/python3").path
        return FileManager.default.isExecutableFile(atPath: p) ? p : nil
    }
}
