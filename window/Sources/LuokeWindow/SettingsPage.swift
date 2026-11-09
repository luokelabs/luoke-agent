import SwiftUI

struct SettingsPage: View {
    @ObservedObject var model: WindowModel
    @Environment(\.lk) private var p

    var body: some View {
        PageScroll(padding: LKInsets.column, maxWidth: 700) {
            PageHeader(title: "设置").lkEnter(0)
            LKTabs(tabs: PrefsTab.allCases.map { LKTabs.Tab(id: $0.rawValue, title: $0.title, external: model.prefsTabOpensElsewhere($0)) },
                   selected: model.prefsTab.rawValue) {
                model.selectPrefsTab(PrefsTab(rawValue: $0.id) ?? .alerts)
            }
            .lkEnter(1)
            Group {
                switch model.prefsTab {
                case .alerts: alerts
                case .display: DisplayTab(model: model)
                case .permissions:
                    if model.agentPermissions != nil { AgentPermissionsTab(model: model) } else { permissions }
                case .model: modelTab
                case .privacy: privacy
                }
            }
            .lkEnter(2)
        }
    }

    // MARK: 提醒

    private var alerts: some View {
        VStack(alignment: .leading, spacing: 0) {
            LKGroup {
                HStack(spacing: 12) {
                    Image(systemName: "bell").foregroundStyle(p.mutedFg).frame(width: 18)
                    Text("主动提醒")
                    Spacer()
                    LKSwitch(on: Binding(get: { model.alertsOn }, set: { model.setAlerts($0) }), label: "主动提醒")
                }
                .lkRow(first: true)
            }
            VStack(alignment: .leading, spacing: 0) {
                LKGroup {
                    HStack(spacing: 12) {
                        Image(systemName: "square.stack").foregroundStyle(p.mutedFg).frame(width: 18)
                        Text("简报")
                        Spacer()
                        LKSelect(value: model.brief.rawValue, options: BriefMode.allCases.map(\.rawValue)) {
                            model.setBrief(BriefMode(rawValue: $0) ?? .morning)
                        }
                    }
                    .lkRow(first: true)
                    BriefPreview(note: model.makeBrief(time: "08:00"))
                        .padding(.horizontal, LKSpace.x4)
                        .padding(.bottom, LKSpace.x3)
                    HStack(spacing: 12) {
                        Image(systemName: "moon").foregroundStyle(p.mutedFg).frame(width: 18)
                        Text("免打扰")
                        Spacer()
                        LKSelect(value: model.quietHours, options: model.quietOptions) { model.setQuiet($0) }
                    }
                    .lkRow(first: false)
                }
                .padding(.top, LKSpace.x3)
                LKSection(title: "每类事")
                LKGroup {
                    ForEach(Array(model.kinds.enumerated()), id: \.element.id) { i, k in
                        HStack(spacing: 12) {
                            AppIcon(tool: k.tool)
                            Text(k.title)
                            Spacer()
                            LKSegmented(options: Level.allCases.map { .init(value: $0, title: $0.title, symbol: $0.symbol) },
                                        value: Binding(get: { k.level }, set: { model.setLevel(k.id, $0) }))
                        }
                        .lkRow(first: i == 0)
                    }
                }
                Text("系统通知只给「当场说」的；Dock 图标不带数字。")
                    .font(LKFont.ui(LKType.caption)).foregroundStyle(p.mutedFg).padding(.top, LKSpace.x3)
            }
            .opacity(model.alertsOn ? 1 : 0.45)
            .allowsHitTesting(model.alertsOn)
        }
    }

    // MARK: 权限

