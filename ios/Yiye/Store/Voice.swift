import AVFoundation
import MediaPlayer
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

/// 一篇能放的：哪条笔记、哪段录音、标题、每句表
struct Track: Equatable {
    var note: UUID
    var path: String
    var title: String
    var marks: [ListenMark]
}

/// 放录音：同一时间只放一段。
/// 写字页的播放条：放一遍就停。听力播放列表：每篇放几遍（1/2/3/5/一直），放够了自动下一篇；倍速；原文里能锁住一句反复听。
/// 锁屏、耳机按键也能控制（反复听英语用）
@MainActor @Observable
final class AudioPlayback {
    static let shared = AudioPlayback()

    var current: String?
    var playing = false
    var position: TimeInterval = 0
    var duration: TimeInterval = 0
    var rate: Float = 1 { didSet { player?.rate = rate; nowPlaying() } }

    /// 播放列表（写字页那条只放一篇的，列表里就它一个）
    var queue: [Track] = []
    var index = 0
    /// 列表模式：每篇放几遍（0 = 一直放）
    var repeatTarget = 3
    /// 这篇已经放完几遍
    var passes = 0
    var playlist = false
    /// 单句循环：锁在哪一句（nil = 不锁）
    var locked: Int?
    /// 整串循环（112）：最后一条放完回到第一条
    var loopAll = false
    /// 一篇第一次完整放完一遍（112：记 heardAt）
    @ObservationIgnored var onHeard: ((UUID) -> Void)?

    var track: Track? { queue.indices.contains(index) ? queue[index] : nil }
    var marks: [ListenMark] { track?.marks ?? [] }
    var sentence: Int? { Listen.index(at: position, in: marks) }

    @ObservationIgnored private var player: AVAudioPlayer?
    @ObservationIgnored private var store: AttachmentStore?
    @ObservationIgnored private var tick: Task<Void, Never>?
    @ObservationIgnored private var durations: [String: TimeInterval] = [:]
    @ObservationIgnored private var remoteReady = false
    @ObservationIgnored private let delegate = PlayerDelegate()

    /// 文件换过了（重新念的），时长别用老的
    func forget(_ name: String) {
        for k in durations.keys where k.hasSuffix(name) { durations[k] = nil }
    }

    func duration(_ rel: String, store: AttachmentStore) -> TimeInterval {
        if let d = durations[rel] { return d }
        let d = (try? AVAudioPlayer(contentsOf: store.url(rel)))?.duration ?? 0
        durations[rel] = d
        return d
    }

    /// 写字页播放条上的那个钮：没在放这段就从头放（放一遍），在放就暂停 / 接着放
    func toggle(_ rel: String, store: AttachmentStore, note: UUID? = nil, marks: [ListenMark] = [], title: String = "") {
        if current == rel, player != nil { playing ? pause() : resume(); return }
        playlist = false
        queue = [Track(note: note ?? UUID(), path: rel, title: title, marks: marks)]
        index = 0
        load(store: store, at: 0, play: true)
    }

    /// 听力播放列表：从第 i 篇开始
    func play(_ tracks: [Track], from i: Int, store: AttachmentStore) {
        guard tracks.indices.contains(i) else { return }
        playlist = true
        queue = tracks
        index = i
        load(store: store, at: 0, play: true)
    }

    private func load(store: AttachmentStore, at time: TimeInterval, play: Bool) {
        tick?.cancel()
        player?.stop()
        self.store = store
        guard let t = track else { stop(); return }
        do {
            try AVAudioSession.sharedInstance().setCategory(.playback, mode: .spokenAudio)
            try AVAudioSession.sharedInstance().setActive(true)
            let p = try AVAudioPlayer(contentsOf: store.url(t.path))
            p.enableRate = true
            p.rate = rate
            p.delegate = delegate
            delegate.onFinish = { [weak self] in self?.finishedOnce() }
            p.prepareToPlay()
            p.currentTime = max(0, min(time, p.duration))
            player = p
            current = t.path
            duration = p.duration
            durations[t.path] = p.duration
            position = p.currentTime
            passes = 0
            locked = nil
            if play { p.play(); playing = true } else { playing = false }
            setUpRemote()
            nowPlaying()
            startTick()
        } catch {
            // 这篇放不了：列表里就跳下一篇
            if playlist, index + 1 < queue.count { index += 1; load(store: store, at: 0, play: play) } else { stop() }
        }
    }

    func pause() {
        player?.pause()
        playing = false
        nowPlaying()
    }

    func resume() {
        guard let p = player else { return }
        p.play()
        playing = true
        nowPlaying()
        startTick()
    }

    func seek(_ rel: String, to fraction: Double, store: AttachmentStore) {
        guard current == rel, let player else { return }
        player.currentTime = max(0, min(1, fraction)) * player.duration
        position = player.currentTime
        if locked != nil { locked = sentence }
        nowPlaying()
    }

