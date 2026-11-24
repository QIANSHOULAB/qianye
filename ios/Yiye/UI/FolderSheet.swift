import SwiftUI
import SwiftData
import YiyeKit

/// 文件夹：全部 + 自己建的；排序也在这儿（改的时间新→旧、旧→新、建的时间）
struct FolderSheet: View {
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    @Query(sort: \Folder.order) private var folders: [Folder]
    @Query(filter: #Predicate<Note> { $0.trashed == false && $0.kind != "listen" }) private var notes: [Note]
    @Query(filter: #Predicate<Note> { $0.trashed == true }) private var trashed: [Note]
    @State private var showTrash = false
    @State private var newName = ""
    @State private var adding = false
    @FocusState private var nameFocused: Bool

    private var t: Lang { app.lang }

    var body: some View {
        @Bindable var settings = app.settings
        VStack(spacing: 0) {
            HStack {
                BarTitle(text: t.t("folders.title"))
                Spacer()
                Button(t.t("common.done")) { dismiss() }.buttonStyle(PlainTextButtonStyle())
            }
            .padding(.horizontal, 16)
            .frame(height: 52)

            ScrollView {
                VStack(spacing: 0) {
                    row(name: t.t("list.all"), count: notes.count, on: settings.folderID.isEmpty) {
                        settings.folderID = ""; dismiss()
                    }
                    ForEach(folders.filter { !$0.isListenOnly }) { f in
                        row(name: f.name, count: notes.filter { $0.folder?.id == f.id }.count, on: settings.folderID == f.id.uuidString) {
                            settings.folderID = f.id.uuidString; dismiss()
                        }
                        .contextMenu {
                            // 111：打了勾，夹子里的便签改完就抄一份给电脑上的大管家
                            Toggle(isOn: Binding(get: { f.toDesk }, set: { setDesk(f, $0) })) {
                                Label(t.t("folders.toDesk"), systemImage: "desktopcomputer")
                            }
                            Button(role: .destructive) { remove(f) } label: { Label(t.t("folders.delete"), systemImage: "trash") }
                        }
                    }
                    if adding {
                        HStack(spacing: 8) {
                            TextField(t.t("folders.namePlaceholder"), text: $newName)
                                .font(.system(size: 17))
                                .focused($nameFocused)
                                .submitLabel(.done)
                                .onSubmit { add() }
                            Button(t.t("folders.add")) { add() }.buttonStyle(SmartButtonStyle(prominent: true))
                        }
                        .padding(.horizontal, 16)
                        .frame(minHeight: 52)
                    } else {
                        Button {
                            adding = true
                            nameFocused = true
                        } label: {
                            Label(t.t("folders.new"), systemImage: "folder.badge.plus")
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.horizontal, 16)
                                .frame(minHeight: 52)
                        }
                        .buttonStyle(PlainTextButtonStyle())
                    }

                    Text(t.t("sort.title"))
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Color(Ink.text3))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 16)
                        .padding(.top, 24)
                        .padding(.bottom, 8)
                    IconSegmented(items: [(SortMode.modifiedNew, t.t("sort.new"), AnyView(LeafIcon(young: true))),
                                          (SortMode.modifiedOld, t.t("sort.old"), AnyView(LeafIcon(young: false)))],
                                  selection: $settings.sort)
                        .padding(.horizontal, 16)

                    // 111：废纸篓。空的时候不显示
                    if !trashed.isEmpty {
                        Button { showTrash = true } label: {
                            HStack(spacing: 12) {
                                Image(systemName: "trash").foregroundStyle(Color(Ink.text3)).frame(width: 24)
                                Text("\(t.t("trash.title")) · \(trashed.count)")
                                    .font(.system(size: 17)).foregroundStyle(Color(Ink.text))
                                Spacer()
                                Image(systemName: "chevron.right").font(.system(size: 13, weight: .semibold)).foregroundStyle(Color(Ink.text3))
                            }
                            .padding(.horizontal, 16)
                            .frame(minHeight: 52)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .padding(.top, 20)
                    }
                }
                .padding(.bottom, 24)
            }
        }
        .background(PaperBackground().ignoresSafeArea())
        .sheet(isPresented: $showTrash) { TrashSheet().presentationDetents([.medium, .large]) }
        .task { if app.demo?.screen == "trash" { showTrash = true } }      // 截图用：直接开着废纸篓
    }

