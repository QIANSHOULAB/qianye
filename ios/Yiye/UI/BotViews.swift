import SwiftUI
import UIKit
import YiyeKit

/// 250 机器人：一张半屏，跟小书童那个聊天窗一个样子。名单（小书童排第一，下面是建的机器人，再下面是群）→ 聊天窗 → 资料页。
struct BotsSheet: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        @Bindable var m = BotsModel.shared
        NavigationStack(path: $m.path) {
            BotListView()
                .botPage()
                .navigationDestination(for: BotRoute.self) { r in
                    BotRoutePage(route: r).botPage()
                }
        }
        .tint(Color(Ink.accent))
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
        .overlay(alignment: .bottom) { ToastView() }
        .onAppear { m.load() }
        .onDisappear { m.open = false; if ShutongModel.shared.recording { ShutongModel.shared.stopRecording() } }
    }
}

private struct BotRoutePage: View {
    let route: BotRoute

    var body: some View {
        switch route {
        case .chat(let id): BotChatView(window: id)
        case .profile(let id):
            if BotID.isGroup(id) { GroupProfileView(id: id) } else { BotProfileView(id: id) }
        case .newBot: NewBotView()
        case .newGroup: NewGroupView()
        }
    }
}

private extension View {
    /// 系统导航栏藏起来（顶上自己画），底下是纸
    func botPage() -> some View {
        toolbar(.hidden, for: .navigationBar)
            .navigationBarBackButtonHidden()
            .background(PaperBackground().ignoresSafeArea())
    }
}

/// 顶上那一条：返回、名字（能点进资料页）、好了
private struct BotHeader: View {
    let title: String
    var back = true
    var onTitle: (() -> Void)?
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss

    private var t: Lang { app.lang }

    var body: some View {
        HStack(spacing: 6) {
            if back {
                Button { dismiss() } label: {
                    Image(systemName: "chevron.left").font(.system(size: 17, weight: .semibold)).foregroundStyle(Color(Ink.accent)).hit44()
                }
                .buttonStyle(.plain)
                .accessibilityLabel(t.t("bots.back"))
                .accessibilityIdentifier("bots.back")
            }
            if let onTitle {
                Button(action: onTitle) {
                    HStack(spacing: 4) {
                        BarTitle(text: title)
                        Image(systemName: "chevron.right").font(.system(size: 11, weight: .bold)).foregroundStyle(Color(Ink.text3))
                    }
                    .hit44()
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("bots.title")
            } else {
                BarTitle(text: title)
            }
            Spacer(minLength: 0)
            Button(t.t("common.done")) { BotsModel.shared.open = false }
                .buttonStyle(PlainTextButtonStyle())
                .accessibilityIdentifier("bots.done")
        }
        .padding(.horizontal, 16)
        .frame(height: 52)
    }
}

/// 头像：名字第一个字 + 一个颜色（按 id 定，不用挑）；小书童是它的小书桌
struct BotAvatar: View {
    let id: String
    let name: String
    var size: CGFloat = 36

    private static let colors: [Color] = [
        Color(red: 0.62, green: 0.36, blue: 0.30), Color(red: 0.33, green: 0.49, blue: 0.40), Color(red: 0.30, green: 0.43, blue: 0.62),
        Color(red: 0.55, green: 0.43, blue: 0.24), Color(red: 0.49, green: 0.36, blue: 0.55), Color(red: 0.28, green: 0.50, blue: 0.54),
    ]

