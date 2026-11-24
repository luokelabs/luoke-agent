import AppKit
import SwiftUI

/// 设置（走查重画稿第二、三稿，11-12；提醒三类 11-13 负责人定）：通用、模型、隐私与权限三个标签。
/// 每页是几组紧凑的行，没有前面的图标；少用的放在最下面一行链接里，点了是弹窗。
/// 登录时启动、更新、能耗、模型、本机接口、导出、卸载是本体管的：本体给数据（`WindowModel.settingsData`，界面接口 §16）、窗口画
struct SettingsPage: View {
    @ObservedObject var model: WindowModel
    @Environment(\.lk) private var p

    var body: some View {
        let data = model.settingsData
        PageScroll() {
            PageHeader(title: "设置").lkEnter(0)
            LKLineTabs(tabs: PrefsTab.shown.map { LKTabs.Tab(id: $0.rawValue, title: $0.title, external: model.prefsTabOpensElsewhere($0)) },
                       selected: model.prefsTab.shownTab.rawValue) {
                model.selectPrefsTab(PrefsTab(rawValue: $0.id) ?? .general)
            }
            .lkEnter(1)
            Group {
                switch model.prefsTab.shownTab {
                case .model: if let data { ModelsTab(model: model, data: data.models) }
                case .privacy: PrivacyTab(model: model, data: data?.privacy)
                default: GeneralTab(model: model, data: data?.general)
                }
            }
            .lkEnter(2)
        }
    }
}

/// 设置里的一行：名字（下面可有一行小字）、右边的控件。行和行之间的线由 `SettingsGroup` 画
struct SettingsRow<Trailing: View>: View {
    let title: String
    var note: String? = nil
    var noteWarns = false
    @ViewBuilder var trailing: Trailing
    @Environment(\.lk) private var p

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(LKFont.ui(LKType.body, .medium))
                if let note {
                    Text(note).font(LKFont.ui(LKType.caption)).foregroundStyle(noteWarns ? p.warningText : p.mutedFg)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: LKSpace.x3)
            trailing
        }
        .frame(minHeight: 34)
    }
}

/// 一组行：卡片的底，行和行之间一条细线（界面规范 §6「列表组」divide-y；负责人 11-14：有的列表有分隔、有的没有，看着怪，
/// 统一都画）
struct SettingsGroup<Content: View>: View {
    @ViewBuilder var content: Content
    @Environment(\.lk) private var p

    var body: some View {
        _VariadicView.Tree(DividedRows(line: p.border)) { content }
            .padding(.horizontal, LKSpace.x4)
            .padding(.vertical, LKSpace.x1)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(CardSurface())
            .clipShape(RoundedRectangle(cornerRadius: p.cardRadius, style: .continuous))
    }
}

/// 一组里的每一行上下留一点，第二行起上边一条线（缩到内容边）
struct DividedRows: _VariadicView_MultiViewRoot {
    let line: Color

    @ViewBuilder func body(children: _VariadicView.Children) -> some View {
        let first = children.first?.id
        VStack(alignment: .leading, spacing: 0) {
            ForEach(children) { child in
                child
                    .padding(.vertical, LKSpace.x2)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .overlay(alignment: .top) { if child.id != first { Rectangle().fill(line).frame(height: 1) } }
            }
        }
    }
}

/// 组上面的小标题
struct SettingsHeading: View {
    let title: String
    @Environment(\.lk) private var p
    var body: some View {
        Text(title).font(LKFont.ui(LKType.small)).foregroundStyle(p.mutedFg)
            .padding(.top, LKSpace.x6).padding(.bottom, LKSpace.x2)
            .accessibilityAddTraits(.isHeader)
    }
}

/// 页底一行链接：「关于螺壳 › · 卸载螺壳 ›」；危险操作标红与普通链接区分
struct SettingsLinks: View {
    struct Link {
        let title: String
        var danger = false
        let action: () -> Void
    }

    let links: [Link]
    @Environment(\.lk) private var p

    init(links: [(String, () -> Void)]) {
        self.links = links.map { Link(title: $0.0, danger: false, action: $0.1) }
    }

    init(items: [Link]) {
        self.links = items
    }

