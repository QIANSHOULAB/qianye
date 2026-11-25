import Foundation
import os
import YiyeKit

/// 170：说话的功能出错时那一行字写全（错误码放前面，截掉一半也看得到），完整的留在系统日志里（Console 里 lab.qianshou.yiye / ear）
enum EarText {
    static let logger = Logger(subsystem: "lab.qianshou.yiye", category: "ear")

    static func detail(_ error: Error) -> String {
        let ns = error as NSError
        return AudioErrorLine.of(domain: ns.domain, code: ns.code, text: ns.localizedDescription)
    }

    static func log(_ why: String, _ detail: String) {
        logger.error("170 \(why, privacy: .public)：\(detail, privacy: .public)")
    }
}

/// 170：诊断经信箱寄给大管家（look-check 那封，diag=1），存在电脑上 logs/yiye-diag.jsonl。
/// 只有出了什么错、错误码、哪个入口、重开几回、卡了多久、回声消除开没开；不带录音、不带便签内容。同一种一分钟一封、一天最多 30 封
@MainActor
final class EarDiagSender {
    static let shared = EarDiagSender()
    weak var app: AppModel?
    private var gate = DiagGate()

    func send(_ d: EarDiag) {
        guard let app, app.demo == nil else { return }
        let day = Calendar.current.ordinality(of: .day, in: .era, for: Date()) ?? 0
        guard gate.allow(d.kind, now: ProcessInfo.processInfo.systemUptime, dayNumber: day) else { return }
        app.butler.sendDiag(d)
    }

    /// 界面卡住超过 1 秒
    func stall(_ seconds: Double) {
        guard let app else { return }
        let entry: EarDiag.Entry = ShutongTalker.shared.on ? .shutong : app.companion.diagEntry
        send(EarDiag(kind: .stall, entry: entry, line: String(format: "界面卡了 %.1f 秒", seconds), stall: seconds))
    }
}

/// 170：界面卡没卡。后台每 0.25 秒往主线程丢一下（上一下没跑到就不丢），主线程晚了超过 1 秒才跑到 = 卡了这么久。
/// 只在前台开着；刚回前台的 5 秒不算
final class StallWatch: @unchecked Sendable {
    static let shared = StallWatch()
    private let q = DispatchQueue(label: "lab.qianshou.yiye.stall", qos: .utility)
    private let lock = NSLock()
    private var timer: DispatchSourceTimer?
    private var waiting = false
    private var since: Double = 0

    func start() {
        q.async {
            guard self.timer == nil else { return }
            self.lock.lock()
            self.since = ProcessInfo.processInfo.systemUptime
            self.waiting = false
            self.lock.unlock()
            let t = DispatchSource.makeTimerSource(queue: self.q)
            t.schedule(deadline: .now() + StallRule.every, repeating: StallRule.every)
            t.setEventHandler { [weak self] in self?.ping() }
            t.resume()
            self.timer = t
        }
    }

    func stop() {
        q.async {
            self.timer?.cancel()
            self.timer = nil
        }
    }

    private func ping() {
        lock.lock()
        if waiting { lock.unlock(); return }
        waiting = true
        let since = self.since
        lock.unlock()
        let posted = ProcessInfo.processInfo.systemUptime
        DispatchQueue.main.async {
            let ran = ProcessInfo.processInfo.systemUptime
            self.lock.lock()
            self.waiting = false
            self.lock.unlock()
            guard posted - since > StallRule.graceAfterActive, let lag = StallRule.isStall(posted: posted, ran: ran) else { return }
            MainActor.assumeIsolated { EarDiagSender.shared.stall(lag) }
        }
    }
}
