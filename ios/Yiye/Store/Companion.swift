import AVFoundation
import Network
import Observation
import UIKit
import YiyeKit

/// 陪玩模式（pc-butler 施工单 100，Song 11-24 10:07）：
/// 「像游戏陪玩那样，打开以后它能实时读我的屏幕，然后可以实时问它问题，它可以实时做出反馈」「主要是一些英文内容，我不太看得懂」。
/// - 104（Song 11-24）：没有「陪玩模式」开关了。工具栏耳机右边一个小图标，点一下弹苹果的直播面板选一叶笺（苹果规定这一下要人点）；开了直播就算开，停了直播就算关。之后全自动。
/// - 直播开着就在后台听（后台音频）：本机按音量判断开口、说完（停 0.8 秒），这一句录成 16 kHz 单声道 WAV（开口前 0.3 秒一起要，最长 20 秒），
///   去直播扩展取问的那一刻的一帧，录音 + 截图一起走信箱（两头加密）交给大管家；大管家用本机 SenseVoice 认字、看图答话、配好音回来，直接放（别的 App 的声音压低）。
/// - 108（Song 11-24 12:20 选 A）：不用苹果听写了（「非常差，经常听不懂我在说啥」，12:12 真机说话一点反应都没有）。
///   出错就说：凡是会让「他说了话却什么都不发生」的地方，都弹一行字、用苹果的中文嗓子念出哪一步坏了，小圆点变红。不许再有静默 return。
///   开听那一下「叮」一声。小圆点：在听绿，判到他在说绿色一闪一闪，等大管家橙，出错红。每次开听体检一次，工具箱「陪玩」下面显示，也寄给大管家记日志。
/// - 截到的屏幕只在开口那一刻取一帧，录音、截图只交自己的大管家，都不存。
/// - 107 深聊（Song 11-24 11:58「我不需要快速回答……他可以去思考 5 分钟再回答我，但是回答的问题要有深度」「锁屏以后，它就进入语音聊模式，不用去截屏」）：
///   陪玩开着锁屏（系统停了直播）话筒不撒手，转深聊；工具箱「深聊」一格亮屏时直接进。不截屏，说完停 1.5 秒算一句，每一句录音寄给大管家，
///   大管家认完字只认「大管家」开头的（别的当场扔，不回）；收到了回一封 ack，手机马上念「收到，想好了叫你」；想好了回口语版 mp3 + 完整文字，
///   到了就念（他正说着就等他说完），完整文字存成「深聊」文件夹里的一条便签。说「大管家，结束」、再点一下「深聊」、30 分钟一句没问：退出，撒手话筒。
@MainActor @Observable
final class Companion {
    typealias Phase = CompanionPhase

    fileprivate(set) var phase: Phase = .off
    /// 直播扩展在跑（回环口子能连上）
    fileprivate(set) var live = false
    /// 上一问从说完到出声几秒
    private(set) var lastTotal: Double?
    /// 这一问哪一步出了错（念过了）：小圆点红，到他下次开口
    fileprivate(set) var alert: CompanionTrouble?
    /// 体检那一行（工具箱「陪玩」下面）
    private(set) var healthLine: String?
    /// 上一句大管家认出来的字（工具箱「陪玩」下面，听歪了一眼看得出来）。只在内存里
    fileprivate(set) var lastHeard: String?

    var light: CompanionLight? { CompanionLight.of(phase, alert: alert != nil) }
    /// 在深聊（107）
    fileprivate(set) var deep = false

