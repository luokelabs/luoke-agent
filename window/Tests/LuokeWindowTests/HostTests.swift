import AppKit
import SwiftUI
import LuokeA2UICore
import XCTest
@testable import LuokeWindow

/// 接着螺壳.app（本体）时（luoke-core#68，周五的精简版）：模型、隐私、添加应用、升级交给本体；菜单栏的几项给本体现成的菜单项；
/// 系统设置由窗口打开。
@MainActor
final class HostTests: XCTestCase {
    final class FakeHost: WindowHost {
        var calls: [String] = []
        func openModelSettings() { calls.append("model") }
        func openPrivacySettings() { calls.append("privacy") }
        func openAddApps() { calls.append("apps") }
        func upgrade(app: String) { calls.append("upgrade \(app)") }
        func askPermission(app: String, id: String) { calls.append("ask \(app) \(id)") }
        var ready: (@MainActor () -> Void)?
        func askPermission(app: String, id: String, ready: @escaping @MainActor () -> Void) {
            calls.append("ready \(app) \(id)")
            self.ready = ready
        }
        func askSystem(id: String) { calls.append("system \(id)") }
        func setPermission(app: String, id: String, on: Bool) { calls.append("use \(app) \(id) \(on)") }
    }

    /// 只写老的四样的本体：新的两样有空的默认实现，照样编得过、点了不出事
    final class OldHost: WindowHost {
        func openModelSettings() {}
        func openPrivacySettings() {}
        func openAddApps() {}
        func upgrade(app: String) {}
    }

    func testPermissionCallsHaveEmptyDefaults() {
        let h = OldHost()
        h.askPermission(app: "luoke-scan", id: "fda")
        h.setPermission(app: "luoke-scan", id: "fda", on: false)
    }

    func testHostOpensItsOwnWindows() {
        let m = Sample.model()
        let h = FakeHost()
        m.host = h
        m.go(.prefs, tab: "model")
        XCTAssertEqual(m.page, .today, "模型是本体的窗口：主窗口留在原来那页")
        m.go(.prefs, tab: "alerts")
        XCTAssertEqual(m.page, .prefs)
        XCTAssertEqual(m.prefsTab, .general, "提醒并进了「通用」")
        m.selectPrefsTab(.privacy)
        XCTAssertEqual(m.prefsTab, .privacy, "隐私与权限里有窗口自己的权限：整个标签不交出去")
        m.go(.apps)
        XCTAssertEqual(m.page, .prefs)
        m.upgrade(.mail)
        XCTAssertEqual(h.calls, ["model", "apps", "upgrade luoke-mail"])
        XCTAssertTrue(m.prefsTabOpensElsewhere(.model))
        XCTAssertFalse(m.prefsTabOpensElsewhere(.privacy))
        XCTAssertFalse(m.prefsTabOpensElsewhere(.general))
        XCTAssertNil(m.settingsData, "本体没给数据：不画示例的")
        m.perform(.go(.prefs, "model"))
        XCTAssertEqual(h.calls.last, "model", "「前往 → 模型」和侧栏底部的模型名走同一条")
    }

    /// 本体给的是数据（§16）：窗口画自己的「应用管理」，动作交给本体，卸载不在窗口里另弹确认
    final class SnapshotHost: WindowHost {
        var calls: [String] = []
        var apps = HostApps(rows: [
            HostAppRow(id: "luoke-mail", tool: .mail, tagline: "守着收件箱", version: "0.18.11", state: .installed, actions: [.disable, .rollback(to: "0.18.10"), .uninstall]),
            HostAppRow(id: "luoke-ime", tool: .ime, tagline: "越用越懂你说话的方式", version: "0.1.20", state: .unavailable(reason: "内存不够这一档"), bundled: true),
            HostAppRow(id: "luoke-search", tool: .search, tagline: "答案带出处", version: "0.4.2", state: .working(label: "正在下载", progress: 0.4)),
        ], notice: HostAppsNotice(text: "输入法已重新启动", ok: true, action: (label: "打开键盘设置", app: "luoke-ime", action: .openKeyboardSettings)))
        func appsSnapshot() -> HostApps? { apps }
        func openAddApps() { calls.append("apps") }
        func openModelSettings() { calls.append("model") }
        func openPrivacySettings() { calls.append("privacy") }
        func upgrade(app: String) { calls.append("upgrade \(app)") }
        func perform(app: String, action: HostAppAction) { calls.append("\(app) \(action.title)") }
        func install(app: String) { calls.append("install \(app)") }
    }

