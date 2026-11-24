import ReplayKit
import SwiftUI
import YiyeKit

/// 工具栏上的陪玩小图标（104，Song 11-24：「直接把它弄个小图标放在我画小圈圈那个地方」）。
/// 没直播：跟旁边按钮一样的灰；直播中：在听 = 绿，问大管家 / 大管家在说 = 主题橙，出错 = 红（另外弹一次 toast，在 Companion.fail 里）。
/// 点一下弹苹果的直播面板（一叶笺已经选好）；直播中再点也是这个面板，里面点停止。
struct CompanionButton: View {
    @Environment(AppModel.self) private var app
    @State private var trigger = BroadcastTrigger()
    private var t: Lang { app.lang }

    var body: some View {
        Button {
            if !trigger.fire() { app.show(t.t("companion.noPanel")) }
        } label: {
            Image(systemName: "dot.radiowaves.left.and.right")
                .foregroundStyle(Color(tint(app.companion.phase)))
        }
        .buttonStyle(SmartButtonStyle())
        .background {
            // 苹果的选择器留在视图层级里（有尺寸、不隐藏、不全透明），点自己的按钮时由 trigger 去按它里面那颗
            BroadcastPicker(trigger: trigger)
                .frame(width: 44, height: 44)
                .opacity(0.01)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
        }
        .accessibilityLabel(t.t("companion.icon"))
    }

    private func tint(_ p: Companion.Phase) -> UIColor {
        switch p {
        case .listening, .hearing: return .dyn(0x34C759, 0x30D158)
        case .asking, .speaking: return Ink.accent
        case .failed: return Ink.danger
        case .off: return Ink.text2
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
