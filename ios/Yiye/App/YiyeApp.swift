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
                .preferredColorScheme(app.demo?.scheme)
                .onChange(of: phase) { _, p in app.scenePhase(p) }
        }
    }
}

struct RootView: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        @Bindable var app = app
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
        .overlay(alignment: .bottom) { ToastView() }
        .overlay { if app.busy != nil { BusyOverlay() } }
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
