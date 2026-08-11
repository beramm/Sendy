import Foundation

/// A limb at rest on a hold. Detected from velocity and dwell, never from image
/// segmentation.
public struct Contact: Sendable, Codable, Hashable, Identifiable {
    public var id: UUID
    public var joint: JointName
    public var startFrame: Int
    public var endFrame: Int
    /// Wall space, median over the dwell.
    public var position: Point2D
    /// Mean joint confidence over the dwell — a contact built from badly
    /// tracked frames is worth less to route derivation.
    public var confidence: Double

    public init(
        id: UUID = UUID(),
        joint: JointName,
        startFrame: Int,
        endFrame: Int,
        position: Point2D,
        confidence: Double
    ) {
        self.id = id
        self.joint = joint
        self.startFrame = startFrame
        self.endFrame = endFrame
        self.position = position
        self.confidence = confidence
    }

    public var frameCount: Int { endFrame - startFrame + 1 }

    /// A total order with no ties, so results are reproducible across runs.
    /// Sorting on `startFrame` alone leaves ties to `Dictionary` iteration
    /// order, which Swift randomises per process.
    public static func deterministicOrder(_ a: Contact, _ b: Contact) -> Bool {
        if a.startFrame != b.startFrame { return a.startFrame < b.startFrame }
        if a.endFrame != b.endFrame { return a.endFrame < b.endFrame }
        if a.position.y != b.position.y { return a.position.y < b.position.y }
        if a.position.x != b.position.x { return a.position.x < b.position.x }
        return a.joint.rawValue < b.joint.rawValue
    }
    public var isHand: Bool { joint.isHand }
    public var isFoot: Bool { joint.isFoot }
    public func contains(frame: Int) -> Bool { frame >= startFrame && frame <= endFrame }
}

/// A cluster of contacts in wall space. Derived, never detected.
public struct Hold: Sendable, Codable, Hashable, Identifiable {
    public var id: Int
    public var position: Point2D
    /// Whichever limb touched this hold first. Used for ordering and display.
    /// **Not** what decides whether it is a hand hold — see `usedByHands`.
    public var firstUsedBy: JointName
    /// True when any hand ever used this hold, and likewise for feet. Both can
    /// be true, which is the normal case for a hold you stand on and later
    /// match hands on.
    ///
    /// This replaces reading `firstUsedBy` alone, which made a hold a *foot*
    /// hold forever if a foot happened to touch it first — on the real fixture
    /// that reduced 16 holds to 6 hand holds and collapsed the climb into 6
    /// moves.
    public var usedByHands: Bool
    public var usedByFeet: Bool
    public var ordinal: Int
    /// How many contacts formed this cluster. A one-contact hold is weak
    /// evidence; the UI shows it differently.
    public var contactCount: Int
    /// Frame index of the earliest contact in the cluster.
    public var firstFrame: Int
    /// Set by manual correction (task 1.10) so a hand-placed hold survives
    /// reprocessing with a different `TuningConfig`.
    public var isManual: Bool

    public init(
        id: Int,
        position: Point2D,
        firstUsedBy: JointName,
        ordinal: Int,
        contactCount: Int,
        firstFrame: Int,
        usedByHands: Bool? = nil,
        usedByFeet: Bool? = nil,
        isManual: Bool = false
    ) {
        self.id = id
        self.position = position
        self.firstUsedBy = firstUsedBy
        // Defaulting from `firstUsedBy` keeps hand-placed holds and older
        // sessions working; `RouteBuilder` always passes both explicitly.
        self.usedByHands = usedByHands ?? firstUsedBy.isHand
        self.usedByFeet = usedByFeet ?? firstUsedBy.isFoot
        self.ordinal = ordinal
        self.contactCount = contactCount
        self.firstFrame = firstFrame
        self.isManual = isManual
    }

    public var isHandHold: Bool { usedByHands }
    /// Used by both a hand and a foot at some point — worth drawing differently,
    /// and a sign the route is being read correctly rather than a clustering
    /// artefact.
    public var isMatchedHold: Bool { usedByHands && usedByFeet }
}

/// The ordered sequence of holds, derived from the reference climb only.
public struct Route: Sendable, Codable, Hashable {
    public var holds: [Hold]
    /// Sanity-check findings. A route outside 3...25 holds almost certainly
    /// means contact detection failed — surfaced, not thrown.
    public var warnings: [String]

    public init(holds: [Hold], warnings: [String] = []) {
        self.holds = holds
        self.warnings = warnings
    }

    public var handHolds: [Hold] { holds.filter(\.isHandHold) }
    public var footHolds: [Hold] { holds.filter(\.usedByFeet) }

    public func hold(id: Int) -> Hold? { holds.first { $0.id == id } }

    /// Nearest hold within `radius`, or nil. Used to match attempt contacts to
    /// the already-built route — never to rebuild it.
    public func nearestHold(to p: Point2D, within radius: Double) -> Hold? {
        var best: Hold?
        var bestD = radius
        for h in holds {
            let d = h.position.distance(to: p)
            if d <= bestD {
                bestD = d
                best = h
            }
        }
        return best
    }
}

/// The span between two successive **hand** hold acquisitions. The unit of
/// analysis for everything downstream.
public struct Section: Sendable, Codable, Hashable, Identifiable {
    public var index: Int
    public var fromHold: Hold
    public var toHold: Hold
    /// Frame indices into the reference pose sequence.
    public var referenceRange: Range<Int>
    /// Frame indices into the attempt pose sequence. Empty when the attempt
    /// never reached this section (truncated / fallen attempt).
    public var attemptRange: Range<Int>
    /// Set when the attempt's contacts in this span don't match the reference
    /// route — reported as a finding, never analysed as a technique difference.
    public var divergence: BetaDivergence?

    public init(
        index: Int,
        fromHold: Hold,
        toHold: Hold,
        referenceRange: Range<Int>,
        attemptRange: Range<Int>,
        divergence: BetaDivergence? = nil
    ) {
        self.index = index
        self.fromHold = fromHold
        self.toHold = toHold
        self.referenceRange = referenceRange
        self.attemptRange = attemptRange
        self.divergence = divergence
    }

    public var id: Int { index }
    public var attemptReached: Bool { !attemptRange.isEmpty }
    /// Human label. Sections are moves, so they are 1-based on screen.
    public var displayName: String { "Move \(index + 1)" }
}

/// Where the attempt did something structurally different, rather than the same
/// thing worse. Reported as a finding; metric comparison is suppressed.
public struct BetaDivergence: Sendable, Codable, Hashable {
    public enum Kind: String, Sendable, Codable {
        case offRouteHold      // used a hold the reference climber never touched
        case skippedHold       // never touched a hold the reference used
        case differentHandOrder
        case noContactsMatched
        /// Started this move and never finished it — came off, or the clip
        /// ended. **Not** a difference in beta, and must never be worded as
        /// one: telling a climber they "climbed it differently" when they fell
        /// is both wrong and discouraging.
        case truncated
    }

    public var kind: Kind
    public var detail: String
    /// Wall-space positions worth drawing, if any.
    public var positions: [Point2D]

    public init(kind: Kind, detail: String, positions: [Point2D] = []) {
        self.kind = kind
        self.detail = detail
        self.positions = positions
    }
}
