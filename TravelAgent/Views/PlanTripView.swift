import SwiftUI

struct PlanTripView: View {
    var agent: TravelAgentService = AgentSettings.currentAgent()
    var onPlanned: (Trip) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var destination = ""
    @State private var startDate = Date.now
    @State private var numberOfDays = 3
    @State private var budget = 15000
    @State private var travelers = 1
    @State private var interests: Set<Interest> = [.beaches, .food]
    @State private var isPlanning = false
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            Form {
                Section("Destination") {
                    TextField("e.g. Goa", text: $destination)
                        .textInputAutocapitalization(.words)
                }
                Section("When") {
                    DatePicker("Start date", selection: $startDate, displayedComponents: .date)
                    Stepper("\(numberOfDays) days", value: $numberOfDays, in: 1...14)
                }
                Section("Budget & group") {
                    Stepper("Budget: ₹\(budget.formatted())", value: $budget, in: 1000...500000, step: 1000)
                    Stepper("\(travelers) traveler\(travelers == 1 ? "" : "s")", value: $travelers, in: 1...20)
                }
                Section("Interests") {
                    interestGrid
                }
                if let errorMessage {
                    Section { Text(errorMessage).foregroundStyle(.red) }
                }
            }
            .navigationTitle("Plan a trip")
            .safeAreaInset(edge: .top) {
                Label("Planning with \(agent.name)", systemImage: "cpu")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
                    .padding(.top, 4)
            }
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
            .safeAreaInset(edge: .bottom) { planButton }
            .disabled(isPlanning)
        }
    }

    private var interestGrid: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 100))], spacing: 10) {
            ForEach(Interest.allCases) { interest in
                let selected = interests.contains(interest)
                Button {
                    if selected { interests.remove(interest) } else { interests.insert(interest) }
                } label: {
                    Label(interest.rawValue, systemImage: interest.icon)
                        .font(.subheadline.weight(.medium))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 10)
                        .background(selected ? Color.primary : Color(.tertiarySystemFill), in: .capsule)
                        .foregroundStyle(selected ? Color(.systemBackground) : .primary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.vertical, 4)
    }

    private var planButton: some View {
        Button(action: plan) {
            HStack {
                if isPlanning {
                    ProgressView().tint(.white)
                    Text("\(agent.name) is planning…")
                } else {
                    Image(systemName: "sparkles")
                    Text("Generate itinerary")
                }
            }
            .font(.headline)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 16)
            .background(destination.isEmpty ? Color(.tertiarySystemFill) : Theme.accent, in: .rect(cornerRadius: 16))
            .foregroundStyle(destination.isEmpty ? Color.secondary : Color.black)
        }
        .disabled(destination.trimmingCharacters(in: .whitespaces).isEmpty || isPlanning)
        .padding()
        .background(.bar)
    }

    private func plan() {
        let request = TripRequest(
            destination: destination.trimmingCharacters(in: .whitespaces),
            startDate: startDate,
            numberOfDays: numberOfDays,
            budget: budget,
            travelers: travelers,
            interests: Interest.allCases.filter(interests.contains)
        )
        isPlanning = true
        errorMessage = nil
        Task {
            defer { isPlanning = false }
            do {
                let days = try await agent.planItinerary(for: request)
                onPlanned(Trip(destination: request.destination, startDate: request.startDate,
                               budget: request.budget, travelers: request.travelers,
                               interests: request.interests.map(\.rawValue), days: days,
                               plannedBy: agent.name))
            } catch {
                errorMessage = "Couldn't plan the trip: \(error.localizedDescription)"
            }
        }
    }
}
