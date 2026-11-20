import LuokeA2UI
import LuokeA2UICore
import SwiftUI

// 右边栏：它自己的一栏（界面规范 v2 §14，原型 docs/今天和右边栏原型.html，负责人 11-12 定稿）。
// 独立于应用，和左边栏一样不跟着页面变；默认收起；顶上一排今天的产出（不放头像名字，负责人 11-13），下面两个页签：「任务」（队列）和「历史」（做过的所有事，按天）。

/// 任务队列里的一件（主控给，`WindowModel.tasks`）
public struct TaskRow: Identifiable, Equatable {
    public enum State: Equatable, Sendable {
        /// 正在做；fraction 0…1，note 是「第 2 份，共 5 份」这类一句话，都可以没有
        case running(fraction: Double?, note: String?)
        /// 排着；`wait` 是在等什么
        case queued(wait: Wait?)
    }

    /// 排着的在等什么（主控按它的条件给；字由窗口写）
    public enum Wait: Equatable, Sendable {
        case soon, time(Date), power, thermal, memory, paused, quiet, busy

        /// 标在那一行右边的短话；马上就轮到的不标
        var label: String? { label(now: Date()) }

        /// 定了钟点的：今天的只写时刻，明天的写「明天 15:25 起」，再往后带上月日（#171：间隔 24 小时的任务下一次是明天，
        /// 只写「15:25 起」像是几小时前就该开始）
        func label(now: Date, calendar: Calendar = .current) -> String? {
            switch self {
            case .soon: return nil
            case .time(let d):
                let f = DateFormatter()
                f.locale = Locale(identifier: "zh_CN")
                f.calendar = calendar
                f.timeZone = calendar.timeZone
                let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: now), to: calendar.startOfDay(for: d)).day ?? 0
                f.dateFormat = days <= 0 ? "HH:mm" : days == 1 ? "'明天' HH:mm" : "M月d日 HH:mm"
                return "\(f.string(from: d)) 起"
            case .power: return "接电源时"
            case .thermal: return "降温后"
            case .memory: return "内存充足时"
            case .paused: return "已暂停"
            case .quiet: return "空闲时"
            case .busy: return "排队中"
            }
        }
    }

    /// 「排队」里的先后：照预计什么时候能开始。马上的最前，定了钟点的从早到晚，等条件的在后，暂停的最后；
    /// 同一档里照主控给的顺序。不照应用排（每行底下写了是哪个应用）
    public static func queueOrder(_ rows: [TaskRow]) -> [TaskRow] {
        func key(_ t: TaskRow) -> (Int, Date) {
            guard case .queued(let wait) = t.state else { return (0, .distantPast) }
            switch wait {
            case .soon?: return (0, .distantPast)
            case .busy?: return (1, .distantPast)
            case nil: return (2, .distantPast)
            case .time(let d)?: return (3, d)
            case .quiet?, .power?, .thermal?, .memory?: return (4, .distantPast)
            case .paused?: return (5, .distantPast)
            }
        }
        return rows.enumerated().sorted { a, b in
            let (x, y) = (key(a.element), key(b.element))
            return x != y ? x < y : a.offset < b.offset
        }.map(\.element)
    }

    public let id: String
    public let tool: ToolIcon
    public let title: String
    public var state: State

    public init(id: String, tool: ToolIcon, title: String, state: State) {
        self.id = id
        self.tool = tool
        self.title = title
        self.state = state
    }
}

/// 右边栏的页签
public enum PanelTab: String, CaseIterable, Sendable {
    case tasks, history

    var title: String { self == .tasks ? "任务" : "历史" }
}

/// 一天的产出（右上角的胶囊、右边栏顶部）。token 的数要主控给：没给就只写完成几件
public struct OutputStats: Equatable, Sendable {
    /// 今天完成几件：主控不给（nil）就从「活动」里数
    public var tasksToday: Int?
    public var tokensToday: Int?
    public var tokensTotal: Int?
    /// 累计从哪天开始记的（「自 11 月 12 日起」）
    public var since: String?

