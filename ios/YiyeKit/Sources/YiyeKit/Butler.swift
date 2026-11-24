import Foundation

// 一叶笺 ⇄ 大管家 接口 v1（ios/docs/大管家接口.md）。v2 走 Cloudflare 信箱（Mailbox.swift），这根 iCloud 的管子留着当备胎：
//   _大管家/待理顺/<id>.json   手机放请求
//   _大管家/已理顺/<id>.json   大管家放结果
//   _大管家/心跳.json          大管家每 60 秒覆盖写一次

public enum ButlerKind: String, Codable, Sendable { case photo, voice, text, keep }

public struct ButlerRequest: Codable, Equatable, Sendable {
    public var v: Int = 1
    public var id: String
    public var note: String
    public var kind: ButlerKind
    public var text: String
    public var images: [String]?
    public var unsure: [String]?
    public var ask: String = "fix"
    public var at: String
    public var app: String
    /// ask=word（088）：选中的词、会了 known / 不会 learning。别的请求没有这两个字段
    public var word: String?
    public var mark: String?
    /// ask=look（陪玩，100）：上一问手机这头量的秒数（识别、取图、寄出、等回信……），大管家只记进日志
    public var timing: [String: Double]?
    /// ask=look（陪玩，108 起）：这一句的录音在信里哪个路径（files 的键，16 kHz 单声道 WAV）。有录音时 text 是空的，大管家自己认字
    public var audio: String?
    /// ask=deep（深聊，107）：话题号。30 分钟内接着问的是同一个话题，大管家记得前面聊了什么
    public var topic: String?
    /// kind=keep（111，思想排泄物抄到电脑）：夹子名、创建时间、改的时间（ISO）。text 是全文
    public var folder: String?
    public var created: String?
    public var modified: String?
    /// ask=article（114）：要扒的网页地址
    public var url: String?
    /// ask=look（117）：截图开口时已经先寄了（look-pre，note 是这一问的 id），这封不带图
    public var pre: Bool?
    /// ask=look（117）：回答一句一句地回（stage=part，最后 done）
    public var stream: Bool?

    /// ask：fix = 理顺（结果回 已理顺/）；speak = 配音（0.4.0 起，结果走 送来/，带 note）；word = 会了 / 不会（088，见 WordMark.swift）
    public init(id: String, note: String, kind: ButlerKind, text: String, images: [String]?, unsure: [String]?, ask: String = "fix", at: String, app: String) {
        self.id = id; self.note = note; self.kind = kind; self.text = text; self.ask = ask
        self.images = (images?.isEmpty ?? true) ? nil : images
        self.unsure = (unsure?.isEmpty ?? true) ? nil : unsure
        self.at = at; self.app = app
    }
}

public struct ButlerResult: Codable, Equatable, Sendable {
    public var v: Int
    public var id: String
    public var note: String
    public var ok: Bool
    public var text: String?
    public var changes: String?
    public var error: String?
    public var model: String?
    public var at: String?
    /// 陪玩的回信（100）：配好的音在信里哪个路径（files 的键）、大管家那头各段几秒（fetch / brain / voice）、哪台答的
    public var audio: String?
    public var timing: [String: Double]?
    public var host: String?
    /// 陪玩（108）：大管家从录音里认出来的字（没听清是空串）。手机只在工具箱里显示一行，不存
    public var heard: String?
    /// 深聊（107）：这封回信是哪一步——ack（收到了，在想）、answer（想好了：text 完整版、audio 口语版、title 一句话摘要）、
    /// end（说了「大管家，结束」）、topic（换了话题）、failed（没想出来，念 text）
    public var stage: String?
    public var title: String?
    /// 抄到电脑（111）：回的是哪个请求、电脑落成了哪个文件、掌机回 why=desk-only
    public var re: String?
    public var file: String?
    public var why: String?
    public init(v: Int = 1, id: String, note: String, ok: Bool, text: String?, changes: String?, error: String?, model: String? = nil, at: String? = nil,
                audio: String? = nil, timing: [String: Double]? = nil, host: String? = nil, heard: String? = nil,
                stage: String? = nil, title: String? = nil, re: String? = nil, file: String? = nil, why: String? = nil) {
        self.v = v; self.id = id; self.note = note; self.ok = ok; self.text = text; self.changes = changes; self.error = error; self.model = model; self.at = at
        self.audio = audio; self.timing = timing; self.host = host; self.heard = heard
        self.stage = stage; self.title = title
        self.re = re; self.file = file; self.why = why
    }

    private enum CodingKeys: String, CodingKey { case v, id, note, ok, text, changes, error, model, at, audio, timing, host, heard, stage, title, re, file, why }

