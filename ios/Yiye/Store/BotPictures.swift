import Foundation
import Photos
import UIKit

/// 252 机器人话里的图：跟聊天记录一起留（最近 200 条，掉出去的图一起删）。截图、UI 测试放临时目录。
@MainActor
enum BotPictures {
    static var demo = false
    private static let cache = NSCache<NSString, UIImage>()

    private static var dir: URL? {
        let base = demo ? FileManager.default.temporaryDirectory : FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
        guard let d = base?.appendingPathComponent(demo ? "bot-images-demo" : "bot-images", isDirectory: true) else { return nil }
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }

    @discardableResult
    static func save(_ data: Data, name: String) -> Bool {
        guard let u = dir?.appendingPathComponent(name) else { return false }
        do { try data.write(to: u, options: .atomic) } catch { return false }
        cache.removeObject(forKey: name as NSString)
        return true
    }

    static func data(_ name: String) -> Data? {
        dir.flatMap { try? Data(contentsOf: $0.appendingPathComponent(name)) }
    }

    /// 同一个名字回同一张（放大看的时候界面刷新不会跳回原大小）
    static func image(_ name: String) -> UIImage? {
        if let i = cache.object(forKey: name as NSString) { return i }
        guard let d = data(name), let i = UIImage(data: d) else { return nil }
        cache.setObject(i, forKey: name as NSString)
        return i
    }

    static func remove(_ names: [String]) {
        for n in names {
            cache.removeObject(forKey: n as NSString)
            if let u = dir?.appendingPathComponent(n) { try? FileManager.default.removeItem(at: u) }
        }
    }

    /// 长按存进相册（只要「添加照片」权限）；原样存那份 JPEG。截图、UI 测试不碰相册
    static func keep(_ name: String, app: AppModel) {
        guard let d = data(name) else { return }
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        if demo { app.show(app.lang.t("share.saved")); return }
        PHPhotoLibrary.requestAuthorization(for: .addOnly) { status in
            guard status == .authorized || status == .limited else {
                Task { @MainActor in app.show(app.lang.t("share.noPermission"), seconds: 6) }
                return
            }
            PHPhotoLibrary.shared().performChanges({
                PHAssetCreationRequest.forAsset().addResource(with: .photo, data: d, options: nil)
            }) { ok, err in
                Task { @MainActor in
                    app.show(ok ? app.lang.t("share.saved") : app.lang.f("share.saveFailed", err?.localizedDescription ?? ""))
                }
            }
        }
    }
}
