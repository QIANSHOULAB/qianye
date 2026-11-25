import Foundation
import Observation
import SwiftUI
import SwiftData
import AVFoundation
import YiyeKit

/// 聊天窗里的一行（136 书童）
struct ShutongLine: Codable, Identifiable, Equatable {
    var id = UUID()
    /// he 他说的 / say 书童说的 / receipt 一批的回执 / confirm 要他点头的 / note 一行小字（没动的、出错的）
    var who: String
    var text: String
    var at = Date()
    /// he：在等的请求 id；confirm：哪种（chat / sweep）
    var rid: String?
    var mode: String = "chat"
    /// receipt：哪一批（能撤销）
    var batch: String?
    var undone = false
    /// receipt：新便签自动收拾的
    var auto = false
    /// confirm：要动手的（扔、合并……），struck 是他划掉的那几条的下标
    var acts: [ShutongAct]?
    var struck: [Int] = []
    /// he：waiting / answered / failed；confirm：pending / done / cancelled
    var state = ""
}

/// 存在手机里的：聊天记录（最近 200 条）、最近 40 批的快照、这周的清理建议
private struct ShutongStore: Codable {
    var lines: [ShutongLine] = []
    var batches: [ShutongBatch] = []
    var slip: ShutongLine?
    var sweepRid: String?
}

/// 136 书童：住在一叶笺里的小帮手。大管家当大脑，这里当手：
/// - 新便签一存下就收拾（语音的去口水、起标题、进文件夹；打字的、拍照的只起标题、进文件夹）；
/// - 聊天窗里他说一句（打字或者按住说），大脑回一串动作，查过再做；扔东西、合并的先列出来，他点「照办」才做；
/// - 每周日一次清理建议：主页顶上一张纸条，他过目、划掉不扔的、点「照扔」才扔。
/// 每一批一个快照，回执上「撤销这一批」一点全回去。
@MainActor @Observable
final class ShutongModel {
    static let shared = ShutongModel()
    static let maxLines = 200
    static let maxBatches = 40
    static let catalogMax = 400

    @ObservationIgnored weak var app: AppModel?
    /// 聊天窗开着
    var open = false
    var lines: [ShutongLine] = []
    var input = ""
    /// 按住说话：在录 / 录完在等大管家认字
    var recording = false
    var hearing = false
    /// 每周日的清理建议（主页顶上那张纸条）
    var slip: ShutongLine?

    @ObservationIgnored private var batches: [ShutongBatch] = []
    @ObservationIgnored private var sweepRid: String?
    @ObservationIgnored private var chatWait: [String: (line: UUID, round: Int, at: Date)] = [:]
    @ObservationIgnored private var hearWait: Set<String> = []
    @ObservationIgnored private var nextTry: [UUID: Date] = [:]
    @ObservationIgnored private var recorder: AVAudioRecorder?
    @ObservationIgnored private var recURL: URL?
    @ObservationIgnored private var recStart = Date.distantPast
    @ObservationIgnored private var loaded = false

    private var zh: Bool { app?.lang.isZh ?? true }
    private func t(_ k: String) -> String { app?.lang.t(k) ?? k }

    /// 在等大脑回话的（聊天窗里显示「书童在想」）
    var thinking: Bool { lines.contains { $0.who == "he" && $0.state == "waiting" } }

    // ---------------------------------------------------------------- 存
    private var file: URL? {
        guard app?.demo == nil, let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else { return nil }
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("shutong.json")
    }

    func load() {
        guard !loaded else { return }
        loaded = true
        guard let file, let d = try? Data(contentsOf: file), let s = try? JSONDecoder().decode(ShutongStore.self, from: d) else { return }
        lines = s.lines
        batches = s.batches
        slip = s.slip
        sweepRid = s.sweepRid
        // app 被杀过：还在等的那几句，回信来了照样认（按请求 id），超时的下面 tick 里收
        for l in lines where l.who == "he" && l.state == "waiting" { if let r = l.rid { chatWait[r] = (line: l.id, round: 1, at: l.at) } }
    }

    private func save() {
        if lines.count > ShutongModel.maxLines { lines.removeFirst(lines.count - ShutongModel.maxLines) }
        if batches.count > ShutongModel.maxBatches { batches.removeFirst(batches.count - ShutongModel.maxBatches) }
        guard let file else { return }
        let s = ShutongStore(lines: lines, batches: batches, slip: slip, sweepRid: sweepRid)
        if let d = try? JSONEncoder().encode(s) { try? d.write(to: file, options: .atomic) }
    }

    /// 设置里「清空书童聊天记录」：聊天记录清掉；快照留着（撤销还能用，只是看不到回执了）
    func clearChat() {
        lines = []
        save()
    }

    /// 回信来了认得出是书童的：在等的请求 id
    var waitingIDs: Set<String> { Set(chatWait.keys).union(hearWait).union(sweepRid.map { [$0] } ?? []) }