    @ObservationIgnored weak var app: AppModel?
    @ObservationIgnored private let bell = LiveBell()
    @ObservationIgnored private let mouth = AVSpeechSynthesizer()
    @ObservationIgnored fileprivate var ear: Ear?
    @ObservationIgnored fileprivate var current: String?
    @ObservationIgnored fileprivate var clock: LookClock?
    @ObservationIgnored fileprivate var prev: [String: Double] = [:]
    @ObservationIgnored fileprivate var shorts = 0
    @ObservationIgnored fileprivate var probeTimer: Timer?
    @ObservationIgnored fileprivate var startedAt: Date?
    @ObservationIgnored fileprivate var batteryAtStart: Float?
    // 107 深聊
    @ObservationIgnored fileprivate var topic = DeepTopic()
    @ObservationIgnored fileprivate var limiter = TroubleLimiter()
    @ObservationIgnored fileprivate var deepSent: Set<String> = []
    @ObservationIgnored fileprivate var deepWaiting: String?
    @ObservationIgnored fileprivate var deepIdle: Timer?
    @ObservationIgnored fileprivate var pending: (ButlerResult, Data?)?
    @ObservationIgnored fileprivate var lockAt: Date?
    @ObservationIgnored fileprivate var cutByCall = false
    @ObservationIgnored fileprivate var observers: [NSObjectProtocol] = []

    enum After { case nothing, listen, stop }

    /// 开着陪玩、在听：后台也别断信箱
    var holdsButler: Bool { ear != nil }

