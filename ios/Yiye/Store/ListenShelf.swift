import Foundation
import Observation
import YiyeKit

/// 225：听力笔记另外记的两样（谁配的、大管家译好的意思，每条笔记一个小文件）和每个嗓子打了几星
@MainActor @Observable
final class ListenShelf {
    @ObservationIgnored private let dir: URL
    @ObservationIgnored private let persist: Bool
    @ObservationIgnored private var cache: [UUID: ListenExtras] = [:]
    /// 哪条笔记记的东西变了就加一：页面跟着重画
    private(set) var version = 0
    private(set) var ratings: VoiceRatings

    static let ratingsKey = "yiye.voiceRatings"

    init(base: URL, persist: Bool) {
        self.persist = persist
        dir = base.appendingPathComponent("听力另记", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let saved = persist ? UserDefaults.standard.data(forKey: ListenShelf.ratingsKey) : nil
        ratings = saved.flatMap { try? JSONDecoder().decode(VoiceRatings.self, from: $0) } ?? VoiceRatings()
    }

    private func file(_ note: UUID) -> URL { dir.appendingPathComponent("\(note.uuidString).json") }

    func extras(_ note: UUID) -> ListenExtras {
        _ = version
        if let e = cache[note] { return e }
        let e = (try? Data(contentsOf: file(note))).flatMap { try? JSONDecoder().decode(ListenExtras.self, from: $0) } ?? ListenExtras()
        cache[note] = e
        return e
    }

    /// 送来的一封（新稿、重配、只送字、补译）
    func delivered(_ note: UUID, audio: String?, voice: ListenVoice?, trans: ListenTrans?) {
        if let voice {
            var r = ratings
            r.delivered(voice)
            keep(r)
        }
        let before = extras(note)
        var e = before
        e.delivered(audio: audio, voice: voice, trans: trans)
        guard e != before else { return }
        cache[note] = e
        if e.isEmpty {
            try? FileManager.default.removeItem(at: file(note))
        } else if let data = try? JSONEncoder().encode(e) {
            try? data.write(to: file(note), options: .atomic)
        }
        version += 1
    }

    /// 笔记真删了
    func drop(_ note: UUID) {
        cache[note] = nil
        try? FileManager.default.removeItem(at: file(note))
    }

    /// 这段录音是谁配的（手机自己念的、老稿：nil）
    func voice(for track: Track) -> ListenVoice? { extras(track.note).voice(for: track.path) }

    func stars(_ v: ListenVoice) -> Int { ratings.stars(v.key) }
    func undoStars(_ v: ListenVoice) -> Int { ratings.undo(v.key) }

    func rate(_ v: ListenVoice, _ stars: Int) {
        var r = ratings
        r.rate(v.key, stars)
        keep(r)
    }

    private func keep(_ r: VoiceRatings) {
        guard r != ratings else { return }
        ratings = r
        if persist, let data = try? JSONEncoder().encode(r) { UserDefaults.standard.set(data, forKey: ListenShelf.ratingsKey) }
    }
}
