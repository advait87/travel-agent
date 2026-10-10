import SwiftUI
import MapKit

/// Today's stops as numbered pins with driving routes between them, your live position,
/// and drive times between each stop.
struct DayMapView: View {
    let trip: Trip
    @State private var dayNumber: Int
    @State private var route = DayRoute()
    @State private var selected: UUID?
    @State private var camera: MapCameraPosition = .automatic

    init(trip: Trip) {
        self.trip = trip
        _dayNumber = State(initialValue: trip.todayNumber)
    }

    private var day: ItineraryDay? { trip.days.first { $0.dayNumber == dayNumber } }
    private var blocks: [Activity] { day?.activities.sorted { $0.start < $1.start } ?? [] }
    private var isToday: Bool { trip.phase == .active && dayNumber == trip.todayNumber }
    private var currentBlockID: UUID? {
        guard isToday else { return nil }
        let now = ProactiveAgent.minutesNow()
        return (blocks.first { $0.end > now })?.id
    }

    var body: some View {
        VStack(spacing: 0) {
            map
                .frame(maxHeight: .infinity)
            stopList
                .frame(height: 300)
        }
        .navigationTitle("Day \(dayNumber) map")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if trip.days.count > 1 {
                Picker("Day", selection: $dayNumber) {
                    ForEach(trip.days.map(\.dayNumber).sorted(), id: \.self) { Text("Day \($0)").tag($0) }
                }
                .pickerStyle(.menu)
            }
        }
        .task(id: dayNumber) {
            selected = nil
            camera = .automatic
            await route.load(blocks: blocks, destination: trip.destination)
            camera = .automatic
        }
    }

    private var map: some View {
        Map(position: $camera, selection: $selected) {
            UserAnnotation()
            ForEach(route.legs) { leg in
                MapPolyline(coordinates: leg.coordinates)
                    .stroke(Theme.accent.opacity(0.8), style: StrokeStyle(lineWidth: 4, lineCap: .round, lineJoin: .round))
            }
            ForEach(Array(route.stops.enumerated()), id: \.element.id) { index, stop in
                Marker(stop.block.title, monogram: Text("\(index + 1)"),
                       coordinate: stop.coordinate)
                    .tint(stop.id == currentBlockID ? Theme.accent : .gray)
                    .tag(stop.id)
            }
        }
        .mapControls {
            MapUserLocationButton()
            MapCompass()
        }
        .overlay(alignment: .top) {
            if route.loading {
                HStack { ProgressView(); Text("Finding places & routes…") }
                    .font(.caption)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(.regularMaterial, in: .capsule)
                    .padding(.top, 8)
            }
        }
        .onChange(of: selected) { _, id in
            guard let stop = route.stops.first(where: { $0.id == id }) else { return }
            withAnimation { camera = .camera(MapCamera(centerCoordinate: stop.coordinate, distance: 3000)) }
        }
    }

    private var stopList: some View {
        ScrollViewReader { proxy in
            List {
                ForEach(Array(blocks.enumerated()), id: \.element.id) { index, block in
                    if let leg = route.legs.first(where: { $0.toBlock == block.id }), let minutes = leg.minutes {
                        Label("\(minutes) min drive · \(leg.kilometres.map { String(format: "%.1f km", $0) } ?? "")",
                              systemImage: "car")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .listRowSeparator(.hidden)
                    }
                    Button {
                        selected = block.id
                    } label: {
                        row(block, number: index + 1)
                    }
                    .buttonStyle(.plain)
                    .listRowBackground(selected == block.id ? Theme.accent.opacity(0.12) : nil)
                    .id(block.id)
                }
            }
            .listStyle(.plain)
            .onChange(of: selected) { _, id in withAnimation { proxy.scrollTo(id, anchor: .center) } }
        }
    }

    private func row(_ block: Activity, number: Int) -> some View {
        HStack(spacing: 12) {
            Text("\(number)")
                .font(.caption.weight(.bold))
                .frame(width: 24, height: 24)
                .background(block.id == currentBlockID ? Theme.accent : Color(.tertiarySystemFill), in: .circle)
                .foregroundStyle(block.id == currentBlockID ? .black : .primary)
            VStack(alignment: .leading, spacing: 2) {
                Text(block.title).font(.subheadline.weight(.semibold))
                Text("\(block.timeRange) · \(block.location)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer()
            if !route.stops.contains(where: { $0.id == block.id }) && !route.loading {
                Image(systemName: "mappin.slash").font(.caption).foregroundStyle(.tertiary)
            }
        }
        .contentShape(.rect)
    }

}

extension MKPolyline {
    var coordinates: [CLLocationCoordinate2D] {
        var result = [CLLocationCoordinate2D](repeating: kCLLocationCoordinate2DInvalid, count: pointCount)
        getCoordinates(&result, range: NSRange(location: 0, length: pointCount))
        return result
    }
}

/// Geocoded stops for a day and the driving legs between them.
@MainActor @Observable
final class DayRoute {
    struct Stop: Identifiable {
        let block: Activity
        let coordinate: CLLocationCoordinate2D
        var id: UUID { block.id }
    }

    struct Leg: Identifiable {
        let id = UUID()
        let toBlock: UUID
        let coordinates: [CLLocationCoordinate2D]
        let minutes: Int?
        let kilometres: Double?
    }

    private(set) var stops: [Stop] = []
    private(set) var legs: [Leg] = []
    private(set) var loading = false
    private var loadedKey = ""

    func load(blocks: [Activity], destination: String) async {
        let key = blocks.map { "\($0.id)\($0.location)" }.joined()
        guard key != loadedKey else { return }
        loadedKey = key
        loading = true
        defer { loading = false }
        var newStops: [Stop] = []
        for block in blocks where !block.location.isEmpty {
            if let coordinate = await PlaceResolver.coordinate(for: block.location, in: destination) {
                newStops.append(Stop(block: block, coordinate: coordinate))
            }
        }
        stops = newStops
        var newLegs: [Leg] = []
        for (from, to) in zip(newStops, newStops.dropFirst()) {
            if let route = await PlaceResolver.route(from: from.coordinate, to: to.coordinate) {
                newLegs.append(Leg(toBlock: to.id, coordinates: route.polyline.coordinates,
                                   minutes: Int(route.expectedTravelTime / 60), kilometres: route.distance / 1000))
            } else {
                newLegs.append(Leg(toBlock: to.id, coordinates: [from.coordinate, to.coordinate], minutes: nil, kilometres: nil))
            }
        }
        legs = newLegs
    }
}

/// Small, non-interactive route map for Home. Tapping it opens the full map.
struct MiniDayMap: View {
    let trip: Trip
    @State private var route = DayRoute()

    private var blocks: [Activity] { trip.displayDay?.activities.sorted { $0.start < $1.start } ?? [] }
    private var currentBlockID: UUID? {
        guard trip.phase == .active else { return nil }
        let now = ProactiveAgent.minutesNow()
        return blocks.first { $0.end > now }?.id
    }

    var body: some View {
        Map(initialPosition: .automatic, interactionModes: []) {
            UserAnnotation()
            ForEach(route.legs) { leg in
                MapPolyline(coordinates: leg.coordinates)
                    .stroke(Theme.accent.opacity(0.8), style: StrokeStyle(lineWidth: 3, lineCap: .round, lineJoin: .round))
            }
            ForEach(Array(route.stops.enumerated()), id: \.element.id) { index, stop in
                Marker(stop.block.title, monogram: Text("\(index + 1)"), coordinate: stop.coordinate)
                    .tint(stop.id == currentBlockID ? Theme.accent : .gray)
            }
        }
        .id(route.stops.count)  // re-fit the camera once pins arrive
        .frame(height: 190)
        .clipShape(.rect(cornerRadius: Theme.radius))
        .overlay(RoundedRectangle(cornerRadius: Theme.radius).strokeBorder(Theme.border))
        .overlay(alignment: .topLeading) {
            if route.loading {
                HStack(spacing: 6) { ProgressView().controlSize(.mini); Text("Mapping today…") }
                    .font(.caption2)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(.regularMaterial, in: .capsule)
                    .padding(8)
            }
        }
        .overlay(alignment: .bottomTrailing) {
            Label("Open map", systemImage: "arrow.up.left.and.arrow.down.right")
                .font(.caption2.weight(.semibold))
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(.regularMaterial, in: .capsule)
                .padding(8)
        }
        .task(id: blocks.map(\.id)) { await route.load(blocks: blocks, destination: trip.destination) }
    }
}
