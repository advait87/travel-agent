import Foundation
import SwiftData

@Model
final class Trip {
    var destination: String
    var startDate: Date
    var budget: Int
    var travelers: Int
    var interests: [String]
    /// Days are stored as JSON: SwiftData doesn't reliably persist nested arrays of structs.
    var daysData = Data()
    var createdAt: Date
    var plannedBy: String = "Mock agent"
    var tips: [String] = []

    init(destination: String, startDate: Date, budget: Int, travelers: Int,
         interests: [String], days: [ItineraryDay], plannedBy: String) {
        self.destination = destination
        self.startDate = startDate
        self.budget = budget
        self.travelers = travelers
        self.interests = interests
        self.createdAt = .now
        self.plannedBy = plannedBy
        self.days = days
    }

    var days: [ItineraryDay] {
        get { (try? JSONDecoder().decode([ItineraryDay].self, from: daysData)) ?? [] }
        set { daysData = (try? JSONEncoder().encode(newValue)) ?? Data() }
    }

    /// AI-generated cover image for a day (Pollinations, no API key needed).
    func imageURL(for day: ItineraryDay) -> URL? {
        let subject = day.imagePrompt ?? "\(destination), \(day.title)"
        let prompt = "\(subject), beautiful travel photography, golden hour, vibrant, high detail"
        guard let encoded = prompt.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) else { return nil }
        return URL(string: "https://image.pollinations.ai/prompt/\(encoded)?width=800&height=480&nologo=true&seed=\(day.dayNumber)")
    }

    var endDate: Date {
        Calendar.current.date(byAdding: .day, value: max(days.count - 1, 0), to: startDate) ?? startDate
    }
}

struct ItineraryDay: Codable, Hashable, Identifiable {
    var id = UUID()
    var dayNumber: Int
    var title: String
    var activities: [Activity]
    var imagePrompt: String? = nil
}

/// One time block in a day. Times are minutes since midnight.
struct Activity: Codable, Hashable, Identifiable {
    var id = UUID()
    var start: Int
    var end: Int
    var title: String
    var detail: String
    var location: String
    var category: Category
    var tags: [String]
    var estimatedCost: Int

    init(start: Int, end: Int, title: String, detail: String, location: String = "",
         category: Category, tags: [String] = [], estimatedCost: Int) {
        self.start = start
        self.end = max(end, start + 15)
        self.title = title
        self.detail = detail
        self.location = location
        self.category = category
        self.tags = tags
        self.estimatedCost = estimatedCost
    }

    var durationMinutes: Int { end - start }
    var timeRange: String { "\(Self.clock(start)) – \(Self.clock(end))" }
    var durationText: String {
        let h = durationMinutes / 60, m = durationMinutes % 60
        return [h > 0 ? "\(h)h" : nil, m > 0 ? "\(m)m" : nil].compactMap { $0 }.joined(separator: " ")
    }

    static func clock(_ minutes: Int) -> String {
        String(format: "%02d:%02d", (minutes / 60) % 24, minutes % 60)
    }

    /// Parses "HH:MM" (24h) or "h:mm AM/PM" into minutes since midnight.
    static func minutes(from text: String) -> Int? {
        let upper = text.uppercased().trimmingCharacters(in: .whitespaces)
        let isPM = upper.hasSuffix("PM"), isAM = upper.hasSuffix("AM")
        let parts = upper.replacingOccurrences(of: "AM", with: "").replacingOccurrences(of: "PM", with: "")
            .trimmingCharacters(in: .whitespaces).split(separator: ":").compactMap { Int($0) }
        guard let hour = parts.first else { return nil }
        var h = hour % 24
        if isPM && h < 12 { h += 12 }
        if isAM && h == 12 { h = 0 }
        return h * 60 + (parts.count > 1 ? parts[1] : 0)
    }

    // Trips saved before time blocks existed only have a single "time" string.
    private enum CodingKeys: String, CodingKey {
        case id, start, end, title, detail, location, category, tags, estimatedCost, time
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        title = try c.decode(String.self, forKey: .title)
        detail = try c.decode(String.self, forKey: .detail)
        location = try c.decodeIfPresent(String.self, forKey: .location) ?? ""
        category = try c.decodeIfPresent(Category.self, forKey: .category) ?? .sightseeing
        tags = try c.decodeIfPresent([String].self, forKey: .tags) ?? []
        estimatedCost = try c.decodeIfPresent(Int.self, forKey: .estimatedCost) ?? 0
        let legacyStart = try c.decodeIfPresent(String.self, forKey: .time).flatMap(Self.minutes(from:))
        start = try c.decodeIfPresent(Int.self, forKey: .start) ?? legacyStart ?? 9 * 60
        end = try c.decodeIfPresent(Int.self, forKey: .end) ?? start + 90
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(start, forKey: .start)
        try c.encode(end, forKey: .end)
        try c.encode(title, forKey: .title)
        try c.encode(detail, forKey: .detail)
        try c.encode(location, forKey: .location)
        try c.encode(category, forKey: .category)
        try c.encode(tags, forKey: .tags)
        try c.encode(estimatedCost, forKey: .estimatedCost)
    }

    enum Category: String, Codable, CaseIterable {
        case food, sightseeing, adventure, relax, nightlife, culture, transport

        var icon: String {
            switch self {
            case .food: "fork.knife"
            case .sightseeing: "binoculars.fill"
            case .adventure: "figure.hiking"
            case .relax: "beach.umbrella.fill"
            case .nightlife: "music.note"
            case .culture: "building.columns.fill"
            case .transport: "car.fill"
            }
        }
    }
}

/// What the user asks the agent for.
struct TripRequest {
    var destination: String
    var startDate: Date
    var numberOfDays: Int
    var budget: Int
    var travelers: Int
    var interests: [Interest]
}

enum Interest: String, CaseIterable, Identifiable {
    case beaches = "Beaches"
    case food = "Food"
    case adventure = "Adventure"
    case culture = "Culture"
    case nightlife = "Nightlife"
    case relaxation = "Relaxation"

    var id: String { rawValue }

    var icon: String {
        switch self {
        case .beaches: "sun.max.fill"
        case .food: "fork.knife"
        case .adventure: "figure.hiking"
        case .culture: "building.columns.fill"
        case .nightlife: "moon.stars.fill"
        case .relaxation: "leaf.fill"
        }
    }
}
