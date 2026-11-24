import SwiftUI
import UIKit
import YiyeKit

// 长相：2014 年的便签本——原木色桌面上放着灰白的纸条，写字页是横线信纸。
// 纸纹、木纹都是这里用代码生成的；图标自己画；不用别人的素材和字体。深色是同一张纸的夜里版：暖深灰底、浅字。

extension UIColor {
    convenience init(hex: UInt32, alpha: CGFloat = 1) {
        self.init(red: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
                  blue: CGFloat(hex & 0xFF) / 255, alpha: alpha)
    }

    static func dyn(_ light: UInt32, _ dark: UInt32, _ la: CGFloat = 1, _ da: CGFloat = 1) -> UIColor {
        UIColor { $0.userInterfaceStyle == .dark ? UIColor(hex: dark, alpha: da) : UIColor(hex: light, alpha: la) }
    }

    convenience init(_ c: RGBA) {
        self.init(red: CGFloat(c.r), green: CGFloat(c.g), blue: CGFloat(c.b), alpha: CGFloat(c.a))
    }
}

enum Ink {
    static let desk = UIColor.dyn(0xEAD6B4, 0x1C1814)
    static let deskGrainA = UIColor.dyn(0xD9C19A, 0x272019)
    static let deskGrainB = UIColor.dyn(0xF3E4C8, 0x17130F)
    static let paper = UIColor.dyn(0xFBF8F1, 0x2A2622)
    static let paperEdge = UIColor.dyn(0xD8CBB5, 0x3D352D)
    static let text = UIColor.dyn(0x4A3F36, 0xE9E1D4)
    static let text2 = UIColor.dyn(0x8A7E70, 0xA99F92)
    static let text3 = UIColor.dyn(0xB3A795, 0x7D7368)
    static let rule = UIColor.dyn(0xE6DBCA, 0x3B352F)
    static let barTop = UIColor.dyn(0xFCF9F3, 0x312C27)
    static let barBottom = UIColor.dyn(0xEEE6D7, 0x27231F)
    static let barLine = UIColor.dyn(0xCFC0A8, 0x484037)
    static let btnTop = UIColor.dyn(0xFFFEFB, 0x3D3731)
    static let btnBottom = UIColor.dyn(0xEDE5D7, 0x2F2A25)
    static let btnBorder = UIColor.dyn(0xC9BAA2, 0x544A40)
    static let btnPressed = UIColor.dyn(0xE3D8C6, 0x26221E)
    static let accent = UIColor.dyn(0xC2410C, 0xF0915E)
    static let doubt = UIColor.dyn(0xFFCC00, 0xFFCC00, 0.34, 0.30)
    static let danger = UIColor.dyn(0xC0392B, 0xE36A5A)
    // 小木钉：米色外观是米色木头，深色外观是近黑的木头
    static let peg = UIColor.dyn(0xD2B386, 0x2E2924)
    static let pegHi = UIColor.dyn(0xEBD6AE, 0x4A433B)
    static let pegEdge = UIColor.dyn(0xA88A5E, 0x0F0D0B)
    static let pegShadow = UIColor.dyn(0x6B5638, 0x000000)
    // 排序的两片叶子：深色里压暗，别发荧光
    static let leafYoung = UIColor.dyn(0x8CC152, 0x6E9A45)
    static let leafYoungEdge = UIColor.dyn(0x5E8E2E, 0x47692B)
    static let leafOld = UIColor.dyn(0xC49A3C, 0x93732F)
    static let leafOldEdge = UIColor.dyn(0x8E6A1F, 0x6A4F1C)
}

/// 每条笔记能换的纸色
enum PaperTint: String, CaseIterable, Identifiable {
    case white, yellow, green, blue, pink
    var id: String { rawValue }
    var color: UIColor {
        switch self {
        case .white: return Ink.paper
        case .yellow: return .dyn(0xFBF0CC, 0xFBF0CC)
        case .green: return .dyn(0xE9F2DC, 0xE9F2DC)
        case .blue: return .dyn(0xE3EDF7, 0xE3EDF7)
        case .pink: return .dyn(0xF9E6E1, 0xF9E6E1)
        }
    }
    /// 换了颜色的纸：夜里也照原色，上面的字、横线按白天的来（Song 11-21：「换的米黄色不是米黄色」）
    var keepsLight: Bool { self != .white }
    var key: String { "paper.\(rawValue)" }
}

/// 字号：小、中、大。行高固定，纸上的横线跟着行走
struct EditorMetrics: Equatable {
    let size: CGFloat
    let line: CGFloat
    static func of(_ level: Int) -> EditorMetrics {
        switch level {
        case 0: return EditorMetrics(size: 15, line: 28)
        case 2: return EditorMetrics(size: 20, line: 36)
        default: return EditorMetrics(size: 17, line: 32)
        }
    }
}

