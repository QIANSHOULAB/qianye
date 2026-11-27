import Foundation

// 225：谁配的、打几星（接口 v3.21 / v3.22），大管家译好的意思（v3.23）。
// 这里是不碰界面的部分：信里那几块长什么样、本地的分、排队寄、点一个词怎么查。

// ---------------------------------------------------------------- 信里缺字段
/// 缺了这个字段当空字符串（补译的信不带 text，231）。不这么办整封信会被当坏信丢掉
@propertyWrapper
public struct DefaultEmpty: Codable, Equatable, Sendable {
    public var wrappedValue: String
    public init(wrappedValue: String) { self.wrappedValue = wrappedValue }
    public init(from d: Decoder) throws { wrappedValue = try d.singleValueContainer().decode(String.self) }
    public func encode(to e: Encoder) throws {
        var c = e.singleValueContainer()
        try c.encode(wrappedValue)
    }
}

extension KeyedDecodingContainer {
    public func decode(_ type: DefaultEmpty.Type, forKey key: Key) throws -> DefaultEmpty {
        try decodeIfPresent(type, forKey: key) ?? DefaultEmpty(wrappedValue: "")
    }
}

// ---------------------------------------------------------------- 谁配的
/// 听力稿 JSON 里的 voice。认不全也不报错（别因为它丢掉整篇稿），usable 才拿来显示
public struct ListenVoice: Codable, Equatable, Sendable {
    public var engine: String
    public var name: String
    public var label: String
    /// 这个嗓子现在的分（没打过不带）
    public var stars: Int?
    public var starsAt: String?

    enum CodingKeys: String, CodingKey { case engine, name, label, stars, starsAt = "stars_at" }

    public init(engine: String, name: String, label: String, stars: Int? = nil, starsAt: String? = nil) {
        self.engine = engine; self.name = name; self.label = label; self.stars = stars; self.starsAt = starsAt
    }

    public init(from d: Decoder) throws {
        let c = try? d.container(keyedBy: CodingKeys.self)
        engine = (try? c?.decodeIfPresent(String.self, forKey: .engine)) ?? ""
        name = (try? c?.decodeIfPresent(String.self, forKey: .name)) ?? ""
        label = (try? c?.decodeIfPresent(String.self, forKey: .label)) ?? ""
        stars = try? c?.decodeIfPresent(Int.self, forKey: .stars)
        starsAt = try? c?.decodeIfPresent(String.self, forKey: .starsAt)
    }

    public var usable: Bool { !engine.isEmpty && !name.isEmpty }
    /// 同一个嗓子：大小写不算（大管家那头也这么认）
    public var key: String { VoiceRatings.key(engine, name) }
    public var shown: String { label.isEmpty ? name : label }
}

/// 本地记的一个嗓子的分
public struct VoiceRating: Codable, Equatable, Sendable {
    /// 0 = 清掉了 / 没打过
    public var stars: Int
    public var at: Date
    /// 打到 1、2 星之前是几分（「撤回」寄回它）
    public var prev: Int?
    public init(stars: Int, at: Date, prev: Int? = nil) { self.stars = stars; self.at = at; self.prev = prev }
}

/// 嗓子 → 星、什么时候打的。手机上打的和大管家送来的，谁新用谁
public struct VoiceRatings: Codable, Equatable, Sendable {
    public var byKey: [String: VoiceRating] = [:]
    public init(byKey: [String: VoiceRating] = [:]) { self.byKey = byKey }

    public static func key(_ engine: String, _ name: String) -> String { "\(engine.lowercased())|\(name.lowercased())" }
    /// 1、2 星：以后不用
    public static func banned(_ stars: Int) -> Bool { stars == 1 || stars == 2 }

    public func stars(_ key: String) -> Int { byKey[key]?.stars ?? 0 }

    /// 「撤回」该寄几星：打低分之前的；原来没打过：0
    public func undo(_ key: String) -> Int { byKey[key]?.prev ?? 0 }