    func setUp() {
        bell.onRing = { [weak self] name in self?.ring(name) }
        Task { await probe() }          // 开 app 时直播要是已经在跑，接着听
        let nc = NotificationCenter.default
        observers.append(nc.addObserver(forName: UIApplication.protectedDataWillBecomeUnavailableNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.lockAt = Date() }            // 锁屏了：接下来直播停，是锁屏停的
        })
        observers.append(nc.addObserver(forName: UIApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.becameActive() }
        })
        observers.append(nc.addObserver(forName: AVAudioSession.interruptionNotification, object: nil, queue: .main) { [weak self] n in
            let raw = (n.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt) ?? 0
            let began = AVAudioSession.InterruptionType(rawValue: raw) == .began
            MainActor.assumeIsolated { self?.interrupted(began: began) }
        })
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
            if deep { live = false; return }            // 深聊不看直播
            if live || ear != nil { liveGone() }
            return
        }
        live = true
        if ear == nil { startListening() }
    }

    private func liveGone() {
        live = false
        if deep { return }                              // 深聊里直播停了不管
        if ear != nil, locking {                        // 锁屏把直播停了：话筒不撒手，转深聊（107）
            beginDeep()
            return
        }
        stopListening()
        phase = .off
        alert = nil
    }

    /// 刚锁屏（或者正锁着）
    private var locking: Bool {
        if !UIApplication.shared.isProtectedDataAvailable { return true }
        if let t = lockAt, Date().timeIntervalSince(t) < 15 { return true }
        return false
    }

    // ---------------------------------------------------------------- 听
    fileprivate func startListening(deep wantDeep: Bool = false) {
        guard ear == nil, let app, app.demo == nil else { return }
        Task {
            guard await AVAudioApplication.requestRecordPermission() else {
                self.healthLine = CompanionHealth(mic: false, live: self.live, mail: app.butler.relayUp, noise: nil, echo: false).line
                return self.fail(.noMic, app.lang.t("companion.noMic"))
            }
            guard self.ear == nil, self.live || wantDeep else { return }
            let ear = Ear()
            ear.onStart = { [weak self] in Task { @MainActor in self?.heardStart() } }
            ear.onClip = { [weak self] wav, secs, peak, end in
                Task { @MainActor in self?.heard(wav, seconds: secs, peak: peak, spokeEnd: end) }
            }
            ear.onDrop = { [weak self] in Task { @MainActor in self?.dropped() } }
            do {
                try ear.start()
            } catch {
                ear.stop()
                return self.fail(.earFailed, error.localizedDescription)
            }
            self.ear = ear
            self.phase = .listening
            self.alert = nil
            self.startedAt = Date()
            self.shorts = 0
            UIDevice.current.isBatteryMonitoringEnabled = true
            self.batteryAtStart = UIDevice.current.batteryLevel
            self.app?.butler.start()
            if wantDeep {
                self.beginDeep()
            } else {
                self.app?.butler.lookWarm()
            }
            ear.chime()                                       // 真正开始听了：叮
            self.probeTimer?.invalidate()
            let t = Timer(timeInterval: 15, repeats: true) { [weak self] _ in Task { @MainActor in await self?.probe() } }
            RunLoop.main.add(t, forMode: .common)
            self.probeTimer = t
            // 体检：等底噪稳下来（门槛看最近 3 秒）再量
            try? await Task.sleep(nanoseconds: 3_500_000_000)
            if self.ear === ear { self.checkUp(ear) }
        }
    }

    private func checkUp(_ ear: Ear) {
        guard let app else { return }
        let h = CompanionHealth(mic: true, live: live, mail: app.butler.relayUp, noise: ear.noise, echo: ear.echo)
        healthLine = h.line
        app.butler.lookCheck(h)
    }

    fileprivate func stopListening() {
        probeTimer?.invalidate()
        probeTimer = nil
        if deep { dropDeep() }
        ear?.stop()
        ear = nil
        if let id = current { app?.butler.forgetLook(id) }
        current = nil
        clock = nil
        if UIApplication.shared.applicationState == .background { app?.butler.stop() }
    }

    /// 开不起来：停听、红点、弹一行、念出来
    private func fail(_ t: CompanionTrouble, _ detail: String) {
        stopListening()
        phase = .failed(t.words)
        if let app { app.show(app.lang.f("companion.failed", detail), seconds: 6) }
        say(t.words, after: .nothing)
    }

    private func heardStart() {
        if phase == .listening || (deep && phase == .asking) {
            phase = .hearing
            alert = nil
        }
    }

    /// 他说完了（或者那一下不算一句）：回到「在听」，深聊里在等回答的回到「等」
    fileprivate var restPhase: Phase { deep && deepWaiting != nil ? .asking : .listening }

    /// 太短的一下（咔哒、咳嗽）：不算一句，记个数跟下一封信走
    private func dropped() {
        shorts += 1
        if phase == .hearing { phase = restPhase }
        playPending()
    }

    // ---------------------------------------------------------------- 问
    private func heard(_ wav: Data, seconds: Double, peak: Double, spokeEnd: Double) {
        if deep { return heardDeep(wav, seconds: seconds, peak: peak) }
        guard ear != nil, let app else { return }
        let id = UUID().uuidString
        if let old = current {                           // 上一句还在等：不要了，它的账先记上
            app.butler.forgetLook(old)
            finishStats()
        }
        current = id
        clock = LookClock(spokeEnd: spokeEnd, rec: seconds, peak: peak)
        phase = .asking
        alert = nil
        let prevSend = takePrev()
        Task {
            let audioPath = ButlerRequest.lookAudioPath(id)
            var files: [String: Data] = [audioPath: wav]
            var path: String?
            var trouble: CompanionTrouble?
            if self.live {
                switch await LiveLink.fetch(id) {
                case .frame(let d):
                    let p = "陪玩/\(id.prefix(8))-屏.jpg"
                    files[p] = d
                    path = p
                case .noFrame: trouble = .noFrame
                case .refused: trouble = .frameRefused
                case .down:
                    self.live = false
                    trouble = .liveDown
                }
            } else {
                trouble = .liveDown
            }
            guard self.current == id else { return }
            self.clock?.frame = ProcessInfo.processInfo.systemUptime
            self.clock?.frameOK = path != nil
            if let trouble { self.notice(trouble) }           // 少了图照样问，先说一声
            let req = ButlerRequest.look(id: id, question: "", audio: audioPath, image: path, at: ISOTime.string(Date()),
                                         app: ButlerService.appVersion, prev: prevSend)
            let r = await app.butler.sendLook(req, files: files)
            guard self.current == id else { return }
            self.clock?.sent = ProcessInfo.processInfo.systemUptime
            switch r {
            case .sent(true):
                self.clock?.sentOK = true
                try? await Task.sleep(nanoseconds: 45_000_000_000)
                if self.current == id, self.phase == .asking { self.giveUp(id, .noAnswer) }
            case .sent(false):
                self.clock?.sentOK = false
                self.giveUp(id, .away)
            case .noPair:
                self.clock?.sentOK = false
                self.giveUp(id, .noPair)
            case .failed:
                self.clock?.sentOK = false
                self.giveUp(id, .noMail)
            }
            if !self.live { self.liveGone() }
        }
    }

    /// 这一问走不下去了：记账、红点、弹一行、念出来，念完接着听
    private func giveUp(_ id: String, _ t: CompanionTrouble) {
        app?.butler.forgetLook(id)
        current = nil
        finishStats()
        alert = t
        app?.show(t.words, seconds: 5)
        phase = .speaking
        say(t.words, after: .listen)
    }

    /// 这一问还接着走，只是哪一步差了点（没截到图）：红点、弹一行、念一句，不改现在在干嘛
    private func notice(_ t: CompanionTrouble) {
        alert = t
        app?.show(t.words, seconds: 5)
        say(t.words, after: .nothing)
    }

    /// 大管家的回答到了（ButlerService 收信时叫）
    func answer(_ r: ButlerResult, audio: Data?) {
        if deepSent.contains(r.id) { return deepAnswer(r, audio: audio) }
        guard r.id == current, let ear else { return }        // 不是最新那一问的：不放（只要最新的）
        current = nil
        clock?.back = ProcessInfo.processInfo.systemUptime
        if let h = r.heard { lastHeard = h.isEmpty ? "（什么都没听出来）" : h }
        let missed = (r.timing?["miss"] ?? 0) > 0
        if missed {
            alert = .misheard
            app?.show(CompanionTrouble.misheard.words, seconds: 4)
        }
        phase = .speaking
        let done: @Sendable () -> Void = { [weak self] in Task { @MainActor in self?.played() } }
        let started: @Sendable () -> Void = { [weak self] in Task { @MainActor in self?.playing(r.timing ?? [:]) } }
        if let audio {
            if ear.play(audio, started: started, done: done) { return }
            alert = .cantPlay                                   // 配好的声音坏了：弹一行，用手机自己的嗓子念回答
            app?.show(CompanionTrouble.cantPlay.words, seconds: 5)
        }
        let words = (r.text?.isEmpty == false ? r.text : nil) ?? (missed ? CompanionTrouble.misheard.words : CompanionTrouble.brainFailed.words)
        ear.speak(words, voice: PhoneVoice.bestVoice("zh-CN"), started: started, done: done)
    }

    fileprivate func playing(_ butler: [String: Double]) {
        clock?.playing = ProcessInfo.processInfo.systemUptime
        clock?.playOK = true
        finishStats(butler: butler)
    }

    fileprivate func played() {
        if clock != nil {                                     // 放完了还没开始出声：没放出来
            clock?.playOK = false
            finishStats()
            alert = .cantPlay
            app?.show(CompanionTrouble.cantPlay.words, seconds: 5)
        }
        if ear != nil, phase == .speaking { phase = restPhase }
        playPending()
    }

    /// 用苹果的中文嗓子念一句。在听就走耳朵（念的时候不判开口）；耳朵没开就直接念。念完：接着听 / 不管 / 撒手话筒
    fileprivate func say(_ words: String, after: After) {
        let voice = PhoneVoice.bestVoice("zh-CN")
        guard let ear else {
            let u = AVSpeechUtterance(string: words)
            u.voice = voice
            mouth.speak(u)
            return
        }
        ear.speak(words, voice: voice, started: {}, done: { [weak self] in
            Task { @MainActor in
                switch after {
                case .listen: self?.played()
                case .stop: self?.stopAfterSaying()
                case .nothing: break
                }
            }
        })
    }

    private func stopAfterSaying() {
        guard !deep, !live, ear != nil else { return }
        stopListening()
        phase = .off
    }

    // ---------------------------------------------------------------- 记账（只有是 / 否和秒数，跟下一封信走）
    private func finishStats(butler: [String: Double] = [:]) {
        guard let c = clock else { return }
        prev = c.summary(butler: butler)
        if let t = prev["total"] { lastTotal = t }
        clock = nil
    }

    fileprivate func takePrev() -> [String: Double] {
        var p = prev
        prev = [:]
        UIDevice.current.isBatteryMonitoringEnabled = true
        let bat = UIDevice.current.batteryLevel
        if bat >= 0 { p["bat"] = Double((bat * 100).rounded()) }
        if let b0 = batteryAtStart, b0 >= 0 { p["bat0"] = Double((b0 * 100).rounded()) }
        if let s = startedAt { p["mins"] = (Date().timeIntervalSince(s) / 60 * 10).rounded() / 10 }
        if shorts > 0 { p["short"] = Double(shorts) }
        shorts = 0
        return p
    }
}