// ================================================================ 纹理（代码生成，按深浅各一份缓存）
enum Texture {
    private static var cache: [String: UIImage] = [:]

    /// 原木桌面：竖向木纹 + 一点噪点
    static func desk(dark: Bool) -> UIImage {
        let key = "desk\(dark)"
        if let i = cache[key] { return i }
        let tc = UITraitCollection(userInterfaceStyle: dark ? .dark : .light)
        let base = Ink.desk.resolvedColor(with: tc), ga = Ink.deskGrainA.resolvedColor(with: tc), gb = Ink.deskGrainB.resolvedColor(with: tc)
        let size = CGSize(width: 360, height: 360)
        let fmt = UIGraphicsImageRendererFormat()
        fmt.scale = 2
        fmt.opaque = true
        var seed: UInt64 = dark ? 99 : 7
        func rnd() -> CGFloat { seed = seed &* 6364136223846793005 &+ 1442695040888963407; return CGFloat(seed >> 33) / CGFloat(UInt32.max >> 1) }
        let img = UIGraphicsImageRenderer(size: size, format: fmt).image { ctx in
            let cg = ctx.cgContext
            base.setFill(); cg.fill(CGRect(origin: .zero, size: size))
            // 木纹：一条条细竖线，左右轻轻摆，首尾接得上（能平铺）。第 3 轮跟参照并排看，纹太硬，收淡、收少
            for i in 0..<44 {
                let x0 = rnd() * size.width
                let amp = 2 + rnd() * 6
                let phase = rnd() * .pi * 2
                let w = 0.5 + rnd() * 1.2
                let c = (i % 3 == 0 ? gb : ga).withAlphaComponent(0.10 + rnd() * 0.18)
                cg.setStrokeColor(c.cgColor)
                cg.setLineWidth(w)
                cg.beginPath()
                var y: CGFloat = 0
                cg.move(to: CGPoint(x: x0 + amp * sin(phase), y: 0))
                while y <= size.height {
                    let x = x0 + amp * sin(phase + y / size.height * .pi * 2)
                    cg.addLine(to: CGPoint(x: x, y: y))
                    y += 6
                }
                cg.strokePath()
            }
            for _ in 0..<2600 {
                let v: CGFloat = rnd() < 0.5 ? 0 : 1
                cg.setFillColor(UIColor(white: v, alpha: 0.05 * rnd()).cgColor)
                cg.fill(CGRect(x: rnd() * size.width, y: rnd() * size.height, width: 1, height: 1))
            }
        }
        cache[key] = img
        return img
    }

    /// 纸的噪点（透明底，叠在纸色上）
    static func paperNoise(dark: Bool) -> UIImage {
        let key = "noise\(dark)"
        if let i = cache[key] { return i }
        let size = CGSize(width: 256, height: 256)
        let fmt = UIGraphicsImageRendererFormat()
        fmt.scale = 2
        fmt.opaque = false
        var seed: UInt64 = 11
        func rnd() -> CGFloat { seed = seed &* 6364136223846793005 &+ 1442695040888963407; return CGFloat(seed >> 33) / CGFloat(UInt32.max >> 1) }
        let img = UIGraphicsImageRenderer(size: size, format: fmt).image { ctx in
            let cg = ctx.cgContext
            for _ in 0..<5200 {
                let white = rnd() < 0.5
                cg.setFillColor(UIColor(white: white ? 1 : 0, alpha: (dark ? 0.05 : 0.045) * rnd()).cgColor)
                cg.fill(CGRect(x: rnd() * size.width, y: rnd() * size.height, width: 1, height: 1))
            }
        }
        cache[key] = img
        return img
    }
}

struct DeskBackground: View {
    @Environment(\.colorScheme) private var scheme
    var body: some View {
        Image(uiImage: Texture.desk(dark: scheme == .dark))
            .resizable(resizingMode: .tile)
            .ignoresSafeArea()
    }
}

struct PaperBackground: View {
    var tint: PaperTint = .white
    @Environment(\.colorScheme) private var scheme
    var body: some View {
        ZStack {
            Color(tint.color)
            Image(uiImage: Texture.paperNoise(dark: scheme == .dark)).resizable(resizingMode: .tile)
        }
    }
}

