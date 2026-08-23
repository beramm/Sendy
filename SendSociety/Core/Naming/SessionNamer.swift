import Foundation

/// Turns a coordinate into a place name. **The only networked protocol in the
/// project**, and the reason it is a protocol at all: `Core` builds on macOS
/// and in tests, where there is no MapKit and must be no traffic.
///
/// Every failure is the same failure. Unreachable, denied, timed out, no
/// result, result with no usable name — all return nil, and the caller falls
/// through to the date. Distinguishing them would only produce error copy for
/// a case that is not an error.
public protocol ReverseGeocoder: Sendable {
    func placeName(for coordinate: Coordinate2D) async -> String?
}

/// Where a session's name came from. Recorded so the harness can say why a
/// session is called what it is, and so a user's own name is never clobbered.
public enum SessionNameSource: String, Sendable, Codable, Hashable {
    /// Matched a coordinate already in the `PlacemarkBook`. No network.
    case cache
    /// Reverse geocoded just now, and written to the book.
    case network
    /// No coordinate, no cache hit, or no network. **The expected outcome
    /// indoors**, not a failure.
    case date
    /// Typed or edited by hand. Outranks everything above.
    case user
}

public struct ResolvedSessionName: Sendable, Equatable {
    public var name: String
    public var source: SessionNameSource

    public init(name: String, source: SessionNameSource) {
        self.name = name
        self.source = source
    }
}

/// Resolution order is **cache, network, date** — never network first.
///
/// Cache-first is not an optimisation. Bouldering gyms are windowless
/// warehouses where GPS and cell both fail, so network-first would fail on most
/// visits to a gym whose name has been known since the first one. It also
/// produces the better name, because the book holds the user's correction and
/// the geocoder holds Apple's guess.
///
/// Pure by construction: no store, no I/O of its own, and the possibly-updated
/// book comes back out for the caller to persist. That makes the ordering
/// rule — the one thing here worth getting wrong — testable without a disk or
/// a network.
public struct SessionNamer: Sendable {

    public var geocoder: (any ReverseGeocoder)?
    public var matchRadiusMeters: Double

    public init(
        geocoder: (any ReverseGeocoder)? = nil,
        matchRadiusMeters: Double = PlacemarkBook.defaultMatchRadiusMeters
    ) {
        self.geocoder = geocoder
        self.matchRadiusMeters = matchRadiusMeters
    }

    public struct Resolution: Sendable {
        public var name: ResolvedSessionName
        /// Non-nil only when the book changed and needs writing back.
        public var updatedBook: PlacemarkBook?
    }

    public func resolve(
        coordinate: Coordinate2D?,
        capturedAt: Date,
        book: PlacemarkBook
    ) async -> Resolution {
        guard let coordinate, coordinate.isPlausible else {
            return Resolution(name: Self.dateName(capturedAt), updatedBook: nil)
        }

        if let hit = book.nearest(to: coordinate, within: matchRadiusMeters) {
            return Resolution(name: ResolvedSessionName(name: Self.placeName(hit.name), source: .cache), updatedBook: nil)
        }

        guard let geocoder, let resolved = await geocoder.placeName(for: coordinate) else {
            return Resolution(name: Self.dateName(capturedAt), updatedBook: nil)
        }

        var updated = book
        updated.remember(name: resolved, at: coordinate, confirmedByUser: false, within: matchRadiusMeters)
        return Resolution(
            name: ResolvedSessionName(name: Self.placeName(resolved), source: .network),
            updatedBook: updated
        )
    }

    // MARK: Formatting

    private static let placePrefix = "Climb at "

    public static func placeName(_ place: String) -> String {
        placePrefix + place
    }

    /// The gym out of a session name, so a rename re-seeds the book with
    /// "Rock Island" rather than "Climb at Rock Island".
    ///
    /// Without this, correcting a name once produces "Climb at Climb at Rock
    /// Island" on the next visit — the prefix is applied on the way out, so it
    /// has to be stripped on the way back in.
    public static func placeComponent(of name: String) -> String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix(placePrefix) else { return trimmed }
        return String(trimmed.dropFirst(placePrefix.count))
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// `Date.FormatStyle`, never a hardcoded `dd/MM/yyyy` — that reads as the
    /// 21st of August in most of the world and as invalid in the United States.
    /// The user's locale decides.
    ///
    /// "on", not "at", because a date is a when and a gym is a where.
    public static func dateName(_ date: Date) -> ResolvedSessionName {
        ResolvedSessionName(
            name: "Climb on \(date.formatted(date: .abbreviated, time: .omitted))",
            source: .date
        )
    }
}
