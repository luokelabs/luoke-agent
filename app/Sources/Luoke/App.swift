import AppKit
import SwiftUI
import UserNotifications

/// 螺壳的壳：菜单栏、对话窗口、系统通知；核心是子进程（DESIGN §1）。
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate, UNUserNotificationCenterDelegate {
    let config = Config.load()
    let feed = FeedModel()
    let presence = Presence()
    var core: CoreProcess?
    var stream: FeedStream?
    var window: NSWindow?
    var windowClosed = true
    var statusItem: NSStatusItem?
    var presenceTimer: Timer?

    func applicationDidFinishLaunching(_ note: Notification) {
        setUpStatusItem()
        feed.socketPath = config.socket
        feed.problem = config.problem
        feed.onNotify = { [weak self] n in self?.post(n) }
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        center.requestAuthorization(options: [.alert, .sound]) { [weak self] _, _ in
            DispatchQueue.main.async { self?.reportNotifications() }
        }
        if config.problem == nil {
            let core = CoreProcess(config: config)
            core.onState = { [weak self] s in self?.feed.problem = s }
            core.start()
            self.core = core
            let stream = FeedStream(socketPath: config.socket,
                                    onEvent: { [weak self] e, d in self?.feed.handle(e, d); self?.updateBadge() },
                                    onConnected: { [weak self] ok in self?.connected(ok) })
            stream.start()
            self.stream = stream
            presence.onChange = { [weak self] in self?.reportPresence() }
            presenceTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.reportPresence(); self?.reportNotifications() }
            }
        }
        if !config.resident { showWindow() }     // 主控登录时带 --resident 拉起：不开窗口
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showWindow()                             // 再次打开就是打开对话窗口
        return false
    }

    func applicationWillTerminate(_ note: Notification) {
        stream?.stop()
        core?.stop()
        if let hub = config.hub {                // 正常退出：告诉主控别再拉起（V1 §8）
            _ = try? UnixHTTP.request(hub, "POST", "/accessory/exiting", body: Data("{}".utf8),
                                      headers: ["X-Luoke-Accessory": "luoke-agent/\(config.version)"], timeout: 3)
        }
    }

    // MARK: - 菜单栏

    private func setUpStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.image = NSImage(systemSymbolName: "bubble.left", accessibilityDescription: "螺壳")
        item.button?.imagePosition = .imageLeading
        let menu = NSMenu()
        menu.addItem(withTitle: "打开螺壳", action: #selector(openFromMenu), keyEquivalent: "")
        menu.addItem(.separator())
        menu.addItem(withTitle: "退出螺壳", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        item.menu = menu
        statusItem = item
    }

    @objc private func openFromMenu() { showWindow() }

    private func updateBadge() {
        let n = feed.openCount
        statusItem?.button?.title = n > 0 ? " \(n)" : ""
        statusItem?.menu?.items.first?.title = n > 0 ? "打开螺壳（\(n) 件事）" : "打开螺壳"
    }

    // MARK: - 窗口

    func showWindow(focus: String? = nil) {
        if window == nil {
            let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 460, height: 640),
                             styleMask: [.titled, .closable, .resizable, .miniaturizable], backing: .buffered, defer: false)
            w.title = "螺壳"
            w.isReleasedWhenClosed = false
            w.contentView = NSHostingView(rootView: FeedView(feed: feed))
            w.delegate = self
            w.center()
            w.setFrameAutosaveName("LuokeFeed")
            window = w
        }
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
        feed.focus = focus
        windowClosed = false
        reportWindow()
    }

    func windowWillClose(_ notification: Notification) {
        windowClosed = true                      // 关窗时 AppKit 还会发 resignKey，这之后都按关了算
        reportWindow()
    }
    func windowDidBecomeKey(_ notification: Notification) { reportWindow() }
    func windowDidResignKey(_ notification: Notification) { reportWindow() }
    func windowDidMiniaturize(_ notification: Notification) { reportWindow() }
    func windowDidDeminiaturize(_ notification: Notification) { reportWindow() }

    /// 开着：没关（最小化也算开着）。在最前面：用户正看着它（DESIGN §5）。
    private func reportWindow() {
        let w = windowClosed ? nil : window
        let open = w != nil && (w!.isVisible || w!.isMiniaturized)
        let front = open && w!.isKeyWindow && !w!.isMiniaturized && NSApp.isActive
        let path = config.socket
        let body = Data("{\"open\": \(open), \"front\": \(front)}".utf8)
        DispatchQueue.global().async { _ = try? UnixHTTP.request(path, "POST", "/window", body: body, timeout: 5) }
    }

    private func connected(_ ok: Bool) {
        feed.connected = ok
        if ok {
            reportPresence()
            reportWindow()
        }
    }

    private func reportPresence() {
        let path = config.socket
        let body = presence.body
        DispatchQueue.global().async { _ = try? UnixHTTP.request(path, "POST", "/presence", body: body, timeout: 5) }
    }

    /// 系统通知的授权报给核心：被拒、横幅关着时核心在窗口里说一句（不替用户改系统设置）。
    private func reportNotifications() {
        let path = config.socket
        UNUserNotificationCenter.current().getNotificationSettings { settings in
            let status = NotifyNames.auth(settings.authorizationStatus)
            let alerts = settings.alertSetting != .disabled
            let body = try? JSONSerialization.data(withJSONObject: ["status": status, "alerts": alerts])
            DispatchQueue.global().async { _ = try? UnixHTTP.request(path, "POST", "/notifications", body: body ?? Data(), timeout: 5) }
        }
    }

    // MARK: - 通知（只有螺壳发，ADR 0014）

    private func post(_ n: [String: Any]) {
        let content = UNMutableNotificationContent()
        content.title = n["title"] as? String ?? ""
        content.body = n["body"] as? String ?? ""
        let urgent = n["urgent"] as? Bool ?? false
        if !(n["silent"] as? Bool ?? false) { content.sound = .default }
        content.interruptionLevel = urgent ? .timeSensitive : .active
        if let sid = n["surfaceId"] as? String { content.userInfo = ["surfaceId": sid] }
        let id = n["id"] as? String ?? UUID().uuidString     // 同一编号（简报）换掉上一条
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: id, content: content, trigger: nil)) { error in
            if let error = error as NSError? {         // 只记编号，不记内容
                FileHandle.standardError.write(Data("螺壳：系统通知没发出去（\(error.domain) \(error.code)）\n".utf8))
            }
        }
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                                            withCompletionHandler done: @escaping () -> Void) {
        let sid = response.notification.request.content.userInfo["surfaceId"] as? String
        DispatchQueue.main.async { self.showWindow(focus: sid) }
        done()
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                            withCompletionHandler done: @escaping (UNNotificationPresentationOptions) -> Void) {
        done([.banner, .sound])
    }
}
