import AppKit
import LuokeA2UI
import LuokeA2UICore
import SwiftUI

/// 搜索框按类型分组的示例（截图用）：工具协议 §1b 的 hits，两个工具（螺壳搜索、邮件助手，两个邮箱）。
/// 内容全是编的；缩略图在这里画（一页 PDF、一张表、一张截图、一张照片的样子），不读任何文件。
enum SearchSample {
    static let search = "luoke-search", mail = "luoke-mail"
    static let home = "/Users/me/"

    private static func open(reveal: Bool) -> [HitAction] {
        reveal ? [HitAction(title: "打开", primary: true), HitAction(title: "在访达中显示", reveal: true)]
               : [HitAction(title: "打开", primary: true)]
    }

    private static func file(_ id: String, _ kind: String, _ label: String, _ path: String, line: String? = nil,
                             date: String, snippet: String? = nil, thumb: Bool = true) -> WindowHit {
        WindowHit(app: search, hitID: id, kind: kind, kindLabel: label, title: (path as NSString).lastPathComponent,
                  line: line, date: date + "T10:00:00+0800", snippet: snippet, source: "files", path: home + path,
                  thumb: thumb ? "thumb/\(id)" : nil, actions: open(reveal: true))
    }

    private static func letter(_ id: String, to: String, from: String, _ subject: String, date: String, snippet: String) -> WindowHit {
        WindowHit(app: mail, hitID: id, kind: "mail", kindLabel: "邮件", title: subject, line: from, date: date + "T09:30:00+0800",
                  snippet: snippet, source: to, actions: [HitAction(title: "在邮件助手里看", primary: true)])
    }

    /// 搜「发票」：PDF 5、邮件 3、图片 2、表格 1，各工具照自己的顺序
    static let hits: [WindowHit] = [
        file("11-p3", "pdf", "PDF", "Documents/报销/2026 年 1 月差旅报销.pdf", line: "第 3 页", date: "2026-01-13",
             snippet: "…报销单 · 住宿费、交通费各一张电子发票，合计 1,286.00 元，请于 1 月 20 日前交财务…"),
        file("12-p1", "pdf", "PDF", "Downloads/发票开具说明.pdf", line: "第 1 页", date: "2026-10-02",
             snippet: "开具增值税电子普通发票时，请核对购买方名称和纳税人识别号。"),
        file("13", "sheet", "表格", "Documents/报销/十月开支.xlsx", line: "第 1 个工作表", date: "2026-10-31",
             snippet: "「十月」日期：10-05，项目：住宿费发票，金额：420"),
        file("14-p6", "pdf", "PDF", "Documents/合同/办公用品采购合同.pdf", line: "第 6 页", date: "2026-09-18",
             snippet: "乙方应在收到货款后 5 个工作日内开具等额发票。"),
        file("15-p1", "pdf", "PDF", "Downloads/财务助理 简历.pdf", line: "第 1 页", date: "2026-08-07",
             snippet: "熟悉发票管理和报销流程。"),
        file("16", "screenshot", "截图", "Desktop/截屏 2026-10-21 14.02.11.png", date: "2026-10-21",
             snippet: "电子发票 已开具 查看详情"),
        file("17-p2", "pdf", "PDF", "Documents/报销/酒店发票.pdf", line: "第 2 页", date: "2026-01-12",
             snippet: "住宿服务 发票代码 …"),
        file("18", "photo", "照片", "Downloads/票据/IMG_4021.HEIC", date: "2026-10-03", snippet: nil),
        letter("m1", to: "ming@harbor-tech.example", from: "某某出行", "您的行程电子发票已开具", date: "2026-10-03",
               snippet: "您 10 月 2 日的行程电子发票已开具，可在附件中查看。"),
        letter("m2", to: "ming@harbor-tech.example", from: "某某云", "10 月账单与发票", date: "2026-11-01",
               snippet: "您 10 月的账单已出，发票将在 3 个工作日内开具。"),
        letter("m3", to: "ming.home@mailbox.example", from: "某某银行", "信用卡电子账单 2026-09", date: "2026-09-19",
               snippet: "本期账单金额 2,318.40 元，消费明细和发票申请见附件。"),
    ]

