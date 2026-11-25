import LuokeA2UI
import LuokeA2UICore
import SwiftUI

/// 「活动」：时间线。左边是时间（右对齐），一条竖线上的点（急事红、刚做的用强调色），应用图标、做了什么、撤销；按天分组
struct ActivityPage: View {
    @ObservedObject var model: WindowModel
    @Environment(\.lk) private var p

    var body: some View {
        PageScroll() {
            PageHeader(title: "活动", note: "螺壳已完成的事项").lkEnter(0)
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
        .help(row.auto ? "自动" : "手动")
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

/// 应用的基础页（mail、scan、mem、searchApp、ime）。接上核心时内容由工具出（`service.pages`，A2UI），框还是这个；没接时用示例。
struct AppPage: View {
    @ObservedObject var model: WindowModel
    let page: Page
    @Environment(\.lk) private var p
    @Environment(\.lkLayout) private var layout
    /// 螺壳搜索页：内容区多高、结果上面那一截（标题、搜索框、「待允许」）多高，都是量出来的；结果用满剩下的高
    @State private var height: CGFloat = 640
    @State private var headHeight: CGFloat = 150

    var body: some View {
        let entry = model.apps.first { $0.id == page }
        let tool = entry?.tool ?? page.appTool ?? .core
        let agent = model.agentApp(for: page)
        let data = agent == nil ? model.appPages[page] : nil
        if page == .searchApp, model.searchBarShown, let agent {
            searchPage(tool, agent, entry)
        } else {
        PageScroll(railed: model.hasRail(layout)) {
            titleRow(tool, agent)
            if let agent {
                AgentAppBody(model: model, app: agent, entry: entry)
            } else if data == nil, model.agentApps != nil {
                let gone = model.appAbsence(tool)
                HStack(spacing: 12) {
                    Text(gone.text).font(LKFont.ui(LKType.small)).foregroundStyle(p.mutedFg)
                    Spacer(minLength: 0)
                    if let b = gone.button {
                        Button(b) { model.fixAbsence(tool) }.buttonStyle(LKButtonStyle(kind: gone.fix == .manage ? .secondary : .primary))
                    }
                }
                .lkCard()
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
                                    LKIcon("chevron-right", size: 13).foregroundStyle(p.mutedFg)
                                }
                            }
                            .lkRow(first: i == 0)
                        }
                    }
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

    /// 螺壳搜索页（UX-09）：搜索框在标题下面，外面不套滚动区（结果自己滚，不两层一起滚）。没搜时下面是这一页（最近搜索），
    /// 自己一个滚动区；搜了以后结果在正文里整页画，栏宽放到内容区全宽，高用满剩下的（量出来的，不写死）。
    /// 搜索框一直在同一个位置，换成结果时不重建，框里的字和光标都还在
    @ViewBuilder private func searchPage(_ tool: ToolIcon, _ agent: AgentApp, _ entry: AppEntry?) -> some View {
        let results = model.searchOpen
        let pad = layout == .narrow ? LKInsets.columnNarrow : LKInsets.column
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 0) {
                titleRow(tool, agent)
                SearchField(model: model).padding(.bottom, 14)
                AgentAppBody(model: model, app: agent, entry: entry, showPage: false)    // 只有「待允许」那一行
            }
            .onGeometryChange(for: CGFloat.self, of: { $0.size.height }) { headHeight = $0 }
            if results {
                SearchPanel(model: model, height: max(240, height - headHeight - pad.top - pad.bottom))
            } else {
                PageScroll(padding: EdgeInsets(), maxWidth: nil) {
                    AgentAppBody(model: model, app: agent, entry: entry, showNeeds: false)
                }
            }
        }
        .padding(pad)
        .frame(maxWidth: results ? .infinity : LKColumn.width, alignment: .topLeading)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .onGeometryChange(for: CGFloat.self, of: { $0.size.height }) { height = $0 }
    }

    /// 标题那一行：应用名，出了事才写的一行状态，只有一页时的页头几样和图标
    @ViewBuilder private func titleRow(_ tool: ToolIcon, _ agent: AgentApp?) -> some View {
        HStack(spacing: 14) {
            VStack(alignment: .leading, spacing: 2) {
                Text(tool.name).font(LKFont.ui(LKType.title, .semibold)).accessibilityAddTraits(.isHeader)
                // 走查重画稿：标题下面不写「在运行 · 一句话」；只有出了事（没在运行、连不上螺壳）才写一行
                if agent.map({ !$0.running || !model.coreReachable }) ?? false {
                HStack(spacing: 6) {
                    // 版本号不放标题下面（和模型名一样是技术细节）：在下面「这个应用 › 版本」里
                    if let agent, !model.coreReachable {
                        // 连不上螺壳：不写绿点和这一轮的数（那是上次的），写清楚是连不上
                        LKLight(state: .off, label: WindowModel.offlineShort)
                        Text(WindowModel.offlineShort).font(LKFont.ui(LKType.caption)).foregroundStyle(p.mutedFg)
                        if let t = agent.summary?.text, !t.isEmpty {
                            Text("·").font(LKFont.ui(LKType.caption)).foregroundStyle(p.mutedFg)
                            Text(model.lastSeen.map { "\(model.seenText($0)) 时看到：\(t)" } ?? "上次看到：\(t)").font(LKFont.ui(LKType.caption)).foregroundStyle(p.mutedFg).lineLimit(1)
                        }
                    } else if let agent {
                        // 绿点只管「在运行」，挨着它写出来；这一轮找到了什么用「·」隔开，不让绿色读成「一切正常」
                        LKLight(state: agent.running ? .ok : .off, label: agent.running ? "运行中" : "未运行")
                        Text(agent.running ? "运行中" : "未运行")
                            .font(LKFont.ui(LKType.caption)).foregroundStyle(p.mutedFg)
                        if agent.running, let t = agent.summary?.text, !t.isEmpty {
                            Text("·").font(LKFont.ui(LKType.caption)).foregroundStyle(p.mutedFg)
                            Text(t).font(LKFont.ui(LKType.caption)).foregroundStyle(p.fg).lineLimit(1)
                        }
                    }
                }
                }
            }
            Spacer()
            // §4 headerPlacement：页上写了放在标题那一行的（邮件助手切换邮箱）。有标签栏的应用，它画在标签那一行的右边、
            // 和设置这些图标挨着（负责人 11-17：放在标题旁边不靠右、容易被忽略）；只有一页的应用照旧在标题这一行
            if let agent, AgentAppBody.tabs(agent).count <= 1 {
                AgentAppBody.headerItems(agent, model: model)
            }
            // 只有一页（没有标签栏）时，设置、处理记录这类图标放在标题右边（走查重画稿 · 扫描）
            if let agent, AgentAppBody.tabs(agent).count <= 1 {
                AgentAppBody.pageIcons(agent, model: model)
            }
        }
        .padding(.bottom, 14)
    }
}

/// 接上核心时应用页的内容：缺的权限、页的标签（窗口里画的 `pages`，带外链箭头的是工具自己界面里的 `ui.pages`）、
/// 那一页的 A2UI（按钮照卡片走 `/action`）；第一页下面是「这个应用」。
/// 宽窗口（`WindowModel.hasRail`）：页上工具写了 `"placement": "aside"` 的段和「这个应用」放进侧栏，别的在主栏
struct AgentAppBody: View {
    @ObservedObject var model: WindowModel
    let app: AgentApp
    let entry: AppEntry?
    /// 画不画标签和这一页；螺壳搜索页上「待允许」那一行和这一页分开画（UX-09：搜索框夹在中间）
    var showPage = true
    /// 画不画「待允许」那一行
    var showNeeds = true
    @Environment(\.lk) private var p
    @Environment(\.lkLayout) private var layout

