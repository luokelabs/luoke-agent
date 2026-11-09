import LuokeA2UI
import SwiftUI

/// 「活动」：时间线。左边是时间（右对齐），一条竖线上的点（急事红、刚做的用强调色），应用图标、做了什么、撤销；按天分组
struct ActivityPage: View {
    @ObservedObject var model: WindowModel
    @Environment(\.lk) private var p

    var body: some View {
        PageScroll(padding: LKInsets.column, maxWidth: 700) {
            PageHeader(title: "活动", note: "螺壳替你做过的事").lkEnter(0)
            let rows = model.activity
            ForEach(Array(days(rows).enumerated()), id: \.element) { i, day in
                VStack(alignment: .leading, spacing: LKSpace.x1 + 2) {
                    Text(day).font(LKFont.ui(LKType.small, .semibold)).foregroundStyle(p.mutedFg)
                        .padding(.leading, ActivityLine.railX + LKSpace.x3)
                        .accessibilityAddTraits(.isHeader)
                    VStack(spacing: 0) {
                        ForEach(rows.filter { $0.day == day }) { r in ActivityLine(row: r, model: model) }
                    }
                    .background(alignment: .topLeading) {
                        Rectangle().fill(p.border).frame(width: 1)
                            .padding(.vertical, LKSpace.x3)
                            .lkRailDraw()
                            .offset(x: ActivityLine.railX - 0.5)
                            .accessibilityHidden(true)
                    }
                }
                .padding(.top, LKSpace.x5)
                .lkEnter(1 + i)
            }
        }
    }
}

/// 按出现的先后列出有哪几天
func days(_ rows: [ActivityRow]) -> [String] {
    var out: [String] = []
    for r in rows where !out.contains(r.day) { out.append(r.day) }
    return out
}

/// 时间线上的一件
struct ActivityLine: View {
    let row: ActivityRow
    @ObservedObject var model: WindowModel
    @Environment(\.lk) private var p

    /// 时间那一列多宽
    static let timeWidth: CGFloat = 56
    /// 点那一列多宽
    static let dotWidth: CGFloat = 16
    /// 竖线在哪（点的正中）
    static var railX: CGFloat { timeWidth + LKSpace.x3 + dotWidth / 2 }

    var body: some View {
        HStack(spacing: LKSpace.x3) {
            Text(row.time).font(LKFont.ui(LKType.caption)).foregroundStyle(p.mutedFg).monospacedDigit()
                .frame(width: Self.timeWidth, alignment: .trailing)
            Circle().fill(dot).frame(width: 7, height: 7)
                .background(Circle().fill(p.bg).frame(width: 13, height: 13))
                .frame(width: Self.dotWidth)
                .accessibilityHidden(true)
            AppIcon(tool: row.tool, size: 20)
            Text(row.text).lineLimit(1)
                .strikethrough(row.undone)
                .foregroundStyle(row.mark == .new && !row.undone ? p.fg : p.mutedFg)
            Spacer(minLength: LKSpace.x2)
            if let label = row.undoLabel {
                Button(label) { model.undoActivity(row.id) }.buttonStyle(LKButtonStyle(kind: .undo)).disabled(row.undone)
            }
        }
        .frame(minHeight: 40)
        .help(row.auto ? "自动做的" : "你点的")
        .accessibilityElement(children: .combine)
    }

    private var dot: Color {
        switch row.mark {
        case .urgent: return p.danger
        case .new: return p.brandText
        case .plain: return p.mutedFg
        }
    }
}

/// 应用的基础页（mail、scan、mem、searchApp）。接上核心时内容由工具出（`service.pages`，A2UI），框还是这个；没接时用示例。
struct AppPage: View {
    @ObservedObject var model: WindowModel
    let page: Page
    @Environment(\.lk) private var p

