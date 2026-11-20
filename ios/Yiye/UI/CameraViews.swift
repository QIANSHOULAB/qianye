import SwiftUI
import UIKit
import AVFoundation
import VisionKit
import Vision
import CoreImage
import UniformTypeIdentifiers

// 拍照：VisionKit 文档相机（找纸边、拉正）。iOS 26 上有它拍完就闪退的报告：
// 打开前记一笔，正常关掉再划掉；下次启动发现那一笔还在（多半闪退了），以后就换成自己做的相机 + Vision 找边拉正。

enum CameraCanary {
    static let key = "yiye.docCamOpen"
    static func arm() { UserDefaults.standard.set(true, forKey: key) }
    static func disarm() { UserDefaults.standard.set(false, forKey: key) }

    @MainActor static func checkOnLaunch(_ settings: Settings) {
        if UserDefaults.standard.bool(forKey: key) {
            settings.useFallbackCamera = true
            disarm()
        }
    }
}

/// 拍照入口：拍完回一张（多页的按页拼成一张长图前先各认各的，这里只取第一页以外的也一起给）
struct CameraFlow: View {
    let done: (UIImage?) -> Void
    @Environment(AppModel.self) private var app

    var body: some View {
        if app.settings.useFallbackCamera || !VNDocumentCameraViewController.isSupported {
            FallbackCamera(done: done)
        } else {
            DocumentCamera(done: done)
        }
    }
}

struct DocumentCamera: UIViewControllerRepresentable {
    let done: (UIImage?) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(done: done) }

    func makeUIViewController(context: Context) -> VNDocumentCameraViewController {
        CameraCanary.arm()
        let vc = VNDocumentCameraViewController()
        vc.delegate = context.coordinator
        return vc
    }

    func updateUIViewController(_ uiViewController: VNDocumentCameraViewController, context: Context) {}

    final class Coordinator: NSObject, VNDocumentCameraViewControllerDelegate {
        let done: (UIImage?) -> Void
        init(done: @escaping (UIImage?) -> Void) { self.done = done }

        func documentCameraViewController(_ controller: VNDocumentCameraViewController, didFinishWith scan: VNDocumentCameraScan) {
            CameraCanary.disarm()
            guard scan.pageCount > 0 else { done(nil); return }
            if scan.pageCount == 1 { done(scan.imageOfPage(at: 0)); return }
            // 多页：上下拼成一张（每页先缩到同宽）
            let pages = (0..<scan.pageCount).map { scan.imageOfPage(at: $0) }
            done(Self.stack(pages))
        }

        func documentCameraViewControllerDidCancel(_ controller: VNDocumentCameraViewController) {
            CameraCanary.disarm()
            done(nil)
        }

        func documentCameraViewController(_ controller: VNDocumentCameraViewController, didFailWithError error: Error) {
            CameraCanary.disarm()
            done(nil)
        }

        static func stack(_ pages: [UIImage]) -> UIImage {
            let w: CGFloat = 1600
            let sizes = pages.map { CGSize(width: w, height: w * $0.size.height / max(1, $0.size.width)) }
            let total = CGSize(width: w, height: sizes.reduce(0) { $0 + $1.height })
            let fmt = UIGraphicsImageRendererFormat()
            fmt.scale = 1
            return UIGraphicsImageRenderer(size: total, format: fmt).image { _ in
                var y: CGFloat = 0
                for (p, s) in zip(pages, sizes) { p.draw(in: CGRect(x: 0, y: y, width: s.width, height: s.height)); y += s.height }
            }
        }
    }
}

// ================================================================ 自己做的相机：拍一张，Vision 找纸边，透视拉正
struct FallbackCamera: UIViewControllerRepresentable {
    let done: (UIImage?) -> Void
    func makeUIViewController(context: Context) -> FallbackCameraController {
        let c = FallbackCameraController()
        c.done = done
        return c
    }
    func updateUIViewController(_ uiViewController: FallbackCameraController, context: Context) {}
}

