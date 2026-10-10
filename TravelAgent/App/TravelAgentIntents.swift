import AppIntents

/// "Hey Siri, tell Travel Agent" → speak what you did → the agent re-checks and answers.
struct TellAgentIntent: AppIntent {
    static let title: LocalizedStringResource = "Tell Travel Agent"
    static let description = IntentDescription("Tell your travel agent what you're doing so it can adjust your day.")

    @Parameter(title: "Update", requestValueDialog: "What are you up to?")
    var update: String

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let reply = await ProactiveAgent.shared.handle(update, source: .siri)
        return .result(dialog: "\(reply)")
    }
}

struct TravelAgentShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(intent: TellAgentIntent(),
                    phrases: ["Tell \(.applicationName)", "Update \(.applicationName)"],
                    shortTitle: "Tell agent",
                    systemImageName: "mic.fill")
    }
}
