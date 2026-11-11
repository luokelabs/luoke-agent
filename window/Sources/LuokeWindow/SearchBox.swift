import AppKit
import LuokeA2UI
import SwiftUI

/// 底部的搜索框（⌘K）：只搜索，不问螺壳。按回车把词直接给应用，结果是应用给的 A2UI 卡片，浮在当前页上，Esc 收起。
struct SearchLayer: View {
    @ObservedObject var model: WindowModel
    @Environment(\.lk) private var p
    @Environment(\.lkSnapshot) private var snapshot
    @Environment(\.lkLayout) private var layout
    @State private var text = ""
    @FocusState private var focused: Bool
    /// 结果面板加搜索框的高：面板出来时实底跟着往上延，后面的字整行淡掉，不在面板上沿露半截
    @State private var stackHeight: CGFloat = 0

    var body: some View {
        ZStack(alignment: .bottom) {
            // 搜索框后面和上面一段是实底，往上渐隐：滚到下面的内容不会半截透出来
            // 搜索框（48 高、离底 18）上沿再往上 20pt 都是实底，渐隐在实底之前就变成底色：上沿不会横切一行淡字
            LinearGradient(stops: [.init(color: p.bg.opacity(0), location: 0), .init(color: p.bg.opacity(0.9), location: 0.12),
                                   .init(color: p.bg, location: 0.22), .init(color: p.bg, location: 1)], startPoint: .top, endPoint: .bottom)
                .frame(height: model.searchOpen ? max(112, stackHeight + 18 + 56) : 112)
                .allowsHitTesting(false)
            if model.searchOpen {
                Color.black.opacity(p.dark ? 0.35 : 0.08)
                    .contentShape(Rectangle())
                    .onTapGesture { model.closeSearch() }
            }
            VStack(spacing: 10) {
                if model.searchOpen { SearchPanel(model: model) }
                field
            }
            .onGeometryChange(for: CGFloat.self, of: { $0.size.height }) { stackHeight = $0 }
            // 和页面那一栏同宽、同一条中线（PageScroll：最宽 700，左右各留 LKInsets.column，窄的时候留得少）；
            // 宽窗口里页有侧栏时跟着主栏往左挪，不骑在两栏中间
            .frame(maxWidth: LKColumn.width - LKInsets.column.leading - LKInsets.column.trailing)
            .padding(.horizontal, layout == .narrow ? LKInsets.columnNarrow.leading : LKInsets.column.leading)
            .offset(x: model.hasRail(layout) ? -LKColumn.railShift : 0)
            .padding(.bottom, 18)
        }
        .onChange(of: model.searchFocus) { focused = true }
    }

    /// 输入法正在拼：搜索框的 field editor 里有 marked text。看各窗口的 firstResponder，不只看 keyWindow
    static var composing: Bool {
        NSApp.windows.contains { ($0.firstResponder as? NSTextView)?.hasMarkedText() == true }
    }

