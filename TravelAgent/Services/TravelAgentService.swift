import Foundation

/// The travel agent's "brain". Screens only talk to this protocol, so the mock
/// below can later be swapped for a real AI-backed implementation.
protocol TravelAgentService {
    /// Shown on the trip so it's clear which brain produced the plan.
    var name: String { get }
    func planItinerary(for request: TripRequest) async throws -> [ItineraryDay]
    func travelTips(for destination: String, interests: [String]) async throws -> [String]
    func nearbySuggestions(at place: String, time: String, destination: String, interests: [String]) async throws -> [String]
    func replan(_ request: ReplanRequest) async throws -> ReplanSuggestion
    func checkIn(_ context: CheckInContext) async throws -> CheckInResult
    func chat(_ request: ChatRequest) async throws -> ChatReply
}

enum AgentSettings {
    static let useMockKey = "useMockAgent"
    static let groqModelKey = "groqModel"
    static let defaultGroqModel = "openai/gpt-oss-20b"

    /// Real agent when keys are set and mock mode is off; otherwise the mock.
    static func currentAgent() -> TravelAgentService {
        let defaults = UserDefaults.standard
        let claudeKey = KeychainStore.get(.claudeAPIKey)
        if defaults.bool(forKey: useMockKey) || claudeKey.isEmpty {
            return MockTravelAgent()
        }
        let model = defaults.string(forKey: groqModelKey).flatMap { $0.isEmpty ? nil : $0 } ?? defaultGroqModel
        let groqKey = KeychainStore.get(.groqAPIKey)
        return LiveTravelAgent(claude: ClaudeClient(apiKey: claudeKey),
                               groq: groqKey.isEmpty ? nil : GroqClient(apiKey: groqKey, model: model))
    }
}

/// Claude for the heavy itinerary generation, Groq for small fast requests.
/// Without a Groq key, small requests fall back to the mock.
struct LiveTravelAgent: TravelAgentService {
    let claude: ClaudeClient
    let groq: GroqClient?
    var name: String { "Claude" + (groq == nil ? "" : " + Groq") }

    func planItinerary(for request: TripRequest) async throws -> [ItineraryDay] {
        try await claude.planItinerary(for: request)
    }

    func travelTips(for destination: String, interests: [String]) async throws -> [String] {
        guard let groq else { return try await MockTravelAgent().travelTips(for: destination, interests: interests) }
        return try await groq.travelTips(for: destination, interests: interests)
    }

    func nearbySuggestions(at place: String, time: String, destination: String, interests: [String]) async throws -> [String] {
        guard let groq else {
            return try await MockTravelAgent().nearbySuggestions(at: place, time: time, destination: destination, interests: interests)
        }
        return try await groq.nearbySuggestions(at: place, time: time, destination: destination, interests: interests)
    }

    func replan(_ request: ReplanRequest) async throws -> ReplanSuggestion {
        try await claude.replan(request)
    }

    func checkIn(_ context: CheckInContext) async throws -> CheckInResult {
        guard let groq else { return try await MockTravelAgent().checkIn(context) }
        return try await groq.checkIn(context)
    }

    func chat(_ request: ChatRequest) async throws -> ChatReply {
        try await claude.chat(request)
    }
}

/// Simulated agent: waits like a network call, then builds a plausible
/// itinerary from templates matched to the user's interests.
struct MockTravelAgent: TravelAgentService {
    var simulatedLatency: Duration = .seconds(1.5)
    var name: String { "Mock agent" }

    func travelTips(for destination: String, interests: [String]) async throws -> [String] {
        try await Task.sleep(for: simulatedLatency / 3)
        return ["Carry cash for small local shops in \(destination).",
                "Start sightseeing early to beat the heat and crowds.",
                "Book popular restaurants a day ahead on weekends.",
                "Keep a reusable water bottle and sunscreen handy."]
    }

    func nearbySuggestions(at place: String, time: String, destination: String, interests: [String]) async throws -> [String] {
        try await Task.sleep(for: simulatedLatency / 3)
        return ["Nearest café – grab a cold coffee and recharge",
                "Local market – browse handicrafts and street snacks",
                "Viewpoint – short walk for great photos at this hour",
                "Popular restaurant – try the regional thali"]
    }

    /// Rule-based check-in: trusts "still at / staying" updates over the schedule.
    func checkIn(_ context: CheckInContext) async throws -> CheckInResult {
        var result = try await ruleCheckIn(context)
        guard let message = context.message?.lowercased() else { return result }
        let changeWords = ["skip", "add", "swap", "change", "replace", "instead", "find", "remove", "move", "quieter"]
        if changeWords.contains(where: message.contains) {
            result.intent = .change
        } else if message.contains("?") || ["what", "where", "how", "when", "which"].contains(where: message.hasPrefix) {
            result.intent = .question
            result.reply = "Good question. \(result.advice)"
        } else {
            result.reply = "Got it. \(result.advice)"
        }
        return result
    }

