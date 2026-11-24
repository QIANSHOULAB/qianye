import SwiftUI
import SwiftData
import PhotosUI
import UIKit
import YiyeKit

/// 列表：一条笔记一张纸条（第一行当标题，下面一两行摘要，加时间）。置顶的在最上面。
/// 右滑扔进废纸篓（留 3 天，底下给撤销）；左滑置顶、小耳机；长按一条进批量选，手指不抬往上往下划，划过的都选上。
struct ListScreen: View {
    @Environment(AppModel.self) private var app
    @Query(filter: #Predicate<Note> { $0.trashed == false && $0.kind != "listen" }, sort: \Note.modifiedAt, order: .reverse) private var notes: [Note]
    @Query(sort: \Folder.order) private var folders: [Folder]
    @State private var query = ""
    @State private var showFolders = false
    @State private var folderDetent: PresentationDetent = .medium
    @State private var pickedItem: PhotosPickerItem?
    /// 相册认字：菜单里放 PhotosPicker 点了没反应（Song 11-22），菜单里放普通按钮，再从这儿打开相册
    @State private var showAlbum = false
    @State private var showCamera = false
    @State private var showMirrorPicker = false
    /// 工具箱面板开着
    @State private var showTools = false
    @State private var broadcast = BroadcastTrigger()
    // ---- 批量选（111）
    @State private var selecting = false
    @State private var selected: Set<UUID> = []
    /// 批量选时每条纸条在列表里的位置（只在批量选时收，平时滚动不用算）
    @State private var rowFrames: [UUID: CGRect] = [:]
    @State private var listHeight: CGFloat = 0
    /// 长按之后手指还没抬：哪一条按下的、手指在哪（GestureState：抬手或被打断自动变回 nil）
    @GestureState private var touch: SelTouch? = nil
    @State private var dragBase: Set<UUID> = []
    @State private var dragAnchor = 0
    @State private var dragY: CGFloat = 0
    /// 手指靠近上下边缘：-1 往上滚、1 往下滚、0 不滚
    @State private var autoScroll = 0

    private var t: Lang { app.lang }

    private var currentFolder: Folder? { folders.first { $0.id.uuidString == app.settings.folderID && !$0.isListenOnly } }

    private var shown: [Note] {
        var xs = notes
        if let f = currentFolder { xs = xs.filter { $0.folder?.id == f.id } }
        let q = query.trimmed
        if !q.isEmpty { xs = xs.filter { $0.markdown.localizedCaseInsensitiveContains(q) } }
        switch app.settings.sort {
        case .modifiedNew: xs.sort { $0.modifiedAt > $1.modifiedAt }
        case .modifiedOld: xs.sort { $0.modifiedAt < $1.modifiedAt }
        }
        return xs.filter(\.pinned) + xs.filter { !$0.pinned }
    }

    var body: some View {
        VStack(spacing: 0) {
            if selecting {
                selectionBar
            } else {
            SmartBar {
                ToolboxButton(trigger: broadcast) {
                    withAnimation(.easeOut(duration: 0.2)) { showTools.toggle() }
                }
            } center: {
                Button { showFolders = true } label: {
                    HStack(spacing: 5) {
                        BarTitle(text: currentFolder?.name ?? t.t("list.all"))
                        Image(systemName: "chevron.down")
                            .font(.system(size: 11, weight: .bold))
                            .foregroundStyle(Color(Ink.text3))
                    }
                    .hit44()
                }
                .buttonStyle(.plain)
            } right: {
                Button { app.startVoice() } label: { Image(systemName: "mic") }
                    .buttonStyle(SmartButtonStyle())
                    .accessibilityLabel(t.t("voice.title"))
                Menu {
                    Button { startCamera() } label: { Label(t.t("capture.shootPage"), systemImage: "camera") }
                    Button { showAlbum = true } label: { Label(t.t("capture.fromAlbum"), systemImage: "photo.on.rectangle") }
                } label: {
                    Image(systemName: "camera")
                }
                .menuStyle(.button)
                .buttonStyle(SmartButtonStyle())
                .accessibilityLabel(t.t("capture.camera"))
                Menu {
                    Button { app.newNote() } label: { Label(t.t("list.new"), systemImage: "square.and.pencil") }
                    Button { app.startVoice() } label: { Label(t.t("voice.title"), systemImage: "mic") }
                    Button { startCamera() } label: { Label(t.t("capture.camera"), systemImage: "camera") }
                    Button { showAlbum = true } label: { Label(t.t("capture.library"), systemImage: "photo.on.rectangle") }
                } label: {
                    Image(systemName: "plus")
                } primaryAction: {
                    app.newNote()
                }
                .menuStyle(.button)
                .buttonStyle(SmartButtonStyle())
                .accessibilityLabel(t.t("list.new"))
            }
            }

            SearchField(text: $query, placeholder: t.t("list.search"))

            if app.showMirrorPrompt {
                MirrorPrompt(choose: { showMirrorPicker = true }, skip: {
                    app.settings.mirrorAsked = true
                    withAnimation(.easeOut(duration: 0.24)) { app.showMirrorPrompt = false }
                })
                .transition(.move(edge: .top).combined(with: .opacity))
            }

            if shown.isEmpty {
                EmptyList(searching: !query.trimmed.isEmpty, newNote: { app.newNote() }, camera: { startCamera() })
            } else {
                ScrollViewReader { proxy in
                    List {
                        ForEach(shown) { n in
                            row(n)
                        }
                        Color.clear.frame(height: selecting ? 90 : 40).listRowBackground(Color.clear).listRowSeparator(.hidden)
                    }
                    .listStyle(.plain)
                    .scrollContentBackground(.hidden)
                    .scrollDismissesKeyboard(.immediately)
                    .scrollDisabled(touch != nil)
                    .coordinateSpace(name: "noteList")
                    .onPreferenceChange(RowFrames.self) { rowFrames = $0 }
                    .background(GeometryReader { g in Color.clear.onAppear { listHeight = g.size.height }.onChange(of: g.size.height) { _, h in listHeight = h } })
                    .onChange(of: touch) { old, new in
                        guard let new else { endTouch(); return }
                        if old == nil { startTouch(new.id) }
                        if let y = new.y { moveTouch(y) }
                    }
                    .task(id: autoScroll) {
                        guard autoScroll != 0 else { return }
                        while !Task.isCancelled && autoScroll != 0 {
                            scrollStep(proxy)
                            try? await Task.sleep(nanoseconds: 140_000_000)
                            if touch != nil { moveTouch(dragY) }
                        }
                    }
                }
                .overlay(alignment: .bottom) {
                    if selecting { batchActions }
                }
            }
        }
        .background(DeskBackground())
        .task {                                                              // 截图用：直接开着文件夹面板（排序那排叶子）；folders-tall 拉到最高，看得到最底下的废纸篓；trash 再叠开废纸篓
            let s = app.demo?.screen ?? ""
            if ["folders", "folders-tall", "trash"].contains(s) { showFolders = true }
            if s == "folders-tall" { folderDetent = .large }
        }
        .task { if app.demo?.screen == "toolbox" { showTools = true } }      // 截图用：直接开着工具箱
        .task {                                                              // 截图用：批量选里已经选了三条
            guard app.demo?.screen == "batch" else { return }
            try? await Task.sleep(nanoseconds: 700_000_000)
            selecting = true
            selected = Set(shown.prefix(3).map(\.id))
        }
        .overlay {
            if showTools {
                ToolboxPanel(pick: openTool, dismiss: closeTools)
            }
        }
        .toolbar(.hidden, for: .navigationBar)
        .sheet(isPresented: $showFolders) { FolderSheet().presentationDetents([.medium, .large], selection: $folderDetent) }
        .photosPicker(isPresented: $showAlbum, selection: $pickedItem, matching: .images)
        .onChange(of: pickedItem) { _, item in
            guard let item else { return }
            pickedItem = nil
            app.loadPicked(item) { img in app.recognize(img) }
        }
        .fullScreenCover(isPresented: $showCamera) {
            CameraFlow { img in
                showCamera = false
                if let img { app.recognize(img) }
            }
            .ignoresSafeArea()
        }
        .sheet(isPresented: $showMirrorPicker) {
            FolderPickerView { url in
                showMirrorPicker = false
                guard let url else { return }
                do {
                    try app.mirror.use(url)
                    app.settings.mirrorAsked = true
                    app.showMirrorPrompt = false
                    for n in app.allNotes() where !n.trashed { app.mirror.saveNow(n, attachments: app.attachments) }
                    app.show(t.f("mirror.on", app.mirror.displayPath(t)))
                } catch {
                    app.show(t.f("mirror.failed", error.localizedDescription))
                }
            }
            .ignoresSafeArea()
        }
    }

    private func startCamera() { showCamera = true }

    // ---------------------------------------------------------------- 一条纸条（111）
    @ViewBuilder
    private func row(_ n: Note) -> some View {
        let on = selected.contains(n.id)
        Button {
            if selecting { toggle(n.id) } else { app.path.append(.editor(n.id)) }
        } label: {
            HStack(spacing: 10) {
                if selecting {
                    Image(systemName: on ? "checkmark.circle.fill" : "circle")
                        .font(.system(size: 22))
                        .foregroundStyle(Color(on ? Ink.accent : Ink.text3))
                        .transition(.move(edge: .leading).combined(with: .opacity))
                }
                NoteStrip(note: n)
            }
        }
        .buttonStyle(StripButtonStyle())
        .highPriorityGesture(
            LongPressGesture(minimumDuration: 0.4)
                .sequenced(before: DragGesture(minimumDistance: 0, coordinateSpace: .named("noteList")))
                .updating($touch) { value, state, _ in
                    if case .second(true, let drag) = value { state = SelTouch(id: n.id, y: drag.map { $0.location.y }) }
                }
        )
        .background(GeometryReader { g in
            Color.clear.preference(key: RowFrames.self, value: selecting ? [n.id: g.frame(in: .named("noteList"))] : [:])
        })
        .accessibilityAddTraits(on ? .isSelected : [])
        .listRowInsets(EdgeInsets(top: 5, leading: 12, bottom: 5, trailing: 12))
        .listRowBackground(Color.clear)
        .listRowSeparator(.hidden)
        .swipeActions(edge: .leading, allowsFullSwipe: true) {
            if !selecting {
                Button(role: .destructive) { app.delete(n) } label: { Label(t.t("trash.swipe"), systemImage: "trash") }
                    .tint(.red)
            }
        }
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            if !selecting {
                Button { togglePin(n) } label: { Label(n.pinned ? t.t("note.unpin") : t.t("note.pin"), systemImage: n.pinned ? "pin.slash" : "pin") }
                    .tint(Color(Ink.accent))
                // 小耳机：点了才进听力（Song 11-21：没点的不要进去）
                Button { app.toggleListen(n) } label: {
                    Label(n.inListen ? t.t("listen.remove") : t.t("listen.add"), systemImage: n.inListen ? "minus.circle" : "headphones")
                }
                .tint(n.inListen ? Color(Ink.text3) : Color(Ink.accent))
            }
        }
    }

