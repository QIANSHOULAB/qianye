import SwiftUI
import UIKit
import YiyeKit

/// 录一段：一打开就在录，边说边出字。说完了 → 存成一条（上面录音，下面字）；不要了 → 什么都不留
struct RecorderScreen: View {
    let target: VoiceTarget
    @Environment(AppModel.self) private var app
    @State private var rec = VoiceRecorder()
    @State private var began = false

    private var t: Lang { app.lang }

    var body: some View {
        VStack(spacing: 0) {
            SmartBar {
                Button(t.t("voice.cancel")) { cancel() }
                    .buttonStyle(SmartButtonStyle())
            } center: {
                BarTitle(text: t.t("voice.title"))
            } right: {
                EmptyView()
            }

            VStack(spacing: 20) {
                Text(VoiceText.clock(rec.elapsed))
                    .font(.system(size: 44, weight: .light).monospacedDigit())
                    .foregroundStyle(Color(Ink.text))
                    .padding(.top, 28)
                LevelBars(levels: rec.levels, live: rec.phase == .recording)
                    .frame(height: 44)
                    .padding(.horizontal, 40)
                transcript
                if let n = rec.note {
                    Text(n)
                        .font(.system(size: 13))
                        .foregroundStyle(Color(Ink.text3))
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 24)
                }
                bottom
            }
        }
        .background(PaperBackground(tint: .white).ignoresSafeArea())
        .task { await begin() }
    }

    private var transcript: some View {
        ScrollViewReader { proxy in
            ScrollView {
                Group {
                    if rec.finals.isEmpty && rec.volatile.isEmpty {
                        Text(rec.phase == .preparing ? t.t("voice.preparing") : t.t("voice.listening"))
                            .foregroundStyle(Color(Ink.text3))
                    } else {
                        Text(VoiceText.join(rec.finals)).foregroundStyle(Color(Ink.text))
                        + Text(rec.finals.isEmpty || rec.volatile.isEmpty ? rec.volatile : (needsSpace ? " " : "") + rec.volatile)
                            .foregroundStyle(Color(Ink.text3))
                    }
                }
                .font(.system(size: 19))
                .lineSpacing(8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 24)
                .id("end")
            }
            .onChange(of: rec.text) { _, _ in withAnimation(.easeOut(duration: 0.2)) { proxy.scrollTo("end", anchor: .bottom) } }
        }
        .frame(maxHeight: .infinity)
    }

    private var needsSpace: Bool {
        guard let a = VoiceText.join(rec.finals).last, let b = rec.volatile.first else { return false }
        return !isWide(a) && !isWide(b)
    }

    @ViewBuilder private var bottom: some View {
        switch rec.phase {
        case .denied:
            VStack(spacing: 12) {
                Text(t.t("voice.denied")).font(.system(size: 15)).foregroundStyle(Color(Ink.text2)).multilineTextAlignment(.center)
                Button(t.t("voice.openSettings")) {
                    if let u = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(u) }
                }
                .buttonStyle(SmartButtonStyle(prominent: true))
            }
            .padding(.horizontal, 32)
            .padding(.bottom, 40)
        case .failed(let why):
            Text(t.f("voice.failed", why))
                .font(.system(size: 15)).foregroundStyle(Color(Ink.text2))
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)
                .padding(.bottom, 40)
        default:
            VStack(spacing: 8) {
                Button { done() } label: {
                    ZStack {
                        Circle().fill(Color(Ink.accent))
                        if rec.phase == .finishing {
                            ProgressView().tint(.white)
                        } else {
                            RoundedRectangle(cornerRadius: 5).fill(.white).frame(width: 24, height: 24)
                        }
                    }
                    .frame(width: 76, height: 76)
                    .shadow(color: .black.opacity(0.18), radius: 6, y: 3)
                }
                .buttonStyle(.plain)
                .disabled(rec.phase != .recording)
                .accessibilityLabel(t.t("voice.done"))
                Text(rec.phase == .finishing ? t.t("voice.saving") : t.t("voice.done"))
                    .font(.system(size: 14))
                    .foregroundStyle(Color(Ink.text2))
            }
            .padding(.bottom, 36)
        }
    }

    private func begin() async {
        guard !began else { return }
        began = true
        AudioPlayback.shared.stop()
        if app.demo != nil {
            let zh = app.lang.isZh
            rec.fake(text: zh ? ["明天上午九点在二楼会议室开周会，", "记得把上周的报表带上。", "冷却液快没了，晚班记得加。"]
                              : ["Weekly sync tomorrow at nine in room two.", "Bring last week's report.", "Coolant is low, night shift top it up."],
                     seconds: 23)
            return
        }
        await rec.start(languageID: app.settings.voiceLang, t: app.lang)
    }

    private func cancel() {
        rec.cancel()
        app.voiceTarget = nil
    }

    private func done() {
        Task {
            let got = await rec.finish()
            let target = self.target
            app.voiceTarget = nil
            if let got { app.addVoice(file: got.url, text: got.text, target: target) }
        }
    }
}