    /// 新加的几个字段读不懂就当没有（timing 里混了不是数的，整封信不能因为它作废）
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        v = try c.decode(Int.self, forKey: .v)
        id = try c.decode(String.self, forKey: .id)
        note = try c.decodeIfPresent(String.self, forKey: .note) ?? ""
        ok = try c.decode(Bool.self, forKey: .ok)
        text = try c.decodeIfPresent(String.self, forKey: .text)
        changes = try c.decodeIfPresent(String.self, forKey: .changes)
        error = try c.decodeIfPresent(String.self, forKey: .error)
        model = try? c.decodeIfPresent(String.self, forKey: .model)
        at = try? c.decodeIfPresent(String.self, forKey: .at)
        audio = try? c.decodeIfPresent(String.self, forKey: .audio)
        timing = try? c.decodeIfPresent([String: Double].self, forKey: .timing)
        host = try? c.decodeIfPresent(String.self, forKey: .host)
        heard = try? c.decodeIfPresent(String.self, forKey: .heard)
        stage = try? c.decodeIfPresent(String.self, forKey: .stage)
        title = try? c.decodeIfPresent(String.self, forKey: .title)
        re = try? c.decodeIfPresent(String.self, forKey: .re)
        file = try? c.decodeIfPresent(String.self, forKey: .file)
        why = try? c.decodeIfPresent(String.self, forKey: .why)
    }
}

public struct ButlerHeartbeat: Codable, Equatable, Sendable {
    public var v: Int
    public var at: String
    public var host: String?
    public var model: String?
}

public enum ButlerPresence: Equatable, Sendable {
    /// 心跳文件都没有：大管家没来
    case never
    /// 3 分钟内来过
    case online
    /// X 分钟前来过；offline=true 表示超过 10 分钟，算离线
    case seen(minutes: Int, offline: Bool)
    /// 信箱（v2）说大管家不在：最后一次见到是 since（从没见过就 nil）
    case away(since: Date?)

    public static func from(_ hb: ButlerHeartbeat?, now: Date = Date()) -> ButlerPresence {
        guard let hb, let at = ISOTime.date(hb.at) else { return .never }
        let mins = Int((now.timeIntervalSince(at) / 60).rounded(.down))
        if mins < 3 { return .online }
        return .seen(minutes: mins, offline: mins > 10)
    }

    /// 算在不在：3 分钟内来过，或者 10 分钟内来过（iCloud 把心跳带过来有时要慢几分钟）
    public var isHere: Bool {
        switch self {
        case .online: return true
        case .seen(_, let offline): return !offline
        case .never, .away: return false
        }
    }
}

/// 结果回来以后笔记怎么办
public enum ButlerOutcome: Equatable, Sendable {
    /// 交出去以后笔记没被改过：直接换上
    case replace(text: String, changes: String?, count: Int)
    /// 这期间改过了：不覆盖，顶上一条「大管家理好了，点一下换上」
    case offer(text: String, changes: String?, count: Int)
    /// 出错：原样显示 error
    case failed(String)
    /// 理完一个字没改
    case unchanged(changes: String?)
}

public enum Butler {
    public static let version = 1
    public static let dirName = "_大管家"
    public static let inboxName = "待理顺"
    public static let outboxName = "已理顺"
    public static let heartbeatName = "心跳.json"

    public static func encoder() -> JSONEncoder {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return e
    }

    public static func decide(_ r: ButlerResult, current: String, sent: String) -> ButlerOutcome {
        if r.v != version {
            return .failed(r.error ?? "接口版本不对：手机 v\(version)，大管家 v\(r.v)")
        }
        guard r.ok, let text = r.text else {
            return .failed(r.error ?? "大管家回了 ok=false，没写 error")
        }
        let count = TextDiff.hunks(sent, text).count
        if text == sent { return .unchanged(changes: r.changes) }
        if current == sent { return .replace(text: text, changes: r.changes, count: count) }
        return .offer(text: text, changes: r.changes, count: count)
    }
}

public final class ButlerChannel {
    public let root: URL
    public let fs: FileAccess
    public init(root: URL, fs: FileAccess) { self.root = root; self.fs = fs }

    public var dir: URL { root.appendingPathComponent(Butler.dirName, isDirectory: true) }
    public var inbox: URL { dir.appendingPathComponent(Butler.inboxName, isDirectory: true) }
    public var outbox: URL { dir.appendingPathComponent(Butler.outboxName, isDirectory: true) }
    public var heartbeatURL: URL { dir.appendingPathComponent(Butler.heartbeatName) }

