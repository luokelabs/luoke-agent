import LuokeA2UICore
import SwiftUI

/// 一张卡片活的样子：宿主把消息喂进来；用户改的值写进数据模型。渲染器不碰文件（读写由宿主做）。
@MainActor
public final class SurfaceModel: ObservableObject, Identifiable {
    public nonisolated let id: String
    @Published public private(set) var surface: Surface
    /// 宿主在处理一次点按时设成 true：按钮先灰掉
    @Published public var busy = false
    /// 正在等答复的是哪个按钮（busy 时宿主设的组件 id）：它画一个转圈，看得出点下去了、在做（luoke-scan#152：只是灰掉，看不出在清理）
    @Published public var pressed: String?
    /// 用户改了数据模型（给整份）；宿主去抖、存起来
    public var onDataChange: ((JSONValue) -> Void)?

    public init(surface: Surface) {
        self.id = surface.surfaceId
        self.surface = surface
    }

    /// 运行中的一组更新（updateComponents / updateDataModel / deleteSurface）：整组查过才换上，查不过抛错、原样不动。
    public func apply(_ messages: [JSONValue]) throws {
        surface = try surface.updated(with: messages)
    }

    /// 一条一条收（边收边画）：不查整张。组件常常比它绑定的数据先到，逐条查会把整张卡片拒掉；
    /// 由已经查过整组的一方（例如 agent 的核心）发来时用它。
    public func receive(_ message: JSONValue) throws {
        var s = surface
        try s.apply(message)
        surface = s
    }

    /// 用户改了一个值。
    public func set(_ path: String, _ value: JSONValue) {
        guard let d = try? surface.data.setting(path, to: value) else { return }
        surface.data = d
        onDataChange?(d)
    }

    public func value(_ path: String) -> JSONValue? { try? surface.data.value(at: path) }

    /// 密码框里填的字清掉（工具协议 §4 secureField）。只改内存里的数据模型。
    /// `only`：点了按钮以后只清这次交出去的那几个（`Surface.sentSecureFieldPaths`），没交的照留；不给（离开这一页时）全清
    public func clearSecureFields(only: [String]? = nil) {
        for p in surface.secureFieldPaths where (only?.contains(p) ?? true) && value(p) != .string("") {
            set(p, .string(""))
        }
    }
}

/// 画一张卡片的哪一部分。宽窗口里应用页分两栏：根 Column 下面写了 `"placement": "aside"` 的段画进侧栏（`aside`），
/// 别的画在主栏（`main`）；别的时候整张照原来的顺序画（`all`）。见工具协议 §4「宽窗口的侧栏」。
/// 应用页分段画时（§4 pageSections，`Surface.pageBlocks`）一次只画一段：`section(编号, skip:)` 从这个组件画起，
/// 它是一列时跳过前 `skip` 个子组件（画在卡片外面的小标题）
public enum SurfacePart: Sendable, Equatable { case all, main, aside, section(String, skip: Int) }

/// 画一张卡片。点了按钮回调（按钮编号、动作名、按当前数据模型解析好的上下文）。
public struct SurfaceView: View {
    @ObservedObject var model: SurfaceModel
    let onAction: (String, String, JSONValue) -> Void
    let part: SurfacePart
    @Environment(\.a2uiButtonStyle) private var buttonStyleHook
    @Environment(\.a2uiDrawn) private var drawn
    @Environment(\.a2uiCardChrome) private var cardChrome
    @Environment(\.a2uiFont) private var fontHook
    @Environment(\.a2uiIcon) private var iconHook
    @Environment(\.a2uiFirstLineInset) private var firstLineInset
    /// 点开了的可折叠段（`Column` 的 `collapsed`）
    @State private var opened: Set<String> = []

    public init(model: SurfaceModel, part: SurfacePart = .all,
                onAction: @escaping (_ componentId: String, _ name: String, _ context: JSONValue) -> Void) {
        self.model = model
        self.part = part
        self.onAction = onAction
    }

    public var body: some View {
        if part == .aside && model.surface.asideSections.isEmpty {
            EmptyView()
        } else if case .section(let id, _) = part {
            node(id, allowed: Catalog.all[model.surface.catalogId] ?? [], depth: 0)
        } else {
            node("root", allowed: Catalog.all[model.surface.catalogId] ?? [], depth: 0)
        }
    }

    /// 一列里画哪几个子组件。分两栏画时根 Column 只留这一栏的段：侧栏最上面那段开头的分隔线不画（上面没有要隔开的），
    /// 主栏里紧跟在挪走的侧栏段后面的分隔线也不画（它隔开的是挪走的那段）
    private func shownKids(_ id: String, _ c: [String: JSONValue], depth: Int) -> [String] {
        var kids = children(c)
        if case .section(let sid, let skip) = part {
            guard depth == 0 && id == sid else { return kids }
            // 一段一张卡片：开头、结尾的分隔线不画（卡片之间本来就隔开了）
            var shown = Array(kids.dropFirst(skip))
            while let f = shown.first, comps[f]?["component"]?.string == "Divider" { shown.removeFirst() }
            while let l = shown.last, comps[l]?["component"]?.string == "Divider" { shown.removeLast() }
            return shown
        }
        guard part != .all else { return kids }
        let aside = model.surface.asideSections
        if depth == 0 {
            let all = kids
            kids = all.indices.filter { i in
                if aside.contains(all[i]) != (part == .aside) { return false }
                return !(part == .main && i > 0 && aside.contains(all[i - 1]) && comps[all[i]]?["component"]?.string == "Divider")
            }.map { all[$0] }
        }
        if part == .aside, let first = aside.first, let lead = comps[first].map(children)?.first,
           comps[lead]?["component"]?.string == "Divider" {
            kids.removeAll { $0 == lead }
        }
        return kids
    }

    private var comps: [String: [String: JSONValue]] { model.surface.components }

    private func text(_ v: JSONValue?) -> String {
        if let p = v?.bindingPath { return Self.keepTail(model.value(p)?.string ?? "") }
        return Self.keepTail(v?.string ?? "")
    }

