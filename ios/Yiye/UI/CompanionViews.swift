import ReplayKit
import SwiftUI
import YiyeKit

/// 陪玩模式开着时，便签列表顶上的一条：现在在干嘛 + 「开始直播」（系统的直播按钮，苹果规定要人点一下）
struct CompanionBar: View {
    @Environment(AppModel.self) private var app
    private var t: Lang { app.lang }

    var body: some View {
        let c = app.companion
        HStack(spacing: 10) {
            Circle().fill(Color(dot(c.phase))).frame(width: 9, height: 9)
            VStack(alignment: .leading, spacing: 2) {
                Text(status(c.phase))
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(Color(Ink.text))
                    .lineLimit(2)
                if let s = c.lastTotal, c.live {
                    Text(t.f("companion.last", String(format: "%.1f", s)))
                        .font(.system(size: 12).monospacedDigit())
                        .foregroundStyle(Color(Ink.text3))
                }
            }
            Spacer(minLength: 8)
            ZStack {
                Text(c.live ? t.t("companion.stop") : t.t("companion.start"))
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(c.live ? Color(Ink.text2) : .white)
                    .padding(.horizontal, 14)
                    .frame(height: 34)
                    .background(Capsule().fill(c.live ? Color(Ink.rule) : Color(Ink.accent)))
                BroadcastPicker()
                    .frame(width: 120, height: 44)
                    .opacity(0.02)
            }
            .frame(height: 44)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(c.live ? t.t("companion.stop") : t.t("companion.start"))
            .accessibilityAddTraits(.isButton)
        }
        .padding(.leading, 16)
        .padding(.trailing, 8)
        .padding(.vertical, 6)
        .background {
            RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Color(Ink.paper))
                .shadow(color: Color.black.opacity(0.08), radius: 6, x: 0, y: 2)
        }
        .padding(.horizontal, 12)
        .padding(.bottom, 6)
    }

    private func status(_ p: Companion.Phase) -> String {
        switch p {
        case .off, .waitLive: return t.t("companion.waitLive")
        case .listening: return t.t("companion.listening")
        case .hearing: return t.t("companion.hearing")
        case .asking: return t.t("companion.asking")
        case .speaking: return t.t("companion.speaking")
        case .failed(let why): return t.f("companion.failed", why)
        }
    }

    private func dot(_ p: Companion.Phase) -> UIColor {
        switch p {
        case .listening, .hearing: return .dyn(0x34C759, 0x30D158)
        case .asking, .speaking: return Ink.accent
        case .failed: return Ink.danger
        case .off, .waitLive: return Ink.text3
        }
    }
}

/// 系统的「开始直播」：点了弹苹果的直播面板，一叶笺已经选好
struct BroadcastPicker: UIViewRepresentable {
    func makeUIView(context: Context) -> RPSystemBroadcastPickerView {
        let v = RPSystemBroadcastPickerView(frame: CGRect(x: 0, y: 0, width: 120, height: 44))
        v.preferredExtension = LiveLink.extensionID
        v.showsMicrophoneButton = false
        v.backgroundColor = .clear
        return v
    }

    func updateUIView(_ v: RPSystemBroadcastPickerView, context: Context) {
        for case let b as UIButton in v.subviews { b.frame = v.bounds }
    }
}
