// 开一个主窗口：swift run --package-path window luoke-window-demo [--agent <数据目录>/run/agent.sock]
// 不带 --agent 全用示例数据；带了就连那个 agent 核心：「今天」、菜单栏图标的急事、应用的页、「设置 · 提醒」「设置 · 权限」
// 用核心的，别的页照旧是示例。
// 演示不发系统通知（不弹授权框），核心要发的通知打到标准错误。
import AppKit
import LuokeWindow
import SwiftUI

let agentSocket: String? = {
    let a = CommandLine.arguments
    guard let i = a.firstIndex(of: "--agent"), i + 1 < a.count else { return nil }
    return a[i + 1]
}()

let demoModel: WindowModel = MainActor.assumeIsolated { Sample.model(defaults: UserDefaults(suiteName: "ai.luoke.window.demo")) }
let connection: AgentConnection? = MainActor.assumeIsolated { () -> AgentConnection? in
    guard let path = agentSocket else { return nil }
    let c = AgentConnection(socketPath: path, model: demoModel)
    c.feed.onNotify = { n in FileHandle.standardError.write(Data("通知：\(n.title)｜\(n.body)\n".utf8)) }
    c.start()
    c.reportWindow(open: true, front: true)
    for (name, front) in [(NSApplication.didBecomeActiveNotification, true), (NSApplication.didResignActiveNotification, false)] {
        NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { c.reportWindow(open: true, front: front) }
        }
    }
    return c
}

struct DemoApp: App {
    @ObservedObject private var model = demoModel
    @Environment(\.openWindow) private var openWindow

    var body: some Scene {
        Window("螺壳", id: "main") {
            MainWindowView(model: model)
                .frame(minWidth: 860, minHeight: 600)
        }
        .defaultSize(width: 1004, height: 760)
        .windowStyle(.hiddenTitleBar)
        .commands { LuokeCommands(model: model) { openWindow(id: "main") } }

        MenuBarExtra {
            StatusMenuContent(model: model) { openWindow(id: "main") }
        } label: {
            Image(systemName: model.hasUrgent ? "bubble.left.and.exclamationmark.bubble.right" : "bubble.left")
        }
        .menuBarExtraStyle(.menu)
    }
}

NSApplication.shared.setActivationPolicy(.regular)
DemoApp.main()