    var body: some View {
        HStack(spacing: LKSpace.x2) {
            ForEach(Array(links.enumerated()), id: \.offset) { i, l in
                if i > 0 { Text("·").foregroundStyle(p.mutedFg) }
                Button(action: l.action) {
                    HStack(spacing: 2) {
                        Text(l.title)
                        LKIcon("chevron-right", size: 11)
                    }
                    .foregroundStyle(l.danger ? p.danger : p.mutedFg)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plainPointer)
            }
        }
        .font(LKFont.ui(LKType.small))
        .padding(.top, LKSpace.x4)
    }
}

// MARK: 通用

/// 通用：外观、登录时启动、检查更新；性能与功耗；提醒（三类和每天的简报）；最下面一行链接
struct GeneralTab: View {
    @ObservedObject var model: WindowModel
    let data: HostGeneral?
    @Environment(\.lk) private var p

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // 连不上螺壳：说清楚哪些现在改不了（提醒归核心管；外观、登录时启动、能耗这几项不经过它，照样能改），
            // 「提醒」那一组整组变灰（负责人 11-15：显示空卡片和默认值，不说原因）
            if !model.coreReachable {
                NoticeLine(row: NoticeRow(id: "offline", kind: "info", text: "未连接螺壳，提醒设置暂时无法更改"), action: nil)
                    .lkCard().padding(.bottom, LKSpace.x4)
            }
            SettingsGroup {
                SettingsRow(title: "外观") {
                    LKSegmented(options: Appearance.allCases.map { .init(value: $0, title: $0.title, symbol: nil) },
                                value: Binding(get: { model.appearance }, set: { model.setAppearance($0) }), label: "外观")
                }
                if let g = data {
                    loginRow(g)
                    updateRow(g)
                    if let auto = g.autoCheck {     // 负责人 11-15：「每天自动检查」的开关在设置里找不到
                        SettingsRow(title: "自动检查更新", note: "仅提示，不自动安装") {
                            LKSwitch(on: Binding(get: { auto }, set: { model.applySetting(.autoCheckUpdates($0)) }), label: "自动检查更新")
                        }
                    }
                }
            }
            if let g = data {
                SettingsHeading(title: "性能与功耗")
                SettingsGroup {
                    SettingsRow(title: "能耗模式") {
                        LKSegmented(options: HostPowerMode.allCases.map { .init(value: $0, title: $0.title, symbol: nil) },
                                    value: Binding(get: { g.powerMode }, set: { model.applySetting(.powerMode($0)) }), label: "能耗模式")
                    }
                    SettingsRow(title: "使用电池时") {
                        LKSegmented(options: HostBatteryMode.allCases.map { .init(value: $0, title: $0.title, symbol: nil) },
                                    value: Binding(get: { g.batteryMode }, set: { model.applySetting(.batteryMode($0)) }), label: "使用电池时")
                    }
                    if let pause = g.pauseOnLowPower {
                        SettingsRow(title: "低电量模式时暂停") {
                            LKSwitch(on: Binding(get: { pause }, set: { model.applySetting(.pauseOnLowPower($0)) }), label: "低电量模式时暂停")
                        }
                    }
                }
            }
            SettingsHeading(title: "提醒")
            SettingsGroup {
                // 现在的状态先写出来，各带一个去处（负责人 11-15：暂停提醒的状态看不到、没有恢复入口；通知被系统关了没有去系统设置的入口）
                if let until = model.pausedUntil {
                    SettingsRow(title: "提醒已暂停至 \(until)", noteWarns: true) {
                        Button("恢复") { model.togglePause() }.buttonStyle(LKButtonStyle())
                    }
                }
                ForEach(model.shownNotices.filter { $0.kind == "notifications" || $0.kind == "ask_notifications" }) { n in
                    SettingsRow(title: n.text, noteWarns: true) {
                        if let a = model.noticeAction(n) { Button(a.label, action: a.run).buttonStyle(LKButtonStyle()) }
                    }
                }
                // 总开关在这一节第一行；关着时下面几行变灰、不能选（负责人 11-15：总开关收在弹窗里，关掉以后外面三类照样亮着能选）
                SettingsRow(title: "主动提醒", note: "关闭后不发送通知和简报，「今天」不受影响") {
                    LKSwitch(on: Binding(get: { model.alertsOn }, set: { model.setAlerts($0) }), label: "主动提醒")
                }
                .disabled(!model.coreReachable)
                .opacity(model.coreReachable ? 1 : 0.45)
                Group {
                    ForEach(AlertClass.allCases, id: \.self) { c in
                        SettingsRow(title: c.title) {
                            LKSegmented(options: AlertTiming.allCases.map { .init(value: $0, title: $0.title, symbol: nil) },
                                        value: Binding(get: { model.alertClasses[c] ?? .brief }, set: { model.setAlertClass(c, $0) }),
                                        label: c.title)
                        }
                    }
                    SettingsRow(title: "简报频率") {
                        LKSelect(value: model.brief.rawValue, options: BriefMode.allCases.map(\.rawValue), label: "简报频率") {
                            model.setBrief(BriefMode(rawValue: $0) ?? .morning)
                        }
                    }
                    SettingsRow(title: "每日简报") {
                        LKSelect(value: model.briefTime, options: model.briefTimeOptions, label: "每日简报") { model.setBriefTime($0) }
                    }
                    SettingsRow(title: "免打扰") {
                        LKSelect(value: model.quietHours, options: model.quietOptions, label: "免打扰") { model.setQuiet($0) }
                    }
                    Button { model.settingsDialog = .alerts } label: {
                        SettingsRow(title: "按应用分类设置") {
                            LKIcon("chevron-right", size: 13).foregroundStyle(p.mutedFg)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plainPointer)
                }
                .disabled(!model.alertsOn || !model.coreReachable)
                .opacity(model.alertsOn && model.coreReachable ? 1 : 0.45)
            }
            if data != nil {
                SettingsLinks(items: [
                    .init(title: "关于螺壳", action: { model.settingsDialog = .about }),
                    .init(title: "卸载螺壳", danger: true, action: { model.settingsAction(.uninstall) }),
                ])
            }
        }
    }

    @ViewBuilder private func loginRow(_ g: HostGeneral) -> some View {
        switch g.loginItem {
        case .on, .off:
            SettingsRow(title: "登录时启动") {
                LKSwitch(on: Binding(get: { g.loginItem == .on }, set: { model.applySetting(.loginItem($0)) }), label: "登录时启动")
            }
        case .requiresApproval:
            SettingsRow(title: "登录时启动", note: "需在系统设置的「登录项」中允许", noteWarns: true) {
                Button("打开系统设置") { model.openLoginItemsSettings() }.buttonStyle(LKButtonStyle(kind: .primary))
            }
        case .error(let why):
            SettingsRow(title: "登录时启动", note: why, noteWarns: true) {
                LKSwitch(on: Binding(get: { false }, set: { model.applySetting(.loginItem($0)) }), label: "登录时启动")
            }
        }
    }

    private func updateRow(_ g: HostGeneral) -> some View {
        // 没查过的不说「已是最新」（负责人 11-15：从没查过也写「当前是最新版」）
        let checked = g.lastChecked.map { "上次检查：\(model.seenText($0))" }
        let note = g.latestVersion.map { "有新版本 \($0)" } ?? (checked.map { "已是最新版本 · \($0)" } ?? "尚未检查")
        return SettingsRow(title: "检查更新", note: note) {
            if g.latestVersion != nil {
                Button("升级") { model.settingsAction(.upgrade) }.buttonStyle(LKButtonStyle(kind: .primary))
            } else {
                LKIconButton(symbol: "refresh-cw", label: "检查更新") { model.settingsAction(.checkUpdates) }
            }
        }
    }
}