// ================================================================ 深聊（107）
extension Companion {
    /// 工具箱「深聊」那一格：没在深聊就进（亮屏时开话筒，然后锁屏揣兜里），在深聊就退
    func toggleDeep() {
        if deep { return exitDeep(say: Deep.saysEnd) }
        if ear != nil {
            beginDeep()
        } else {
            startListening(deep: true)
        }
        if let app { app.show(app.lang.t("companion.deepOn"), seconds: 6) }
    }

    /// 进深聊：话筒照开着（锁屏也不撒手），不截屏、不看直播，说完停 1.5 秒算一句
    fileprivate func beginDeep() {
        guard let ear else { return }
        deep = true
        ear.setDeep(true)
        if phase != .speaking { phase = .listening }
        alert = nil
        current = nil
        clock = nil
        app?.butler.deepWarm()
        armDeepIdle()
    }

    /// 出深聊：直播还开着就回陪玩，不然念完一句撒手话筒
    func exitDeep(say words: String? = nil) {
        guard deep else { return }
        dropDeep()
        if live, let ear {
            ear.setDeep(false)
            phase = .listening
            if let words { say(words, after: .nothing) }
            return
        }
        if let words, ear != nil {
            phase = .speaking
            say(words, after: .stop)
        } else {
            stopListening()
            phase = .off
        }
    }

