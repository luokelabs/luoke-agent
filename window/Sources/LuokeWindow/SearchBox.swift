import AppKit
import LuokeA2UI
import SwiftUI

/// 螺壳搜索页上的搜索框（⌘K）：在页标题下面、正文最上面（UX-09，原来浮在窗口底部）。只搜索，不问螺壳：按回车把词直接给应用，
/// 结果在它下面的正文里整页画（`SearchPanel(inline:)`），Esc 收起。
struct SearchField: View {
    @ObservedObject var model: WindowModel
    @Environment(\.lk) private var p
    @Environment(\.lkSnapshot) private var snapshot
    @State private var text = ""
    @FocusState private var focused: Bool

    var body: some View {
        field
        .onChange(of: model.searchFocus) {
            model.pendingSearchFocus = false
            focused = true
        }
        // 页上发起的搜索（点「最近搜索」的一条）：框里换成搜的那一句，看得出在搜什么、能接着改
        .onChange(of: model.searchFill) { text = model.searchFill.text }
        // 结果开着时框里是搜的那一句（视图重建过也一样）
        .task { if text.isEmpty && model.searchOpen { text = model.searchQuery } }
        // 窗口打开时系统把光标放进第一个输入框：不要（负责人 11-14），⌘K 或点了才进去；
        // 但从别的页按 ⌘K 跳过来时（pendingSearchFocus），直接聚焦且不踢掉焦点
        .onAppear {
            if model.pendingSearchFocus {
                model.pendingSearchFocus = false
                DispatchQueue.main.async { focused = true }
                return
            }
            // 窗口变成前台窗口时系统才放光标：等一下再拿掉
            for t in [0.0, 0.3, 0.8] {
                DispatchQueue.main.asyncAfter(deadline: .now() + t) {
                    guard !model.pendingSearchFocus else { return }
                    if focused { focused = false }
                    Self.dropAutoFocus()
                }
            }
        }
    }

    /// 窗口一打开就落在搜索框上的光标拿掉（只在它还没打字时）
    static func dropAutoFocus() {
        for w in NSApp.windows where w.isVisible {
            if let tv = w.firstResponder as? NSTextView, tv.isFieldEditor, tv.string.isEmpty { w.makeFirstResponder(nil) }
        }
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
            .buttonStyle(.plainPointer)
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
                    // 回车：用 ↑↓ 或鼠标选中了一条、框里还是搜的那一句时打开它；不然搜（同一句也重新搜）
                    .onSubmit { if !model.returnPressed(text: text) { model.runSearch(text) } }
                    // 输入法正在拼时（框里有带下划线的字）↓↑ 是选候选词，不动结果
                    .onKeyPress(.downArrow) { model.searchAnswer?.hits.isEmpty == false && !Self.composing ? (model.moveSearchSelection(1), .handled).1 : .ignored }
                    .onKeyPress(.upArrow) { model.searchAnswer?.hits.isEmpty == false && !Self.composing ? (model.moveSearchSelection(-1), .handled).1 : .ignored }
                    .onKeyPress(keys: [.return]) { press in
                        guard !Self.composing else { return .ignored }
                        // 按住回车的连发不算：只认按下的那一下（rc3：多出的一下把结果用外部应用打开了）
                        if press.phase == .repeat { return .handled }
                        guard press.modifiers.contains(.command) else { return .ignored }
                        // ⌘↩ 在访达中显示选中的那条；没选中时什么都不做，框里改了字才当搜
                        return model.returnPressed(text: text, reveal: true) || model.showsResults(for: text) ? .handled : .ignored
                    }
                    .onExitCommand {
                        text = ""
                        model.closeSearch()
                        focused = false
                    }
            }
            // 框里有字或结果开着：一个 ×，点了清空、收起结果，回到最近搜索（只用鼠标的也退得回来；键盘是 Esc）
            if !text.isEmpty || model.searchOpen {
                Button {
                    text = ""
                    model.closeSearch()
                } label: {
                    LKIcon("x", size: 14).foregroundStyle(p.mutedFg).frame(width: 22, height: 22).contentShape(Rectangle())
                }
                .buttonStyle(.plainPointer)
                .help("清除")
                .accessibilityLabel("清除搜索")
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
        .frame(maxWidth: .infinity, minHeight: 44, maxHeight: 44)
        // 在页里、不再浮在内容上：不要影子，描一圈边和别的输入框一样
        .background(RoundedRectangle(cornerRadius: LKRadius.sheet, style: .continuous).fill(p.card))
        .overlay(RoundedRectangle(cornerRadius: LKRadius.sheet, style: .continuous).strokeBorder(p.input, lineWidth: 1))
    }
}

/// 搜索框下面的结果（螺壳搜索页的正文里）：一个应用一段，放不下就滚动。`height`：结果最高多少，页给的是内容区剩下的高
struct SearchPanel: View {
    @ObservedObject var model: WindowModel
    var height: CGFloat = SearchResults.height
    @Environment(\.lk) private var p
    @Environment(\.lkSnapshot) private var snapshot

    var body: some View {
        if let a = model.searchAnswer, !a.hits.isEmpty {
            // 给了 hits 的：按类型分组自己画（SearchResults），顶上一行和页脚贴着面板的边
            SearchResults(model: model, answer: a, snapshot: snapshot, height: height)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: LKRadius.sheet, style: .continuous).fill(p.card))
                .clipShape(RoundedRectangle(cornerRadius: LKRadius.sheet, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: LKRadius.sheet, style: .continuous).strokeBorder(p.border, lineWidth: 1))
        } else {
            cardsPanel
        }
    }

    private var cardsPanel: some View {
        Group {
            if snapshot {   // 离屏画不出系统的滚动视图：平铺，多出来的从下面截掉（和 PageScroll 一样）
                content.fixedSize(horizontal: false, vertical: true).frame(maxHeight: height - 60, alignment: .top)
                    .fixedSize(horizontal: false, vertical: true).clipped()   // 结果少时不撑满
            } else {
                ScrollView { content }.scrollIndicators(.never)    // 和 SearchResults 一样：滚动条一出一收会抖
                    .frame(maxHeight: height - 60)
                    .fixedSize(horizontal: false, vertical: true)     // 结果少时不撑满
            }
        }
            .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: LKRadius.sheet, style: .continuous).fill(p.card))
        .overlay(RoundedRectangle(cornerRadius: LKRadius.sheet, style: .continuous).strokeBorder(p.border, lineWidth: 1))
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
                } else if let why = a.partialNote {
                    // 没找到、但应用说了这次搜得不全（模型还在加载……）：写出原因，能再搜一次
                    ErrorNote(text: "未找到结果", detail: why) { model.runSearch(model.searchQuery) }
                    ForEach(a.lines, id: \.self) { line($0) }
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
