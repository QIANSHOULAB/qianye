import SwiftData
import SwiftUI
import UIKit
import YiyeKit

/// 听力：一张播放列表，跟音乐 app 一样一行一篇，默认只有声音。
/// 听力（kind == listen）只住这儿，便签那边一条都不出现（112）；这里收全：不管哪条路进来、有没有声音都列；听完满 7 天自己进废纸篓，听完的淡一点。
/// 大管家送来的每日简讯直接进（088，Song 11-23 15:05），Song 自己点小耳机放进来的也在。还没声音的也列着，写明在等大管家配音。
/// 按日期分组（088）：一天一个小标题，新的一天在上面，组里新的在上面（简讯 1→6）；放完一篇接下一篇，一天放完接着放前一天的。
/// 每篇放几遍（1/2/3/5/一直），放够了自动下一篇；想看字点那一行后面的「文」
/// 🔁 开着时每天的标题右边一个小圈（144）：亮 = 这天在循环里，可以亮好几天，第一个标题旁边「全部」一下全亮
struct PlaylistScreen: View {
    let open: ListenOpen
    @Environment(AppModel.self) private var app
    @Query(filter: #Predicate<Note> { $0.trashed == false }, sort: \Note.createdAt, order: .reverse)
    private var everything: [Note]
    @State private var textFor: Track?
    @State private var began = false
    /// 小耳机收全（112）：听力不管哪条路进来都在，加上 Song 自己点小耳机放进来的普通便签。条件放在代码里（查询里写太复杂，编译器吃不下）
    private var notes: [Note] { everything.filter { ListenRule.inPlaylist(kind: $0.kind, inListen: $0.inListen, trashed: $0.trashed) } }
    private var player: AudioPlayback { AudioPlayback.shared }
    private var t: Lang { app.lang }

    /// 按天分好的（笔记 createdAt，手机的时区）
    private var days: [ListenDay<UUID>] { ListenDays.group(notes.map { (id: $0.id, at: $0.createdAt) }) }
    /// 144：那几天的「yyyy-MM-dd」，从上到下
    private var dayKeys: [String] { days.map { ListenLoop.key($0.start) } }
    private var today: String { ListenLoop.key(Date()) }

    /// 能放的（有录音的那些），照分组从上到下的顺序
    private var tracks: [Track] {
        let byID = Dictionary(notes.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        return ListenDays.flat(days).compactMap { id in byID[id].flatMap { n in app.track(n) } }
    }

    var body: some View {
        let tracks = self.tracks
        VStack(spacing: 0) {
            SmartBar {
                Button(t.t("listen.close")) { app.listening = nil }
                    .buttonStyle(SmartButtonStyle())
            } center: {
                BarTitle(text: t.t("listen.title"))
            } right: {
                EmptyView()
            }

            if notes.isEmpty {
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
                let byID = Dictionary(notes.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
                let keys = dayKeys
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 8) {
                        ForEach(days, id: \.start) { day in
                            header(day, first: day.start == days.first?.start, keys: keys)
                            ForEach(day.ids, id: \.self) { id in
                                if let n = byID[id] {
                                    if let i = tracks.firstIndex(where: { $0.note == n.id }) {
                                        row(i, tracks, heard: n.heardAt != nil, keys: keys)
                                    } else {
                                        waitingRow(n)
                                    }
                                }
                            }
                        }
                    }
                    .padding(.horizontal, 12)
                    .padding(.bottom, 12)
                }
                PlayerBar(tracks: tracks)
            }
        }
        .background(DeskBackground().ignoresSafeArea())
        .sheet(item: $textFor) { tr in
            TextSheet(track: tr, tracks: tracks).presentationDetents([.medium, .large])
        }
        .onAppear(perform: begin)
        .onChange(of: tracks) { _, new in player.refresh(new) }      // 144：循环到一半来了新稿子，排进去（亮着的话）
    }

    private func begin() {
        guard !began else { return }
        began = true
        player.repeatTarget = app.settings.listenRepeat
        player.rate = Float(app.settings.listenRate)
        let today = self.today
        app.changeLoop { $0.open(today: today) }               // 144：换了一天，回到只亮今天
        let tracks = self.tracks
        guard let id = open.startNote, let i = tracks.firstIndex(where: { $0.note == id }) else { return }
        // 从写字页进来的：直接放这篇
        if player.track?.note != id || !player.playlist {
            let keys = dayKeys, day = tracks[i].day
            app.changeLoop { $0.played(day: day, days: keys, today: today) }
            player.play(tracks, from: i, store: app.attachments)
        }
        if open.showText { textFor = tracks[i] }
    }

    private func row(_ i: Int, _ tracks: [Track], heard: Bool, keys: [String]) -> some View {
        let tr = tracks[i]
        let on = player.playlist && player.track?.note == tr.note
        let total = player.duration(tr.path, store: app.attachments)
        return HStack(spacing: 10) {
            Button {
                if on { player.playing ? player.pause() : player.resume() }
                else {
                    let today = self.today
                    app.changeLoop { $0.played(day: tr.day, days: keys, today: today) }   // 144：点了没亮那天的一篇：循环换成只亮那天
                    player.play(tracks, from: i, store: app.attachments)
                }
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
            .accessibilityIdentifier("listen.row.\(tr.title)")
            .accessibilityValue(on ? "playing" : "")

            textButton(tr)
        }
        .modifier(PlaylistCard())
        .opacity(heard && !on ? 0.55 : 1)          // 听完的淡一点，不加字
    }

    /// 还没声音的一行：在等大管家配音（几点交的、大管家在不在），或者点一下让手机先念
    private func waitingRow(_ n: Note) -> some View {
        let waiting = n.dubRequest != nil
        let here = app.butler.presence.isHere
        let title = n.title.isEmpty ? t.t("note.untitled") : n.title
        let sub: String
        if waiting {
            sub = here ? t.f("listen.waitDub", n.dubSentAt.map { When.short($0, t) } ?? "") : t.t("listen.waitDubAway")
        } else {
            sub = t.t("listen.noAudio")
        }
        return HStack(spacing: 10) {
            Button {
                if !waiting { app.speak(n) }
            } label: {
                HStack(spacing: 12) {
                    Image(systemName: waiting ? "hourglass" : "speaker.wave.2")
                        .font(.system(size: 14))
                        .foregroundStyle(Color(Ink.text2))
                        .frame(width: 34, height: 34)
                        .background(Circle().fill(Color(Ink.text3).opacity(0.14)))
                    VStack(alignment: .leading, spacing: 3) {
                        Text(title)
                            .font(.system(size: 16))
                            .foregroundStyle(Color(Ink.text2))
                            .lineLimit(2)
                            .multilineTextAlignment(.leading)
                        Text(sub)
                            .font(.system(size: 13))
                            .foregroundStyle(waiting && !here ? Color(Ink.danger) : Color(Ink.text3))
                    }
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            // 没在等配音、也没有声音：挂「重配」，走现有的 requestDub（112：不许有哪条听力两边都看不到）
            if !waiting {
                Button(t.t("listen.redub")) { app.dub(n) }
                    .buttonStyle(SmartButtonStyle())
            }
            textButton(Track(note: n.id, path: "", title: title, marks: []))
        }
        .modifier(PlaylistCard())
    }

    private func textButton(_ tr: Track) -> some View {
        Button { textFor = tr } label: { Text(t.t("listen.text")).font(.system(size: 15, weight: .medium)) }
            .buttonStyle(SmartButtonStyle())
            .accessibilityLabel(t.t("listen.showText"))
    }

    /// 一天的小标题；🔁 开着时右边一个小圈（亮 = 这天在循环里），第一个标题旁边还有「全部」（144）
    private func header(_ day: ListenDay<UUID>, first: Bool, keys: [String]) -> some View {
        let key = ListenLoop.key(day.start)
        let loop = app.settings.listenLoop
        let lit = loop.shown(keys).contains(key)
        let title = dayTitle(day.start)
        let today = self.today
        return HStack(alignment: .center, spacing: 2) {
            DayHeader(text: title, top: 0)
            Spacer(minLength: 8)
            if loop.on {
                if first {
                    let all = loop.allLit(keys)
                    Button(t.t("listen.loopEvery")) { app.changeLoop { $0.lightAll(today: today) } }
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(all ? Color(Ink.text3) : Color(Ink.accent))
                        .buttonStyle(.plain)
                        .disabled(all)
                        .padding(.horizontal, 8)
                        .accessibilityIdentifier("listen.loopEvery")
                }
                Button { app.changeLoop { $0.toggle(key, days: keys, today: today) } } label: {
                    Image(systemName: lit ? "checkmark.circle.fill" : "circle")
                        .font(.system(size: 19))
                        .foregroundStyle(lit ? Color(Ink.accent) : Color(Ink.text3))
                        .frame(width: 36, height: 22)
                        .contentShape(Rectangle().inset(by: -11))
                }
                .buttonStyle(.plain)
                .padding(.trailing, 4)
                .accessibilityLabel(t.f("listen.loopDay", title))
                .accessibilityIdentifier("listen.loop.\(key)")
                .accessibilityValue(lit ? "on" : "off")
                .accessibilityAddTraits(lit ? .isSelected : [])
            }
        }
        .padding(.top, 16)
    }

    /// 组的小标题：今天、昨天，再早的写日期加星期（不是今年的带年份）
    private func dayTitle(_ start: Date) -> String {
        switch ListenDays.label(start) {
        case .today: return t.t("listen.today")
        case .yesterday: return t.t("time.yesterday")
        case .date(let d, let withYear):
            let f = DateFormatter()
            f.locale = t.locale
            f.setLocalizedDateFormatFromTemplate(withYear ? (t.isZh ? "yMMMdEEE" : "EEEMMMdy") : (t.isZh ? "MMMdEEE" : "EEEMMMd"))
            return f.string(from: d)
        }
    }

    private func passLine(_ total: TimeInterval) -> String {
        let n = player.passes + 1
        let of = player.repeatTarget == 0 ? "∞" : "\(player.repeatTarget)"
        return "\(VoiceText.clock(player.position)) / \(VoiceText.clock(total))  ·  " + t.f("listen.pass", n) + " / \(of)"
    }
}

/// 一天的小标题：13 号字、灰，跟 iOS 设置的分组标题一个意思（不全大写）
private struct DayHeader: View {
    let text: String
    var top: CGFloat = 16
    var body: some View {
        Text(text)
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(Color(Ink.text2))
            .padding(.leading, 4)
            .padding(.top, top)
            .padding(.bottom, 0)
            .accessibilityAddTraits(.isHeader)
    }
}

/// 播放列表一行的纸片底
private struct PlaylistCard: ViewModifier {
    func body(content: Content) -> some View {
        content
            .padding(.leading, 10)
            .padding(.trailing, 6)
            .padding(.vertical, 8)
            .background(
                RoundedRectangle(cornerRadius: 3)
                    .fill(Color(Ink.paper))
                    .shadow(color: .black.opacity(0.12), radius: 1.5, y: 1)
            )
    }
}

/// 底下的播放条：上一篇、放/停、下一篇，进度，每篇几遍、倍速
struct PlayerBar: View {
    let tracks: [Track]
    @Environment(AppModel.self) private var app
    private var player: AudioPlayback { AudioPlayback.shared }
    private var t: Lang { app.lang }

    /// 144：🔁 开着时大播放钮从亮着的第一篇开始
    private var firstLit: Int {
        let loop = app.settings.listenLoop
        guard loop.on else { return 0 }
        let lit = loop.shown(ListenLoop.ordered(tracks.map(\.day)))
        return tracks.firstIndex { lit.contains($0.day) } ?? 0
    }

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
                    else if !tracks.isEmpty { player.play(tracks, from: firstLit, store: app.attachments) }
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
            HStack(spacing: 8) {
                Segmented(items: [(1, t.t("listen.times1")), (2, t.t("listen.times2")), (3, t.t("listen.times3")), (5, t.t("listen.times5")), (0, t.t("listen.always"))],
                          selection: Binding(get: { settings.listenRepeat }, set: { settings.listenRepeat = $0; player.repeatTarget = $0 }))
                // 🔁 总开关（112 整串循环；144 开着时每天的标题上挑哪几天）。一个图标，开着高亮，不加字
                Button {
                    app.changeLoop { $0.on.toggle() }
                } label: {
                    Image(systemName: "repeat")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(settings.listenLoopAll ? Color.white : Color(Ink.text2))
                        .frame(width: 44, height: 40)
                        .background(RoundedRectangle(cornerRadius: 9, style: .continuous)
                            .fill(settings.listenLoopAll ? Color(Ink.accent) : Color(Ink.text3).opacity(0.14)))
                }
                .buttonStyle(.plain)
                .accessibilityLabel(t.t("listen.loopAll"))
                .accessibilityAddTraits(settings.listenLoopAll ? .isSelected : [])
            }
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
                            // 112：一句一个能选词的文字视图。选中一个词，系统菜单最前面多「已掌握」「难词」；点一下跳到这句
                            SentenceText(text: lines[i], color: now ? Ink.text : Ink.text2,
                                         titles: (t.t("word.markKnown"), t.t("word.markLearning")),
                                         onWord: { w, m in app.markWord(w, m, note: track.note) },
                                         onTap: { tap(i) })
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.vertical, 6)
                                .padding(.horizontal, 10)
                                .background(RoundedRectangle(cornerRadius: 6).fill(now ? Color(Ink.accent).opacity(0.13) : .clear))
                                .id(i)
                        }
                        if track.marks.isEmpty && !track.path.isEmpty {
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
        .background(PaperBackground().ignoresSafeArea())
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
    var id: String { "\(note.uuidString)|\(path)" }
}

/// 一句话的文字：只读、能选词。选中一个词或词组，系统菜单最前面多「已掌握」「难词」（走 AppModel.markWord，大管家那头已经通了）；点一下回调 onTap（跳到这句）
struct SentenceText: UIViewRepresentable {
    let text: String
    let color: UIColor
    let titles: (known: String, learning: String)
    let onWord: (String, WordMark) -> Void
    let onTap: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> UITextView {
        let tv = UITextView()
        tv.isEditable = false
        tv.isSelectable = true
        tv.isScrollEnabled = false
        tv.backgroundColor = .clear
        tv.textContainerInset = .zero
        tv.textContainer.lineFragmentPadding = 0
        tv.delegate = context.coordinator
        let tap = UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.tapped))
        tap.delegate = context.coordinator
        tv.addGestureRecognizer(tap)
        context.coordinator.tv = tv
        return tv
    }

    func updateUIView(_ tv: UITextView, context: Context) {
        let c = context.coordinator
        c.parent = self
        // 放音时整张表每秒刷新好几回：字和颜色没变就别重设，免得选中的词被清掉
        guard c.lastText != text || c.lastColor != color else { return }
        c.lastText = text
        c.lastColor = color
        let para = NSMutableParagraphStyle()
        para.lineSpacing = 5
        tv.attributedText = NSAttributedString(string: text, attributes: [
            .font: UIFont.systemFont(ofSize: 18), .foregroundColor: color, .paragraphStyle: para,
        ])
    }

    func sizeThatFits(_ proposal: ProposedViewSize, uiView: UITextView, context: Context) -> CGSize? {
        let w = proposal.width ?? 320
        let s = uiView.sizeThatFits(CGSize(width: w, height: .greatestFiniteMagnitude))
        return CGSize(width: w, height: ceil(s.height))
    }

    final class Coordinator: NSObject, UITextViewDelegate, UIGestureRecognizerDelegate {
        var parent: SentenceText?
        weak var tv: UITextView?
        var lastText = ""
        var lastColor: UIColor?

        @objc func tapped() { parent?.onTap() }

        // 点的时候已经有选中的词：这一下只是收掉选中和菜单，不跳句
        func gestureRecognizerShouldBegin(_ g: UIGestureRecognizer) -> Bool { (tv?.selectedRange.length ?? 0) == 0 }
        func gestureRecognizer(_ g: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool { true }

        func textView(_ textView: UITextView, editMenuForTextIn range: NSRange, suggestedActions: [UIMenuElement]) -> UIMenu? {
            guard let p = parent, range.length > 0, range.location + range.length <= textView.textStorage.length,
                  let w = WordMark.clean(textView.textStorage.string.sub16(range)) else { return nil }
            let known = UIAction(title: p.titles.known, image: UIImage(systemName: "checkmark")) { _ in p.onWord(w, .known) }
            let learning = UIAction(title: p.titles.learning, image: UIImage(systemName: "arrow.counterclockwise")) { _ in p.onWord(w, .learning) }
            return UIMenu(children: [UIMenu(options: .displayInline, children: [known, learning])] + suggestedActions)
        }
    }
}

extension AppModel {
    /// 144：改 🔁 和亮着的天：存进设置，播放器跟着换
    func changeLoop(_ change: (inout ListenLoop) -> Void) {
        var l = settings.listenLoop
        change(&l)
        settings.listenLoop = l
        AudioPlayback.shared.loop = l
    }
}
