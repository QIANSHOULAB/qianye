import SwiftUI
import UIKit

// 顶栏、按钮、提示条全部自己画，不用系统导航栏（免得 iOS 26 自动套上液态玻璃）。
// 顶栏：纸色渐变 + 底下一道细线；按钮：圆角小方块，浅浅的立体（2014 年那种）。

struct SmartBar<Left: View, Center: View, Right: View>: View {
    let left: Left
    let center: Center
    let right: Right

    init(@ViewBuilder left: () -> Left, @ViewBuilder center: () -> Center, @ViewBuilder right: () -> Right) {
        self.left = left(); self.center = center(); self.right = right()
    }

    var body: some View {
        ZStack {
            center
                .frame(maxWidth: .infinity)
                .padding(.horizontal, 104)
            HStack(spacing: 4) {
                left
                Spacer(minLength: 0)
                right
            }
            .padding(.horizontal, 8)
        }
        .frame(height: 52)
        .background(alignment: .bottom) {
            ZStack(alignment: .bottom) {
                LinearGradient(colors: [Color(Ink.barTop), Color(Ink.barBottom)], startPoint: .top, endPoint: .bottom)
                Rectangle().fill(Color(Ink.barLine)).frame(height: 0.5)
            }
            .shadow(color: .black.opacity(0.10), radius: 2, y: 1)
            .ignoresSafeArea(edges: .top)
        }
        .zIndex(2)
    }
}

/// 顶栏上的标题
struct BarTitle: View {
    let text: String
    var body: some View {
        Text(text)
            .font(.system(size: 17, weight: .semibold))
            .foregroundStyle(Color(Ink.text))
            .lineLimit(1)
            .shadow(color: .white.opacity(0.6), radius: 0, y: 0.5)
    }
}

/// 2014 年那种按钮：圆角小方块，上亮下暗，一圈细边
struct SmartButtonStyle: ButtonStyle {
    var prominent = false
    var minWidth: CGFloat = 40

    func makeBody(configuration: Configuration) -> some View {
        let pressed = configuration.isPressed
        return configuration.label
            .font(.system(size: 15, weight: .medium))
            .foregroundStyle(prominent ? Color.white : Color(Ink.text2))
            .padding(.horizontal, 10)
            .frame(minWidth: minWidth, minHeight: 32)
            .background {
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(prominent
                          ? AnyShapeStyle(LinearGradient(colors: [Color(Ink.accent).opacity(pressed ? 0.85 : 1), Color(Ink.accent).opacity(pressed ? 0.8 : 0.92)], startPoint: .top, endPoint: .bottom))
                          : AnyShapeStyle(LinearGradient(colors: pressed ? [Color(Ink.btnPressed), Color(Ink.btnPressed)] : [Color(Ink.btnTop), Color(Ink.btnBottom)], startPoint: .top, endPoint: .bottom)))
            }
            .overlay {
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .strokeBorder(prominent ? Color.black.opacity(0.12) : Color(Ink.btnBorder), lineWidth: 0.75)
            }
            .shadow(color: .black.opacity(pressed ? 0 : 0.07), radius: 0.5, y: 0.75)
            .frame(minWidth: 44, minHeight: 44)
            .contentShape(Rectangle())
            .animation(.easeOut(duration: 0.2), value: pressed)
    }
}

/// 纯字按钮（次要操作）
struct PlainTextButtonStyle: ButtonStyle {
    var color: UIColor = Ink.accent
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 15, weight: .semibold))
            .foregroundStyle(Color(color).opacity(configuration.isPressed ? 0.5 : 1))
            .frame(minHeight: 44)
            .contentShape(Rectangle())
    }
}

/// 底下的提示条：一句话 + 一个动作（删了给「撤销」）
struct ToastView: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        Group {
            if let t = app.toast {
                HStack(spacing: 12) {
                    Text(t.text)
                        .font(.system(size: 15))
                        .foregroundStyle(Color(Ink.paper))
                        .lineLimit(2)
                    if let a = t.actionTitle, let run = t.action {
                        Spacer(minLength: 4)
                        Button(a) { run() }
                            .buttonStyle(PlainTextButtonStyle(color: .dyn(0xFFB27A, 0xC2410C)))
                    }
                }
                .padding(.horizontal, 16)
                .frame(minHeight: 48)
                .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color(Ink.text).opacity(0.94)))
                .padding(.horizontal, 16)
                .padding(.bottom, 24)
                .transition(.move(edge: .bottom).combined(with: .opacity))
                .id(t.id)
            }
        }
        .animation(.easeOut(duration: 0.24), value: app.toast?.id)
    }
}

