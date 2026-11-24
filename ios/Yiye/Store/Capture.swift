import UIKit
import ImageIO
import SwiftData
import YiyeKit
import YiyeOCR

/// 拍照 / 相册 → 本机认字 → Intake（草稿出来马上进笔记，不等大管家）
enum Capture {
    static func intake(from image: UIImage) async throws -> Intake {
        let fixed = upright(image)
        guard let cg = fixed.cgImage else { throw CocoaError(.fileReadCorruptFile) }
        let r = try await PhotoToDraft.run(cg, orientation: .up)
        let original = AttachmentStore.jpeg(fixed).map { [$0] } ?? []
        return Intake(draft: r.draft, originals: original)
    }

    /// 把 EXIF 方向画进像素里（Vision 和存原图都按「正」的来）
    static func upright(_ img: UIImage) -> UIImage {
        if img.imageOrientation == .up { return img }
        let fmt = UIGraphicsImageRendererFormat()
        fmt.scale = img.scale
        fmt.opaque = true
        return UIGraphicsImageRenderer(size: img.size, format: fmt).image { _ in img.draw(in: CGRect(origin: .zero, size: img.size)) }
    }
}

extension AppModel {
    /// 导入：同一个 id 的，文件里的更新就换上；没有的新建。文件夹按名字找，没有就建
    func mergeImported(_ items: [MirrorImport]) -> (added: Int, updated: Int) {
        var added = 0, updated = 0
        let existing = Dictionary(allNotes().map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        var folders = Dictionary(((try? context.fetch(FetchDescriptor<Folder>())) ?? []).map { ($0.name, $0) }, uniquingKeysWith: { a, _ in a })
        func folderNamed(_ name: String) -> Folder? {
            guard !name.isEmpty else { return nil }
            if let f = folders[name] { return f }
            let f = Folder(name: name, order: folders.count)
            context.insert(f)
            folders[name] = f
            return f
        }
        for it in items {
            if let n = existing[it.meta.id] {
                if it.meta.modified > n.modifiedAt.addingTimeInterval(1) {
                    n.markdown = it.body
                    n.modifiedAt = it.meta.modified
                    n.pinned = it.meta.pinned
                    n.paper = it.meta.color
                    n.folder = folderNamed(it.meta.folder)
                    if n.audioPaths.isEmpty { n.audioPaths = Listen.importPaths(note: n.id) { attachments.exists($0) }; loadMarks(n) }
                    updated += 1
                }
                continue
            }
            let n = Note()
            n.id = it.meta.id
            n.markdown = it.body
            n.createdAt = it.meta.created
            n.modifiedAt = it.meta.modified
            n.pinned = it.meta.pinned
            n.paper = it.meta.color
            n.kind = it.meta.kind
            n.inListen = ListenRule.isListen(kind: it.meta.kind)
            n.folder = folderNamed(it.meta.folder)
            n.originalPaths = it.meta.kind == "photo" ? originalsFor(it.meta.id) : []
            n.audioPaths = Listen.importPaths(note: it.meta.id) { attachments.exists($0) }
            loadMarks(n)
            context.insert(n)
            added += 1
        }
        try? context.save()
        return (added, updated)
    }

    /// 导入时把每句表从「.marks.json」读回来
    private func loadMarks(_ n: Note) {
        var table: [String: [ListenMark]] = [:]
        for p in n.audioPaths {
            if let d = attachments.data(Listen.sidecar(for: p)), let m = try? JSONDecoder().decode([ListenMark].self, from: d) { table[p] = m }
        }
        if !table.isEmpty { n.markTable = table }
    }

    private func originalsFor(_ id: UUID) -> [String] {
        let short = MirrorFormat.shortID(id)
        return (1...9).map { "\(MirrorFolder.attachName)/\(short)-原图-\($0).jpg" }.filter { attachments.exists($0) }
    }
}