    private func ruleCheckIn(_ context: CheckInContext) async throws -> CheckInResult {
        try await Task.sleep(for: simulatedLatency / 3)
        let latest = (context.message ?? context.recentUpdates.last ?? "").lowercased()
        let stayingWords = ["still", "staying", "stay", "late", "longer", "behind"]
        if stayingWords.contains(where: latest.contains), let scheduled = context.scheduledIndex ?? context.blocks.lastIndex(where: { $0.end <= context.now }) {
            let atIndex = max(scheduled - 1, 0)
            let block = context.blocks[atIndex]
            return CheckInResult(status: .behind, headline: "You're running behind",
                                 advice: "You were due to leave \(block.title) at \(Activity.clock(block.end)). I've prepared a new plan.",
                                 atBlockIndex: atIndex, shouldReplan: true)
        }
        if let i = context.scheduledIndex {
            let block = context.blocks[i]
            let next = context.blocks.indices.contains(i + 1) ? context.blocks[i + 1] : nil
            return CheckInResult(status: .onTrack, headline: "Enjoy \(block.title)",
                                 advice: next.map { "Leave by \(Activity.clock(block.end)) for \($0.title) at \(Activity.clock($0.start))." } ?? "Last stop today, take your time.",
                                 atBlockIndex: i, shouldReplan: false)
        }
        if let next = context.blocks.first(where: { $0.start > context.now }) {
            return CheckInResult(status: .free, headline: "Free time until \(Activity.clock(next.start))",
                                 advice: "Next up: \(next.title) at \(next.location).", atBlockIndex: nil, shouldReplan: false)
        }
        return CheckInResult(status: .free, headline: "Day complete", advice: "Nothing else planned today. Rest up!",
                             atBlockIndex: nil, shouldReplan: false)
    }

    /// Keyword chat: "skip X" drops a block from today, anything else gets a canned answer.
    func chat(_ request: ChatRequest) async throws -> ChatReply {
        try await Task.sleep(for: simulatedLatency * 2 / 3)
        let message = request.history.last?.text.lowercased() ?? ""
        guard let today = request.days.first(where: { $0.dayNumber == request.todayNumber }) else {
            return ChatReply(reply: "I don't see a plan for today yet.", proposal: nil)
        }
        if message.contains("skip") || message.contains("remove") || message.contains("cancel"),
           let block = today.activities.first(where: { message.contains($0.title.lowercased()) })
            ?? today.activities.first(where: { $0.start > request.now && $0.category != .food }) {
            return ChatReply(reply: "Done, I've taken \(block.title) out so you have more breathing room.",
                             proposal: ProposedDay(dayNumber: today.dayNumber,
                                                   blocks: today.activities.filter { $0.id != block.id },
                                                   changes: ["Skip \(block.title)"]))
        }
        let next = today.activities.sorted { $0.start < $1.start }.first { $0.start > request.now }
        return ChatReply(reply: next.map { "Next up is \($0.title) at \(Activity.clock($0.start)). Want me to change anything?" }
                         ?? "That's everything for today. Want ideas for tonight?", proposal: nil)
    }

    /// Rule-based replanning: push the day back from now, skipping non-meal blocks
    /// you'd reach more than 45 minutes late.
    func replan(_ request: ReplanRequest) async throws -> ReplanSuggestion {
        try await Task.sleep(for: simulatedLatency * 2 / 3)
        let current = request.currentBlock
        var decisions = [ReplanSuggestion.Decision(
            blockID: current.id, title: current.title, action: .extend,
            start: current.start, end: max(request.now, current.end),
            reason: "You're enjoying it, so stay a little longer.")]
        var cursor = max(request.now, current.end) + 15
        var skipped: [String] = []
        for block in request.remainingBlocks.dropFirst() {
            let lateness = cursor - block.start
            if lateness <= 0 {
                decisions.append(.init(blockID: block.id, title: block.title, action: .keep,
                                       start: block.start, end: block.end, reason: "Still on time."))
                cursor = block.end + 15
            } else if lateness > 45 && block.category != .food {
                skipped.append(block.title)
                decisions.append(.init(blockID: block.id, title: block.title, action: .skip,
                                       start: block.start, end: block.end,
                                       reason: "You'd arrive \(lateness) min late, so it's not worth it."))
            } else {
                let end = max(block.end, cursor + 30)
                decisions.append(.init(blockID: block.id, title: block.title, action: .shift,
                                       start: cursor, end: end, reason: "Moved later to fit."))
                cursor = end + 15
            }
        }
        let behind = max(request.now - current.end, 0)
        let message = skipped.isEmpty
            ? "You're \(behind) min behind. Everything still fits if we push the rest of the day back a bit."
            : "You're \(behind) min behind. Stay at \(current.title) and skip \(skipped.joined(separator: ", ")), the least worth it today."
        return ReplanSuggestion(message: message, decisions: decisions)
    }

