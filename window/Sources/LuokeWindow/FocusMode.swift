import LuokeA2UI
import SwiftUI

/// 「一件件处理」怎么进场：第一件随面板出来，后面的从下面来，键盘上按的只淡入淡出
enum FocusItemStyle { case enter, next, key }

/// 「一件件处理」：一块面板盖住「今天」，一次只摆一件。⏎ 答标了 primary 的那个（没标的不答），↓ 跳过，Esc 回「今天」
struct FocusPanel: View {
    @ObservedObject var model: WindowModel
    let ns: Namespace.ID
    @Environment(\.lk) private var p
    @Environment(\.lkSnapshot) private var snapshot
    @Environment(\.accessibilityReduceMotion) private var reduce
    @FocusState private var focused: Bool

    var body: some View {
        let session = model.focus
        let current = model.focusCurrent
        let answered = model.focusAnswered
        let started = answered > 0 || !(session?.skipped.isEmpty ?? true)
        let style: FocusItemStyle = !started ? .enter : ((session?.viaKey ?? false) || reduce ? .key : .next)
        let key = current?.id ?? "end"
        VStack(alignment: .leading, spacing: 0) {
            top(total: session?.ids.count ?? 0, answered: answered, quick: style == .key)
                .lkAppear(!snapshot, Motion.enter(0.2, delay: Motion.focusTopAt, reduce: reduce))
            ZStack(alignment: .topLeading) {
                Group {
                    if let c = current {
                        FocusItem(card: c, model: model, style: style)
                    } else {
                        FocusEnd(model: model, left: model.focusLeft, style: style)
                    }
                }
                .id(key)
                .transition(.asymmetric(insertion: .identity,
                                        removal: .modifier(active: FocusOut(model: model, active: true), identity: FocusOut(model: model, active: false))))
            }
            .animation(style == .key ? Motion.fade(Motion.key) : Motion.enter(Motion.nextOut), value: key)
            .padding(EdgeInsets(top: LKSpace.x11, leading: LKSpace.x14, bottom: LKSpace.x11, trailing: LKSpace.x14))
            .frame(maxWidth: 660, alignment: .topLeading)
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .clipShape(RoundedRectangle(cornerRadius: LKRadius.focus, style: .continuous))
        .background {
            RoundedRectangle(cornerRadius: LKRadius.focus, style: .continuous)
                .fill(p.card)
                .overlay(RoundedRectangle(cornerRadius: LKRadius.focus, style: .continuous).strokeBorder(p.dark ? p.cardEdge : .clear, lineWidth: 1))
                .shadow(color: p.shadow.opacity(p.dark ? 0 : 0.08), radius: 1, y: 1)
                .shadow(color: p.dark ? .black.opacity(0.6) : p.shadow.opacity(0.35), radius: 20, y: 18)
                .matchedGeometryEffect(id: "focus-surface", in: ns)
        }
        .padding(LKSpace.x4)
        .focusable()
        .focusEffectDisabled()
        .focused($focused)
        .onAppear { focused = true }
        .onKeyPress(.return) {
            if model.focusCurrent == nil { model.exitFocus() } else { model.answerFocusPrimary(viaKey: true) }
            return .handled
        }
        .onKeyPress(.downArrow) {
            model.skipFocus(viaKey: true)
            return .handled
        }
        .onKeyPress(.escape) {
            model.exitFocus()
            return .handled
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("一件件处理")
    }

    /// 顶上一条：标题、每件一格的进度、还有几件、完成
    private func top(total: Int, answered: Int, quick: Bool) -> some View {
        HStack(spacing: LKSpace.x4) {
            Text("一件件处理").font(LKFont.ui(LKType.lead, .semibold))
            HStack(spacing: LKSpace.x1) {
                ForEach(0..<total, id: \.self) { i in
                    Capsule().fill(p.border).frame(height: 3)
                        .overlay(alignment: .leading) {
                            Capsule().fill(p.fg).scaleEffect(x: i < answered ? 1 : 0.001, y: 1, anchor: .leading)
                        }
                        .clipShape(Capsule())
                }
            }
            .frame(width: 180)
            .animation(quick ? Motion.fade(Motion.key) : Motion.move(Motion.segment, delay: 0.04, reduce: reduce), value: answered)
            .accessibilityElement()
            .accessibilityLabel("答了 \(answered) 件，共 \(total) 件")
            Text(model.cards.isEmpty ? "都处理完了" : "还有 \(model.cards.count) 件")
                .font(LKFont.ui(LKType.small)).foregroundStyle(p.mutedFg).monospacedDigit()
                .contentTransition(reduce ? .opacity : .numericText())
                .animation(Motion.enter(Motion.counter, delay: 0.12, reduce: reduce), value: model.cards.count)
            Spacer(minLength: 0)
            Button { model.exitFocus() } label: {
                HStack(spacing: LKSpace.x2) {
                    Text("完成")
                    Kbd(text: "Esc")
                }
            }
            .buttonStyle(LKButtonStyle(kind: .text))
        }
        .padding(.horizontal, LKSpace.x6)
        .padding(.vertical, LKSpace.x4)
        .overlay(alignment: .bottom) { Rectangle().fill(p.border).frame(height: 1) }
    }
}

/// 换下一件时旧的那件：往上走 12 pt 淡出；键盘上按的、减少动态效果时只淡出（走的时候才看是哪一种）
private struct FocusOut: ViewModifier {
    let model: WindowModel
    let active: Bool
    @Environment(\.accessibilityReduceMotion) private var reduce

    func body(content: Content) -> some View {
        let quick = reduce || (model.focus?.viaKey ?? true)
        content.opacity(active ? 0 : 1).offset(y: active && !quick ? -12 : 0)
    }
}

/// 进场的一块：第 i 块错开一点
private struct FocusPart: ViewModifier {
    let index: Int
    let style: FocusItemStyle
    @Environment(\.lkSnapshot) private var snapshot
    @Environment(\.accessibilityReduceMotion) private var reduce

    @ViewBuilder func body(content: Content) -> some View {
        let n = Double(index)
        switch style {
        case .enter:
            content.lkAppear(!snapshot, dy: 12, Motion.enter(Motion.focusParts, delay: Motion.focusPartsAt + Motion.focusStagger * n, reduce: reduce))
        case .next:
            content.lkAppear(!snapshot, dy: 16, Motion.enter(Motion.nextIn, delay: Motion.nextInAt + Motion.stagger * n, reduce: reduce))
        case .key:
            content.lkAppear(!snapshot, Motion.fade(Motion.key))
        }
    }
}

private extension View {
    func focusPart(_ i: Int, _ style: FocusItemStyle) -> some View { modifier(FocusPart(index: i, style: style)) }
}

/// 卡片里的按钮在一件件处理里另外画（大一号，后面跟「跳过」）
private struct HiddenButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View { EmptyView() }
}

/// 正摆着的那一件：哪个应用、标题 26、正文 15、几行明细、36 pt 的按钮和「跳过」、按键提示
struct FocusItem: View {
    let card: TodayCard
    @ObservedObject var model: WindowModel
    let style: FocusItemStyle
    @Environment(\.lk) private var p