    // ---------------------------------------------------------------- 批量选（111）
    private var selectionBar: some View {
        SmartBar {
            EmptyView()
        } center: {
            BarTitle(text: t.f("batch.selected", selected.count))
        } right: {
            Button(t.t("batch.all")) {
                selected = Set(shown.map(\.id))
                haptic()
            }
            .buttonStyle(PlainTextButtonStyle())
            Button(t.t("batch.cancel")) { endSelecting() }
                .buttonStyle(PlainTextButtonStyle())
        }
    }

    private var batchActions: some View {
        HStack(spacing: 12) {
            Button { trashSelected() } label: {
                Label(t.t("batch.trash"), systemImage: "trash").frame(maxWidth: .infinity)
            }
            .buttonStyle(SmartButtonStyle())
            .disabled(selected.isEmpty)
            Menu {
                Button(t.t("list.all")) { moveSelected(to: nil) }
                ForEach(movableFolders) { f in Button(f.name) { moveSelected(to: f) } }
            } label: {
                Label(t.t("batch.move"), systemImage: "folder").frame(maxWidth: .infinity)
            }
            .menuStyle(.button)
            .buttonStyle(SmartButtonStyle())
            .disabled(selected.isEmpty)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(Color(Ink.paper).opacity(0.96).overlay(alignment: .top) { Rectangle().fill(Color(Ink.rule)).frame(height: 0.5) })
        .transition(.move(edge: .bottom).combined(with: .opacity))
    }

    /// 挪到…里不列只装听力的夹子（112：里面有便签、而且每一条都是听力）
    private var movableFolders: [Folder] { folders.filter { !$0.isListenOnly } }

    private func haptic() { UIImpactFeedbackGenerator(style: .light).impactOccurred() }

    private func toggle(_ id: UUID) {
        if selected.contains(id) { selected.remove(id) } else { selected.insert(id) }
        haptic()
    }

    private func startTouch(_ id: UUID) {
        if !selecting { withAnimation(.easeOut(duration: 0.2)) { selecting = true } }
        dragBase = selected
        let ids = shown.map(\.id)
        dragAnchor = ids.firstIndex(of: id) ?? 0
        if !selected.contains(id) { selected.insert(id); haptic() }
    }

    /// 手指在 y：划过的从按下那条到这一条都选上；往回划，退掉的不选
    private func moveTouch(_ y: CGFloat) {
        dragY = y
        let ids = shown.map(\.id)
        let seen = ids.enumerated().compactMap { i, id in rowFrames[id].map { (i, $0) } }
        guard let at = BatchSelect.index(atY: Double(y), frames: seen.map { (minY: Double($0.1.minY), maxY: Double($0.1.maxY)) }) else { return }
        let current = seen[at].0
        let next = BatchSelect.selection(base: dragBase, order: ids, anchor: dragAnchor, current: current)
        if next != selected {
            if next.count > selected.count { haptic() }
            selected = next
        }
        autoScroll = y < 90 ? -1 : (y > listHeight - 90 ? 1 : 0)
    }

    private func endTouch() { autoScroll = 0 }

    /// 手指在边缘时，列表往那边滚一条
    private func scrollStep(_ proxy: ScrollViewProxy) {
        let ids = shown.map(\.id)
        let visible = ids.enumerated().filter { rowFrames[$0.element] != nil }
        guard let first = visible.first, let last = visible.last else { return }
        if autoScroll > 0, last.offset + 1 < ids.count {
            withAnimation(.easeOut(duration: 0.12)) { proxy.scrollTo(ids[last.offset + 1], anchor: .bottom) }
        } else if autoScroll < 0, first.offset > 0 {
            withAnimation(.easeOut(duration: 0.12)) { proxy.scrollTo(ids[first.offset - 1], anchor: .top) }
        }
    }

    private func endSelecting() {
        withAnimation(.easeOut(duration: 0.2)) { selecting = false }
        selected = []
        rowFrames = [:]
        autoScroll = 0
    }

    private func trashSelected() {
        let picked = shown.filter { selected.contains($0.id) }
        endSelecting()
        app.deleteMany(picked)
    }

    private func moveSelected(to f: Folder?) {
        for n in shown where selected.contains(n.id) { n.folder = f; app.changed(n) }
        endSelecting()
    }

    private func closeTools() {
        withAnimation(.easeOut(duration: 0.2)) { showTools = false }
    }

    /// 工具箱里点一格：先收面板，再打开它
    private func openTool(_ tool: Tool) {
        closeTools()
        switch tool {
        case .listen: app.listening = ListenOpen()
        case .settings: app.path.append(.settings)
        case .companion:
            if !broadcast.fire() { app.show(t.t("companion.noPanel")) }
        case .deep:
            app.companion.toggleDeep()
        }
    }

    private func togglePin(_ n: Note) {
        withAnimation(.easeOut(duration: 0.24)) { n.pinned.toggle() }
        app.changed(n)
    }

}

/// 长按之后手指还没抬：按的是哪条、手指在哪（y 在列表里的位置）
struct SelTouch: Equatable {
    var id: UUID
    var y: CGFloat?
}

struct RowFrames: PreferenceKey {
    static var defaultValue: [UUID: CGRect] = [:]
    static func reduce(value: inout [UUID: CGRect], nextValue: () -> [UUID: CGRect]) {
        value.merge(nextValue()) { $1 }
    }
}

/// 纸条：灰白纸、左边一颗小木钉、底下一道浅影
struct NoteStrip: View {
    let note: Note
    @Environment(AppModel.self) private var app

