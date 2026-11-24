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
                           selecting: selecting, sweepBegin: sweepBegin, sweepMove: sweepMove, sweepEnd: endTouch))
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
        case .listen: app.listening = ListenOpen()
        case .settings: app.path.append(.settings)
        case .companion:
            if !broadcast.fire() { app.show(t.t("companion.noPanel")) }
        case .deep:
            app.companion.toggleDeep()
        case .dove:
            DoveModel.shared.open = true             // 128：飞鸽传书（RootView 里的 sheet）
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