    var body: some View {
        let digest = SurfaceDigest(card.surface.surface)
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: LKSpace.x2) {
                AppIcon(tool: card.tool, size: 24)
                Text(([card.tool.name] + (card.time.map { [$0] } ?? [])).joined(separator: " · "))
                    .font(LKFont.ui(LKType.small)).foregroundStyle(p.mutedFg)
            }
            .focusPart(0, style)
            SurfaceView(model: card.surface) { cid, _, _ in model.answerFocus(cid) }
                .environment(\.a2uiFont, { variant in
                    switch variant {
                    case "h1", "h2", "h3", "h4", "h5": return LKFont.ui(LKType.title, .semibold)
                    default: return LKFont.ui(LKType.lead)
                    }
                })
                .environment(\.a2uiButtonStyle, { _ in AnyA2UIButtonStyle(HiddenButtonStyle()) })
                .padding(.top, LKSpace.x4)
                .focusPart(1, style)
            HStack(spacing: LKSpace.x2) {
                ForEach(digest.actions) { a in
                    DigestButton(action: a, surface: card.surface, style: LKButtonStyle(kind: LKButtonKind(a2ui: a.variant), size: .large)) {
                        model.answerFocus(a.id)
                    }
                }
                Button("跳过") { model.skipFocus() }.buttonStyle(LKButtonStyle(kind: .text, size: .large))
            }
            .padding(.top, LKSpace.x6)
            .focusPart(2, style)
            HStack(spacing: LKSpace.x4) {
                if let a = digest.primary { hint("⏎", a.label) }
                hint("↓", "跳过")
                hint("Esc", "回到今天")
            }
            .padding(.top, LKSpace.x4)
            .focusPart(3, style)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func hint(_ key: String, _ label: String) -> some View {
        HStack(spacing: LKSpace.x1 + 2) {
            Kbd(text: key)
            Text(label).font(LKFont.ui(LKType.caption)).foregroundStyle(p.mutedFg)
        }
    }
}

/// 都过了一遍：都答了是吉祥物和一句话；跳过了的写还有几件留着
struct FocusEnd: View {
    @ObservedObject var model: WindowModel
    let left: Int
    let style: FocusItemStyle
    @Environment(\.lk) private var p

    var body: some View {
        VStack(alignment: .leading, spacing: LKSpace.x3) {
            if left == 0 { Mascot(width: 104).focusPart(0, style) }
            Text(left == 0 ? "今天没什么要你操心的" : "还有 \(left) 件留着")
                .font(LKFont.ui(LKType.title, .semibold)).tracking(-0.26)
                .focusPart(1, style)
            Text(left > 0 ? "跳过的事还在「今天」里，等你有空再看。"
                 : model.shows(.activity) ? "做了的都在「今天」和「活动」里，随时能撤销。" : "做了的都在「今天」里，随时能撤销。")
                .font(LKFont.ui(LKType.lead)).foregroundStyle(p.fg.opacity(0.85))
                .focusPart(2, style)
            Button("回到今天") { model.exitFocus() }
                .buttonStyle(LKButtonStyle(kind: .primary, size: .large))
                .padding(.top, LKSpace.x2)
                .focusPart(3, style)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