/// 超过一秒的活：小转圈 + 一句在干啥
struct BusyOverlay: View {
    @Environment(AppModel.self) private var app
    var body: some View {
        ZStack {
            Color.black.opacity(0.12).ignoresSafeArea()
            HStack(spacing: 12) {
                ProgressView().tint(Color(Ink.text2))
                Text(app.busy ?? "").font(.system(size: 15)).foregroundStyle(Color(Ink.text))
            }
            .padding(.horizontal, 20)
            .frame(minHeight: 52)
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color(Ink.paper)))
            .shadow(color: .black.opacity(0.15), radius: 12, y: 4)
        }
        .transition(.opacity)
    }
}

/// 分段选择（二选一、三选一），自己画
/// 只放图标的分段控件（样子同 Segmented）；label 只给读屏用，屏幕上不显示
struct IconSegmented<T: Hashable>: View {
    let items: [(T, String, AnyView)]
    @Binding var selection: T

    var body: some View {
        HStack(spacing: 0) {
            ForEach(items.indices, id: \.self) { i in
                let it = items[i]
                let on = it.0 == selection
                Button { withAnimation(.easeOut(duration: 0.2)) { selection = it.0 } } label: {
                    it.2
                        .opacity(on ? 1 : 0.55)
                        .frame(maxWidth: .infinity, minHeight: 32)
                        .background {
                            if on {
                                RoundedRectangle(cornerRadius: 6, style: .continuous)
                                    .fill(LinearGradient(colors: [Color(Ink.btnTop), Color(Ink.btnBottom)], startPoint: .top, endPoint: .bottom))
                                    .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous).strokeBorder(Color(Ink.btnBorder), lineWidth: 0.75))
                                    .shadow(color: .black.opacity(0.08), radius: 0.5, y: 0.75)
                            }
                        }
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .frame(minHeight: 44)
                .accessibilityLabel(it.1)
                .accessibilityAddTraits(on ? .isSelected : [])
            }
        }
        .padding(3)
        .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(Color(Ink.text3).opacity(0.18)))
    }
}

struct Segmented<T: Hashable>: View {
    let items: [(T, String)]
    @Binding var selection: T

    var body: some View {
        HStack(spacing: 0) {
            ForEach(items.indices, id: \.self) { i in
                let it = items[i]
                let on = it.0 == selection
                Button { withAnimation(.easeOut(duration: 0.2)) { selection = it.0 } } label: {
                    Text(it.1)
                        .font(.system(size: 14, weight: on ? .semibold : .regular))
                        .foregroundStyle(on ? Color(Ink.text) : Color(Ink.text2))
                        .frame(maxWidth: .infinity, minHeight: 32)
                        .background {
                            if on {
                                RoundedRectangle(cornerRadius: 6, style: .continuous)
                                    .fill(LinearGradient(colors: [Color(Ink.btnTop), Color(Ink.btnBottom)], startPoint: .top, endPoint: .bottom))
                                    .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous).strokeBorder(Color(Ink.btnBorder), lineWidth: 0.75))
                                    .shadow(color: .black.opacity(0.08), radius: 0.5, y: 0.75)
                            }
                        }
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .frame(minHeight: 44)
            }
        }
        .padding(3)
        .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(Color(Ink.text3).opacity(0.18)))
    }
}

extension View {
    /// 换了颜色的纸上那一块：夜里也按白天的颜色画
    @ViewBuilder func lightIf(_ on: Bool) -> some View {
        if on { self.environment(\.colorScheme, .light) } else { self }
    }

    /// 能点的地方 ≥ 44
    func hit44() -> some View { frame(minWidth: 44, minHeight: 44).contentShape(Rectangle()) }
}