    var body: some View {
        let entry = model.apps.first { $0.id == page }
        let tool = entry?.tool ?? page.appTool ?? .core
        let agent = model.agentApp(for: page)
        let data = agent == nil ? model.appPages[page] : nil
        PageScroll {
            HStack(spacing: 14) {
                AppIcon(tool: tool, size: 40)
                VStack(alignment: .leading, spacing: 2) {
                    Text(tool.name).font(LKFont.ui(LKType.title, .semibold)).accessibilityAddTraits(.isHeader)
                    HStack(spacing: 6) {
                        Text(entry?.version ?? "").font(LKFont.mono(LKType.caption)).foregroundStyle(p.mutedFg)
                        if let agent {
                            LKLight(state: agent.running ? .ok : .off, label: agent.running ? "在运行" : "没在运行")
                                .help(agent.running ? "在运行" : "没在运行")
                            Text(agent.running ? (agent.summary?.text ?? "") : "没在运行")
                                .font(LKFont.ui(LKType.caption)).foregroundStyle(p.mutedFg).lineLimit(1)
                        } else {
                            LKLight(state: .ok, label: "在运行")
                        }
                    }
                }
                Spacer()
                if let agent {
                    if agent.hasUI {
                        Button { model.openAppUI() } label: { IconText("打开完整界面", symbol: "arrow.up.right.square") }
                            .buttonStyle(LKButtonStyle())
                    }
                } else if let data, data.hasUI {   // 有自己界面的应用才有（扫描没有）
                    Button { model.show("这里会打开\(tool.name)自己的窗口") } label: { IconText("打开完整界面", symbol: "arrow.up.right.square") }
                        .buttonStyle(LKButtonStyle())
                }
            }
            .padding(.bottom, 18)
            if let agent {
                AgentAppBody(model: model, app: agent, entry: entry)
            } else if data == nil, model.agentApps != nil {
                Text("\(tool.name)还没接上螺壳。").font(LKFont.ui(LKType.small)).foregroundStyle(p.mutedFg)
            }
            if let data {
                LKTabs(tabs: data.tabs.map { LKTabs.Tab(id: $0.id, title: $0.title, external: $0.external) }, selected: model.appTab) { t in
                    if t.external { model.show("这里会打开\(tool.name)自己的窗口") } else { model.selectAppTab(t.id) }
                }
                if model.appTab == "overview" {
                    HStack(spacing: 10) {
                        ForEach(data.stats, id: \.key) { s in
                            VStack(alignment: .leading, spacing: 2) {
                                Text(s.key).font(LKFont.ui(LKType.small)).foregroundStyle(p.mutedFg)
                                Text(s.value).font(LKFont.ui(LKType.title, .semibold)).monospacedDigit()
                            }
                            .lkCard()
                        }
                    }
                    LKSection(title: data.listTitle, count: data.lines.count)
                    LKGroup {
                        ForEach(Array(data.lines.enumerated()), id: \.element.id) { i, l in
                            HStack(spacing: 12) {
                                Text(l.title)
                                Spacer()
                                if let b = l.badge { LKBadge(text: b, symbol: "calendar", kind: .brand) }
                                if let m = l.meta { Text(m).monospacedDigit() }
                                if let a = l.action {
                                    Button { model.show("这里会打开\(tool.name)自己的窗口") } label: { IconText(a, symbol: a == "起草" ? "pencil" : nil) }
                                        .buttonStyle(LKButtonStyle())
                                    if let a2 = l.action2 {
                                        Button(a2) { model.show("这里会打开\(tool.name)自己的窗口") }.buttonStyle(LKButtonStyle())
                                    }
                                } else {
                                    Image(systemName: "chevron.right").font(.system(size: 11, weight: .semibold)).foregroundStyle(p.mutedFg)
                                }
                            }
                            .lkRow(first: i == 0)
                        }
                    }
                    ThisAppSection(model: model, entry: entry, tool: tool)
                } else {
                    LKGroup {
                        let rows = model.activity.filter { $0.tool == tool }
                        ForEach(Array(rows.enumerated()), id: \.element.id) { i, r in ActivityLine(row: r, model: model).lkRow(first: i == 0) }
                    }
                }
            }
        }
    }
}

