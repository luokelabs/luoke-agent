import Foundation
import LuokeA2UICore

/// 压力场景的数据：不另造卡片，把工具录的卡片（场景样例经真核心）复制几份，看条目很多时窗口的样子。
@MainActor
enum StressSample {
    /// #54 的回放里开着的急事件数：截图和测试照这个数合成
    static let urgentReplay = 205

    /// `events` 里属于 `app` 的卡片（surface 和 `feed` 里的卡片、顺序）各复制成 `times` 份：
    /// 第 k 份（k ≥ 1）的 surface id、卡片 id 后面加 `~k`，内容不变
    static func scaled(_ events: [(String, Data)], app: String, times: Int) -> [(String, Data)] {
        copied(events, times: times, card: { $0["app"]?.string == app })
    }

    /// 急事很多（#54 的回放：开着两百多件急事）：`app` 的急事卡片复制成 `times` 份，每份的 root 写上一句不同的副标题
    /// （工具协议 §4 `subtitle`，`subtitle(k)` 给第 k 份的）。看紧凑的表里同一类叠成一行、点开以后一行一件分不分得清
    static func urgentFlood(_ events: [(String, Data)], app: String, times: Int, subtitle: @escaping (Int) -> String) -> [(String, Data)] {
        copied(events, times: times, card: { $0["app"]?.string == app && $0["section"]?.string == "urgent" }, edit: { m, k in
            guard var o = m.object, var body = o["updateComponents"]?.object, let comps = body["components"]?.array else { return m }
            body["components"] = .array(comps.map { c in
                guard c["id"]?.string == "root", var r = c.object else { return c }
                r["subtitle"] = .string(subtitle(k))
                return .object(r)
            })
            o["updateComponents"] = .object(body)
            return .object(o)
        })
    }

    /// 要你决定的很多（#51 的 `stress-brief-many`）：`app` 要你决定的卡片复制成 `times` 份。卡片内容不变；
    /// 核心给的标题开头的数换成第几份（「1 封新邮件要处理」→「2 封新邮件要处理」…），简报里列的几件看得出不是同一件
    static func decideFlood(_ events: [(String, Data)], app: String, times: Int) -> [(String, Data)] {
        copied(events, times: times, card: { $0["app"]?.string == app && $0["section"]?.string == "decide" }, retitle: { title, k in
            guard let n = title.firstIndex(where: { !$0.isNumber }), n > title.startIndex else { return title }
            return "\(k + 1)" + title[n...]
        })
    }

    /// 第 k 封可疑邮件的副标题（示意的，写法照邮件助手会填的「发件人 · 主题」）：发件人 8 个、主题 7 个错开轮，
    /// 连着 56 封没有两封一样（一屏放得下的远少于这个数）
    static func mailSubtitle(_ k: Int) -> String {
        let senders = ["某银行安全中心", "快递通知", "云账户团队", "人事部", "税务服务", "Apple 支持", "网盘分享", "积分商城"]
        let subjects = ["账户已冻结，请在 24 小时内验证", "包裹地址有误，请重新填写", "你的密码今天过期", "工资单已更新，请登录查看",
                        "你有一笔退税待领取", "新设备登录了你的账户", "有人给你共享了「合同终版」"]
        return "\(senders[k % senders.count]) · \(subjects[k % subjects.count])"
    }

    /// `card` 挑中的卡片（`feed` 里的卡片和它的 surface）各复制成 `times` 份；`edit` 改每一份的 a2ui 消息（第 0 份是原来那张）
    private static func copied(_ events: [(String, Data)], times: Int, card pick: (JSONValue) -> Bool,
                               retitle: ((String, Int) -> String)? = nil,
                               edit: ((JSONValue, Int) -> JSONValue)? = nil) -> [(String, Data)] {
        let kinds = ["createSurface", "updateComponents", "updateDataModel", "deleteSurface"]
        func surfaceID(_ m: JSONValue) -> String? { kinds.lazy.compactMap { m[$0]?["surfaceId"]?.string }.first }
        func renamed(_ m: JSONValue, _ k: Int) -> JSONValue {
            guard var o = m.object else { return m }
            for kind in kinds {
                if var body = o[kind]?.object, let sid = body["surfaceId"]?.string {
                    body["surfaceId"] = .string("\(sid)~\(k)")
                    o[kind] = .object(body)
                }
            }
            return .object(o)
        }
        var picked = Set<String>()
        for (name, data) in events where name == "feed" {
            for c in (try? JSONValue.parse(data))?["cards"]?.array ?? [] where pick(c) { if let id = c["id"]?.string { picked.insert(id) } }
        }
        var out: [(String, Data)] = []
        for (name, data) in events {
            guard let v = try? JSONValue.parse(data) else { out.append((name, data)); continue }
            if name == "a2ui", let sid = surfaceID(v), picked.contains(sid) {
                out.append((name, edit.map { $0(v, 0).serialized() } ?? data))
                for k in 1..<max(times, 1) {
                    let m = renamed(v, k)
                    out.append((name, (edit.map { $0(m, k) } ?? m).serialized()))
                }
            } else if name == "feed", var feed = v.object {
                let cards = feed["cards"]?.array ?? []
                let mine = cards.filter(pick)
                var extra: [JSONValue] = []
                for k in 1..<max(times, 1) {
                    for c in mine {
                        guard var o = c.object, let id = o["id"]?.string else { continue }
                        o["id"] = .string("\(id)~\(k)")
                        if let retitle, let t = o["title"]?.string { o["title"] = .string(retitle(t, k)) }
                        extra.append(.object(o))
                    }
                }
                feed["cards"] = .array(cards + extra)
                feed["order"] = .array((feed["order"]?.array ?? []) + extra.compactMap { $0["id"] })
                let urgentOrDecide = extra.filter { ["urgent", "decide"].contains($0["section"]?.string ?? "") }.count
                feed["open"] = .number((feed["open"]?.number ?? 0) + Double(urgentOrDecide))
                out.append((name, JSONValue.object(feed).serialized()))
            } else {
                out.append((name, data))
            }
        }
        return out
    }
}
