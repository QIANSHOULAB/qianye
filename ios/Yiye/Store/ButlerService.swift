import Foundation
import Observation
import YiyeKit

/// 连大管家。接口 v2（065 起）：走 Cloudflare 信箱，交出去几秒就到，结果、配音一到就推过来；
/// 信箱连不上（没配对、断网、站里出错）才走 iCloud 文件夹（v1，备胎）。手机上不存任何 AI 钥匙。
/// 只在 app 开着时连：进前台连上信箱、看一次 iCloud，开着时每 5 秒看一眼 iCloud。不用后台能力。
@MainActor @Observable
final class ButlerService {
    var presence: ButlerPresence = .never
    private(set) var lastLook: Date?
    /// 信箱的配对（钥匙串里存着；掌机写进 iCloud 的配对.json 读到一次就存，或者扫码、粘贴）
    private(set) var pairing: MailPairing?
    /// 信箱的长连接连着（收到 hello 了）
    private(set) var relayUp = false
    @ObservationIgnored weak var app: AppModel?
    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private var looking = false
    @ObservationIgnored private var heartbeat: ButlerPresence = .never
    @ObservationIgnored private var relayOn = false
    @ObservationIgnored private var relaySeen: Date?
    @ObservationIgnored private var mail: MailClient?
    @ObservationIgnored private var socket: MailSocket?
    @ObservationIgnored private var taking: Set<Int> = []
    @ObservationIgnored private var lastPairCheck = Date.distantPast
    /// 走信箱寄出去的请求 → 信箱里的号（同一条又交一次配音时撤回旧的用）
    @ObservationIgnored private var seqs: [String: Int] = (UserDefaults.standard.dictionary(forKey: "yiye.mailSeqs") as? [String: Int]) ?? [:]
    static let appVersion = (Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String) ?? "0.1.0"
    static let pairingAccount = "dgj-pairing"
    static let seqsKey = "yiye.mailSeqs"
    static let wordsKey = "yiye.wordQueue"
    /// 「会了 / 不会」排着队的（088）：大管家回 ok 才出队
    @ObservationIgnored private var words = WordQueue.decode(UserDefaults.standard.data(forKey: ButlerService.wordsKey))
    @ObservationIgnored private var wordSending: Set<String> = []
    /// 陪玩（100）：在等回答的请求 id
    @ObservationIgnored private var looks: Set<String> = []

    enum LookSent: Equatable { case sent(Bool), noPair, failed(String) }

    func start() {
        guard timer == nil else { return }
        if pairing == nil, app?.demo == nil, let d = Keychain.read(ButlerService.pairingAccount) { pairing = MailPairing.parse(d) }
        connectMail()
        look()
        let t = Timer(timeInterval: 5, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.look() }
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        disconnectMail()
    }

    // ---------------------------------------------------------------- 信箱（v2）
    private func connectMail() {
        guard socket == nil, app?.demo == nil, let p = pairing, let client = MailClient(pairing: p), let url = client.socketURL else { return }
        mail = client
        let s = MailSocket(url: url, onPush: { [weak self] push in
            Task { @MainActor in self?.onPush(push) }
        }, onDown: { [weak self] _ in
            Task { @MainActor in self?.relayDown() }
        })
        socket = s
        s.start()
    }

    private func disconnectMail() {
        socket?.stop()
        socket = nil
        relayDown()
    }

    private func relayDown() {
        relayUp = false
        refreshPresence()
    }

    /// 横条听谁的：信箱连着听信箱的，连不上看 iCloud 心跳
    private func refreshPresence() {
        let p = ButlerPresence.current(relayUp: relayUp, relayOn: relayOn, relaySeen: relaySeen, heartbeat: heartbeat)
        if p != presence { presence = p }
    }

    private func onPush(_ p: MailPush) {
        switch p {
        case .hello(let items, let pc, let seen):
            relayUp = true
            relayOn = pc
            relaySeen = seen
            refreshPresence()
            for it in items { take(it) }
            flushWords()
        case .msg(let it):
            take(it)
        case .pc(let on, let seen):
            relayOn = on
            if let seen { relaySeen = seen }
            refreshPresence()
        case .state(let pc, let seen):
            relayUp = true
            relayOn = pc
            if let seen { relaySeen = seen }
            refreshPresence()
        case .gone(_, let mid, let to, _):
            if to == "pc" { forgetSeq(mid) }      // 大管家取走了（或者过期了）：撤回不了了
        case .pong, .other:
            break
        }
    }

