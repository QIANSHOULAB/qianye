// swift-tools-version:5.9
// 一叶笺 iPhone 版里不碰 UIKit 的那部分：Markdown 五招、出图排版、镜像文件、大管家接口、认字草稿。
// Linux 上也能编、能跑测试（CI 在 macOS 上再跑一遍）。
import PackageDescription

let package = Package(
    name: "YiyeKit",
    platforms: [.iOS("26.0"), .macOS("14.0")],
    products: [.library(name: "YiyeKit", targets: ["YiyeKit"])],
    targets: [
        .target(name: "YiyeKit"),
        .testTarget(name: "YiyeKitTests", dependencies: ["YiyeKit"]),
    ]
)
