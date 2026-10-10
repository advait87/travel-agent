import SwiftUI
import SwiftData

/// The full conversation with the agent. Sending here goes through the same inbox as the Home box.
struct ChatView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \ChatEntry.date) private var entries: [ChatEntry]
    @Query private var proposals: [PlanProposal]
    @State private var draft = ""
    private var agent = ProactiveAgent.shared

    var body: some View {
        NavigationStack {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 12) {
                        if entries.isEmpty { emptyState }
                        ForEach(entries) { entry in
                            bubble(entry).id(entry.id)
                        }
                        if agent.isWorking {
                            HStack { ProgressView(); Text(agent.workingLabel).foregroundStyle(.secondary) }
                                .font(.subheadline)
                                .id("typing")
                        }
                    }
                    .padding()
                }
                .scrollDismissesKeyboard(.interactively)
                .onAppear { proxy.scrollTo(entries.last?.id, anchor: .bottom) }
                .onChange(of: entries.count) {
                    withAnimation { proxy.scrollTo(entries.last?.id, anchor: .bottom) }
                }
                .onChange(of: agent.isWorking) {
                    if agent.isWorking { withAnimation { proxy.scrollTo("typing", anchor: .bottom) } }
                }
            }
            .safeAreaInset(edge: .bottom) { composer }
            .background(Color(.systemGroupedBackground))
            .navigationTitle("Your agent")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Close") { dismiss() } }
                ToolbarItem(placement: .primaryAction) {
                    Button("Clear", systemImage: "trash") {
                        entries.forEach(modelContext.delete)
                        try? modelContext.save()
                    }
                    .disabled(entries.isEmpty)
                }
            }
        }
    }

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 12) {
            Eyebrow(text: "Try asking")
            ForEach(ProactiveAgent.starters, id: \.self) { starter in
                Button {
                    send(starter, source: .typed)
                } label: {
                    Text(starter).font(.subheadline).frame(maxWidth: .infinity, alignment: .leading)
                }
                .buttonStyle(.plain)
                .inset()
            }
        }
    }

    @ViewBuilder
    private func bubble(_ entry: ChatEntry) -> some View {
        switch entry.role {
        case .user:
            Text(entry.text)
                .font(.subheadline)
                .padding(12)
                .background(Theme.accent.opacity(0.18), in: .rect(cornerRadius: Theme.radius))
                .frame(maxWidth: .infinity, alignment: .trailing)
                .padding(.leading, 48)
        case .agent:
            VStack(alignment: .leading, spacing: 10) {
                Label { Text(entry.text) } icon: { Image(systemName: "sparkles").foregroundStyle(Theme.accent) }
                    .font(.subheadline)
                if let id = entry.proposalID, let proposal = proposals.first(where: { $0.id == id }) {
                    ProposalCard(proposal: proposal)
                }
            }
            .card()
            .padding(.trailing, 24)
        }
    }

    private var composer: some View {
        HStack(alignment: .bottom, spacing: 8) {
            TextField("Tell or ask your agent…", text: $draft, axis: .vertical)
                .lineLimit(1...4)
                .padding(12)
                .background(Color(.secondarySystemGroupedBackground), in: .rect(cornerRadius: Theme.radius))
                .overlay(RoundedRectangle(cornerRadius: Theme.radius).strokeBorder(Theme.border))
            HoldToTalkButton(liveText: $draft) { send($0, source: .voice) }
            Button {
                send(draft, source: .typed)
            } label: {
                Image(systemName: "arrow.up.circle.fill").font(.system(size: 34))
            }
            .accessibilityLabel("Send")
            .disabled(draft.trimmingCharacters(in: .whitespaces).isEmpty)
        }
        .padding(.horizontal)
        .padding(.vertical, 8)
        .background(.bar)
    }

    private func send(_ text: String, source: ProactiveAgent.Source) {
        draft = ""
        Task { await agent.handle(text, source: source) }
    }
}

/// The one plan change the agent proposes, wherever it shows up: what changes (worked out against the
/// current day), then Ignore / Apply. Once decided it collapses to a one-line status (with Undo).
struct ProposalCard: View {
    @Environment(\.modelContext) private var modelContext
    let proposal: PlanProposal
    private var agent = ProactiveAgent.shared

    init(proposal: PlanProposal) { self.proposal = proposal }

    var body: some View {
        switch proposal.state {
        case .pending: pending
        case .applied:
            HStack {
                Label("Applied to your plan", systemImage: "checkmark")
                Spacer()
                if proposal.canUndo {
                    Button("Undo") { withAnimation { agent.undo(proposal) } }.fontWeight(.semibold)
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        case .undone: status("Undone")
        case .dismissed: status("Ignored")
        case .superseded: status("Replaced by a newer plan")
        }
    }

    private var pending: some View {
        let current = ActiveTrip.current(in: modelContext)?.days.first { $0.dayNumber == proposal.dayNumber }?.activities ?? []
        let changes = PlanChange.diff(from: current, to: proposal.blocks)
        return VStack(alignment: .leading, spacing: 10) {
            Eyebrow(text: "Suggested change · Day \(proposal.dayNumber)")
            if changes.isEmpty {
                Text("Same plan, nothing to change.").font(.caption).foregroundStyle(.secondary)
            }
            ForEach(changes) { change in
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: change.kind == .added ? "plus" : change.kind == .removed ? "xmark" : "arrow.right")
                        .foregroundStyle(change.kind == .removed ? .secondary : .primary)
                        .frame(width: 18)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(change.block.title)
                            .font(.subheadline.weight(.semibold))
                            .strikethrough(change.kind == .removed)
                            .foregroundStyle(change.kind == .removed ? .secondary : .primary)
                        Text(change.kind == .removed ? "Skipped" : "\(change.block.timeRange) · \(change.block.location)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            DecisionButtons(onAccept: { withAnimation { agent.apply(proposal) } },
                            onDecline: { withAnimation { agent.dismiss(proposal) } })
        }
        .inset()
    }

    private func status(_ text: String) -> some View {
        Text(text).font(.caption).foregroundStyle(.secondary)
    }
}
