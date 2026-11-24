import Foundation
import UIKit
import Observation
import YiyeKit

/// iCloud 云盘里的文件要协调读写；别的机器写进来的占位文件，读之前先叫它下载
final class CoordinatedFileAccess: FileAccess {
    let plain = PlainFileAccess()
    let fm = FileManager.default

    private func coordinated<T>(read url: URL, _ body: (URL) throws -> T) throws -> T {
        var err: NSError?
        var out: Result<T, Error>?
        NSFileCoordinator().coordinate(readingItemAt: url, options: [], error: &err) { u in out = Result { try body(u) } }
        if let err { throw err }
        guard let out else { throw CocoaError(.fileReadUnknown) }
        return try out.get()
    }

    private func coordinated(write url: URL, options: NSFileCoordinator.WritingOptions, _ body: (URL) throws -> Void) throws {
        var err: NSError?
        var out: Result<Void, Error> = .success(())
        NSFileCoordinator().coordinate(writingItemAt: url, options: options, error: &err) { u in out = Result { try body(u) } }
        if let err { throw err }
        try out.get()
    }

    func read(_ url: URL) throws -> Data { try coordinated(read: url) { try Data(contentsOf: $0) } }

    func write(_ data: Data, to url: URL) throws {
        try plain.makeDir(url.deletingLastPathComponent())
        try coordinated(write: url, options: .forReplacing) { try data.write(to: $0, options: .atomic) }
    }

    func move(_ from: URL, to: URL) throws {
        try plain.makeDir(to.deletingLastPathComponent())
        var err: NSError?
        var out: Result<Void, Error> = .success(())
        NSFileCoordinator().coordinate(writingItemAt: from, options: .forMoving, writingItemAt: to, options: .forReplacing, error: &err) { a, b in
            out = Result {
                if self.fm.fileExists(atPath: b.path) { try self.fm.removeItem(at: b) }
                try self.fm.moveItem(at: a, to: b)
            }
        }
        if let err { throw err }
        try out.get()
    }

    func remove(_ url: URL) throws {
        guard fm.fileExists(atPath: url.path) else { return }
        try coordinated(write: url, options: .forDeleting) { try self.fm.removeItem(at: $0) }
    }

    func list(_ dir: URL) throws -> [URL] { try plain.list(dir) }
    func exists(_ url: URL) -> Bool { plain.exists(url) }
    func makeDir(_ url: URL) throws { try plain.makeDir(url) }
    func modified(_ url: URL) -> Date? { plain.modified(url) }

    func ensureDownloaded(_ url: URL) -> Bool {
        if fm.fileExists(atPath: url.path) && isLocal(url) { return true }
        try? fm.startDownloadingUbiquitousItem(at: url)
        let deadline = Date().addingTimeInterval(8)
        while Date() < deadline {
            if fm.fileExists(atPath: url.path) && isLocal(url) { return true }
            Thread.sleep(forTimeInterval: 0.3)
        }
        // 协调读也会把它拉下来
        _ = try? coordinated(read: url) { _ in true }
        return fm.fileExists(atPath: url.path)
    }

    private func isLocal(_ url: URL) -> Bool {
        guard let v = try? url.resourceValues(forKeys: [.ubiquitousItemDownloadingStatusKey]),
              let s = v.ubiquitousItemDownloadingStatus else { return true }   // 不是 iCloud 里的文件
        return s == .current || s == .downloaded
    }
}

/// 某条笔记此刻的样子（拿到后台写文件用）
struct NoteSnapshot: Sendable {
    var meta: MirrorMeta
    var markdown: String
    var attachments: [String]
}

/// 镜像文件夹：Song 挑一次（文件面板开在 iCloud 云盘那一层），app 在里面建「一叶笺/」。每存一次写一个 .md。
@MainActor @Observable
final class MirrorService {
    private(set) var root: URL?
    var lastError: String?
    private(set) var lastWrite: Date?
    @ObservationIgnored let fs = CoordinatedFileAccess()
    @ObservationIgnored let queue = DispatchQueue(label: "lab.qianshou.yiye.mirror", qos: .utility)
    @ObservationIgnored private var pending: [UUID: DispatchWorkItem] = [:]
    @ObservationIgnored private var scoped: URL?
    @ObservationIgnored private let demo: Bool
    static let folderName = "一叶笺"
    static let bookmarkKey = "yiye.mirrorBookmark"

    init(demo: Bool) { self.demo = demo }

    var isOn: Bool { root != nil }

    var folder: MirrorFolder? { root.map { MirrorFolder(root: $0, fs: fs) } }
    var channel: ButlerChannel? { root.map { ButlerChannel(root: $0, fs: fs) } }

    /// 设置里显示的位置：「iCloud 云盘/一叶笺」这样
    func displayPath(_ lang: Lang) -> String {
        guard let root else { return lang.t("mirror.off") }
        let p = root.path
        if let r = p.range(of: "com~apple~CloudDocs") {
            let rest = p[r.upperBound...].trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            return lang.t("mirror.icloud") + (rest.isEmpty ? "" : "/" + rest)
        }
        if demo { return lang.t("mirror.icloud") + "/" + MirrorService.folderName }
        let comps = root.pathComponents.suffix(2)
        return comps.joined(separator: "/")
    }

