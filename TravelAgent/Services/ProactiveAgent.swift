import Foundation
import SwiftData
import BackgroundTasks
import UserNotifications
import CoreLocation
import UIKit

/// The agent's single inbox. Everything the traveler says (typed, voice, Siri, notification answers,
/// Live Activity buttons), everything the phone notices (geofences) and the timer all go through
/// `handle(_:source:)`:
///
///   1. Triage (Groq, ~2 s): where are they, are they on track, and what kind of message is this?
///   2. Escalate to Claude only when the plan has to change (asked for, or they've fallen behind).
///   3. The result is one saved PlanProposal, shown in the same place whatever triggered it.
@MainActor @Observable
final class ProactiveAgent {
    static let shared = ProactiveAgent()

    /// Where the agent gets the time, your location and its brain, and whether it may touch the phone
    /// (Live Activity, notifications, geofences, background tasks). Tests swap these out.
    struct Environment {
        var now: () -> Int
        var place: () async -> String?
        var agent: () -> TravelAgentService
        var sideEffects: Bool

        @MainActor static let live = Environment(
            now: { ProactiveAgent.minutesNow() }, place: { await ProactiveAgent.placeName() },
            agent: { AgentSettings.currentAgent() }, sideEffects: true)
    }
    static let backgroundTaskID = "com.advaitandhale.travelagent.checkin"
    static let intervalKey = "checkInMinutes"
    static let starters = ["I'm running late", "Find me a quieter dinner spot",
                           "I'm tired, make this afternoon chill", "What's good near me?"]

    enum Source: String {
        case typed, voice, siri, notification, liveActivity, geofence, timer, manual, background

        var label: String {
            switch self {
            case .typed: "You typed"
            case .voice: "You said"
            case .siri: "Siri"
            case .notification: "Notification answer"
            case .liveActivity: "Live Activity"
            case .geofence: "Location"
            case .timer: "Scheduled check-in"
            case .manual: "Manual check"
            case .background: "Background check-in"
            }
        }

        /// Human words belong in the conversation; automatic signals only go to the feed.
        var isConversational: Bool { [.typed, .voice, .siri, .notification].contains(self) }
    }

    private(set) var isWorking = false
    private(set) var workingLabel = ""
    private(set) var lastCheck: Date?
    private(set) var latest: CheckInResult?
    private(set) var lastError: String?
    private var failed: (text: String?, source: Source)?
    private var lastNotification: (title: String, date: Date)?
    /// Titles of notifications the policy let through (for tests and debugging).
    private(set) var sentNotifications: [String] = []
    private var loop: Task<Void, Never>?

    var intervalMinutes: Int {
        let value = UserDefaults.standard.integer(forKey: Self.intervalKey)
        return value > 0 ? value : 30
    }

    var nextCheck: Date? { lastCheck?.addingTimeInterval(Double(intervalMinutes) * 60) }

    private let container: ModelContainer
    var environment: Environment
    private var context: ModelContext { container.mainContext }

    init(container: ModelContainer = SharedModel.container, environment: Environment = .live) {
        self.container = container
        self.environment = environment
    }

    // MARK: - Lifecycle

    /// Foreground loop. Background check-ins are handled by BGAppRefresh (see scheduleBackgroundCheckIn).
    func start() {
        guard loop == nil else { return }
        loop = Task {
            while !Task.isCancelled {
                await rearmIfNewDay()
                if lastCheck.map({ Date.now.timeIntervalSince($0) >= Double(intervalMinutes) * 60 }) ?? true {
                    await handle(nil, source: .timer)
                }
                try? await Task.sleep(for: .seconds(20))
            }
        }
    }

    func restartTimer() { lastCheck = nil }

