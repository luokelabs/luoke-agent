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

/// 页底一行链接：「逐类设置提醒 › · 关于螺壳 › · 卸载螺壳 ›」
struct SettingsLinks: View {
    let links: [(String, () -> Void)]
    @Environment(\.lk) private var p

    var body: some View {
        HStack(spacing: LKSpace.x2) {
            ForEach(Array(links.enumerated()), id: \.offset) { i, l in
                if i > 0 { Text("·").foregroundStyle(p.mutedFg) }
                Button(action: l.1) {
                    HStack(spacing: 2) {
                        Text(l.0)
                        LKIcon("chevron-right", size: 11)
                    }
                    .foregroundStyle(p.mutedFg)
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
                    SettingsRow(title: "每日简报") {
                        LKSelect(value: model.briefTime, options: model.briefTimeOptions, label: "每日简报") { model.setBriefTime($0) }
                    }
                }
                .disabled(!model.alertsOn || !model.coreReachable)
                .opacity(model.alertsOn && model.coreReachable ? 1 : 0.45)
            }
            SettingsLinks(links: [("分类提醒设置", { model.settingsDialog = .alerts })]
                          + (data == nil ? [] : [("关于螺壳", { model.settingsDialog = .about }),
                                                 ("卸载螺壳", { model.settingsAction(.uninstall) })]))
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

/// 隐私与权限：最上面一句数据在哪；「螺壳可以用的」每项一个开关；最下面「导出诊断信息 › · 系统权限检查 ›」
struct PrivacyTab: View {
    @ObservedObject var model: WindowModel
    let data: HostPrivacy?
    @Environment(\.lk) private var p

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SettingsGroup {
                SettingsRow(title: "数据仅保存在这台 Mac 上", note: data?.dataLine ?? "邮件、记忆、文件索引均不上传") { EmptyView() }
            }
            CanUseList(model: model)
            SettingsLinks(links: (data?.canExport ?? false ? [("导出诊断信息", { model.settingsAction(.export) })] : [])
                          + [("系统权限检查", { model.settingsDialog = .checks })])
        }
    }
}

/// 「螺壳可以用的」：螺壳名下的系统权限（文件、照片……）、账号，每项一行；没允许的是「允许」按钮。
/// 代你做的事（扫描「不用点就清」）是那个应用自己的设置，在它的页上，不放这里（负责人 11-15）。
/// 每次都问的、账号的移除、各应用的细项在「系统权限检查」弹窗里
struct CanUseList: View {
    @ObservedObject var model: WindowModel
    @Environment(\.lk) private var p

    var body: some View {
        if model.agentPermissions != nil {
            let groups = model.luokePermissions
            let accounts = model.agentPermissionRows("account")
            if !groups.isEmpty || !accounts.isEmpty {
                SettingsHeading(title: "螺壳的权限")
                SettingsGroup {
                    ForEach(groups) { g in luokeRow(g) }
                    ForEach(accounts) { r in
                        SettingsRow(title: r.title, note: AgentPermissionsTab.light(r.kind, r.state, needed: model.isNeeded(r)).1) {
                            if (r.can ?? []).contains("open") {
                                LKIconButton(symbol: "square-arrow-out-up-right", label: "打开") { model.permissionAction(r, "open") }
                            }
                        }
                    }
                }
            }
        } else if !model.permissions.isEmpty || !model.accounts.isEmpty {
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
                ForEach(model.accounts) { r in SettingsRow(title: r.title, note: r.sub) { EmptyView() } }
            }
        }
    }