    /// 本体给了设置的数据（界面接口 §16）：三个标签都画在窗口里，改了一项、点了动作都交给本体
    final class SettingsDataHost: WindowHost {
        var calls: [String] = []
        var settings = Sample.hostSettings
        func settingsSnapshot() -> HostSettings? { settings }
        func apply(_ change: HostSettingChange) { calls.append("\(change)") }
        func checkForUpdates() { calls.append("check") }
        func uninstallLuoke() { calls.append("uninstall") }
        func exportDiagnostics() { calls.append("export") }
        func openAddApps() { calls.append("apps") }
        func openModelSettings() { calls.append("model") }
        func openPrivacySettings() { calls.append("privacy") }
        func upgrade(app: String) { calls.append("upgrade \(app)") }
    }

    func testHostSettingsDataDrivesTheSettingsPage() {
        let m = Sample.model()
        let h = SettingsDataHost()
        m.host = h
        m.go(.prefs, tab: "model")
        XCTAssertEqual([m.page, m.prefsTab] as [AnyHashable], [Page.prefs, PrefsTab.model], "有数据就画在窗口里")
        XCTAssertFalse(m.prefsTabOpensElsewhere(.model))
        XCTAssertEqual(m.hostSettingsTab, .general, "能耗、登录时启动、更新在「通用」")
        m.applySetting(.powerMode(.quiet))
        m.applySetting(.tier("plus"))
        m.settingsAction(.checkUpdates)
        m.settingsAction(.upgrade)
        m.settingsAction(.export)
        m.settingsAction(.uninstall)
        XCTAssertEqual(h.calls, ["powerMode(LuokeWindow.HostPowerMode.quiet)", "tier(\"plus\")", "check", "upgrade luoke-core", "export", "uninstall"])
        h.settings.general.powerMode = .quiet
        m.hostSettingsChanged()
        XCTAssertEqual(m.settingsData?.general.powerMode, .quiet, "本体说变了，窗口重新取")
    }

    func testSampleSettingsChangeInTheWindow() {
        let m = Sample.model()
        XCTAssertNotNil(m.settingsData, "没接本体：用示例")
        m.applySetting(.batteryMode(.noLargeModel))
        m.applySetting(.tier("plus"))
        XCTAssertEqual(m.settingsData?.general.batteryMode, .noLargeModel)
        XCTAssertEqual(m.settingsData?.models.tiers[1].state, .switching(progress: 0))
        m.settingsDialog = .advanced
        XCTAssertEqual(m.settingsDialog?.title, "高级（本机接口）")
        XCTAssertEqual(ModelsTab.gb(0.5), "512 MB")
        XCTAssertEqual(ModelsTab.gb(5.6), "5.6 GB")
        XCTAssertEqual(ModelsTab.gb(27.8), "28 GB")
    }

    func testHostAppSnapshotDrivesTheAppsPage() {
        let m = Sample.model()
        let h = SnapshotHost()
        m.host = h
        m.go(.apps)
        XCTAssertEqual(m.page, .apps, "有数据就停在窗口里，不打开本体的窗口")
        XCTAssertEqual(h.calls, [])
        XCTAssertEqual(m.appRows.map(\.id), ["luoke-mail", "luoke-ime", "luoke-search"])
        XCTAssertFalse(m.confirmsUninstallHere, "卸载走本体的确认页")
        let mail = m.appRows[0]
        XCTAssertTrue(mail.canUninstall)
        XCTAssertEqual(mail.moreActions, [.disable, .rollback(to: "0.18.10"), .uninstall], "都收进「更多」，卸载在最后")
        XCTAssertFalse(m.appRows[1].canUninstall, "随螺壳装的不显示卸载")
        let off = HostAppRow(id: "luoke-scan", tool: .scan, tagline: "", version: "0.1.0", state: .disabled, actions: [.enable, .uninstall])
        XCTAssertTrue(off.enableOnRow)
        XCTAssertEqual(off.moreActions, [.uninstall], "停用了的：「开启」在行上，不进「更多」；卸载照旧在「更多」里")
        m.perform(.uninstall, on: mail)
        m.perform(.rollback(to: "0.18.10"), on: mail)
        m.perform(.openKeyboardSettings, onApp: "luoke-ime")
        XCTAssertEqual(h.calls, ["luoke-mail 卸载", "luoke-mail 回退到 0.18.10", "luoke-ime 打开键盘设置"])
        h.apps.rows[0].version = "0.18.12"
        m.hostAppsChanged()
        XCTAssertEqual(m.appRows[0].version, "0.18.12", "本体说数据变了，窗口重新取")
    }

    func testNoHostMeansTheWindowDrawsThePages() {
        let m = Sample.model()
        XCTAssertFalse(m.prefsTabOpensElsewhere(.model))
        m.go(.prefs, tab: "model")
        XCTAssertEqual(m.page, .prefs)
        XCTAssertEqual(m.prefsTab, .model)
        m.go(.apps)
        XCTAssertEqual(m.page, .apps)
    }

