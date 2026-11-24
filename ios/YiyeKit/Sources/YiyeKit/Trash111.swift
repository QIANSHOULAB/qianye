import Foundation

// 111：废纸篓留 3 天、思想排泄物抄到电脑、长按批量选。这三件事的规则都放这儿（纯算，能单测），界面和数据库在 app 里。

// ================================================================ 废纸篓：留 3 天
public enum TrashRule {
    public static let keepDays = 3
    public static let keepSeconds: TimeInterval = 3 * 86_400

    /// 扔进来超过 3 天，该真删了
    public static func isExpired(trashedAt: Date, now: Date) -> Bool {
        now.timeIntervalSince(trashedAt) >= keepSeconds
    }

    public enum Left: Equatable, Sendable {
        /// 还剩 n 天（2 天以上）
        case days(Int)
        /// 剩不到 2 天、不少于 1 天
        case tomorrow
        /// 不到 1 天
        case today
    }

    public static func left(trashedAt: Date, now: Date) -> Left {
        let remain = keepSeconds - now.timeIntervalSince(trashedAt)
        if remain < 86_400 { return .today }
        if remain < 2 * 86_400 { return .tomorrow }
        return .days(min(keepDays, Int(remain / 86_400)))
    }

    /// 老数据：扔了但没写时间的，补成现在（从现在起算 3 天）
    public static func backfill(trashed: Bool, trashedAt: Date?, now: Date) -> Date? {
        if trashed && trashedAt == nil { return now }
        return trashedAt
    }
}

// ================================================================ 思想排泄物：抄到电脑
public struct KeepCandidate: Equatable, Sendable {
    public var id: UUID
    public var folder: String
    public var folderToDesk: Bool
    public var trashed: Bool
    public var modifiedAt: Date
    /// 电脑确认收到的那版 modifiedAt
    public var deskAt: Date?

    public init(id: UUID, folder: String, folderToDesk: Bool, trashed: Bool, modifiedAt: Date, deskAt: Date?) {
        self.id = id; self.folder = folder; self.folderToDesk = folderToDesk; self.trashed = trashed
        self.modifiedAt = modifiedAt; self.deskAt = deskAt
    }

    /// 电脑那份不是最新一版
    public var needsDesk: Bool {
        guard folderToDesk, !trashed else { return false }
        guard let d = deskAt else { return true }
        return abs(d.timeIntervalSince(modifiedAt)) > 0.001
    }
}

public enum KeepPlan {
    /// 写字页里停手这么久才寄
    public static let quiet: TimeInterval = 60
    /// 超过这么久还没到电脑，设置页提一句
    public static let staleAfter: TimeInterval = 24 * 3600
    /// 同一版寄出去了、回信还没来：这么久以后可以再寄
    public static let resendAfter: TimeInterval = 120

    /// 现在该寄哪几条。
    /// desk：信箱说电脑在线（pcs 里有 desk）；editing：写字页正开着的那条（停手 60 秒才寄）；force：马上寄的（刚离开写字页、退到后台）；
    /// inflight：已经寄出去、回信还没来的「便签 → （寄的那版 modifiedAt，寄的时间）」，同一版不重复寄
    public static func due(_ notes: [KeepCandidate], now: Date, desk: Bool, editing: UUID? = nil, force: Set<UUID> = [],
                           inflight: [UUID: (modified: Date, sentAt: Date)] = [:]) -> [UUID] {
        guard desk else { return [] }
        return notes.filter { n in
            guard n.needsDesk else { return false }
            if let f = inflight[n.id], abs(f.modified.timeIntervalSince(n.modifiedAt)) < 0.001, now.timeIntervalSince(f.sentAt) < resendAfter { return false }
            if force.contains(n.id) { return true }
            if n.id == editing { return now.timeIntervalSince(n.modifiedAt) >= quiet }
            return true
        }.map(\.id)
    }

    /// 回信算不算寄到了：电脑回的、ok
    public static func reached(ok: Bool, host: String?) -> Bool { ok && host == "电脑" }

    /// 一个回信回来了：该不该把 deskAt 记成寄的那版。比手里的还旧的版本不倒退
    public static func newDeskAt(current: Date?, sent: Date) -> Date {
        guard let c = current else { return sent }
        return max(c, sent)
    }

    public struct Stale: Equatable, Sendable {
        public var folder: String
        public var count: Int
    }

    /// 超过 24 小时还没到电脑的，按夹子数
    public static func stale(_ notes: [KeepCandidate], now: Date) -> [Stale] {
        var counts: [String: Int] = [:]
        var order: [String] = []
        for n in notes where n.needsDesk && now.timeIntervalSince(n.modifiedAt) >= staleAfter {
            if counts[n.folder] == nil { order.append(n.folder) }
            counts[n.folder, default: 0] += 1
        }
        return order.map { Stale(folder: $0, count: counts[$0] ?? 0) }
    }

    /// 名字叫这个的夹子，默认开「抄一份到电脑」
    public static let deskFolderName = "思想排泄物"

    public static func isDeskFolderName(_ name: String) -> Bool {
        name.trimmingCharacters(in: .whitespacesAndNewlines) == deskFolderName
    }

    /// 信箱推来的 hello / state / pc 里的 pcs：哪几台大管家在线，["desk","handheld"]。别的推送、老信箱没有 pcs 的：nil
    public static func machines(in push: String) -> [String]? {
        struct W: Decodable { var t: String; var pcs: [String]? }
        guard let w = try? JSONDecoder().decode(W.self, from: Data(push.utf8)), ["hello", "state", "pc"].contains(w.t) else { return nil }
        return w.pcs
    }
}

extension ButlerRequest {
    /// 一条思想排泄物寄给电脑：kind=keep，写全文，电脑落成 md
    public static func keep(id: String, note: String, folder: String, text: String, created: String, modified: String, at: String, app: String) -> ButlerRequest {
        var r = ButlerRequest(id: id, note: note, kind: .keep, text: text, images: nil, unsure: nil, ask: "keep", at: at, app: app)
        r.folder = folder
        r.created = created
        r.modified = modified
        return r
    }
}

// ================================================================ 长按批量选：拖选
public enum BatchSelect {
    /// 从第 a 条划到第 b 条（不分先后）划过的所有条
    public static func span(_ order: [UUID], from a: Int, to b: Int) -> [UUID] {
        guard !order.isEmpty else { return [] }
        let lo = max(0, min(min(a, b), order.count - 1))
        let hi = max(0, min(max(a, b), order.count - 1))
        return Array(order[lo...hi])
    }

    /// 手指现在在哪一条（y 落在哪个格子里）；在最上面一条之上算第一条，在最下面一条之下算最后一条。frames 按 order 排好
    public static func index(atY y: Double, frames: [(minY: Double, maxY: Double)]) -> Int? {
        guard !frames.isEmpty else { return nil }
        for (i, f) in frames.enumerated() where y >= f.minY && y < f.maxY { return i }
        if y < frames[0].minY { return 0 }
        if y >= frames[frames.count - 1].maxY { return frames.count - 1 }
        // 两条之间的空隙：算上面那条
        var best = 0
        for (i, f) in frames.enumerated() where f.minY <= y { best = i }
        return best
    }

    /// 拖选的结果：开始拖之前选好的 + 从起点划到现在的这一段（往回划，这一段变短，退掉的就不选了）
    public static func selection(base: Set<UUID>, order: [UUID], anchor: Int, current: Int) -> Set<UUID> {
        base.union(span(order, from: anchor, to: current))
    }
}
