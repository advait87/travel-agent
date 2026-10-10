import SwiftUI

/// "I'm on this day right now" panel: where you are in the schedule, a warning when you're
/// running behind, agent replanning (what to skip), and suggestions near your GPS location.
struct LiveModeCard: View {
    let trip: Trip
    let dayNumber: Int

    @State private var now = Date.now
    @State private var atBlockID: UUID?
    @State private var replanning = false
    @State private var sentToAgent = false
    @State private var locating = false
    @State private var place: LocationService.Place?
    @State private var nearby: [String] = []
    @State private var errorMessage: String?
    @State private var location = LocationService()
    private var usage = UsageTracker.shared

    init(trip: Trip, dayNumber: Int) {
        self.trip = trip
        self.dayNumber = dayNumber
    }

    private var day: ItineraryDay? { trip.days.first { $0.dayNumber == dayNumber } }
    private var blocks: [Activity] { day?.activities.sorted { $0.start < $1.start } ?? [] }
    private var nowMinutes: Int {
        let parts = Calendar.current.dateComponents([.hour, .minute], from: now)
        return (parts.hour ?? 0) * 60 + (parts.minute ?? 0)
    }
    private var scheduledBlock: Activity? { blocks.first { $0.start <= nowMinutes && nowMinutes < $0.end } }
    private var nextBlock: Activity? { blocks.first { $0.start > nowMinutes } }
    private var atBlock: Activity? { blocks.first { $0.id == atBlockID } ?? scheduledBlock }
    private var minutesBehind: Int { atBlock.map { nowMinutes - $0.end } ?? 0 }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            scheduleStatus
            if minutesBehind > 15 {
                behindBanner
            } else if atBlock != nil {
                Button("Running late? Ask the agent", systemImage: "clock.arrow.circlepath") { replan() }
                    .font(.subheadline)
                    .disabled(replanning)
            }
            if replanning {
                HStack { ProgressView(); Text("Agent is rebalancing your day…").foregroundStyle(.secondary) }
                    .font(.subheadline)
            }
            if sentToAgent {
                Label("New plan is waiting in the agent card above.", systemImage: "arrow.up")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            Divider()
            nearMe
            if let errorMessage {
                Label(errorMessage, systemImage: "exclamationmark.circle")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .inset()
            }
            if let last = usage.entries.first {
                Label("Last AI call: \(last.purpose) · \(last.summary)", systemImage: "ladybug")
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
        }
        .card()
        .onChange(of: dayNumber) { sentToAgent = false; atBlockID = nil }
    }

    // MARK: - Sections

    private var header: some View {
        HStack {
            Label("Live · Day \(dayNumber)", systemImage: "dot.radiowaves.left.and.right")
                .font(.headline)
                .foregroundStyle(Theme.accent)
            Spacer()
            DatePicker("Time", selection: $now, displayedComponents: .hourAndMinute)
                .labelsHidden()
        }
    }

    @ViewBuilder
    private var scheduleStatus: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let scheduledBlock {
                Text("Schedule says: **\(scheduledBlock.title)** until \(Activity.clock(scheduledBlock.end))")
            } else if let nextBlock {
                Text("Next up: **\(nextBlock.title)** at \(Activity.clock(nextBlock.start))")
            } else {
                Text("Nothing else scheduled today.")
            }
            Picker("I'm actually at", selection: $atBlockID) {
                Text("Where the schedule says").tag(UUID?.none)
                ForEach(blocks) { block in
                    Text("\(Activity.clock(block.start)) \(block.title)").tag(UUID?.some(block.id))
                }
            }
            .pickerStyle(.menu)
        }
        .font(.subheadline)
    }

    private var behindBanner: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("You're \(minutesBehind / 60 > 0 ? "\(minutesBehind / 60)h " : "")\(minutesBehind % 60)m behind schedule",
                  systemImage: "exclamationmark.triangle.fill")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(Theme.accent)
            Text("You were meant to leave \(atBlock?.title ?? "") at \(Activity.clock(atBlock?.end ?? 0)).")
                .font(.caption)
            Button {
                replan()
            } label: {
                Label("Should I stay? Ask the agent what to skip", systemImage: "sparkles")
                    .font(.subheadline.weight(.semibold))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8)
            }
            .buttonStyle(.borderedProminent)
            .disabled(replanning)
        }
        .inset()
    }

    private var nearMe: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label(place.map { "Near \($0.name)" } ?? "Suggestions near me", systemImage: "location.fill")
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)
                Spacer()
                Button(nearby.isEmpty ? "Find" : "Refresh") { findNearby() }
                    .font(.subheadline)
                    .disabled(locating)
            }
            if locating {
                HStack { ProgressView(); Text("Locating you…").foregroundStyle(.secondary) }.font(.subheadline)
            }
            ForEach(nearby, id: \.self) { item in
                Label(item, systemImage: "mappin")
                    .font(.subheadline)
            }
        }
    }

    // MARK: - Actions

    private func replan() {
        guard let day, let atBlock else { return }
        replanning = true
        errorMessage = nil
        sentToAgent = false
        let request = ReplanRequest(destination: trip.destination, day: day, currentBlock: atBlock,
                                    now: nowMinutes, placeName: place?.name)
        Task {
            defer { replanning = false }
            do {
                // Same single proposal as automatic replans and chat, so there's one place to apply it.
                let suggestion = try await AgentSettings.currentAgent().replan(request)
                ProactiveAgent.shared.propose(suggestion.apply(to: day).activities, dayNumber: day.dayNumber,
                                              message: suggestion.message, source: .replan)
                sentToAgent = true
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    private func findNearby() {
        locating = true
        errorMessage = nil
        Task {
            defer { locating = false }
            do {
                let found = try await location.currentPlace()
                place = found
                nearby = try await AgentSettings.currentAgent().nearbySuggestions(
                    at: found.name, time: Activity.clock(nowMinutes),
                    destination: trip.destination, interests: trip.interests)
            } catch {
                errorMessage = "Near me: \(error.localizedDescription)"
            }
        }
    }
}
