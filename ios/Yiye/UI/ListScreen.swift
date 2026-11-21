import SwiftUI
import SwiftData
import PhotosUI
import YiyeKit

/// 列表：一条笔记一张纸条（第一行当标题，下面一两行摘要，加时间）。置顶的在最上面。左滑删除带撤销
struct ListScreen: View {
    @Environment(AppModel.self) private var app
    @Query(filter: #Predicate<Note> { $0.trashed == false }, sort: \Note.modifiedAt, order: .reverse) private var notes: [Note]
    @Query(sort: \Folder.order) private var folders: [Folder]
    @State private var query = ""
    @State private var showFolders = false
    @State private var pickedItem: PhotosPickerItem?
    @State private var showCamera = false
    @State private var showMirrorPicker = false

    private var t: Lang { app.lang }

    private var currentFolder: Folder? { folders.first { $0.id.uuidString == app.settings.folderID } }

    private var shown: [Note] {
        var xs = notes
        if let f = currentFolder { xs = xs.filter { $0.folder?.id == f.id } }
        let q = query.trimmed
        if !q.isEmpty { xs = xs.filter { $0.markdown.localizedCaseInsensitiveContains(q) } }
        switch app.settings.sort {
        case .modifiedNew: xs.sort { $0.modifiedAt > $1.modifiedAt }
        case .modifiedOld: xs.sort { $0.modifiedAt < $1.modifiedAt }
        case .created: xs.sort { $0.createdAt > $1.createdAt }
        }
        return xs.filter(\.pinned) + xs.filter { !$0.pinned }
    }

    var body: some View {
        VStack(spacing: 0) {
            SmartBar {
                Button { app.path.append(.settings) } label: { Image(systemName: "gearshape") }
                    .buttonStyle(SmartButtonStyle())
                    .accessibilityLabel(t.t("settings.title"))
                Button { app.listening = ListenOpen() } label: { Image(systemName: "headphones") }
                    .buttonStyle(SmartButtonStyle())
                    .accessibilityLabel(t.t("listen.title"))
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
                    PhotosPicker(selection: $pickedItem, matching: .images) {
                        Label(t.t("capture.fromAlbum"), systemImage: "photo.on.rectangle")
                    }
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
                    PhotosPicker(selection: $pickedItem, matching: .images) {
                        Label(t.t("capture.library"), systemImage: "photo.on.rectangle")
                    }
                } label: {
                    Image(systemName: "plus")
                } primaryAction: {
                    app.newNote()
                }
                .menuStyle(.button)
                .buttonStyle(SmartButtonStyle())
                .accessibilityLabel(t.t("list.new"))
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
                List {
                    ForEach(shown) { n in
                        Button { app.path.append(.editor(n.id)) } label: { NoteStrip(note: n) }
                            .buttonStyle(StripButtonStyle())
                            .listRowInsets(EdgeInsets(top: 5, leading: 12, bottom: 5, trailing: 12))
                            .listRowBackground(Color.clear)
                            .listRowSeparator(.hidden)
                            .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                                Button(role: .destructive) { app.delete(n) } label: { Label(t.t("note.delete"), systemImage: "trash") }
                            }
                            .swipeActions(edge: .leading, allowsFullSwipe: true) {
                                Button { togglePin(n) } label: { Label(n.pinned ? t.t("note.unpin") : t.t("note.pin"), systemImage: n.pinned ? "pin.slash" : "pin") }
                                    .tint(Color(Ink.accent))
                            }
                            .contextMenu {
                                Button { togglePin(n) } label: { Label(n.pinned ? t.t("note.unpin") : t.t("note.pin"), systemImage: "pin") }
                                Menu {
                                    Button(t.t("list.all")) { move(n, to: nil) }
                                    ForEach(folders) { f in Button(f.name) { move(n, to: f) } }
                                } label: { Label(t.t("note.move"), systemImage: "folder") }
                                Button(role: .destructive) { app.delete(n) } label: { Label(t.t("note.delete"), systemImage: "trash") }
                            }
                    }
                    Color.clear.frame(height: 40).listRowBackground(Color.clear).listRowSeparator(.hidden)
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
                .scrollDismissesKeyboard(.immediately)
            }
        }
        .background(DeskBackground())
        .toolbar(.hidden, for: .navigationBar)
        .sheet(isPresented: $showFolders) { FolderSheet().presentationDetents([.medium, .large]) }
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

    private func togglePin(_ n: Note) {
        withAnimation(.easeOut(duration: 0.24)) { n.pinned.toggle() }
        app.changed(n)
    }

    private func move(_ n: Note, to f: Folder?) {
        n.folder = f
        app.changed(n)
    }
}

/// 纸条：灰白纸、左边一枚回形针、底下一道浅影
struct NoteStrip: View {
    let note: Note
    @Environment(AppModel.self) private var app

    var body: some View {
        let title = note.title
        let summary = note.summary
        HStack(alignment: .top, spacing: 10) {
            PaperClip().padding(.top, -6)
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
    }
}

/// 列表里纸条上的大管家小记号
struct ButlerMark: View {
    let note: Note
    @Environment(AppModel.self) private var app
    var body: some View {
        let s = note.butlerState
        switch s.phase {
        case .waiting: Label(app.lang.t("butler.short.waiting"), systemImage: "hourglass").labelStyle(.titleAndIcon).font(.system(size: 11))
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

    static func long(_ d: Date, _ lang: Lang) -> String {
        let f = DateFormatter()
        f.locale = lang.locale
        f.setLocalizedDateFormatFromTemplate(lang.isZh ? "MMMdEEEjmm" : "EEEMMMdjmm")
        return f.string(from: d)
    }
}