    /// 「待允许」那一行读屏念的：缺什么，点了去哪一页。页名照设置里画出来的标签（权限并进了「隐私与权限」）
    static func needsLabel(_ needs: String) -> String {
        "待允许：\(needs)，前往设置 · \(PrefsTab.permissions.shownTab.title)"
    }

    /// 标签只画窗口里的页（`pages`），同一个编号只画一次（编号撞了 SwiftUI 会把一个标签画两遍）。
    /// 应用自己界面的页（`ui.pages`）不画成标签：窗口不打开应用自己的界面（11-09 定），要用户做的事由应用做成窗口里的页
    /// （负责人 11-08，agent#62）。`ui.pages` 照旧用来核对 `POST /open` 和卡片上「去设置」的 `page`
    /// `hidden` 的页（工具协议 §1a）不画；正看着它时（`agent.open_page` 去的），它临时排在最后、是选中的那个，
    /// 点别的标签就离开，它也不再画
    static func tabs(_ app: AgentApp, current: String? = nil) -> [LKTabs.Tab] {
        var seen = Set<String>()
        let shown = app.pages.filter { !$0.hidden && seen.insert($0.id).inserted }
        let extra = app.pages.first { $0.hidden && $0.id == current && !seen.contains($0.id) }
        return (shown + (extra.map { [$0] } ?? [])).map { LKTabs.Tab(id: $0.id, title: $0.title) }
    }