    /// 只给卡片、不给 hits 的工具（旧的工具）：照旧画它的卡片
    @MainActor static func card() -> SearchCard? {
        let json = """
        [{"version": "v0.9", "createSurface": {"surfaceId": "luoke-mem/search", "catalogId": "ai.luoke/a2ui/agent/1"}},
         {"version": "v0.9", "updateComponents": {"surfaceId": "luoke-mem/search", "components": [
           {"id": "root", "component": "Column", "children": ["h", "t"]},
           {"id": "h", "component": "Text", "text": "记忆里有 1 条", "variant": "h4"},
           {"id": "t", "component": "Text", "text": "10 月 5 日：住宿费发票交给了财务。", "variant": "caption"}]}}]
        """
        guard let v = try? JSONValue.parse(Data(json.utf8)), let msgs = v.array, let s = try? Surface.build(msgs) else { return nil }
        return SearchCard(id: "luoke-mem/search", surface: SurfaceModel(surface: s))
    }

    static func answer() -> SearchAnswer { SearchAnswer(hits: hits, search: 1, failed: [], asked: 2) }

    /// 窗口要缩略图时核心答的（这里画好）
    @MainActor static func thumbs() -> [String: NSImage] {
        var out: [String: NSImage] = [:]
        for h in hits {
            guard let key = WindowModel.thumbKey(h) else { continue }
            switch h.kind {
            case "pdf": out[key] = page(lines: h.hitID.count + 5)
            case "sheet": out[key] = sheet()
            case "screenshot": out[key] = screenshot()
            case "photo": out[key] = photo()
            default: break
            }
        }
        return out
    }

    private static func draw(_ w: CGFloat, _ h: CGFloat, _ body: @escaping (CGRect) -> Void) -> NSImage {
        NSImage(size: NSSize(width: w, height: h), flipped: true) { r in body(r); return true }
    }

    /// 一页文字（竖的）
    static func page(lines: Int) -> NSImage {
        draw(300, 400) { r in
            NSColor.white.setFill()
            r.fill()
            NSColor(white: 0.78, alpha: 1).setFill()
            NSRect(x: 30, y: 36, width: 140, height: 14).fill()
            NSColor(white: 0.88, alpha: 1).setFill()
            for i in 0..<lines {
                NSRect(x: 30, y: 72 + CGFloat(i) * 24, width: i % 3 == 2 ? 170 : 240, height: 8).fill()
            }
        }
    }

    /// 一张表的前几行
    static func sheet() -> NSImage {
        draw(400, 300) { r in
            NSColor.white.setFill()
            r.fill()
            NSColor(srgbRed: 0.95, green: 0.94, blue: 0.92, alpha: 1).setFill()
            NSRect(x: 0, y: 0, width: 400, height: 26).fill()
            NSColor(srgbRed: 0.86, green: 0.84, blue: 0.81, alpha: 1).setFill()
            for row in 1...11 { NSRect(x: 0, y: CGFloat(row) * 26, width: 400, height: 1).fill() }
            for x in [70, 200, 280] { NSRect(x: CGFloat(x), y: 0, width: 1, height: 300).fill() }
            let cells = [["日期", "项目", "金额", "发票号"], ["10-05", "住宿费发票", "420", "88001"], ["10-06", "打车", "65", "88002"],
                         ["10-09", "办公用品", "138", "88003"]]
            for (i, row) in cells.enumerated() {
                for (j, text) in row.enumerated() {
                    let font = NSFont.systemFont(ofSize: 14, weight: i == 0 ? .semibold : .regular)
                    (text as NSString).draw(at: NSPoint(x: [7, 77, 207, 287][j], y: CGFloat(i) * 26 + 5),
                                            withAttributes: [.font: font, .foregroundColor: NSColor(white: 0.2, alpha: 1)])
                }
            }
        }
    }

    static func screenshot() -> NSImage {
        draw(400, 250) { r in
            NSColor(srgbRed: 0.90, green: 0.93, blue: 0.97, alpha: 1).setFill()
            r.fill()
            NSColor.white.setFill()
            for i in 0..<5 { NSRect(x: 40, y: 40 + CGFloat(i) * 36, width: 320, height: 22).fill() }
        }
    }

    static func photo() -> NSImage {
        draw(400, 300) { r in
            NSGradient(starting: NSColor(srgbRed: 0.78, green: 0.53, blue: 0.35, alpha: 1),
                       ending: NSColor(srgbRed: 0.38, green: 0.22, blue: 0.14, alpha: 1))?.draw(in: r, angle: 60)
            NSColor(srgbRed: 0.95, green: 0.88, blue: 0.72, alpha: 1).setFill()
            NSBezierPath(ovalIn: NSRect(x: 270, y: 40, width: 70, height: 70)).fill()
        }
    }
}
