import Foundation
import Observation
import UIKit
import YiyeKit

/// 172 遥控：工具箱「遥控」那一页的状态。先选电脑 / 掌机（只有在线的点得动），然后：
/// - 那台的截图一两秒一张（前一张回来了才要下一张）；点 = 左键、长按 = 右键、两指上下滑 = 滚轮，点完马上换一张；
/// - 底下打字发送；「密码」开关开着时框里只显示点点，发出去走 secret（整封信两头加密），发完清空；密码不存、不进日志。
/// - 关掉这一页、退到后台：结束（那台角上的「手机遥控中」消失）。
/// 240（Song 11-27 07:38）：画面占满全屏，底下一条反馈栏（「点了」「等画面变…」「点上了」「没反应，再点一次？」）和输入框；
/// 输入框两个按钮：「问大管家」（「点上没」，回答出现在反馈栏）、「敲进电脑 / 掌机」（原来的打字）。
/// 聪明截图（大管家 live）：收到一张马上要下一张（它等画面变了才回），只寄变了的块、拼在手上那张上；进遥控先显示上回那张（压暗、写「上回」）。
@MainActor @Observable
final class RemoteModel {
    static let shared = RemoteModel()

    /// 那一页开着（RootView 里的 sheet；关掉时 RemoteSheet 叫 stop）
    var open = false
    /// 正在遥控哪台（nil = 还在选）
    private(set) var target: RemoteTarget?
    private(set) var image: UIImage?
    private(set) var state = RemoteState()
    /// 一句话：在连、那台说的话（不让远程点、结束了……）
    private(set) var line: String?
    /// 在等一封回信
    private(set) var waiting = false
    /// 底下的输入框
    var draft = ""
    /// 密码开关
    var password = false
    /// 181：手机上放大到几倍、挪到哪儿（只在手机上）。新截图来了不动；换屏、结束、重开遥控才回整屏
    var zoom = RemoteZoom()
    /// UI 测试看的：上一下寄出去的是什么（Demo 里才写）
    private(set) var lastSent = ""
    /// 197 带路：正照着哪张卡点（圈画在那台的截图上）
    private(set) var guide: GuideCard?
    /// 197：从小书童的卡片上开的那一页
    var guideOpen = false
    /// 240：现在显示的是上回那张（压暗、角上写「上回」），新图还没到
    private(set) var stale = false
    /// 240：手上显示的是第几张（点的时候带回去、要下一张时报给大管家）
    private(set) var shown: Int?
    /// 240：那台会聪明截图
    private(set) var live = false
    /// 240：在等大管家答
    private(set) var asking = false

    @ObservationIgnored weak var app: AppModel?
    @ObservationIgnored private var session = ""
    @ObservationIgnored private var inflight: String?
    @ObservationIgnored private var sentAt = Date.distantPast
    @ObservationIgnored private var refresh: Task<Void, Never>?
    @ObservationIgnored private var demoShot = 0
    /// 240：在路上的那张 shot（跟点、打字分开：点不等截图）
    @ObservationIgnored private var shotFlight: String?
    @ObservationIgnored private var shotAt = Date.distantPast
    @ObservationIgnored private var askFlight: String?
    @ObservationIgnored private var openAt = Date.distantPast
    /// 240：刚做的那一下（反馈栏按它说「点上了」还是「画面变了」）
    @ObservationIgnored private var lastMove = ""
    /// 240：每台上回那张（进遥控先显示它）
    @ObservationIgnored private var lastShots: [RemoteTarget: UIImage] = [:]

    private var demo: Bool { app?.demo != nil }
    private func t(_ k: String) -> String { app?.lang.t(k) ?? k }

    /// 信箱说在线的那几台（Demo：两台都在）
    var online: Set<RemoteTarget> {
        if demo { return Set(RemoteTarget.allCases) }
        return RemoteTarget.online(app?.butler.machines ?? [])
    }

    // ---------------------------------------------------------------- 开、关
    func start(_ t: RemoteTarget) {
        guard online.contains(t) else { return }
        target = t
        session = UUID().uuidString
        image = lastShot(t)                                  // 240：先显示上回那张，压暗
        stale = image != nil
        shown = nil
        live = false
        asking = false
        shotFlight = nil
        askFlight = nil
        openAt = Date()
        state = RemoteState()
        zoom = RemoteZoom()
        line = self.t("remote.connecting")
        draft = ""
        password = false
        send(RemoteOp(op: "open", session: session, screen: guide?.target == t ? guide?.screen : nil, have: 0))
        loop()
    }

