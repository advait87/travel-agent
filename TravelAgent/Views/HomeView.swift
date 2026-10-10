import SwiftUI
import SwiftData

/// Home is the trip you're on: today's route, the agent (its latest call, your last exchange and the
/// one pending plan change), one box to tell or ask it anything, today's schedule and the feed.
struct HomeView: View {
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \Trip.createdAt, order: .reverse) private var trips: [Trip]
    @Query(sort: \AgentEvent.date, order: .reverse) private var events: [AgentEvent]
    @Query(sort: \ChatEntry.date, order: .reverse) private var chat: [ChatEntry]
    @Query(sort: \PlanProposal.createdAt, order: .reverse) private var proposals: [PlanProposal]
    @State private var showingPlanner = false
    @State private var showingSettings = false
    @State private var openedTrip: Trip?
    @State private var mappedTrip: Trip?
    @State private var showingChat = false
    @State private var visibleDay: Int?
    @State private var update = ""
    @FocusState private var composerFocused: Bool
    private var agent = ProactiveAgent.shared
    private var router = AppRouter.shared

    private var currentTrip: Trip? { ActiveTrip.current(in: modelContext) }
    private var pending: PlanProposal? { proposals.first { $0.state == .pending } }
    private var justApplied: PlanProposal? { proposals.first { $0.canUndo } }

    var body: some View {
        NavigationStack {
            ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    if let trip = currentTrip {
                        tripHeader(trip).id("top")
                        Button { mappedTrip = trip } label: { MiniDayMap(trip: trip) }
                            .buttonStyle(.plain)
                        agentCard(trip).id("agent")
                        composer
                        DayCarousel(trip: trip, visibleDay: $visibleDay)
                            .padding(.horizontal, -16)
                            .id("days")
                        LiveModeCard(trip: trip, dayNumber: visibleDay ?? trip.todayNumber).id("live")
                        feed.id("feed")
                        TripSummaryCard(trip: trip)
                        TripTipsCard(trip: trip)
                    } else {
                        heroCard
                    }
                    otherTrips
                }
                .padding()
            }
            .onChange(of: router.scrollTarget) { _, target in
                guard let target else { return }
                withAnimation { proxy.scrollTo(target, anchor: .top) }
                router.scrollTarget = nil
            }
            .onChange(of: router.say) { _, text in
                guard let text else { return }
                router.say = nil
                withAnimation { proxy.scrollTo("agent", anchor: .top) }
                Task { await typeAndSend(text) }
            }
            .onChange(of: router.showMap) { _, show in
                if show, let trip = currentTrip { mappedTrip = trip }
                if !show { mappedTrip = nil }
            }
            .onChange(of: router.showChat) { _, show in showingChat = show }
            }
            .background(Color(.systemGroupedBackground))
            .navigationTitle(navigationTitle)
            .toolbar {
                ToolbarItemGroup(placement: .topBarTrailing) {
                    Button("New trip", systemImage: "plus") { showingPlanner = true }
                    Button("Settings", systemImage: "gearshape") { showingSettings = true }
                }
            }
            .sheet(isPresented: $showingSettings) { SettingsView() }
            .navigationDestination(item: $openedTrip) { trip in
                ItineraryView(trip: trip)
            }
            .navigationDestination(item: $mappedTrip) { trip in
                DayMapView(trip: trip)
            }
            .sheet(isPresented: $showingChat) { ChatView() }
            .sheet(isPresented: $showingPlanner) {
                PlanTripView { trip in
                    modelContext.insert(trip)
                    try? modelContext.save()
                    showingPlanner = false
                    agent.restartTimer()
                    Task { await agent.refreshAutomation() }
                }
            }
            .onChange(of: router.composeRequested, initial: true) { _, requested in
                if requested {
                    composerFocused = true
                    router.composeRequested = false
                }
            }
        }
    }

    private var navigationTitle: String {
        switch currentTrip?.phase {
        case .active: "Today"
        case .upcoming: "Next trip"
        case .finished: "Last trip"
        case nil: "Travel Agent"
        }
    }

    // MARK: - Current trip

    private func tripHeader(_ trip: Trip) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            switch trip.phase {
            case .active: Eyebrow(text: "Current trip · Day \(trip.todayNumber) of \(trip.days.count)")
            case .upcoming:
                Eyebrow(text: "Starts \(trip.daysUntilStart == 1 ? "tomorrow" : "in \(trip.daysUntilStart) days") · "
                        + trip.startDate.formatted(.dateTime.weekday(.abbreviated).day().month()))
            case .finished: Eyebrow(text: "Trip complete · \(trip.days.count) days")
            }
            Text(trip.destination).font(.largeTitle.bold())
        }
    }

    /// Everything the agent has to say, in one place: status, latest call, your last exchange, the
    /// pending plan change (or Undo for the one just applied), and errors with Retry.
    private func agentCard(_ trip: Trip) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Eyebrow(text: statusText(trip))
                Spacer()
                if agent.isWorking {
                    ProgressView().controlSize(.small)
                } else if trip.phase == .active {
                    Button("Check now") { Task { await agent.checkNow() } }
                        .font(.subheadline)
                }
            }

            switch trip.phase {
            case .upcoming:
                Text("I'll start watching your day on \(trip.startDate.formatted(.dateTime.weekday(.wide).day().month())).")
                    .font(.title2.bold())
                Text("Until then, ask me to change anything in the plan.").font(.body)
            case .finished:
                Text("Hope it was a great trip!").font(.title2.bold())
                Text("Plan the next one with +.").font(.body)
            case .active:
                if let latest = agent.latest {
                    Text(latest.headline).font(.title.bold())
                    // The check-in advice and the replan's reasoning read as one explanation.
                    Text([latest.advice, pending?.source == .replan ? pending?.message : nil]
                        .compactMap { $0 }.joined(separator: " "))
                        .font(.body)
                } else if !agent.isWorking {
                    Text("Your agent checks in automatically.")
                        .font(.title3.weight(.semibold))
                        .foregroundStyle(.secondary)
                }
            }

            if agent.isWorking {
                Text(agent.workingLabel).font(.subheadline).foregroundStyle(.secondary)
            }

            lastExchange

            if let pending {
                ProposalCard(proposal: pending)
            } else if let justApplied {
                ProposalCard(proposal: justApplied)
            }

            if let error = agent.lastError {
                HStack(alignment: .top) {
                    Label(error, systemImage: "exclamationmark.triangle")
                        .font(.subheadline)
                    Spacer()
                    Button("Retry") { Task { await agent.retry() } }
                        .font(.subheadline.weight(.semibold))
                        .disabled(agent.isWorking)
                }
                .inset()
            }

            if trip.phase == .active, let next = agent.nextCheck {
                Text("Next check-in \(next.formatted(.relative(presentation: .named))) · every \(agent.intervalMinutes) min")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(6)
        .card()
    }

    /// Your most recent message and the agent's answer (last 30 minutes).
    @ViewBuilder
    private var lastExchange: some View {
        if let reply = chat.first, reply.role == .agent, Date.now.timeIntervalSince(reply.date) < 1800 {
            let question = chat.dropFirst().first { $0.role == .user }
            VStack(alignment: .leading, spacing: 6) {
                if let question {
                    Text("You: \(question.text)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
                // When the reply is the check-in above, don't say it twice: just show what you said.
                if !(agent.latest.map { reply.text.contains($0.advice) } ?? false) {
                    Label { Text(reply.text) } icon: { Image(systemName: "sparkles").foregroundStyle(Theme.accent) }
                        .font(.subheadline)
                }
            }
            .inset()
        }
    }

    private func statusText(_ trip: Trip) -> String {
        guard trip.phase == .active else { return "Your agent" }
        switch agent.latest?.status {
        case .behind: return "Behind schedule"
        case .ahead: return "Ahead of schedule"
        case .free: return "Free time"
        case .onTrack: return "On track"
        case nil: return "Your agent"
        }
    }

    /// One box for everything you tell or ask the agent, typed or with the held mic.
    private var composer: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .bottom, spacing: 8) {
                TextField("Tell or ask your agent…", text: $update, axis: .vertical)
                    .lineLimit(1...4)
                    .focused($composerFocused)
                    .accessibilityIdentifier("agentBox")
                    .padding(12)
                    .background(Color(.secondarySystemGroupedBackground), in: .rect(cornerRadius: Theme.radius))
                    .overlay(RoundedRectangle(cornerRadius: Theme.radius).strokeBorder(Theme.border))
                HoldToTalkButton(liveText: $update) { send($0, source: .voice) }
                Button {
                    send(update, source: .typed)
                } label: {
                    Image(systemName: "arrow.up.circle.fill").font(.system(size: 34))
                }
                .accessibilityLabel("Send")
                .disabled(update.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            if chat.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(ProactiveAgent.starters, id: \.self) { starter in
                            Button(starter) { send(starter, source: .typed) }
                                .font(.caption.weight(.semibold))
                                .buttonStyle(.bordered)
                                .buttonBorderShape(.capsule)
                                .tint(.secondary)
                        }
                    }
                }
                .scrollClipDisabled()
            } else {
                Button {
                    showingChat = true
                } label: {
                    Label("See conversation (\(chat.count))", systemImage: "bubble.left.and.text.bubble.right")
                        .font(.caption.weight(.semibold))
                }
                .tint(.secondary)
            }
        }
    }

    /// Demo remote: types the text into the box letter by letter, then sends it like dictation.
    private func typeAndSend(_ text: String) async {
        update = ""
        for character in text {
            update.append(character)
            try? await Task.sleep(for: .milliseconds(35))
        }
        try? await Task.sleep(for: .milliseconds(400))
        send(update, source: .voice)
    }

    private func send(_ text: String, source: ProactiveAgent.Source) {
        update = ""
        composerFocused = false
        Task { await agent.handle(text, source: source) }
    }

    private var feed: some View {
        VStack(alignment: .leading, spacing: 12) {
            Eyebrow(text: "Agent feed")
            if events.isEmpty {
                Text("Check-ins and your updates will appear here.").font(.subheadline).foregroundStyle(.secondary)
            }
            ForEach(Array(events.prefix(12).enumerated()), id: \.element.id) { index, event in
                if index > 0 { Divider() }
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: icon(for: event.kind))
                        .foregroundStyle(event.kind == .alert ? Theme.accent : .secondary)
                        .frame(width: 20)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(event.title).font(.subheadline.weight(.semibold))
                        if !event.detail.isEmpty {
                            Text(event.detail).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    Spacer()
                    Text(event.date.formatted(date: .omitted, time: .shortened))
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }
        }
        .card()
    }

    private func icon(for kind: AgentEvent.Kind) -> String {
        switch kind {
        case .user: "person.fill"
        case .checkIn: "sparkles"
        case .alert: "exclamationmark.triangle.fill"
        }
    }

    // MARK: - No trip / other trips

    private var heroCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Image(systemName: "airplane.departure").font(.largeTitle).foregroundStyle(Theme.accent)
            Text("Where to next?").font(.title.bold())
            Text("Plan a trip and your agent will look after the day for you.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Button {
                showingPlanner = true
            } label: {
                Label("Plan a new trip", systemImage: "sparkles")
                    .font(.headline)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 6)
            }
            .buttonStyle(.borderedProminent)
        }
        .card()
    }

    @ViewBuilder
    private var otherTrips: some View {
        let others = trips.filter { $0.id != currentTrip?.id }
        if !others.isEmpty {
            DisclosureGroup("Other trips (\(others.count))") {
                ForEach(others) { trip in
                    Button {
                        openedTrip = trip
                    } label: {
                        HStack {
                            Text(trip.destination)
                            Spacer()
                            Text("\(trip.days.count) days").foregroundStyle(.secondary)
                        }
                        .padding(.vertical, 6)
                    }
                    .contextMenu {
                        Button("Delete trip", systemImage: "trash", role: .destructive) {
                            modelContext.delete(trip)
                        }
                    }
                }
            }
            .card()
        }
    }
}
