import SwiftUI
import UIKit
import Observation
import YiyeKit

// 132 整体配色：白（默认，就是原来那套米黄木头）、黄、绿、蓝、粉。
// 做法：Ink.* 不再是写死的颜色，而是从当前这套配色（Skin）里取；Theme 是 @Observable，
// 界面 body 里一读 Ink.xxx 就自动记下「我依赖配色」，换配色时所有读过的界面自己重画，不用重启、不用重建页面。
// 每种配色 = 亮一套 + 深一套（外观里选深色时用）；整套是拿原来那套米黄换色相换出来的，明暗层次不动。

struct Pair {
    let l: UInt32
    let d: UInt32
    init(_ l: UInt32, _ d: UInt32) { self.l = l; self.d = d }
}

struct Palette {
    var desk: Pair, deskGrainA: Pair, deskGrainB: Pair
    var paper: Pair, paperEdge: Pair
    var text: Pair, text2: Pair, text3: Pair, rule: Pair
    var barTop: Pair, barBottom: Pair, barLine: Pair
    var btnTop: Pair, btnBottom: Pair, btnBorder: Pair, btnPressed: Pair
    var accent: Pair
    var peg: Pair, pegHi: Pair, pegEdge: Pair, pegShadow: Pair

    /// 原来那套（升级前的样子，一个色号都没动）
    static let classic = Palette(
        desk: Pair(0xEAD6B4, 0x1C1814), deskGrainA: Pair(0xD9C19A, 0x272019), deskGrainB: Pair(0xF3E4C8, 0x17130F),
        paper: Pair(0xFBF8F1, 0x2A2622), paperEdge: Pair(0xD8CBB5, 0x3D352D),
        text: Pair(0x4A3F36, 0xE9E1D4), text2: Pair(0x8A7E70, 0xA99F92), text3: Pair(0xB3A795, 0x7D7368), rule: Pair(0xE6DBCA, 0x3B352F),
        barTop: Pair(0xFCF9F3, 0x312C27), barBottom: Pair(0xEEE6D7, 0x27231F), barLine: Pair(0xCFC0A8, 0x484037),
        btnTop: Pair(0xFFFEFB, 0x3D3731), btnBottom: Pair(0xEDE5D7, 0x2F2A25), btnBorder: Pair(0xC9BAA2, 0x544A40), btnPressed: Pair(0xE3D8C6, 0x26221E),
        accent: Pair(0xC2410C, 0xF0915E),
        peg: Pair(0xD2B386, 0x2E2924), pegHi: Pair(0xEBD6AE, 0x4A433B), pegEdge: Pair(0xA88A5E, 0x0F0D0B), pegShadow: Pair(0x6B5638, 0x000000))

    private static let all: [WritableKeyPath<Palette, Pair>] = [
        \.desk, \.deskGrainA, \.deskGrainB, \.paper, \.paperEdge, \.text, \.text2, \.text3, \.rule,
        \.barTop, \.barBottom, \.barLine, \.btnTop, \.btnBottom, \.btnBorder, \.btnPressed,
        \.peg, \.pegHi, \.pegEdge, \.pegShadow,
    ]
    private static let texts: [WritableKeyPath<Palette, Pair>] = [\.text, \.text2, \.text3]

    /// 换成另一种颜色：色相换掉，亮度不动；亮的饱和度乘 light，深的乘 dark（深色底饱和度本来就低，乘得多一点才看得出「带一点那个颜色」）
    static func tinted(hue: Double, light: Double, dark: Double, paperSat: Double, accent: Pair) -> Palette {
        var p = classic
        for k in all {
            let o = classic[keyPath: k]
            let boost = texts.contains(k) ? 1.5 : 1.0     // 字的颜色本来就灰，多给一点才不是一片灰
            p[keyPath: k] = Pair(ThemeMath.recolor(o.l, hue: hue, satScale: light * boost),
                                 ThemeMath.recolor(o.d, hue: hue, satScale: dark * boost))
        }
        // 纸：比换纸的那种颜色再浅一点，列表里「跟整体」的纸和手动钉的同色纸还分得开
        p.paper = Pair(ThemeMath.hex(.init(h: hue, s: paperSat, l: 0.945)), ThemeMath.hex(.init(h: hue, s: 0.16, l: 0.165)))
        p.accent = accent
        return p
    }

