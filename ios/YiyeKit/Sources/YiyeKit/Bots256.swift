import Foundation

// 256 新建机器人、新建群：填到一半的字、缺什么、哪里不对、「一句话说明」不填时拿什么。
// 名字的规矩照大管家（pc-butler handheld/bots.py 的 clean_name / _fields / group_op），两头对不上时以大管家回的 error 为准。

public enum BotNew {
    public static let nameMax = 20
    public static let descMax = 200
    /// 大管家建的时候会去掉的：空白、@ 和它文件里用的记号
    private static let dropped = "@＠#<>：:，,、"

    /// 建出来叫什么
    public static func cleanName(_ s: String) -> String {
        let marks = dropped.unicodeScalars
        var out = String.UnicodeScalarView()
        for u in s.unicodeScalars where !u.properties.isWhitespace && !marks.contains(u) { out.append(u) }
        return String(out)
    }

    public enum Problem: Equatable, Sendable {
        /// 打了字，去掉空格和 @ 以后什么都不剩
        case nameEmpty
        /// 带上现在几个字（跟大管家一样按码位数）
        case nameTooLong(Int)
        case nameTaken(String)
    }

    /// 名字哪里不对；还没打字不算不对（那是缺）
    public static func nameProblem(_ raw: String, taken: [String]) -> Problem? {
        if trim(raw).isEmpty { return nil }
        let name = cleanName(raw)
        if name.isEmpty { return .nameEmpty }
        let n = name.unicodeScalars.count
        if n > nameMax { return .nameTooLong(n) }
        if taken.contains(where: { $0.lowercased() == name.lowercased() }) { return .nameTaken(name) }
        return nil
    }

    /// 人设的第一句（不带句末的标点）
    public static func firstSentence(_ persona: String) -> String {
        let chars = Array(persona)
        var out = ""
        for (i, c) in chars.enumerated() {
            // 英文句号后面跟着空白、汉字或者没了才算一句完（3.5 里的点不算）
            let dot = c == "." && (i + 1 == chars.count || chars[i + 1].isWhitespace || !chars[i + 1].isASCII)
            if dot || c.isNewline || "。！？；!?;".contains(c) {
                if out.contains(where: { $0.isLetter || $0.isNumber }) { break }
                out = ""
                continue
            }
            out.append(c)
        }
        if !out.contains(where: { $0.isLetter || $0.isNumber }) { out = trim(persona) }
        return String(trim(out).prefix(descMax))
    }

    static func trim(_ s: String) -> String { s.trimmingCharacters(in: .whitespacesAndNewlines) }
}

/// 新机器人页填的
public struct BotDraft: Equatable, Sendable {
    public var name: String
    public var desc: String
    public var persona: String

    public init(name: String = "", desc: String = "", persona: String = "") {
        self.name = name; self.desc = desc; self.persona = persona
    }

    public enum Missing: Equatable, Sendable { case name, persona }

    /// 填了字没有（返回时要不要问一句）
    public var dirty: Bool { !BotNew.trim(name + desc + persona).isEmpty }

    public var missing: [Missing] {
        var m: [Missing] = []
        if BotNew.trim(name).isEmpty { m.append(.name) }
        if BotNew.trim(persona).isEmpty { m.append(.persona) }
        return m
    }

    public func ready(taken: [String]) -> Bool { missing.isEmpty && BotNew.nameProblem(name, taken: taken) == nil }

    /// 寄出去的说明：他写了用他的，没写拿人设第一句
    public var sentDesc: String {
        let d = BotNew.trim(desc)
        return d.isEmpty ? BotNew.firstSentence(persona) : d
    }

    public var sentPersona: String { BotNew.trim(persona) }
}

/// 拉群页填的
public struct BotGroupDraft: Equatable, Sendable {
    public static let membersMin = 2
    public static let membersMax = 6
    public var name: String
    public var members: [String]

    public init(name: String = "", members: [String] = []) {
        self.name = name; self.members = members
    }

    public var dirty: Bool { !BotNew.trim(name).isEmpty || !members.isEmpty }

    /// 寄出去的群名：连着的空白并成一个（大管家也这么办）
    public var sentName: String { name.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ") }

    /// 群名超了几个字（超了大管家会悄悄截短，这里先拦下）
    public var nameTooLong: Int? {
        let n = sentName.unicodeScalars.count
        return n > BotNew.nameMax ? n : nil
    }

    /// 还差几个成员
    public var short: Int { max(0, BotGroupDraft.membersMin - members.count) }

    public var ready: Bool {
        !sentName.isEmpty && nameTooLong == nil && (BotGroupDraft.membersMin...BotGroupDraft.membersMax).contains(members.count)
    }
}