    /// Re-arms everything for the current trip: questions, Live Activity and geofences. Permissions are
    /// asked for here, in context, once there's a trip to look after.
    func refreshAutomation() async {
        guard environment.sideEffects else { return }
        UserDefaults.standard.set(Self.dayKey(), forKey: "armedDay")
        guard let trip = ActiveTrip.current(in: context) else { return }
        _ = try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge])
        await NudgeScheduler.schedule(for: trip)
        guard trip.phase == .active else {
            await LiveActivityManager.endAll()
            GeofenceManager.shared.clear()
            return
        }
        await LiveActivityManager.update(trip: trip, headline: latest?.headline ?? "Your agent is on it",
                                         status: latest?.status.rawValue ?? "on_track")
        await GeofenceManager.shared.refresh(for: trip)
    }

    /// A new day means new places to fence, a fresh Live Activity and the next 48 h of questions.
    func rearmIfNewDay() async {
        if UserDefaults.standard.string(forKey: "armedDay") != Self.dayKey() {
            latest = nil
            await refreshAutomation()
        }
    }

    private static func dayKey() -> String {
        let parts = Calendar.current.dateComponents([.year, .month, .day], from: .now)
        return "\(parts.year ?? 0)-\(parts.month ?? 0)-\(parts.day ?? 0)"
    }

    static func scheduleBackgroundCheckIn() {
        let request = BGAppRefreshTaskRequest(identifier: backgroundTaskID)
        let minutes = UserDefaults.standard.integer(forKey: intervalKey)
        request.earliestBeginDate = .now.addingTimeInterval(Double(minutes > 0 ? minutes : 30) * 60)
        try? BGTaskScheduler.shared.submit(request)
    }

    // MARK: - The inbox

    /// Handles one input (or a timer tick when `text` is nil). Returns the reply, for Siri.
    @discardableResult
    func handle(_ text: String?, source: Source) async -> String {
        let message = text?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let message {
            guard !message.isEmpty else { return "I didn't catch that." }
            // Never drop what the traveler said: wait for any running check to finish.
            while isWorking { try? await Task.sleep(for: .milliseconds(300)) }
            context.insert(AgentEvent(kind: .user, title: message, detail: source.label))
            if source.isConversational { context.insert(ChatEntry(role: .user, text: message)) }
            try? context.save()
        } else if isWorking {
            return ""
        }

        guard let trip = ActiveTrip.current(in: context) else { return "Plan a trip first and I'll look after it." }
        guard let day = trip.today else {
            // Before or after the trip there's no day to watch; messages still reach the planner.
            guard let message else { lastCheck = .now; return "" }
            return await run(source: source, text: message) { try await self.converse(trip: trip, source: source) }
        }

        let now = environment.now()
        let blocks = day.activities.sorted { $0.start < $1.start }
        // Outside the day (before the first block, after the last) automatic check-ins stay quiet.
        if message == nil, source != .manual, let first = blocks.first, let last = blocks.last,
           now < first.start - 60 || now > last.end + 30 {
            lastCheck = .now
            return ""
        }

        return await run(source: source, text: message) {
            let place = await self.environment.place()
            let checkContext = CheckInContext(
                destination: trip.destination, dayNumber: day.dayNumber, now: now, blocks: blocks,
                placeName: place, recentUpdates: self.recentUpdates(),
                lastAdvice: self.latest.map { "\($0.headline). \($0.advice)" }, message: message)
            let agent = self.environment.agent()

            self.workingLabel = message == nil ? "Checking your day…" : "Thinking…"
            let result = try await agent.checkIn(checkContext)
            self.latest = result
            if self.environment.sideEffects {
                await LiveActivityManager.update(trip: trip, headline: result.headline, status: result.status.rawValue)
            }
            self.context.insert(AgentEvent(kind: result.status == .behind ? .alert : .checkIn,
                                           title: result.headline, detail: "\(source.label) · \(result.advice)"))

            var reply = result.reply.isEmpty ? "\(result.headline). \(result.advice)" : result.reply
            var proposal: PlanProposal?

            if message != nil && result.intent == .change {
                // Asked for a change: Claude rewrites the day.
                return try await self.converse(trip: trip, source: source, place: place)
            } else if result.shouldReplan,
                      let atIndex = result.atBlockIndex ?? checkContext.scheduledIndex ?? blocks.lastIndex(where: { $0.start <= now }),
                      blocks.indices.contains(atIndex) {
                // Fallen behind: Claude decides what to skip.
                self.workingLabel = "You're behind, rebalancing your day…"
                let suggestion = try await agent.replan(ReplanRequest(
                    destination: trip.destination, day: day, currentBlock: blocks[atIndex], now: now, placeName: place))
                proposal = self.propose(suggestion.apply(to: day).activities, dayNumber: day.dayNumber,
                                        message: suggestion.message, source: .replan)
                if message != nil { reply += " " + suggestion.message }
            }

            if message != nil, source.isConversational {
                self.context.insert(ChatEntry(role: .agent, text: reply, proposalID: proposal?.id))
            }
            try? self.context.save()

            // Notify only when something needs the traveler's attention.
            if let proposal {
                self.notify(title: "Should you stay? New plan ready", body: proposal.message)
            } else if message == nil && result.status == .behind {
                self.notify(title: result.headline, body: result.advice)
            } else if source == .notification && result.intent == .question {
                // Asked from a notification reply: answer the same way.
                self.notify(title: "Your agent", body: reply)
            }
            return reply
        }
    }

    /// Manual "Check now".
    func checkNow() async { await handle(nil, source: .manual) }

    func retry() async {
        guard let failed else { return }
        self.failed = nil
        if let text = failed.text {
            // The message is already in the conversation; re-run without logging it twice.
            await rerun(text: text, source: failed.source)
        } else {
            await handle(nil, source: failed.source)
        }
    }

    private func rerun(text: String, source: Source) async {
        guard let trip = ActiveTrip.current(in: context) else { return }
        _ = await run(source: source, text: text) { try await self.converse(trip: trip, source: source) }
    }

    /// Shared bookkeeping: busy state, errors (with retry) and the next check-in time.
    private func run(source: Source, text: String?, _ work: () async throws -> String) async -> String {
        isWorking = true
        lastError = nil
        defer {
            isWorking = false
            workingLabel = ""
            lastCheck = .now
            if environment.sideEffects { Self.scheduleBackgroundCheckIn() }
        }
        do {
            return try await work()
        } catch {
            lastError = error.localizedDescription
            failed = (text, source)
            return "Sorry, I couldn't reach your agent: \(error.localizedDescription)"
        }
    }

    /// Claude conversation: answers and, when asked, rewrites a day.
    private func converse(trip: Trip, source: Source, place: String? = nil) async throws -> String {
        workingLabel = "Reworking your plan…"
        let history = recentChat().map { ChatTurn(role: $0.role, text: $0.text) }
        let request = ChatRequest(
            destination: trip.destination, travelers: trip.travelers, budget: trip.budget, days: trip.days,
            todayNumber: trip.todayNumber, now: environment.now(), placeName: place,
            recentUpdates: recentUpdates(), history: history)
        let answer = try await environment.agent().chat(request)
        let proposal = answer.proposal.map {
            propose($0.blocks, dayNumber: $0.dayNumber, message: answer.reply, source: .chat)
        }
        if source.isConversational {
            context.insert(ChatEntry(role: .agent, text: answer.reply, proposalID: proposal?.id))
        }
        try? context.save()
        if source != .typed && source != .voice, let proposal {
            notify(title: "New plan ready", body: proposal.message)
        }
        return answer.reply
    }

    // MARK: - Proposals

    /// Saves a new proposal; any older pending one is superseded so there's only ever one.
    @discardableResult
    func propose(_ blocks: [Activity], dayNumber: Int, message: String, source: PlanProposal.Source) -> PlanProposal {
        let pending = PlanProposal.State.pending.rawValue
        let open = (try? context.fetch(FetchDescriptor<PlanProposal>(predicate: #Predicate { $0.stateRaw == pending }))) ?? []
        open.forEach { $0.state = .superseded }
        let proposal = PlanProposal(dayNumber: dayNumber, blocks: blocks, message: message, source: source)
        context.insert(proposal)
        context.insert(AgentEvent(kind: .alert, title: "New plan ready", detail: message))
        try? context.save()
        return proposal
    }

    func apply(_ proposal: PlanProposal) {
        guard let trip = ActiveTrip.current(in: context) else { return }
        var days = trip.days
        guard let index = days.firstIndex(where: { $0.dayNumber == proposal.dayNumber }) else { return }
        proposal.previous = days[index].activities
        days[index].activities = proposal.blocks
        trip.days = days
        proposal.state = .applied
        proposal.appliedAt = .now
        let changes = PlanChange.diff(from: proposal.previous, to: proposal.blocks)
        context.insert(AgentEvent(kind: .checkIn, title: "Plan updated",
                                  detail: changes.map { "\($0.kind == .removed ? "Skip" : $0.kind == .added ? "Add" : "Move") \($0.block.title)" }
                                      .joined(separator: " · ")))
        try? context.save()
        Task { await refreshAutomation() }
    }

    func dismiss(_ proposal: PlanProposal) {
        proposal.state = .dismissed
        try? context.save()
    }

    func undo(_ proposal: PlanProposal) {
        guard proposal.canUndo, let trip = ActiveTrip.current(in: context) else { return }
        var days = trip.days
        guard let index = days.firstIndex(where: { $0.dayNumber == proposal.dayNumber }) else { return }
        days[index].activities = proposal.previous
        trip.days = days
        proposal.state = .undone
        context.insert(AgentEvent(kind: .checkIn, title: "Plan change undone"))
        try? context.save()
        Task { await refreshAutomation() }
    }

    // MARK: - Helpers

    func recentUpdates() -> [String] {
        let since = Date.now.addingTimeInterval(-4 * 3600)
        let descriptor = FetchDescriptor<AgentEvent>(
            predicate: #Predicate { $0.date > since && $0.kindRaw == "user" },
            sortBy: [SortDescriptor(\.date)])
        return ((try? context.fetch(descriptor)) ?? []).map {
            "\($0.date.formatted(date: .omitted, time: .shortened)): \($0.title)"
        }
    }

    private func recentChat() -> [ChatEntry] {
        var descriptor = FetchDescriptor<ChatEntry>(sortBy: [SortDescriptor(\.date, order: .reverse)])
        descriptor.fetchLimit = 12
        return ((try? context.fetch(descriptor)) ?? []).reversed()
    }

    nonisolated static func minutesNow() -> Int {
        let parts = Calendar.current.dateComponents([.hour, .minute], from: .now)
        return (parts.hour ?? 0) * 60 + (parts.minute ?? 0)
    }

    /// Last known location (works in the background too, if location is authorized).
    static func placeName() async -> String? {
        guard let location = CLLocationManager().location else { return nil }
        let placemark = try? await CLGeocoder().reverseGeocodeLocation(location).first
        return [placemark?.name, placemark?.locality].compactMap { $0 }.joined(separator: ", ")
    }

    /// Notification policy: never while the app is open (the screen already shows it), and never the
    /// same thing twice within 10 minutes.
    private func notify(title: String, body: String) {
        if environment.sideEffects && UIApplication.shared.applicationState == .active { return }
        if let last = lastNotification, last.title == title, Date.now.timeIntervalSince(last.date) < 600 { return }
        lastNotification = (title, .now)
        sentNotifications.append(title)
        guard environment.sideEffects else { return }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        UNUserNotificationCenter.current().add(
            UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
    }
}
