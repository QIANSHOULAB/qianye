import AVFoundation
import Observation
import SwiftUI
import UIKit
import YiyeKit

/// 137 书童「开口说」（Song 11-25 07:42：「我可以语音实时给他对话……我告诉他我想做什么，然后他就直接做」）。
/// 聊天窗里一个键：一按像打电话，一来一回；再按一下、或者说「好了」退出，回到打字。声音链路照陪玩（117）那套，不另起炉灶：
/// - 一只耳朵（Companion.swift 的 Ear）：回声消除、判开口、停 0.8 秒算说完、这一句录成 16 kHz WAV；叮一声开始听。
/// - 这一句寄给大管家（只走信箱）：SenseVoice 认字（带他的口音表）、对声纹（别人说的不算）；「撤销」「对」「不对」「好了」本地认，
///   别的交给这一场一直开着的大脑；回动作 + 晓晓配好的一句。
/// - 说了就做：改标题、挪、收拾、置顶直接做，念回执；扔、合并先念「要扔这几条，对吗？」，他说「对」才做，「不对」、20 秒不吭声都不做。
///   「撤销」撤最近一批。
/// - 字幕：他说的每一句认出来的字出在聊天窗里，认歪了点「改字」，改完照改后的再办一遍。
/// - 插嘴：它说话时他一开口就停（声纹建好了先对 1 秒声纹）。不聋：话筒被系统停了整个重开；15 秒看一次还有没有声音进来。
/// - 出错念一句人话（固定的话都是随 App 带的晓晓录音）；每一句量秒数（说完 → 寄出 → 回信 → 做完 → 出声），跟下一封信走。
/// - 锁屏、切走就停，回来接着打字。
@MainActor @Observable
final class ShutongTalker {
    static let shared = ShutongTalker()

    enum Phase: Equatable { case off, listening, hearing, thinking, speaking }

    private(set) var phase: Phase = .off
    var on: Bool { phase != .off }

    @ObservationIgnored weak var app: AppModel?
    @ObservationIgnored private var ear: Ear?
    /// 在等回信的那一句：请求 id、聊天窗里那一行（字幕）、第几轮（大脑要全文再寄一轮）
    @ObservationIgnored private var current: (rid: String, line: UUID, round: Int)?
    @ObservationIgnored private var clock: TalkClock?
    @ObservationIgnored private var prev: [String: Double] = [:]
    @ObservationIgnored private var probeTimer: Timer?
    @ObservationIgnored private var pingTimer: Timer?
    @ObservationIgnored private var nodTask: Task<Void, Never>?
    @ObservationIgnored private var vpReady = false
    @ObservationIgnored private var whoID: String?
    /// 170：这一场的耳朵管家（跟陪玩同一套：「配置变了」先等一等再看、开不起来再试、回声消除退路、重开太多回就停）
    @ObservationIgnored private var keeper: EarKeeper<Ear>?
    @ObservationIgnored private var tellBack = false
    private var rebuilding: Bool { keeper?.busy ?? false }
    @ObservationIgnored private var observers: [NSObjectProtocol] = []
    /// 念完这一句以后接着干的（念完问句开始等点头、念完「好，回去打字」退出）
    @ObservationIgnored private var afterSpeak: (() -> Void)?
    @ObservationIgnored private var fakeSaid = ""

    private var m: ShutongModel { ShutongModel.shared }
    private var demo: Bool { app?.demo != nil }
    private func t(_ k: String) -> String { app?.lang.t(k) ?? k }
    private var now: Double { ProcessInfo.processInfo.systemUptime }

    // ---------------------------------------------------------------- 开、关
    /// 聊天窗里那个键：没开就开，开着就关
    func toggle() {
        if on { stop() } else { start() }
    }