    private func setDesk(_ f: Folder, _ on: Bool) {
        f.toDesk = on
        try? app.context.save()
        if on { app.butler.keepFlush() }
    }

    private func row(name: String, count: Int, on: Bool, tap: @escaping () -> Void) -> some View {
        Button(action: tap) {
            HStack(spacing: 12) {
                Image(systemName: on ? "folder.fill" : "folder")
                    .foregroundStyle(Color(on ? Ink.accent : Ink.text3))
                    .frame(width: 24)
                Text(name).font(.system(size: 17, weight: on ? .semibold : .regular)).foregroundStyle(Color(Ink.text))
                Spacer()
                Text("\(count)").font(.system(size: 15).monospacedDigit()).foregroundStyle(Color(Ink.text3))
            }
            .padding(.horizontal, 16)
            .frame(minHeight: 52)
            .contentShape(Rectangle())
            .overlay(alignment: .bottom) {
                Rectangle().fill(Color(Ink.rule)).frame(height: 0.5).padding(.leading, 52)
            }
        }
        .buttonStyle(.plain)
    }

    private func add() {
        let name = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { adding = false; return }
        let f = Folder(name: name, order: (folders.map(\.order).max() ?? -1) + 1)
        app.context.insert(f)
        try? app.context.save()
        newName = ""
        adding = false
    }

    private func remove(_ f: Folder) {
        let name = f.name
        for n in notes where n.folder?.id == f.id { n.folder = nil; app.changed(n) }
        if app.settings.folderID == f.id.uuidString { app.settings.folderID = "" }
        app.context.delete(f)
        try? app.context.save()
        app.show(app.lang.f("folders.deleted", name))
    }
}

/// 废纸篓（111）：标题 + 剩几天。右滑放回原来的文件夹，左滑现在就删（真删，不再确认：他自己划的）
struct TrashSheet: View {
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    @Query(filter: #Predicate<Note> { $0.trashed == true }) private var items: [Note]

    private var t: Lang { app.lang }
    private var notes: [Note] { items.sorted { ($0.trashedAt ?? .distantPast) > ($1.trashedAt ?? .distantPast) } }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                BarTitle(text: t.t("trash.title"))
                Spacer()
                Button(t.t("common.done")) { dismiss() }.buttonStyle(PlainTextButtonStyle())
            }
            .padding(.horizontal, 16)
            .frame(height: 52)

            List {
                ForEach(notes) { n in
                    HStack(spacing: 12) {
                        Text(n.title.isEmpty ? t.t("note.untitled") : n.title)
                            .font(.system(size: 17))
                            .foregroundStyle(Color(n.title.isEmpty ? Ink.text3 : Ink.text))
                            .lineLimit(1)
                        Spacer(minLength: 8)
                        Text(leftText(n))
                            .font(.system(size: 13))
                            .foregroundStyle(Color(Ink.text3))
                    }
                    .frame(minHeight: 44)
                    .listRowBackground(Color.clear)
                    .listRowSeparatorTint(Color(Ink.rule))
                    .swipeActions(edge: .leading, allowsFullSwipe: true) {
                        Button { app.putBack([n.id]) } label: { Label(t.t("trash.putBack"), systemImage: "arrow.uturn.backward") }
                            .tint(Color(Ink.accent))
                    }
                    .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                        Button(role: .destructive) { app.purgeNow(n) } label: { Label(t.t("trash.deleteNow"), systemImage: "trash") }
                            .tint(.red)
                    }
                }
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
        }
        .background(PaperBackground().ignoresSafeArea())
        .onChange(of: items.count) { _, c in if c == 0 { dismiss() } }
    }

    private func leftText(_ n: Note) -> String {
        switch TrashRule.left(trashedAt: n.trashedAt ?? Date(), now: Date()) {
        case .days(let d): return t.f("trash.days", d)
        case .tomorrow: return t.t("trash.tomorrow")
        case .today: return t.t("trash.today")
        }
    }
}
