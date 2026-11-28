import Foundation

// 听力（0.3.0）：一篇稿子 + 一段录音 + 每句从第几秒开始。反复听整篇、单句循环、上一句下一句都靠这张表。
// 录音从哪来：大管家配好音送来（_大管家/送来/），或者手机自己念（「念出来」）。

/// 一句：从录音第几秒开始，这句的字
public struct ListenMark: Codable, Equatable, Sendable {
    public var t: Double
    public var s: String
    public init(t: Double, s: String) { self.t = t; self.s = s }
}

public enum Listen {
    /// 稿子切成句：去掉 Markdown 记号，按 . ! ? 。！？ 和换行切（后面得是空白或结尾，1.5、U.S. 这类不切）
    public static func sentences(_ markdown: String) -> [String] {
        var out: [String] = []
        for span in lineSpans(markdown) {
            guard let p = Markdown5.plain(span.text)?.trimmed, !p.isEmpty else { continue }
            if case .image = Markdown5.parseLine(span.text, at: 0).block { continue }
            out += split(p)
        }
        return out
    }

    static let abbreviations: Set<String> = ["mr", "mrs", "ms", "dr", "st", "jr", "sr", "vs", "etc", "e.g", "i.e", "u.s", "u.k", "u.n", "no", "inc", "co", "jan", "feb", "mar", "apr", "jun", "jul", "aug", "sep", "sept", "oct", "nov", "dec"]

    static func split(_ line: String) -> [String] {
        let chars = Array(line)
        var out: [String] = []
        var cur = ""
        var i = 0
        while i < chars.count {
            let c = chars[i]
            cur.append(c)
            var end = false
            if "。！？".contains(c) {
                end = true
            } else if ".!?".contains(c) {
                let nextIsSpace = i + 1 >= chars.count || chars[i + 1].isWhitespace
                // 收尾的引号、括号跟着这句
                var j = i + 1
                while j < chars.count, "\"'”’)）".contains(chars[j]) { cur.append(chars[j]); j += 1 }
                let afterQuote = j >= chars.count || chars[j].isWhitespace
                if (nextIsSpace || j > i + 1) && afterQuote {
                    if c == "." {
                        let word = cur.dropLast(j - i).split(whereSeparator: { $0.isWhitespace }).last.map { String($0).lowercased() } ?? ""
                        let bare = word.trimmingCharacters(in: CharacterSet(charactersIn: "\"'“‘("))
                        end = !abbreviations.contains(bare) && !(bare.count == 1 && bare.first!.isLetter)
                    } else {
                        end = true
                    }
                }
                i = j - 1
            }
            if end {
                let s = cur.trimmingCharacters(in: .whitespaces)
                if !s.isEmpty { out.append(s) }
                cur = ""
            }
            i += 1
        }
        let rest = cur.trimmingCharacters(in: .whitespaces)
        if !rest.isEmpty { out.append(rest) }
        return out
    }

    /// 第几秒在第几句（落在第一句之前算第一句）
    public static func index(at time: Double, in marks: [ListenMark]) -> Int? {
        guard !marks.isEmpty else { return nil }
        var lo = 0
        for (i, m) in marks.enumerated() where m.t <= time + 0.001 { lo = i }
        return lo
    }

    /// 第 i 句的起止秒
    public static func span(_ i: Int, in marks: [ListenMark], duration: Double) -> (start: Double, end: Double) {
        guard marks.indices.contains(i) else { return (0, duration) }
        let start = marks[i].t
        let end = i + 1 < marks.count ? marks[i + 1].t : duration
        return (start, max(start, end))
    }

    /// 笔记里存的：录音路径 → 每句的表（JSON）
    public static func encode(_ m: [String: [ListenMark]]) -> String {
        guard !m.isEmpty, let d = try? JSONEncoder.sorted.encode(m) else { return "" }
        return String(data: d, encoding: .utf8) ?? ""
    }

    public static func decode(_ s: String) -> [String: [ListenMark]] {
        guard let d = s.data(using: .utf8), !s.isEmpty else { return [:] }
        return (try? JSONDecoder().decode([String: [ListenMark]].self, from: d)) ?? [:]
    }

    /// 每句表跟着录音存一份「<录音>.marks.json」，镜像、导入时一起走
    public static func sidecar(for audio: String) -> String { audio + ".marks.json" }

    /// 手机自己念的：附件/<短id>-念-1.m4a；大管家送来的：附件/<短id>-听-1.<mp3|m4a|wav>
    public static func speakName(note: UUID) -> String { "\(MirrorFormat.shortID(note))-念-1.m4a" }
    public static func deliveryName(note: UUID, ext: String) -> String { "\(MirrorFormat.shortID(note))-听-1.\(ext)" }

    /// 听力用的录音（念的、送来的），不是随手录的那种
    public static func isListenAudio(_ path: String) -> Bool {
        let name = (path as NSString).lastPathComponent
        return name.contains("-念-") || name.contains("-听-")
    }

    /// 导入时按名字找回这条笔记的录音：听力的在前，随手录的在后
    public static func importPaths(note: UUID, exists: (String) -> Bool) -> [String] {
        let short = MirrorFormat.shortID(note)
        let listen = ["\(short)-念-1.m4a", "\(short)-听-1.mp3", "\(short)-听-1.m4a", "\(short)-听-1.wav"]
            .map { "\(MirrorFolder.attachName)/\($0)" }.filter(exists)
        return listen + VoiceText.paths(note: note, exists: exists)
    }
}

