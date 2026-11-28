import Foundation

// 258 灵感库（大管家那头 257：pc-butler handheld/library.py）。接口 v3.29（ask=library，只走信箱，只有电脑办得了）。
// 这里是不碰界面的那部分：请求和回信怎么认、手机上存的那份目录怎么照回信改、怎么找、照片墙怎么分两列。

/// 请求里 `library` 那一块
public struct LibraryAsk: Codable, Equatable, Sendable {
    /// list / get / drop / undrop
    public var action: String
    public var id: String?
    /// list：上回回信给的 cursor
    public var since: Int?
    public var limit: Int?

    public init(_ action: String, id: String? = nil, since: Int? = nil, limit: Int? = nil) {
        self.action = action; self.id = id; self.since = since; self.limit = limit
    }

    private enum CodingKeys: String, CodingKey { case action = "do", id, since, limit }
}

/// 库里一条的卡片。list 回的只有前一半，get 回的多后一半
public struct LibraryCard: Codable, Equatable, Sendable, Identifiable {
    public var id: String
    public var bot: String
    public var kind: String
    public var date: String
    /// 「少数派」「撑眼眶」；普通的是空串
    public var label: String
    public var punctum: String
    public var move: String
    public var site: String
    public var url: String
    public var tags: [String]
    public var colors: [String]
    /// 缩略图在这封信里的路径
    public var thumb: String?
    public var difference: String
    public var idea: String
    public var good: String
    public var deliberate: String
    public var minorityNote: String
    public var stretchNote: String
    public var gates: [String]

    public init(id: String, bot: String = "", kind: String = "", date: String = "", label: String = "", punctum: String = "",
                move: String = "", site: String = "", url: String = "", tags: [String] = [], colors: [String] = [], thumb: String? = nil,
                difference: String = "", idea: String = "", good: String = "", deliberate: String = "", minorityNote: String = "",
                stretchNote: String = "", gates: [String] = []) {
        self.id = id; self.bot = bot; self.kind = kind; self.date = date; self.label = label; self.punctum = punctum; self.move = move
        self.site = site; self.url = url; self.tags = tags; self.colors = colors; self.thumb = thumb; self.difference = difference
        self.idea = idea; self.good = good; self.deliberate = deliberate; self.minorityNote = minorityNote; self.stretchNote = stretchNote
        self.gates = gates
    }

    private enum CodingKeys: String, CodingKey {
        case id, bot, kind, date, label, punctum, move, site, url, tags, colors, thumb, difference, idea, good, deliberate, gates
        case minorityNote = "minority_note", stretchNote = "stretch_note"
    }

    /// 只有 id 非有不可；别的读不懂当没有
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        func s(_ k: CodingKeys) -> String { (try? c.decodeIfPresent(String.self, forKey: k)) ?? "" }
        func a(_ k: CodingKeys) -> [String] { (try? c.decodeIfPresent([String].self, forKey: k)) ?? [] }
        bot = s(.bot); kind = s(.kind); date = s(.date); label = s(.label); punctum = s(.punctum); move = s(.move)
        site = s(.site); url = s(.url); tags = a(.tags); colors = a(.colors)
        let t = s(.thumb)
        thumb = t.isEmpty ? nil : t
        difference = s(.difference); idea = s(.idea); good = s(.good); deliberate = s(.deliberate)
        minorityNote = s(.minorityNote); stretchNote = s(.stretchNote); gates = a(.gates)
    }
}

/// get 回信里的一张图：crop / crop2 / full / mobile
public struct LibraryPicture: Codable, Equatable, Sendable {
    public var role: String
    public var path: String
    public init(role: String, path: String) { self.role = role; self.path = path }
}

/// 回信里 `library` 那一块（stage = library）
public struct LibraryReply: Codable, Equatable, Sendable {
    public var action: String
    public var id: String?
    public var cursor: Int?
    public var more: Bool?
    public var reset: Bool?
    public var kinds: [String]?
    public var items: [LibraryCard]?
    public var gone: [String]?
    public var item: LibraryCard?
    public var images: [LibraryPicture]?
    public var kept: Bool?

    public init(_ action: String, id: String? = nil, cursor: Int? = nil, more: Bool? = nil, reset: Bool? = nil, kinds: [String]? = nil,
                items: [LibraryCard]? = nil, gone: [String]? = nil, item: LibraryCard? = nil, images: [LibraryPicture]? = nil, kept: Bool? = nil) {
        self.action = action; self.id = id; self.cursor = cursor; self.more = more; self.reset = reset; self.kinds = kinds
        self.items = items; self.gone = gone; self.item = item; self.images = images; self.kept = kept
    }