    private var field: some View {
        HStack(spacing: 8) {
            Button { model.focusSearch() } label: {
                LKIcon("search", size: 16).foregroundStyle(p.mutedFg)
            }
            .buttonStyle(.plain)
            .keyboardShortcut("k", modifiers: .command)
            .accessibilityLabel("把光标放进搜索框")
            if snapshot {       // 系统输入框离屏画不出来
                let q = model.searchOpen ? model.searchQuery : ""   // 结果面板开着时框里是搜的那一句
                Text(q.isEmpty ? "搜索" : q)
                    .foregroundStyle(q.isEmpty ? p.mutedFg : p.fg).frame(maxWidth: .infinity, alignment: .leading)
            } else {
                TextField("搜索", text: $text)
                    .textFieldStyle(.plain)
                    .focused($focused)
                    // 回车：结果开着、框里还是搜的那一句时打开选中的（没选中是第一条），不然搜
                    .onSubmit { if !model.returnPressed(text: text) { model.runSearch(text) } }
                    // 输入法正在拼时（框里有带下划线的字）↓↑ 是选候选词，不动结果
                    .onKeyPress(.downArrow) { model.searchAnswer?.hits.isEmpty == false && !Self.composing ? (model.moveSearchSelection(1), .handled).1 : .ignored }
                    .onKeyPress(.upArrow) { model.searchAnswer?.hits.isEmpty == false && !Self.composing ? (model.moveSearchSelection(-1), .handled).1 : .ignored }
                    .onKeyPress(keys: [.return]) { press in
                        guard press.modifiers.contains(.command), !Self.composing else { return .ignored }
                        return model.returnPressed(text: text, reveal: true) ? .handled : .ignored     // ⌘↩ 在访达中显示
                    }
                    .onExitCommand {
                        text = ""
                        model.closeSearch()
                        focused = false
                    }
            }
            Kbd(text: "⌘K")
        }
        .background {
            if model.searchAnswer?.hits.isEmpty == false {
                // 框里没有光标时也认 ⌘↩。传框里的字：搜完改了字没按回车，⌘↩ 不该显示上一次的结果。
                // 挂在 background 上不占位，结果出来时「⌘K」不跳
                Button("") { _ = model.returnPressed(text: text, reveal: true) }
                    .keyboardShortcut(.return, modifiers: .command).frame(width: 0, height: 0).opacity(0)
                    .accessibilityHidden(true)
            }
        }
        .padding(EdgeInsets(top: 6, leading: 14, bottom: 6, trailing: 14))
        .frame(maxWidth: .infinity, minHeight: 48, maxHeight: 48)
        .background(RoundedRectangle(cornerRadius: LKRadius.sheet, style: .continuous).fill(p.card))
        .shadow(color: .black.opacity(p.dark ? 0.35 : 0.1), radius: 12, y: 6)   // 不描边：浅色靠影子，深色靠卡片色
    }
}

/// 搜索框上面的结果：一个应用一段，放不下就滚动
struct SearchPanel: View {
    @ObservedObject var model: WindowModel
    @Environment(\.lk) private var p
    @Environment(\.lkSnapshot) private var snapshot

    var body: some View {
        if let a = model.searchAnswer, !a.hits.isEmpty {
            // 给了 hits 的：按类型分组自己画（SearchResults），顶上一行和页脚贴着面板的边
            SearchResults(model: model, answer: a, snapshot: snapshot)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: LKRadius.sheet, style: .continuous).fill(p.card.opacity(0.97)))
                .clipShape(RoundedRectangle(cornerRadius: LKRadius.sheet, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: LKRadius.sheet, style: .continuous).strokeBorder(p.border, lineWidth: 1))
                .shadow(color: .black.opacity(0.18), radius: 25, y: 12)
        } else {
            cardsPanel
        }
    }

    private var cardsPanel: some View {
        Group {
            if snapshot {   // 离屏画不出系统的滚动视图：平铺，多出来的从下面截掉（和 PageScroll 一样）
                content.fixedSize(horizontal: false, vertical: true).frame(maxHeight: 460, alignment: .top)
                    .fixedSize(horizontal: false, vertical: true).clipped()   // 结果少时不撑满
            } else {
                ScrollView { content }.scrollIndicators(.never)    // 和 SearchResults 一样：滚动条一出一收会抖
                    .frame(maxHeight: 460)
                    .fixedSize(horizontal: false, vertical: true)     // 结果少时不撑满
            }
        }
            .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: LKRadius.sheet, style: .continuous).fill(p.card.opacity(0.97)))
        .overlay(RoundedRectangle(cornerRadius: LKRadius.sheet, style: .continuous).strokeBorder(p.border, lineWidth: 1))
        .shadow(color: .black.opacity(0.18), radius: 25, y: 12)
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: 10) {
            if model.searching {
                line("在搜…")
            } else if let a = model.searchAnswer {
                ForEach(a.cards) { s in
                    SurfaceView(model: s.surface) { cid, _, ctx in model.tapSurface(s.id, componentId: cid, context: ctx) }
                }
                if let note = a.note, a.retry {
                    ErrorNote(text: note) { model.runSearch(model.searchQuery) }
                } else if let note = a.note {
                    line(note)
                } else if a.allFailed {
                    ErrorNote(text: a.allFailedText) { model.runSearch(model.searchQuery) }
                } else {
                    // 有的没答上来时不写「没有找到。」：那个应用里还没搜（录屏里两句前后矛盾）
                    ForEach(a.lines, id: \.self) { line($0) }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func line(_ text: String) -> some View {
        Text(text).font(LKFont.ui(LKType.small)).foregroundStyle(p.mutedFg)
    }
}
