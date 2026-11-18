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
    /// 这一份上的点按排队做（宿主给应用的页设）：一个动作在等答复时别的按钮不灰，再点的由宿主排在后面
    public var queues = false
    /// 排着队、还没发出去的按钮：和正在等答复的那个一样画转圈、不能再点
    @Published public var queued: Set<String> = []
    /// 点开了的可折叠段（`Column` 的 `collapsed`）。记在这里，不记在视图里：同一份画在两处时（弹窗「放得下照内容高、放不下就滚」
    /// 是两份视图）点开的一样；不然点开后内容变高、换到能滚的那一份，那一份还是收着的，要再点一次（#165）
    @Published public var opened: Set<String> = []

    /// 整份都不能点：在等答复，又不排队（卡片）
    public var locked: Bool { busy && !queues }
    /// 这个按钮点下去了：正在等答复，或排着队
    public func waiting(_ id: String) -> Bool { (busy && pressed == id) || queued.contains(id) }
    /// 用户改了数据模型（给整份）；宿主去抖、存起来
    public var onDataChange: ((JSONValue) -> Void)?

    /// 建出来时的数据模型（工具给的）。应用页每取一次新建一份，所以就是这一次工具给的；和现在的比，看得出用户改过哪些
    public let given: JSONValue

    public init(surface: Surface) {
        self.id = surface.surfaceId
        self.surface = surface
        self.given = surface.data
    }

    /// 用户改过这个路径上的值（和工具给的不一样）
    public func changed(_ path: String) -> Bool { value(path) != (try? given.value(at: path)) }

    /// 用户改过、没交出去的选择和输入框里的字放回工具给的。离开这一页时调（界面接口 §6）：回来再取照工具新给的，不当成同一页重新取
    public func forgetChoices() {
        for p in Array(surface.choiceShapes.keys) + Array(surface.textFieldLabels.keys) where changed(p) {
            if let v = try? given.value(at: p) { set(p, v) }
        }
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
        // §4 headerPlacement：根下面写了 placement header 的那一样画在应用页标题那一行，页里不再画
        if depth == 0 && id == "root" { kids.removeAll { model.surface.headerItems.contains($0) } }
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
                if j < ids.count, isButtonRow(ids[j]) || pickRow(ids[j]) != nil {   // 选项组和按钮一样放到这一条右边，放不下回到下面
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
           Self.kind(comps[next]) == "caption" || isButtonRow(next) || pickRow(next) != nil {
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
    /// 一排同一个动作的按钮、其中正好一个是主按钮：n 选 1，答选中的那个；不是就答 nil。只在应用页上认
    /// 每项的字放宽到 10 个（输入法「各应用」的「跟随全局（候选窗口）」：同一页上别的选项是分段，它不能单独画成一排按钮）
    private func pickRow(_ id: String) -> String? {
        guard model.surface.page, drawn != nil, let c = comps[id], c["component"]?.string == "Row" else { return nil }
        let kids = children(c)
        guard kids.count >= 2, kids.count <= 7,
              kids.allSatisfy({ comps[$0]?["component"]?.string == "Button" && !model.surface.opensURL($0) && comps[$0]?["confirm"] == nil })
        else { return nil }
        let names = Set(kids.compactMap { comps[$0]?["action"]?["event"]?["name"]?.string })
        let picked = kids.filter { comps[$0]?["variant"]?.string == "primary" }
        let labels = kids.map { model.surface.buttonLabel($0) }
        guard names.count == 1, picked.count == 1, labels.allSatisfy({ $0.1 == nil }),
              ChoiceChips.fits(labels.map(\.0), each: 10) else { return nil }
        return picked[0]
    }

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

    /// 子组件，不画的不算（§4 countLabel：数出 0 项的按钮、只装着它的那一行）
    private func children(_ c: [String: JSONValue]) -> [String] {
        let s = model.surface
        return (c["children"]?.array?.compactMap { $0.string } ?? []).filter { !s.drawsNothing($0) }
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
    /// 一项一行（spaceBetween 的 Row）右边的次要按钮：只有一个也只画图标（设计规范 §18.1 第 5 条：一行里的动作只有一个时直接放那个图标）。
    /// 主按钮、危险的（「移到废纸篓」）照旧画成按钮，不缩成图标
    private var chipButtons: Set<String> {
        guard model.surface.page else { return [] }
        var out = Set<String>()
        for (id, c) in comps where model.surface.chipRow(id) { out.formUnion(children(c)) }
        return out
    }

    /// 一项一行（spaceBetween 的 Row）右边的按钮，直接放的和包在一行里的都算
    private var rowTrailButtons: Set<String> {
        var out = Set<String>()
        for (_, c) in comps where c["component"]?.string == "Row" && c["justify"]?.string == "spaceBetween" {
            for k in children(c).dropFirst() {
                if comps[k]?["component"]?.string == "Button" { out.insert(k) }
                else if let r = comps[k], r["component"]?.string == "Row" {
                    out.formUnion(children(r).filter { comps[$0]?["component"]?.string == "Button" })
                }
            }
        }
        return out
    }

    private var rowEndButtons: Set<String> {
        var out = Set<String>()
        func minor(_ id: String) -> Bool {
            guard comps[id]?["component"]?.string == "Button" else { return false }
            let v = comps[id]?["variant"]?.string
            return v == nil || v == "borderless"
        }
        for (_, c) in comps where c["component"]?.string == "Row" && c["justify"]?.string == "spaceBetween" {
            let kids = children(c)
            guard kids.count >= 2, let lead = comps[kids[0]], lead["component"]?.string == "Column" else { continue }
            for k in kids.dropFirst() {
                if let r = comps[k], r["component"]?.string == "Row" { out.formUnion(children(r).filter(minor)) }
                else if minor(k) { out.insert(k) }
            }
        }
        return out
    }

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
        // 一项一行（§4 itemIcons 那样排）：`"justify": "spaceBetween"` 的 Row，左边是标题那一列（第一项是字），
        // 右边是这一项的按钮（一个按钮行，或直接几个按钮）
        for (_, c) in comps where c["component"]?.string == "Row" && c["justify"]?.string == "spaceBetween" {
            let kids = children(c)
            // 标题那一列的第一样是字、勾选框（扫描详情里勾的那个文件），或一行「字 + 标签」（「LoRA 是一种微调方法 待确认」）
            guard kids.count >= 2, let lead = comps[kids[0]], lead["component"]?.string == "Column",
                  let first = children(lead).first,
                  ["Text", "CheckBox"].contains(comps[first]?["component"]?.string ?? "")
                    || (comps[first]?["component"]?.string == "Row" && children(comps[first] ?? [:]).first.map { comps[$0]?["component"]?.string == "Text" } == true)
            else { continue }
            for k in kids.dropFirst() {
                // 右边那一排按钮：几个都行（全部记忆一条后面有对、不对、看依据、忘掉四个），打开网页的不算
                // 打开网页的那个按钮照旧带字（底线：链接先写明去哪个网站），同一排别的按钮照样只画图标
                // （负责人 11-16 的实例：收件箱一行有「Gmail」，「加星标」「归档」就都带着字）
                if let r = comps[k], r["component"]?.string == "Row", !children(r).isEmpty,
                   children(r).allSatisfy({ comps[$0]?["component"]?.string == "Button" }) {
                    out.formUnion(children(r).filter { !model.surface.opensURL($0) })
                }
                else if comps[k]?["component"]?.string == "Button" { out.insert(k) }
            }
        }
        return out
    }

    /// 写了 `collapsed` 的一列：先收起，只画那一句和一个箭头，点开才画里面的（工具协议 §4）
    private func collapsible(_ id: String, _ c: [String: JSONValue], _ inner: AnyView) -> AnyView {
        guard let summary = c["collapsed"]?.string, !summary.isEmpty else { return inner }
        let open = model.opened.contains(id)
        return AnyView(VStack(alignment: .leading, spacing: 6) {
            Button {
                withAnimation(.easeOut(duration: 0.15)) { if open { model.opened.remove(id) } else { model.opened.insert(id) } }
            } label: {
                HStack(spacing: 2) {                       // 「还有 3 个 ›」：箭头在字后面
                    Text(summary)
                    iconView("chevron-right", size: 13).rotationEffect(.degrees(open ? 90 : 0))
                }
                .font(fontHook?("caption") ?? .callout)
                .foregroundStyle(drawn?.mutedFg ?? .secondary)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plainPointer)
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
            let row = rowNode(id, c, allowed: allowed, depth: depth)
            // §4 rowOpen：整行可点，点了就是点 `open` 指的那个按钮（那个按钮本身不画）
            if let target = c["open"]?.string, comps[target]?["component"]?.string == "Button" {
                let others = model.surface.subtree(id).filter { $0 != target && comps[$0]?["component"]?.string == "Button" && !hiddenTargets.contains($0) }
                return AnyView(OpenRow(label: model.surface.buttonLabel(target).0, colors: drawn, inline: c["justify"]?.string != "spaceBetween",
                                       chevron: true,     // 行里有别的按钮也画：不画看不出整行能点开（负责人 11-16）
                                       disabled: model.locked, run: { fire(target) }) { row })
            }
            return row
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
            if hiddenTargets.contains(id) { return AnyView(EmptyView()) }
            return AnyView(button(id, c))
        case "CheckBox":
            return AnyView(checkBox(c))
        case "ChoicePicker":
            return AnyView(choice(id, c))
        case "TextField", "DateTimeInput":
            if let t = c["submit"]?.string, comps[t]?["component"]?.string == "Button" {
                return AnyView(field(c).onSubmit { fire(t) })   // §4 fieldSubmit：回车就是点那个按钮
            }
            return AnyView(field(c))
        case "Slider":
            return AnyView(slider(c))
        default:
            return AnyView(EmptyView())
        }
    }

    /// 左右两块、整行能点开的一行（箭头在最右边）
    private func opensAcross(_ id: String) -> Bool {
        guard let c = comps[id], c["component"]?.string == "Row", c["justify"]?.string == "spaceBetween",
              let target = c["open"]?.string else { return false }
        return comps[target]?["component"]?.string == "Button"
    }

    /// 一行（Row）怎么画：名字小块、一行几段字、一项前面的图标、一排数、左右两块、字后面跟按钮，别的照排
    private func rowNode(_ id: String, _ c: [String: JSONValue], allowed: Set<String>, depth: Int) -> AnyView {
        let kids = children(c)
        // 一排同一个动作的按钮、其中正好一个是主按钮（输入法页的「全拼 / 小鹤双拼 / 自然码双拼」：选中的那个标成 primary）：
        // 这是 n 选 1，画成和别处一样的分段选择，选中的是主按钮那一个，点一段就是点那个按钮
        // （负责人 11-15：输入法页的选项是红底实心，像主按钮，别处的选项是描边分段，两种样子）
        // 只在应用页上认（卡片上「归档 / 暂不处理」那样的一排是动作，不是选项）
        if let d = drawn, let picked = pickRow(id) {
            let opts = kids.map { ChoiceBox.Option(value: $0, label: model.surface.buttonLabel($0).0) }
            return AnyView(ChoiceChips(options: opts, selected: picked, label: "", colors: d) { k in
                if k != picked { fire(k) }
            }.disabled(model.locked))
        }
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
                    } else if kc["variant"]?.string == "strong" {
                        // 加粗的那段（发件人）：一行，实在放不下才省略（先省略写了 maxLines 的主题）
                        textView(kc, inline: true).lineLimit(1)
                    } else if kc["variant"]?.string == "badge" || kc["variant"]?.string == "caption" {
                        // 标签、小字（截止日、来信时间）：照原样一行，不被挤成竖排（负责人 11-16 的实例：时间一个字一行）
                        textView(kc, inline: true).fixedSize().layoutPriority(1)
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
        // 页底一行几个链接（「这台 Mac 状态正常 › · 大文件（不会自动清）› · 其他 6 项 ›」）：中间隔一个点
        if kids.count > 1, kids.allSatisfy({ comps[$0]?["component"]?.string == "Row" && comps[$0]?["open"] != nil }) {
            return AnyView(FlowLayout(spacing: 12) {
                ForEach(Array(kids.enumerated()), id: \.offset) { i, k in
                    if i > 0 { Text("·").font(fontHook?("caption") ?? .callout).foregroundStyle(drawn?.mutedFg ?? .secondary) }
                    node(k, allowed: allowed, depth: depth + 1)
                }
            })
        }
        return AnyView(FlowLayout(spacing: 8) {
            ForEach(kids, id: \.self) { node($0, allowed: allowed, depth: depth + 1) }
        })
    }

    /// 点一个按钮（`open`、`submit` 指的那个，§4 rowOpen、fieldSubmit）：和点按钮一样交给宿主
    private func fire(_ id: String) {
        guard !model.locked, !model.waiting(id), let (name, ctx) = try? model.surface.action(id) else { return }
        onAction(id, name, ctx)
    }

    /// `open`、`submit` 指的按钮：窗口不画（整行可点、回车就提交）
    private var hiddenTargets: Set<String> {
        var out = Set<String>()
        for (_, c) in comps {
            if c["component"]?.string == "Row", let t = c["open"]?.string { out.insert(t) }
            if c["component"]?.string == "TextField" || c["component"]?.string == "ChoicePicker", let t = c["submit"]?.string { out.insert(t) }
        }
        return out
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
                // 有的行整行能点开（行尾有箭头）、有的不能：不能点的行尾也留出箭头那么宽，右边的数和比例条才对得齐（负责人 11-18）
                let anyOpen = kids.contains { opensAcross($0) }
                ForEach(Array(kids.enumerated()), id: \.element) { i, kid in
                    Group {
                        if anyOpen, !opensAcross(kid), comps[kid]?["component"]?.string == "Row", comps[kid]?["justify"]?.string == "spaceBetween" {
                            HStack(spacing: 8) {
                                node(kid, allowed: allowed, depth: depth + 1).frame(maxWidth: .infinity, alignment: .leading)
                                OpenChevron(inline: false, colors: d).hidden().accessibilityHidden(true)
                            }
                        } else {
                            node(kid, allowed: allowed, depth: depth + 1)
                        }
                    }
                        // 整行能点开的：线和线之间这一整格都能点，不只是字那一条（负责人 11-18）
                        .environment(\.openRowBleed, 9)
                        // 线上下各空 9；第一项上面、最后一项下面不空，卡片四周的边距和别的卡片一样
                        .padding(.top, i == 0 ? 0 : 9)
                        .padding(.bottom, i == kids.count - 1 ? 0 : 9)
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
        // 一行一项右边的主按钮（收件箱每行的「回复」）：一屏几十个实底的品牌色太重（界面规范 §2：品牌色一屏两三处），
        // 画成次要按钮；只画图标的、危险的照旧
        let rowPrimary = c["variant"]?.string == "primary" && rowTrailButtons.contains(id) && icon == nil
        let variant = trailingIds.contains(id) ? "mini" : rowPrimary ? nil : c["variant"]?.string
        // 画成开关的按钮：点了还是按钮的动作，开没开听工具重画的页面。打开网页的按钮不画成开关
        if c["variant"]?.string == "switch", let on = c["on"]?.bool, !model.surface.opensURL(id) {
            let flip = {
                guard let (name, ctx) = try? model.surface.action(id) else { return }
                onAction(id, name, ctx)
            }
            // 开关也可以带 confirm（§4）：打开定时整理之类，先把说明给用户看，点了确认才扳
            if let o = c["confirm"]?.object, let title = o["title"]?.string {
                let ask = ConfirmAsk(title: title, text: o["text"]?.string, label: o["label"]?.string ?? label)
                return AnyView(ConfirmGate(ask: ask, colors: drawn, run: flip) { open in
                    AnyView(DrawnSwitch(label: label, on: on, colors: drawn, tap: open).disabled(model.locked).accessibilityHint("要确认"))
                })
            }
            return AnyView(DrawnSwitch(label: label, on: on, colors: drawn, tap: flip).disabled(model.locked))
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
        // 一条后面只画图标的按钮：一个浅底的小方块（走查重画稿），不再套按钮的样式
        let iconOnly = icon != nil && !opens && itemActionButtons.contains(id) && (model.surface.buttonsInRow(id) > 1 || rowEndButtons.contains(id))
        // 主按钮（「移到废纸篓」这类）只画图标时照旧是实底的按钮；次要的是浅底小方块
        let plainIcon = iconOnly && variant != "primary"
        if model.waiting(id) {
            // 点下去了、在等答复：转圈换掉图标，字照旧
            content = AnyView(HStack(spacing: 6) {
                BusySpinner().frame(width: 14, height: 14)
                if !iconOnly { Text(label) }
            })
        } else if let icon, iconOnly {
            // 一条后面的几个按钮（扫描页的「移到废纸篓」「不是病毒」）：有图标的只画图标，字放在悬停提示里、给读屏念（工具协议 §4）
            content = plainIcon
                ? AnyView(iconView(icon, size: 14)
                    .frame(width: 28, height: 28)
                    .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill((drawn?.fg ?? .primary).opacity(0.06)))
                    .contentShape(Rectangle()))
                : AnyView(iconView(icon, size: 14).frame(minWidth: 14))
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
        // 按钮要交一组选项里选的那个（上下文绑着一个 ChoicePicker 的值），而现在一个都没选：先禁用，选了才亮
        // （负责人 11-16：记忆「待确认」默认都不选，选了「确定」才亮）
        let choicePaths = Set(comps.values.filter { $0["component"]?.string == "ChoicePicker" }.compactMap { $0["value"]?.bindingPath })
        let unpicked = ((c["action"]?["event"]?["context"]?.object ?? [:]).values).contains { v in
            guard let p = v.bindingPath else { return false }
            let base = choicePaths.first { p == $0 || p.hasPrefix($0 + "/") }
            return base.map { model.value($0)?.array?.isEmpty ?? false } ?? false
        }
        let disabled = model.locked || model.waiting(id) || unpicked || (opens && site == nil) || !model.surface.buttonCountAllows(id)   // §4 countLabel：0 项的不画（children 里就去掉了），这里只是保险
        // 一排小标签里的（「最近搜过」「检索范围」）：小圆角标签，选了的实底加粗（走查重画稿 .m-tag、.m-tag.on）
        if let d = drawn, chipButtons.contains(id), !model.waiting(id) {
            let on = c["variant"]?.string == "selected"
            let tag = AnyView(Text(label)
                .font(.system(size: 12, weight: on ? .semibold : .regular))
                .foregroundStyle(on ? d.fg : d.mutedFg)
                .padding(.horizontal, 10).padding(.vertical, 3)
                .background(Capsule().fill(on ? d.fg.opacity(0.16) : .clear))
                .overlay(Capsule().strokeBorder(on ? .clear : d.input, lineWidth: 1))
                .contentShape(Capsule()))
            if let o = c["confirm"]?.object, let title = o["title"]?.string {
                let ask = ConfirmAsk(title: title, text: o["text"]?.string, label: o["label"]?.string ?? label)
                return AnyView(ConfirmGate(ask: ask, colors: drawn, run: run) { open in
                    AnyView(Button(action: open) { tag }.buttonStyle(.plainPointer).disabled(disabled).help(help).accessibilityLabel(help)
                        .accessibilityHint("要确认").fixedSize())
                })
            }
            return AnyView(Button(action: run) { tag }.buttonStyle(.plainPointer).disabled(disabled).help(help).accessibilityLabel(help).fixedSize())
        }
        // §4 confirm：点了先在按钮下面弹确认，用户再点一次才做（忘掉、删除这类）。读屏念的字带上「要确认」
        if let o = c["confirm"]?.object, let title = o["title"]?.string, !opens {
            let ask = ConfirmAsk(title: title, text: o["text"]?.string, label: o["label"]?.string ?? label)
            return AnyView(ConfirmGate(ask: ask, colors: drawn, run: run) { open in
                let b = Button(action: open) { content }.disabled(disabled).help(help).accessibilityLabel(help).accessibilityHint("要确认")
                return plainIcon ? AnyView(b.buttonStyle(.plainPointer).fixedSize()) : AnyView(styledButton(b, variant).fixedSize())
            })
        }
        let b = Button(action: run) { content }
            .disabled(disabled)
            .help(help)
            .accessibilityLabel(help)
        if plainIcon && !model.waiting(id) { return AnyView(b.buttonStyle(.plainPointer).fixedSize()) }
        return AnyView(styledButton(b, variant).fixedSize())   // 字不截断：放不下整行换行
    }

    private func styledButton(_ b: some View, _ variant: String?) -> some View {
        Group {
            if let hook = buttonStyleHook {
                // 焦点环在按钮上画（按钮样式里读不到焦点）：深色的「按这个处理」原来拿到焦点看不出来
                b.buttonStyle(hook(variant)).modifier(KeyFocusable(radius: 7)).pointerOnHover()
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
        if let d = drawn { return AnyView(DrawnCheckBox(label: text(c["label"]), on: binding, colors: d, strong: model.surface.page)) }
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
            let opts = zip(labels, options).map { ChoiceBox.Option(value: $0.value, label: $0.label, icon: $1["icon"]?.string, tooltip: $1["tooltip"]?.string) }
            // §4 choiceSubmit：选了就是点 submit 指的按钮（选的值先写进数据模型）
            let pick: (String) -> Void = { v in
                binding.wrappedValue = v
                if let t = c["submit"]?.string { fire(t) }
            }
            // 选了就交、又没有选中的（§4 choiceSubmit，记忆的「好 / 不用 / 别再提」）：点一下就做了，画成一排按钮，
            // 不画成选项组（负责人 11-14：和选项组一个样子，以为是选一个，点了卡片就没了）。
            // 有选中的（筛选「等回复 / 全部」、「今天 / 本周」）是切换看哪一种，照旧是选项组
            if c["submit"]?.string != nil, binding.wrappedValue.isEmpty, ChoiceChips.fits(labels.map(\.label)) {
                let suggested = binding.wrappedValue
                let row = HStack(spacing: 8) {
                    ForEach(opts, id: \.value) { o in
                        styledButton(Button { pick(o.value) } label: {
                            if model.busy && binding.wrappedValue == o.value {
                                HStack(spacing: 6) { BusySpinner().frame(width: 14, height: 14); Text(o.label) }
                            } else if let icon = o.icon {
                                HStack(spacing: 6) { iconView(icon, size: 14); Text(o.label) }
                            } else {
                                Text(o.label)
                            }
                        }
                        .disabled(model.locked).help(o.tooltip ?? o.label).accessibilityLabel(o.label),
                        o.value == suggested ? "primary" : nil).fixedSize()
                    }
                }
                return AnyView(VStack(alignment: .leading, spacing: 8) {
                    if !shownLabel.isEmpty {
                        styled(Text(shownLabel), nil).frame(maxWidth: .infinity, alignment: .leading).fixedSize(horizontal: false, vertical: true)
                    }
                    row
                }.frame(maxWidth: .infinity, alignment: .leading))
            }
            // 几个选项都摆出来（11-12 改了 11-06 的做法：处理方式要一眼看到，建议的那个已选中）：这一项只有 2～4 个短选项时并排，
            // 否则还是一个框
            let pill: AnyView = ChoiceChips.fits(labels.map(\.label))
                ? AnyView(ChoiceChips(options: opts, selected: binding.wrappedValue, label: label, colors: d,
                                      iconsOnly: trailingIds.contains(id), onPick: pick).disabled(model.locked))
                : AnyView(ChoiceBox(options: opts, selected: binding.wrappedValue, label: label, colors: d, onPick: pick).disabled(model.locked))
            return AnyView(HStack(alignment: .center, spacing: 12) {
                if !shownLabel.isEmpty {
                    // 这一项的标题：字体和正文一样走宿主的 a2uiFont（一件件处理里正文大一号，说明小一号，#52）
                    styled(Text(shownLabel), nil).frame(maxWidth: .infinity, alignment: .leading).fixedSize(horizontal: false, vertical: true)
                    pill
                } else if trailingIds.contains(id) {
                    Spacer(minLength: 0)
                    pill
                } else {
                    pill     // 没写标题的一组（走查重画稿：处理方式排在说明下面）：靠左
                    Spacer(minLength: 0)
                }
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
        // 回车就搜的框（§4 fieldSubmit）：画成搜索框，前面一个放大镜，高一点、圆一点（走查重画稿「搜记忆」「搜人物」「告诉螺壳你要找什么」）
        let search = c["component"]?.string == "TextField" && c["submit"] != nil && !secure && (text(c["label"]).contains("搜") || text(c["label"]).contains("找"))
        if let d = drawn, search {
            let input: AnyView = d.staticFields
                ? AnyView(Text(binding.wrappedValue.isEmpty ? text(c["label"]) : binding.wrappedValue)
                    .foregroundStyle(binding.wrappedValue.isEmpty ? d.mutedFg : d.fg).frame(maxWidth: .infinity, alignment: .leading))
                : AnyView(TextField(text(c["label"]), text: binding).textFieldStyle(.plain).modifier(KeyFocusRevealing()))
            return AnyView(HStack(spacing: 8) {
                hostIcon("search", fallback: "magnifyingglass", size: 15).foregroundStyle(d.mutedFg)   // 放大镜（组件目录里没有 search）
                input
            }
            // 走查重画稿 .m-big：字大一号、高 48、圆角 12，底色同卡片
            .font(.system(size: 15))
            .padding(.horizontal, 14).frame(minHeight: 46)
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(d.card))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(d.input, lineWidth: 1)))
        }
        if let d = drawn, d.staticFields {
            let v = binding.wrappedValue
            let shown = secure ? String(repeating: "•", count: min(v.count, 12)) : v
            return AnyView(DrawnBox(text: v.isEmpty ? text(c["label"]) : shown, placeholder: v.isEmpty, chevron: false, colors: d))
        }
        // 长文字（A2UI 的 longText：回信草稿）：几行高，往下长，最多十几行
        let long = !secure && c["component"]?.string == "TextField" && c["variant"]?.string == "longText"
        if let d = drawn {
            let input = secure ? AnyView(SecureField(text(c["label"]), text: binding))
                : long ? AnyView(TextField(text(c["label"]), text: binding, axis: .vertical).lineLimit(4...14))
                : AnyView(TextField(text(c["label"]), text: binding))
            return AnyView(input.textFieldStyle(.plain).font(.system(size: 13)).modifier(KeyFocusRevealing())
                .padding(.horizontal, 10).padding(.vertical, long ? 8 : 0).frame(minHeight: 30)
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
        case "undo-2": return "arrow.uturn.backward"
        case "history": return "clock.arrow.circlepath"
        case "thumbs-up": return "hand.thumbsup"
        case "thumbs-down": return "hand.thumbsdown"
        case "mail-x": return "envelope.badge.shield.half.filled"
        case "bell-off": return "bell.slash"
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
            let h = line.map { sizes[$0].height }.max() ?? 0
            for i in line {   // 一行里高矮不一的上下居中（图标按钮 30、开关 20 并排时对齐）
                subviews[i].place(at: CGPoint(x: x, y: y + (h - sizes[i].height) / 2), proposal: ProposedViewSize(sizes[i]))
                x += sizes[i].width + spacing
            }
            y += h + spacing
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


/// 按钮的确认（工具协议 §4 confirm）：标题、一句说明、确认按钮的字
struct ConfirmAsk {
    let title: String
    let text: String?
    let label: String
}

/// 点了先弹确认的按钮：`button` 拿到「打开确认」的动作画出按钮；确认里点「取消」或在外面点就收起，点确认才 `run`
struct ConfirmGate: View {
    let ask: ConfirmAsk
    let colors: A2UIDrawn?
    let run: () -> Void
    let button: (@escaping () -> Void) -> AnyView
    @State private var open = false
    @Environment(\.a2uiButtonStyle) private var styles
    @Environment(\.a2uiFont) private var fonts

    var body: some View {
        button { open = true }
            .popover(isPresented: $open, arrowEdge: .bottom) {
                VStack(alignment: .leading, spacing: 12) {
                    Text(ask.title).font(fonts?("h5") ?? .system(size: 13, weight: .semibold))
                        .foregroundStyle(colors?.fg ?? .primary)
                    if let t = ask.text {
                        Text(t).font(fonts?("caption") ?? .system(size: 12)).foregroundStyle(colors?.mutedFg ?? .secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    HStack(spacing: 8) {
                        Spacer(minLength: 0)
                        styled(Button("取消") { open = false }, nil)
                            .keyboardShortcut(.cancelAction)
                        // 宿主给了按钮样式（螺壳的窗口）就照它画成红的危险按钮，和别处的确认框一样；没给用系统的
                        if styles != nil {
                            styled(Button(ask.label) { open = false; run() }, "destructive")
                        } else {
                            Button(ask.label) { open = false; run() }
                                .tint(colors?.danger ?? .red)
                                .buttonStyle(.borderedProminent)
                        }
                    }
                }
                .padding(16)
                .frame(width: 280)
            }
    }

    @ViewBuilder private func styled(_ b: Button<Text>, _ variant: String?) -> some View {
        if let styles { b.buttonStyle(styles(variant)) } else { b }
    }
}


/// 整行能点开的一行行尾的箭头
struct OpenChevron: View {
    let inline: Bool
    let colors: A2UIDrawn?

    var body: some View {
        Image(systemName: "chevron.right").font(.system(size: inline ? 10 : 11, weight: .semibold))
            .foregroundStyle(colors?.mutedFg ?? .secondary)
    }
}

/// 列表里整行能点开的一行，能点的范围上下各多出多少（到分隔线）
private struct OpenRowBleedKey: EnvironmentKey { static let defaultValue: CGFloat = 0 }
extension EnvironmentValues {
    var openRowBleed: CGFloat {
        get { self[OpenRowBleedKey.self] }
        set { self[OpenRowBleedKey.self] = newValue }
    }
}

/// 整行可点的一项（工具协议 §4 rowOpen）：鼠标停上去底下浮一层淡灰，行尾一个向右的箭头；行里别的按钮照常点
struct OpenRow<Content: View>: View {
    let label: String
    let colors: A2UIDrawn?
    /// 一句话那样的一行（不是左右两块的一项）：箭头紧跟在字后面（「收件箱里有 4 封在等你回复 ›」）
    var inline = false
    /// 行尾画不画箭头：能点开的行一律画，放在最右边、按钮的右边（负责人 11-16）
    var chevron = true
    let disabled: Bool
    let run: () -> Void
    @ViewBuilder let content: () -> Content
    @State private var hover = false
    @Environment(\.openRowBleed) private var bleed

    var body: some View {
        HStack(spacing: inline ? 3 : 8) {
            if inline { content().fixedSize() } else { content().frame(maxWidth: .infinity, alignment: .leading) }
            if chevron { OpenChevron(inline: inline, colors: colors) }
            if inline { Spacer(minLength: 0) }
        }
        // 能点的范围和停上去的底色比排版占的地方大：左右各 8；在列表里上下一直到分隔线（`openRowBleed`）
        .padding(.horizontal, 8).padding(.vertical, 4 + bleed)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous)
            .fill(hover && !disabled ? (colors?.fg ?? .primary).opacity(0.05) : .clear))
        .padding(.horizontal, -8).padding(.vertical, -bleed)
        .contentShape(Rectangle())
        .onHover { hover = $0 }
        .modifier(PointerIf(on: !disabled))
        .onTapGesture { if !disabled { run() } }
        .accessibilityElement(children: .contain)
        .accessibilityAddTraits(.isButton)
        // 默认动作也是打开：读屏的「激活」、辅助功能的按下都走这里（以前只有带名字的动作，按下没反应）
        .accessibilityAction { if !disabled { run() } }
        .accessibilityAction(named: label.isEmpty ? "打开" : label) { if !disabled { run() } }
        .help(label)
    }
}
