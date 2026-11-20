import Foundation
import SwiftData
import YiyeKit

// 从第一天就按 CloudKit 的规矩写：字段都给默认值或可选，不用 unique，关系可选。以后开 iCloud 同步不用改表。
// 图片存文件（附件/），不进数据库。

@Model
final class Note {
    var id: UUID = UUID()
    /// 正文：Markdown（五招 + 图片行）
    var markdown: String = ""
    var createdAt: Date = Date()
    var modifiedAt: Date = Date()
    var pinned: Bool = false
    /// 纸色：white / yellow / green / blue / pink
    var paper: String = "white"
    /// 怎么进来的：text / photo / voice
    var kind: String = "text"
    /// 拿不准的字（标黄）：「位置,长度;…」，相对 markdown
    var unsure: String = ""
    /// 原图（附件/…-原图-1.jpg），一行一个
    var originals: String = ""
    /// 录音（附件/…-语音-1.m4a），一行一个。不进正文，写字页最上面一条播放条
    var audios: String = ""
    /// 跟大管家打交道的状态（JSON）
    var butler: String = ""
    /// 左滑删了、还能撤销的
    var trashed: Bool = false
    var folder: Folder?

    init() {}

    var title: String { Markdown5.title(markdown) }
    var summary: String { Markdown5.summary(markdown) }

    var originalPaths: [String] {
        get { originals.split(separator: "\n").map(String.init).filter { !$0.isEmpty } }
        set { originals = newValue.joined(separator: "\n") }
    }

    var audioPaths: [String] {
        get { audios.split(separator: "\n").map(String.init).filter { !$0.isEmpty } }
        set { audios = newValue.joined(separator: "\n") }
    }

    var butlerState: ButlerNoteState {
        get { ButlerNoteState.decode(butler) }
        set { butler = newValue.encoded() }
    }

    var unsureRanges: [NSRange] {
        get { RangeCodec.decode(unsure) }
        set { unsure = RangeCodec.encode(newValue) }
    }

    var tint: PaperTint { PaperTint(rawValue: paper) ?? .white }
}

@Model
final class Folder {
    var id: UUID = UUID()
    var name: String = ""
    var createdAt: Date = Date()
    var order: Int = 0
    @Relationship(deleteRule: .nullify, inverse: \Note.folder)
    var notes: [Note]? = []

    init(name: String, order: Int) {
        self.name = name
        self.order = order
    }
}
