import MapKit

/// Turns itinerary place names into coordinates (Apple Maps search near the destination),
/// and finds driving routes between stops. Results are cached for the session.
@MainActor
enum PlaceResolver {
    private static var coordinates: [String: CLLocationCoordinate2D] = [:]
    private static var regions: [String: MKCoordinateRegion] = [:]

    static func coordinate(for place: String, in destination: String) async -> CLLocationCoordinate2D? {
        let key = "\(place)|\(destination)".lowercased()
        if let cached = coordinates[key] { return cached }

        let search = MKLocalSearch.Request()
        search.naturalLanguageQuery = place
        if let region = await region(for: destination) { search.region = region }
        var found = try? await MKLocalSearch(request: search).start().mapItems.first?.placemark.coordinate
        if found == nil {
            found = try? await CLGeocoder().geocodeAddressString("\(place), \(destination)").first?.location?.coordinate
        }
        if let found { coordinates[key] = found }
        return found
    }

    private static func region(for destination: String) async -> MKCoordinateRegion? {
        let key = destination.lowercased()
        if let cached = regions[key] { return cached }
        guard let center = try? await CLGeocoder().geocodeAddressString(destination).first?.location?.coordinate
        else { return nil }
        let region = MKCoordinateRegion(center: center, latitudinalMeters: 60_000, longitudinalMeters: 60_000)
        regions[key] = region
        return region
    }

    static func route(from: CLLocationCoordinate2D, to: CLLocationCoordinate2D) async -> MKRoute? {
        let request = MKDirections.Request()
        request.source = MKMapItem(placemark: MKPlacemark(coordinate: from))
        request.destination = MKMapItem(placemark: MKPlacemark(coordinate: to))
        request.transportType = .automobile
        return try? await MKDirections(request: request).calculate().routes.first
    }
}
