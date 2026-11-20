import Foundation

// 所有内容进来走同一条路：键盘、相机，以后麦克风（v2）→ 排版 → 存。加语音只是多一个入口。

public enum IntakeKind: String, Codable, Sendable, CaseIterable {
    case text, photo, voice

    public var butlerKind: ButlerKind {
        switch self { case .text: return .text; case .photo: return .photo; case .voice: return .voice }
    }
}

/// 一份进来的东西：已经是 Markdown 草稿了（相机认完字、语音转完字，或者键盘直接打）
public struct Intake: Sendable {
    public var kind: IntakeKind
    public var markdown: String
    /// 拿不准的位置（UTF-16，相对 markdown）
    public var unsure: [NSRange]
    /// 原件：照片（JPEG）。语音 v2 时放录音
    public var originals: [Data]
    public init(kind: IntakeKind, markdown: String, unsure: [NSRange] = [], originals: [Data] = []) {
        self.kind = kind; self.markdown = markdown; self.unsure = unsure; self.originals = originals
    }

    public init(draft: OCRDraft, originals: [Data]) {
        self.init(kind: .photo, markdown: draft.markdown, unsure: draft.unsure, originals: originals)
    }
}

public enum IntakeFormatter {
    /// 排版：去行尾空白、连着三个以上空行并成一个、头尾空行去掉。拿不准的位置跟着平移
    public static func tidy(_ intake: Intake) -> Intake {
        var lines = lineSpans(intake.markdown)
        // 记下每行新旧起点
        var out = ""
        var map: [(old: NSRange, newStart: Int)] = []
        var blankRun = 0
        while let f = lines.first, f.text.trimmed.isEmpty { lines.removeFirst() }
        while let l = lines.last, l.text.trimmed.isEmpty { lines.removeLast() }
        for l in lines {
            var t = l.text
            while let c = t.last, c == " " || c == "\t" { t.removeLast() }
            if t.trimmed.isEmpty { blankRun += 1; if blankRun > 1 { continue } } else { blankRun = 0 }
            if !out.isEmpty { out += "\n" }
            map.append((NSRange(location: l.range.location, length: t.u16), out.u16))
            out += t
        }
        var unsure: [NSRange] = []
        for r in intake.unsure {
            guard let m = map.first(where: { r.location >= $0.old.location && r.location < $0.old.end }) else { continue }
            let len = min(r.length, m.old.end - r.location)
            if len > 0 { unsure.append(NSRange(location: m.newStart + (r.location - m.old.location), length: len)) }
        }
        var x = intake
        x.markdown = out
        x.unsure = unsure
        return x
    }
}

/// 拿不准的位置存进数据库用：「位置,长度;位置,长度」
public enum RangeCodec {
    public static func encode(_ rs: [NSRange]) -> String { rs.map { "\($0.location),\($0.length)" }.joined(separator: ";") }
    public static func decode(_ s: String) -> [NSRange] {
        s.split(separator: ";").compactMap { p in
            let a = p.split(separator: ",")
            guard a.count == 2, let l = Int(a[0]), let n = Int(a[1]), n > 0 else { return nil }
            return NSRange(location: l, length: n)
        }
    }
}
