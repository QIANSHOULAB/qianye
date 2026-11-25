import Foundation

// 136 书童：一叶笺里住个会动手的小帮手。大管家（大脑）分析，回一串动作；手机照着做之前逐条查，做完留快照，一点撤销全回去。
// 这里是不碰界面和数据库的那部分：问大脑带什么、大脑回什么、白名单怎么查、一批动作怎么做、怎么撤、回执那句话。
// 接口见 ios/docs/大管家接口.md「v3.10：书童」。

// ================================================================ 问大脑（ask=shutong）
/// 便签目录里的一条（不寄全文：开头 200 字）
public struct ShutongCard: Codable, Equatable, Sendable {
    public var id: String
    public var title: String
    public var folder: String
    public var head: String
    public var created: String
    public var modified: String
    public var chars: Int
    public var kind: String
    public var locked: Bool

    public init(id: String, title: String, folder: String, head: String, created: String, modified: String, chars: Int, kind: String, locked: Bool) {
        self.id = id; self.title = title; self.folder = folder; self.head = head
        self.created = created; self.modified = modified; self.chars = chars; self.kind = kind; self.locked = locked
    }
}

/// 一个文件夹：名字、是不是书童建的、几条、最近几条的标题（给大脑看这个夹子装什么）
public struct ShutongFolderInfo: Codable, Equatable, Sendable {
    public var name: String
    public var auto: Bool
    public var count: Int
    public var samples: [String]

    public init(name: String, auto: Bool, count: Int, samples: [String]) {
        self.name = name; self.auto = auto; self.count = count; self.samples = samples
    }
}

/// 聊天窗里最近几句（he = Song，shutong = 书童）
public struct ShutongTalk: Codable, Equatable, Sendable {
    public var who: String
    public var text: String
    public init(who: String, text: String) { self.who = who; self.text = text }
}

/// 请求里 `shutong` 那一块
public struct ShutongAsk: Codable, Equatable, Sendable {
    /// tidy = 新便签一存下就收拾；chat = 聊天窗里他说了一句；sweep = 每周日的清理建议
    public var mode: String
    /// 第几轮：大脑要看全文（need）时手机再寄一轮，带上 full
    public var round: Int
    /// tidy：收拾的是哪一条
    public var target: String?
    public var notes: [ShutongCard]
    public var folders: [ShutongFolderInfo]
    /// 全文：tidy 带那一条；第二轮带大脑点名要的
    public var full: [String: String]?
    public var history: [ShutongTalk]?
    /// 书童自己建过几个文件夹、上限几个（到了就别再建，回执里问一句）
    public var autoFolders: Int
    public var folderCap: Int

    public init(mode: String, round: Int = 1, target: String? = nil, notes: [ShutongCard], folders: [ShutongFolderInfo],
                full: [String: String]? = nil, history: [ShutongTalk]? = nil, autoFolders: Int, folderCap: Int = ShutongPlan.folderCap) {
        self.mode = mode; self.round = round; self.target = target; self.notes = notes; self.folders = folders
        self.full = (full?.isEmpty ?? true) ? nil : full
        self.history = (history?.isEmpty ?? true) ? nil : history
        self.autoFolders = autoFolders; self.folderCap = folderCap
    }
}

extension ButlerRequest {
    /// 136 书童：text = 他这一句（收拾、清理建议是空串），note 是空串（不属于哪一条便签）
    public static func shutong(id: String, text: String, ask: ShutongAsk, at: String, app: String) -> ButlerRequest {
        var r = ButlerRequest(id: id, note: "", kind: .text, text: text, images: nil, unsure: nil, ask: "shutong", at: at, app: app)
        r.shutong = ask
        return r
    }

    /// 136 书童聊天窗按住说话：录音在信里 audio 那个路径（16 kHz 单声道 WAV），大管家用 SenseVoice 认字，回 heard
    public static func shutongHear(id: String, audio: String, at: String, app: String) -> ButlerRequest {
        var r = ButlerRequest(id: id, note: "", kind: .voice, text: "", images: nil, unsure: nil, ask: "shutong-hear", at: at, app: app)
        r.audio = audio
        return r
    }
}

