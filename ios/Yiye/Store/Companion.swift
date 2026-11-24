import AVFoundation
import Network
import Observation
import Speech
import UIKit
import YiyeKit

/// 陪玩模式（pc-butler 施工单 100，Song 11-24 10:07）：
/// 「像游戏陪玩那样，打开以后它能实时读我的屏幕，然后可以实时问它问题，它可以实时做出反馈」「主要是一些英文内容，我不太看得懂」。
/// - 104（Song 11-24）：没有「陪玩模式」开关了。工具栏耳机右边一个小图标，点一下弹苹果的直播面板选一叶笺（苹果规定这一下要人点）；开了直播就算开，停了直播就算关。之后全自动。
/// - 直播开着就在后台听（后台音频）：本机判断开口、说完（停 0.8 秒），苹果本机听写成字（不上传），
///   去直播扩展取问的那一刻的一帧，走信箱（两头加密）交给大管家；大管家看图答话、配好音回来，直接放（别的 App 的声音压低）。
/// - 两台大管家都不在：用苹果的中文嗓子念「大管家不在」。关掉陪玩、停了直播：马上停听、停截。
/// - 截到的屏幕只在开口那一刻取一帧，只交自己的大管家，不存。
@MainActor @Observable
final class Companion {
    enum Phase: Equatable { case off, listening, hearing, asking, speaking, failed(String) }

    private(set) var phase: Phase = .off
    /// 直播扩展在跑（回环口子能连上）
    private(set) var live = false
    /// 上一问从说完到出声几秒
    private(set) var lastTotal: Double?

    @ObservationIgnored weak var app: AppModel?
    @ObservationIgnored private let bell = LiveBell()
    @ObservationIgnored private var ear: Ear?
    @ObservationIgnored private var current: String?
    @ObservationIgnored private var clock: LookClock?
    @ObservationIgnored private var prev: [String: Double] = [:]
    @ObservationIgnored private var probeTimer: Timer?
    @ObservationIgnored private var startedAt: Date?
    @ObservationIgnored private var batteryAtStart: Float?

    /// 开着陪玩、在听：后台也别断信箱
    var holdsButler: Bool { ear != nil }

    static let saysAway = "大管家不在"
    static let saysNoPair = "还没配大管家的信箱"
    static let saysNoMail = "信箱连不上"
    static let saysNoAnswer = "大管家没回，再问一次？"
    static let saysFailed = "大管家这回没答上来"

    func setUp() {
        bell.onRing = { [weak self] name in self?.ring(name) }
        Task { await probe() }          // 开 app 时直播要是已经在跑，接着听
    }

    // ---------------------------------------------------------------- 直播在不在
    private func ring(_ name: String) {
        if name == LiveWire.started {
            live = true
            Task {
                _ = await LiveLink.fetch("hello")          // 先把口子认领下来
                self.startListening()
            }
        } else if name == LiveWire.stopped {
            liveGone()
        }
    }

    private func probe() async {
        let r = await LiveLink.fetch("hello")
        if case .down = r {
            if live || ear != nil { liveGone() }
            return
        }
        live = true
        if ear == nil { startListening() }
    }

    private func liveGone() {
        live = false
        stopListening()
        phase = .off
    }

    // ---------------------------------------------------------------- 听
    private func startListening() {
        guard ear == nil, let app, app.demo == nil else { return }
        Task {
            guard await AVAudioApplication.requestRecordPermission() else { return self.fail(app.lang.t("companion.noMic")) }
            let auth = await withCheckedContinuation { (c: CheckedContinuation<SFSpeechRecognizerAuthorizationStatus, Never>) in
                SFSpeechRecognizer.requestAuthorization { c.resume(returning: $0) }
            }
            guard auth == .authorized else { return self.fail(app.lang.t("companion.noMic")) }
            guard self.ear == nil, self.live else { return }
            let ear = Ear(locale: "zh-CN")
            ear.onStart = { [weak self] in Task { @MainActor in self?.heardStart() } }
            ear.onHeard = { [weak self] text, end in Task { @MainActor in self?.heard(text, spokeEnd: end) } }
            ear.onDrop = { [weak self] in Task { @MainActor in self?.backToListening() } }
            do {
                try ear.start()
            } catch {
                ear.stop()
                return self.fail(error.localizedDescription)
            }
            self.ear = ear
            self.phase = .listening
            self.startedAt = Date()
            UIDevice.current.isBatteryMonitoringEnabled = true
            self.batteryAtStart = UIDevice.current.batteryLevel
            self.app?.butler.start()
            self.app?.butler.lookWarm()
            self.probeTimer?.invalidate()
            let t = Timer(timeInterval: 15, repeats: true) { [weak self] _ in Task { @MainActor in await self?.probe() } }
            RunLoop.main.add(t, forMode: .common)
            self.probeTimer = t
        }
    }