    /// 句尾不超过 6 个汉字的一段（「」后面的「可能是病毒」）不在中间折行：字之间加 U+2060（不占位、读屏不念），
    /// 长文件名把前面撑满时整段挪到下一行，不剩「是病毒」三个字的尾巴
    public static func keepTail(_ s: String) -> String {
        var tail: [Character] = []
        for ch in s.reversed() {
            guard let u = ch.unicodeScalars.first, (0x4E00...0x9FFF).contains(u.value) else { break }
            tail.insert(ch, at: 0)
        }
        guard tail.count >= 2, tail.count <= 6, tail.count < s.count else { return s }
        return String(s.dropLast(tail.count)) + tail.map(String.init).joined(separator: "\u{2060}")
    }

    /// 一列分成块：「正文 [+ 小字] + 一两个按钮的一行」是一块（下标），别的一个组件一块
    private func itemBlocks(_ ids: [String]) -> [[Int]] {
        var out: [[Int]] = []
        var i = 0
        while i < ids.count {
            // 正文开头（可再跟一行小字），或单独一行小字（「上一轮 …」「自动清理：关」这样的状态）后面跟按钮
            let k0 = Self.kind(comps[ids[i]])
            let prevKind = i > 0 ? Self.kind(comps[ids[i - 1]]) : ""
            // 跟在一条（正文、选择框）后面的小字是那一条的说明，不自己成一条
            // 一块开头的那行小字（「多是 CoinDigest…」）是说明，按钮照常放在下面，不拉到它右边
            if comps[ids[i]]?["component"]?.string == "Text", k0 == "body" || (k0 == "caption" && prevKind != "body" && i > 0) {
                var j = i + 1
                if k0 == "body", j < ids.count, Self.kind(comps[ids[j]]) == "caption" { j += 1 }
                if j < ids.count, isButtonRow(ids[j]) {
                    out.append(Array(i...j))
                    i = j + 1
                    continue
                }
            }
            out.append([i])
            i += 1
        }
        return out
    }