    private var permissions: some View {
        VStack(alignment: .leading, spacing: 0) {
            LKSection(title: "系统").padding(.top, -LKSpace.x7)
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
                            LKLight(state: .warn, label: "等你允许")
                            Button("允许") { model.requestPermission(r.id) }.buttonStyle(LKButtonStyle(kind: .primary))
                        case .notYet:
                            LKLight(state: .off, label: "先不用")
                            Button("允许") { model.requestPermission(r.id) }.buttonStyle(LKButtonStyle())
                        }
                    }
                    .lkRow(first: i == 0)
                }
            }
            LKSection(title: "账号")
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
            LKSection(title: "代你做")
            LKGroup {
                ForEach(Array(model.delegates.enumerated()), id: \.element.id) { i, d in
                    HStack(spacing: 12) {
                        AppIcon(tool: d.tool, size: 28)
                        Text(d.title)
                        Spacer()
                        LKSwitch(on: Binding(get: { d.on }, set: { model.setDelegate(d.id, on: $0) }), label: d.title)
                    }
                    .lkRow(first: i == 0)
                }
            }
            LKSection(title: "每次都问")
            LKGroup {
                ForEach(Array(model.eachTime.enumerated()), id: \.element.id) { i, e in
                    HStack(spacing: 12) {
                        AppIcon(tool: e.tool, size: 28)
                        Text(e.title)
                        Spacer()
                        Image(systemName: "lock").foregroundStyle(p.mutedFg).help(e.why).accessibilityLabel(e.why)
                    }
                    .lkRow(first: i == 0)
                }
            }
        }
    }

    // MARK: 模型

    private var modelTab: some View {
        VStack(alignment: .leading, spacing: LKSpace.x3) {
            VStack(spacing: LKSpace.x1) {
                ForEach(model.tiers) { t in
                    let on = t.id == model.currentTier
                    Button { model.setTier(t.id) } label: {
                        HStack(spacing: 12) {
                            Circle().strokeBorder(on ? p.primary : p.input, lineWidth: 1).frame(width: 16, height: 16)
                                .overlay(Circle().fill(p.primary).padding(3).opacity(on ? 1 : 0))
                            VStack(alignment: .leading, spacing: 1) {
                                Text(t.title).font(LKFont.ui(LKType.body, .medium))
                                Text(t.model).font(LKFont.mono(LKType.caption)).foregroundStyle(p.mutedFg)
                            }
                            Spacer()
                            if on { LKBadge(text: "", symbol: "checkmark") }
                            Text(t.size).font(LKFont.ui(LKType.caption)).foregroundStyle(p.mutedFg)
                        }
                        .padding(.horizontal, LKSpace.x3).padding(.vertical, LKSpace.x3)
                        .background(RoundedRectangle(cornerRadius: LKRadius.control, style: .continuous).fill(on ? p.selection : .clear))
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(on ? .isSelected : [])
                }
            }
            .padding(LKSpace.x2)
            .background(CardSurface())
            LKGroup {
                HStack(spacing: 12) {
                    Image(systemName: "cpu").foregroundStyle(p.mutedFg).frame(width: 18)
                    Text("引擎")
                    Spacer()
                    Text(model.engineVersion).font(LKFont.mono(LKType.caption)).foregroundStyle(p.mutedFg)
                    LKLight(state: model.engineReady ? .ok : .warn, label: "就绪 · 今天试跑通过")
                }
                .lkRow(first: true)
                HStack(spacing: 12) {
                    Image(systemName: "slider.horizontal.3").foregroundStyle(p.mutedFg).frame(width: 18)
                    Text("能耗")
                    Spacer()
                    LKSegmented(options: Energy.allCases.map { .init(value: $0, title: $0.rawValue, symbol: nil) },
                                value: Binding(get: { model.energy }, set: { model.energy = $0 }))
                }
                .lkRow(first: false)
                HStack(spacing: 12) {
                    Image(systemName: "internaldrive").foregroundStyle(p.mutedFg).frame(width: 18)
                    Text("用电池时也在后台跑")
                    Spacer()
                    LKSwitch(on: Binding(get: { model.onBattery }, set: { model.onBattery = $0 }), label: "用电池时也在后台跑")
                }
                .lkRow(first: false)
            }
        }
    }

    // MARK: 隐私

    private var privacy: some View {
        LKGroup {
            HStack(spacing: 12) {
                Image(systemName: "lock").foregroundStyle(p.mutedFg).frame(width: 18)
                Text("数据只在这台 Mac 上")
                Spacer()
                LKLight(state: .ok, label: "没有云端")
            }
            .lkRow(first: true)
            privacyRow("brain", "记忆", "打开") { model.go(.mem) }
            privacyRow("arrow.down.circle", "诊断信息", "导出") { model.show("诊断信息存到了下载文件夹") }
            privacyRow("trash", "卸载螺壳", "卸载") { model.show("会先问你要不要连数据一起删") }
        }
    }

    private func privacyRow(_ symbol: String, _ title: String, _ button: String, action: @escaping () -> Void) -> some View {
        HStack(spacing: 12) {
            Image(systemName: symbol).foregroundStyle(p.mutedFg).frame(width: 18)
            Text(title)
            Spacer()
            Button(button, action: action).buttonStyle(LKButtonStyle())
        }
        .lkRow(first: false)
    }
}

