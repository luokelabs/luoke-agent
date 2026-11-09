import LuokeA2UICore
import SwiftUI

/// 一张卡片活的样子：宿主把消息喂进来；用户改的值写进数据模型。渲染器不碰文件（读写由宿主做）。
@MainActor
public final class SurfaceModel: ObservableObject, Identifiable {
    public nonisolated let id: String
    @Published public private(set) var surface: Surface
    /// 宿主在处理一次点按时设成 true：按钮先灰掉
    @Published public var busy = false
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
}

/// 画一张卡片。点了按钮回调（按钮编号、动作名、按当前数据模型解析好的上下文）。
public struct SurfaceView: View {
    @ObservedObject var model: SurfaceModel
    let onAction: (String, String, JSONValue) -> Void
    @Environment(\.a2uiButtonStyle) private var buttonStyleHook
    @Environment(\.a2uiDrawn) private var drawn
    @Environment(\.a2uiCardChrome) private var cardChrome
    @Environment(\.a2uiFont) private var fontHook

    public init(model: SurfaceModel, onAction: @escaping (_ componentId: String, _ name: String, _ context: JSONValue) -> Void) {
        self.model = model
        self.onAction = onAction
    }

    public var body: some View {
        node("root", allowed: Catalog.all[model.surface.catalogId] ?? [], depth: 0)
    }

    private var comps: [String: [String: JSONValue]] { model.surface.components }

    private func text(_ v: JSONValue?) -> String {
        if let p = v?.bindingPath { return model.value(p)?.string ?? "" }
        return v?.string ?? ""
    }

    private func children(_ c: [String: JSONValue]) -> [String] {
        c["children"]?.array?.compactMap { $0.string } ?? []
    }