    func testStatusMenuItemsForTheHostMenu() {
        let m = Sample.model()       // 示例里有一件急事
        var opened = 0
        let items = StatusMenuItems.items(model: m) { opened += 1 }
        XCTAssertEqual(items.map { $0.isSeparatorItem ? "—" : $0.title },
                       ["急事", "可疑邮件：冒充招商银行", "—", "打开螺壳", "暂停提醒一小时"],
                       "不带本体自己的状态行和退出；前后没有多余的分隔线")
        XCTAssertTrue(items[0].isSectionHeader)
        XCTAssertNotNil(items[1].image, "急事前面是应用的图标")
        XCTAssertTrue(StatusMenuItems.hasDot(m))
        m.go(.activity)
        fire(items[1])
        XCTAssertEqual(opened, 1, "点急事：先打开窗口")
        XCTAssertEqual(m.page, .today, "再去「今天」")
        fire(items[4])
        XCTAssertEqual(opened, 1, "暂停提醒不开窗口")
        XCTAssertNotNil(m.pausedUntil)
        XCTAssertEqual(StatusMenuItems.items(model: m) {}.last?.title, "恢复提醒")
        m.urgent = []
        XCTAssertEqual(StatusMenuItems.items(model: m) {}.map(\.title), ["打开螺壳", "恢复提醒"])
        XCTAssertFalse(StatusMenuItems.hasDot(m))
    }

    /// 小点照核心的 `dot`：急事放进简报、只放在窗口里，或关了主动提醒时，菜单里照样列急事，图标不点
    func testDotFollowsTheCore() throws {
        let m = WindowModel()
        let f = AgentFeed(model: m)
        for (e, d) in Sample.agentEvents() { f.handle(e, d) }
        XCTAssertTrue(m.hasUrgent)
        let feed = try XCTUnwrap(Sample.agentEvents().last { $0.0 == "feed" })
        guard case .object(var o) = try JSONValue.parse(feed.1) else { return XCTFail("feed 是对象") }
        o["dot"] = .bool(false)
        f.handle("feed", JSONValue.object(o).serialized())
        XCTAssertTrue(m.hasUrgent, "横幅、菜单里照样有")
        XCTAssertTrue(StatusMenuItems.items(model: m) {}.contains { $0.title == "可疑邮件：冒充招商银行" })
        XCTAssertFalse(StatusMenuItems.hasDot(m), "核心说不点")
        o["dot"] = .bool(true)
        f.handle("feed", JSONValue.object(o).serialized())
        XCTAssertTrue(StatusMenuItems.hasDot(m))
        o["dot"] = nil
        f.handle("feed", JSONValue.object(o).serialized())
        XCTAssertTrue(StatusMenuItems.hasDot(m), "老的核心不给：照有没有急事")
    }

    func testSystemSettingsOpenFromTheWindow() {
        final class Box: @unchecked Sendable {
            let lock = NSLock()
            var url = "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles"
            var posts = 0
            func get() -> String { lock.lock(); defer { lock.unlock() }; posts += 1; return url }
            var count: Int { lock.lock(); defer { lock.unlock() }; return posts }
            func set(_ s: String) { lock.lock(); url = s; lock.unlock() }
        }
        let answer = Box()
        let m = WindowModel()
        let c = AgentConnection(model: m) { method, path, _ in
            if method == "POST" && path == "/permissions" {
                let body = JSONValue.object(["text": .string("在系统设置里打开「完全磁盘访问」。"), "error": .bool(false),
                                             "url": .string(answer.get())])
                return (200, body.serialized())
            }
            return (200, Data(#"{"rows":[]}"#.utf8))
        }
        var opened: [URL] = []
        c.settingsOpener = { opened.append($0) }
        c.permission(app: "luoke-scan", id: "fda", op: "settings")
        XCTAssertTrue(wait { !opened.isEmpty })
        XCTAssertEqual(opened.map(\.absoluteString), ["x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles"])
        answer.set("https://example.com/evil")
        c.permission(app: "luoke-scan", id: "fda", op: "settings")
        XCTAssertTrue(wait { answer.count == 2 })
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))     // 答复回到主线程
        XCTAssertEqual(opened.count, 1, "只开系统设置的地址")
    }

    private func fire(_ item: NSMenuItem) {
        _ = (item.target as AnyObject?)?.perform(item.action, with: item)
    }

    private func wait(_ ok: () -> Bool) -> Bool {
        for _ in 0..<200 {
            if ok() { return true }
            RunLoop.main.run(until: Date().addingTimeInterval(0.025))
        }
        return ok()
    }
}
