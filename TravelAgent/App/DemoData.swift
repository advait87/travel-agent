import Foundation
import SwiftData

/// `-demoTrip` launch argument: a one-day Goa trip built around the current time, so every flow
/// (on track, running late, replans, map) can be shown on the simulator without planning a trip.
enum DemoData {
    @MainActor static func insertIfRequested() {
        guard ProcessInfo.processInfo.arguments.contains("-demoTrip") else { return }
        let context = SharedModel.container.mainContext
        guard ((try? context.fetchCount(FetchDescriptor<Trip>())) ?? 0) == 0 else { return }

        // The current block started 40 minutes ago; everything else is laid out around it.
        let now = ProactiveAgent.minutesNow()
        let base = now - 40 - 210
        func block(_ offset: Int, _ length: Int, _ title: String, _ place: String, _ category: Activity.Category,
                   _ tags: [String], _ detail: String, _ cost: Int) -> Activity {
            Activity(start: base + offset, end: base + offset + length, title: title, detail: detail,
                     location: place, category: category, tags: tags, estimatedCost: cost)
        }
        let blocks = [
            block(0, 60, "Breakfast at Infantaria", "Infantaria, Calangute", .food, ["Breakfast", "Bakery"],
                  "Goan sausage bread and filter coffee at the classic bakery.", 400),
            block(75, 120, "Baga Beach morning", "Baga Beach", .relax, ["Beach", "Swim"],
                  "Swim and relax before the crowds arrive.", 0),
            block(210, 90, "Lunch at Souza Lobo", "Souza Lobo, Calangute", .food, ["Seafood"],
                  "Beachside institution, try the fish curry rice.", 900),
            block(315, 120, "Fort Aguada", "Fort Aguada", .sightseeing, ["History", "Views"],
                  "17th-century Portuguese fort and lighthouse over the Arabian Sea.", 100),
            block(450, 90, "Sunset at Chapora", "Chapora Fort", .sightseeing, ["Sunset", "Views"],
                  "The Dil Chahta Hai fort, best at golden hour.", 0),
            block(570, 120, "Dinner at Thalassa", "Thalassa, Siolim", .food, ["Greek", "Sunset"],
                  "Greek taverna on the cliffs with live music.", 1500),
        ].filter { $0.start >= 0 && $0.end < 24 * 60 }
        let day = ItineraryDay(dayNumber: 1, title: "Beaches, forts & sunsets", activities: blocks,
                               imagePrompt: "Goa beach with a Portuguese fort at golden hour")
        context.insert(Trip(destination: "Goa", startDate: .now, budget: 20_000, travelers: 2,
                            interests: ["Beaches", "Food"], days: [day], plannedBy: "Demo data"))
        try? context.save()
    }
}
