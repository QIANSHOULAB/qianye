import SwiftUI
import YiyeKit

/// 听力：一张播放列表，跟音乐 app 一样一行一篇，默认只有声音。
/// 每篇放几遍（1/2/3/5/一直），放够了自动下一篇；想看字点那一行后面的「文」
struct PlaylistScreen: View {
    let open: ListenOpen
    @Environment(AppModel.self) private var app
    @State private var tracks: [Track] = []
    @State private var textFor: Track?
    @State private var began = false
    private var player: AudioPlayback { AudioPlayback.shared }
    private var t: Lang { app.lang }

    var body: some View {
        VStack(spacing: 0) {
            SmartBar {
                Button(t.t("listen.close")) { app.listening = nil }
                    .buttonStyle(SmartButtonStyle())
            } center: {
                BarTitle(text: t.t("listen.title"))
            } right: {
                EmptyView()
            }

            if tracks.isEmpty {
                VStack(spacing: 12) {
                    Spacer()
                    Image(systemName: "headphones").font(.system(size: 34)).foregroundStyle(Color(Ink.text3))
                    Text(t.t("listen.empty"))
                        .font(.system(size: 16))
                        .foregroundStyle(Color(Ink.text2))
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 32)
                    Spacer()
                    Spacer()
                }
                .frame(maxWidth: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: 8) {
                        ForEach(tracks.indices, id: \.self) { i in row(i) }
                    }
                    .padding(12)
                }
                PlayerBar(tracks: tracks)
            }
        }
        .background(DeskBackground().ignoresSafeArea())
        .sheet(item: $textFor) { tr in
            TextSheet(track: tr, tracks: tracks).presentationDetents([.medium, .large])
        }
        .onAppear(perform: begin)
    }

    private func begin() {
        guard !began else { return }
        began = true
        tracks = app.listenTracks()
        player.repeatTarget = app.settings.listenRepeat
        player.rate = Float(app.settings.listenRate)
        guard let id = open.startNote, let i = tracks.firstIndex(where: { $0.note == id }) else { return }
        // 从写字页、「念出来」进来的：直接放这篇
        if player.track?.note != id || !player.playlist { player.play(tracks, from: i, store: app.attachments) }
        if open.showText { textFor = tracks[i] }
    }

    private func row(_ i: Int) -> some View {
        let tr = tracks[i]
        let on = player.playlist && player.track?.note == tr.note
        let total = player.duration(tr.path, store: app.attachments)
        return HStack(spacing: 10) {
            Button {
                if on { player.playing ? player.pause() : player.resume() }
                else { player.play(tracks, from: i, store: app.attachments) }
            } label: {
                HStack(spacing: 12) {
                    Image(systemName: on && player.playing ? "pause.fill" : "play.fill")
                        .font(.system(size: 14))
                        .foregroundStyle(on ? Color.white : Color(Ink.accent))
                        .frame(width: 34, height: 34)
                        .background(Circle().fill(on ? Color(Ink.accent) : Color(Ink.accent).opacity(0.12)))
                    VStack(alignment: .leading, spacing: 3) {
                        Text(tr.title)
                            .font(.system(size: 16, weight: on ? .semibold : .regular))
                            .foregroundStyle(Color(Ink.text))
                            .lineLimit(2)
                            .multilineTextAlignment(.leading)
                        Text(on ? passLine(total) : VoiceText.clock(total))
                            .font(.system(size: 13).monospacedDigit())
                            .foregroundStyle(on ? Color(Ink.accent) : Color(Ink.text3))
                    }
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            Button { textFor = tr } label: { Text(t.t("listen.text")).font(.system(size: 15, weight: .medium)) }
                .buttonStyle(SmartButtonStyle())
                .accessibilityLabel(t.t("listen.showText"))
        }
        .padding(.leading, 10)
        .padding(.trailing, 6)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 3)
                .fill(Color(Ink.paper))
                .shadow(color: .black.opacity(0.12), radius: 1.5, y: 1)
        )
    }

    private func passLine(_ total: TimeInterval) -> String {
        let n = player.passes + 1
        let of = player.repeatTarget == 0 ? "∞" : "\(player.repeatTarget)"
        return "\(VoiceText.clock(player.position)) / \(VoiceText.clock(total))  ·  " + t.f("listen.pass", n) + " / \(of)"
    }
}

/// 底下的播放条：上一篇、放/停、下一篇，进度，每篇几遍、倍速
struct PlayerBar: View {
    let tracks: [Track]
    @Environment(AppModel.self) private var app
    private var player: AudioPlayback { AudioPlayback.shared }
    private var t: Lang { app.lang }