    private func stopListening() {
        probeTimer?.invalidate()
        probeTimer = nil
        ear?.stop()
        ear = nil
        if let id = current { app?.butler.forgetLook(id) }
        current = nil
        clock = nil
        if UIApplication.shared.applicationState == .background { app?.butler.stop() }
    }

    private func fail(_ why: String) {
        stopListening()
        phase = .failed(why)
        if let app { app.show(app.lang.f("companion.failed", why), seconds: 6) }    // 出错弹一次，不留条
    }

    private func heardStart() {
        if phase == .listening { phase = .hearing }
    }

    private func backToListening() {
        if phase == .hearing { phase = .listening }
    }

    // ---------------------------------------------------------------- 问
    private func heard(_ text: String, spokeEnd: Double) {
        let q = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard ear != nil, let app else { return }
        guard q.count >= 2 else { return backToListening() }
        let id = UUID().uuidString
        if let old = current { app.butler.forgetLook(old) }
        current = id
        var c = LookClock(spokeEnd: spokeEnd)
        c.heard = ProcessInfo.processInfo.systemUptime
        clock = c
        phase = .asking
        var prevNow = prev
        UIDevice.current.isBatteryMonitoringEnabled = true
        let bat = UIDevice.current.batteryLevel
        if bat >= 0 { prevNow["bat"] = Double((bat * 100).rounded()) }
        if let b0 = batteryAtStart, b0 >= 0 { prevNow["bat0"] = Double((b0 * 100).rounded()) }
        if let s = startedAt { prevNow["mins"] = (Date().timeIntervalSince(s) / 60 * 10).rounded() / 10 }
        prev = [:]
        let prevSend = prevNow
        Task {
            var files: [String: Data] = [:]
            var path: String?
            if self.live {
                switch await LiveLink.fetch(id) {
                case .frame(let d):
                    let p = "陪玩/\(id.prefix(8))-屏.jpg"
                    files[p] = d
                    path = p
                case .down:
                    self.live = false
                default:
                    break
                }
            }
            guard self.current == id else { return }
            self.clock?.frame = ProcessInfo.processInfo.systemUptime
            let req = ButlerRequest.look(id: id, question: q, image: path, at: ISOTime.string(Date()), app: ButlerService.appVersion, prev: prevSend)
            let r = await app.butler.sendLook(req, files: files)
            guard self.current == id else { return }
            self.clock?.sent = ProcessInfo.processInfo.systemUptime
            switch r {
            case .sent(true):
                try? await Task.sleep(nanoseconds: 45_000_000_000)
                if self.current == id, self.phase == .asking { self.giveUp(id, Companion.saysNoAnswer) }
            case .sent(false): self.giveUp(id, Companion.saysAway)
            case .noPair: self.giveUp(id, Companion.saysNoPair)
            case .failed: self.giveUp(id, Companion.saysNoMail)
            }
            if !self.live { self.liveGone() }
        }
    }

    private func giveUp(_ id: String, _ words: String) {
        app?.butler.forgetLook(id)
        current = nil
        speak(words)
    }

