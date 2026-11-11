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
        XCTAssertEqual(m.prefsTab, .alerts)
        m.selectPrefsTab(.privacy)
        XCTAssertEqual(m.prefsTab, .alerts, "隐私也是本体的")
        m.selectPrefsTab(.permissions)
        XCTAssertEqual(m.prefsTab, .permissions, "权限是 agent 的页，照旧切过去")
        m.go(.apps)
        XCTAssertEqual(m.page, .prefs)
        m.upgrade(.mail)
        XCTAssertEqual(h.calls, ["model", "privacy", "apps", "upgrade luoke-mail"])
        XCTAssertTrue(m.prefsTabOpensElsewhere(.model))
        XCTAssertTrue(m.prefsTabOpensElsewhere(.privacy))
        XCTAssertFalse(m.prefsTabOpensElsewhere(.alerts))
        m.perform(.go(.prefs, "model"))
        XCTAssertEqual(h.calls.last, "model", "「前往 → 模型」和侧栏底部的模型名走同一条")
    }

    /// 本体给了模型、隐私的界面（11-09 负责人定）：画在窗口的设置里，不再另弹窗口；添加应用、升级照旧交给本体
    final class EmbeddingHost: WindowHost {
        var calls: [String] = []
        func settingsContent(_ tab: PrefsTab) -> AnyView? {
            tab == .model || tab == .privacy ? AnyView(Text("本体的\(tab.title)")) : nil
        }
        func openModelSettings() { calls.append("model") }
        func openPrivacySettings() { calls.append("privacy") }
        func openAddApps() { calls.append("apps") }
        func upgrade(app: String) { calls.append("upgrade \(app)") }
    }

    func testHostSettingsAreDrawnInTheWindow() {
        let m = Sample.model()
        let h = EmbeddingHost()
        m.host = h
        m.go(.prefs, tab: "model")
        XCTAssertEqual(m.page, .prefs, "模型画在设置里")
        XCTAssertEqual(m.prefsTab, .model)
        m.selectPrefsTab(.privacy)
        XCTAssertEqual(m.prefsTab, .privacy)
        m.perform(.go(.prefs, "model"))
        XCTAssertEqual(m.prefsTab, .model, "「前往 → 模型」、侧栏底部的模型名也停在设置里")
        XCTAssertFalse(m.prefsTabOpensElsewhere(.model), "标签上不画「在别处打开」")
        XCTAssertFalse(m.prefsTabOpensElsewhere(.privacy))
        m.go(.apps)
        XCTAssertEqual(h.calls, ["apps"], "只有添加应用交出去")
        XCTAssertNil(OldHost().settingsContent(.model), "老本体没给界面：照旧打开它的窗口")
    }

    /// 本体也给了应用目录：「添加应用」画在主窗口里；升级先翻到这一页，再交本体在那一行里升
    final class AppsHost: WindowHost {
        var calls: [String] = []
        func appsContent() -> AnyView? { AnyView(Text("本体的应用目录")) }
        func openModelSettings() { calls.append("model") }
        func openPrivacySettings() { calls.append("privacy") }
        func openAddApps() { calls.append("apps") }
        func upgrade(app: String) { calls.append("upgrade \(app)") }
    }

    func testHostAppsAreDrawnInTheWindow() {
        let m = Sample.model()
        let h = AppsHost()
        m.host = h
        m.go(.apps)
        XCTAssertEqual(m.page, .apps, "添加应用画在主窗口里")
        m.perform(.go(.apps, nil))
        XCTAssertEqual(m.page, .apps, "菜单的「添加应用…」也停在窗口里")
        m.go(.today)
        m.upgrade(.mail)
        XCTAssertEqual(m.page, .apps, "升级翻到「添加应用」页")
        XCTAssertEqual(h.calls, ["upgrade luoke-mail"], "不打开本体的窗口")
        XCTAssertNil(OldHost().appsContent(), "老本体没给界面：照旧打开它的窗口")
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
