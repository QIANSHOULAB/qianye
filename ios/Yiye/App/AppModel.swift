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
    let appearance: Appearance
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
        appearance = Appearance(persist: demo == nil, forced: demo?.appearancePref)
        Theme.shared.start(persist: demo == nil, forced: demo?.themePref)
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
        ShutongModel.shared.app = self                      // 136 书童
        ShutongTalker.shared.app = self                     // 137 书童开口说
        EarDiagSender.shared.app = self                     // 170 说话出错、界面卡：诊断寄给大管家
        TodoDesk.shared.app = self                          // 162 项目待办
        if let demo {
            Demo.seed(self, demo)
        } else {
            CameraCanary.checkOnLaunch(settings)
            mirror.restore()
            showMirrorPrompt = !settings.mirrorAsked && !mirror.isOn
            purgeTrashed()
            cleanHeard()
            migrateDeskFolders()
            backfillListen()
        }
        AudioPlayback.shared.loop = settings.listenLoop
        AudioPlayback.shared.onHeard = { [weak self] id in self?.heard(id) }
        butler.start()
        if demo == nil { companion.setUp() }
    }

    func scenePhase(_ p: ScenePhase) {
        switch p {
        case .active:
            if demo == nil { purgeTrashed(); cleanHeard(); ShutongModel.shared.showUnread() }   // 158：大管家的话没看的先弹
            butler.start()
            if demo == nil { StallWatch.shared.start() }    // 170：界面卡没卡
        case .background:
            StallWatch.shared.stop()
            ShutongTalker.shared.wentAway()                  // 137：切走了，开口说停（回来接着打字）
            try? context.save()
            butler.keepFlush(all: true)                      // 111：退到后台前，该抄给电脑的马上寄（写字页里的也算）
            if !companion.holdsButler { butler.stop() }     // 陪玩在听：信箱不断（后台音频让 app 一直醒着）
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
        ShutongModel.shared.enqueue(n)                       // 136：离开写字页以后书童起标题、放文件夹（空的照旧不留）
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
            ShutongModel.shared.enqueue(n)                   // 136：新便签一存下就收拾
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
        // 136：书童开着时，新的语音便签交给书童收拾（去口水、起标题、进文件夹，原话留着），不再走理顺；拍照的照旧理顺
        let shutongTakes = x.kind == .voice && existing == nil && settings.shutongAuto && n.shutongState.phase == "queued"
        if (x.kind == .photo || x.kind == .voice) && settings.butlerAutoPhoto && !n.markdown.trimmed.isEmpty && !shutongTakes {
            butler.submit(n)
        }
        if shutongTakes { ShutongModel.shared.tick() }
        if open && existing == nil { path.append(.editor(n.id)) }
        return n
    }

    /// 笔记改了：存库、镜像（攒一秒再写）
    func changed(_ n: Note) {
        n.modifiedAt = Date()
        try? context.save()
        mirror.saveSoon(n, attachments: attachments)
    }

    /// 删 = 进废纸篓，留 3 天（111）。右滑、批量选、写字页的删都走这儿；底下 5 秒给「撤销」
    func delete(_ n: Note) { deleteMany([n]) }

    func deleteMany(_ notes: [Note], quiet: Bool = false) {
        guard !notes.isEmpty else { return }
        let now = Date()
        for n in notes {
            n.trashed = true
            n.trashedAt = now
            mirror.trash(n.id)
        }
        try? context.save()
        TodoDesk.shared.trashed(notes)                      // 162：扔的是项目待办里的，告诉大管家
        if quiet { return }
        let ids = notes.map(\.id)
        let text: String
        if notes.count == 1 {
            let n = notes[0]
            text = t.f("trash.toast", n.title.isEmpty ? t.t("note.untitled") : n.title)
        } else {
            text = t.f("trash.toastMany", notes.count)
        }
        show(text, action: t.t("toast.undo"), seconds: 5) { [weak self] in
            guard let self else { return }
            self.putBack(ids)
            self.toast = nil
        }
    }

    /// 放回去：回原来的文件夹（扔的时候没动过 folder）；镜像里那份也挪回来
    func putBack(_ ids: [UUID]) {
        for id in ids {
            guard let n = note(id) else { continue }
            n.trashed = false
            n.trashedAt = nil
            n.heardAt = ListenRule.heardAtAfterPutBack(n.heardAt, now: Date())      // 112：听完的，从放回这天重新算 7 天
            mirror.restoreFromTrash(id)
        }
        try? context.save()
        TodoDesk.shared.putBack(ids)                        // 162：放回去的是待办，告诉大管家
    }

    /// 现在就删：真删，镜像里那份也删（他自己划的，不再问）
    func purgeNow(_ n: Note) {
        let id = n.id
        context.delete(n)
        try? context.save()
        mirror.purge(id)
    }

    /// 废纸篓里超过 3 天的真删；扔了但没写时间的（老数据）补成现在。开 app、回到前台时跑
    func purgeTrashed() {
        let now = Date()
        var gone: [UUID] = []
        for n in allNotes() where n.trashed {
            n.trashedAt = TrashRule.backfill(trashed: true, trashedAt: n.trashedAt, now: now)
            if let at = n.trashedAt, TrashRule.isExpired(trashedAt: at, now: now) {
                gone.append(n.id)
                context.delete(n)
            }
        }
        try? context.save()
        for id in gone { mirror.purge(id) }
    }

    /// 112：听完满 7 天的听力，自己进废纸篓（留 3 天能放回）。没听完的、普通便签一条都不动。打开 app、回到前台跑，不加后台任务
    func cleanHeard() {
        let now = Date()
        let old = allNotes().filter { !$0.trashed && ListenRule.shouldClean(kind: $0.kind, heardAt: $0.heardAt, now: now) }
        deleteMany(old, quiet: true)
    }

    /// 112：一篇第一次完整放完（听力列表里、写字页里放完都算）
    func heard(_ id: UUID) {
        guard let n = note(id), n.heardAt == nil else { return }
        n.heardAt = ListenRule.firstHeard(current: n.heardAt, now: Date())
        try? context.save()
    }

    /// 111 装新版第一次开：名字叫「思想排泄物」的夹子打开「抄一份到电脑」。只跑一次（以后他自己关了就不再替他开）
    func migrateDeskFolders() {
        guard !settings.deskMigrated else { return }
        let all = (try? context.fetch(FetchDescriptor<Folder>())) ?? []
        for f in all where KeepPlan.isDeskFolderName(f.name) { f.toDesk = true }
        try? context.save()
        settings.deskMigrated = true
    }

    /// 111：开了「抄一份到电脑」的夹子里的便签（空的不算），看电脑那份是不是最新一版
    func keepCandidates() -> [KeepCandidate] {
        allNotes().compactMap { n in
            guard let f = n.folder, f.toDesk, !n.markdown.trimmed.isEmpty else { return nil }
            return KeepCandidate(id: n.id, folder: f.name, folderToDesk: true, trashed: n.trashed, modifiedAt: n.modifiedAt, deskAt: n.deskAt)
        }
    }

    /// 111：超过 24 小时还没到电脑的，按夹子数（设置页那行小字）
    func keepStale() -> [KeepPlan.Stale] {
        KeepPlan.stale(keepCandidates(), now: Date())
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
        butler.keepFlush(force: [n.id])                          // 111：离开写字页，改完的马上抄给电脑
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
        allNotes().filter { ListenRule.inPlaylist(kind: $0.kind, inListen: $0.inListen, trashed: $0.trashed) }.sorted { $0.createdAt > $1.createdAt }
    }

    /// 能放的那些
    func listenTracks() -> [Track] { listenNotes().compactMap { track($0) } }

    /// 一条笔记的听力录音（没有就 nil）
    func track(_ n: Note) -> Track? {
        guard let path = n.listenPath else { return nil }
        return Track(note: n.id, path: path, title: n.title.isEmpty ? t.t("note.untitled") : n.title, marks: n.markTable[path] ?? [],
                     day: ListenLoop.key(n.createdAt))
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

    // ---------------------------------------------------------------- 文章（114）
    /// 捷径「存进一叶笺」来的：网址存成一条文章便签（第一行标题、最后一行网址）并寄给大管家扒正文；文字直接存成便签。返回回给捷径的一句话
    func saveShared(url: String?, text: String?) async -> String {
        switch ArticleShare.parse(url: url, text: text) {
        case .nothing:
            return t.t("article.noInput")
        case .text(let s):
            let n = Note()
            n.markdown = s
            context.insert(n)
            try? context.save()
            mirror.saveSoon(n, attachments: attachments)
            return t.t("article.savedText")
        case .url(let u):
            let title = await PageTitleFetch.title(u)
            let n = Note()
            n.kind = "article"
            n.markdown = ArticleText.initial(title: title, url: u)
            context.insert(n)
            try? context.save()
            mirror.saveSoon(n, attachments: attachments)
            let sent = await butler.submitArticle(n, url: u)
            return sent ? t.t("article.saved") : t.t("article.needPair")
        }
    }

    /// 扒正文 / 简写的回信：正文换进便签；简写出错记下原因（简写好的听力稿从「送来」另走）
    func articleReply(_ r: ButlerResult, _ nid: UUID) {
        guard let n = note(nid) else { return }
        var st = n.articleState
        if st.fetchID == r.id {
            let body = (r.text ?? "").trimmed
            if r.ok && body.isEmpty {
                st.fetchReply(id: r.id, ok: false, error: "大管家没扒出正文")
            } else if st.fetchReply(id: r.id, ok: r.ok, error: r.error) {
                n.markdown = ArticleText.compose(title: r.title, body: body, url: st.url, keepingHeadOf: n.markdown)
                n.unsure = ""
                n.articleState = st
                changed(n)
                NotificationCenter.default.post(name: .yiyeNoteReplaced, object: n.id)
                return
            }
        } else if st.simplifyID == r.id {
            st.simplifyReply(id: r.id, ok: r.ok, error: r.error)
        }
        n.articleState = st
        try? context.save()
    }

    /// 简写出来的听力送到了：挂回文章便签
    private func linkSimplified(request: String?, note: UUID) {
        guard let rq = request, !rq.isEmpty else { return }
        for a in allNotes() where a.kind == "article" {
            var st = a.articleState
            guard st.simplifyID == rq else { continue }
            st.pieceArrived(request: rq, note: note.uuidString)
            a.articleState = st
        }
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
        linkSimplified(request: d.request, note: id)
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
