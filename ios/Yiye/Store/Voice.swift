import AVFoundation
import Speech
import YiyeKit

/// 录一段：话筒 → 一边写 .m4a，一边喂给手机本机的 SpeechAnalyzer 转字（iOS 26 新接口，不上传）。
/// 认字用 SpeechTranscriber；这台手机没有它（或不认这个语言）就退到 DictationTranscriber。认不了也照样录音。
@MainActor @Observable
final class VoiceRecorder {
    enum Phase: Equatable { case idle, preparing, recording, finishing, denied, failed(String) }

    var phase: Phase = .idle
    /// 定稿的一段段
    var finals: [String] = []
    /// 还在变的那一段
    var volatile = ""
    /// 最近一串音量（0…1），画跳动的竖条
    var levels: [Float] = Array(repeating: 0, count: 28)
    var elapsed: TimeInterval = 0
    /// 一句状态：第一次下载语音模型、这回只录音……
    var note: String?

    var text: String { VoiceText.join(finals + [volatile]) }

    let url = FileManager.default.temporaryDirectory.appendingPathComponent("yiye-rec-\(UUID().uuidString).m4a")

    @ObservationIgnored private var engine: AVAudioEngine?
    @ObservationIgnored private var sink: TapSink?
    @ObservationIgnored private var analyzer: SpeechAnalyzer?
    @ObservationIgnored private var feed: AsyncStream<AnalyzerInput>.Continuation?
    @ObservationIgnored private var analyzeTask: Task<CMTime?, Never>?
    @ObservationIgnored private var resultsTask: Task<Void, Never>?
    @ObservationIgnored private var clockTask: Task<Void, Never>?
    @ObservationIgnored private var startedAt: Date?

    /// 截图用：摆一个录到一半的样子
    func fake(text: [String], seconds: TimeInterval) {
        finals = text
        elapsed = seconds
        levels = (0..<28).map { i in Float(0.25 + 0.55 * abs(sin(Double(i) * 0.7))) }
        phase = .recording
    }

    func start(languageID: String, t: Lang) async {
        guard phase == .idle else { return }
        phase = .preparing
        guard await AVAudioApplication.requestRecordPermission() else { phase = .denied; return }
        let auth = await withCheckedContinuation { (c: CheckedContinuation<SFSpeechRecognizerAuthorizationStatus, Never>) in
            SFSpeechRecognizer.requestAuthorization { c.resume(returning: $0) }
        }

        // 认字的模块（不行就只录音）
        var module: (any SpeechModule)?
        var format: AVAudioFormat?
        if auth == .authorized || auth == .notDetermined {
            module = await Self.makeModule(Locale(identifier: languageID))
            if let m = module {
                do {
                    if let req = try await AssetInventory.assetInstallationRequest(supporting: [m]) {
                        note = t.t("voice.model")
                        try await req.downloadAndInstall()
                        note = nil
                    }
                    format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [m])
                } catch {
                    module = nil
                    note = t.f("voice.noModel", error.localizedDescription)
                }
            } else {
                note = t.t("voice.noLang")
            }
        } else {
            note = t.t("voice.noSpeech")
        }

        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playAndRecord, mode: .default, options: [.defaultToSpeaker])
            try session.setActive(true)
            let engine = AVAudioEngine()
            let input = engine.inputNode
            let inFormat = input.outputFormat(forBus: 0)
            let file = try AVAudioFile(forWriting: url, settings: [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: inFormat.sampleRate,
                AVNumberOfChannelsKey: inFormat.channelCount,
                AVEncoderBitRateKey: 64_000,
            ], commonFormat: .pcmFormatFloat32, interleaved: false)

            var cont: AsyncStream<AnalyzerInput>.Continuation?
            if let module, let format {
                let (stream, c) = AsyncStream<AnalyzerInput>.makeStream()
                cont = c
                let analyzer = SpeechAnalyzer(modules: [module])
                self.analyzer = analyzer
                analyzeTask = Task {
                    let last = try? await analyzer.analyzeSequence(stream)
                    return last
                }
                resultsTask = Task { [weak self] in await self?.collect(module) }
            }
            feed = cont
            let sink = TapSink(file: file, from: inFormat, to: cont == nil ? nil : format, feed: cont) { [weak self] v in
                Task { @MainActor in self?.push(level: v) }
            }
            self.sink = sink
            input.installTap(onBus: 0, bufferSize: 4096, format: inFormat) { buf, _ in sink.handle(buf) }
            engine.prepare()
            try engine.start()
            self.engine = engine
            startedAt = Date()
            phase = .recording
            clockTask = Task { [weak self] in
                while !Task.isCancelled {
                    try? await Task.sleep(nanoseconds: 200_000_000)
                    guard let self, let s = self.startedAt else { return }
                    self.elapsed = Date().timeIntervalSince(s)
                }
            }
        } catch {
            stopAudio()
            phase = .failed(error.localizedDescription)
        }
    }

    /// 说完了：停话筒、等最后一段字定稿，交出录音文件和字
    func finish() async -> (url: URL, text: String, seconds: TimeInterval)? {
        guard phase == .recording else { return nil }
        phase = .finishing
        let seconds = elapsed
        stopAudio()
        feed?.finish()
        feed = nil
        if let analyzer, let analyzeTask {
            let last = await analyzeTask.value
            if let last { try? await analyzer.finalizeAndFinish(through: last) } else { await analyzer.cancelAndFinishNow() }
            await resultsTask?.value
        }
        volatile = ""
        phase = .idle
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        return (url, VoiceText.join(finals), seconds)
    }

    /// 不要了：停下、删掉录音
    func cancel() {
        stopAudio()
        feed?.finish()
        feed = nil
        if let analyzer { Task { await analyzer.cancelAndFinishNow() } }
        resultsTask?.cancel()
        try? FileManager.default.removeItem(at: url)
        phase = .idle
    }

    private func stopAudio() {
        clockTask?.cancel()
        clockTask = nil
        if let engine {
            engine.inputNode.removeTap(onBus: 0)
            engine.stop()
        }
        engine = nil
        sink = nil   // AVAudioFile 跟着释放，文件写完
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    private func push(level v: Float) {
        guard phase == .recording else { return }
        levels.removeFirst()
        levels.append(v)
    }

    private func got(_ s: String, final: Bool) {
        if final { finals.append(s); volatile = "" } else { volatile = s }
    }

    private func collect(_ module: any SpeechModule) async {
        do {
            if let m = module as? SpeechTranscriber {
                for try await r in m.results { got(String(r.text.characters), final: r.isFinal) }
            } else if let m = module as? DictationTranscriber {
                for try await r in m.results { got(String(r.text.characters), final: r.isFinal) }
            }
        } catch {
            note = error.localizedDescription
        }
    }

    /// 先用 SpeechTranscriber（新、长段落好），没有就用 DictationTranscriber
    static func makeModule(_ locale: Locale) async -> (any SpeechModule)? {
        if SpeechTranscriber.isAvailable, let loc = await SpeechTranscriber.supportedLocale(equivalentTo: locale) {
            return SpeechTranscriber(locale: loc, preset: .progressiveTranscription)
        }
        if let loc = await DictationTranscriber.supportedLocale(equivalentTo: locale) {
            return DictationTranscriber(locale: loc, preset: .progressiveLongDictation)
        }
        return nil
    }
}

