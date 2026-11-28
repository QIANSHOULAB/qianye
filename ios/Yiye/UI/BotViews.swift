import SwiftUI
import UIKit
import YiyeKit

/// 250 机器人：一张半屏，跟小书童那个聊天窗一个样子。名单（小书童排第一，下面是建的机器人，再下面是群）→ 聊天窗 → 资料页。
struct BotsSheet: View {
    @Environment(AppModel.self) private var app
    /// 252：提醒点进来看图，半屏直接拉满
    @State private var detent: PresentationDetent = .medium

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
        .presentationDetents([.medium, .large], selection: $detent)
        .presentationDragIndicator(.visible)
        .overlay(alignment: .bottom) { ToastView() }
        .onAppear { m.load(); LibraryModel.shared.sync(); if m.focus != nil { detent = .large } }   // 258：顺手取灵感库新的
        .onChange(of: m.focus) { _, f in if f != nil { detent = .large } }
        // 256：新建页整张拉满，不用往上推；258：灵感库也是
        .onChange(of: m.path.last) { _, r in if r == .newBot || r == .newGroup || r == .library { detent = .large } }
        .onDisappear { m.open = false; m.focus = nil; if ShutongModel.shared.recording { ShutongModel.shared.stopRecording() } }
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
        case .library: GalleryWall()
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

/// 256：新建页右上那个「建好」：填齐才亮，寄出去以后换成转圈
struct BotMake {
    let ready: Bool
    let busy: Bool
    let tap: () -> Void
}

/// 顶上那一条：返回、名字（能点进资料页）、好了（256：新建页换成「建好」）
struct BotHeader: View {
    let title: String
    var back = true
    var onTitle: (() -> Void)?
    var onBack: (() -> Void)?
    var make: BotMake?
    /// 258：寄过设计图的机器人，右上多一个进灵感库的
    var onLibrary: (() -> Void)?
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss

    init(title: String, back: Bool = true, onTitle: (() -> Void)? = nil, onBack: (() -> Void)? = nil, make: BotMake? = nil,
         onLibrary: (() -> Void)? = nil) {                          // 258 起别的文件也用这条
        self.title = title; self.back = back; self.onTitle = onTitle; self.onBack = onBack; self.make = make; self.onLibrary = onLibrary
    }

    private var t: Lang { app.lang }

