import Foundation
import XCTest

/// 229：改名叫 one。给人看的字里不再有旧名字；里子（Bundle ID、iCloud 文件夹「一叶笺」）不动
final class Name229Tests: XCTestCase {
    /// ios/（这个测试文件往上三层）
    private var ios: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    /// String Catalog 里「键 → [中文, 英文]」
    private func catalog(_ name: String) throws -> [String: [String]] {
        let data = try Data(contentsOf: ios.appendingPathComponent("Yiye/Resources/\(name)"))
        let root = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let strings = try XCTUnwrap(root["strings"] as? [String: Any])
        return strings.mapValues { v in
            let locs = (v as? [String: Any])?["localizations"] as? [String: Any] ?? [:]
            return ["zh-Hans", "en"].map { lang in
                ((locs[lang] as? [String: Any])?["stringUnit"] as? [String: Any])?["value"] as? String ?? ""
            }
        }
    }

    func testNameIsOneEverywhereAPersonReads() throws {
        let app = try catalog("Localizable.xcstrings")
        XCTAssertEqual(app["app.name"], ["one", "one"])
        XCTAssertEqual(app["share.mark"], ["one", "one"])          // 出图落款
        let info = try catalog("InfoPlist.xcstrings")
        XCTAssertEqual(info["CFBundleDisplayName"], ["one", "one"])
        XCTAssertEqual(info["CFBundleName"], ["one", "one"])
        for (key, values) in app.merging(info, uniquingKeysWith: { a, _ in a }) {
            for v in values {
                XCTAssertFalse(v.contains("一叶笺") || v.contains("Yiye"), "\(key) 还是旧名字：\(v)")
            }
        }
    }

    func testInsidesStay() throws {
        let yml = try String(contentsOf: ios.appendingPathComponent("project.yml"), encoding: .utf8)
        XCTAssertEqual(yml.components(separatedBy: "CFBundleDisplayName: one\n").count, 3)      // app 和直播扩展两处
        XCTAssertTrue(yml.contains("PRODUCT_BUNDLE_IDENTIFIER: lab.qianshou.yiye\n"))          // 里子不动
        XCTAssertTrue(yml.contains("CFBundleURLSchemes: [yiye]"))
        let mirror = try String(contentsOf: ios.appendingPathComponent("Yiye/Store/MirrorService.swift"), encoding: .utf8)
        XCTAssertTrue(mirror.contains("folderName = \"一叶笺\""))                                  // iCloud 文件夹：旧数据靠它接着
    }
}
