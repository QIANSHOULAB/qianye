import Foundation

// 「会了」「不会」（088，Song 11-22 21:46：「我希望我在便签里面直接就可以标记哪些单词我是学会了……它自动就发到大脑那边去了」）。
// 笔记里选中一个词，系统菜单点一下，就排进这里；寄给大管家（一个 ask=word 的请求），大管家改 pc-butler tingli 分支的 词表.md，
// 回一个结果。回 ok=true 才从队里拿掉；寄不出去、大管家回 ok=false（比如老版本不认 word），过一会儿再寄。
// 接口：ios/docs/大管家接口.md「v3.1：词」。

public enum WordMark: String, Codable, Sendable, CaseIterable {
    /// 会了：挪到「已掌握」
    case known
    /// 不会：加进「学习中」
    case learning

    /// 选中的字 → 要寄的词。空的、太长的、整段的（带换行、超过 6 个词）、一个字母都没有的：nil（菜单里不出这两项）
    public static func clean(_ selected: String) -> String? {
        let strip = CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: ".,;:!?\"'“”‘’()（）[]【】《》<>*_#`~，。；：！？、-–—"))
        let t = selected.trimmingCharacters(in: strip)
        guard !t.isEmpty, !t.contains("\n"), t.count <= 48 else { return nil }
        let words = t.split(whereSeparator: { $0.isWhitespace })
        guard words.count <= 6, t.unicodeScalars.contains(where: { CharacterSet.letters.contains($0) }) else { return nil }
        return words.joined(separator: " ")
    }

    /// 同一个词：大小写、前后空格不算
    public static func key(_ word: String) -> String {
        word.lowercased().split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
    }
}

extension ButlerRequest {
    /// 一个「会了 / 不会」：ask=word，text 也写上词（老大管家的日志里看得出是什么）
    public static func wordMark(id: String, word: String, mark: WordMark, note: String, at: String, app: String) -> ButlerRequest {
        var r = ButlerRequest(id: id, note: note, kind: .text, text: word, images: nil, unsure: nil, ask: "word", at: at, app: app)
        r.word = word
        r.mark = mark.rawValue
        return r
    }
}

/// 排着队的一个：每寄一次换一个新的请求 id（大管家办过的 id 不办第二次）
public struct WordPending: Codable, Equatable, Sendable {
    public var word: String
    public var mark: WordMark
    public var note: String
    /// 点的时间（ISO，带时区）：大管家拿它算哪天
    public var at: String
    /// 这次寄出去的请求 id（还没寄过：nil）
    public var request: String?
    /// 最近一次寄到信箱的时间（寄不出去：nil）
    public var sentAt: Date?
    /// 大管家上次回 ok=false 的时间
    public var failedAt: Date?
    public var tries: Int = 0

    public init(word: String, mark: WordMark, note: String, at: String) {
        self.word = word; self.mark = mark; self.note = note; self.at = at
    }
}

/// 手机这头的队：点了就进，大管家回 ok=true 就出。存在 UserDefaults 里（JSON）
public struct WordQueue: Codable, Equatable, Sendable {
    public var items: [WordPending] = []
    /// 回了 ok=false 以后隔多久再寄
    public static let retryAfter: TimeInterval = 600
    /// 寄到信箱了、一直没回（大管家关着，信在信箱里等着）：隔多久再寄一份
    public static let resendAfter: TimeInterval = 86_400
    /// 寄这么多次还不成就不寄了（坏的词别一直寄）
    public static let maxTries = 30

    public init(items: [WordPending] = []) { self.items = items }

    /// 点了一下：同一个词还在队里的，换成这次的（只寄最后一次的意思）
    public mutating func add(_ word: String, _ mark: WordMark, note: String, at: String) {
        let k = WordMark.key(word)
        items.removeAll { WordMark.key($0.word) == k }
        items.append(WordPending(word: word, mark: mark, note: note, at: at))
    }

    /// 该寄的：没寄过的；回过 ok=false 隔够了的；寄到信箱一天还没回的
    public func due(now: Date = Date()) -> [WordPending] {
        items.filter { p in
            guard p.tries < WordQueue.maxTries else { return false }
            if let f = p.failedAt { return now.timeIntervalSince(f) >= WordQueue.retryAfter }
            guard let s = p.sentAt else { return true }
            return now.timeIntervalSince(s) >= WordQueue.resendAfter
        }
    }

    /// 要寄了：给它一个新的请求 id
    public mutating func sending(_ word: String, id: String) {
        guard let i = index(word) else { return }
        items[i].request = id
        items[i].tries += 1
    }

    /// 寄到信箱了
    public mutating func sent(_ id: String, at: Date = Date()) {
        guard let i = items.firstIndex(where: { $0.request == id }) else { return }
        items[i].sentAt = at
        items[i].failedAt = nil
    }

    /// 寄不出去（网不通、没配对）：下回再寄
    public mutating func notSent(_ id: String) {
        guard let i = items.firstIndex(where: { $0.request == id }) else { return }
        items[i].sentAt = nil
    }

    /// 信箱的毛病（断网、额度用光、叫等一会儿）：这回不算次数，通了再寄（143：以前 5 秒撞一次，30 次就把这个词放弃了）
    public mutating func deferred(_ id: String) {
        guard let i = items.firstIndex(where: { $0.request == id }) else { return }
        items[i].sentAt = nil
        items[i].tries = max(0, items[i].tries - 1)
    }

    /// 大管家回了：ok 就出队；不 ok 隔一会儿再寄。返回是不是在等它（不是就当没看见）
    @discardableResult
    public mutating func answered(_ id: String, ok: Bool, at: Date = Date()) -> Bool {
        guard let i = items.firstIndex(where: { $0.request == id }) else { return false }
        if ok { items.remove(at: i) } else { items[i].failedAt = at }
        return true
    }

    public var requestIDs: Set<String> { Set(items.compactMap(\.request)) }

    private func index(_ word: String) -> Int? {
        let k = WordMark.key(word)
        return items.firstIndex { WordMark.key($0.word) == k }
    }

    public func encoded() -> Data { (try? JSONEncoder().encode(self)) ?? Data() }
    public static func decode(_ d: Data?) -> WordQueue {
        guard let d, let q = try? JSONDecoder().decode(WordQueue.self, from: d) else { return WordQueue() }
        return q
    }
}