    /// 启动时：把上次挑的文件夹找回来
    func restore() {
        guard let data = UserDefaults.standard.data(forKey: MirrorService.bookmarkKey) else { return }
        var stale = false
        guard let url = try? URL(resolvingBookmarkData: data, options: [], relativeTo: nil, bookmarkDataIsStale: &stale) else {
            lastError = "bookmark"
            return
        }
        _ = url.startAccessingSecurityScopedResource()
        scoped = url
        if stale, let fresh = try? url.bookmarkData(options: .minimalBookmark, includingResourceValuesForKeys: nil, relativeTo: nil) {
            UserDefaults.standard.set(fresh, forKey: MirrorService.bookmarkKey)
        }
        root = MirrorService.rootFor(url)
        try? folder?.prepare()
    }

    static func rootFor(_ picked: URL) -> URL {
        picked.lastPathComponent == folderName ? picked : picked.appendingPathComponent(folderName, isDirectory: true)
    }

    /// 文件面板挑好了：记住它，在里面建「一叶笺/」
    func use(_ picked: URL) throws {
        if let old = scoped { old.stopAccessingSecurityScopedResource() }
        _ = picked.startAccessingSecurityScopedResource()
        scoped = picked
        let data = try picked.bookmarkData(options: .minimalBookmark, includingResourceValuesForKeys: nil, relativeTo: nil)
        UserDefaults.standard.set(data, forKey: MirrorService.bookmarkKey)
        let r = MirrorService.rootFor(picked)
        try MirrorFolder(root: r, fs: fs).prepare()
        try ButlerChannel(root: r, fs: fs).prepare()
        root = r
        lastError = nil
    }

    /// 截图用：一个临时文件夹当镜像
    func useDemo(_ url: URL) {
        root = url
        try? folder?.prepare()
        try? channel?.prepare()
    }

    static func snapshot(_ n: Note) -> NoteSnapshot {
        NoteSnapshot(meta: MirrorMeta(id: n.id, created: n.createdAt, modified: n.modifiedAt, folder: n.folder?.name ?? "",
                                      pinned: n.pinned, color: PaperMark.toMirror(n.paper), kind: n.kind),
                     markdown: n.markdown,
                     attachments: Markdown5.imagePaths(n.markdown) + n.originalPaths + n.audioPaths + n.audioPaths.map(Listen.sidecar))
    }

    /// 攒一秒再写（打字时不是每个字都写一次）
    func saveSoon(_ n: Note, attachments: AttachmentStore) {
        guard let folder else { return }
        let snap = MirrorService.snapshot(n)
        pending[snap.meta.id]?.cancel()
        let item = DispatchWorkItem { MirrorService.write(snap, folder: folder, store: attachments) }
        pending[snap.meta.id] = item
        queue.asyncAfter(deadline: .now() + 1.0, execute: item)
        lastWrite = Date()
    }

    func saveNow(_ n: Note, attachments: AttachmentStore) {
        guard let folder else { return }
        let snap = MirrorService.snapshot(n)
        pending[snap.meta.id]?.cancel()
        pending[snap.meta.id] = nil
        queue.async { MirrorService.write(snap, folder: folder, store: attachments) }
        lastWrite = Date()
    }

    /// 后台写：先把附件拷过去，再写 .md（标题改了顺手删旧名字的）
    nonisolated static func write(_ s: NoteSnapshot, folder: MirrorFolder, store: AttachmentStore) {
        for p in s.attachments where !folder.hasAttachment(p) {
            if let d = try? Data(contentsOf: store.url(p)) { try? folder.writeAttachment(d, relative: p) }
        }
        try? folder.save(s.meta, body: s.markdown)
    }

    func trash(_ id: UUID) {
        guard let folder else { return }
        pending[id]?.cancel()
        pending[id] = nil
        queue.async { try? folder.trash(id) }
    }

    /// 真删：镜像废纸篓里那份也删
    func purge(_ id: UUID) {
        guard let folder else { return }
        queue.async { folder.purge(id) }
    }

    func restoreFromTrash(_ id: UUID) {
        guard let folder else { return }
        queue.async { try? folder.restore(id) }
    }

    /// 等前面排着的写完再干（交给大管家前，笔记和原图得先在镜像里）
    func afterPendingWrites(_ work: @escaping @Sendable () -> Void) {
        queue.async(execute: work)
    }

    /// 从文件夹导入：一条不落搬回来（换了正式版 Bundle ID 变了，数据靠这个过去）
    func importAll(into app: AppModel) {
        guard let folder else { return }
        app.busy = app.lang.t("busy.import")
        let store = app.attachments
        queue.async {
            let got = folder.importAll()
            // 附件拷回本机
            for n in got.notes {
                let short = MirrorFormat.shortID(n.meta.id)
                let originals = (1...9).map { "\(MirrorFolder.attachName)/\(short)-原图-\($0).jpg" }.filter { folder.hasAttachment($0) }
                let audios = Listen.importPaths(note: n.meta.id) { folder.hasAttachment($0) }
                let sidecars = audios.map(Listen.sidecar).filter { folder.hasAttachment($0) }
                for p in Markdown5.imagePaths(n.body) + originals + audios + sidecars where !FileManager.default.fileExists(atPath: store.url(p).path) {
                    let src = folder.url(p)
                    if folder.fs.ensureDownloaded(src), let d = try? folder.fs.read(src) {
                        try? d.write(to: store.url(p), options: .atomic)
                    }
                }
            }
            Task { @MainActor in
                app.busy = nil
                let r = app.mergeImported(got.notes)
                app.show(app.lang.f("import.done", r.added, r.updated) + (got.pending.isEmpty ? "" : app.lang.f("import.pending", got.pending.count)))
            }
        }
    }
}
