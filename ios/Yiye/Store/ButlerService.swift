import Foundation
import Observation
import YiyeKit

/// 连大管家：管子就是镜像文件夹，手机上不存任何 AI 钥匙。
/// 只在 app 开着时看结果：进前台看一次，开着时每 5 秒看一次。不用后台能力。
@MainActor @Observable
final class ButlerService {
    var presence: ButlerPresence = .never
    private(set) var lastLook: Date?
    @ObservationIgnored weak var app: AppModel?
    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private var looking = false
    static let appVersion = (Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String) ?? "0.1.0"

    func start() {
        guard timer == nil else { return }
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
    }

    /// 交给大管家：先写笔记和原图进镜像，再放请求（先写 .part，写完改名）
    func submit(_ n: Note) {
        guard let app else { return }
        var st = n.butlerState
        let id = UUID().uuidString
        guard let channel = app.mirror.channel else {
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
        let req = ButlerRequest(id: id, note: n.id.uuidString, kind: kind, text: n.markdown,
                                images: kind == .photo ? n.originalPaths : nil,
                                unsure: unsureTexts, at: ISOTime.string(Date()), app: ButlerService.appVersion)
        st.submitted(id: id, text: n.markdown, at: Date())
        n.butlerState = st
        try? app.context.save()
        app.mirror.saveNow(n, attachments: app.attachments)
        let snapPaths = n.originalPaths
        let store = app.attachments
        let folder = app.mirror.folder
        app.mirror.afterPendingWrites {
            if let folder {
                for p in snapPaths where !folder.hasAttachment(p) {
                    if let d = try? Data(contentsOf: store.url(p)) { try? folder.writeAttachment(d, relative: p) }
                }
            }
            let err: String?
            do { try channel.submit(req); err = nil } catch { err = "\(error.localizedDescription)" }
            Task { @MainActor [weak self] in
                guard let err, let self, let app = self.app, let n = app.note(n_id(req)) else { return }
                var s = n.butlerState
                s.phase = .failed
                s.error = err
                n.butlerState = s
                try? app.context.save()
            }
        }
    }

    /// 看一眼：心跳、在等的结果
    func look() {
        guard let app, !looking, let channel = app.mirror.channel else {
            if app?.mirror.isOn == false { presence = .never }
            return
        }
        looking = true
        let waiting: [(UUID, String)] = app.allNotes().compactMap { n in
            let s = n.butlerState
            guard s.phase == .waiting, let rid = s.requestID else { return nil }
            return (n.id, rid)
        }
        app.mirror.afterPendingWrites {
            let hb = channel.heartbeat()
            var got: [(UUID, ButlerResult)] = []
            for (nid, rid) in waiting {
                if let r = channel.result(rid) { got.append((nid, r)) }
            }
            let results = got
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.looking = false
                self.lastLook = Date()
                self.presence = ButlerPresence.from(hb)
                for (nid, r) in results { self.apply(r, to: nid, channel: channel) }
            }
        }
    }

    /// 结果回来：没改过就直接换上；改过了等着点；出错原样显示。用完删结果文件
    private func apply(_ r: ButlerResult, to noteID: UUID, channel: ButlerChannel) {
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
        let id = r.id
        app.mirror.afterPendingWrites { channel.removeResult(id) }
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

private func n_id(_ r: ButlerRequest) -> UUID { UUID(uuidString: r.note) ?? UUID() }

extension Notification.Name {
    /// 大管家把笔记的字换了：写字页要重新装字
    static let yiyeNoteReplaced = Notification.Name("yiyeNoteReplaced")
}