    var body: some View {
        HStack(spacing: 6) {
            if back {
                Button { if let onBack { onBack() } else { dismiss() } } label: {
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
            if let onLibrary {
                Button(action: onLibrary) {
                    Image(systemName: "square.grid.2x2").font(.system(size: 17, weight: .medium)).foregroundStyle(Color(Ink.accent)).hit44()
                }
                .buttonStyle(.plain)
                .accessibilityLabel(t.t("lib.title"))
                .accessibilityIdentifier("bots.header.library")
            }
            if let make {
                if make.busy {
                    ProgressView()
                        .frame(minWidth: 44, minHeight: 44)
                        .accessibilityIdentifier("bots.creating")
                } else {
                    Button(t.t("bots.create"), action: make.tap)
                        .buttonStyle(PlainTextButtonStyle(color: make.ready ? Ink.accent : Ink.text3))
                        .disabled(!make.ready)
                        .opacity(make.ready ? 1 : 0.55)
                        .accessibilityIdentifier("bots.create")
                }
            } else {
                Button(t.t("common.done")) { BotsModel.shared.open = false }
                    .buttonStyle(PlainTextButtonStyle())
                    .accessibilityIdentifier("bots.done")
            }
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
                    GalleryCard { m.path.append(.library) }                   // 258
                        .padding(.bottom, 8)
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
    /// 252：提醒点进来滚到的那一趟定时活：同一趟后面的信到了别把它顶走
    @State private var pinned: String?
    /// 252：点开全屏看的那一组图
    @State private var viewing: BotShown?
    @FocusState private var typing: Bool

    private var t: Lang { app.lang }
    private var m: BotsModel { BotsModel.shared }
    private var isGroup: Bool { BotID.isGroup(window) }
    private var text: Binding<String> { Binding(get: { m.inputs[window] ?? "" }, set: { m.inputs[window] = $0 }) }

    var body: some View {
        let rows = m.chats[window] ?? []
        let gallery = !isGroup && (LibraryModel.shared.book.owners.contains(window) || rows.contains { !($0.line.item ?? "").isEmpty })
        let toGallery: (() -> Void)? = gallery ? { typing = false; m.path.append(.library) } : nil
        VStack(spacing: 0) {
            BotHeader(title: m.name(window), onTitle: { typing = false; m.openProfile(window) }, onLibrary: toGallery)
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
                            BotBubble(window: window, row: r) { names, i in
                                typing = false
                                viewing = BotShown(names: names, index: i)
                            }
                            .id(r.id)
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
                .onAppear { if !jump(proxy) { proxy.scrollTo("bottom", anchor: .bottom) } }
                .onChange(of: rows.count) { _, _ in follow(proxy) }
                .onChange(of: m.focus) { _, _ in _ = jump(proxy) }                          // 窗开着时又点了一条提醒
                .onChange(of: m.thinking(window)) { _, _ in withAnimation(.easeOut(duration: 0.2)) { proxy.scrollTo("bottom", anchor: .bottom) } }
            }
            if isGroup { mentions }
            inputBar
        }
        .onAppear { m.load() }
        .onDisappear { if ShutongModel.shared.recording { ShutongModel.shared.stopRecording() } }
        .fullScreenCover(item: $viewing) { BotPictureViewer(shown: $0) }
    }

    /// 252：提醒指的那一句到了就滚到它（在顶上），返回 true
    private func jump(_ proxy: ScrollViewProxy) -> Bool {
        guard let f = m.focus, f.window == window, let row = m.chats[window]?.first(where: { $0.line.msg == f.msg }) else { return false }
        pinned = row.line.run
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 450_000_000)
            withAnimation(.easeOut(duration: 0.25)) { proxy.scrollTo(row.id, anchor: .top) }
            if m.focus == f { m.focus = nil }
        }
        return true
    }

    /// 多了一行：平时跟到底；在等提醒指的那句、或者正看着那一趟，就别动
    private func follow(_ proxy: ScrollViewProxy) {
        let last = m.chats[window]?.last?.line
        if last?.who != "he" {
            if jump(proxy) { return }
            if let f = m.focus, f.window == window, f.fresh { return }
            if let pinned, last?.run == pinned { return }
        }
        pinned = nil
        withAnimation(.easeOut(duration: 0.2)) { proxy.scrollTo("bottom", anchor: .bottom) }
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
    /// 252：点了一张图：这条的全部图、点的第几张
    let see: ([String], Int) -> Void
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
                    said
                }
            }
            .padding(.trailing, 32)
            .frame(maxWidth: .infinity, alignment: .leading)
        } else {
            said
                .padding(.trailing, 32)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    /// 252：图在字上面，按顺序；258：能评的底下只有一个很淡的 👎
    private var said: some View {
        VStack(alignment: .leading, spacing: 6) {
            let names = line.images ?? []
            ForEach(Array(names.enumerated()), id: \.offset) { p in
                BotPicture(name: p.element, first: p.offset == 0, id: "\(line.msg ?? "").\(p.offset)") { see(names, p.offset) }
            }
            words(line.text)
            if line.canReact == true, line.msg != nil {
                HStack(spacing: 4) {
                    thumbDown
                    if m.justDropped.contains(row.id) { dropped }
                }
                .padding(.leading, -10)
                .animation(.easeOut(duration: 0.4), value: m.justDropped.contains(row.id))
            }
        }
    }

    private var thumbDown: some View {
        let on = line.reaction == "down"
        return Button { m.dislike(window, row.id) } label: {
            Image(systemName: on ? "hand.thumbsdown.fill" : "hand.thumbsdown")
                .font(.system(size: 14))
                .foregroundStyle(Color(on ? Ink.accent : Ink.text3))
                .opacity(on ? 1 : 0.6)
                .frame(width: 40, height: 32)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(t.t(m.libraryItem(line) != nil ? "lib.drop" : "bots.dislike"))
        .accessibilityIdentifier("bots.down.\(line.msg ?? "")")
        .accessibilityAddTraits(on ? [.isButton, .isSelected] : .isButton)
    }

    /// 258：设计图点了 👎：一行小字「不留了 · 撤回」，几秒后淡掉
    private var dropped: some View {
        HStack(spacing: 2) {
            Text(t.t("lib.dropped") + " ·")
                .font(.system(size: 13))
                .foregroundStyle(Color(Ink.text3))
                .accessibilityIdentifier("bots.dropped.\(line.msg ?? "")")
            Button { m.dislike(window, row.id) } label: {
                Text(t.t("lib.undo"))
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Color(Ink.accent))
                    .frame(minWidth: 36, minHeight: 32)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("bots.undo.\(line.msg ?? "")")
        }
        .transition(.opacity)
    }
}

// ================================================================ 252 图
/// 点开看的一组图
struct BotShown: Identifiable {
    let id = UUID()
    let names: [String]
    let index: Int
}

/// 聊天窗里的一张：第一张（裁出来的那块）铺满，后面的（整屏小图）小一号；四角跟聊天气泡一样圆；点开全屏，长按存相册
private struct BotPicture: View {
    let name: String
    let first: Bool
    let id: String
    let open: () -> Void
    @Environment(AppModel.self) private var app

    var body: some View {
        if let img = BotPictures.image(name), img.size.height > 0 {
            let ratio = img.size.width / img.size.height
            let tall: CGFloat = first ? 340 : 220                    // 竖长的图别把一屏占满
            let wide: CGFloat = first ? 600 : 240
            Image(uiImage: img)
                .resizable()
                .aspectRatio(ratio, contentMode: .fit)
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                .frame(maxWidth: min(wide, tall * ratio), alignment: .leading)
                .contentShape(Rectangle())
                .onTapGesture(perform: open)
                .onLongPressGesture { BotPictures.keep(name, app: app) }
                .accessibilityElement()
                .accessibilityAddTraits([.isImage, .isButton])
                .accessibilityLabel(app.lang.t("bots.picture"))
                .accessibilityAction { open() }
                .accessibilityAction(named: Text(app.lang.t("share.save"))) { BotPictures.keep(name, app: app) }
                .accessibilityIdentifier("bots.pic.\(id)")
        }
    }
}

/// 全屏看：双指放大、左右滑看这条里的下一张、长按存相册、点一下收起
private struct BotPictureViewer: View {
    let shown: BotShown
    @State private var page: Int
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss

    init(shown: BotShown) {
        self.shown = shown
        _page = State(initialValue: shown.index)
    }

    var body: some View {
        ZStack(alignment: .topTrailing) {
            Color.black.ignoresSafeArea()
            TabView(selection: $page) {
                ForEach(Array(shown.names.enumerated()), id: \.offset) { p in
                    if let img = BotPictures.image(p.element) {
                        ZoomableImage(image: img, name: "bots.viewer.image.\(p.offset)",
                                      onTap: { dismiss() }, onLongPress: { BotPictures.keep(p.element, app: app) })
                            .ignoresSafeArea()
                            .tag(p.offset)
                    }
                }
            }
            .tabViewStyle(.page(indexDisplayMode: shown.names.count > 1 ? .automatic : .never))
            .ignoresSafeArea()
            Button { dismiss() } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 15, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 36, height: 36)
                    .background { Circle().fill(.white.opacity(0.18)) }
                    .frame(width: 44, height: 44)
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .padding(.trailing, 12)
            .padding(.top, 4)
            .accessibilityLabel(app.lang.t("common.close"))
            .accessibilityIdentifier("bots.viewer.close")
        }
        .overlay(alignment: .bottom) { ToastView() }
        .statusBarHidden()
    }
}

// ================================================================ 建机器人
/// 256：新建页顶上那一句：缺什么、哪里不对、大管家回的原话
private struct NewNote: View {
    let text: String
    let bad: Bool