    /// 深聊的账清掉（话筒不管）
    fileprivate func dropDeep() {
        deep = false
        deepIdle?.invalidate()
        deepIdle = nil
        deepWaiting = nil
        pending = nil
        for id in deepSent { app?.butler.forgetLook(id) }
        deepSent = []
    }

    /// 30 分钟一句没问：退出深聊
    fileprivate func armDeepIdle() {
        deepIdle?.invalidate()
        let t = Timer(timeInterval: Deep.idle, repeats: false) { [weak self] _ in
            Task { @MainActor in self?.exitDeep(say: Deep.saysEnd) }
        }
        RunLoop.main.add(t, forMode: .common)
        deepIdle = t
    }

    /// 深聊里说完一句：录音寄给大管家（是不是在问它，它认完字判）。寄出去就回到在听
    fileprivate func heardDeep(_ wav: Data, seconds: Double, peak: Double) {
        guard let app else { return }
        let id = UUID().uuidString
        let path = ButlerRequest.deepAudioPath(id)
        var prev = takePrev()
        prev["deep"] = 1
        prev["rec"] = (seconds * 100).rounded() / 100
        prev["peak"] = peak
        let req = ButlerRequest.deep(id: id, audio: path, topic: topic.current(Date()), at: ISOTime.string(Date()),
                                     app: ButlerService.appVersion, prev: prev)
        deepSent.insert(id)
        if phase == .hearing { phase = restPhase }
        playPending()
        Task {
            let r = await app.butler.sendLook(req, files: [path: wav])
            switch r {
            case .sent(true): break
            case .sent(false):
                self.deepSent.remove(id)
                self.deepTrouble(.away)
            case .noPair:
                self.deepSent.remove(id)
                self.deepTrouble(.noPair)
            case .failed:
                self.deepSent.remove(id)
                self.deepTrouble(.noMail)
            }
        }
    }

    /// 深聊里每一句都寄（不知道是不是在问），所以「大管家不在」「信箱连不上」这种 10 分钟最多念一回
    fileprivate func deepTrouble(_ t: CompanionTrouble) {
        alert = t
        guard limiter.allow("\(t)", now: Date()) else { return }
        app?.show(t.words, seconds: 5)
        say(t.words, after: .nothing)
    }