extension JSONEncoder {
    static var sorted: JSONEncoder {
        let e = JSONEncoder()
        e.outputFormatting = [.sortedKeys]
        return e
    }
}

// ================================================================ 大管家送来的（接口 v1 第「送来」节）
/// _大管家/送来/<id>.json：大管家配好音的听力稿，手机拿到就变成一条笔记
public struct ButlerDelivery: Codable, Equatable, Sendable {
    public var v: Int
    public var id: String
    public var kind: String
    public var title: String?
    /// 补译的信（231）不带 text：当空字符串
    @DefaultEmpty public var text: String
    /// 相对镜像根，比如「附件/<id>.mp3」
    public var audio: String?
    public var marks: [ListenMark]?
    /// 放进哪个文件夹（没有就建），默认「英语」
    public var folder: String?
    public var at: String?
    /// 给手机上已有的哪条笔记配的音（回「配音」请求时带上；没有就是新的一条）
    public var note: String?
    /// 回的是哪个请求
    public var request: String?
    /// kind=secret（128 特勤局机密文件）：text 是那串一次性的东西，hint 是一句说明；手机弹一张卡，不存、不镜像
    public var hint: String?
    /// kind=tell（158 大管家找 Song）：急的（Telegram 也发了）
    public var urgent: Bool?
    /// kind=todo / todo-done（162 项目待办）：待办 id（orders 分支 项目待办/<id>.md 的 <id>）；信的 id 每封都不一样
    public var todo: String?
    /// kind=board（234 看板，见 Board234.swift）：看板的固定 id（比如 game-log）
    public var board: String?
    /// kind=guide（197 遥控带路，见 Guide197.swift）：带路的号、ask / done / stuck、哪台哪块屏、圈、要不要双击、信里带的截图
    public var guide: String?
    public var status: String?
    public var host: String?
    public var screen: Int?
    public var x: Double?
    public var y: Double?
    public var r: Double?
    public var double: Bool?
    public var image: String?
    /// kind=confirm（203 要他点头，见 Confirm203.swift）：卡的号、哪张单、要做的那件事、几点过期（status、host 同上）；
    /// bark = 大管家同时发了 Bark（手机不用自己再弹通知）
    public var confirm: String?
    public var order: String?
    public var detail: String?
    public var expires: String?
    public var bark: Bool?
    /// kind=listen（225）：谁配的、几星（v3.21 / v3.22，见 Voice225.swift），大管家译好的意思（v3.23）
    public var voice: ListenVoice?
    public var trans: ListenTrans?
    /// kind=bot（252，v3.28，见 Bots252.swift）：定时活寄进机器人窗的一句：哪个机器人、这句的号、图（信里的路径）、
    /// 能不能 👍👎、哪一趟、趟里第几句、是不是最后一句
    public var bot: String?
    public var msg: String?
    public var images: [String]?
    public var react: Bool?
    public var run: String?
    public var seq: Int?
    public var last: Bool?
    /// 258（v3.29）：这一句对着灵感库里哪一条（有它的点 👎 = 不留）
    public var item: String?
    public init(v: Int = Butler.version, id: String, kind: String = "listen", title: String? = nil, text: String,
                audio: String?, marks: [ListenMark]?, folder: String? = nil, at: String? = nil, note: String? = nil, request: String? = nil,
                voice: ListenVoice? = nil, trans: ListenTrans? = nil) {
        self.v = v; self.id = id; self.kind = kind; self.title = title; self.text = text
        self.audio = audio; self.marks = marks; self.folder = folder; self.at = at; self.note = note; self.request = request
        self.voice = voice; self.trans = trans
    }

    /// 补译的信（v3.23）：指名一条手机上已有的稿，只带 trans，没有录音、没有字
    public var isTransLetter: Bool {
        (kind.isEmpty || kind == "listen") && note != nil && audio == nil && !(trans?.isEmpty ?? true) && text.isEmpty
    }
}

extension Butler {
    public static let deliveredName = "送来"
}

extension ButlerChannel {
    public var delivered: URL { dir.appendingPathComponent(Butler.deliveredName, isDirectory: true) }

    /// 送来/ 里能读的（.part 不算；iCloud 占位的先叫它下载，这回没下完就下回再拿）
    public func deliveries() -> [(url: URL, item: ButlerDelivery)] {
        let list = (try? fs.list(delivered)) ?? []
        var out: [(URL, ButlerDelivery)] = []
        for u in list {
            let name = iCloudPlaceholderRealName(u.lastPathComponent) ?? u.lastPathComponent
            guard name.hasSuffix(".json") else { continue }
            let url = delivered.appendingPathComponent(name)
            guard fs.ensureDownloaded(url), let data = try? fs.read(url),
                  let item = try? JSONDecoder().decode(ButlerDelivery.self, from: data) else { continue }
            out.append((url, item))
        }
        return out.sorted { ($0.1.at ?? "") < ($1.1.at ?? "") }
    }

    /// 送来的录音（相对镜像根）：下载好了就给数据
    public func deliveryAudio(_ rel: String) -> Data? {
        let url = root.appendingPathComponent(rel)
        guard fs.ensureDownloaded(url) else { return nil }
        return try? fs.read(url)
    }

    public func removeDelivery(_ url: URL) { try? fs.remove(url) }
}
