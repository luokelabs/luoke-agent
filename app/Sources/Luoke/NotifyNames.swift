import UserNotifications

/// 通知授权的名字，和 luoke-core 启动器的 `--notify-status` 用同一套。
enum NotifyNames {
    static func auth(_ s: UNAuthorizationStatus) -> String {
        switch s {
        case .notDetermined: return "not_determined"
        case .denied: return "denied"
        case .authorized: return "authorized"
        case .provisional: return "provisional"
        case .ephemeral: return "ephemeral"
        @unknown default: return "unknown"
        }
    }

    static func setting(_ s: UNNotificationSetting) -> String {
        switch s {
        case .notSupported: return "not_supported"
        case .disabled: return "disabled"
        case .enabled: return "enabled"
        @unknown default: return "unknown"
        }
    }
}