    public func prepare() throws {
        try fs.makeDir(inbox)
        try fs.makeDir(outbox)
    }

    /// 放请求：先写 <id>.json.part，写完改名成 <id>.json
    public func submit(_ r: ButlerRequest) throws {
        try prepare()
        let data = try Butler.encoder().encode(r)
        let part = inbox.appendingPathComponent("\(r.id).json.part")
        let final = inbox.appendingPathComponent("\(r.id).json")
        try fs.write(data, to: part)
        try fs.move(part, to: final)
    }

    public func hasRequest(_ id: String) -> Bool { fs.exists(inbox.appendingPathComponent("\(id).json")) }

    /// 撤回还没被大管家拿走的请求（同一条又交了一次，旧的不用再做）
    public func withdraw(_ id: String) {
        try? fs.remove(inbox.appendingPathComponent("\(id).json"))
    }

    /// 读某个请求的结果（还没回来就 nil）。iCloud 占位的先叫它下载
    public func result(_ id: String) -> ButlerResult? {
        let url = outbox.appendingPathComponent("\(id).json")
        if !fs.exists(url) {
            let placeholder = outbox.appendingPathComponent(".\(id).json.icloud")
            guard fs.exists(placeholder) else { return nil }
            _ = fs.ensureDownloaded(url)
            guard fs.exists(url) else { return nil }
        }
        guard fs.ensureDownloaded(url), let data = try? fs.read(url) else { return nil }
        return try? JSONDecoder().decode(ButlerResult.self, from: data)
    }

    /// 已理顺/ 里所有能读的结果（.part 不算）
    public func allResults() -> [ButlerResult] {
        let list = (try? fs.list(outbox)) ?? []
        var ids: [String] = []
        for u in list {
            let name = iCloudPlaceholderRealName(u.lastPathComponent) ?? u.lastPathComponent
            guard name.hasSuffix(".json") else { continue }
            ids.append(String(name.dropLast(5)))
        }
        return ids.compactMap { result($0) }
    }

    /// 结果用完（换进笔记，或者点了不要）删掉
    public func removeResult(_ id: String) {
        try? fs.remove(outbox.appendingPathComponent("\(id).json"))
    }

    public func heartbeat() -> ButlerHeartbeat? {
        let url = heartbeatURL
        if !fs.exists(url) {
            let placeholder = dir.appendingPathComponent(".\(Butler.heartbeatName).icloud")
            if fs.exists(placeholder) { _ = fs.ensureDownloaded(url) }
        }
        guard fs.exists(url), let data = try? fs.read(url) else { return nil }
        return try? JSONDecoder().decode(ButlerHeartbeat.self, from: data)
    }
}

// ================================================================ 改了几处、改了啥：按字比（Myers），连着改的算一处
public enum TextDiff {
    public struct Hunk: Equatable, Sendable {
        public var old: String
        public var new: String
    }

    public enum Op: Equatable { case same(Character), del(Character), ins(Character) }

    /// 逐字比出最短编辑（Myers O((N+M)D)）
    public static func ops(_ a: String, _ b: String) -> [Op] {
        let A = Array(a), B = Array(b)
        let n = A.count, m = B.count
        if n == 0 { return B.map { .ins($0) } }
        if m == 0 { return A.map { .del($0) } }
        let maxD = min(n + m, 800)        // 改得太多就当整段换掉，省内存
        let off = maxD
        var v = [Int](repeating: 0, count: 2 * maxD + 2)
        var trace: [[Int]] = []
        var found = false
        for d in 0...maxD {
            trace.append(v)
            var k = -d
            while k <= d {
                var x: Int
                if k == -d || (k != d && v[off + k - 1] < v[off + k + 1]) { x = v[off + k + 1] } else { x = v[off + k - 1] + 1 }
                var y = x - k
                while x < n && y < m && A[x] == B[y] { x += 1; y += 1 }
                v[off + k] = x
                if x >= n && y >= m { found = true; break }
                k += 2
            }
            if found { break }
        }
        if !found { return A.map { .del($0) } + B.map { .ins($0) } }
        // 往回走
        var x = n, y = m
        var out: [Op] = []
        for d in stride(from: trace.count - 1, through: 1, by: -1) {
            let vv = trace[d]
            let k = x - y
            let prevK: Int
            if k == -d || (k != d && vv[off + k - 1] < vv[off + k + 1]) { prevK = k + 1 } else { prevK = k - 1 }
            let prevX = vv[off + prevK]
            let prevY = prevX - prevK
            while x > prevX && y > prevY { out.append(.same(A[x - 1])); x -= 1; y -= 1 }
            if x == prevX { out.append(.ins(B[y - 1])); y -= 1 } else { out.append(.del(A[x - 1])); x -= 1 }
        }
        while x > 0 && y > 0 { out.append(.same(A[x - 1])); x -= 1; y -= 1 }
        while x > 0 { out.append(.del(A[x - 1])); x -= 1 }
        while y > 0 { out.append(.ins(B[y - 1])); y -= 1 }
        return out.reversed()
    }