    var body: some View {
        if !text.isEmpty {
            Text(text)
                .font(.system(size: 14))
                .foregroundStyle(Color(bad ? Ink.danger : Ink.text3))
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 20)
                .padding(.bottom, 4)
                .accessibilityIdentifier(bad ? "bots.error" : "bots.hint")
        }
    }
}

private extension View {
    /// 256：填了字又点返回，先问一句
    @MainActor func dropAsk(_ asking: Binding<Bool>, _ t: Lang, drop: @escaping () -> Void) -> some View {
        alert(t.t("bots.dropAsk"), isPresented: asking) {                    // 用弹窗：两个按钮一定都在
            Button(t.t("bots.dropYes"), role: .destructive, action: drop)
            Button(t.t("bots.dropNo"), role: .cancel) {}
        }
    }
}

private struct NewBotView: View {
    @Environment(AppModel.self) private var app
    @State private var asking = false

    private var t: Lang { app.lang }

    var body: some View {
        @Bindable var m = BotsModel.shared
        let d = m.newBot
        let busy = m.busy.contains("new")
        let taken = m.roster.map(\.name)
        let line = topLine(d, BotNew.nameProblem(d.name, taken: taken), m.newError[.newBot])
        VStack(spacing: 0) {
            BotHeader(title: t.t("bots.newTitle"),
                      onBack: { if d.dirty && !busy { asking = true } else { leave() } },
                      make: BotMake(ready: d.ready(taken: taken), busy: busy) { m.create() })
            NewNote(text: line.text, bad: line.bad)
            Form {
                Section(t.t("bots.name")) {
                    TextField("", text: $m.newBot.name)
                        .autocorrectionDisabled()
                        .accessibilityIdentifier("bots.name")
                }
                Section(t.t("bots.persona")) {
                    TextField(t.t("bots.personaHint"), text: $m.newBot.persona, axis: .vertical)
                        .lineLimit(4...12)
                        .accessibilityIdentifier("bots.persona")
                }
                Section(t.t("bots.desc")) {
                    TextField(t.t("bots.descNew"), text: $m.newBot.desc).accessibilityIdentifier("bots.desc")
                }
            }
            .disabled(busy)
            .scrollContentBackground(.hidden)
        }
        .onChange(of: m.newBot) { _, _ in m.newError[.newBot] = nil }         // 改了一个字，上回那句就撤了
        .dropAsk($asking, t) {
            BotsModel.shared.newBot = BotDraft()
            BotsModel.shared.newError[.newBot] = nil
            leave()
        }
    }

