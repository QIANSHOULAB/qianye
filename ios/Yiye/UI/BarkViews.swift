import SwiftUI
import YiyeKit

/// 204 设置里「提醒」那一节：开关「提醒里显示内容」；开着时写清在 Bark 里粘到哪（名字照 Bark 官方文档和它的界面）
struct BarkSettings: View {
    @Environment(AppModel.self) private var app

    private var t: Lang { app.lang }

    var body: some View {
        let m = BarkModel.shared
        VStack(alignment: .leading, spacing: 10) {
            Toggle(isOn: Binding(get: { m.showContent }, set: { m.set($0) })) {
                Text(t.t("bark.show")).font(.system(size: 16)).foregroundStyle(Color(Ink.text))
            }
            .tint(Color(Ink.accent))
            .frame(minHeight: 44)
            .disabled(m.sending)
            .accessibilityIdentifier("bark.toggle")
            Text(t.t(m.showContent ? "bark.steps" : "bark.offNote"))
                .font(.system(size: 13))
                .foregroundStyle(Color(m.showContent ? Ink.text2 : Ink.text3))
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier(m.showContent ? "bark.steps" : "bark.offNote")
            if m.showContent {
                Button(t.t("bark.copyAgain")) { m.copyAgain() }
                    .buttonStyle(SmartButtonStyle())
                    .accessibilityIdentifier("bark.copyAgain")
            }
            if !m.said.isEmpty {
                Text(m.said)
                    .font(.system(size: 13))
                    .foregroundStyle(Color(Ink.text3))
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("bark.said")
            }
        }
    }
}