    /// 跳到第 i 句；单句循环开着就锁到这句
    func jump(to i: Int) {
        guard let player, marks.indices.contains(i) else { return }
        player.currentTime = marks[i].t
        position = player.currentTime
        if locked != nil { locked = i }
        if !playing { resume() } else { nowPlaying() }
    }

    /// 单句循环开关：开就锁在正在放的这句
    func toggleSentenceLoop() {
        locked = locked == nil ? (sentence ?? 0) : nil
    }

    func nextTrack() {
        guard let store, index + 1 < queue.count else { return }
        index += 1
        load(store: store, at: 0, play: true)
    }

    func previousTrack() {
        guard let store else { return }
        if position > 3 || index == 0 { player?.currentTime = 0; position = 0; passes = 0; if !playing { resume() }; nowPlaying(); return }
        index -= 1
        load(store: store, at: 0, play: true)
    }

    func nextSentence() {
        guard !marks.isEmpty else { return }
        let i = (locked ?? sentence ?? -1) + 1
        if marks.indices.contains(i) { jump(to: i) }
    }

    func previousSentence() {
        guard !marks.isEmpty else { return }
        let cur = locked ?? sentence ?? 0
        let i = position - marks[cur].t < 1.0 ? max(0, cur - 1) : cur
        jump(to: i)
    }

    func stop() {
        tick?.cancel()
        player?.stop()
        player = nil
        current = nil
        playing = false
        position = 0
        locked = nil
        passes = 0
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
    }

    /// 放完一遍：列表模式按遍数重来或下一篇；写字页那条放完就停
    private func finishedOnce() {
        guard let store, let p = player else { return }
        passes += 1
        if passes == 1, let t = track { onHeard?(t.note) }
        if playlist, repeatTarget == 0 || passes < repeatTarget {
            p.currentTime = 0
            position = 0
            p.play()
            nowPlaying()
            return
        }
        if playlist, let next = ListenRule.nextIndex(after: index, count: queue.count, loopAll: loopAll) {
            index = next
            load(store: store, at: 0, play: true)
            return
        }
        playing = false
        position = 0
        p.currentTime = 0
        nowPlaying()
    }

    private func startTick() {
        tick?.cancel()
        tick = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 50_000_000)
                guard let self, let p = self.player else { return }
                // 单句循环：到这句结尾就回到这句开头
                if let i = self.locked, self.playing {
                    let span = Listen.span(i, in: self.marks, duration: p.duration)
                    if p.currentTime >= span.end - 0.03 || !p.isPlaying {
                        p.currentTime = span.start
                        if !p.isPlaying { p.play() }
                    }
                }
                self.position = p.currentTime
                if !self.playing && !p.isPlaying { return }
            }
        }
    }

    // ---------------------------------------------------------------- 锁屏、耳机
    private func nowPlaying() {
        guard let player else { return }
        MPNowPlayingInfoCenter.default().nowPlayingInfo = [
            MPMediaItemPropertyTitle: (track?.title).flatMap { $0.isEmpty ? nil : $0 } ?? "Yiye",
            MPMediaItemPropertyPlaybackDuration: player.duration,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: player.currentTime,
            MPNowPlayingInfoPropertyPlaybackRate: playing ? Double(rate) : 0.0,
        ]
    }

    private func setUpRemote() {
        guard !remoteReady else { return }
        remoteReady = true
        let c = MPRemoteCommandCenter.shared()
        c.playCommand.addTarget { [weak self] _ in MainActor.assumeIsolated { self?.resume() }; return .success }
        c.pauseCommand.addTarget { [weak self] _ in MainActor.assumeIsolated { self?.pause() }; return .success }
        c.togglePlayPauseCommand.addTarget { [weak self] _ in
            MainActor.assumeIsolated { if self?.playing == true { self?.pause() } else { self?.resume() } }
            return .success
        }
        // 耳机按两下 / 锁屏的下一首：列表里跳下一篇；只有一篇时跳下一句
        c.nextTrackCommand.addTarget { [weak self] _ in
            MainActor.assumeIsolated { guard let self else { return }; if self.queue.count > 1 { self.nextTrack() } else { self.nextSentence() } }
            return .success
        }
        c.previousTrackCommand.addTarget { [weak self] _ in
            MainActor.assumeIsolated { guard let self else { return }; if self.queue.count > 1 { self.previousTrack() } else { self.previousSentence() } }
            return .success
        }
        c.changePlaybackPositionCommand.addTarget { [weak self] e in
            guard let e = e as? MPChangePlaybackPositionCommandEvent else { return .commandFailed }
            MainActor.assumeIsolated {
                guard let self, let p = self.player else { return }
                p.currentTime = e.positionTime
                self.position = p.currentTime
                self.nowPlaying()
            }
            return .success
        }
    }
}

/// AVAudioPlayer 放完的回调（在别的线程来）转回主线程
final class PlayerDelegate: NSObject, AVAudioPlayerDelegate, @unchecked Sendable {
    var onFinish: (@MainActor () -> Void)?
    func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        let f = onFinish
        Task { @MainActor in f?() }
    }
}
