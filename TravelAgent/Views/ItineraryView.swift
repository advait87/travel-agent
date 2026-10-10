import SwiftUI

/// A whole trip on one screen (used for trips other than the current one).
struct ItineraryView: View {
    let trip: Trip
    @State private var visibleDay: Int?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                VStack(alignment: .leading, spacing: 16) {
                    TripSummaryCard(trip: trip)
                    TripTipsCard(trip: trip)
                    LiveModeCard(trip: trip, dayNumber: visibleDay ?? trip.todayNumber)
                }
                .padding(.horizontal)
                DayCarousel(trip: trip, visibleDay: $visibleDay)
            }
            .padding(.vertical)
        }
        .background(Color(.systemGroupedBackground))
        .navigationTitle(trip.destination)
    }
}

/// Swipeable day cards; each one is a little narrower than the screen so the next day peeks in.
struct DayCarousel: View {
    let trip: Trip
    @Binding var visibleDay: Int?

    private var days: [ItineraryDay] { trip.days.sorted { $0.dayNumber < $1.dayNumber } }

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(alignment: .top, spacing: 12) {
                ForEach(days) { day in
                    DayCard(day: day, date: date(for: day), imageURL: trip.imageURL(for: day),
                            isToday: trip.phase == .active && day.dayNumber == trip.todayNumber)
                        .containerRelativeFrame(.horizontal) { width, _ in days.count > 1 ? width - 72 : width - 32 }
                        .id(day.dayNumber)
                }
            }
            .scrollTargetLayout()
        }
        .contentMargins(.horizontal, 16, for: .scrollContent)
        .scrollTargetBehavior(.viewAligned)
        .scrollPosition(id: $visibleDay)
        .onAppear { if visibleDay == nil { visibleDay = trip.todayNumber } }
    }

    private func date(for day: ItineraryDay) -> Date {
        Calendar.current.date(byAdding: .day, value: day.dayNumber - 1, to: trip.startDate) ?? trip.startDate
    }
}

/// Days, travelers, spend vs budget and which agent planned it.
struct TripSummaryCard: View {
    let trip: Trip

    private var totalCost: Int {
        trip.days.flatMap(\.activities).reduce(0) { $0 + $1.estimatedCost } * trip.travelers
    }

    var body: some View {
        VStack(spacing: 10) {
            HStack {
                stat("calendar", "\(trip.days.count) days")
                Divider()
                stat("person.2.fill", "\(trip.travelers)")
                Divider()
                stat("indianrupeesign.circle.fill", "₹\(totalCost.formatted()) / ₹\(trip.budget.formatted())")
            }
            Label("Planned by \(trip.plannedBy)", systemImage: "sparkles")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .card()
    }

    private func stat(_ icon: String, _ text: String) -> some View {
        VStack(spacing: 4) {
            Image(systemName: icon).foregroundStyle(.secondary)
            Text(text).font(.caption.weight(.medium))
        }
        .frame(maxWidth: .infinity)
    }
}

/// Destination tips from the agent, fetched once per trip.
struct TripTipsCard: View {
    let trip: Trip
    @State private var loadingTips = false
    @State private var tipsError: String?

    var body: some View {
        DisclosureGroup {
            VStack(alignment: .leading, spacing: 8) {
                if loadingTips {
                    HStack { ProgressView(); Text("Fetching tips…").foregroundStyle(.secondary) }
                } else if let tipsError {
                    Text(tipsError).font(.caption).foregroundStyle(.secondary)
                } else {
                    ForEach(trip.tips, id: \.self) { tip in
                        Label(tip, systemImage: "lightbulb")
                            .font(.subheadline)
                    }
                }
            }
            .padding(.top, 8)
        } label: {
            Label("Agent tips", systemImage: "lightbulb").font(.headline)
        }
        .card()
        .task(id: trip.id) { await loadTipsIfNeeded() }
    }

    private func loadTipsIfNeeded() async {
        guard trip.tips.isEmpty, !loadingTips else { return }
        loadingTips = true
        defer { loadingTips = false }
        do {
            trip.tips = try await AgentSettings.currentAgent()
                .travelTips(for: trip.destination, interests: trip.interests)
        } catch {
            tipsError = error.localizedDescription
        }
    }
}

// MARK: - Day card

/// One day as a card: generated cover image, then its time blocks in order.
struct DayCard: View {
    let day: ItineraryDay
    let date: Date
    let imageURL: URL?
    var isToday = false

    /// Extra blocks revealed by "Show earlier" / "Show later".
    @State private var extraBefore = 0
    @State private var extraAfter = 0

    private var blocks: [Activity] { day.activities.sorted { $0.start < $1.start } }

    /// Blocks inside the window: 30 min ago to 3 h ahead (today), or the first 3.5 h of other days.
    private var windowRange: Range<Int> {
        guard !blocks.isEmpty else { return 0..<0 }
        let anchor = isToday ? ProactiveAgent.minutesNow() : blocks[0].start + 30
        let from = anchor - 30, to = anchor + 180
        let inside = blocks.indices.filter { blocks[$0].end > from && blocks[$0].start < to }
        if let first = inside.first, let last = inside.last { return first..<(last + 1) }
        // Nothing in the window: show the next block, or the last one if the day is over.
        let next = blocks.firstIndex { $0.start >= to } ?? blocks.count - 1
        return next..<(next + 1)
    }

    private var visibleRange: Range<Int> {
        let window = windowRange
        return max(window.lowerBound - extraBefore, 0)..<min(window.upperBound + extraAfter, blocks.count)
    }