    func start() {
        guard let app, phase == .off else { return }
        if app.companion.holdsButler { app.show(t("shutong.talkBusy")); return }
        if m.recording || m.hearing { return }
        m.load()
        if demo {
            phase = .listening
            return
        }
        Task {
            guard await AVAudioApplication.requestRecordPermission() else { app.show(self.t("shutong.micDenied")); return }
            guard self.phase == .off, self.keeper == nil else { return }
            let k = self.makeKeeper()
            self.keeper = k
            do {
                let e = try await k.open()                       // 170：在耳朵队列上开（不卡界面），最多试 3 次
                guard self.keeper === k, self.phase == .off else { Ear.release(e); return }
                self.ear = e
            } catch {
                guard self.keeper === k else { return }
                self.keeper = nil
                Ear.releaseSession()
                let detail = EarText.detail(error)
                EarText.log("小书童开话筒", detail)
                EarDiagSender.shared.send(EarDiag(kind: .failed, entry: .shutong, line: "开话筒：\(detail)", code: (error as NSError).code))
                app.show(app.lang.f("shutong.micFailed", detail))
                return
            }
            self.phase = .listening
            self.observe()
            app.butler.start()
            self.warm()
            self.ear?.chime()
            let probe = Timer(timeInterval: 15, repeats: true) { [weak self] _ in
                Task { @MainActor in
                    guard let self, let ear = self.ear, !self.rebuilding, !ear.healthy() else { return }
                    self.rebuild("话筒没声音了", tell: true)
                }
            }
            RunLoop.main.add(probe, forMode: .common)
            self.probeTimer = probe
            let ping = Timer(timeInterval: TalkTiming.ping, repeats: true) { [weak self] _ in
                Task { @MainActor in if self?.on == true { self?.warm() } }
            }
            RunLoop.main.add(ping, forMode: .common)
            self.pingTimer = ping
        }
    }

    /// 退出。words：先念这句再撒手话筒（「好，回去打字」）
    func stop(say words: String? = nil) {
        guard on else { return }
        if let words, ear != nil {
            phase = .speaking
            afterSpeak = { [weak self] in self?.teardown() }
            speakFixed(words)
            Task {                                              // 念不出来也最多等 5 秒
                try? await Task.sleep(nanoseconds: 5_000_000_000)
                if self.phase == .speaking, self.afterSpeak != nil { self.teardown() }
            }
            return
        }
        teardown()
    }

    private func teardown() {
        probeTimer?.invalidate(); probeTimer = nil
        pingTimer?.invalidate(); pingTimer = nil
        nodTask?.cancel(); nodTask = nil
        afterSpeak = nil
        for o in observers { NotificationCenter.default.removeObserver(o) }
        observers = []
        let k = keeper
        keeper = nil
        let old = k?.close() ?? ear                          // 170：在重开的那只也一起停
        ear = nil
        if let old { Ear.release(old) }
        if let cur = current {
            app?.butler.forgetTalk(cur.rid)
            m.talkSet(cur.line, state: "failed")
        }
        current = nil
        if m.talkPending != nil { m.talkNod(false) }            // 还在等他点头的：不办
        finishStats()
        phase = .off
        if !demo {
            app?.butler.sendTalkNote(.shutongTalkOff(id: UUID().uuidString, at: ISOTime.string(Date()), app: ButlerService.appVersion))
        }
    }

    /// 锁屏、切走（AppModel 在退到后台时叫）：停，回来接着打字
    func wentAway() {
        if !on, let k = keeper {                                // 170：话筒还在开（没开好）就切走了：不开了
            keeper = nil
            if let e = k.close() { Ear.release(e) }
            return
        }
        guard on else { return }
        teardown()
        m.talkNote(t("shutong.talkAway"))
    }

    /// 进来、每 4 分钟敲一下：大管家把耳朵和这一场的大脑热着（先看一遍目录）
    private func warm() {
        guard let app, !demo else { return }
        let req = ButlerRequest.shutongTalkWarm(id: UUID().uuidString, ask: m.talkAsk(confirming: false), at: ISOTime.string(Date()),
                                                app: ButlerService.appVersion, prev: takePrev())
        app.butler.sendTalkNote(req)
    }