/// 接上核心时应用页的内容：缺的权限、页的标签（窗口里画的 `pages`，带外链箭头的是工具自己界面里的 `ui.pages`）、
/// 那一页的 A2UI（按钮照卡片走 `/action`）；第一页下面是「这个应用」。
struct AgentAppBody: View {
    @ObservedObject var model: WindowModel
    let app: AgentApp
    let entry: AppEntry?
    @Environment(\.lk) private var p

    var body: some View {
        let tab = model.agentTab(app)
        if !app.needs.isEmpty {
            Button { model.go(.prefs, tab: PrefsTab.permissions.rawValue) } label: {
                HStack(spacing: 12) {
                    Image(systemName: "lock").foregroundStyle(p.warning).frame(width: 18)
                    Text("需要你允许：\(model.needsText(app))")
                    Spacer()
                    Image(systemName: "chevron.right").font(.system(size: 11, weight: .semibold)).foregroundStyle(p.mutedFg)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .lkCard(padding: EdgeInsets(top: 11, leading: 14, bottom: 11, trailing: 14))
            .padding(.bottom, 16)
            .accessibilityLabel("需要你允许：\(model.needsText(app))，去设置 · 权限")
        }
        let tabs = app.pages.map { LKTabs.Tab(id: $0.id, title: $0.title) }
            + (app.uiPages ?? []).map { LKTabs.Tab(id: $0.id, title: $0.title, external: true) }
        if tabs.count > 1 || !(app.uiPages ?? []).isEmpty {
            LKTabs(tabs: tabs, selected: tab ?? "") { t in
                if t.external { model.openAppUI(page: t.id) } else { model.selectAppTab(t.id) }
            }
        }
        if let tab {
            let sid = AgentFeed.pageKey(app.id, tab)
            if let s = model.agentPages[sid]?.surface {
                SurfaceView(model: s) { cid, _, ctx in model.tapSurface(sid, componentId: cid, context: ctx) }
                    .lkCard()
            } else {
                Text(model.agentPages[sid]?.error ?? "正在取这一页…").font(LKFont.ui(LKType.small)).foregroundStyle(p.mutedFg)
                    .lkCard()
            }
        }
        if tab == nil || tab == app.pages.first?.id {
            ThisAppSection(model: model, entry: entry, tool: app.tool, needs: app.needs.isEmpty ? nil : model.needsText(app))
        }
    }
}

/// 应用页最下面的「这个应用」：提醒、权限（进设置）、版本（升级归主控）
struct ThisAppSection: View {
    @ObservedObject var model: WindowModel
    let entry: AppEntry?
    let tool: ToolIcon
    /// 接上核心时：还缺的权限（权限一行亮黄灯）
    var needs: String? = nil
    @Environment(\.lk) private var p

    var body: some View {
        LKSection(title: "这个应用")
        LKGroup {
            settingLine("bell", "提醒", first: true) {
                HStack(spacing: 4) { Image(systemName: "bell.badge"); Image(systemName: "square.stack") }
                    .font(.system(size: 12)).foregroundStyle(p.mutedFg)
            } action: { model.go(.prefs, tab: PrefsTab.alerts.rawValue) }
            settingLine("key", "权限", first: false) {
                if let needs { LKLight(state: .warn, label: "等你允许：\(needs)").help("等你允许：\(needs)") }
            } action: { model.go(.prefs, tab: PrefsTab.permissions.rawValue) }
            HStack(spacing: 12) {
                Image(systemName: "shippingbox").foregroundStyle(p.mutedFg).frame(width: 18)
                Text("版本")
                Spacer()
                if let up = entry?.update {
                    Text("\(entry?.version ?? "") → \(up)").font(LKFont.mono(LKType.caption)).foregroundStyle(p.mutedFg)
                    Button("升级") { model.upgrade(tool) }.buttonStyle(LKButtonStyle(kind: .primary))
                } else {
                    Text(entry?.version ?? "").font(LKFont.mono(LKType.caption)).foregroundStyle(p.mutedFg)
                    Image(systemName: "checkmark.circle").foregroundStyle(p.success).accessibilityLabel("已是最新")
                }
            }
            .lkRow(first: false)
        }
    }

    private func settingLine<T: View>(_ symbol: String, _ title: String, first: Bool, @ViewBuilder trailing: () -> T,
                                      action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: symbol).foregroundStyle(p.mutedFg).frame(width: 18)
                Text(title)
                Spacer()
                trailing()
                Image(systemName: "chevron.right").font(.system(size: 11, weight: .semibold)).foregroundStyle(p.mutedFg)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .lkRow(first: first)
    }
}

/// 搜索结果：按来源分段，不经模型
struct SearchPage: View {
    @ObservedObject var model: WindowModel
    @Environment(\.lk) private var p

