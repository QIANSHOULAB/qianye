import Foundation
import Observation
import UIKit
import YiyeKit

/// 258 灵感库：像素走私犯寄过的设计图。库在电脑上（pc-butler 257），手机存一份目录和缩略图，原图点开时取、取过的留着，
/// 没网也能翻已经存下的。接口 v3.29（ask=library，只走信箱）。目录怎么改在 YiyeKit 的 LibraryBook。
@MainActor @Observable
final class LibraryModel {
    static let shared = LibraryModel()

    @ObservationIgnored weak var app: AppModel?
    var book = LibraryBook()
    var syncing = false
    /// 墙顶上那一句：大管家不在 / 大管家回的错
    var note: String?
    /// 正在取原图的
    var fetching: Set<String> = []
    var fetchError: [String: String] = [:]

    private struct Wait {
        /// list / get / drop / undrop
        var action: String
        var id: String = ""
        var ticket = 0
        var at = Date()
    }

    @ObservationIgnored private var waits: [String: Wait] = [:]
    @ObservationIgnored private var tickets: [String: Int] = [:]
    @ObservationIgnored private var lastSync: Date?
    @ObservationIgnored private var loaded = false
    /// 截图、UI 测试的假大管家记着不留了的
    @ObservationIgnored private var demoOut: Set<String> = []
    private let cache = NSCache<NSString, UIImage>()

    var waitingIDs: Set<String> { Set(waits.keys) }

    private var zh: Bool { app?.lang.isZh ?? true }
    private var demo: Bool { app?.demo != nil }
    private func t(_ k: String) -> String { app?.lang.t(k) ?? k }

    // ---------------------------------------------------------------- 存
    private var dir: URL? {
        let base = demo ? FileManager.default.temporaryDirectory
                        : FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
        guard let d = base?.appendingPathComponent(demo ? "library-demo" : "library", isDirectory: true) else { return nil }
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }

    private var bookFile: URL? { demo ? nil : dir?.appendingPathComponent("book.json") }

    func load() {
        guard !loaded else { return }
        loaded = true
        if let f = bookFile, let d = try? Data(contentsOf: f), let b = try? JSONDecoder().decode(LibraryBook.self, from: d) { book = b }
    }

    private func save() {
        if let f = bookFile, let d = try? JSONEncoder().encode(book) { try? d.write(to: f, options: .atomic) }
    }

    /// 改目录：掉出去的图一起删
    private func change(_ edit: (inout LibraryBook) -> Void) {
        let before = book.files
        var b = book
        edit(&b)
        book = b
        for name in before.subtracting(b.files) {
            cache.removeObject(forKey: name as NSString)
            if let u = dir?.appendingPathComponent(name) { try? FileManager.default.removeItem(at: u) }
        }
        save()
    }

    /// 信里带来的一张图存下来；回手机上的文件名
    private func keep(_ path: String, _ files: [String: Data]) -> (name: String, data: Data)? {
        guard let name = BotPost.fileName(path), let d = files[path], let u = dir?.appendingPathComponent(name) else { return nil }
        do { try d.write(to: u, options: .atomic) } catch { return nil }
        cache.removeObject(forKey: name as NSString)
        return (name, d)
    }

    func data(_ name: String) -> Data? {
        dir.flatMap { try? Data(contentsOf: $0.appendingPathComponent(name)) }
    }

    /// 同一个名字回同一张（放大看的时候界面刷新不会跳回原大小）
    func image(_ name: String) -> UIImage? {
        if let i = cache.object(forKey: name as NSString) { return i }
        guard let d = data(name), let i = UIImage(data: d) else { return nil }
        cache.setObject(i, forKey: name as NSString)
        return i
    }

    // ---------------------------------------------------------------- 取新的
    /// 打开时只取上回以后变过的。force = 进灵感库那一页；别处一分钟内不重复敲
    func sync(force: Bool = false) {
        load()
        let now = Date()
        if waits.values.contains(where: { $0.action == "list" && now.timeIntervalSince($0.at) < 60 }) { return }
        if !force, let l = lastSync, now.timeIntervalSince(l) < 60 { return }
        lastSync = now
        note = nil
        syncing = true
        list()
    }

    private func list() {
        send(LibraryAsk("list", since: book.cursor, limit: 40), Wait(action: "list"))
    }

    // ---------------------------------------------------------------- 原图
    /// 点开一条：原图还没有就去取
    func open(_ id: String) {
        load()
        fetchError[id] = nil
        guard let e = book.entry(id) else { return }
        if let shots = e.shots, !shots.isEmpty, shots.allSatisfy({ image($0.name) != nil }) { return }
        guard !fetching.contains(id) else { return }
        fetching.insert(id)
        send(LibraryAsk("get", id: id), Wait(action: "get", id: id))
    }