    // ---------------------------------------------------------------- 便签 ⇄ 书童眼里的样子
    private func snap(_ n: Note) -> ShutongNote {
        ShutongNote(id: n.id.uuidString, markdown: n.markdown, folder: n.folder?.name, pinned: n.pinned, trashed: n.trashed,
                    trashedAt: n.trashedAt, modifiedAt: n.modifiedAt, spoken: n.spoken, kind: n.kind,
                    manualPaper: n.pinnedTint != nil, pinnedBy: n.shutongState.pinnedBy)
    }

    func allFolders() -> [Folder] {
        guard let app else { return [] }
        return ((try? app.context.fetch(FetchDescriptor<Folder>(sortBy: [SortDescriptor(\.order)]))) ?? []).filter { !$0.isListenOnly }
    }

    /// 现在的样子：便签（听力不算，扔了的也带上：撤销要放回）、文件夹名、书童自己建过几个
    func world() -> (notes: [String: ShutongNote], folders: [String], auto: Int) {
        guard let app else { return ([:], [], 0) }
        var notes: [String: ShutongNote] = [:]
        for n in app.allNotes() where n.kind != "listen" { notes[n.id.uuidString] = snap(n) }
        let fs = allFolders()
        return (notes, fs.map(\.name), fs.filter(\.auto).count)
    }

    private func card(_ n: Note) -> ShutongCard {
        ShutongCard(id: n.id.uuidString, title: n.title, folder: n.folder?.name ?? "", head: Markdown5.summary(n.markdown, maxChars: 200),
                    created: ISOTime.string(n.createdAt), modified: ISOTime.string(n.modifiedAt), chars: n.markdown.count, kind: n.kind,
                    locked: n.pinnedTint != nil || (n.pinned && !n.shutongState.pinnedBy))
    }

    func folderInfo() -> [ShutongFolderInfo] {
        allFolders().map { f in
            let live = (f.notes ?? []).filter { !$0.trashed }.sorted { $0.modifiedAt > $1.modifiedAt }
            return ShutongFolderInfo(name: f.name, auto: f.auto, count: live.count, samples: live.prefix(5).map(\.title))
        }
    }

    func history() -> [ShutongTalk] {
        lines.filter { $0.who == "he" || $0.who == "say" }.suffix(10).map { ShutongTalk(who: $0.who == "he" ? "he" : "shutong", text: String($0.text.prefix(400))) }
    }

    func catalog() -> [ShutongCard] {
        guard let app else { return [] }
        return app.allNotes().filter { !$0.trashed && $0.kind != "listen" }.sorted { $0.modifiedAt > $1.modifiedAt }
            .prefix(ShutongModel.catalogMax).map { card($0) }
    }

    /// 一条书童眼里的样子写回便签（标题、文件夹、正文、置顶、废纸篓、原话、改的时间）；镜像跟着走
    private func write(_ s: ShutongNote, to n: Note, folders: [String: Folder]) {
        guard let app else { return }
        let wasTrashed = n.trashed
        if n.markdown != s.markdown {
            n.markdown = s.markdown
            n.unsure = ""
        }
        n.folder = s.folder.flatMap { folders[$0] }
        n.pinned = s.pinned
        var st = n.shutongState
        st.pinnedBy = s.pinnedBy
        n.shutongState = st
        n.spoken = s.spoken
        n.trashed = s.trashed
        n.trashedAt = s.trashedAt
        n.modifiedAt = s.modifiedAt
        if s.trashed && !wasTrashed { app.mirror.trash(n.id) }
        else if !s.trashed && wasTrashed { app.mirror.restoreFromTrash(n.id) }
        else if !s.trashed { app.mirror.saveSoon(n, attachments: app.attachments) }
    }

    private func folderMap() -> [String: Folder] {
        var m: [String: Folder] = [:]
        for f in allFolders() where m[f.name] == nil { m[f.name] = f }
        return m
    }

    // ---------------------------------------------------------------- 做一批、撤一批
    @discardableResult
    private func doBatch(_ acts: [ShutongAct], auto: Bool) -> ShutongBatch? {
        guard let app else { return nil }
        var (notes, folders, _) = world()
        let b = ShutongApply.run(acts, notes: &notes, folders: &folders, now: Date(), id: UUID().uuidString)
        guard !b.counts.isEmpty else { return nil }
        for name in b.made {
            if let f = app.folderNamed(name) { f.auto = true }
        }
        try? app.context.save()
        let fm = folderMap()
        for s in b.after {
            guard let id = UUID(uuidString: s.id), let n = app.note(id) else { continue }
            let textChanged = n.markdown != s.markdown
            write(s, to: n, folders: fm)
            if textChanged { NotificationCenter.default.post(name: .yiyeNoteReplaced, object: id) }
        }
        try? app.context.save()
        batches.append(b)
        var line = ShutongLine(who: "receipt", text: ShutongReceipt.line(b.counts, zh: zh) ?? "")
        line.batch = b.id
        line.auto = auto
        lines.append(line)
        save()
        return b
    }