// MARK: 模型

/// 模型：两个版本各一行（写用什么模型、多大；在用的标「正在用」，没下载的写要下载多大、右边下载图标，下载中显示进度），
/// 模型清单（型号、用途；右边参数量 · 量化 · 大小），最下面「高级（本机接口）›」
struct ModelsTab: View {
    @ObservedObject var model: WindowModel
    let data: HostModels
    @Environment(\.lk) private var p

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SettingsGroup {
                ForEach(data.tiers) { t in tierRow(t) }
            }
            if data.metered {
                Text("当前为按流量计费的网络，不自动下载")
                    .font(LKFont.ui(LKType.caption)).foregroundStyle(p.mutedFg).padding(.top, LKSpace.x2)
            }
            if !data.catalog.isEmpty {
                SettingsHeading(title: "模型清单")
                SettingsGroup {
                    ForEach(data.catalog) { r in
                        SettingsRow(title: r.name, note: r.shownPurpose) {
                            Text("\(r.params) · \(r.quant) · \(Self.gb(r.sizeGB))")
                                .font(LKFont.ui(LKType.small)).foregroundStyle(p.mutedFg).monospacedDigit()
                        }
                    }
                }
            }
            SettingsLinks(links: [("高级（本机接口）", { model.settingsDialog = .advanced })])
        }
    }

    @ViewBuilder private func tierRow(_ t: HostTier) -> some View {
        switch t.state {
        case .inUse:
            SettingsRow(title: t.shownTitle, note: "\(t.blurb) · \(Self.gb(t.sizeGB))") { LKBadge(text: "使用中") }
                .help(t.model)
        case .switching(let progress):
            SettingsRow(title: t.shownTitle, note: "\(t.blurb) · \(Self.gb(t.sizeGB))") {
                // 正在用的这一档在补下模型：照样标「使用中」（负责人 11-15：补下模型时「正在用」标记没了）
                if t.current { LKBadge(text: "使用中") }
                VStack(alignment: .trailing, spacing: 4) {
                    Text(progress.map { "下载中 \(Int($0 * 100))%" } ?? "等待下载").font(LKFont.ui(LKType.caption)).foregroundStyle(p.mutedFg)
                    ProgressCapsule(value: progress ?? 0).frame(width: 120)
                }
            }
        case .available(let need) where need <= 0:      // 模型都在磁盘上：点了马上换
            SettingsRow(title: t.shownTitle, note: "\(t.blurb) · \(Self.gb(t.sizeGB))") {
                Button("切换") { model.applySetting(.tier(t.id)) }.buttonStyle(LKButtonStyle())
            }
        case .available(let need):
            SettingsRow(title: t.shownTitle, note: "\(t.blurb) · 需要下载 \(Self.gb(need))") {
                LKIconButton(symbol: "circle-arrow-down", label: "下载\(t.shownTitle)") { model.applySetting(.tier(t.id)) }
            }
        case .failed(let reason):
            SettingsRow(title: t.shownTitle, note: reason, noteWarns: true) {
                if t.current { LKBadge(text: "使用中") }
                // 再下一次也没用的（磁盘不够）不给「重新下载」（负责人 11-15：磁盘不够也给，点了没用）
                if t.canRetry { LKIconButton(symbol: "refresh-cw", label: "重新下载") { model.settingsAction(.retryDownloads) } }
            }
        }
    }

    /// 「5.6 GB」「512 MB」
    static func gb(_ v: Double) -> String {
        if v < 1 { return "\(Int((v * 1024).rounded())) MB" }
        return v >= 10 ? "\(Int(v.rounded())) GB" : String(format: "%.1f GB", v)
    }
}