    /// 隐藏页里带图标的（设置、处理记录）：标签栏右端的图标按钮，点了以弹窗打开
    /// 正看的那一页写了 `"placement": "header"` 的几样（§4 headerPlacement：邮件助手的「全部邮箱 / 工作 / 个人」）
    @MainActor @ViewBuilder
    static func headerItems(_ app: AgentApp, model: WindowModel) -> some View {
        if let tab = model.visibleAppTab, let s = model.agentPages[AgentFeed.pageKey(app.id, tab)]?.surface {
            let sid = AgentFeed.pageKey(app.id, tab)
            ForEach(s.surface.headerItems, id: \.self) { hid in
                SurfaceView(model: s, part: .section(hid, skip: 0)) { cid, _, ctx in model.tapPage(sid, componentId: cid, context: ctx) }
                    .fixedSize()
            }
        }
    }

    static func pageIcons(_ app: AgentApp, model: WindowModel) -> some View {
        HStack(spacing: 6) {
            ForEach(app.pages.filter { $0.hidden && $0.icon != nil }) { pg in
                LKIconButton(symbol: pg.icon ?? "settings", label: pg.title) { model.selectAppTab(pg.id) }
            }
        }
    }

    var body: some View {
        let tab = model.visibleAppTab
        if model.hasRail(layout) {
            RailSplit {
                content(tab, part: .main)
            } rail: {
                if let tab, let s = model.agentPages[AgentFeed.pageKey(app.id, tab)]?.surface, !s.surface.asideSections.isEmpty {
                    let sid = AgentFeed.pageKey(app.id, tab)
                    if let blocks = s.surface.pageBlocks(aside: true) {   // §4 pageSections：侧栏里也一段一张卡片
                        PageSections(model: s, blocks: blocks) { cid, _, ctx in model.tapPage(sid, componentId: cid, context: ctx) }
                            .padding(.bottom, LKSpace.x2)
                    } else {
                        SurfaceView(model: s, part: .aside) { cid, _, ctx in model.tapPage(sid, componentId: cid, context: ctx) }
                            .lkCard()
                            .padding(.bottom, LKSpace.x2)
                    }
                }
            }
        } else {
            content(tab, part: .all)
        }
    }

    /// 缺的权限、标签、这一页（`part`：分两栏时只画主栏的段）
    @ViewBuilder private func content(_ tab: String?, part: SurfacePart) -> some View {
        if showNeeds && !app.needs.isEmpty {
            Button { model.go(.prefs, tab: PrefsTab.permissions.rawValue) } label: {
                HStack(spacing: 12) {
                    LKIcon("lock").foregroundStyle(p.warning).frame(width: 18)
                    Text("待允许：\(model.needsText(app))")
                    Spacer()
                    LKIcon("chevron-right", size: 13).foregroundStyle(p.mutedFg)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plainPointer)
            .lkCard(padding: EdgeInsets(top: 11, leading: 14, bottom: 11, trailing: 14))
            .padding(.bottom, 16)
            .accessibilityLabel(Self.needsLabel(model.needsText(app)))
        }
        let tabs = AgentAppBody.tabs(app)
        if tabs.count > 1 {
            LKLineTabs(tabs: tabs, selected: tab ?? "", onSelect: { t in model.selectAppTab(t.id) }) {
                HStack(spacing: 8) {
                    AgentAppBody.headerItems(app, model: model)
                    AgentAppBody.pageIcons(app, model: model)
                }
            }
        }
        if let tab, showPage {
            let sid = AgentFeed.pageKey(app.id, tab)
            if let s = model.agentPages[sid]?.surface {
                if let blocks = s.surface.pageBlocks(aside: part == .all ? nil : part == .aside) ?? (part == .all ? s.surface.headedBlocks() : nil) {
                    // §4 pageSections：一段一张卡片，不再整页一张
                    PageSections(model: s, blocks: blocks) { cid, _, ctx in model.tapPage(sid, componentId: cid, context: ctx) }
                } else {
                    SurfaceView(model: s, part: part) { cid, _, ctx in model.tapPage(sid, componentId: cid, context: ctx) }
                        .lkCard()
                }
            } else if let err = model.agentPages[sid]?.error {
                // 急事、要你决定的在「今天」里照样有（从 feed 来，不靠这一页）：写出几样，不说成「要处理的都在」
                let urgentN = model.urgent.filter { $0.id.hasPrefix(app.id + "/") }.count
                let decideN = model.cards.filter { $0.id.hasPrefix(app.id + "/") }.count
                let elsewhere = urgentN + decideN == 0 ? nil
                    : decideN == 0 ? "\(urgentN) 件急事在「今天」中"
                    : "相关的 \(urgentN + decideN) 件在「今天」中"
                let offline = model.agentPages[sid]?.offline == true && model.offlineLong
                // 不放「重试」：窗口每 3 秒自己再取（`AgentConnection.retryLater`），取到就换成页面
                let detail = [WindowModel.autoRetrying, elsewhere, offline ? WindowModel.offlineAdvice : nil].compactMap { $0 }
                    .joined(separator: "\n")
                ErrorNote(text: err, detail: detail)
                    .lkCard()
            } else {
                LoadingNote().frame(maxWidth: .infinity, minHeight: 120).lkCard()
            }
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
                Text("急事立即提醒，其余纳入简报")   // 写字：两个小图标看不出意思
                    .font(LKFont.ui(LKType.caption)).foregroundStyle(p.mutedFg)
            } action: { model.go(.prefs, tab: PrefsTab.alerts.rawValue) }
            settingLine("key", "权限", first: false) {
                // 灯后面写出等的是哪一项（只有灯时看不出是什么）；宽窗口的侧栏里放不下就从尾巴省略，完整的在悬停提示里
                if let needs {
                    HStack(spacing: 6) {
                        LKLight(state: .warn).accessibilityHidden(true)
                        Text("待允许：\(needs)").font(LKFont.ui(LKType.caption)).foregroundStyle(p.mutedFg)
                            .lineLimit(1).truncationMode(.tail)
                    }
                    .help("待允许：\(needs)")
                }
            } action: { model.go(.prefs, tab: PrefsTab.permissions.rawValue) }
            HStack(spacing: 12) {
                LKIcon("package").foregroundStyle(p.mutedFg).frame(width: 18)
                Text("版本")
                Spacer()
                if let up = entry?.update {
                    Text("\(entry?.version ?? "") → \(up)").font(LKFont.mono(LKType.caption)).foregroundStyle(p.mutedFg)
                    Button("升级") { model.upgrade(tool) }.buttonStyle(LKButtonStyle(kind: .primary))
                } else {
                    Text(entry?.version ?? "").font(LKFont.mono(LKType.caption)).foregroundStyle(p.mutedFg)
                    if model.coreReachable {
                        Label { Text("已是最新版本") } icon: { LKIcon("circle-check", size: 14) }.labelStyle(.titleAndIcon)
                            .font(LKFont.ui(LKType.caption)).foregroundStyle(p.successText)
                    } else {   // 连不上时查不了：不画绿勾，说是上次查的
                        Text("上次检查时为最新版本").font(LKFont.ui(LKType.caption)).foregroundStyle(p.mutedFg)
                    }
                }
            }
            .lkRow(first: false)
        }
    }

