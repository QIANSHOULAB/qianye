import SwiftUI
import SwiftData

/// 文件夹：全部 + 自己建的；排序也在这儿（改的时间新→旧、旧→新、建的时间）
struct FolderSheet: View {
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    @Query(sort: \Folder.order) private var folders: [Folder]
    @Query(filter: #Predicate<Note> { $0.trashed == false }) private var notes: [Note]
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
                    ForEach(folders) { f in
                        row(name: f.name, count: notes.filter { $0.folder?.id == f.id }.count, on: settings.folderID == f.id.uuidString) {
                            settings.folderID = f.id.uuidString; dismiss()
                        }
                        .contextMenu {
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
                }
                .padding(.bottom, 24)
            }
        }
        .background(PaperBackground().ignoresSafeArea())
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
