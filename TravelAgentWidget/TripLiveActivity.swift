import ActivityKit
import AppIntents
import SwiftUI
import WidgetKit

@main
struct TravelAgentWidgets: WidgetBundle {
    var body: some Widget {
        TravelAgentWidget()
        TripLiveActivity()
    }
}

/// Lock Screen / Dynamic Island card: where you should be, a self-updating countdown,
/// the agent's latest call, and buttons that wake the agent.
struct TripLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: TripActivityAttributes.self) { context in
            LockScreenView(attributes: context.attributes, state: context.state)
                .padding()
                .activityBackgroundTint(Color.black.opacity(0.75))
                .activitySystemActionForegroundColor(.white)
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    Label(context.state.blockTitle, systemImage: "mappin.circle.fill").font(.caption)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    Text(timerInterval: Date.now...max(context.state.blockEnd, .now), countsDown: true)
                        .font(.caption.monospacedDigit())
                        .frame(width: 60)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(context.state.headline).font(.caption)
                        ActionButtons()
                    }
                }
            } compactLeading: {
                Image(systemName: "airplane")
            } compactTrailing: {
                Text(timerInterval: Date.now...max(context.state.blockEnd, .now), countsDown: true)
                    .monospacedDigit()
                    .frame(width: 44)
            } minimal: {
                Image(systemName: "airplane")
            }
        }
    }
}

private struct LockScreenView: View {
    let attributes: TripActivityAttributes
    let state: TripActivityAttributes.ContentState

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label(attributes.destination, systemImage: "airplane")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(.white.opacity(0.7))
                Spacer()
                Text(state.headline)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(state.status == "behind" ? .orange : .green)
                    .lineLimit(1)
            }
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(state.blockTitle).font(.headline).foregroundStyle(.white).lineLimit(1)
                    if let next = state.nextTitle, let start = state.nextStart {
                        Text("Next: \(next) at \(start.formatted(date: .omitted, time: .shortened))")
                            .font(.caption)
                            .foregroundStyle(.white.opacity(0.7))
                            .lineLimit(1)
                    }
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 0) {
                    Text("Leave in").font(.caption2).foregroundStyle(.white.opacity(0.7))
                    Text(timerInterval: Date.now...max(state.blockEnd, .now), countsDown: true)
                        .font(.title2.bold().monospacedDigit())
                        .foregroundStyle(.white)
                        .multilineTextAlignment(.trailing)
                        .frame(width: 90, alignment: .trailing)
                }
            }
            ActionButtons()
        }
    }
}

private struct ActionButtons: View {
    var body: some View {
        HStack {
            Button(intent: ActivityDoneIntent()) {
                Label("Done", systemImage: "checkmark").frame(maxWidth: .infinity)
            }
            .tint(.green)
            Button(intent: ActivityStillHereIntent()) {
                Label("Still here", systemImage: "hourglass").frame(maxWidth: .infinity)
            }
            .tint(.orange)
        }
        .font(.caption.weight(.semibold))
        .buttonStyle(.borderedProminent)
    }
}
