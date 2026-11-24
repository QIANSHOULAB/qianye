import ReplayKit
import SwiftUI
import YiyeKit

/// 陪玩现在在干嘛的颜色（104 定的，105 起用在工具箱的小圆点和「陪玩」那一格上）：在听绿，问和说橙，出错红；没直播回 nil
func companionColor(_ p: Companion.Phase) -> UIColor? {
    switch p {
    case .listening, .hearing: return .dyn(0x34C759, 0x30D158)
    case .asking, .speaking: return Ink.accent
    case .failed: return Ink.danger
    case .off: return nil
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
