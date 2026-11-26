import SwiftUI
import UIKit
import YiyeKit

/// 172 遥控：工具箱里的一格。先选电脑 / 掌机（只有在线的点得动），然后是那台的截图：
/// 点一下 = 左键，长按 = 右键，两指上下滑 = 滚轮；底下打字发送，「密码」开着只显示点点。关掉这一页 = 结束。
struct RemoteSheet: View {
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss

    private var t: Lang { app.lang }

    var body: some View {
        @Bindable var m = RemoteModel.shared
        VStack(spacing: 0) {
            HStack(spacing: 14) {
                BarTitle(text: m.target.map { t.t($0 == .desk ? "remote.desk" : "remote.handheld") } ?? t.t("remote.title"))
                Spacer()
                if m.target != nil {
                    if (m.state.screens ?? 1) > 1 {
                        Button(t.t("remote.screen")) { m.switchScreen() }.buttonStyle(PlainTextButtonStyle())
                    }
                    Button(t.t("remote.end")) { m.stop() }
                        .buttonStyle(PlainTextButtonStyle())
                        .accessibilityIdentifier("remote.end")
                }
                Button(t.t("common.done")) { m.stop(); dismiss() }.buttonStyle(PlainTextButtonStyle())
            }
            .padding(.horizontal, 16)
            .frame(height: 52)

            if m.target == nil {
                pick(m)
            } else {
                screen(m)
                bottom(m)
            }
        }
        .background(Color(Ink.paper).ignoresSafeArea())
        .onDisappear { RemoteModel.shared.stop() }
    }

    // ---------------------------------------------------------------- 选哪台
    private func pick(_ m: RemoteModel) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(t.t("remote.pick"))
                .font(.system(size: 17, weight: .medium))
                .foregroundStyle(Color(Ink.text))
            HStack(spacing: 12) {
                machine(.desk, symbol: "desktopcomputer", m)
                machine(.handheld, symbol: "gamecontroller", m)
            }
            if let l = m.line {
                Text(l).font(.system(size: 14)).foregroundStyle(Color(Ink.text2))
            }
            Text(t.t("remote.hint"))
                .font(.system(size: 13))
                .foregroundStyle(Color(Ink.text2))
                .fixedSize(horizontal: false, vertical: true)
            Spacer()
        }
        .padding(16)
    }

    private func machine(_ target: RemoteTarget, symbol: String, _ m: RemoteModel) -> some View {
        let on = m.online.contains(target)
        return Button { m.start(target) } label: {
            VStack(spacing: 6) {
                Image(systemName: symbol).font(.system(size: 28))
                Text(t.t(target == .desk ? "remote.desk" : "remote.handheld")).font(.system(size: 15, weight: .medium))
                if !on {
                    Text(t.t("remote.offline")).font(.system(size: 12)).foregroundStyle(Color(Ink.text2))
                }
            }
            .frame(maxWidth: .infinity, minHeight: 96)
            .foregroundStyle(Color(on ? Ink.accent : Ink.text2))
            .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Color(Ink.btnTop)))
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Color(Ink.paperEdge), lineWidth: 0.75))
        }
        .buttonStyle(.plain)
        .disabled(!on)
        .accessibilityIdentifier("remote.pick.\(target.rawValue)")
    }

    // ---------------------------------------------------------------- 那台的屏
    private func screen(_ m: RemoteModel) -> some View {
        VStack(spacing: 6) {
            ZStack {
                if let img = m.image {
                    Image(uiImage: img)
                        .resizable()
                        .scaledToFit()
                        .overlay {
                            RemotePad(imageSize: img.size,
                                      tap: { x, y in m.tap(x, y) },
                                      press: { x, y in m.tap(x, y, right: true) },
                                      scroll: { x, y, n in m.scroll(x, y, notches: n) })
                        }
                } else {
                    ProgressView()
                }
            }
            .frame(maxWidth: .infinity)
            .frame(minHeight: 160)
            HStack(spacing: 6) {
                if m.waiting { ProgressView().controlSize(.mini) }
                Text(m.line ?? "")
                    .font(.system(size: 13))
                    .foregroundStyle(Color(Ink.text2))
                    .lineLimit(2)
                Spacer()
            }
            .padding(.horizontal, 16)
            if app.demo != nil {                                   // UI 测试看：上一下寄出去的（不含密码）
                Text(m.lastSent)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(Color(Ink.text2))
                    .accessibilityIdentifier("remote.sent")
            }
            Spacer(minLength: 0)
        }
    }

    // ---------------------------------------------------------------- 打字、密码
    private func bottom(_ m: RemoteModel) -> some View {
        @Bindable var m = m
        return HStack(spacing: 8) {
            Group {
                if m.password {
                    SecureField(t.t("remote.passInput"), text: $m.draft)
                        .accessibilityIdentifier("remote.input.secure")
                } else {
                    TextField(t.t("remote.input"), text: $m.draft)
                        .accessibilityIdentifier("remote.input")
                }
            }
            .font(.system(size: 17))
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
            .submitLabel(.send)
            .onSubmit { m.sendDraft() }
            .padding(.horizontal, 12)
            .frame(height: 42)
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color(Ink.btnTop)))

            Button {
                m.password.toggle()
            } label: {
                Image(systemName: m.password ? "lock.fill" : "lock.open")
                    .font(.system(size: 18))
                    .frame(width: 40, height: 42)
                    .foregroundStyle(Color(m.password ? Ink.accent : Ink.text2))
            }
            .buttonStyle(.plain)
            .accessibilityLabel(t.t("remote.password"))
            .accessibilityValue(m.password ? "on" : "off")
            .accessibilityIdentifier("remote.passToggle")

            Button(t.t("remote.send")) { m.sendDraft() }
                .buttonStyle(PlainTextButtonStyle())
                .disabled(m.draft.isEmpty)
                .accessibilityIdentifier("remote.send")
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 10)
    }
}