    var body: some View {
        let title = note.title
        let summary = note.summary
        HStack(alignment: .top, spacing: 10) {
            WoodPeg().padding(.top, -4)
            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    if note.pinned {
                        Image(systemName: "pin.fill").font(.system(size: 11)).foregroundStyle(Color(Ink.accent))
                    }
                    Text(title.isEmpty ? app.lang.t("note.untitled") : title)
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(Color(title.isEmpty ? Ink.text3 : Ink.text))
                        .lineLimit(1)
                }
                if !summary.isEmpty {
                    Text(summary)
                        .font(.system(size: 14))
                        .foregroundStyle(Color(Ink.text2))
                        .lineLimit(2)
                        .lineSpacing(2)
                }
                HStack(spacing: 8) {
                    if note.kind == "photo" { Image(systemName: "camera").font(.system(size: 11)) }
                    if !note.audioPaths.isEmpty { Image(systemName: "waveform").font(.system(size: 11)) }
                    if note.inListen { Image(systemName: "headphones").font(.system(size: 11)).foregroundStyle(Color(Ink.accent)) }
                    if !note.originalPaths.isEmpty || !Markdown5.imagePaths(note.markdown).isEmpty { Image(systemName: "photo").font(.system(size: 11)) }
                    ButlerMark(note: note)
                    Spacer(minLength: 0)
                    Text(When.short(note.modifiedAt, app.lang))
                        .font(.system(size: 12).monospacedDigit())
                }
                .foregroundStyle(Color(Ink.text3))
                .padding(.top, 2)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.leading, 6)
        .padding(.trailing, 14)
        .padding(.vertical, 12)
        .background {
            ZStack(alignment: .bottom) {
                PaperBackground(tint: note.tint)
                Rectangle().fill(Color(Ink.paperEdge)).frame(height: 1)
            }
            .clipShape(RoundedRectangle(cornerRadius: 3, style: .continuous))
            .shadow(color: Color(red: 0.27, green: 0.16, blue: 0.06).opacity(0.22), radius: 2.5, x: 0, y: 1.5)
        }
        .lightIf(note.tint.keepsLight)
    }
}