    /// 一条的标题（正文后面跟着说明或按钮）用中等字重，和下面的小字分得开；别的照常画
    private func item(_ kids: [String], _ k: Int, allowed: Set<String>, depth: Int) -> AnyView {
        let c = comps[kids[k]]
        let next = k + 1 < kids.count ? kids[k + 1] : ""
        // 紧跟在卡片标题后面的正文是标题的说明（急事卡「病毒库认出了它…」），不算条目标题
        let afterHeading = k > 0 && Self.kind(comps[kids[k - 1]]) == "heading"
        if drawn != nil, !afterHeading, c?["component"]?.string == "Text", Self.kind(c) == "body", !next.isEmpty,
           Self.kind(comps[next]) == "caption" || isButtonRow(next) {
            return AnyView(styled(Text(text(c?["text"])).fontWeight(.medium), c?["variant"]?.string).textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading).fixedSize(horizontal: false, vertical: true))
        }
        return node(kids[k], allowed: allowed, depth: depth + 1)
    }

    /// 执行行：只有一个按钮，前面可以有一段字（「另外 1 样照建议清理」「按上面的选择清理」）。一排好几个按钮的
    /// （邮件方案卡「按这个处理 / 加入日程 / 在邮件助手里看」）照常从正文起点排
    private func isRunRow(_ id: String) -> Bool {
        guard let c = comps[id] else { return false }
        let kids = children(c)
        let buttons = kids.filter { comps[$0]?["component"]?.string == "Button" }
        let texts = kids.filter { comps[$0]?["component"]?.string == "Text" }
        return buttons.count == 1 && texts.count == kids.count - 1 && texts.count <= 1 && !model.surface.opensURL(buttons[0])
    }

    /// 一行里是一两个按钮（没有打开网页的：去哪个网站要写在按钮下面，见 Row）
    private func isButtonRow(_ id: String) -> Bool {
        guard let c = comps[id], c["component"]?.string == "Row" else { return false }
        let kids = children(c)
        return (1...2).contains(kids.count)
            && kids.allSatisfy { comps[$0]?["component"]?.string == "Button" && !model.surface.opensURL($0) }
    }

    /// 一排一两个按钮，或者以它收尾的一段（写了 `placement` 的 `Column`）：画在一栏里时和不包着一样，下一样空 16
    private func endsWithButtons(_ id: String) -> Bool {
        if isButtonRow(id) { return true }
        guard let c = comps[id], c["component"]?.string == "Column", c["placement"] != nil, let last = children(c).last else { return false }
        return isButtonRow(last)
    }

    private func children(_ c: [String: JSONValue]) -> [String] {
        c["children"]?.array?.compactMap { $0.string } ?? []
    }

    /// 图标：宿主给了 Lucide 的图就用它（模板图，跟着字色），不然用最接近的系统符号
    private func iconView(_ name: String?, size: CGFloat) -> AnyView { Self.icon(name, size: size, hook: iconHook) }

    /// 一个图标（组件目录里的名字）：宿主给了 Lucide 的图就用它，不然用最接近的系统符号（选择框和它的菜单也用）
    static func icon(_ name: String?, size: CGFloat, hook: ((String) -> Image?)?) -> AnyView {
        if let hook, let lucide = A2UI.lucide(name), let img = hook(lucide) {
            return AnyView(img.resizable().renderingMode(.template).aspectRatio(contentMode: .fit).frame(width: size, height: size))
        }
        return AnyView(Image(systemName: Self.symbol(name)).font(.system(size: size * 0.85)).frame(width: size, height: size))
    }

    /// 窗口自己用的图标（不在组件目录里的，例如打开网页的 ↗）：宿主给了就用，不然用系统符号
    private func hostIcon(_ lucide: String, fallback: String, size: CGFloat) -> AnyView {
        if let img = iconHook?(lucide) {
            return AnyView(img.resizable().renderingMode(.template).aspectRatio(contentMode: .fit).frame(width: size, height: size))
        }
        return AnyView(Image(systemName: fallback).font(.system(size: size * 0.85, weight: .semibold)))
    }

    /// 一段字：标签（badge）、加粗（strong）、最多几行（maxLines，省略的部分在悬停提示里）。inline：和别的字并排，不撑满一行
    private func textView(_ c: [String: JSONValue], inline: Bool) -> AnyView {
        let s = text(c["text"])
        let variant = c["variant"]?.string
        if variant == "badge" { return AnyView(DrawnBadge(text: s, tone: c["tone"]?.string, colors: drawn)) }
        let t = variant == "strong" ? Text(s).fontWeight(.semibold) : Text(s)
        var v = AnyView(styled(t, variant == "strong" ? "body" : variant).textSelection(.enabled))
        if let n = c["maxLines"]?.number {
            v = AnyView(v.lineLimit(Int(n)).truncationMode(.tail).help(s))
        }
        if inline { return v }
        return AnyView(v.frame(maxWidth: .infinity, alignment: .leading).fixedSize(horizontal: false, vertical: true))
    }

    /// 并排在一行里的几段字：Row 里只有字和图标，其中有标签、加粗或写了 maxLines 的
    private func isInlineLine(_ id: String) -> Bool {
        guard let c = comps[id], c["component"]?.string == "Row", c["justify"] == nil else { return false }
        let kids = children(c).compactMap { comps[$0] }
        return !kids.isEmpty && kids.allSatisfy { ["Text", "Icon"].contains($0["component"]?.string ?? "") }
            && kids.contains { ["badge", "strong"].contains($0["variant"]?.string ?? "") || $0["maxLines"] != nil }
    }

    /// 一组名字小块（§4 chips）：Row 里只有 badge，最后可以再跟一段 caption（「等 12 个」）。挨得近、放不下换行
    private func isChips(_ id: String) -> Bool {
        guard let c = comps[id], c["component"]?.string == "Row", c["justify"] == nil else { return false }
        let ids = children(c)
        let kids = ids.compactMap { comps[$0] }
        guard kids.count == ids.count else { return false }
        let badges = kids.prefix { $0["component"]?.string == "Text" && $0["variant"]?.string == "badge" }
        let rest = kids.dropFirst(badges.count)
        return !badges.isEmpty && (rest.isEmpty
            || rest.count == 1 && rest.first?["component"]?.string == "Text" && rest.first?["variant"]?.string == "caption")
    }

    /// 卡片里一块的小标题：一行 Row，一个图标和一段字，可以再跟一段字写数（「判为可疑 206」）
    private func isSectionTitle(_ id: String) -> Bool {
        guard let c = comps[id], c["component"]?.string == "Row" else { return false }
        let kids = children(c).compactMap { comps[$0] }
        return (2...3).contains(kids.count) && kids[0]["component"]?.string == "Icon" && kids[1]["component"]?.string == "Text"
            && kids[1]["variant"] == nil && (kids.count == 2 || kids[2]["component"]?.string == "Text" && kids[2]["variant"]?.string != "badge")
    }

    private func sectionTitle(_ id: String) -> some View {
        let kids = children(comps[id] ?? [:]).compactMap { comps[$0] }
        return HStack(spacing: 6) {
            iconView(kids.first?["name"]?.string, size: 14).foregroundStyle(drawn?.mutedFg ?? .secondary)
            Text(text(kids[1]["text"])).font((fontHook?("caption") ?? .callout).weight(.semibold))
                .foregroundStyle(drawn?.fg ?? .primary)
            if kids.count == 3 {
                Text(text(kids[2]["text"])).font((fontHook?("caption") ?? .callout).weight(.semibold))
                    .foregroundStyle(drawn?.mutedFg ?? .secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isHeader)
    }

    /// 一项右边的选择框和按钮：`"justify": "spaceBetween"` 的 Row 里第一块后面的那些
    private var trailingIds: Set<String> {
        var out = Set<String>()
        for (_, c) in comps where c["component"]?.string == "Row" && c["justify"]?.string == "spaceBetween" {
            out.formUnion(children(c).dropFirst())
        }
        return out
    }

    /// 一条后面的按钮：一列里紧跟在一条（正文开头，可再跟一行小字）后面的一排一两个按钮
    private var itemActionButtons: Set<String> {
        var out = Set<String>()
        for (_, c) in comps where c["component"]?.string == "Column" {
            let kids = children(c)
            for i in kids.indices where i > 0 && isButtonRow(kids[i]) {
                let a = Self.kind(comps[kids[i - 1]]), b = i > 1 ? Self.kind(comps[kids[i - 2]]) : ""
                let titled = comps[kids[i - 1]]?["component"]?.string == "Text" && a == "body"
                    || (a == "caption" && b == "body" && comps[kids[i - 2]]?["component"]?.string == "Text")
                if titled { out.formUnion(children(comps[kids[i]] ?? [:])) }
            }
        }
        return out
    }

    /// 写了 `collapsed` 的一列：先收起，只画那一句和一个箭头，点开才画里面的（工具协议 §4）
    private func collapsible(_ id: String, _ c: [String: JSONValue], _ inner: AnyView) -> AnyView {
        guard let summary = c["collapsed"]?.string, !summary.isEmpty else { return inner }
        let open = opened.contains(id)
        return AnyView(VStack(alignment: .leading, spacing: 6) {
            Button {
                withAnimation(.easeOut(duration: 0.15)) { if open { opened.remove(id) } else { opened.insert(id) } }
            } label: {
                HStack(spacing: 4) {
                    iconView("chevron-right", size: 14).rotationEffect(.degrees(open ? 90 : 0))
                    Text(summary)
                }
                .font(fontHook?("caption") ?? .callout)
                .foregroundStyle(drawn?.mutedFg ?? .secondary)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(summary)
            .accessibilityValue(open ? "已展开" : "已收起")
            if open { inner }
        })
    }

    private func node(_ id: String, allowed: Set<String>, depth: Int) -> AnyView {
        guard depth < 32, let c = comps[id], let type = c["component"]?.string, allowed.contains(type) else {
            return AnyView(EmptyView())
        }
        switch type {
        case "Text":
            return textView(c, inline: false)
        case "Column", "List":
            return collapsible(id, c, column(id, c, type, allowed: allowed, depth: depth))
        case "Row":
            let kids = children(c)
            if isChips(id) {
                return AnyView(FlowLayout(spacing: 4) {
                    ForEach(kids, id: \.self) { textView(comps[$0] ?? [:], inline: true).fixedSize() }
                }
                .frame(maxWidth: .infinity, alignment: .leading))
            }
            if isInlineLine(id) {
                // 一行里并排的几段字（发件人、主题、截止标签；卡片标题和邮箱标签）：写了 maxLines 的那段放不下就省略，别的照原样
                return AnyView(HStack(alignment: .center, spacing: 6) {
                    ForEach(kids, id: \.self) { k in
                        let kc = comps[k] ?? [:]
                        if kc["component"]?.string == "Icon" {
                            iconView(kc["name"]?.string, size: 14).foregroundStyle(drawn?.mutedFg ?? .secondary)
                        } else if kc["maxLines"] != nil {
                            textView(kc, inline: true).layoutPriority(-1)
                        } else if kc["variant"]?.string == "strong" || kc["variant"]?.string == "badge" {
                            textView(kc, inline: true).fixedSize()
                        } else {
                            textView(kc, inline: true).fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading))
            }
            if kids.count == 2, comps[kids[0]]?["component"]?.string == "Icon", comps[kids[1]]?["component"]?.string == "Column" {
                // 一项前面的图标（§4 itemIcons，扫描页）：图标在左、和第一行字对齐，右边一列（标题、说明）占满。
                // 只认「图标 + 一列」：「图标 + 一段字」是一块的小标题
                return AnyView(HStack(alignment: .top, spacing: 10) {
                    iconView(comps[kids[0]]?["name"]?.string, size: 16).foregroundStyle(drawn?.mutedFg ?? .secondary).padding(.top, 2)
                    node(kids[1], allowed: allowed, depth: depth + 1).frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxWidth: .infinity, alignment: .leading))
            }
            if c["justify"]?.string == "spaceEvenly", kids.count > 1 {   // 几块一样宽、各自靠左（一排数：扫描页顶上的三个数）
                return AnyView(HStack(alignment: .top, spacing: 16) {
                    ForEach(kids, id: \.self) { node($0, allowed: allowed, depth: depth + 1).frame(maxWidth: .infinity, alignment: .leading) }
                })
            }
            if c["justify"]?.string == "spaceBetween", let first = kids.first {   // 左边一块、右边一块（A2UI Row 的 justify）
                return AnyView(SpaceBetweenRow {   // 上下居中：标题和右边的按钮、文字和图标对齐；放不下时右边那块折到下一行
                    node(first, allowed: allowed, depth: depth + 1)
                    HStack(spacing: 6) {   // 右边一块按自己的宽度：选择框、小按钮挨着
                        ForEach(Array(kids.dropFirst()), id: \.self) { node($0, allowed: allowed, depth: depth + 1).fixedSize() }
                    }
                })
            }
            // 一段字后面跟按钮（「另外 1 样照建议处理」「按这个处理」）：字在左，按钮靠右
            if let first = kids.first, comps[first]?["component"]?.string == "Text", kids.count > 1,
               kids.dropFirst().allSatisfy({ comps[$0]?["component"]?.string == "Button" }) {
                return AnyView(HStack(alignment: .center, spacing: 12) {
                    node(first, allowed: allowed, depth: depth + 1)
                    ForEach(Array(kids.dropFirst()), id: \.self) { node($0, allowed: allowed, depth: depth + 1).fixedSize() }
                })
            }
            return AnyView(FlowLayout(spacing: 8) {
                ForEach(kids, id: \.self) { node($0, allowed: allowed, depth: depth + 1) }
            })
        case "Card":
            let inner = node(c["child"]?.string ?? "", allowed: allowed, depth: depth + 1)
            if !cardChrome { return inner }
            return AnyView(GroupBox { inner.padding(6) })
        case "ProgressBar":
            return AnyView(DrawnProgress(value: c["value"]?.number ?? 0, colors: drawn))
        case "Divider":
            // 分段：上下各多留 8，段和段之间看得出是两块
            if let d = drawn { return AnyView(Rectangle().fill(d.border).frame(height: 1).padding(.vertical, 8)) }
            return AnyView(Divider())
        case "Icon":
            return AnyView(iconView(c["name"]?.string, size: 16).foregroundStyle(drawn?.mutedFg ?? .secondary))
        case "Button":
            return AnyView(button(id, c))
        case "CheckBox":
            return AnyView(checkBox(c))
        case "ChoicePicker":
            return AnyView(choice(id, c))
        case "TextField", "DateTimeInput":
            return AnyView(field(c))
        case "Slider":
            return AnyView(slider(c))
        default:
            return AnyView(EmptyView())
        }
    }

    /// 一列（Column、List）
    private func column(_ id: String, _ c: [String: JSONValue], _ type: String, allowed: Set<String>, depth: Int) -> AnyView {
        let kids = shownKids(id, c, depth: depth)
        let gap = type == "List" ? 4 : CGFloat(c["gap"]?.number ?? 8)
        var tops = type == "List" || c["gap"] != nil ? kids.indices.map { $0 == 0 ? 0 : gap } : Self.itemSpacing(kids.map { comps[$0] })
        for i in kids.indices where i > 0 && c["gap"] == nil && isInlineLine(kids[i - 1]) && Self.kind(comps[kids[i]]) == "caption" {
            tops[i] = 2   // 一行（发件人、主题、标签）下面的理由贴着它
        }
        if type == "List", let d = drawn {
            // 一项一行，项和项之间一条细线（逐封列的邮件，工具协议 §4）
            return AnyView(VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(kids.enumerated()), id: \.element) { i, kid in
                    node(kid, allowed: allowed, depth: depth + 1)
                        .padding(.vertical, 9)
                        .overlay(alignment: .top) { if i > 0 { Rectangle().fill(d.border).frame(height: 1) } }
                }
            })
        }
        if type == "Column", c["gap"] == nil, drawn != nil {
            // 一条（正文、可有一行小字）后面只跟一两个按钮：按钮放到这一条的右边，和选择框一样，一条少占一行
            let blocks: [[Int]] = itemBlocks(kids)
            return AnyView(VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(blocks.enumerated()), id: \.offset) { (bi: Int, b: [Int]) in
                  Group {
                    let afterHeading: Bool = bi > 0 && Self.kind(comps[kids[blocks[bi - 1].last!]]) == "heading"
                    // 上一条以一排按钮收尾：按钮结束了那一条，下一样空 16（「打开自动清理」下面的「病毒库更新于」不贴着它）
                    let afterButtons: Bool = bi > 0 && endsWithButtons(kids[blocks[bi - 1].last!])
                    // 上一块是分隔线后面的段标题（「自动清理：关」「要你看看的 · 4 样」）：这一条属于那一段，贴近一点（8），不空 16 像另起一件事
                    let afterSection: Bool = bi >= 2 && blocks[bi - 1].count == 1 && Self.kind(comps[kids[blocks[bi - 1][0]]]) == "caption"
                        && comps[kids[blocks[bi - 2][0]]]?["component"]?.string == "Divider"
                    let top: CGFloat = bi == 0 ? 0 : (b.count > 1 ? (afterHeading ? 4 : afterSection ? 8 : 16) : (afterButtons ? max(16, tops[b[0]]) : tops[b[0]]))
                    if b.count > 1 {
                        // 字在按钮左边放得下一行才把按钮放右边；放不下就按钮回到下面，不折出两三个字的尾巴
                        ViewThatFits(in: .horizontal) {
                            HStack(alignment: .center, spacing: 12) {
                                VStack(alignment: .leading, spacing: 2) {
                                    ForEach(b.dropLast(), id: \.self) { (k: Int) in
                                        item(kids, k, allowed: allowed, depth: depth).fixedSize(horizontal: true, vertical: false)
                                    }
                                }
                                Spacer(minLength: 12)
                                node(kids[b[b.count - 1]], allowed: allowed, depth: depth + 1).fixedSize()
                            }
                            VStack(alignment: .leading, spacing: 6) {
                                VStack(alignment: .leading, spacing: 2) {
                                    ForEach(b.dropLast(), id: \.self) { (k: Int) in item(kids, k, allowed: allowed, depth: depth) }
                                }
                                node(kids[b[b.count - 1]], allowed: allowed, depth: depth + 1)
                            }
                        }
                        .padding(.top, top)
                    } else if isSectionTitle(kids[b[0]]),
                              bi == 0 || comps[kids[blocks[bi - 1][0]]]?["component"]?.string == "Divider" {
                        // 卡片里分块：分隔线后面一行「图标 + 字」是这一块的小标题（待处理、可以整理、判为可疑）
                        sectionTitle(kids[b[0]]).padding(.top, top)
                    } else if bi > 0, Self.kind(comps[kids[b[0]]]) == "caption",
                              comps[kids[blocks[bi - 1][0]]]?["component"]?.string == "Divider" {
                        // 分隔线后面的一行小字是这一段的标题：小字、次要颜色、半粗（和「今天」的「要你决定 1」一样），
                        // 和中等字重的条目标题、常规的说明分成三级
                        styled(Text(text(comps[kids[b[0]]]?["text"])).fontWeight(.semibold), "caption")
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .accessibilityAddTraits(.isHeader)
                            .padding(.top, top)
                    } else if bi > 0, comps[kids[b[0]]]?["component"]?.string == "Row",
                              comps[kids[blocks[bi - 1].last!]]?["component"]?.string == "ChoicePicker",
                              isRunRow(kids[b[0]]) {
                        // 一组选择框下面的执行行（「另外 1 样照建议清理」「按上面的选择清理」）：上面空 16，按钮固定在右端，
                        // 看得出它管的是上面整组，不是最后一条
                        let kid = kids[b[0]]
                        if comps[children(comps[kid] ?? [:]).first ?? ""]?["component"]?.string == "Text" {
                            node(kid, allowed: allowed, depth: depth + 1).padding(.top, 16)
                        } else {
                            node(kid, allowed: allowed, depth: depth + 1).fixedSize()
                                .frame(maxWidth: .infinity, alignment: .trailing).padding(.top, 16)
                        }
                    } else if bi > 0, comps[kids[b[0]]]?["component"]?.string == "Row",
                              comps[kids[blocks[bi - 1].last!]]?["component"]?.string == "ChoicePicker" {
                        // 一组选择框下面一排好几个按钮（邮件方案卡）：照常从正文起点排，上面同样空 16，是整张卡的动作
                        node(kids[b[0]], allowed: allowed, depth: depth + 1).padding(.top, 16)
                    } else {
                        item(kids, b[0], allowed: allowed, depth: depth).padding(.top, top)
                    }
                  }
                  .padding(.trailing, depth == 0 && bi == 0 ? firstLineInset : 0)   // 第一行让出右上角的时间
                }
            })
        }
        return AnyView(VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(kids.enumerated()), id: \.element) { i, kid in
                node(kid, allowed: allowed, depth: depth + 1).padding(.top, tops[i])
            }
        })
    }

    private func styled(_ t: Text, _ variant: String?) -> some View {
        if let f = fontHook?(variant) {
            if variant == "caption", let d = drawn { return AnyView(t.font(f).foregroundStyle(d.mutedFg)) }
            return AnyView(t.font(f))
        }
        switch variant {
        case "h1": return AnyView(t.font(.title))
        case "h2": return AnyView(t.font(.title2))
        case "h3": return AnyView(t.font(.title3))
        case "h4": return AnyView(t.font(.headline))
        case "h5": return AnyView(t.font(.subheadline.weight(.semibold)))
        case "caption": return AnyView(t.font(.caption).foregroundStyle(.secondary))
        default: return AnyView(t)
        }
    }

    private func button(_ id: String, _ c: [String: JSONValue]) -> AnyView {
        let (label, icon) = model.surface.buttonLabel(id)
        // 一项右边的小按钮（「加入日程 11-12 16:00」）画小一号
        let variant = trailingIds.contains(id) ? "mini" : c["variant"]?.string
        // 画成开关的按钮：点了还是按钮的动作，开没开听工具重画的页面。打开网页的按钮不画成开关
        if c["variant"]?.string == "switch", let on = c["on"]?.bool, !model.surface.opensURL(id) {
            return AnyView(DrawnSwitch(label: label, on: on, colors: drawn) {
                guard let (name, ctx) = try? model.surface.action(id) else { return }
                onAction(id, name, ctx)
            }.disabled(model.busy))
        }
        // 打开网页的按钮：去哪个网站用 agent 核心写的 `site`（工具协议 §5），写进悬停提示和读屏念的字（「加入日程 · 会打开 …」）；
        // 没写就不让点
        let opens = model.surface.opensURL(id)
        let site = model.surface.openSite(id)
        let tip = c["tooltip"]?.string ?? label
        let help = opens ? "\(tip) · 会打开 \(site ?? "网页")" : tip
        let run = {
            guard let (name, ctx) = try? model.surface.action(id) else { return }
            onAction(id, name, ctx)
        }
        let content: AnyView
        if model.busy, model.pressed == id {
            // 点下去了、在等答复：转圈换掉图标，字照旧
            let iconOnly = icon != nil && !opens && itemActionButtons.contains(id) && model.surface.buttonsInRow(id) > 1
            content = AnyView(HStack(spacing: 6) {
                BusySpinner().frame(width: 14, height: 14)
                if !iconOnly { Text(label) }
            })
        } else if let icon, !opens, itemActionButtons.contains(id), model.surface.buttonsInRow(id) > 1 {
            // 一条后面的几个按钮（扫描页的「移到废纸篓」「不是病毒」）：有图标的只画图标，字放在悬停提示里、给读屏念（工具协议 §4）
            content = AnyView(iconView(icon, size: 14).frame(minWidth: 14))
        } else if let icon {
            content = AnyView(HStack(spacing: 6) { iconView(icon, size: 14); Text(label) })
        } else if opens {
            // 打开网页、没给图标的：带 ↗，看得出会离开螺壳去网页
            content = AnyView(HStack(spacing: 4) {
                Text(label)
                hostIcon("arrow-up-right", fallback: "arrow.up.right", size: 12)
            })
        } else {
            content = AnyView(Text(label))
        }
        let b = Button(action: run) { content }
            .disabled(model.busy || (opens && site == nil) || !model.surface.buttonCountAllows(id))   // §4 countLabel：0 项时灰掉（countAlso：选了别的值时不灰）
            .help(help)
            .accessibilityLabel(help)
        return AnyView(styledButton(b, variant).fixedSize())   // 字不截断：放不下整行换行
    }

    private func styledButton(_ b: some View, _ variant: String?) -> some View {
        Group {
            if let hook = buttonStyleHook {
                // 焦点环在按钮上画（按钮样式里读不到焦点）：深色的「按这个处理」原来拿到焦点看不出来
                b.buttonStyle(hook(variant)).modifier(KeyFocusable(radius: 7))
            } else {
                switch variant {
            case "primary": b.buttonStyle(.borderedProminent)
            case "borderless": b.buttonStyle(.borderless).controlSize(.small)   // 每一行上的小动作
            case "destructive": b.buttonStyle(.bordered).tint(.red)                 // 删除、标为不对这类
            default: b.buttonStyle(.bordered)
                }
            }
        }
    }

    private func checkBox(_ c: [String: JSONValue]) -> AnyView {
        let path = c["value"]?.bindingPath
        let binding = Binding<Bool>(
            get: { path.flatMap { model.value($0)?.bool } ?? c["value"]?.bool ?? false },
            set: { if let p = path { model.set(p, .bool($0)) } })
        if let d = drawn { return AnyView(DrawnCheckBox(label: text(c["label"]), on: binding, colors: d)) }
        let t = Toggle(text(c["label"]), isOn: binding)
        #if os(macOS)
        return AnyView(t.toggleStyle(.checkbox))
        #else
        return AnyView(t)
        #endif
    }

    private func choice(_ id: String, _ c: [String: JSONValue]) -> AnyView {
        let path = c["value"]?.bindingPath
        let options = c["options"]?.array ?? []
        let labels = options.map { (value: $0["value"]?.string ?? "", label: text($0["label"])) }
        let binding = Binding<String>(
            get: { (path.flatMap { model.value($0) } ?? c["value"])?.array?.first?.string ?? "" },
            set: { v in if let p = path { model.set(p, .array([.string(v)])) } })   // 单选也是数组（A2UI 规定）
        let short = labels.count <= 4 && labels.allSatisfy { $0.label.count <= 6 }
        let label = text(c["label"])
        // 一项右边的选择框：那一项的字已经画在左边，这里不再写，只给读屏念
        let shownLabel = trailingIds.contains(id) ? "" : label
        if let d = drawn {
            // n 选 1 画成一个小框：写着现在选的（工具建议的），点开再改。不画成一排分段（像切换标签页，负责人 11-06）。
            // 框放在这一项的同一行、靠右：一项一行，看得出框是哪一项的（之前框在下一行，像下一项的开头）。
            // 真窗口和截图是同一个框，点了弹出菜单（现在选的那一项打勾）
            let pill = ChoiceBox(options: zip(labels, options).map { ChoiceBox.Option(value: $0.value, label: $0.label, icon: $1["icon"]?.string) },
                                 selected: binding.wrappedValue, label: label, colors: d) { binding.wrappedValue = $0 }
                .disabled(model.busy)
            return AnyView(HStack(alignment: .center, spacing: 12) {
                if !shownLabel.isEmpty {
                    // 这一项的标题：字体和正文一样走宿主的 a2uiFont（一件件处理里正文大一号，说明小一号，#52）
                    styled(Text(shownLabel), nil).frame(maxWidth: .infinity, alignment: .leading).fixedSize(horizontal: false, vertical: true)
                } else {
                    Spacer(minLength: 0)
                }
                pill
            }.frame(minHeight: 28))
        }
        return AnyView(VStack(alignment: .leading, spacing: 4) {
            if !label.isEmpty {
                Text(label).frame(maxWidth: .infinity, alignment: .leading).fixedSize(horizontal: false, vertical: true)
            }
            let picker = Picker(label, selection: binding) {
                ForEach(labels, id: \.value) { Text($0.label).tag($0.value) }
            }.labelsHidden()
            if short { picker.pickerStyle(.segmented).fixedSize() } else { picker.pickerStyle(.menu).fixedSize() }
        })
    }

    private func field(_ c: [String: JSONValue]) -> AnyView {
        let path = c["value"]?.bindingPath
        let binding = Binding<String>(
            get: { path.flatMap { model.value($0)?.string } ?? c["value"]?.string ?? "" },
            set: { if let p = path { model.set(p, .string($0)) } })
        // 密码框（工具协议 §4 secureField，只在应用页上）：填的字画成圆点
        let secure = model.surface.page && c["component"]?.string == "TextField" && c["variant"]?.string == "obscured"
        if let d = drawn, d.staticFields {
            let v = binding.wrappedValue
            let shown = secure ? String(repeating: "•", count: min(v.count, 12)) : v
            return AnyView(DrawnBox(text: v.isEmpty ? text(c["label"]) : shown, placeholder: v.isEmpty, chevron: false, colors: d))
        }
        if let d = drawn {
            let input = secure ? AnyView(SecureField(text(c["label"]), text: binding)) : AnyView(TextField(text(c["label"]), text: binding))
            return AnyView(input.textFieldStyle(.plain).font(.system(size: 13)).modifier(KeyFocusRevealing())
                .padding(.horizontal, 10).frame(minHeight: 30)
                .background(RoundedRectangle(cornerRadius: 8).fill(d.card))
                .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(d.input, lineWidth: 1)))
        }
        if secure { return AnyView(SecureField(text(c["label"]), text: binding).textFieldStyle(.roundedBorder)) }
        return AnyView(TextField(text(c["label"]), text: binding).textFieldStyle(.roundedBorder))
    }

    private func slider(_ c: [String: JSONValue]) -> some View {
        let path = c["value"]?.bindingPath
        let lo = c["min"]?.number ?? 0, hi = c["max"]?.number ?? 1
        let binding = Binding<Double>(
            get: { path.flatMap { model.value($0)?.number } ?? c["value"]?.number ?? lo },
            set: { if let p = path { model.set(p, .number($0)) } })
        return VStack(alignment: .leading, spacing: 2) {
            let label = text(c["label"])
            if !label.isEmpty { Text(label) }
            Slider(value: binding, in: lo...max(hi, lo + 1e-9))
        }
    }

    /// 组件目录里的图标名 → 系统符号
    /// 一列里每个组件上面空多少：一条（正文一行，下面的小字说明、按钮）是一组，说明贴着标题（2），按钮离说明 6；
    /// 一组完了下一条正文空 14，看得出说明属于哪一条。别的照旧 8
    static func kind(_ c: [String: JSONValue]?) -> String {
        guard let c, let t = c["component"]?.string else { return "" }
        if t == "Text" {
            let v = c["variant"]?.string ?? "body"
            return v == "caption" ? "caption" : v.hasPrefix("h") ? "heading" : "body"
        }
        return t == "ChoicePicker" ? "body" : t
    }

    static func itemSpacing(_ comps: [[String: JSONValue]?]) -> [CGFloat] {
        func kind(_ c: [String: JSONValue]?) -> String {
            guard let c, let t = c["component"]?.string else { return "" }
            if t == "Text" {
                let v = c["variant"]?.string ?? "body"
                return v == "caption" ? "caption" : v.hasPrefix("h") ? "heading" : "body"
            }
            return t == "ChoicePicker" ? "body" : t   // 一项一个选择框的：选择框那一行就是这一条的标题
        }
        let kinds = comps.map(kind)
        return kinds.indices.map { i -> CGFloat in
            guard i > 0 else { return 0 }
            let prev = kinds[i - 1], cur = kinds[i]
            if cur == "caption" && prev == "body" { return 2 }
            if cur == "Row" && (prev == "caption" || prev == "body") { return 6 }
            if cur == "body" && i >= 2 && (prev == "Row" || (prev == "caption" && kinds[i - 2] == "body")) { return 14 }
            return 8
        }
    }

    /// 图标名 → 最接近的系统符号（宿主没给 Lucide 的图时用；以前的名字先换成 Lucide 的）
    public static func symbol(_ name: String?) -> String {
        switch A2UI.lucide(name) {
        case "archive": return "archivebox"
        case "brain": return "brain"
        case "calendar": return "calendar"
        case "calendar-plus": return "calendar.badge.plus"
        case "check": return "checkmark"
        case "chevron-down": return "chevron.down"
        case "chevron-right": return "chevron.right"
        case "circle-help": return "questionmark.circle"
        case "circle-minus": return "minus.circle"
        case "clock": return "clock"
        case "folder": return "folder"
        case "inbox": return "tray"
        case "info": return "info.circle"
        case "lightbulb": return "lightbulb"
        case "link": return "link"
        case "mail": return "envelope"
        case "pencil-line": return "pencil.line"
        case "reply": return "arrowshape.turn.up.left"
        case "settings": return "gearshape"
        case "shield-alert": return "exclamationmark.shield"
        case "sparkles": return "sparkles"
        case "square-arrow-out-up-right": return "arrow.up.forward.app"
        case "star": return "star"
        case "trash-2": return "trash"
        case "triangle-alert": return "exclamationmark.triangle"
        case "user": return "person"
        case "x": return "xmark"
        case "hard-drive": return "internaldrive"
        case "key": return "key"
        case "lock": return "lock"
        case "package": return "shippingbox"
        case "cpu": return "cpu"
        case "shield-check": return "checkmark.shield"
        case "refresh-cw": return "arrow.clockwise"
        case "copy": return "doc.on.doc"
        case "trending-up": return "chart.line.uptrend.xyaxis"
        case "file": return "doc"
        case "power": return "power"
        case "puzzle": return "puzzlepiece"
        case "app-window": return "macwindow"
        case "globe": return "globe"
        case "folder-open": return "folder"
        case "keyboard": return "keyboard"
        case "eye": return "eye"
        default: return "circle"
        }
    }

}