// ================================================================ 大脑回什么
/// 一个动作。op：title 改标题 / folder 建文件夹 / move 挪 / tidy 收拾口语 / pin 置顶 / merge 合并 / trash 扔废纸篓
public struct ShutongAct: Codable, Equatable, Sendable {
    public var op: String
    public var note: String?
    /// merge：并进哪一条
    public var into: String?
    public var title: String?
    /// folder：新文件夹的名字
    public var name: String?
    /// move：挪进哪个文件夹（"" = 全部便签）
    public var folder: String?
    /// tidy：收拾好的正文（不含标题行）；merge：合并后的正文（不给就两条接起来）
    public var text: String?
    /// pin：true 置顶、false 取消
    public var on: Bool?
    /// trash：为什么觉得能扔（清理建议列表里显示）
    public var why: String?
    /// 他在这句话里点名了这一条：受保护的也能动（只在聊天窗里算）
    public var named: Bool?

    public init(op: String, note: String? = nil, into: String? = nil, title: String? = nil, name: String? = nil, folder: String? = nil,
                text: String? = nil, on: Bool? = nil, why: String? = nil, named: Bool? = nil) {
        self.op = op; self.note = note; self.into = into; self.title = title; self.name = name; self.folder = folder
        self.text = text; self.on = on; self.why = why; self.named = named
    }

    private enum CodingKeys: String, CodingKey { case op, note, into, title, name, folder, text, on, why, named }

    /// 读不懂的字段当没有（大脑偶尔把 on 写成字符串）
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        op = (try? c.decode(String.self, forKey: .op)) ?? ""
        note = try? c.decodeIfPresent(String.self, forKey: .note)
        into = try? c.decodeIfPresent(String.self, forKey: .into)
        title = try? c.decodeIfPresent(String.self, forKey: .title)
        name = try? c.decodeIfPresent(String.self, forKey: .name)
        folder = try? c.decodeIfPresent(String.self, forKey: .folder)
        text = try? c.decodeIfPresent(String.self, forKey: .text)
        if let b = try? c.decodeIfPresent(Bool.self, forKey: .on) { on = b }
        else if let s = try? c.decodeIfPresent(String.self, forKey: .on) { on = ["true", "1", "yes"].contains(s.lowercased()) }
        else { on = nil }
        why = try? c.decodeIfPresent(String.self, forKey: .why)
        named = try? c.decodeIfPresent(Bool.self, forKey: .named)
    }

    /// 扔东西、合并：先列出来，他点「照办」才动手
    public var needsConfirm: Bool { op == "trash" || op == "merge" }
}

/// 回信里 `shutong` 那一块
public struct ShutongReply: Codable, Equatable, Sendable {
    /// 一句人话
    public var say: String?
    public var acts: [ShutongAct]?
    /// 要看全文的便签 id（手机再寄一轮）
    public var need: [String]?

    public init(say: String? = nil, acts: [ShutongAct]? = nil, need: [String]? = nil) {
        self.say = say; self.acts = acts; self.need = need
    }
}

// ================================================================ 便签在书童眼里的样子
/// 一条便签书童会动到的那几样。快照、撤销都用它：撤销 = 把这几样原样放回去
public struct ShutongNote: Codable, Equatable, Sendable {
    public var id: String
    public var markdown: String
    /// nil = 全部便签（不在文件夹里）
    public var folder: String?
    public var pinned: Bool
    public var trashed: Bool
    public var trashedAt: Date?
    public var modifiedAt: Date
    /// 原话（收拾口语之前那一版）；空 = 没收拾过
    public var spoken: String
    public var kind: String
    /// 他手动换过纸色
    public var manualPaper: Bool
    /// 是书童置顶的（不是他手动置顶的）
    public var pinnedBy: Bool

    public init(id: String, markdown: String, folder: String?, pinned: Bool, trashed: Bool, trashedAt: Date?, modifiedAt: Date,
                spoken: String, kind: String, manualPaper: Bool, pinnedBy: Bool) {
        self.id = id; self.markdown = markdown; self.folder = folder; self.pinned = pinned; self.trashed = trashed
        self.trashedAt = trashedAt; self.modifiedAt = modifiedAt; self.spoken = spoken; self.kind = kind
        self.manualPaper = manualPaper; self.pinnedBy = pinnedBy
    }