    // ---------------------------------------------------------------- 耳朵
    /// 170：耳朵管家（跟陪玩同一套）
    private func makeKeeper() -> EarKeeper<Ear> {
        let k = EarKeeper<Ear>(.init(make: { [weak self] echo in
            guard let self else { throw CancellationError() }
            return try await self.makeEar(echo: echo)
        }, release: { e, keep in
            await Ear.later { e.stop(keepSession: keep) }
        }, running: { $0.healthy(within: 1.0) }, startedAt: { $0.startedAt }))
        k.onRebuilding = { [weak self] _ in self?.ear = nil }
        k.onRebuilt = { [weak self] e, why, took in
            guard let self else { return }
            self.ear = e
            if self.phase == .speaking || self.phase == .hearing { self.phase = .listening }
            if self.tellBack { self.speakFixed(CompanionTrouble.earBack.words) }
            self.tellBack = false
            if let k = self.keeper {
                EarDiagSender.shared.send(EarDiag(kind: .rebuilt, entry: .shutong, line: why, rebuilds: k.rules.rebuilds,
                                                  ignored: k.rules.ignored, echo: e.echo, took: took))
            }
        }
        k.onGaveUp = { [weak self] why, err in
            guard let self else { return }
            let detail = err.map { EarText.detail($0) } ?? "一分钟里重开了 \(self.keeper?.rules.rebuilds ?? 0) 回还是不稳，先停了"
            EarText.log(why, detail)
            EarDiagSender.shared.send(EarDiag(kind: err == nil ? .gaveUp : .failed, entry: .shutong, line: "\(why)：\(detail)",
                                              code: err.map { ($0 as NSError).code }, rebuilds: self.keeper?.rules.rebuilds ?? 0,
                                              ignored: self.keeper?.rules.ignored ?? 0, echo: !(self.keeper?.rules.echoOff ?? false)))
            self.app?.show(CompanionTrouble.earLost.words + "：" + why + "：" + detail, seconds: 6)
            self.teardown()
        }
        return k
    }

    private func makeEar(echo: Bool) async throws -> Ear {
        let ear = Ear(echo: echo)
        ear.onStart = { [weak self] in Task { @MainActor in self?.heardStart() } }
        ear.onClip = { [weak self] wav, secs, _, end in Task { @MainActor in self?.heard(wav, seconds: secs, spokeEnd: end) } }
        ear.onDrop = { [weak self] in Task { @MainActor in self?.dropped() } }
        ear.onBarge = { [weak self] in Task { @MainActor in self?.barge() } }
        ear.onProbe = { [weak self] wav in Task { @MainActor in self?.askWho(wav) } }
        ear.onLost = { [weak self, weak ear] why in
            Task { @MainActor in
                guard let self, let ear else { return }
                self.keeper?.configChanged(ear, why: why)        // 170：先等一等、看一眼，真停了才重开
            }
        }
        do {
            try await Ear.run { try ear.start() }
        } catch {
            await Ear.later { ear.stop(keepSession: true) }
            throw error
        }
        return ear
    }

    /// 不聋：话筒被系统停了（来电、Siri、换耳机、媒体服务重置）：整只耳朵重开；重开不了念出来、退出
    private func rebuild(_ why: String, tell: Bool) {
        guard let k = keeper, !k.busy, ear != nil else { return }
        tellBack = tell
        Task { await k.rebuild(why) }
    }