    /// 他点了第几颗
    public mutating func rate(_ key: String, _ stars: Int, at: Date = Date()) {
        let s = min(5, max(0, stars))
        let old = byKey[key]
        var prev: Int?
        if VoiceRatings.banned(s) {
            let was = old?.stars ?? 0
            prev = VoiceRatings.banned(was) ? (old?.prev ?? 0) : was
        }
        byKey[key] = VoiceRating(stars: s, at: at, prev: prev)
    }

    /// 送来的稿带的分：比手机记的新才用；没写时间的只在手机没记过时用；没带分的不动
    public mutating func delivered(_ v: ListenVoice) {
        guard v.usable, let s = v.stars, (0...5).contains(s) else { return }
        let when = v.starsAt.flatMap { ISOTime.date($0) }
        guard let old = byKey[v.key] else {
            byKey[v.key] = VoiceRating(stars: s, at: when ?? .distantPast)
            return
        }
        // 手机寄出去的时间到秒，大管家回来的也到秒：差不到一秒算同一下
        guard let when, when.timeIntervalSince(old.at) >= 1 else { return }
        byKey[v.key] = VoiceRating(stars: s, at: when)
    }
}

// ---------------------------------------------------------------- 排队寄
extension ButlerRequest {
    /// 给一个嗓子打星：ask=voice，stars 0–5（0 = 清掉）
    public static func voiceStars(id: String, engine: String, voice: String, stars: Int, note: String, at: String, app: String) -> ButlerRequest {
        var r = ButlerRequest(id: id, note: note, kind: .text, text: "\(engine):\(voice) \(stars)星", images: nil, unsure: nil, ask: "voice", at: at, app: app)
        r.engine = engine
        r.voice = voice
        r.stars = stars
        return r
    }
}

public struct VotePending: Codable, Equatable, Sendable {
    public var engine: String
    public var voice: String
    public var stars: Int
    public var note: String
    public var at: String
    public var request: String?
    public var sentAt: Date?
    public var failedAt: Date?
    public var tries: Int = 0
    public var key: String { VoiceRatings.key(engine, voice) }

    public init(engine: String, voice: String, stars: Int, note: String, at: String) {
        self.engine = engine; self.voice = voice; self.stars = stars; self.note = note; self.at = at
    }
}

/// 打星排着队的：规矩跟「会了 / 不会」（WordQueue）一样，大管家回 ok=true 才出队；同一个嗓子只留最后一下
public struct VoteQueue: Codable, Equatable, Sendable {
    public var items: [VotePending] = []
    public init(items: [VotePending] = []) { self.items = items }

    public mutating func add(engine: String, voice: String, stars: Int, note: String, at: String) {
        let p = VotePending(engine: engine, voice: voice, stars: stars, note: note, at: at)
        items.removeAll { $0.key == p.key }
        items.append(p)
    }

    public func due(now: Date = Date()) -> [VotePending] {
        items.filter { p in
            guard p.tries < WordQueue.maxTries else { return false }
            if let f = p.failedAt { return now.timeIntervalSince(f) >= WordQueue.retryAfter }
            guard let s = p.sentAt else { return true }
            return now.timeIntervalSince(s) >= WordQueue.resendAfter
        }
    }

    public mutating func sending(_ key: String, id: String) {
        guard let i = items.firstIndex(where: { $0.key == key }) else { return }
        items[i].request = id
        items[i].tries += 1
    }

    public mutating func sent(_ id: String, at: Date = Date()) {
        guard let i = items.firstIndex(where: { $0.request == id }) else { return }
        items[i].sentAt = at
        items[i].failedAt = nil
    }

    public mutating func notSent(_ id: String) {
        guard let i = items.firstIndex(where: { $0.request == id }) else { return }
        items[i].sentAt = nil
    }