    /// 回执上「撤销这一批」：每条放回动之前；他后来又改过的那条不动，说一声
    func undo(_ batchID: String) {
        guard let app, let k = batches.firstIndex(where: { $0.id == batchID }), !batches[k].undone else { return }
        let b = batches[k]
        var (notes, folders, _) = world()
        let kept = Set(ShutongApply.undo(b, notes: &notes, folders: &folders))
        let fm = folderMap()
        for old in b.before where !kept.contains(old.id) {
            guard let id = UUID(uuidString: old.id), let n = app.note(id) else { continue }
            let textChanged = n.markdown != old.markdown
            write(old, to: n, folders: fm)
            if textChanged { NotificationCenter.default.post(name: .yiyeNoteReplaced, object: id) }
        }
        // 这一批建的文件夹：放回去以后空了就拿掉
        for f in allFolders() where f.auto && b.made.contains(f.name) && !folders.contains(f.name) && (f.notes ?? []).isEmpty {
            if app.settings.folderID == f.id.uuidString { app.settings.folderID = "" }
            app.context.delete(f)
        }
        try? app.context.save()
        batches[k].undone = true
        if let i = lines.firstIndex(where: { $0.batch == batchID }) { lines[i].undone = true }
        if !kept.isEmpty { lines.append(ShutongLine(who: "note", text: app.lang.f("shutong.keptAfterEdit", kept.count))) }
        save()
    }

    func isUndone(_ batchID: String) -> Bool { batches.first { $0.id == batchID }?.undone ?? true }

    // ---------------------------------------------------------------- 查过再做
    /// 大脑回的一串动作：逐条查；扔、合并的先列出来等他点头；别的直接做。没动的记一笔
    private func act(_ acts: [ShutongAct], mode: String, say: String) {
        let (notes, folders, auto) = world()
        let c = ShutongPlan.check(acts, notes: notes, folders: folders, autoFolders: auto, mode: mode)
        if !say.isEmpty { lines.append(ShutongLine(who: "say", text: say)) }
        if c.needsConfirm {
            var l = ShutongLine(who: "confirm", text: "", acts: c.ok, state: "pending")
            l.mode = mode
            lines.append(l)
        } else if !c.ok.isEmpty {
            doBatch(c.ok, auto: false)
        }
        if c.folderCapHit { lines.append(ShutongLine(who: "note", text: t("shutong.folderCap"))) }
        if !c.skipped.isEmpty {
            let why = Array(Set(c.skipped.map { zh ? $0.why : ShutongModel.english($0.why) })).sorted().prefix(3).joined(separator: zh ? "；" : "; ")
            lines.append(ShutongLine(who: "note", text: app?.lang.f("shutong.skipped", c.skipped.count, why) ?? why))
        }
        save()
    }

    /// 没做的原因（YiyeKit 里是中文）：英文界面换成一句短的
    static func english(_ why: String) -> String {
        let map: [(String, String)] = [("不在白名单", "not allowed"), ("找不到", "note not found"), ("受保护", "protected (you pinned or colored it)"),
                                       ("已经有标题", "already has a title"), ("他放好的不挪", "already in a folder"), ("数字或代码", "numbers didn’t match"),
                                       ("合并后数字", "numbers didn’t match"), ("没有这个文件夹", "no such folder"), ("书童建的文件夹到", "folder limit reached"),
                                       ("文件夹名", "bad folder name"), ("标题不行", "bad title"), ("只收拾语音", "only voice notes get tidied")]
        return map.first { why.hasPrefix($0.0) }?.1 ?? "other"
    }

    /// 确认卡上点「照办」（清理建议是「照扔」）：划掉的不动，其余再查一遍（这期间可能变了）再做
    func confirm(_ lineID: UUID) {
        guard let i = lines.firstIndex(where: { $0.id == lineID }), lines[i].state == "pending" else { return }
        let l = lines[i]
        let picked = (l.acts ?? []).enumerated().filter { !l.struck.contains($0.offset) }.map(\.element)
        lines[i].state = "done"
        let (notes, folders, auto) = world()
        let c = ShutongPlan.check(picked, notes: notes, folders: folders, autoFolders: auto, mode: l.mode == "talk" ? "chat" : l.mode)
        if !c.ok.isEmpty { doBatch(c.ok, auto: false) } else { lines.append(ShutongLine(who: "note", text: t("shutong.nothingLeft"))) }
        save()
    }

    func cancel(_ lineID: UUID) {
        guard let i = lines.firstIndex(where: { $0.id == lineID }), lines[i].state == "pending" else { return }
        lines[i].state = "cancelled"
        save()
    }

    func strike(_ lineID: UUID, _ k: Int) {
        guard let i = lines.firstIndex(where: { $0.id == lineID }), lines[i].state == "pending" else { return }
        if let j = lines[i].struck.firstIndex(of: k) { lines[i].struck.remove(at: j) } else { lines[i].struck.append(k) }
        save()
    }

