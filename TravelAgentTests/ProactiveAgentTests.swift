import Foundation
import SwiftData
import Testing
@testable import TravelAgent

/// End-to-end tests of the agent's inbox with a fake clock, a fake GPS and the offline mock brain.
/// Each test drives one real-world change (time passes, you arrive somewhere, you say something)
/// and checks what the agent does: check-in, replan, proposal, notification, conversation.
@MainActor
@Suite(.serialized)
struct ProactiveAgentTests {
    let container: ModelContainer
    let spy = SpyAgent()
    let clock = FakeClock()
    let gps = FakeGPS()
    let agent: ProactiveAgent
    let trip: Trip

    init() throws {
        container = try ModelContainer(
            for: Trip.self, AgentEvent.self, ChatEntry.self, PlanProposal.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        trip = Fixtures.goaTrip(startingInDays: 0)
        container.mainContext.insert(trip)
        try container.mainContext.save()
        let (spy, clock, gps) = (spy, clock, gps)
        agent = ProactiveAgent(container: container, environment: .init(
            now: { clock.minutes }, place: { gps.place }, agent: { spy }, sideEffects: false))
    }

    private var context: ModelContext { container.mainContext }
    private func fetch<T: PersistentModel>(_ type: T.Type) -> [T] { (try? context.fetch(FetchDescriptor<T>())) ?? [] }
    private var pending: PlanProposal? { fetch(PlanProposal.self).first { $0.state == .pending } }
    private var todayTitles: [String] { trip.days[0].activities.map(\.title) }

    // MARK: - Time

    @Test("Scheduled check-in sees the time, where you are and the current block")
    func checkInUsesTimeAndLocation() async throws {
        clock.set(11, 0)
        gps.place = "Baga Beach, Calangute"

        await agent.handle(nil, source: .timer)

        let seen = try #require(spy.checkIns.last)
        #expect(seen.now == 11 * 60)
        #expect(seen.placeName == "Baga Beach, Calangute")
        #expect(seen.scheduledIndex == 1)  // Baga Beach block
        #expect(agent.latest?.status == .onTrack)
        #expect(agent.latest?.headline.contains("Baga Beach") == true)
        #expect(agent.sentNotifications.isEmpty, "On-track check-ins never notify")
    }

    @Test("As the clock moves, the agent follows the schedule")
    func agentFollowsTheClock() async {
        clock.set(11, 0)
        await agent.handle(nil, source: .timer)
        #expect(agent.latest?.headline.contains("Baga Beach") == true)

        clock.set(16, 0)
        await agent.handle(nil, source: .timer)
        #expect(agent.latest?.headline.contains("Fort Aguada") == true)

        clock.set(19, 30)  // between sunset and dinner
        await agent.handle(nil, source: .timer)
        #expect(agent.latest?.status == .free)
        #expect(spy.checkIns.count == 3)
    }

    @Test("Automatic check-ins stay quiet before and after the day, but Check now still works")
    func quietOutsideTheDay() async {
        clock.set(6, 0)
        await agent.handle(nil, source: .timer)
        clock.set(23, 30)
        await agent.handle(nil, source: .timer)
        #expect(spy.checkIns.isEmpty, "No API calls (and no notifications) outside the day")

        await agent.checkNow()
        #expect(spy.checkIns.count == 1)
    }

    // MARK: - Running late

    @Test("Staying too long: behind, Claude replans, Fort Aguada is skipped, you're notified")
    func stayingLateTriggersReplan() async throws {
        clock.set(16, 30)  // lunch was meant to end at 14:30
        gps.place = "Souza Lobo, Calangute"

        await agent.handle("Still here, staying longer than planned", source: .notification)

        #expect(agent.latest?.status == .behind)
        #expect(spy.replans == 1)
        let proposal = try #require(pending)
        #expect(proposal.source == .replan)
        let removed = PlanChange.diff(from: trip.days[0].activities, to: proposal.blocks)
            .filter { $0.kind == .removed }.map(\.block.title)
        #expect(removed == ["Fort Aguada"])
        #expect(agent.sentNotifications == ["Should you stay? New plan ready"])

        // Your words and the agent's answer (linked to the proposal) are in the conversation.
        let chat = fetch(ChatEntry.self).sorted { $0.date < $1.date }
        #expect(chat.map(\.role) == [.user, .agent])
        #expect(chat.last?.proposalID == proposal.id)
    }

    @Test("Applying the replan rewrites the day, and Undo puts it back")
    func applyAndUndo() async throws {
        clock.set(16, 30)
        await agent.handle("Still here, staying longer", source: .typed)
        let proposal = try #require(pending)
        let before = todayTitles

        agent.apply(proposal)
        #expect(!todayTitles.contains("Fort Aguada"))
        #expect(proposal.state == .applied && proposal.canUndo)

        agent.undo(proposal)
        #expect(todayTitles == before)
        #expect(proposal.state == .undone)
    }

    // MARK: - Location

    @Test("Arriving somewhere (geofence) wakes the agent, goes to the feed, not the chat")
    func geofenceArrival() async {
        clock.set(15, 10)
        gps.place = "Fort Aguada, Candolim"

        await ActivityResponder.handle(.arrived("Fort Aguada"), agent: agent)

        #expect(spy.checkIns.count == 1)
        #expect(spy.checkIns.last?.message == "Arrived at Fort Aguada (detected by location).")
        #expect(spy.checkIns.last?.placeName == "Fort Aguada, Candolim")
        let update = fetch(AgentEvent.self).first { $0.kind == .user }
        #expect(update?.detail == "Location")
        #expect(fetch(ChatEntry.self).isEmpty, "Automatic signals don't clutter the conversation")
    }

    @Test("Answering 'Still here' on a notification is understood as staying at that block")
    func notificationAnswer() async {
        clock.set(13, 5)
        await ActivityResponder.handle(.stillHere, blockTitle: "Baga Beach", agent: agent)
        #expect(spy.checkIns.last?.message == "Still at Baga Beach, staying longer than planned.")
    }

    // MARK: - Talking to the agent

    @Test("A change request escalates to Claude and becomes the one pending proposal")
    func changeRequest() async throws {
        clock.set(12, 0)
        await agent.handle("Skip the sunset at Chapora", source: .voice)

        #expect(spy.chats.count == 1)
        let proposal = try #require(pending)
        #expect(proposal.source == .chat)
        #expect(!proposal.blocks.map(\.title).contains("Sunset at Chapora"))
        #expect(agent.sentNotifications.isEmpty, "You asked in the app, so no notification")
    }

    @Test("Questions are answered by the quick check-in, without calling Claude")
    func questionStaysCheap() async {
        clock.set(12, 0)
        await agent.handle("What's next?", source: .typed)

        #expect(spy.checkIns.count == 1)
        #expect(spy.chats.isEmpty && spy.replans == 0)
        let reply = fetch(ChatEntry.self).first { $0.role == .agent }
        #expect(reply?.text.isEmpty == false)
    }

    @Test("A newer proposal replaces the older one, so only one is ever pending")
    func onlyOnePendingProposal() {
        let first = agent.propose([], dayNumber: 1, message: "first", source: .chat)
        let second = agent.propose([], dayNumber: 1, message: "second", source: .replan)
        #expect(first.state == .superseded)
        #expect(second.state == .pending)
        #expect(fetch(PlanProposal.self).filter { $0.state == .pending }.count == 1)
    }

    // MARK: - Trip phases

    @Test("An upcoming trip: no check-ins, but messages still reach the planner")
    func upcomingTrip() async throws {
        context.delete(trip)
        let future = Fixtures.goaTrip(startingInDays: 3)
        context.insert(future)
        try context.save()
        #expect(future.phase == .upcoming && future.today == nil)

        clock.set(11, 0)
        await agent.handle(nil, source: .timer)
        #expect(spy.checkIns.isEmpty)

        await agent.handle("Skip the sunset at Chapora", source: .typed)
        #expect(spy.checkIns.isEmpty)
        #expect(spy.chats.count == 1)
    }
}

/// Pure logic: the diff shown on proposals and how replan decisions rewrite a day.
@Suite struct PlanLogicTests {
    @Test func diffFindsRemovedAddedAndMovedBlocks() {
        let day = Fixtures.goaTrip(startingInDays: 0).days[0].activities
        var new = day.filter { $0.title != "Fort Aguada" }
        new[0].start += 30
        new.append(Activity(start: 22 * 60, end: 23 * 60, title: "Night market", detail: "", category: .nightlife,
                            estimatedCost: 0))
        let changes = PlanChange.diff(from: day, to: new)
        #expect(changes.filter { $0.kind == .removed }.map(\.block.title) == ["Fort Aguada"])
        #expect(changes.filter { $0.kind == .added }.map(\.block.title) == ["Night market"])
        #expect(changes.filter { $0.kind == .retimed }.map(\.block.title) == ["Breakfast"])
    }