    /// 信箱的毛病：这回不算次数
    public mutating func deferred(_ id: String) {
        guard let i = items.firstIndex(where: { $0.request == id }) else { return }
        items[i].sentAt = nil
        items[i].tries = max(0, items[i].tries - 1)
    }

    @discardableResult
    public mutating func answered(_ id: String, ok: Bool, at: Date = Date()) -> Bool {
        guard let i = items.firstIndex(where: { $0.request == id }) else { return false }
        if ok { items.remove(at: i) } else { items[i].failedAt = at }
        return true
    }

    public var requestIDs: Set<String> { Set(items.compactMap(\.request)) }

    public func encoded() -> Data { (try? JSONEncoder().encode(self)) ?? Data() }
    public static func decode(_ d: Data?) -> VoteQueue {
        guard let d, let q = try? JSONDecoder().decode(VoteQueue.self, from: d) else { return VoteQueue() }
        return q
    }
}

// ---------------------------------------------------------------- 大管家译好的
/// trans（v3.23）。哪块认不出来就当没有，别的照用
public struct ListenTrans: Codable, Equatable, Sendable {
    public struct Phrase: Codable, Equatable, Sendable {
        public var t: String
        public var zh: String
        public init(t: String, zh: String) { self.t = t; self.zh = zh }
    }

    public struct Line: Codable, Equatable, Sendable {
        public var s: String
        public var zh: String
        public var w: [String: String]
        public var p: [Phrase]
        public init(s: String, zh: String, w: [String: String] = [:], p: [Phrase] = []) { self.s = s; self.zh = zh; self.w = w; self.p = p }
        enum CodingKeys: String, CodingKey { case s, zh, w, p }
        public init(from d: Decoder) throws {
            let c = try d.container(keyedBy: CodingKeys.self)
            s = try c.decode(String.self, forKey: .s)
            zh = (try? c.decodeIfPresent(String.self, forKey: .zh)) ?? ""
            w = (try? c.decodeIfPresent([String: String].self, forKey: .w)) ?? [:]
            p = (try? c.decodeIfPresent([Phrase].self, forKey: .p)) ?? []
        }
    }

    public var v: Int
    public var lines: [Line]
    public init(v: Int = 1, lines: [Line]) { self.v = v; self.lines = lines }

    /// 一句解不开就跳过它
    private struct Maybe: Decodable {
        var line: Line?
        init(from d: Decoder) throws { line = try? Line(from: d) }
    }
    enum CodingKeys: String, CodingKey { case v, lines }
    public init(from d: Decoder) throws {
        let c = try? d.container(keyedBy: CodingKeys.self)
        v = (try? c?.decodeIfPresent(Int.self, forKey: .v)) ?? 1
        lines = ((try? c?.decodeIfPresent([Maybe].self, forKey: .lines)) ?? []).compactMap(\.line)
    }

    public var isEmpty: Bool { lines.isEmpty }

    /// 按原句对：一字不差优先，不行把空白理齐了再对
    public func line(for sentence: String) -> Line? {
        if let l = lines.first(where: { $0.s == sentence }) { return l }
        let want = ListenTrans.squash(sentence)
        return lines.first { ListenTrans.squash($0.s) == want }
    }

    static func squash(_ s: String) -> String { s.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ") }
}

public enum TransLookup {
    public struct Hit: Equatable, Sendable {
        /// 在这一句里标哪一段（UTF-16）
        public var range: NSRange
        public var text: String
        public var zh: String
        public init(range: NSRange, text: String, zh: String) { self.range = range; self.text = text; self.zh = zh }
    }