    /// 大管家的回答到了（ButlerService 收信时叫）
    func answer(_ r: ButlerResult, audio: Data?) {
        guard r.id == current, let ear else { return }
        current = nil
        clock?.back = ProcessInfo.processInfo.systemUptime
        phase = .speaking
        let done: @Sendable () -> Void = { [weak self] in Task { @MainActor in self?.played() } }
        let started: @Sendable () -> Void = { [weak self] in Task { @MainActor in self?.playing(r.timing ?? [:]) } }
        if let audio, ear.play(audio, started: started, done: done) { return }
        let words = (r.text?.isEmpty == false ? r.text : nil) ?? Companion.saysFailed
        ear.speak(words, voice: PhoneVoice.bestVoice("zh-CN"), started: started, done: done)
    }

    private func playing(_ butler: [String: Double]) {
        guard var c = clock else { return }
        c.playing = ProcessInfo.processInfo.systemUptime
        prev = c.summary(butler: butler)
        lastTotal = prev["total"]
        clock = nil
    }

    private func speak(_ words: String) {
        guard let ear else { return }
        phase = .speaking
        clock = nil
        ear.speak(words, voice: PhoneVoice.bestVoice("zh-CN"), started: {}, done: { [weak self] in Task { @MainActor in self?.played() } })
    }

    private func played() {
        if ear != nil, phase == .speaking { phase = .listening }
    }
}

// ================================================================ 门铃：扩展开播、停播
final class LiveBell: @unchecked Sendable {
    var onRing: (@MainActor (String) -> Void)?

    init() {
        let center = CFNotificationCenterGetDarwinNotifyCenter()
        let me = Unmanaged.passUnretained(self).toOpaque()
        for n in [LiveWire.started, LiveWire.stopped] {
            CFNotificationCenterAddObserver(center, me, { _, observer, name, _, _ in
                guard let observer, let name else { return }
                let bell = Unmanaged<LiveBell>.fromOpaque(observer).takeUnretainedValue()
                let s = name.rawValue as String
                DispatchQueue.main.async { MainActor.assumeIsolated { bell.onRing?(s) } }
            }, n as CFString, nil, .deliverImmediately)
        }
    }

    static func post(_ name: String) {
        CFNotificationCenterPostNotification(CFNotificationCenterGetDarwinNotifyCenter(), CFNotificationName(name as CFString), nil, nil, true)
    }
}

// ================================================================ 回环：去扩展取一帧
enum LiveFetch: Equatable { case frame(Data), noFrame, refused, down }

enum LiveLink {
    /// 主 App 的口令：装上以后随机一次，一直用它（扩展只认开播后第一个报上来的）
    static var token: String {
        let k = "yiye.liveToken"
        if let t = UserDefaults.standard.string(forKey: k), t.count == 32 { return t }
        let t = UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
        UserDefaults.standard.set(t, forKey: k)
        return t
    }

    /// 包里的直播扩展（SideStore 重签时会改 bundle id，所以现找）
    static var extensionID: String? {
        guard let dir = Bundle.main.builtInPlugInsURL,
              let items = try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) else { return nil }
        for u in items where u.pathExtension == "appex" {
            guard let b = Bundle(url: u), let ext = b.object(forInfoDictionaryKey: "NSExtension") as? [String: Any],
                  (ext["NSExtensionPointIdentifier"] as? String) == "com.apple.broadcast-services-upload" else { continue }
            return b.bundleIdentifier
        }
        return nil
    }

    static func fetch(_ id: String, timeout: TimeInterval = 1.5) async -> LiveFetch {
        guard let port = NWEndpoint.Port(rawValue: LiveWire.port) else { return .down }
        let token = self.token
        return await withCheckedContinuation { (cont: CheckedContinuation<LiveFetch, Never>) in
            let q = DispatchQueue(label: "lab.qianshou.yiye.livelink")
            let c = NWConnection(host: NWEndpoint.Host(LiveWire.host), port: port, using: .tcp)
            let once = Once()
            let finish: @Sendable (LiveFetch) -> Void = { r in
                guard once.take() else { return }
                c.cancel()
                cont.resume(returning: r)
            }
            c.stateUpdateHandler = { st in
                switch st {
                case .ready:
                    c.send(content: LiveWire.request(token: token, id: id), completion: .contentProcessed { e in
                        if e != nil { finish(.down) }
                    })
                    LiveLink.read(c, Data()) { data in
                        guard let data, let head = LiveWire.parseHead(data) else { return finish(.down) }
                        let (s, n) = head
                        switch s {
                        case .frame: finish(n > 0 ? .frame(Data(data.dropFirst(5).prefix(n))) : .noFrame)
                        case .none: finish(.noFrame)
                        case .refused: finish(.refused)
                        }
                    }
                case .failed, .waiting, .cancelled:
                    finish(.down)
                default:
                    break
                }
            }
            c.start(queue: q)
            q.asyncAfter(deadline: .now() + timeout) { finish(.down) }
        }
    }

    private static func read(_ c: NWConnection, _ got: Data, _ done: @escaping @Sendable (Data?) -> Void) {
        c.receive(minimumIncompleteLength: 1, maximumLength: 1 << 20) { data, _, complete, err in
            var all = got
            if let data { all.append(data) }
            if all.count >= 5 {
                guard let head = LiveWire.parseHead(all) else { return done(nil) }
                if all.count >= 5 + head.1 { return done(all) }
            }
            if complete || err != nil { return done(nil) }
            LiveLink.read(c, all, done)
        }
    }
}