    var body: some View {
        @Bindable var settings = app.settings
        VStack(spacing: 10) {
            if let tr = player.playlist ? player.track : nil {
                Text(tr.title).font(.system(size: 14, weight: .semibold)).foregroundStyle(Color(Ink.text)).lineLimit(1)
                HStack(spacing: 8) {
                    Text(VoiceText.clock(player.position)).font(.system(size: 12).monospacedDigit()).foregroundStyle(Color(Ink.text3))
                    ProgressLine(position: player.position, total: player.duration) { f in
                        player.seek(tr.path, to: f, store: app.attachments)
                    }
                    .frame(height: 28)
                    Text(VoiceText.clock(player.duration)).font(.system(size: 12).monospacedDigit()).foregroundStyle(Color(Ink.text3))
                }
            }
            HStack(spacing: 28) {
                Button { player.previousTrack() } label: { Image(systemName: "backward.end.fill").font(.system(size: 20)).hit44() }
                    .accessibilityLabel(t.t("listen.prev"))
                Button {
                    if player.playlist, player.track != nil { player.playing ? player.pause() : player.resume() }
                    else if !tracks.isEmpty { player.play(tracks, from: 0, store: app.attachments) }
                } label: {
                    Image(systemName: player.playlist && player.playing ? "pause.fill" : "play.fill")
                        .font(.system(size: 22))
                        .foregroundStyle(.white)
                        .frame(width: 56, height: 56)
                        .background(Circle().fill(Color(Ink.accent)))
                }
                .accessibilityLabel(player.playing ? t.t("voice.pause") : t.t("voice.play"))
                Button { player.nextTrack() } label: { Image(systemName: "forward.end.fill").font(.system(size: 20)).hit44() }
                    .accessibilityLabel(t.t("listen.next"))
            }
            .buttonStyle(.plain)
            .foregroundStyle(Color(Ink.text2))
            Segmented(items: [(1, t.t("listen.times1")), (2, t.t("listen.times2")), (3, t.t("listen.times3")), (5, t.t("listen.times5")), (0, t.t("listen.always"))],
                      selection: Binding(get: { settings.listenRepeat }, set: { settings.listenRepeat = $0; player.repeatTarget = $0 }))
            Segmented(items: [(0.75, "0.75×"), (1.0, "1×"), (1.25, "1.25×")],
                      selection: Binding(get: { settings.listenRate }, set: { settings.listenRate = $0; player.rate = Float($0) }))
        }
        .padding(.horizontal, 16)
        .padding(.top, 12)
        .padding(.bottom, 8)
        .background {
            ZStack(alignment: .top) {
                LinearGradient(colors: [Color(Ink.barTop), Color(Ink.barBottom)], startPoint: .top, endPoint: .bottom)
                Rectangle().fill(Color(Ink.barLine)).frame(height: 0.5)
            }
            .ignoresSafeArea(edges: .bottom)
        }
    }
}

/// 原文：一句一行，正在放的那句标出来；点哪句从哪句放；能锁住一句反复听
struct TextSheet: View {
    let track: Track
    let tracks: [Track]
    @Environment(AppModel.self) private var app
    private var player: AudioPlayback { AudioPlayback.shared }
    private var t: Lang { app.lang }

    private var mine: Bool { player.track?.note == track.note && player.current == track.path }
    private var lines: [String] {
        if !track.marks.isEmpty { return track.marks.map(\.s) }
        return Listen.sentences(app.note(track.note)?.markdown ?? "")
    }

    var body: some View {
        VStack(spacing: 0) {
            Text(track.title)
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(Color(Ink.text))
                .lineLimit(2)
                .padding(.top, 20)
                .padding(.horizontal, 20)
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(lines.indices, id: \.self) { i in
                            let now = mine && player.sentence == i
                            Text(lines[i])
                                .font(.system(size: 18))
                                .lineSpacing(5)
                                .foregroundStyle(now ? Color(Ink.text) : Color(Ink.text2))
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.vertical, 6)
                                .padding(.horizontal, 10)
                                .background(RoundedRectangle(cornerRadius: 6).fill(now ? Color(Ink.accent).opacity(0.13) : .clear))
                                .contentShape(Rectangle())
                                .onTapGesture { tap(i) }
                                .id(i)
                        }
                        if track.marks.isEmpty {
                            Text(t.t("listen.noTiming")).font(.system(size: 13)).foregroundStyle(Color(Ink.text3)).padding(10)
                        }
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 12)
                }
                .onChange(of: player.sentence) { _, i in
                    guard mine, let i else { return }
                    withAnimation(.easeOut(duration: 0.25)) { proxy.scrollTo(i, anchor: .center) }
                }
            }
            if !track.marks.isEmpty {
                HStack(spacing: 24) {
                    Button { player.previousSentence() } label: { Image(systemName: "backward.fill").font(.system(size: 18)).hit44() }
                        .accessibilityLabel(t.t("listen.prevSentence"))
                    Button { if mine { player.toggleSentenceLoop() } } label: {
                        Label(t.t("listen.loopOne"), systemImage: "repeat.1")
                            .font(.system(size: 15, weight: .medium))
                    }
                    .buttonStyle(SmartButtonStyle(prominent: mine && player.locked != nil))
                    Button { player.nextSentence() } label: { Image(systemName: "forward.fill").font(.system(size: 18)).hit44() }
                        .accessibilityLabel(t.t("listen.nextSentence"))
                }
                .buttonStyle(.plain)
                .foregroundStyle(Color(Ink.text2))
                .padding(.vertical, 10)
            }
        }
        .background(PaperBackground(tint: .white).ignoresSafeArea())
    }

    private func tap(_ i: Int) {
        guard !track.marks.isEmpty else { return }
        if !mine, let k = tracks.firstIndex(where: { $0.note == track.note }) {
            player.play(tracks, from: k, store: app.attachments)
        }
        player.jump(to: i)
    }
}

extension Track: Identifiable {
    var id: String { path }
}
