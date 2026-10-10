import Foundation
import Observation

/// Debug log of every AI request: tokens, estimated cost and latency.
@MainActor @Observable
final class UsageTracker {
    static let shared = UsageTracker()

    struct Entry: Identifiable {
        let id = UUID()
        let date = Date.now
        let provider: String
        let model: String
        let purpose: String
        let inputTokens: Int
        let outputTokens: Int
        let costUSD: Double
        let seconds: Double

        var summary: String {
            "\(inputTokens.formatted()) in · \(outputTokens.formatted()) out · \(UsageTracker.format(costUSD)) · \(String(format: "%.1f", seconds))s"
        }
    }

    private(set) var entries: [Entry] = []

    var totalCost: Double { entries.reduce(0) { $0 + $1.costUSD } }
    var totalTokens: Int { entries.reduce(0) { $0 + $1.inputTokens + $1.outputTokens } }

    func record(provider: String, model: String, purpose: String,
                inputTokens: Int, outputTokens: Int, seconds: Double) {
        let rates = Self.rates(for: model)
        let cost = (Double(inputTokens) * rates.input + Double(outputTokens) * rates.output) / 1_000_000
        let entry = Entry(provider: provider, model: model, purpose: purpose, inputTokens: inputTokens,
                          outputTokens: outputTokens, costUSD: cost, seconds: seconds)
        entries.insert(entry, at: 0)
        print("[usage] \(provider) \(purpose): \(entry.summary)")
    }

    func clear() { entries.removeAll() }

    /// USD per million tokens (input, output). Groq rates are approximate; check groq.com/pricing.
    static func rates(for model: String) -> (input: Double, output: Double) {
        switch model {
        case let m where m.hasPrefix("claude-opus-5-5"): (4, 20)
        case let m where m.hasPrefix("claude-sonnet"): (2, 10)
        case let m where m.contains("gpt-oss-120b"): (0.15, 0.60)
        case let m where m.contains("gpt-oss-20b"): (0.10, 0.50)
        default: (0.10, 0.50)
        }
    }

    nonisolated static func format(_ usd: Double) -> String {
        usd < 0.01 ? String(format: "$%.4f", usd) : String(format: "$%.3f", usd)
    }
}