    /// 深聊的回信：ack（收到了）、end、topic、answer / failed
    fileprivate func deepAnswer(_ r: ButlerResult, audio: Data?) {
        if let h = r.heard, !h.isEmpty { lastHeard = h }
        switch r.stage {
        case "ack":
            topic.asked(Date())
            armDeepIdle()
            deepWaiting = r.id
            alert = nil
            if phase == .listening { phase = .asking }
            say((r.text?.isEmpty == false ? r.text : nil) ?? Deep.saysGot, after: .nothing)
            let id = r.id
            Task {
                try? await Task.sleep(nanoseconds: UInt64(Deep.answerWait * 1_000_000_000))
                guard self.deep, self.deepWaiting == id else { return }
                self.deepWaiting = nil
                self.deepSent.remove(id)
                self.app?.butler.forgetLook(id)
                if self.phase == .asking { self.phase = .listening }
                self.alert = .deepNoAnswer
                self.app?.show(CompanionTrouble.deepNoAnswer.words, seconds: 6)
                self.say(CompanionTrouble.deepNoAnswer.words, after: .nothing)
            }
        case "end":
            deepSent.remove(r.id)
            app?.butler.forgetLook(r.id)
            exitDeep(say: (r.text?.isEmpty == false ? r.text : nil) ?? Deep.saysEnd)
        case "topic":
            deepSent.remove(r.id)
            app?.butler.forgetLook(r.id)
            topic.renew()
            topic.asked(Date())
            armDeepIdle()
            say((r.text?.isEmpty == false ? r.text : nil) ?? Deep.saysTopic, after: .nothing)
        default:                                           // answer / failed
            deepSent.remove(r.id)
            app?.butler.forgetLook(r.id)
            if deepWaiting == r.id { deepWaiting = nil }
            if phase == .asking { phase = .listening }
            if r.stage == "answer", let text = r.text, !text.isEmpty {
                app?.addDeepNote(id: r.id, title: r.title ?? "", text: text, audio: audio)
            }
            if r.stage != "answer" { alert = .deepNoAnswer }
            pending = (r, audio)
            playPending()
        }
    }

    /// 回答到了：他没在说话就念（正说着就等他说完）
    fileprivate func playPending() {
        guard let p = pending, let ear, phase != .hearing else { return }
        let (r, audio) = p
        pending = nil
        phase = .speaking
        let done: @Sendable () -> Void = { [weak self] in Task { @MainActor in self?.played() } }
        if let audio, ear.play(audio, started: {}, done: done) { return }
        if audio != nil {
            alert = .cantPlay
            app?.show(CompanionTrouble.cantPlay.words, seconds: 5)
        }
        let words = (r.text?.isEmpty == false ? r.text : nil) ?? CompanionTrouble.deepNoAnswer.words
        ear.speak(words, voice: PhoneVoice.bestVoice("zh-CN"), started: {}, done: done)
    }

    // ---------------------------------------------------------------- 来电话、回到前台
    /// 来电话把话筒打断了：挂了以后能续就续，续不上记下，下次亮屏提示
    fileprivate func interrupted(began: Bool) {
        guard let ear, !began else { return }
        if ear.resume() { return }
        if deep {
            cutByCall = true
            alert = .deepCut
            stopListening()
            phase = .failed(CompanionTrouble.deepCut.words)
        }
    }