    public init(tasksToday: Int? = nil, tokensToday: Int? = nil, tokensTotal: Int? = nil, since: String? = nil) {
        self.tasksToday = tasksToday
        self.tokensToday = tokensToday
        self.tokensTotal = tokensTotal
        self.since = since
    }

    /// 860、18K、184K、3M、2B：四舍五入，不带小数，单位大写（负责人 11-13）
    static func tokens(_ n: Int) -> String {
        let v = Double(n)
        if v >= 999_500_000 { return "\(Int((v / 1e9).rounded()))B" }
        if v >= 999_500 { return "\(Int((v / 1e6).rounded()))M" }
        if v >= 1_000 { return "\(Int((v / 1e3).rounded()))K" }
        return "\(n)"
    }
}

extension WindowModel {
    /// 右上角那一粒要写什么：有任务在跑写它的名字；没有就写今天的产出
    var runningTask: TaskRow? { tasks.first { if case .running = $0.state { return true } else { return false } } }

    /// 今天的产出（没给就是空的，只有完成几件）
    var outputToday: OutputStats { outputStats ?? OutputStats() }

    /// 今天完成几件：主控给了就用它，没给就数「活动」里今天的、没撤销的；「今天」上「已自动处理」比它多时用那个数
    /// （活动记录还没到、只有今天的那几行时，右上角写 0 和下面「替你做完了 1 件」对不上）
    var tasksDone: Int {
        if let n = outputStats?.tasksToday { return n }
        let logged = activity.filter { $0.day == "今天" && !$0.undone }.count
        return max(logged, done.filter { !$0.undone }.count)
    }
}

/// 窗口右上角的胶囊（负责人 11-13 定的 A）：高 30，和左边的收起按钮一样高、在同一条线上，离右边 12（收起按钮离左边也是 12），
/// 不随页面宽度挪。里面是方框对号加今天完成几件、芯片加今天生成多少 token（K、M、B）。有任务时贴着底边一条 2 高的分段细线：
/// 一件任务一段（最多 8 段），正在做的那段照进度填红，在等条件的（接电源、你不用时……）浅棕，排着的浅灰；没有任务就没有这条线。
/// 点了拉出右边栏。内存、GPU 不在这里，在右边栏顶上
struct OutputPill: View {
    /// 高 24（负责人 11-17：再小一些）
    static let height: CGFloat = 24
    /// 最多画几段：任务再多，最后一段就代表「还有」
    static let maxSegments = 8
    /// 进度环：和数字的字差不多高；每两段之间空的那一截占整圈的多少
    static let ringSize: CGFloat = 14, ringLine: CGFloat = 2.2, ringGap: CGFloat = 0.07
    /// 在等条件的那几段的颜色
    static let waitColor = Color.hex(0xC9A27A)

    @ObservedObject var model: WindowModel
    @Environment(\.lk) private var p

    var body: some View {
        Button { model.openPanel(.tasks) } label: {
            // 一行：两个数，有任务时再加一个小进度环（负责人 11-17：底下的分段线让数不在正中，换成环，放右边：环出现时数不挪位置）
            HStack(spacing: 8) {
                count("square-check", "\(model.tasksDone)")
                if let t = model.outputToday.tokensToday { count("cpu", OutputStats.tokens(t)) }
                if !model.tasks.isEmpty { queue }
            }
            .fixedSize()
            .opacity(model.coreReachable ? 1 : RightPanel.offlineOpacity)
            .padding(.horizontal, 10)
            .frame(height: Self.height)
            .background(Self.body(p))
            .overlay(Self.rim(p))
            .contentShape(Capsule())
        }
        .buttonStyle(.plainPointer)
        .help(Self.summary(model))
        .accessibilityLabel(Self.summary(model) + "，打开任务和历史")
    }

    /// 胶囊的底（负责人 11-17：更有质感）：上亮下暗的一点渐变，贴身一层细影加一层散开的软影，像一颗浮起来的小按钮
    static func body(_ p: Palette) -> some View {
        Capsule()
            .fill(p.card)
            .overlay(Capsule().fill(LinearGradient(colors: p.dark ? [.white.opacity(0.07), .white.opacity(0)] : [p.muted.opacity(0), p.muted.opacity(0.8)],
                                                   startPoint: .top, endPoint: .bottom)))
            .shadow(color: p.shadow.opacity(p.dark ? 0.35 : 0.10), radius: 0.5, y: 0.5)
            .shadow(color: p.shadow.opacity(p.dark ? 0.30 : 0.09), radius: 5, y: 2)
    }

