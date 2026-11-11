#if os(macOS)
import AppKit
import LuokeA2UICore
@testable import LuokeA2UI
import SwiftUI
import XCTest

/// 量出来多大、每块摆在哪（相对 `root`）
final class Frames {
    var size: CGSize?
    var at: [String: CGRect] = [:]
}

extension View {
    func probe(_ name: String, _ f: Frames) -> some View {
        onGeometryChange(for: CGRect.self) { $0.frame(in: .named("root")) } action: { f.at[name] = $0 }
    }
}

/// 给子视图提这么宽（`nil` 是它自己的理想宽），记下它答多大，再照这个宽摆
struct Propose: Layout {
    let width: CGFloat?
    let frames: Frames

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let s = subviews.first?.sizeThatFits(ProposedViewSize(width: width, height: nil)) ?? .zero
        frames.size = s
        return s
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        subviews.first?.place(at: bounds.origin, proposal: ProposedViewSize(width: width, height: nil))
    }
}

/// 在离屏的 NSHostingView 里量一遍、摆一遍（不开窗口）
@MainActor
func render<V: View>(_ v: V, width: CGFloat, height: CGFloat = 800) {
    let host = NSHostingView(rootView: v.frame(width: width, height: height, alignment: .topLeading).coordinateSpace(name: "root"))
    host.frame = CGRect(x: 0, y: 0, width: width, height: height)
    for _ in 0..<5 {
        host.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.01))
    }
}

/// 一张卡片：`components` 是 updateComponents 里的组件（JSON 数组的内容）
@MainActor
func card(_ components: String) throws -> SurfaceModel {
    let msgs = try JSONValue.parse(Data("""
    [{"version":"v0.9","createSurface":{"surfaceId":"s","catalogId":"ai.luoke/a2ui/agent/1"}},
     {"version":"v0.9","updateComponents":{"surfaceId":"s","components":[\(components)]}}]
    """.utf8)).array!
    return SurfaceModel(surface: try Surface.build(msgs))
}

/// 给一张卡片提这么宽，它答多大
@MainActor
func sizeOf(_ model: SurfaceModel, width: CGFloat?) -> CGSize {
    let f = Frames()
    render(Propose(width: width, frames: f) { SurfaceView(model: model) { _, _, _ in } }, width: 1200)
    return f.size ?? .zero
}
#endif
