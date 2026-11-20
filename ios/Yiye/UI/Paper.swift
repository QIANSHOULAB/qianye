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
    static let desk = UIColor.dyn(0xE2CFAE, 0x1C1814)
    static let deskGrainA = UIColor.dyn(0xCDB48C, 0x2A231C)
    static let deskGrainB = UIColor.dyn(0xEEDFC4, 0x15120F)
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
    static let clip = UIColor.dyn(0x9A9EA3, 0x8C9096)
    static let clipShine = UIColor.dyn(0xE4E7EA, 0xB9BDC2)
}

extension Color {
    init(_ u: UIColor) { self.init(uiColor: u) }
}

/// 每条笔记能换的纸色
enum PaperTint: String, CaseIterable, Identifiable {
    case white, yellow, green, blue, pink
    var id: String { rawValue }
    var color: UIColor {
        switch self {
        case .white: return Ink.paper
        case .yellow: return .dyn(0xFBF2D2, 0x332D1E)
        case .green: return .dyn(0xEDF3E2, 0x242B21)
        case .blue: return .dyn(0xE8F0F7, 0x1F2730)
        case .pink: return .dyn(0xF9EAE6, 0x322425)
        }
    }
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
            // 木纹：一条条细竖线，左右轻轻摆，首尾接得上（能平铺）
            for i in 0..<70 {
                let x0 = rnd() * size.width
                let amp = 2 + rnd() * 6
                let phase = rnd() * .pi * 2
                let w = 0.6 + rnd() * 1.8
                let c = (i % 3 == 0 ? gb : ga).withAlphaComponent(0.18 + rnd() * 0.28)
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

/// 回形针（纸条左上角那个）：自己画的两道弯
struct PaperClip: View {
    var body: some View {
        Canvas { ctx, size in
            let w = size.width, h = size.height
            var p = Path()
            // 外圈
            p.move(to: CGPoint(x: w * 0.30, y: h * 0.92))
            p.addLine(to: CGPoint(x: w * 0.30, y: h * 0.18))
            p.addArc(center: CGPoint(x: w * 0.5, y: h * 0.18), radius: w * 0.20, startAngle: .degrees(180), endAngle: .degrees(0), clockwise: false)
            p.addLine(to: CGPoint(x: w * 0.70, y: h * 0.80))
            p.addArc(center: CGPoint(x: w * 0.55, y: h * 0.80), radius: w * 0.15, startAngle: .degrees(0), endAngle: .degrees(180), clockwise: false)
            p.addLine(to: CGPoint(x: w * 0.40, y: h * 0.30))
            ctx.stroke(p, with: .color(Color(Ink.clip)), style: StrokeStyle(lineWidth: 2.2, lineCap: .round, lineJoin: .round))
            ctx.stroke(p, with: .color(Color(Ink.clipShine).opacity(0.7)), style: StrokeStyle(lineWidth: 0.8, lineCap: .round, lineJoin: .round))
        }
        .frame(width: 14, height: 34)
        .shadow(color: .black.opacity(0.18), radius: 0.6, x: 0.5, y: 0.8)
    }
}