final class FallbackCameraController: UIViewController, AVCapturePhotoCaptureDelegate {
    var done: ((UIImage?) -> Void)?
    private let session = AVCaptureSession()
    private let output = AVCapturePhotoOutput()
    private var preview: AVCaptureVideoPreviewLayer?
    private let shutter = UIButton(type: .custom)
    private let cancel = UIButton(type: .system)
    private var finished = false

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        shutter.layer.cornerRadius = 36
        shutter.layer.borderWidth = 5
        shutter.layer.borderColor = UIColor.white.cgColor
        shutter.backgroundColor = UIColor.white.withAlphaComponent(0.25)
        shutter.addTarget(self, action: #selector(shoot), for: .touchUpInside)
        shutter.accessibilityLabel = AppModel.shared.lang.t("capture.shoot")
        cancel.setTitle(AppModel.shared.lang.t("common.cancel"), for: .normal)
        cancel.setTitleColor(.white, for: .normal)
        cancel.titleLabel?.font = .systemFont(ofSize: 17)
        cancel.addTarget(self, action: #selector(quit), for: .touchUpInside)
        [shutter, cancel].forEach { $0.translatesAutoresizingMaskIntoConstraints = false; view.addSubview($0) }
        NSLayoutConstraint.activate([
            shutter.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            shutter.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -24),
            shutter.widthAnchor.constraint(equalToConstant: 72),
            shutter.heightAnchor.constraint(equalToConstant: 72),
            cancel.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 24),
            cancel.centerYAnchor.constraint(equalTo: shutter.centerYAnchor),
            cancel.heightAnchor.constraint(greaterThanOrEqualToConstant: 44),
        ])
        AVCaptureDevice.requestAccess(for: .video) { ok in
            Task { @MainActor in ok ? self.setUp() : self.finish(nil) }
        }
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        preview?.frame = view.bounds
    }

    private func setUp() {
        session.sessionPreset = .photo
        guard let dev = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back),
              let input = try? AVCaptureDeviceInput(device: dev),
              session.canAddInput(input), session.canAddOutput(output) else { finish(nil); return }
        session.addInput(input)
        session.addOutput(output)
        let p = AVCaptureVideoPreviewLayer(session: session)
        p.videoGravity = .resizeAspectFill
        p.frame = view.bounds
        view.layer.insertSublayer(p, at: 0)
        preview = p
        let s = session
        DispatchQueue.global(qos: .userInitiated).async { s.startRunning() }
    }

    @objc private func shoot() {
        shutter.isEnabled = false
        output.capturePhoto(with: AVCapturePhotoSettings(), delegate: self)
    }

    @objc private func quit() { finish(nil) }

    private func finish(_ img: UIImage?) {
        guard !finished else { return }
        finished = true
        let s = session
        DispatchQueue.global(qos: .userInitiated).async { s.stopRunning() }
        done?(img)
    }

    nonisolated func photoOutput(_ output: AVCapturePhotoOutput, didFinishProcessingPhoto photo: AVCapturePhoto, error: Error?) {
        let data = photo.fileDataRepresentation()
        Task { @MainActor in
            guard let data, let img = UIImage(data: data) else { self.finish(nil); return }
            let flat = await DocumentFlattener.flatten(img)
            self.finish(flat)
        }
    }
}

/// 找纸的四个角（Vision DetectDocumentSegmentationRequest），透视拉正（CIPerspectiveCorrection）
enum DocumentFlattener {
    static func flatten(_ img: UIImage) async -> UIImage {
        let up = Capture.upright(img)
        guard let cg = up.cgImage else { return up }
        guard let obs = try? await DetectDocumentSegmentationRequest().perform(on: cg) else { return up }
        let w = CGFloat(cg.width), h = CGFloat(cg.height)
        func vec(_ p: NormalizedPoint) -> CIVector { CIVector(cgPoint: CGPoint(x: p.x * w, y: p.y * h)) }
        let ci = CIImage(cgImage: cg)
        guard let f = CIFilter(name: "CIPerspectiveCorrection") else { return up }
        f.setValue(ci, forKey: kCIInputImageKey)
        f.setValue(vec(obs.topLeft), forKey: "inputTopLeft")
        f.setValue(vec(obs.topRight), forKey: "inputTopRight")
        f.setValue(vec(obs.bottomLeft), forKey: "inputBottomLeft")
        f.setValue(vec(obs.bottomRight), forKey: "inputBottomRight")
        guard let out = f.outputImage, let res = CIContext().createCGImage(out, from: out.extent) else { return up }
        // 拉出来太小（多半找错边了）就用原图
        if CGFloat(res.width) * CGFloat(res.height) < w * h * 0.15 { return up }
        return UIImage(cgImage: res)
    }
}

// ================================================================ 镜像文件夹：文件面板开在 iCloud 云盘那一层
struct FolderPickerView: UIViewControllerRepresentable {
    let done: (URL?) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(done: done) }

    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        let p = UIDocumentPickerViewController(forOpeningContentTypes: [.folder], asCopy: false)
        p.allowsMultipleSelection = false
        p.directoryURL = URL(fileURLWithPath: "/private/var/mobile/Library/Mobile Documents/com~apple~CloudDocs", isDirectory: true)
        p.delegate = context.coordinator
        return p
    }

    func updateUIViewController(_ uiViewController: UIDocumentPickerViewController, context: Context) {}

    final class Coordinator: NSObject, UIDocumentPickerDelegate {
        let done: (URL?) -> Void
        init(done: @escaping (URL?) -> Void) { self.done = done }
        func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) { done(urls.first) }
        func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) { done(nil) }
    }
}

// ================================================================ 看原图
struct OriginalsViewer: View {
    let paths: [String]
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            SmartBar {
                Button(app.lang.t("common.close")) { dismiss() }.buttonStyle(SmartButtonStyle())
            } center: {
                BarTitle(text: app.lang.t("editor.original"))
            } right: {
                EmptyView()
            }
            ScrollView {
                VStack(spacing: 16) {
                    ForEach(paths, id: \.self) { p in
                        if let img = app.attachments.image(p) {
                            Image(uiImage: img).resizable().scaledToFit()
                                .shadow(color: .black.opacity(0.2), radius: 6, y: 2)
                        } else {
                            Text(app.lang.t("editor.originalMissing")).foregroundStyle(Color(Ink.text3)).padding(40)
                        }
                    }
                }
                .padding(16)
            }
            .background(DeskBackground())
        }
    }
}