/// 一排按钮放不下就折行。量（`sizeThatFits`）和摆（`placeSubviews`）按同一个宽折：都用父视图提的宽，不用摆的时候的
/// `bounds`。`bounds` 按像素取过整，会比量的时候窄零点几 pt：原来最后一个按钮就折到下一行，画到按一行量的卡片外面
struct FlowLayout: Layout {
    var spacing: CGFloat = 8
    /// 差不到这么多也算放得下：按像素取整最多差一个像素，1x 的屏上是 1 pt
    static let slack: CGFloat = 1

    /// 每一行是哪几个（下标）。一行的第一个不折
    private func lines(_ sizes: [CGSize], width: CGFloat) -> [[Int]] {
        var out: [[Int]] = [], x: CGFloat = 0
        for (i, s) in sizes.enumerated() {
            if out.isEmpty || x + s.width > width + Self.slack { out.append([]); x = 0 }
            out[out.count - 1].append(i)
            x += s.width + spacing
        }
        return out
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let sizes = subviews.map { $0.sizeThatFits(.unspecified) }
        let width = proposal.width ?? .infinity
        var widest: CGFloat = 0, height: CGFloat = 0
        for (n, line) in lines(sizes, width: width).enumerated() {
            widest = max(widest, line.reduce(0) { $0 + sizes[$1].width } + spacing * CGFloat(line.count - 1))
            height += (n > 0 ? spacing : 0) + (line.map { sizes[$0].height }.max() ?? 0)
        }
        return CGSize(width: min(widest, width), height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let sizes = subviews.map { $0.sizeThatFits(.unspecified) }
        var y = bounds.minY
        for line in lines(sizes, width: proposal.width ?? .infinity) {
            var x = bounds.minX
            for i in line {
                subviews[i].place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(sizes[i]))
                x += sizes[i].width + spacing
            }
            y += (line.map { sizes[$0].height }.max() ?? 0) + spacing
        }
    }
}