// MARK: 隐私与权限

/// 隐私与权限：最上面一句数据在哪；下面是全部权限（螺壳级权限支持按应用展开、本体系统检查如通知、应用自有权限、账号、每次询问）；页底可导出诊断信息
struct PrivacyTab: View {
    @ObservedObject var model: WindowModel
    let data: HostPrivacy?
    @Environment(\.lk) private var p

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SettingsGroup {
                SettingsRow(title: "数据仅保存在这台 Mac 上", note: data?.dataLine ?? "邮件、记忆、文件索引均不上传") { EmptyView() }
            }
            CanUseList(model: model, systemChecks: data?.systemChecks ?? [])
            if data?.canExport ?? false {
                SettingsLinks(links: [("导出诊断信息", { model.settingsAction(.export) })])
            }
        }
    }
}

/// 权限管理唯一入口：螺壳名下的系统权限（已授权且多应用使用时可就地「按应用」展开）、本体系统检查（如通知，不与上面重复）、
/// 应用自有系统权限、账号，以及每次询问的只读清单。
/// 代你做的事（扫描「不用点就清」）是那个应用自己的设置，在它的页上，不放这里（负责人 11-15）。
struct CanUseList: View {
    @ObservedObject var model: WindowModel
    var systemChecks: [HostSystemCheck] = []
    @Environment(\.lk) private var p
    /// 已授权的螺壳级权限点击后就地展开，显示并单独开关各应用的权限
    @State private var expanded: Set<String> = []

    /// 关掉某个应用使用螺壳名下的权限时显示的状态文字（约定：不说系统拦着）
    static let hostOffText = "未允许"

