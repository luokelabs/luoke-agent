import SwiftUI

/// 底部一条：搜索，或者问螺壳（⌘K）。回答浮在当前页上，Esc 收起。
struct AskLayer: View {
    @ObservedObject var model: WindowModel
    @Environment(\.lk) private var p

    var body: some View {
        ZStack(alignment: .bottom) {
            LinearGradient(stops: [.init(color: p.bg.opacity(0), location: 0), .init(color: p.bg.opacity(0.92), location: 0.45),
                                   .init(color: p.bg, location: 1)], startPoint: .top, endPoint: .bottom)
                .frame(height: 96)
                .allowsHitTesting(false)
            if model.askOpen {
                Color.black.opacity(p.dark ? 0.35 : 0.08)
                    .contentShape(Rectangle())
                    .onTapGesture { model.closeAsk() }
            }
            VStack(spacing: 10) {
                if model.askOpen, let a = model.answer { AnswerPanel(answer: a, model: model) }
                Pill(model: model)
            }
            .padding(.bottom, 18)
        }
    }
}

struct Pill: View {
    @ObservedObject var model: WindowModel
    @Environment(\.lk) private var p

    var body: some View {
        Button { if model.askOpen { model.closeAsk() } else { model.openAsk() } } label: {
            HStack(spacing: 8) {
                Image(systemName: "sparkle").font(.system(size: 14)).foregroundStyle(p.mutedFg)
                if let chip = chipText {
                    Text(chip).font(LKFont.ui(LKType.caption)).padding(.horizontal, 8).frame(height: 26)
                        .background(RoundedRectangle(cornerRadius: LKRadius.control, style: .continuous).fill(p.muted))
                }
                Text(model.askOpen ? (model.answer?.question ?? "") : (model.page == .chat ? "接着问…" : "搜索，或者问螺壳"))
                    .foregroundStyle(model.askOpen ? p.fg : p.mutedFg)
                    .lineLimit(1)
                Spacer(minLength: 8)
                Kbd(text: "⌘K")
                Image(systemName: "arrow.up").font(.system(size: 12, weight: .semibold)).foregroundStyle(p.mutedFg)
                    .frame(width: 30, height: 30).background(RoundedRectangle(cornerRadius: LKRadius.control, style: .continuous).fill(p.muted))
            }
            .padding(EdgeInsets(top: 6, leading: 14, bottom: 6, trailing: 6))
            .frame(width: 640, height: 48)
            .background(RoundedRectangle(cornerRadius: LKRadius.sheet, style: .continuous).fill(p.card))
            .overlay(RoundedRectangle(cornerRadius: LKRadius.sheet, style: .continuous).strokeBorder(p.input, lineWidth: 1))
            .shadow(color: .black.opacity(0.1), radius: 12, y: 6)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .keyboardShortcut("k", modifiers: .command)
        .accessibilityLabel("搜索，或者问螺壳")
    }

    /// 上下文标签：你在哪一页
    private var chipText: String? {
        switch model.page {
        case .today: return model.askContext
        case .mail, .scan, .mem, .searchApp, .search, .activity, .prefs, .apps: return model.askContext ?? model.page.title
        case .chat: return nil
        }
    }
}

struct AnswerPanel: View {
    let answer: Answer
    @ObservedObject var model: WindowModel
    @Environment(\.lk) private var p

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "person").font(.system(size: 12))
                Text(answer.question).lineLimit(1)
                Spacer()
            }
            .font(LKFont.ui(LKType.small)).foregroundStyle(p.mutedFg)
            Text(answer.text).fixedSize(horizontal: false, vertical: true)
            if !answer.rows.isEmpty || answer.primary != nil {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(answer.rows.enumerated()), id: \.element.id) { i, r in
                        HStack(spacing: 10) {
                            AppIcon(tool: r.tool)
                            Text(r.title).font(LKFont.ui(LKType.small))
                            Spacer()
                            if !r.action.isEmpty {
                                Button(r.action) { model.show(r.action == "打开" ? "用它的默认程序打开（只在你点了以后）" : "这里会打开\(r.tool.name)自己的窗口") }
                                    .buttonStyle(LKButtonStyle())
                            }
                        }
                        .padding(.vertical, 8)
                        .overlay(alignment: .top) { if i > 0 { Rectangle().fill(p.border).frame(height: 1) } }
                    }
                    if let primary = answer.primary {
                        HStack(spacing: 8) {
                            Button(primary) { model.closeAsk(); model.show("交给应用去做（只在你点了以后）") }
                                .buttonStyle(LKButtonStyle(kind: .primary))
                        }
                        .padding(.top, 10)
                    }
                }
                .lkCard(padding: EdgeInsets(top: 4, leading: 14, bottom: 10, trailing: 14), fill: p.bg)
            }
            HStack(spacing: 6) {
                Spacer()
                if model.page == .today || !answer.rows.isEmpty {
                    Button { model.go(.search) } label: { IconText("搜索结果", symbol: "magnifyingglass") }.buttonStyle(LKButtonStyle(kind: .text))
                }
                Button { model.pinAnswer() } label: { IconText("钉到今天", symbol: "pin") }.buttonStyle(LKButtonStyle(kind: .text))
                Button { model.expandAnswer() } label: { IconText("展开", symbol: "arrow.up.left.and.arrow.down.right") }.buttonStyle(LKButtonStyle(kind: .text))
            }
        }
        .padding(14)
        .frame(width: 640, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: LKRadius.sheet, style: .continuous).fill(p.card.opacity(0.97)))
        .overlay(RoundedRectangle(cornerRadius: LKRadius.sheet, style: .continuous).strokeBorder(p.border, lineWidth: 1))
        .shadow(color: .black.opacity(0.18), radius: 25, y: 12)
    }
}
