import SwiftUI
import UIKit
import Photos
import CoreText
import YiyeKit

/// 量字：跟画图用同一套 CoreText，量出来和画出来一样宽
final class CTMeasurer: TextMeasurer {
    private var cache: [FontSpec: UIFont] = [:]

    func uiFont(_ f: FontSpec) -> UIFont {
        if let u = cache[f] { return u }
        let w: UIFont.Weight
        switch f.weight {
        case ..<450: w = .regular
        case ..<550: w = .medium
        case ..<650: w = .semibold
        case ..<750: w = .bold
        default: w = .heavy
        }
        let u = UIFont.systemFont(ofSize: CGFloat(f.size), weight: w)
        cache[f] = u
        return u
    }

    func line(_ s: String, _ f: FontSpec, color: UIColor = .black, tracking: Double = 0) -> CTLine {
        var attrs: [NSAttributedString.Key: Any] = [.font: uiFont(f), .foregroundColor: color]
        if tracking != 0 { attrs[.kern] = tracking }
        return CTLineCreateWithAttributedString(NSAttributedString(string: s, attributes: attrs))
    }

    func width(_ s: String, _ f: FontSpec) -> Double {
        Double(CTLineGetTypographicBounds(line(s, f), nil, nil, nil))
    }
}

/// 出图：便签 / 白纸。按 3 倍画，字多就出长图，图上不印日期
enum ShareRenderer {
    static func render(_ markdown: String, theme: ShareTheme, mark: String, latin: Bool, store: AttachmentStore, scale: CGFloat = 3) -> UIImage {
        let m = CTMeasurer()
        let model = Structure.parse(markdown)
        let res = ShareLayout.layout(model, theme: theme, measurer: m, mark: mark, latinMark: latin,
                                     imageSize: { p in store.size(p).map { (Double($0.width), Double($0.height)) } })
        let size = CGSize(width: res.width, height: res.height)
        let fmt = UIGraphicsImageRendererFormat()
        fmt.scale = scale
        fmt.opaque = true
        return UIGraphicsImageRenderer(size: size, format: fmt).image { ctx in
            let cg = ctx.cgContext
            UIColor(theme.bg).setFill()
            cg.fill(CGRect(origin: .zero, size: size))
            for s in PaperNoise.specks(width: res.width, height: res.height, alpha: theme.noiseAlpha, seed: theme.noiseSeed) {
                cg.setFillColor(UIColor(white: s.white ? 1 : 0, alpha: CGFloat(s.alpha)).cgColor)
                cg.fill(CGRect(x: s.x, y: s.y, width: s.size, height: s.size))
            }
            for op in res.ops {
                switch op {
                case .text(let s, let x, let y, let font, let color, let align, let tracking):
                    let line = m.line(s, font, color: UIColor(color), tracking: tracking)
                    let w = CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil))
                    var px = CGFloat(x)
                    if align == .right { px -= w } else if align == .center { px -= w / 2 }
                    cg.saveGState()
                    cg.textMatrix = .identity
                    cg.translateBy(x: px, y: CGFloat(y))
                    cg.scaleBy(x: 1, y: -1)
                    cg.textPosition = .zero
                    CTLineDraw(line, cg)
                    cg.restoreGState()
                case .line(let x1, let y1, let x2, let y2, let color, let width):
                    cg.setStrokeColor(UIColor(color).cgColor)
                    cg.setLineWidth(CGFloat(width))
                    cg.beginPath()
                    cg.move(to: CGPoint(x: x1, y: y1))
                    cg.addLine(to: CGPoint(x: x2, y: y2))
                    cg.strokePath()
                case .rect(let x, let y, let w, let h, let fill, let stroke, let radius):
                    let r = CGRect(x: x, y: y, width: w, height: h)
                    let path = UIBezierPath(roundedRect: r, cornerRadius: CGFloat(radius))
                    if let fill { UIColor(fill).setFill(); path.fill() }
                    if let stroke { UIColor(stroke).setStroke(); path.lineWidth = 1; path.stroke() }
                case .dot(let x, let y, let r, let color):
                    UIColor(color).setFill()
                    cg.fillEllipse(in: CGRect(x: x - r, y: y - r, width: r * 2, height: r * 2))
                case .image(let p, let x, let y, let w, let h):
                    store.image(p)?.draw(in: CGRect(x: x, y: y, width: w, height: h))
                }
            }
        }
    }
}

/// 分享成图：上面是图，底下两个版式缩略图，「保存相册」「分享」
struct ShareScreen: View {
    let note: Note
    var initialTheme = "note"
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    @State private var theme = "note"
    @State private var images: [String: UIImage] = [:]
    @State private var files: [String: URL] = [:]
    @State private var savedMessage: String?
    @State private var saving = false

    private var t: Lang { app.lang }

