import SwiftUI

/// 动效的曲线和时长（docs/主窗口.md「动效」）。减少动态效果时一律只淡入淡出，不超过 150 ms，不等。
enum Motion {
    // 时长（秒）
    static let press = 0.09
    static let cardLeave = 0.13
    static let reflow = 0.32
    static let reflowDelay = 0.05
    static let flight = 0.44
    static let flightBow: CGFloat = 36
    static let rowParts = 0.22
    static let rowPartsAt = 0.28
    static let stagger = 0.03
    static let counter = 0.28
    static let counterAt = 0.29
    static let undoRow = 0.16
    static let undoCard = 0.26
    static let undoCardAt = 0.16
    static let focusGrow = 0.42
    static let focusFade = 0.15
    static let focusTopAt = 0.09
    static let focusPartsAt = 0.10
    static let focusStagger = 0.035
    static let focusParts = 0.30
    static let focusExit = 0.18
    static let nextOut = 0.16
    static let nextIn = 0.30
    static let nextInAt = 0.07
    static let segment = 0.26
    static let key = 0.12
    static let pill = 0.28
    static let pageOut = 0.13
    static let blocks = 0.26
    static let blocksAt = 0.02
    static let rail = 0.42
    static let briefRoom = 0.34
    static let briefHead = 0.20
    static let briefHeadAt = 0.14
    static let brief = 0.42
    static let briefAt = 0.17
    static let briefClose = 0.16
    static let thumb = 0.24
    static let ring = 1.2
    static let reduced = 0.15

    // 曲线
    static func enter(_ d: Double, delay: Double = 0, reduce: Bool = false) -> Animation {
        reduce ? .linear(duration: min(d, reduced)) : .timingCurve(0.23, 1, 0.32, 1, duration: d).delay(delay)
    }

    static func move(_ d: Double, delay: Double = 0, reduce: Bool = false) -> Animation {
        reduce ? .linear(duration: min(d, reduced)) : .timingCurve(0.77, 0, 0.175, 1, duration: d).delay(delay)
    }

    static func drawer(_ d: Double, delay: Double = 0, reduce: Bool = false) -> Animation {
        reduce ? .linear(duration: min(d, reduced)) : .timingCurve(0.32, 0.72, 0, 1, duration: d).delay(delay)
    }

    static func exit(_ d: Double, delay: Double = 0, reduce: Bool = false) -> Animation {
        reduce ? .linear(duration: min(d, reduced)) : .timingCurve(0.3, 0, 0.8, 0.15, duration: d).delay(delay)
    }

    /// 简报那段话升上来用的
    static func soft(_ d: Double, delay: Double = 0, reduce: Bool = false) -> Animation {
        reduce ? .linear(duration: min(d, reduced)) : .timingCurve(0.16, 1, 0.3, 1, duration: d).delay(delay)
    }

    /// 只淡入淡出（键盘上按的，或者减少动态效果）
    static func fade(_ d: Double) -> Animation { .linear(duration: min(d, reduced)) }

    /// 卡片离开：淡出、缩到 0.97
    static func cardLeave(reduce: Bool) -> AnyTransition {
        reduce ? AnyTransition.opacity.animation(fade(cardLeave))
            : AnyTransition.opacity.combined(with: .scale(scale: 0.97)).animation(enter(cardLeave))
    }

    /// 撤销时卡片回来：晚一点淡入、从 0.97 放大回来
    static func cardBack(reduce: Bool) -> AnyTransition {
        reduce ? AnyTransition.opacity.animation(fade(undoCard))
            : AnyTransition.opacity.combined(with: .scale(scale: 0.97)).animation(enter(undoCard, delay: undoCardAt))
    }
}

/// 飞的那一程：x 前一半往左边空白处偏、后一半落回，y 和大小一起先快后慢
enum FlightPath {
    static let outX = UnitCurve.bezier(startControlPoint: UnitPoint(x: 0.2, y: 0.6), endControlPoint: UnitPoint(x: 0.35, y: 1))
    static let backX = UnitCurve.bezier(startControlPoint: UnitPoint(x: 0.45, y: 0), endControlPoint: UnitPoint(x: 0.2, y: 1))
    static let y = UnitCurve.bezier(startControlPoint: UnitPoint(x: 0.33, y: 0), endControlPoint: UnitPoint(x: 0.2, y: 1))

