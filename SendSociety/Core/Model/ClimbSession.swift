import Foundation

/// Gravity measured in the phone's coordinate system when an in-app recording
/// actually begins. Unlike a Core Motion attitude quaternion, gravity remains
/// comparable after the capture screen has been dismissed and a new motion
/// session starts for the other climber.
public struct CaptureOrientation: Sendable, Codable, Hashable {
    public var gravityX: Double
    public var gravityY: Double
    public var gravityZ: Double

    public init(gravityX: Double, gravityY: Double, gravityZ: Double) {
        self.gravityX = gravityX
        self.gravityY = gravityY
        self.gravityZ = gravityZ
    }

    /// Sideways rotation of a portrait phone, with zero meaning a level
    /// horizon. Derived from gravity so it is stable across motion sessions.
    public var rollDegrees: Double {
        atan2(gravityX, -gravityY) * 180 / .pi
    }

    /// Up/down camera elevation, with zero meaning the rear camera points
    /// horizontally at the wall.
    public var pitchDegrees: Double {
        atan2(gravityZ, hypot(gravityX, gravityY)) * 180 / .pi
    }
}

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
    /// Where the clip was filmed, when the file carried it. **Usually nil** —
    /// `PHPicker` strips location and `AVCaptureMovieFileOutput` writes none.
    /// Used for session naming and nothing else; see `plan.md` §3.12.
    public var coordinate: Coordinate2D?
    /// Present only for clips recorded inside the app. Photos imports have no
    /// trustworthy motion sample, so they still provide a visual wall overlay
    /// but deliberately provide no pitch/roll target.
    public var captureOrientation: CaptureOrientation?

    public init(
        id: UUID = UUID(),
        filename: String,
        role: Role,
        recordedAt: Date = Date(),
        label: String = "",
        coordinate: Coordinate2D? = nil,
        captureOrientation: CaptureOrientation? = nil
    ) {
        self.id = id
        self.filename = filename
        self.role = role
        self.recordedAt = recordedAt
        self.label = label
        self.coordinate = coordinate
        self.captureOrientation = captureOrientation
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
    /// Where the session was filmed, taken from the reference clip. Nil is the
    /// common case indoors.
    public var coordinate: Coordinate2D?
    /// Why the session is called what it is. **`.user` is a lock**: a name a
    /// human typed is never replaced by a geocode or a date.
    public var nameSource: SessionNameSource

    public init(
        id: UUID = UUID(),
        createdAt: Date = Date(),
        name: String,
        reference: VideoRef? = nil,
        attempts: [VideoRef] = [],
        config: TuningConfig = TuningConfig(),
        manualRouteOverride: Route? = nil,
        poseSource: PoseSource = .vision,
        coordinate: Coordinate2D? = nil,
        nameSource: SessionNameSource = .date
    ) {
        self.id = id
        self.createdAt = createdAt
        self.name = name
        self.reference = reference
        self.attempts = attempts
        self.config = config
        self.manualRouteOverride = manualRouteOverride
        self.poseSource = poseSource
        self.coordinate = coordinate
        self.nameSource = nameSource
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
        coordinate = try c.decodeIfPresent(Coordinate2D.self, forKey: .coordinate)
        // Sessions written before naming existed decode as `.user`, not
        // `.date`. Their names were typed by hand or chosen by the old default,
        // and either way re-resolving one would rename a session the user
        // already knows by sight.
        nameSource = try c.decodeIfPresent(SessionNameSource.self, forKey: .nameSource) ?? .user
    }

    /// A name the user owns, and which nothing may overwrite.
    public var hasUserName: Bool { nameSource == .user }

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
