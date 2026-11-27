import SwiftData
import SwiftUI
import Translation
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

/// 原文：一句一行，正在放的那句标亮。点一下选一个词、点两下选整句，弹小卡片给中文意思（222）；
/// 「从这句放」「单句循环」在卡片上和底下那排；「跟着放」开着时正在放的那句自己滚到中间
struct TextSheet: View {
    let track: Track
    let tracks: [Track]
    @Environment(AppModel.self) private var app
    private var player: AudioPlayback { AudioPlayback.shared }
    private var t: Lang { app.lang }

    /// 222：点中的词或整句（卡片开着）
    @State private var pick: TextPick?
    /// 卡片上刚点过的「难词」「已掌握」
    @State private var marked: WordMark?
    /// 手刚碰过文字：跟着放先停一会儿
    @State private var hold = FollowHold()
    /// 长按拖选着字的那一句
    @State private var selecting: Int?
    @State private var frames = RowFrames()
    @State private var translator = PhoneTranslator()

    private var mine: Bool { player.track?.note == track.note && player.current == track.path }
    private var lines: [String] {
        if !track.marks.isEmpty { return track.marks.map(\.s) }
        return Listen.sentences(app.note(track.note)?.markdown ?? "")
    }

    /// 能不能自己滚的几样条件，哪样一变就重新等一回
    private struct FollowKey: Equatable {
        var until: Date?
        var card: Bool
        var selecting: Bool
        var on: Bool
    }
    private var followKey: FollowKey {
        FollowKey(until: hold.until, card: pick != nil, selecting: selecting != nil, on: app.settings.listenFollow)
    }

    var body: some View {
        VStack(spacing: 0) {
            Text(track.title)
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(Color(Ink.text))
                .lineLimit(2)
                .accessibilityIdentifier("listen.sheetTitle")
                .frame(maxWidth: .infinity)
                .padding(.top, 20)
                .padding(.horizontal, 20)
                .contentShape(Rectangle())
                .onTapGesture { close() }
            ScrollViewReader { proxy in
                textArea(self.lines)
                    .task(id: followKey) { await follow(proxy) }
                    .onChange(of: player.sentence) { _, _ in scrollNow(proxy) }
            }
            if !track.marks.isEmpty { bar }
        }
        .coordinateSpace(.named("textsheet"))
        .overlay { cardLayer }
        .background(PaperBackground().ignoresSafeArea())
        .translationTask(translator.config) { [translator = self.translator] session in await translator.run(session) }
        .onAppear(perform: demoPick)
        .onDisappear { translator.cancel() }
    }

