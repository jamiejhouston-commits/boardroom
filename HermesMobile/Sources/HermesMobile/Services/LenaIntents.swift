import AppIntents

/// "Talk to Lena" — runnable from Siri, the Shortcuts app, a Control Center
/// control, or a lock-screen shortcut, even while the phone is locked. It posts
/// Lena's opening message as a reply-enabled notification, so you can then chat
/// with her right from the lock screen (type in the notification's reply field).
struct TalkToLenaIntent: AppIntent {
    static var title: LocalizedStringResource { "Talk to Lena" }
    static var description: IntentDescription { IntentDescription("Start a lock-screen chat with your assistant, Lena.") }
    static var openAppWhenRun: Bool { false }

    @MainActor
    func perform() async throws -> some IntentResult {
        await NotificationPresenter.startLenaChat()
        return .result()
    }
}

struct BoardroomAppShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: TalkToLenaIntent(),
            phrases: [
                "Talk to Lena in \(.applicationName)",
                "Message Lena in \(.applicationName)",
                "Ask Lena in \(.applicationName)"
            ],
            shortTitle: "Talk to Lena",
            systemImageName: "person.crop.circle.badge.checkmark")
    }
}