    private func observe() {
        let nc = NotificationCenter.default
        observers.append(nc.addObserver(forName: AVAudioSession.interruptionNotification, object: nil, queue: .main) { [weak self] n in
            let raw = (n.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt) ?? 0
            let began = AVAudioSession.InterruptionType(rawValue: raw) == .began
            MainActor.assumeIsolated {
                guard let self, let ear = self.ear, !began else { return }
                if !ear.resume() { self.rebuild("被打断了", tell: true) }
            }
        })
        observers.append(nc.addObserver(forName: AVAudioSession.routeChangeNotification, object: nil, queue: .main) { [weak self] n in
            let raw = (n.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt) ?? 0
            MainActor.assumeIsolated {
                let reason = AVAudioSession.RouteChangeReason(rawValue: raw)
                guard reason == .newDeviceAvailable || reason == .oldDeviceUnavailable || reason == .override else { return }
                Task { @MainActor in
                    try? await Task.sleep(nanoseconds: 1_500_000_000)
                    if let self, let ear = self.ear, !self.rebuilding, !ear.healthy(within: 1.2) { self.rebuild("换了耳机", tell: false) }
                }
            }
        })
        observers.append(nc.addObserver(forName: AVAudioSession.mediaServicesWereResetNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.rebuild("媒体服务重置", tell: true) }
        })
        observers.append(nc.addObserver(forName: UIApplication.protectedDataWillBecomeUnavailableNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.wentAway() }                   // 锁屏
        })
    }

    private func heardStart() {
        nodTask?.cancel()                                     // 他开口了：不算不吭声
        if phase == .listening { phase = .hearing }
    }

    private func dropped() {
        if phase == .hearing { phase = current == nil ? .listening : .thinking }
        if m.talkPending != nil, current == nil, nodTask == nil { armNod() }
    }

    // ---------------------------------------------------------------- 说一句
    /// Demo（截图、UI 测试）：没有话筒，假装他说了这一句
    func fakeHeard(_ text: String) {
        let s = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard demo, on, !s.isEmpty else { return }
        fakeSaid = s
        heard(TalkDemo.clip(), seconds: 0.6, spokeEnd: now)
    }

    private func heard(_ wav: Data, seconds: Double, spokeEnd: Double) {
        guard let app, on else { return }
        nodTask?.cancel(); nodTask = nil
        if let old = current {                                 // 上一句还没回：只要最新的（那一行留着能点「再问一次」）
            app.butler.forgetTalk(old.rid)
            m.talkSet(old.line, state: "failed")
            finishStats()
        }
        if ear?.busy == true { ear?.stopPlaying() }
        afterSpeak = nil
        let rid = UUID().uuidString
        let line = m.talkLine(rid: rid)
        current = (rid, line, 1)
        clock = TalkClock(spokeEnd: spokeEnd, rec: seconds)
        phase = .thinking
        let path = ButlerRequest.talkAudioPath(rid)
        let req = ButlerRequest.shutongTalk(id: rid, audio: path, text: "", ask: m.talkAsk(confirming: m.talkPending != nil),
                                            at: ISOTime.string(Date()), app: ButlerService.appVersion, prev: takePrev())
        send(req, files: [path: wav])
    }

    /// 字幕认歪了，他改了字：照改后的再办一遍（开口说关着就当打字发）
    func resend(_ lineID: UUID, text: String) {
        let s = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !s.isEmpty else { return }
        guard on else {
            m.input = s
            m.send()
            return
        }
        if let old = current { app?.butler.forgetTalk(old.rid) }
        let rid = UUID().uuidString
        m.talkSet(lineID, text: s, state: "waiting", rid: rid)
        current = (rid, lineID, 1)
        clock = nil
        phase = .thinking
        fakeSaid = s
        let req = ButlerRequest.shutongTalk(id: rid, audio: nil, text: s, ask: m.talkAsk(confirming: m.talkPending != nil),
                                            at: ISOTime.string(Date()), app: ButlerService.appVersion, prev: takePrev())
        send(req, files: [:])
    }

    private func send(_ req: ButlerRequest, files: [String: Data]) {
        guard let app else { return }
        if demo { return fake(req) }
        let rid = req.id
        Task {
            let r = await app.butler.sendTalk(req, files: files)
            guard self.current?.rid == rid else { return }
            self.clock?.sent = self.now
            switch r {
            case .sent(true): self.watch(rid)
            case .sent(false): self.trouble(.away)
            case .noPair: self.trouble(.noPair)
            case .failed: self.trouble(.noMail)
            }
        }
    }

    /// 寄出去 45 秒没回：念「大管家没回」
    private func watch(_ rid: String) {
        Task {
            try? await Task.sleep(nanoseconds: UInt64(TalkTiming.answerWait * 1_000_000_000))
            if self.current?.rid == rid { self.trouble(.noAnswer) }
        }
    }

    /// 这一句走不下去了：那一行标红（能点「再问一次」）、弹一行、念出来，念完接着听
    private func trouble(_ tr: CompanionTrouble) {
        if let cur = current {
            app?.butler.forgetTalk(cur.rid)
            m.talkSet(cur.line, state: "failed")
        }
        current = nil
        finishStats()
        app?.show(tr.words, seconds: 5)
        speakFixed(tr.words)
    }

    // ---------------------------------------------------------------- 回信
    func answer(_ r: ButlerResult, audio: Data?) {
        if r.stage == "who" { return whoAnswer(r) }
        guard on, let cur = current, cur.rid == r.id else { return }   // 不是最新那一句的：不要
        clock?.back = now
        if let v = r.timing?["vpOK"] { vpReady = v > 0 }
        let rep = r.shutong
        let cmd = TalkCmd.of(rep?.cmd)
        clock?.cmd = cmd.rawValue
        if let h = r.heard?.trimmingCharacters(in: .whitespacesAndNewlines) {
            m.talkSet(cur.line, text: h.isEmpty ? t("shutong.talkMissed") : h)
        }
        if cmd == .need, cur.round < 2, let need = rep?.need, !need.isEmpty {   // 大脑要看全文：再寄一轮（不再认字）
            let rid = UUID().uuidString
            let heard = (r.heard ?? fakeSaid).trimmingCharacters(in: .whitespacesAndNewlines)
            m.talkSet(cur.line, rid: rid)
            current = (rid, cur.line, 2)
            let req = ButlerRequest.shutongTalk(id: rid, audio: nil, text: heard,
                                                ask: m.talkAsk(confirming: m.talkPending != nil, full: m.fullTexts(need)),
                                                at: ISOTime.string(Date()), app: ButlerService.appVersion)
            send(req, files: [:])
            return
        }
        current = nil
        m.talkSet(cur.line, state: r.ok ? "answered" : "failed")
        switch cmd {
        case .notHim:                                          // 别人说的：不算，那一行拿掉
            m.talkDrop(cur.line)
            clock = nil
            if phase == .thinking { phase = .listening }
        case .misheard:
            finishStats()
            speak(audio, else: CompanionTrouble.misheard.words)
        case .undo:
            let did = m.talkUndo()
            clock?.acted = now
            speakFixed(did ? TalkSays.undone : TalkSays.nothingToUndo)
        case .yes:
            let had = m.talkNod(true)
            clock?.acted = now
            speakFixed(had ? TalkSays.done : TalkSays.nothingToUndo)
        case .no:
            m.talkNod(false)
            speakFixed(TalkSays.kept)
        case .bye:
            finishStats()
            stop(say: TalkSays.bye)
        case .act, .need:
            if m.talkPending != nil { m.talkNod(false) }        // 在等点头时他说了别的：那张清单不办
            guard r.ok else {
                m.talkNote((r.error ?? "").isEmpty ? t("shutong.brainFailed") : (r.error ?? ""))
                speak(audio, else: CompanionTrouble.brainFailed.words)
                return
            }
            let say = (rep?.say ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            let acts = rep?.acts ?? []
            switch m.talkAct(acts, say: say) {
            case .confirm:
                clock?.acted = now
                speak(audio, else: nil) { [weak self] in self?.armNod() }
            case .done(let counts, let skipped):
                clock?.acted = now
                if audio != nil, TalkReceipt.matches(spoken: rep?.spoken, counts: counts) {
                    speak(audio, else: TalkSays.doneLook) { [weak self] in if skipped > 0 { self?.speakFixed(TalkSays.skippedSome) } }
                } else {
                    speakFixed(skipped > 0 ? TalkSays.skippedSome : TalkSays.doneLook)
                }
            case .nothing:
                if acts.isEmpty {
                    speak(audio, else: say.isEmpty ? nil : say)          // 问他一句 / 答他的问题
                } else {
                    speakFixed(TalkSays.noneDone)
                }
            }
        }
    }

    /// 念完「要扔这几条，对吗？」：20 秒不吭声就不办
    private func armNod() {
        nodTask?.cancel()
        let wait = demo ? 14.0 : TalkTiming.confirmWait           // Demo（UI 测试）短一点；143：8 秒时 CI 模拟器打「yes」还没打完就到点了
        nodTask = Task {
            try? await Task.sleep(nanoseconds: UInt64(wait * 1_000_000_000))
            guard !Task.isCancelled, self.on, self.current == nil, self.phase == .listening, self.m.talkPending != nil else { return }
            self.nodTask = nil
            self.m.talkNod(false)
            self.speakFixed(TalkSays.silent)
        }
    }

    // ---------------------------------------------------------------- 插嘴
    /// 它在说，他开口了（够响、够长）：声纹没建好就是他，马上停；建好了先把头 1 秒寄去对声纹
    private func barge() {
        guard let ear, phase == .speaking else { return }
        if vpReady { ear.wantProbe(); return }
        stopForHim()
    }

    private func stopForHim() {
        ear?.stopPlaying()
        afterSpeak = nil
        nodTask?.cancel()
        phase = .hearing
    }

    private func askWho(_ wav: Data) {
        guard let app, ear?.busy == true else { return }
        let id = UUID().uuidString
        whoID = id
        let path = ButlerRequest.lookWhoPath(id)
        let req = ButlerRequest.lookWho(id: id, audio: path, at: ISOTime.string(Date()), app: ButlerService.appVersion)
        Task {
            if case .sent(true) = await app.butler.sendTalk(req, files: [path: wav]) {
                try? await Task.sleep(nanoseconds: 2_500_000_000)
            }
            if self.whoID == id {                             // 问不了 / 2.5 秒没回：当是他
                self.whoID = nil
                app.butler.forgetTalk(id)
                if self.ear?.busy == true { self.stopForHim() }
            }
        }
    }

    private func whoAnswer(_ r: ButlerResult) {
        guard r.id == whoID else { return }
        whoID = nil
        if (r.timing?["him"] ?? 1) > 0 {
            if ear?.busy == true { stopForHim() }
        } else {
            ear?.dropCurrentClip()                            // 别人在说话：接着念，这一句扔掉
        }
    }

    // ---------------------------------------------------------------- 念
    /// 念大管家配好的那段；没有就念 fallback（固定的话放晓晓录音，别的用苹果的嗓子）；都没有就直接回去听
    private func speak(_ audio: Data?, else fallback: String?, then: (() -> Void)? = nil) {
        afterSpeak = then
        guard let ear, !demo else { return spoken(first: true) }
        phase = .speaking
        let started: @Sendable () -> Void = { [weak self] in Task { @MainActor in self?.soundStarted() } }
        let done: @Sendable () -> Void = { [weak self] in Task { @MainActor in self?.spoken(first: false) } }
        if let audio, ear.play(audio, started: started, done: done) { return }
        guard let fallback else { return spoken(first: true) }
        if let name = VoiceLines.file(for: fallback), let url = Bundle.main.url(forResource: name, withExtension: "mp3"),
           let d = try? Data(contentsOf: url), ear.play(d, started: started, done: done) { return }
        ear.speak(fallback, voice: PhoneVoice.bestVoice("zh-CN"), started: started, done: done)
    }

    private func speakFixed(_ words: String) {
        let then = afterSpeak
        speak(nil, else: words, then: then)
    }

    private func soundStarted() {
        clock?.sound = now
        finishStats()
    }

    /// 念完了（或者没东西念）：回去听；念完要接着干的接着干
    private func spoken(first: Bool) {
        if first { finishStats() }
        if on, phase == .speaking || phase == .thinking { phase = .listening }
        let next = afterSpeak
        afterSpeak = nil
        next?()
    }

    // ---------------------------------------------------------------- 记账（只有秒数，跟下一封信走）
    private func finishStats() {
        guard let c = clock else { return }
        prev = c.summary()
        clock = nil
    }

    private func takePrev() -> [String: Double] {
        let p = prev
        prev = [:]
        return p
    }

    // ---------------------------------------------------------------- 截图、UI 测试用的假大管家（Demo）
    /// 跟大管家一样：「撤销 / 对 / 不对 / 好了」本地认；别的照 136 的假大脑回动作，念的那句照手机这头干一遍不落地算
    private func fake(_ req: ButlerRequest) {
        let said = req.text.isEmpty ? fakeSaid : req.text
        let conf = req.shutong?.confirming ?? false
        var rep = ShutongReply()
        if let c = TalkDemo.command(said, confirming: conf) {
            rep.cmd = c.rawValue
        } else {
            let (say, acts) = m.talkFakeActs(said)
            let dry = m.talkDryRun(acts)
            var spoken = say
            if dry.checked.needsConfirm {
                let names = dry.checked.ok.filter { $0.op == "trash" }.map { m.noteTitle($0.note) }
                spoken = "要扔这 \(names.count) 条：" + names.joined(separator: "、") + "，对吗？"
            } else if let line = ShutongReceipt.line(dry.counts, zh: true) {
                spoken = TalkReceipt.prefix + line
            }
            rep = ShutongReply(say: say, acts: acts, need: nil, cmd: "", spoken: spoken)
        }
        let r = ButlerResult(id: req.id, note: "", ok: true, text: rep.spoken, changes: nil, error: nil, host: "电脑", heard: said,
                             stage: "talk", shutong: rep)
        Task {
            try? await Task.sleep(nanoseconds: 500_000_000)
            self.answer(r, audio: nil)
        }
    }
}
