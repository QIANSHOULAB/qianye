import Foundation

// 250 机器人（大管家那头 249：pc-butler handheld/bots.py）。接口 v3.26（ask=bot）、v3.27（ask=group）。
// 这里是不碰界面的那部分：信里装什么、回信怎么认、群里陆续到的发言怎么排、@ 怎么认、聊天记录带哪几条。

public enum BotID {
    /// 小书童：第 1 个机器人，单聊走原来的聊天窗（ask=shutong）
    public static let shutong = "shutong"
    public static func isGroup(_ id: String) -> Bool { id.hasPrefix("g") }
}

public struct BotCard: Codable, Equatable, Sendable, Identifiable {
    public var id: String
    public var name: String
    public var desc: String
    public var gear: String?
    public var builtin: Bool
    /// 只有看资料页（memory）、新建、改完的回信带
    public var persona: String?

    public init(id: String, name: String, desc: String, gear: String? = nil, builtin: Bool = false, persona: String? = nil) {
        self.id = id; self.name = name; self.desc = desc; self.gear = gear; self.builtin = builtin; self.persona = persona
    }

    private enum CodingKeys: String, CodingKey { case id, name, desc, gear, builtin, persona }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        desc = (try? c.decodeIfPresent(String.self, forKey: .desc)) ?? ""
        gear = try? c.decodeIfPresent(String.self, forKey: .gear)
        builtin = (try? c.decodeIfPresent(Bool.self, forKey: .builtin)) ?? false
        persona = try? c.decodeIfPresent(String.self, forKey: .persona)
    }
}

public struct BotMemo: Codable, Equatable, Hashable, Sendable {
    public var date: String
    public var text: String
    public init(date: String, text: String) { self.date = date; self.text = text }

    private enum CodingKeys: String, CodingKey { case date, text }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        date = (try? c.decodeIfPresent(String.self, forKey: .date)) ?? ""
        text = try c.decode(String.self, forKey: .text)
    }
}

public struct BotGroup: Codable, Equatable, Sendable, Identifiable {
    public var id: String
    public var name: String
    public var members: [String]
    public var chief: String
    public var memory: [BotMemo]

    public init(id: String, name: String, members: [String], chief: String = BotID.shutong, memory: [BotMemo] = []) {
        self.id = id; self.name = name; self.members = members; self.chief = chief; self.memory = memory
    }

    private enum CodingKeys: String, CodingKey { case id, name, members, chief, memory }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        members = (try? c.decodeIfPresent([String].self, forKey: .members)) ?? []
        chief = (try? c.decodeIfPresent(String.self, forKey: .chief)) ?? BotID.shutong
        memory = (try? c.decodeIfPresent([BotMemo].self, forKey: .memory)) ?? []
    }
}

public struct BotTalk: Codable, Equatable, Sendable {
    /// "he" 他；单聊里机器人是 "bot"，群里是机器人 id
    public var who: String
    public var text: String
    public init(who: String, text: String) { self.who = who; self.text = text }
}

/// 请求里 `bot` / `group` 那一块
public struct BotAsk: Codable, Equatable, Sendable {
    /// list / new / edit / delete / chat / memory / forget；群：list / new / edit / delete / say
    public var action: String
    public var id: String?
    public var name: String?
    public var desc: String?
    public var persona: String?
    public var gear: String?
    public var text: String?
    public var history: [BotTalk]?
    public var members: [String]?
    public var chief: String?
    /// 群 say：只让这一个回（小书童要全文时第二轮用）
    public var to: String?

    public init(_ action: String, id: String? = nil, name: String? = nil, desc: String? = nil, persona: String? = nil, gear: String? = nil,
                text: String? = nil, history: [BotTalk]? = nil, members: [String]? = nil, chief: String? = nil, to: String? = nil) {
        self.action = action; self.id = id; self.name = name; self.desc = desc; self.persona = persona; self.gear = gear
        self.text = text; self.history = (history?.isEmpty ?? true) ? nil : history; self.members = members; self.chief = chief; self.to = to
    }

    private enum CodingKeys: String, CodingKey { case action = "do", id, name, desc, persona, gear, text, history, members, chief, to }
}

/// 回信里 `bot` 那一块（stage = bot）
public struct BotReply: Codable, Equatable, Sendable {
    public var action: String
    public var id: String?
    public var say: String?
    /// 今天的额度用完了
    public var quota: Bool?
    public var bot: BotCard?
    public var memory: [BotMemo]?
    public var bots: [BotCard]?
    public var groups: [BotGroup]?

    public init(_ action: String, id: String? = nil, say: String? = nil, quota: Bool? = nil, bot: BotCard? = nil, memory: [BotMemo]? = nil,
                bots: [BotCard]? = nil, groups: [BotGroup]? = nil) {
        self.action = action; self.id = id; self.say = say; self.quota = quota; self.bot = bot; self.memory = memory; self.bots = bots; self.groups = groups
    }

    private enum CodingKeys: String, CodingKey { case action = "do", id, say, quota, bot, memory, bots, groups }
}

/// 群里的一句发言；bot 是空串 = 系统的一行小字
public struct GroupSay: Codable, Equatable, Sendable {
    public var bot: String
    public var text: String
    /// 小书童的发言可以带动作、要全文（跟 v3.10 一样）
    public var acts: [ShutongAct]?
    public var need: [String]?

    public init(bot: String, text: String, acts: [ShutongAct]? = nil, need: [String]? = nil) {
        self.bot = bot; self.text = text; self.acts = acts; self.need = need
    }
}