    var body: some View {
        let range = visibleRange
        VStack(alignment: .leading, spacing: 0) {
            cover
            VStack(alignment: .leading, spacing: 12) {
                Text("\(blocks.count) blocks · \(Activity.clock(blocks.first?.start ?? 0)) – \(Activity.clock(blocks.last?.end ?? 0))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if range.lowerBound > 0 {
                    showMore("Show earlier", count: range.lowerBound, icon: "chevron.up") { extraBefore += 3 }
                }
                ForEach(Array(range), id: \.self) { index in
                    let block = blocks[index]
                    if index > range.lowerBound, block.start - blocks[index - 1].end >= 30 {
                        FreeTimeGap(minutes: block.start - blocks[index - 1].end)
                    }
                    TimeBlockRow(block: block)
                }
                if range.upperBound < blocks.count {
                    showMore("Show later", count: blocks.count - range.upperBound, icon: "chevron.down") { extraAfter += 3 }
                }
            }
            .padding(12)
        }
        .background(Color(.secondarySystemGroupedBackground))
        .clipShape(.rect(cornerRadius: 24))
        .overlay(RoundedRectangle(cornerRadius: 24).strokeBorder(Theme.border))
    }

    private func showMore(_ title: String, count: Int, icon: String, action: @escaping () -> Void) -> some View {
        Button {
            withAnimation(.snappy) { action() }
        } label: {
            Label("\(title) · \(count) more", systemImage: icon)
                .font(.subheadline.weight(.semibold))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 8)
        }
        .buttonStyle(.bordered)
        .tint(.secondary)
    }

    private var cover: some View {
        ZStack(alignment: .bottomLeading) {
            // The image fills an overlay so its natural width can never widen the card.
            Color.clear
                .frame(maxWidth: .infinity)
                .frame(height: 200)
                .overlay {
                    AsyncImage(url: imageURL, transaction: Transaction(animation: .easeIn)) { phase in
                        switch phase {
                        case .success(let image):
                            image.resizable().scaledToFill()
                        case .failure:
                            placeholder(Image(systemName: "photo"))
                        default:
                            placeholder(ProgressView().tint(.white))
                        }
                    }
                }
                .clipped()

            LinearGradient(colors: [.clear, .black.opacity(0.7)], startPoint: .center, endPoint: .bottom)

            VStack(alignment: .leading, spacing: 2) {
                Text("DAY \(day.dayNumber) · \(date.formatted(.dateTime.weekday(.wide).day().month()).uppercased())")
                    .font(.caption.weight(.bold))
                    .opacity(0.9)
                Text(day.title)
                    .font(.title2.bold())
            }
            .foregroundStyle(.white)
            .padding(16)
        }
        .frame(height: 200)
    }

    private func placeholder(_ content: some View) -> some View {
        Color(.tertiarySystemFill)
            .overlay(content.font(.largeTitle).foregroundStyle(.white.opacity(0.8)))
    }
}

private struct TimeBlockRow: View {
    let block: Activity

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .trailing, spacing: 2) {
                Text(Activity.clock(block.start)).font(.subheadline.weight(.semibold).monospacedDigit())
                Text(Activity.clock(block.end)).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            }
            .frame(width: 50, alignment: .trailing)

            HStack(spacing: 0) {
                Rectangle()
                    .fill(block.category.color)
                    .frame(width: 5)
                VStack(alignment: .leading, spacing: 8) {
                    HStack(alignment: .firstTextBaseline) {
                        Label(block.title, systemImage: block.category.icon)
                            .font(.headline)
                            .labelStyle(BlockTitleLabelStyle(color: block.category.color))
                        Spacer(minLength: 4)
                        Text(block.durationText)
                            .font(.caption2.weight(.semibold))
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Color(.tertiarySystemFill), in: .capsule)
                    }
                    Text(block.detail)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    if !block.location.isEmpty {
                        Label(block.location, systemImage: "mappin.and.ellipse")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    HStack(spacing: 6) {
                        TagChip(text: block.category.rawValue.capitalized, color: block.category.color, filled: true)
                        ForEach(block.tags.filter { $0.lowercased() != block.category.rawValue }, id: \.self) {
                            TagChip(text: $0, color: block.category.color, filled: false)
                        }
                        Spacer(minLength: 0)
                        if block.estimatedCost > 0 {
                            Text("₹\(block.estimatedCost.formatted())")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                .padding(12)
                .frame(maxWidth: .infinity, minHeight: blockHeight, alignment: .topLeading)
            }
            .background(Color(.systemGroupedBackground))
            .clipShape(.rect(cornerRadius: 14))
        }
    }

    /// Longer blocks are taller so the day's shape is visible at a glance.
    private var blockHeight: CGFloat { min(CGFloat(block.durationMinutes) * 0.9, 220) }
}

private struct BlockTitleLabelStyle: LabelStyle {
    let color: Color
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 6) {
            configuration.icon.foregroundStyle(color).font(.subheadline)
            configuration.title
        }
    }
}

private struct TagChip: View {
    let text: String
    let color: Color
    let filled: Bool

    var body: some View {
        Text(text)
            .font(.caption2.weight(.semibold))
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(filled ? color.opacity(0.18) : .clear, in: .capsule)
            .overlay(Capsule().strokeBorder(color.opacity(filled ? 0 : 0.5)))
            .foregroundStyle(color)
    }
}

private struct FreeTimeGap: View {
    let minutes: Int

    var body: some View {
        HStack(spacing: 8) {
            Spacer().frame(width: 38)
            Image(systemName: "cup.and.saucer")
            Text("Free time · \(minutes / 60 > 0 ? "\(minutes / 60)h " : "")\(minutes % 60 > 0 ? "\(minutes % 60)m" : "")")
            Rectangle().fill(.quaternary).frame(height: 1)
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .padding(.leading, 12)
    }
}

extension Activity.Category {
    /// Categories are told apart by icon and tag, not colour, to keep the UI monochrome.
    var color: Color { .secondary }
}
