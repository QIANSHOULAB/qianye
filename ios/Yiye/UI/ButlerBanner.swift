import SwiftUI
import YiyeKit

/// 写字页顶上那一行：大管家在理 / 改了 3 处（点开看改了啥、能换回原文）/ 理好了点一下换上 / 出错（原样显示 + 再交一次）
struct ButlerBanner: View {
    let note: Note
    @Environment(AppModel.self) private var app
    @State private var open = false

    private var t: Lang { app.lang }

    var body: some View {
        let s = note.butlerState
        VStack(alignment: .leading, spacing: 0) {
            switch s.phase {
            case .waiting:
                row(icon: "hourglass", text: t.t("butler.waiting"), sub: presenceHint, color: Ink.text2) { EmptyView() }
            case .applied:
                Button { withAnimation(.easeOut(duration: 0.24)) { open.toggle() } } label: {
                    row(icon: "wand.and.stars", text: t.f("butler.applied", s.count), sub: nil, color: Ink.accent) {
                        Image(systemName: open ? "chevron.up" : "chevron.down").font(.system(size: 12, weight: .semibold)).foregroundStyle(Color(Ink.text3))
                    }
                }
                .buttonStyle(.plain)
                if open { details(s) }
            case .offer:
                HStack(spacing: 8) {
                    Button { app.butler.acceptOffer(note) } label: {
                        row(icon: "sparkles", text: t.t("butler.offer"), sub: nil, color: Ink.accent) { EmptyView() }
                    }
                    .buttonStyle(.plain)
                    Button(t.t("butler.no")) { app.butler.dismiss(note) }
                        .buttonStyle(PlainTextButtonStyle(color: Ink.text2))
                        .padding(.trailing, 16)
                }
            case .failed:
                VStack(alignment: .leading, spacing: 4) {
                    row(icon: "exclamationmark.circle", text: t.t("butler.failed"), sub: nil, color: Ink.danger) {
                        Button(t.t("butler.retry")) { app.butler.submit(note) }.buttonStyle(SmartButtonStyle())
                    }
                    Text(s.error ?? "")
                        .font(.system(size: 13, design: .monospaced))
                        .foregroundStyle(Color(Ink.text2))
                        .textSelection(.enabled)
                        .padding(.horizontal, 16)
                        .padding(.bottom, 10)
                }
            case .unchanged:
                row(icon: "checkmark.circle", text: t.t("butler.unchanged"), sub: nil, color: Ink.text2) {
                    Button(t.t("butler.ok")) { app.butler.dismiss(note) }.buttonStyle(PlainTextButtonStyle(color: Ink.text2))
                }
            case .none:
                EmptyView()
            }
        }
        .background {
            ZStack(alignment: .bottom) {
                Color(Ink.paper).opacity(0.96)
                Rectangle().fill(Color(Ink.rule)).frame(height: 0.5)
            }
        }
        .onAppear { if app.demo?.screen == "butler" { open = true } }
    }

    private var presenceHint: String? {
        switch app.butler.presence {
        case .never: return t.t("butler.absent")
        case .online: return nil
        case .seen(let m, _): return t.f("butler.seen", m)
        }
    }

    private func row<Trailing: View>(icon: String, text: String, sub: String?, color: UIColor, @ViewBuilder trailing: () -> Trailing) -> some View {
        HStack(spacing: 10) {
            Image(systemName: icon).font(.system(size: 14, weight: .semibold)).foregroundStyle(Color(color))
            VStack(alignment: .leading, spacing: 1) {
                Text(text).font(.system(size: 14, weight: .semibold)).foregroundStyle(Color(color))
                if let sub { Text(sub).font(.system(size: 12)).foregroundStyle(Color(Ink.text3)) }
            }
            Spacer(minLength: 8)
            trailing()
        }
        .padding(.horizontal, 16)
        .frame(minHeight: 44)
        .contentShape(Rectangle())
    }

    /// 改了啥：大管家自己写的说明 + 逐处「原 → 新」
    private func details(_ s: ButlerNoteState) -> some View {
        let hunks = TextDiff.hunks(s.original ?? "", note.markdown)
        return VStack(alignment: .leading, spacing: 8) {
            if let c = s.changes, !c.isEmpty {
                Text(c).font(.system(size: 14)).foregroundStyle(Color(Ink.text))
            }
            ForEach(Array(hunks.prefix(12).enumerated()), id: \.offset) { pair in
                let h = pair.element
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(h.old.isEmpty ? "∅" : show(h.old)).strikethrough().foregroundStyle(Color(Ink.text3))
                    Image(systemName: "arrow.right").font(.system(size: 10)).foregroundStyle(Color(Ink.text3))
                    Text(h.new.isEmpty ? "∅" : show(h.new)).foregroundStyle(Color(Ink.text))
                }
                .font(.system(size: 14).monospacedDigit())
            }
            if hunks.count > 12 { Text(t.f("butler.more", hunks.count - 12)).font(.system(size: 12)).foregroundStyle(Color(Ink.text3)) }
            HStack(spacing: 12) {
                Button(t.t("butler.revert")) { app.butler.revert(note) }.buttonStyle(SmartButtonStyle())
                Button(t.t("butler.ok")) { withAnimation(.easeOut(duration: 0.24)) { app.butler.dismiss(note) } }
                    .buttonStyle(PlainTextButtonStyle(color: Ink.text2))
            }
            .padding(.top, 2)
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 12)
        .transition(.opacity)
    }

    private func show(_ s: String) -> String { s.replacingOccurrences(of: "\n", with: "⏎") }
}