/// 话筒回调在音频线程上跑：写文件、算音量、转成认字要的格式喂进去。不碰主线程的东西
final class TapSink: @unchecked Sendable {
    private let file: AVAudioFile
    private let converter: AVAudioConverter?
    private let outFormat: AVAudioFormat?
    private let feed: AsyncStream<AnalyzerInput>.Continuation?
    private let onLevel: @Sendable (Float) -> Void

    init(file: AVAudioFile, from: AVAudioFormat, to: AVAudioFormat?, feed: AsyncStream<AnalyzerInput>.Continuation?, onLevel: @escaping @Sendable (Float) -> Void) {
        self.file = file
        self.outFormat = to
        self.converter = to.flatMap { AVAudioConverter(from: from, to: $0) }
        self.feed = feed
        self.onLevel = onLevel
    }

    func handle(_ buffer: AVAudioPCMBuffer) {
        try? file.write(from: buffer)
        if let ch = buffer.floatChannelData?[0], buffer.frameLength > 0 {
            var sum: Float = 0
            for i in 0..<Int(buffer.frameLength) { sum += ch[i] * ch[i] }
            let rms = sqrt(sum / Float(buffer.frameLength))
            let db = 20 * log10(max(rms, 1e-6))
            onLevel(min(1, max(0, (db + 55) / 45)))
        }
        guard let converter, let outFormat, let feed else { return }
        let cap = AVAudioFrameCount(Double(buffer.frameLength) * outFormat.sampleRate / buffer.format.sampleRate) + 64
        guard let out = AVAudioPCMBuffer(pcmFormat: outFormat, frameCapacity: cap) else { return }
        var given = false
        var err: NSError?
        converter.convert(to: out, error: &err) { _, status in
            if given { status.pointee = .noDataNow; return nil }
            given = true
            status.pointee = .haveData
            return buffer
        }
        if err == nil, out.frameLength > 0 { feed.yield(AnalyzerInput(buffer: out)) }
    }
}

/// 写字页上面的播放条：同一时间只放一段
@MainActor @Observable
final class AudioPlayback {
    static let shared = AudioPlayback()

    var current: String?
    var playing = false
    var position: TimeInterval = 0

    @ObservationIgnored private var player: AVAudioPlayer?
    @ObservationIgnored private var tick: Task<Void, Never>?
    @ObservationIgnored private var durations: [String: TimeInterval] = [:]

    func duration(_ rel: String, store: AttachmentStore) -> TimeInterval {
        if let d = durations[rel] { return d }
        let d = (try? AVAudioPlayer(contentsOf: store.url(rel)))?.duration ?? 0
        durations[rel] = d
        return d
    }

    func toggle(_ rel: String, store: AttachmentStore) {
        if current == rel, let player {
            if player.isPlaying { player.pause(); playing = false } else { player.play(); playing = true; startTick() }
            return
        }
        stop()
        do {
            try AVAudioSession.sharedInstance().setCategory(.playback, mode: .spokenAudio)
            try AVAudioSession.sharedInstance().setActive(true)
            let p = try AVAudioPlayer(contentsOf: store.url(rel))
            p.play()
            player = p
            current = rel
            playing = true
            position = 0
            startTick()
        } catch {
            stop()
        }
    }

    func seek(_ rel: String, to fraction: Double, store: AttachmentStore) {
        guard current == rel, let player else { return }
        player.currentTime = max(0, min(1, fraction)) * player.duration
        position = player.currentTime
    }

    func stop() {
        tick?.cancel()
        player?.stop()
        player = nil
        current = nil
        playing = false
        position = 0
    }

    private func startTick() {
        tick?.cancel()
        tick = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 100_000_000)
                guard let self, let p = self.player else { return }
                self.position = p.currentTime
                if !p.isPlaying && self.playing {
                    // 放完了
                    self.playing = false
                    if p.currentTime == 0 || p.currentTime >= p.duration - 0.05 { self.position = 0 }
                    return
                }
            }
        }
    }
}
