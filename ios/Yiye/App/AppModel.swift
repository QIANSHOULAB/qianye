import SwiftUI
import SwiftData
import UIKit
import YiyeKit
import YiyeOCR
import PhotosUI

enum Route: Hashable {
    case editor(UUID)
    case settings
}

/// 录一段往哪放：新的一条，或者接在某条的光标处
enum VoiceTarget: Identifiable, Equatable {
    case new
    case into(UUID, Int)
    var id: String {
        switch self { case .new: return "new"; case .into(let n, let at): return "\(n)-\(at)" }
    }
}

/// 打开听力播放列表：从哪篇开始、要不要直接把原文翻出来
struct ListenOpen: Identifiable, Equatable {
    var id = UUID()
    var startNote: UUID?
    var showText = false
}

struct Toast: Identifiable {
    let id = UUID()
    var text: String
    var actionTitle: String? = nil
    var action: (() -> Void)? = nil
}

/// 整个 app 的状态：数据库、设置、语言、镜像、大管家、往哪走
@MainActor @Observable
final class AppModel {
    static let shared = AppModel()

    let demo: DemoConfig?
    let container: ModelContainer
    let settings: Settings
    let lang: Lang
    let attachments: AttachmentStore
    let mirror: MirrorService
    let butler: ButlerService
    /// 陪玩模式（100）
    let companion: Companion

    var path: [Route] = []
    var toast: Toast?
    /// 正在干一件超过一秒的活（认字）：显示一句在干啥
    var busy: String?
    /// 第一次打开问一次镜像文件夹
    var showMirrorPrompt = false
    /// 刚建的空笔记（离开时还是空的就删掉）
    var freshNoteID: UUID?
    /// 正在录一段（侧键、列表、写字页都从这儿开）
    var voiceTarget: VoiceTarget?
    /// 听力播放列表开着
    var listening: ListenOpen?

    @ObservationIgnored private var toastTask: Task<Void, Never>?
    @ObservationIgnored private var didStart = false

    var context: ModelContext { container.mainContext }

    init() {
        let demo = DemoConfig.fromLaunch()
        self.demo = demo
        let schema = Schema([Note.self, Folder.self])
        let config = ModelConfiguration(schema: schema, isStoredInMemoryOnly: demo != nil, cloudKitDatabase: .none)
        container = (try? ModelContainer(for: schema, configurations: [config]))
            ?? (try! ModelContainer(for: schema, configurations: [ModelConfiguration(schema: schema, isStoredInMemoryOnly: true, cloudKitDatabase: .none)]))
        settings = Settings(persist: demo == nil)
        lang = Lang(forced: demo?.lang)
        attachments = AttachmentStore(demo: demo != nil)
        mirror = MirrorService(demo: demo != nil)
        butler = ButlerService()
        companion = Companion()
    }

    func started() {
        guard !didStart else { return }
        didStart = true
        butler.app = self
        companion.app = self
        if let demo {
            Demo.seed(self, demo)
        } else {
            CameraCanary.checkOnLaunch(settings)
            mirror.restore()
            showMirrorPrompt = !settings.mirrorAsked && !mirror.isOn
            purgeTrashed()
            backfillListen()
        }
        butler.start()
        if demo == nil { companion.setUp() }
    }

    func scenePhase(_ p: ScenePhase) {
        switch p {
        case .active:
            butler.start()
        case .background:
            if !companion.holdsButler { butler.stop() }     // 陪玩在听：信箱不断（后台音频让 app 一直醒着）
            try? context.save()
        default: break
        }
    }

    var t: Lang { lang }

