import SwiftUI
import SwiftData
import PhotosUI
import UIKit
import UIKit.UIGestureRecognizerSubclass
import YiyeKit

/// 列表：一条笔记一张纸条（第一行当标题，下面一两行摘要，加时间）。置顶的在最上面。
/// 右滑扔进废纸篓（留 3 天，底下给撤销）；左滑置顶、小耳机；长按一条进批量选，手指不抬往上往下划，划过的都选上。
/// 长按（133）：不挂 SwiftUI 手势（0.7.8–0.7.12 的高优先长按把点按和左右滑都压住了），挂在列表底下的 UICollectionView 上，见 NoteListPress。
/// 批量选里沿左边那一条（圆圈连同小木钉）往上往下划（135）：起手那条没选，划过的都选上；选了的，划过的都取消。见 NoteListSweep。
/// 右滑扔（160）：拖过纸条宽的七成松手就扔，不用拉满、不用再点按钮。也挂在 UICollectionView 上，见 NoteListSwipe。
struct ListScreen: View {
    @Environment(AppModel.self) private var app
    @Query(filter: #Predicate<Note> { $0.trashed == false && $0.kind != "listen" }, sort: \Note.modifiedAt, order: .reverse) private var notes: [Note]
    @Query(sort: \Folder.order) private var folders: [Folder]
    /// 157：还没听过的听力稿（大管家送来、还没完整放过一遍的）：顶栏「听力」右上角一个小点
    @Query(filter: #Predicate<Note> { $0.trashed == false && $0.kind == "listen" && $0.heardAt == nil }) private var unheard: [Note]
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
    @State private var dragBase: Set<UUID> = []
    @State private var dragAnchor = 0
    /// 长按起来的时刻（松手变回 nil）；松手的时刻。松手那一下按钮要是也算一次点按，就不理它（133）
    @State private var pressBeganAt: Date?
    @State private var pressEndedAt = Date.distantPast
    /// 沿左边那一条划（135）：这一划是在选（起手那条原来没选）还是在取消
    @State private var sweepAdds = true

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
            SmartBar(centerInset: Narrow.on ? 140 : 104) {      // 157：窄屏中间只给两边按钮之间那一段（长的文件夹名先缩小再省略，不压按钮）
                ToolboxButton(trigger: broadcast) {
                    withAnimation(.easeOut(duration: 0.2)) { showTools.toggle() }
                }
                // 136 书童：一点，从下面升起半屏聊天窗；250：建过别的机器人、群，点开先是名单（只有小书童一个就直接进它）
                Button { BotsModel.shared.openFromBar() } label: { Image(systemName: "studentdesk") }
                    .buttonStyle(SmartButtonStyle(compact: Narrow.on))
                    .accessibilityLabel(t.t("shutong.name"))
                // 157 听力（Song 11-25「把听力放出来，经常用」）：一点直接进；有没听过的新稿子，右上角一个小点
                let fresh = unheard.contains { $0.listenPath != nil }
                Button { app.listening = ListenOpen() } label: {
                    Image(systemName: "headphones")
                        .overlay(alignment: .topTrailing) {
                            if fresh {
                                Circle().fill(Color(Ink.accent))
                                    .frame(width: 8, height: 8)
                                    .overlay(Circle().strokeBorder(Color(Ink.btnTop), lineWidth: 1.5))
                                    .offset(x: 6, y: -5)
                            }
                        }
                }
                .buttonStyle(SmartButtonStyle(compact: Narrow.on))
                .accessibilityLabel(t.t("listen.title"))
                .accessibilityValue(fresh ? t.t("listen.fresh") : "")
                .accessibilityIdentifier("bar.listen")
            } center: {
                Button { showFolders = true } label: {
                    HStack(spacing: 5) {
                        BarTitle(text: currentFolder?.name ?? t.t("list.all"), size: Narrow.on ? 15 : 17)
                        Image(systemName: "chevron.down")
                            .font(.system(size: Narrow.on ? 10 : 11, weight: .bold))
                            .foregroundStyle(Color(Ink.text3))
                    }
                    .hit44()
                }
                .buttonStyle(.plain)
            } right: {
                Button { app.startVoice() } label: { Image(systemName: "mic") }
                    .buttonStyle(SmartButtonStyle(compact: Narrow.on))
                    .accessibilityLabel(t.t("voice.title"))
                Menu {
                    Button { startCamera() } label: { Label(t.t("capture.shootPage"), systemImage: "camera") }
                    Button { showAlbum = true } label: { Label(t.t("capture.fromAlbum"), systemImage: "photo.on.rectangle") }
                } label: {
                    Image(systemName: "camera")
                }
                .menuStyle(.button)
                .buttonStyle(SmartButtonStyle(compact: Narrow.on))
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
                .buttonStyle(SmartButtonStyle(compact: Narrow.on))
                .accessibilityLabel(t.t("list.new"))
            }
            }

            SearchField(text: $query, placeholder: t.t("list.search"))

            if !selecting, let slip = ShutongModel.shared.slip {              // 136：周日的清理建议，不点就当没看见
                ShutongSlip(slip: slip)
                    .transition(.move(edge: .top).combined(with: .opacity))
            }

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
                        row(n)
                    }
                    Color.clear.frame(height: selecting ? 90 : 40).listRowBackground(Color.clear).listRowSeparator(.hidden)
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
                .scrollDismissesKeyboard(.immediately)
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
            // 长按着、或者刚松手：这一下是长按的尾巴，不算点（别进了批量选马上被点掉，也别顺手打开）
            if let b = pressBeganAt, Date().timeIntervalSince(b) < 30 { return }
            if Date().timeIntervalSince(pressEndedAt) < 0.25 { return }
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
        .background(RowTag(id: n.id, begin: startTouch, move: moveTouch, end: endTouch,
                           selecting: selecting, sweepBegin: sweepBegin, sweepMove: sweepMove, sweepEnd: endTouch,
                           trash: { id in if let x = app.note(id) { app.delete(x) } }, trashTitle: t.t("trash.swipe")))
        .accessibilityAddTraits(on ? .isSelected : [])
        .accessibilityAction(named: Text(t.t("trash.swipe"))) { if !selecting { app.delete(n) } }   // 160：右滑换成自己的拖，VoiceOver 的「扔」补上
        .listRowInsets(EdgeInsets(top: 5, leading: 12, bottom: 5, trailing: 12))
        .listRowBackground(Color.clear)
        .listRowSeparator(.hidden)
        // 右滑扔（160）不再用系统的 swipeActions（那条线是系统定的，滑一小段停成半开还要再点）：NoteListSwipe
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

