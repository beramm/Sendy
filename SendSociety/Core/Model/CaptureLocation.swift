import Foundation

/// Where a clip was filmed, in degrees.
///
/// Deliberately **not** `CLLocationCoordinate2D`. That type is not `Codable`,
/// and `Core` builds on macOS for the CLI and the test target, where pulling in
/// CoreLocation buys nothing. Conversion happens at the app boundary, in the
/// one place that talks to the hardware.
///
/// This is the only geographic quantity in the project, and it exists for
/// **session naming only**. It is not wall space, it never reaches
/// `MetricsEngine`, and no pipeline stage reads it. See `CLAUDE.md`, "The one
/// network exception".
public struct Coordinate2D: Sendable, Codable, Hashable {
    public var latitudeDegrees: Double
    public var longitudeDegrees: Double

    public init(latitudeDegrees: Double, longitudeDegrees: Double) {
        self.latitudeDegrees = latitudeDegrees
        self.longitudeDegrees = longitudeDegrees
    }

    /// A coordinate outside these bounds is a parse failure, not a place. The
    /// check earns its keep against ISO 6709's degrees-and-minutes form, which
    /// scans as a valid decimal number and lands in the sea.
    public var isPlausible: Bool {
        latitudeDegrees.isFinite && longitudeDegrees.isFinite
            && abs(latitudeDegrees) <= 90 && abs(longitudeDegrees) <= 180
    }

    /// Haversine, on a spherical Earth. Accurate to a few metres over the
    /// hundreds of metres this is used across, which is three orders of
    /// magnitude better than the GPS fix it compares.
    public func distanceMeters(to other: Coordinate2D) -> Double {
        let earthRadiusMeters = 6_371_000.0
        let lat1 = latitudeDegrees * .pi / 180
        let lat2 = other.latitudeDegrees * .pi / 180
        let dLat = lat2 - lat1
        let dLon = (other.longitudeDegrees - longitudeDegrees) * .pi / 180
        let a = sin(dLat / 2) * sin(dLat / 2)
            + cos(lat1) * cos(lat2) * sin(dLon / 2) * sin(dLon / 2)
        return 2 * earthRadiusMeters * atan2(sqrt(a), sqrt(max(0, 1 - a)))
    }
}
