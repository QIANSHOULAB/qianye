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

/// 252：提醒点进来要看的那一句（信还在路上就等它到，一分钟）
struct BotFocus: Equatable {
    var window: String
    var msg: String
    var at = Date()
    var fresh: Bool { Date().timeIntervalSince(at) < 60 }
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
    /// 252：机器人的定时活（资料页打开时拉），拉不到时的一句
    var jobs: [String: [BotJob]] = [:]
    var jobsError: [String: String] = [:]
    var focus: BotFocus?
    /// 256：新建页填到一半的字放这儿：右滑返回、整张拉下去都不丢，建好了或点了「不建了」才清
    var newBot = BotDraft()
    var newGroup = BotGroupDraft()
    /// 256：新建页顶上那一句错（大管家回的 error、寄不出去、没等到）
    var newError: [BotRoute: String] = [:]

    /// 256：寄出去的那封新建是照哪份填的字
    fileprivate enum Made {
        case bot(BotDraft)
        case group(BotGroupDraft)
        var page: BotRoute {
            switch self {
            case .bot: return .newBot
            case .group: return .newGroup
            }
        }
    }

    private struct Wait {
        /// list / new / edit / delete / memory / forget / chat / say
        var action: String
        /// 哪个窗（机器人 / 群 id；list、new 是 "list" / "new"）
        var window: String
        /// 说话的那一行
        var line: UUID?
        var round = 1
        var at = Date()
        /// 252 react：哪一句、寄的什么、原来是什么（没办成就放回去）
        var msg: String?
        var react: String?
        var old: String?
        /// 256 new：照哪份填的字寄的；信是不是在信箱里排着；等超时了（不转圈了，回信晚到照样认）
        var made: Made?
        var queued = false
        var late = false
        /// 252：👍👎、开关定时活：信放进信箱迟早办，不催、不超时撤回
        var quiet: Bool { action == "react" || action.hasPrefix("job-") }
    }

