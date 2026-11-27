import Foundation

/// 234 看板：大管家写的一条便签，原地更新（头一块是「游戏记录」，pc-butler 233）。接口 v3.24（ios/docs/大管家接口.md）。
/// 跟 162 项目待办两码事：不算待办（扔了不回话）；下一封照样盖掉他改的字，扔了就另建一条。
public enum Board {
    public static let kind = "board"
    /// 一块看板最多翻几个号找便签（每扔一次另建，号往后挪一个）
    public static let generations = 64

    /// 信里的看板 id（data.board）。没写 = 不是能认的看板
    public static func id(of d: ButlerDelivery) -> String? {
        let b = (d.board ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        return b.isEmpty ? nil : b
    }

    /// 看板 id → 便签 UUID；generation：头一回 0，扔掉后另建就往后挪
    public static func noteID(_ board: String, generation: Int = 0) -> UUID {
        StableID.uuid("board:\(board)" + (generation == 0 ? "" : "#\(generation)"))
    }

    /// 便签正文：「# 标题」在第一行，下面是 text。text 自己开头带了一行「# …」就去掉，标题只认 title
    public static func markdown(title: String?, text: String) -> String {
        let head = (title ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        var body = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if !head.isEmpty, body.hasPrefix("# ") {
            body = body.firstIndex(of: "\n").map { String(body[$0...]) } ?? ""
        }
        return Todo.markdown(title: head, text: body)
    }
}

/// 手机上一条看板便签现在的样子（app 交进来，规则在这里定）
public struct BoardNow: Equatable, Sendable {
    public var trashed: Bool
    public var markdown: String
    public init(trashed: Bool, markdown: String) { self.trashed = trashed; self.markdown = markdown }
}

/// 每块看板现在对应哪条便签、收下的最新那封是几点写的（app 在 UserDefaults 里存一份 JSON）
public struct BoardBook: Codable, Equatable, Sendable {
    public struct Entry: Codable, Equatable, Sendable {
        public var note: String
        public var at: String?
    }

    public enum Step: Equatable, Sendable {
        /// 新建一条（UUID、正文）
        case create(UUID, String)
        /// 原地盖掉（他改过也盖）
        case update(UUID, String)
        /// 不动，为什么
        case none(String)
    }

    public var items: [String: Entry] = [:]

    public init() {}

    public static func load(_ data: Data?) -> BoardBook {
        guard let data, let b = try? JSONDecoder().decode(BoardBook.self, from: data) else { return BoardBook() }
        return b
    }

    public func data() -> Data { (try? JSONEncoder().encode(self)) ?? Data() }

    /// 收到一封看板信。look：手机上这个 UUID 的便签现在什么样（没有 = nil）
    public mutating func receive(board: String, markdown: String, at: String?, look: (UUID) -> BoardNow?) -> Step {
        let ids = (0..<Board.generations).map { Board.noteID(board, generation: $0) }
        // 现在这条：本子里记的那条还活着就是它；不然在这块看板的号里找活着的（本子丢了、他把旧的放回来了）
        var live: (id: UUID, now: BoardNow)?
        if let r = items[board].flatMap({ UUID(uuidString: $0.note) }), let n = look(r), !n.trashed { live = (r, n) }
        if live == nil {
            for id in ids {
                if let n = look(id), !n.trashed { live = (id, n); break }
            }
        }
        if let found = live {
            // 比收下过的那封写得早（走备用通道迟到的）：不盖
            if let new = at.flatMap({ ISOTime.date($0) }), let old = items[board]?.at.flatMap({ ISOTime.date($0) }), new < old {
                items[board]?.note = found.id.uuidString
                return .none("迟到的")
            }
            items[board] = Entry(note: found.id.uuidString, at: at)
            return found.now.markdown == markdown ? .none("一样") : .update(found.id, markdown)
        }
        // 没有活着的（头一回、他扔了、删干净了）：新建，用手机上空着的号（废纸篓里那条还占着它的号）
        let id = ids.first { look($0) == nil } ?? UUID()
        items[board] = Entry(note: id.uuidString, at: at)
        return .create(id, markdown)
    }

    /// 这条便签是不是哪块看板现在写着的那条（写字页底下那行小字照这个出）
    public func owns(_ note: UUID) -> Bool {
        let s = note.uuidString
        return items.values.contains { $0.note == s }
    }
}

extension ButlerRequest {
    /// 234：看板的信收到了（回执）：note 是那封信的 id
    public static func boardOK(id: String, of letter: String, at: String, app: String) -> ButlerRequest {
        ButlerRequest(id: id, note: letter, kind: .text, text: "", images: nil, unsure: nil, ask: "board-ok", at: at, app: app)
    }
}