    /// 边：一圈细线，上沿一道高光往下淡掉
    static func rim(_ p: Palette) -> some View {
        ZStack {
            Capsule().strokeBorder(p.input.opacity(p.dark ? 0.9 : 0.75), lineWidth: 0.5)
            Capsule().inset(by: 0.5)
                .strokeBorder(LinearGradient(colors: [.white.opacity(p.dark ? 0.14 : 0.9), .white.opacity(0)],
                                             startPoint: .top, endPoint: .center), lineWidth: 1)
        }
    }

    private func count(_ icon: String, _ text: String) -> some View {
        HStack(spacing: 4) {
            LKIcon(icon, size: 12).foregroundStyle(p.mutedFg)
            Text(text).font(LKFont.ui(LKType.caption, .semibold)).foregroundStyle(p.fg).monospacedDigit().lineLimit(1)
        }
    }

    /// 进度环：一件任务一段（最多 8 段），从 12 点起顺时针；正在做的那段照进度填（不知道进度的先填一小截），
    /// 在等条件的浅棕，排着的浅灰
    private var queue: some View {
        let tasks = Array(model.tasks.prefix(Self.maxSegments))
        let n = CGFloat(tasks.count), g: CGFloat = tasks.count > 1 ? Self.ringGap : 0
        let span = (1 - g * n) / n
        let style = StrokeStyle(lineWidth: Self.ringLine, lineCap: .round)
        let track = p.mutedFg.opacity(0.22)
        return ZStack {
            ForEach(Array(tasks.enumerated()), id: \.element.id) { i, t in
                let a0 = CGFloat(i) * (span + g) + g / 2
                Circle().trim(from: a0, to: a0 + span).stroke(Self.waiting(t) ? Self.waitColor : track, style: style)
                if case .running(let f, _) = t.state {
                    Circle().trim(from: a0, to: a0 + span * CGFloat(max(f ?? 0.18, 0.04))).stroke(p.brandText, style: style)
                }
            }
        }
        .rotationEffect(.degrees(-90))
        .padding(Self.ringLine / 2)
        .frame(width: Self.ringSize, height: Self.ringSize)
        .accessibilityHidden(true)
    }

    /// 排着、在等条件的（接电源、等降温、你不用时……）；马上就轮到的、排在后面的不算
    static func waiting(_ t: TaskRow) -> Bool {
        if case .queued(let w) = t.state, let w, w != .soon, w != .busy { return true }
        return false
    }

    /// 悬停提示、读屏：「今天完成 23 件 · 生成 184K token · 进行中：读取合同 PDF · 排队 2 件」
    static func summary(_ m: WindowModel) -> String {
        var parts = m.coreReachable ? [] : [RightPanel.offlineText]
        parts.append("今天完成 \(m.tasksDone) 件")
        if let t = m.outputToday.tokensToday { parts.append("生成 \(OutputStats.tokens(t)) token") }
        if let r = m.runningTask { parts.append("进行中：\(r.title)") }
        let queued = m.tasks.filter { if case .queued = $0.state { return true } else { return false } }.count
        if queued > 0 { parts.append("排队 \(queued) 件") }
        return parts.joined(separator: " · ")
    }
}

/// 右边栏
struct RightPanel: View {
    static let width: CGFloat = 300
    static let offlineText = "未连接螺壳"
    static let offlineOpacity = 0.45

    @ObservedObject var model: WindowModel
    @Environment(\.lk) private var p