    var body: some View {
        VStack(spacing: 0) {
            SmartBar {
                Button(t.t("common.close")) { dismiss() }.buttonStyle(SmartButtonStyle())
            } center: {
                BarTitle(text: t.t("share.title"))
            } right: {
                EmptyView()
            }

            ScrollView {
                if let img = images[theme] {
                    Image(uiImage: img)
                        .resizable()
                        .scaledToFit()
                        .clipShape(RoundedRectangle(cornerRadius: 2))
                        .shadow(color: .black.opacity(0.22), radius: 8, y: 3)
                        .padding(.horizontal, 28)
                        .padding(.vertical, 24)
                        .id(theme)
                        .transition(.opacity)
                } else {
                    ProgressView().padding(80)
                }
            }
            .background(DeskBackground())

            VStack(spacing: 12) {
                HStack(spacing: 16) {
                    ForEach(ShareTheme.all, id: \.id) { th in
                        Button { withAnimation(.easeOut(duration: 0.24)) { theme = th.id } } label: {
                            VStack(spacing: 6) {
                                thumb(th.id)
                                    .frame(width: 92, height: 92)
                                    .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                                    .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous)
                                        .strokeBorder(theme == th.id ? Color(Ink.accent) : Color(Ink.btnBorder), lineWidth: theme == th.id ? 2 : 0.75))
                                Text(t.t("theme.\(th.id)"))
                                    .font(.system(size: 13, weight: theme == th.id ? .semibold : .regular))
                                    .foregroundStyle(Color(theme == th.id ? Ink.text : Ink.text2))
                            }
                        }
                        .buttonStyle(.plain)
                    }
                }
                if let savedMessage {
                    Text(savedMessage).font(.system(size: 13)).foregroundStyle(Color(Ink.text2)).transition(.opacity)
                }
                HStack(spacing: 12) {
                    Button { save() } label: {
                        Label(t.t("share.save"), systemImage: "square.and.arrow.down").frame(maxWidth: .infinity)
                    }
                    .buttonStyle(SmartButtonStyle())
                    .disabled(images[theme] == nil || saving)
                    if let url = files[theme] {
                        ShareLink(item: url, preview: SharePreview(note.title.isEmpty ? t.t("app.name") : note.title, image: Image(uiImage: images[theme] ?? UIImage()))) {
                            Label(t.t("share.share"), systemImage: "square.and.arrow.up").frame(maxWidth: .infinity)
                        }
                        .buttonStyle(SmartButtonStyle(prominent: true))
                    } else {
                        Button {} label: { Label(t.t("share.share"), systemImage: "square.and.arrow.up").frame(maxWidth: .infinity) }
                            .buttonStyle(SmartButtonStyle(prominent: true))
                            .disabled(true)
                    }
                }
                .padding(.horizontal, 16)
            }
            .padding(.top, 12)
            .padding(.bottom, 8)
            .background {
                ZStack(alignment: .top) {
                    LinearGradient(colors: [Color(Ink.barTop), Color(Ink.barBottom)], startPoint: .top, endPoint: .bottom)
                    Rectangle().fill(Color(Ink.barLine)).frame(height: 0.5)
                }
                .ignoresSafeArea(edges: .bottom)
            }
        }
        .onAppear {
            theme = initialTheme
            renderAll()
        }
    }

    @ViewBuilder private func thumb(_ id: String) -> some View {
        if let img = images[id] {
            Image(uiImage: img).resizable().scaledToFit().frame(width: 92)
                .frame(width: 92, height: 92, alignment: .top).clipped()
        } else {
            Color(Ink.rule)
        }
    }

    private func renderAll() {
        let md = note.markdown
        let mark = t.t("share.mark")
        let latin = !t.isZh
        for th in ShareTheme.all {
            let img = ShareRenderer.render(md, theme: th, mark: mark, latin: latin, store: app.attachments)
            images[th.id] = img
            if let data = img.pngData() {
                let f = DateFormatter()
                f.dateFormat = "yyyyMMdd_HHmmss"
                let name = "\(t.isZh ? "一叶笺" : "Yiye")_\(f.string(from: Date()))_\(th.id).png"
                let url = FileManager.default.temporaryDirectory.appendingPathComponent(name)
                try? data.write(to: url, options: .atomic)
                files[th.id] = url
            }
        }
    }

    /// 保存相册（只要「添加照片」权限）
    private func save() {
        guard let img = images[theme] else { return }
        saving = true
        PHPhotoLibrary.requestAuthorization(for: .addOnly) { status in
            guard status == .authorized || status == .limited else {
                Task { @MainActor in
                    saving = false
                    withAnimation { savedMessage = t.t("share.noPermission") }
                }
                return
            }
            PHPhotoLibrary.shared().performChanges({
                PHAssetChangeRequest.creationRequestForAsset(from: img)
            }) { ok, err in
                Task { @MainActor in
                    saving = false
                    withAnimation { savedMessage = ok ? t.t("share.saved") : t.f("share.saveFailed", err?.localizedDescription ?? "") }
                }
            }
        }
    }
}