    var body: some View {
        PageScroll {
            PageHeader(title: "搜索") {
                HStack(spacing: 6) {
                    Image(systemName: "magnifyingglass").foregroundStyle(p.mutedFg)
                    Text(model.searchQuery)
                }
                .font(LKFont.ui(LKType.small))
                .padding(.horizontal, 10).frame(height: 30)
                .background(RoundedRectangle(cornerRadius: LKRadius.control, style: .continuous).fill(p.card))
                .overlay(RoundedRectangle(cornerRadius: LKRadius.control, style: .continuous).strokeBorder(p.input, lineWidth: 1))
            }
            HStack(spacing: 6) {
                LKChip(on: model.searchFilter == "all", action: { model.searchFilter = "all" }) { Text("全部") }
                LKChip(on: model.searchFilter == "files", action: { model.searchFilter = "files" }) { AppIcon(tool: .search); Text("文件") }
                LKChip(on: model.searchFilter == "photos", action: { model.searchFilter = "photos" }) { AppIcon(tool: .search); Text("照片和视频") }
                LKChip(on: model.searchFilter == "mail", action: { model.searchFilter = "mail" }) { AppIcon(tool: .mail); Text("me@example.com") }
            }
            .padding(.bottom, 4)
            ForEach(model.searchSections.filter { model.searchFilter == "all" || $0.id == model.searchFilter }) { s in
                LKSection(title: s.title, count: s.count)
                if let perm = s.needsPermission {
                    HStack(spacing: 12) {
                        Image(systemName: "lock").foregroundStyle(p.mutedFg)
                        VStack(alignment: .leading, spacing: 1) {
                            Text("照片还没允许搜")
                            Text("允许以后，照片里的文字和场景也能搜到").font(LKFont.ui(LKType.small)).foregroundStyle(p.mutedFg)
                        }
                        Spacer()
                        Button("允许") { model.requestPermission(perm) }.buttonStyle(LKButtonStyle())
                    }
                    .lkCard(padding: EdgeInsets(top: 11, leading: 14, bottom: 11, trailing: 14))
                } else {
                    LKGroup {
                        ForEach(Array(s.hits.enumerated()), id: \.element.id) { i, h in
                            HStack(alignment: .top, spacing: 12) {
                                AppIcon(tool: h.tool)
                                VStack(alignment: .leading, spacing: 2) {
                                    HStack(spacing: 8) {
                                        Text(h.title)
                                        Text(h.meta).font(LKFont.ui(LKType.caption)).foregroundStyle(p.mutedFg)
                                    }
                                    Text(h.snippet).font(LKFont.ui(LKType.small)).foregroundStyle(p.mutedFg).lineLimit(1)
                                }
                                Spacer()
                                Button("打开") { model.show("用它的默认程序打开（只在你点了以后）") }.buttonStyle(LKButtonStyle())
                                if h.reveal {
                                    Button { model.show("在访达中显示") } label: { Image(systemName: "folder") }
                                        .buttonStyle(LKButtonStyle()).accessibilityLabel("在访达中显示")
                                }
                                if h.similar {
                                    Button("找相似的") { model.show("找相似的：新结果画在这一条下面") }.buttonStyle(LKButtonStyle(kind: .text))
                                }
                            }
                            .lkRow(first: i == 0)
                        }
                    }
                }
            }
        }
    }
}

/// 添加应用：螺壳挑好、签过名的应用。装、升级归主控。
struct AddAppsPage: View {
    @ObservedObject var model: WindowModel
    @Environment(\.lk) private var p