    var body: some View {
        ZStack {
            if id == BotID.shutong {
                Circle().fill(Color(Ink.accent).opacity(0.16))
                Image(systemName: "studentdesk").font(.system(size: size * 0.48, weight: .medium)).foregroundStyle(Color(Ink.accent))
            } else if BotID.isGroup(id) {
                Circle().fill(Color(Ink.text3).opacity(0.18))
                Image(systemName: "person.3.fill").font(.system(size: size * 0.36, weight: .medium)).foregroundStyle(Color(Ink.text2))
            } else {
                Circle().fill(BotAvatar.colors[BotFace.color(id, count: BotAvatar.colors.count)])
                Text(BotFace.letter(name)).font(.system(size: size * 0.46, weight: .semibold)).foregroundStyle(.white)
            }
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}

// ================================================================ 名单
private struct BotListView: View {
    @Environment(AppModel.self) private var app
    private var t: Lang { app.lang }
    private var m: BotsModel { BotsModel.shared }

    var body: some View {
        VStack(spacing: 0) {
            BotHeader(title: t.t("bots.title"), back: false)
            ScrollView {
                VStack(spacing: 0) {
                    if m.busy.contains("list") && m.others.isEmpty && m.groups.isEmpty { hint(t.t("bots.loading")) }
                    if let e = m.listError {
                        hint(e)
                        Button(t.t("shutong.retry")) { m.refresh() }.buttonStyle(PlainTextButtonStyle()).padding(.bottom, 8)
                    }
                    ForEach(m.roster) { b in
                        row(b.id, name: m.name(b.id), line: m.desc(b)) { m.openWindow(b.id) }
                    }
                    if !m.groups.isEmpty {
                        Text(t.t("bots.groups"))
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(Color(Ink.text3))
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.top, 16)
                            .padding(.bottom, 4)
                        ForEach(m.groups) { g in
                            row(g.id, name: g.name, line: g.members.map { m.name($0) }.joined(separator: " · ")) { m.openWindow(g.id) }
                        }
                    }
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 12)
            }
            HStack(spacing: 12) {
                Button(t.t("bots.new")) { m.path.append(.newBot) }
                    .buttonStyle(SmartButtonStyle(minWidth: 112))
                    .accessibilityIdentifier("bots.new")
                Button(t.t("bots.newGroup")) { m.path.append(.newGroup) }
                    .buttonStyle(SmartButtonStyle(minWidth: 112))
                    .disabled(m.roster.count < 2)
                    .accessibilityIdentifier("bots.newGroup")
            }
            .padding(.vertical, 12)
        }
    }

    private func hint(_ s: String) -> some View {
        Text(s)
            .font(.system(size: 14))
            .foregroundStyle(Color(Ink.text3))
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 6)
    }

    private func row(_ id: String, name: String, line: String, tap: @escaping () -> Void) -> some View {
        Button(action: tap) {
            HStack(spacing: 12) {
                BotAvatar(id: id, name: name)
                VStack(alignment: .leading, spacing: 2) {
                    Text(name).font(.system(size: 16, weight: .semibold)).foregroundStyle(Color(Ink.text)).lineLimit(1)
                    if !line.isEmpty {
                        Text(line).font(.system(size: 13)).foregroundStyle(Color(Ink.text3)).lineLimit(1)
                    }
                }
                Spacer(minLength: 0)
            }
            .frame(minHeight: 56)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("bots.row.\(id)")
    }
}

// ================================================================ 聊天窗（单聊、群聊）
private struct BotChatView: View {
    let window: String
    @Environment(AppModel.self) private var app
    @State private var holding = false
    @FocusState private var typing: Bool

    private var t: Lang { app.lang }
    private var m: BotsModel { BotsModel.shared }
    private var isGroup: Bool { BotID.isGroup(window) }
    private var text: Binding<String> { Binding(get: { m.inputs[window] ?? "" }, set: { m.inputs[window] = $0 }) }

    var body: some View {
        let rows = m.chats[window] ?? []
        VStack(spacing: 0) {
            BotHeader(title: m.name(window), onTitle: { typing = false; m.openProfile(window) })
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 10) {
                        if rows.isEmpty {
                            Text(t.t(isGroup ? "bots.groupEmpty" : "bots.empty"))
                                .font(.system(size: 15))
                                .foregroundStyle(Color(Ink.text2))
                                .padding(.top, 8)
                        }
                        ForEach(rows) { r in
                            BotBubble(window: window, row: r).id(r.id)
                        }
                        if m.thinking(window) {
                            Text(isGroup ? t.t("bots.thinkingGroup") : t.f("bots.thinking", m.name(window)))
                                .font(.system(size: 14))
                                .foregroundStyle(Color(Ink.text3))
                        }
                        Color.clear.frame(height: 4).id("bottom")
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
                }
                .scrollDismissesKeyboard(.interactively)
                .onAppear { proxy.scrollTo("bottom", anchor: .bottom) }
                .onChange(of: rows.count) { _, _ in withAnimation(.easeOut(duration: 0.2)) { proxy.scrollTo("bottom", anchor: .bottom) } }
                .onChange(of: m.thinking(window)) { _, _ in withAnimation(.easeOut(duration: 0.2)) { proxy.scrollTo("bottom", anchor: .bottom) } }
            }
            if isGroup { mentions }
            inputBar
        }
        .onAppear { m.load() }
        .onDisappear { if ShutongModel.shared.recording { ShutongModel.shared.stopRecording() } }
    }

