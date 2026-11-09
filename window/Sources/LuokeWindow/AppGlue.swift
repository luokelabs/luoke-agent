import AppKit
import Foundation
import IOKit
import UserNotifications

// 螺壳.app 接核心要的几样（docs/界面接口.md §11、§12、§14）：系统通知、用户在不在、通知授权。
// 照 luoke-agent 原来的壳（app/Sources/Luoke）搬过来，本体直接用，不用再拷。

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

    /// 通知授权的名字（§12 `POST /notifications` 的 `status`）
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
