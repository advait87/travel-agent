import Foundation

enum AgentError: LocalizedError {
    case missingKey(String)
    case http(Int, String)
    case refusal
    case truncated
    case badResponse(String)

    var errorDescription: String? {
        switch self {
        case .missingKey(let provider): "Add your \(provider) API key in Settings."
        case .http(let code, let message): "API error \(code): \(message)"
        case .refusal: "The agent declined this request."
        case .truncated: "The plan was too long and got cut off. Try fewer days."
        case .badResponse(let detail): "Unexpected response: \(detail)"
        }
    }
}

/// Calls the Claude Messages API over raw HTTP (there is no official Swift SDK).
/// Used for the heavy requests: generating and re-planning structured itineraries.
struct ClaudeClient {
    var apiKey: String
    var model = "claude-opus-5-5"

    func planItinerary(for request: TripRequest) async throws -> [ItineraryDay] {
        let interests = request.interests.map(\.rawValue).joined(separator: ", ")
        let prompt = """
        Plan a \(request.numberOfDays)-day trip to \(request.destination) starting \
        \(request.startDate.formatted(date: .complete, time: .omitted)) for \(request.travelers) \
        traveler(s) with a total budget of ₹\(request.budget) (INR). Interests: \(interests.isEmpty ? "anything" : interests).
        Split each day into 5-8 chronological time blocks (meals, activities, travel, rest) with \
        realistic start and end times in 24h HH:MM; blocks must not overlap. Use real, specific places. \
        Give each block 1-3 short tags (e.g. Food, Beach, Sunset, Travel). estimatedCost is per person \
        in INR; keep the total within budget. Give each day a short, catchy title and an imagePrompt: \
        a vivid one-line visual description of that day's highlight scene for an image generator.
        Fill day1 to day\(request.numberOfDays), one full day each; don't repeat places across days.
        """

        // One required property per day (day1, day2, …): the schema itself guarantees every day comes back.
        let keys = (1...max(request.numberOfDays, 1)).map { "day\($0)" }
        let schema: [String: Any] = [
            "type": "object",
            "properties": Dictionary(uniqueKeysWithValues: keys.map { ($0, Self.daySchema) }),
            "required": keys,
            "additionalProperties": false,
        ]
        let text = try await structuredRequest(prompt: prompt, schema: schema, purpose: "Plan itinerary")
        let plan = try JSONDecoder().decode([String: PlanDTO.Day].self, from: Data(text.utf8))
        let days = keys.compactMap { plan[$0] }
        guard days.count == keys.count else {
            throw AgentError.badResponse("agent returned \(days.count) of \(keys.count) days, try again")
        }
        return days.enumerated().map { index, day in
            ItineraryDay(dayNumber: index + 1, title: day.title,
                         activities: day.activities.compactMap(\.activity).sorted { $0.start < $1.start },
                         imagePrompt: day.imagePrompt)
        }
    }

    func replan(_ request: ReplanRequest) async throws -> ReplanSuggestion {
        let blocks = request.remainingBlocks
        let list = blocks.enumerated().map { i, b in
            "b\(i): \(b.timeRange) \(b.title) [\(b.category.rawValue)] at \(b.location), ~₹\(b.estimatedCost)"
        }.joined(separator: "\n")
        let prompt = """
        I'm on a trip in \(request.destination). It's now \(Activity.clock(request.now)). I'm still at \
        "\(request.currentBlock.title)" (block b0), which was scheduled to end at \(Activity.clock(request.currentBlock.end)).\
        \(request.placeName.map { " My GPS location: \($0)." } ?? "")
        Remaining schedule for today:
        \(list)

        Rebalance the rest of my day like a smart travel agent. b0 ends now or a bit later if it's worth \
        staying. Skip the blocks that are least worth it so the rest fits realistically (allow travel time). \
        Keep meals unless impossible. Return one decision per block id above, with new 24h HH:MM times \
        (for skipped blocks, repeat the original times). message: 1-2 friendly sentences explaining the \
        trade-off, e.g. "Stay at the beach — skip the museum, it's the least worth it today."
        """
        let text = try await structuredRequest(prompt: prompt, schema: Self.replanSchema, purpose: "Replan day")
        let dto = try JSONDecoder().decode(ReplanDTO.self, from: Data(text.utf8))
        let decisions: [ReplanSuggestion.Decision] = dto.decisions.compactMap { d in
            guard let index = Int(d.blockId.dropFirst()), blocks.indices.contains(index) else { return nil }
            let block = blocks[index]
            return .init(blockID: block.id, title: block.title,
                         action: ReplanSuggestion.Action(rawValue: d.action) ?? .keep,
                         start: Activity.minutes(from: d.startTime) ?? block.start,
                         end: Activity.minutes(from: d.endTime) ?? block.end, reason: d.reason)
        }
        return ReplanSuggestion(message: dto.message, decisions: decisions)
    }

