import SwiftUI
import SwiftData
import PhotosUI
import YiyeKit

/// 写字页：横线信纸 + 底下一条五招工具条（键盘弹出来时它跟着键盘走）
struct EditorScreen: View {
    let noteID: UUID
    @Environment(AppModel.self) private var app
    @State private var note: Note?
    @State private var controller = EditorController()
    @State private var focused = false
    @State private var showShare = false
    @State private var showCamera = false
    @State private var showOriginals = false
    /// 相册里挑的：插进正文的图 / 要认字的图
    @State private var insertItem: PhotosPickerItem?
    @State private var ocrItem: PhotosPickerItem?
    /// 相册认字：菜单里放 PhotosPicker 点了没反应（Song 11-22），菜单里放普通按钮，再从这儿打开相册
    @State private var showOCRAlbum = false
    @State private var saveTask: Task<Void, Never>?
    @State private var loaded = false

    enum PickerMode: Identifiable { case insert, ocr; var id: Int { self == .insert ? 0 : 1 } }

    private var t: Lang { app.lang }

    var body: some View {
        VStack(spacing: 0) {
            SmartBar {
                Button { close() } label: {
                    HStack(spacing: 2) {
                        Image(systemName: "chevron.left").font(.system(size: 14, weight: .semibold))
                        Text(t.t("editor.back"))
                    }
                }
                .buttonStyle(SmartButtonStyle())
            } center: {
                if let note {
                    Text(When.long(note.modifiedAt, t))
                        .font(.system(size: 13).monospacedDigit())
                        .foregroundStyle(Color(Ink.text3))
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                }
            } right: {
                Button { flush(); showShare = true } label: { Image(systemName: "paperplane") }
                    .buttonStyle(SmartButtonStyle())
                    .accessibilityLabel(t.t("share.title"))
                menu
            }

            VStack(spacing: 0) {
                if let note, note.butlerState.phase != .none {
                    ButlerBanner(note: note)
                        .transition(.move(edge: .top).combined(with: .opacity))
                }

                if let note, !note.audioPaths.isEmpty || !note.dub.isEmpty {
                    AudioStrip(note: note)
                }

                NoteTextEditor(controller: controller)
            }
            .background(PaperBackground(tint: note?.tint ?? .white))
            .lightIf(note?.tint.keepsLight == true)

            MarkdownBar(focused: focused, apply: { controller.apply($0) },
                        insertItem: $insertItem,
                        gap: app.settings.imageGap,
                        toggleGap: toggleGap,
                        album: { flush(); showOCRAlbum = true },
                        camera: { flush(); showCamera = true },
                        voice: { flush(); if let note { app.startVoice(.into(note.id, controller.caretInMarkdown() ?? note.markdown.u16)) } },
                        done: { controller.endEditing() })
        }
        .background(PaperBackground(tint: note?.tint ?? .white).lightIf(note?.tint.keepsLight == true).ignoresSafeArea())
        .toolbar(.hidden, for: .navigationBar)
        .animation(.easeOut(duration: 0.24), value: note?.butlerState.phase)
        .onAppear(perform: setUp)
        .onDisappear(perform: tearDown)
        .onReceive(NotificationCenter.default.publisher(for: .yiyeNoteReplaced)) { msg in
            guard let id = msg.object as? UUID, id == noteID, let note else { return }
            controller.load(markdown: note.markdown, unsure: note.unsureRanges)
        }
        .onChange(of: app.settings.fontSize) { _, v in controller.setMetrics(EditorMetrics.of(v)) }
        .onChange(of: insertItem) { _, item in
            guard let item else { return }
            insertItem = nil
            app.loadPicked(item) { img in handlePicked(img, mode: .insert) }
        }
        .photosPicker(isPresented: $showOCRAlbum, selection: $ocrItem, matching: .images)
        .onChange(of: ocrItem) { _, item in
            guard let item else { return }
            ocrItem = nil
            flush()
            app.loadPicked(item) { img in handlePicked(img, mode: .ocr) }
        }
        .fullScreenCover(isPresented: $showShare) {
            if let note { ShareScreen(note: note, initialTheme: app.demo?.shareTheme ?? "note") }
        }
        .fullScreenCover(isPresented: $showCamera) {
            CameraFlow { img in
                showCamera = false
                if let img, let note { app.recognize(img, into: note, at: controller.caretInMarkdown()) }
            }
            .ignoresSafeArea()
        }
        .sheet(isPresented: $showOriginals) {
            if let note { OriginalsViewer(paths: note.originalPaths) }
        }
    }