    // ---------------------------------------------------------------- 不留、撤回
    /// 他刚点了：屏上当场照办。回的号交给 settle / giveUp（连点几下，只认最后那一下的回话）
    func intend(_ id: String, kept: Bool) -> Int {
        load()
        let n = (tickets[id] ?? 0) + 1
        tickets[id] = n
        change { $0.intend(id, kept: kept) }
        return n
    }

    func settle(_ id: String, kept: Bool, ticket: Int) {
        guard tickets[id] == ticket else { return }
        if demo { if kept { demoOut.remove(id) } else { demoOut.insert(id) } }
        change { $0.settle(id, kept: kept) }
    }

    func giveUp(_ id: String, ticket: Int) {
        guard tickets[id] == ticket else { return }
        change { $0.giveUp(id) }
    }

    /// 灵感库页里点的 👎 / 撤回（聊天窗里那个走 ask=bot do=react，同一件事）
    func setKept(_ id: String, _ kept: Bool) {
        let ticket = intend(id, kept: kept)
        BotsModel.shared.mark(id, out: !kept)
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        send(LibraryAsk(kept ? "undrop" : "drop", id: id), Wait(action: kept ? "undrop" : "drop", id: id, ticket: ticket))
    }

    // ---------------------------------------------------------------- 寄、收
    private func send(_ ask: LibraryAsk, _ wait: Wait) {
        guard let app else { return }
        let rid = UUID().uuidString
        let req = ButlerRequest.library(id: rid, ask: ask, at: ISOTime.string(Date()), app: ButlerService.appVersion)
        waits[rid] = wait
        if app.demo != nil { fake(req); return }
        Task {
            switch await app.butler.sendBots(req) {
            case .sent(let pc):
                // 信在信箱里排着：晚到的回信照认
                if !pc && self.waits[rid] != nil { self.note = self.t("lib.offline") }
            case .noPair:
                self.failed(rid, self.t("shutong.noPair"))
            case .failed(let why):
                self.failed(rid, app.lang.f("shutong.sendFailed", why))
            }
        }
    }

    private func failed(_ rid: String, _ why: String) {
        guard let w = waits.removeValue(forKey: rid) else { return }
        switch w.action {
        case "list":
            syncing = false
            lastSync = nil
            note = why
        case "get":
            fetching.remove(w.id)
            fetchError[w.id] = why
        default:                                                     // 没办成：放回原来的
            guard tickets[w.id] == w.ticket else { return }
            giveUp(w.id, ticket: w.ticket)
            BotsModel.shared.mark(w.id, out: !book.visible(w.id))
            app?.show(why)
        }
    }

