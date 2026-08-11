import Foundation

/// One video belonging to a session. The file lives inside the session
/// directory so a session is a single self-contained folder.
public struct VideoRef: Sendable, Codable, Hashable, Identifiable {
    public enum Role: String, Sendable, Codable {
        /// The stronger climber's video. Not "pro", not "friend".
        case reference
        /// The user's own climb.
        case attempt
    }

    public var id: UUID
    /// Filename relative to the session directory.
    public var filename: String
    public var role: Role
    public var recordedAt: Date
    public var label: String

    public init(
        id: UUID = UUID(),
        filename: String,
        role: Role,
        recordedAt: Date = Date(),
        label: String = ""
    ) {
        self.id = id
        self.filename = filename
        self.role = role
        self.recordedAt = recordedAt
        self.label = label
    }
}

/// One reference climb and an array of attempts. Sessions are one-off — no
/// library, no cross-session persistence — but attempts are a collection from
/// day one, because retry after a fall is normal within a single session.
public struct ClimbSession: Sendable, Codable, Hashable, Identifiable {
    public var id: UUID
    public var createdAt: Date
    public var name: String
    public var reference: VideoRef?
    public var attempts: [VideoRef]
    /// The config this session was last processed with. Saved so reopening a
    /// session restores the tuning that produced what's on screen.
    public var config: TuningConfig
    /// Holds edited by hand in the correction UI, keyed by nothing — they
    /// replace derived holds wholesale when present.
    public var manualRouteOverride: Route?
    /// Which pose model this session is currently processed with. Changing it
    /// re-extracts, unlike every field in `TuningConfig`, which is why it lives
    /// here and not there.
    public var poseSource: PoseSource

    public init(
        id: UUID = UUID(),
        createdAt: Date = Date(),
        name: String,
        reference: VideoRef? = nil,
        attempts: [VideoRef] = [],
        config: TuningConfig = TuningConfig(),
        manualRouteOverride: Route? = nil,
        poseSource: PoseSource = .vision
    ) {
        self.id = id
        self.createdAt = createdAt
        self.name = name
        self.reference = reference
        self.attempts = attempts
        self.config = config
        self.manualRouteOverride = manualRouteOverride
        self.poseSource = poseSource
    }

    /// Sessions written before pose sources existed decode as Vision rather
    /// than failing — the harness keeps old sessions readable.
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        createdAt = try c.decode(Date.self, forKey: .createdAt)
        name = try c.decode(String.self, forKey: .name)
        reference = try c.decodeIfPresent(VideoRef.self, forKey: .reference)
        attempts = try c.decode([VideoRef].self, forKey: .attempts)
        config = try c.decode(TuningConfig.self, forKey: .config)
        manualRouteOverride = try c.decodeIfPresent(Route.self, forKey: .manualRouteOverride)
        poseSource = try c.decodeIfPresent(PoseSource.self, forKey: .poseSource) ?? .vision
    }

    public var isReadyToProcess: Bool { reference != nil && !attempts.isEmpty }

    public var allVideos: [VideoRef] {
        (reference.map { [$0] } ?? []) + attempts
    }

    public mutating func addAttempt(_ ref: VideoRef) {
        var r = ref
        r.role = .attempt
        if r.label.isEmpty { r.label = "Attempt \(attempts.count + 1)" }
        attempts.append(r)
    }
}