    /// 螺壳名下的一项：给了就是开关（关了是不让各应用用，和系统那层无关）；没给就是「允许」或「打开系统设置」
    @ViewBuilder private func luokeRow(_ g: LuokePermission) -> some View {
        let users = g.rows.filter(model.hostPermissionOn).reduce(into: [String]()) { out, r in
            if !out.contains(r.tool.name) { out.append(r.tool.name) }
        }
        let missing = AgentPermissionsTab.light("system", g.state, needed: g.rows.contains { model.isNeeded($0) }).1
        // 完全磁盘访问这类在系统设置里给的：macOS 要螺壳退出再打开才算数，没重开时这里照旧是没允许
        let note = g.state == "granted" ? (users.isEmpty ? "暂无应用使用" : "\(users.joined(separator: "、")) 使用中")
            : g.can.first == "settings" ? "\(missing)，允许后需重新打开螺壳" : missing
        SettingsRow(title: g.title, note: note) {
            if g.state == "granted" {
                LKSwitch(on: Binding(get: { !users.isEmpty }, set: { on in
                    for r in g.rows where model.hostPermissionOn(r) != on { model.setHostPermission(r, on: on) }
                }), label: "允许螺壳使用\(g.title)")
            } else if let op = g.can.first, let r = g.rows.first(where: { $0.can?.contains(op) == true }) {
                Button(op == "settings" ? "打开系统设置" : "允许") { model.permissionAction(r, op) }
                    .buttonStyle(LKButtonStyle(kind: .primary))
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
                case .checks: checks
                }
            }
        }
    }

    /// 主动提醒、简报怎么发、免打扰，和每类事怎么说
    private var alerts: some View {
        VStack(alignment: .leading, spacing: 0) {
            SettingsGroup {
                SettingsRow(title: "简报") {
                    LKSelect(value: model.brief.rawValue, options: BriefMode.allCases.map(\.rawValue), label: "简报") {
                        model.setBrief(BriefMode(rawValue: $0) ?? .morning)
                    }
                }
                SettingsRow(title: "免打扰") {
                    LKSelect(value: model.quietHours, options: model.quietOptions, label: "免打扰") { model.setQuiet($0) }
                }
            }
            if !model.kinds.isEmpty {
                SettingsHeading(title: "分类")
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

    private var checks: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let cs = model.settingsData?.privacy.systemChecks, !cs.isEmpty {
                SettingsGroup {
                    ForEach(Array(cs.enumerated()), id: \.offset) { _, c in
                        SettingsRow(title: c.name, note: c.detail) { LKLight(state: c.ok ? .ok : .warn, label: c.ok ? "正常" : "未允许") }
                    }
                }
            }
            // 各应用的细项、账号、代你做、每次都问（原来的「设置 · 权限」）
            if model.agentPermissions != nil { AgentPermissionsTab(model: model) } else { SamplePermissions(model: model) }
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

/// 没接核心时（示例）的权限：系统、账号、每次都问（代你做的在各应用自己的页上）。没有行的一节不画标题
struct SamplePermissions: View {
    @ObservedObject var model: WindowModel
    @Environment(\.lk) private var p

    var body: some View {
        let first = [("系统", !model.permissions.isEmpty), ("账号", !model.accounts.isEmpty),
                     ("每次询问", !model.eachTime.isEmpty)].first { $0.1 }?.0
        VStack(alignment: .leading, spacing: 0) {
            if !model.permissions.isEmpty {
                section("系统", first: first)
                LKGroup {
                    ForEach(Array(model.permissions.enumerated()), id: \.element.id) { i, r in
                        HStack(spacing: 12) {
                            AppIcon(tool: r.owner, size: 28)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(r.title)
                                if let s = r.sub { Text(s).font(LKFont.ui(LKType.small)).foregroundStyle(p.mutedFg) }
                            }
                            Spacer()
                            switch r.state {
                            case .granted: LKLight(state: .ok, label: "已允许")
                            case .waiting:
                                LKLight(state: .warn, label: "待允许")
                                Button("允许") { model.requestPermission(r.id) }.buttonStyle(LKButtonStyle(kind: .primary))
                            case .notYet:
                                LKLight(state: .off, label: "未启用")
                                Button("允许") { model.requestPermission(r.id) }.buttonStyle(LKButtonStyle())
                            }
                        }
                        .lkRow(first: i == 0)
                    }
                }
            }
            if !model.accounts.isEmpty {
                section("账号", first: first)
                LKGroup {
                    ForEach(Array(model.accounts.enumerated()), id: \.element.id) { i, r in
                        HStack(spacing: 12) {
                            AppIcon(tool: r.owner, size: 28)
                            Text(r.title).font(LKFont.mono(LKType.small))
                            Spacer()
                            LKLight(state: .ok, label: r.sub ?? "")
                            Button("移除") { model.show("授权码会从钥匙串里删掉") }.buttonStyle(LKButtonStyle(kind: .text))
                        }
                        .lkRow(first: i == 0)
                    }
                }
            }
            if !model.eachTime.isEmpty {
                section("每次询问", first: first)
                LKGroup {
                    ForEach(Array(model.eachTime.enumerated()), id: \.element.id) { i, e in
                        HStack(spacing: 12) {
                            AppIcon(tool: e.tool, size: 28)
                            Text(e.title)
                            Spacer()
                            LKIcon("lock").foregroundStyle(p.mutedFg).help(e.why).accessibilityLabel(e.why)
                        }
                        .lkRow(first: i == 0)
                    }
                }
            }
        }
    }

    @ViewBuilder private func section(_ title: String, first: String?) -> some View {
        if title == first { LKSection(title: title).padding(.top, -LKSpace.x4) } else { LKSection(title: title) }
    }
}

/// 接上核心时的「设置 · 权限」（docs/界面接口.md §10）：螺壳名下的和各应用的系统权限、账号、每次都问（代你做的在各应用自己的页上）。
/// 按钮只照每一行的 `can` 出，点了才交给核心（`POST /permissions`）；每次都问的只列出来，没有按钮。
struct AgentPermissionsTab: View {
    @ObservedObject var model: WindowModel
    @Environment(\.lk) private var p

    var body: some View {
        let luoke = model.luokePermissions
        let system = model.agentPermissionRows("system")
        let accounts = model.agentPermissionRows("account")
        let each = model.agentPermissionRows("each-time")
        let first = [("系统", !luoke.isEmpty || !system.isEmpty), ("账号", !accounts.isEmpty),
                     ("每次询问", !each.isEmpty)].first { $0.1 }?.0
        VStack(alignment: .leading, spacing: 0) {
            if first == nil {
                Text("已安装的应用暂未申请权限").font(LKFont.ui(LKType.small)).foregroundStyle(p.mutedFg)
            }
            if !luoke.isEmpty || !system.isEmpty {
                section("系统", first: first)
                LKGroup {
                    ForEach(Array(luoke.enumerated()), id: \.element.id) { i, g in
                        luokeRow(g).lkRow(first: i == 0)
                        ForEach(g.rows.filter { $0.kind == "system" }) { r in hostUseRow(r).lkRow(first: false) }
                    }
                    ForEach(Array(system.enumerated()), id: \.element.id) { i, r in
                        appRow(r) { buttons(r, emphasize: r.state != "granted") }.lkRow(first: i == 0 && luoke.isEmpty)
                    }
                }
            }
            if !accounts.isEmpty {
                section("账号", first: first)
                LKGroup {
                    ForEach(Array(accounts.enumerated()), id: \.element.id) { i, r in
                        appRow(r) { buttons(r, emphasize: false) }.lkRow(first: i == 0)
                    }
                }
            }
            if !each.isEmpty {
                section("每次询问", first: first)
                LKGroup {
                    ForEach(Array(each.enumerated()), id: \.element.id) { i, r in
                        let why = r.facts.isEmpty ? "每次需手动确认" : r.facts.joined(separator: "；")
                        HStack(spacing: 12) {
                            AppIcon(tool: r.tool, size: 28)
                            Text(r.title)
                            Spacer()
                            LKIcon("lock").foregroundStyle(p.mutedFg).help(why).accessibilityLabel(why)
                        }
                        .lkRow(first: i == 0)
                    }
                }
            }
        }
    }

    @ViewBuilder private func section(_ title: String, first: String?) -> some View {
        if title == first { LKSection(title: title).padding(.top, -LKSpace.x7) } else { LKSection(title: title) }
    }

    /// 螺壳名下的一项：螺壳的图标，写哪些应用在用（各自看什么在申请的说明里）
    private func luokeRow(_ g: LuokePermission) -> some View {
        let users = g.rows.filter(model.hostPermissionOn).reduce(into: [String]()) { out, r in
            if !out.contains(r.tool.name) { out.append(r.tool.name) }
        }
        let (light, label) = Self.light("system", g.state, needed: g.rows.contains { model.isNeeded($0) })
        return HStack(spacing: 12) {
            AppIcon(tool: .core, size: 28)
            VStack(alignment: .leading, spacing: 1) {
                Text(g.title)
                Text(users.isEmpty ? "暂无应用使用" : "\(users.joined(separator: "、")) 使用中")
                    .font(LKFont.ui(LKType.small)).foregroundStyle(p.mutedFg)
            }
            Spacer()
            LKLight(state: light, label: label).help(label)
            ForEach(g.can, id: \.self) { op in
                if let r = g.rows.first(where: { $0.can?.contains(op) == true }) { button(op, r, emphasize: g.state != "granted") }
            }
        }
    }

    /// 螺壳名下的一项，这个应用用不用。关了只是用户和螺壳的约定：字上不说系统拦着它
    private func hostUseRow(_ r: AgentPermission) -> some View {
        let on = model.hostPermissionOn(r)
        return HStack(spacing: 12) {
            AppIcon(tool: r.tool, size: 20)
            VStack(alignment: .leading, spacing: 1) {
                Text(r.tool.name)
                if !on {
                    Text(Self.hostOffText).font(LKFont.ui(LKType.small)).foregroundStyle(p.mutedFg)
                }
            }
            Spacer()
            Text("允许").font(LKFont.ui(LKType.small)).foregroundStyle(p.mutedFg).accessibilityHidden(true)
            LKSwitch(on: Binding(get: { on }, set: { model.setHostPermission(r, on: $0) }), label: "允许\(r.tool.name)使用\(r.title)")
        }
        .padding(.leading, 40)      // 和上面螺壳那一行的字对齐
    }

    static let hostOffText = "未允许"

    /// 应用名下的一项（系统权限、账号）
    private func appRow<B: View>(_ r: AgentPermission, @ViewBuilder buttons: () -> B) -> some View {
        let (light, label) = Self.light(r.kind, r.state, needed: model.isNeeded(r))
        return HStack(spacing: 12) {
            AppIcon(tool: r.tool, size: 28)
            Text(r.title)
            Spacer()
            LKLight(state: light, label: label).help(label)
            buttons()
        }
    }

    @ViewBuilder private func buttons(_ r: AgentPermission, emphasize: Bool) -> some View {
        ForEach(r.can ?? [], id: \.self) { op in button(op, r, emphasize: emphasize) }
    }

    /// 一个操作一个按钮；on、off 是开关，不在这里
    @ViewBuilder private func button(_ op: String, _ r: AgentPermission, emphasize: Bool) -> some View {
        let busy = model.permissionPending[r.id] != nil
        switch op {
        case "settings":
            // 一行一个、几行都缺时一屏好几个实底的品牌色（界面规范 §2：一屏两三处）：都画次要按钮，缺的那行写着「没允许」
            Button { model.permissionAction(r, op) } label: { IconText("打开系统设置", symbol: "settings") }
                .buttonStyle(LKButtonStyle(kind: .secondary)).disabled(busy)
        case "request":
            Button("允许") { model.permissionAction(r, op) }.buttonStyle(LKButtonStyle(kind: .primary)).disabled(busy)
        case "open":
            Button { model.permissionAction(r, op) } label: { IconText("打开", symbol: "square-arrow-out-up-right") }
                .buttonStyle(LKButtonStyle()).disabled(busy)
        case "remove":
            Button("移除") { model.permissionAction(r, op) }.buttonStyle(LKButtonStyle(kind: .text)).disabled(busy)
        default:
            EmptyView()
        }
    }

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
}