/// 列表里纸条上的大管家小记号
struct ButlerMark: View {
    let note: Note
    @Environment(AppModel.self) private var app
    var body: some View {
        let s = note.butlerState
        switch s.phase {
        case .waiting:
            // 大管家没连上：写「排队」、标红，不再假装「在理」
            if app.butler.presence.isHere {
                Label(app.lang.t("butler.short.waiting"), systemImage: "hourglass").labelStyle(.titleAndIcon).font(.system(size: 11))
            } else {
                Label(app.lang.t("butler.short.queued"), systemImage: "hourglass").labelStyle(.titleAndIcon).font(.system(size: 11))
                    .foregroundStyle(Color(Ink.danger))
            }
        case .offer: Label(app.lang.t("butler.short.offer"), systemImage: "sparkles").font(.system(size: 11)).foregroundStyle(Color(Ink.accent))
        case .failed: Image(systemName: "exclamationmark.circle").font(.system(size: 11)).foregroundStyle(Color(Ink.danger))
        default: EmptyView()
        }
    }
}

struct StripButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.985 : 1)
            .brightness(configuration.isPressed ? -0.02 : 0)
            .animation(.easeOut(duration: 0.2), value: configuration.isPressed)
    }
}

struct SearchField: View {
    @Binding var text: String
    let placeholder: String
    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass").foregroundStyle(Color(Ink.text3))
            TextField(placeholder, text: $text)
                .font(.system(size: 15))
                .foregroundStyle(Color(Ink.text))
                .submitLabel(.search)
                .focused($focused)
            if !text.isEmpty {
                Button { text = "" } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(Color(Ink.text3)) }
                    .buttonStyle(.plain)
                    .hit44()
            }
        }
        .padding(.horizontal, 12)
        .frame(height: 36)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color(Ink.paper).opacity(0.85)))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Color(Ink.paperEdge), lineWidth: 0.75))
        .padding(.horizontal, 12)
        .padding(.top, 10)
        .padding(.bottom, 4)
    }
}