    @ObservationIgnored private var waits: [String: Wait] = [:]
    @ObservationIgnored private var loaded = false
    /// 截图、UI 测试用的假大管家记着的记忆
    @ObservationIgnored private var demoMemory: [String: [BotMemo]] = [:]
    @ObservationIgnored private var demoJobs: [String: [BotJob]] = [:]

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
        BotPictures.demo = app?.demo != nil
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
        for (k, v) in chats where v.count > BotLog.maxLines {
            dropPictures(Array(v.prefix(v.count - BotLog.maxLines)))     // 252：图跟聊天记录一样留最近 200 条
            chats[k] = Array(v.suffix(BotLog.maxLines))
        }
        guard let file else { return }
        if let d = try? JSONEncoder().encode(BotsStore(bots: bots, groups: groups, chats: chats)) { try? d.write(to: file, options: .atomic) }
    }

    private func dropPictures(_ rows: [BotRow]) {
        BotPictures.remove(rows.flatMap { $0.line.images ?? [] })
    }

    /// 设置里「清空机器人聊天记录」
    func clearChats() {
        load()
        dropPictures(chats.values.flatMap { $0 })
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

    /// 从提醒点进来；252：带 msg 就滚到那一句
    func openFromLink(_ id: String, msg: String? = nil) {
        load()
        focus = msg.map { BotFocus(window: id, msg: $0) }
        path = [.chat(id)]
        open = true
        refresh(quiet: true)
    }

    func openProfile(_ id: String) {
        path.append(.profile(id))
        askProfile(id)
    }

    func askProfile(_ id: String) {
        if BotID.isGroup(id) { refresh(quiet: true); return }
        send(BotAsk("memory", id: id), window: id)
        if id != BotID.shutong { askJobs(id) }
    }

    func refresh(quiet: Bool = false) {
        listError = nil
        guard !waits.values.contains(where: { $0.action == "list" }) else { return }
        send(BotAsk("list"), window: quiet ? "quiet" : "list")
    }

    // ---------------------------------------------------------------- 建、改、删
    /// 256：照新机器人页填的寄；说明没填拿人设第一句
    func create() {
        let d = newBot
        guard !busy.contains("new"), d.ready(taken: roster.map(\.name)) else { return }
        newError[.newBot] = nil
        send(BotAsk("new", name: BotNew.cleanName(d.name), desc: d.sentDesc, persona: d.sentPersona), window: "new", made: .bot(d))
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

    func createGroup() {
        let d = newGroup
        guard !busy.contains("newGroup"), d.ready else { return }
        newError[.newGroup] = nil
        send(BotAsk("new", name: d.sentName, members: d.members, chief: BotID.shutong), window: "newGroup", group: true, made: .group(d))
    }

    func editGroup(_ id: String, name: String, members: [String], chief: String) {
        send(BotAsk("edit", id: id, name: name, members: members, chief: chief), window: id, group: true)
    }

    func deleteGroup(_ id: String) {
        send(BotAsk("delete", id: id), window: id, group: true)
    }

    // ---------------------------------------------------------------- 252 👍👎、定时活
    func react(_ window: String, _ row: UUID, _ how: String) {
        guard let i = chats[window]?.firstIndex(where: { $0.id == row }), let line = chats[window]?[i].line, let msg = line.msg else { return }
        let new: String? = line.reaction == how ? nil : how                      // 再点一次取消
        chats[window]?[i].line.reaction = new
        save()
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        let bot = line.who
        sendQuiet(BotAsk("react", id: bot, msg: msg, react: new ?? "none"),
             Wait(action: "react", window: window, msg: msg, react: new, old: line.reaction))
    }

    func askJobs(_ id: String) {
        jobsError[id] = nil
        sendQuiet(BotAsk("jobs", id: id), Wait(action: "jobs", window: id))
    }

    func setJob(_ id: String, _ job: String, on: Bool) {
        if let i = jobs[id]?.firstIndex(where: { $0.id == job }) { jobs[id]?[i].on = on }
        sendQuiet(BotAsk(on ? "job-on" : "job-off", id: id, job: job), Wait(action: on ? "job-on" : "job-off", window: id))
    }

    func deleteJob(_ id: String, _ job: String) {
        jobs[id]?.removeAll { $0.id == job }
        sendQuiet(BotAsk("job-delete", id: id, job: job), Wait(action: "job-delete", window: id))
    }

    /// 寄一封不挡界面的（不记 busy，别把保存按钮灰掉）
    private func sendQuiet(_ ask: BotAsk, _ wait: Wait) {
        guard let app else { return }
        let rid = UUID().uuidString
        let req = ButlerRequest.bot(id: rid, ask: ask, at: ISOTime.string(Date()), app: ButlerService.appVersion)
        waits[rid] = wait
        if app.demo != nil { fake(req); return }
        Task {
            switch await app.butler.sendBots(req) {
            case .sent(let pc):
                if !pc && wait.quiet { app.show(self.t("shutong.queued")) }
            case .noPair:
                self.opFailed(rid, self.t("shutong.noPair"))
            case .failed(let why):
                self.opFailed(rid, self.f("shutong.sendFailed", why))
            }
        }
    }

    /// 👍👎 没办成：放回原来的（他中间又点过别的就不动）
    private func undoReact(_ w: Wait) {
        guard let msg = w.msg, let i = chats[w.window]?.firstIndex(where: { $0.line.msg == msg }),
              chats[w.window]?[i].line.reaction == w.react else { return }
        chats[w.window]?[i].line.reaction = w.old
        save()
    }

    private func opAnswer(_ r: ButlerResult, _ w: Wait) {
        let id = w.window
        guard r.ok else {
            switch w.action {
            case "react": undoReact(w); app?.show(failure(r))
            case "jobs": jobsError[id] = failure(r)
            default: app?.show(failure(r)); askJobs(id)
            }
            return
        }
        // 还有开关在路上：以最后那封回的名单为准
        if let list = r.bot?.jobs, !waits.values.contains(where: { $0.window == id && $0.action.hasPrefix("job-") }) {
            jobs[id] = list
            jobsError[id] = nil
        }
    }

    // ---------------------------------------------------------------- 252 定时活寄进窗的一句
    func post(_ d: ButlerDelivery, files: [String: Data]) {
        load()
        guard let line = BotPost.line(d, images: keepPictures(d.images, files)) else { return }
        let id = line.who
        var rows = chats[id] ?? []
        guard let at = BotPost.slot(line, in: rows.map(\.line)) else { return }     // 同一句寄两回：不重复放
        rows.insert(BotRow(line: line), at: at)
        chats[id] = rows
        save()
        if card(id) == nil { refresh(quiet: true) }                    // 不认识的机器人：名单拉一次就认得了
        if let app, app.demo == nil, UIApplication.shared.applicationState != .active, d.bark != true, (d.seq ?? 1) == 1 {
            ButlerNotice.post(title: name(id), body: d.text, id: d.id)
        }
    }

    private func keepPictures(_ paths: [String]?, _ files: [String: Data]) -> [String] {
        var names: [String] = []
        for p in paths ?? [] {
            guard let n = BotPost.fileName(p), let d = files[p], BotPictures.save(d, name: n) else { continue }
            names.append(n)
        }
        return names
    }

    private func send(_ ask: BotAsk, window: String, group: Bool = false, made: Made? = nil) {
        guard let app else { return }
        let rid = UUID().uuidString
        let at = ISOTime.string(Date())
        let req = group ? ButlerRequest.group(id: rid, ask: ask, at: at, app: ButlerService.appVersion)
                        : ButlerRequest.bot(id: rid, ask: ask, at: at, app: ButlerService.appVersion)
        waits[rid] = Wait(action: ask.action, window: window, made: made)
        if window != "quiet" { busy.insert(window) }
        if app.demo != nil { fake(req); return }
        Task {
            switch await app.butler.sendBots(req) {
            case .sent(let pc):
                if !pc { self.waits[rid]?.queued = true }
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
        if w.action == "react" { undoReact(w); app?.show(why); return }
        if w.action == "jobs" { jobsError[w.window] = why; return }
        if w.action.hasPrefix("job-") { app?.show(why); askJobs(w.window); return }
        busy.remove(w.window)
        if w.action == "list" {
            if w.window == "list" { listError = why }
        } else if let made = w.made {
            refused(made.page, why)
        } else {
            app?.show(why)
        }
    }

    /// 256 没建成：那句写在新建页上（字留着）；他已经走开了就底下再弹一行
    private func refused(_ page: BotRoute, _ why: String) {
        newError[page] = why
        if path.last != page { app?.show(why) }
    }

    /// 256 new 的回信：没办成把那句原样亮在新建页上（字留着）；办成了清掉填的字，还在那一页就跳进它的窗
    private func madeAnswer(_ r: ButlerResult, _ made: Made) {
        guard r.ok else {
            refused(made.page, failure(r))
            return
        }
        if let b = r.bot?.bots ?? r.group?.bots { bots = b }
        if let g = r.bot?.groups ?? r.group?.groups { groups = g }
        if let id = r.bot?.id, let b = r.bot?.bot {
            profiles[id] = BotProfile(persona: b.persona ?? "", memory: r.bot?.memory ?? [])
        }
        newError[made.page] = nil
        switch made {
        case .bot(let d): if newBot.name == d.name { newBot = BotDraft() }
        case .group(let d): if newGroup.name == d.name { newGroup = BotGroupDraft() }
        }
        if let id = r.bot?.id ?? r.group?.id, path.last == made.page { path = [.chat(id)] }
        save()
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
    func answer(_ r: ButlerResult, files: [String: Data] = [:]) {
        load()
        if let g = r.group, g.action == "say" { groupAnswer(r, g); return }
        guard let w = waits[r.id] else {
            // 等超时了才到的单聊回话：照样放进去
            if let b = r.bot, b.action == "chat", let id = b.id, let row = chats[id]?.first(where: { $0.line.who == "he" && $0.line.rid == r.id }) {
                chatAnswer(r, Wait(action: "chat", window: id, line: row.id), files: files)
            }
            return
        }
        if w.action == "say" {                                   // 老大管家不认识这个 ask：回的信没有 group
            sayFailed(r.id, failure(r))
            return
        }
        waits.removeValue(forKey: r.id)
        if w.action == "chat" {
            chatAnswer(r, w, files: files)
            return
        }
        if w.action == "jobs" || w.quiet {
            opAnswer(r, w)
            return
        }
        if let made = w.made {
            // 晚到的那封回来时，别把后来那封的转圈停了
            if !waits.values.contains(where: { $0.window == w.window && !$0.late }) { busy.remove(w.window) }
            madeAnswer(r, made)
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
        case "delete":
            let id = r.bot?.id ?? r.group?.id ?? w.window
            dropPictures(chats[id] ?? [])
            chats[id] = nil
            profiles[id] = nil
            jobs[id] = nil
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

    private func chatAnswer(_ r: ButlerResult, _ w: Wait, files: [String: Data]) {
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
        let pictures = keepPictures(r.bot?.images, files)
        let line = BotLine(who: quota ? "" : w.window, text: say, rid: r.id, msg: r.bot?.msg,
                           images: pictures.isEmpty ? nil : pictures, canReact: !quota && r.bot?.msg != nil)
        rows.insert(BotRow(line: line), at: min(at, rows.count))
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
            if w.quiet || w.late {                                      // 252：信在信箱里，晚了也会办
                if now.timeIntervalSince(w.at) > 86_400 { waits[rid] = nil }
                continue
            }
            let talking = w.action == "chat" || w.action == "say"
            if now.timeIntervalSince(w.at) <= (talking ? 300 : 90) { continue }
            if let made = w.made {                                      // 256：停转圈、字留着；回信晚到照样认
                waits[rid]?.late = true
                busy.remove(w.window)
                newError[made.page] = t(w.queued ? "shutong.queued" : "bots.noAnswer")
                continue
            }
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

    /// 252：掌眼窗里的样子：昨天聊过一串，今天定时活寄来四句（故意先到第 2 句），两条定时活。走的是真的收信那条路
    func demoEye() {
        guard app?.demo != nil else { return }
        loaded = true
        BotPictures.demo = true
        let z = zh
        let eye = BotCard(id: "bdemoeye1", name: z ? "掌眼" : "Curator", desc: z ? "每天寄几条好设计" : "A few good designs a day", gear: "Sonnet 中")
        bots = [BotCard(id: BotID.shutong, name: BotsModel.scribeName, desc: "", builtin: true), eye]
        demoMemory[eye.id] = []
        demoJobs[eye.id] = [BotJob(id: "j0000001", when: z ? "每天 20:45" : "Daily 20:45", kind: "设计日课", what: z ? "设计日课" : "Design lesson", on: true),
                            BotJob(id: "j0000002", when: z ? "每天 08:00" : "Daily 08:00", kind: "查资料", what: z ? "查一下新加坡天气" : "Singapore weather", on: true)]
        let old = Date().addingTimeInterval(-86_400)
        chats[eye.id] = (1...10).map { i in
            BotRow(line: BotLine(who: i % 2 == 0 ? eye.id : "he", text: z ? "昨天第 \(i) 句" : "Yesterday \(i)",
                                 at: old.addingTimeInterval(Double(i)), state: "answered"))
        }
        let wire = DemoDesign.pictures()
        let texts = z ? ["第一条 刺点：整屏只有一根烧红的铁丝\n差别：同类堆卡片，它只留一根线\n能偷的招：一个主角，别的全退后",
                         "第二条 少数派\n刺点：灰字符堆成的波团漫过白字列表",
                         "第三条 刺点：酒红漆管直角垂下喇叭罩",
                         "今天就这些。看了 18 个，刷掉 15 个。"]
                      : ["One. The punctum: a single red-hot wire\nBorrow: one hero, everything else steps back",
                         "Two. Minority pick\nThe punctum: a wave of grey glyphs over a white list",
                         "Three. The punctum: a wine-red pipe bends straight down",
                         "That’s all for today. 18 looked at, 15 dropped."]
        for n in [2, 1, 3, 4] {
            let imgs: [String] = n == 4 ? [] : [1, 2].map { "附件/zdemo\(n)-\($0).jpg" }
            var files: [String: Data] = [:]
            for (k, p) in imgs.enumerated() { files[p] = wire[(n - 1) % wire.count][k] }
            let data: [String: Any] = ["v": 1, "id": "bm-demo\(n)", "kind": BotPost.kind, "bot": eye.id, "msg": "zdemo\(n)", "text": texts[n - 1],
                                       "images": imgs, "react": n < 4, "run": "j0000001-demo", "seq": n, "last": n == 4,
                                       "at": ISOTime.string(Date().addingTimeInterval(-60))]
            if let j = try? JSONSerialization.data(withJSONObject: data), let d = try? JSONDecoder().decode(ButlerDelivery.self, from: j) {
                post(d, files: files)
            }
        }
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
            if a.name == "Nope" {                                       // 256 UI 测试：大管家回 error
                fakeReply(rid, stage: "bot", ok: false, error: z ? "机器人到 12 个了，先删一个" : "12 bots already. Delete one first.")
                return
            }
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
        case "react":
            fakeReply(rid, stage: "bot", bot: BotReply("react", id: id, msg: a.msg, react: a.react))
        case "jobs", "job-on", "job-off", "job-delete":
            if a.action == "job-delete" { demoJobs[id]?.removeAll { $0.id == a.job } }
            if let i = demoJobs[id]?.firstIndex(where: { $0.id == a.job }) { demoJobs[id]?[i].on = a.action == "job-on" }
            fakeReply(rid, stage: "bot", bot: BotReply(a.action, id: id, jobs: demoJobs[id] ?? []))
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