    /// 长按 0.4 秒起来了：按的那条进批量选
    private func startTouch(_ id: UUID) {
        pressBeganAt = Date()
        if !selecting { withAnimation(.easeOut(duration: 0.2)) { selecting = true } }
        dragBase = selected
        let ids = shown.map(\.id)
        dragAnchor = ids.firstIndex(of: id) ?? 0
        if !selected.contains(id) { selected.insert(id); haptic() }
    }

    /// 手指（没抬）划到了 id 这条：从按下那条到这一条都选上；往回划，退掉的不选
    private func moveTouch(_ id: UUID) {
        let ids = shown.map(\.id)
        guard let current = ids.firstIndex(of: id) else { return }
        let next = BatchSelect.selection(base: dragBase, order: ids, anchor: dragAnchor, current: current)
        if next != selected {
            if next.count > selected.count { haptic() }
            selected = next
        }
    }

    private func endTouch() {
        pressBeganAt = nil
        pressEndedAt = Date()
    }

    /// 批量选里从左边那一条起手往上往下划（135）：起手那条没选 → 这一划是选；选了 → 这一划是取消（跟苹果邮件一样）
    private func sweepBegin(_ id: UUID) {
        guard selecting else { return }
        let ids = shown.map(\.id)
        guard let at = ids.firstIndex(of: id) else { return }
        dragBase = selected
        dragAnchor = at
        sweepAdds = !selected.contains(id)
        sweepMove(id)
    }

    /// 手指划到了 id 这条：起手那条到这一条都选上（或都取消）；往回划，退掉的回到划之前的样子
    private func sweepMove(_ id: UUID) {
        guard selecting else { return }
        let ids = shown.map(\.id)
        guard let current = ids.firstIndex(of: id) else { return }
        let span = BatchSelect.span(ids, from: dragAnchor, to: current)
        let next = sweepAdds ? dragBase.union(span) : dragBase.subtracting(span)
        if next != selected {
            haptic()
            selected = next
        }
    }