    func answer(_ r: ButlerResult, files: [String: Data]) {
        load()
        let w = waits[r.id]
        guard r.ok, let reply = r.library else {
            let e = (r.error ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            failed(r.id, e.isEmpty ? t("shutong.brainFailed") : e)
            return
        }
        waits.removeValue(forKey: r.id)
        switch reply.action {
        case "list":
            // 不是在等的（app 被杀过、晚到的）：比手上的新才认，别把目录倒回去
            if w == nil && (reply.reset == true || (reply.cursor ?? 0) <= book.cursor) { return }
            var saved: [String: LibraryThumb] = [:]
            for c in reply.items ?? [] {
                guard let p = c.thumb, let got = keep(p, files) else { continue }
                let size = UIImage(data: got.data)?.size ?? .zero
                saved[c.id] = LibraryThumb(name: got.name, ratio: size.height > 0 ? Double(size.width / size.height) : 1)
            }
            let was = book.cursor
            change { $0.apply(reply, saved: saved) }
            note = nil
            if reply.more == true && (reply.cursor ?? 0) != was {
                list()
            } else {
                syncing = false
            }
        case "get":
            guard let id = reply.id ?? w?.id else { return }
            var shots: [LibraryShot] = []
            for p in reply.images ?? [] {
                if let got = keep(p.path, files) { shots.append(LibraryShot(role: p.role, name: got.name)) }
            }
            change { $0.fill(id, card: reply.item, shots: shots) }
            fetching.remove(id)
            fetchError[id] = nil
            note = nil
        case "drop", "undrop":
            guard let id = reply.id ?? w?.id else { return }
            let kept = reply.kept ?? (reply.action == "undrop")
            if let w {
                settle(id, kept: kept, ticket: w.ticket)
            } else if tickets[id] == nil {
                change { $0.settle(id, kept: kept) }
            }
        default:
            break
        }
    }

    /// 等太久的别一直转圈（ButlerService.look 每 5 秒叫）。信还在信箱里，晚到照认
    func tick() {
        guard loaded, !waits.isEmpty else { return }
        let now = Date()
        for (rid, w) in waits {
            let age = now.timeIntervalSince(w.at)
            if age > 86_400 { waits[rid] = nil; continue }
            guard age > 90 else { continue }
            if w.action == "list" && syncing { syncing = false; if note == nil { note = t("bots.noAnswer") } }
            if w.action == "get" && fetching.contains(w.id) { fetching.remove(w.id); fetchError[w.id] = t("bots.noAnswer") }
        }
    }

    // ---------------------------------------------------------------- 截图、UI 测试用的假大管家（Demo）
    /// 假库里五条：前三条就是掌眼窗里寄来的那三条
    private func demoCards() -> [LibraryCard] {
        let z = zh
        func c(_ id: String, _ kind: String, _ punctum: String, _ difference: String, _ move: String, _ site: String, label: String = "") -> LibraryCard {
            LibraryCard(id: id, bot: "bdemoeye1", kind: kind, date: "2026-11-28", label: label, punctum: punctum, move: move,
                        site: site, url: "https://\(site)/", difference: difference)
        }
        let web = z ? "网页" : "Web", product = z ? "产品" : "Product", type = z ? "字体" : "Type", poster = z ? "海报" : "Poster"
        return [
            c("zdemo1", web, z ? "整屏只有一根烧红的铁丝" : "A single red-hot wire on the whole screen",
              z ? "同类堆卡片，它只留一根线" : "Others stack cards; this keeps one line",
              z ? "一个主角，别的全退后" : "One hero, everything else steps back", "ritual.engineer"),
            c("zdemo2", web, z ? "灰字符堆成的波团漫过白字列表" : "A wave of grey glyphs over a white list",
              z ? "背景敢抢字的戏" : "The background fights the type", z ? "让底纹动起来" : "Let the texture move", "every.to",
              label: z ? "少数派" : "Minority"),
            c("zdemo3", product, z ? "酒红漆管直角垂下喇叭罩" : "A wine-red pipe bends straight down",
              z ? "结构当装饰" : "Structure as ornament", z ? "一根管子讲完" : "Say it with one tube", "behance.net"),
            c("zlib4", type, z ? "黑三角啃碎一整版白色大字" : "Black triangles chew up the big white type",
              z ? "字被啃了还认得出" : "Still readable after the bite", z ? "用形状切字" : "Cut type with shapes", "typewolf.com"),
            c("zlib5", poster, z ? "写满字的彩管缠成一堆" : "Lettered tubes in a tangle",
              z ? "字长在物体上" : "Type grows on objects", z ? "把字印在会拐弯的东西上" : "Print on things that bend", "posterhouse.org"),
        ]
    }

    private func fake(_ req: ButlerRequest) {
        guard let a = req.library else { return }
        let rid = req.id
        let cards = demoCards()
        Task {
            try? await Task.sleep(nanoseconds: 400_000_000)
            let pictures = DemoDesign.library()
            var files: [String: Data] = [:]
            let reply: LibraryReply
            switch a.action {
            case "list":
                var items: [LibraryCard] = []
                if (a.since ?? 0) < cards.count {
                    for (n, card) in cards.enumerated() where !self.demoOut.contains(card.id) {
                        var c = card
                        let path = "附件/\(c.id)-t.jpg"
                        files[path] = pictures[n % pictures.count].thumb
                        c.thumb = path
                        c.difference = ""
                        items.append(c)
                    }
                }
                var kinds: [String] = []
                for c in cards where !kinds.contains(c.kind) { kinds.append(c.kind) }
                reply = LibraryReply("list", cursor: cards.count, more: false, reset: false, kinds: kinds, items: items.reversed(), gone: [])
            case "get":
                guard let n = cards.firstIndex(where: { $0.id == a.id }) else { return }
                var images: [LibraryPicture] = []
                for (role, d) in pictures[n % pictures.count].images {
                    let path = "附件/\(cards[n].id)-\(role).jpg"
                    files[path] = d
                    images.append(LibraryPicture(role: role, path: path))
                }
                reply = LibraryReply("get", id: a.id, item: cards[n], images: images)
            default:
                reply = LibraryReply(a.action, id: a.id, cursor: cards.count + 1, kept: a.action == "undrop")
            }
            var r = ButlerResult(id: rid, note: "", ok: true, text: "", changes: nil, error: nil, host: "电脑", stage: "library")
            r.library = reply
            self.answer(r, files: files)
        }
    }
}