    var body: some View {
        VStack(spacing: 0) {
            header
            // 连不上螺壳：数和列表是断开前的，画淡，顶上写一行（负责人 11-16）
            if !model.coreReachable {
                HStack(spacing: 6) {
                    LKIcon("circle-alert", size: 14).foregroundStyle(p.warning).accessibilityHidden(true)
                    Text(Self.offlineText).font(LKFont.ui(LKType.small, .medium)).foregroundStyle(p.fg)
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, LKSpace.x4).padding(.vertical, LKSpace.x2)
            }
            Group {
                stats
                tabs
                Divider().overlay(p.border)
                Group {
                    switch model.panelTab {
                    case .tasks: TaskList(model: model)
                    case .history: HistoryList(model: model)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            }
            .opacity(model.coreReachable ? 1 : Self.offlineOpacity)
        }
        .frame(width: Self.width)
        .background(p.sidebar)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("螺壳的任务和历史")
    }

    /// 顶上只有收起的 ×：不放头像、名字和「工作中」「空闲」（负责人 11-13：右边栏不用它自己的头像名称；
    /// 在做什么看右上角那一粒和下面的「任务」）
    private var header: some View {
        HStack(spacing: LKSpace.x3) {
            // 这台 Mac 现在多忙（负责人 11-13：内存、GPU 放在右边栏顶上；以后有了 CPU、神经网络引擎再加）
            meter("RAM", model.machineLoad?.ram, MachineLoad.ramColor(p.dark))
            meter("GPU", model.machineLoad?.gpu, MachineLoad.gpuColor(p.dark))
            Spacer(minLength: 0)
            Button { model.closePanel() } label: {
                LKIcon("x", size: 16).foregroundStyle(p.mutedFg).frame(width: 30, height: 30).contentShape(Rectangle())
            }
            .buttonStyle(.plainPointer)
            .help("收起")
            .accessibilityLabel("收起右边栏")
        }
        .padding(.leading, LKSpace.x4).padding(.trailing, LKSpace.x3)
        .padding(.top, LKSpace.x3).padding(.bottom, LKSpace.x1)
    }

    /// 一样资源：名字（它的颜色）、一条短的进度、百分比
    private func meter(_ name: String, _ v: Double?, _ color: Color) -> some View {
        HStack(spacing: 6) {
            Text(name).font(.system(size: 11, weight: .bold, design: .rounded)).foregroundStyle(color)
            ZStack(alignment: .leading) {
                Capsule().fill(p.mutedFg.opacity(0.18))
                Capsule().fill(color).frame(width: 30 * CGFloat(v ?? 0))
            }
            .frame(width: 30, height: 4)
            Text(MachineLoad.percent(v)).font(LKFont.ui(LKType.caption)).foregroundStyle(p.mutedFg).monospacedDigit()
                .lineLimit(1).fixedSize()
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(name == "RAM" ? "内存" : name) \(MachineLoad.percent(v))")
    }

    /// 顶部一排产出：今天完成几件；主控给了 token 数再加两格
    @ViewBuilder private var stats: some View {
        let s = model.outputToday
        VStack(alignment: .leading, spacing: LKSpace.x2) {
            HStack(spacing: LKSpace.x2) {
                stat("\(model.tasksDone)", unit: "件", label: "今天完成")
                if let t = s.tokensToday { stat(OutputStats.tokens(t), unit: "token", label: "今天生成") }
            }
            if let total = s.tokensTotal {
                Text("累计 \(OutputStats.tokens(total)) token" + (s.since.map { " · 自 \($0)起" } ?? ""))
                    .font(LKFont.ui(LKType.caption)).foregroundStyle(p.mutedFg).padding(.horizontal, 2)
            }
        }
        .padding(.horizontal, LKSpace.x3).padding(.bottom, LKSpace.x3)
    }

    private func stat(_ value: String, unit: String, label: String) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline, spacing: 3) {
                Text(value).font(LKFont.ui(20, .semibold)).monospacedDigit()
                Text(unit).font(LKFont.ui(LKType.caption, .medium)).foregroundStyle(p.mutedFg)
            }
            Text(label).font(LKFont.ui(LKType.caption)).foregroundStyle(p.mutedFg)
        }
        .padding(.horizontal, LKSpace.x3).padding(.vertical, 9)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(p.card))
    }

    private var tabs: some View {
        HStack(spacing: LKSpace.x1) {
            ForEach(PanelTab.allCases, id: \.self) { t in
                let on = model.panelTab == t
                Button { model.panelTab = t } label: {
                    Text(t.title)
                        .font(LKFont.ui(LKType.small, on ? .semibold : .regular))
                        .foregroundStyle(on ? p.fg : p.mutedFg)
                        .padding(.horizontal, 10).padding(.top, 9).padding(.bottom, 10)
                        .overlay(alignment: .bottom) { Rectangle().fill(on ? p.brand : .clear).frame(height: 2) }
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plainPointer)
                .accessibilityAddTraits(on ? .isSelected : [])
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, LKSpace.x3)
    }
}

