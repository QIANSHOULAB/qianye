import SwiftUI
import UIKit

/// 原图对照（123）：从顶栏下面展开，占上半屏，下面还是便签的字，照样能滚、能改。几张原图左右滑，双指放大、拖动，双击放大 / 还原。
/// 键盘弹起（compact）时缩到屏幕的三分之一不到，别把字挤没了。
struct OriginalPanel: View {
    let paths: [String]
    let compact: Bool
    @Environment(AppModel.self) private var app
    @State private var images: [UIImage?] = []
    @State private var page = 0

    var body: some View {
        let h = UIScreen.main.bounds.height * (compact ? 0.22 : 0.46)
        TabView(selection: $page) {
            ForEach(paths.indices, id: \.self) { i in
                Group {
                    if i < images.count, let img = images[i] {
                        ZoomableImage(image: img)
                    } else if i < images.count {
                        Text(app.lang.t("editor.originalMissing"))
                            .font(.system(size: 14))
                            .foregroundStyle(Color(Ink.text3))
                            .padding(24)
                    } else {
                        Color.clear
                    }
                }
                .tag(i)
            }
        }
        .tabViewStyle(.page(indexDisplayMode: paths.count > 1 ? .automatic : .never))
        .frame(height: h)
        .frame(maxWidth: .infinity)
        .background(Color(Ink.text).opacity(0.06))
        .overlay(alignment: .bottom) { Rectangle().fill(Color(Ink.barLine)).frame(height: 0.5) }
        .animation(.easeOut(duration: 0.2), value: compact)
        .onAppear {
            // 图只读一回，放大缩小不会被重读重置
            if images.count != paths.count { images = paths.map { app.attachments.image($0) } }
        }
    }
}

/// 能双指放大、拖动、双击放大 / 还原的一张图
struct ZoomableImage: UIViewRepresentable {
    let image: UIImage
    /// 252：机器人的图：给 UI 测试认的名字、点一下、长按
    var name: String?
    var onTap: (() -> Void)?
    var onLongPress: (() -> Void)?

    func makeUIView(context: Context) -> ZoomScroll {
        let v = ZoomScroll()
        v.setImage(image)
        v.listen(name: name, tap: onTap, longPress: onLongPress)
        return v
    }

    func updateUIView(_ v: ZoomScroll, context: Context) {
        v.setImage(image)
        v.listen(name: name, tap: onTap, longPress: onLongPress)
    }
}

final class ZoomScroll: UIScrollView, UIScrollViewDelegate {
    private let iv = UIImageView()
    private var current: UIImage?
    private let double = UITapGestureRecognizer(target: nil, action: nil)
    private var single: UITapGestureRecognizer?
    private var press: UILongPressGestureRecognizer?
    private var onTap: (() -> Void)?
    private var onLongPress: (() -> Void)?

    init() {
        super.init(frame: .zero)
        delegate = self
        minimumZoomScale = 1
        maximumZoomScale = 5
        showsHorizontalScrollIndicator = false
        showsVerticalScrollIndicator = false
        bouncesZoom = true
        iv.contentMode = .scaleAspectFit
        addSubview(iv)
        double.addTarget(self, action: #selector(doubleTapped(_:)))
        double.numberOfTapsRequired = 2
        addGestureRecognizer(double)
    }

    func listen(name: String?, tap: (() -> Void)?, longPress: (() -> Void)?) {
        if let name {
            iv.isAccessibilityElement = true
            iv.accessibilityIdentifier = name
            iv.accessibilityTraits = .image
        }
        onTap = tap
        onLongPress = longPress
        if tap != nil && single == nil {
            let g = UITapGestureRecognizer(target: self, action: #selector(tapped))
            g.require(toFail: double)
            addGestureRecognizer(g)
            single = g
        }
        if longPress != nil && press == nil {
            let g = UILongPressGestureRecognizer(target: self, action: #selector(pressed(_:)))
            addGestureRecognizer(g)
            press = g
        }
    }

    @objc private func tapped() { onTap?() }

    @objc private func pressed(_ g: UILongPressGestureRecognizer) { if g.state == .began { onLongPress?() } }

    required init?(coder: NSCoder) { fatalError("init(coder:)") }

    func setImage(_ i: UIImage) {
        guard current !== i else { return }
        current = i
        iv.image = i
        zoomScale = 1
        setNeedsLayout()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        if zoomScale == 1 {
            iv.frame = bounds
            contentSize = bounds.size
        }
    }

    func viewForZooming(in scrollView: UIScrollView) -> UIView? { iv }

    @objc private func doubleTapped(_ g: UITapGestureRecognizer) {
        if zoomScale > 1.01 {
            setZoomScale(1, animated: true)
        } else {
            let p = g.location(in: iv)
            let w = bounds.width / 2.5, h = bounds.height / 2.5
            zoom(to: CGRect(x: p.x - w / 2, y: p.y - h / 2, width: w, height: h), animated: true)
        }
    }
}
