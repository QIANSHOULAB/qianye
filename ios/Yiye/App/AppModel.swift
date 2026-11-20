import SwiftUI
import SwiftData
import UIKit
import YiyeKit
import YiyeOCR

enum Route: Hashable {
    case editor(UUID)
    case settings
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

    var path: [Route] = []
    var toast: Toast?
    /// 正在干一件超过一秒的活（认字）：显示一句在干啥
    var busy: String?
    /// 第一次打开问一次镜像文件夹
    var showMirrorPrompt = false
    /// 刚建的空笔记（离开时还是空的就删掉）
    var freshNoteID: UUID?

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
    }

    func started() {
        guard !didStart else { return }
        didStart = true
        butler.app = self
        if let demo {
            Demo.seed(self, demo)
        } else {
            CameraCanary.checkOnLaunch(settings)
            mirror.restore()
            showMirrorPrompt = !settings.mirrorAsked && !mirror.isOn
            purgeTrashed()
        }
        butler.start()
    }

    func scenePhase(_ p: ScenePhase) {
        switch p {
        case .active:
            butler.start()
        case .background:
            butler.stop()
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
    func intake(_ input: Intake, into existing: Note? = nil, at location: Int? = nil, open: Bool = true) -> Note {
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
            if x.kind == .photo { n.kind = IntakeKind.photo.rawValue }
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
        n.modifiedAt = Date()
        try? context.save()
        mirror.saveSoon(n, attachments: attachments)
        if x.kind == .photo && settings.butlerAutoPhoto {
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
        if n.markdown.trimmed.isEmpty && n.originalPaths.isEmpty {
            context.delete(n)
            try? context.save()
            if mirror.isOn { mirror.trash(n.id) }
        } else {
            mirror.saveNow(n, attachments: attachments)
        }
        if freshNoteID == n.id { freshNoteID = nil }
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
