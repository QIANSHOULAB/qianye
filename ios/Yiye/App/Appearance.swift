import SwiftUI
import UIKit
import Observation

/// 外观：跟随系统（默认）/ 纸（一直亮）/ 深色（一直深）。选了立刻生效，记住。
@MainActor @Observable
final class Appearance {
    /// "system" / "paper" / "dark"
    private(set) var choice: String
    @ObservationIgnored private let persist: Bool

    init(persist: Bool, forced: String? = nil) {
        self.persist = persist
        let s = forced ?? (persist ? UserDefaults.standard.string(forKey: "yiye.appearance") : nil)
        choice = ["system", "paper", "dark"].contains(s ?? "") ? s! : "system"
        apply()
    }

    func set(_ c: String) {
        choice = c
        if persist { UserDefaults.standard.set(c, forKey: "yiye.appearance") }
        apply()
    }

    var scheme: ColorScheme? {
        switch choice {
        case "paper": return .light
        case "dark": return .dark
        default: return nil
        }
    }

    var uiStyle: UIUserInterfaceStyle {
        switch choice {
        case "paper": return .light
        case "dark": return .dark
        default: return .unspecified
        }
    }

    /// SwiftUI 的 preferredColorScheme 管不到的 UIKit 弹窗、新开的窗口，一并压成同一个
    func apply() {
        for scene in UIApplication.shared.connectedScenes {
            guard let ws = scene as? UIWindowScene else { continue }
            for w in ws.windows { w.overrideUserInterfaceStyle = uiStyle }
        }
    }
}