/// `"justify": "spaceBetween"` 的一行：左边一块靠左、右边一块靠右，上下居中。排得下时和原来的
/// `HStack(spacing: 12) { 左; Spacer(minLength: 8); 右 }` 一样：左边给的宽是整行减去右边和中间的 32。
/// 左边压到最窄也排不下时，右边那块折到下一行、靠右，整行不比给的宽更宽：原来的 HStack 这时把卡片连带整页撑宽，左边被切掉。
/// 量和摆都按父视图提的宽来定排不排得下（同 `FlowLayout`）。
struct SpaceBetweenRow: Layout {
    /// 一行时中间至少空这么多：原来 HStack 的间距 12、Spacer 的 8、再一个 12
    static let gap: CGFloat = 32
    /// 折成两行时，两行之间
    static let lineSpacing: CGFloat = 8

    private func oneRow(_ width: CGFloat?, _ left: LayoutSubview, _ right: CGSize) -> Bool {
        guard let width else { return true }
        return left.sizeThatFits(ProposedViewSize(width: 0, height: nil)).width + Self.gap + right.width <= width
    }

    private func leftProposal(_ proposal: ProposedViewSize, _ right: CGSize) -> ProposedViewSize {
        ProposedViewSize(width: proposal.width.map { $0 - Self.gap - right.width }, height: proposal.height)
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        guard let left = subviews.first else { return .zero }
        let r = subviews.count > 1 ? subviews[1].sizeThatFits(.unspecified) : .zero
        if oneRow(proposal.width, left, r) {
            let l = left.sizeThatFits(leftProposal(proposal, r))
            return CGSize(width: proposal.width ?? l.width + Self.gap + r.width, height: max(l.height, r.height))
        }
        let width = proposal.width ?? 0
        let l = left.sizeThatFits(ProposedViewSize(width: width, height: nil))
        return CGSize(width: width, height: l.height + Self.lineSpacing + r.height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        guard let left = subviews.first else { return }
        let right = subviews.count > 1 ? subviews[1] : nil
        let r = right?.sizeThatFits(.unspecified) ?? .zero
        if oneRow(proposal.width, left, r) {
            left.place(at: CGPoint(x: bounds.minX, y: bounds.midY), anchor: .leading, proposal: leftProposal(proposal, r))
            right?.place(at: CGPoint(x: bounds.maxX, y: bounds.midY), anchor: .trailing, proposal: ProposedViewSize(r))
            return
        }
        let lp = ProposedViewSize(width: proposal.width ?? 0, height: nil)
        let l = left.sizeThatFits(lp)
        left.place(at: bounds.origin, anchor: .topLeading, proposal: lp)
        // 右边那块比整行还宽时从左边起，不往左边外面画
        right?.place(at: CGPoint(x: max(bounds.maxX, bounds.minX + r.width), y: bounds.minY + l.height + Self.lineSpacing),
                     anchor: .topTrailing, proposal: ProposedViewSize(r))
    }
}

/// 按钮上的转圈：一段圆弧，真窗口里转（减少动态效果时不转）。不用 ProgressView：离屏截图里它画不出来
struct BusySpinner: View {
    @Environment(\.accessibilityReduceMotion) private var still
    @State private var turning = false

    var body: some View {
        Circle().trim(from: 0.12, to: 0.82)
            .stroke(style: StrokeStyle(lineWidth: 2, lineCap: .round))
            .padding(1.5)
            .rotationEffect(.degrees(turning ? 360 : 0))
            .animation(still ? nil : .linear(duration: 0.9).repeatForever(autoreverses: false), value: turning)
            .onAppear { turning = true }
            .accessibilityLabel("正在处理")
    }
}
