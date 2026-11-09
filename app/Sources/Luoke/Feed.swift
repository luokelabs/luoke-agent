import LuokeA2UI
import LuokeA2UICore
import SwiftUI

/// 窗口里的卡片：照核心的界面协议（GET /feed 的事件）维护。
@MainActor
final class FeedModel: ObservableObject {
    struct Said: Equatable { let text: String; let error: Bool }

    @Published var surfaces: [String: SurfaceModel] = [:]
    @Published var order: [String] = []
    @Published var openCount = 0
    @Published var notices: [String] = []
    @Published var results: [String: Said] = [:]
    @Published var connected = false
    @Published var problem: String?
    @Published var focus: String?

    var onNotify: (([String: Any]) -> Void)?
    var socketPath = ""

    func handle(_ event: String, _ data: Data) {
        switch event {
        case "a2ui":
            guard let m = try? JSONValue.parse(data), let sid = surfaceId(of: m), let (kind, body) = try? unwrapMessage(m) else { return }
            if kind == "createSurface" {
                guard let cat = body["catalogId"]?.string, let s = try? Surface(surfaceId: sid, catalogId: cat) else { return }
                surfaces[sid] = SurfaceModel(surface: s)
                results[sid] = nil
            } else if kind == "deleteSurface" {
                surfaces[sid] = nil
                results[sid] = nil
            } else if let model = surfaces[sid] {
                try? model.receive(m)   // 核心已经整组查过
            }
        case "feed":
            guard let o = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return }
            order = o["order"] as? [String] ?? []
            openCount = o["open"] as? Int ?? 0
            notices = o["notices"] as? [String] ?? []
        case "busy":
            if let o = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any], let sid = o["surfaceId"] as? String {
                surfaces[sid]?.busy = true
            }
        case "result":
            if let o = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any], let sid = o["surfaceId"] as? String {
                surfaces[sid]?.busy = false
                let text = o["text"] as? String ?? ""
                let error = o["error"] as? Bool ?? false
                let replaced = o["replaced"] as? Bool ?? false     // 卡片已经换成结果，那句话上面有了
                results[sid] = text.isEmpty || (replaced && !error) ? nil : Said(text: text, error: error)
            }
        case "notify":
            if let o = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] { onNotify?(o) }
        default:
            break
        }
    }

    /// 用户点了按钮：照 A2UI 的 action 送给核心（上下文按这边的数据模型解析好）。
    func tap(_ sid: String, _ componentId: String, _ context: JSONValue) {
        surfaces[sid]?.busy = true
        let body = JSONValue.object(["surfaceId": .string(sid), "sourceComponentId": .string(componentId), "context": context]).serialized()
        let path = socketPath
        DispatchQueue.global().async {
            let r = try? UnixHTTP.request(path, "POST", "/action", body: body)
            DispatchQueue.main.async {
                self.surfaces[sid]?.busy = false
                if r == nil { self.results[sid] = Said(text: "没连上螺壳的核心。", error: true) }
            }
        }
    }
}

struct FeedView: View {
    @ObservedObject var feed: FeedModel

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(feed.openCount > 0 ? "\(feed.openCount) 件事" : "没有要你看的事").font(.headline)
                Spacer()
                if !feed.connected && feed.problem == nil { ProgressView().controlSize(.small) }
            }
            .padding(.horizontal, 16).padding(.vertical, 10)
            Divider()
            if let p = feed.problem {
                Text(p).foregroundStyle(.secondary).padding(24).frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 12) {
                            ForEach(feed.order, id: \.self) { sid in
                                if let model = feed.surfaces[sid] {
                                    CardView(model: model, said: feed.results[sid]) { cid, _, ctx in feed.tap(sid, cid, ctx) }
                                        .id(sid)
                                }
                            }
                            ForEach(feed.notices, id: \.self) { n in
                                Text(n).font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        .padding(16)
                    }
                    .onChange(of: feed.focus) { _, sid in
                        if let sid { withAnimation { proxy.scrollTo(sid, anchor: .top) } }
                    }
                }
            }
        }
        .frame(minWidth: 400, idealWidth: 460, minHeight: 420, idealHeight: 640)
    }
}

struct CardView: View {
    @ObservedObject var model: SurfaceModel
    let said: FeedModel.Said?
    let onAction: (String, String, JSONValue) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            SurfaceView(model: model, onAction: onAction)
            if model.busy {
                HStack(spacing: 6) { ProgressView().controlSize(.small); Text("正在处理…").font(.caption).foregroundStyle(.secondary) }
            } else if let s = said {
                Text(s.text).font(.caption).foregroundStyle(s.error ? Color.red : Color.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color(nsColor: .controlBackgroundColor)))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color(nsColor: .separatorColor), lineWidth: 0.5))
    }
}