final class Once: @unchecked Sendable {
    private let lock = NSLock()
    private var done = false
    func take() -> Bool {
        lock.lock(); defer { lock.unlock() }
        if done { return false }
        done = true
        return true
    }
}

// ================================================================ 耳朵和嘴：话筒、听写、放回答
/// 一个 AVAudioEngine 从开到关一直跑着（后台不能重新开话筒，所以不停）：
/// - 话筒开回声消除（voice processing），别的 App 的声音在有人说话时压低（advanced ducking），自己放的回答不会被自己听进去；
/// - 每一小块算分贝交给 VoiceGate；开口了就开一个本机听写（zh-CN，requiresOnDeviceRecognition），开口前 0.3 秒一起喂进去；
/// - 说完：收尾，等定稿（最多 2 秒，没定稿用最后一版）交出去；
/// - 放回答、念一句的时候不判开口（mute），放完再等 0.3 秒。
final class Ear: @unchecked Sendable {
    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private let playFormat = AVAudioFormat(standardFormatWithSampleRate: 24_000, channels: 1)!
    private let recognizer: SFSpeechRecognizer?
    private let synth = AVSpeechSynthesizer()
    private let lock = NSLock()
    private var gate = VoiceGate()
    private var pre: [AVAudioPCMBuffer] = []
    private var preMs: Double = 0
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private var texts: [Int: String] = [:]
    private var gen = 0
    private var mutedUntil: Double = 0
    private var playing = false
    private var running = false

    var onStart: (@Sendable () -> Void)?
    var onHeard: (@Sendable (String, Double) -> Void)?
    var onDrop: (@Sendable () -> Void)?

    init(locale: String) {
        recognizer = SFSpeechRecognizer(locale: Locale(identifier: locale))
    }

    func start() throws {
        let s = AVAudioSession.sharedInstance()
        try s.setCategory(.playAndRecord, mode: .default, options: [.mixWithOthers, .defaultToSpeaker, .allowBluetoothA2DP])
        try s.setActive(true)
        let input = engine.inputNode
        do {
            try input.setVoiceProcessingEnabled(true)
            input.voiceProcessingOtherAudioDuckingConfiguration = AVAudioVoiceProcessingOtherAudioDuckingConfiguration(
                enableAdvancedDucking: true, duckingLevel: .mid)
        } catch {
            // 没有回声消除也照样能用：放回答时本来就不听
        }
        engine.attach(player)
        engine.connect(player, to: engine.mainMixerNode, format: playFormat)
        input.installTap(onBus: 0, bufferSize: 1024, format: nil) { [weak self] buf, _ in self?.hear(buf) }
        engine.prepare()
        try engine.start()
        running = true
    }