/// 回信里 `group` 那一块（stage = group）
public struct GroupReply: Codable, Equatable, Sendable {
    public var action: String
    public var id: String?
    public var seq: Int?
    public var done: Bool?
    public var messages: [GroupSay]?
    public var bots: [BotCard]?
    public var groups: [BotGroup]?

    public init(_ action: String, id: String? = nil, seq: Int? = nil, done: Bool? = nil, messages: [GroupSay]? = nil,
                bots: [BotCard]? = nil, groups: [BotGroup]? = nil) {
        self.action = action; self.id = id; self.seq = seq; self.done = done; self.messages = messages; self.bots = bots; self.groups = groups
    }

    private enum CodingKeys: String, CodingKey { case action = "do", id, seq, done, messages, bots, groups }
}

extension ButlerRequest {
    /// 250 机器人：他这句在 bot.text 里，note、text 是空串
    public static func bot(id: String, ask: BotAsk, at: String, app: String) -> ButlerRequest {
        var r = ButlerRequest(id: id, note: "", kind: .text, text: "", images: nil, unsure: nil, ask: "bot", at: at, app: app)
        r.bot = ask
        return r
    }

    /// 250 机器人群：群里有小书童（或这句 @ 了它）带上 shutong 那一块，它才能收拾便签
    public static func group(id: String, ask: BotAsk, shutong: ShutongAsk? = nil, at: String, app: String) -> ButlerRequest {
        var r = ButlerRequest(id: id, note: "", kind: .text, text: "", images: nil, unsure: nil, ask: "group", at: at, app: app)
        r.group = ask
        r.shutong = shutong
        return r
    }
}

// ================================================================ 聊天记录
public struct BotLine: Codable, Identifiable, Equatable, Sendable {
    public var id: UUID
    /// "he" 他；机器人 id；"" 系统小字
    public var who: String
    public var text: String
    public var at: Date
    /// 他那一句：在等的请求 id；回话：回的是哪个请求
    public var rid: String?
    /// 群里陆续到的发言的序号
    public var seq: Int?
    /// 他那一句：waiting / answered / failed
    public var state: String

    public init(id: UUID = UUID(), who: String, text: String, at: Date = Date(), rid: String? = nil, seq: Int? = nil, state: String = "") {
        self.id = id; self.who = who; self.text = text; self.at = at; self.rid = rid; self.seq = seq; self.state = state
    }
}

public enum BotLog {
    public static let maxLines = 200
    public static let historyMax = 30

    /// 带给大管家的前几句：before 那一条之前最近 30 条（系统小字不带；单聊里机器人写 "bot"）
    public static func history(_ lines: [BotLine], before: UUID?, group: Bool) -> [BotTalk] {
        let upto = before.flatMap { b in lines.firstIndex { $0.id == b } } ?? lines.count
        return lines[..<upto].filter { !$0.who.isEmpty && !$0.text.isEmpty }
            .suffix(historyMax)
            .map { BotTalk(who: $0.who == "he" || group ? $0.who : "bot", text: String($0.text.prefix(800))) }
    }

    /// 群里陆续到的发言放哪儿：同一个请求的按 seq 排；晚到的插到该在的位置；这个 seq 已经放过了回 nil
    public static func slot(rid: String, seq: Int, in lines: [BotLine]) -> Int? {
        if lines.contains(where: { $0.who != "he" && $0.rid == rid && $0.seq == seq }) { return nil }
        if let j = lines.firstIndex(where: { $0.who != "he" && $0.rid == rid && ($0.seq ?? 0) > seq }) { return j }
        if let last = lines.lastIndex(where: { $0.rid == rid }) { return last + 1 }
        return lines.count
    }
}

// ================================================================ @
public enum BotMention {
    private static let marks: Set<Character> = ["@", "＠"]

    /// 输入框末尾正在打的 @：回 @ 后面打了的字（"" = 刚打 @）；没在打回 nil
    public static func typing(_ text: String) -> String? {
        guard let i = text.lastIndex(where: { marks.contains($0) }) else { return nil }
        let tail = text[text.index(after: i)...]
        if tail.count > 20 || tail.contains(where: { $0.isWhitespace }) { return nil }
        return String(tail)
    }

    /// 弹出来给他点的成员：名字以打了的字开头
    public static func candidates(_ text: String, members: [BotCard]) -> [BotCard] {
        guard let q = typing(text)?.lowercased() else { return [] }
        return members.filter { q.isEmpty || $0.name.lowercased().hasPrefix(q) }
    }

    /// 点了一个：末尾那个 @… 换成「@名字 」
    public static func insert(_ name: String, into text: String) -> String {
        let head: Substring
        if typing(text) != nil, let i = text.lastIndex(where: { marks.contains($0) }) {
            head = text[..<i]
        } else {
            head = text[...]
        }
        return String(head) + "@" + name + " "
    }

    /// 这句里 @ 了小书童没有
    public static func atScribe(_ text: String, name: String = "小书童") -> Bool {
        text.contains("@" + name) || text.contains("＠" + name)
    }
}

// ================================================================ 头像
public enum BotFace {
    /// 名字第一个字
    public static func letter(_ name: String) -> String {
        name.first.map { String($0).uppercased() } ?? "?"
    }

    /// 颜色按机器人 id 定（每次一样），0..<count
    public static func color(_ id: String, count: Int) -> Int {
        var h: UInt32 = 2166136261
        for b in id.utf8 { h = (h ^ UInt32(b)) &* 16777619 }
        return count > 0 ? Int(h % UInt32(count)) : 0
    }
}
