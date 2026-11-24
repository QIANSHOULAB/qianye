import Foundation
import Observation
import YiyeKit

/// 备用信箱（130）：谷歌 Firebase 那根管子在 app 里的接线。
/// 配置（apiKey、databaseURL）是大管家经 Cloudflare 递来的 kind2=config，存钥匙串；没收到配置之前只有 Cloudflare 一条路。
/// 匿名登录的 refreshToken 也在钥匙串。进、出备用模式都不弹提示，只在设置里大管家那一行多一行小字。
/// 令牌、配置、信的内容不进日志、不进截图。
struct KeychainFbTokens: FbTokenStore {
    static let account = "fb-refresh"
    func load() -> String? { Keychain.read(Self.account).flatMap { String(data: $0, encoding: .utf8) } }
    func save(_ refreshToken: String?) {
        if let t = refreshToken { Keychain.write(Data(t.utf8), Self.account) } else { Keychain.delete(Self.account) }
    }
}

/// 流：URLSession 一行一行读。Firebase 的 data 总是一行，空行被 lines 吞掉也不影响（SSEParser 不靠空行）
struct URLSessionStreamer: FbStreamer {
    func lines(_ req: URLRequest) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { cont in
            let t = Task {
                do {
                    let (bytes, resp) = try await URLSession.shared.bytes(for: req)
                    if let h = resp as? HTTPURLResponse, h.statusCode != 200 {
                        cont.finish(throwing: FbError.http(h.statusCode, ""))
                        return
                    }
                    for try await line in bytes.lines { cont.yield(line) }
                    cont.finish()
                } catch {
                    cont.finish(throwing: error)
                }
            }
            cont.onTermination = { _ in t.cancel() }
        }
    }
}

@MainActor @Observable
final class BackupCoordinator {
    static let configAccount = "fb-config"

    /// MailClient 寄信时看的那个
    let hub = MailBackup()
    /// 收到过配置（设置里「备用通道：有」）
    private(set) var config: FbConfig?
    /// 现在走备用通道
    private(set) var on = false
    @ObservationIgnored weak var service: ButlerService?
    @ObservationIgnored private var pipe: FbPipe?
    @ObservationIgnored private var listener: FbListener?
    @ObservationIgnored private var seenTask: Task<Void, Never>?
    @ObservationIgnored private var suspended = false

    init() {
        if let d = Keychain.read(Self.configAccount), let c = try? JSONDecoder().decode(FbConfig.self, from: d), c.isValid { config = c }
        hub.onChange = { [weak self] change in
            Task { @MainActor in self?.changed(change) }
        }
    }

    var hasConfig: Bool { config != nil }

    /// 信箱的配对有了（或换了）：用这个信箱号建管子。没配置就什么都不做
    func configure(box: String?) {
        stopListening()
        guard let c = config, let box, !box.isEmpty else {
            pipe = nil
            hub.setPipe(nil)
            on = false
            return
        }
        let http = URLSessionHTTP()
        let auth = FbAuth(config: c, http: http, store: KeychainFbTokens())
        let p = FbPipe(config: c, box: box, auth: auth, http: http, streamer: URLSessionStreamer())
        pipe = p
        hub.setPipe(p)
        if hub.isOn { startListening() }
    }

    /// 大管家递来的配置：存钥匙串（一样的不重存），用上。返回是不是新的
    @discardableResult
    func adopt(_ c: FbConfig, box: String?) -> Bool {
        guard c.isValid else { return false }
        if config == c { return false }
        if let d = try? JSONEncoder().encode(c) { Keychain.write(d, Self.configAccount) }
        Keychain.delete(KeychainFbTokens.account)            // 换了项目：旧的登录作废
        config = c
        configure(box: box)
        return true
    }

    // ---------------------------------------------------------------- 进出备用模式
    private func changed(_ c: BackupGate.Change) {
        switch c {
        case .entered:
            on = true
            startListening()
        case .left:
            on = false
            stopListening()
        }
    }

    /// 退到后台：不听了；回前台：还在备用模式就接着听
    func suspend() {
        suspended = true
        stopListening()
    }

    func resume() {
        suspended = false
        if hub.isOn { startListening() }
    }

    private func startListening() {
        guard !suspended, let p = pipe, listener == nil else { return }
        let l = FbListener(pipe: p, onLetter: { [weak self] letter in
            Task { @MainActor in self?.service?.fbLetter(letter) }
        }, onBroken: { [weak self] mid in
            Task { @MainActor in self?.dropBroken(mid) }
        })
        listener = l
        l.start()
        seenTask?.cancel()
        seenTask = Task {                                   // 备用模式下每 60 秒写一次 seen/phone
            while !Task.isCancelled {
                try? await p.writeSeen("phone")
                try? await Task.sleep(nanoseconds: 60_000_000_000)
            }
        }
    }

    private func stopListening() {
        listener?.stop()
        listener = nil
        seenTask?.cancel()
        seenTask = nil
    }

    private func dropBroken(_ mid: String) {
        guard let p = pipe else { return }
        Task { try? await p.delete(mid: mid, dir: "to_phone") }
    }

    /// 办完一封（ack）：删
    func ack(_ mid: String) {
        guard let p = pipe else { return }
        Task { try? await p.delete(mid: mid, dir: "to_phone") }
    }
}