    var body: some View {
        PageScroll {
            PageHeader(title: "应用")
            section("有更新") { if case .update = $0.state { return true }; return false }
            section("可以装") { $0.state == .installable }
            section("装好了") { $0.state == .installed }
        }
    }

    @ViewBuilder private func section(_ title: String, _ match: @escaping (CatalogApp) -> Bool) -> some View {
        let items = model.catalog.filter(match)
        if !items.isEmpty {
            LKSection(title: title, count: items.count)
            LazyVGrid(columns: [GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10)], alignment: .leading, spacing: 10) {
                ForEach(items) { a in tile(a) }
            }
        }
    }

    private func tile(_ a: CatalogApp) -> some View {
        HStack(alignment: .top, spacing: 12) {
            AppIcon(tool: a.tool, size: 28)
            VStack(alignment: .leading, spacing: 4) {
                Text(a.tool.name).font(LKFont.ui(LKType.body, .medium))
                Text(a.tagline).font(LKFont.ui(LKType.small)).foregroundStyle(p.mutedFg)
                if a.state == .installed || a.facts.isEmpty {
                    Text(a.version).font(LKFont.mono(LKType.caption)).foregroundStyle(p.mutedFg)
                } else {
                    Wrap { ForEach(a.facts, id: \.self) { LKBadge(text: $0).fixedSize() } }
                }
            }
            Spacer(minLength: 0)
            switch a.state {
            case .update: Button("升级") { model.upgrade(a.tool) }.buttonStyle(LKButtonStyle(kind: .primary))
            case .installable:
                Button { model.show("装\(a.tool.name)：下载、核对签名、装好、本机试跑") } label: { IconText("安装", symbol: "arrow.down.circle") }
                    .buttonStyle(LKButtonStyle(kind: .primary))
            case .installed: Image(systemName: "checkmark.circle").foregroundStyle(p.success).accessibilityLabel("装好了")
            }
        }
        .lkCard(padding: EdgeInsets(top: 14, leading: 14, bottom: 14, trailing: 14))
    }
}

struct ChatPage: View {
    @ObservedObject var model: WindowModel
    @Environment(\.lk) private var p

    var body: some View {
        PageScroll {
            PageHeader(title: "对话") {
                Button { model.go(.today) } label: { Image(systemName: "xmark") }
                    .buttonStyle(LKButtonStyle(kind: .text)).accessibilityLabel("关上")
            }
            VStack(alignment: .leading, spacing: 14) {
                ForEach(model.chat) { line in
                    if line.mine {
                        HStack {
                            Spacer()
                            Text(line.text).padding(.horizontal, 12).padding(.vertical, 8)
                                .background(UnevenRoundedRectangle(topLeadingRadius: LKRadius.card, bottomLeadingRadius: LKRadius.card, bottomTrailingRadius: LKRadius.small, topTrailingRadius: LKRadius.card).fill(p.muted))
                        }
                    } else {
                        Text(line.text).lkCard(padding: EdgeInsets(top: 12, leading: 14, bottom: 12, trailing: 14))
                    }
                }
            }
            .frame(maxWidth: 640, alignment: .leading)
        }
    }
}