    /// 寄给手机的一封：取、拆、办，办完 ack。拆不开、不是信的也 ack 掉（别堵在信箱里）；网不通的下回 hello 里还有
    private func take(_ it: MailItem) {
        guard it.to == "phone", let mail, !taking.contains(it.seq) else { return }
        taking.insert(it.seq)
        Task {
            defer { self.taking.remove(it.seq) }
            do {
                let env = try await mail.receive(it)
                if await self.handle(env) { try? await mail.ack(it.seq) }
            } catch let e as MailError where e.isPermanent {
                if e != .gone { try? await mail.ack(it.seq) }
            } catch {
                // 网不通：下次连上，hello 里还有它
            }
        }
    }

    /// 办一封信：结果换进笔记、配音没配成清掉在等、送来的变成笔记。返回能不能 ack
    private func handle(_ env: MailEnvelope) async -> Bool {
        guard let app else { return false }
        var waiting: [String: UUID] = [:]
        var dubbing: [String: UUID] = [:]
        for n in app.allNotes() {
            let s = n.butlerState
            if s.phase == .waiting, let rid = s.requestID { waiting[rid] = n.id }
            if let rid = n.dubRequest { dubbing[rid] = n.id }
        }
        var action = MailAction.decide(env, waiting: waiting, dubbing: dubbing, words: words.requestIDs, looks: looks)
        if action == .later, let ch = app.mirror.channel, let a = env.delivery?.audio {
            // 信里没带录音：去 iCloud 镜像里找（后台读，占位的要等它下载）
            let data: Data? = await withCheckedContinuation { c in
                app.mirror.afterPendingWrites { c.resume(returning: ch.deliveryAudio(a)) }
            }
            if let data { action = MailAction.decide(env, waiting: waiting, dubbing: dubbing, localAudio: { _ in data }) }
        }
        switch action {
        case .apply(let r, let nid):
            apply(r, to: nid)
            return true
        case .dubFailed(let r, let nid):
            if let n = app.note(nid) { app.dubFailed(n, error: r.error) }
            return true
        case .word(let r):
            words.answered(r.id, ok: r.ok)
            saveWords()
            return true
        case .look(let r, let audio):
            if r.stage != "ack" { looks.remove(r.id) }          // 深聊（107）：ack 之后同一个 id 还有一封回答
            app.companion.answer(r, audio: audio)
            return true
        case .deliver(let d, let audio):
            app.addDelivery(d, audio: audio)
            return true
        case .later:
            return false
        case .drop:
            return true
        }
    }

    /// 用这份配对：存进钥匙串，换掉原来的信箱，连上
    func adopt(_ p: MailPairing) {
        guard p.isValid else { return }
        Keychain.write(Data(p.code.utf8), ButlerService.pairingAccount)
        disconnectMail()
        mail = nil
        seqs = [:]
        UserDefaults.standard.set(seqs, forKey: ButlerService.seqsKey)
        pairing = p
        if timer != nil { connectMail() }
        if let app { app.show(app.lang.t("pair.done")) }
    }

    /// 扫码、粘贴进来的配对码
    @discardableResult
    func pair(code: String) -> Bool {
        guard let p = MailPairing.parse(code) else {
            if let app { app.show(app.lang.t("pair.bad")) }
            return false
        }
        adopt(p)
        return true
    }

    /// 钥匙串里没配对：看 iCloud 里掌机写的 配对.json（15 秒看一次）；配过了也隔 5 分钟看一眼，掌机重配过就换
    private func checkPairing() {
        guard let app, app.demo == nil, let channel = app.mirror.channel else { return }
        let every: TimeInterval = pairing == nil ? 15 : 300
        guard Date().timeIntervalSince(lastPairCheck) >= every else { return }
        lastPairCheck = Date()
        app.mirror.afterPendingWrites {
            let found = channel.pairing()
            Task { @MainActor [weak self] in
                guard let self, let found, MailPairing.shouldAdopt(found, over: self.pairing) else { return }
                self.adopt(found)
            }
        }
    }

    private func rememberSeq(_ rid: String, _ seq: Int) {
        seqs[rid] = seq
        if seqs.count > 100 {
            seqs = Dictionary(uniqueKeysWithValues: seqs.sorted { $0.value > $1.value }.prefix(100).map { ($0.key, $0.value) })
        }
        UserDefaults.standard.set(seqs, forKey: ButlerService.seqsKey)
    }