/// 接上核心时的「设置 · 权限」（docs/界面接口.md §10）：螺壳名下的和各应用的系统权限、账号、代你做、每次都问。
/// 按钮只照每一行的 `can` 出，点了才交给核心（`POST /permissions`）；每次都问的只列出来，没有按钮。
struct AgentPermissionsTab: View {
    @ObservedObject var model: WindowModel
    @Environment(\.lk) private var p

    var body: some View {
        let luoke = model.luokePermissions
        let system = model.agentPermissionRows("system")
        let accounts = model.agentPermissionRows("account")
        let delegates = model.agentPermissionRows("delegate")
        let each = model.agentPermissionRows("each-time")
        let first = [("系统", !luoke.isEmpty || !system.isEmpty), ("账号", !accounts.isEmpty), ("代你做", !delegates.isEmpty),
                     ("每次都问", !each.isEmpty)].first { $0.1 }?.0
        VStack(alignment: .leading, spacing: 0) {
            if first == nil {
                Text("装好的应用还没有要权限的。").font(LKFont.ui(LKType.small)).foregroundStyle(p.mutedFg)
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
            if !delegates.isEmpty {
                section("代你做", first: first)
                LKGroup {
                    ForEach(Array(delegates.enumerated()), id: \.element.id) { i, r in
                        HStack(spacing: 12) {
                            AppIcon(tool: r.tool, size: 28)
                            Text(r.title)
                            Spacer()
                            delegateSwitch(r)
                        }
                        .lkRow(first: i == 0)
                    }
                }
            }
            if !each.isEmpty {
                section("每次都问", first: first)
                LKGroup {
                    ForEach(Array(each.enumerated()), id: \.element.id) { i, r in
                        let why = r.facts.isEmpty ? "每次都要你点" : r.facts.joined(separator: "；")
                        HStack(spacing: 12) {
                            AppIcon(tool: r.tool, size: 28)
                            Text(r.title)
                            Spacer()
                            Image(systemName: "lock").foregroundStyle(p.mutedFg).help(why).accessibilityLabel(why)
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
                Text(users.isEmpty ? "现在没有应用在用" : "\(users.joined(separator: "、"))在用")
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
            LKSwitch(on: Binding(get: { on }, set: { model.setHostPermission(r, on: $0) }), label: "让\(r.tool.name)用\(r.title)")
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
            Button { model.permissionAction(r, op) } label: { IconText("打开系统设置", symbol: "gearshape") }
                .buttonStyle(LKButtonStyle(kind: emphasize ? .primary : .secondary)).disabled(busy)
        case "request":
            Button("允许") { model.permissionAction(r, op) }.buttonStyle(LKButtonStyle(kind: .primary)).disabled(busy)
        case "open":
            Button { model.permissionAction(r, op) } label: { IconText("打开", symbol: "arrow.up.right.square") }
                .buttonStyle(LKButtonStyle()).disabled(busy)
        case "remove":
            Button("移除") { model.permissionAction(r, op) }.buttonStyle(LKButtonStyle(kind: .text)).disabled(busy)
        default:
            EmptyView()
        }
    }

    /// 代你做的开关：点了先照点的画，等核心答了再照它的状态
    private func delegateSwitch(_ r: AgentPermission) -> some View {
        let pending = model.permissionPending[r.id]
        let on = pending.map { $0 == "on" } ?? (r.state == "on")
        let enabled = pending == nil && (r.can ?? []).contains(on ? "off" : "on")
        return LKSwitch(on: Binding(get: { on }, set: { model.permissionAction(r, $0 ? "on" : "off") }), label: r.title)
            .disabled(!enabled)
            .opacity(enabled ? 1 : 0.5)
    }

    /// 状态灯：灯的颜色和读屏、悬停时的一句话
    static func light(_ kind: String, _ state: String?, needed: Bool) -> (LKLight.State, String) {
        let account = kind == "account"
        switch state {
        case "granted": return (.ok, account ? "连着" : "已允许")
        case "denied": return account ? (.off, "没连上") : (.warn, "没允许")
        case "ask": return needed ? (.warn, "等你允许") : (.off, account ? "没连上" : "还没允许")
        default: return (.off, "现在不知道")
        }
    }
}

/// 「设置 · 提醒」里简报的样子：通知里那一句
struct BriefPreview: View {
    let note: BriefNote
    @Environment(\.lk) private var p

    var body: some View {
        HStack(alignment: .top, spacing: LKSpace.x3) {
            BrandBadge(size: 28)
            VStack(alignment: .leading, spacing: 2) {
                Text("螺壳 · \(note.title)").font(LKFont.ui(LKType.small, .semibold))
                Text(note.sentence).font(LKFont.ui(LKType.small)).fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(LKSpace.x3)
        .background(RoundedRectangle(cornerRadius: LKRadius.card, style: .continuous).fill(p.bg))
        .overlay(RoundedRectangle(cornerRadius: LKRadius.card, style: .continuous).strokeBorder(p.border, lineWidth: 1))
        .accessibilityElement(children: .combine)
        .accessibilityLabel("简报的样子：\(note.sentence)")
    }
}

/// 「设置 · 显示」：「今天」的密度，标准还是紧凑；只记在这个窗口里
struct DisplayTab: View {
    @ObservedObject var model: WindowModel
    @Environment(\.lk) private var p
    @Environment(\.accessibilityReduceMotion) private var reduce

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            LKGroup {
                VStack(alignment: .leading, spacing: 0) {
                    HStack(spacing: LKSpace.x3) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("「今天」的密度")
                            Text("紧凑：一张表，一屏放得下更多").font(LKFont.ui(LKType.caption)).foregroundStyle(p.mutedFg)
                        }
                        Spacer()
                        LKSegmented(options: Density.allCases.map { .init(value: $0, title: $0.title, symbol: nil) },
                                    value: Binding(get: { model.density }, set: { model.setDensity($0) }), segmentWidth: 56)
                            .accessibilityLabel("密度")
                    }
                    .frame(minHeight: 52)
                    .padding(.top, LKSpace.x2)
                    DensityPreview(model: model)
                        .id(model.density)
                        .transition(.opacity.animation(Motion.enter(0.22, delay: 0.08, reduce: reduce)))
                        .padding(.bottom, LKSpace.x4)
                }
                .padding(.horizontal, LKSpace.x4)
            }
        }
    }
}

/// 密度的小样：标准是一张卡片的样子，紧凑是三行
struct DensityPreview: View {
    @ObservedObject var model: WindowModel
    @Environment(\.lk) private var p

    var body: some View {
        let cards = Array(model.cards.prefix(3))
        Group {
            if model.density == .compact {
                VStack(spacing: 0) {
                    ForEach(Array(cards.enumerated()), id: \.element.id) { i, c in
                        HStack(spacing: LKSpace.x2) {
                            AppIcon(tool: c.tool, size: 16)
                            Text(c.displayTitle).lineLimit(1)
                            Spacer(minLength: 0)
                            Text(c.time ?? "").foregroundStyle(p.mutedFg).monospacedDigit()
                        }
                        .font(LKFont.ui(LKType.caption))
                        .padding(.horizontal, LKSpace.x3)
                        .frame(height: 26)
                        .overlay(alignment: .top) { if i > 0 { Rectangle().fill(p.border).frame(height: 1) } }
                    }
                }
            } else if let c = cards.first {
                let d = SurfaceDigest(c.surface.surface)
                VStack(alignment: .leading, spacing: LKSpace.x1 + 2) {
                    HStack(spacing: LKSpace.x2) {
                        AppIcon(tool: c.tool, size: 16)
                        Text(c.displayTitle).font(LKFont.ui(LKType.caption, .semibold)).lineLimit(1)
                        Spacer(minLength: 0)
                        Text(c.time ?? "").font(LKFont.ui(LKType.caption)).foregroundStyle(p.mutedFg).monospacedDigit()
                    }
                    if !d.detail.isEmpty {
                        Text(d.detail).font(LKFont.ui(LKType.caption)).foregroundStyle(p.mutedFg).lineLimit(1).padding(.leading, LKSpace.x6)
                    }
                    if let a = d.primary {
                        Text(a.label).font(LKFont.ui(LKType.caption, .medium)).foregroundStyle(p.primaryFg)
                            .padding(.horizontal, LKSpace.x2).frame(height: 22)
                            .background(RoundedRectangle(cornerRadius: LKRadius.small, style: .continuous).fill(p.primary))
                            .padding(.leading, LKSpace.x6)
                    }
                }
                .padding(LKSpace.x3)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: LKRadius.control, style: .continuous).fill(p.bg))
        .overlay(RoundedRectangle(cornerRadius: LKRadius.control, style: .continuous).strokeBorder(p.border, lineWidth: 1))
        .clipShape(RoundedRectangle(cornerRadius: LKRadius.control, style: .continuous))
        .accessibilityHidden(true)
    }
}
