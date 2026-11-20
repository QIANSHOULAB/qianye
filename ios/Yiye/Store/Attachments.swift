import UIKit
import YiyeKit

/// 图片存成文件：<Application Support>/附件/xxx.jpg，正文里写 ![](附件/xxx.jpg)。镜像时原样拷到 <镜像根>/附件/。
final class AttachmentStore {
    let base: URL
    private let cache = NSCache<NSString, UIImage>()

    init(demo: Bool) {
        let fm = FileManager.default
        if demo {
            base = fm.temporaryDirectory.appendingPathComponent("yiye-demo", isDirectory: true)
        } else {
            base = (try? fm.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true))
                ?? fm.temporaryDirectory
        }
        try? fm.createDirectory(at: base.appendingPathComponent(MirrorFolder.attachName, isDirectory: true), withIntermediateDirectories: true)
    }

    func url(_ rel: String) -> URL { base.appendingPathComponent(rel) }

    func exists(_ rel: String) -> Bool { FileManager.default.fileExists(atPath: url(rel).path) }

    /// 存一张，返回「附件/name」
    @discardableResult
    func save(_ data: Data, name: String) throws -> String {
        let rel = "\(MirrorFolder.attachName)/\(name)"
        try data.write(to: url(rel), options: .atomic)
        return rel
    }

    /// 录好的文件挪进附件，返回「附件/name」
    @discardableResult
    func move(_ file: URL, name: String) throws -> String {
        let rel = "\(MirrorFolder.attachName)/\(name)"
        let dst = url(rel)
        try? FileManager.default.removeItem(at: dst)
        try FileManager.default.moveItem(at: file, to: dst)
        return rel
    }

    func data(_ rel: String) -> Data? { try? Data(contentsOf: url(rel)) }

    func image(_ rel: String) -> UIImage? {
        if let i = cache.object(forKey: rel as NSString) { return i }
        guard let i = UIImage(contentsOfFile: url(rel).path) else { return nil }
        cache.setObject(i, forKey: rel as NSString)
        return i
    }

    func size(_ rel: String) -> CGSize? { image(rel)?.size }

    /// 缩到长边 2048、JPEG 质量 0.85（大管家接口里定的）
    static func jpeg(_ img: UIImage, maxSide: CGFloat = 2048, quality: CGFloat = 0.85) -> Data? {
        let s = img.size
        let k = min(1, maxSide / max(s.width, s.height))
        let target = CGSize(width: (s.width * k).rounded(), height: (s.height * k).rounded())
        let fmt = UIGraphicsImageRendererFormat()
        fmt.scale = 1
        fmt.opaque = true
        let out = UIGraphicsImageRenderer(size: target, format: fmt).image { _ in img.draw(in: CGRect(origin: .zero, size: target)) }
        return out.jpegData(compressionQuality: quality)
    }

    /// 新图的文件名：<短id>-<6 位>.jpg
    static func newName(for noteID: UUID) -> String {
        let r = UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(6).lowercased()
        return "\(MirrorFormat.shortID(noteID))-\(r).jpg"
    }
}
