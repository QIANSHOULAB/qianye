import AppIntents

/// 侧键（Action Button）一按就录：Settings > Action Button > Shortcut > 一叶笺「录一段」
struct RecordVoiceIntent: AppIntent {
    static let title: LocalizedStringResource = "voice.intent"
    static let description = IntentDescription("voice.intentDesc")
    static let openAppWhenRun: Bool = true

    @MainActor
    func perform() async throws -> some IntentResult {
        AppModel.shared.startVoice(.new)
        return .result()
    }
}

/// 分享进来的网页 / 文字存成便签（114）。不打开 app 也能跑完。在「快捷指令」里搭一次，开「在共享表单中显示」，分享菜单里就有「存进一叶笺」
struct SaveToYiyeIntent: AppIntent {
    static let title: LocalizedStringResource = "article.intent"
    static let description = IntentDescription("article.intentDesc")
    static let openAppWhenRun: Bool = false

    @Parameter(title: "article.paramURL")
    var url: URL?

    @Parameter(title: "article.paramText")
    var text: String?

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let app = AppModel.shared
        app.started()
        let msg = await app.saveShared(url: url?.absoluteString, text: text)
        return .result(dialog: "\(msg)")
    }
}

struct YiyeShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(intent: RecordVoiceIntent(),
                    phrases: ["Record a voice note in \(.applicationName)", "\(.applicationName) voice note"],
                    shortTitle: "voice.intent",
                    systemImageName: "mic")
        AppShortcut(intent: SaveToYiyeIntent(),
                    phrases: ["Save to \(.applicationName)", "Save an article to \(.applicationName)"],
                    shortTitle: "article.intent",
                    systemImageName: "square.and.arrow.down")
    }
}
