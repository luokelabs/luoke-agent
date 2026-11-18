import AppKit
import Foundation
import IOKit
import UserNotifications

// 螺壳.app 接核心要的几样（docs/界面接口.md §11、§14）：系统通知、用户在不在、通知授权。
// 照 luoke-agent 原来的壳（app/Sources/Luoke）搬过来，本体直接用，不用再拷。

/// 主窗口的标题栏：最上面一条（`WindowControls.height`），红黄绿在它的正中。
/// 不用工具栏撑高标题栏：工具栏那一层盖在上面，标题栏里收起侧栏的按钮、右上角的胶囊都点不动（负责人 11-14）。
/// 标题栏透明、内容铺满，红黄绿自己挪到正中；窗口变大小、退出全屏后系统会把它们放回去，再挪一次。
/// 螺壳.app 建好主窗口以后调一次；`luoke-window-demo` 和 `TitlebarTests` 也用它
public enum MainWindowChrome {
    @MainActor public static func apply(to window: NSWindow) {
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.styleMask.insert(.fullSizeContentView)
        window.toolbar = nil
        placeLights(window)
        let names = [NSWindow.didResizeNotification, NSWindow.didEndLiveResizeNotification,
                     NSWindow.didExitFullScreenNotification, NSWindow.didBecomeKeyNotification, NSWindow.didResignKeyNotification]
        for n in names {
            NotificationCenter.default.addObserver(forName: n, object: window, queue: .main) { [weak window] _ in
                MainActor.assumeIsolated { if let window { placeLights(window) } }
            }
        }
        // 系统排标题栏时（换内容、变大小）会把它们放回原处：它们一挪就再放回来
        for k in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
            guard let b = window.standardWindowButton(k) else { continue }
            b.postsFrameChangedNotifications = true
            NotificationCenter.default.addObserver(forName: NSView.frameDidChangeNotification, object: b, queue: nil) { [weak window] _ in
                MainActor.assumeIsolated { if let window { placeLights(window) } }
                // 系统一次排三个，排到后面的会把刚挪好的又放回去：这一轮排完再放一次
                DispatchQueue.main.async { MainActor.assumeIsolated { if let window { placeLights(window) } } }
            }
        }
    }

    /// 红黄绿：中心离上沿 `lightsCenterY`，从 `lightsLeading` 起，一个 14 宽、隔 9
    @MainActor static func placeLights(_ w: NSWindow) {
        let kinds: [NSWindow.ButtonType] = [.closeButton, .miniaturizeButton, .zoomButton]
        for (i, k) in kinds.enumerated() {
            guard let b = w.standardWindowButton(k), let sup = b.superview else { continue }
            let h = b.frame.height
            let y = sup.isFlipped ? WindowControls.lightsCenterY - h / 2 : sup.bounds.height - WindowControls.lightsCenterY - h / 2
            let to = NSPoint(x: WindowControls.lightsLeading + CGFloat(i) * 23, y: y)
            if b.frame.origin != to { b.setFrameOrigin(to) }     // 已经在了不再挪：挪了又发通知，别来回
        }
    }
}

public extension AgentNotification {
    /// 点通知时认得出是核心发的：`userInfo` 里有这个键（值是通知编号）
    static let userInfoKey = "luoke-agent"

    /// 系统通知的内容。以「螺壳」的名义发（发送方就是螺壳.app）；只带标题和一句话，不带卡片内容。
    /// timeSensitive：`urgent` 的用时效性通知，要 entitlement；beta 2 不加（luoke-core#68），一律普通通知。
    func content(timeSensitive: Bool = false) -> UNMutableNotificationContent {
        let c = UNMutableNotificationContent()
        c.title = title
        c.body = body
        if !silent { c.sound = .default }
        c.interruptionLevel = urgent && timeSensitive ? .timeSensitive : .active
        var info: [String: Any] = [Self.userInfoKey: id]
        if let surfaceId { info["surfaceId"] = surfaceId }
        c.userInfo = info
        return c
    }

    /// 发出去：编号相同的（简报）换掉上一条。出错只记编号，不记内容
    func post(timeSensitive: Bool = false) {
        let req = UNNotificationRequest(identifier: id, content: content(timeSensitive: timeSensitive), trigger: nil)
        let id = self.id
        UNUserNotificationCenter.current().add(req) { error in
            if let error = error as NSError? {
                NSLog("螺壳：系统通知没发出去（%@ %d，%@）", error.domain, error.code, id)
            }
        }
    }

    /// 点了的通知是不是核心发的；是的话给它的卡片编号（可能没有）
    static func clicked(_ userInfo: [AnyHashable: Any]) -> (isAgent: Bool, surfaceId: String?) {
        (userInfo[userInfoKey] != nil, userInfo["surfaceId"] as? String)
    }

    /// 通知授权的名字（§11 `POST /notifications` 的 `status`）
    static func authName(_ s: UNAuthorizationStatus) -> String {
        switch s {
        case .notDetermined: return "not_determined"
        case .denied: return "denied"
        case .authorized: return "authorized"
        case .provisional: return "provisional"
        case .ephemeral: return "ephemeral"
        @unknown default: return "unknown"
        }
    }
}

/// 用户在不在 Mac 前（§11）：空闲多久（IOHIDSystem 的 HIDIdleTime）、锁屏、屏幕睡着。
/// `AgentConnection.watchPresence()` 拿一个：变了马上报，平时每 30 秒报一次。
@MainActor
final class Presence {
    private(set) var locked = false
    private(set) var asleep = false
    var onChange: (() -> Void)?
    private var tokens: [(NotificationCenter, NSObjectProtocol)] = []

    init() {
        let dnc = DistributedNotificationCenter.default()
        let ws = NSWorkspace.shared.notificationCenter
        func watch(_ c: NotificationCenter, _ name: Notification.Name, _ set: @escaping @MainActor (Presence) -> Void) {
            let t = c.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    set(self)
                    self.onChange?()
                }
            }
            tokens.append((c, t))
        }
        watch(dnc, .init("com.apple.screenIsLocked")) { $0.locked = true }
        watch(dnc, .init("com.apple.screenIsUnlocked")) { $0.locked = false }
        watch(ws, NSWorkspace.screensDidSleepNotification) { $0.asleep = true }
        watch(ws, NSWorkspace.screensDidWakeNotification) { $0.asleep = false }
    }

    func stop() {
        for (c, t) in tokens { c.removeObserver(t) }
        tokens = []
    }

    var idleSeconds: Double {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOHIDSystem"))
        guard service != 0 else { return 0 }
        defer { IOObjectRelease(service) }
        guard let prop = IORegistryEntryCreateCFProperty(service, "HIDIdleTime" as CFString, kCFAllocatorDefault, 0)?
            .takeRetainedValue(), let ns = (prop as? NSNumber)?.uint64Value else { return 0 }
        return Double(ns) / 1_000_000_000
    }
}
