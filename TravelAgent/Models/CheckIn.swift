import Foundation

/// Everything the agent knows at a check-in.
struct CheckInContext {
    var destination: String
    var dayNumber: Int
    /// Minutes since midnight.
    var now: Int
    var blocks: [Activity]
    var placeName: String?
    var recentUpdates: [String]
    var lastAdvice: String?
    /// What the traveler just said, if this check-in was triggered by a message.
    var message: String? = nil

    var scheduledIndex: Int? { blocks.firstIndex { $0.start <= now && now < $0.end } }

    var scheduleText: String {
        blocks.enumerated().map { i, b in "\(i): \(b.timeRange) \(b.title) at \(b.location)" }.joined(separator: "\n")
    }
}

struct CheckInResult {
    enum Status: String { case onTrack = "on_track", behind, ahead, free }
    /// What the message was: a status update, a question, or a request to change the plan.
    enum Intent: String { case update, question, change }

    var status: Status
    var headline: String
    var advice: String
    /// Index of the block the user is most likely at right now, if known.
    var atBlockIndex: Int?
    var shouldReplan: Bool
    /// Direct answer to the traveler's message (empty for timer check-ins).
    var reply: String = ""
    var intent: Intent = .update
}