    /// 打了 @：弹出成员名，点一下插进去
    @ViewBuilder private var mentions: some View {
        let found = BotMention.candidates(text.wrappedValue, members: memberCards)
        if !found.isEmpty {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(found) { b in
                        Button { m.inputs[window] = BotMention.insert(b.name, into: text.wrappedValue) } label: {
                            HStack(spacing: 6) {
                                BotAvatar(id: b.id, name: b.name, size: 22)
                                Text(m.name(b.id)).font(.system(size: 14)).foregroundStyle(Color(Ink.text))
                            }
                            .padding(.horizontal, 10)
                            .frame(height: 34)
                            .background { Capsule().fill(Color(Ink.paper)) }
                            .overlay { Capsule().strokeBorder(Color(Ink.paperEdge), lineWidth: 0.75) }
                        }
                        .buttonStyle(.plain)
                        .accessibilityElement(children: .combine)
                        .accessibilityIdentifier("bots.mention.\(b.id)")
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 6)
            }
        }
    }

    /// 群成员；小书童不在群里也能 @
    private var memberCards: [BotCard] {
        var ids = m.group(window)?.members ?? []
        if !ids.contains(BotID.shutong) { ids.append(BotID.shutong) }
        return ids.compactMap { m.card($0) }
    }

    private var inputBar: some View {
        let s = ShutongModel.shared
        let canSend = !text.wrappedValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        return HStack(alignment: .bottom, spacing: 8) {
            // 按住说：跟小书童一条路（大管家认字），认出的字放进输入框，看一眼再发
            Image(systemName: s.recording ? "mic.fill" : (s.hearing ? "ellipsis" : "mic"))
                .font(.system(size: 19, weight: .medium))
                .foregroundStyle(Color(s.recording ? Ink.danger : Ink.text2))
                .frame(width: 44, height: 44)
                .background { Circle().fill(Color(Ink.btnPressed).opacity(s.recording ? 1 : 0)) }
                .contentShape(Circle())
                .gesture(DragGesture(minimumDistance: 0)
                    .onChanged { _ in
                        guard !holding else { return }
                        holding = true
                        let id = window
                        s.startRecording(into: { heard in
                            let old = BotsModel.shared.inputs[id] ?? ""
                            BotsModel.shared.inputs[id] = old.isEmpty ? heard : old + " " + heard
                        })
                    }
                    .onEnded { _ in
                        holding = false
                        s.stopRecording()
                    })
                .accessibilityLabel(t.t("shutong.hold"))
            TextField(s.recording ? t.t("shutong.hold") : (s.hearing ? t.t("shutong.hearing") : t.t("bots.placeholder")),
                      text: text, axis: .vertical)
                .font(.system(size: 17))
                .lineLimit(1...5)
                .focused($typing)
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
                .background { RoundedRectangle(cornerRadius: 18, style: .continuous).fill(Color(Ink.paper)) }
                .overlay { RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(Color(Ink.paperEdge), lineWidth: 0.75) }
                .accessibilityIdentifier("bots.input")
            Button { m.say(window) } label: {
                Image(systemName: "arrow.up.circle.fill")
                    .font(.system(size: 30))
                    .foregroundStyle(Color(canSend ? Ink.accent : Ink.text3))
                    .frame(width: 44, height: 44)
            }
            .buttonStyle(.plain)
            .disabled(!canSend)
            .accessibilityLabel(t.t("shutong.send"))
            .accessibilityIdentifier("bots.send")
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background {
            ZStack(alignment: .top) {
                LinearGradient(colors: [Color(Ink.barTop), Color(Ink.barBottom)], startPoint: .top, endPoint: .bottom)
                Rectangle().fill(Color(Ink.barLine)).frame(height: 0.5)
            }
            .ignoresSafeArea(edges: .bottom)
        }
    }
}

