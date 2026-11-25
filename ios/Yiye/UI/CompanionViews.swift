import ReplayKit
import SwiftUI
import YiyeKit

/// 陪玩小圆点的颜色（104 定，108 加了闪）：在听绿，判到他在说绿色一闪一闪，等大管家、放回答橙，出错红；没直播回 nil
func companionColor(_ l: CompanionLight?) -> UIColor? {
    switch l {
    case .green?, .greenBlink?: return .dyn(0x34C759, 0x30D158)
    case .orange?: return Ink.accent
    case .red?: return Ink.danger
    case nil: return nil
    }
}

/// 工具箱右上角的小圆点。greenBlink 一秒闪两三下
struct CompanionDot: View {
    let light: CompanionLight

    var body: some View {
        TimelineView(.periodic(from: .now, by: 0.2)) { ctx in
            let on = light != .greenBlink || Int(ctx.date.timeIntervalSinceReferenceDate / 0.4) % 2 == 0
            Circle().fill(Color(companionColor(light) ?? .clear))
                .opacity(on ? 1 : 0.2)
        }
    }
}

/// 替系统的直播选择器按那一下。系统那颗按钮的位置不固定（直接一层、套几层、layoutSubviews 之后才建出来），所以递归找
@MainActor
final class BroadcastTrigger {
    weak var picker: RPSystemBroadcastPickerView?

    /// 按下去了回 true；找不到按钮回 false（界面弹「直播面板叫不出来」，不静默）
    func fire() -> Bool {
        guard let picker else { return false }
        picker.setNeedsLayout()
        picker.layoutIfNeeded()
        guard let b = findFirst(in: picker as UIView, children: { $0.subviews }, where: { $0 is UIButton }) as? UIButton else { return false }
        // 新版 iOS 有的只认 touchDown，两个都发不会坏
        b.sendActions(for: .touchDown)
        b.sendActions(for: .touchUpInside)
        return true
    }
}

/// 系统的「开始直播」选择器：本身不给人点，只是被上面的按钮触发
struct BroadcastPicker: UIViewRepresentable {
    let trigger: BroadcastTrigger

    func makeUIView(context: Context) -> RPSystemBroadcastPickerView {
        let v = RPSystemBroadcastPickerView(frame: CGRect(x: 0, y: 0, width: 44, height: 44))
        v.preferredExtension = LiveLink.extensionID          // nil 也照样弹面板，在面板里自己选一叶笺
        v.showsMicrophoneButton = false
        v.backgroundColor = .clear
        trigger.picker = v
        return v
    }

    func updateUIView(_ v: RPSystemBroadcastPickerView, context: Context) {
        trigger.picker = v
    }
}

/// 139 打电话式：接通了顶上一条小胶囊：在听 / 在想 / 在说 + 挂断。锁屏上没有（那要 Live Activity 扩展，免费签名装不下第 4 个）
struct CallBar: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        let c = app.companion
        if c.callOn {
            HStack(spacing: 10) {
                Circle()
                    .fill(c.phase == .hearing ? Color.green : Color(Ink.accent))
                    .frame(width: 8, height: 8)
                Text(app.lang.t(state(c.phase)))
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Color(Ink.text))
                    .accessibilityIdentifier("call.state")
                Button {
                    c.hangUp(.button)
                } label: {
                    Image(systemName: "phone.down.fill")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(width: 34, height: 26)
                        .background(Capsule().fill(Color(Ink.danger)))
                }
                .buttonStyle(.plain)
                .accessibilityLabel(app.lang.t("call.hangUp"))
                .accessibilityIdentifier("call.hangUp")
            }
            .padding(.leading, 14)
            .padding(.trailing, 6)
            .padding(.vertical, 6)
            .background(Capsule().fill(Color(Ink.paper)).shadow(color: .black.opacity(0.16), radius: 8, y: 3))
            .overlay(Capsule().strokeBorder(Color(Ink.paperEdge), lineWidth: 0.75))
            .padding(.top, 6)
            .transition(.move(edge: .top).combined(with: .opacity))
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("call.bar")
        }
    }

    private func state(_ p: CompanionPhase) -> String {
        switch p {
        case .hearing: return "call.hearing"
        case .asking: return "call.thinking"
        case .speaking: return "call.speaking"
        default: return "call.listening"
        }
    }
}
