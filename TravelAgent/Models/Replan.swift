import Foundation

/// "I'm still here and behind schedule" — what the agent needs to rebalance the rest of the day.
struct ReplanRequest {
    var destination: String
    var day: ItineraryDay
    var currentBlock: Activity
    /// Minutes since midnight.
    var now: Int
    var placeName: String?

    var remainingBlocks: [Activity] {
        day.activities.sorted { $0.start < $1.start }.filter { $0.start >= currentBlock.start }
    }
}

struct ReplanSuggestion {
    enum Action: String, CaseIterable { case keep, skip, shorten, extend, shift }

    struct Decision: Identifiable {
        var id: UUID { blockID }
        var blockID: UUID
        var title: String
        var action: Action
        var start: Int
        var end: Int
        var reason: String
    }

    var message: String
    var decisions: [Decision]

    var skippedCount: Int { decisions.filter { $0.action == .skip }.count }

    func apply(to day: ItineraryDay) -> ItineraryDay {
        var updated = day
        updated.activities = day.activities.compactMap { block in
            guard let decision = decisions.first(where: { $0.blockID == block.id }) else { return block }
            guard decision.action != .skip else { return nil }
            var changed = block
            changed.start = decision.start
            changed.end = max(decision.end, decision.start + 15)
            return changed
        }
        .sorted { $0.start < $1.start }
        return updated
    }
}
