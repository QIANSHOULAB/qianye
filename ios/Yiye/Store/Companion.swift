import AVFoundation
import Network
import Observation
import UIKit
import YiyeKit

/// 陪玩模式（pc-butler 施工单 100，Song 11-24 10:07）：
/// 「像游戏陪玩那样，打开以后它能实时读我的屏幕，然后可以实时问它问题，它可以实时做出反馈」「主要是一些英文内容，我不太看得懂」。
/// - 104（Song 11-24）：没有「陪玩模式」开关了。工具栏耳机右边一个小图标，点一下弹苹果的直播面板选一叶笺（苹果规定这一下要人点）；开了直播就算开，停了直播就算关。之后全自动。
/// - 直播开着就在后台听（后台音频）：本机按音量判断开口、说完（停 0.8 秒），这一句录成 16 kHz 单声道 WAV（开口前 0.3 秒一起要，最长 20 秒），
///   录音走信箱（两头加密）交给大管家；大管家用本机 SenseVoice 认字、看图答话、配好音回来，直接放（别的 App 的声音压低）。
/// - 108（Song 11-24 12:20 选 A）：不用苹果听写了。出错就说：凡是会让「他说了话却什么都不发生」的地方，都弹一行字、念出哪一步坏了，小圆点变红。
///   开听那一下「叮」一声。小圆点：在听绿，判到他在说绿色一闪一闪，等大管家橙，出错红。每次开听体检一次，工具箱「陪玩」下面显示，也寄给大管家记日志。
/// - 截到的屏幕只取开口那一刻的一帧，录音、截图只交自己的大管家，都不存。
/// - 107 深聊：陪玩开着锁屏（系统停了直播）话筒不撒手，转深聊；工具箱「深聊」一格亮屏时直接进。不截屏，说完停 1.5 秒算一句，每一句录音寄给大管家，
///   大管家认完字判是不是在问它（127：不用喊「大管家」）；收到了回一封 ack，手机马上念「收到，想好了叫你」；想好了回口语版 mp3 + 完整文字，
///   到了就念（他正说着就等他说完），完整文字存成「深聊」文件夹里的一条便签。说「结束」、再点一下「深聊」、30 分钟一句没问：退出，撒手话筒。
/// - 117（Song 11-24 14:02–14:54，照掌机那套「语音陪玩」）：
///   不聋：来电、闹钟、Siri、别的 App 出声、蓝牙耳机连上断开、媒体服务重置，话筒被系统停了自动整个重开；15 秒一次看话筒还有没有声音进来，
///   没了也重开；重开不了念出来、变红。边说边传：判到他开口就先去取那一刻的截图、先寄出去，说完只寄录音。边想边说：大管家一句一句寄回来，
///   到一句放一句。插嘴：放回答时也判开口（更响、更长才算）；声纹建好以前够响够长就停，建好以后先把头 1 秒寄去对声纹，是他才停。
///   一个嗓子：手机自己念的固定的话都是随 App 带的晓晓录音。陪玩开着每 4 分钟敲一下大管家（大脑不下班），关了陪玩说一声（这一场结束）。
/// - 139 打电话式（Song 11-25 07:56）：Siri / 捷径「叫大管家」接通（嘟一声），就是深聊那套；说「挂掉」「拜拜」就挂（手机本地认，
///   不过信箱），嘟嘟两声、撒手话筒、放掉会话，别家的歌自己接着放。电话耳朵不跟别家的声音混（歌停）、戴蓝牙耳机用耳机的麦。
///   挂的时候还在等的回答不扔：到了存进深聊，下次接通先提一句。锁着屏接通过一次，就开「答完 60 秒没话自己挂」。
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
    /// 117：声纹攒到哪了（工具箱「陪玩」下面）
    fileprivate(set) var voiceprintLine: String?

    var light: CompanionLight? { CompanionLight.of(phase, alert: alert != nil) }
    /// 在深聊（107）
    fileprivate(set) var deep = false

    @ObservationIgnored weak var app: AppModel?
    @ObservationIgnored private let bell = LiveBell()
    @ObservationIgnored private let mouth = AVSpeechSynthesizer()
    @ObservationIgnored fileprivate var lineMouth: AVAudioPlayer?
    @ObservationIgnored fileprivate var ear: Ear?
    @ObservationIgnored fileprivate var current: String?
    @ObservationIgnored fileprivate var clock: LookClock?
    @ObservationIgnored fileprivate var prev: [String: Double] = [:]
    @ObservationIgnored fileprivate var shorts = 0
    @ObservationIgnored fileprivate var probeTimer: Timer?
    @ObservationIgnored fileprivate var startedAt: Date?
    @ObservationIgnored fileprivate var batteryAtStart: Float?
    // 117
    @ObservationIgnored fileprivate var parts = PartQueue()
    @ObservationIgnored fileprivate var doneTotal: Int?
    @ObservationIgnored fileprivate var doneTiming: [String: Double] = [:]
    @ObservationIgnored fileprivate var statsLater = false
    @ObservationIgnored fileprivate var gear = 1
    @ObservationIgnored fileprivate var deadline: Date?
    @ObservationIgnored fileprivate var preID: String?
    @ObservationIgnored fileprivate var preState: PreState = .none
    @ObservationIgnored fileprivate var pingTimer: Timer?
    @ObservationIgnored fileprivate var whoID: String?
    @ObservationIgnored fileprivate var vpReady = false
    @ObservationIgnored fileprivate var rebuilding = false
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
    // 139 打电话式
    /// 在打电话（「叫大管家」接通的）
    fileprivate(set) var callOn = false
    /// 139 秒数：说完到第一声、说「挂掉」到挂断（工具箱「陪玩」下面一行）
    fileprivate(set) var callTimes: String?
    @ObservationIgnored fileprivate var line = CallLine(idleOn: false)
    @ObservationIgnored fileprivate var carried: Set<String> = []
    @ObservationIgnored fileprivate var callTimer: Timer?
    @ObservationIgnored fileprivate let reader = ClipReader()
    @ObservationIgnored fileprivate var hangWho: (id: String, done: (Bool) -> Void)?
    @ObservationIgnored fileprivate var heldOff = false
    @ObservationIgnored fileprivate var lastSpokeEnd: Double?
    @ObservationIgnored fileprivate var firstSound: Double?

    enum After { case nothing, listen, stop }
    /// 117：开口那一刻的截图先寄了没有
    enum PreState { case none, pending, sent, failed(CompanionTrouble) }

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
        // 117 不聋：换了耳机（蓝牙连上、断开）、媒体服务重置
        observers.append(nc.addObserver(forName: AVAudioSession.routeChangeNotification, object: nil, queue: .main) { [weak self] n in
            let raw = (n.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt) ?? 0
            MainActor.assumeIsolated { self?.routeChanged(raw) }
        })
        observers.append(nc.addObserver(forName: AVAudioSession.mediaServicesWereResetNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.rebuildEar("媒体服务重置", tell: true) }
        })
    }

    // ---------------------------------------------------------------- 直播在不在
    private func ring(_ name: String) {
        heldOff = false                                   // 139：直播重开 / 停了，挂电话时的「整个陪玩都停」作废
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
        // 117 不聋：话筒还在不在出声（引擎停了、15 秒里一块声音都没进来）：整个重开
        if let ear, !rebuilding, !ear.healthy() {
            rebuildEar("话筒没声音了", tell: true)
        }
        let r = await LiveLink.fetch("hello")
        if case .down = r {
            if deep { live = false; return }            // 深聊不看直播
            if live || ear != nil { liveGone() }
            return
        }
        live = true
        if ear == nil, !heldOff { startListening() }      // 139：陪玩开着时说了挂断词：整个陪玩停，直播还开着也不自己接着听
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
    fileprivate func startListening(deep wantDeep: Bool = false, call: Bool = false) {
        guard ear == nil, let app, app.demo == nil else { return }
        Task {
            guard await AVAudioApplication.requestRecordPermission() else {
                self.healthLine = CompanionHealth(mic: false, live: self.live, mail: app.butler.relayUp, noise: nil, echo: false).line
                return self.fail(.noMic, app.lang.t("companion.noMic"))
            }
            guard self.ear == nil, self.live || wantDeep else { return }
            let ear: Ear
            do {
                ear = try self.makeEar(call: call)
            } catch {
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
            if call {                                         // 139：电话接通了：嘟一声（不念长句）
                ear.beep(1)
                self.connected(companion: false)
            } else {
                ear.chime()                                   // 真正开始听了：叮
            }
            self.probeTimer?.invalidate()
            let t = Timer(timeInterval: 15, repeats: true) { [weak self] _ in Task { @MainActor in await self?.probe() } }
            RunLoop.main.add(t, forMode: .common)
            self.probeTimer = t
            self.armPing()
            // 体检：等底噪稳下来（门槛看最近 3 秒）再量
            try? await Task.sleep(nanoseconds: 3_500_000_000)
            if self.ear === ear { self.checkUp(ear) }
        }
    }

    /// 一只耳朵：话筒、门槛、嘴。开不起来抛错
    private func makeEar(call: Bool = false) throws -> Ear {
        let ear = Ear(call: call)
        ear.onStart = { [weak self] in Task { @MainActor in self?.heardStart() } }
        ear.onClip = { [weak self] wav, secs, peak, end in
            Task { @MainActor in self?.heard(wav, seconds: secs, peak: peak, spokeEnd: end) }
        }
        ear.onDrop = { [weak self] in Task { @MainActor in self?.dropped() } }
        ear.onBarge = { [weak self] in Task { @MainActor in self?.barge() } }
        ear.onProbe = { [weak self] wav in Task { @MainActor in self?.askWho(wav) } }
        ear.onLost = { [weak self] why in Task { @MainActor in self?.rebuildEar(why, tell: false) } }
        do {
            try ear.start()
        } catch {
            ear.stop()
            throw error
        }
        return ear
    }

    /// 117 不聋：话筒被系统停了，整个耳朵重开（后台也试：音频会话还是我们的）。重开不了：念出来、变红（深聊里照旧等亮屏提示）
    fileprivate func rebuildEar(_ why: String, tell: Bool) {
        guard let old = ear, !rebuilding else { return }
        rebuilding = true
        defer { rebuilding = false }
        let wasDeep = deep
        old.stop()
        ear = nil
        do {
            let e = try makeEar(call: old.call)
            e.setDeep(wasDeep)
            ear = e
            if phase == .speaking || phase == .hearing { phase = restPhase }
            if current != nil, phase != .asking { dropAnswer() }       // 放到一半被打断的回答不接着放了
            if tell { notice(.earBack) }
        } catch {
            if wasDeep {
                cutByCall = true
                alert = .deepCut
                stopListening()
                phase = .failed(CompanionTrouble.deepCut.words)
            } else {
                fail(.earLost, "\(why)：\(error.localizedDescription)")
            }
        }
    }

    private func routeChanged(_ raw: UInt) {
        guard ear != nil else { return }
        let reason = AVAudioSession.RouteChangeReason(rawValue: raw)
        guard reason == .newDeviceAvailable || reason == .oldDeviceUnavailable || reason == .override else { return }
        // 引擎多半自己会喊「配置变了」（onLost）；1.5 秒后再看一眼，话筒没声了就重开
        Task {
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            if let ear = self.ear, !self.rebuilding, !ear.healthy(within: 1.2) { self.rebuildEar("换了耳机", tell: false) }
        }
    }

    private func checkUp(_ ear: Ear) {
        guard let app else { return }
        let h = CompanionHealth(mic: true, live: live, mail: app.butler.relayUp, noise: ear.noise, echo: ear.echo)
        healthLine = h.line
        app.butler.lookCheck(h)
    }

    /// 117 陪玩开着大脑不下班：每 4 分钟敲一下大管家（深聊里不敲，深聊有自己的）
    private func armPing() {
        pingTimer?.invalidate()
        let t = Timer(timeInterval: 240, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.ear != nil, !self.deep else { return }
                self.app?.butler.lookWarm()
            }
        }
        RunLoop.main.add(t, forMode: .common)
        pingTimer = t
    }

    fileprivate func stopListening() {
        callTimer?.invalidate()                           // 139
        callTimer = nil
        callOn = false
        probeTimer?.invalidate()
        probeTimer = nil
        pingTimer?.invalidate()
        pingTimer = nil
        if deep { dropDeep() }
        ear?.stop()
        ear = nil
        if let id = current { app?.butler.forgetLook(id) }
        current = nil
        clock = nil
        parts = PartQueue()
        doneTotal = nil
        preID = nil
        preState = .none
        app?.butler.lookOff()                             // 117：这一场结束
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
        if callOn { line.heard(now: Date()) }             // 139：他说话了，60 秒从头数
        if phase == .listening || (deep && phase == .asking) {
            phase = .hearing
            alert = nil
        }
        if !deep { sendPre() }
    }

    /// 117 边说边传：他一开口就去取这一刻的截图、先寄出去（这一问将来的 id 先定下来）
    fileprivate func sendPre() {
        guard live, let app else { preID = nil; preState = .none; return }
        let qid = UUID().uuidString
        preID = qid
        preState = .pending
        Task {
            let r = await LiveLink.fetch(qid)
            var trouble: CompanionTrouble?
            switch r {
            case .frame(let d):
                let path = ButlerRequest.lookPrePath(qid)
                let req = ButlerRequest.lookPre(id: UUID().uuidString, question: qid, image: path, at: ISOTime.string(Date()),
                                                app: ButlerService.appVersion)
                app.butler.lookPre(req, files: [path: d])
                if self.preID == qid { self.preState = .sent }
                return
            case .noFrame: trouble = .noFrame
            case .refused: trouble = .frameRefused
            case .down:
                self.live = false
                trouble = .liveDown
            }
            if let trouble {
                if self.preID == qid {
                    self.preState = .failed(trouble)
                } else if self.current == qid {
                    self.notice(trouble)                        // 这一问已经寄了（说是先寄了图）：少了图照样答，说一声
                }
            }
        }
    }

    /// 他说完了（或者那一下不算一句）：回到「在听」，深聊里在等回答的回到「等」
    fileprivate var restPhase: Phase { deep && deepWaiting != nil ? .asking : .listening }

    /// 太短的一下（咔哒、咳嗽）：不算一句，记个数跟下一封信走
    private func dropped() {
        shorts += 1
        if phase == .hearing { phase = current != nil ? .asking : restPhase }
        playPending()
    }

    // ---------------------------------------------------------------- 问
    private func heard(_ wav: Data, seconds: Double, peak: Double, spokeEnd: Double) {
        if deep { return heardDeep(wav, seconds: seconds, peak: peak, spokeEnd: spokeEnd) }
        guard ear != nil, let app else { return }
        let id = preID ?? UUID().uuidString               // 117：截图先寄的那一问就用那个 id
        let st = preState
        preID = nil
        preState = .none
        if let old = current {                           // 上一句还在等 / 还在放：不要了，它的账先记上
            app.butler.forgetLook(old)
            ear?.stopPlaying()
            finishStats()
            parts = PartQueue()
            doneTotal = nil
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
            var pre = false
            var trouble: CompanionTrouble?
            switch st {
            case .sent, .pending:
                pre = true                                  // 图已经（或正在）先寄了，大管家那头等它 1.5 秒
            case .failed(let t):
                trouble = t
            case .none:
                if self.live {                              // 开口时没取（插嘴、刚开直播）：现在取
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
            }
            guard self.current == id else { return }
            self.clock?.frame = ProcessInfo.processInfo.systemUptime
            self.clock?.frameOK = pre || path != nil
            if let trouble { self.notice(trouble) }           // 少了图照样问，先说一声
            let req = ButlerRequest.look(id: id, question: "", audio: audioPath, image: path, at: ISOTime.string(Date()),
                                         app: ButlerService.appVersion, prev: prevSend, pre: pre, stream: true)
            let r = await app.butler.sendLook(req, files: files)
            guard self.current == id else { return }
            self.clock?.sent = ProcessInfo.processInfo.systemUptime
            switch r {
            case .sent(true):
                self.clock?.sentOK = true
                self.watch(id)
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

    /// 117：寄出去以后盯着：一档 45 秒、档越高越久没回音（每来一句重新算），还一句都没到就念「大管家没回」；放了几句、done 没来：收尾
    private func watch(_ id: String) {
        deadline = Date().addingTimeInterval(LookWait.seconds(gear: gear))
        Task {
            while self.current == id {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                guard self.current == id, let d = self.deadline, Date() > d else { continue }
                if self.parts.played == 0, self.phase == .asking {
                    self.giveUp(id, .noAnswer)
                } else if !(self.ear?.busy ?? false) {
                    self.answerFinished()
                }
                return
            }
        }
    }

    /// 这一问走不下去了：记账、红点、弹一行、念出来，念完接着听
    private func giveUp(_ id: String, _ t: CompanionTrouble) {
        app?.butler.forgetLook(id)
        current = nil
        parts = PartQueue()
        doneTotal = nil
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

    /// 大管家的回信到了（ButlerService 收信时叫）：117 起一句一句来（part），最后一封 done；老大管家还是一封带整段声音
    func answer(_ r: ButlerResult, audio: Data?) {
        if carried.contains(r.id) { return carriedAnswer(r, audio: audio) }    // 139：挂了以后才到的回答
        if deepSent.contains(r.id) { return deepAnswer(r, audio: audio) }
        if r.stage == "who" { return whoAnswer(r) }
        if let line = VoiceprintLine.of(r.timing) {
            voiceprintLine = line
            vpReady = (r.timing?["vpOK"] ?? 0) > 0
        }
        guard r.id == current, let ear else { return }        // 不是最新那一问的：不放（只要最新的）
        if let g = r.timing?["gear"], g >= 1, g <= 4 { gear = Int(g) }
        deadline = Date().addingTimeInterval(LookWait.seconds(gear: gear))
        if clock?.back == nil { clock?.back = ProcessInfo.processInfo.systemUptime }
        if r.stage == "part" {
            enqueue(parts.add(Int(r.timing?["part"] ?? 0), audio ?? Data()))
            return
        }
        // done（117）或者老的一封
        if let h = r.heard { lastHeard = h.isEmpty ? "（什么都没听出来）" : h }
        let timing = r.timing ?? [:]
        if (timing["notHim"] ?? 0) > 0 {                     // 不是他的声音：不答，接着听
            lastHeard = "（不是你的声音，没答）"
            current = nil
            parts = PartQueue()
            finishStats(butler: timing)
            if phase == .asking { phase = restPhase }
            return
        }
        let total = Int(timing["parts"] ?? 0)
        if total > 0 || parts.played > 0 {
            doneTotal = total
            doneTiming = timing
            if clock?.playing != nil { finishStats(butler: timing) } else { statsLater = true }
            partPlayed()
            Task {                                              // 落在后面的那几句：最多再等 4 秒
                try? await Task.sleep(nanoseconds: 4_000_000_000)
                guard self.current == r.id else { return }
                self.enqueue(self.parts.finish(total: total))
                if !(self.ear?.busy ?? false) { self.answerFinished() }
            }
            return
        }
        current = nil
        let missed = (timing["miss"] ?? 0) > 0
        if missed {
            alert = .misheard
            app?.show(CompanionTrouble.misheard.words, seconds: 4)
        }
        phase = .speaking
        let done: @Sendable () -> Void = { [weak self] in Task { @MainActor in self?.played() } }
        let started: @Sendable () -> Void = { [weak self] in Task { @MainActor in self?.playing(timing) } }
        if let audio {
            if ear.play(audio, started: started, done: done) { return }
            alert = .cantPlay                                   // 配好的声音坏了：弹一行
            app?.show(CompanionTrouble.cantPlay.words, seconds: 5)
        }
        let words = (r.text?.isEmpty == false ? r.text : nil) ?? (missed ? CompanionTrouble.misheard.words : CompanionTrouble.brainFailed.words)
        speakLine(words, started: started, done: done)
    }

    /// 117：按顺序到了的几句接着放
    private func enqueue(_ items: [Data]) {
        guard let ear, !items.isEmpty else { return }
        for d in items {
            let first = clock?.playing == nil
            let started: @Sendable () -> Void = { [weak self] in Task { @MainActor in if first { self?.partStarted() } } }
            let done: @Sendable () -> Void = { [weak self] in Task { @MainActor in self?.partPlayed() } }
            if !ear.enqueue(d, started: started, done: done) {
                alert = .cantPlay
            }
        }
        if phase == .asking || phase == .listening { phase = .speaking }
    }

    private func partStarted() {
        clock?.playing = ProcessInfo.processInfo.systemUptime
        clock?.playOK = true
        if let t = clock?.summary()["total"] { lastTotal = t }
        if statsLater {
            statsLater = false
            finishStats(butler: doneTiming)
        }
    }

    /// 放完一句：done 来了、该到的都到了、都放完了：这一问结束
    private func partPlayed() {
        guard current != nil, let ear, !ear.busy, let total = doneTotal, parts.next >= total else { return }
        answerFinished()
    }

    fileprivate func answerFinished() {
        if let id = current { app?.butler.forgetLook(id) }
        current = nil
        parts = PartQueue()
        doneTotal = nil
        if statsLater {
            statsLater = false
            finishStats(butler: doneTiming)
        }
        if ear != nil, phase == .speaking || phase == .asking { phase = restPhase }
        playPending()
    }

    /// 放到一半不放了（插嘴、话筒重开）
    fileprivate func dropAnswer() {
        ear?.stopPlaying()
        if let id = current { app?.butler.forgetLook(id) }
        current = nil
        parts = PartQueue()
        doneTotal = nil
        statsLater = false
        finishStats()
    }

    fileprivate func playing(_ butler: [String: Double]) {
        clock?.playing = ProcessInfo.processInfo.systemUptime
        clock?.playOK = true
        finishStats(butler: butler)
    }

    fileprivate func played() {
        if callOn { line.answered(now: Date()) }          // 139：它说完了，60 秒从这儿数
        if clock != nil {                                     // 放完了还没开始出声：没放出来
            clock?.playOK = false
            finishStats()
            alert = .cantPlay
            app?.show(CompanionTrouble.cantPlay.words, seconds: 5)
        }
        if ear != nil, phase == .speaking { phase = restPhase }
        playPending()
    }

    // ---------------------------------------------------------------- 插嘴（117）
    /// 他在回答放着的时候开口了（够响、够长）。声纹没建好：就是他（拿手机的人离话筒最近），马上停；建好了：头 1 秒寄去对声纹
    private func barge() {
        guard let ear else { return }
        if vpReady {
            ear.wantProbe()
            return
        }
        stopForHim()
    }

    /// 停念、丢掉没念完的，接着录他这句当新问题（截图也先寄）
    private func stopForHim() {
        dropAnswer()
        phase = .hearing
        alert = nil
        sendPre()
    }

    private func askWho(_ wav: Data) {
        guard let app, ear?.busy == true else { return }
        let id = UUID().uuidString
        whoID = id
        let path = ButlerRequest.lookWhoPath(id)
        let req = ButlerRequest.lookWho(id: id, audio: path, at: ISOTime.string(Date()), app: ButlerService.appVersion)
        Task {
            let r = await app.butler.sendLook(req, files: [path: wav])
            if case .sent(true) = r {
                try? await Task.sleep(nanoseconds: 2_500_000_000)
            }
            if self.whoID == id {                           // 问不了 / 2.5 秒没回：当是他
                self.whoID = nil
                app.butler.forgetLook(id)
                if self.ear?.busy == true { self.stopForHim() }
            }
        }
    }

    private func whoAnswer(_ r: ButlerResult) {
        if let h = hangWho, r.id == h.id {                // 139：说挂断词的是不是他
            hangWho = nil
            app?.butler.forgetLook(r.id)
            return h.done((r.timing?["him"] ?? 1) > 0)
        }
        guard r.id == whoID else { return }
        whoID = nil
        app?.butler.forgetLook(r.id)
        if (r.timing?["him"] ?? 1) > 0 {
            if ear?.busy == true { stopForHim() }
        } else {
            ear?.dropCurrentClip()                          // 别人在说话：接着念，这一句录音扔掉
        }
    }

    // ---------------------------------------------------------------- 说（117：固定的话放随 App 带的晓晓录音）
    /// 一句固定的话的晓晓录音（不是固定的话回 nil）
    fileprivate func line(_ words: String) -> Data? {
        guard let name = VoiceLines.file(for: words), let url = Bundle.main.url(forResource: name, withExtension: "mp3") else { return nil }
        return try? Data(contentsOf: url)
    }

    /// 走耳朵念一句：固定的话放晓晓录音，别的（大管家的回答字，声音坏了时）才用苹果的嗓子
    fileprivate func speakLine(_ words: String, started: @escaping @Sendable () -> Void, done: @escaping @Sendable () -> Void) {
        guard let ear else { return }
        if let d = line(words), ear.play(d, started: started, done: done) { return }
        ear.speak(words, voice: PhoneVoice.bestVoice("zh-CN"), started: started, done: done)
    }

    /// 念一句。在听就走耳朵；耳朵没开就直接放。念完：接着听 / 不管 / 撒手话筒
    fileprivate func say(_ words: String, after: After) {
        guard ear != nil else {
            if let d = line(words) {
                try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .default, options: [.mixWithOthers])
                try? AVAudioSession.sharedInstance().setActive(true)
                lineMouth = try? AVAudioPlayer(data: d)
                if lineMouth?.play() == true { return }
            }
            let u = AVSpeechUtterance(string: words)
            u.voice = PhoneVoice.bestVoice("zh-CN")
            mouth.speak(u)
            return
        }
        speakLine(words, started: {}, done: { [weak self] in
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
        if callOn { return hangUp(.button) }               // 139：电话里点「深聊」= 挂
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
        if current != nil { dropAnswer() }
        clock = nil
        preID = nil
        preState = .none
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

    /// 深聊里说完一句。139 电话里短的一句先在手机上认字：是挂断词（「不聊了」也算）就挂，不过信箱；别的照常寄
    fileprivate func heardDeep(_ wav: Data, seconds: Double, peak: Double, spokeEnd: Double = 0) {
        lastSpokeEnd = spokeEnd > 0 ? spokeEnd : ProcessInfo.processInfo.systemUptime
        guard callOn, seconds <= HangUp.maxSeconds else { return sendDeep(wav, seconds: seconds, peak: peak) }
        if phase == .hearing { phase = restPhase }
        let end = lastSpokeEnd
        Task {
            if let text = await self.reader.read(Wav.decode(wav)), HangUp.endsCall(text), await self.isHim(wav) {
                return self.hangUp(.words, spokeEnd: end)
            }
            guard self.deep else { return }
            self.sendDeep(wav, seconds: seconds, peak: peak)
        }
    }

    /// 录音寄给大管家（是不是在问它，它认完字判）。寄出去就回到在听
    fileprivate func sendDeep(_ wav: Data, seconds: Double, peak: Double) {
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
        guard deep else { return }                         // 139：已经挂了：不再念（会把会话又抢回来，别家的歌又停）
        alert = t
        guard limiter.allow("\(t)", now: Date()) else { return }
        app?.show(t.words, seconds: 5)
        say(t.words, after: .nothing)
    }

    /// 深聊的回信：ack（收到了）、end、topic、gear（117 换档）、answer / failed
    fileprivate func deepAnswer(_ r: ButlerResult, audio: Data?) {
        if let h = r.heard, !h.isEmpty { lastHeard = h }
        if let line = VoiceprintLine.of(r.timing) { voiceprintLine = line }
        switch r.stage {
        case "ack":
            if callOn {                                    // 139：在等的回答（挂了也不扔）、说完到第一声几秒
                line.asked(r.id)
                if let s = lastSpokeEnd, firstSound == nil { firstSound = ProcessInfo.processInfo.systemUptime - s }
            }
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
            if callOn { return hangUp(.butler) }           // 139：手机没认出来、大管家认出来的挂断词，电话里「不聊了」
            exitDeep(say: (r.text?.isEmpty == false ? r.text : nil) ?? Deep.saysEnd)
        case "topic":
            deepSent.remove(r.id)
            app?.butler.forgetLook(r.id)
            topic.renew()
            topic.asked(Date())
            armDeepIdle()
            say((r.text?.isEmpty == false ? r.text : nil) ?? Deep.saysTopic, after: .nothing)
        case "gear":                                       // 117：深聊里换档，念一句「三档」
            deepSent.remove(r.id)
            app?.butler.forgetLook(r.id)
            armDeepIdle()
            pending = (r, audio)
            playPending()
        default:                                           // answer / failed
            line.got(r.id)
            if callOn, let s = lastSpokeEnd, firstSound == nil { firstSound = ProcessInfo.processInfo.systemUptime - s }
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
        speakLine(words, started: {}, done: done)
    }

    // ---------------------------------------------------------------- 来电话、回到前台
    /// 来电话、闹钟、Siri、别的 App 把话筒打断了：挂了以后接着开；接不上整个重开（117）；还不行念出来、变红
    fileprivate func interrupted(began: Bool) {
        guard let ear, !began else { return }
        if ear.resume() { return }
        rebuildEar("被打断了", tell: true)
    }

    fileprivate func becameActive() {
        guard cutByCall else { return }
        cutByCall = false
        app?.show(CompanionTrouble.deepCut.words, action: app?.lang.t("companion.restart"), seconds: 10) { [weak self] in
            self?.startListening(deep: true)
        }
    }
}

// ================================================================ 打电话式（139）
/// 挂电话那几步接到耳朵上（顺序 YiyeKit CallLine 定：嘟嘟、停话筒、停放、放掉会话）
private final class EarPort: CallPort, @unchecked Sendable {
    let ear: Ear
    let release: @Sendable () -> Void
    init(ear: Ear, release: @escaping @Sendable () -> Void) { self.ear = ear; self.release = release }
    func beep(_ times: Int) { ear.beep(times) }
    func stopMic() { ear.deafen() }
    func stopPlaying() {}                                  // 嘟嘟已经顶掉了正在放的回答；嘟完连引擎一起停
    func releaseSession(notifyOthers: Bool) { release() } // 嘟完 ear.stop()：setActive(false, .notifyOthersOnDeactivation)
}

/// 截图、UI 测试（模拟器没有真话筒）：什么都不碰
private final class NoPort: CallPort {
    func beep(_ times: Int) {}
    func stopMic() {}
    func stopPlaying() {}
    func releaseSession(notifyOthers: Bool) {}
}

extension Companion {
    /// 「叫大管家」（Siri、捷径、侧键）：接通，就是深聊那套（停 1.5 秒自动发，带搜索答）。
    /// 陪玩开着：陪玩里转深聊（声音照陪玩：混着、压低）；没开：开一只电话耳朵（别家的歌停、戴蓝牙耳机用耳机的麦）
    func startCall() {
        guard let app else { return }
        if callOn { ear?.beep(1); return }
        if app.demo != nil { return demoCall() }
        heldOff = false
        firstSound = nil
        Task { await reader.prepare() }
        if let ear {
            if !deep { beginDeep() }
            ear.beep(1)
            connected(companion: true)
        } else {
            startListening(deep: true, call: true)
        }
    }

    /// 意图用：接通，等话筒真开了（最多 3 秒）。返回接通没有（锁屏里系统不让开话筒就是 false）
    func startCallWaiting() async -> Bool {
        startCall()
        for _ in 0..<30 {
            if callOn { return true }
            if case .failed = phase { return false }
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        return callOn
    }

    /// 接通了（嘟一声已经响了）
    fileprivate func connected(companion: Bool) {
        guard let app else { return }
        line = CallLine(idleOn: app.settings.callLockOK)
        line.connect(now: Date(), companion: companion)
        callOn = true
        if !UIApplication.shared.isProtectedDataAvailable {      // 锁着屏接通过：锁屏喊得回来，答完 60 秒没话自己挂可以开
            app.settings.callLockOK = true
            line.idleOn = true
        }
        callTimer?.invalidate()
        let t = Timer(timeInterval: 5, repeats: true) { [weak self] _ in Task { @MainActor in self?.callTick() } }
        RunLoop.main.add(t, forMode: .common)
        callTimer = t
        // 上回挂了以后才到的回答：先提一句
        if let words = CallLine.carryLine(titles: app.settings.callCarry, zh: app.lang.isZh) {
            app.settings.callCarry = []
            say(words, after: .nothing)
        }
    }

    private func callTick() {
        guard callOn, let ear else { return }
        let busy = ear.busy || phase == .hearing || deepWaiting != nil || pending != nil
        if line.idleDue(now: Date(), busy: busy) { hangUp(.idle) }
    }

    /// 挂：嘟嘟两声、话筒马上不听、嘟完停引擎放掉会话（别家的歌自己接着放）。还在等的回答不扔；陪玩开着也整个停。
    /// spokeEnd：他说完挂断词的那一刻（量「说挂掉到挂断」几秒）
    func hangUp(_ why: CallLine.Why, spokeEnd: Double? = nil) {
        guard callOn else { return }
        guard let ear else { callOn = false; return }
        let beepAt = ProcessInfo.processInfo.systemUptime
        let port = EarPort(ear: ear) { [weak self] in
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 650_000_000)     // 嘟嘟放完
                guard let self, self.ear === ear else { return }
                self.stopListening()
                self.phase = .off
                self.alert = nil
            }
        }
        let left = line.hangUp(why, port: port)
        callOn = false
        if live { heldOff = true }                      // 陪玩开着说挂：整个陪玩都停（直播还开着也不再自己接着听）
        carried.formUnion(left)
        deepSent.subtract(left)                         // dropDeep 不把它们忘掉：回答到了照样收
        if let w = deepWaiting, left.contains(w) { deepWaiting = nil }
        callTimer?.invalidate()
        callTimer = nil
        var parts: [String] = []
        if let f = firstSound { parts.append(String(format: "说完到第一声 %.1f 秒", f)) }
        if let s = spokeEnd { parts.append(String(format: "说挂掉到挂断 %.1f 秒", beepAt - s)) }
        if !parts.isEmpty { callTimes = "电话：" + parts.joined(separator: " · ") }
        app?.show(app?.lang.t("call.hungUp") ?? "", seconds: 3)
    }

    /// 挂了以后才到的回答：不念，存进深聊，下次接通先提一句
    fileprivate func carriedAnswer(_ r: ButlerResult, audio: Data?) {
        guard r.stage != "ack" else { return }
        carried.remove(r.id)
        app?.butler.forgetLook(r.id)
        guard let app, r.stage == "answer", let text = r.text, !text.isEmpty else { return }
        app.addDeepNote(id: r.id, title: r.title ?? "", text: text, audio: audio)
        let title = (r.title?.isEmpty == false ? r.title! : String(text.prefix(12)))
        app.settings.callCarry = Array((app.settings.callCarry + [title]).suffix(3))
    }

    /// 117 的声纹建好了：说挂断词的是不是他（别人说「拜拜」不算）。问不了、2 秒没回：当是他（信箱断了也挂得掉）
    fileprivate func isHim(_ wav: Data) async -> Bool {
        guard vpReady, let app else { return true }
        let id = UUID().uuidString
        let path = ButlerRequest.lookWhoPath(id)
        let req = ButlerRequest.lookWho(id: id, audio: path, at: ISOTime.string(Date()), app: ButlerService.appVersion)
        return await withCheckedContinuation { (c: CheckedContinuation<Bool, Never>) in
            let once = Once()
            let finish: (Bool) -> Void = { him in if once.take() { c.resume(returning: him) } }
            self.hangWho = (id, finish)
            Task {
                let r = await app.butler.sendLook(req, files: [path: wav])
                if case .sent(true) = r { try? await Task.sleep(nanoseconds: 2_000_000_000) }
                if self.hangWho?.id == id { self.hangWho = nil }
                app.butler.forgetLook(id)
                finish(true)
            }
        }
    }

    /// 截图、UI 测试：假装接通（模拟器没有真话筒、没有信箱）。-YiyeCallSay「书童做完没|挂掉」：每 2.5 秒当他说了一句，
    /// 不是挂断词的当问了、答了；挂断词照手机本地的规矩挂
    fileprivate func demoCall() {
        line = CallLine(idleOn: false)
        line.connect(now: Date(), companion: false)
        callOn = true
        deep = true
        phase = .listening
        let says = (UserDefaults.standard.string(forKey: "YiyeCallSay") ?? "").split(separator: "|").map(String.init)
        Task {
            for s in says {
                try? await Task.sleep(nanoseconds: 2_500_000_000)
                guard self.callOn else { return }
                if HangUp.endsCall(s) {
                    self.line.hangUp(.words, port: NoPort())
                    self.callOn = false
                    self.deep = false
                    self.phase = .off
                    self.callTimes = "电话：说挂掉到挂断 0.0 秒（模拟器）"
                    self.app?.show(self.app?.lang.t("call.hungUp") ?? "", seconds: 3)
                    return
                }
                self.lastHeard = s
                self.phase = .asking
                try? await Task.sleep(nanoseconds: 1_500_000_000)
                guard self.callOn else { return }
                self.phase = .speaking
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                guard self.callOn else { return }
                self.phase = .listening
            }
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
/// 一个 AVAudioEngine 从开到关一直跑着（后台不能随便重新开话筒，所以不停；117：系统把它停了，Companion 整个换一只新的）：
/// - 话筒开回声消除（voice processing），别的 App 的声音在有人说话时压低（advanced ducking），自己放的回答不会被自己听进去；
/// - 每一小块转成 16 kHz 单声道交给 ClipCutter：判开口、说完，开口前 0.3 秒一起要，最长 20 秒；说完把这一句编成 WAV 交出去（108）；
/// - 放回答时（117）照样判开口，但要更响、更长（插嘴，onBarge）；叮、念一句以后再等 0.3 秒；
/// - 回答一句一句排着放（enqueue），插嘴时 stopPlaying 全停。
final class Ear: @unchecked Sendable {
    /// 139：电话耳朵（不跟别家的声音混：歌停，挂了接着放；戴蓝牙耳机用耳机的麦）
    let call: Bool
    private var deaf = false
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
    /// 排着、正在放的段数（0 = 没在放）
    private var queued = 0
    private var playGen = 0
    private var running = false
    private var lastBuffer: Double = 0
    private var probeWanted = false
    private var dropClip = false
    private var configObserver: NSObjectProtocol?
    /// 回声消除开上了没有（体检用）
    private(set) var echo = false

    var onStart: (@Sendable () -> Void)?
    /// 一句说完：WAV、录了几秒、最响一块的 dB、说完的那一刻（systemUptime）
    var onClip: (@Sendable (Data, Double, Double, Double) -> Void)?
    var onDrop: (@Sendable () -> Void)?
    /// 117：放回答时他开口了（够响、够长）
    var onBarge: (@Sendable () -> Void)?
    /// 117：插嘴那一句的头 1 秒（要对声纹时）
    var onProbe: (@Sendable (Data) -> Void)?
    /// 117：系统把引擎停了 / 换了配置（换耳机）
    var onLost: (@Sendable (String) -> Void)?

    init(call: Bool = false) { self.call = call }

    /// 门槛现在的底噪（dBFS）
    var noise: Double {
        lock.lock(); defer { lock.unlock() }
        return cutter.noise
    }

    /// 在放回答（或叮、念的一句）
    var busy: Bool {
        lock.lock(); defer { lock.unlock() }
        return queued > 0
    }

    /// 117 不聋：引擎在转、最近 within 秒里有声音块进来
    func healthy(within: Double = 6) -> Bool {
        lock.lock()
        let last = lastBuffer, run = running
        lock.unlock()
        return run && engine.isRunning && ProcessInfo.processInfo.systemUptime - last < within
    }

    func start() throws {
        let s = AVAudioSession.sharedInstance()
        if call {
            // 139：跟打电话一样，别家的歌停（不带 mixWithOthers），挂的时候 notifyOthersOnDeactivation 叫它接着放；
            // 戴蓝牙耳机：用耳机的麦（HFP），挂了歌回 A2DP 原音质
            try s.setCategory(.playAndRecord, mode: .default, options: Ear.callOptions)
        } else {
            try s.setCategory(.playAndRecord, mode: .default, options: [.mixWithOthers, .defaultToSpeaker, .allowBluetoothA2DP])
        }
        try s.setActive(true)
        let input = engine.inputNode
        do {
            try input.setVoiceProcessingEnabled(true)
            if !call {
                input.voiceProcessingOtherAudioDuckingConfiguration = AVAudioVoiceProcessingOtherAudioDuckingConfiguration(
                    enableAdvancedDucking: true, duckingLevel: .mid)
            }
            echo = true
        } catch {
            echo = false        // 没有回声消除也照样能用：放回答时只认更响的插嘴
        }
        engine.attach(player)
        engine.connect(player, to: engine.mainMixerNode, format: playFormat)
        input.installTap(onBus: 0, bufferSize: 1024, format: nil) { [weak self] buf, _ in self?.hear(buf) }
        engine.prepare()
        try engine.start()
        lock.lock()
        running = true
        lastBuffer = ProcessInfo.processInfo.systemUptime
        cutter.gate.strictFloor = echo ? -38 : -25        // 117：没有回声消除，自己放的声音也进话筒：插嘴要更响
        lock.unlock()
        configObserver = NotificationCenter.default.addObserver(forName: .AVAudioEngineConfigurationChange, object: engine, queue: nil) { [weak self] _ in
            self?.onLost?("话筒的配置变了")
        }
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
            lock.lock()
            lastBuffer = ProcessInfo.processInfo.systemUptime
            lock.unlock()
            return true
        } catch {
            return false
        }
    }

    func stop() {
        if let o = configObserver { NotificationCenter.default.removeObserver(o) }
        configObserver = nil
        lock.lock()
        running = false
        cutter = ClipCutter()
        queued = 0
        playGen += 1
        lock.unlock()
        player.stop()
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        synth.stopSpeaking(at: .immediate)
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    /// 139 挂了：话筒马上不听（引擎还转着，把嘟嘟放完）
    func deafen() {
        lock.lock()
        deaf = true
        lock.unlock()
    }

    /// 139：电话的音频会话选项。蓝牙耳机用它的麦：iOS 26 的 AirPods 高音质收音（bluetoothHighQualityRecording），
    /// 耳机不支持就退到 HFP（allowBluetoothHFP，SDK 写明两个一起给时 HFP 兜底）。挂了会话一放，歌回 A2DP 原音质
    static var callOptions: AVAudioSession.CategoryOptions {
        [.defaultToSpeaker, .allowBluetoothHFP, .bluetoothHighQualityRecording]
    }

    /// 117 插嘴：这一句的头 1 秒交出去对声纹
    func wantProbe() {
        lock.lock()
        probeWanted = true
        lock.unlock()
    }

    /// 117 插嘴的是别人：这一句录完扔掉
    func dropCurrentClip() {
        lock.lock()
        if cutter.speaking { dropClip = true }
        lock.unlock()
    }

    // ---------------------------------------------------------------- 听
    private func hear(_ buf: AVAudioPCMBuffer) {
        guard buf.frameLength > 0, let samples = toEar(buf), !samples.isEmpty else { return }
        let now = ProcessInfo.processInfo.systemUptime
        lock.lock()
        guard running, !deaf else { lock.unlock(); return }
        lastBuffer = now
        let playing = queued > 0
        let mute = !playing && now < mutedUntil
        let ev = cutter.feed(samples, mute: mute, strict: playing)
        var probe: Data?
        if probeWanted, cutter.speaking, cutter.clip.count >= ClipCutter.rate {
            probeWanted = false
            probe = Wav.encode(Array(cutter.clip.prefix(ClipCutter.rate)))
        }
        var dropThis = false
        if case .clip? = ev { dropThis = dropClip; dropClip = false }
        if case .tooShort? = ev { dropClip = false; probeWanted = false }
        let endSilence = cutter.gate.endSilenceMs / 1000
        let maxSeconds = cutter.maxSeconds
        let startCB = onStart, dropCB = onDrop, clipCB = onClip, bargeCB = onBarge, probeCB = onProbe
        lock.unlock()
        if let probe { probeCB?(probe) }
        switch ev {
        case .start?:
            if playing { bargeCB?() } else { startCB?() }
        case .tooShort?:
            dropCB?()
        case .clip(let s, let secs, let peak)?:
            if dropThis {
                dropCB?()
                return
            }
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
        schedule(buf, started: {}, done: {}, interrupt: true)
    }

    /// 139：电话的「嘟」：接通 1 声，挂断 2 声（425 Hz，像电话）
    func beep(_ times: Int) {
        let sr = playFormat.sampleRate
        let on = Int(0.16 * sr), off = Int(0.11 * sr)
        let total = max(1, times) * (on + off)
        guard let buf = AVAudioPCMBuffer(pcmFormat: playFormat, frameCapacity: AVAudioFrameCount(total)), let d = buf.floatChannelData else { return }
        for i in 0..<total {
            let k = i % (on + off)
            guard k < on else { d[0][i] = 0; continue }
            let fade = min(1, Double(k) / (0.005 * sr), Double(on - k) / (0.02 * sr))
            d[0][i] = Float(sin(2 * Double.pi * 425 * Double(k) / sr) * 0.25 * fade)
        }
        buf.frameLength = AVAudioFrameCount(total)
        schedule(buf, started: {}, done: {}, interrupt: true)
    }

    /// mp3 → 放的格式。坏的回 nil
    private func decode(_ data: Data) -> AVAudioPCMBuffer? {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("yiye-\(UUID().uuidString).mp3")
        defer { try? FileManager.default.removeItem(at: url) }
        do {
            try data.write(to: url, options: .atomic)
            let f = try AVAudioFile(forReading: url)
            guard let raw = AVAudioPCMBuffer(pcmFormat: f.processingFormat, frameCapacity: AVAudioFrameCount(f.length)) else { return nil }
            try f.read(into: raw)
            return Ear.convert(raw, to: playFormat)
        } catch {
            return nil
        }
    }

    /// 放一段 mp3（顶掉正在放的）。放不了（坏的）返回 false
    func play(_ data: Data, started: @escaping @Sendable () -> Void, done: @escaping @Sendable () -> Void) -> Bool {
        guard let buf = decode(data) else { return false }
        schedule(buf, started: started, done: done, interrupt: true)
        return true
    }

    /// 117：回答的下一句，排在正在放的后面
    func enqueue(_ data: Data, started: @escaping @Sendable () -> Void, done: @escaping @Sendable () -> Void) -> Bool {
        guard let buf = decode(data) else { return false }
        schedule(buf, started: started, done: done, interrupt: false)
        return true
    }

    /// 117 插嘴：全停，排着的也不要了。他正说着：不压门槛
    func stopPlaying() {
        lock.lock()
        playGen += 1
        queued = 0
        mutedUntil = 0
        lock.unlock()
        player.stop()
        synth.stopSpeaking(at: .immediate)
    }

    /// 用苹果的中文嗓子念一句（只给不是固定的话用：大管家配的声音坏了时的回答字）。合成出不来声音就直接让系统念
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
                    self.schedule(one, started: started, done: done, interrupt: true)
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

    /// interrupt：顶掉正在放的（叮、念的一句、老的一整段）；不顶：排在后面（回答的下一句）
    private func schedule(_ buf: AVAudioPCMBuffer, started: @escaping @Sendable () -> Void, done: @escaping @Sendable () -> Void, interrupt: Bool) {
        lock.lock()
        guard running else { lock.unlock(); return done() }
        if interrupt {
            playGen += 1
            queued = 0
        }
        queued += 1
        let g = playGen
        lock.unlock()
        if interrupt { player.stop() }
        player.scheduleBuffer(buf, at: nil, options: [], completionCallbackType: .dataPlayedBack) { [weak self] _ in
            guard let self else { return }
            self.lock.lock()
            if self.playGen == g {                      // 被顶掉、被插嘴停掉的那几段不算放完
                self.queued = max(0, self.queued - 1)
                if self.queued == 0 { self.mutedUntil = ProcessInfo.processInfo.systemUptime + 0.3 }
            }
            self.lock.unlock()
            done()
        }
        if !engine.isRunning { try? engine.start() }
        if !player.isPlaying { player.play() }
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