    /// Multi-turn chat about the trip. The agent answers and may rewrite one day's schedule.
    func chat(_ request: ChatRequest) async throws -> ChatReply {
        let itinerary = request.days.sorted { $0.dayNumber < $1.dayNumber }.map { day in
            "Day \(day.dayNumber) – \(day.title)\(day.dayNumber == request.todayNumber ? " (TODAY)" : ""):\n" +
            day.activities.sorted { $0.start < $1.start }.map {
                "  \($0.timeRange) \($0.title) [\($0.category.rawValue)] at \($0.location), ~₹\($0.estimatedCost) – \($0.detail)"
            }.joined(separator: "\n")
        }.joined(separator: "\n")
        let system = """
        You are a proactive, friendly travel agent chatting with a traveler who is on a trip to \(request.destination) \
        (\(request.travelers) traveler(s), total budget ₹\(request.budget)). It is now \(Activity.clock(request.now)) on day \
        \(request.todayNumber).\(request.placeName.map { " Their GPS location: \($0)." } ?? "")
        Recent updates from the traveler: \(request.recentUpdates.isEmpty ? "none" : request.recentUpdates.joined(separator: "; "))

        Current itinerary:
        \(itinerary)

        Answer in 1-3 short, specific sentences (real place names, prices in INR). If the traveler asks for a change \
        to the plan (swap, add, skip, move, find a different place), set changeDayNumber to that day and return that \
        day's COMPLETE new list of blocks in "blocks" (unchanged blocks too, same titles, 24h HH:MM, no overlaps; \
        past blocks of today stay as they were) and list each change in "changes" as a short phrase. \
        Otherwise set changeDayNumber to 0 and return empty blocks and changes.
        """
        var messages: [[String: Any]] = request.history.map {
            ["role": $0.role == .user ? "user" : "assistant", "content": $0.text]
        }
        // The API needs the conversation to start with a user turn.
        while messages.first?["role"] as? String == "assistant" { messages.removeFirst() }

        let text = try await structuredRequest(system: system, messages: messages, schema: Self.chatSchema,
                                               purpose: "Chat")
        let dto = try JSONDecoder().decode(ChatDTO.self, from: Data(text.utf8))
        let blocks = dto.blocks.compactMap(\.activity).sorted { $0.start < $1.start }
        let proposal = dto.changeDayNumber > 0 && !blocks.isEmpty
            ? ProposedDay(dayNumber: dto.changeDayNumber, blocks: blocks, changes: dto.changes) : nil
        return ChatReply(reply: dto.reply, proposal: proposal)
    }

    private func structuredRequest(prompt: String, schema: [String: Any], purpose: String) async throws -> String {
        try await structuredRequest(system: nil, messages: [["role": "user", "content": prompt]],
                                    schema: schema, purpose: purpose)
    }

    /// Sends one structured-output request and returns the JSON text. Logs token usage and cost.
    private func structuredRequest(system: String?, messages: [[String: Any]], schema: [String: Any],
                                   purpose: String) async throws -> String {
        var body: [String: Any] = [
            "model": model,
            "max_tokens": 16000,
            "thinking": ["type": "adaptive"],
            "fallbacks": "default",
            "output_config": [
                "effort": "low",
                "format": ["type": "json_schema", "schema": schema],
            ],
            "messages": messages,
        ]
        if let system { body["system"] = system }

        var urlRequest = URLRequest(url: URL(string: "https://api.anthropic.com/v1/messages")!)
        urlRequest.httpMethod = "POST"
        urlRequest.timeoutInterval = 180
        urlRequest.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        urlRequest.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        urlRequest.setValue("server-side-fallback-2026-07-01", forHTTPHeaderField: "anthropic-beta")
        urlRequest.setValue("application/json", forHTTPHeaderField: "content-type")
        urlRequest.httpBody = try JSONSerialization.data(withJSONObject: body)

        let started = Date.now
        let (data, response) = try await URLSession.shared.data(for: urlRequest)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else {
            let message = (try? JSONDecoder().decode(APIErrorEnvelope.self, from: data))?.error.message
            throw AgentError.http(status, message ?? String(decoding: data, as: UTF8.self))
        }

        let message = try JSONDecoder().decode(MessageResponse.self, from: data)
        if let usage = message.usage {
            await UsageTracker.shared.record(provider: "Claude", model: message.model ?? model, purpose: purpose,
                                             inputTokens: usage.input_tokens, outputTokens: usage.output_tokens,
                                             seconds: Date.now.timeIntervalSince(started))
        }
        switch message.stop_reason {
        case "refusal": throw AgentError.refusal
        case "max_tokens": throw AgentError.truncated
        default: break
        }
        guard let text = message.content.first(where: { $0.type == "text" })?.text else {
            throw AgentError.badResponse("no text block")
        }
        return text
    }

