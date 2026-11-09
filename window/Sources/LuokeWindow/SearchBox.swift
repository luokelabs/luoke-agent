import LuokeA2UI
import SwiftUI

/// 底部的搜索框（⌘K）：只搜索，不问螺壳。按回车把词直接给应用，结果是应用给的 A2UI 卡片，浮在当前页上，Esc 收起。
struct SearchLayer: View {
    @ObservedObject var model: WindowModel
    @Environment(\.lk) private var p
    @Environment(\.lkSnapshot) private var snapshot
    @State private var text = ""
    @FocusState private var focused: Bool

    var body: some View {
        ZStack(alignment: .bottom) {
            LinearGradient(stops: [.init(color: p.bg.opacity(0), location: 0), .init(color: p.bg.opacity(0.92), location: 0.45),
                                   .init(color: p.bg, location: 1)], startPoint: .top, endPoint: .bottom)
                .frame(height: 96)
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
            .padding(.bottom, 18)
        }
        .onChange(of: model.searchFocus) { focused = true }
    }

    private var field: some View {
        HStack(spacing: 8) {
            Button { model.focusSearch() } label: {
                Image(systemName: "magnifyingglass").font(.system(size: 14)).foregroundStyle(p.mutedFg)
            }
            .buttonStyle(.plain)
            .keyboardShortcut("k", modifiers: .command)
            .accessibilityLabel("把光标放进搜索框")
            if snapshot {       // 系统输入框离屏画不出来
                Text("搜索").foregroundStyle(p.mutedFg).frame(maxWidth: .infinity, alignment: .leading)
            } else {
                TextField("搜索", text: $text)
                    .textFieldStyle(.plain)
                    .focused($focused)
                    .onSubmit { model.runSearch(text) }
                    .onExitCommand {
                        text = ""
                        model.closeSearch()
                        focused = false
                    }
            }
            Kbd(text: "⌘K")
        }
        .padding(EdgeInsets(top: 6, leading: 14, bottom: 6, trailing: 14))
        .frame(width: 640, height: 48)
        .background(RoundedRectangle(cornerRadius: LKRadius.sheet, style: .continuous).fill(p.card))
        .overlay(RoundedRectangle(cornerRadius: LKRadius.sheet, style: .continuous).strokeBorder(p.input, lineWidth: 1))
        .shadow(color: .black.opacity(0.1), radius: 12, y: 6)
    }
}

/// 搜索框上面的结果：一个应用一段，放不下就滚动
struct SearchPanel: View {
    @ObservedObject var model: WindowModel
    @Environment(\.lk) private var p
    @Environment(\.lkSnapshot) private var snapshot

    var body: some View {
        Group {
            if snapshot {   // 离屏画不出系统的滚动视图：平铺，多出来的从下面截掉（和 PageScroll 一样）
                content.fixedSize(horizontal: false, vertical: true).frame(maxHeight: 460, alignment: .top)
                    .fixedSize(horizontal: false, vertical: true).clipped()   // 结果少时不撑满
            } else {
                ScrollView { content }
                    .frame(maxHeight: 460)
                    .fixedSize(horizontal: false, vertical: true)     // 结果少时不撑满
            }
        }
            .padding(14)
        .frame(width: 640, alignment: .leading)
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
                if let note = a.note {
                    line(note)
                } else if a.cards.isEmpty {
                    line("没有找到。")
                }
                ForEach(a.failed, id: \.self) { line("\($0)这次没有答复。") }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func line(_ text: String) -> some View {
        Text(text).font(LKFont.ui(LKType.small)).foregroundStyle(p.mutedFg)
    }
}