/// 第一次打开问一次：一句话加一个按钮，能跳过
struct MirrorPrompt: View {
    @Environment(AppModel.self) private var app
    let choose: () -> Void
    let skip: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(app.lang.t("mirror.ask"))
                .font(.system(size: 15))
                .foregroundStyle(Color(Ink.text))
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 12) {
                Button(app.lang.t("mirror.choose")) { choose() }
                    .buttonStyle(SmartButtonStyle(prominent: true))
                Button(app.lang.t("mirror.skip")) { skip() }
                    .buttonStyle(PlainTextButtonStyle(color: Ink.text2))
                Spacer()
            }
        }
        .padding(16)
        .background(PaperBackground().clipShape(RoundedRectangle(cornerRadius: 4)).shadow(color: .black.opacity(0.15), radius: 2, y: 1))
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
    }
}

struct EmptyList: View {
    @Environment(AppModel.self) private var app
    let searching: Bool
    let newNote: () -> Void
    let camera: () -> Void

    var body: some View {
        VStack(spacing: 16) {
            Spacer()
            Text(searching ? app.lang.t("list.noHit") : app.lang.t("list.empty"))
                .font(.system(size: 17))
                .foregroundStyle(Color(Ink.text2))
                .multilineTextAlignment(.center)
            if !searching {
                HStack(spacing: 12) {
                    Button(app.lang.t("list.new")) { newNote() }.buttonStyle(SmartButtonStyle(prominent: true))
                    Button(app.lang.t("capture.camera")) { camera() }.buttonStyle(SmartButtonStyle())
                    Button(app.lang.t("voice.title")) { app.startVoice() }.buttonStyle(SmartButtonStyle())
                }
            }
            Spacer()
            Spacer()
        }
        .frame(maxWidth: .infinity)
        .padding(32)
    }
}

