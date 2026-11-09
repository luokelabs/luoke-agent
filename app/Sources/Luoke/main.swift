import AppKit
import UserNotifications

// `--notify-status`：只打印一行 JSON {"authorization", "alert"}，不发通知、不请求授权，不起核心
// （和 luoke-core 启动器的同名参数一样，主控的完成页拿它列出通知状态；V1 §8）。
if CommandLine.arguments.dropFirst().first == "--notify-status" {
    let done = DispatchSemaphore(value: 0)
    var line = ""
    UNUserNotificationCenter.current().getNotificationSettings { st in
        line = "{\"authorization\": \"\(NotifyNames.auth(st.authorizationStatus))\", \"alert\": \"\(NotifyNames.setting(st.alertSetting))\"}"
        done.signal()
    }
    if done.wait(timeout: .now() + 10) == .timedOut { exit(5) }
    print(line)
    exit(0)
}

// `--notify <标题> <副标题> <正文> [--open <参数>]`：以螺壳的名义发一条通知（主控完成页的「允许它发通知」用，
// 系统还没问过用户时会先弹出询问）。退出码和 luoke-core 启动器一样：0 交给系统了；3 没允许；4 系统拒收；
// 5 10 秒内没答复；64 用法不对。不起核心、不开窗口。点了这条通知，正在运行的螺壳打开对话窗口。
if CommandLine.arguments.dropFirst().first == "--notify" {
    func err(_ s: String) { FileHandle.standardError.write(Data((s + "\n").utf8)) }
    let args = Array(CommandLine.arguments.dropFirst(2))
    guard args.count >= 3 else { err("用法：--notify <标题> <副标题> <正文> [--open <参数>]"); exit(64) }
    var openArg = ""
    if let i = args.firstIndex(of: "--open"), i + 1 < args.count { openArg = args[i + 1] }
    let center = UNUserNotificationCenter.current()
    let done = DispatchSemaphore(value: 0)
    var code: Int32 = 0
    center.requestAuthorization(options: [.alert, .sound]) { granted, _ in
        guard granted else {
            center.getNotificationSettings { st in
                err("通知：没允许（authorization \(NotifyNames.auth(st.authorizationStatus))，alert \(NotifyNames.setting(st.alertSetting))）")
                code = 3
                done.signal()
            }
            return
        }
        let content = UNMutableNotificationContent()
        content.title = args[0]
        content.subtitle = args[1]
        content.body = args[2]
        content.userInfo = ["open": openArg]
        center.add(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)) { e in
            if let e = e as NSError? { err("通知：系统没收下（\(e.domain) \(e.code)）"); code = 4 }
            done.signal()
        }
    }
    if done.wait(timeout: .now() + 10) == .timedOut { err("通知：10 秒内系统没答复"); exit(5) }
    exit(code)
}

let app = NSApplication.shared
let delegate = MainActor.assumeIsolated { AppDelegate() }
app.delegate = delegate
app.setActivationPolicy(.accessory)   // 只在菜单栏；Info.plist 里也是 LSUIElement
app.run()