    fileprivate func becameActive() {
        guard cutByCall else { return }
        cutByCall = false
        app?.show(CompanionTrouble.deepCut.words, action: app?.lang.t("companion.restart"), seconds: 10) { [weak self] in
            self?.startListening(deep: true)
        }
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

// ================================================================ 耳朵和嘴：话筒、切句录音、放回答
/// 一个 AVAudioEngine 从开到关一直跑着（后台不能重新开话筒，所以不停）：
/// - 话筒开回声消除（voice processing），别的 App 的声音在有人说话时压低（advanced ducking），自己放的回答不会被自己听进去；
/// - 每一小块转成 16 kHz 单声道交给 ClipCutter：判开口、说完，开口前 0.3 秒一起要，最长 20 秒；说完把这一句编成 WAV 交出去（108，不再用苹果听写）；
/// - 放回答、念一句、叮的时候不判开口（mute），放完再等 0.3 秒。
final class Ear: @unchecked Sendable {
    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private let playFormat = AVAudioFormat(standardFormatWithSampleRate: 24_000, channels: 1)!
    private let earFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: Double(ClipCutter.rate), channels: 1, interleaved: false)!
    private var converter: AVAudioConverter?
    private let synth = AVSpeechSynthesizer()
    private let backup = AVSpeechSynthesizer()
    private let lock = NSLock()
    private var cutter = ClipCutter()
    private var mutedUntil: Double = 0
    private var playing = false
    private var playGen = 0
    private var running = false
    /// 回声消除开上了没有（体检用）
    private(set) var echo = false

    var onStart: (@Sendable () -> Void)?
    /// 一句说完：WAV、录了几秒、最响一块的 dB、说完的那一刻（systemUptime）
    var onClip: (@Sendable (Data, Double, Double, Double) -> Void)?
    var onDrop: (@Sendable () -> Void)?

    /// 门槛现在的底噪（dBFS）
    var noise: Double {
        lock.lock(); defer { lock.unlock() }
        return cutter.noise
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
            echo = true
        } catch {
            echo = false        // 没有回声消除也照样能用：放回答时本来就不听
        }
        engine.attach(player)
        engine.connect(player, to: engine.mainMixerNode, format: playFormat)
        input.installTap(onBus: 0, bufferSize: 1024, format: nil) { [weak self] buf, _ in self?.hear(buf) }
        engine.prepare()
        try engine.start()
        lock.lock()
        running = true
        lock.unlock()
    }

    /// 深聊（107）：停 1.5 秒才算说完，一句最长 60 秒；陪玩：0.8 秒、20 秒
    func setDeep(_ on: Bool) {
        lock.lock()
        cutter.gate.endSilenceMs = on ? Deep.endSilenceMs : 800
        cutter.maxSeconds = on ? Deep.maxSeconds : 20
        cutter.gate.maxMs = cutter.maxSeconds * 1000
        lock.unlock()
    }

    /// 来电话打断以后接着开（后台能不能再开话筒看系统，开不了回 false）
    func resume() -> Bool {
        do {
            try AVAudioSession.sharedInstance().setActive(true)
            if !engine.isRunning { try engine.start() }
            return true
        } catch {
            return false
        }
    }

