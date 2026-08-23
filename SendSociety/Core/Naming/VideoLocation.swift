import Foundation
import AVFoundation

/// ISO 6709, the string QuickTime stores a capture location in — e.g.
/// `+51.5074-000.1278+015.000/`.
///
/// Both directions live here because both paths need them and neither should
/// own the format: the import path parses what a camera wrote, and the
/// recording path has to write it itself, since `AVCaptureMovieFileOutput`
/// stores no location at all.
public enum ISO6709 {

    /// Parses the **decimal degrees** form, which is what iOS writes.
    ///
    /// The degrees-and-minutes form (`+5130.44-00007.66/`) is deliberately
    /// rejected rather than half-supported: it scans as a perfectly good decimal
    /// number and would silently place the gym in the North Sea. The bounds
    /// check in `Coordinate2D.isPlausible` is what catches it.
    public static func parse(_ string: String) -> Coordinate2D? {
        let scalars = string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !scalars.isEmpty else { return nil }

        var numbers: [Double] = []
        var current = ""
        for character in scalars {
            if character == "+" || character == "-" {
                if let value = Double(current) { numbers.append(value) }
                current = String(character)
            } else if character.isNumber || character == "." {
                current.append(character)
            } else {
                if let value = Double(current) { numbers.append(value) }
                current = ""
            }
        }
        if let value = Double(current) { numbers.append(value) }

        guard numbers.count >= 2 else { return nil }
        let coordinate = Coordinate2D(latitudeDegrees: numbers[0], longitudeDegrees: numbers[1])
        return coordinate.isPlausible ? coordinate : nil
    }

    public static func string(for coordinate: Coordinate2D, altitudeMeters: Double? = nil) -> String {
        let latitude = String(format: "%+09.5f", coordinate.latitudeDegrees)
        let longitude = String(format: "%+010.5f", coordinate.longitudeDegrees)
        let altitude = altitudeMeters.map { String(format: "%+.3f", $0) } ?? ""
        return "\(latitude)\(longitude)\(altitude)/"
    }
}

/// Reads the capture location out of a video file, if it has one.
///
/// **A missing coordinate is the normal case, not an error.** `PHPicker` strips
/// location from the file it exports, and `AVCaptureMovieFileOutput` never
/// wrote one in the first place unless the recording path attached it. This
/// returns nil far more often than it returns a coordinate, and every caller
/// has to treat that as ordinary.
public struct VideoLocationReader: Sendable {

    public init() {}

    public func coordinate(of url: URL) async -> Coordinate2D? {
        let asset = AVURLAsset(url: url)

        // Common metadata first: it is the format-independent view, and covers
        // files that came from a camera other than this one.
        if let items = try? await asset.load(.commonMetadata),
           let coordinate = await Self.coordinate(in: items, identifier: .commonIdentifierLocation) {
            return coordinate
        }

        guard let formats = try? await asset.load(.availableMetadataFormats) else { return nil }
        for format in formats {
            guard let items = try? await asset.loadMetadata(for: format) else { continue }
            if let coordinate = await Self.coordinate(in: items, identifier: .quickTimeMetadataLocationISO6709) {
                return coordinate
            }
            if let coordinate = await Self.coordinate(in: items, identifier: .commonIdentifierLocation) {
                return coordinate
            }
        }
        return nil
    }

    private static func coordinate(
        in items: [AVMetadataItem],
        identifier: AVMetadataIdentifier
    ) async -> Coordinate2D? {
        for item in AVMetadataItem.metadataItems(from: items, filteredByIdentifier: identifier) {
            guard let value = try? await item.load(.stringValue) else { continue }
            if let coordinate = ISO6709.parse(value) { return coordinate }
        }
        return nil
    }
}