    // ---------------------------------------------------------------- 提示条
    func show(_ text: String, action: String? = nil, seconds: Double = 4, _ run: (() -> Void)? = nil) {
        toast = Toast(text: text, actionTitle: action, action: run)
        toastTask?.cancel()
        toastTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            if !Task.isCancelled { withAnimation(.easeOut(duration: 0.24)) { self?.toast = nil } }
        }
    }

    // ---------------------------------------------------------------- 笔记
    func note(_ id: UUID) -> Note? {
        let d = FetchDescriptor<Note>(predicate: #Predicate<Note> { $0.id == id })
        return try? context.fetch(d).first
    }

    func allNotes() -> [Note] {
        (try? context.fetch(FetchDescriptor<Note>())) ?? []
    }

    func folder(_ id: UUID?) -> Folder? {
        guard let id else { return nil }
        let d = FetchDescriptor<Folder>(predicate: #Predicate<Folder> { $0.id == id })
        return try? context.fetch(d).first
    }

    /// 新建一条空笔记并打开
    func newNote() {
        let n = Note()
        n.folder = folder(UUID(uuidString: settings.folderID))
        context.insert(n)
        try? context.save()
        freshNoteID = n.id
        path.append(.editor(n.id))
    }

    /// 所有内容进来走同一条路：键盘、相机，以后麦克风 → 排版 → 存 → （拍照的）交给大管家
    @discardableResult
    func intake(_ input: Intake, into existing: Note? = nil, at location: Int? = nil, open: Bool = true, audio: [URL] = []) -> Note {
        let x = IntakeFormatter.tidy(input)
        let n: Note
        if let existing {
            n = existing
            var md = n.markdown
            var unsure = RangeCodec.decode(n.unsure)
            let at = min(max(0, location ?? md.u16), md.u16)
            var insert = x.markdown
            var shift = 0
            if at > 0, !md.sub16(NSRange(location: at - 1, length: 1)).hasSuffix("\n") { insert = "\n" + insert; shift = 1 }
            if at < md.u16, !md.sub16(NSRange(location: at, length: 1)).hasPrefix("\n") { insert += "\n" }
            md = md.replacing16(NSRange(location: at, length: 0), with: insert)
            unsure = unsure.map { $0.location >= at ? $0.shifted(insert.u16) : $0 } + x.unsure.map { $0.shifted(at + shift) }
            n.markdown = md
            n.unsure = RangeCodec.encode(unsure)
            if x.kind == .photo || (x.kind == .voice && n.kind == IntakeKind.text.rawValue) { n.kind = x.kind.rawValue }
        } else {
            n = Note()
            n.kind = x.kind.rawValue
            n.markdown = x.markdown
            n.unsure = RangeCodec.encode(x.unsure)
            n.folder = folder(UUID(uuidString: settings.folderID))
            context.insert(n)
        }
        // 原件存成附件（不进正文），「看原图」能看
        var originals = n.originalPaths
        for data in x.originals {
            let name = "\(MirrorFormat.shortID(n.id))-原图-\(originals.count + 1).jpg"
            if let rel = try? attachments.save(data, name: name) { originals.append(rel) }
        }
        n.originalPaths = originals
        // 录音也存成附件，写字页最上面放
        var audios = n.audioPaths
        for file in audio {
            if let rel = try? attachments.move(file, name: VoiceText.fileName(note: n.id, index: audios.count + 1)) { audios.append(rel) }
        }
        n.audioPaths = audios
        n.modifiedAt = Date()
        try? context.save()
        mirror.saveSoon(n, attachments: attachments)
        if (x.kind == .photo || x.kind == .voice) && settings.butlerAutoPhoto && !n.markdown.trimmed.isEmpty {
            butler.submit(n)
        }
        if open && existing == nil { path.append(.editor(n.id)) }
        return n
    }

    /// 笔记改了：存库、镜像（攒一秒再写）
    func changed(_ n: Note) {
        n.modifiedAt = Date()
        try? context.save()
        mirror.saveSoon(n, attachments: attachments)
    }

    /// 左滑删除：先藏起来，给「撤销」；过一会儿真删
    func delete(_ n: Note) {
        n.trashed = true
        try? context.save()
        mirror.trash(n.id)
        let id = n.id
        let title = n.title.isEmpty ? t.t("note.untitled") : n.title
        show(t.f("toast.deleted", title), action: t.t("toast.undo"), seconds: 5) { [weak self] in
            guard let self, let n = self.note(id) else { return }
            n.trashed = false
            try? self.context.save()
            self.mirror.restoreFromTrash(id)
            self.toast = nil
        }
    }

    /// 上次藏起来没撤销的，启动时真删
    func purgeTrashed() {
        for n in allNotes() where n.trashed { context.delete(n) }
        try? context.save()
    }

    /// 离开写字页：空的就不留
    func leave(_ n: Note) {
        if n.markdown.trimmed.isEmpty && n.originalPaths.isEmpty && n.audioPaths.isEmpty {
            context.delete(n)
            try? context.save()
            if mirror.isOn { mirror.trash(n.id) }
        } else {
            mirror.saveNow(n, attachments: attachments)
        }
        if freshNoteID == n.id { freshNoteID = nil }
    }

    // ---------------------------------------------------------------- 录一段
    /// 开录（侧键、列表的话筒、写字页的话筒）。已经在录就不动
    func startVoice(_ target: VoiceTarget = .new) {
        if voiceTarget == nil { voiceTarget = target }
    }

    /// 录完：录音进附件，字进正文（新的一条，或者接在原来那条的光标处），自动交大管家
    func addVoice(file: URL, text: String, target: VoiceTarget) {
        let md = VoiceText.markdown(from: text)
        let input = Intake(kind: .voice, markdown: md)
        switch target {
        case .new:
            intake(input, audio: [file])
        case .into(let id, let at):
            if let n = note(id) {
                intake(input, into: n, at: at, audio: [file])
                NotificationCenter.default.post(name: .yiyeNoteReplaced, object: id)
            }
            else { intake(input, audio: [file]) }
        }
        if md.isEmpty { show(t.t("voice.noText")) }
    }

    // ---------------------------------------------------------------- 听力
    /// 播放列表里的：放进了听力的笔记，新的在前（还没录音的也列出来，显示在等配音）
    func listenNotes() -> [Note] {
        allNotes().filter { !$0.trashed && $0.inListen }.sorted { $0.createdAt > $1.createdAt }
    }

    /// 能放的那些
    func listenTracks() -> [Track] { listenNotes().compactMap { track($0) } }

    /// 一条笔记的听力录音（没有就 nil）
    func track(_ n: Note) -> Track? {
        guard let path = n.listenPath else { return nil }
        return Track(note: n.id, path: path, title: n.title.isEmpty ? t.t("note.untitled") : n.title, marks: n.markTable[path] ?? [])
    }

    /// 放进听力 / 从听力拿掉。放进去时还没录音：大管家在线就交它配音，不在线手机先念
    func toggleListen(_ n: Note) {
        if n.inListen {
            n.inListen = false
            changed(n)
            show(t.t("listen.removed"))
            return
        }
        n.inListen = true
        changed(n)
        if n.listenPath == nil && n.dub.isEmpty {
            if butler.presence.isHere { dub(n) } else { speak(n); show(t.t("listen.addedPhone"), seconds: 6) }
        } else {
            show(t.t("listen.added"))
        }
    }

    /// 交大管家配音（ElevenLabs）：好了从「送来」回到这条，换掉手机念的。
    /// 又交一次：旧的请求大管家还没拿走就撤回，不配两遍
    func dub(_ n: Note) {
        guard !n.markdown.trimmed.isEmpty else { show(t.t("listen.dubEmpty")); return }
        let old = n.dubRequest
        guard let rid = butler.requestDub(n, replacing: old) else { return }
        n.dub = "\(rid)|\(ISOTime.string(Date()))"
        changed(n)
        show(butler.presence.isHere ? t.t("listen.dubSent") : t.t("listen.dubQueued"), seconds: 6)
    }

    /// 大管家说没配成：清掉「在等」，说一声
    func dubFailed(_ n: Note, error: String?) {
        n.dub = ""
        changed(n)
        let why = (error ?? "").trimmed
        show(why.isEmpty ? t.t("listen.dubFailed") : t.f("listen.dubFailedWhy", String(why.prefix(80))), seconds: 8)
    }

    /// 每句表存进笔记，也跟着录音存一份「.marks.json」（镜像、导入一起走）
    func setMarks(_ n: Note, path: String, marks: [ListenMark]) {
        var table = n.markTable
        table[path] = marks.isEmpty ? nil : marks
        n.markTable = table
        if !marks.isEmpty, let d = try? JSONEncoder().encode(marks) {
            try? attachments.save(d, name: (Listen.sidecar(for: path) as NSString).lastPathComponent)
        }
    }

    func folderNamed(_ name: String) -> Folder? {
        let name = name.trimmed
        guard !name.isEmpty else { return nil }
        let all = (try? context.fetch(FetchDescriptor<Folder>())) ?? []
        if let f = all.first(where: { $0.name == name }) { return f }
        let f = Folder(name: name, order: all.count)
        context.insert(f)
        return f
    }

    /// 「念出来」：手机用苹果的语音把这条念成录音，进听力列表
    func speak(_ n: Note) {
        let id = n.id
        let md = n.markdown
        busy = t.t("busy.speak")
        Task {
            defer { self.busy = nil }
            let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("yiye-speak-\(UUID().uuidString).m4a")
            do {
                let out = try await PhoneVoice().render(md, to: tmp)
                guard let n = self.note(id) else { return }
                AudioPlayback.shared.forget(Listen.speakName(note: id))
                let rel = try self.attachments.move(tmp, name: Listen.speakName(note: id))
                n.audioPaths = [rel] + n.audioPaths.filter { $0 != rel }
                self.setMarks(n, path: rel, marks: out.marks)
                self.changed(n)
                if !n.inListen || out.premium == false {
                    self.show(out.premium ? self.t.t("listen.spoken") : self.t.t("listen.spokenBasic"), seconds: out.premium ? 4 : 8)
                }
            } catch {
                self.show(self.t.f("listen.speakFailed", error.localizedDescription))
            }
        }
    }

    /// 088 装新版第一次开：手机里已经有的、大管家送来的（kind=listen）、有听力录音、不在听力里的，放进听力。只跑一次
    func backfillListen() {
        guard !settings.listenBackfilled else { return }
        var n = 0
        for note in allNotes() where !note.trashed && note.kind == "listen" && note.listenPath != nil && !note.inListen {
            note.inListen = true
            mirror.saveSoon(note, attachments: attachments)
            n += 1
        }
        if n > 0 { try? context.save() }
        settings.listenBackfilled = true
    }

    // ---------------------------------------------------------------- 会了 / 不会（088）
    /// 写字页选中一个词点「会了」「不会」：交给大管家改词表，马上一行小提示，不问
    func markWord(_ selected: String, _ mark: WordMark, note: UUID) {
        guard let w = WordMark.clean(selected) else { return }
        butler.markWord(w, mark, note: note)
        show(mark == .known ? t.f("word.known", w) : t.f("word.learning", w), seconds: 3)
    }

    /// 大管家送来一篇（配好音的听力稿）：变成一条笔记，进「英语」文件夹，直接进听力（088）。
    /// 回「配音」请求的（带 note）：录音挂到那条笔记上，换掉手机念的
    func addDelivery(_ d: ButlerDelivery, audio: Data?) {
        guard !settings.deliveredIDs.contains(d.id) else { return }
        if let nid = d.note.flatMap({ UUID(uuidString: $0) }), let n = note(nid) {
            settings.deliveredIDs = Array((settings.deliveredIDs + [d.id]).suffix(500))
            // 回的是最新那次请求（或者没写回的哪次）才算等到了；更早那次的先挂上，接着等新的
            let latest = d.request == nil || d.request == n.dubRequest
            guard let audio, let a = d.audio else {
                if latest { dubFailed(n, error: nil) }
                return
            }
            let ext = (a as NSString).pathExtension.lowercased()
            let name = Listen.deliveryName(note: nid, ext: ext.isEmpty ? "mp3" : ext)
            AudioPlayback.shared.forget(name)
            if let rel = try? attachments.save(audio, name: name) {
                let old = n.audioPaths.filter { Listen.isListenAudio($0) && $0 != rel }
                var table = n.markTable
                for o in old { table[o] = nil }
                n.markTable = table
                n.audioPaths = [rel] + n.audioPaths.filter { !Listen.isListenAudio($0) }
                setMarks(n, path: rel, marks: d.marks ?? [])
            }
            if latest { n.dub = "" }
            changed(n)
            show(t.f("listen.dubbed", n.title.isEmpty ? t.t("note.untitled") : n.title))
            return
        }
        let id = UUID(uuidString: d.id) ?? UUID()
        guard note(id) == nil else { return }
        let n = Note()
        n.id = id
        n.kind = d.kind.isEmpty ? "listen" : d.kind
        n.markdown = d.text
        // 直接进听力，听力页按日期分组（Song 11-23 15:05，推翻 11-21「点了耳机才进」）；文件夹照旧
        n.inListen = true
        if let at = d.at.flatMap({ ISOTime.date($0) }) { n.createdAt = at; n.modifiedAt = at }
        n.folder = folderNamed(d.folder ?? "英语")
        context.insert(n)
        if let audio, let a = d.audio {
            let ext = (a as NSString).pathExtension.lowercased()
            let name = (a as NSString).lastPathComponent.isEmpty ? Listen.deliveryName(note: id, ext: ext.isEmpty ? "mp3" : ext) : (a as NSString).lastPathComponent
            if let rel = try? attachments.save(audio, name: name) {
                n.audioPaths = [rel]
                setMarks(n, path: rel, marks: d.marks ?? [])
            }
        }
        try? context.save()
        mirror.saveSoon(n, attachments: attachments)
        settings.deliveredIDs = Array((settings.deliveredIDs + [d.id]).suffix(500))
        show(t.f("listen.arrived", n.title.isEmpty ? t.t("note.untitled") : n.title))
    }

    // ---------------------------------------------------------------- 深聊（107）
    /// 大管家想好的完整版存成一条便签，放「深聊」文件夹；口语版的录音挂在上面，能再听
    func addDeepNote(id: String, title: String, text: String, audio: Data?) {
        let nid = UUID(uuidString: id) ?? UUID()
        guard note(nid) == nil else { return }
        let n = Note()
        n.id = nid
        let head = title.trimmingCharacters(in: .whitespacesAndNewlines)
        n.markdown = (head.isEmpty ? "" : "# \(head)\n\n") + text
        n.folder = folderNamed("深聊")
        context.insert(n)
        if let audio, let rel = try? attachments.save(audio, name: "深聊-\(id.prefix(8)).mp3") { n.audioPaths = [rel] }
        try? context.save()
        mirror.saveSoon(n, attachments: attachments)
    }

    // ---------------------------------------------------------------- 相册
    /// 相册里挑的图取出来（iCloud 照片要现下，可能要几秒）；取不出来说一声
    func loadPicked(_ item: PhotosPickerItem, _ done: @escaping (UIImage) -> Void) {
        busy = t.t("busy.album")
        Task {
            do {
                guard let data = try await item.loadTransferable(type: Data.self) else { throw CocoaError(.fileReadNoSuchFile) }
                guard let img = UIImage(data: data) else { throw CocoaError(.fileReadCorruptFile) }
                self.busy = nil
                done(img)
            } catch {
                self.busy = nil
                self.show(self.t.f("album.failed", error.localizedDescription))
            }
        }
    }

    // ---------------------------------------------------------------- 拍照认字
    func recognize(_ image: UIImage, into existing: Note? = nil, at location: Int? = nil) {
        busy = t.t("busy.ocr")
        Task {
            defer { self.busy = nil }
            do {
                let got = try await Capture.intake(from: image)
                if got.markdown.trimmed.isEmpty {
                    self.show(self.t.t("ocr.nothing"))
                    return
                }
                self.intake(got, into: existing, at: location)
            } catch {
                show(t.f("ocr.failed", "\(error.localizedDescription)"))
            }
        }
    }
}