    private func endSelecting() {
        withAnimation(.easeOut(duration: 0.2)) { selecting = false }
        selected = []
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
        case .settings: app.path.append(.settings)
        case .companion:
            if !broadcast.fire() { app.show(t.t("companion.noPanel")) }
        case .deep:
            app.companion.toggleDeep()
        case .dove:
            DoveModel.shared.open = true             // 128：飞鸽传书（RootView 里的 sheet）
        case .remote:
            RemoteModel.shared.open = true           // 172：遥控（RootView 里的 sheet）
        }
    }

    private func togglePin(_ n: Note) {
        withAnimation(.easeOut(duration: 0.24)) { n.pinned.toggle() }
        app.changed(n)
    }

}

// ---------------------------------------------------------------- 长按批量选（133）
/// 每条纸条背后垫一个看不见、不接触摸的小 UIView：记着自己是哪条便签，顺着父视图找到列表底下的 UICollectionView，
/// 给它挂一个长按识别器（一个列表只挂一个）。
struct RowTag: UIViewRepresentable {
    let id: UUID
    let begin: @MainActor (UUID) -> Void
    let move: @MainActor (UUID) -> Void
    let end: @MainActor () -> Void
    /// 135：批量选开着没有；沿左边那一条划的三个回调
    var selecting = false
    var sweepBegin: @MainActor (UUID) -> Void = { _ in }
    var sweepMove: @MainActor (UUID) -> Void = { _ in }
    var sweepEnd: @MainActor () -> Void = {}
    /// 160：右滑过七成松手：扔这条；红底上的字
    var trash: @MainActor (UUID) -> Void = { _ in }
    var trashTitle = ""

    func makeUIView(context: Context) -> RowTagView {
        let v = RowTagView()
        v.isUserInteractionEnabled = false
        v.backgroundColor = .clear
        return v
    }

    func updateUIView(_ v: RowTagView, context: Context) {
        v.noteID = id
        v.begin = begin
        v.move = move
        v.end = end
        v.selecting = selecting
        v.sweepBegin = sweepBegin
        v.sweepMove = sweepMove
        v.sweepEnd = sweepEnd
        v.trash = trash
        v.trashTitle = trashTitle
        v.install()
    }
}

final class RowTagView: UIView {
    var noteID: UUID?
    var begin: (@MainActor (UUID) -> Void)?
    var move: (@MainActor (UUID) -> Void)?
    var end: (@MainActor () -> Void)?
    var selecting = false
    var sweepBegin: (@MainActor (UUID) -> Void)?
    var sweepMove: (@MainActor (UUID) -> Void)?
    var sweepEnd: (@MainActor () -> Void)?
    var trash: (@MainActor (UUID) -> Void)?
    var trashTitle = ""

    override func didMoveToWindow() {
        super.didMoveToWindow()
        install()
    }

    /// 找到列表，挂上（挂过就只把最新的回调交给它）
    func install() {
        guard window != nil, let begin, let move, let end else { return }
        var v = superview
        while let s = v, !(s is UICollectionView) { v = s.superview }
        guard let cv = v as? UICollectionView else { return }
        let g = NoteListPress.on(cv)
        g.onBegin = begin
        g.onMove = move
        g.onEnd = end
        // 135：沿左边那一条划
        if let sweepBegin, let sweepMove, let sweepEnd {
            let s = NoteListSweep.on(cv)
            s.selecting = selecting
            s.onBegin = sweepBegin
            s.onMove = sweepMove
            s.onEnd = sweepEnd
        }
        // 160：右滑扔
        if let trash {
            let w = NoteListSwipe.on(cv)
            w.selecting = selecting
            w.onTrash = trash
            w.title = trashTitle
            w.demoOnce()
        }
    }

    /// 这一格里垫着的那个
    static func find(in v: UIView) -> RowTagView? {
        if let t = v as? RowTagView { return t }
        for s in v.subviews {
            if let t = find(in: s) { return t }
        }
        return nil
    }
}

