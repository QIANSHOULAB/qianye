import SwiftUI
import SwiftData

@main
struct YiyeApp: App {
    @State private var app = AppModel.shared
    @Environment(\.scenePhase) private var phase

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(app)
                .modelContainer(app.container)
                .environment(\.locale, app.lang.locale)
                .preferredColorScheme(app.demo?.forcedScheme ?? app.appearance.scheme)
                .onChange(of: phase) { _, p in
                    app.scenePhase(p)
                    if p == .active { app.appearance.apply() }
                    if p == .background { DoveModel.shared.wipeKey() }      // 128：钥匙不在后台的内存里留着
                }
        }
    }
}

struct RootView: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        @Bindable var app = app
        @Bindable var dove = DoveModel.shared
        @Bindable var shutong = ShutongModel.shared
        @Bindable var remote = RemoteModel.shared
        NavigationStack(path: $app.path) {
            ListScreen()
                .navigationDestination(for: Route.self) { r in
                    switch r {
                    case .editor(let id): EditorScreen(noteID: id)
                    case .settings: SettingsScreen()
                    }
                }
        }
        .tint(Color(uiColor: Ink.accent))
        .frame(maxWidth: Narrow.demo ? 375 : .infinity)                                            // 157 截图：限宽 375 看小屏挤不挤
        .overlay(alignment: .bottom) { ToastView() }
        .overlay(alignment: .top) { CallBar() }                                                     // 139 打电话式
        .overlay { if app.busy != nil { BusyOverlay() } }
        .fullScreenCover(item: $app.voiceTarget) { target in RecorderScreen(target: target) }
        .background {
            Color.clear.fullScreenCover(item: $app.listening) { o in PlaylistScreen(open: o) }
        }
        .background { Color.clear.sheet(isPresented: $dove.open) { DoveSheet() } }                 // 128 飞鸽传书
        .background { Color.clear.sheet(item: $dove.secret) { c in SecretCardView(card: c) } }    // 128 特勤局机密文件
        .background { Color.clear.sheet(isPresented: $shutong.open) { ShutongSheet() } }           // 136 书童
        .background { Color.clear.sheet(isPresented: $remote.open) { RemoteSheet() } }             // 172 遥控
        .task {                                                                                    // 截图、UI 测试用
            if let s = app.demo?.screen, ["shutong", "shutong-confirm", "shutong-slip", "shutong-tell", "shutong-links"].contains(s) {
                app.started()
                try? await Task.sleep(nanoseconds: 400_000_000)
                ShutongModel.shared.demo(s)
            }
        }
        .task {                                                                                    // 截图用
            if let s = app.demo?.screen, ["dove", "dove-done", "secret"].contains(s) { DoveModel.shared.demo(s) }
        }
        .onAppear { app.started() }
    }
}

/// 隐藏了系统导航栏以后，左边缘右滑返回照样能用
extension UINavigationController: @retroactive UIGestureRecognizerDelegate {
    override open func viewDidLoad() {
        super.viewDidLoad()
        interactivePopGestureRecognizer?.delegate = self
    }

    public func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        viewControllers.count > 1
    }
}