    // MARK: - Wire types

    private struct MessageResponse: Decodable {
        struct Block: Decodable { let type: String; let text: String? }
        struct Usage: Decodable { let input_tokens: Int; let output_tokens: Int }
        let content: [Block]
        let stop_reason: String?
        let model: String?
        let usage: Usage?
    }

    private struct ReplanDTO: Decodable {
        struct Decision: Decodable {
            let blockId: String, action: String, startTime: String, endTime: String, reason: String
        }
        let message: String
        let decisions: [Decision]
    }

    private static let replanSchema: [String: Any] = [
        "type": "object",
        "properties": [
            "message": ["type": "string"],
            "decisions": [
                "type": "array",
                "items": [
                    "type": "object",
                    "properties": [
                        "blockId": ["type": "string", "description": "e.g. b0"],
                        "action": ["type": "string", "enum": ReplanSuggestion.Action.allCases.map(\.rawValue)],
                        "startTime": ["type": "string", "description": "24h HH:MM"],
                        "endTime": ["type": "string", "description": "24h HH:MM"],
                        "reason": ["type": "string", "description": "Short reason"],
                    ],
                    "required": ["blockId", "action", "startTime", "endTime", "reason"],
                    "additionalProperties": false,
                ],
            ],
        ],
        "required": ["message", "decisions"],
        "additionalProperties": false,
    ]

    private struct APIErrorEnvelope: Decodable {
        struct Detail: Decodable { let message: String }
        let error: Detail
    }

    private struct PlanDTO: Decodable {
        struct Day: Decodable {
            let title: String, imagePrompt: String, activities: [ActivityDTO]
        }
        let days: [Day]
    }

    private struct ActivityDTO: Decodable {
        let startTime: String, endTime: String, title: String, detail: String, location: String
        let category: String, tags: [String], estimatedCost: Int

        var activity: Activity? {
            guard let start = Activity.minutes(from: startTime) else { return nil }
            return Activity(start: start, end: Activity.minutes(from: endTime) ?? start + 60,
                            title: title, detail: detail, location: location,
                            category: Activity.Category(rawValue: category) ?? .sightseeing,
                            tags: tags, estimatedCost: max(estimatedCost, 0))
        }
    }

    private struct ChatDTO: Decodable {
        let reply: String, changeDayNumber: Int, blocks: [ActivityDTO], changes: [String]
    }

    private static let chatSchema: [String: Any] = [
        "type": "object",
        "properties": [
            "reply": ["type": "string"],
            "changeDayNumber": ["type": "integer", "description": "0 when the plan doesn't change"],
            "blocks": ["type": "array", "items": activitySchema],
            "changes": ["type": "array", "items": ["type": "string"]],
        ],
        "required": ["reply", "changeDayNumber", "blocks", "changes"],
        "additionalProperties": false,
    ]

    private static let activitySchema: [String: Any] = [
        "type": "object",
        "properties": [
            "startTime": ["type": "string", "description": "24h HH:MM, e.g. 09:30"],
            "endTime": ["type": "string", "description": "24h HH:MM, e.g. 11:00"],
            "title": ["type": "string"],
            "detail": ["type": "string", "description": "One or two sentences"],
            "location": ["type": "string", "description": "Specific place name"],
            "tags": ["type": "array", "items": ["type": "string"]],
            "category": ["type": "string", "enum": Activity.Category.allCases.map(\.rawValue)],
            "estimatedCost": ["type": "integer"],
        ],
        "required": ["startTime", "endTime", "title", "detail", "location", "category", "tags", "estimatedCost"],
        "additionalProperties": false,
    ]

    private static let daySchema: [String: Any] = [
        "type": "object",
        "properties": [
            "title": ["type": "string"],
            "imagePrompt": ["type": "string"],
            "activities": ["type": "array", "items": activitySchema],
        ],
        "required": ["title", "imagePrompt", "activities"],
        "additionalProperties": false,
    ]
}