    /// 受保护：他手动换过纸色，或者他手动置顶的。书童不碰（他点名了才动）
    public var locked: Bool { manualPaper || (pinned && !pinnedBy) }

    /// 撤销时比的那几样（他后来自己又改过的，撤销不盖掉他的字）
    func same(as o: ShutongNote) -> Bool {
        markdown == o.markdown && folder == o.folder && pinned == o.pinned && trashed == o.trashed
    }
}

// ================================================================ 查：白名单、找不到、受保护
public struct ShutongSkip: Equatable, Sendable {
    public var act: ShutongAct
    public var why: String
}

public struct ShutongChecked: Equatable, Sendable {
    public var ok: [ShutongAct]
    public var skipped: [ShutongSkip]
    /// 书童建的文件夹到上限了，还想建：回执里问一句
    public var folderCapHit: Bool
    public var needsConfirm: Bool { ok.contains { $0.needsConfirm } }
}

public enum ShutongPlan {
    public static let ops: Set<String> = ["title", "folder", "move", "tidy", "pin", "merge", "trash"]
    /// 书童自己建的文件夹最多这么多个（Song：别越分越碎）
    public static let folderCap = 10
    public static let folderNameMax = 12
    public static let titleMax = 40

    /// 逐条查。mode：tidy 只许动 target 那一条、只起标题（没标题才起）、只挪「全部」里的、只收拾语音的；chat 他点名的受保护便签也能动。
    /// notes：id → 现在的样子；folders：现有文件夹的名字；autoFolders：书童已经建过几个
    public static func check(_ acts: [ShutongAct], notes: [String: ShutongNote], folders: [String], autoFolders: Int,
                             mode: String, target: String? = nil) -> ShutongChecked {
        var ok: [ShutongAct] = []
        var skipped: [ShutongSkip] = []
        var capHit = false
        var known = Set(folders)
        var made = 0
        var gone = Set<String>()                     // 这一批里已经扔了、并掉了的
        var tidied = Set<String>()
        func skip(_ a: ShutongAct, _ why: String) { skipped.append(ShutongSkip(act: a, why: why)) }

        for raw in acts {
            var a = raw
            guard ops.contains(a.op) else { skip(a, "不在白名单：\(a.op)"); continue }
            if a.op == "folder" {
                let name = (a.name ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                guard !name.isEmpty, name.count <= folderNameMax, !name.contains("/"), !name.contains("\n") else { skip(a, "文件夹名不行"); continue }
                if known.contains(name) { continue }                       // 已经有了：不用建
                // 上限只管它自己建（收拾、清理建议）；聊天窗里他让建就建
                if mode != "chat" && autoFolders + made >= folderCap { capHit = true; skip(a, "书童建的文件夹到 \(folderCap) 个了"); continue }
                a.name = name
                known.insert(name)
                made += 1
                ok.append(a)
                continue
            }
            guard let id = a.note, let n = notes[id], !n.trashed, !gone.contains(id) else { skip(a, "找不到这条"); continue }
            if mode == "tidy", let target, id != target { skip(a, "收拾只管新的这一条"); continue }
            let named = mode == "chat" && a.named == true
            if n.locked && !named { skip(a, "受保护：他手动换过纸色或置顶的"); continue }
            switch a.op {
            case "title":
                let t = (a.title ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                guard !t.isEmpty, t.count <= titleMax, !t.contains("\n") else { skip(a, "标题不行"); continue }
                if mode != "chat", ShutongText.heading(n.markdown) != nil { skip(a, "已经有标题"); continue }
                a.title = t
            case "move":
                let f = (a.folder ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                if !f.isEmpty && !known.contains(f) { skip(a, "没有这个文件夹：\(f)"); continue }
                if mode != "chat", n.folder != nil { skip(a, "他放好的不挪"); continue }
                if (n.folder ?? "") == f { continue }                       // 本来就在那儿
                a.folder = f
            case "tidy":
                let t = (a.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                guard !t.isEmpty else { skip(a, "收拾完是空的"); continue }
                if mode != "chat", n.kind != "voice" { skip(a, "只收拾语音记下的"); continue }
                if tidied.contains(id) { skip(a, "同一条收拾了两遍"); continue }
                let old = ShutongText.body(n.markdown)
                let lost = ShutongText.lost(from: old, to: t)
                if !lost.isEmpty { skip(a, "数字或代码对不上：" + lost.sorted().prefix(5).joined(separator: "、")); continue }
                a.text = t
                tidied.insert(id)
            case "pin":
                if a.on == nil { a.on = true }
            case "merge":
                guard let into = a.into, into != id, let m = notes[into], !m.trashed, !gone.contains(into) else { skip(a, "找不到并进去的那条"); continue }
                if m.locked && !(mode == "chat" && a.named == true) { skip(a, "受保护：并进去的那条他手动动过"); continue }
                if mode == "tidy" { skip(a, "收拾不合并"); continue }
                if let t = a.text?.trimmingCharacters(in: .whitespacesAndNewlines), !t.isEmpty {
                    let lost = ShutongText.lost(from: n.markdown + "\n" + m.markdown, to: t)
                    if !lost.isEmpty { skip(a, "合并后数字或代码对不上：" + lost.sorted().prefix(5).joined(separator: "、")); continue }
                    a.text = t
                } else {
                    a.text = nil
                }
                gone.insert(id)
            case "trash":
                if mode == "tidy" { skip(a, "收拾不扔东西"); continue }
                gone.insert(id)
            default:
                break
            }
            ok.append(a)
        }
        return ShutongChecked(ok: ok, skipped: skipped, folderCapHit: capHit)
    }
}

// ================================================================ 做、撤
/// 这一批干了啥（回执那句话照它说）
public struct ShutongCounts: Codable, Equatable, Sendable {
    public var titles = 0
    public var folders: [String] = []
    /// 挪进哪个文件夹几条（"" = 挪回全部）
    public var moved: [String: Int] = [:]
    public var tidied = 0
    public var pinned = 0
    public var unpinned = 0
    public var merged = 0
    public var trashed = 0
    public init() {}

    public var isEmpty: Bool { titles == 0 && folders.isEmpty && moved.isEmpty && tidied == 0 && pinned == 0 && unpinned == 0 && merged == 0 && trashed == 0 }
}

/// 一批动作的快照：before = 动之前（只存动过的那几条）；after = 刚做完的样子（撤销时比：他后来又改过的不盖）；made = 这一批新建的文件夹
public struct ShutongBatch: Codable, Equatable, Sendable {
    public var id: String
    public var at: Date
    public var before: [ShutongNote]
    public var after: [ShutongNote]
    public var made: [String]
    public var counts: ShutongCounts
    public var undone: Bool

    public init(id: String, at: Date, before: [ShutongNote], after: [ShutongNote], made: [String], counts: ShutongCounts, undone: Bool = false) {
        self.id = id; self.at = at; self.before = before; self.after = after; self.made = made; self.counts = counts; self.undone = undone
    }
}

public enum ShutongApply {
    /// 照查过的动作做（先收拾正文，再别的）。notes、folders 原地改；返回这一批的快照
    public static func run(_ acts: [ShutongAct], notes: inout [String: ShutongNote], folders: inout [String], now: Date, id: String) -> ShutongBatch {
        var before: [String: ShutongNote] = [:]
        var order: [String] = []
        var made: [String] = []
        var c = ShutongCounts()
        func touch(_ nid: String) {
            guard before[nid] == nil, let n = notes[nid] else { return }
            before[nid] = n
            order.append(nid)
        }
        let sorted = acts.filter { $0.op == "tidy" } + acts.filter { $0.op != "tidy" }
        for a in sorted {
            switch a.op {
            case "folder":
                guard let name = a.name, !folders.contains(name) else { continue }
                folders.append(name)
                made.append(name)
                c.folders.append(name)
            case "title":
                guard let nid = a.note, var n = notes[nid], let t = a.title else { continue }
                touch(nid)
                n.markdown = ShutongText.setTitle(n.markdown, t)
                n.modifiedAt = now
                notes[nid] = n
                c.titles += 1
            case "move":
                guard let nid = a.note, var n = notes[nid] else { continue }
                touch(nid)
                let f = a.folder ?? ""
                n.folder = f.isEmpty ? nil : f
                notes[nid] = n
                c.moved[f, default: 0] += 1
            case "tidy":
                guard let nid = a.note, var n = notes[nid], let t = a.text else { continue }
                touch(nid)
                if n.spoken.isEmpty { n.spoken = before[nid]?.markdown ?? n.markdown }      // 原话一个字不丢：收拾之前那一版
                n.markdown = ShutongText.compose(heading: ShutongText.heading(n.markdown), body: t)
                n.modifiedAt = now
                notes[nid] = n
                c.tidied += 1
            case "pin":
                guard let nid = a.note, var n = notes[nid] else { continue }
                touch(nid)
                let on = a.on ?? true
                if n.pinned == on { continue }
                n.pinned = on
                n.pinnedBy = on
                notes[nid] = n
                if on { c.pinned += 1 } else { c.unpinned += 1 }
            case "merge":
                guard let nid = a.note, let into = a.into, var n = notes[nid], var m = notes[into] else { continue }
                touch(nid); touch(into)
                m.markdown = a.text ?? (m.markdown.trimmingCharacters(in: .whitespacesAndNewlines) + "\n\n" + n.markdown.trimmingCharacters(in: .whitespacesAndNewlines))
                m.modifiedAt = now
                n.trashed = true
                n.trashedAt = now
                notes[into] = m
                notes[nid] = n
                c.merged += 1
            case "trash":
                guard let nid = a.note, var n = notes[nid] else { continue }
                touch(nid)
                n.trashed = true
                n.trashedAt = now
                notes[nid] = n
                c.trashed += 1
            default:
                continue
            }
        }
        let b = order.compactMap { before[$0] }
        let after = order.compactMap { notes[$0] }
        return ShutongBatch(id: id, at: now, before: b, after: after, made: made, counts: c)
    }

    /// 撤销一批：每条放回动之前的样子。他后来自己又改过的那条不动（返回这些 id），别把他的字盖掉。
    /// 这一批建的文件夹：没有便签了（放回去以后）就拿掉
    @discardableResult
    public static func undo(_ b: ShutongBatch, notes: inout [String: ShutongNote], folders: inout [String]) -> [String] {
        var kept: [String] = []
        let after = Dictionary(b.after.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        for old in b.before {
            guard let now = notes[old.id] else { continue }                       // 真删了（废纸篓到期）：没法放回
            if let a = after[old.id], !now.same(as: a) { kept.append(old.id); continue }
            notes[old.id] = old
        }
        for name in b.made {
            let used = notes.values.contains { $0.folder == name }
            if !used { folders.removeAll { $0 == name } }
        }
        return kept
    }
}

// ================================================================ 字
public enum ShutongText {
    /// 第一行是「# 标题」就返回标题
    public static func heading(_ md: String) -> String? {
        let first = md.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: false).first.map(String.init) ?? ""
        let t = first.trimmingCharacters(in: .whitespaces)
        guard t.hasPrefix("# ") else { return nil }
        let h = String(t.dropFirst(2)).trimmingCharacters(in: .whitespaces)
        return h.isEmpty ? nil : h
    }

    /// 去掉「# 标题」那一行以后的正文
    public static func body(_ md: String) -> String {
        guard heading(md) != nil else { return md }
        let parts = md.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: false)
        return parts.count > 1 ? String(parts[1]).trimmingCharacters(in: .newlines) : ""
    }

    /// 起标题：第一行是「# 」就换掉，不是就在最上面加一行
    public static func setTitle(_ md: String, _ title: String) -> String {
        if heading(md) != nil { return "# \(title)\n" + body(md) }
        return "# \(title)\n" + md
    }

    public static func compose(heading: String?, body: String) -> String {
        guard let heading else { return body }
        return "# \(heading)\n" + body
    }

    /// 带数字的那些词（数字、型号、代码：A3、VMC-850、1280、12:30）。逗号不算（1,280 = 1280）
    public static func tokens(_ s: String) -> Set<String> {
        let pattern = "[A-Za-z0-9][A-Za-z0-9._:/\\-]*"
        guard let re = try? NSRegularExpression(pattern: pattern) else { return [] }
        let plain = s.replacingOccurrences(of: ",", with: "")
        var out = Set<String>()
        for m in re.matches(in: plain, range: NSRange(plain.startIndex..., in: plain)) {
            guard let r = Range(m.range, in: plain) else { continue }
            var w = String(plain[r])
            while let last = w.last, ".:/-".contains(last) { w.removeLast() }
            if w.contains(where: { $0.isNumber }) { out.insert(w.uppercased()) }
        }
        return out
    }

    /// 原来有、收拾以后没了的数字和代码
    public static func lost(from old: String, to new: String) -> Set<String> {
        let a = tokens(old)
        let b = tokens(new)
        let flat = new.replacingOccurrences(of: ",", with: "").uppercased()
        return Set(a.filter { !b.contains($0) && !flat.contains($0) })
    }
}

// ================================================================ 回执那句人话
public enum ShutongReceipt {
    /// 「起了 3 个标题，挪了 2 条进『机床』，收拾了 1 条语音」。什么都没干返回 nil
    public static func line(_ c: ShutongCounts, zh: Bool) -> String? {
        var parts: [String] = []
        if !c.folders.isEmpty {
            parts.append(zh ? "建了文件夹" + c.folders.map { "『\($0)』" }.joined(separator: "、")
                            : "made " + c.folders.map { "“\($0)”" }.joined(separator: ", "))
        }
        if c.titles > 0 { parts.append(zh ? "起了 \(c.titles) 个标题" : "titled \(c.titles)") }
        for (f, n) in c.moved.sorted(by: { $0.key < $1.key }) {
            if f.isEmpty { parts.append(zh ? "\(n) 条挪回全部便签" : "moved \(n) back to All Notes") }
            else { parts.append(zh ? "挪了 \(n) 条进『\(f)』" : "moved \(n) into “\(f)”") }
        }
        if c.tidied > 0 { parts.append(zh ? "收拾了 \(c.tidied) 条语音" : "tidied \(c.tidied) voice note\(c.tidied == 1 ? "" : "s")") }
        if c.pinned > 0 { parts.append(zh ? "置顶了 \(c.pinned) 条" : "pinned \(c.pinned)") }
        if c.unpinned > 0 { parts.append(zh ? "取消置顶 \(c.unpinned) 条" : "unpinned \(c.unpinned)") }
        if c.merged > 0 { parts.append(zh ? "合并了 \(c.merged) 对重复的" : "merged \(c.merged) duplicate\(c.merged == 1 ? "" : "s")") }
        if c.trashed > 0 { parts.append(zh ? "扔了 \(c.trashed) 条进废纸篓（3 天能捞）" : "trashed \(c.trashed) (back within 3 days)") }
        guard !parts.isEmpty else { return nil }
        if zh { return parts.joined(separator: "，") }
        let s = parts.joined(separator: ", ")
        return s.prefix(1).uppercased() + s.dropFirst()
    }
}

// ================================================================ 一条便签跟书童的来往（存在 Note.shutong 里）
public struct ShutongNoteState: Codable, Equatable, Sendable {
    /// queued 等着收拾 / sent 寄出去了在等 / done 收拾过 / skip 不收拾了
    public var phase: String = ""
    public var rid: String?
    public var sentAt: Date?
    /// 寄出去那一版的 modifiedAt：回信来时他改过了，就不动正文
    public var sentModified: Double?
    /// 书童置顶的（不算他手动置顶）
    public var pinnedBy: Bool = false
    public var tries: Int = 0

    public init() {}

    public static func decode(_ s: String) -> ShutongNoteState {
        guard !s.isEmpty, let d = s.data(using: .utf8), let v = try? JSONDecoder().decode(ShutongNoteState.self, from: d) else { return ShutongNoteState() }
        return v
    }

    public func encoded() -> String {
        guard let d = try? JSONEncoder().encode(self) else { return "" }
        return String(decoding: d, as: UTF8.self)
    }

    public static let maxTries = 6
    /// 寄出去多久没回就再寄（大管家不在：信在信箱里等；回不来的才再寄）
    public static let resendAfter: TimeInterval = 20 * 60

    /// 该不该现在寄（queued，或者寄出去太久没回）
    public func due(now: Date) -> Bool {
        if phase == "queued" { return true }
        if phase == "sent", let at = sentAt, now.timeIntervalSince(at) >= ShutongNoteState.resendAfter, tries < ShutongNoteState.maxTries { return true }
        return false
    }
}