    @Test func mockReplanSkipsWhatYouCantReachInTime() async throws {
        let day = Fixtures.goaTrip(startingInDays: 0).days[0]
        let lunch = day.activities[2]
        let suggestion = try await MockTravelAgent().replan(ReplanRequest(
            destination: "Goa", day: day, currentBlock: lunch, now: 16 * 60 + 30, placeName: nil))
        let updated = suggestion.apply(to: day)
        #expect(!updated.activities.map(\.title).contains("Fort Aguada"))
        #expect(updated.activities.contains { $0.title == "Dinner at Tito's" }, "Meals are kept")
        #expect(updated.activities.first { $0.title == "Lunch" }?.end == 16 * 60 + 30, "You stay until now")
    }
}

// MARK: - Test doubles

/// The offline mock brain, with every call recorded.
final class SpyAgent: TravelAgentService, @unchecked Sendable {
    private let mock = MockTravelAgent(simulatedLatency: .zero)
    var checkIns: [CheckInContext] = []
    var replans = 0
    var chats: [ChatRequest] = []
    var name: String { "Spy" }

    func planItinerary(for request: TripRequest) async throws -> [ItineraryDay] { try await mock.planItinerary(for: request) }
    func travelTips(for destination: String, interests: [String]) async throws -> [String] { [] }
    func nearbySuggestions(at place: String, time: String, destination: String, interests: [String]) async throws -> [String] { [] }

