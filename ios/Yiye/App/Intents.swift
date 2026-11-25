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

/// 139「叫大管家」：喊一声接通（Siri、捷径、侧键、耳机上喊 Siri），就是深聊那套；说「挂掉」就挂，挂了歌接着放。
/// 锁着屏：先在后台直接开话筒（AudioRecordingIntent：系统认这是开录音的意图）；系统不让（话筒起不来）再请他解锁、到前台接通。
struct CallButlerIntent: AudioRecordingIntent {
    static let title: LocalizedStringResource = "call.intent"
    static let description = IntentDescription("call.intentDesc")
    static let supportedModes: IntentModes = [.background, .foreground(.dynamic)]

    @MainActor
    func perform() async throws -> some IntentResult {
        let app = AppModel.shared
        app.started()
        if await app.companion.startCallWaiting() { return .result() }
        try await continueInForeground(nil, alwaysConfirm: false)
        _ = await app.companion.startCallWaiting()
        return .result()
    }
}

struct YiyeShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        // 139：中文说法在 AppShortcuts.xcstrings；Info.plist 的 INAlternativeAppNames 让「大管家」「Yiye」也当 App 名字认，
        // 所以「叫大管家」「Call Yiye」就能喊起来
        AppShortcut(intent: CallButlerIntent(),
                    phrases: ["Call \(.applicationName)", "Call the butler in \(.applicationName)", "Talk to \(.applicationName)"],
                    shortTitle: "call.intent",
                    systemImageName: "phone")
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