    /// 点了一个词（它在这一句里的范围）：落在哪个词组里就出整个词组；不然查这个词。都没有：nil（苹果翻译兜底）
    public static func word(_ r: NSRange, in sentence: String, line: ListenTrans.Line) -> Hit? {
        let s = sentence as NSString
        guard r.location >= 0, r.length >= 0, r.location + r.length <= s.length else { return nil }
        let token = s.substring(with: r)
        // Minister's 也算在词组 Prime Minister 里：找词组时先不算尾巴上的 's
        var core = r
        if core.length > 2, token.lowercased().hasSuffix("'s") || token.lowercased().hasSuffix("’s") { core.length -= 2 }
        if let p = phrase(core, in: s, line.p) { return p }
        for k in candidates(token) {
            if let zh = line.w[k], !zh.isEmpty { return Hit(range: r, text: token, zh: zh) }
        }
        return nil
    }

    /// 这个词落在哪个词组里（几个都中：取最长的）
    static func phrase(_ r: NSRange, in s: NSString, _ phrases: [ListenTrans.Phrase]) -> Hit? {
        var best: Hit?
        for p in phrases where !p.zh.isEmpty && !p.t.isEmpty {
            var from = 0
            while from < s.length {
                let found = s.range(of: p.t, options: [.caseInsensitive], range: NSRange(location: from, length: s.length - from))
                guard found.location != NSNotFound, found.length > 0 else { break }
                from = found.location + 1
                guard found.location <= r.location, found.location + found.length >= r.location + r.length, whole(found, in: s) else { continue }
                if found.length > (best?.range.length ?? 0) { best = Hit(range: found, text: s.substring(with: found), zh: p.zh) }
            }
        }
        return best
    }

    /// 前后不是字母数字（「in charge」别在「min charges」里中）
    private static func whole(_ r: NSRange, in s: NSString) -> Bool {
        func letter(_ i: Int) -> Bool {
            guard i >= 0, i < s.length, let u = Unicode.Scalar(s.character(at: i)) else { return false }
            return CharacterSet.alphanumerics.contains(u)
        }
        return !letter(r.location - 1) && !letter(r.location + r.length)
    }

    /// 词表里的键：小写，前后的标点去掉（U.S. → u.s）
    public static func key(_ token: String) -> String {
        token.lowercased().trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
    }

    /// 依次试：原样（撇号两种写法都认）→ 去掉 's → 去掉复数的 s → 去掉 es
    public static func candidates(_ token: String) -> [String] {
        let k = key(token)
        var out: [String] = []
        func add(_ x: String) {
            guard !x.isEmpty else { return }
            for y in [x, x.replacingOccurrences(of: "’", with: "'"), x.replacingOccurrences(of: "'", with: "’")] where !out.contains(y) { out.append(y) }
        }
        add(k)
        if k.hasSuffix("'s") || k.hasSuffix("’s") { add(String(k.dropLast(2))) }
        if k.hasSuffix("s") { add(String(k.dropLast())) }
        if k.hasSuffix("es") { add(String(k.dropLast(2))) }
        return out
    }
}

// ---------------------------------------------------------------- 一条听力笔记另外记的
/// 嗓子跟着录音走（手机自己重念的录音不算它配的）；译文跟着笔记走，晚到的补译信只换它
public struct ListenExtras: Codable, Equatable, Sendable {
    /// voice 配的是哪个录音（附件的相对路径）
    public var audio: String?
    public var voice: ListenVoice?
    public var trans: ListenTrans?
    public init(audio: String? = nil, voice: ListenVoice? = nil, trans: ListenTrans? = nil) {
        self.audio = audio; self.voice = voice; self.trans = trans
    }

    /// 送来一篇（新稿、重配带录音；081 只送字；231 补译只带 trans）
    public mutating func delivered(audio rel: String?, voice v: ListenVoice?, trans t: ListenTrans?) {
        if let rel {
            audio = rel
            voice = (v?.usable ?? false) ? v : nil
        }
        if let t, !t.isEmpty { trans = t }
    }

    public func voice(for path: String) -> ListenVoice? {
        guard let voice, voice.usable, audio == path, !path.isEmpty else { return nil }
        return voice
    }

    public var isEmpty: Bool { voice == nil && trans == nil }
}