    // ---------------------------------------------------------------- 197 带路
    /// 小书童的卡片上点了「去点」：开那台的遥控，圈画在上面
    func openGuide(_ c: GuideCard) {
        if target != nil { stop() }
        guide = c
        guideOpen = true
        if online.contains(c.target) { start(c.target) } else { line = t("remote.offline") }
    }

    /// 同一张带路来了新的（换一句、点上了、不用点了）
    func guideUpdate(_ c: GuideCard) {
        guard guide?.id == c.id else { return }
        if c.status == "ask" {
            guide = c
        } else {
            guide = nil
            line = c.text
        }
    }

    /// 结束这一场（回到选机器）
    func stop() {
        refresh?.cancel()
        refresh = nil
        if let t = target, !session.isEmpty { fire(RemoteOp(op: "close", session: session), to: t) }
        if let t = target, let img = image, !stale { keepLast(img, for: t) }
        stale = false
        shown = nil
        live = false
        asking = false
        shotFlight = nil
        askFlight = nil
        target = nil
        session = ""
        inflight = nil
        waiting = false
        image = nil
        zoom = RemoteZoom()
        line = nil
        draft = ""
        password = false
        guide = nil
    }

    /// 退到后台：结束
    func wentAway() {
        if target != nil { stop() }
    }

