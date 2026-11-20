import Foundation

// 镜像文件夹：每存一次往 <根>/笔记/ 写一个「标题-短id.md」，开头一段 front matter；图片进 附件/；删掉的挪进 废纸篓/。
// 根默认是「iCloud 云盘/一叶笺」，大管家那头（掌机上的 iCloud for Windows）看到的是同一个文件夹。

public struct MirrorMeta: Equatable, Sendable {
    public var id: UUID
    public var created: Date
    public var modified: Date
    public var folder: String
    public var pinned: Bool
    public var color: String
    public var kind: String
    public init(id: UUID, created: Date, modified: Date, folder: String = "", pinned: Bool = false, color: String = "white", kind: String = "text") {
        self.id = id; self.created = created; self.modified = modified; self.folder = folder; self.pinned = pinned; self.color = color; self.kind = kind
    }
}

public enum MirrorFormat {
    public static func shortID(_ id: UUID) -> String { String(id.uuidString.prefix(8)) }

    /// 标题能进文件名的样子：去掉 / \ : * ? " < > | 和控制字符，空白并成一个，最多 40 个字
    public static func sanitize(_ title: String) -> String {
        let bad = Set("/\\:*?\"<>|")
        var s = ""
        var lastSpace = false
        for ch in title {
            if bad.contains(ch) || ch.unicodeScalars.contains(where: { $0.value < 0x20 || $0.value == 0x7F }) { continue }
            if ch.isWhitespace { if !lastSpace && !s.isEmpty { s.append(" ") }; lastSpace = true; continue }
            lastSpace = false
            s.append(ch)
        }
        s = s.trimmed
        while s.hasPrefix(".") { s.removeFirst() }
        if s.count > 40 { s = String(s.prefix(40)).trimmed }
        return s
    }

    public static func fileName(title: String, id: UUID) -> String {
        let t = sanitize(title)
        return t.isEmpty ? "\(shortID(id)).md" : "\(t)-\(shortID(id)).md"
    }

    static func quote(_ s: String) -> String {
        "\"" + s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"").replacingOccurrences(of: "\n", with: " ") + "\""
    }

    static func unquote(_ s: String) -> String {
        let t = s.trimmed
        guard t.count >= 2, t.hasPrefix("\""), t.hasSuffix("\"") else { return t }
        var out = ""
        var esc = false
        for ch in t.dropFirst().dropLast() {
            if esc { out.append(ch); esc = false; continue }
            if ch == "\\" { esc = true; continue }
            out.append(ch)
        }
        return out
    }

    public static func render(_ m: MirrorMeta, body: String) -> String {
        var s = "---\n"
        s += "id: \(m.id.uuidString)\n"
        s += "created: \(ISOTime.string(m.created))\n"
        s += "modified: \(ISOTime.string(m.modified))\n"
        s += "folder: \(quote(m.folder))\n"
        s += "pinned: \(m.pinned ? "true" : "false")\n"
        s += "color: \(m.color)\n"
        s += "kind: \(m.kind)\n"
        s += "---\n\n"
        s += body
        if !body.hasSuffix("\n") { s += "\n" }
        return s
    }

    /// 读回来：有 front matter 就拆开；没有（别处写进来的 .md）meta 为 nil，整个当正文
    public static func parse(_ text: String) -> (meta: MirrorMeta?, body: String) {
        let t = text.replacingOccurrences(of: "\r\n", with: "\n")
        guard t.hasPrefix("---\n") else { return (nil, t) }
        let rest = t.dropFirst(4)
        guard let end = rest.range(of: "\n---\n") ?? (rest.hasSuffix("\n---") ? rest.range(of: "\n---", options: .backwards) : nil) else { return (nil, t) }
        let head = rest[rest.startIndex..<end.lowerBound]
        var body = String(rest[end.upperBound...])
        if body.hasPrefix("\n") { body.removeFirst() }
        if body.hasSuffix("\n") { body.removeLast() }
        var kv: [String: String] = [:]
        for line in head.split(separator: "\n") {
            guard let c = line.firstIndex(of: ":") else { continue }
            let k = line[line.startIndex..<c].trimmingCharacters(in: .whitespaces)
            let v = line[line.index(after: c)...].trimmingCharacters(in: .whitespaces)
            kv[k] = v
        }
        guard let idS = kv["id"], let id = UUID(uuidString: idS.trimmed) else { return (nil, body) }
        let created = kv["created"].flatMap { ISOTime.date($0) } ?? Date()
        let modified = kv["modified"].flatMap { ISOTime.date($0) } ?? created
        let meta = MirrorMeta(id: id, created: created, modified: modified,
                              folder: unquote(kv["folder"] ?? ""),
                              pinned: (kv["pinned"] ?? "false").lowercased() == "true",
                              color: kv["color"].map(unquote) ?? "white",
                              kind: kv["kind"].map(unquote) ?? "text")
        return (meta, body)
    }
}