    private func leave() {
        if BotsModel.shared.path.last == .newBot { BotsModel.shared.path.removeLast() }
    }

    /// 名字不对 → 大管家回的话 → 还缺什么 → 建出来的名字跟打的不一样
    private func topLine(_ d: BotDraft, _ problem: BotNew.Problem?, _ error: String?) -> (text: String, bad: Bool) {
        switch problem {
        case .nameEmpty?: return (t.t("bots.nameNothing"), true)
        case .nameTooLong(let n)?: return (t.f("bots.nameLong", String(n)), true)
        case .nameTaken(let name)?: return (t.f("bots.nameTaken", name), true)
        case .none: break
        }
        if let error { return (error, true) }
        let missing = d.missing.map { t.t($0 == .name ? "bots.needName" : "bots.needPersona") }
        if !missing.isEmpty { return (t.f("bots.need", missing.joined(separator: t.isZh ? "、" : ", ")), false) }
        let name = BotNew.cleanName(d.name)
        return (name == d.name.trimmingCharacters(in: .whitespacesAndNewlines) ? "" : t.f("bots.nameAs", name), false)
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
                if !scribe { jobsSection }
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

    /// 252：定时活，一条一行：什么时候、干什么，右边开关；左滑删。新增在聊天里跟它说
    @ViewBuilder private var jobsSection: some View {
        Section(t.t("bots.jobs")) {
            if let list = m.jobs[id] {
                if list.isEmpty { Text(t.t("bots.noJobs")).font(.system(size: 14)).foregroundStyle(Color(Ink.text3)) }
                ForEach(list) { j in
                    Toggle(isOn: Binding(get: { j.on }, set: { m.setJob(id, j.id, on: $0) })) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(j.when).font(.system(size: 15, weight: .semibold)).foregroundStyle(Color(Ink.text))
                            Text(j.title).font(.system(size: 13)).foregroundStyle(Color(Ink.text2)).lineLimit(2)
                        }
                    }
                    .tint(Color(Ink.accent))
                    .accessibilityIdentifier("bots.job.\(j.id)")
                    .swipeActions(edge: .trailing) {
                        Button(t.t("note.delete"), role: .destructive) { m.deleteJob(id, j.id) }
                    }
                }
            } else {
                Text(m.jobsError[id] ?? t.t("bots.loading")).foregroundStyle(Color(Ink.text3))
            }
        }
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
    @State private var asking = false

