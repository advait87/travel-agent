import SwiftUI
import SwiftData

struct SettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @State private var confirmingDelete = false
    private var usage = UsageTracker.shared
    @AppStorage(AgentSettings.useMockKey) private var useMock = false
    @AppStorage(ProactiveAgent.intervalKey) private var checkInMinutes = 30
    @AppStorage(AgentSettings.groqModelKey) private var groqModel = AgentSettings.defaultGroqModel
    @State private var claudeKey = KeychainStore.get(.claudeAPIKey)
    @State private var groqKey = KeychainStore.get(.groqAPIKey)

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    SecureField("sk-ant-…", text: $claudeKey)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                } header: {
                    Text("Claude API key")
                } footer: {
                    Text("Plans full itineraries. Stored securely in the iOS Keychain.")
                }

                Section {
                    SecureField("gsk_…", text: $groqKey)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    TextField("Model", text: $groqModel)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                } header: {
                    Text("Groq API key & model")
                } footer: {
                    Text("Handles quick requests like travel tips. Any Groq model ID works, e.g. a Llama model.")
                }

                Section {
                    Picker("Check in every", selection: $checkInMinutes) {
                        ForEach([1, 5, 15, 30, 60], id: \.self) { Text("\($0) min").tag($0) }
                    }
                    Button("Send a test question now", systemImage: "bell.badge") {
                        if let trip = ActiveTrip.current(in: modelContext) {
                            Task { await NudgeScheduler.sendTestQuestion(for: trip) }
                        }
                    }
                    Button("Re-arm questions, Live Activity & geofences", systemImage: "arrow.clockwise") {
                        Task { await ProactiveAgent.shared.refreshAutomation() }
                    }
                } header: {
                    Text("Proactive agent")
                } footer: {
                    Text("While the app is open it checks in on this schedule. It also asks \"Done with …?\" at the end of every block, and wakes up when you arrive at or leave a planned place. The test question arrives in 5 s, so lock your phone to see it.")
                }

                Section {
                    Toggle("Use mock agent (offline)", isOn: $useMock)
                } footer: {
                    Text("The mock is used automatically when no Claude key is set.")
                }

                Section {
                    LabeledContent("Total cost", value: UsageTracker.format(usage.totalCost))
                    LabeledContent("Total tokens", value: usage.totalTokens.formatted())
                    ForEach(usage.entries) { entry in
                        VStack(alignment: .leading, spacing: 2) {
                            Text("\(entry.provider) · \(entry.purpose)").font(.subheadline.weight(.semibold))
                            Text(entry.model).font(.caption2).foregroundStyle(.secondary)
                            Text(entry.summary).font(.caption.monospacedDigit())
                        }
                    }
                    if !usage.entries.isEmpty {
                        Button("Clear log") { usage.clear() }
                    }
                } header: {
                    Text("Debug · AI usage (this session)")
                } footer: {
                    Text("Claude Opus 5.5 at $4 / $20 per million tokens (input / output). Groq rates are approximate.")
                }

                Section {
                    Button("Delete all trips", systemImage: "trash", role: .destructive) {
                        confirmingDelete = true
                    }
                    .confirmationDialog("Delete all trips?", isPresented: $confirmingDelete) {
                        Button("Delete all trips", role: .destructive) {
                            try? modelContext.delete(model: Trip.self)
                            try? modelContext.delete(model: AgentEvent.self)
                            try? modelContext.delete(model: ChatEntry.self)
                            try? modelContext.delete(model: PlanProposal.self)
                            try? modelContext.save()
                        }
                    }
                }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") {
                        KeychainStore.set(claudeKey, for: .claudeAPIKey)
                        KeychainStore.set(groqKey, for: .groqAPIKey)
                        dismiss()
                    }
                }
            }
        }
    }
}
