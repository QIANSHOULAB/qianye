import SwiftUI
import UIKit
import YiyeKit

/// 258 灵感库：机器人名单最上面那张卡 → 照片墙（种类、搜索）→ 点一张全屏看（裁图、整屏、手机图左右滑，底下卡片字和原网址）。
/// 图是主角：墙上只有图，不加边不加字。

/// 一块图：照给的宽高比裁满；缩略图没有就写站名
private struct GalleryTile: View {
    let entry: LibraryEntry
    let ratio: Double
    var radius: CGFloat = 12

    var body: some View {
        Color(Ink.rule)
            .aspectRatio(CGFloat(ratio), contentMode: .fit)
            .overlay {
                if let n = entry.thumb?.name, let img = LibraryModel.shared.image(n) {
                    Image(uiImage: img).resizable().scaledToFill()
                } else {
                    Text(entry.card.site)
                        .font(.system(size: 11))
                        .foregroundStyle(Color(Ink.text3))
                        .lineLimit(2)
                        .padding(4)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
            .contentShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
    }
}

/// 机器人名单最上面那张卡：带最新几张小图
struct GalleryCard: View {
    private let open: () -> Void
    @Environment(AppModel.self) private var app

    init(open: @escaping () -> Void) { self.open = open }

    private var t: Lang { app.lang }
    private var m: LibraryModel { LibraryModel.shared }

    var body: some View {
        let all = m.book.shown
        let latest = Array(all.prefix(4))
        Button(action: open) {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 6) {
                    Text(t.t("lib.title")).font(.system(size: 17, weight: .semibold)).foregroundStyle(Color(Ink.text))
                    if !all.isEmpty {
                        Text("\(all.count)").font(.system(size: 15)).foregroundStyle(Color(Ink.text3))
                    }
                    Spacer(minLength: 0)
                    Image(systemName: "chevron.right").font(.system(size: 12, weight: .bold)).foregroundStyle(Color(Ink.text3))
                }
                if latest.isEmpty {
                    Text(t.t("lib.cardEmpty")).font(.system(size: 13)).foregroundStyle(Color(Ink.text3))
                } else {
                    HStack(spacing: 6) {
                        ForEach(latest) { GalleryTile(entry: $0, ratio: 1, radius: 8) }
                        ForEach(latest.count..<4, id: \.self) { _ in Color.clear.aspectRatio(1, contentMode: .fit) }
                    }
                    .accessibilityHidden(true)
                }
            }
            .padding(12)
            .background { RoundedRectangle(cornerRadius: 16, style: .continuous).fill(Color(Ink.paper)) }
            .overlay { RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(Color(Ink.paperEdge), lineWidth: 0.75) }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("bots.library")
    }
}

/// 点开看的那一条
private struct GalleryShown: Identifiable {
    let id: String
}

/// 照片墙
struct GalleryWall: View {
    @Environment(AppModel.self) private var app
    @State private var query = ""
    @State private var kind: String?
    @State private var viewing: GalleryShown?
    @FocusState private var typing: Bool

    private var t: Lang { app.lang }
    private var m: LibraryModel { LibraryModel.shared }

