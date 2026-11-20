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

struct YiyeShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(intent: RecordVoiceIntent(),
                    phrases: ["Record a voice note in \(.applicationName)", "\(.applicationName) voice note"],
                    shortTitle: "voice.intent",
                    systemImageName: "mic")
    }
}