/// 时间：今天只写几点，今年写月日，再早写年月日
@MainActor
enum When {
    static func short(_ d: Date, _ lang: Lang) -> String {
        let cal = Calendar.current
        let f = DateFormatter()
        f.locale = lang.locale
        if cal.isDateInToday(d) { f.setLocalizedDateFormatFromTemplate("jmm") }
        else if cal.isDateInYesterday(d) { return lang.t("time.yesterday") }
        else if cal.component(.year, from: d) == cal.component(.year, from: Date()) { f.setLocalizedDateFormatFromTemplate("MMMd") }
        else { f.setLocalizedDateFormatFromTemplate("yMMMd") }
        return f.string(from: d)
    }

    /// 几点几分；不是今天的带上日期（「上次在线」用）
    static func clock(_ d: Date, _ lang: Lang) -> String {
        let f = DateFormatter()
        f.locale = lang.locale
        f.setLocalizedDateFormatFromTemplate(Calendar.current.isDateInToday(d) ? "jmm" : "MMMdjmm")
        return f.string(from: d)
    }

    static func long(_ d: Date, _ lang: Lang) -> String {
        let f = DateFormatter()
        f.locale = lang.locale
        f.setLocalizedDateFormatFromTemplate(lang.isZh ? "MMMdEEEjmm" : "EEEMMMdjmm")
        return f.string(from: d)
    }
}
