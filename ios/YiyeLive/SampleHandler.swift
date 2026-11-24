import CoreImage
import CoreImage.CIFilterBuiltins
import ImageIO
import Network
import ReplayKit
import YiyeKit

/// 一叶笺的屏幕直播扩展（陪玩模式，pc-butler 施工单 100）。
/// - 只在内存里留最新一帧（一个像素缓冲的引用，不攒帧、不写盘，扩展内存上限约 50 MB）。
/// - 主 App 要的时候（他问的那一刻）才把那一帧转正、缩到大脑看的尺寸、压成 JPEG，从本机回环口子交过去。
/// - 开播、停播各响一声 Darwin 通知（门铃），主 App 听见了开始听 / 停听。
final class SampleHandler: RPBroadcastSampleHandler {
    let store = FrameStore()
    private var server: FrameServer?

    override func broadcastStarted(withSetupInfo setupInfo: [String: NSObject]?) {
        let s = FrameServer(store: store)
        server = s
        s.start()
        listenForFinish()
        ring(LiveWire.started)
    }

    override func broadcastFinished() {
        server?.stop()
        server = nil
        store.clear()
        CFNotificationCenterRemoveEveryObserver(CFNotificationCenterGetDarwinNotifyCenter(), Unmanaged.passUnretained(self).toOpaque())
        ring(LiveWire.stopped)
    }

    /// 主 App 关了陪玩：马上停播（系统会弹一句「陪玩关了」）
    private func listenForFinish() {
        let me = Unmanaged.passUnretained(self).toOpaque()
        CFNotificationCenterAddObserver(CFNotificationCenterGetDarwinNotifyCenter(), me, { _, observer, _, _, _ in
            guard let observer else { return }
            let h = Unmanaged<SampleHandler>.fromOpaque(observer).takeUnretainedValue()
            h.store.clear()
            h.finishBroadcastWithError(NSError(domain: "lab.qianshou.yiye.live", code: 1,
                                               userInfo: [NSLocalizedDescriptionKey: "陪玩关了 · Buddy mode off"]))
        }, LiveWire.finish as CFString, nil, .deliverImmediately)
    }

    override func processSampleBuffer(_ sampleBuffer: CMSampleBuffer, with sampleBufferType: RPSampleBufferType) {
        guard sampleBufferType == .video, let pb = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        var orient = CGImagePropertyOrientation.up
        if let n = CMGetAttachment(sampleBuffer, key: RPVideoSampleOrientationKey as CFString, attachmentModeOut: nil) as? NSNumber,
           let o = CGImagePropertyOrientation(rawValue: n.uint32Value) {
            orient = o
        }
        store.keep(pb, orient)
    }

    private func ring(_ name: String) {
        CFNotificationCenterPostNotification(CFNotificationCenterGetDarwinNotifyCenter(), CFNotificationName(name as CFString), nil, nil, true)
    }
}

/// 最新一帧（只是引用；ReplayKit 的缓冲池够用，留一个不卡它）
final class FrameStore: @unchecked Sendable {
    private let lock = NSLock()
    private var buffer: CVPixelBuffer?
    private var orient = CGImagePropertyOrientation.up
    private lazy var context = CIContext(options: [.cacheIntermediates: false])

    func keep(_ pb: CVPixelBuffer, _ o: CGImagePropertyOrientation) {
        lock.lock(); buffer = pb; orient = o; lock.unlock()
    }

    func clear() {
        lock.lock(); buffer = nil; lock.unlock()
    }

    /// 转正、缩到 Opus 5.5 会用的尺寸（长边 2576、视觉 token 4784），JPEG 0.8
    func jpeg() -> Data? {
        lock.lock()
        let pb = buffer, o = orient
        lock.unlock()
        guard let pb else { return nil }
        let img = CIImage(cvPixelBuffer: pb).oriented(o)
        let ext = img.extent
        let (w, h) = BrainImage.resizedSize(Int(ext.width), Int(ext.height))
        var out = img
        if w != Int(ext.width) {
            let f = CIFilter.lanczosScaleTransform()
            f.inputImage = img
            f.scale = Float(Double(h) / Double(ext.height))
            f.aspectRatio = Float((Double(w) / Double(ext.width)) / (Double(h) / Double(ext.height)))
            if let o = f.outputImage { out = o }
        }
        out = out.transformed(by: CGAffineTransform(translationX: -out.extent.origin.x, y: -out.extent.origin.y))
        let cs = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
        let q = CIImageRepresentationOption(rawValue: kCGImageDestinationLossyCompressionQuality as String)
        return context.jpegRepresentation(of: out, colorSpace: cs, options: [q: 0.8])
    }
}

/// 127.0.0.1 上的口子：一问一答（「YIYE1 口令 编号」→ 状态 + 长度 + JPEG），答完就关。
/// 只认这一回直播里第一个报上来的口令（主 App 开播时马上来认领）；口令不对的回 refused。
final class FrameServer: @unchecked Sendable {
    private let q = DispatchQueue(label: "lab.qianshou.yiye.live.server")
    private let store: FrameStore
    private var listener: NWListener?
    private var gate = LiveWire.Gate()
    private var running = false

    init(store: FrameStore) { self.store = store }

    func start() {
        q.async {
            self.running = true
            self.listen()
        }
    }

    func stop() {
        q.async {
            self.running = false
            self.listener?.cancel()
            self.listener = nil
        }
    }

    private func listen() {
        guard running, let port = NWEndpoint.Port(rawValue: LiveWire.port) else { return }
        let params = NWParameters.tcp
        params.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: port)
        params.allowLocalEndpointReuse = true
        params.acceptLocalOnly = true
        guard let l = try? NWListener(using: params) else { return retry() }
        l.newConnectionHandler = { [weak self] c in self?.serve(c) }
        l.stateUpdateHandler = { [weak self] st in
            if case .failed = st { self?.q.async { self?.listener?.cancel(); self?.listener = nil; self?.retry() } }
        }
        listener = l
        l.start(queue: q)
    }

    private func retry() {
        q.asyncAfter(deadline: .now() + 1) { [weak self] in
            guard let self, self.running, self.listener == nil else { return }
            self.listen()
        }
    }

    private func serve(_ c: NWConnection) {
        c.start(queue: q)
        read(c, Data())
        q.asyncAfter(deadline: .now() + 5) { c.cancel() }
    }

    private func read(_ c: NWConnection, _ got: Data) {
        c.receive(minimumIncompleteLength: 1, maximumLength: 256) { [weak self] data, _, done, err in
            guard let self else { return }
            var all = got
            if let data { all.append(data) }
            if all.last == 0x0a || all.count >= 256 || done || err != nil {
                self.answer(c, all)
            } else {
                self.read(c, all)
            }
        }
    }

    private func answer(_ c: NWConnection, _ line: Data) {
        let out: Data
        if let r = LiveWire.parseRequest(line) {
            if !gate.allow(r.token) {
                out = LiveWire.reply(.refused)
            } else if r.id == "hello" {
                out = LiveWire.reply(.none)
            } else if let j = store.jpeg(), j.count <= LiveWire.maxFrame {
                out = LiveWire.reply(.frame, jpeg: j)
            } else {
                out = LiveWire.reply(.none)
            }
        } else {
            out = LiveWire.reply(.refused)
        }
        c.send(content: out, completion: .contentProcessed { _ in c.cancel() })
    }
}
