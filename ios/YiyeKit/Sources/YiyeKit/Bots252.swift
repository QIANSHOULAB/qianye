import Foundation

// 252 机器人的话带图、👍👎、定时活（大管家那头 251：pc-butler handheld/botjobs.py、zhangyan.py）。接口 v3.28。
// 这里是不碰界面的那部分：定时活怎么认、寄来的一句放进窗里哪个位置、图存什么名字。

/// 机器人的一条定时活
public struct BotJob: Codable, Equatable, Hashable, Sendable, Identifiable {
    public var id: String
    /// 「每天 20:45」
    public var when: String
    /// 「设计日课」「查资料」
    public var kind: String
    /// 他的原话
    public var what: String
    public var on: Bool

    public init(id: String, when: String, kind: String, what: String, on: Bool) {
        self.id = id; self.when = when; self.kind = kind; self.what = what; self.on = on
    }

    private enum CodingKeys: String, CodingKey { case id, when, kind, what, on }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        when = (try? c.decodeIfPresent(String.self, forKey: .when)) ?? ""
        kind = (try? c.decodeIfPresent(String.self, forKey: .kind)) ?? ""
        what = (try? c.decodeIfPresent(String.self, forKey: .what)) ?? ""
        on = (try? c.decodeIfPresent(Bool.self, forKey: .on)) ?? true
    }

    /// 一行里「干什么」那半句：原话跟种类一样就只写一遍
    public var title: String { what.isEmpty || what == kind ? kind : what }
}

/// 定时活寄进机器人窗的一句话（送来 kind=bot）
public enum BotPost {
    public static let kind = "bot"

    /// 信里图的路径（附件/xx.jpg）→ 手机上存的文件名；奇怪的名字不认
    public static func fileName(_ path: String) -> String? {
        let name = (path as NSString).lastPathComponent
        let ok = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_.")
        guard !name.isEmpty, name.count <= 80, !name.hasPrefix("."), name.unicodeScalars.allSatisfy({ ok.contains($0) }) else { return nil }
        return name
    }

    /// 这封信变成聊天窗里的一行；images = 手机上已经存好的文件名
    public static func line(_ d: ButlerDelivery, images: [String]) -> BotLine? {
        guard let bot = d.bot, !bot.isEmpty, let msg = d.msg, !msg.isEmpty else { return nil }
        return BotLine(who: bot, text: d.text, at: d.at.flatMap { ISOTime.date($0) } ?? Date(), seq: d.seq,
                       msg: msg, images: images.isEmpty ? nil : images, canReact: d.react == true, run: d.run)
    }

    /// 放哪儿：同一趟（run）按 seq 排；别的按时间；这一句（msg）放过了回 nil
    public static func slot(_ line: BotLine, in lines: [BotLine]) -> Int? {
        if let m = line.msg, lines.contains(where: { $0.msg == m }) { return nil }
        if let run = line.run {
            if let j = lines.firstIndex(where: { $0.run == run && ($0.seq ?? 0) > (line.seq ?? 0) }) { return j }
            if let last = lines.lastIndex(where: { $0.run == run }) { return last + 1 }
        }
        return lines.firstIndex { $0.at > line.at } ?? lines.count
    }
}