/// 列表上的长按：按住 0.4 秒起来，按的那条进批量选；手指不抬往上往下划，划过的都选上；划到上下边缘，列表自己往那边滚。
/// 为什么不用 SwiftUI 手势：0.7.8–0.7.12 在每条纸条上挂 highPriorityGesture(长按→拖)，把按钮的点按和 List 的左右滑都压住了（133）。
/// 这个识别器挂在 UICollectionView 上：手指一动（超过 10 点）它就作废，点按、左右滑、上下滚照常；
/// 起来那一刻 cancelsTouchesInView 把这次触摸从按钮上收走，松手不会再算一次点按（ListScreen 那头另外也挡了一道）。
final class NoteListPress: UILongPressGestureRecognizer, UIGestureRecognizerDelegate {
    var onBegin: @MainActor (UUID) -> Void = { _ in }
    var onMove: @MainActor (UUID) -> Void = { _ in }
    var onEnd: @MainActor () -> Void = {}
    private weak var list: UICollectionView?
    private var link: CADisplayLink?
    private var speed: CGFloat = 0
    private var lastID: UUID?
    private var scrollWas = true
    private var active = false

    static func on(_ cv: UICollectionView) -> NoteListPress {
        if let g = cv.gestureRecognizers?.first(where: { $0 is NoteListPress }) as? NoteListPress { return g }
        let g = NoteListPress(target: nil, action: nil)
        g.list = cv
        g.minimumPressDuration = 0.4
        g.cancelsTouchesInView = true
        g.delegate = g
        g.addTarget(g, action: #selector(NoteListPress.handle))
        cv.addGestureRecognizer(g)
        return g
    }

    /// 手指底下是哪条便签（空白处、最底下垫的那一格：nil）
    private func noteID(at p: CGPoint) -> UUID? {
        guard let cv = list else { return nil }
        if let ip = cv.indexPathForItem(at: p), let cell = cv.cellForItem(at: ip) {
            return RowTagView.find(in: cell)?.noteID
        }
        for cell in cv.visibleCells where cell.frame.contains(p) {
            return RowTagView.find(in: cell)?.noteID
        }
        return nil
    }

    func gestureRecognizerShouldBegin(_ g: UIGestureRecognizer) -> Bool {
        guard g === self, let cv = list else { return true }
        if cv.isDragging || cv.isDecelerating { return false }
        return noteID(at: location(in: cv)) != nil
    }

    /// 按钮自己的识别器照常跑（松手那一下由 cancelsTouchesInView 和 ListScreen 挡掉）；拖动类的（上下滚、左右滑）不能跟长按一起
    func gestureRecognizer(_ g: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
        !(other is UIPanGestureRecognizer)
    }

    @objc private func handle() {
        guard let cv = list else { return }
        switch state {
        case .began:
            guard let id = noteID(at: location(in: cv)) else { return }
            active = true
            lastID = id
            scrollWas = cv.isScrollEnabled
            cv.isScrollEnabled = false
            onBegin(id)
            startLink()
        case .changed:
            guard active else { return }
            follow()
        default:
            guard active else { return }
            active = false
            stopLink()
            cv.isScrollEnabled = scrollWas
            lastID = nil
            onEnd()
        }
    }

    /// 手指到了哪条：选上那一段；离列表上下边缘 80 点以内，越靠边滚得越快
    private func follow() {
        guard let cv = list else { return }
        let p = location(in: cv)
        pick(p)
        let y = p.y - cv.contentOffset.y
        let h = cv.bounds.height
        let edge: CGFloat = 80
        if y < edge { speed = -min(edge, edge - y) / 6 }
        else if y > h - edge { speed = min(edge, y - (h - edge)) / 6 }
        else { speed = 0 }
    }

    private func pick(_ p: CGPoint) {
        guard let id = noteID(at: p), id != lastID else { return }
        lastID = id
        onMove(id)
    }

    private func startLink() {
        link?.invalidate()
        let l = CADisplayLink(target: self, selector: #selector(tick))
        l.add(to: .main, forMode: .common)
        link = l
    }

    private func stopLink() {
        link?.invalidate()
        link = nil
        speed = 0
    }

    @objc private func tick() {
        guard speed != 0, let cv = list else { return }
        let top = -cv.adjustedContentInset.top
        let bottom = max(top, cv.contentSize.height + cv.adjustedContentInset.bottom - cv.bounds.height)
        let y = min(max(cv.contentOffset.y + speed, top), bottom)
        guard y != cv.contentOffset.y else { return }
        cv.contentOffset.y = y
        pick(location(in: cv))
    }
}

// ---------------------------------------------------------------- 沿左边那一条划选（135）
/// 批量选开着时，从左边那一条（圆圈那列连同纸条左边小木钉，离格子左边 stripWidth 点以内）按下、往上往下划：
/// 起手那条没选，划过的都选上；起手那条选了，划过的都取消（ListScreen.sweepBegin 定）。划到上下边缘，列表自己往那边滚，接着选。
/// 跟 133 的长按、点按、左右滑、上下滚怎么不打架：
/// - 没在批量选、或者手指没落在左边那一条上：手指一落下它就作废（touchesBegan 里直接 failed），别的识别器一点不等它；
/// - 列表自己的上下滚要等它作废才动（require(toFail:)）；落在左边那一条上、手指横着走，它也作废，照旧滚；
/// - 它起来了，cancelsTouchesInView 把这次触摸从按钮上收走，松手不算点；长按手指一动超过 10 点自己就作废了。
final class NoteListSweep: UIPanGestureRecognizer, UIGestureRecognizerDelegate {
    /// 左边那一条多宽：行左边距 12 + 圆圈 22 + 间距 10 + 纸条左边距 6 + 小木钉 22 = 72，多给 4 点
    static let stripWidth: CGFloat = 76
    var selecting = false
    var onBegin: @MainActor (UUID) -> Void = { _ in }
    var onMove: @MainActor (UUID) -> Void = { _ in }
    var onEnd: @MainActor () -> Void = {}
    private weak var list: UICollectionView?
    private var link: CADisplayLink?
    private var speed: CGFloat = 0
    private var lastID: UUID?
    private var active = false

    static func on(_ cv: UICollectionView) -> NoteListSweep {
        if let g = cv.gestureRecognizers?.first(where: { $0 is NoteListSweep }) as? NoteListSweep { return g }
        let g = NoteListSweep(target: nil, action: nil)
        g.list = cv
        g.maximumNumberOfTouches = 1
        g.cancelsTouchesInView = true
        g.delegate = g
        g.addTarget(g, action: #selector(NoteListSweep.handle))
        cv.addGestureRecognizer(g)
        cv.panGestureRecognizer.require(toFail: g)
        return g
    }

    /// 这一点落在哪条便签的左边那一条上（不在左边那一条上、空白处：nil）
    private func stripNote(at p: CGPoint) -> UUID? {
        guard let cv = list else { return nil }
        var hit: UICollectionViewCell?
        if let ip = cv.indexPathForItem(at: p) { hit = cv.cellForItem(at: ip) }
        if hit == nil { hit = cv.visibleCells.first { $0.frame.contains(p) } }
        guard let cell = hit, p.x - cell.frame.minX < Self.stripWidth else { return nil }
        return RowTagView.find(in: cell)?.noteID
    }

    /// 手指底下是哪条便签（不管左右）
    private func noteID(at p: CGPoint) -> UUID? {
        guard let cv = list else { return nil }
        if let ip = cv.indexPathForItem(at: p), let cell = cv.cellForItem(at: ip) {
            return RowTagView.find(in: cell)?.noteID
        }
        for cell in cv.visibleCells where cell.frame.contains(p) {
            return RowTagView.find(in: cell)?.noteID
        }
        return nil
    }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent) {
        super.touchesBegan(touches, with: event)
        guard state == .possible else { return }
        guard selecting, let cv = list, let t = touches.first, stripNote(at: t.location(in: cv)) != nil else {
            state = .failed
            return
        }
    }

    func gestureRecognizerShouldBegin(_ g: UIGestureRecognizer) -> Bool {
        guard g === self else { return true }
        guard selecting, let cv = list else { return false }
        let tr = translation(in: cv)
        guard abs(tr.y) >= abs(tr.x) else { return false }                 // 横着走：不是划选
        let start = CGPoint(x: location(in: cv).x - tr.x, y: location(in: cv).y - tr.y)
        return stripNote(at: start) != nil
    }

    @objc private func handle() {
        guard let cv = list else { return }
        switch state {
        case .began:
            let tr = translation(in: cv)
            let p = location(in: cv)
            guard let id = stripNote(at: CGPoint(x: p.x - tr.x, y: p.y - tr.y)) else { return }
            active = true
            lastID = id
            onBegin(id)
            startLink()
            follow()
        case .changed:
            guard active else { return }
            follow()
        default:
            guard active else { return }
            active = false
            stopLink()
            lastID = nil
            onEnd()
        }
    }

    /// 手指到了哪条：起手那条到这一条都选上（或取消）；离列表上下边缘 80 点以内，越靠边滚得越快
    private func follow() {
        guard let cv = list else { return }
        let p = location(in: cv)
        pick(p)
        let y = p.y - cv.contentOffset.y
        let h = cv.bounds.height
        let edge: CGFloat = 80
        if y < edge { speed = -min(edge, edge - y) / 6 }
        else if y > h - edge { speed = min(edge, y - (h - edge)) / 6 }
        else { speed = 0 }
    }

    private func pick(_ p: CGPoint) {
        guard let id = noteID(at: p), id != lastID else { return }
        lastID = id
        onMove(id)
    }

    private func startLink() {
        link?.invalidate()
        let l = CADisplayLink(target: self, selector: #selector(tick))
        l.add(to: .main, forMode: .common)
        link = l
    }

    private func stopLink() {
        link?.invalidate()
        link = nil
        speed = 0
    }

    @objc private func tick() {
        guard speed != 0, let cv = list else { return }
        let top = -cv.adjustedContentInset.top
        let bottom = max(top, cv.contentSize.height + cv.adjustedContentInset.bottom - cv.bounds.height)
        let y = min(max(cv.contentOffset.y + speed, top), bottom)
        guard y != cv.contentOffset.y else { return }
        cv.contentOffset.y = y
        pick(location(in: cv))
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
                PaperBackground(tint: note.pinnedTint)
                Rectangle().fill(Color(Ink.paperEdge)).frame(height: 1)
            }
            .clipShape(RoundedRectangle(cornerRadius: 3, style: .continuous))
            .shadow(color: Color(red: 0.27, green: 0.16, blue: 0.06).opacity(0.22), radius: 2.5, x: 0, y: 1.5)
        }
        .lightIf(note.pinnedTint?.keepsLight == true)
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

// ---------------------------------------------------------------- 右滑扔（160）
/// 往右拖一条纸条：纸条跟着手指走，左边露出红底、垃圾桶、「扔」；过了纸条宽的七成（SwipeTrash.line）轻震一下，垃圾桶从停在最左边
/// 改成跟着纸条左边走，一看就知道松手就扔；拖回线内再震一下。松手：线外纸条往右飞出去、这一行收起（app.delete：废纸篓留 3 天、
/// 底下撤销照旧）；线内弹回原位。系统的 swipeActions 定不了这条线，所以跟长按（133）、左边划选（135）一样挂在 UICollectionView 上：
/// - 只认往右、横比竖多、走过几点的拖（gestureRecognizerShouldBegin）；斜着往下、往左（系统的左滑）它都作废；
/// - 批量选里不认（左边那一条的划选照旧）；某条左滑开着（系统的置顶、小耳机露着）不认，让系统把它收回去；
/// - 列表的上下滚等它作废再动（require(toFail:)，跟 135 一样）；它起来了 cancelsTouchesInView，松手不算点；
/// - 起来了别的手势都让它（默认不同时认）：长按（手指一动就作废）、系统的左滑都不动。
final class NoteListSwipe: UIPanGestureRecognizer, UIGestureRecognizerDelegate {
    var selecting = false
    var onTrash: @MainActor (UUID) -> Void = { _ in }
    var title = ""
    private weak var list: UICollectionView?
    private weak var cell: UICollectionViewCell?
    private var noteID: UUID?
    private var track = SwipeTrash(width: 1)
    private var back: SwipeBack?
    /// 起手时那一格的位置（有了 transform 以后 frame 就不准了）
    private var home = CGRect.zero
    private let buzz = UIImpactFeedbackGenerator(style: .medium)

    static func on(_ cv: UICollectionView) -> NoteListSwipe {
        if let g = cv.gestureRecognizers?.first(where: { $0 is NoteListSwipe }) as? NoteListSwipe { return g }
        let g = NoteListSwipe(target: nil, action: nil)
        g.list = cv
        g.maximumNumberOfTouches = 1
        g.cancelsTouchesInView = true
        g.delegate = g
        g.addTarget(g, action: #selector(NoteListSwipe.handle))
        cv.addGestureRecognizer(g)
        cv.panGestureRecognizer.require(toFail: g)
        return g
    }

    private func cellAt(_ p: CGPoint) -> UICollectionViewCell? {
        guard let cv = list else { return nil }
        if let ip = cv.indexPathForItem(at: p), let c = cv.cellForItem(at: ip) { return c }
        return cv.visibleCells.first { $0.frame.contains(p) }
    }

    /// 有一条左滑开着：系统把那一格的内容往左推开了（行里垫的 RowTagView 跑到了格子左边距 12 点的左边）。
    /// 11-25 CI：先前看「类名带 SwipeAction 的视图露着」不行——SwiftUI 的列表平时就挂着那些视图，一直当成开着，右拖从来起不了手
    static func swipeOpen(_ cv: UICollectionView) -> Bool {
        for c in cv.visibleCells {
            guard let tag = RowTagView.find(in: c) else { continue }
            if tag.convert(tag.bounds, to: c).minX < 4 { return true }
        }
        return false
    }

    func gestureRecognizerShouldBegin(_ g: UIGestureRecognizer) -> Bool {
        guard g === self, let cv = list else { return true }
        let tr = translation(in: cv)
        let open = Self.swipeOpen(cv)
        guard SwipeTrash.begins(dx: Double(tr.x), dy: Double(tr.y), selecting: selecting, swipeOpen: open) else {
            debug(String(format: "no: dx %.0f dy %.0f sel %d open %d", tr.x, tr.y, selecting ? 1 : 0, open ? 1 : 0))
            return false
        }
        let p = location(in: cv)
        guard let c = cellAt(CGPoint(x: p.x - tr.x, y: p.y - tr.y)), let id = RowTagView.find(in: c)?.noteID else { debug("no: cell"); return false }
        cell = c
        noteID = id
        debug("begin")
        return true
    }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent) {
        super.touchesBegan(touches, with: event)
        debug("touch")
    }

    /// UI 测试看得到的一行（只在 -YiyeDemo 下）：这个识别器最近一次为什么起 / 不起手
    private static var tag: UILabel?
    private func debug(_ why: String) {
        guard UserDefaults.standard.bool(forKey: "YiyeDemo"), let w = list?.window else { return }
        if Self.tag == nil || Self.tag?.window !== w {
            let l = UILabel(frame: CGRect(x: 0, y: 0, width: 2, height: 2))
            l.alpha = 0.02
            l.isUserInteractionEnabled = false
            l.accessibilityIdentifier = "swipe.debug"
            w.addSubview(l)
            Self.tag = l
        }
        Self.tag?.text = why
        Self.tag?.accessibilityLabel = why
    }

    /// 截图用（Demo 画面 swipe-in / swipe-out）：第二条纸条停在拖到一半（YiyeSwipeDemo = 纸条宽的几成）的样子
    private var demoDone = false
    func demoOnce() {
        let f = UserDefaults.standard.double(forKey: "YiyeSwipeDemo")
        guard f > 0, !demoDone else { return }
        demoDone = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak self] in
            guard let self, let cv = self.list else { return }
            let cells = cv.visibleCells.filter { RowTagView.find(in: $0)?.noteID != nil }.sorted { $0.frame.minY < $1.frame.minY }
            guard cells.count > 1 else { return }
            let c = cells[1]
            self.cell = c
            self.home = c.frame
            self.track = SwipeTrash(width: Double(c.bounds.width))
            let b = SwipeBack(title: self.title)
            cv.insertSubview(b, belowSubview: c)
            self.back = b
            self.follow(c, c.bounds.width * CGFloat(f))
        }
    }

    /// 列表自己的左右滑（系统 swipeActions 的拖动）也会接右拖（11-25 CI：它先接走了，什么都不干，松手还算成点开）：
    /// 别的拖动类手势都等它先作废。往左、往下、批量选里、左滑开着，它一走动就作废，系统的照常；133、135 自己的不等它
    func gestureRecognizer(_ g: UIGestureRecognizer, shouldBeRequiredToFailBy other: UIGestureRecognizer) -> Bool {
        g === self && other is UIPanGestureRecognizer && !(other is NoteListSweep) && other !== self
    }

    @objc private func handle() {
        guard let cv = list, let c = cell else { return }
        let dx = max(0, translation(in: cv).x)
        switch state {
        case .began:
            c.transform = .identity
            home = c.frame
            track = SwipeTrash(width: Double(c.bounds.width))
            buzz.prepare()
            back?.removeFromSuperview()
            let b = SwipeBack(title: title)
            cv.insertSubview(b, belowSubview: c)
            back = b
            follow(c, dx)
        case .changed:
            follow(c, dx)
        case .ended:
            debug(String(format: "ended dx %.0f of %.0f", dx, c.bounds.width))
            if track.release(Double(dx)) { flyOut(c) } else { snapBack(c) }
        default:
            snapBack(c)
        }
    }

    /// 纸条跟着手指走；红底从纸条原来的左边一直铺到它现在的左边；过线、回线各轻震一下
    private func follow(_ c: UICollectionViewCell, _ dx: CGFloat) {
        if track.move(Double(dx)) != .none { buzz.impactOccurred(); buzz.prepare() }
        c.transform = CGAffineTransform(translationX: dx, y: 0)
        back?.place(in: home, dx: dx, track: track)
    }

    private func flyOut(_ c: UICollectionViewCell) {
        let id = noteID, w = c.bounds.width, b = back, h = home
        back = nil
        cell = nil
        UIView.animate(withDuration: 0.18, delay: 0, options: [.curveEaseIn]) {
            c.transform = CGAffineTransform(translationX: w + 40, y: 0)
            b?.place(in: h, dx: w + 40, track: self.track)
        } completion: { _ in
            if let id { self.onTrash(id) }
            UIView.animate(withDuration: 0.25) { b?.alpha = 0 } completion: { _ in b?.removeFromSuperview() }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) { c.transform = .identity }   // 这一格收起以后会被别的便签拿去用
        }
    }