    /// 第 t（0…1）时左上角在哪、多大
    static func at(_ t: Double, from: CGRect, to: CGRect, bow: CGFloat = Motion.flightBow) -> CGRect {
        let t = min(max(t, 0), 1)
        let dx = to.minX - from.minX
        let mid = dx / 2 - bow
        let x: CGFloat = t < 0.5 ? mid * CGFloat(outX.value(at: t / 0.5))
            : mid + (dx - mid) * CGFloat(backX.value(at: (t - 0.5) / 0.5))
        let e = CGFloat(y.value(at: t))
        let size = from.width + (to.width - from.width) * e
        return CGRect(x: from.minX + x, y: from.minY + (to.minY - from.minY) * e, width: size, height: size)
    }
}

/// 飞着的应用图标
struct FlyingIcon: View, Animatable {
    let tool: ToolIcon
    let from: CGRect
    let to: CGRect
    var progress: Double

    var animatableData: Double {
        get { progress }
        set { progress = newValue }
    }

    var body: some View {
        let r = FlightPath.at(progress, from: from, to: to)
        AppIcon(tool: tool, size: r.width)
            .offset(x: r.minX, y: r.minY)
            .accessibilityHidden(true)
    }
}

// MARK: 进场

private struct EntranceKey: EnvironmentKey { static let defaultValue = Entrance.none }

extension EnvironmentValues {
    /// 这一页是怎么来的：换页、从「一件件处理」回来时各块错开着升上来
    var lkEntrance: Entrance {
        get { self[EntranceKey.self] }
        set { self[EntranceKey.self] = newValue }
    }
}

/// 一块内容出现时淡入、往上升一点。第一次画（开窗口、截图）直接在原位
private struct EnterBlock: ViewModifier {
    let index: Int
    @Environment(\.lkEntrance) private var entrance
    @Environment(\.lkSnapshot) private var snapshot
    @Environment(\.accessibilityReduceMotion) private var reduce
    @State private var armed: Bool?
    @State private var shown = false

    func body(content: Content) -> some View {
        let animate = entrance != .none && !snapshot
        let visible = shown || (armed == nil && !animate)
        content
            .opacity(visible ? 1 : 0)
            .offset(y: visible || reduce ? 0 : 8)
            .onAppear {
                guard armed == nil else { return }
                armed = animate
                guard animate else { shown = true; return }
                let base = entrance == .fromFocus ? Motion.focusPartsAt : Motion.blocksAt
                withAnimation(Motion.enter(Motion.blocks, delay: base + Motion.stagger * Double(min(index, 9)), reduce: reduce)) { shown = true }
            }
    }
}

/// 出现时淡入、从 rise pt 处移过来（简报、新的一行、一件件处理的每一块）。fresh 是 false 就直接在原位
struct AppearIn: ViewModifier {
    let fresh: Bool
    var dx: CGFloat = 0
    var dy: CGFloat = 0
    let animation: Animation
    @Environment(\.lkSnapshot) private var snapshot
    @Environment(\.accessibilityReduceMotion) private var reduce
    @State private var armed: Bool?
    @State private var shown = false

    func body(content: Content) -> some View {
        let animate = fresh && !snapshot
        let visible = shown || (armed == nil && !animate)
        content
            .opacity(visible ? 1 : 0)
            .offset(x: visible || reduce ? 0 : dx, y: visible || reduce ? 0 : dy)
            .onAppear {
                guard armed == nil else { return }
                armed = animate
                guard animate else { shown = true; return }
                withAnimation(animation) { shown = true }
            }
    }
}

/// 时间线：出现时从上往下画出来
private struct RailDraw: ViewModifier {
    @Environment(\.lkEntrance) private var entrance
    @Environment(\.lkSnapshot) private var snapshot
    @Environment(\.accessibilityReduceMotion) private var reduce
    @State private var armed: Bool?
    @State private var shown = false

    func body(content: Content) -> some View {
        let animate = entrance != .none && !snapshot
        let visible = shown || (armed == nil && !animate)
        content
            .scaleEffect(x: 1, y: visible || reduce ? 1 : 0.001, anchor: .top)
            .opacity(visible || !reduce ? 1 : 0)
            .onAppear {
                guard armed == nil else { return }
                armed = animate
                guard animate else { shown = true; return }
                withAnimation(Motion.enter(Motion.rail, delay: Motion.blocksAt, reduce: reduce)) { shown = true }
            }
    }
}

extension View {
    /// 页里的第 index 块：换页时错开 30 ms 升上来
    func lkEnter(_ index: Int) -> some View { modifier(EnterBlock(index: index)) }

    /// 出现时的动效（见 AppearIn）
    func lkAppear(_ fresh: Bool, dx: CGFloat = 0, dy: CGFloat = 0, _ animation: Animation) -> some View {
        modifier(AppearIn(fresh: fresh, dx: dx, dy: dy, animation: animation))
    }

    func lkRailDraw() -> some View { modifier(RailDraw()) }
}