    /// 要下一张：前一张回来了（或者等太久没回）才要。240：聪明截图的那台收到就要（它等画面变了才回），老的隔 1.5 秒
    private func loop() {
        refresh?.cancel()
        refresh = Task { [weak self] in
            var last = Date()
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 100_000_000)
                guard let self, self.target != nil else { return }
                let started = self.shown != nil || Date().timeIntervalSince(self.openAt) > 8   // 第一张（open 那封）回来了，或者丢了
                guard started else { continue }
                let gap = RemoteFeed.nextDelay(live: self.live)
                let lost = Date().timeIntervalSince(self.shotAt) > RemoteFeed.lostAfter(live: self.live)
                guard self.shotFlight == nil || lost, Date().timeIntervalSince(last) >= gap else { continue }
                if self.app?.butler.remoteMayAsk() ?? true {          // 143：寄不出去就退避
                    last = Date()
                    self.send(RemoteOp(op: "shot", session: self.session, have: self.live ? (self.shown ?? 0) : nil,
                                       wait: self.live ? true : nil))
                }
            }
        }
    }

    // ---------------------------------------------------------------- 240 上回那张
    private func lastShot(_ t: RemoteTarget) -> UIImage? {
        if let img = lastShots[t] { return img }
        guard !demo, let u = Self.lastURL(t), let d = try? Data(contentsOf: u), let img = UIImage(data: d) else { return nil }
        lastShots[t] = img
        return img
    }

    private func keepLast(_ img: UIImage, for t: RemoteTarget) {
        lastShots[t] = img
        guard !demo, let u = Self.lastURL(t), let d = img.jpegData(compressionQuality: 0.6) else { return }
        try? d.write(to: u, options: [.atomic, .completeFileProtection])
    }

    /// Caches 里（不进 iCloud、不进备份）
    private static func lastURL(_ t: RemoteTarget) -> URL? {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first?.appendingPathComponent("remote-last-\(t.rawValue).jpg")
    }

    // ---------------------------------------------------------------- 手势、打字
    /// 在图上点了一下（x、y 是那张图上的比例）
    func tap(_ x: Double, _ y: Double, right: Bool = false) {
        guard !stale, let shot = state.shot else { return }
        if !right, let g = guide, g.target == target, g.screen == (state.screen ?? 0) {   // 197：圈里的那一下按卡片说的发
            let how = g.tapPlan(x, y, aspect: aspect)
            send(RemoteOp(op: how.op, session: session, shot: shot, x: x, y: y, guide: how.guide))
            return
        }
        send(RemoteOp(op: right ? "right" : "tap", session: session, shot: shot, x: x, y: y))
    }

    /// 197：在图上连点两下 = 双击
    func doubleTap(_ x: Double, _ y: Double) {
        guard !stale, let shot = state.shot else { return }
        var g: String?
        if let c = guide, c.target == target, c.contains(x, y, aspect: aspect) { g = c.id }
        send(RemoteOp(op: "double", session: session, shot: shot, x: x, y: y, guide: g))
    }

    private var aspect: Double {
        guard let s = image?.size, s.width > 0 else { return 0.625 }
        return Double(s.height / s.width)
    }

    func scroll(_ x: Double, _ y: Double, notches: Int) {
        guard notches != 0, !stale, let shot = state.shot else { return }
        send(RemoteOp(op: "scroll", session: session, shot: shot, x: x, y: y, dy: notches))
    }

    func switchScreen() {
        let n = max(1, state.screens ?? 1)
        guard n > 1 else { return }
        zoom = RemoteZoom()
        shown = nil                                           // 240：换屏了，手上那张不算数，下一张整图
        send(RemoteOp(op: "shot", session: session, screen: ((state.screen ?? 0) + 1) % n, have: live ? 0 : nil))
    }

    /// 240：问大管家（「点上没」「卡在哪」）：回答出现在反馈栏。密码开着不让问（框里的字不能进大脑）
    func askDraft() {
        let s = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !s.isEmpty, !password, target != nil else { return }
        draft = ""
        asking = true
        line = t("remote.fb.asking")
        if demo { lastSent = "ask \(s)" }
        send(RemoteOp(op: "ask", session: session, text: s))
    }

    /// 发送：密码开着走 secret，不然走 type。发完框里清空（密码那份也就没了）
    func sendDraft() {
        let s = draft
        guard !s.isEmpty, let t = target else { return }
        draft = ""
        if password {
            password = false
            let id = UUID().uuidString
            if demo {
                lastSent = "pass"                                // 不写密码本身
                return demoAnswer(id: id, op: RemoteOp(op: "pass"))
            }
            let req = ButlerRequest.remotePass(id: id, secret: s, session: session, target: t, at: ISOTime.string(Date()), app: ButlerService.appVersion)
            post(req)
        } else {
            send(RemoteOp(op: "type", session: session, text: s))
        }
    }

    /// 240：寄出去那一下反馈栏先说一句（「点了」「滚了」「敲进去了」）
    private func saySent(_ op: String) {
        guard let k = RemoteFeed.line(op: op, sent: true, after: nil) else { return }
        lastMove = op
        line = t(k)
    }

    // ---------------------------------------------------------------- 寄、收
    private func send(_ op: RemoteOp) {
        guard let t = target else { return }
        let id = UUID().uuidString
        var op = op
        if live, op.op != "shot", op.op != "close", op.op != "ask", op.op != "open", op.have == nil { op.have = shown ?? 0 }   // 240
        if op.op == "shot" { shotFlight = id; shotAt = Date() }
        if op.op == "ask" { askFlight = id }
        if op.op != "shot" && op.op != "ask" && op.op != "open" { line = nil; saySent(op.op) }
        if demo {
            if op.op != "shot" && op.op != "ask" { lastSent = Self.describe(op) }     // 一两秒一张的截图不盖掉上一下
            if let g = op.guide { demoGuideDone(g) }
            return demoAnswer(id: id, op: op)
        }
        post(ButlerRequest.remote(id: id, op: op, target: t, at: ISOTime.string(Date()), app: ButlerService.appVersion))
    }

    private func post(_ req: ButlerRequest) {
        guard let app else { return }
        let bg = req.remote?.op == "shot" || req.remote?.op == "ask"   // 240：截图、问话不转圈、不挡点
        if !bg {
            inflight = req.id
            sentAt = Date()
            waiting = true
        }
        Task {
            let why = await app.butler.sendRemote(req)
            app.butler.autoDone("remote", ok: why == nil)
            if let why {
                if self.inflight == req.id { self.inflight = nil; self.waiting = false }
                if self.shotFlight == req.id { self.shotFlight = nil }
                if self.askFlight == req.id { self.askFlight = nil; self.asking = false }
                self.line = why
            }
        }
    }

    /// 关的那一下：不等回信
    private func fire(_ op: RemoteOp, to t: RemoteTarget) {
        guard let app, !demo else { return }
        let req = ButlerRequest.remote(id: UUID().uuidString, op: op, target: t, at: ISOTime.string(Date()), app: ButlerService.appVersion)
        Task { _ = await app.butler.sendRemote(req) }
    }

    /// 那台的回信（ButlerService 收信时叫）。240：tiles = 只寄了变了的块（路径 → JPEG）
    func answer(_ r: ButlerResult, image data: Data?, tiles: [String: Data] = [:]) {
        let st = r.remote ?? RemoteState()
        if let s = st.session, !s.isEmpty, s != session, !session.isEmpty { return }      // 上一场的
        if r.id == inflight { inflight = nil; waiting = false }
        if r.id == shotFlight { shotFlight = nil }
        if st.live == true { live = true }
        if st.answer == true || (askFlight != nil && r.id == askFlight) {                    // 240：问大管家的回答
            askFlight = nil
            asking = false
            if r.ok {
                let said = r.text ?? ""
                line = said.isEmpty ? t("remote.fb.noAnswer") : said
            } else {
                line = r.error ?? t("remote.failed")
            }
            return
        }
        let img = data.flatMap { UIImage(data: $0) }
        switch RemoteFeed.step(shown: shown, state: st, hasImage: img != nil) {
        case .full:
            if let img {
                if let new = st.screen, let old = state.screen, new != old { zoom = RemoteZoom() }   // 181：换了一块屏
                image = img
                stale = false
                shown = st.shot
            }
        case .tiles:
            var size: CGSize?
            if let w = st.iw, let h = st.ih { size = CGSize(width: w, height: h) }
            if !stale, let base = image, let done = Self.compose(base, tiles: st.tiles ?? [], data: tiles, size: size) {
                image = done
                shown = st.shot
            }
        case .same, .skip:
            break
        }
        if st.shot != nil || st.ended == true || st.blocked == true {
            var keep = st
            keep.shot = shown ?? st.shot                          // 点的时候带回去的永远是手上那张
            keep.tiles = nil
            state = keep
        }
        if st.ended == true {
            refresh?.cancel()
            refresh = nil
            line = r.ok ? (r.text ?? t("remote.ended")) : (r.error ?? t("remote.ended"))
            if let tg = target, let im = image, !stale { keepLast(im, for: tg) }
            target = nil
            session = ""
            zoom = RemoteZoom()
            shown = nil
            stale = false
            return
        }
        if !r.ok { line = r.error ?? t("remote.failed") }
        else if st.black == true { line = t("remote.black") }
        else if let k = RemoteFeed.line(op: lastMove, after: st.after) { line = t(k) }
        else if line == t("remote.connecting"), shown != nil { line = nil }
    }

    /// 240：块拼到手上那张上（按大管家那张图的像素：size 是它说的图多大）。缺一块就不拼，回 nil（下一封 have 还是手上那张）
    static func compose(_ base: UIImage, tiles: [RemoteTile], data: [String: Data], size: CGSize?) -> UIImage? {
        let full = size ?? base.size
        guard full.width > 0, full.height > 0, !tiles.isEmpty else { return nil }
        var parts: [(UIImage, CGRect)] = []
        for tile in tiles {
            guard let d = data[tile.path], let im = UIImage(data: d) else { return nil }
            parts.append((im, CGRect(x: tile.x, y: tile.y, width: tile.w, height: tile.h)))
        }
        let fmt = UIGraphicsImageRendererFormat()
        fmt.scale = 1
        fmt.opaque = true
        return UIGraphicsImageRenderer(size: full, format: fmt).image { _ in
            base.draw(in: CGRect(origin: .zero, size: full))
            for (im, rect) in parts { im.draw(in: rect) }
        }
    }

    static func describe(_ op: RemoteOp) -> String {
        switch op.op {
        case "tap", "double", "right": return String(format: "%@ %.3f %.3f", op.op, op.x ?? 0, op.y ?? 0) + (op.guide == nil ? "" : " g")
        case "scroll": return "scroll \(op.dy ?? 0)"
        case "type": return "type \(op.text ?? "")"
        default: return op.op
        }
    }

    /// 197 Demo：假大管家 1 秒后说「点上了」
    private func demoGuideDone(_ g: String) {
        Task {
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            var d = ButlerDelivery(id: "guide-demo-done", kind: GuideCard.kind, text: self.app?.lang.isZh == false ? "Got it. Carrying on." : "点上了，我接着干",
                                   audio: nil, marks: nil)
            d.guide = g
            d.status = "done"
            ShutongModel.shared.butlerGuide(d, image: nil)
        }
    }

    /// 画出来的假屏：右上角一块红
    static func demoScreen(_ n: Int) -> UIImage {
        let size = CGSize(width: 1280, height: 800)
        return UIGraphicsImageRenderer(size: size).image { ctx in
            UIColor(white: 0.94, alpha: 1).setFill()
            ctx.fill(CGRect(origin: .zero, size: size))
            UIColor(red: 0.13, green: 0.33, blue: 0.6, alpha: 1).setFill()
            ctx.fill(CGRect(x: 0, y: 0, width: size.width, height: 56))
            let a: [NSAttributedString.Key: Any] = [.font: UIFont.systemFont(ofSize: 34, weight: .medium), .foregroundColor: UIColor.darkGray]
            ("Desktop · \(n)" as NSString).draw(at: CGPoint(x: 60, y: 120), withAttributes: a)
            UIColor(red: 0.78, green: 0.16, blue: 0.16, alpha: 1).setFill()
            ctx.fill(CGRect(x: 1020, y: 70, width: 230, height: 50))
        }
    }

    // ---------------------------------------------------------------- Demo（截图、UI 测试）：假大管家回一张画出来的屏
    // 240：假大管家也「聪明」：open 回整张（有上回那张时晚 1.5 秒，看得见「上回」）；等着的 shot 1 秒后回「没变」；
    // 点 / 双击 / 右键先回「等画面变」，0.6 秒后寄一块（点的地方画个蓝圈）说「点上了」；问大管家 1 秒后答一句。
    private func demoAnswer(id: String, op: RemoteOp) {
        if op.op == "close" { return }
        let sess = session
        switch op.op {
        case "shot" where op.wait == true:
            let have = op.have ?? 0
            Task {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                guard self.session == sess else { return }
                var st = RemoteState(on: true, session: sess, screen: 0, shot: have, w: 2560, h: 1600, screens: 1)
                st.live = true
                st.same = true
                self.answer(Self.demoResult(id, st), image: nil)
            }
        case "ask":
            Task {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                guard self.session == sess else { return }
                var st = RemoteState(on: true, session: sess, screen: 0)
                st.answer = true
                var r = Self.demoResult(id, st)
                r.text = self.app?.lang.isZh == false ? "Yes, it took: the red button is pressed. Next, tap Save at the bottom right."
                    : "点上了：右上角那个红按钮按下去了。下一步点右下角的「保存」。"
                self.answer(r, image: nil)
            }
        case "tap", "double", "right":
            let have = shown ?? 0
            var wait = RemoteState(on: true, session: sess, screen: 0, shot: have, w: 2560, h: 1600, screens: 1)
            wait.live = true
            wait.same = true
            wait.after = "wait"
            answer(Self.demoResult(id, wait), image: nil)
            let (x, y) = (op.x ?? 0.5, op.y ?? 0.5)
            Task {
                try? await Task.sleep(nanoseconds: 600_000_000)
                guard self.session == sess else { return }
                self.demoShot += 1
                let n = self.demoShot
                let tx = max(0, min(1280 - 128, Int(x * 1280) / 64 * 64 - 64)), ty = max(0, min(800 - 128, Int(y * 800) / 64 * 64 - 64))
                let piece = Self.demoRing(at: CGPoint(x: x * 1280 - Double(tx), y: y * 800 - Double(ty)))
                let path = "遥控/demo-\(n)-0.jpg"
                var st = RemoteState(on: true, session: sess, screen: 0, shot: n, w: 2560, h: 1600, screens: 1)
                st.live = true
                st.base = have
                st.tiles = [RemoteTile(path: path, x: tx, y: ty, w: 128, h: 128)]
                st.iw = 1280
                st.ih = 800
                st.after = "moved"
                self.answer(Self.demoResult(UUID().uuidString, st), image: nil, tiles: [path: piece.jpegData(compressionQuality: 0.8) ?? Data()])
            }
        default:
            demoShot += 1
            let n = demoShot
            let late = op.op == "open" && stale
            Task {
                if late { try? await Task.sleep(nanoseconds: 1_500_000_000) }
                guard self.session == sess else { return }
                let img = Self.demoScreen(n)
                var st = RemoteState(on: true, session: sess, screen: 0, shot: n, w: 2560, h: 1600, screens: 1, image: "遥控/demo-\(n).jpg")
                st.live = true
                st.iw = 1280
                st.ih = 800
                if op.op != "open" { st.after = "moved" }
                self.answer(Self.demoResult(id, st), image: img.jpegData(compressionQuality: 0.6))
            }
        }
    }

    private static func demoResult(_ id: String, _ st: RemoteState) -> ButlerResult {
        var r = ButlerResult(id: id, note: "", ok: true, text: "", changes: nil, error: nil, stage: "remote")
        r.remote = st
        return r
    }

    /// 一块 128×128：Demo 屏的底色上，点的地方一个蓝圈
    static func demoRing(at p: CGPoint) -> UIImage {
        let fmt = UIGraphicsImageRendererFormat()
        fmt.scale = 1
        return UIGraphicsImageRenderer(size: CGSize(width: 128, height: 128), format: fmt).image { ctx in
            UIColor(white: 0.94, alpha: 1).setFill()
            ctx.fill(CGRect(x: 0, y: 0, width: 128, height: 128))
            UIColor(red: 0.15, green: 0.45, blue: 0.95, alpha: 1).setStroke()
            let c = UIBezierPath(ovalIn: CGRect(x: p.x - 22, y: p.y - 22, width: 44, height: 44))
            c.lineWidth = 5
            c.stroke()
        }
    }
}
