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
    /// 听力录音的每句表（录音路径 → 每句从第几秒开始），JSON
    var marks: String = ""
    /// 在不在听力播放列表里（Song 11-21：「我选择的才会进去」）
    var inListen: Bool = false
    /// 交给大管家配音、还没回来的：「请求 id|交出去的时间」
    var dub: String = ""
    /// 跟大管家打交道的状态（JSON）
    var butler: String = ""
    /// 左滑删了、还能撤销的
    var trashed: Bool = false
    /// 扔进废纸篓的时间（111）：留 3 天，到点真删。老数据没有，开 app 时补成现在
    var trashedAt: Date?
    /// 电脑确认收到的那版 modifiedAt（111）：跟 modifiedAt 不一样就该再寄给电脑
    var deskAt: Date?
    /// 听力第一次完整放完一遍的时间（112）：听完满 7 天自己进废纸篓。只记第一次
    var heardAt: Date?
    /// 文章便签（kind == "article"，114）跟大管家打交道的状态（JSON）：扒正文、简写
    var article: String = ""
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

    var markTable: [String: [ListenMark]] {
        get { Listen.decode(marks) }
        set { marks = Listen.encode(newValue) }
    }

    var articleState: ArticleState {
        get { ArticleState.decode(article) }
        set { article = newValue.encoded() }
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

    /// 听力用的录音（念的、大管家配的）
    var listenPath: String? { audioPaths.first(where: { Listen.isListenAudio($0) }) }

    var dubSentAt: Date? {
        let p = dub.split(separator: "|", maxSplits: 1)
        return p.count == 2 ? ISOTime.date(String(p[1])) : nil
    }

    /// 在等的配音请求 id
    var dubRequest: String? {
        let id = dub.split(separator: "|", maxSplits: 1).first.map(String.init) ?? ""
        return id.isEmpty ? nil : id
    }
}

@Model
final class Folder {
    var id: UUID = UUID()
    var name: String = ""
    var createdAt: Date = Date()
    var order: Int = 0
    /// 抄一份到电脑（111）：夹子里的便签改完就寄给大管家，电脑落成 md
    var toDesk: Bool = false
    @Relationship(deleteRule: .nullify, inverse: \Note.folder)
    var notes: [Note]? = []

    init(name: String, order: Int) {
        self.name = name
        self.order = order
        self.toDesk = KeepPlan.isDeskFolderName(name)
    }
}

extension Folder {
    /// 只装听力的文件夹（112）：里面有便签、而且每一条都是听力。便签这边的文件夹面板、「挪到」菜单都不列它
    var isListenOnly: Bool {
        ListenRule.isListenOnlyFolder(kinds: (notes ?? []).filter { !$0.trashed }.map(\.kind))
    }
}