    private enum CodingKeys: String, CodingKey { case action = "do", id, cursor, more, reset, kinds, items, gone, item, images, kept }

    /// 这封信里点了名的图
    public var paths: [String] { (items ?? []).compactMap { $0.thumb } + (images ?? []).map { $0.path } }
}

extension ButlerRequest {
    /// 258 灵感库
    public static func library(id: String, ask: LibraryAsk, at: String, app: String) -> ButlerRequest {
        var r = ButlerRequest(id: id, note: "", kind: .text, text: "", images: nil, unsure: nil, ask: "library", at: at, app: app)
        r.library = ask
        return r
    }
}

// ================================================================ 手机上存的那份
/// 手机上存好的缩略图：文件名、宽高比
public struct LibraryThumb: Codable, Equatable, Sendable {
    public var name: String
    public var ratio: Double
    public init(name: String, ratio: Double) { self.name = name; self.ratio = ratio }
}

/// 手机上存好的一张原图
public struct LibraryShot: Codable, Equatable, Sendable {
    public var role: String
    public var name: String
    public init(role: String, name: String) { self.role = role; self.name = name }
}

public struct LibraryEntry: Codable, Equatable, Sendable, Identifiable {
    public var card: LibraryCard
    /// 到手机的先后（同一天的，后到的排前）
    public var seq: Int
    public var thumb: LibraryThumb?
    /// 点开过才有
    public var shots: [LibraryShot]?
    public var id: String { card.id }

    public init(card: LibraryCard, seq: Int, thumb: LibraryThumb? = nil, shots: [LibraryShot]? = nil) {
        self.card = card; self.seq = seq; self.thumb = thumb; self.shots = shots
    }

    public var files: [String] { (thumb.map { [$0.name] } ?? []) + (shots ?? []).map { $0.name } }
}

/// 目录。`entries` / `bin` 是大管家说的（在库里 / 不留了）；`pending` 是他刚点、大管家还没回话的（true = 要留，false = 不留），
/// 屏上以它为准；大管家回了话、或者拉回来的跟它一样了，就拿掉。
public struct LibraryBook: Codable, Equatable, Sendable {
    public static let binMax = 60

    public var entries: [String: LibraryEntry] = [:]
    /// 不留了的：图还存着，撤回当场放回来
    public var bin: [LibraryEntry] = []
    public var pending: [String: Bool] = [:]
    public var kinds: [String] = []
    public var cursor = 0
    public var nextSeq = 1

    public init() {}

    /// 现在该在手机上存着的文件（改之前减改之后 = 该删的）
    public var files: Set<String> { Set((Array(entries.values) + bin).flatMap { $0.files }) }

    public func entry(_ id: String) -> LibraryEntry? { entries[id] ?? bin.first { $0.id == id } }
    public func has(_ id: String) -> Bool { entry(id) != nil }
    /// 屏上看得见吗
    public func visible(_ id: String) -> Bool { pending[id] ?? (entries[id] != nil) }
    /// 有东西在库里的机器人（它的窗右上放灵感库按钮）
    public var owners: Set<String> { Set((Array(entries.values) + bin).map { $0.card.bot }.filter { !$0.isEmpty }) }

    /// 屏上该有的：新的在前
    public var shown: [LibraryEntry] {
        var out = entries.values.filter { pending[$0.id] != false }
        out += bin.filter { pending[$0.id] == true && entries[$0.id] == nil }
        return out.sorted { $0.card.date != $1.card.date ? $0.card.date > $1.card.date : $0.seq > $1.seq }
    }

    /// 顶上那一排种类：照大管家给的顺序，只放屏上还有东西的
    public var kindsShown: [String] {
        let have = shown.map { $0.card.kind }.filter { !$0.isEmpty }
        var out = kinds.filter { have.contains($0) }
        for k in have where !out.contains(k) { out.append(k) }
        return out
    }

    /// 按种类和搜的字挑：空格分开的几个词都得对上（刺点、招式、站名、标签）
    public func search(_ query: String, kind: String? = nil) -> [LibraryEntry] {
        let words = query.lowercased().split(whereSeparator: { $0.isWhitespace }).map(String.init)
        return shown.filter { e in
            if let kind, e.card.kind != kind { return false }
            if words.isEmpty { return true }
            let hay = ([e.card.punctum, e.card.move, e.card.site] + e.card.tags).joined(separator: "\n").lowercased()
            return words.allSatisfy { hay.contains($0) }
        }
    }