    /// 一句一行；点在字外面的空地上收起卡片，一滚也收
    private func textArea(_ lines: [String]) -> some View {
        GeometryReader { geo in
            ScrollView {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(lines.indices, id: \.self) { i in
                        row(i, lines[i])
                    }
                    if track.marks.isEmpty && !track.path.isEmpty {
                        Text(t.t("listen.noTiming")).font(.system(size: 13)).foregroundStyle(Color(Ink.text3)).padding(10)
                    }
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 12)
                .frame(maxWidth: .infinity, minHeight: geo.size.height, alignment: .top)
                .background(Color.clear.contentShape(Rectangle()).onTapGesture { close() })
            }
            .onScrollPhaseChange { old, new in scrolled(old, new) }
        }
    }

    private func row(_ i: Int, _ line: String) -> some View {
        let now = mine && player.sentence == i
        let chosen = pick?.line == i
        let whole = chosen && pick?.range == nil
        let fill: Color = whole ? Color(Ink.accent).opacity(0.26) : now ? Color(Ink.accent).opacity(0.13) : .clear
        return SentenceText(text: line, color: now || whole ? Ink.text : Ink.text2,
                            picked: chosen ? pick?.range : nil,
                            titles: (t.t("word.markKnown"), t.t("word.markLearning")),
                            name: "listen.line.\(i)",
                            onWord: { w, m in app.markWord(w, m, note: track.note) },
                            onTap: { tap in picked(i, line, tap) },
                            onTouch: { hold.touched() },
                            onSelecting: { on in selectionChanged(i, on) })
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 6).fill(fill))
            .overlay {
                if whole { RoundedRectangle(cornerRadius: 6).strokeBorder(Color(Ink.accent), lineWidth: 1.5).allowsHitTesting(false) }
            }
            .onGeometryChange(for: CGRect.self, of: { $0.frame(in: .named("textsheet")) }, action: { frames.map[i] = $0 })
            .id(i)
    }

    /// 底下那排：上一句、单句循环、下一句、跟着放
    private var bar: some View {
        HStack(spacing: 12) {
            Button { close(); hold.clear(); player.previousSentence() } label: { Image(systemName: "backward.fill").font(.system(size: 18)).hit44() }
                .buttonStyle(.plain)
                .accessibilityLabel(t.t("listen.prevSentence"))
            Button { if mine { player.toggleSentenceLoop() } } label: {
                Label(t.t("listen.loopOne"), systemImage: "repeat.1")
                    .font(.system(size: 15, weight: .medium))
                    .lineLimit(1)
            }
            .buttonStyle(SmartButtonStyle(prominent: mine && player.locked != nil))
            Button { close(); hold.clear(); player.nextSentence() } label: { Image(systemName: "forward.fill").font(.system(size: 18)).hit44() }
                .buttonStyle(.plain)
                .accessibilityLabel(t.t("listen.nextSentence"))
            Button {
                app.settings.listenFollow.toggle()
                hold.clear()
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: app.settings.listenFollow ? "checkmark.circle.fill" : "circle").font(.system(size: 14))
                    Text(t.t("listen.follow")).lineLimit(1)
                }
            }
            .buttonStyle(SmartButtonStyle(prominent: app.settings.listenFollow))
            .accessibilityIdentifier("listen.follow")
            .accessibilityValue(app.settings.listenFollow ? "on" : "off")
        }
        .foregroundStyle(Color(Ink.text2))
        .padding(.horizontal, 10)
        .padding(.vertical, 10)
    }

    // ---------------------------------------------------------------- 点词、点句、卡片
    private func picked(_ i: Int, _ line: String, _ tap: SentenceTap) {
        let row = frames.map[i] ?? .zero
        let english = !WordPick.words(in: line).isEmpty
        let whole = TextPick(line: i, range: nil, text: line, area: row, translatable: english)
        switch tap {
        case .word(let r, let w, let rect):
            open(TextPick(line: i, range: r, text: w, area: rect.offsetBy(dx: row.minX, dy: row.minY), translatable: true))
        case .sentence:
            open(whole)
        case .blank:
            // 一个英文词都没有的句子：点一下就给整句的卡片（「从这句放」在那上面）
            if !english && pick == nil { open(whole) } else { close() }
        }
    }

    private func open(_ p: TextPick) {
        marked = nil
        pick = p
        if p.translatable { translator.ask(p.text, demo: app.demo != nil) } else { translator.cancel() }
    }

    private func close() {
        guard pick != nil else { return }
        pick = nil
        marked = nil
        translator.cancel()
    }

    private func selectionChanged(_ i: Int, _ on: Bool) {
        if on {
            close()
            selecting = i
        } else if selecting == i {
            selecting = nil
        }
        hold.touched()
    }

    /// 卡片贴着点中的词（句）：下面地方大放下面，不然放上面，不盖住它（点第二下还落在原处）
    @ViewBuilder private var cardLayer: some View {
        if let p = pick {
            GeometryReader { geo in
                card(p, in: geo.size)
            }
        }
    }

    private func card(_ p: TextPick, in size: CGSize) -> some View {
        let h = size.height, w = size.width
        let below = h - p.area.maxY >= p.area.minY
        let room = max(140, (below ? h - p.area.maxY : p.area.minY) - 12)
        let width = p.range == nil ? max(0, w - 24) : max(0, min(320, w - 24))
        let x = min(max(12, p.area.midX - width / 2), max(12, w - width - 12))
        let above = max(0, min(p.area.maxY + 6, h - room))          // 卡片放下面时，它上头空多少
        let under = max(0, min(h - p.area.minY + 6, h - room))      // 放上面时，它底下空多少
        return VStack(alignment: .leading, spacing: 0) {
            if below {
                Color.clear.frame(width: 1, height: above).allowsHitTesting(false)
            } else {
                Spacer(minLength: 0)
            }
            WordCard(pick: p, state: translator.state, marked: marked, timed: !track.marks.isEmpty,
                     looping: mine && player.locked == p.line, t: t,
                     onMark: { m in mark(p, m) },
                     onPlay: { playFrom(p.line) },
                     onLoop: { loop(p.line) },
                     onRetry: { translator.ask(p.text, demo: app.demo != nil) })
                .frame(width: width)
                .frame(maxHeight: room, alignment: below ? .top : .bottom)
                .layoutPriority(1)
            if below {
                Spacer(minLength: 0)
            } else {
                Color.clear.frame(width: 1, height: under).allowsHitTesting(false)
            }
        }
        .padding(.leading, x)
        .frame(width: w, height: h, alignment: .topLeading)
    }

    private func mark(_ p: TextPick, _ m: WordMark) {
        app.markWord(p.text, m, note: track.note)
        marked = m
    }

    /// 这篇还没在放：先放上这篇
    private func start() {
        if !mine, let k = tracks.firstIndex(where: { $0.note == track.note }) {
            player.play(tracks, from: k, store: app.attachments)
        }
    }

    private func playFrom(_ i: Int) {
        guard !track.marks.isEmpty else { return }
        close()
        hold.clear()
        start()
        player.jump(to: i)
    }

    private func loop(_ i: Int) {
        guard !track.marks.isEmpty else { return }
        start()
        player.loopSentence(i)
    }

    // ---------------------------------------------------------------- 跟着放
    private func scrolled(_ old: ScrollPhase, _ new: ScrollPhase) {
        switch new {
        case .interacting:
            close()             // 一滚，卡片就跟字对不上了
            hold.touched()
        case .tracking, .decelerating:
            hold.touched()
        case .idle:
            if old == .interacting || old == .decelerating { hold.touched() }       // 5 秒从松手算
        default:
            break
        }
    }

    private func scrollNow(_ proxy: ScrollViewProxy) {
        guard mine, let i = player.sentence,
              hold.mayScroll(on: app.settings.listenFollow, card: pick != nil, selecting: selecting != nil) else { return }
        withAnimation(.easeOut(duration: 0.25)) { proxy.scrollTo(i, anchor: .center) }
    }

    /// 停够了（或者卡片收了、开关开了）就回到正在放的那句
    private func follow(_ proxy: ScrollViewProxy) async {
        let wait = hold.left()
        if wait > 0 { try? await Task.sleep(nanoseconds: UInt64((wait + 0.05) * 1_000_000_000)) }
        guard !Task.isCancelled else { return }
        scrollNow(proxy)
    }

    /// 截图用：开着一张卡片的样子
    private func demoPick() {
        guard let s = app.demo?.screen, s == "listen-word" || s == "listen-line" else { return }
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 1_200_000_000)
            let lines = self.lines
            guard lines.count > 1, let row = frames.map[1], let r = WordPick.words(in: lines[1]).first else { return }
            if s == "listen-line" {
                open(TextPick(line: 1, range: nil, text: lines[1], area: row, translatable: true))
            } else {
                let word = (lines[1] as NSString).substring(with: r)
                let area = CGRect(x: row.minX + 10, y: row.minY, width: 64, height: row.height)
                open(TextPick(line: 1, range: r, text: word, area: area, translatable: true))
            }
        }
    }
}

extension Track: Identifiable {
    var id: String { "\(note.uuidString)|\(path)" }
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