    /// 状态灯：灯的颜色和读屏、悬停时的一句话
    static func light(_ kind: String, _ state: String?, needed: Bool) -> (LKLight.State, String) {
        let account = kind == "account"
        switch state {
        case "granted": return (.ok, account ? "已连接" : "已允许")
        case "denied": return account ? (.off, "未连接") : (.warn, "未允许")
        case "ask": return needed ? (.warn, "待允许") : (.off, account ? "未连接" : "未允许")
        default: return (.off, "未知")
        }
    }

    /// 过滤掉已在螺壳级权限中展示的同名项（如完全磁盘访问、照片），保留通知等仅由本体检查的系统权限
    static func extraChecks(_ checks: [HostSystemCheck], covered: Set<String>) -> [HostSystemCheck] {
        checks.filter { !covered.contains($0.name) }
    }

    var body: some View {
        if model.agentPermissions != nil {
            let groups = model.luokePermissions
            let extras = Self.extraChecks(systemChecks, covered: Set(groups.map(\.title)))
            let system = model.agentPermissionRows("system")
            let accounts = model.agentPermissionRows("account")
            let each = model.agentPermissionRows("each-time")
            if !groups.isEmpty || !extras.isEmpty || !system.isEmpty || !accounts.isEmpty {
                SettingsHeading(title: "螺壳的权限")
                SettingsGroup {
                    ForEach(groups) { g in luokeRow(g) }
                    ForEach(Array(extras.enumerated()), id: \.offset) { _, c in systemCheckRow(c) }
                    ForEach(system) { r in appSystemRow(r) }
                    ForEach(accounts) { r in
                        SettingsRow(title: r.title, note: Self.light(r.kind, r.state, needed: model.isNeeded(r)).1) {
                            if (r.can ?? []).contains("open") {
                                LKIconButton(symbol: "square-arrow-out-up-right", label: "打开") { model.permissionAction(r, "open") }
                            }
                            if (r.can ?? []).contains("remove") {
                                Button("移除") { model.permissionAction(r, "remove") }
                                    .buttonStyle(LKButtonStyle(kind: .text))
                                    .disabled(model.permissionPending[r.id] != nil)
                            }
                        }
                    }
                }
            }
            if !each.isEmpty {
                SettingsHeading(title: "每次询问")
                SettingsGroup {
                    ForEach(each) { r in
                        let why = r.facts.isEmpty ? "每次需手动确认" : r.facts.joined(separator: "；")
                        SettingsRow(title: r.title, note: r.tool.name) {
                            LKIcon("lock").foregroundStyle(p.mutedFg).help(why).accessibilityLabel(why)
                        }
                    }
                }
            }
        } else {
            let extras = Self.extraChecks(systemChecks, covered: Set(model.permissions.map(\.title)))
            if !model.permissions.isEmpty || !extras.isEmpty || !model.accounts.isEmpty {
                SettingsHeading(title: "螺壳的权限")
                SettingsGroup {
                    ForEach(model.permissions) { r in
                        SettingsRow(title: r.title, note: r.sub) {
                            if r.state == .granted {
                                LKSwitch(on: .constant(true), label: r.title)
                            } else {
                                Button("允许") { model.requestPermission(r.id) }.buttonStyle(LKButtonStyle(kind: r.state == .waiting ? .primary : .secondary))
                            }
                        }
                    }
                    ForEach(Array(extras.enumerated()), id: \.offset) { _, c in systemCheckRow(c) }
                    ForEach(model.accounts) { r in
                        SettingsRow(title: r.title, note: r.sub) {
                            Button("移除") { model.show("授权码会从钥匙串里删掉") }.buttonStyle(LKButtonStyle(kind: .text))
                        }
                    }
                }
            }
            if !model.eachTime.isEmpty {
                SettingsHeading(title: "每次询问")
                SettingsGroup {
                    ForEach(model.eachTime) { e in
                        SettingsRow(title: e.title, note: e.tool.name) {
                            LKIcon("lock").foregroundStyle(p.mutedFg).help(e.why).accessibilityLabel(e.why)
                        }
                    }
                }
            }
        }
    }