    // ---------------------------------------------------------------- 菜单
    private var menu: some View {
        Menu {
            if let note {
                Menu {
                    ForEach(PaperTint.allCases) { p in
                        Button { setPaper(p) } label: {
                            if note.tint == p { Label(t.t(p.key), systemImage: "checkmark") } else { Text(t.t(p.key)) }
                        }
                    }
                } label: { Label(t.t("editor.paper"), systemImage: "paintpalette") }
                if !note.originalPaths.isEmpty {
                    Button { showOriginals = true } label: { Label(t.t("editor.original"), systemImage: "photo") }
                }
                Button { flush(); app.butler.submit(note) } label: { Label(t.t("editor.toButler"), systemImage: "wand.and.stars") }
                Menu {
                    Button { flush(); app.toggleListen(note) } label: {
                        Label(note.inListen ? t.t("listen.remove") : t.t("listen.add"), systemImage: note.inListen ? "minus.circle" : "plus.circle")
                    }
                    Button { flush(); app.dub(note) } label: { Label(t.t("listen.dub"), systemImage: "waveform.badge.mic") }
                    Button { flush(); app.speak(note) } label: { Label(t.t("listen.speak"), systemImage: "speaker.wave.2") }
                } label: { Label(t.t("listen.title"), systemImage: "headphones") }
                Button { flush(); showOCRAlbum = true } label: {
                    Label(t.t("capture.libraryInto"), systemImage: "text.viewfinder")
                }
                Button { togglePin() } label: { Label(note.pinned ? t.t("note.unpin") : t.t("note.pin"), systemImage: "pin") }
                FolderMenu(note: note)
                Button(role: .destructive) { deleteNote() } label: { Label(t.t("note.delete"), systemImage: "trash") }
            }
        } label: {
            Image(systemName: "ellipsis")
        }
        .menuStyle(.button)
        .buttonStyle(SmartButtonStyle())
        .accessibilityLabel(t.t("editor.more"))
    }

    // ---------------------------------------------------------------- 生命周期
    private func setUp() {
        guard !loaded else { return }
        loaded = true
        guard let n = app.note(noteID) else { return }
        note = n
        controller.store = app.attachments
        controller.setMetrics(EditorMetrics.of(app.settings.fontSize))
        _ = controller.makeView()
        controller.setForceLight(n.tint.keepsLight)
        controller.load(markdown: n.markdown, unsure: n.unsureRanges)
        controller.onChange = { scheduleSave() }
        controller.onFocus = { f in withAnimation(.easeOut(duration: 0.2)) { focused = f } }
        controller.wordTitles = (app.t.t("word.markKnown"), app.t.t("word.markLearning"))
        let nid = n.id
        controller.onWord = { w, m in app.markWord(w, m, note: nid) }
        if app.freshNoteID == n.id {
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 350_000_000)
                controller.focus()
            }
        }
        if let d = app.demo, d.screen.hasPrefix("share") {
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 300_000_000)
                showShare = true
            }
        }
    }

    private func tearDown() {
        guard let note, !showShare, !showCamera, !showOriginals, app.voiceTarget == nil, app.busy == nil else { return }
        flush()
        app.leave(note)
    }

    private func scheduleSave() {
        saveTask?.cancel()
        saveTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 400_000_000)
            if !Task.isCancelled { flush() }
        }
    }

    /// 写字页的字 → 笔记（只在真变了时改「改的时间」）
    private func flush() {
        saveTask?.cancel()
        guard let note else { return }
        let cur = controller.current()
        let unsure = RangeCodec.encode(cur.unsure)
        guard cur.markdown != note.markdown || unsure != note.unsure else { return }
        note.markdown = cur.markdown
        note.unsure = unsure
        app.changed(note)
    }

    private func close() {
        flush()
        if !app.path.isEmpty { app.path.removeLast() }
    }

    private func handlePicked(_ img: UIImage, mode: PickerMode) {
        guard let note else { return }
        switch mode {
        case .insert:
            guard let data = AttachmentStore.jpeg(Capture.upright(img)),
                  let rel = try? app.attachments.save(data, name: AttachmentStore.newName(for: note.id)) else { return }
            controller.insertImage(path: rel, gap: app.settings.imageGap)
            flush()
        case .ocr:
            flush()
            app.recognize(img, into: note, at: controller.caretInMarkdown())
        }
    }

    /// 图片间距键：空一格 ⇄ 靠拢。这条笔记里的图当场重排，以后插的图也照这个
    private func toggleGap() {
        app.settings.imageGap.toggle()
        let gap = app.settings.imageGap
        controller.respaceImages(gap: gap)
        flush()
        app.show(gap ? t.t("md.spacingGap") : t.t("md.spacingSnug"), seconds: 2)
    }

    private func setPaper(_ p: PaperTint) {
        guard let note else { return }
        withAnimation(.easeOut(duration: 0.24)) { note.paper = p.rawValue }
        controller.setForceLight(p.keepsLight)
        app.changed(note)
    }

    private func togglePin() {
        guard let note else { return }
        note.pinned.toggle()
        app.changed(note)
    }

    private func deleteNote() {
        guard let note else { return }
        flush()
        loaded = false
        self.note = nil
        if !app.path.isEmpty { app.path.removeLast() }
        app.delete(note)
    }
}

/// 挪到文件夹
struct FolderMenu: View {
    let note: Note
    @Environment(AppModel.self) private var app
    @Query(sort: \Folder.order) private var folders: [Folder]

