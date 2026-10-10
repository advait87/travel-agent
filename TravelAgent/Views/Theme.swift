import SwiftUI

/// One accent on a monochrome base; every surface uses the same card or inset style.
enum Theme {
    static let accent = Color(red: 0.98, green: 0.65, blue: 0.25)
    static let radius: CGFloat = 16
    static let border = Color.primary.opacity(0.08)
}

extension View {
    /// Top-level surface: card background, hairline border, consistent padding.
    func card() -> some View {
        padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(.secondarySystemGroupedBackground), in: .rect(cornerRadius: Theme.radius))
            .overlay(RoundedRectangle(cornerRadius: Theme.radius).strokeBorder(Theme.border))
    }

    /// Nested group inside a card (suggestions, banners, lists).
    func inset() -> some View {
        padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(.tertiarySystemGroupedBackground), in: .rect(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Theme.border))
    }
}

/// Small uppercase label used for section headers and statuses.
struct Eyebrow: View {
    let text: String
    var highlighted = false

    var body: some View {
        Text(text.uppercased())
            .font(.caption2.weight(.bold))
            .tracking(0.6)
            .foregroundStyle(highlighted ? Theme.accent : .secondary)
    }
}

/// One row of an agent plan change: neutral icon, struck-through title when skipped.
struct DecisionRow: View {
    let decision: ReplanSuggestion.Decision
    var showsReason = true

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: icon)
                .foregroundStyle(decision.action == .skip ? .secondary : .primary)
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(decision.title)
                        .font(.subheadline.weight(.semibold))
                        .strikethrough(decision.action == .skip)
                        .foregroundStyle(decision.action == .skip ? .secondary : .primary)
                    Text(decision.action.rawValue.capitalized)
                        .font(.caption2.weight(.semibold))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color(.quaternarySystemFill), in: .capsule)
                        .foregroundStyle(.secondary)
                }
                Text(detailText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var detailText: String {
        let times = "\(Activity.clock(decision.start))–\(Activity.clock(decision.end))"
        guard showsReason else { return decision.action == .skip ? "Skipped" : times }
        return decision.action == .skip ? decision.reason : "\(times) · \(decision.reason)"
    }

    private var icon: String {
        switch decision.action {
        case .skip: "xmark"
        case .extend: "plus"
        case .shorten: "minus"
        case .shift: "arrow.right"
        case .keep: "checkmark"
        }
    }
}

/// Accept / decline pair used for every agent proposal: equal widths, full row, only "accept" highlighted.
struct DecisionButtons: View {
    var accept = "Apply"
    var decline = "Ignore"
    let onAccept: () -> Void
    let onDecline: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Button(action: onDecline) {
                Text(decline).frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .tint(.secondary)
            Button(action: onAccept) {
                Label(accept, systemImage: "checkmark").frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .tint(Theme.accent)
            .foregroundStyle(.black)
        }
        .font(.headline)
        .controlSize(.large)
    }
}