/// 「任务」：进行中的、排着的。先只读（以后做成能手动调先后）
private struct TaskList: View {
    @ObservedObject var model: WindowModel
    @Environment(\.lk) private var p

    var body: some View {
        let running = model.tasks.filter { if case .running = $0.state { return true } else { return false } }
        let queued = model.tasks.filter { if case .queued = $0.state { return true } else { return false } }
        PanelScroll {
            VStack(alignment: .leading, spacing: 0) {
                if model.tasks.isEmpty {
                    Text("没有任务").font(LKFont.ui(LKType.small)).foregroundStyle(p.mutedFg)
                        .frame(maxWidth: .infinity).padding(.top, LKSpace.x8)
                } else {
                    if !running.isEmpty { section("进行中", running) }
                    if !queued.isEmpty { section("排队", TaskRow.queueOrder(queued)) }
                }
            }
            .padding(LKSpace.x3)
        }
    }

    private func section(_ title: String, _ rows: [TaskRow]) -> some View {
        VStack(alignment: .leading, spacing: LKSpace.x2) {
            Text(title).font(LKFont.ui(LKType.caption, .semibold)).foregroundStyle(p.mutedFg).padding(.leading, 4)
            VStack(spacing: 0) {
                ForEach(Array(rows.enumerated()), id: \.element.id) { i, t in
                    TaskLine(task: t).overlay(alignment: .top) { if i > 0 { Rectangle().fill(p.border).frame(height: 1) } }
                }
            }
            .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(p.card))
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
        .padding(.bottom, LKSpace.x4)
    }
}

private struct TaskLine: View {
    let task: TaskRow
    @Environment(\.lk) private var p

    var body: some View {
        HStack(spacing: LKSpace.x3) {
            AppIcon(tool: task.tool, size: 22)
            VStack(alignment: .leading, spacing: 1) {
                Text(task.title).font(LKFont.ui(LKType.body, .medium)).lineLimit(1)
                if let sub { Text(sub).font(LKFont.ui(LKType.caption)).foregroundStyle(p.mutedFg).lineLimit(1) }
                if case .running(let f?, _) = task.state {
                    ProgressCapsule(value: f).padding(.top, 4)
                }
            }
            Spacer(minLength: 0)
            if case .queued(let wait?) = task.state, let label = wait.label {
                Text(label).font(LKFont.ui(11.5, .medium)).foregroundStyle(p.mutedFg)
                    .padding(.horizontal, 7).frame(height: 20)
                    .background(RoundedRectangle(cornerRadius: LKRadius.small, style: .continuous).fill(p.muted))
            }
        }
        .padding(.horizontal, LKSpace.x3).padding(.vertical, 10)
        .accessibilityElement(children: .combine)
    }

    private var sub: String? {
        var parts = [task.tool.name]
        if case .running(_, let note?) = task.state { parts.append(note) }
        return parts.joined(separator: " · ")
    }
}

/// 「历史」：它做过的所有事，按天；所有应用的都在这里。能撤销的给「撤销」
private struct HistoryList: View {
    @ObservedObject var model: WindowModel
    @Environment(\.lk) private var p