    func stop() {
        lock.lock()
        running = false
        cutter = ClipCutter()
        lock.unlock()
        player.stop()
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        synth.stopSpeaking(at: .immediate)
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    // ---------------------------------------------------------------- 听
    private func hear(_ buf: AVAudioPCMBuffer) {
        guard buf.frameLength > 0, let samples = toEar(buf), !samples.isEmpty else { return }
        let now = ProcessInfo.processInfo.systemUptime
        lock.lock()
        guard running else { lock.unlock(); return }
        let mute = playing || now < mutedUntil
        let ev = cutter.feed(samples, mute: mute)
        let endSilence = cutter.gate.endSilenceMs / 1000
        let maxSeconds = cutter.maxSeconds
        let startCB = onStart, dropCB = onDrop, clipCB = onClip
        lock.unlock()
        switch ev {
        case .start?:
            startCB?()
        case .tooShort?:
            dropCB?()
        case .clip(let s, let secs, let peak)?:
            let end = secs >= maxSeconds - 0.01 ? now : now - endSilence
            clipCB?(Wav.encode(s), secs, peak, end)
        case nil:
            break
        }
    }

    /// 话筒那一块 → 16 kHz 单声道浮点。转换器一直用同一个（接着上一块转，接缝不咔哒）
    private func toEar(_ b: AVAudioPCMBuffer) -> [Float]? {
        if converter == nil || converter?.inputFormat != b.format {
            converter = AVAudioConverter(from: b.format, to: earFormat)
            converter?.downmix = true
        }
        guard let conv = converter else { return nil }
        let cap = AVAudioFrameCount(Double(b.frameLength) * earFormat.sampleRate / b.format.sampleRate) + 256
        guard let out = AVAudioPCMBuffer(pcmFormat: earFormat, frameCapacity: cap) else { return nil }
        let fed = Once()
        var err: NSError?
        let st = conv.convert(to: out, error: &err) { _, status in
            if fed.take() {
                status.pointee = .haveData
                return b
            }
            status.pointee = .noDataNow
            return nil
        }
        guard st != .error, err == nil else { return nil }
        guard out.frameLength > 0, let d = out.floatChannelData else { return [] }
        return Array(UnsafeBufferPointer(start: d[0], count: Int(out.frameLength)))
    }

    // ---------------------------------------------------------------- 说
    /// 真正开始听的那一下：很短的「叮」（两个音，不念字）
    func chime() {
        let sr = playFormat.sampleRate
        let parts: [(Double, Double)] = [(1318.5, 0.07), (1760, 0.10)]
        let counts = parts.map { Int($0.1 * sr) }
        let total = counts.reduce(0, +)
        guard let buf = AVAudioPCMBuffer(pcmFormat: playFormat, frameCapacity: AVAudioFrameCount(total)), let d = buf.floatChannelData else { return }
        var i = 0
        for (j, part) in parts.enumerated() {
            let n = counts[j]
            for k in 0..<n {
                let fadeIn = min(1, Double(k) / (0.004 * sr))
                let fadeOut = min(1, Double(n - k) / (0.03 * sr))
                d[0][i] = Float(sin(2 * Double.pi * part.0 * Double(k) / sr) * 0.22 * fadeIn * fadeOut)
                i += 1
            }
        }
        buf.frameLength = AVAudioFrameCount(total)
        schedule(buf, started: {}, done: {})
    }

    /// 放大管家配好的 mp3。放不了（坏的）返回 false
    func play(_ data: Data, started: @escaping @Sendable () -> Void, done: @escaping @Sendable () -> Void) -> Bool {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("yiye-answer.mp3")
        do {
            try data.write(to: url, options: .atomic)
            let f = try AVAudioFile(forReading: url)
            guard let raw = AVAudioPCMBuffer(pcmFormat: f.processingFormat, frameCapacity: AVAudioFrameCount(f.length)) else {
                try? FileManager.default.removeItem(at: url)
                return false
            }
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

    /// 用苹果的中文嗓子念一句（大管家不在、没回、哪一步坏了……）。合成出不来声音就直接让系统念
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
                guard let self else { return done() }
                if let one = Ear.join(all, fmt) {
                    self.schedule(one, started: started, done: done)
                } else {
                    self.sayDirect(words, voice: voice)
                    started()
                    done()
                }
            } else {
                box.add(pcm)
            }
        }
    }

    private func sayDirect(_ words: String, voice: AVSpeechSynthesisVoice?) {
        let u = AVSpeechUtterance(string: words)
        u.voice = voice
        backup.speak(u)
    }

    private func schedule(_ buf: AVAudioPCMBuffer, started: @escaping @Sendable () -> Void, done: @escaping @Sendable () -> Void) {
        lock.lock()
        guard running else { lock.unlock(); return done() }
        playing = true
        playGen += 1
        let g = playGen
        lock.unlock()
        player.stop()                                   // 前一段（叮、念的一句）还没完就让给新的
        player.scheduleBuffer(buf, at: nil, options: [], completionCallbackType: .dataPlayedBack) { [weak self] _ in
            guard let self else { return }
            self.lock.lock()
            if self.playGen == g {                      // 被新的一段顶掉的那段不算放完
                self.playing = false
                self.mutedUntil = ProcessInfo.processInfo.systemUptime + 0.3
            }
            self.lock.unlock()
            done()
        }
        if !engine.isRunning { try? engine.start() }
        player.play()
        started()
    }

    // ---------------------------------------------------------------- 小工具
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
