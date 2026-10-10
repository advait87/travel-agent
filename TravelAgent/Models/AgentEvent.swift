import Foundation
import SwiftData

/// One entry in the agent feed: something the user told the agent, or a check-in result.
@Model
final class AgentEvent {
    enum Kind: String { case user, checkIn, alert }

    var date: Date
    var kindRaw: String
    var title: String
    var detail: String

    init(kind: Kind, title: String, detail: String = "", date: Date = .now) {
        self.date = date
        self.kindRaw = kind.rawValue
        self.title = title
        self.detail = detail
    }

    var kind: Kind { Kind(rawValue: kindRaw) ?? .checkIn }
}

/// One container shared by the app UI, background check-ins and Siri intents.
enum SharedModel {
    @MainActor static let container: ModelContainer = {
        do {
            return try ModelContainer(for: Trip.self, AgentEvent.self, ChatEntry.self, PlanProposal.self)
        } catch {
            fatalError("Could not open data store: \(error)")
        }
    }()
}

extension Trip {
    /// Upcoming trips get a countdown and no check-ins; finished ones go quiet.
    enum Phase { case upcoming, active, finished }

    private var dayOffset: Int {
        let start = Calendar.current.startOfDay(for: startDate)
        let today = Calendar.current.startOfDay(for: .now)
        return Calendar.current.dateComponents([.day], from: start, to: today).day ?? 0
    }

    var phase: Phase {
        if dayOffset < 0 { return .upcoming }
        return dayOffset < max(days.count, 1) ? .active : .finished
    }

    var daysUntilStart: Int { max(-dayOffset, 0) }

    /// The day to show: today while travelling, day 1 before the trip, the last day after it.
    var todayNumber: Int {
        switch phase {
        case .upcoming: 1
        case .active: dayOffset + 1
        case .finished: max(days.count, 1)
        }
    }

    /// Today's plan, only while the trip is actually happening.
    var today: ItineraryDay? { phase == .active ? displayDay : nil }

    var displayDay: ItineraryDay? { days.first { $0.dayNumber == todayNumber } }
}

enum ActiveTrip {
    /// The trip you're "on": one happening today, else the next upcoming one, else the newest.
    @MainActor static func current(in context: ModelContext) -> Trip? {
        let trips = (try? context.fetch(FetchDescriptor<Trip>(sortBy: [SortDescriptor(\.createdAt, order: .reverse)]))) ?? []
        return trips.first { $0.phase == .active }
            ?? trips.filter { $0.phase == .upcoming }.min { $0.startDate < $1.startDate }
            ?? trips.first
    }
}