    private func snapBack(_ c: UICollectionViewCell) {
        let b = back, h = home
        back = nil
        cell = nil
        UIView.animate(withDuration: 0.28, delay: 0, usingSpringWithDamping: 0.85, initialSpringVelocity: 0) {
            c.transform = .identity
            b?.place(in: h, dx: 0, track: self.track)
        } completion: { _ in b?.removeFromSuperview() }
    }
}

/// 右滑时纸条后面露出来的红底：垃圾桶 + 「扔」
final class SwipeBack: UIView {
    private let icon = UIImageView(image: UIImage(systemName: "trash.fill"))
    private let label = UILabel()
    private let iconW: CGFloat = 64

    init(title: String) {
        super.init(frame: .zero)
        backgroundColor = .systemRed
        layer.cornerRadius = 6
        clipsToBounds = true
        isUserInteractionEnabled = false
        icon.tintColor = .white
        icon.contentMode = .scaleAspectFit
        label.text = title
        label.textColor = .white
        label.font = .systemFont(ofSize: 13, weight: .semibold)
        label.textAlignment = .center
        addSubview(icon)
        addSubview(label)
        accessibilityIdentifier = "swipe.back"
    }

    required init?(coder: NSCoder) { fatalError() }

    /// cell：那一格原来的位置（没挪的）；dx：纸条往右挪了多少。红底从纸条原来的左边（行左边距 12）铺到它现在的左边
    func place(in cell: CGRect, dx: CGFloat, track: SwipeTrash) {
        frame = CGRect(x: cell.minX + 12, y: cell.minY + 5, width: max(0, dx), height: max(0, cell.height - 10))
        let x = CGFloat(track.iconX(Double(dx), iconWidth: Double(iconW)))
        let midY = bounds.height / 2
        icon.frame = CGRect(x: x + (iconW - 22) / 2, y: midY - 20, width: 22, height: 22)
        label.frame = CGRect(x: x, y: midY + 4, width: iconW, height: 18)
    }
}