private struct BotBubble: View {
    let window: String
    let row: BotRow
    @Environment(AppModel.self) private var app

    private var t: Lang { app.lang }
    private var m: BotsModel { BotsModel.shared }
    private var line: BotLine { row.line }

    var body: some View {
        if let card = row.card {
            switch card.who {
            case "confirm": ShutongConfirmCard(line: card, group: (window, row.id))
            case "receipt": ShutongBubble(line: card)
            default: small(card.text)
            }
        } else if line.who == "he" {
            mine
        } else if line.who.isEmpty {
            small(line.text)
        } else {
            theirs
        }
    }

    private func small(_ s: String) -> some View {
        Text(s)
            .font(.system(size: 13))
            .foregroundStyle(Color(Ink.text3))
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder private func words(_ s: String) -> some View {
        if Links.find(s).isEmpty {
            Text(s)
                .font(.system(size: 16))
                .foregroundStyle(Color(Ink.text))
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("bots.line")
        } else {
            LinkText(s, color: Ink.text, titles: .of(t))
        }
    }

    private var mine: some View {
        VStack(alignment: .trailing, spacing: 3) {
            words(line.text)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background { RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Color(Ink.accent).opacity(0.16)) }
            if line.state == "failed" {
                Button(t.t("shutong.retry")) { m.retry(window, line.id) }
                    .buttonStyle(PlainTextButtonStyle())
                    .font(.system(size: 13))
            }
        }
        .frame(maxWidth: .infinity, alignment: .trailing)
        .padding(.leading, 48)
    }

