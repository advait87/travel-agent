import Foundation
import SwiftData

/// One line of the conversation with the agent (saved, so it survives the app being closed).
@Model
final class ChatEntry {
    enum Role: String { case user, agent }

    var date: Date
    var roleRaw: String
    var text: String
    /// The plan change this reply proposed, if any.
    var proposalID: UUID?

    init(role: Role, text: String, proposalID: UUID? = nil) {
        self.date = .now
        self.roleRaw = role.rawValue
        self.text = text
        self.proposalID = proposalID
    }

    var role: Role { Role(rawValue: roleRaw) ?? .agent }
}

/// A conversation turn as sent to the model.
struct ChatTurn {
    let role: ChatEntry.Role
    let text: String
}

/// Everything the agent needs to answer a message about the trip.
struct ChatRequest {
    let destination: String
    let travelers: Int
    let budget: Int
    let days: [ItineraryDay]
    let todayNumber: Int
    let now: Int
    let placeName: String?
    let recentUpdates: [String]
    let history: [ChatTurn]
}

struct ChatReply {
    let reply: String
    let proposal: ProposedDay?
}

/// A model's rewritten schedule for one day.
struct ProposedDay {
    let dayNumber: Int
    let blocks: [Activity]
    let changes: [String]
}

/// What changes between two versions of a day, worked out locally so the UI never relies on
/// the model's own summary.
struct PlanChange: Hashable, Identifiable {
    enum Kind { case added, removed, retimed }
    let id = UUID()
    let kind: Kind
    let block: Activity

    static func diff(from old: [Activity], to new: [Activity]) -> [PlanChange] {
        let oldByTitle = Dictionary(old.map { ($0.title.lowercased(), $0) }, uniquingKeysWith: { a, _ in a })
        let newTitles = Set(new.map { $0.title.lowercased() })
        var result = old.filter { !newTitles.contains($0.title.lowercased()) }.map { PlanChange(kind: .removed, block: $0) }
        for block in new {
            if let previous = oldByTitle[block.title.lowercased()] {
                if previous.start != block.start || previous.end != block.end {
                    result.append(PlanChange(kind: .retimed, block: block))
                }
            } else {
                result.append(PlanChange(kind: .added, block: block))
            }
        }
        return result.sorted { $0.block.start < $1.block.start }
    }
}