/// 截图上面盖一层看不见的 UIView 接手势（UIKit 的识别器，133 那回 SwiftUI 的手势互相抢过）：
/// 点 = 左键、长按 = 右键、两指上下滑 = 滚轮。位置换成那张图上的比例（这层跟图一样大，图是等比放的）
struct RemotePad: UIViewRepresentable {
    let imageSize: CGSize
    let tap: (Double, Double) -> Void
    let press: (Double, Double) -> Void
    let scroll: (Double, Double, Int) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeUIView(context: Context) -> UIView {
        let v = UIView()
        v.backgroundColor = .clear
        v.isAccessibilityElement = true
        v.accessibilityIdentifier = "remote.screen"
        v.accessibilityTraits = .allowsDirectInteraction
        let c = context.coordinator
        let lp = UILongPressGestureRecognizer(target: c, action: #selector(Coordinator.pressed(_:)))
        lp.minimumPressDuration = 0.5
        let tp = UITapGestureRecognizer(target: c, action: #selector(Coordinator.tapped(_:)))
        tp.require(toFail: lp)                         // 松得快：长按马上作废，点不慢
        let pan = UIPanGestureRecognizer(target: c, action: #selector(Coordinator.panned(_:)))
        pan.minimumNumberOfTouches = 2
        pan.maximumNumberOfTouches = 2
        v.addGestureRecognizer(lp)
        v.addGestureRecognizer(tp)
        v.addGestureRecognizer(pan)
        return v
    }

    func updateUIView(_ uiView: UIView, context: Context) {
        context.coordinator.parent = self
    }

    final class Coordinator: NSObject {
        var parent: RemotePad
        init(_ p: RemotePad) { parent = p }

        private func where_(_ g: UIGestureRecognizer) -> (Double, Double)? {
            guard let v = g.view else { return nil }
            let p = g.location(in: v)
            guard let n = RemoteMap.normalized((Double(p.x), Double(p.y)), view: (Double(v.bounds.width), Double(v.bounds.height)),
                                               image: (Double(parent.imageSize.width), Double(parent.imageSize.height))) else { return nil }
            return (n.x, n.y)
        }

        @objc func tapped(_ g: UITapGestureRecognizer) {
            guard g.state == .ended, let p = where_(g) else { return }
            parent.tap(p.0, p.1)
        }

        @objc func pressed(_ g: UILongPressGestureRecognizer) {
            guard g.state == .began, let p = where_(g) else { return }
            UIImpactFeedbackGenerator(style: .medium).impactOccurred()
            parent.press(p.0, p.1)
        }

        @objc func panned(_ g: UIPanGestureRecognizer) {
            guard g.state == .ended, let v = g.view, let p = where_(g) else { return }
            parent.scroll(p.0, p.1, RemoteMap.notches(dragY: Double(g.translation(in: v).y)))
        }
    }
}