    func stop() {
        lock.lock()
        running = false
        gen += 1
        task?.cancel()
        task = nil
        request = nil
        pre = []
        lock.unlock()
        player.stop()
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        synth.stopSpeaking(at: .immediate)
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    // ---------------------------------------------------------------- 听
    private func hear(_ buf: AVAudioPCMBuffer) {
        guard buf.frameLength > 0, let copy = Ear.copy(buf) else { return }
        let ms = Double(buf.frameLength) / buf.format.sampleRate * 1000
        let db = Ear.level(buf)
        let now = ProcessInfo.processInfo.systemUptime
        lock.lock()
        guard running else { lock.unlock(); return }
        let mute = playing || now < mutedUntil
        let was = gate.speaking
        let ev = gate.feed(db: db, ms: ms, mute: mute)
        var startCB: (@Sendable () -> Void)?
        var dropCB: (@Sendable () -> Void)?
        switch ev {
        case .start?:
            beginLocked(pre + [copy])
            pre = []
            preMs = 0
            startCB = onStart
        case .end?:
            request?.append(copy)
            endLocked(spokeEnd: now - gate.endSilenceMs / 1000)
        case .tooShort?:
            task?.cancel()
            task = nil
            request = nil
            gen += 1
            dropCB = onDrop
        case nil:
            if gate.speaking {
                request?.append(copy)
            } else {
                if was { request = nil }
                pre.append(copy)
                preMs += ms
                while preMs > 300, pre.count > 1 {
                    preMs -= Double(pre[0].frameLength) / pre[0].format.sampleRate * 1000
                    pre.removeFirst()
                }
            }
        }
        lock.unlock()
        startCB?()
        dropCB?()
    }

    private func beginLocked(_ first: [AVAudioPCMBuffer]) {
        gen += 1
        let g = gen
        texts = texts.filter { $0.key >= g - 3 }
        endAt = endAt.filter { $0.key >= g - 3 }
        task?.cancel()
        let r = SFSpeechAudioBufferRecognitionRequest()
        r.shouldReportPartialResults = true
        r.requiresOnDeviceRecognition = true
        r.addsPunctuation = true
        r.taskHint = .dictation
        for b in first { r.append(b) }
        request = r
        guard let recognizer, recognizer.isAvailable else { return }
        task = recognizer.recognitionTask(with: r) { [weak self] result, _ in
            guard let self, let result else { return }
            self.lock.lock()
            self.texts[g] = result.bestTranscription.formattedString
            let final = result.isFinal
            self.lock.unlock()
            if final { self.deliver(g) }
        }
    }

    private var endAt: [Int: Double] = [:]

    private func endLocked(spokeEnd: Double) {
        let g = gen
        endAt[g] = spokeEnd
        request?.endAudio()
        request = nil
        DispatchQueue.global().asyncAfter(deadline: .now() + 2) { [weak self] in self?.deliver(g) }
    }

    /// 一句定稿了（或者等了 2 秒）：交出去，只交一次
    private func deliver(_ g: Int) {
        lock.lock()
        guard let end = endAt.removeValue(forKey: g) else { lock.unlock(); return }
        let text = texts.removeValue(forKey: g) ?? ""
        let cb = onHeard
        lock.unlock()
        cb?(text, end)
    }

    // ---------------------------------------------------------------- 说
    /// 放大管家配好的 mp3。放不了（坏的）返回 false
    func play(_ data: Data, started: @escaping @Sendable () -> Void, done: @escaping @Sendable () -> Void) -> Bool {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("yiye-answer.mp3")
        do {
            try data.write(to: url, options: .atomic)
            let f = try AVAudioFile(forReading: url)
            guard let raw = AVAudioPCMBuffer(pcmFormat: f.processingFormat, frameCapacity: AVAudioFrameCount(f.length)) else { return false }
            try f.read(into: raw)
            try? FileManager.default.removeItem(at: url)
            guard let buf = Ear.convert(raw, to: playFormat) else { return false }
            schedule(buf, started: started, done: done)
            return true
        } catch {
            try? FileManager.default.removeItem(at: url)
            return false
        }
    }

    /// 用苹果的中文嗓子念一句（大管家不在、没回……）
    func speak(_ words: String, voice: AVSpeechSynthesisVoice?, started: @escaping @Sendable () -> Void, done: @escaping @Sendable () -> Void) {
        let u = AVSpeechUtterance(string: words)
        u.voice = voice
        let box = Collect()
        let fmt = playFormat
        synth.write(u) { [weak self] b in
            guard let pcm = b as? AVAudioPCMBuffer else { return }
            if pcm.frameLength == 0 {
                guard box.finish() else { return }
                let all = box.items.compactMap { Ear.convert($0, to: fmt) }
                guard let self, let one = Ear.join(all, fmt) else { return done() }
                self.schedule(one, started: started, done: done)
            } else {
                box.add(pcm)
            }
        }
    }

    private func schedule(_ buf: AVAudioPCMBuffer, started: @escaping @Sendable () -> Void, done: @escaping @Sendable () -> Void) {
        lock.lock()
        guard running else { lock.unlock(); return done() }
        playing = true
        lock.unlock()
        player.stop()
        player.scheduleBuffer(buf, at: nil, options: [], completionCallbackType: .dataPlayedBack) { [weak self] _ in
            guard let self else { return }
            self.lock.lock()
            self.playing = false
            self.mutedUntil = ProcessInfo.processInfo.systemUptime + 0.3
            self.lock.unlock()
            done()
        }
        if !engine.isRunning { try? engine.start() }
        player.play()
        started()
    }

    // ---------------------------------------------------------------- 小工具
    static func level(_ b: AVAudioPCMBuffer) -> Double {
        let n = Int(b.frameLength)
        guard n > 0 else { return -120 }
        var sum: Double = 0
        if let f = b.floatChannelData {
            let p = f[0]
            for i in 0..<n { let v = Double(p[i]); sum += v * v }
        } else if let s = b.int16ChannelData {
            let p = s[0]
            for i in 0..<n { let v = Double(p[i]) / 32768; sum += v * v }
        } else {
            return -120
        }
        return 20 * log10(max(sqrt(sum / Double(n)), 1e-6))
    }

    static func copy(_ b: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        guard let c = AVAudioPCMBuffer(pcmFormat: b.format, frameCapacity: b.frameLength) else { return nil }
        c.frameLength = b.frameLength
        let src = UnsafeMutableAudioBufferListPointer(b.mutableAudioBufferList)
        let dst = UnsafeMutableAudioBufferListPointer(c.mutableAudioBufferList)
        for (s, d) in zip(src, dst) {
            guard let sp = s.mData, let dp = d.mData else { continue }
            memcpy(dp, sp, Int(min(s.mDataByteSize, d.mDataByteSize)))
        }
        return c
    }

    static func convert(_ b: AVAudioPCMBuffer, to fmt: AVAudioFormat) -> AVAudioPCMBuffer? {
        if b.format == fmt { return b }
        guard let conv = AVAudioConverter(from: b.format, to: fmt) else { return nil }
        let cap = AVAudioFrameCount(Double(b.frameLength) * fmt.sampleRate / b.format.sampleRate) + 1024
        guard let out = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: cap) else { return nil }
        let fed = Once()
        var err: NSError?
        conv.convert(to: out, error: &err) { _, status in
            if fed.take() {
                status.pointee = .haveData
                return b
            }
            status.pointee = .endOfStream
            return nil
        }
        return err == nil && out.frameLength > 0 ? out : nil
    }

    static func join(_ bs: [AVAudioPCMBuffer], _ fmt: AVAudioFormat) -> AVAudioPCMBuffer? {
        let total = bs.reduce(0) { $0 + $1.frameLength }
        guard total > 0, let out = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: total), let d = out.floatChannelData else { return nil }
        var at = 0
        for b in bs {
            guard let s = b.floatChannelData else { continue }
            memcpy(d[0] + at, s[0], Int(b.frameLength) * MemoryLayout<Float>.size)
            at += Int(b.frameLength)
        }
        out.frameLength = AVAudioFrameCount(at)
        return out
    }

    private final class Collect: @unchecked Sendable {
        private let lock = NSLock()
        private(set) var items: [AVAudioPCMBuffer] = []
        private var done = false
        func add(_ b: AVAudioPCMBuffer) { lock.lock(); items.append(b); lock.unlock() }
        func finish() -> Bool { lock.lock(); defer { lock.unlock() }; if done { return false }; done = true; return true }
    }
}