/// 跳动的竖条：最近一串音量
struct LevelBars: View {
    let levels: [Float]
    let live: Bool
    var body: some View {
        HStack(alignment: .center, spacing: 4) {
            ForEach(levels.indices, id: \.self) { i in
                Capsule()
                    .fill(Color(Ink.accent).opacity(live ? 0.85 : 0.3))
                    .frame(width: 4, height: max(4, CGFloat(levels[i]) * 44))
            }
        }
        .animation(.easeOut(duration: 0.12), value: levels)
    }
}

/// 写字页最上面：这条笔记的录音，一段一行（播放、进度、时长）。听力录音多一个钮，打开播放列表
struct AudioStrip: View {
    let note: Note
    @Environment(AppModel.self) private var app

    var body: some View {
        VStack(spacing: 6) {
            ForEach(note.audioPaths, id: \.self) { p in
                AudioRow(path: p, note: note.id, title: note.title, marks: note.markTable[p] ?? [])
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }
}

struct AudioRow: View {
    let path: String
    var note: UUID? = nil
    var title = ""
    var marks: [ListenMark] = []
    @Environment(AppModel.self) private var app
    private var player: AudioPlayback { AudioPlayback.shared }

    var body: some View {
        let total = player.duration(path, store: app.attachments)
        let mine = player.current == path
        let pos = mine ? player.position : 0
        HStack(spacing: 10) {
            Button { player.toggle(path, store: app.attachments, note: note, marks: marks, title: title) } label: {
                Image(systemName: mine && player.playing ? "pause.fill" : "play.fill")
                    .font(.system(size: 15))
                    .foregroundStyle(.white)
                    .frame(width: 34, height: 34)
                    .background(Circle().fill(Color(Ink.accent)))
                    .hit44()
            }
            .buttonStyle(.plain)
            .accessibilityLabel(mine && player.playing ? app.lang.t("voice.pause") : app.lang.t("voice.play"))

            ProgressLine(position: pos, total: total) { f in
                if mine { player.seek(path, to: f, store: app.attachments) }
            }
            .frame(height: 44)

            Text(mine ? "\(VoiceText.clock(pos)) / \(VoiceText.clock(total))" : VoiceText.clock(total))
                .font(.system(size: 13).monospacedDigit())
                .foregroundStyle(Color(Ink.text2))
                .lineLimit(1)
                .fixedSize()

            if Listen.isListenAudio(path), let note {
                Button { app.listening = ListenOpen(startNote: note) } label: {
                    Image(systemName: "headphones").font(.system(size: 15)).foregroundStyle(Color(Ink.text2)).hit44()
                }
                .buttonStyle(.plain)
                .accessibilityLabel(app.lang.t("listen.title"))
            }
        }
        .padding(.leading, 4)
        .padding(.trailing, 12)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color(Ink.paper).opacity(0.9))
                .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Color(Ink.btnBorder), lineWidth: 0.75))
        )
        .onDisappear { if player.current == path && !player.playlist { player.stop() } }
    }
}

/// 细进度条：点哪跳哪
struct ProgressLine: View {
    let position: TimeInterval
    let total: TimeInterval
    let seek: (Double) -> Void

    var body: some View {
        GeometryReader { g in
            ZStack(alignment: .leading) {
                Capsule().fill(Color(Ink.text3).opacity(0.3)).frame(height: 4)
                Capsule().fill(Color(Ink.accent)).frame(width: total > 0 ? g.size.width * CGFloat(min(1, position / total)) : 0, height: 4)
            }
            .frame(maxHeight: .infinity)
            .contentShape(Rectangle())
            .onTapGesture(coordinateSpace: .local) { x in
                guard g.size.width > 0 else { return }
                seek(Double(x.x / g.size.width))
            }
        }
    }
}