    /// 本体检查的系统权限状态（如通知）：正常亮绿灯，未允许亮黄灯（通知未允许时可直接打开系统设置）
    @ViewBuilder private func systemCheckRow(_ c: HostSystemCheck) -> some View {
        let label = c.ok ? "已允许" : "未允许"
        SettingsRow(title: c.name, note: c.detail ?? label) {
            if !c.ok && c.name == "通知" {
                Button("打开系统设置") {
                    if let u = URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension") {
                        NSWorkspace.shared.open(u)
                    }
                }
                .buttonStyle(LKButtonStyle(kind: .secondary))
            }
            LKLight(state: c.ok ? .ok : .warn, label: label).help(label)
        }
    }

    /// 挂在某个应用自己名下的系统权限（非螺壳统一管理）
    @ViewBuilder private func appSystemRow(_ r: AgentPermission) -> some View {
        let (_, label) = Self.light(r.kind, r.state, needed: model.isNeeded(r))
        let busy = model.permissionPending[r.id] != nil
        SettingsRow(title: r.title, note: "\(r.tool.name) · \(label)") {
            ForEach(r.can ?? [], id: \.self) { op in
                if op == "settings" {
                    Button { model.permissionAction(r, op) } label: { IconText("打开系统设置", symbol: "settings") }
                        .buttonStyle(LKButtonStyle(kind: .secondary)).disabled(busy)
                } else if op == "request" {
                    Button("允许") { model.permissionAction(r, op) }
                        .buttonStyle(LKButtonStyle(kind: .primary)).disabled(busy)
                } else if op == "open" {
                    LKIconButton(symbol: "square-arrow-out-up-right", label: "打开") { model.permissionAction(r, op) }
                        .disabled(busy)
                }
            }
        }
    }

    /// 螺壳名下的一项：给了就是开关（关了是不让各应用用，和系统那层无关），支持点击展开单独控制各应用；没给就是「允许」或「打开系统设置」
    @ViewBuilder private func luokeRow(_ g: LuokePermission) -> some View {
        let users = g.rows.filter(model.hostPermissionOn).reduce(into: [String]()) { out, r in
            if !out.contains(r.tool.name) { out.append(r.tool.name) }
        }
        let appRows = g.rows.filter { $0.kind == "system" }
        let canExpand = g.state == "granted" && appRows.count > 1
        let isOpen = canExpand && expanded.contains(g.id)
        let missing = Self.light("system", g.state, needed: g.rows.contains { model.isNeeded($0) }).1
        // 完全磁盘访问这类在系统设置里给的：macOS 要螺壳退出再打开才算数，没重开时这里照旧是没允许
        let note = g.state == "granted" ? (users.isEmpty ? "暂无应用使用" : "\(users.joined(separator: "、")) 使用中")
            : g.can.first == "settings" ? "\(missing)，允许后需重新打开螺壳" : missing
        VStack(alignment: .leading, spacing: 0) {
            SettingsRow(title: g.title, note: note) {
                if canExpand {
                    Button {
                        withAnimation(.easeOut(duration: 0.15)) {
                            if isOpen { expanded.remove(g.id) } else { expanded.insert(g.id) }
                        }
                    } label: {
                        HStack(spacing: 4) {
                            Text(isOpen ? "收起" : "按应用").font(LKFont.ui(LKType.caption))
                            LKIcon("chevron-right", size: 11).rotationEffect(.degrees(isOpen ? 90 : 0))
                        }
                        .foregroundStyle(p.mutedFg)
                        .padding(.horizontal, 6).frame(height: 24)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plainPointer)
                    .accessibilityLabel(isOpen ? "收起各应用权限" : "展开各应用权限")
                }
                if g.state == "granted" {
                    LKSwitch(on: Binding(get: { !users.isEmpty }, set: { on in
                        for r in g.rows where model.hostPermissionOn(r) != on { model.setHostPermission(r, on: on) }
                    }), label: "允许螺壳使用\(g.title)")
                } else if let op = g.can.first, let r = g.rows.first(where: { $0.can?.contains(op) == true }) {
                    Button(op == "settings" ? "打开系统设置" : "允许") { model.permissionAction(r, op) }
                        .buttonStyle(LKButtonStyle(kind: .primary))
                }
            }
            if isOpen {
                VStack(spacing: 0) {
                    ForEach(appRows) { r in
                        let on = model.hostPermissionOn(r)
                        HStack(spacing: 10) {
                            AppIcon(tool: r.tool, size: 18)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(r.tool.name).font(LKFont.ui(LKType.small))
                                if !on {
                                    Text(Self.hostOffText).font(LKFont.ui(LKType.caption)).foregroundStyle(p.mutedFg)
                                }
                            }
                            Spacer(minLength: LKSpace.x3)
                            LKSwitch(on: Binding(get: { on }, set: { model.setHostPermission(r, on: $0) }),
                                     label: "允许\(r.tool.name)使用\(g.title)")
                        }
                        .padding(.leading, 12).padding(.vertical, 6)
                        .overlay(alignment: .top) { Rectangle().fill(p.border).frame(height: 1).padding(.leading, 12) }
                    }
                }
                .padding(.top, LKSpace.x1)
            }
        }
    }

}