/// 小木钉（纸条左上角那颗）：自己画的圆钉帽 + 一点木纹 + 落在纸上的小影子；颜色跟外观走（米色 / 深色）
struct WoodPeg: View {
    var body: some View {
        Canvas { ctx, size in
            let w = size.width
            let c = CGPoint(x: w * 0.5, y: w * 0.46)
            let r = w * 0.40
            // 纸被钉住的地方：几道浅浅的拉扯褶
            for dx in [-1.0, 1.0] {
                var f = Path()
                f.move(to: CGPoint(x: c.x + dx * r * 0.95, y: c.y + r * 0.9))
                f.addQuadCurve(to: CGPoint(x: c.x + dx * r * 1.55, y: c.y + r * 1.7), control: CGPoint(x: c.x + dx * r * 1.4, y: c.y + r * 1.1))
                ctx.stroke(f, with: .color(Color(Ink.pegShadow).opacity(0.5)), style: StrokeStyle(lineWidth: 0.6, lineCap: .round))
            }
            // 影子：钉帽底下偏右下一道
            let sh = CGRect(x: c.x - r * 0.9, y: c.y + r * 0.45, width: r * 2.1, height: r * 1.2)
            ctx.fill(Path(ellipseIn: sh), with: .color(Color(Ink.pegShadow).opacity(0.38)))
            // 钉帽：略斜着看，所以是压扁的圆
            let cap = CGRect(x: c.x - r, y: c.y - r * 0.92, width: r * 2, height: r * 1.84)
            ctx.fill(Path(ellipseIn: cap), with: .radialGradient(
                Gradient(colors: [Color(Ink.pegHi), Color(Ink.peg)]),
                center: CGPoint(x: c.x - r * 0.35, y: c.y - r * 0.4), startRadius: 0, endRadius: r * 1.5))
            ctx.stroke(Path(ellipseIn: cap), with: .color(Color(Ink.pegEdge)), lineWidth: 0.7)
            // 一点木纹意思
            var g = Path()
            g.move(to: CGPoint(x: c.x - r * 0.55, y: c.y + r * 0.1))
            g.addQuadCurve(to: CGPoint(x: c.x + r * 0.5, y: c.y - r * 0.05), control: CGPoint(x: c.x, y: c.y - r * 0.25))
            ctx.stroke(g, with: .color(Color(Ink.pegEdge).opacity(0.45)), style: StrokeStyle(lineWidth: 0.6, lineCap: .round))
        }
        .frame(width: 22, height: 26)
    }
}

/// 排序用的叶子：新改的在前 = 刚冒出来的嫩芽小叶，老的在前 = 枯黄的老叶
struct LeafIcon: View {
    let young: Bool
    var body: some View {
        Canvas { ctx, size in
            let w = size.width, h = size.height
            var p = Path()
            if young {
                // 嫩芽：小而圆，尖尖微卷
                p.move(to: CGPoint(x: w * 0.18, y: h * 0.88))
                p.addCurve(to: CGPoint(x: w * 0.82, y: h * 0.14), control1: CGPoint(x: w * 0.02, y: h * 0.40), control2: CGPoint(x: w * 0.42, y: h * 0.06))
                p.addCurve(to: CGPoint(x: w * 0.18, y: h * 0.88), control1: CGPoint(x: w * 0.98, y: h * 0.50), control2: CGPoint(x: w * 0.60, y: h * 0.90))
            } else {
                // 老叶：长，边上有点卷，尖朝下
                p.move(to: CGPoint(x: w * 0.12, y: h * 0.12))
                p.addCurve(to: CGPoint(x: w * 0.90, y: h * 0.90), control1: CGPoint(x: w * 0.60, y: h * 0.00), control2: CGPoint(x: w * 1.02, y: h * 0.50))
                p.addCurve(to: CGPoint(x: w * 0.12, y: h * 0.12), control1: CGPoint(x: w * 0.55, y: h * 1.04), control2: CGPoint(x: w * 0.02, y: h * 0.55))
            }
            ctx.fill(p, with: .color(Color(young ? Ink.leafYoung : Ink.leafOld)))
            ctx.stroke(p, with: .color(Color(young ? Ink.leafYoungEdge : Ink.leafOldEdge)), lineWidth: 0.8)
            // 叶脉：老叶更明显
            var v = Path()
            if young {
                v.move(to: CGPoint(x: w * 0.20, y: h * 0.86)); v.addLine(to: CGPoint(x: w * 0.66, y: h * 0.34))
            } else {
                v.move(to: CGPoint(x: w * 0.16, y: h * 0.16)); v.addLine(to: CGPoint(x: w * 0.86, y: h * 0.86))
                for t in [0.3, 0.5, 0.7] {
                    let x = w * (0.16 + 0.70 * t), y = h * (0.16 + 0.70 * t)
                    v.move(to: CGPoint(x: x, y: y)); v.addLine(to: CGPoint(x: x + w * 0.16, y: y - h * 0.10))
                    v.move(to: CGPoint(x: x, y: y)); v.addLine(to: CGPoint(x: x - w * 0.10, y: y + h * 0.16))
                }
            }
            ctx.stroke(v, with: .color(Color(young ? Ink.leafYoungEdge : Ink.leafOldEdge).opacity(young ? 0.7 : 0.9)), style: StrokeStyle(lineWidth: young ? 0.8 : 0.9, lineCap: .round))
        }
        .frame(width: 22, height: 22)
    }
}
