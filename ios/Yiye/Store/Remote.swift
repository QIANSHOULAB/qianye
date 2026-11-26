import Foundation
import Observation
import UIKit
import YiyeKit

/// 172 遥控：工具箱「遥控」那一页的状态。先选电脑 / 掌机（只有在线的点得动），然后：
/// - 那台的截图一两秒一张（前一张回来了才要下一张）；点 = 左键、长按 = 右键、两指上下滑 = 滚轮，点完马上换一张；
/// - 底下打字发送；「密码」开关开着时框里只显示点点，发出去走 secret（整封信两头加密），发完清空；密码不存、不进日志。
/// - 关掉这一页、退到后台：结束（那台角上的「手机遥控中」消失）。
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
    /// UI 测试看的：上一下寄出去的是什么（Demo 里才写）
    private(set) var lastSent = ""

    @ObservationIgnored weak var app: AppModel?
    @ObservationIgnored private var session = ""
    @ObservationIgnored private var inflight: String?
    @ObservationIgnored private var sentAt = Date.distantPast
    @ObservationIgnored private var refresh: Task<Void, Never>?
    @ObservationIgnored private var demoShot = 0

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
        image = nil
        state = RemoteState()
        line = self.t("remote.connecting")
        draft = ""
        password = false
        send(RemoteOp(op: "open", session: session))
        loop()
    }

    /// 结束这一场（回到选机器）
    func stop() {
        refresh?.cancel()
        refresh = nil
        if let t = target, !session.isEmpty { fire(RemoteOp(op: "close", session: session), to: t) }
        target = nil
        session = ""
        inflight = nil
        waiting = false
        image = nil
        line = nil
        draft = ""
        password = false
    }

    /// 退到后台：结束
    func wentAway() {
        if target != nil { stop() }
    }

    /// 一两秒要一张：前一张回来了（或者等了 8 秒没回）才要下一张
    private func loop() {
        refresh?.cancel()
        refresh = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 1_500_000_000)
                guard let self, self.target != nil else { return }
                if self.inflight == nil || Date().timeIntervalSince(self.sentAt) > 8, self.app?.butler.remoteMayAsk() ?? true {   // 143：寄不出去就退避
                    self.send(RemoteOp(op: "shot", session: self.session))
                }
            }
        }
    }

    // ---------------------------------------------------------------- 手势、打字
    /// 在图上点了一下（x、y 是那张图上的比例）
    func tap(_ x: Double, _ y: Double, right: Bool = false) {
        guard let shot = state.shot else { return }
        send(RemoteOp(op: right ? "right" : "tap", session: session, shot: shot, x: x, y: y))
    }

    func scroll(_ x: Double, _ y: Double, notches: Int) {
        guard notches != 0, let shot = state.shot else { return }
        send(RemoteOp(op: "scroll", session: session, shot: shot, x: x, y: y, dy: notches))
    }

    func switchScreen() {
        let n = max(1, state.screens ?? 1)
        guard n > 1 else { return }
        send(RemoteOp(op: "shot", session: session, screen: ((state.screen ?? 0) + 1) % n))
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

    // ---------------------------------------------------------------- 寄、收
    private func send(_ op: RemoteOp) {
        guard let t = target else { return }
        let id = UUID().uuidString
        if op.op != "shot" { line = nil }
        if demo {
            if op.op != "shot" { lastSent = Self.describe(op) }     // 一两秒一张的截图不盖掉上一下
            return demoAnswer(id: id, op: op)
        }
        post(ButlerRequest.remote(id: id, op: op, target: t, at: ISOTime.string(Date()), app: ButlerService.appVersion))
    }

    private func post(_ req: ButlerRequest) {
        guard let app else { return }
        inflight = req.id
        sentAt = Date()
        waiting = true
        Task {
            let why = await app.butler.sendRemote(req)
            app.butler.autoDone("remote", ok: why == nil)
            if let why {
                if self.inflight == req.id { self.inflight = nil; self.waiting = false }
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

    /// 那台的回信（ButlerService 收信时叫）
    func answer(_ r: ButlerResult, image data: Data?) {
        let st = r.remote ?? RemoteState()
        if let s = st.session, !s.isEmpty, s != session, !session.isEmpty { return }      // 上一场的
        if r.id == inflight { inflight = nil; waiting = false }
        if let data, let img = UIImage(data: data) {
            image = img
            state = st
        } else if st.shot != nil {
            state = st
        }
        if st.ended == true {
            refresh?.cancel()
            refresh = nil
            line = r.ok ? (r.text ?? t("remote.ended")) : (r.error ?? t("remote.ended"))
            target = nil
            session = ""
            return
        }
        if !r.ok { line = r.error ?? t("remote.failed") }
        else if st.black == true { line = t("remote.black") }
    }

    static func describe(_ op: RemoteOp) -> String {
        switch op.op {
        case "tap", "right": return String(format: "%@ %.2f %.2f", op.op, op.x ?? 0, op.y ?? 0)
        case "scroll": return "scroll \(op.dy ?? 0)"
        case "type": return "type \(op.text ?? "")"
        default: return op.op
        }
    }

    // ---------------------------------------------------------------- Demo（截图、UI 测试）：假大管家回一张画出来的屏
    private func demoAnswer(id: String, op: RemoteOp) {
        if op.op == "close" { return }
        demoShot += 1
        let size = CGSize(width: 1280, height: 800)
        let img = UIGraphicsImageRenderer(size: size).image { ctx in
            UIColor(white: 0.94, alpha: 1).setFill()
            ctx.fill(CGRect(origin: .zero, size: size))
            UIColor(red: 0.13, green: 0.33, blue: 0.6, alpha: 1).setFill()
            ctx.fill(CGRect(x: 0, y: 0, width: size.width, height: 56))
            let a: [NSAttributedString.Key: Any] = [.font: UIFont.systemFont(ofSize: 34, weight: .medium), .foregroundColor: UIColor.darkGray]
            ("Desktop · \(demoShot)" as NSString).draw(at: CGPoint(x: 60, y: 120), withAttributes: a)
            UIColor(red: 0.78, green: 0.16, blue: 0.16, alpha: 1).setFill()
            ctx.fill(CGRect(x: 1020, y: 70, width: 230, height: 50))
        }
        let path = "遥控/demo-\(demoShot).jpg"
        let st = RemoteState(on: true, session: session, screen: 0, shot: demoShot, w: 2560, h: 1600, screens: 1, image: path)
        let r = ButlerResult(id: id, note: "", ok: true, text: "", changes: nil, error: nil, stage: "remote")
        var rr = r
        rr.remote = st
        inflight = id
        answer(rr, image: img.jpegData(compressionQuality: 0.6))
    }
}
