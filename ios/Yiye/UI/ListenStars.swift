import SwiftUI
import UIKit
import YiyeKit

/// 225：「<嗓子> 配的」和五颗星，点第几颗就是几星（马上寄给大管家）。打了 1、2 星多一行「以后不用 <嗓子>」和「撤回」。
/// 播放条、原文页底下用大的；听完的那几行用小的（只有星）
struct VoiceStars: View {
    let voice: ListenVoice
    let note: UUID
    /// 无障碍号的前缀：bar、sheet、row
    let tag: String
    var small = false
    @Environment(AppModel.self) private var app
    private var t: Lang { app.lang }

    var body: some View {
        let stars = app.shelf.stars(voice)
        VStack(alignment: small ? .leading : .center, spacing: 0) {
            HStack(spacing: 6) {
                if !small {
                    Text(t.f("star.by", voice.shown))
                        .font(.system(size: 13))
                        .foregroundStyle(Color(Ink.text3))
                        .lineLimit(1)
                        .accessibilityIdentifier("star.\(tag).by")
                }
                HStack(spacing: 0) {
                    ForEach(1...5, id: \.self) { n in star(n, stars) }
                }
            }
            if !small && VoiceRatings.banned(stars) {
                HStack(spacing: 4) {
                    Text(t.f("star.banned", voice.shown))
                        .font(.system(size: 13))
                        .foregroundStyle(Color(Ink.text3))
                        .lineLimit(1)
                        .accessibilityIdentifier("star.\(tag).banned")
                    Button { rate(app.shelf.undoStars(voice)) } label: {
                        Text(t.t("star.undo"))
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(Color(Ink.accent))
                            .padding(.horizontal, 8)
                            .frame(minHeight: 30)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("star.\(tag).undo")
                }
            }
        }
    }

    private func star(_ n: Int, _ stars: Int) -> some View {
        Button { rate(n) } label: {
            Image(systemName: n <= stars ? "star.fill" : "star")
                .font(.system(size: small ? 13 : 15))
                .foregroundStyle(Color(n <= stars ? Ink.accent : Ink.text3))
                .frame(width: small ? 28 : 32, height: small ? 28 : 32)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("star.\(tag).\(n)")
        .accessibilityLabel(t.f("star.n", n))
        .accessibilityValue(n <= stars ? "on" : "off")
    }

    private func rate(_ stars: Int) {
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        app.rateVoice(voice, stars: stars, note: note)
    }
}