    var body: some View {
        let kinds = m.book.kindsShown
        let picked = kind.flatMap { kinds.contains($0) ? $0 : nil }          // 这一类的都不留了：回到全部
        let found = m.book.search(query, kind: picked)
        let empty = m.book.shown.isEmpty
        VStack(spacing: 0) {
            BotHeader(title: t.t("lib.title"))
            searchField
            if !kinds.isEmpty { chips(kinds, picked) }
            if let line = m.note ?? (m.syncing && empty ? t.t("lib.syncing") : nil) {
                Text(line)
                    .font(.system(size: 13))
                    .foregroundStyle(Color(Ink.text3))
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 16)
                    .padding(.bottom, 6)
                    .accessibilityIdentifier("lib.note")
            }
            ScrollView {
                if !found.isEmpty {
                    wall(found)
                } else if !(m.syncing && empty) {
                    Text(t.t(empty ? "lib.empty" : "lib.noHit"))
                        .font(.system(size: 15))
                        .foregroundStyle(Color(Ink.text2))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 16)
                        .padding(.top, 16)
                }
            }
            .scrollDismissesKeyboard(.immediately)
        }
        .onAppear { m.sync(force: true) }
        .fullScreenCover(item: $viewing) { GalleryViewer(id: $0.id) }
    }

    private var searchField: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass").font(.system(size: 15)).foregroundStyle(Color(Ink.text3))
            TextField(t.t("lib.search"), text: $query)
                .font(.system(size: 16))
                .focused($typing)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
                .submitLabel(.search)
                .accessibilityIdentifier("lib.search")
            if !query.isEmpty {
                Button { query = "" } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(Color(Ink.text3)).frame(width: 32, height: 32)
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("lib.clear")
            }
        }
        .padding(.horizontal, 10)
        .frame(height: 38)
        .background { RoundedRectangle(cornerRadius: 11, style: .continuous).fill(Color(Ink.paper)) }
        .overlay { RoundedRectangle(cornerRadius: 11, style: .continuous).strokeBorder(Color(Ink.paperEdge), lineWidth: 0.75) }
        .padding(.horizontal, 12)
        .padding(.bottom, 8)
    }

    private func chips(_ kinds: [String], _ picked: String?) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                chip(t.t("lib.all"), id: "all", on: picked == nil) { kind = nil }
                ForEach(kinds, id: \.self) { k in
                    chip(k, id: k, on: picked == k) { kind = k }
                }
            }
            .padding(.horizontal, 12)
        }
        .padding(.bottom, 8)
    }

    private func chip(_ title: String, id: String, on: Bool, tap: @escaping () -> Void) -> some View {
        Button { typing = false; tap() } label: {
            Text(title)
                .font(.system(size: 14, weight: on ? .semibold : .regular))
                .foregroundStyle(Color(on ? Ink.paper : Ink.text))
                .padding(.horizontal, 14)
                .frame(height: 32)
                .background { Capsule().fill(Color(on ? Ink.text : Ink.paper)) }
                .overlay { Capsule().strokeBorder(Color(Ink.paperEdge), lineWidth: on ? 0 : 0.75) }
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("lib.kind.\(id)")
        .accessibilityAddTraits(on ? [.isButton, .isSelected] : .isButton)
    }

    private func wall(_ found: [LibraryEntry]) -> some View {
        let columns = LibraryBook.columns(found.map { $0.thumb?.ratio ?? 1 }, count: 2)
        return HStack(alignment: .top, spacing: 8) {
            ForEach(columns.indices, id: \.self) { c in
                LazyVStack(spacing: 8) {
                    ForEach(columns[c].map { found[$0] }) { e in
                        Button { typing = false; viewing = GalleryShown(id: e.id) } label: {
                            GalleryTile(entry: e, ratio: LibraryBook.tileRatio(e.thumb?.ratio ?? 1))
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(e.card.punctum.isEmpty ? e.card.site : e.card.punctum)
                        .accessibilityIdentifier("lib.tile.\(e.id)")
                    }
                }
                .frame(maxWidth: .infinity)
            }
        }
        .padding(.horizontal, 12)
        .padding(.top, 2)
        .padding(.bottom, 24)
    }
}

/// 全屏看一条：黑底。上面图（左右滑、双指放大、长按存相册），下面卡片字和原网址；右上 👎 = 不留，不弹确认框
private struct GalleryViewer: View {
    let id: String
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    @State private var page = 0

    private var t: Lang { app.lang }
    private var m: LibraryModel { LibraryModel.shared }

    var body: some View {
        let entry = m.book.entry(id)
        VStack(spacing: 0) {
            HStack {
                round("xmark", t.t("common.close"), "lib.viewer.close") { dismiss() }
                Spacer()
                round("hand.thumbsdown", t.t("lib.drop"), "lib.viewer.drop") { drop() }
            }
            .padding(.horizontal, 12)
            .padding(.top, 4)
            if let entry {
                pictures(entry)
                card(entry.card)
            } else {
                Spacer()
            }
        }
        .background(Color.black.ignoresSafeArea())
        .overlay(alignment: .bottom) { ToastView() }
        .onAppear { m.open(id) }
    }

    private func round(_ icon: String, _ label: String, _ identifier: String, tap: @escaping () -> Void) -> some View {
        Button(action: tap) {
            Image(systemName: icon)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(.white.opacity(0.85))
                .frame(width: 36, height: 36)
                .background { Circle().fill(.white.opacity(0.16)) }
                .frame(width: 44, height: 44)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
        .accessibilityIdentifier(identifier)
    }

    /// 原图没到先摆缩略图
    private func pictures(_ entry: LibraryEntry) -> some View {
        let shots = entry.shots ?? []
        let names = shots.isEmpty ? (entry.thumb.map { [$0.name] } ?? []) : shots.map { $0.name }
        return TabView(selection: $page) {
            ForEach(Array(names.enumerated()), id: \.element) { p in
                if let img = m.image(p.element) {
                    ZoomableImage(image: img, name: shots.isEmpty ? "lib.viewer.thumb" : "lib.viewer.image.\(p.offset)",
                                  onLongPress: { if !shots.isEmpty { keep(p.element) } })
                        .tag(p.offset)
                }
            }
        }
        .tabViewStyle(.page(indexDisplayMode: names.count > 1 ? .always : .never))
        .overlay(alignment: .top) { waiting }
    }

    @ViewBuilder private var waiting: some View {
        if m.fetching.contains(id) {
            HStack(spacing: 8) {
                ProgressView().tint(.white)
                Text(t.t("lib.fetching")).font(.system(size: 13)).foregroundStyle(.white.opacity(0.8))
            }
            .padding(.horizontal, 12)
            .frame(minHeight: 32)
            .background { Capsule().fill(.black.opacity(0.6)) }
        } else if let why = m.fetchError[id] {
            HStack(spacing: 10) {
                Text(why).font(.system(size: 13)).foregroundStyle(.white.opacity(0.85)).lineLimit(2)
                Button(t.t("shutong.retry")) { m.open(id) }
                    .buttonStyle(PlainTextButtonStyle(color: .dyn(0xFFB27A, 0xFFB27A)))
            }
            .padding(.horizontal, 12)
            .background { Capsule().fill(.black.opacity(0.6)) }
            .padding(.horizontal, 12)
        }
    }

    private func card(_ c: LibraryCard) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                Text([c.kind, c.date, c.label].filter { !$0.isEmpty }.joined(separator: " · "))
                    .font(.system(size: 12))
                    .foregroundStyle(.white.opacity(0.5))
                field(t.t("lib.punctum"), c.punctum, size: 18, id: "lib.punctum")
                field(t.t("lib.difference"), c.difference, size: 15, id: "lib.difference")
                field(t.t("lib.move"), c.move, size: 15, id: "lib.move")
                if let url = URL(string: c.url), url.scheme?.hasPrefix("http") == true {
                    Button { browse(url) } label: {
                        HStack(spacing: 6) {
                            Image(systemName: "safari")
                            Text(c.url).lineLimit(1).truncationMode(.middle)
                        }
                        .font(.system(size: 14))
                        .foregroundStyle(Color(red: 1.0, green: 0.70, blue: 0.48))
                        .frame(minHeight: 36)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("lib.url")
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
        }
        .frame(maxHeight: 260)
    }

    @ViewBuilder private func field(_ title: String, _ text: String, size: CGFloat, id: String) -> some View {
        if !text.isEmpty {
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.system(size: 12, weight: .semibold)).foregroundStyle(.white.opacity(0.45))
                Text(text)
                    .font(.system(size: size, weight: size > 16 ? .semibold : .regular))
                    .foregroundStyle(.white.opacity(0.94))
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier(id)
            }
        }
    }

    private func keep(_ name: String) {
        guard let d = m.data(name) else { return }
        BotPictures.keep(data: d, demo: app.demo != nil, app: app)
    }

    private func browse(_ url: URL) {
        if app.demo != nil { app.show(t.f("lib.opened", url.host ?? "")); return }     // UI 测试不跳出去
        UIApplication.shared.open(url)
    }

    private func drop() {
        let item = id
        let model = app
        LibraryModel.shared.setKept(item, false)
        dismiss()
        model.show(t.t("lib.dropped"), action: t.t("lib.undo"), seconds: 8) {
            LibraryModel.shared.setKept(item, true)
            model.toast = nil
        }
    }
}
