import SwiftUI
import UIKit
import AVFoundation

/// 扫码配对（接口 v2）：对准掌机屏幕上的二维码，扫到就交回去；是不是大管家的配对码，ButlerService.pair 再判
struct PairScanner: UIViewControllerRepresentable {
    let done: (String?) -> Void
    func makeUIViewController(context: Context) -> PairScannerController {
        let c = PairScannerController()
        c.done = done
        return c
    }
    func updateUIViewController(_ uiViewController: PairScannerController, context: Context) {}
}

final class PairScannerController: UIViewController, AVCaptureMetadataOutputObjectsDelegate {
    var done: ((String?) -> Void)?
    private let session = AVCaptureSession()
    private var preview: AVCaptureVideoPreviewLayer?
    private let hint = UILabel()
    private let cancel = UIButton(type: .system)
    private var finished = false

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        let t = AppModel.shared.lang
        hint.text = t.t("pair.scanTitle")
        hint.textColor = .white
        hint.font = .systemFont(ofSize: 17, weight: .semibold)
        hint.textAlignment = .center
        hint.numberOfLines = 0
        cancel.setTitle(t.t("common.cancel"), for: .normal)
        cancel.setTitleColor(.white, for: .normal)
        cancel.titleLabel?.font = .systemFont(ofSize: 17)
        cancel.addTarget(self, action: #selector(quit), for: .touchUpInside)
        [hint, cancel].forEach { $0.translatesAutoresizingMaskIntoConstraints = false; view.addSubview($0) }
        NSLayoutConstraint.activate([
            hint.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 24),
            hint.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 24),
            hint.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -24),
            cancel.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            cancel.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -24),
            cancel.heightAnchor.constraint(greaterThanOrEqualToConstant: 44),
        ])
        AVCaptureDevice.requestAccess(for: .video) { ok in
            Task { @MainActor in
                if ok {
                    self.setUp()
                } else {
                    AppModel.shared.show(AppModel.shared.lang.t("pair.noCamera"), seconds: 6)
                    self.finish(nil)
                }
            }
        }
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        preview?.frame = view.bounds
    }

    private func setUp() {
        guard let dev = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back),
              let input = try? AVCaptureDeviceInput(device: dev), session.canAddInput(input) else { finish(nil); return }
        session.addInput(input)
        let out = AVCaptureMetadataOutput()
        guard session.canAddOutput(out) else { finish(nil); return }
        session.addOutput(out)
        out.setMetadataObjectsDelegate(self, queue: .main)
        out.metadataObjectTypes = [.qr]
        let p = AVCaptureVideoPreviewLayer(session: session)
        p.videoGravity = .resizeAspectFill
        p.frame = view.bounds
        view.layer.insertSublayer(p, at: 0)
        preview = p
        let s = session
        DispatchQueue.global(qos: .userInitiated).async { s.startRunning() }
    }

    @objc private func quit() { finish(nil) }

    private func finish(_ code: String?) {
        guard !finished else { return }
        finished = true
        let s = session
        DispatchQueue.global(qos: .userInitiated).async { s.stopRunning() }
        done?(code)
    }

    nonisolated func metadataOutput(_ output: AVCaptureMetadataOutput, didOutput metadataObjects: [AVMetadataObject], from connection: AVCaptureConnection) {
        guard let code = metadataObjects.compactMap({ ($0 as? AVMetadataMachineReadableCodeObject)?.stringValue }).first else { return }
        Task { @MainActor in self.finish(code) }
    }
}