    private mutating func takeBin(_ id: String) -> LibraryEntry? {
        guard let i = bin.firstIndex(where: { $0.id == id }) else { return nil }
        return bin.remove(at: i)
    }

    private mutating func putBin(_ e: LibraryEntry) {
        bin.removeAll { $0.id == e.id }
        bin.append(e)
        if bin.count > LibraryBook.binMax { bin.removeFirst(bin.count - LibraryBook.binMax) }
    }

    /// 一封 list 的回信；saved：这封带来、已经存好的缩略图（id → 图）
    public mutating func apply(_ r: LibraryReply, saved: [String: LibraryThumb]) {
        var old: [String: LibraryEntry] = [:]
        if r.reset == true {                                       // 库重建过：照这封从头装（取过的原图跟着同一个 id 留下）
            for e in Array(entries.values) + bin { old[e.id] = e }
            entries = [:]
            bin = []
        }
        for card in r.items ?? [] {
            var was = entries[card.id]
            if was == nil { was = takeBin(card.id) }
            if was == nil { was = old[card.id] }
            var c = card
            if let w = was?.card {                                 // list 的卡不带后一半：取过的留着
                if c.difference.isEmpty { c.difference = w.difference }
                if c.idea.isEmpty { c.idea = w.idea }
                if c.good.isEmpty { c.good = w.good }
                if c.deliberate.isEmpty { c.deliberate = w.deliberate }
                if c.minorityNote.isEmpty { c.minorityNote = w.minorityNote }
                if c.stretchNote.isEmpty { c.stretchNote = w.stretchNote }
                if c.gates.isEmpty { c.gates = w.gates }
            }
            var seq = was?.seq ?? 0
            if seq == 0 { seq = nextSeq; nextSeq += 1 }
            entries[c.id] = LibraryEntry(card: c, seq: seq, thumb: saved[c.id] ?? was?.thumb, shots: was?.shots)
            if pending[c.id] == true { pending[c.id] = nil }
        }
        for id in r.gone ?? [] {
            if let e = entries.removeValue(forKey: id) { putBin(e) }
            if pending[id] == false { pending[id] = nil }
        }
        if let k = r.kinds { kinds = k }
        if let c = r.cursor { cursor = c }
    }

    /// 取回来的整张卡和原图
    public mutating func fill(_ id: String, card: LibraryCard?, shots: [LibraryShot]) {
        func filled(_ e: LibraryEntry) -> LibraryEntry {
            var n = e
            if var c = card { c.thumb = e.card.thumb; n.card = c }
            if !shots.isEmpty { n.shots = shots }
            return n
        }
        if let e = entries[id] {
            entries[id] = filled(e)
        } else if let i = bin.firstIndex(where: { $0.id == id }) {
            bin[i] = filled(bin[i])
        }
    }

    /// 他点了 👎（kept = false）或撤回（true）：屏上当场照办
    public mutating func intend(_ id: String, kept: Bool) { pending[id] = kept }

    /// 大管家回话了：办成了
    public mutating func settle(_ id: String, kept: Bool) {
        pending[id] = nil
        if kept {
            if let e = takeBin(id) { entries[id] = e }
        } else if let e = entries.removeValue(forKey: id) {
            putBin(e)
        }
    }

    /// 没办成：回到大管家说的样子
    public mutating func giveUp(_ id: String) { pending[id] = nil }

    // ---------------------------------------------------------------- 照片墙
    /// 照片墙分几列：一张张往最矮的那列放。ratios = 宽 / 高；回每列放第几张
    public static func columns(_ ratios: [Double], count: Int) -> [[Int]] {
        let n = max(1, count)
        var out = [[Int]](repeating: [], count: n)
        var high = [Double](repeating: 0, count: n)
        for (i, r) in ratios.enumerated() {
            var k = 0
            for j in 1..<max(1, n) where high[j] < high[k] - 0.001 { k = j }
            out[k].append(i)
            high[k] += 1 / tileRatio(r)
        }
        return out
    }

    /// 墙上一块的宽高比：太长太扁的裁一裁
    public static func tileRatio(_ r: Double) -> Double { r > 0 ? min(max(r, 0.62), 1.8) : 1 }
}
