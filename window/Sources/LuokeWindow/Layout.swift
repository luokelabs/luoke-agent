import LuokeA2UICore
import SwiftUI

/// 内容区（窗口减去侧栏）有多宽，决定各页怎么排（docs/主窗口.md「宽窗口」）。
/// 宽了一栏不变宽，多出来的地方放第二栏（侧栏），再宽就留白。
enum LKLayout: Equatable {
    /// 一栏，两边边距收窄
    case narrow
    /// 一栏，最宽 700 pt
    case regular
    /// 主栏 + 侧栏（页上有放进侧栏的东西时），一组居中
    case wide

    /// 比这窄是 narrow
    static let narrowBelow: CGFloat = 760
    /// 到这么宽是 wide（主栏、侧栏、两边边距放得下，还剩点空）
    static let wideFrom: CGFloat = 1200

    /// 内容区的宽只由窗口和侧栏定，不随怎么排而变，所以不会在两档之间来回跳，不用留回差
    init(width: CGFloat) {
        self = width < Self.narrowBelow ? .narrow : width >= Self.wideFrom ? .wide : .regular
    }
}

/// 各页那一栏的尺寸
enum LKColumn {
    /// 一栏最宽多少（连两边边距）：今天、应用页、设置……都一样，底部的搜索框和它对齐
    static let width: CGFloat = 700
    /// 侧栏多宽
    static let rail: CGFloat = 380
    /// 主栏和侧栏中间空多少
    static let gap: CGFloat = 32
    /// 有侧栏时一组最宽多少（连两边边距）
    static var railedWidth: CGFloat { width + gap + rail }
    /// 有侧栏时主栏的中线比内容区的中线往左挪多少：底部的搜索框跟着主栏
    static var railShift: CGFloat { (gap + rail) / 2 }
    /// 紧凑的「今天」那张表最宽多少
    static let table: CGFloat = 1080
}

private struct LayoutKey: EnvironmentKey { static let defaultValue = LKLayout.regular }

extension EnvironmentValues {
    /// 窗口在 `WindowBody` 量一次内容区，往下传
    var lkLayout: LKLayout {
        get { self[LayoutKey.self] }
        set { self[LayoutKey.self] = newValue }
    }
}

extension LKInsets {
    /// 窄的时候那一栏两边各留多少
    static let columnNarrow = EdgeInsets(top: LKSpace.x7, leading: LKSpace.x6, bottom: column.bottom, trailing: LKSpace.x6)
}

/// 宽窗口里的两栏：主栏占剩下的（700 一栏减去边距的那么宽），侧栏固定宽，顶对齐，跟着页面一起滚
struct RailSplit<Main: View, Rail: View>: View {
    @ViewBuilder var main: Main
    @ViewBuilder var rail: Rail

    var body: some View {
        HStack(alignment: .top, spacing: LKColumn.gap) {
            VStack(alignment: .leading, spacing: 0) { main }
                .frame(maxWidth: .infinity, alignment: .topLeading)
            VStack(alignment: .leading, spacing: 0) { rail }
                .frame(width: LKColumn.rail, alignment: .topLeading)
        }
    }
}

extension WindowModel {
    /// 这一页在这一档里有没有侧栏。页和底部的搜索框都照它，搜索框才跟得上主栏。
    /// 「今天」（标准，不在一件件处理）：有「已经替你做了」；
    /// 接上核心的应用页：第一页（下面有「这个应用」），或者工具在这一页写了 `"placement": "aside"` 的段
    func hasRail(_ layout: LKLayout) -> Bool {
        guard layout == .wide, focus == nil else { return false }
        switch page {
        case .today:
            return density == .standard && !done.isEmpty
        case .mail, .scan, .mem, .searchApp, .ime:
            guard let app = agentApp(for: page) else { return false }
            let tab = agentTab(app)
            if tab == nil || tab == app.firstPage { return true }
            return agentPages[AgentFeed.pageKey(app.id, tab!)]?.surface?.surface.asideSections.isEmpty == false
        default:
            return false
        }
    }
}
