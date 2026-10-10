import Foundation
import SwiftData

/// The single plan change the agent is proposing. Replans (you fell behind) and chat requests
/// ("find a quieter dinner spot") both produce one; only one is pending at a time. Saved, so it
/// survives the app being closed, and keeps the old schedule so Apply can be undone.
@Model
final class PlanProposal {
    enum State: String { case pending, applied, dismissed, superseded, undone }
    enum Source: String { case replan, chat }

    var id: UUID
    var createdAt: Date
    var dayNumber: Int
    var message: String
    var sourceRaw: String
    var stateRaw: String
    var appliedAt: Date?
    var blocksData = Data()
    var previousData = Data()

    init(dayNumber: Int, blocks: [Activity], message: String, source: Source) {
        self.id = UUID()
        self.createdAt = .now
        self.dayNumber = dayNumber
        self.message = message
        self.sourceRaw = source.rawValue
        self.stateRaw = State.pending.rawValue
        self.blocks = blocks
    }

    var state: State {
        get { State(rawValue: stateRaw) ?? .dismissed }
        set { stateRaw = newValue.rawValue }
    }

    var source: Source { Source(rawValue: sourceRaw) ?? .chat }

    var blocks: [Activity] {
        get { (try? JSONDecoder().decode([Activity].self, from: blocksData)) ?? [] }
        set { blocksData = (try? JSONEncoder().encode(newValue)) ?? Data() }
    }

    /// The day as it was before Apply (for Undo).
    var previous: [Activity] {
        get { (try? JSONDecoder().decode([Activity].self, from: previousData)) ?? [] }
        set { previousData = (try? JSONEncoder().encode(newValue)) ?? Data() }
    }

    /// Undo stays available for 10 minutes after applying.
    var canUndo: Bool { state == .applied && (appliedAt.map { Date.now.timeIntervalSince($0) < 600 } ?? false) }
}