    private func node(_ id: String, allowed: Set<String>, depth: Int) -> AnyView {
        guard depth < 32, let c = comps[id], let type = c["component"]?.string, allowed.contains(type) else {
            return AnyView(EmptyView())
        }
        switch type {
        case "Text":
            return AnyView(styled(Text(text(c["text"])), c["variant"]?.string).textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading).fixedSize(horizontal: false, vertical: true))
        case "Column", "List":
            return AnyView(VStack(alignment: .leading, spacing: type == "List" ? 4 : CGFloat(c["gap"]?.number ?? 8)) {
                ForEach(children(c), id: \.self) { node($0, allowed: allowed, depth: depth + 1) }
            })
        case "Row":
            let kids = children(c)
            if c["justify"]?.string == "spaceBetween", let first = kids.first {   // 左边一块、右边一块（A2UI Row 的 justify）
                return AnyView(HStack(alignment: .center, spacing: 12) {   // 上下居中：标题和右边的按钮、文字和图标对齐
                    node(first, allowed: allowed, depth: depth + 1)
                    Spacer(minLength: 8)
                    ForEach(Array(kids.dropFirst()), id: \.self) { node($0, allowed: allowed, depth: depth + 1).fixedSize() }   // 右边一块按自己的宽度
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
            if let d = drawn { return AnyView(Rectangle().fill(d.border).frame(height: 1)) }
            return AnyView(Divider())
        case "Icon":
            let image = Image(systemName: Self.symbol(c["name"]?.string))
            if let d = drawn { return AnyView(image.foregroundStyle(d.mutedFg)) }
            return AnyView(image.foregroundStyle(.secondary))
        case "Button":
            return AnyView(button(id, c))
        case "CheckBox":
            return AnyView(checkBox(c))
        case "ChoicePicker":
            return AnyView(choice(c))
        case "TextField", "DateTimeInput":
            return AnyView(field(c))
        case "Slider":
            return AnyView(slider(c))
        default:
            return AnyView(EmptyView())
        }
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
        let label = comps[c["child"]?.string ?? ""].map { text($0["text"]) } ?? ""
        let variant = c["variant"]?.string
        // 画成开关的按钮：点了还是按钮的动作，开没开听工具重画的页面
        // 打开网页的按钮不画成开关：要去的网站得画在按钮外面（下面）
        if variant == "switch", let on = c["on"]?.bool, !model.surface.opensURL(id) {
            return AnyView(DrawnSwitch(label: label, on: on, colors: drawn) {
                guard let (name, ctx) = try? model.surface.action(id) else { return }
                onAction(id, name, ctx)
            }.disabled(model.busy))
        }
        // 打开网页的按钮：去哪个网站画在按钮外面，用 agent 核心写的 `site`（工具协议 §5）；没写就不让点
        let opens = model.surface.opensURL(id)
        let site = model.surface.openSite(id)
        let b = Button(label) {
            guard let (name, ctx) = try? model.surface.action(id) else { return }
            onAction(id, name, ctx)
        }
        .disabled(model.busy || (opens && site == nil))
        let shown = styledButton(b, variant)
        guard opens else { return AnyView(shown) }
        return AnyView(HStack(spacing: 6) {
            shown
            if let site {
                styled(Text(site), "caption").lineLimit(1).truncationMode(.head)
            }
        })
    }

    private func styledButton(_ b: some View, _ variant: String?) -> some View {
        Group {
            if let hook = buttonStyleHook {
                b.buttonStyle(hook(variant))
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

    private func choice(_ c: [String: JSONValue]) -> some View {
        let path = c["value"]?.bindingPath
        let options = c["options"]?.array ?? []
        let labels = options.map { (value: $0["value"]?.string ?? "", label: text($0["label"])) }
        let binding = Binding<String>(
            get: { (path.flatMap { model.value($0) } ?? c["value"])?.array?.first?.string ?? "" },
            set: { v in if let p = path { model.set(p, .array([.string(v)])) } })   // 单选也是数组（A2UI 规定）
        let short = labels.count <= 4 && labels.allSatisfy { $0.label.count <= 6 }
        return VStack(alignment: .leading, spacing: 4) {
            let label = text(c["label"])
            if !label.isEmpty {
                Text(label).frame(maxWidth: .infinity, alignment: .leading).fixedSize(horizontal: false, vertical: true)
            }
            if let d = drawn {
                if short {
                    DrawnSegments(options: labels, value: binding, colors: d)
                } else if d.staticFields {
                    DrawnBox(text: labels.first { $0.value == binding.wrappedValue }?.label ?? "", placeholder: false, chevron: true, colors: d)
                } else {
                    Menu {
                        ForEach(labels, id: \.value) { o in Button(o.label) { binding.wrappedValue = o.value } }
                    } label: {
                        DrawnBox(text: labels.first { $0.value == binding.wrappedValue }?.label ?? "", placeholder: false, chevron: true, colors: d)
                    }
                    .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                }
            } else {
            let picker = Picker(label, selection: binding) {
                ForEach(labels, id: \.value) { Text($0.label).tag($0.value) }
            }.labelsHidden()
            if short { picker.pickerStyle(.segmented).fixedSize() } else { picker.pickerStyle(.menu).fixedSize() }
            }
        }
    }

    private func field(_ c: [String: JSONValue]) -> AnyView {
        let path = c["value"]?.bindingPath
        let binding = Binding<String>(
            get: { path.flatMap { model.value($0)?.string } ?? c["value"]?.string ?? "" },
            set: { if let p = path { model.set(p, .string($0)) } })
        if let d = drawn, d.staticFields {
            let v = binding.wrappedValue
            return AnyView(DrawnBox(text: v.isEmpty ? text(c["label"]) : v, placeholder: v.isEmpty, chevron: false, colors: d))
        }
        if let d = drawn {
            return AnyView(TextField(text(c["label"]), text: binding).textFieldStyle(.plain).font(.system(size: 13))
                .padding(.horizontal, 10).frame(minHeight: 30)
                .background(RoundedRectangle(cornerRadius: 8).fill(d.card))
                .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(d.input, lineWidth: 1)))
        }
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
    public static func symbol(_ name: String?) -> String {
        switch name {
        case "mail": return "envelope"
        case "calendar": return "calendar"
        case "warning": return "exclamationmark.triangle"
        case "check": return "checkmark"
        case "close": return "xmark"
        case "trash": return "trash"
        case "archive": return "archivebox"
        case "star": return "star"
        case "reply": return "arrowshape.turn.up.left"
        case "clock": return "clock"
        case "info": return "info.circle"
        case "person": return "person"
        case "link": return "link"
        case "memory": return "brain"
        case "question": return "questionmark.circle"
        case "lightbulb": return "lightbulb"
        default: return "circle"
        }
    }
}

/// 一排按钮放不下就折行。
struct FlowLayout: Layout {
    var spacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? .infinity
        var x: CGFloat = 0, y: CGFloat = 0, line: CGFloat = 0, widest: CGFloat = 0
        for v in subviews {
            let s = v.sizeThatFits(.unspecified)
            if x > 0, x + s.width > width { y += line + spacing; x = 0; line = 0 }
            x += s.width + spacing
            line = max(line, s.height)
            widest = max(widest, x - spacing)
        }
        return CGSize(width: min(widest, width), height: y + line)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, line: CGFloat = 0
        for v in subviews {
            let s = v.sizeThatFits(.unspecified)
            if x > bounds.minX, x + s.width > bounds.maxX { y += line + spacing; x = bounds.minX; line = 0 }
            v.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(s))
            x += s.width + spacing
            line = max(line, s.height)
        }
    }
}