    var body: some View {
        Menu {
            Button { move(nil) } label: {
                if note.folder == nil { Label(app.lang.t("list.all"), systemImage: "checkmark") } else { Text(app.lang.t("list.all")) }
            }
            ForEach(folders) { f in
                Button { move(f) } label: {
                    if note.folder?.id == f.id { Label(f.name, systemImage: "checkmark") } else { Text(f.name) }
                }
            }
        } label: { Label(app.lang.t("note.move"), systemImage: "folder") }
    }

    private func move(_ f: Folder?) {
        note.folder = f
        app.changed(note)
    }
}

/// 五招工具条 + 插图、拍照认字；键盘弹着时多一个收键盘
struct MarkdownBar: View {
    let focused: Bool
    let apply: (MDCommand) -> Void
    @Binding var insertItem: PhotosPickerItem?
    /// 图片间距：true 空一格，false 靠拢
    let gap: Bool
    let toggleGap: () -> Void
    let album: () -> Void
    let camera: () -> Void
    let voice: () -> Void
    let done: () -> Void
    @Environment(AppModel.self) private var app

    var body: some View {
        HStack(spacing: 0) {
            key("H", label: app.lang.t("md.heading")) { apply(.heading) }
            key(symbol: "list.bullet", label: app.lang.t("md.list")) { apply(.bullet) }
            key("B", bold: true, label: app.lang.t("md.bold")) { apply(.bold) }
            key(symbol: "text.quote", label: app.lang.t("md.quote")) { apply(.quote) }
            key(symbol: "text.aligncenter", label: app.lang.t("md.center")) { apply(.center) }
            Rectangle().fill(Color(Ink.barLine)).frame(width: 0.5, height: 22).padding(.horizontal, 2)
            PhotosPicker(selection: $insertItem, matching: .images) { keyFace(symbol: "photo") }
                .buttonStyle(KeyStyle())
                .accessibilityLabel(app.lang.t("md.image"))
            Button(action: toggleGap) { spacingFace }
                .buttonStyle(KeyStyle())
                .accessibilityLabel(app.lang.t("md.spacing"))
                .accessibilityValue(gap ? app.lang.t("md.spacingGap") : app.lang.t("md.spacingSnug"))
            Menu {
                Button { camera() } label: { Label(app.lang.t("capture.shootPage"), systemImage: "camera") }
                Button { album() } label: { Label(app.lang.t("capture.fromAlbum"), systemImage: "photo.on.rectangle") }
            } label: {
                keyFace(symbol: "camera")
            }
            .menuStyle(.button)
            .buttonStyle(KeyStyle())
            .accessibilityLabel(app.lang.t("capture.camera"))
            key(symbol: "mic", label: app.lang.t("voice.title")) { voice() }
            if focused {
                key(symbol: "keyboard.chevron.compact.down", label: app.lang.t("md.done")) { done() }
            }
        }
        .padding(.horizontal, 4)
        .frame(height: 48)
        .frame(maxWidth: .infinity)
        .background {
            ZStack(alignment: .top) {
                LinearGradient(colors: [Color(Ink.barTop), Color(Ink.barBottom)], startPoint: .top, endPoint: .bottom)
                Rectangle().fill(Color(Ink.barLine)).frame(height: 0.5)
            }
            .ignoresSafeArea(edges: .bottom)
        }
    }

    /// 图片间距键：两张小图，空一格时中间隔开，靠拢时挨着
    private var spacingFace: some View {
        VStack(spacing: gap ? 5 : 1.5) {
            RoundedRectangle(cornerRadius: 2).stroke(lineWidth: 1.5).frame(width: 18, height: 7)
            RoundedRectangle(cornerRadius: 2).stroke(lineWidth: 1.5).frame(width: 18, height: 7)
        }
        .foregroundStyle(Color(Ink.text2))
        .animation(.easeOut(duration: 0.2), value: gap)
        .frame(maxWidth: .infinity, minHeight: 44)
        .contentShape(Rectangle())
    }

    /// 只有图标的键面（相册、拍照那两个不是普通按钮，用同一个样子）
    private func keyFace(symbol: String) -> some View {
        Image(systemName: symbol).font(.system(size: 17))
            .foregroundStyle(Color(Ink.text2))
            .frame(maxWidth: .infinity, minHeight: 44)
            .contentShape(Rectangle())
    }

    private func key(_ text: String = "", symbol: String? = nil, bold: Bool = false, label: String, _ run: @escaping () -> Void) -> some View {
        Button(action: run) {
            Group {
                if let symbol { Image(systemName: symbol).font(.system(size: 17)) }
                else { Text(text).font(.system(size: 18, weight: bold ? .heavy : .semibold, design: .serif)) }
            }
            .foregroundStyle(Color(Ink.text2))
            .frame(maxWidth: .infinity, minHeight: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(KeyStyle())
        .accessibilityLabel(label)
    }
}

struct KeyStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(RoundedRectangle(cornerRadius: 6).fill(Color(Ink.btnPressed).opacity(configuration.isPressed ? 1 : 0)))
            .animation(.easeOut(duration: 0.2), value: configuration.isPressed)
    }
}
