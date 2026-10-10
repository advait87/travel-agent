import ActivityKit
import AppIntents
import Foundation

/// Live Activity data, shared by the app (which starts/updates it) and the widget (which draws it).
struct TripActivityAttributes: ActivityAttributes {
    struct ContentState: Codable, Hashable {
        var blockTitle: String
        var location: String
        var blockEnd: Date
        var nextTitle: String?
        var nextStart: Date?
        var headline: String
        var status: String
    }

    var destination: String
}

/// Live Activity buttons. LiveActivityIntents run inside the app's process (in the background),
/// so tapping one wakes the agent. The widget build only needs the type, not the behavior.
struct ActivityDoneIntent: LiveActivityIntent {
    static let title: LocalizedStringResource = "Done here"
    func perform() async throws -> some IntentResult {
        #if !WIDGET_EXTENSION
        await ActivityResponder.handle(.done, source: .liveActivity)
        #endif
        return .result()
    }
}

struct ActivityStillHereIntent: LiveActivityIntent {
    static let title: LocalizedStringResource = "Still here"
    func perform() async throws -> some IntentResult {
        #if !WIDGET_EXTENSION
        await ActivityResponder.handle(.stillHere, source: .liveActivity)
        #endif
        return .result()
    }
}
