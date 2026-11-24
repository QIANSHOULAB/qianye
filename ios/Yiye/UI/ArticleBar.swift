import SwiftUI
import UIKit
import YiyeKit

/// 文章便签（kind == "article"）写字页底部的细栏（114）：两个按钮「简写」「直接配音」，加一行说大管家在干什么。
/// 正文还在扒：两个按钮灰着；扒失败、没回话：写原因，按钮照样能用（用便签里现有的字）。
struct ArticleBar: View {
    let note: Note
    @Environment(AppModel.self) private var app
    private var t: Lang { app.lang }

    var body: some View {
        // 每 20 秒重算一次，好让「没回话」自己出来
        TimelineView(.periodic(from: .now, by: 20)) { ctx in
            let st = note.articleState
            let ok = st.canPress(now: ctx.date)
            VStack(alignment: .leading, spacing: 8) {
                lineView(st.line(now: ctx.date))
                HStack(spacing: 10) {
                    Button(t.t("article.simplify")) { Task { await app.butler.submitSimplify(note) } }
                        .buttonStyle(SmartButtonStyle())
                        .disabled(!ok)
                    Button(t.t("article.readAsIs")) { readAsIs() }
                        .buttonStyle(SmartButtonStyle(prominent: true))
                        .disabled(!ok)
                    Spacer(minLength: 0)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(Ink.paper).opacity(0.96).overlay(alignment: .top) { Rectangle().fill(Color(Ink.rule)).frame(height: 0.5) })
        }
    }

    @ViewBuilder
    private func lineView(_ line: ArticleState.Line) -> some View {
        switch line {
        case .none:
            EmptyView()
        case .fetching:
            small(t.t("article.fetching"), icon: "hourglass")
        case .fetchFailed(let why):
            small(why, icon: "exclamationmark.circle", danger: true)
        case .fetchSilent, .simplifySilent:
            small(t.t("article.silent"), icon: "exclamationmark.circle", danger: true)
        case .simplifying:
            small(t.t("article.simplifying"), icon: "hourglass")
        case .simplifyFailed(let why):
            small(why, icon: "exclamationmark.circle", danger: true)
        case .simplified(let id):
            Button {
                if let u = UUID(uuidString: id) { app.listening = ListenOpen(startNote: u) }
            } label: {
                Label(t.t("article.simplified"), systemImage: "headphones")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(Color(Ink.accent))
            }
            .buttonStyle(.plain)
        }
    }

    private func small(_ text: String, icon: String, danger: Bool = false) -> some View {
        Label(text, systemImage: icon)
            .font(.system(size: 13))
            .foregroundStyle(Color(danger ? Ink.danger : Ink.text3))
            .fixedSize(horizontal: false, vertical: true)
    }

    /// 直接配音 = 现成的配音：没进小耳机就放进去（顺手配音），进了就重配
    private func readAsIs() {
        if note.inListen { app.dub(note) } else { app.toggleListen(note) }
    }
}

/// 存文章时顺手拿一下网页标题：只下前 200 KB、等 6 秒，拿不到就返回 nil（便签第一行放网址）
enum PageTitleFetch {
    static func title(_ url: String) async -> String? {
        guard let u = URL(string: url) else { return nil }
        var req = URLRequest(url: u, timeoutInterval: 6)
        req.setValue("Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X) AppleWebKit/605.1.15 Version/18.0 Mobile/15E148 Safari/604.1", forHTTPHeaderField: "User-Agent")
        req.setValue("bytes=0-200000", forHTTPHeaderField: "Range")
        guard let (data, _) = try? await URLSession.shared.data(for: req) else { return nil }
        let head = data.prefix(200_000)
        let html = String(data: head, encoding: .utf8) ?? String(decoding: head, as: UTF8.self)
        return PageTitle.extract(html)
    }
}