public struct MirrorImport: Equatable, Sendable {
    public var meta: MirrorMeta
    public var body: String
    public var fileName: String
    /// 文件里本来没有 front matter（别处写的），id 是这次新给的
    public var adopted: Bool
}

public final class MirrorFolder {
    public static let notesName = "笔记", attachName = "附件", trashName = "废纸篓"
    public let root: URL
    public let fs: FileAccess

    public init(root: URL, fs: FileAccess) { self.root = root; self.fs = fs }

    public var notesDir: URL { root.appendingPathComponent(MirrorFolder.notesName, isDirectory: true) }
    public var attachDir: URL { root.appendingPathComponent(MirrorFolder.attachName, isDirectory: true) }
    public var trashDir: URL { root.appendingPathComponent(MirrorFolder.trashName, isDirectory: true) }

    public func prepare() throws {
        for d in [notesDir, attachDir, trashDir] { try fs.makeDir(d) }
    }

    /// 某条笔记在某个目录里的文件（标题改过就可能有旧名字的）
    public func files(for id: UUID, in dir: URL) -> [URL] {
        let short = MirrorFormat.shortID(id)
        let list = (try? fs.list(dir)) ?? []
        return list.filter { u in
            let name = iCloudPlaceholderRealName(u.lastPathComponent) ?? u.lastPathComponent
            return name == "\(short).md" || name.hasSuffix("-\(short).md")
        }
    }

    /// 存一条：写新文件名，标题改了就把旧名字的删掉（等于改名）
    @discardableResult
    public func save(_ meta: MirrorMeta, body: String) throws -> URL {
        try fs.makeDir(notesDir)
        let name = MirrorFormat.fileName(title: Markdown5.title(body), id: meta.id)
        let url = notesDir.appendingPathComponent(name)
        try fs.write(Data(MirrorFormat.render(meta, body: body).utf8), to: url)
        for old in files(for: meta.id, in: notesDir) where old.lastPathComponent != name {
            try? fs.remove(old)
        }
        return url
    }

    /// 删一条：挪进废纸篓（同名的加个编号）
    public func trash(_ id: UUID) throws {
        try fs.makeDir(trashDir)
        for f in files(for: id, in: notesDir) {
            var dest = trashDir.appendingPathComponent(f.lastPathComponent)
            var n = 2
            while fs.exists(dest) {
                let base = f.deletingPathExtension().lastPathComponent
                dest = trashDir.appendingPathComponent("\(base) (\(n)).md")
                n += 1
            }
            try fs.move(f, to: dest)
        }
    }

    /// 撤销删除：从废纸篓挪回来（最近那份）
    public func restore(_ id: UUID) throws {
        guard let f = files(for: id, in: trashDir).sorted(by: { (fs.modified($0) ?? .distantPast) > (fs.modified($1) ?? .distantPast) }).first else { return }
        var name = f.lastPathComponent
        if let r = name.range(of: " \\([0-9]+\\)\\.md$", options: .regularExpression) { name.replaceSubrange(r, with: ".md") }
        try fs.move(f, to: notesDir.appendingPathComponent(name))
    }

    public func url(_ relative: String) -> URL { root.appendingPathComponent(relative) }

    /// 附件：relative 形如「附件/xxx.jpg」
    public func writeAttachment(_ data: Data, relative: String) throws {
        try fs.write(data, to: url(relative))
    }

    public func hasAttachment(_ relative: String) -> Bool { fs.exists(url(relative)) }

    /// 从文件夹导入：把 笔记/ 下的 .md 全读出来。iCloud 占位的先叫它下载；还没下好的记在 pending 里
    public func importAll() -> (notes: [MirrorImport], pending: [String]) {
        var out: [MirrorImport] = []
        var pending: [String] = []
        let list = (try? fs.list(notesDir)) ?? []
        for u in list {
            var url = u
            if let real = iCloudPlaceholderRealName(u.lastPathComponent) {
                url = u.deletingLastPathComponent().appendingPathComponent(real)
                if !fs.ensureDownloaded(url) { pending.append(real); continue }
            }
            guard url.pathExtension.lowercased() == "md" else { continue }
            if !fs.ensureDownloaded(url) { pending.append(url.lastPathComponent); continue }
            guard let data = try? fs.read(url), let text = String(data: data, encoding: .utf8) else { continue }
            let parsed = MirrorFormat.parse(text)
            if let m = parsed.meta {
                out.append(MirrorImport(meta: m, body: parsed.body, fileName: url.lastPathComponent, adopted: false))
            } else {
                let d = fs.modified(url) ?? Date()
                out.append(MirrorImport(meta: MirrorMeta(id: UUID(), created: d, modified: d), body: parsed.body, fileName: url.lastPathComponent, adopted: true))
            }
        }
        return (out, pending)
    }
}