    private func settingLine<T: View>(_ symbol: String, _ title: String, first: Bool, @ViewBuilder trailing: () -> T,
                                      action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 12) {
                LKIcon(symbol).foregroundStyle(p.mutedFg).frame(width: 18)
                Text(title).fixedSize()   // 放不下时省略的是右边的说明，不是这一行的名字
                Spacer()
                trailing()
                LKIcon("chevron-right", size: 13).foregroundStyle(p.mutedFg)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plainPointer)
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
                    LKIcon("search").foregroundStyle(p.mutedFg)
                    Text(model.searchQuery)
                }
                .font(LKFont.ui(LKType.small))
                .padding(.horizontal, 10).frame(height: 30)
                .background(RoundedRectangle(cornerRadius: p.controlRadius, style: .continuous).fill(p.card))
                .overlay(RoundedRectangle(cornerRadius: p.controlRadius, style: .continuous).strokeBorder(p.input, lineWidth: 1))
            }
            HStack(spacing: 6) {
                LKChip(on: model.searchFilter == "all", action: { model.searchFilter = "all" }) { Text("全部") }
                LKChip(on: model.searchFilter == "files", action: { model.searchFilter = "files" }) { AppIcon(tool: .search); Text("文件") }
                LKChip(on: model.searchFilter == "photos", action: { model.searchFilter = "photos" }) { AppIcon(tool: .search); Text("照片和视频") }
                LKChip(on: model.searchFilter == "mail", action: { model.searchFilter = "mail" }) { AppIcon(tool: .mail); Text("me@example.com") }
            }
            .padding(.bottom, 4)
            let sections = model.searchSections.filter { model.searchFilter == "all" || $0.id == model.searchFilter }
            if sections.allSatisfy({ $0.hits.isEmpty && $0.needsPermission == nil }) {
                HStack(spacing: LKSpace.x3) {
                    LKIcon("search").foregroundStyle(p.mutedFg)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("未找到「\(model.searchQuery)」")
                        Text("可更换关键词或减少字数后重试").font(LKFont.ui(LKType.small)).foregroundStyle(p.mutedFg)
                    }
                    Spacer(minLength: 0)
                }
                .lkCard(padding: EdgeInsets(top: 12, leading: 14, bottom: 12, trailing: 14))
            }
            ForEach(sections) { s in
                LKSection(title: s.title, count: s.count)
                if let perm = s.needsPermission {
                    HStack(spacing: 12) {
                        LKIcon("lock").foregroundStyle(p.mutedFg)
                        VStack(alignment: .leading, spacing: 1) {
                            Text("照片搜索未允许")
                            Text("允许后可搜索照片中的文字和场景").font(LKFont.ui(LKType.small)).foregroundStyle(p.mutedFg)
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
                                    Button { model.show("在访达中显示") } label: { LKIcon("folder") }
                                        .buttonStyle(LKButtonStyle()).accessibilityLabel("在访达中显示")
                                }
                                if h.similar {
                                    Button("查找相似") { model.show("找相似的：新结果画在这一条下面") }.buttonStyle(LKButtonStyle(kind: .text))
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

/// 应用管理（原「添加应用」，设计规范 §18.6，2026-11-12）：两节，「螺壳出品」和「Powered by 螺壳」；应用图标放大；
/// 每个应用右边一个「更多」，卸载也在里面，点了弹确认（接着本体时由本体的确认页走）。数据是本体给的（`HostApps`，docs/界面接口.md §16），
/// 没有时用窗口自己的示例目录。
struct AddAppsPage: View {
    @ObservedObject var model: WindowModel
    @Environment(\.lk) private var p

    static let iconSize: CGFloat = 34

    /// 螺壳自己的应用那一句话由窗口写（顶层 ADR 0028；走查重画稿「应用管理」），不用各应用清单里的宣传语
    /// （负责人 11-17：那几句长、带人称、带句号）。不认得的应用（第三方）照它自己的
    static func line(_ tool: ToolIcon) -> String? {
        switch tool {
        case .mail: return "整理收件箱"
        case .mem: return "记录习惯和关注的事"
        case .scan: return "清理磁盘，查看这台 Mac 的状态"
        case .search: return "按意思查找文件、邮件和图片"
        case .ime: return "学习常用说法的输入法"
        default: return nil
        }
    }

    /// 分节：记忆不算应用（负责人 11-14），不排在应用中间，单独一节「核心组件」放在最后（UX-10）。
    /// 本体的应用清单不列记忆（它是螺壳自带的组件，不是装的应用）：侧栏有记忆、清单里没有时，窗口照核心给的记忆补一行（`memory`）
    static func sections(_ rows: [HostAppRow], memory: HostAppRow? = nil) -> (luoke: [HostAppRow], poweredBy: [HostAppRow], core: [HostAppRow]) {
        var core = rows.filter { $0.tool == .mem }
        if core.isEmpty, let memory { core = [memory] }
        let apps = rows.filter { $0.tool != .mem }
        return (apps.filter { $0.origin == .luoke }, apps.filter { $0.origin == .poweredBy }, core)
    }

    var body: some View {
        let rows = model.appRows
        PageScroll() {       // 边距、一栏多宽和设置、各应用的页一样（#173：原来照旧的两列卡片稿单独定的，现在是一张列表）
            PageHeader(title: "应用管理")
            let s = Self.sections(rows, memory: model.memoryAppRow)
            group("螺壳出品", s.luoke)
            group("Powered by 螺壳", s.poweredBy) {
                // 空的时候：一行「还没有第三方应用」、一句说明，右边「欢迎接入」（走查重画稿）
                SettingsGroup {
                    SettingsRow(title: "暂无第三方应用", note: "第三方应用可接入螺壳，使用这台 Mac 上的模型和记忆") {
                        // 有接入说明的网址才放按钮，按钮上写去哪个网站（负责人 11-15：「欢迎接入」点了不开网页）
                        if let u = model.integrationGuideURL, let host = u.host {
                            Button("接入说明（\(host)）") { model.openIntegrationGuide() }.buttonStyle(LKButtonStyle(kind: .secondary))
                        }
                    }
                }
            }
            group("核心组件", s.core)
            if let n = model.appsNotice { notice(n) }
        }
    }

    /// 做完一个动作的结果，画在页底；后面可以跟一个按钮
    private func notice(_ n: HostAppsNotice) -> some View {
        HStack(spacing: 10) {
            LKIcon(n.ok ? "circle-check" : "circle-alert", size: 16).foregroundStyle(n.ok ? p.success : p.danger)
            Text(n.text).font(LKFont.ui(LKType.small)).fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
            if let a = n.action {
                Button(a.label) { model.perform(a.action, onApp: a.app) }.buttonStyle(LKButtonStyle(kind: .secondary))
            }
        }
        .padding(.top, 18)
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder private func group<Empty: View>(_ title: String, _ items: [HostAppRow], @ViewBuilder empty: () -> Empty) -> some View {
        SettingsHeading(title: title)
        if items.isEmpty {
            empty()
        } else {
            // 一组一张卡片，一个应用一行：图标、名字、一句话，右边是卸载图标（走查重画稿第三稿）
            SettingsGroup {
                ForEach(items) { a in AppTile(model: model, row: a) }
            }
        }
    }

    @ViewBuilder private func group(_ title: String, _ items: [HostAppRow]) -> some View {
        group(title, items) { EmptyView() }
    }
}

struct AppTile: View {
    @ObservedObject var model: WindowModel
    let row: HostAppRow
    @Environment(\.lk) private var p
    @State private var confirming = false
    @State private var more = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .center, spacing: 12) {
                AppIcon(tool: row.tool, size: AddAppsPage.iconSize)
                VStack(alignment: .leading, spacing: 3) {
                    HStack(alignment: .firstTextBaseline, spacing: 10) {
                        Text(row.name).font(LKFont.ui(LKType.body, .semibold))
                        Text(AddAppsPage.line(row.tool) ?? row.tagline).font(LKFont.ui(LKType.small)).foregroundStyle(p.mutedFg).lineLimit(1)
                    }
                    detail
                }
                Spacer(minLength: 0)
                trailing
                if expandable {
                    LKIcon("chevron-right", size: 12).foregroundStyle(p.mutedFg).rotationEffect(.degrees(open ? 90 : 0))
                        .accessibilityHidden(true)
                }
            }
            .padding(.vertical, 3)
            .contentShape(Rectangle())
            .onTapGesture { if expandable { withAnimation(.easeOut(duration: 0.15)) { toggle() } } }
            .accessibilityAddTraits(expandable ? .isButton : [])
            // 读屏念出是哪个应用、什么状态（不写的话整行只念「按钮」）
            .accessibilityLabel([row.name, AddAppsPage.line(row.tool) ?? row.tagline].filter { !$0.isEmpty }.joined(separator: "，"))
            // 读屏的「激活」、辅助功能的按下也要能展开（只挂点按手势的话按下没反应）
            .accessibilityAction { if expandable { toggle() } }
            if open && expandable { details.padding(.leading, AddAppsPage.iconSize + 12).padding(.top, 6).padding(.bottom, 4) }
        }
    }

    /// 装好的应用点一行展开：它要的每项权限、凭什么要、现在给没给（负责人 11-15：应用详情整页没入口，看不到它要什么权限）
    private var expandable: Bool {
        switch row.state {
        case .installed, .disabled, .update: return true
        default: return false
        }
    }
    private var open: Bool { model.openedApps.contains(row.id) }
    private func toggle() { if open { model.openedApps.remove(row.id) } else { model.openedApps.insert(row.id) } }

    private var running: Bool? { model.coreReachable ? model.agentApps?.first { $0.id == row.id }?.running : nil }

    @ViewBuilder private var details: some View {
        let perms = (model.agentPermissions ?? []).filter { $0.app == row.id }
        VStack(alignment: .leading, spacing: 6) {
            Text("权限").font(LKFont.ui(LKType.caption, .semibold)).foregroundStyle(p.mutedFg)
            if model.agentPermissions == nil {
                Text("正在读取").font(LKFont.ui(LKType.caption)).foregroundStyle(p.mutedFg)
            } else if perms.isEmpty {
                Text("未申请权限").font(LKFont.ui(LKType.caption)).foregroundStyle(p.mutedFg)
            }
            ForEach(perms) { r in
                VStack(alignment: .leading, spacing: 1) {
                    HStack(spacing: 6) {
                        Text(r.title).font(LKFont.ui(LKType.small, .medium))
                        Text(AppTile.stateWord(r.state)).font(LKFont.ui(LKType.caption)).foregroundStyle(p.mutedFg)
                    }
                    if !r.facts.isEmpty {
                        Text(r.facts.joined(separator: "；")).font(LKFont.ui(LKType.caption)).foregroundStyle(p.mutedFg)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            // 从这里去改：权限在「设置 · 隐私与权限」，应用自己的设置在它的页上（团队 11-18：展开后要能跳到对应应用的设置）
            HStack(spacing: 8) {
                if !perms.isEmpty {
                    Button("权限设置") { model.go(.prefs, tab: PrefsTab.permissions.rawValue) }
                        .buttonStyle(LKButtonStyle(kind: .secondary, size: .small))
                }
                if let to = model.appSettingsPlace(row.tool) {
                    Button(to.tab == nil ? "打开应用" : "应用设置") { model.go(to.page, tab: to.tab) }
                        .buttonStyle(LKButtonStyle(kind: .secondary, size: .small))
                }
            }
            .padding(.top, 4)
        }
    }

    static func stateWord(_ s: String?) -> String {
        switch s {
        case "granted", "on": return "已允许"
        case "denied", "off": return "未允许"
        case "ask": return "待允许"
        default: return "未知"
        }
    }

    /// 随螺壳这个包装的应用（只有开启和停用，没有卸载，顶层 ADR 0002）：在版本那一行写明，菜单里为什么没有「卸载」
    /// 看得出来（负责人 11-18：不改机制，页上写明）
    static let bundledWord = "随螺壳安装"

    /// 装好的应用名字下面那一行：版本、随螺壳安装、在不在运行
    static func versionLine(_ row: HostAppRow, running: Bool?) -> String {
        [row.version.isEmpty ? nil : "版本 \(row.version)", row.bundled ? bundledWord : nil,
         running.map { $0 ? "运行中" : "未运行" }].compactMap { $0 }.joined(separator: " · ")
    }

    /// 名字下面最后一行：装好的写版本，没装的写大小、要哪一档，装不了的写原因，在装的画进度
    @ViewBuilder private var detail: some View {
        switch row.state {
        case .working(let label, let progress):
            VStack(alignment: .leading, spacing: 4) {
                Text(label).font(LKFont.ui(LKType.caption)).foregroundStyle(p.mutedFg)
                if let progress { ProgressCapsule(value: progress) }
            }
        case .unavailable(let reason):
            Text(reason).font(LKFont.ui(LKType.caption)).foregroundStyle(p.warningText)
        case .disabled:
            HStack(spacing: 8) {
                LKBadge(text: "已停用").fixedSize()
                if row.bundled { Text(AppTile.bundledWord).font(LKFont.ui(LKType.caption)).foregroundStyle(p.mutedFg) }
            }
        case .update(let to):
            Text("有新版本 \(to)").font(LKFont.ui(LKType.caption)).foregroundStyle(p.mutedFg)
        case .installed:
            // 版本和在不在运行（负责人 11-15：看不出装没装好、什么版本、在不在运行）
            Text(AppTile.versionLine(row, running: running))
                .font(LKFont.ui(LKType.caption)).foregroundStyle(running == false ? p.warningText : p.mutedFg)
        default:
            if !row.facts.isEmpty { Wrap { ForEach(row.facts, id: \.self) { LKBadge(text: $0).fixedSize() } } }
        }
    }

    @ViewBuilder private var trailing: some View {
        switch row.state {
        case .update:
            Button("升级") { model.upgrade(row.tool) }.buttonStyle(LKButtonStyle(kind: .primary))
            tail
        case .installable:
            Button { model.install(row) } label: { IconText("安装", symbol: "circle-arrow-down") }
                .buttonStyle(LKButtonStyle(kind: .primary))
        case .working, .unavailable:
            EmptyView()
        case .disabled:
            if row.enableOnRow {
                Button("开启") { model.perform(.enable, on: row) }.buttonStyle(LKButtonStyle(kind: .secondary))
            }
            tail
        case .installed:
            if running == false {       // 没在运行：给「启动」
                Button("启动") { model.perform(.restart, on: row) }.buttonStyle(LKButtonStyle(kind: .secondary))
            }
            tail
        }
    }

    /// 行尾：「更多」（开启、停用、回到上一版……、卸载）。卸载接着本体时直接交给它（它自己的确认页会列出要拿走的东西）；
    /// 示例里先在这里弹确认
    @ViewBuilder private var tail: some View {
        if !row.moreActions.isEmpty {
            LKIconButton(symbol: "ellipsis", label: "更多") { more = true }
                .popover(isPresented: $more, arrowEdge: .bottom) {
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(row.moreActions, id: \.self) { a in
                            if a == .uninstall && row.moreActions.count > 1 { Divider().padding(.vertical, 4) }
                            Button { more = false; pick(a) } label: {
                                Text(a.title).foregroundStyle(a == .uninstall ? p.danger : p.fg)
                                    .frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
                            }
                            .buttonStyle(.plainPointer).padding(.horizontal, 10).padding(.vertical, 6)
                        }
                    }
                    .padding(6).frame(minWidth: 160)
                }
                .popover(isPresented: $confirming, arrowEdge: .bottom) { confirmUninstall }
        }
    }

    private func pick(_ a: HostAppAction) {
        if a == .uninstall && model.confirmsUninstallHere {
            DispatchQueue.main.async { confirming = true }     // 等菜单收起再弹
        } else {
            model.perform(a, on: row)
        }
    }

    private var confirmUninstall: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("卸载\(row.name)？").font(LKFont.ui(LKType.body, .medium))
            Text("它写入记忆的内容和自身数据可以保留，重新安装后恢复")
                .font(LKFont.ui(LKType.small)).foregroundStyle(p.mutedFg)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 8) {
                Spacer(minLength: 0)
                Button("取消") { confirming = false }.buttonStyle(LKButtonStyle(kind: .secondary))
                Button("卸载") { confirming = false; model.perform(.uninstall, on: row) }.buttonStyle(LKButtonStyle(kind: .danger))
            }
        }
        .padding(16).frame(width: 280)
    }
}

struct ChatPage: View {
    @ObservedObject var model: WindowModel
    @Environment(\.lk) private var p

    var body: some View {
        PageScroll {
            PageHeader(title: "对话") {
                Button { model.go(.today) } label: { LKIcon("x") }
                    .buttonStyle(LKButtonStyle(kind: .text)).accessibilityLabel("关上")
            }
            VStack(alignment: .leading, spacing: 14) {
                ForEach(model.chat) { line in
                    if line.mine {
                        HStack {
                            Spacer()
                            Text(line.text).padding(.horizontal, 12).padding(.vertical, 8)
                                .background(UnevenRoundedRectangle(topLeadingRadius: p.cardRadius, bottomLeadingRadius: p.cardRadius, bottomTrailingRadius: LKRadius.small, topTrailingRadius: p.cardRadius).fill(p.muted))
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

/// 应用页分段画（工具协议 §4 pageSections，照扫描页对照稿）：页头那一行不画卡片；一排数每格一张小卡片；
/// 一段一张卡片，段的小标题（图标、字、数）画在卡片外面、上面。几张卡片还是同一页，按钮照旧回到这一页
struct PageSections: View {
    @ObservedObject var model: SurfaceModel
    let blocks: [PageBlock]
    let onAction: (String, String, JSONValue) -> Void
    @Environment(\.lk) private var p

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { i, block in
                view(block).padding(.top, i == 0 ? 0 : gap(block))
            }
        }
    }

    /// 带小标题的段和上面隔得开一点（对照稿 .sec2 上面 18），别的 12
    private func gap(_ b: PageBlock) -> CGFloat {
        if case .card(_, let title, _) = b, title != nil { return 18 }
        if case .group(let title, _) = b, title != nil { return 18 }
        return 12
    }

    @ViewBuilder private func view(_ b: PageBlock) -> some View {
        switch b {
        case .bare(let id):
            SurfaceView(model: model, part: .section(id, skip: 0), onAction: onAction)
        case .tiles(let ids):
            HStack(alignment: .top, spacing: 10) {
                ForEach(ids, id: \.self) { id in
                    SurfaceView(model: model, part: .section(id, skip: 0), onAction: onAction)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .lkCard(padding: EdgeInsets(top: 12, leading: 14, bottom: 12, trailing: 14))
                }
            }
        case .card(let id, let title, let skip):
            VStack(alignment: .leading, spacing: 8) {
                if let title { titleView(title) }
                if skip == 0, model.surface.plainList(id) {
                    flushList(id)
                } else {
                    SurfaceView(model: model, part: .section(id, skip: skip), onAction: onAction).lkCard()
                }
            }
        case .group(let title, let ids):
            VStack(alignment: .leading, spacing: 8) {
                if let title { titleView(title) }
                if ids.count == 1, model.surface.plainList(ids[0]) {
                    flushList(ids[0])
                } else if ids.count == 1, model.surface.chipRow(ids[0]) {
                    // 小标题下面只有一排小标签（「最近搜过」「检索范围」）：不放进卡片
                    SurfaceView(model: model, part: .section(ids[0], skip: 0), onAction: onAction)
                } else if !ids.isEmpty {
                    VStack(alignment: .leading, spacing: 14) {
                        ForEach(ids, id: \.self) { id in SurfaceView(model: model, part: .section(id, skip: 0), onAction: onAction) }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .lkCard()
                }
            }
        }
    }

    /// 卡片里只是一组行：卡片不留边，行自己带边距，停上去的底色铺满卡片（负责人 11-22）
    private func flushList(_ id: String) -> some View {
        SurfaceView(model: model, part: .section(id, skip: 0), onAction: onAction)
            .environment(\.a2uiListInset, LKInsets.card)
            .frame(maxWidth: .infinity, alignment: .leading)
            .clipShape(RoundedRectangle(cornerRadius: p.cardRadius, style: .continuous))
            .background(CardSurface())
    }

    private func titleView(_ t: SectionTitle) -> some View {
        // 走查重画稿：卡片上面的小标题是灰的小字，数跟在「·」后面（「待确认 · 1」）
        HStack(spacing: 6) {
            if let icon = t.icon { LKIcon(A2UI.lucide(icon) ?? icon, size: 13) }
            Text(text(t.text))
            if let n = t.count { Text("· \(text(n))") }
        }
        .font(LKFont.ui(LKType.small))
        .foregroundStyle(p.mutedFg)
        .padding(.horizontal, 2)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isHeader)
    }

    private func text(_ v: JSONValue) -> String {
        if let path = v.bindingPath { return model.value(path)?.string ?? "" }
        return v.string ?? ""
    }
}