// MARK: 设置底下链接打开的弹窗

struct SettingsDialogView: View {
    @ObservedObject var model: WindowModel
    let dialog: SettingsDialog
    @Environment(\.lk) private var p

    var body: some View {
        LKDialog(title: dialog.title, close: { model.settingsDialog = nil }) {
            VStack(alignment: .leading, spacing: 0) {
                switch dialog {
                case .alerts: alerts
                case .about: about
                case .advanced: if let a = model.settingsData?.models.advanced { LocalAPIRows(model: model, api: a) }
                }
            }
        }
    }

    /// 各类事项的提醒方式（简报频率、免打扰已直接放在「设置 · 通用」的提醒卡片里）
    private var alerts: some View {
        VStack(alignment: .leading, spacing: 0) {
            if model.kinds.isEmpty {
                SettingsGroup {
                    SettingsRow(title: "暂无可单独设置的提醒类别") { EmptyView() }
                }
            } else {
                SettingsGroup {
                    ForEach(model.kinds) { k in
                        HStack(spacing: 12) {
                            AppIcon(tool: k.tool, size: 20)
                            // 名字长的折行，右边那组选项不让位：每行的选项一样宽、靠右，自然对成列（#175：选项被挤成「立即…」、各行错开）
                            // 核心给不出名字的一类（应用清单里没有、但还有开着的事）：写「其他提醒」，前面有应用图标，不写「这一类事」
                            let title = k.title == WindowModel.unnamedKind ? "其他提醒" : k.title
                            Text(title).lineLimit(2).fixedSize(horizontal: false, vertical: true)
                            Spacer(minLength: 0)
                            LKSegmented(options: Level.allCases.map { .init(value: $0, title: $0.title, symbol: nil) },
                                        value: Binding(get: { k.level }, set: { model.setLevel(k.id, $0) }), radio: true, label: title)
                                .fixedSize().layoutPriority(1)
                        }
                        .frame(minHeight: 34)
                    }
                }
            }
        }
    }

    private var about: some View {
        SettingsGroup {
            SettingsRow(title: "版本") {
                Text(model.settingsData?.general.currentVersion ?? "").font(LKFont.mono(LKType.small)).foregroundStyle(p.mutedFg)
                    .textSelection(.enabled)
            }
        }
    }
}

/// 本机接口（高级）：开关、地址、密钥、可用模型
struct LocalAPIRows: View {
    @ObservedObject var model: WindowModel
    let api: HostLocalAPI
    @Environment(\.lk) private var p

    var body: some View {
        SettingsGroup {
            SettingsRow(title: "本机接口", note: "允许这台 Mac 上的其他程序使用螺壳的模型") {
                LKSwitch(on: Binding(get: { api.enabled }, set: { model.applySetting(.localAPI($0)) }), label: "本机接口")
            }
            if let e = api.error { SettingsRow(title: "开启失败", note: e, noteWarns: true) { EmptyView() } }
            if api.enabled {
                let url = "http://\(api.address):\(api.port)/v1"
                SettingsRow(title: "地址") {
                    Text(url).font(LKFont.mono(LKType.caption)).foregroundStyle(p.mutedFg).textSelection(.enabled)
                    LKIconButton(symbol: "copy", label: "复制地址") { model.copy(url, said: "地址已复制") }
                }
                if api.hasKey {
                    SettingsRow(title: "密钥", note: "不显示，复制后使用") {
                        LKIconButton(symbol: "copy", label: "复制密钥") { model.settingsAction(.copyKey) }
                        LKIconButton(symbol: "refresh-cw", label: "更换密钥") { model.settingsAction(.rotateKey) }
                    }
                }
                if !api.models.isEmpty {
                    SettingsRow(title: "可用模型") {
                        Text(api.models.joined(separator: "、")).font(LKFont.mono(LKType.caption)).foregroundStyle(p.mutedFg)
                    }
                }
            }
        }
    }
}
