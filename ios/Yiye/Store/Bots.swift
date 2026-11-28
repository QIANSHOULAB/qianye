import Foundation
import Observation
import UIKit
import YiyeKit

/// 机器人那张半屏里能进的几页
enum BotRoute: Hashable {
    case chat(String)
    case profile(String)
    case newBot
    case newGroup
}

/// 聊天窗里的一行；card = 群里小书童那一批的回执、要点头的清单（跟小书童窗里一个样子）
struct BotRow: Codable, Identifiable, Equatable {
    var line: BotLine
    var card: ShutongLine?
    var id: UUID { line.id }
}

/// 资料页：人设和它记得的（大管家那边为准，打开时拉）
struct BotProfile: Equatable {
    var persona: String
    var memory: [BotMemo]
}

private struct BotsStore: Codable {
    var bots: [BotCard] = []
    var groups: [BotGroup] = []
    var chats: [String: [BotRow]] = [:]
}

/// 250 机器人：建很多个小书童那样的机器人（各有名字、人设、记忆），单聊、拉群。大脑、人设、记忆都在大管家那头（pc-butler 249），
/// 手机只存聊天记录（bots.json，每个窗最近 200 条）和上一次拉到的名单。接口 v3.26 / v3.27。
@MainActor @Observable
final class BotsModel {
    static let shared = BotsModel()
    static let scribeName = "小书童"

    @ObservationIgnored weak var app: AppModel?
    /// 名单那张半屏开着
    var open = false
    var path: [BotRoute] = []
    var bots: [BotCard] = []
    var groups: [BotGroup] = []
    var chats: [String: [BotRow]] = [:]
    var inputs: [String: String] = [:]
    var profiles: [String: BotProfile] = [:]
    /// 正在办的："list"、"new"、机器人 / 群的 id
    var busy: Set<String> = []
    /// 名单没拉到时的一句
    var listError: String?

    private struct Wait {
        /// list / new / edit / delete / memory / forget / chat / say
        var action: String
        /// 哪个窗（机器人 / 群 id；list、new 是 "list" / "new"）
        var window: String
        /// 说话的那一行
        var line: UUID?
        var round = 1
        var at = Date()
    }

    @ObservationIgnored private var waits: [String: Wait] = [:]
    @ObservationIgnored private var loaded = false
    /// 截图、UI 测试用的假大管家记着的记忆
    @ObservationIgnored private var demoMemory: [String: [BotMemo]] = [:]

    private var zh: Bool { app?.lang.isZh ?? true }
    private func t(_ k: String) -> String { app?.lang.t(k) ?? k }
    private func f(_ k: String, _ a: String) -> String { app?.lang.f(k, a) ?? a }

    // ---------------------------------------------------------------- 存
    private var file: URL? {
        guard app?.demo == nil, let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else { return nil }
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("bots.json")
    }

    func load() {
        guard !loaded else { return }
        loaded = true
        guard let file, let d = try? Data(contentsOf: file), let s = try? JSONDecoder().decode(BotsStore.self, from: d) else { return }
        bots = s.bots
        groups = s.groups
        chats = s.chats
        // app 被杀过：还在等的那几句，回信来了照样认（按请求 id），超时的 tick 里收
        for (w, rows) in chats {
            for r in rows where r.line.who == "he" && r.line.state == "waiting" {
                if let rid = r.line.rid { waits[rid] = Wait(action: BotID.isGroup(w) ? "say" : "chat", window: w, line: r.id, at: r.line.at) }
            }
        }
    }

    private func save() {
        for (k, v) in chats where v.count > BotLog.maxLines { chats[k] = Array(v.suffix(BotLog.maxLines)) }
        guard let file else { return }
        if let d = try? JSONEncoder().encode(BotsStore(bots: bots, groups: groups, chats: chats)) { try? d.write(to: file, options: .atomic) }
    }

    /// 设置里「清空机器人聊天记录」
    func clearChats() {
        load()
        chats = [:]
        waits = waits.filter { $0.value.action != "chat" && $0.value.action != "say" }
        save()
    }

    var waitingIDs: Set<String> { Set(waits.keys) }

    // ---------------------------------------------------------------- 名单
    /// 除了小书童
    var others: [BotCard] { bots.filter { $0.id != BotID.shutong } }

    /// 只有小书童一个：主页那个按钮点开直接进它，跟以前一样
    var onlyScribe: Bool { others.isEmpty && groups.isEmpty }

