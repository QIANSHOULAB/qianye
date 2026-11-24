import SwiftUI
import YiyeKit

/// 工具箱（105，Song 11-24）：顶栏只留便签的按钮（话筒、相机、+），不是便签的功能全收进这个箱子。
/// 以后新的非便签功能往 `Tool` 里加一格就行。
enum Tool: CaseIterable, Identifiable {
    case listen, companion, deep, settings
    var id: Self { self }

    var symbol: String {
        switch self {
        case .listen: return "headphones"
        case .companion: return "dot.radiowaves.left.and.right"
        case .deep: return "brain.head.profile"
        case .settings: return "gearshape"
        }
    }

    var labelKey: String {
        switch self {
        case .listen: return "listen.title"
        case .companion: return "settings.companion"
        case .deep: return "tools.deep"
        case .settings: return "settings.title"
        }
    }
}

/// 顶栏左边的工具箱按钮。直播中右上角带一个小圆点（颜色照陪玩的规矩）。
/// 苹果的直播选择器也留在这里的背景里（有尺寸、不隐藏、不全透明），不管箱子开没开都在视图层级里，「陪玩」那一格由 trigger 去按。
struct ToolboxButton: View {
    @Environment(AppModel.self) private var app
    let trigger: BroadcastTrigger
    let open: () -> Void

    var body: some View {
        Button(action: open) {
            Image(systemName: "shippingbox")
                .overlay(alignment: .topTrailing) {
                    if let l = app.companion.light {
                        CompanionDot(light: l)
                            .frame(width: 9, height: 9)
                            .overlay(Circle().strokeBorder(Color(Ink.btnTop), lineWidth: 1.5))
                            .offset(x: 6, y: -5)
                    }
                }
        }
        .buttonStyle(SmartButtonStyle())
        .background {
            BroadcastPicker(trigger: trigger)
                .frame(width: 44, height: 44)
                .opacity(0.01)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
        }
        .accessibilityLabel(app.lang.t("tools.title"))
    }
}

/// 从顶栏下面落下来的小面板：一格一个工具，图标加两三个字。点一格打开它、面板收起；点面板外面也收起
struct ToolboxPanel: View {
    @Environment(AppModel.self) private var app
    let pick: (Tool) -> Void
    let dismiss: () -> Void

    private let columns = Array(repeating: GridItem(.fixed(80), spacing: 6), count: 3)

    var body: some View {
        ZStack(alignment: .topLeading) {
            Color.black.opacity(0.001)
                .ignoresSafeArea()
                .contentShape(Rectangle())
                .onTapGesture(perform: dismiss)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 6) {
            LazyVGrid(columns: columns, alignment: .leading, spacing: 6) {
                ForEach(Tool.allCases) { tool in
                    Button { pick(tool) } label: {
                        VStack(spacing: 5) {
                            Image(systemName: tool.symbol)
                                .font(.system(size: 22, weight: .regular))
                                .foregroundStyle(Color(tint(tool)))
                                .frame(height: 26)
                            Text(app.lang.t(tool.labelKey))
                                .font(.system(size: 13, weight: .medium))
                                .foregroundStyle(Color(Ink.text))
                                .lineLimit(1)
                                .minimumScaleFactor(0.8)
                        }
                        .frame(width: 80, height: 68)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
            companionLines
            }
            .frame(width: 80 * 3 + 6 * 2, alignment: .leading)      // 面板贴着格子，不拉满整行
            .padding(8)
            .background {
                RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Color(Ink.paper))
                    .shadow(color: Color.black.opacity(0.14), radius: 10, x: 0, y: 4)
            }
            .overlay { RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Color(Ink.paperEdge), lineWidth: 0.75) }
            .padding(.leading, 8)
            .padding(.top, 52 + 2)
        }
        .transition(.opacity.combined(with: .move(edge: .top)))
    }

    /// 「陪玩」那格下面两行小字（108）：上次开听的体检、上一句大管家认出来的字。听歪了、哪样没连上，一眼看得出来
    @ViewBuilder private var companionLines: some View {
        let c = app.companion
        if c.healthLine != nil || c.lastHeard != nil || c.voiceprintLine != nil {
            VStack(alignment: .leading, spacing: 2) {
                if let h = c.healthLine {
                    Text(h)
                }
                if let v = c.voiceprintLine {                  // 117：只认他的声音，攒到哪了
                    Text(v)
                }
                if let w = c.lastHeard {
                    Text("上一句：" + w)
                        .truncationMode(.tail)
                }
            }
            .font(.system(size: 11))
            .foregroundStyle(Color(Ink.text2))
            .lineLimit(1)
            .padding(.horizontal, 6)
            .padding(.bottom, 2)
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityElement(children: .combine)
        }
    }

    private func tint(_ tool: Tool) -> UIColor {
        if tool == .companion, !app.companion.deep, let c = companionColor(app.companion.light) { return c }
        if tool == .deep, app.companion.deep, let c = companionColor(app.companion.light) { return c }
        return Ink.text2
    }
}
