// 录入僧 163：造带 HDR 增益图的 JPG（跟 iPhone 相机拍的一样挂一张增益图）。
// 用法：gain <底图.jpg> <输出.jpg> <apple|iso> <EXIF 方向>
import CoreImage
import Foundation
import ImageIO

let a = CommandLine.arguments
let src = URL(fileURLWithPath: a[1]), dst = URL(fileURLWithPath: a[2]), kind = a[3], orient = Int(a[4]) ?? 1
guard var img = CIImage(contentsOf: src) else { print("读不了底图"); exit(1) }
var props = img.properties
props[kCGImagePropertyOrientation as String] = orient
img = img.settingProperties(props)
let ctx = CIContext()
let p3 = CGColorSpace(name: CGColorSpace.displayP3)!
var data: Data?
if kind == "apple" {
    // 增益图：半尺寸灰图，中间亮一块（像窗户）
    let w = img.extent.width / 2, h = img.extent.height / 2
    let base = CIImage(color: CIColor(red: 0.25, green: 0.25, blue: 0.25)).cropped(to: CGRect(x: 0, y: 0, width: w, height: h))
    let spot = CIImage(color: CIColor(red: 0.9, green: 0.9, blue: 0.9)).cropped(to: CGRect(x: w * 0.3, y: h * 0.3, width: w * 0.3, height: h * 0.3))
    let gm = spot.composited(over: base)
    data = ctx.jpegRepresentation(of: img, colorSpace: p3, options: [.hdrGainMapImage: gm,
                                                                    CIImageRepresentationOption(rawValue: kCGImageDestinationLossyCompressionQuality as String): 0.92])
} else {
    // ISO 21496：拿一张 HDR 图（亮处推到 2 倍）让 CoreImage 自己算增益图
    let hdr = img.applyingFilter("CIColorMatrix", parameters: ["inputRVector": CIVector(x: 2, y: 0, z: 0, w: 0),
                                                                "inputGVector": CIVector(x: 0, y: 2, z: 0, w: 0),
                                                                "inputBVector": CIVector(x: 0, y: 0, z: 2, w: 0)])
    if #available(macOS 15.0, *) {
        data = ctx.jpegRepresentation(of: img, colorSpace: p3, options: [.hdrImage: hdr,
                                                                        CIImageRepresentationOption(rawValue: kCGImageDestinationLossyCompressionQuality as String): 0.92])
    }
}
guard let d = data else { print("造不出来"); exit(1) }
try d.write(to: dst)
print("ok \(d.count) bytes")
