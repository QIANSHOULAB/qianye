// swift-tools-version:5.9
// 拍照认字：Vision 的 RecognizeDocumentsRequest（iOS 26 / macOS 26）→ YiyeKit 的 OCRPage → Markdown 草稿。
// app 用 YiyeOCR；CI 在 macOS 上用 ocr-eval 跑 10 张样张，报认对几成、标黄准不准。
import PackageDescription

let package = Package(
    name: "YiyeOCR",
    platforms: [.iOS("26.0"), .macOS("26.0")],
    products: [.library(name: "YiyeOCR", targets: ["YiyeOCR"])],
    dependencies: [.package(path: "../YiyeKit")],
    targets: [
        .target(name: "YiyeOCR", dependencies: ["YiyeKit"]),
        .executableTarget(name: "ocr-eval", dependencies: ["YiyeOCR", "YiyeKit"]),
    ]
)
