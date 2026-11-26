import SwiftUI
import UIKit
import UIKit.UIGestureRecognizerSubclass
import YiyeKit

/// 172 遥控：工具箱里的一格。先选电脑 / 掌机（只有在线的点得动），然后是那台的截图：
/// 点一下 = 左键，长按 = 右键，两指上下滑 = 滚轮；底下打字发送，「密码」开着只显示点点。关掉这一页 = 结束。
/// 181：两指张合在手机上放大缩小截图（1×…5×，不寄给那台）；放大了一指拖 = 挪图，点哪儿还是哪儿；右下角「1×」回整屏。
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
        .interactiveDismissDisabled(m.zoom.zoomed)               // 181：放大着往下拖是挪图，别把这一页拖关了
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
                    // 框 = 整张图等比放进去的那一块；放大是把图在框里放大、挪，框外面裁掉
                    Color.clear
                        .aspectRatio(img.size.width / max(img.size.height, 1), contentMode: .fit)
                        .overlay {
                            GeometryReader { g in
                                Image(uiImage: img)
                                    .resizable()
                                    .frame(width: g.size.width, height: g.size.height)
                                    .scaleEffect(m.zoom.scale, anchor: .topLeading)
                                    .offset(x: m.zoom.x * g.size.width, y: m.zoom.y * g.size.height)
                            }
                        }
                        .clipped()
                        .overlay {
                            RemotePad(imageSize: img.size,
                                      zoom: m.zoom,
                                      setZoom: { m.zoom = $0 },
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
                if m.zoom.zoomed {                                 // 181：放在图右下角外面，不盖住画面（边角上的叉要点得到）
                    Button { m.zoom = RemoteZoom() } label: {
                        Text("1×")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(Color(Ink.accent))
                            .padding(.horizontal, 14)
                            .frame(height: 30)
                            .background(Capsule().fill(Color(Ink.btnTop)))
                            .overlay(Capsule().strokeBorder(Color(Ink.paperEdge), lineWidth: 0.75))
                            .contentShape(Capsule())
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("remote.zoomReset")
                }
            }
            .frame(minHeight: 30)
            .padding(.horizontal, 16)
            if app.demo != nil {                                   // UI 测试看：上一下寄出去的（不含密码）、放大到哪儿
                Text(m.lastSent)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(Color(Ink.text2))
                    .accessibilityIdentifier("remote.sent")
                Text(String(format: "%.3f %.3f %.3f", m.zoom.scale, m.zoom.x, m.zoom.y))
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(Color(Ink.text2))
                    .accessibilityIdentifier("remote.zoom")
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
/// 点 = 左键、长按 = 右键、两指上下滑 = 滚轮；两指张合 = 手机上放大缩小，放大了一指拖 = 挪图（这两样不寄）。
/// 位置换成那张图上的比例（这层跟框一样大，图是等比放的；放大了按手指下面那一点算）
struct RemotePad: UIViewRepresentable {
    let imageSize: CGSize
    let zoom: RemoteZoom
    let setZoom: (RemoteZoom) -> Void
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
        let drag = RemoteDrag(target: c, action: #selector(Coordinator.dragged(_:)))
        drag.canPan = { [weak c] in c?.parent.zoom.zoomed ?? false }
        drag.delegate = c
        lp.delegate = c
        tp.delegate = c
        v.isMultipleTouchEnabled = true
        v.addGestureRecognizer(lp)
        v.addGestureRecognizer(tp)
        v.addGestureRecognizer(drag)
        return v
    }

    func updateUIView(_ uiView: UIView, context: Context) {
        context.coordinator.parent = self
    }

    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        var parent: RemotePad
        /// 这一趟拖开头时的放大样子
        private var panStart: RemoteZoom?
        private var zoomStart: RemoteZoom?
        /// 刚有过两根手指：紧跟着抬起来的那一根不算点
        private var twoAt = Date.distantPast
        init(_ p: RemotePad) { parent = p }

        /// 手指在框里的哪儿（按框的几分之几）
        private func inFrame(_ p: (x: Double, y: Double), _ v: UIView) -> (x: Double, y: Double) {
            (p.x / max(Double(v.bounds.width), 1), p.y / max(Double(v.bounds.height), 1))
        }

        /// 框里那一点下面是图上哪儿（图外面的空白：nil）
        private func picture(_ p: CGPoint, _ v: UIView) -> (Double, Double)? {
            guard let n = RemoteMap.normalized((Double(p.x), Double(p.y)), view: (Double(v.bounds.width), Double(v.bounds.height)),
                                               image: (Double(parent.imageSize.width), Double(parent.imageSize.height))) else { return nil }
            let q = parent.zoom.picture((n.x, n.y))
            return (q.x, q.y)
        }

        private func where_(_ g: UIGestureRecognizer) -> (Double, Double)? {
            guard let v = g.view, Date().timeIntervalSince(twoAt) > 0.35 else { return nil }
            return picture(g.location(in: v), v)
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

        @objc func dragged(_ g: RemoteDrag) {
            guard let v = g.view else { return }
            switch g.state {
            case .began, .changed:
                if g.mode == .two, let t = g.two {
                    twoAt = Date()
                    guard t.kind == .zoom else { return }
                    let from = zoomStart ?? parent.zoom
                    zoomStart = from
                    parent.setZoom(from.pinched(factor: t.factor, from: inFrame((t.startX, t.startY), v), to: inFrame((t.midX, t.midY), v)))
                } else if g.mode == .pan {
                    let from = panStart ?? parent.zoom
                    panStart = from
                    let d = inFrame((Double(g.translation.x), Double(g.translation.y)), v)
                    parent.setZoom(from.moved(dx: d.x, dy: d.y))
                }
            case .ended:
                if g.mode == .two, let t = g.two {
                    twoAt = Date()
                    if t.kind == .scroll, let p = picture(CGPoint(x: t.midX, y: t.midY), v) {
                        parent.scroll(p.0, p.1, RemoteMap.notches(dragY: t.travelY))
                    }
                }
                panStart = nil; zoomStart = nil
            default:
                panStart = nil; zoomStart = nil
            }
        }

        /// 两根手指按着的时候，点、长按都不算（张合之前停一下，别冒出个右键）
        func gestureRecognizerShouldBegin(_ g: UIGestureRecognizer) -> Bool {
            if g is RemoteDrag { return true }
            return !(g.view?.gestureRecognizers?.contains { ($0 as? RemoteDrag)?.two != nil } ?? false)
        }

        /// 外面的拖（这一页往下拖关掉）等我们认不认：放大了挪图、两指缩放的时候不让它抢
        func gestureRecognizer(_ g: UIGestureRecognizer, shouldBeRequiredToFailBy other: UIGestureRecognizer) -> Bool {
            g is RemoteDrag && other is UIPanGestureRecognizer && other.view !== g.view
        }
    }
}

/// 181 截图上的拖：一根手指拖（放大了才认）= 挪图；两根手指 = 缩放或者滚轮（YiyeKit TwoFingers 认），认定了到抬手不换。
/// 先落一根、第二根晚一点落下也算两指
final class RemoteDrag: UIGestureRecognizer {
    enum Mode { case none, pan, two }
    var canPan: () -> Bool = { false }
    private(set) var mode: Mode = .none
    private(set) var two: TwoFingers?
    /// 一指拖了多远（点）
    private(set) var translation = CGPoint.zero
    private var fingers: [UITouch] = []
    private var origin = CGPoint.zero

    private func spot(_ i: Int) -> (x: Double, y: Double) {
        let p = fingers[i].location(in: view)
        return (Double(p.x), Double(p.y))
    }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent) {
        super.touchesBegan(touches, with: event)
        for t in touches {
            if fingers.count < 2 { fingers.append(t) } else { ignore(t, for: event) }
        }
        if fingers.count == 1 { origin = fingers[0].location(in: view) }
        if fingers.count == 2, two == nil { two = TwoFingers(spot(0), spot(1)) }
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent) {
        super.touchesMoved(touches, with: event)
        if fingers.count == 2, var t = two {
            let kind = t.move(spot(0), spot(1))
            two = t
            guard kind != .undecided else { return }
            mode = .two
            state = state == .possible ? .began : .changed
        } else if fingers.count == 1 {
            let p = fingers[0].location(in: view)
            translation = CGPoint(x: p.x - origin.x, y: p.y - origin.y)
            if state == .possible {
                let far = hypot(translation.x, translation.y)
                if canPan() {
                    if far > 10 { mode = .pan; state = .began }
                } else if far > 30 {
                    state = .failed                      // 没放大：一指拖不归我们（照旧能把这一页拖下去）
                }
            } else {
                state = .changed
            }
        }
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent) {
        super.touchesEnded(touches, with: event)
        guard touches.contains(where: { fingers.contains($0) }) else { return }
        state = (state == .began || state == .changed) ? .ended : .failed
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent) {
        super.touchesCancelled(touches, with: event)
        state = (state == .began || state == .changed) ? .cancelled : .failed
    }

    override func reset() {
        super.reset()
        fingers = []
        two = nil
        mode = .none
        translation = .zero
    }
}