    func card(_ id: String) -> BotCard? {
        if let b = bots.first(where: { $0.id == id }) { return b }
        return id == BotID.shutong ? BotCard(id: BotID.shutong, name: BotsModel.scribeName, desc: "", builtin: true) : nil
    }

    func group(_ id: String) -> BotGroup? { groups.first { $0.id == id } }

    /// 显示的名字：小书童跟界面语言走
    func name(_ id: String) -> String {
        if id == BotID.shutong { return t("shutong.name") }
        return card(id)?.name ?? group(id)?.name ?? t("bots.gone")
    }

    /// 小书童那一行的说明跟界面语言走
    func desc(_ b: BotCard) -> String { b.id == BotID.shutong ? t("bots.scribeDesc") : b.desc }

    /// 名单里的机器人，小书童排第一
    var roster: [BotCard] { [card(BotID.shutong)].compactMap { $0 } + others }

    // ---------------------------------------------------------------- 入口
    /// 主页顶栏那个按钮
    func openFromBar() {
        load()
        if onlyScribe { ShutongModel.shared.open = true } else { showList() }
    }

    /// 打开名单（顺手跟大管家拉一次）
    func showList() {
        load()
        path = []
        open = true
        refresh()
    }

    /// 从小书童窗里去名单：一次只开得出一张，先收那张
    func listFromScribe() {
        ShutongModel.shared.open = false
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 600_000_000)
            self.showList()
        }
    }

    /// 从小书童窗顶上点名字：它的资料页
    func scribeProfile() {
        ShutongModel.shared.open = false
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 600_000_000)
            self.load()
            self.path = [.profile(BotID.shutong)]
            self.open = true
            self.askProfile(BotID.shutong)
        }
    }

    /// 名单里点了一个：小书童开它自己的窗，别的在这张里往里走
    func openWindow(_ id: String) {
        load()
        if id == BotID.shutong {
            open = false
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 600_000_000)
                ShutongModel.shared.open = true
            }
        } else {
            path.append(.chat(id))
        }
    }

    /// 从提醒点进来
    func openFromLink(_ id: String) {
        load()
        path = [.chat(id)]
        open = true
        refresh(quiet: true)
    }

    func openProfile(_ id: String) {
        path.append(.profile(id))
        askProfile(id)
    }

    func askProfile(_ id: String) {
        if BotID.isGroup(id) { refresh(quiet: true) } else { send(BotAsk("memory", id: id), window: id) }
    }

    func refresh(quiet: Bool = false) {
        listError = nil
        guard !waits.values.contains(where: { $0.action == "list" }) else { return }
        send(BotAsk("list"), window: quiet ? "quiet" : "list")
    }

    // ---------------------------------------------------------------- 建、改、删
    func create(name: String, desc: String, persona: String) {
        send(BotAsk("new", name: name, desc: desc, persona: persona), window: "new")
    }

    func edit(_ id: String, name: String, desc: String, persona: String) {
        send(BotAsk("edit", id: id, name: name, desc: desc, persona: persona), window: id)
    }

    func delete(_ id: String) {
        send(BotAsk("delete", id: id), window: id)
    }

    func forget(_ id: String, _ memo: BotMemo) {
        // 先从屏上拿掉，大管家回来的名单说了算
        if var p = profiles[id] { p.memory.removeAll { $0 == memo }; profiles[id] = p }
        send(BotAsk("forget", id: id, text: memo.text), window: id)
    }

    func createGroup(name: String, members: [String], chief: String) {
        send(BotAsk("new", name: name, members: members, chief: chief), window: "new", group: true)
    }

    func editGroup(_ id: String, name: String, members: [String], chief: String) {
        send(BotAsk("edit", id: id, name: name, members: members, chief: chief), window: id, group: true)
    }

    func deleteGroup(_ id: String) {
        send(BotAsk("delete", id: id), window: id, group: true)
    }

    private func send(_ ask: BotAsk, window: String, group: Bool = false) {
        guard let app else { return }
        let rid = UUID().uuidString
        let at = ISOTime.string(Date())
        let req = group ? ButlerRequest.group(id: rid, ask: ask, at: at, app: ButlerService.appVersion)
                        : ButlerRequest.bot(id: rid, ask: ask, at: at, app: ButlerService.appVersion)
        waits[rid] = Wait(action: ask.action, window: window)
        if window != "quiet" { busy.insert(window) }
        if app.demo != nil { fake(req); return }
        Task {
            switch await app.butler.sendBots(req) {
            case .sent(let pc):
                if !pc && window != "quiet" { app.show(self.t("shutong.queued")) }
            case .noPair:
                self.opFailed(rid, self.t("shutong.noPair"))
            case .failed(let why):
                self.opFailed(rid, self.f("shutong.sendFailed", why))
            }
        }
    }

    private func opFailed(_ rid: String, _ why: String) {
        guard let w = waits.removeValue(forKey: rid) else { return }
        busy.remove(w.window)
        if w.action == "list" {
            if w.window == "list" { listError = why }
        } else {
            app?.show(why)
        }
    }

    // ---------------------------------------------------------------- 说话
    /// 这个窗里有没有在等回话的
    func thinking(_ window: String) -> Bool {
        chats[window]?.contains { $0.line.who == "he" && $0.line.state == "waiting" } ?? false
    }

    func say(_ window: String) {
        load()
        let text = (inputs[window] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        inputs[window] = ""
        let line = BotLine(who: "he", text: String(text.prefix(2000)), state: "waiting")
        chats[window, default: []].append(BotRow(line: line))
        save()
        ask(window, line: line.id, round: 1, to: nil, full: nil)
    }

    func retry(_ window: String, _ line: UUID) {
        guard let i = chats[window]?.firstIndex(where: { $0.id == line }), chats[window]?[i].line.state == "failed" else { return }
        chats[window]?[i].line.state = "waiting"
        save()
        ask(window, line: line, round: 1, to: nil, full: nil)
    }

    private func ask(_ window: String, line: UUID, round: Int, to: String?, full: [String: String]?) {
        guard let app, let rows = chats[window], let i = rows.firstIndex(where: { $0.id == line }) else { return }
        let text = rows[i].line.text
        let group = BotID.isGroup(window)
        let history = BotLog.history(rows.filter { $0.card == nil }.map(\.line), before: line, group: group)
        let rid = UUID().uuidString
        let at = ISOTime.string(Date())
        let req: ButlerRequest
        if group {
            // 群里有小书童、或者这句叫了它：带上便签目录，它才能收拾
            let scribe = self.group(window)?.members.contains(BotID.shutong) == true || BotMention.atScribe(text) || to == BotID.shutong
            let block = scribe ? ShutongModel.shared.groupAsk(round: round, full: full) : nil
            req = ButlerRequest.group(id: rid, ask: BotAsk("say", id: window, text: text, history: history, to: to), shutong: block,
                                      at: at, app: ButlerService.appVersion)
        } else {
            req = ButlerRequest.bot(id: rid, ask: BotAsk("chat", id: window, text: text, history: history), at: at, app: ButlerService.appVersion)
        }
        if round == 1 { chats[window]?[i].line.rid = rid }
        waits[rid] = Wait(action: group ? "say" : "chat", window: window, line: line, round: round)
        save()
        if app.demo != nil { fake(req); return }
        Task {
            switch await app.butler.sendBots(req) {
            case .sent(let pc):
                if !pc { self.note(window, self.t("shutong.queued"), after: line) }
            case .noPair:
                self.sayFailed(rid, self.t("shutong.noPair"))
            case .failed(let why):
                self.sayFailed(rid, self.f("shutong.sendFailed", why))
            }
        }
    }

    private func note(_ window: String, _ text: String, after: UUID? = nil) {
        chats[window, default: []].append(BotRow(line: BotLine(who: "", text: text)))
        save()
    }

    private func setState(_ window: String, _ line: UUID?, _ state: String) {
        guard let line, let i = chats[window]?.firstIndex(where: { $0.id == line }) else { return }
        chats[window]?[i].line.state = state
    }

    private func sayFailed(_ rid: String, _ why: String) {
        guard let w = waits.removeValue(forKey: rid) else { return }
        setState(w.window, w.line, "failed")
        note(w.window, why)
    }

    /// 这一句还有没有别的请求在等（群里小书童要全文的第二轮）
    private func stillWaiting(_ line: UUID?) -> Bool {
        guard let line else { return false }
        return waits.values.contains { $0.line == line }
    }

    // ---------------------------------------------------------------- 回信
    func answer(_ r: ButlerResult) {
        load()
        if let g = r.group, g.action == "say" { groupAnswer(r, g); return }
        guard let w = waits[r.id] else {
            // 等超时了才到的单聊回话：照样放进去
            if let b = r.bot, b.action == "chat", let id = b.id, let row = chats[id]?.first(where: { $0.line.who == "he" && $0.line.rid == r.id }) {
                chatAnswer(r, Wait(action: "chat", window: id, line: row.id))
            }
            return
        }
        if w.action == "say" {                                   // 老大管家不认识这个 ask：回的信没有 group
            sayFailed(r.id, failure(r))
            return
        }
        waits.removeValue(forKey: r.id)
        if w.action == "chat" {
            chatAnswer(r, w)
            return
        }
        busy.remove(w.window)
        guard r.ok else {
            if w.action == "list" {
                if w.window == "list" { listError = failure(r) }
            } else {
                app?.show(failure(r))
                if w.action == "forget" { askProfile(w.window) }
            }
            return
        }
        let bots = r.bot?.bots ?? r.group?.bots
        let groups = r.bot?.groups ?? r.group?.groups
        if let bots { self.bots = bots }
        if let groups { self.groups = groups }
        if let id = r.bot?.id, let b = r.bot?.bot {
            profiles[id] = BotProfile(persona: b.persona ?? "", memory: r.bot?.memory ?? [])
        }
        switch w.action {
        case "new":
            if let id = r.bot?.id ?? r.group?.id, path.last == .newBot || path.last == .newGroup { path = [.chat(id)] }
        case "delete":
            let id = r.bot?.id ?? r.group?.id ?? w.window
            chats[id] = nil
            profiles[id] = nil
            path = []
        case "edit":
            app?.show(t("bots.saved"))
        default:
            break
        }
        save()
    }

    private func failure(_ r: ButlerResult) -> String {
        let e = (r.error ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        return e.isEmpty ? t("shutong.brainFailed") : e
    }

    private func chatAnswer(_ r: ButlerResult, _ w: Wait) {
        let say = (r.bot?.say ?? r.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard r.ok, !say.isEmpty else {
            setState(w.window, w.line, "failed")
            note(w.window, failure(r))
            return
        }
        setState(w.window, w.line, "answered")
        var rows = chats[w.window] ?? []
        let at = w.line.flatMap { l in rows.firstIndex { $0.id == l } }.map { $0 + 1 } ?? rows.count
        let quota = r.bot?.quota == true
        rows.insert(BotRow(line: BotLine(who: quota ? "" : w.window, text: say, rid: r.id)), at: min(at, rows.count))
        chats[w.window] = rows
        save()
        if !quota { heardOutside(w.window, name: name(w.window), say: say, r) }
    }

    private func groupAnswer(_ r: ButlerResult, _ g: GroupReply) {
        // 窗是哪个：在等的请求认得；不认得（app 被杀过、晚到的信）看这封说是哪个群
        let w = waits[r.id]
        guard let window = w?.window ?? g.id, group(window) != nil || chats[window] != nil else { return }
        let seq = g.seq ?? 1
        var rows = chats[window] ?? []
        let says = (g.messages ?? []).filter { !$0.text.isEmpty || !($0.acts ?? []).isEmpty || !($0.need ?? []).isEmpty }
        var need: [String] = []
        if !says.isEmpty, let at = BotLog.slot(rid: r.id, seq: seq, in: rows.map(\.line)) {
            var add: [BotRow] = []
            for m in says {
                if !m.text.isEmpty { add.append(BotRow(line: BotLine(who: m.bot, text: m.text, rid: r.id, seq: seq))) }
                guard m.bot == BotID.shutong else { continue }
                if let n = m.need, !n.isEmpty, (w?.round ?? 2) < 2 { need = n }
                for card in ShutongModel.shared.groupActs(m.acts ?? []) {
                    add.append(BotRow(line: BotLine(who: BotID.shutong, text: "", rid: r.id, seq: seq), card: card))
                }
            }
            rows.insert(contentsOf: add, at: min(at, rows.count))
            chats[window] = rows
            if let m = says.first(where: { !$0.bot.isEmpty }) { heardOutside(window, name: name(m.bot), say: m.text, r) }
        }
        if let w, !need.isEmpty {                                  // 小书童要看全文：再寄一轮，只让它回
            ask(window, line: w.line ?? UUID(), round: 2, to: BotID.shutong, full: ShutongModel.shared.fullTexts(need))
        }
        if !r.ok {
            waits.removeValue(forKey: r.id)
            setState(window, w?.line, "failed")
            note(window, failure(r))
            return
        }
        if g.done == true {
            waits.removeValue(forKey: r.id)
            if !stillWaiting(w?.line) { setState(window, w?.line, "answered") }
        } else {
            waits[r.id]?.at = Date()                               // 还有下一封：等着
        }
        save()
    }

    /// 切到后台时来的话、大管家又没发 Bark：手机自己弹一条
    private func heardOutside(_ window: String, name: String, say: String, _ r: ButlerResult) {
        guard let app, app.demo == nil, UIApplication.shared.applicationState != .active, r.bark != true else { return }
        ButlerNotice.post(title: name, body: say, id: r.id)
    }

    // ---------------------------------------------------------------- 群里小书童的卡
    private func changeCard(_ window: String, _ row: UUID, _ change: (inout ShutongLine) -> Void) {
        guard let i = chats[window]?.firstIndex(where: { $0.id == row }), var c = chats[window]?[i].card else { return }
        change(&c)
        chats[window]?[i].card = c
        save()
    }

    func strike(_ window: String, _ row: UUID, _ k: Int) {
        changeCard(window, row) { c in
            guard c.state == "pending" else { return }
            if let j = c.struck.firstIndex(of: k) { c.struck.remove(at: j) } else { c.struck.append(k) }
        }
    }

    func cancel(_ window: String, _ row: UUID) {
        changeCard(window, row) { c in if c.state == "pending" { c.state = "cancelled" } }
    }

    func confirm(_ window: String, _ row: UUID) {
        guard let i = chats[window]?.firstIndex(where: { $0.id == row }), let c = chats[window]?[i].card, c.state == "pending" else { return }
        let done = ShutongModel.shared.groupRun(c)
        chats[window]?[i].card?.state = "done"
        let rows = done.map { BotRow(line: BotLine(who: BotID.shutong, text: ""), card: $0) }
        chats[window]?.insert(contentsOf: rows, at: i + 1)
        save()
    }

    // ---------------------------------------------------------------- 超时（ButlerService.look 每 5 秒叫）
    func tick() {
        guard loaded, !waits.isEmpty else { return }
        let now = Date()
        for (rid, w) in waits {
            let talking = w.action == "chat" || w.action == "say"
            if now.timeIntervalSince(w.at) <= (talking ? 300 : 90) { continue }
            if talking { sayFailed(rid, t("bots.noAnswer")) } else { opFailed(rid, t("bots.noAnswer")) }
        }
    }

    // ---------------------------------------------------------------- 截图、UI 测试用的假大管家（Demo）
    /// 一个机器人、一个群，里面有几句
    func demoSeed() {
        guard app?.demo != nil else { return }
        loaded = true
        let z = zh
        let cook = BotCard(id: "bdemo0001", name: z ? "老厨子" : "Chef", desc: z ? "管做饭，问吃什么找他" : "Food: what to eat and how", gear: "Sonnet 中")
        let money = BotCard(id: "bdemo0002", name: z ? "账房" : "Ledger", desc: z ? "记账、算钱" : "Sums and budgets", gear: "Sonnet 中")
        bots = [BotCard(id: BotID.shutong, name: BotsModel.scribeName, desc: "", builtin: true), cook, money]
        groups = [BotGroup(id: "gdemo0001", name: z ? "晚饭群" : "Dinner club", members: [cook.id, money.id])]
        demoMemory[cook.id] = [BotMemo(date: "2026-11-28", text: z ? "他不吃香菜" : "No cilantro for him")]
        chats = ["gdemo0001": [BotRow(line: BotLine(who: "he", text: z ? "周末吃什么" : "Weekend dinner?", state: "answered")),
                               BotRow(line: BotLine(who: cook.id, text: z ? "包饺子。" : "Dumplings."))]]
    }

    private func fakeReply(_ rid: String, stage: String, ok: Bool = true, bot: BotReply? = nil, group: GroupReply? = nil, error: String? = nil) {
        var r = ButlerResult(id: rid, note: "", ok: ok, text: bot?.say, changes: nil, error: error, host: "电脑", stage: stage)
        r.bot = bot
        r.group = group
        answer(r)
    }

    private func fake(_ req: ButlerRequest) {
        let z = zh
        if bots.isEmpty { bots = [BotCard(id: BotID.shutong, name: BotsModel.scribeName, desc: "", builtin: true)] }
        Task {
            try? await Task.sleep(nanoseconds: 500_000_000)
            if let a = req.group {
                self.fakeGroup(req.id, a, z)
            } else if let a = req.bot {
                self.fakeBot(req.id, a, z)
            }
        }
    }

    private func fakeBot(_ rid: String, _ a: BotAsk, _ z: Bool) {
        let id = a.id ?? ""
        switch a.action {
        case "list":
            fakeReply(rid, stage: "bot", bot: BotReply("list", bots: bots, groups: groups))
        case "new":
            let nid = "bdemo\(1000 + bots.count)"
            let b = BotCard(id: nid, name: a.name ?? "", desc: a.desc ?? "", gear: "Sonnet 中", persona: a.persona ?? "")
            demoMemory[nid] = [BotMemo(date: "2026-11-28", text: z ? "他爱喝茶" : "He likes tea"),
                               BotMemo(date: "2026-11-28", text: z ? "周日他值班" : "On shift Sunday")]
            fakeReply(rid, stage: "bot", bot: BotReply("new", id: nid, bot: b, memory: demoMemory[nid], bots: bots + [b], groups: groups))
        case "edit", "forget", "memory":
            guard var b = card(id) else { fakeReply(rid, stage: "bot", ok: false, error: "?"); return }
            if a.action == "edit" { b.name = a.name ?? b.name; b.desc = a.desc ?? b.desc; b.persona = a.persona }
            if a.action == "forget" { demoMemory[id]?.removeAll { $0.text == a.text } }
            b.persona = b.persona ?? profiles[id]?.persona ?? (z ? "嘴碎，热心。" : "Chatty and kind.")
            let list = bots.map { $0.id == id ? b : $0 }
            fakeReply(rid, stage: "bot", bot: BotReply(a.action, id: id, bot: b, memory: demoMemory[id] ?? [], bots: list, groups: groups))
        case "delete":
            fakeReply(rid, stage: "bot", bot: BotReply("delete", id: id, bots: bots.filter { $0.id != id }, groups: groups))
        case "chat":
            let say = (z ? "好嘞：" : "Aye: ") + (a.text ?? "")
            fakeReply(rid, stage: "bot", bot: BotReply("chat", id: id, say: say))
        default:
            break
        }
    }

    /// 群里说一句：两个机器人回，分两封，故意倒着到（第 2 封先到、带 done），屏上该按 1、2 摆
    private func fakeGroup(_ rid: String, _ a: BotAsk, _ z: Bool) {
        let id = a.id ?? ""
        switch a.action {
        case "say":
            let members = group(id)?.members ?? []
            let first = members.first ?? BotID.shutong
            let second = members.dropFirst().first ?? first
            fakeReply(rid, stage: "group", group: GroupReply("say", id: id, seq: 2, done: true,
                      messages: [GroupSay(bot: second, text: z ? "第二句：我来算钱" : "Second: I’ll do the sums")]))
            Task {
                try? await Task.sleep(nanoseconds: 600_000_000)
                self.fakeReply(rid, stage: "group", group: GroupReply("say", id: id, seq: 1, done: false,
                               messages: [GroupSay(bot: first, text: z ? "第一句：包饺子" : "First: dumplings")]))
            }
        case "new":
            let nid = "gdemo\(1000 + groups.count)"
            let g = BotGroup(id: nid, name: a.name ?? "", members: a.members ?? [], chief: a.chief ?? BotID.shutong)
            fakeReply(rid, stage: "group", group: GroupReply("new", id: nid, bots: bots, groups: groups + [g]))
        case "edit":
            let list = groups.map { g -> BotGroup in
                var n = g
                if g.id == id { n.name = a.name ?? g.name; n.members = a.members ?? g.members; n.chief = a.chief ?? g.chief }
                return n
            }
            fakeReply(rid, stage: "group", group: GroupReply("edit", id: id, bots: bots, groups: list))
        case "delete":
            fakeReply(rid, stage: "group", group: GroupReply("delete", id: id, bots: bots, groups: groups.filter { $0.id != id }))
        default:
            fakeReply(rid, stage: "group", group: GroupReply("list", bots: bots, groups: groups))
        }
    }
}
