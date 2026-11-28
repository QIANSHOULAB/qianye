import UIKit

/// 252 截图、UI 测试里掌眼寄来的「设计图」：现画的色块，不拿别人的作品。每条两张：裁出来的那块、整屏小图
enum DemoDesign {
    static func pictures() -> [[Data]] {
        let sets: [(UIColor, UIColor)] = [
            (UIColor(red: 0.07, green: 0.07, blue: 0.09, alpha: 1), UIColor(red: 0.95, green: 0.27, blue: 0.16, alpha: 1)),
            (UIColor(red: 0.93, green: 0.92, blue: 0.88, alpha: 1), UIColor(red: 0.18, green: 0.20, blue: 0.24, alpha: 1)),
            (UIColor(red: 0.85, green: 0.84, blue: 0.80, alpha: 1), UIColor(red: 0.45, green: 0.08, blue: 0.14, alpha: 1)),
        ]
        return sets.enumerated().map { n, c in
            [draw(CGSize(width: 900, height: 700), back: c.0, ink: c.1, shape: n, full: false),
             draw(CGSize(width: 720, height: 450), back: c.0, ink: c.1, shape: n, full: true)]
        }
    }

    /// 258 灵感库的假图：三套颜色；每套一张缩略图，原图是裁图、整屏、手机图
    static func library() -> [(thumb: Data, images: [(String, Data)])] {
        let base = pictures()
        let tall = [(UIColor(red: 0.07, green: 0.07, blue: 0.09, alpha: 1), UIColor(red: 0.95, green: 0.27, blue: 0.16, alpha: 1)),
                    (UIColor(red: 0.93, green: 0.92, blue: 0.88, alpha: 1), UIColor(red: 0.18, green: 0.20, blue: 0.24, alpha: 1)),
                    (UIColor(red: 0.85, green: 0.84, blue: 0.80, alpha: 1), UIColor(red: 0.45, green: 0.08, blue: 0.14, alpha: 1))]
        var out: [(thumb: Data, images: [(String, Data)])] = []
        for (n, c) in tall.enumerated() {
            let mobile = draw(CGSize(width: 390, height: 640), back: c.0, ink: c.1, shape: n, full: false)
            // 缩略图高矮错开，照片墙看得出来
            let thumb = [base[n][0], mobile, base[n][1]][n]
            out.append((thumb, [("crop", base[n][0]), ("full", base[n][1]), ("mobile", mobile)]))
        }
        return out
    }

    private static func draw(_ size: CGSize, back: UIColor, ink: UIColor, shape: Int, full: Bool) -> Data {
        let f = UIGraphicsImageRendererFormat()
        f.scale = 1
        return UIGraphicsImageRenderer(size: size, format: f).jpegData(withCompressionQuality: 0.85) { ctx in
            back.setFill()
            ctx.fill(CGRect(origin: .zero, size: size))
            let w = size.width, h = size.height
            let path = UIBezierPath()
            switch shape {
            case 0:                                                   // 一根烧红的铁丝
                path.move(to: CGPoint(x: w * 0.08, y: h * 0.72))
                path.addCurve(to: CGPoint(x: w * 0.92, y: h * 0.28), controlPoint1: CGPoint(x: w * 0.40, y: h * 0.05),
                              controlPoint2: CGPoint(x: w * 0.55, y: h * 0.98))
                path.lineWidth = full ? 4 : 14
            case 1:                                                   // 一团波纹
                for i in 0..<9 {
                    let y = h * 0.25 + CGFloat(i) * h * 0.055
                    path.move(to: CGPoint(x: w * 0.12, y: y))
                    path.addQuadCurve(to: CGPoint(x: w * 0.88, y: y), controlPoint: CGPoint(x: w * 0.5, y: y + (i % 2 == 0 ? h * 0.2 : -h * 0.2)))
                }
                path.lineWidth = full ? 2 : 6
            default:                                                  // 直角垂下的管子
                path.move(to: CGPoint(x: w * 0.1, y: h * 0.3))
                path.addLine(to: CGPoint(x: w * 0.65, y: h * 0.3))
                path.addLine(to: CGPoint(x: w * 0.65, y: h * 0.78))
                path.lineWidth = full ? 16 : 54
            }
            path.lineCapStyle = .round
            path.lineJoinStyle = .round
            ink.setStroke()
            path.stroke()
            if full {                                                 // 整屏：上面一排小字条
                ink.withAlphaComponent(0.55).setFill()
                for i in 0..<4 { ctx.fill(CGRect(x: 32 + CGFloat(i) * 70, y: 24, width: 44, height: 6)) }
                ctx.fill(CGRect(x: w - 120, y: 24, width: 88, height: 6))
                ctx.fill(CGRect(x: 32, y: h - 46, width: 180, height: 14))
            }
        }
    }
}