    private var t: Lang { app.lang }

    var body: some View {
        @Bindable var m = BotsModel.shared
        let d = m.newGroup
        let busy = m.busy.contains("newGroup")
        let line = topLine(d, m.newError[.newGroup])
        VStack(spacing: 0) {
            BotHeader(title: t.t("bots.groupTitle"),
                      onBack: { if d.dirty && !busy { asking = true } else { leave() } },
                      make: BotMake(ready: d.ready, busy: busy) { m.createGroup() })
            NewNote(text: line.text, bad: line.bad)
            List {
                Section(t.t("bots.groupName")) {
                    TextField("", text: $m.newGroup.name)
                        .autocorrectionDisabled()
                        .accessibilityIdentifier("bots.groupName")
                }
                Section(t.t("bots.members")) {
                    ForEach(m.roster) { b in
                        PickRow(card: b, on: d.members.contains(b.id)) {
                            if let i = m.newGroup.members.firstIndex(of: b.id) {
                                m.newGroup.members.remove(at: i)
                            } else if m.newGroup.members.count < BotGroupDraft.membersMax {
                                m.newGroup.members.append(b.id)
                            }
                        }
                    }
                }
            }
            .disabled(busy)
            .scrollContentBackground(.hidden)
        }
        .onAppear {
            // 上回勾的里有删掉了的：拿掉，不然大管家不认
            let alive = Set(m.roster.map(\.id))
            if m.newGroup.members.contains(where: { !alive.contains($0) }) { m.newGroup.members.removeAll { !alive.contains($0) } }
        }
        .onChange(of: m.newGroup) { _, _ in m.newError[.newGroup] = nil }
        .dropAsk($asking, t) {
            BotsModel.shared.newGroup = BotGroupDraft()
            BotsModel.shared.newError[.newGroup] = nil
            leave()
        }
    }

    private func leave() {
        if BotsModel.shared.path.last == .newGroup { BotsModel.shared.path.removeLast() }
    }

    private func topLine(_ d: BotGroupDraft, _ error: String?) -> (text: String, bad: Bool) {
        if let n = d.nameTooLong { return (t.f("bots.groupLong", String(n)), true) }
        if let error { return (error, true) }
        var missing: [String] = []
        if d.sentName.isEmpty { missing.append(t.t("bots.needGroupName")) }
        if d.short > 0 { missing.append(t.f("bots.needMembers", String(d.short))) }
        return (missing.isEmpty ? "" : t.f("bots.need", missing.joined(separator: t.isZh ? "、" : ", ")), false)
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
