import SwiftUI
import YiyeKit

/// 飞鸽传书（128）：工具箱里的一格。点进来只有三样：粘贴、写这是谁家的（可以不写）、发送。
/// 钥匙只露「ntn_…c3d4」这一行；寄出去以后内存、剪贴板里的都清掉；不存便签、不走 iCloud。
struct DoveSheet: View {
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss

    private var t: Lang { app.lang }

    var body: some View {
        @Bindable var dove = DoveModel.shared
        VStack(spacing: 0) {
            HStack {
                BarTitle(text: t.t("dove.title"))
                Spacer()
                Button(t.t("common.done")) { dove.close(); dismiss() }.buttonStyle(PlainTextButtonStyle())
            }
            .padding(.horizontal, 16)
            .frame(height: 52)

            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    HStack(spacing: 12) {
                        Image(systemName: "bird")
                            .font(.system(size: 30, weight: .regular))
                            .foregroundStyle(Color(Ink.accent))
                            .frame(width: 36)
                        VStack(alignment: .leading, spacing: 3) {
                            if dove.hasKey {
                                Text(dove.masked)
                                    .font(.system(size: 17, weight: .medium, design: .monospaced))
                                    .foregroundStyle(Color(Ink.text))
                                if let g = dove.looksLike {
                                    Text(t.f("dove.looksLike", g))
                                        .font(.system(size: 13))
                                        .foregroundStyle(Color(Ink.text2))
                                }
                            } else {
                                Text(t.t("dove.empty"))
                                    .font(.system(size: 15))
                                    .foregroundStyle(Color(Ink.text2))
                            }
                        }
                        Spacer(minLength: 8)
                        PasteButton(payloadType: String.self) { strings in
                            let s = strings.first ?? ""
                            Task { @MainActor in DoveModel.shared.paste(s) }
                        }
                        .labelStyle(.titleAndIcon)
                        .buttonBorderShape(.capsule)
                    }

                    TextField(t.t("dove.name"), text: $dove.name)
                        .font(.system(size: 17))
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .submitLabel(.done)
                        .padding(.horizontal, 12)
                        .frame(height: 44)
                        .background { RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color(Ink.paper)) }
                        .overlay { RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Color(Ink.paperEdge), lineWidth: 0.75) }

                    HStack {
                        Button(t.t("dove.send")) { dove.send() }
                            .buttonStyle(SmartButtonStyle(prominent: true, minWidth: 120))
                            .disabled(!dove.canSend)
                            .opacity(dove.canSend ? 1 : 0.45)
                        Spacer()
                    }

                    statusLine(dove.status)
                }
                .padding(16)
            }
        }
        .background(PaperBackground().ignoresSafeArea())
        .presentationDetents([.medium])
        .onDisappear { DoveModel.shared.close() }
    }

    @ViewBuilder private func statusLine(_ s: DoveModel.Status) -> some View {
        switch s {
        case .idle:
            EmptyView()
        case .sending:
            line(t.t("dove.sending"), color: Ink.text2)
        case .waiting(let pc):
            line(t.t(pc ? "dove.waiting" : "dove.queued"), color: Ink.text2)
        case .noMailbox:
            line(t.t("dove.noMailbox"), color: Ink.danger)
        case .failed(let why):
            line(t.f("dove.failed", why), color: Ink.danger)
        case .answered(let r):
            line(r.line, color: r.ok ? Ink.text : Ink.danger)
        }
    }

    private func line(_ text: String, color: UIColor) -> some View {
        Text(text)
            .font(.system(size: 15))
            .foregroundStyle(Color(color))
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// 特勤局机密文件（128）：大管家递来的一次性东西。一个盖了章的文件夹，内容、复制、关闭。关了就没了：不存、不镜像。
/// 复制只留在这台手机上，2 分钟后系统自己清剪贴板。
struct SecretCardView: View {
    @Environment(AppModel.self) private var app
    let card: SecretCard

    private var t: Lang { app.lang }

    var body: some View {
        let dove = DoveModel.shared
        VStack(spacing: 14) {
            ZStack {
                Image(systemName: "folder.fill")
                    .font(.system(size: 72))
                    .foregroundStyle(Color(Ink.peg))
                    .shadow(color: .black.opacity(0.15), radius: 2, y: 1)
                Text(t.t("secret.stamp"))
                    .font(.system(size: 14, weight: .heavy))
                    .tracking(2)
                    .foregroundStyle(Color(Ink.danger))
                    .padding(.horizontal, 7)
                    .padding(.vertical, 2)
                    .overlay { RoundedRectangle(cornerRadius: 3).strokeBorder(Color(Ink.danger), lineWidth: 2) }
                    .rotationEffect(.degrees(-14))
                    .offset(y: 8)
            }
            .frame(height: 84)
            .accessibilityHidden(true)

            VStack(spacing: 4) {
                Text(t.t("secret.title"))
                    .font(.system(size: 20, weight: .bold))
                    .foregroundStyle(Color(Ink.text))
                if !card.title.isEmpty {
                    Text(card.title)
                        .font(.system(size: 15))
                        .foregroundStyle(Color(Ink.text2))
                }
            }

            Text(card.text)
                .font(.system(size: 13, design: .monospaced))
                .foregroundStyle(Color(Ink.text))
                .lineLimit(3)
                .truncationMode(.middle)
                .multilineTextAlignment(.leading)
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background { RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color(Ink.paper)) }
                .overlay { RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Color(Ink.paperEdge), lineWidth: 0.75) }

            if !card.hint.isEmpty {
                Text(card.hint)
                    .font(.system(size: 13))
                    .foregroundStyle(Color(Ink.text2))
                    .multilineTextAlignment(.center)
            }

            HStack(spacing: 12) {
                Button(t.t(dove.copied ? "secret.copied" : "secret.copy")) { dove.copySecret() }
                    .buttonStyle(SmartButtonStyle(prominent: true, minWidth: 110))
                Button(t.t("secret.close")) { dove.closeSecret() }
                    .buttonStyle(SmartButtonStyle(minWidth: 80))
            }

            Text(t.t("secret.burn"))
                .font(.system(size: 12))
                .foregroundStyle(Color(Ink.text3))
        }
        .padding(20)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(PaperBackground().ignoresSafeArea())
        .presentationDetents([.medium])
    }
}
