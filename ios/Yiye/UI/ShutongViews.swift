import SwiftUI
import YiyeKit

/// 136 书童的聊天窗：从下面升起半屏。能打字，能按住说（大管家用 SenseVoice 认，认出的字先放进输入框给他看一眼）。
/// 他说的靠右，书童说的靠左；一批动作一张回执，上面「撤销这一批」；扔、合并的先列成清单，划掉不想动的，点「照办」才做。
struct ShutongSheet: View {
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    @State private var holding = false
    @FocusState private var typing: Bool

    private var t: Lang { app.lang }

    var body: some View {
        @Bindable var m = ShutongModel.shared
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "studentdesk")
                    .font(.system(size: 17, weight: .medium))
                    .foregroundStyle(Color(Ink.accent))
                BarTitle(text: t.t("shutong.name"))
                Spacer()
                Button(t.t("common.done")) { m.open = false; dismiss() }.buttonStyle(PlainTextButtonStyle())
            }
            .padding(.horizontal, 16)
            .frame(height: 52)

            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 10) {
                        if m.lines.isEmpty {
                            Text(t.t("shutong.hint"))
                                .font(.system(size: 15))
                                .foregroundStyle(Color(Ink.text2))
                                .fixedSize(horizontal: false, vertical: true)
                                .padding(.top, 8)
                        }
                        ForEach(m.lines) { line in
                            ShutongBubble(line: line).id(line.id)
                        }
                        if m.thinking {
                            Text(t.t("shutong.thinking"))
                                .font(.system(size: 14))
                                .foregroundStyle(Color(Ink.text3))
                                .id("thinking")
                        }
                        Color.clear.frame(height: 4).id("bottom")
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
                }
                .scrollDismissesKeyboard(.interactively)
                .onAppear { proxy.scrollTo("bottom", anchor: .bottom) }
                .onChange(of: m.lines.count) { _, _ in withAnimation(.easeOut(duration: 0.2)) { proxy.scrollTo("bottom", anchor: .bottom) } }
                .onChange(of: m.thinking) { _, _ in withAnimation(.easeOut(duration: 0.2)) { proxy.scrollTo("bottom", anchor: .bottom) } }
            }

            inputBar(m)
        }
        .background(PaperBackground().ignoresSafeArea())
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
        .onAppear { m.load() }
        .onDisappear { m.open = false; if m.recording { m.stopRecording() } }
    }

    private func inputBar(_ model: ShutongModel) -> some View {
        @Bindable var m = model
        return HStack(alignment: .bottom, spacing: 8) {
            // 按住说：松开把录音寄给大管家认字（SenseVoice），认出的字放进输入框
            Image(systemName: m.recording ? "mic.fill" : (m.hearing ? "ellipsis" : "mic"))
                .font(.system(size: 19, weight: .medium))
                .foregroundStyle(Color(m.recording ? Ink.danger : Ink.text2))
                .frame(width: 44, height: 44)
                .background { Circle().fill(Color(Ink.btnPressed).opacity(m.recording ? 1 : 0)) }
                .contentShape(Circle())
                .gesture(DragGesture(minimumDistance: 0)
                    .onChanged { _ in
                        guard !holding else { return }
                        holding = true
                        m.startRecording()
                    }
                    .onEnded { _ in
                        holding = false
                        m.stopRecording()
                    })
                .accessibilityLabel(t.t("shutong.hold"))
            TextField(m.recording ? t.t("shutong.hold") : (m.hearing ? t.t("shutong.hearing") : t.t("shutong.placeholder")),
                      text: $m.input, axis: .vertical)
                .font(.system(size: 17))
                .lineLimit(1...5)
                .focused($typing)
                .submitLabel(.send)
                .onSubmit { typing = false; m.send() }
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
                .background { RoundedRectangle(cornerRadius: 18, style: .continuous).fill(Color(Ink.paper)) }
                .overlay { RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(Color(Ink.paperEdge), lineWidth: 0.75) }
                .accessibilityIdentifier("shutong.input")
            let canSend = !m.input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            Button { typing = false; m.send() } label: {
                Image(systemName: "arrow.up.circle.fill")
                    .font(.system(size: 30))
                    .foregroundStyle(Color(canSend ? Ink.accent : Ink.text3))
                    .frame(width: 44, height: 44)
            }
            .buttonStyle(.plain)
            .disabled(!canSend)
            .accessibilityLabel(t.t("shutong.send"))
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background {
            ZStack(alignment: .top) {
                LinearGradient(colors: [Color(Ink.barTop), Color(Ink.barBottom)], startPoint: .top, endPoint: .bottom)
                Rectangle().fill(Color(Ink.barLine)).frame(height: 0.5)
            }
            .ignoresSafeArea(edges: .bottom)
        }
    }
}