    @ViewBuilder private var theirs: some View {
        if BotID.isGroup(window) {                                   // 群里：谁说的，头像加名字
            HStack(alignment: .top, spacing: 8) {
                BotAvatar(id: line.who, name: m.name(line.who), size: 28)
                VStack(alignment: .leading, spacing: 2) {
                    Text(m.name(line.who)).font(.system(size: 12, weight: .semibold)).foregroundStyle(Color(Ink.text3))
                    words(line.text)
                }
            }
            .padding(.trailing, 32)
            .frame(maxWidth: .infinity, alignment: .leading)
        } else {
            words(line.text)
                .padding(.trailing, 32)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

// ================================================================ 建机器人
private struct NewBotView: View {
    @Environment(AppModel.self) private var app
    @State private var name = ""
    @State private var desc = ""
    @State private var persona = ""

    private var t: Lang { app.lang }
    private var m: BotsModel { BotsModel.shared }

    var body: some View {
        let busy = m.busy.contains("new")
        let ready = !name.trimmingCharacters(in: .whitespaces).isEmpty && !desc.trimmingCharacters(in: .whitespaces).isEmpty
        VStack(spacing: 0) {
            BotHeader(title: t.t("bots.newTitle"))
            Form {
                Section(t.t("bots.name")) {
                    TextField("", text: $name).accessibilityIdentifier("bots.name")
                }
                Section(t.t("bots.desc")) {
                    TextField(t.t("bots.descHint"), text: $desc).accessibilityIdentifier("bots.desc")
                }
                Section(t.t("bots.persona")) {
                    TextField(t.t("bots.personaHint"), text: $persona, axis: .vertical)
                        .lineLimit(4...12)
                        .accessibilityIdentifier("bots.persona")
                }
                Section {
                    Button(t.t("bots.create")) { m.create(name: name, desc: desc, persona: persona) }
                        .disabled(!ready || busy)
                        .accessibilityIdentifier("bots.create")
                }
            }
            .scrollContentBackground(.hidden)
        }
    }
}

// ================================================================ 机器人资料页
private struct BotProfileView: View {
    let id: String
    @Environment(AppModel.self) private var app
    @State private var name = ""
    @State private var desc = ""
    @State private var persona = ""
    /// 上回照着填的人设：他没动过才让晚到的资料盖上去
    @State private var filled = ""
    @State private var asking = false

    private var t: Lang { app.lang }
    private var m: BotsModel { BotsModel.shared }
    private var scribe: Bool { id == BotID.shutong }

    var body: some View {
        let card = m.card(id)
        let profile = m.profiles[id]
        let changed = name != (card?.name ?? "") || desc != (card?.desc ?? "") || persona != (profile?.persona ?? "")
        VStack(spacing: 0) {
            BotHeader(title: m.name(id))
            List {
                if scribe {
                    Section { Text(t.t("bots.builtin")).font(.system(size: 14)).foregroundStyle(Color(Ink.text2)) }
                } else {
                    Section(t.t("bots.name")) { TextField("", text: $name).accessibilityIdentifier("bots.name") }
                    Section(t.t("bots.desc")) { TextField(t.t("bots.descHint"), text: $desc).accessibilityIdentifier("bots.desc") }
                    Section(t.t("bots.persona")) {
                        TextField(t.t("bots.personaHint"), text: $persona, axis: .vertical)
                            .lineLimit(3...12)
                            .accessibilityIdentifier("bots.persona")
                    }
                    Section {
                        Button(t.t("bots.save")) { m.edit(id, name: name, desc: desc, persona: persona) }
                            .disabled(!changed || profile == nil || m.busy.contains(id) || name.isEmpty || desc.isEmpty)
                            .accessibilityIdentifier("bots.save")
                    }
                }
                Section(t.t("bots.memory")) {
                    if let profile {
                        if profile.memory.isEmpty { Text(t.t("bots.noMemory")).foregroundStyle(Color(Ink.text3)) }
                        ForEach(profile.memory, id: \.self) { memo in
                            MemoRow(memo: memo)
                                .swipeActions(edge: .trailing) {
                                    Button(t.t("bots.forget"), role: .destructive) { m.forget(id, memo) }
                                }
                        }
                    } else {
                        Text(t.t("bots.loading")).foregroundStyle(Color(Ink.text3))
                    }
                }
                if !scribe {
                    Section {
                        Button(t.t("bots.delete"), role: .destructive) { asking = true }
                            .accessibilityIdentifier("bots.delete")
                    }
                }
            }
            .scrollContentBackground(.hidden)
        }
        .confirmationDialog(t.f("bots.deleteAsk", m.name(id)), isPresented: $asking, titleVisibility: .visible) {
            Button(t.t("bots.deleteYes"), role: .destructive) { m.delete(id) }
            Button(t.t("common.cancel"), role: .cancel) {}
        }
        .onAppear { fill() }
        .onChange(of: m.profiles[id]) { _, _ in if !changedByHim { fill() } }
    }

    /// 他改过名字、说明、人设以后，晚到的资料不盖掉
    private var changedByHim: Bool {
        guard let c = m.card(id) else { return false }
        return (!name.isEmpty && name != c.name) || (!desc.isEmpty && desc != c.desc) || persona != filled
    }

    private func fill() {
        let card = m.card(id)
        name = card?.name ?? ""
        desc = card?.desc ?? ""
        persona = m.profiles[id]?.persona ?? ""
        filled = persona
    }
}

private struct MemoRow: View {
    let memo: BotMemo

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(memo.text).font(.system(size: 15)).foregroundStyle(Color(Ink.text))
            if !memo.date.isEmpty { Text(memo.date).font(.system(size: 12)).foregroundStyle(Color(Ink.text3)) }
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("bots.memo")
    }
}

// ================================================================ 拉群、群资料页
/// 勾成员的一行
private struct PickRow: View {
    let card: BotCard
    let on: Bool
    let tap: () -> Void
    private var m: BotsModel { BotsModel.shared }

    var body: some View {
        Button(action: tap) {
            HStack(spacing: 10) {
                BotAvatar(id: card.id, name: m.name(card.id), size: 28)
                Text(m.name(card.id)).foregroundStyle(Color(Ink.text))
                Spacer(minLength: 0)
                Image(systemName: on ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(Color(on ? Ink.accent : Ink.text3))
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("bots.pick.\(card.id)")
        .accessibilityAddTraits(on ? [.isButton, .isSelected] : .isButton)
    }
}

private struct NewGroupView: View {
    @Environment(AppModel.self) private var app
    @State private var name = ""
    @State private var picked: [String] = []

    private var t: Lang { app.lang }
    private var m: BotsModel { BotsModel.shared }

    var body: some View {
        let ready = !name.trimmingCharacters(in: .whitespaces).isEmpty && (2...6).contains(picked.count)
        VStack(spacing: 0) {
            BotHeader(title: t.t("bots.groupTitle"))
            List {
                Section(t.t("bots.groupName")) { TextField("", text: $name).accessibilityIdentifier("bots.groupName") }
                Section(t.t("bots.members")) {
                    ForEach(m.roster) { b in
                        PickRow(card: b, on: picked.contains(b.id)) {
                            if let i = picked.firstIndex(of: b.id) { picked.remove(at: i) } else if picked.count < 6 { picked.append(b.id) }
                        }
                    }
                }
                Section {
                    Button(t.t("bots.create")) { m.createGroup(name: name, members: picked, chief: BotID.shutong) }
                        .disabled(!ready || m.busy.contains("new"))
                        .accessibilityIdentifier("bots.create")
                }
            }
            .scrollContentBackground(.hidden)
        }
    }
}

private struct GroupProfileView: View {
    let id: String
    @Environment(AppModel.self) private var app
    @State private var name = ""
    @State private var picked: [String] = []
    @State private var chief = BotID.shutong
    @State private var asking = false

    private var t: Lang { app.lang }
    private var m: BotsModel { BotsModel.shared }

    /// 总管：群里的，或者小书童
    private var chiefs: [String] { picked.contains(BotID.shutong) ? picked : [BotID.shutong] + picked }

    var body: some View {
        let g = m.group(id)
        let changed = name != (g?.name ?? "") || picked != (g?.members ?? []) || chief != (g?.chief ?? BotID.shutong)
        VStack(spacing: 0) {
            BotHeader(title: m.name(id))
            List {
                Section(t.t("bots.groupName")) { TextField("", text: $name).accessibilityIdentifier("bots.groupName") }
                Section(t.t("bots.members")) {
                    ForEach(m.roster) { b in
                        PickRow(card: b, on: picked.contains(b.id)) {
                            if let i = picked.firstIndex(of: b.id) { picked.remove(at: i) } else if picked.count < 6 { picked.append(b.id) }
                            if !chiefs.contains(chief) { chief = BotID.shutong }
                        }
                    }
                }
                Section {
                    Picker(t.t("bots.chief"), selection: $chief) {
                        ForEach(chiefs, id: \.self) { Text(m.name($0)).tag($0) }
                    }
                    .accessibilityIdentifier("bots.chief")
                }
                if let mem = g?.memory, !mem.isEmpty {
                    Section(t.t("bots.groupMemory")) { ForEach(mem, id: \.self) { MemoRow(memo: $0) } }
                }
                Section {
                    Button(t.t("bots.save")) { m.editGroup(id, name: name, members: picked, chief: chief) }
                        .disabled(!changed || name.isEmpty || !(2...6).contains(picked.count) || m.busy.contains(id))
                        .accessibilityIdentifier("bots.save")
                }
                Section {
                    Button(t.t("bots.deleteGroup"), role: .destructive) { asking = true }
                        .accessibilityIdentifier("bots.delete")
                }
            }
            .scrollContentBackground(.hidden)
        }
        .confirmationDialog(t.f("bots.deleteAsk", m.name(id)), isPresented: $asking, titleVisibility: .visible) {
            Button(t.t("bots.deleteYes"), role: .destructive) { m.deleteGroup(id) }
            Button(t.t("common.cancel"), role: .cancel) {}
        }
        .onAppear {
            guard let g = m.group(id) else { return }
            name = g.name
            picked = g.members
            chief = g.chief
        }
    }
}
