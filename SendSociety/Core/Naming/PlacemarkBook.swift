import Foundation

/// Coordinate → gym name, learned once and reused for ever.
///
/// **This is what keeps the network exception narrow.** Without it, naming a
/// session would mean a lookup per session; with it, a gym is resolved once and
/// every later visit is offline. It is also why the offline path is not a
/// degraded one: after the first successful resolve, the cache *is* the normal
/// path and the network is dead code until the user climbs somewhere new.
///
/// Entries are matched by proximity, not equality. Two fixes at the same gym
/// differ by tens of metres — GPS indoors is a rumour — so an exact-match cache
/// would never hit.
public struct PlacemarkBook: Sendable, Codable, Hashable {

    /// A gym radius, not a GPS radius. Sized so every fix taken around one
    /// building collapses to one entry, and so two genuinely different gyms do
    /// not — which in practice they never are, at 200 m apart.
    ///
    /// Not a `TuningConfig` field, unlike every other guessed number in the
    /// project. `TuningConfig` holds thresholds that change what the pipeline
    /// *measures*, and are therefore worth re-running a session against; this
    /// one changes a label. Its correction mechanism is better than a slider
    /// anyway: rename the session, and `remember` re-seeds the entry.
    public static let defaultMatchRadiusMeters: Double = 200

    public struct Entry: Sendable, Codable, Hashable, Identifiable {
        public var id: UUID
        public var coordinate: Coordinate2D
        public var name: String
        /// True once a human has typed or corrected this name. A geocode result
        /// never overwrites one — Apple's label for a bouldering gym in a light
        /// industrial unit is routinely the street or the previous tenant.
        public var confirmedByUser: Bool
        public var updatedAt: Date

        public init(
            id: UUID = UUID(),
            coordinate: Coordinate2D,
            name: String,
            confirmedByUser: Bool = false,
            updatedAt: Date = Date()
        ) {
            self.id = id
            self.coordinate = coordinate
            self.name = name
            self.confirmedByUser = confirmedByUser
            self.updatedAt = updatedAt
        }
    }

    public var entries: [Entry]

    public init(entries: [Entry] = []) {
        self.entries = entries
    }

    /// The closest entry within the radius, or nil. Closest rather than first,
    /// so an overlapping pair resolves deterministically rather than by
    /// insertion order.
    public func nearest(to coordinate: Coordinate2D, within meters: Double = defaultMatchRadiusMeters) -> Entry? {
        entries
            .map { ($0, $0.coordinate.distanceMeters(to: coordinate)) }
            .filter { $0.1 <= meters }
            .min { $0.1 < $1.1 }?
            .0
    }

    /// Records a name against a coordinate, folding into a nearby entry rather
    /// than accumulating one per visit.
    ///
    /// A user-confirmed entry is only ever replaced by another user edit, so a
    /// later geocode of the same building cannot undo a correction.
    @discardableResult
    public mutating func remember(
        name: String,
        at coordinate: Coordinate2D,
        confirmedByUser: Bool,
        within meters: Double = defaultMatchRadiusMeters,
        now: Date = Date()
    ) -> Entry? {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, coordinate.isPlausible else { return nil }

        if let index = indexOfNearest(to: coordinate, within: meters) {
            if entries[index].confirmedByUser && !confirmedByUser { return entries[index] }
            entries[index].name = trimmed
            entries[index].confirmedByUser = entries[index].confirmedByUser || confirmedByUser
            entries[index].updatedAt = now
            return entries[index]
        }

        let entry = Entry(coordinate: coordinate, name: trimmed, confirmedByUser: confirmedByUser, updatedAt: now)
        entries.append(entry)
        return entry
    }

    private func indexOfNearest(to coordinate: Coordinate2D, within meters: Double) -> Int? {
        entries.indices
            .map { ($0, entries[$0].coordinate.distanceMeters(to: coordinate)) }
            .filter { $0.1 <= meters }
            .min { $0.1 < $1.1 }?
            .0
    }
}