/// 聊天窗里的一行
struct ShutongBubble: View {
    let line: ShutongLine
    @Environment(AppModel.self) private var app

    private var t: Lang { app.lang }
    private var m: ShutongModel { ShutongModel.shared }

    var body: some View {
        switch line.who {
        case "he": he
        case "say": say
        case "receipt": receipt
        case "confirm": ShutongConfirmCard(line: line)
        default:
            Text(line.text)
                .font(.system(size: 13))
                .foregroundStyle(Color(Ink.text3))
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var he: some View {
        VStack(alignment: .trailing, spacing: 3) {
            Text(line.text)
                .font(.system(size: 16))
                .foregroundStyle(Color(Ink.text))
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background { RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Color(Ink.accent).opacity(0.16)) }
                .textSelection(.enabled)
            if line.state == "failed" {
                Button(t.t("shutong.retry")) { m.retry(line.id) }
                    .buttonStyle(PlainTextButtonStyle())
                    .font(.system(size: 13))
            }
        }
        .frame(maxWidth: .infinity, alignment: .trailing)
        .padding(.leading, 48)
    }

    private var say: some View {
        Text(line.text)
            .font(.system(size: 16))
            .foregroundStyle(Color(Ink.text))
            .fixedSize(horizontal: false, vertical: true)
            .textSelection(.enabled)
            .padding(.trailing, 32)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var receipt: some View {
        let undone = line.undone || (line.batch.map { m.isUndone($0) } ?? true)
        return VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Image(systemName: undone ? "arrow.uturn.backward.circle" : "checkmark.circle.fill")
                    .foregroundStyle(Color(undone ? Ink.text3 : Ink.accent))
                VStack(alignment: .leading, spacing: 2) {
                    if line.auto {
                        Text(t.t("shutong.auto")).font(.system(size: 12, weight: .semibold)).foregroundStyle(Color(Ink.text3))
                    }
                    Text(line.text)
                        .font(.system(size: 15, weight: .medium))
                        .foregroundStyle(Color(undone ? Ink.text3 : Ink.text))
                        .strikethrough(undone)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            if undone {
                Text(t.t("shutong.undone")).font(.system(size: 13)).foregroundStyle(Color(Ink.text3))
            } else if let b = line.batch {
                Button(t.t("shutong.undo")) { m.undo(b) }
                    .buttonStyle(SmartButtonStyle())
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background { RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color(Ink.paper)) }
        .overlay { RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Color(Ink.paperEdge), lineWidth: 0.75) }
    }
}

/// 要他点头的清单：一条一行，点一下划掉（不动它）；「照办」/「照扔」、「算了」
struct ShutongConfirmCard: View {
    let line: ShutongLine
    @Environment(AppModel.self) private var app

    private var t: Lang { app.lang }

    var body: some View {
        let m = ShutongModel.shared
        let acts = line.acts ?? []
        let pending = line.state == "pending"
        let allTrash = acts.allSatisfy { $0.op == "trash" }
        VStack(alignment: .leading, spacing: 8) {
            Text(line.mode == "sweep" ? t.t("shutong.sweepTitle") : t.t("shutong.confirm"))
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(Color(Ink.text))
            ForEach(Array(acts.enumerated()), id: \.offset) { pair in
                let struck = line.struck.contains(pair.offset)
                Button { m.strike(line.id, pair.offset) } label: {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Image(systemName: struck ? "circle" : (pair.element.op == "trash" ? "trash.circle.fill" : "checkmark.circle.fill"))
                            .foregroundStyle(Color(struck ? Ink.text3 : (pair.element.op == "trash" ? Ink.danger : Ink.accent)))
                        Text(m.describe(pair.element))
                            .font(.system(size: 15))
                            .foregroundStyle(Color(struck ? Ink.text3 : Ink.text))
                            .strikethrough(struck)
                            .multilineTextAlignment(.leading)
                            .fixedSize(horizontal: false, vertical: true)
                        Spacer(minLength: 0)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(!pending)
            }
            if pending {
                HStack(spacing: 12) {
                    Button(allTrash ? t.t("shutong.trashIt") : t.t("shutong.doIt")) { m.confirm(line.id) }
                        .buttonStyle(SmartButtonStyle(prominent: true, minWidth: 88))
                    Button(t.t("shutong.never")) { m.cancel(line.id) }
                        .buttonStyle(PlainTextButtonStyle(color: Ink.text2))
                }
                .padding(.top, 2)
            } else {
                Text(line.state == "done" ? t.t("shutong.done") : t.t("shutong.cancelled"))
                    .font(.system(size: 13))
                    .foregroundStyle(Color(Ink.text3))
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background { RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color(Ink.paper)) }
        .overlay { RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Color(Ink.danger).opacity(pending && allTrash ? 0.35 : 0), lineWidth: 1) }
    }
}

/// 主页顶上的小纸条（每周日一次）：「书童觉得这几条可以扔了 · 3 条」。点了进聊天窗过目，点 × 这周不看了
struct ShutongSlip: View {
    let slip: ShutongLine
    @Environment(AppModel.self) private var app

    var body: some View {
        let t = app.lang
        HStack(spacing: 10) {
            Image(systemName: "studentdesk").foregroundStyle(Color(Ink.accent))
            Button { ShutongModel.shared.openSlip() } label: {
                VStack(alignment: .leading, spacing: 1) {
                    Text(t.t("shutong.sweepTitle")).font(.system(size: 14, weight: .semibold)).foregroundStyle(Color(Ink.text))
                    Text(t.f("shutong.slipCount", (slip.acts ?? []).count) + " · " + t.t("shutong.slipOpen"))
                        .font(.system(size: 12)).foregroundStyle(Color(Ink.text3))
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            Button { withAnimation(.easeOut(duration: 0.2)) { ShutongModel.shared.dismissSlip() } } label: {
                Image(systemName: "xmark").font(.system(size: 12, weight: .bold)).foregroundStyle(Color(Ink.text3)).hit44()
            }
            .buttonStyle(.plain)
            .accessibilityLabel(t.t("shutong.never"))
        }
        .padding(.leading, 14)
        .padding(.trailing, 4)
        .frame(minHeight: 52)
        .background {
            RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color(Ink.paper))
                .shadow(color: .black.opacity(0.08), radius: 3, y: 1)
        }
        .padding(.horizontal, 12)
        .padding(.top, 6)
    }
}

/// 写字页顶上「原话」展开的那块（136）：收拾之前那一版，一个字不丢；一键换回原话
struct SpokenPanel: View {
    let note: Note
    let compact: Bool
    let swapBack: () -> Void
    @Environment(AppModel.self) private var app

    private var spokenText: some View {
        Text(note.spoken)
            .font(.system(size: 15))
            .foregroundStyle(Color(Ink.text2))
            .textSelection(.enabled)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityIdentifier("shutong.spoken")
    }

    var body: some View {
        let t = app.lang
        let same = note.markdown == note.spoken
        VStack(alignment: .leading, spacing: 8) {
            // 短的多高占多高，长的才滚（ScrollView 会把空的地方也撑满）
            ViewThatFits(in: .vertical) {
                spokenText
                ScrollView { spokenText }
            }
            HStack {
                if same {
                    Text(t.t("editor.isSpoken")).font(.system(size: 13)).foregroundStyle(Color(Ink.text3))
                } else {
                    Button(t.t("editor.useSpoken"), action: swapBack).buttonStyle(SmartButtonStyle())
                }
                Spacer()
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .frame(maxHeight: UIScreen.main.bounds.height * (compact ? 0.22 : 0.4), alignment: .top)
        .background(Color(Ink.text).opacity(0.06))
        .overlay(alignment: .bottom) { Rectangle().fill(Color(Ink.barLine)).frame(height: 0.5) }
    }
}
