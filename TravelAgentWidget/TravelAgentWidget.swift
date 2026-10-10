import WidgetKit
import SwiftUI

/// Home/Lock Screen widget: one tap opens the app straight into "tell your agent".
/// (Widgets can't record audio, so the tap hands off to the app's composer / dictation.)
struct TellAgentEntry: TimelineEntry {
    let date: Date
}

struct TellAgentProvider: TimelineProvider {
    func placeholder(in context: Context) -> TellAgentEntry { TellAgentEntry(date: .now) }
    func getSnapshot(in context: Context, completion: @escaping (TellAgentEntry) -> Void) {
        completion(TellAgentEntry(date: .now))
    }
    func getTimeline(in context: Context, completion: @escaping (Timeline<TellAgentEntry>) -> Void) {
        completion(Timeline(entries: [TellAgentEntry(date: .now)], policy: .never))
    }
}

struct TellAgentWidgetView: View {
    @Environment(\.widgetFamily) private var family

    var body: some View {
        switch family {
        case .accessoryCircular:
            ZStack {
                AccessoryWidgetBackground()
                Image(systemName: "mic.fill").font(.title2)
            }
        case .accessoryRectangular:
            Label("Tell your agent", systemImage: "mic.fill")
        default:
            VStack(alignment: .leading, spacing: 8) {
                Image(systemName: "mic.circle.fill")
                    .font(.system(size: 40))
                    .foregroundStyle(.white)
                Spacer()
                Text("Tell your agent")
                    .font(.headline)
                    .foregroundStyle(.white)
                Text("What are you up to?")
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.85))
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        }
    }
}

struct TravelAgentWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "TellAgent", provider: TellAgentProvider()) { _ in
            TellAgentWidgetView()
                .widgetURL(URL(string: "travelagent://tell"))
                .containerBackground(for: .widget) {
                    LinearGradient(colors: [.blue, .teal], startPoint: .topLeading, endPoint: .bottomTrailing)
                }
        }
        .configurationDisplayName("Tell your agent")
        .description("Tap to tell your travel agent what you're doing.")
        .supportedFamilies([.systemSmall, .accessoryCircular, .accessoryRectangular])
    }
}
