import Foundation

// 132 整体配色。两件事的纯逻辑，放这儿好单测：
// 1. 一张便签的纸是「跟整体」还是「手动钉住的」；
// 2. 一个十六进制颜色换成另一个色相（整套配色就是拿原来那套米黄换色相换出来的）。

/// 便签的纸记在 Note.paper 这个字符串里。
/// "white"（老便签全是这个，新建的也是）= 跟整体配色；"yellow/green/blue/pink" = 手动换过，钉住；
/// "white-pin" = 手动点了「白」，钉住（老数据分不出默认白和手动白，所以老的 white 一律算跟整体）。
public enum PaperMark {
    public static let follow = "white"
    public static let pinnedWhite = "white-pin"
    /// 镜像文件 color 一项里，跟整体写这个（不写死成某种颜色）
    public static let mirrorFollow = "follow"
    public static let colors = ["white", "yellow", "green", "blue", "pink"]

    /// 钉住的纸色：nil = 跟整体。不认识的值当跟整体
    public static func pinned(_ stored: String) -> String? {
        if stored == pinnedWhite { return "white" }
        if stored == follow || stored.isEmpty { return nil }
        return colors.contains(stored) ? stored : nil
    }

    /// 手动点了某个颜色：记成钉住的（白也算）
    public static func store(pick color: String) -> String {
        color == "white" ? pinnedWhite : (colors.contains(color) ? color : follow)
    }

    public static func toMirror(_ stored: String) -> String {
        pinned(stored) == nil ? mirrorFollow : stored
    }

    /// 镜像里读回来：follow 和老的 white 都是跟整体；其余照记
    public static func fromMirror(_ value: String) -> String {
        if value == mirrorFollow || value.isEmpty { return follow }
        return pinned(value) == nil ? follow : value
    }
}

/// 颜色换算：0xRRGGBB ↔ HSL，换色相、乘饱和度、拉亮度
public enum ThemeMath {
    public struct HSL: Equatable, Sendable {
        public var h: Double   // 0..360
        public var s: Double   // 0..1
        public var l: Double   // 0..1
        public init(h: Double, s: Double, l: Double) { self.h = h; self.s = s; self.l = l }
    }

    public static func hsl(_ hex: UInt32) -> HSL {
        let r = Double((hex >> 16) & 0xFF) / 255, g = Double((hex >> 8) & 0xFF) / 255, b = Double(hex & 0xFF) / 255
        let mx = max(r, g, b), mn = min(r, g, b)
        let l = (mx + mn) / 2
        guard mx != mn else { return HSL(h: 0, s: 0, l: l) }
        let d = mx - mn
        let s = l > 0.5 ? d / (2 - mx - mn) : d / (mx + mn)
        var h: Double
        if mx == r { h = (g - b) / d + (g < b ? 6 : 0) }
        else if mx == g { h = (b - r) / d + 2 }
        else { h = (r - g) / d + 4 }
        h *= 60
        return HSL(h: h, s: s, l: l)
    }

    public static func hex(_ c: HSL) -> UInt32 {
        let h = (c.h.truncatingRemainder(dividingBy: 360) + 360).truncatingRemainder(dividingBy: 360) / 360
        let s = min(1, max(0, c.s)), l = min(1, max(0, c.l))
        func ch(_ t0: Double, _ p: Double, _ q: Double) -> Double {
            var t = t0
            if t < 0 { t += 1 }
            if t > 1 { t -= 1 }
            if t < 1.0 / 6 { return p + (q - p) * 6 * t }
            if t < 0.5 { return q }
            if t < 2.0 / 3 { return p + (q - p) * (2.0 / 3 - t) * 6 }
            return p
        }
        let r: Double, g: Double, b: Double
        if s == 0 { r = l; g = l; b = l } else {
            let q = l < 0.5 ? l * (1 + s) : l + s - l * s
            let p = 2 * l - q
            r = ch(h + 1.0 / 3, p, q); g = ch(h, p, q); b = ch(h - 1.0 / 3, p, q)
        }
        func byte(_ x: Double) -> UInt32 { UInt32((min(1, max(0, x)) * 255).rounded()) }
        return (byte(r) << 16) | (byte(g) << 8) | byte(b)
    }

    /// 换色相、饱和度乘一个系数；亮度不动（整套配色的明暗层次原样保住）
    public static func recolor(_ hex: UInt32, hue: Double, satScale: Double) -> UInt32 {
        var c = self.hsl(hex)
        c.h = hue
        c.s = min(1, c.s * satScale)
        return Self.hex(c)
    }

    /// 相对亮度（WCAG），看字和底够不够分得开
    public static func luminance(_ hex: UInt32) -> Double {
        func lin(_ v: UInt32) -> Double {
            let x = Double(v) / 255
            return x <= 0.03928 ? x / 12.92 : pow((x + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * lin((hex >> 16) & 0xFF) + 0.7152 * lin((hex >> 8) & 0xFF) + 0.0722 * lin(hex & 0xFF)
    }

    public static func contrast(_ a: UInt32, _ b: UInt32) -> Double {
        let x = luminance(a), y = luminance(b)
        return (max(x, y) + 0.05) / (min(x, y) + 0.05)
    }
}