    func checkIn(_ context: CheckInContext) async throws -> CheckInResult {
        checkIns.append(context)
        return try await mock.checkIn(context)
    }

    func replan(_ request: ReplanRequest) async throws -> ReplanSuggestion {
        replans += 1
        return try await mock.replan(request)
    }

    func chat(_ request: ChatRequest) async throws -> ChatReply {
        chats.append(request)
        return try await mock.chat(request)
    }
}

final class FakeClock: @unchecked Sendable {
    var minutes = 12 * 60
    func set(_ hour: Int, _ minute: Int) { minutes = hour * 60 + minute }
}

final class FakeGPS: @unchecked Sendable {
    var place: String? = nil
}

enum Fixtures {
    /// One day in Goa: breakfast, beach, lunch, fort, sunset, dinner.
    static func goaTrip(startingInDays offset: Int) -> Trip {
        func block(_ from: (Int, Int), _ to: (Int, Int), _ title: String, _ place: String,
                   _ category: Activity.Category) -> Activity {
            Activity(start: from.0 * 60 + from.1, end: to.0 * 60 + to.1, title: title, detail: "",
                     location: place, category: category, estimatedCost: 500)
        }
        let day = ItineraryDay(dayNumber: 1, title: "Beaches & forts", activities: [
            block((9, 0), (10, 0), "Breakfast", "Infantaria, Calangute", .food),
            block((10, 30), (13, 0), "Baga Beach", "Baga Beach", .relax),
            block((13, 30), (14, 30), "Lunch", "Souza Lobo", .food),
            block((15, 0), (17, 0), "Fort Aguada", "Fort Aguada", .sightseeing),
            block((17, 30), (19, 0), "Sunset at Chapora", "Chapora Fort", .sightseeing),
            block((20, 0), (21, 30), "Dinner at Tito's", "Tito's Lane, Baga", .food),
        ])
        let start = Calendar.current.date(byAdding: .day, value: offset, to: .now)!
        return Trip(destination: "Goa", startDate: start, budget: 20_000, travelers: 1,
                    interests: [], days: [day], plannedBy: "Tests")
    }
}