    var body: some View {
        let rows = model.activity
        PanelScroll {
            VStack(alignment: .leading, spacing: 0) {
                if rows.isEmpty {
                    Text("暂无历史记录").font(LKFont.ui(LKType.small)).foregroundStyle(p.mutedFg)
                        .frame(maxWidth: .infinity).padding(.top, LKSpace.x8)
                }
                ForEach(days(rows), id: \.self) { day in
                    Text(day).font(LKFont.ui(LKType.caption, .semibold)).foregroundStyle(p.mutedFg)
                        .padding(.leading, 4).padding(.bottom, LKSpace.x2)
                        .accessibilityAddTraits(.isHeader)
                    let dayRows = rows.filter { $0.day == day }
                    VStack(spacing: 0) {
                        ForEach(Array(dayRows.enumerated()), id: \.element.id) { i, r in
                            HistoryLine(row: r, model: model)
                                .overlay(alignment: .top) { if i > 0 { Rectangle().fill(p.border).frame(height: 1) } }
                        }
                    }
                    .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(p.card))
                    .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                    .padding(.bottom, LKSpace.x4)
                }
            }
            .padding(LKSpace.x3)
        }
    }
}

private struct HistoryLine: View {
    let row: ActivityRow
    @ObservedObject var model: WindowModel
    @Environment(\.lk) private var p

    @State private var open = false

    /// 卡片还在窗口里：点这一行在下面展开它（明细、点得开的信；负责人 11-16：历史的行点不开明细）
    private var surface: SurfaceModel? { row.surfaceId.flatMap { model.backend?.cardSurface($0) } }

    var body: some View {
        let s = surface
        VStack(alignment: .leading, spacing: 0) {
            line(expandable: s != nil)
            if open, let s, let sid = row.surfaceId {
                SurfaceView(model: s) { cid, _, ctx in model.tapSurface(sid, componentId: cid, context: ctx) }
                    .padding(.horizontal, LKSpace.x3).padding(.bottom, 10)
            }
        }
    }

    private func line(expandable: Bool) -> some View {
        HStack(spacing: LKSpace.x3) {
            AppIcon(tool: row.tool, size: 22)
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 4) {
                    Text(row.text).font(LKFont.ui(LKType.body, .medium)).lineLimit(2)
                        .foregroundStyle(row.undone ? p.mutedFg : p.fg)
                    if expandable {
                        LKIcon("chevron-right", size: 12).foregroundStyle(p.mutedFg).rotationEffect(.degrees(open ? 90 : 0))
                            .accessibilityHidden(true)
                    }
                }
                Text(([row.time, row.tool.name] + (row.undone ? ["已撤销"] : [])).joined(separator: " · "))
                    .font(LKFont.ui(LKType.caption)).foregroundStyle(p.mutedFg).lineLimit(1)
            }
            Spacer(minLength: 0)
            if let label = row.undoLabel, !row.undone {
                Button(label) { model.undoActivity(row.id) }.buttonStyle(LKButtonStyle(kind: .undo))
            }
        }
        .padding(.horizontal, LKSpace.x3).padding(.vertical, 10)
        .contentShape(Rectangle())
        .onTapGesture { if expandable { withAnimation(.easeOut(duration: 0.15)) { open.toggle() } } }
        .help(row.auto ? "自动" : "手动")
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(expandable ? .isButton : [])
        .accessibilityAction { if expandable { open.toggle() } }
    }
}

/// 在做的转圈（减少动态效果时不转）
struct PanelSpinner: View {
    @Environment(\.lk) private var p
    @Environment(\.accessibilityReduceMotion) private var reduce
    @Environment(\.lkSnapshot) private var snapshot
    @State private var angle = 0.0

    var body: some View {
        Circle().trim(from: 0, to: 0.3).stroke(p.brand, style: StrokeStyle(lineWidth: 2, lineCap: .round))
            .background(Circle().stroke(p.input, lineWidth: 2))
            .rotationEffect(.degrees(angle))
            .onAppear {
                guard !reduce, !snapshot else { return }
                withAnimation(.linear(duration: 1).repeatForever(autoreverses: false)) { angle = 360 }
            }
            .accessibilityHidden(true)
    }
}

/// 右边栏里会滚的区域：截图画不出滚动区，那时按内容画、多出来的截掉（同 `PageScroll`）
struct PanelScroll<Content: View>: View {
    @ViewBuilder var content: Content
    @Environment(\.lkSnapshot) private var snapshot

    var body: some View {
        if snapshot {
            VStack(alignment: .leading, spacing: 0) { content }
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                .clipped()
        } else {
            ScrollView { VStack(alignment: .leading, spacing: 0) { content } }.scrollIndicators(.hidden)
        }
    }
}
