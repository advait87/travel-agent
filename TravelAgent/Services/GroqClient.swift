import Foundation

/// Calls Groq's OpenAI-compatible chat API for small, fast requests
/// (open models such as Llama / GPT-OSS).
struct GroqClient {
    var apiKey: String
    var model: String

    func complete(_ prompt: String, purpose: String, maxTokens: Int = 2000) async throws -> String {
        var body: [String: Any] = [
            "model": model,
            "max_completion_tokens": maxTokens,
            "messages": [["role": "user", "content": prompt]],
        ]
        // GPT-OSS models reason before answering; keep that short so tokens go to the answer.
        if model.contains("gpt-oss") {
            body["reasoning_effort"] = "low"
        }
        var request = URLRequest(url: URL(string: "https://api.groq.com/openai/v1/chat/completions")!)
        request.httpMethod = "POST"
        request.timeoutInterval = 30
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let started = Date.now
        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else {
            throw AgentError.http(status, String(decoding: data, as: UTF8.self))
        }
        let decoded = try JSONDecoder().decode(ChatResponse.self, from: data)
        if let usage = decoded.usage {
            await UsageTracker.shared.record(provider: "Groq", model: model, purpose: purpose,
                                             inputTokens: usage.prompt_tokens, outputTokens: usage.completion_tokens,
                                             seconds: Date.now.timeIntervalSince(started))
        }
        guard let choice = decoded.choices.first,
              let text = choice.message.content?.trimmingCharacters(in: .whitespacesAndNewlines),
              !text.isEmpty else {
            let reason = decoded.choices.first?.finish_reason ?? "unknown"
            throw AgentError.badResponse("empty completion from \(model) (finish_reason: \(reason))")
        }
        return text
    }

    func travelTips(for destination: String, interests: [String]) async throws -> [String] {
        let text = try await complete("""
        Give exactly 4 short, practical travel tips for visiting \(destination)\
        \(interests.isEmpty ? "" : " for someone into \(interests.joined(separator: ", "))"). \
        One tip per line, under 20 words each, no numbering, no intro.
        """, purpose: "Travel tips")
        return Self.lines(text, limit: 4)
    }

    func nearbySuggestions(at place: String, time: String, destination: String, interests: [String]) async throws -> [String] {
        let text = try await complete("""
        I'm a traveler on a trip to \(destination), currently at \(place). Local time is \(time).\
        \(interests.isEmpty ? "" : " I enjoy \(interests.joined(separator: ", ")).")
        Suggest 4 specific things to do or eat within a short distance of where I am right now, \
        suited to this time of day. Format each line as "Place – short tip" (under 18 words). \
        One per line, no numbering, no intro.
        """, purpose: "Nearby suggestions")
        return Self.lines(text, limit: 4)
    }

    /// Routine 30-minute check-in: cheap and fast, so it runs on Groq.
    func checkIn(_ context: CheckInContext) async throws -> CheckInResult {
        let updates = context.recentUpdates.isEmpty ? "none" : context.recentUpdates.map { "- \($0)" }.joined(separator: "\n")
        let text = try await complete("""
        You are a proactive travel agent checking in on a traveler in \(context.destination), day \(context.dayNumber).
        Current time: \(Activity.clock(context.now)). GPS: \(context.placeName ?? "unknown").
        Today's schedule (index: time title at place):
        \(context.scheduleText)
        What the traveler told you recently (newest last):
        \(updates)
        Your last advice: \(context.lastAdvice ?? "none")
        \(context.message.map { "The traveler just said: \"\($0)\"" } ?? "This is a routine scheduled check-in (no new message).")

        Work out where they really are (use their updates over the schedule), whether they're on track, \
        and the single most useful next step. Reply with ONLY a JSON object:
        {"status": "on_track" | "behind" | "ahead" | "free", "headline": "<max 8 words>", \
        "advice": "<1-2 sentences, concrete next step with times>", "atBlockIndex": <int or -1>, \
        "shouldReplan": <true if they are 30+ min behind or plans changed, so later blocks no longer fit>, \
        "intent": "update" | "question" | "change", \
        "reply": "<if they said something: a direct, friendly 1-2 sentence answer; else empty>"}
        intent: "change" if they ask to add, remove, swap, move or find a different place/activity in the plan; \
        "question" if they ask something; otherwise "update". Answer questions yourself in reply.
        """, purpose: "Check-in")
        guard let start = text.firstIndex(of: "{"), let end = text.lastIndex(of: "}"),
              let json = try? JSONSerialization.jsonObject(with: Data(text[start...end].utf8)) as? [String: Any] else {
            throw AgentError.badResponse("check-in wasn't JSON: \(text.prefix(120))")
        }
        let index = json["atBlockIndex"] as? Int ?? -1
        return CheckInResult(
            status: CheckInResult.Status(rawValue: json["status"] as? String ?? "") ?? .onTrack,
            headline: json["headline"] as? String ?? "Check-in",
            advice: json["advice"] as? String ?? "",
            atBlockIndex: context.blocks.indices.contains(index) ? index : nil,
            shouldReplan: json["shouldReplan"] as? Bool ?? false,
            reply: json["reply"] as? String ?? "",
            intent: CheckInResult.Intent(rawValue: json["intent"] as? String ?? "") ?? .update)
    }

    private static func lines(_ text: String, limit: Int) -> [String] {
        text.split(separator: "\n")
            .map { $0.trimmingCharacters(in: CharacterSet(charactersIn: "-•*0123456789. ").union(.whitespaces)) }
            .filter { !$0.isEmpty }
            .prefix(limit)
            .map { String($0) }
    }

    private struct ChatResponse: Decodable {
        struct Choice: Decodable {
            struct Message: Decodable { let content: String? }
            let message: Message
            let finish_reason: String?
        }
        struct Usage: Decodable { let prompt_tokens: Int; let completion_tokens: Int }
        let choices: [Choice]
        let usage: Usage?
    }
}
