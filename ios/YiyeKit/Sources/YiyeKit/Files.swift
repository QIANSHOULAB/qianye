import Foundation

// 读写文件这一层抽出来：手机上走 NSFileCoordinator（iCloud 云盘里的文件要协调读写），测试里直接 FileManager。

public protocol FileAccess: AnyObject {
    func read(_ url: URL) throws -> Data
    /// 整个文件换掉（先写临时文件再改名）
    func write(_ data: Data, to url: URL) throws
    func move(_ from: URL, to: URL) throws
    func remove(_ url: URL) throws
    /// 目录里的文件（不进子目录）。iCloud 占位文件（.名字.icloud）原样列出来，由调用的人决定要不要等它下载
    func list(_ dir: URL) throws -> [URL]
    func exists(_ url: URL) -> Bool
    func makeDir(_ url: URL) throws
    func modified(_ url: URL) -> Date?
    /// iCloud 里别的机器写进来、手机上还只是占位的文件：先叫它下载。下载好了返回 true
    func ensureDownloaded(_ url: URL) -> Bool
}

public final class PlainFileAccess: FileAccess {
    let fm = FileManager.default
    public init() {}
    public func read(_ url: URL) throws -> Data { try Data(contentsOf: url) }
    public func write(_ data: Data, to url: URL) throws {
        try makeDir(url.deletingLastPathComponent())
        try data.write(to: url, options: .atomic)
    }
    public func move(_ from: URL, to: URL) throws {
        try makeDir(to.deletingLastPathComponent())
        if fm.fileExists(atPath: to.path) { try fm.removeItem(at: to) }
        try fm.moveItem(at: from, to: to)
    }
    public func remove(_ url: URL) throws { if fm.fileExists(atPath: url.path) { try fm.removeItem(at: url) } }
    public func list(_ dir: URL) throws -> [URL] {
        guard fm.fileExists(atPath: dir.path) else { return [] }
        return try fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil, options: [])
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }
    public func exists(_ url: URL) -> Bool { fm.fileExists(atPath: url.path) }
    public func makeDir(_ url: URL) throws {
        var isDir: ObjCBool = false
        if fm.fileExists(atPath: url.path, isDirectory: &isDir), isDir.boolValue { return }
        try fm.createDirectory(at: url, withIntermediateDirectories: true)
    }
    public func modified(_ url: URL) -> Date? {
        (try? fm.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date
    }
    public func ensureDownloaded(_ url: URL) -> Bool { fm.fileExists(atPath: url.path) }
}

/// iCloud 占位文件：「.笔记-1A2B3C4D.md.icloud」→ 真名「笔记-1A2B3C4D.md」
public func iCloudPlaceholderRealName(_ name: String) -> String? {
    guard name.hasPrefix("."), name.hasSuffix(".icloud"), name.count > 8 else { return nil }
    return String(name.dropFirst().dropLast(7))
}

// ================================================================ 时间：一律写成带时区的 ISO 8601（2026-11-20T08:00:00+08:00）
public enum ISOTime {
    public static func string(_ d: Date, tz: TimeZone = .current) -> String {
        let f = ISO8601DateFormatter()
        f.timeZone = tz
        f.formatOptions = [.withInternetDateTime]
        var s = f.string(from: d)
        if s.hasSuffix("Z") { s = String(s.dropLast()) + "+00:00" }
        return s
    }
    public static func date(_ s: String) -> Date? {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        if let d = f.date(from: s) { return d }
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f.date(from: s)
    }
}
