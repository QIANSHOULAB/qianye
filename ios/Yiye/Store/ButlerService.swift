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
    /// 打星排着队的（225）：规矩同「会了 / 不会」
    static let votesKey = "yiye.voteQueue"
    @ObservationIgnored private var votes = VoteQueue.decode(UserDefaults.standard.data(forKey: ButlerService.votesKey))
    @ObservationIgnored private var voteSending: Set<String> = []
    /// 陪玩（100）：在等回答的请求 id
    @ObservationIgnored private var looks: Set<String> = []
    /// 飞鸽传书（128）：在等回信的请求 id（只在内存里）
    @ObservationIgnored private var doves: Set<String> = []
    /// 书童（136）：在等回信的请求 id（app 被杀过也认：回信带 stage=shutong）
    @ObservationIgnored private var shutongs: Set<String> = []
    /// 书童开口说（137）：在等回信的请求 id（一句话、插嘴对声纹）
    @ObservationIgnored private var talks: Set<String> = []
    /// 备用信箱（130）：谷歌那根管子
    let backup = BackupCoordinator()
    /// 办过的信封号（两条管子可能各来一份：只办一次）
    @ObservationIgnored private var handledIDs: [String] = []
    @ObservationIgnored private var fbTaking: Set<String> = []
    /// 信箱说电脑（desk）在线（111：只寄给电脑，掌机不存文件）
    private(set) var deskOn = false
    /// 信箱说在线的大管家（desk / handheld；172 遥控只让选在线的）
    private(set) var machines: [String] = []
    /// 抄到电脑（111）：寄出去、回信还没来的「便签 → 寄的那版 modifiedAt、寄的时间」
    @ObservationIgnored private var keepInflight: [UUID: (modified: Date, sentAt: Date)] = [:]
    /// 请求 id → 「便签 id|寄的那版 modifiedAt（秒数）」，存起来：app 被杀了回信来了也认得
    @ObservationIgnored private var keepWait: [String: String] = (UserDefaults.standard.dictionary(forKey: "yiye.keepWait") as? [String: String]) ?? [:]
    /// 143：敲信箱的退避、信箱叫等一会儿、额度用光（寄信和长连接共用，换配对也不忘）
    let brake = MailBrake()
    /// 143：自动寄的那些，每一条各自退避
    @ObservationIgnored private var auto = ItemGate()
    /// 143：没取下来的信（信箱叫等着、网断了一下）：到点了再取，不用等下回连上
    @ObservationIgnored private var stalled: [Int: MailItem] = [:]
    @ObservationIgnored private var keepSending: Set<UUID> = []
    /// 信箱今天的额度用光了：到几点恢复（设置里大管家那一行写出来）
    private(set) var quotaUntil: Date?

    enum LookSent: Equatable { case sent(Bool), noPair, failed(String) }

    func start() {
        DoveModel.shared.service = self
        TodoDesk.shared.service = self                      // 162：他扔了 / 放回去的待办，靠信箱寄
        BoardDesk.shared.service = self                     // 234：看板的回执靠信箱寄
        backup.service = self
        backup.resume()
        guard timer == nil else { return }
        brake.onChange = { [weak self] in Task { @MainActor in self?.refreshQuota() } }
        brake.wake()                                        // 143：回到前台，退避的这一下不等（信箱叫等的照等）
        if pairing == nil, app?.demo == nil, let d = Keychain.read(ButlerService.pairingAccount) { pairing = MailPairing.parse(d) }
        backup.configure(box: pairing?.box)
        connectMail()
        look()
        let t = Timer(timeInterval: 5, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.look()
                TodoDesk.shared.flush()                     // 162：没寄出去的 todo-done / todo-undo
            }
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
        guard socket == nil, app?.demo == nil, let p = pairing, let client = MailClient(pairing: p, backup: backup.hub, brake: brake),
              let url = client.socketURL else { return }
        mail = client
        let s = MailSocket(url: url, brake: brake, onPush: { [weak self] push in
            Task { @MainActor in self?.onPush(push) }
        }, onDown: { [weak self] _ in
            Task { @MainActor in self?.relayDown() }
        })
        s.onRefused503 = { Task { _ = try? await client.state() } }       // 143：问一次是不是额度用光（HTTP 看得到原因）
        s.onText = { [weak self] text in
            guard let pcs = KeepPlan.machines(in: text) else { return }
            Task { @MainActor in self?.setMachines(pcs) }
        }
        socket = s
        s.start()
    }

    private func disconnectMail() {
        socket?.stop()
        socket = nil
        stalled = [:]                              // 下回连上 hello 里还有
        relayDown(deliberate: true)
        backup.hub.socketStopped()                 // 自己关的（退到后台）不算断
        backup.suspend()
    }

    private func relayDown(deliberate: Bool = false) {
        relayUp = false
        deskOn = false
        if !deliberate { backup.hub.socketDown() }
        refreshQuota()
        refreshPresence()
    }

    // ---------------------------------------------------------------- 别敲成风暴（143）
    private func refreshQuota() {
        let u = brake.quota()?.until
        if u != quotaUntil { quotaUntil = u }
    }

    /// 自动寄的那些：这一轮寄哪几条。信箱不让寄就是空的；上一封没寄出去只给一条探路。
    /// force：他刚离开写字页、要退到后台，没在探路就全给
    func autoPick(_ keys: [String], inflight: Int = 0, force: Bool = false) -> [String] {
        guard let mail else { return [] }
        let limit = force && !mail.brake.autoProbing ? Int.max : mail.autoLimit
        return auto.pick(keys, ready: mail.autoReady, limit: limit, inflight: inflight)
    }

    func autoDone(_ key: String, ok: Bool) {
        if ok { auto.succeeded(key) } else { auto.failed(key) }
    }

    /// 遥控画面一两秒要一张：现在能不能要（信箱还没连过的让它去连）
    func remoteMayAsk() -> Bool { mail == nil || !autoPick(["remote"]).isEmpty }

    private func retryStalled() {
        guard mail != nil, !stalled.isEmpty, brake.wait(.http) <= 0 else { return }
        let some = stalled.values.sorted { $0.seq < $1.seq }
        stalled = [:]
        for it in some { take(it) }
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
            backup.hub.socketUp()
            relayOn = pc
            relaySeen = seen
            refreshPresence()
            for it in items { take(it) }
            flushWords()
            flushVotes()
        case .msg(let it):
            take(it)
        case .pc(let on, let seen):
            relayOn = on
            if let seen { relaySeen = seen }
            refreshPresence()
        case .state(let pc, let seen):
            relayUp = true
            backup.hub.socketUp()
            relayOn = pc
            if let seen { relaySeen = seen }
            refreshPresence()
        case .gone(let seq, let mid, let to, _):
            if to == "pc" { forgetSeq(mid) }      // 大管家取走了（或者过期了）：撤回不了了
            if to == "phone" { stalled[seq] = nil }
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
                if self.handledIDs.contains(env.id) { try? await mail.ack(it.seq); return }       // 130：谷歌那头先到过了
                if await self.handle(env) {
                    self.rememberHandled(env.id)
                    try? await mail.ack(it.seq)
                }
            } catch let e as MailError where e.isPermanent {
                if e != .gone { try? await mail.ack(it.seq) }
            } catch {
                // 网不通、信箱叫等着：到点了再取（143），下次连上 hello 里也还有它
                if MailClient.sick(error) { self.stalled[it.seq] = it }
            }
        }
    }

    /// 办一封信：结果换进笔记、配音没配成清掉在等、送来的变成笔记。返回能不能 ack
    private func handle(_ env: MailEnvelope) async -> Bool {
        guard let app else { return false }
        var waiting: [String: UUID] = [:]
        var dubbing: [String: UUID] = [:]
        var articles: [String: UUID] = [:]
        for n in app.allNotes() {
            let s = n.butlerState
            if s.phase == .waiting, let rid = s.requestID { waiting[rid] = n.id }
            if let rid = n.dubRequest { dubbing[rid] = n.id }
            if n.kind == "article" {
                let a = n.articleState
                if a.fetch == .fetching, let f = a.fetchID { articles[f] = n.id }
                if a.simplify == .working, let f = a.simplifyID { articles[f] = n.id }
            }
        }
        var action = MailAction.decide(env, waiting: waiting, dubbing: dubbing, words: words.requestIDs, looks: looks, keeps: Set(keepWait.keys), articles: Set(articles.keys), doves: doves,
                                       shutongs: shutongs.union(ShutongModel.shared.waitingIDs), talks: talks, votes: votes.requestIDs,
                                       bots: BotsModel.shared.waitingIDs, libraries: LibraryModel.shared.waitingIDs)
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
        case .vote(let r):                                  // 225：打星的回信：ok 才出队；老大管家不认就过一会儿再寄，不弹错
            votes.answered(r.id, ok: r.ok)
            saveVotes()
            return true
        case .look(let r, let audio):
            if r.stage != "ack" && r.stage != "part" { looks.remove(r.id) }   // 深聊（107）：ack 之后同一个 id 还有一封回答；117：part 之后还有
            app.companion.answer(r, audio: audio)
            return true
        case .keep(let r):
            keepReply(r)
            return true
        case .dove(let r):                                  // 128：钥匙的回信
            doves.remove(r.id)
            if BarkModel.shared.answered(r) { return true }         // 204：加密钥匙的回信归设置里那个开关
            DoveModel.shared.answered(DoveReply.from(r))
            return true
        case .secret(let d):                                // 128：大管家递来的一次性机密：弹一张卡，不存
            DoveModel.shared.show(d)
            return true
        case .tell(let d):                                  // 158：大管家要跟 Song 说的：进小书童聊天窗、弹通知、回执
            ShutongModel.shared.butlerSaid(d)
            sendTellOK(of: d.id)
            return true
        case .guide(let d, let image):                      // 197：请他点一下：小书童里一张带圈的卡
            ShutongModel.shared.butlerGuide(d, image: image)
            return true
        case .confirm(let d):                               // 203：要他点头：小书童里一张「同意 / 不同意」
            ShutongModel.shared.butlerConfirm(d)
            return true
        case .confirmReply(let r):
            ShutongModel.shared.confirmAnswered(r)
            return true
        case .todo(let d):                                  // 162：项目待办：建 / 更新 / 扔那条便签，回执
            TodoDesk.shared.receive(d)
            sendTodoOK(of: d.id)
            return true
        case .board(let d):                                 // 234：看板：新建 / 原地盖那条便签（回执 BoardDesk 里寄）
            BoardDesk.shared.receive(d)
            return true
        case .fbConfig(let c):                              // 130：备用信箱的配置：存钥匙串，回「收到」
            backup.adopt(c.config, box: pairing?.box)
            sendFbConfigOK(of: c.id)
            return true
        case .article(let r):
            if let nid = articles[r.id] { app.articleReply(r, nid) }
            return true
        case .shutong(let r):                               // 136 书童：动作、一句话；按住说话认出的字
            shutongs.remove(r.id)
            ShutongModel.shared.answer(r)
            return true
        case .bots(let r, let images):                      // 250 机器人：名单、单聊、群里的发言（252：带图）
            BotsModel.shared.answer(r, files: images)
            return true
        case .botPost(let d, let images):                   // 252：定时活寄进机器人窗的一句
            BotsModel.shared.post(d, files: images)
            return true
        case .library(let r, let files):                    // 258 灵感库：目录、缩略图、原图
            LibraryModel.shared.answer(r, files: files)
            return true
        case .talk(let r, let audio):                       // 137 书童开口说：一句话的回信 / 插嘴对声纹
            talks.remove(r.id)
            ShutongTalker.shared.answer(r, audio: audio)
            return true
        case .remote(let r, let image):                     // 172 遥控：那台的样子、截图
            RemoteModel.shared.answer(r, image: image)
            return true
        case .remoteTiles(let r, let tiles):                // 240 遥控：只寄了变了的块
            RemoteModel.shared.answer(r, image: nil, tiles: tiles)
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
        backup.configure(box: p.box)
        disconnectMail()
        mail = nil
        auto = ItemGate()
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
        guard seq >= 0 else { return }                       // 130：谷歌那条管子寄的没有信箱里的号
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
        let due = words.due().filter { !wordSending.contains(WordMark.key($0.word)) }
        let picked = Set(autoPick(due.map { "word|\(WordMark.key($0.word))" }, inflight: wordSending.count))
        for p in due where picked.contains("word|\(WordMark.key(p.word))") {
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
                    self.autoDone("word|\(key)", ok: true)
                } catch {
                    if MailClient.sick(error) { self.words.deferred(id) } else { self.words.notSent(id) }   // 信箱的毛病不算他这个词的次数
                    self.autoDone("word|\(key)", ok: false)
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

    // ---------------------------------------------------------------- 打星（225）
    func rateVoice(_ v: ListenVoice, stars: Int, note: UUID) {
        votes.add(engine: v.engine, voice: v.name, stars: stars, note: note.uuidString, at: ISOTime.string(Date()))
        saveVotes()
        flushVotes()
    }

    /// 该寄的打星寄出去（只走信箱）。上一下还在路上就等它走完，免得后点的先到
    func flushVotes() {
        guard let mail, app?.demo == nil else { return }
        let due = votes.due().filter { !voteSending.contains($0.key) }
        let picked = Set(autoPick(due.map { "voice|\($0.key)" }, inflight: voteSending.count))
        for p in due where picked.contains("voice|\(p.key)") {
            let id = UUID().uuidString
            let key = p.key
            votes.sending(key, id: id)
            voteSending.insert(key)
            let req = ButlerRequest.voiceStars(id: id, engine: p.engine, voice: p.voice, stars: p.stars, note: p.note, at: p.at, app: ButlerService.appVersion)
            Task {
                defer { self.voteSending.remove(key) }
                do {
                    _ = try await mail.send(.request(req))
                    self.votes.sent(id)
                    self.autoDone("voice|\(key)", ok: true)
                } catch {
                    if MailClient.sick(error) { self.votes.deferred(id) } else { self.votes.notSent(id) }
                    self.autoDone("voice|\(key)", ok: false)
                }
                self.saveVotes()
            }
        }
        saveVotes()
    }

    private func saveVotes() {
        guard app?.demo == nil else { return }
        UserDefaults.standard.set(votes.encoded(), forKey: ButlerService.votesKey)
    }

    // ---------------------------------------------------------------- 思想排泄物抄到电脑（111）
    /// 信箱报哪几台大管家在线：pcs 里有 desk 才寄。刚变成在线，马上把攒着的寄出去
    private func setMachines(_ pcs: [String]) {
        let was = deskOn
        if machines != pcs { machines = pcs }
        deskOn = pcs.contains("desk")
        if deskOn && !was { keepFlush() }
    }

    /// 该抄给电脑的寄出去。force：马上寄的（刚离开写字页）；all：退后台前，全部马上寄。
    /// 写字页里正开着的那条，停手 60 秒才寄；同一版寄出去了回信没来，不重复寄；不显示寄没寄
    func keepFlush(force: Set<UUID> = [], all: Bool = false) {
        guard let app, app.demo == nil, mail != nil, deskOn else { return }
        let cands = app.keepCandidates()
        var editing: UUID?
        if case .editor(let id)? = app.path.last { editing = id }
        let forced = all ? Set(cands.map(\.id)) : force
        let ids = KeepPlan.due(cands, now: Date(), desk: deskOn, editing: editing, force: forced, inflight: keepInflight)
        // 143：寄不出去就退避，不再每 5 秒每条撞一下
        let picked = Set(autoPick(ids.map { "keep|\($0.uuidString)" }, inflight: keepSending.count, force: all || !force.isEmpty))
        for id in ids where picked.contains("keep|\(id.uuidString)") { sendKeep(id) }
    }

    private func sendKeep(_ id: UUID) {
        guard let app, let mail, let n = app.note(id), let f = n.folder else { return }
        let rid = UUID().uuidString
        let modified = n.modifiedAt
        let req = ButlerRequest.keep(id: rid, note: n.id.uuidString, folder: f.name, text: n.markdown,
                                     created: ISOTime.string(n.createdAt), modified: ISOTime.string(modified),
                                     at: ISOTime.string(Date()), app: ButlerService.appVersion)
        keepInflight[id] = (modified, Date())
        keepWait[rid] = "\(id.uuidString)|\(modified.timeIntervalSince1970)"
        if keepWait.count > 60 {
            for k in keepWait.keys.sorted().prefix(keepWait.count - 60) { keepWait[k] = nil }
        }
        saveKeepWait()
        keepSending.insert(id)
        Task {
            defer { self.keepSending.remove(id) }
            do {
                _ = try await mail.send(.request(req), timeout: 20)
                self.autoDone("keep|\(id.uuidString)", ok: true)
            } catch {
                self.autoDone("keep|\(id.uuidString)", ok: false)
                self.keepWait[rid] = nil
                self.keepInflight[id] = nil
                self.saveKeepWait()
            }
        }
    }

    /// 回信：电脑回 ok 才记「电脑那份是这一版」；掌机回 desk-only、出错的都不算，过两分钟再寄
    private func keepReply(_ r: ButlerResult) {
        let rid = r.re ?? r.id
        guard let app, let v = keepWait.removeValue(forKey: rid) else { return }
        saveKeepWait()
        let parts = v.split(separator: "|")
        guard parts.count == 2, let nid = UUID(uuidString: String(parts[0])), let ts = Double(String(parts[1])) else { return }
        let sent = Date(timeIntervalSince1970: ts)
        guard KeepPlan.reached(ok: r.ok, host: r.host) else { return }
        if let n = app.note(nid) {
            n.deskAt = KeepPlan.newDeskAt(current: n.deskAt, sent: sent)
            try? app.context.save()
        }
        if let f = keepInflight[nid], abs(f.modified.timeIntervalSince(sent)) < 0.001 { keepInflight[nid] = nil }
    }

    private func saveKeepWait() {
        guard app?.demo == nil else { return }
        UserDefaults.standard.set(keepWait, forKey: "yiye.keepWait")
    }

    // ---------------------------------------------------------------- 备用信箱（130）
    private func rememberHandled(_ id: String) {
        handledIDs.append(id)
        if handledIDs.count > 300 { handledIDs.removeFirst(handledIDs.count - 300) }
    }

    /// 谷歌那条管子来的一封（备用模式下听着）：拆、办、办完删。两条路都来了只办一次
    func fbLetter(_ l: FbLetterBody) {
        guard let mail, !fbTaking.contains(l.mid) else { return }
        fbTaking.insert(l.mid)
        Task {
            defer { self.fbTaking.remove(l.mid) }
            var done = false
            do {
                let env = try mail.open(l.body)
                if self.handledIDs.contains(env.id) {
                    done = true
                } else if await self.handle(env) {
                    self.rememberHandled(env.id)
                    done = true
                }
            } catch let e as MailError where e.isPermanent {
                done = true                                  // 拆不开、不是信：删掉，别堵着
            } catch {
            }
            if done { self.backup.ack(l.mid) }
        }
    }

    /// 备用信箱的配置存好了：回大管家一句「收到」（它不再递）。走 send：Cloudflare 或谷歌，哪条通走哪条
    /// 158：大管家的话收到了（它 30 分钟没收到回执就补发 Telegram）
    private func sendTellOK(of tell: String) {
        guard let mail else { return }
        let req = ButlerRequest.tellOK(id: UUID().uuidString, of: tell, at: ISOTime.string(Date()), app: ButlerService.appVersion)
        Task { _ = try? await mail.send(.request(req), timeout: 20) }
    }

    /// 162：待办的信收到了（大管家 30 分钟没收到回执就再寄一次）
    private func sendTodoOK(of letter: String) {
        guard let mail else { return }
        let req = ButlerRequest.todoOK(id: UUID().uuidString, of: letter, at: ISOTime.string(Date()), app: ButlerService.appVersion)
        Task { _ = try? await mail.send(.request(req), timeout: 20) }
    }

    /// 234：看板的信收到了（大管家 30 分钟没收到回执就换个信 id 再寄最新的一版）
    func sendBoardOK(of letter: String) {
        guard let mail else { return }
        let req = ButlerRequest.boardOK(id: UUID().uuidString, of: letter, at: ISOTime.string(Date()), app: ButlerService.appVersion)
        Task { _ = try? await mail.send(.request(req), timeout: 20) }
    }

    /// 162：他扔了 / 放回去了一条待办。寄成了 true；没配对、寄不出去 false（TodoDesk 留着下回再寄）
    func sendTodo(ask: String, todo: String) async -> Bool {
        guard let mail, app?.demo == nil else { return false }
        let id = UUID().uuidString, at = ISOTime.string(Date())
        let req = ask == "todo-undo" ? ButlerRequest.todoUndo(id: id, todo: todo, at: at, app: ButlerService.appVersion)
                                     : ButlerRequest.todoDone(id: id, todo: todo, at: at, app: ButlerService.appVersion)
        do {
            _ = try await mail.send(.request(req), timeout: 20)
            return true
        } catch {
            return false
        }
    }

    private func sendFbConfigOK(of cfg: String) {
        guard let mail else { return }
        let req = ButlerRequest.fbConfigOK(id: UUID().uuidString, of: cfg, at: ISOTime.string(Date()), app: ButlerService.appVersion)
        Task { _ = try? await mail.send(.request(req), timeout: 20) }
    }

    // ---------------------------------------------------------------- 遥控（172）
    /// 一个遥控动作：只走信箱（不走 iCloud：密码不进 iCloud，慢了也没用）。寄出去了回 nil，没寄出去回一句为什么。
    /// 请求不落盘、不进 UserDefaults；回信按 stage=remote 认，不用记 id
    func sendRemote(_ req: ButlerRequest) async -> String? {
        if mail == nil { connectMail() }
        guard let mail, app?.demo == nil else { return app?.lang.t("remote.noPair") }
        do {
            _ = try await mail.send(.request(req), timeout: 20)
            return nil
        } catch {
            return (error as? MailError)?.errorDescription ?? error.localizedDescription
        }
    }

    /// 203：他点的「同意 / 不同意」：只走信箱（晚了就过期了，不走 iCloud）。寄出去了回 nil，没寄出去回一句为什么
    func sendConfirm(_ req: ButlerRequest) async -> String? {
        if mail == nil { connectMail() }
        guard let mail else { return app?.lang.t("shutong.noPair") }
        do {
            _ = try await mail.send(.request(req), timeout: 20)
            return nil
        } catch {
            return (error as? MailError)?.errorDescription ?? error.localizedDescription
        }
    }

    // ---------------------------------------------------------------- 飞鸽传书（128）
    enum DoveSent: Equatable { case sent(pc: Bool), noPair, failed(String) }

    /// 把一把钥匙寄给大管家：只走信箱，不走 iCloud（钥匙不进 iCloud）。寄不出去就是没交，钥匙还在调用的人手里。
    /// 请求、钥匙都不落盘、不进 UserDefaults；这里只记请求 id 等回信
    func sendKey(key: String, name: String, id: String = UUID().uuidString) async -> DoveSent {
        if mail == nil { connectMail() }
        guard let mail else { return .noPair }
        let req = ButlerRequest.dove(id: id, key: key, name: name, at: ISOTime.string(Date()), app: ButlerService.appVersion)
        doves.insert(req.id)
        do {
            let sent = try await mail.send(.request(req), timeout: 20)
            return .sent(pc: sent.pc)
        } catch {
            doves.remove(req.id)
            return .failed((error as? MailError)?.errorDescription ?? error.localizedDescription)
        }
    }

    // ---------------------------------------------------------------- 文章（114）
    /// 把一条文章便签的网址寄给大管家扒正文（只走信箱；大管家不在，信在信箱里等它）。没配对、寄不出去：记下原因，按钮照样能用。返回寄出去没有
    func submitArticle(_ n: Note, url: String) async -> Bool {
        guard let app else { return false }
        if mail == nil { connectMail() }
        var st = n.articleState
        st.url = url
        guard let mail else {
            st.fetch = .failed
            st.fetchError = app.lang.t("article.needPairShort")
            n.articleState = st
            try? app.context.save()
            return false
        }
        let id = UUID().uuidString
        st.startFetch(id: id, now: Date())
        n.articleState = st
        try? app.context.save()
        let req = ButlerRequest.article(id: id, note: n.id.uuidString, url: url, at: ISOTime.string(Date()), app: ButlerService.appVersion)
        do {
            let sent = try await mail.send(.request(req), timeout: 15)
            rememberSeq(id, sent.seq)
            return true
        } catch {
            var s2 = n.articleState
            if s2.fetchID == id {
                s2.fetch = .failed
                s2.fetchError = (error as? MailError)?.errorDescription ?? error.localizedDescription
                n.articleState = s2
                try? app.context.save()
            }
            return false
        }
    }

    /// 简写：便签全文寄给大管家，回来的是一到三条听力（从「送来」，带 request）
    func submitSimplify(_ n: Note) async {
        guard let app else { return }
        if mail == nil { connectMail() }
        var st = n.articleState
        guard let mail else {
            st.simplify = .failed
            st.simplifyError = app.lang.t("article.needPairShort")
            n.articleState = st
            try? app.context.save()
            return
        }
        let id = UUID().uuidString
        st.startSimplify(id: id, now: Date())
        n.articleState = st
        try? app.context.save()
        let req = ButlerRequest.simplify(id: id, note: n.id.uuidString, text: n.markdown, at: ISOTime.string(Date()), app: ButlerService.appVersion)
        do {
            let sent = try await mail.send(.request(req), timeout: 15)
            rememberSeq(id, sent.seq)
        } catch {
            var s2 = n.articleState
            if s2.simplifyID == id {
                s2.simplify = .failed
                s2.simplifyError = (error as? MailError)?.errorDescription ?? error.localizedDescription
                n.articleState = s2
                try? app.context.save()
            }
        }
    }

    // ---------------------------------------------------------------- 书童（136）
    /// 寄一封书童的请求（只走信箱：大管家不在，信在信箱里等它，不撤回）。sent(false) = 信箱说两台大管家都不在
    func sendShutong(_ req: ButlerRequest, files: [String: Data] = [:]) async -> LookSent {
        if mail == nil { connectMail() }
        guard let mail else { return .noPair }
        shutongs.insert(req.id)
        do {
            let sent = try await mail.send(.request(req, files: files), timeout: 20)
            rememberSeq(req.id, sent.seq)
            return .sent(sent.pc)
        } catch {
            shutongs.remove(req.id)
            return .failed((error as? MailError)?.errorDescription ?? error.localizedDescription)
        }
    }

    // ---------------------------------------------------------------- 机器人（250）
    /// 寄一封机器人的请求（只走信箱：大管家不在，信在信箱里等它）。sent(false) = 信箱说两台大管家都不在
    func sendBots(_ req: ButlerRequest) async -> LookSent {
        if mail == nil { connectMail() }
        guard let mail else { return .noPair }
        do {
            let sent = try await mail.send(.request(req), timeout: 20)
            rememberSeq(req.id, sent.seq)
            return .sent(sent.pc)
        } catch {
            return .failed((error as? MailError)?.errorDescription ?? error.localizedDescription)
        }
    }

    // ---------------------------------------------------------------- 书童开口说（137）
    /// 寄一句（只走信箱：晚到的回答没用）。信箱说两台大管家都不在：当场撤回，回 .sent(false)
    func sendTalk(_ req: ButlerRequest, files: [String: Data] = [:]) async -> LookSent {
        if mail == nil { connectMail() }
        guard let mail else { return .noPair }
        talks.insert(req.id)
        do {
            let sent = try await mail.send(.request(req, files: files), timeout: 15)
            if !sent.pc {
                talks.remove(req.id)
                try? await mail.ack(sent.seq)
            }
            return .sent(sent.pc)
        } catch {
            talks.remove(req.id)
            return .failed((error as? MailError)?.errorDescription ?? error.localizedDescription)
        }
    }

    /// 不等回信的（进来、敲一下、退出）：寄了就算
    func sendTalkNote(_ req: ButlerRequest) {
        if mail == nil { connectMail() }
        guard let mail, app?.demo == nil else { return }
        Task {
            if let sent = try? await mail.send(.request(req), timeout: 15), !sent.pc { try? await mail.ack(sent.seq) }
        }
    }

    func forgetTalk(_ id: String) { talks.remove(id) }

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

    /// 170 诊断：说话的功能出错、界面卡了：一封 look-check（diag=1），大管家记日志、存 logs/yiye-diag.jsonl，不回信。
    /// 大管家不在线也留在信箱里（不撤），等它上线再看
    func sendDiag(_ d: EarDiag) {
        if mail == nil { connectMail() }
        guard let mail, app?.demo == nil else { return }
        let req = ButlerRequest.yiyeDiag(id: UUID().uuidString, diag: d, at: ISOTime.string(Date()), app: ButlerService.appVersion)
        Task { _ = try? await mail.send(.request(req), timeout: 15) }
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

    /// 117 边说边传：他一开口就把那一刻的截图先寄出去（不回信；大管家不在就算了）
    func lookPre(_ req: ButlerRequest, files: [String: Data]) {
        if mail == nil { connectMail() }
        guard let mail, app?.demo == nil else { return }
        Task {
            if let sent = try? await mail.send(.request(req, files: files), timeout: 15), !sent.pc { try? await mail.ack(sent.seq) }
        }
    }

    /// 117 关了陪玩：这一场结束（不回信；大管家不在就算了）
    func lookOff() {
        guard let mail, app?.demo == nil else { return }
        let req = ButlerRequest.lookOff(id: UUID().uuidString, at: ISOTime.string(Date()), app: ButlerService.appVersion)
        Task {
            if let sent = try? await mail.send(.request(req), timeout: 15), !sent.pc { try? await mail.ack(sent.seq) }
        }
    }

    func forgetLook(_ id: String) { looks.remove(id) }

    // ---------------------------------------------------------------- iCloud（v1 备胎）
    /// 看一眼：配对、心跳、在等的结果、送来的
    func look() {
        guard let app else { return }
        ShutongModel.shared.tick()                          // 136：新便签该收拾的寄出去
        BotsModel.shared.tick()                             // 250：机器人等太久的收掉
        LibraryModel.shared.tick()                          // 258：灵感库等太久的停转圈
        backup.hub.tick()
        refreshQuota()
        retryStalled()
        checkPairing()
        keepFlush()
        if !words.items.isEmpty { flushWords() }
        if !votes.items.isEmpty { flushVotes() }
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
