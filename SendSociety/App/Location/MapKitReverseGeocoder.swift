#if os(iOS)
import Foundation
import MapKit
import CoreLocation

/// The one place in the app that touches the network, and the only reason
/// `CLAUDE.md` has a network exception at all.
///
/// Everything about it is confined by design: it is reached from session naming
/// and nothing else, it sends a coordinate and uploads nothing, and every
/// failure is nil — the caller falls through to a date and the app is whole.
///
/// It lives in the app layer rather than `Core` so the pipeline cannot reach
/// it even by accident: `Core` has no MapKit, so a stage that tried to geocode
/// would not compile.
struct MapKitReverseGeocoder: ReverseGeocoder {

    func placeName(for coordinate: Coordinate2D) async -> String? {
        let location = CLLocation(
            latitude: coordinate.latitudeDegrees,
            longitude: coordinate.longitudeDegrees
        )
        guard let request = MKReverseGeocodingRequest(location: location) else { return nil }
        guard let items = try? await request.mapItems, !items.isEmpty else { return nil }

        // A point of interest first. A gym is a POI; the address-only result for
        // the same coordinate is the street, which names the session after a
        // road. Both beat nothing, and both are correctable — a rename re-seeds
        // the book, so the wrong one is wrong exactly once.
        if let poi = items.first(where: { $0.pointOfInterestCategory != nil })?.name,
           !poi.isEmpty {
            return poi
        }
        return items.compactMap(\.name).first { !$0.isEmpty }
    }
}
#endif