    /// 确认卡上一条怎么写：「扔：周末采购（3 个月没打开）」
    func describe(_ a: ShutongAct) -> String {
        let name: (String?) -> String = { [weak self] id in
            guard let self, let app = self.app, let s = id, let u = UUID(uuidString: s), let n = app.note(u) else { return "?" }
            return n.title.isEmpty ? self.t("note.untitled") : n.title
        }
        switch a.op {
        case "trash":
            let why = (a.why ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            return name(a.note) + (why.isEmpty ? "" : (zh ? "（\(why)）" : " (\(why))"))
        case "merge": return app?.lang.f("shutong.mergeInto", name(a.note), name(a.into)) ?? ""
        case "title": return app?.lang.f("shutong.renameTo", name(a.note), a.title ?? "") ?? ""
        case "move": return app?.lang.f("shutong.moveTo", name(a.note), (a.folder ?? "").isEmpty ? t("list.all") : (a.folder ?? "")) ?? ""
        case "folder": return app?.lang.f("shutong.makeFolder", a.name ?? "") ?? ""
        case "pin": return name(a.note) + " · " + t((a.on ?? true) ? "note.pin" : "note.unpin")
        case "tidy": return app?.lang.f("shutong.tidyOne", name(a.note)) ?? ""
        default: return a.op
        }
    }

    // ---------------------------------------------------------------- 聊天窗：他说一句
    func send() {
        load()
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        input = ""
        var l = ShutongLine(who: "he", text: text)
        l.state = "waiting"
        lines.append(l)
        save()
        askChat(text: text, line: l.id, round: 1, full: nil)
    }

    private func askChat(text: String, line: UUID, round: Int, full: [String: String]?) {
        guard let app else { return }
        let rid = UUID().uuidString
        let ask = ShutongAsk(mode: "chat", round: round, notes: catalog(), folders: folderInfo(), full: full,
                             history: history().dropLast().map { $0 }, autoFolders: allFolders().filter(\.auto).count)
        let req = ButlerRequest.shutong(id: rid, text: text, ask: ask, at: ISOTime.string(Date()), app: ButlerService.appVersion)
        chatWait[rid] = (line: line, round: round, at: Date())
        if let i = lines.firstIndex(where: { $0.id == line }) { lines[i].rid = rid }
        save()
        if app.demo != nil { fake(req); return }
        Task {
            switch await app.butler.sendShutong(req) {
            case .sent(let pc):
                if !pc { self.lines.append(ShutongLine(who: "note", text: self.t("shutong.queued"))); self.save() }
            case .noPair:
                self.chatFailed(rid, self.t("shutong.noPair"))
            case .failed(let why):
                self.chatFailed(rid, self.app?.lang.f("shutong.sendFailed", why) ?? why)
            }
        }
    }

    private func chatFailed(_ rid: String, _ why: String) {
        guard let w = chatWait.removeValue(forKey: rid) else { return }
        if let i = lines.firstIndex(where: { $0.id == w.line }) { lines[i].state = "failed" }
        lines.append(ShutongLine(who: "note", text: why))
        save()
    }

    /// 没回话的那句再问一次
    func retry(_ lineID: UUID) {
        guard let i = lines.firstIndex(where: { $0.id == lineID }), lines[i].who == "he", lines[i].state == "failed" else { return }
        lines[i].state = "waiting"
        save()
        askChat(text: lines[i].text, line: lineID, round: 1, full: nil)
    }

    // ---------------------------------------------------------------- 回信
    func answer(_ r: ButlerResult) {
        load()
        if r.stage == "shutong-hear" || hearWait.contains(r.id) { heard(r); return }
        if let app, let n = app.allNotes().first(where: { $0.shutongState.rid == r.id }) { tidyReply(r, n); return }
        if r.id == sweepRid { sweepReply(r); return }
        guard let w = chatWait.removeValue(forKey: r.id) ?? lines.first(where: { $0.rid == r.id }).map({ (line: $0.id, round: 1, at: $0.at) }) else { return }
        guard let i = lines.firstIndex(where: { $0.id == w.line }) else { return }
        guard r.ok, let rep = r.shutong else {
            lines[i].state = "failed"
            lines.append(ShutongLine(who: "note", text: (r.error ?? "").isEmpty ? t("shutong.brainFailed") : (r.error ?? "")))
            save()
            return
        }
        if let need = rep.need, !need.isEmpty, w.round < 2 {             // 大脑要看全文：再寄一轮
            askChat(text: lines[i].text, line: lines[i].id, round: 2, full: fullTexts(need))
            return
        }
        lines[i].state = "answered"
        act(rep.acts ?? [], mode: "chat", say: (rep.say ?? r.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines))
    }

    func fullTexts(_ ids: [String]) -> [String: String] {
        guard let app else { return [:] }
        var out: [String: String] = [:]
        for s in ids.prefix(20) {
            guard let u = UUID(uuidString: s), let n = app.note(u) else { continue }
            out[s] = String(n.markdown.prefix(20_000))
        }
        return out
    }

    // ---------------------------------------------------------------- A：新便签一存下就收拾
    /// 新便签记一笔「等着收拾」（开关开着才记；老便签从来不碰）
    func enqueue(_ n: Note) {
        guard let app, app.settings.shutongAuto else { return }
        var st = n.shutongState
        guard st.phase.isEmpty else { return }
        st.phase = "queued"
        n.shutongState = st
    }

    /// 每 5 秒看一眼（ButlerService.look 叫）：该收拾的寄出去；聊天等太久的收掉；周日问一次清理建议
    func tick() {
        guard let app else { return }
        load()
        let now = Date()
        for (rid, w) in chatWait where now.timeIntervalSince(w.at) > 240 {
            chatFailed(rid, t("shutong.noAnswer"))
        }
        if app.settings.shutongAuto {
            var inflight = 0
            var due: [Note] = []
            for n in app.allNotes() where !n.trashed {
                let st = n.shutongState
                if st.phase == "sent" && !st.due(now: now) { inflight += 1; continue }
                guard st.due(now: now) else { continue }
                if let at = nextTry[n.id], at > now { continue }
                if n.markdown.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { continue }
                if n.kind == "photo" && n.butlerState.phase == .waiting { continue }           // 拍照的先等理顺
                if n.kind != "voice", case .editor(let id)? = app.path.last, id == n.id { continue }   // 打字的：离开写字页再收拾
                due.append(n)
            }
            for n in due.prefix(max(0, 3 - inflight)) { sendTidy(n) }
        }
        sweepIfSunday(now)
    }

    private func sendTidy(_ n: Note) {
        guard let app else { return }
        let rid = UUID().uuidString
        var st = n.shutongState
        st.phase = "sent"
        st.rid = rid
        st.sentAt = Date()
        st.sentModified = n.modifiedAt.timeIntervalSince1970
        st.tries += 1
        n.shutongState = st
        try? app.context.save()
        let ask = ShutongAsk(mode: "tidy", target: n.id.uuidString, notes: [card(n)], folders: folderInfo(),
                             full: [n.id.uuidString: String(n.markdown.prefix(20_000))], autoFolders: allFolders().filter(\.auto).count)
        let req = ButlerRequest.shutong(id: rid, text: "", ask: ask, at: ISOTime.string(Date()), app: ButlerService.appVersion)
        if app.demo != nil { fake(req); return }
        let nid = n.id
        Task {
            switch await app.butler.sendShutong(req) {
            case .sent: break                                         // 大管家不在：信在信箱里等它，不打扰他
            case .noPair, .failed:
                guard let n = app.note(nid) else { return }
                var s = n.shutongState
                guard s.rid == rid else { return }
                s.phase = "queued"                                   // 寄不出去：原样留着，排队，通了再收拾
                n.shutongState = s
                try? app.context.save()
                self.nextTry[nid] = Date().addingTimeInterval(120)
            }
        }
    }

    private func tidyReply(_ r: ButlerResult, _ n: Note) {
        guard let app else { return }
        var st = n.shutongState
        guard r.ok, let rep = r.shutong else {                       // 大脑交不出来：原样留着，过 10 分钟再试，不打扰他
            st.phase = st.tries >= ShutongNoteState.maxTries ? "skip" : "queued"
            n.shutongState = st
            try? app.context.save()
            nextTry[n.id] = Date().addingTimeInterval(600)
            return
        }
        var acts = rep.acts ?? []
        if abs(n.modifiedAt.timeIntervalSince1970 - (st.sentModified ?? 0)) > 0.5 {
            acts = acts.filter { $0.op != "tidy" && $0.op != "title" }   // 寄出去以后他改过：正文、标题不动
        }
        st.phase = "done"
        n.shutongState = st
        try? app.context.save()
        let (notes, folders, auto) = world()
        let c = ShutongPlan.check(acts, notes: notes, folders: folders, autoFolders: auto, mode: "tidy", target: n.id.uuidString)
        if !c.ok.isEmpty, let b = doBatch(c.ok, auto: true), let line = ShutongReceipt.line(b.counts, zh: zh) {
            let bid = b.id
            app.show(t("shutong.name") + (zh ? "：" : ": ") + line, action: t("shutong.undo"), seconds: 5) { [weak self] in
                self?.undo(bid)
                self?.app?.toast = nil
            }
        }
        if c.folderCapHit { lines.append(ShutongLine(who: "note", text: t("shutong.folderCap"))); save() }
    }

    // ---------------------------------------------------------------- 清理建议
    static func weekKey(_ d: Date) -> String {
        let c = Calendar(identifier: .iso8601)
        return "\(c.component(.yearForWeekOfYear, from: d))-W\(c.component(.weekOfYear, from: d))"
    }

    private func sweepIfSunday(_ now: Date) {
        guard let app, app.demo == nil, Calendar.current.component(.weekday, from: now) == 1 else { return }
        let wk = ShutongModel.weekKey(now)
        guard app.settings.shutongSweepWeek != wk, sweepRid == nil else { return }
        guard app.allNotes().filter({ !$0.trashed && $0.kind != "listen" }).count >= 5 else { return }
        app.settings.shutongSweepWeek = wk
        askSweep()
    }

    private func askSweep() {
        guard let app else { return }
        let rid = UUID().uuidString
        let ask = ShutongAsk(mode: "sweep", notes: catalog(), folders: folderInfo(), autoFolders: allFolders().filter(\.auto).count)
        let req = ButlerRequest.shutong(id: rid, text: "", ask: ask, at: ISOTime.string(Date()), app: ButlerService.appVersion)
        sweepRid = rid
        save()
        Task {
            switch await app.butler.sendShutong(req) {
            case .sent: break
            case .noPair, .failed:
                self.sweepRid = nil
                self.app?.settings.shutongSweepWeek = ""                  // 没寄出去：下回再问
                self.save()
            }
        }
    }

    private func sweepReply(_ r: ButlerResult) {
        sweepRid = nil
        defer { save() }
        guard r.ok, let rep = r.shutong else { return }
        let (notes, folders, auto) = world()
        let c = ShutongPlan.check((rep.acts ?? []).filter { $0.op == "trash" || $0.op == "merge" }, notes: notes, folders: folders,
                                  autoFolders: auto, mode: "sweep")
        guard !c.ok.isEmpty else { slip = nil; return }
        var l = ShutongLine(who: "confirm", text: (rep.say ?? "").trimmingCharacters(in: .whitespacesAndNewlines), acts: c.ok, state: "pending")
        l.mode = "sweep"
        slip = l
    }

    /// 主页那张纸条点开：进聊天窗，清单在最底下
    func openSlip() {
        guard let s = slip else { return }
        slip = nil
        if !s.text.isEmpty { lines.append(ShutongLine(who: "say", text: s.text)) }
        lines.append(s)
        save()
        open = true
    }

    func dismissSlip() {
        slip = nil
        save()
    }

    // ---------------------------------------------------------------- 按住说话（SenseVoice 在大管家那头认）
    func startRecording() {
        guard let app, !recording, !hearing, !ShutongTalker.shared.on else { return }
        if app.companion.holdsButler { app.show(t("shutong.micBusy")); return }
        AVAudioApplication.requestRecordPermission { ok in
            Task { @MainActor in
                guard ok else { self.app?.show(self.t("shutong.micDenied")); return }
                self.beginRecording()
            }
        }
    }

    private func beginRecording() {
        let s = AVAudioSession.sharedInstance()
        do {
            try s.setCategory(.playAndRecord, mode: .default, options: [.defaultToSpeaker])
            try s.setActive(true)
            let url = FileManager.default.temporaryDirectory.appendingPathComponent("shutong-\(UUID().uuidString).wav")
            let settings: [String: Any] = [AVFormatIDKey: Int(kAudioFormatLinearPCM), AVSampleRateKey: 16_000.0, AVNumberOfChannelsKey: 1,
                                           AVLinearPCMBitDepthKey: 16, AVLinearPCMIsFloatKey: false, AVLinearPCMIsBigEndianKey: false]
            let r = try AVAudioRecorder(url: url, settings: settings)
            guard r.record() else { throw CocoaError(.fileWriteUnknown) }
            recorder = r
            recURL = url
            recStart = Date()
            recording = true
        } catch {
            app?.show(app?.lang.f("shutong.micFailed", error.localizedDescription) ?? "")
        }
    }

    func stopRecording() {
        guard recording, let r = recorder, let url = recURL else { return }
        r.stop()
        recorder = nil
        recording = false
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        defer { try? FileManager.default.removeItem(at: url) }
        guard Date().timeIntervalSince(recStart) >= 0.5, let data = try? Data(contentsOf: url), let app else { return }
        let rid = UUID().uuidString
        let path = "附件/shutong-\(rid.prefix(8)).wav"
        let req = ButlerRequest.shutongHear(id: rid, audio: path, at: ISOTime.string(Date()), app: ButlerService.appVersion)
        hearWait.insert(rid)
        hearing = true
        Task {
            switch await app.butler.sendShutong(req, files: [path: data]) {
            case .sent(let pc):
                if !pc { self.hearWait.remove(rid); self.hearing = false; self.app?.show(self.t("shutong.hearOffline")) }
            case .noPair:
                self.hearWait.remove(rid); self.hearing = false; self.app?.show(self.t("shutong.noPair"))
            case .failed(let why):
                self.hearWait.remove(rid); self.hearing = false; self.app?.show(self.app?.lang.f("shutong.sendFailed", why) ?? why)
            }
        }
        Task {                                                           // 30 秒没认回来：不等了
            try? await Task.sleep(nanoseconds: 30_000_000_000)
            if self.hearWait.remove(rid) != nil { self.hearing = false; self.app?.show(self.t("shutong.hearTimeout")) }
        }
    }

    private func heard(_ r: ButlerResult) {
        hearWait.remove(r.id)
        hearing = false
        let h = (r.heard ?? r.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard r.ok, !h.isEmpty else { app?.show(t("shutong.notHeard")); return }
        input = input.isEmpty ? h : input + " " + h                     // 认出的字先放进输入框：他看一眼、能改，再点发送
    }

    // ---------------------------------------------------------------- 137 开口说（ShutongTalker 叫）
    /// 他说的一句先占一行（字幕）：认出字以前是「…」
    func talkLine(rid: String) -> UUID {
        load()
        let l = ShutongLine(who: "he", text: "…", rid: rid, mode: "talk", state: "waiting")
        lines.append(l)
        save()
        return l.id
    }

    func talkSet(_ lineID: UUID, text: String? = nil, state: String? = nil, rid: String? = nil) {
        guard let i = lines.firstIndex(where: { $0.id == lineID }) else { return }
        if let text { lines[i].text = text }
        if let state { lines[i].state = state }
        if let rid { lines[i].rid = rid }
        save()
    }

    /// 不是他的声音：那一行拿掉
    func talkDrop(_ lineID: UUID) {
        lines.removeAll { $0.id == lineID }
        save()
    }

    func talkNote(_ text: String) {
        lines.append(ShutongLine(who: "note", text: text))
        save()
    }

    /// 问大管家带的：目录、文件夹、聊天前几句、是不是在等他点头；第二轮带全文
    func talkAsk(confirming: Bool, full: [String: String]? = nil) -> ShutongAsk {
        load()
        return ShutongAsk(mode: "talk", round: full == nil ? 1 : 2, notes: catalog(), folders: folderInfo(), full: full,
                          history: history().dropLast().map { $0 }, autoFolders: allFolders().filter(\.auto).count, confirming: confirming)
    }

    enum TalkActed { case done(ShutongCounts, skipped: Int), confirm, nothing(skipped: Int) }

    /// 大脑回的动作：跟聊天窗一样逐条查；扔、合并的列成清单等他点头（这回是嘴上点头）；别的直接做
    func talkAct(_ acts: [ShutongAct], say: String) -> TalkActed {
        let (notes, folders, auto) = world()
        let c = ShutongPlan.check(acts, notes: notes, folders: folders, autoFolders: auto, mode: "chat")
        if !say.isEmpty { lines.append(ShutongLine(who: "say", text: say)) }
        var out = TalkActed.nothing(skipped: c.skipped.count)
        if c.needsConfirm {
            var l = ShutongLine(who: "confirm", text: "", acts: c.ok, state: "pending")
            l.mode = "talk"
            lines.append(l)
            out = .confirm
        } else if !c.ok.isEmpty, let b = doBatch(c.ok, auto: false) {
            out = .done(b.counts, skipped: c.skipped.count)
        }
        if c.folderCapHit { lines.append(ShutongLine(who: "note", text: t("shutong.folderCap"))) }
        if !c.skipped.isEmpty {
            let why = Array(Set(c.skipped.map { zh ? $0.why : ShutongModel.english($0.why) })).sorted().prefix(3).joined(separator: zh ? "；" : "; ")
            lines.append(ShutongLine(who: "note", text: app?.lang.f("shutong.skipped", c.skipped.count, why) ?? why))
        }
        save()
        return out
    }

    /// 在等他嘴上点头的那张清单
    var talkPending: UUID? { lines.last(where: { $0.who == "confirm" && $0.mode == "talk" && $0.state == "pending" })?.id }

    /// 「对」：照办（划掉的不动）；「不对」、不吭声、他说了别的：不办。返回有没有在等的
    @discardableResult
    func talkNod(_ yes: Bool) -> Bool {
        guard let id = talkPending else { return false }
        if yes { confirm(id) } else { cancel(id) }
        return true
    }

    /// 「撤销」：撤最近那一批还没撤的。返回撤没撤
    func talkUndo() -> Bool {
        guard let b = batches.last(where: { !$0.undone }) else { return false }
        undo(b.id)
        return true
    }

    /// 干一遍不落地（假大管家算回执、算要念的清单用）
    func talkDryRun(_ acts: [ShutongAct]) -> (checked: ShutongChecked, counts: ShutongCounts) {
        var (notes, folders, auto) = world()
        let c = ShutongPlan.check(acts, notes: notes, folders: folders, autoFolders: auto, mode: "chat")
        let b = ShutongApply.run(c.ok, notes: &notes, folders: &folders, now: Date(), id: "dry")
        return (c, b.counts)
    }

    /// 假大管家（Demo）听到这一句回什么：跟聊天窗的假大脑一个路数
    func talkFakeActs(_ said: String) -> (say: String, acts: [ShutongAct]) {
        let z = zh
        let text = said.lowercased()
        let notes = catalog()
        func find(_ words: [String]) -> String? { notes.first { n in words.contains { n.title.lowercased().contains($0) } }?.id }
        if text.contains("扔") || text.contains("清") || text.contains("old") || text.contains("clean") || text.contains("trash") {
            var acts: [ShutongAct] = []
            for (w, why) in [(["旧", "old"], z ? "半年没打开" : "untouched for months"), (["读书", "reading"], z ? "很短，也没再动过" : "short and never touched again")] {
                if let id = find(w) { acts.append(ShutongAct(op: "trash", note: id, why: why)) }
            }
            return (z ? "这两条看着可以扔了。" : "These two look done.", acts)
        }
        if text.contains("机床") || text.contains("machine") {
            let folder = z ? "机床" : "Machines"
            var acts = [ShutongAct(op: "folder", name: folder)]
            if let id = find(["交接", "handover"]) { acts.append(ShutongAct(op: "move", note: id, folder: folder)) }
            if let id = find(["周会", "weekly"]) { acts.append(ShutongAct(op: "move", note: id, folder: folder)) }
            return (z ? "机床相关的放进『机床』了。" : "Put the machine stuff in “Machines”.", acts)
        }
        return (z ? "你说的是哪几条？" : "Which ones do you mean?", [])
    }

    func noteTitle(_ id: String?) -> String {
        guard let s = id, let u = UUID(uuidString: s), let n = app?.note(u) else { return "?" }
        return n.title.isEmpty ? t("note.untitled") : n.title
    }

    // ---------------------------------------------------------------- 截图、UI 测试用的假大脑（Demo）
    private func fake(_ req: ButlerRequest) {
        guard let ask = req.shutong else { return }
        let z = zh
        var acts: [ShutongAct] = []
        var say = ""
        if ask.mode == "tidy", let target = ask.target {
            acts = [ShutongAct(op: "tidy", note: target, text: z ? "B 线冷却液快没了，晚班记得加。\n3 号机下午换刀，换完记一下 VMC-850 的件数。"
                                                                 : "Line B is low on coolant. Night shift, top it up.\nNew blade on #3 this afternoon. Log the VMC-850 count after."),
                    ShutongAct(op: "title", note: target, title: z ? "B 线冷却液和换刀" : "Coolant and the new blade"),
                    ShutongAct(op: "move", note: target, folder: z ? "工作" : "Work")]
        } else {
            let text = req.text.lowercased()
            let notes = ask.notes
            func find(_ words: [String]) -> String? { notes.first { n in words.contains { n.title.lowercased().contains($0) } }?.id }
            if text.contains("清") || text.contains("clean") {
                say = z ? "这两条看着可以扔了，你过目。" : "These two look done. Have a look."
                for (w, why) in [(["旧", "old"], z ? "半年没打开" : "untouched for months"), (["读书", "reading"], z ? "很短，也没再动过" : "short and never touched again")] {
                    if let id = find(w) { acts.append(ShutongAct(op: "trash", note: id, why: why)) }
                }
            } else {
                say = z ? "机床相关的放进『机床』了。" : "Put the machine stuff in “Machines”."
                let folder = z ? "机床" : "Machines"
                acts.append(ShutongAct(op: "folder", name: folder))
                if let id = find(["交接", "handover"]) { acts.append(ShutongAct(op: "move", note: id, folder: folder)) }
                if let id = find(["周会", "weekly"]) { acts.append(ShutongAct(op: "move", note: id, folder: folder)) }
                if let id = find(["明天早上", "team lunch"]) { acts.append(ShutongAct(op: "title", note: id, title: z ? "周会和机床" : "Lunch with the team")) }
                if let id = find(["采购", "groceries"]) { acts.append(ShutongAct(op: "move", note: id, folder: folder)) }   // 置顶又换过纸色的：受保护，不动
            }
        }
        let r = ButlerResult(id: req.id, note: "", ok: true, text: say, changes: nil, error: nil, host: "电脑", stage: "shutong",
                             shutong: ShutongReply(say: say, acts: acts, need: nil))
        Task {
            try? await Task.sleep(nanoseconds: 600_000_000)
            self.answer(r)
        }
    }

    /// 截图用：聊天窗里已经有一问一答一张回执 / 一张等他点头的清单；主页纸条
    func demo(_ screen: String) {
        guard let app else { return }
        loaded = true
        switch screen {
        case "shutong":
            input = app.lang.isZh ? "把机床相关的都放一起" : "Put the machine stuff together"
            send()
            open = true
        case "shutong-confirm":
            input = app.lang.isZh ? "清一清" : "Clean up a bit"
            send()
            open = true
        case "shutong-slip":
            let z = app.lang.isZh
            let picks = app.allNotes().filter { !$0.trashed && ($0.title.contains(z ? "读书" : "Reading") || $0.title.contains(z ? "明天" : "Team")) }
            var l = ShutongLine(who: "confirm", text: z ? "这两条好久没动了。" : "These two haven’t moved in ages.",
                                acts: picks.map { ShutongAct(op: "trash", note: $0.id.uuidString, why: z ? "很久没打开" : "not opened in ages") }, state: "pending")
            l.mode = "sweep"
            slip = l
        default:
            break
        }
    }
}