    /// 连着改的并成一处。中间只隔一两个没改的字（比如「128O件 → 1,280件」）也算一处
    public static func hunks(_ a: String, _ b: String) -> [Hunk] {
        if a == b { return [] }
        let o = ops(a, b)
        var out: [Hunk] = []
        var cur: Hunk? = nil
        var gap = ""
        for op in o {
            switch op {
            case .same(let c):
                if cur != nil { gap.append(c) }
                if gap.count > 2 || c == "\n" {
                    if let h = cur { out.append(h) }
                    cur = nil; gap = ""
                }
            case .del(let c):
                if cur == nil { cur = Hunk(old: "", new: "") } else if !gap.isEmpty { cur!.old += gap; cur!.new += gap; gap = "" }
                cur!.old.append(c)
            case .ins(let c):
                if cur == nil { cur = Hunk(old: "", new: "") } else if !gap.isEmpty { cur!.old += gap; cur!.new += gap; gap = "" }
                cur!.new.append(c)
            }
        }
        if let h = cur { out.append(h) }
        return out
    }
}

// ================================================================ 一条笔记跟大管家打交道的状态（存进数据库，写字页顶上那行字看它）
public struct ButlerNoteState: Codable, Equatable, Sendable {
    public enum Phase: String, Codable, Sendable {
        case none       // 没交过，或者看完了
        case waiting    // 交出去了：「大管家在理」
        case applied    // 直接换上了：「大管家改了 3 处」，能换回原文
        case offer      // 这期间改过：「大管家理好了，点一下换上」
        case failed     // 出错：原样显示 error，给「再交一次」
        case unchanged  // 理完没改
    }
    public var phase: Phase = .none
    public var requestID: String?
    public var sentText: String?
    public var sentAt: Date?
    /// 换上之前的字（换回原文用）
    public var original: String?
    /// 换回原文时把拿不准的标记也还回去
    public var originalUnsure: String?
    /// 理好的字（offer 时等着换）
    public var proposed: String?
    public var changes: String?
    public var count: Int = 0
    public var error: String?

    public init() {}

    public var isWaiting: Bool { phase == .waiting }

    public mutating func submitted(id: String, text: String, at: Date) {
        self = ButlerNoteState()
        phase = .waiting; requestID = id; sentText = text; sentAt = at
    }

    /// 结果回来：返回要换进笔记的字（不用换就 nil）
    public mutating func receive(_ r: ButlerResult, current: String, currentUnsure: String = "") -> String? {
        guard phase == .waiting, r.id == requestID else { return nil }
        switch Butler.decide(r, current: current, sent: sentText ?? "") {
        case .replace(let text, let changes, let count):
            phase = .applied; original = current; originalUnsure = currentUnsure; proposed = nil
            self.changes = changes; self.count = count
            return text
        case .offer(let text, let changes, let count):
            phase = .offer; proposed = text; self.changes = changes; self.count = count
            return nil
        case .failed(let e):
            phase = .failed; error = e
            return nil
        case .unchanged(let changes):
            phase = .unchanged; self.changes = changes; count = 0
            return nil
        }
    }

    /// 点一下换上：返回新字
    public mutating func acceptOffer(current: String, currentUnsure: String = "") -> String? {
        guard phase == .offer, let p = proposed else { return nil }
        original = current; originalUnsure = currentUnsure
        count = TextDiff.hunks(current, p).count
        phase = .applied; proposed = nil
        return p
    }

    /// 换回原文：返回原来的字
    public mutating func revert() -> String? {
        guard phase == .applied, let o = original else { return nil }
        phase = .none
        let back = o
        original = nil
        return back
    }

    public mutating func dismiss() {
        let keepOriginal = phase == .applied
        if !keepOriginal { self = ButlerNoteState() } else { phase = .none }
    }

    public func encoded() -> String {
        (try? String(data: JSONEncoder().encode(self), encoding: .utf8)) ?? ""
    }

    public static func decode(_ s: String) -> ButlerNoteState {
        guard !s.isEmpty, let d = s.data(using: .utf8), let v = try? JSONDecoder().decode(ButlerNoteState.self, from: d) else { return ButlerNoteState() }
        return v
    }
}