    func planItinerary(for request: TripRequest) async throws -> [ItineraryDay] {
        try await Task.sleep(for: simulatedLatency)

        let place = request.destination.isEmpty ? "your destination" : request.destination
        let interests = request.interests.isEmpty ? Interest.allCases : request.interests
        let budget = request.budget / max(request.numberOfDays, 1) / max(request.travelers, 1)

        return (1...max(request.numberOfDays, 1)).map { day in
            let focus = interests[(day - 1) % interests.count]
            var blocks = [
                Activity(start: t(8, 30), end: t(9, 30), title: "Breakfast at a local café",
                         detail: "Start the day at a popular breakfast spot.", location: place,
                         category: .food, tags: ["Food", "Breakfast"], estimatedCost: budget / 8),
            ]
            blocks += Self.templates(for: focus, in: place, budget: budget)
            blocks.append(
                Activity(start: t(20), end: t(21, 30), title: "Dinner with a view",
                         detail: "A well-reviewed restaurant to wrap up day \(day).", location: place,
                         category: .food, tags: ["Food", "Dinner"], estimatedCost: budget / 4)
            )
            let title = day == 1 ? "Arrival & \(focus.rawValue)" : "\(focus.rawValue) Day"
            return ItineraryDay(dayNumber: day, title: title, activities: blocks.sorted { $0.start < $1.start },
                                imagePrompt: "\(place), \(focus.rawValue.lowercased()) scene")
        }
    }

    private static func templates(for interest: Interest, in place: String, budget: Int) -> [Activity] {
        switch interest {
        case .beaches:
            [Activity(start: t(10), end: t(13), title: "Beach morning", detail: "Swim and sunbathe at the best-rated beach.", location: place, category: .relax, tags: ["Beach", "Swim"], estimatedCost: 0),
             Activity(start: t(16, 30), end: t(18, 30), title: "Sunset beach walk", detail: "Catch the sunset along the shoreline.", location: place, category: .sightseeing, tags: ["Beach", "Sunset"], estimatedCost: 0)]
        case .food:
            [Activity(start: t(11), end: t(13), title: "Local market food trail", detail: "Taste street food and regional specialties.", location: place, category: .food, tags: ["Food", "Street food"], estimatedCost: budget / 6),
             Activity(start: t(15), end: t(17, 30), title: "Cooking class", detail: "Learn to cook a signature local dish.", location: place, category: .culture, tags: ["Food", "Class"], estimatedCost: budget / 4)]
        case .adventure:
            [Activity(start: t(9, 45), end: t(13, 30), title: "Guided trek", detail: "A half-day hike to a scenic viewpoint.", location: place, category: .adventure, tags: ["Hike", "Outdoors"], estimatedCost: budget / 5),
             Activity(start: t(15), end: t(17), title: "Water sports", detail: "Kayaking, parasailing or jet skiing.", location: place, category: .adventure, tags: ["Water", "Thrill"], estimatedCost: budget / 4)]
        case .culture:
            [Activity(start: t(10), end: t(12, 30), title: "Old town heritage walk", detail: "Explore historic streets and architecture.", location: place, category: .culture, tags: ["History", "Walk"], estimatedCost: budget / 10),
             Activity(start: t(14, 30), end: t(16, 30), title: "Museum visit", detail: "Learn the history of the region.", location: place, category: .culture, tags: ["Museum"], estimatedCost: budget / 10)]
        case .nightlife:
            [Activity(start: t(14), end: t(17), title: "Lazy afternoon nap", detail: "Rest up before the night out.", location: "Hotel", category: .relax, tags: ["Rest"], estimatedCost: 0),
             Activity(start: t(22), end: t(23, 59), title: "Night out", detail: "The liveliest bars and clubs in town.", location: place, category: .nightlife, tags: ["Party", "Music"], estimatedCost: budget / 3)]
        case .relaxation:
            [Activity(start: t(10, 30), end: t(12), title: "Spa session", detail: "A relaxing massage at a well-reviewed spa.", location: place, category: .relax, tags: ["Spa", "Wellness"], estimatedCost: budget / 4),
             Activity(start: t(16), end: t(18), title: "Café hopping", detail: "Unwind at cozy cafés.", location: place, category: .food, tags: ["Café", "Chill"], estimatedCost: budget / 10)]
        }
    }
}

private func t(_ hour: Int, _ minute: Int = 0) -> Int { hour * 60 + minute }