    static func of(_ id: String) -> Palette {
        switch id {
        case "yellow": return tinted(hue: 46, light: 1.3, dark: 2.8, paperSat: 0.80, accent: Pair(0xB45309, 0xF0A04B))
        case "green": return tinted(hue: 98, light: 0.85, dark: 2.8, paperSat: 0.60, accent: Pair(0x2E7D32, 0x7CCB82))
        case "blue": return tinted(hue: 210, light: 0.75, dark: 2.8, paperSat: 0.70, accent: Pair(0x1D6FD6, 0x6AA9F2))
        case "pink": return tinted(hue: 8, light: 0.80, dark: 2.8, paperSat: 0.75, accent: Pair(0xC2185B, 0xF27AA6))
        default: return classic
        }
    }
}

/// 一套配色落成的 UIColor（亮暗各一份，跟着系统外观切）。换配色才重新生成，平时取出来的是同一个对象
final class Skin {
    let desk, deskGrainA, deskGrainB, paper, paperEdge: UIColor
    let text, text2, text3, rule: UIColor
    let barTop, barBottom, barLine: UIColor
    let btnTop, btnBottom, btnBorder, btnPressed: UIColor
    let accent: UIColor
    let peg, pegHi, pegEdge, pegShadow: UIColor

    init(_ p: Palette) {
        func c(_ x: Pair) -> UIColor { .dyn(x.l, x.d) }
        desk = c(p.desk); deskGrainA = c(p.deskGrainA); deskGrainB = c(p.deskGrainB); paper = c(p.paper); paperEdge = c(p.paperEdge)
        text = c(p.text); text2 = c(p.text2); text3 = c(p.text3); rule = c(p.rule)
        barTop = c(p.barTop); barBottom = c(p.barBottom); barLine = c(p.barLine)
        btnTop = c(p.btnTop); btnBottom = c(p.btnBottom); btnBorder = c(p.btnBorder); btnPressed = c(p.btnPressed)
        accent = c(p.accent)
        peg = c(p.peg); pegHi = c(p.pegHi); pegEdge = c(p.pegEdge); pegShadow = c(p.pegShadow)
    }
}

@Observable
final class Theme {
    static let ids = ["white", "yellow", "green", "blue", "pink"]
    static let shared = Theme()

    /// white / yellow / green / blue / pink
    private(set) var choice: String
    private(set) var skin: Skin
    @ObservationIgnored private var persist = true

    init() {
        let s = UserDefaults.standard.string(forKey: "yiye.theme") ?? "white"
        let id = Theme.ids.contains(s) ? s : "white"
        choice = id
        skin = Skin(Palette.of(id))
    }

    /// 启动时调一次。截图（demo）不读也不写用户设置：-YiyeTheme green 直接指定
    func start(persist: Bool, forced: String?) {
        self.persist = persist
        guard !persist else { return }
        let id = Theme.ids.contains(forced ?? "") ? forced! : "white"
        choice = id
        skin = Skin(Palette.of(id))
    }

    func set(_ id: String) {
        guard Theme.ids.contains(id), id != choice else { return }
        choice = id
        skin = Skin(Palette.of(id))
        if persist { UserDefaults.standard.set(id, forKey: "yiye.theme") }
    }

    /// 配色选择块上画的两个颜色：底和纸（亮色版）
    static func swatch(_ id: String) -> (desk: UIColor, paper: UIColor) {
        let p = Palette.of(id)
        return (UIColor(hex: p.desk.l), UIColor(hex: p.paper.l))
    }
}

/// 设置里「配色」那一排
struct ThemeSwatches: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        let t = app.lang
        let cur = Theme.shared.choice
        HStack(spacing: 0) {
            ForEach(Theme.ids, id: \.self) { id in
                let sw = Theme.swatch(id)
                let on = id == cur
                Button { withAnimation(.easeOut(duration: 0.2)) { Theme.shared.set(id) } } label: {
                    VStack(spacing: 6) {
                        ZStack {
                            Circle().fill(Color(sw.desk))
                            Circle().fill(Color(sw.paper)).frame(width: 20, height: 20)
                                .overlay(Circle().strokeBorder(Color.black.opacity(0.12), lineWidth: 0.5))
                            if on { Image(systemName: "checkmark").font(.system(size: 11, weight: .bold)).foregroundStyle(Color(Palette.of(id).accent.l.ui)) }
                        }
                        .frame(width: 40, height: 40)
                        .overlay(Circle().strokeBorder(on ? Color(Ink.accent) : Color(Ink.btnBorder), lineWidth: on ? 2 : 0.75))
                        Text(t.t("paper.\(id)")).font(.system(size: 12)).foregroundStyle(Color(on ? Ink.text : Ink.text2))
                    }
                    .frame(maxWidth: .infinity, minHeight: 44)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(t.t("paper.\(id)"))
                .accessibilityAddTraits(on ? .isSelected : [])
            }
        }
    }
}

private extension UInt32 {
    var ui: UIColor { UIColor(hex: self) }
}