    private func forgetSeq(_ rid: String) {
        if seqs.removeValue(forKey: rid) != nil { UserDefaults.standard.set(seqs, forKey: ButlerService.seqsKey) }
    }

    // ---------------------------------------------------------------- 交出去
    /// 寄出去：信箱优先，寄不出去走 iCloud（v1）；两条都不行，failed 里说为什么
    private func send(_ req: ButlerRequest, files: [String: Data], originals: [String], failed: @escaping @MainActor (String) -> Void) {
        let icloud = icloudSender(originals: originals)
        let mail = self.mail
        Task {
            switch await ButlerOutbox.submit(req, files: files, mail: mail, icloud: icloud) {
            case .mailbox(let seq): self.rememberSeq(req.id, seq)
            case .icloud: break
            case .failed(let why): failed(why)
            }
        }
    }

    private func icloudSender(originals: [String]) -> (@Sendable (ButlerRequest) async throws -> Void)? {
        guard app?.mirror.channel != nil else { return nil }
        return { [weak self] req in
            guard let self else { return }
            try await self.icloudSubmit(req, originals: originals)
        }
    }

    /// 走 iCloud（v1）：等镜像把笔记和原图写完，再放请求（先写 .part，写完改名）
    private func icloudSubmit(_ req: ButlerRequest, originals: [String]) async throws {
        guard let app, let channel = app.mirror.channel else { throw CocoaError(.fileNoSuchFile) }
        let store = app.attachments
        let folder = app.mirror.folder
        try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
            app.mirror.afterPendingWrites {
                if let folder {
                    for p in originals where !folder.hasAttachment(p) {
                        if let d = try? Data(contentsOf: store.url(p)) { try? folder.writeAttachment(d, relative: p) }
                    }
                }
                do {
                    try channel.submit(req)
                    c.resume()
                } catch {
                    c.resume(throwing: error)
                }
            }
        }
    }

    /// 跟着信走的原图（本机附件里有的）
    private func files(_ paths: [String]) -> [String: Data] {
        guard let app else { return [:] }
        var out: [String: Data] = [:]
        for p in paths { if let d = app.attachments.data(p) { out[p] = d } }
        return out
    }

    /// 交给大管家理顺：信箱优先（原图跟着信走），寄不出去走 iCloud
    func submit(_ n: Note) {
        guard let app else { return }
        var st = n.butlerState
        let id = UUID().uuidString
        guard mail != nil || app.mirror.channel != nil else {
            st.submitted(id: id, text: n.markdown, at: Date())
            st.phase = .failed
            st.error = app.lang.t("butler.needMirror")
            n.butlerState = st
            try? app.context.save()
            return
        }
        let kind = IntakeKind(rawValue: n.kind)?.butlerKind ?? .text
        let unsureTexts = n.unsureRanges.compactMap { r -> String? in
            r.end <= n.markdown.u16 ? n.markdown.sub16(r) : nil
        }
        let images = kind == .photo ? n.originalPaths : []
        let req = ButlerRequest(id: id, note: n.id.uuidString, kind: kind, text: n.markdown,
                                images: images, unsure: unsureTexts, at: ISOTime.string(Date()), app: ButlerService.appVersion)
        st.submitted(id: id, text: n.markdown, at: Date())
        n.butlerState = st
        try? app.context.save()
        app.mirror.saveNow(n, attachments: app.attachments)
        let noteID = n.id
        send(req, files: files(images), originals: images) { [weak self] why in
            guard let self, let app = self.app, let n = app.note(noteID) else { return }
            var s = n.butlerState
            guard s.requestID == id, s.phase == .waiting else { return }
            s.phase = .failed
            s.error = why
            n.butlerState = s
            try? app.context.save()
        }
    }

    /// 交大管家配音：一个 ask=speak 的请求（好了回「送来」，带 note；没配成回一个 ok=false 的结果）。
    /// replacing：这条之前交过、大管家还没拿走的，先撤回（信箱里的删掉，iCloud 里的也删掉）
    func requestDub(_ n: Note, replacing old: String? = nil) -> String? {
        guard let app else { return nil }
        guard mail != nil || app.mirror.channel != nil else {
            app.show(app.lang.t("butler.needMirror"), seconds: 6)
            return nil
        }
        let id = UUID().uuidString
        let kind = IntakeKind(rawValue: n.kind)?.butlerKind ?? .text
        let req = ButlerRequest(id: id, note: n.id.uuidString, kind: kind, text: n.markdown, images: nil, unsure: nil,
                                ask: "speak", at: ISOTime.string(Date()), app: ButlerService.appVersion)
        app.mirror.saveNow(n, attachments: app.attachments)
        if let old { withdraw(old) }
        let noteID = n.id
        send(req, files: [:], originals: []) { [weak self] why in
            guard let self, let app = self.app, let n = app.note(noteID), n.dubRequest == id else { return }
            app.dubFailed(n, error: why)
        }
        return id
    }

    private func withdraw(_ rid: String) {
        if let seq = seqs[rid], let mail { Task { try? await mail.ack(seq) } }
        forgetSeq(rid)
        if let app, let channel = app.mirror.channel { app.mirror.afterPendingWrites { channel.withdraw(rid) } }
    }

    // ---------------------------------------------------------------- 会了 / 不会（088）
    /// 点了一下：排进队，马上寄。大管家关着也行：信在信箱里等它；寄不出去（没配对、断网）就排着，连上了再寄
    func markWord(_ word: String, _ mark: WordMark, note: UUID) {
        words.add(word, mark, note: note.uuidString, at: ISOTime.string(Date()))
        saveWords()
        flushWords()
    }

    /// 该寄的寄出去（只走信箱：电脑上没有 iCloud，掌机老版本也不认）
    func flushWords() {
        guard let mail, app?.demo == nil else { return }
        for p in words.due() where !wordSending.contains(WordMark.key(p.word)) {
            let id = UUID().uuidString
            let key = WordMark.key(p.word)
            words.sending(p.word, id: id)
            wordSending.insert(key)
            let req = ButlerRequest.wordMark(id: id, word: p.word.trimmed, mark: p.mark, note: p.note, at: p.at, app: ButlerService.appVersion)
            Task {
                defer { self.wordSending.remove(key) }
                do {
                    _ = try await mail.send(.request(req))
                    self.words.sent(id)
                } catch {
                    self.words.notSent(id)
                }
                self.saveWords()
            }
        }
        saveWords()
    }

    private func saveWords() {
        guard app?.demo == nil else { return }
        UserDefaults.standard.set(words.encoded(), forKey: ButlerService.wordsKey)
    }

    // ---------------------------------------------------------------- 陪玩（100）
    /// 问一句：只走信箱（晚到的回答没用，不走 iCloud）。信箱说两台大管家都不在：当场撤回，回 .sent(false)
    func sendLook(_ req: ButlerRequest, files: [String: Data]) async -> LookSent {
        if mail == nil { connectMail() }
        guard let mail else { return .noPair }
        looks.insert(req.id)
        do {
            let sent = try await mail.send(.request(req, files: files), timeout: 15)
            if !sent.pc {
                looks.remove(req.id)
                try? await mail.ack(sent.seq)
            }
            return .sent(sent.pc)
        } catch {
            looks.remove(req.id)
            return .failed((error as? MailError)?.errorDescription ?? error.localizedDescription)
        }
    }

    /// 开始听了：叫大管家先把大脑热上（不回信；大管家不在就算了）
    func lookWarm() {
        if mail == nil { connectMail() }
        guard let mail, app?.demo == nil else { return }
        let req = ButlerRequest.lookWarm(id: UUID().uuidString, at: ISOTime.string(Date()), app: ButlerService.appVersion)
        Task {
            if let sent = try? await mail.send(.request(req), timeout: 15), !sent.pc { try? await mail.ack(sent.seq) }
        }
    }

    /// 陪玩体检（108）：大管家只记一行日志（是 / 否和数），不回信；大管家不在就算了
    func lookCheck(_ h: CompanionHealth) {
        if mail == nil { connectMail() }
        guard let mail, app?.demo == nil else { return }
        let req = ButlerRequest.lookCheck(id: UUID().uuidString, health: h, at: ISOTime.string(Date()), app: ButlerService.appVersion)
        Task {
            if let sent = try? await mail.send(.request(req), timeout: 15), !sent.pc { try? await mail.ack(sent.seq) }
        }
    }

    /// 进了深聊（107）：叫大管家把耳朵装上（不回信）
    func deepWarm() {
        if mail == nil { connectMail() }
        guard let mail, app?.demo == nil else { return }
        let req = ButlerRequest.deepWarm(id: UUID().uuidString, at: ISOTime.string(Date()), app: ButlerService.appVersion)
        Task {
            if let sent = try? await mail.send(.request(req), timeout: 15), !sent.pc { try? await mail.ack(sent.seq) }
        }
    }

    func forgetLook(_ id: String) { looks.remove(id) }

    // ---------------------------------------------------------------- iCloud（v1 备胎）
    /// 看一眼：配对、心跳、在等的结果、送来的
    func look() {
        guard let app else { return }
        checkPairing()
        if !words.items.isEmpty { flushWords() }
        guard !looking, let channel = app.mirror.channel else {
            if !app.mirror.isOn {
                heartbeat = .never
                refreshPresence()
            }
            return
        }
        looking = true
        let notes = app.allNotes()
        let waiting: [(UUID, String)] = notes.compactMap { n in
            let s = n.butlerState
            guard s.phase == .waiting, let rid = s.requestID else { return nil }
            return (n.id, rid)
        }
        // 交了配音在等的：配好了从「送来」回来；没配成的从「已理顺」回来
        let dubbing: [(UUID, String)] = notes.compactMap { n in n.dubRequest.map { (n.id, $0) } }
        app.mirror.afterPendingWrites {
            let hb = channel.heartbeat()
            var got: [(UUID, ButlerResult)] = []
            for (nid, rid) in waiting {
                if let r = channel.result(rid) { got.append((nid, r)) }
            }
            let results = got
            var dubGot: [(UUID, ButlerResult)] = []
            for (nid, rid) in dubbing {
                if let r = channel.result(rid) { dubGot.append((nid, r)) }
            }
            let dubResults = dubGot
            // 大管家送来的听力稿：录音还没同步过来的，下回再拿
            var sent: [(URL, ButlerDelivery, Data?)] = []
            for d in channel.deliveries() {
                if let a = d.item.audio {
                    guard let data = channel.deliveryAudio(a) else { continue }
                    sent.append((d.url, d.item, data))
                } else {
                    sent.append((d.url, d.item, nil))
                }
            }
            let deliveries = sent
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.looking = false
                self.lastLook = Date()
                self.heartbeat = ButlerPresence.from(hb)
                self.refreshPresence()
                for (nid, r) in results {
                    self.apply(r, to: nid)
                    let id = r.id
                    app.mirror.afterPendingWrites { channel.removeResult(id) }
                }
                for (nid, r) in dubResults {
                    if !r.ok, let n = app.note(nid), n.dubRequest == r.id { app.dubFailed(n, error: r.error) }
                    let id = r.id
                    app.mirror.afterPendingWrites { channel.removeResult(id) }
                }
                for (url, item, data) in deliveries {
                    app.addDelivery(item, audio: data)
                    app.mirror.afterPendingWrites { channel.removeDelivery(url) }
                }
            }
        }
    }

    /// 结果回来：没改过就直接换上；改过了等着点；出错原样显示
    private func apply(_ r: ButlerResult, to noteID: UUID) {
        guard let app, let n = app.note(noteID) else { return }
        var st = n.butlerState
        if let text = st.receive(r, current: n.markdown, currentUnsure: n.unsure) {
            n.markdown = text
            n.unsure = ""
            n.butlerState = st
            app.changed(n)
            NotificationCenter.default.post(name: .yiyeNoteReplaced, object: n.id)
        } else {
            n.butlerState = st
            try? app.context.save()
        }
    }

    /// 点一下换上
    func acceptOffer(_ n: Note) {
        guard let app else { return }
        var st = n.butlerState
        guard let text = st.acceptOffer(current: n.markdown, currentUnsure: n.unsure) else { return }
        n.markdown = text
        n.unsure = ""
        n.butlerState = st
        app.changed(n)
        NotificationCenter.default.post(name: .yiyeNoteReplaced, object: n.id)
    }

    /// 换回原文
    func revert(_ n: Note) {
        guard let app else { return }
        var st = n.butlerState
        let backUnsure = st.originalUnsure ?? ""
        guard let text = st.revert() else { return }
        n.markdown = text
        n.unsure = backUnsure
        n.butlerState = st
        app.changed(n)
        NotificationCenter.default.post(name: .yiyeNoteReplaced, object: n.id)
    }

    func dismiss(_ n: Note) {
        var st = n.butlerState
        st.dismiss()
        n.butlerState = st
        try? app?.context.save()
    }
}

extension Notification.Name {
    /// 大管家把笔记的字换了：写字页要重新装字
    static let yiyeNoteReplaced = Notification.Name("yiyeNoteReplaced")
}
