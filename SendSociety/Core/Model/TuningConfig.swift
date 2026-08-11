import Foundation

/// Every threshold in the pipeline, in one place.
///
/// Nothing in this project is hardcoded that hasn't been validated against real
/// footage, and nothing here has been. **These defaults are documented
/// guesses**, corrected on site through the debug tuning panel without a
/// rebuild. See `TuningConfig.fields` for the panel's data source — adding a
/// field there is what makes it adjustable.
public struct TuningConfig: Sendable, Codable, Hashable {

    // MARK: Pose

    /// Torso joints below this confidence are treated as untracked. The torso
    /// floor exists to reject whole-frame tracking failures, so it stays high.
    public var jointConfidenceFloor: Double = 0.30
    /// Separate, **lower** floor for wrists and ankles.
    ///
    /// Vision reports systematically lower confidence on extremities than on the
    /// torso — on the real fixtures the left wrist averages 0.27 against 0.70 for
    /// the hips. Judging both by one number discarded the left wrist in most
    /// frames of the attempt clip, which left contact detection with nothing to
    /// work from: 432 frames produced a single hand contact. The extremities are
    /// simultaneously the least confident joints and the only ones that touch
    /// holds, so they get their own floor.
    ///
    /// **Defaults to the same value as the torso floor, because the data said
    /// so.** Lowering it was the obvious move and it is wrong: swept on the
    /// reference clip, 0.30 gives 7 moves and every value from 0.25 down gives
    /// 6, while the attempt clip is completely flat at 1 hand acquisition. Kept
    /// low-confidence wrist positions are *noisy* positions, and noise raises
    /// velocity, which destroys the at-rest runs contact detection needs.
    ///
    /// The field stays because the concept is still right — the two joint groups
    /// serve different purposes, and a different pose model will have a
    /// different confidence distribution, at which point this becomes the knob
    /// that lets it be judged on its own scale rather than Vision's.
    public var extremityConfidenceFloor: Double = 0.30
    /// Frames whose torso joints fall below `jointConfidenceFloor` are dropped
    /// and interpolated across, up to this many consecutive frames.
    public var maxInterpolatedGapFrames: Int = 12
    /// Pose is resampled to this rate before anything else runs, so thresholds
    /// expressed in frames mean the same thing on 30fps and 60fps sources.
    public var workingFrameRate: Double = 30

    // MARK: Smoothing — 1€ filter

    /// Minimum cutoff frequency (Hz). Lower = smoother when still.
    public var smoothingMinCutoff: Double = 1.0
    /// Speed coefficient. Higher = less lag when moving fast.
    ///
    /// Much larger than the values quoted in the One-Euro paper because
    /// coordinates here are normalized `[0,1]` rather than pixels: joint speeds
    /// are order 0.1–1 per second, so a beta of 0.007 would never lift the
    /// cutoff at all. At 4.0 a joint moving at 0.3/s sees its cutoff more than
    /// double, which holds group delay to about two frames at 30fps —
    /// measured in `PoseSmootherTests`.
    public var smoothingBeta: Double = 4.0
    /// Cutoff for the derivative estimate (Hz).
    public var smoothingDerivativeCutoff: Double = 1.0

    // MARK: Contact detection

    /// **Body-lengths per second.** Below this a limb counts as at rest.
    /// Body-lengths, not wall-widths, so the threshold does not change when the
    /// tripod moves back — see `ClimbScale`.
    ///
    /// Default derived from the dev fixture: extremity speed there has a median
    /// of ~0.5 BL/s and a p25 of ~0.25 BL/s, with moving phases an order of
    /// magnitude above that.
    public var contactVelocityThreshold: Double = 0.30
    /// Consecutive frames at rest before a contact is emitted.
    public var contactDwellFrames: Int = 6
    /// **Body-lengths.** Contacts of the same joint closer than this, and within
    /// `contactMergeGapFrames`, are merged. Absorbs re-grips and shake-outs.
    ///
    /// **Must stay well below `holdClusterEpsilon`.** Merging works *inside* one
    /// hold; clustering decides when two contacts are *different* holds. When
    /// the two were equal (both 0.55, the original defaults) a hand leaving one
    /// hold and landing on a neighbour within the gap window was merged into a
    /// single contact — the move was destroyed before clustering could see it.
    /// On the real reference clip that took 44 raw contacts down to 24 and
    /// collapsed a 26-second climb into 6 moves. `ContactDetector` warns when
    /// this invariant is broken.
    public var contactMergeRadius: Double = 0.20
    /// Frames a hand may be off a hold and still count as the same contact.
    /// At the 30fps working rate the old default of 20 was two-thirds of a
    /// second — long enough for a whole hand-foot-hand sequence to fit inside.
    public var contactMergeGapFrames: Int = 8
    /// Mean joint confidence a contact must clear to be trusted.
    public var contactConfidenceFloor: Double = 0.30

    // MARK: Route derivation — DBSCAN

    /// Cluster radius in **body-lengths**. Holds a climber uses as distinct sit
    /// at least this far apart.
    ///
    /// Swept against the real fixture: the derived move count is flat at 7–8
    /// across 0.30–0.55 and drops to 6 by 0.70, so this sits in the stable band
    /// rather than at its edge. Lower also resists DBSCAN chaining, which
    /// matters more now that merging no longer thins the contacts first —
    /// `holdClusterMinPoints` is 1, so every contact is a core point and dense
    /// runs of them will otherwise link into one cluster.
    public var holdClusterEpsilon: Double = 0.40
    /// Minimum contacts to seed a cluster. 1 keeps single-touch holds, which
    /// matters because the reference climber touches some holds exactly once.
    public var holdClusterMinPoints: Int = 1
    /// Sanity band. Outside it, route derivation reports a warning rather than
    /// proceeding silently.
    public var minPlausibleHolds: Int = 3
    public var maxPlausibleHolds: Int = 25

    // MARK: Attempt matching

    /// Nearest-neighbour radius, in **body-lengths of the reference climber**,
    /// when matching an attempt contact to a route hold. Beyond it the contact
    /// is an off-route hold.
    public var routeMatchRadius: Double = 0.80

    /// How far **below** the highest hand hold a later hand acquisition has to
    /// sit, in body-lengths, before the climb is treated as already topped out.
    ///
    /// A boulder finishes on the top hold. Hands that go somewhere lower
    /// afterwards are the climber coming down, reaching past, or letting go —
    /// not a move on the route. On `gym-testing/test1` the reference tops out
    /// on hold 18 at frame 1139 and then touches hold 19, three quarters of a
    /// body-length lower, at frame 1446. That produced a twelfth "move" after
    /// the send, which the attempt could never reach and which therefore
    /// reported as the end of their go.
    ///
    /// Set to a large value to disable, which is what a traverse or a route
    /// with a genuinely low finish needs.
    public var topOutDropMargin: Double = 0.50

    /// How far above the lowest observed foot position, in body-lengths, still
    /// counts as **standing on the ground** rather than on a foothold.
    ///
    /// The climb starts when both feet have left the floor. Before that the
    /// climber is arranging themselves on the start holds, and hand movements
    /// there are setup, not moves. On `gym-testing/test1` the reference takes
    /// two hand holds at the same height while its right foot is still down —
    /// matching onto the start holds — which produced a first "move" that was
    /// nothing of the kind.
    ///
    /// Measured on that pair: ground contacts sit at y 0.066–0.087 and the
    /// first real foothold at 0.159, against a torso of ~0.10. Half a
    /// body-length separates them comfortably.
    public var groundMargin: Double = 0.50

    // MARK: Depth (foreshortening)

    /// Percentile of observed segment length taken as `L_true`.
    public var segmentLengthPercentile: Double = 0.95
    /// z is emitted as nil below this confidence. Foreshortening has a flat
    /// derivative near the wall plane, so a low-confidence z is not a small
    /// error — it is an arbitrary one.
    public var depthConfidenceFloor: Double = 0.25
    /// Exponential smoothing factor on the hip z track, 0...1. Higher = less
    /// smoothing.
    public var depthSmoothingAlpha: Double = 0.35

    // MARK: Metrics

    /// Elbow angle above which an arm counts as straight.
    public var straightArmDegrees: Double = 150
    /// Load below this fraction of bodyweight means the contact isn't bearing.
    public var loadedContactFraction: Double = 0.08
    /// IDW exponent for load distribution.
    public var loadIDWExponent: Double = 2.0
    /// A delta smaller than this many normalized units is noise, not a finding.
    public var deltaSignificanceThreshold: Double = 0.08

    // MARK: Fall detection

    /// Downward COM acceleration, in body-lengths/s², treated as free fall.
    public var fallAccelThreshold: Double = 12.0
    /// How long free fall must persist.
    public var fallSustainSeconds: Double = 0.30
    /// A re-contact within this window means it was a dyno, not a fall.
    public var fallRecontactWindowSeconds: Double = 0.60
    /// Margin, in body-lengths, by which the COM must leave the base of support
    /// to count as out.
    public var bosMarginBodyLengths: Double = 0.05
    /// Downward ankle velocity spike (wall-widths/s) that marks a foot slip.
    public var footSlipVelocityThreshold: Double = 0.45
    /// Proximate-cause window before release.
    public var proximateWindowSeconds: Double = 2.0
    /// How much more lateral than vertical the COM's exit from the base of
    /// support must be to read as a barn door rather than a straight drop.
    public var barnDoorLateralRatio: Double = 1.5
    /// Fraction of frames in the proximate window that must be rising for a hip
    /// peel to count as monotonic rather than noise.
    public var hipPeelMonotonicFraction: Double = 0.6
    /// Total hip-z rise, in body-lengths, below which a peel is not worth
    /// reporting.
    public var hipPeelMinimumRise: Double = 0.05

    // MARK: Fatigue trends
    //
    // Slopes are per move across the whole climb, never within one move. All
    // four are correlational and are reported as hypotheses.

    /// Straight-arm ratio decline per move that counts as bent-arm accumulation.
    public var bentArmSlopeThreshold: Double = -0.02
    /// Load-asymmetry growth per move.
    public var loadAsymmetrySlopeThreshold: Double = 0.01
    /// Reach-margin growth per move, in body-lengths.
    public var reachMarginSlopeThreshold: Double = 0.02
    /// Dwell-ratio growth per move.
    public var dwellRatioSlopeThreshold: Double = 0.10
    /// Arm-load growth per move. A better pump proxy than bent arms alone,
    /// because a climber can keep their arms straight and still be taking
    /// everything through them.
    public var armLoadSlopeThreshold: Double = 0.02

    // MARK: Magnitude bands
    //
    // How big a difference has to be before the copy calls it "clearly" or
    // "a lot" rather than "slightly". Multiples of
    // `deltaSignificanceThreshold`, so raising significance raises all three
    // together.

    /// Above `deltaSignificanceThreshold × this`, a difference reads as clear
    /// rather than slight.
    public var clearMagnitudeMultiple: Double = 2.0
    /// Above `deltaSignificanceThreshold × this`, a difference reads as large.
    public var largeMagnitudeMultiple: Double = 4.0

    // MARK: Coverage gates
    //
    // A metric computed from a handful of frames in a move is not a
    // measurement. These say how much of a move must have tracked.

    /// Fraction of a move's frames needing a depth estimate.
    public var depthCoverageFloor: Double = 0.10
    /// Fraction of a move's frames needing a COM.
    public var comCoverageFloor: Double = 0.30
    /// Confidence discount applied to a joint position that was interpolated
    /// across a tracking gap rather than observed.
    public var interpolatedConfidenceFactor: Double = 0.80

    // MARK: Registration

    /// Mean reprojection residual (wall-widths) above which two clips are not
    /// comparable and the user is told to re-record.
    public var registrationResidualLimit: Double = 0.035

    public init() {}

    // MARK: Debug panel metadata

    /// Describes one adjustable field so the tuning panel can be generated
    /// rather than hand-written. Every threshold above appears here.
    public struct Field: Sendable, Identifiable {
        public enum Kind: Sendable {
            case double(WritableKeyPath<TuningConfig, Double> & Sendable, range: ClosedRange<Double>, step: Double)
            case int(WritableKeyPath<TuningConfig, Int> & Sendable, range: ClosedRange<Int>)
        }
        public var id: String { label }
        public var group: String
        public var label: String
        public var help: String
        public var kind: Kind
    }


    // MARK: Lenient decoding

    /// Every field falls back to its default when absent.
    ///
    /// Swift's synthesised `Decodable` throws on a missing key, which meant
    /// that **adding a threshold orphaned every session already saved**.
    /// `ClimbSession` decodes `config` hard and `SessionStore.loadAll` wraps
    /// the whole thing in `try?`, so the failure was silent: the session did
    /// not error, it vanished from the list. Losing a gym recording because a
    /// slider was added afterwards is the worst outcome this harness has.
    ///
    /// Written out field by field rather than left to synthesis, because the
    /// synthesised version is exactly the thing that was wrong. A test
    /// (`olderConfigDecodes`) strips the newest keys and asserts the defaults
    /// come back.
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = TuningConfig()
        jointConfidenceFloor = try c.decodeIfPresent(Double.self, forKey: .jointConfidenceFloor) ?? d.jointConfidenceFloor
        extremityConfidenceFloor = try c.decodeIfPresent(Double.self, forKey: .extremityConfidenceFloor) ?? d.extremityConfidenceFloor
        maxInterpolatedGapFrames = try c.decodeIfPresent(Int.self, forKey: .maxInterpolatedGapFrames) ?? d.maxInterpolatedGapFrames
        workingFrameRate = try c.decodeIfPresent(Double.self, forKey: .workingFrameRate) ?? d.workingFrameRate
        smoothingMinCutoff = try c.decodeIfPresent(Double.self, forKey: .smoothingMinCutoff) ?? d.smoothingMinCutoff
        smoothingBeta = try c.decodeIfPresent(Double.self, forKey: .smoothingBeta) ?? d.smoothingBeta
        smoothingDerivativeCutoff = try c.decodeIfPresent(Double.self, forKey: .smoothingDerivativeCutoff) ?? d.smoothingDerivativeCutoff
        contactVelocityThreshold = try c.decodeIfPresent(Double.self, forKey: .contactVelocityThreshold) ?? d.contactVelocityThreshold
        contactDwellFrames = try c.decodeIfPresent(Int.self, forKey: .contactDwellFrames) ?? d.contactDwellFrames
        contactMergeRadius = try c.decodeIfPresent(Double.self, forKey: .contactMergeRadius) ?? d.contactMergeRadius
        contactMergeGapFrames = try c.decodeIfPresent(Int.self, forKey: .contactMergeGapFrames) ?? d.contactMergeGapFrames
        contactConfidenceFloor = try c.decodeIfPresent(Double.self, forKey: .contactConfidenceFloor) ?? d.contactConfidenceFloor
        holdClusterEpsilon = try c.decodeIfPresent(Double.self, forKey: .holdClusterEpsilon) ?? d.holdClusterEpsilon
        holdClusterMinPoints = try c.decodeIfPresent(Int.self, forKey: .holdClusterMinPoints) ?? d.holdClusterMinPoints
        minPlausibleHolds = try c.decodeIfPresent(Int.self, forKey: .minPlausibleHolds) ?? d.minPlausibleHolds
        maxPlausibleHolds = try c.decodeIfPresent(Int.self, forKey: .maxPlausibleHolds) ?? d.maxPlausibleHolds
        routeMatchRadius = try c.decodeIfPresent(Double.self, forKey: .routeMatchRadius) ?? d.routeMatchRadius
        topOutDropMargin = try c.decodeIfPresent(Double.self, forKey: .topOutDropMargin) ?? d.topOutDropMargin
        groundMargin = try c.decodeIfPresent(Double.self, forKey: .groundMargin) ?? d.groundMargin
        segmentLengthPercentile = try c.decodeIfPresent(Double.self, forKey: .segmentLengthPercentile) ?? d.segmentLengthPercentile
        depthConfidenceFloor = try c.decodeIfPresent(Double.self, forKey: .depthConfidenceFloor) ?? d.depthConfidenceFloor
        depthSmoothingAlpha = try c.decodeIfPresent(Double.self, forKey: .depthSmoothingAlpha) ?? d.depthSmoothingAlpha
        straightArmDegrees = try c.decodeIfPresent(Double.self, forKey: .straightArmDegrees) ?? d.straightArmDegrees
        loadedContactFraction = try c.decodeIfPresent(Double.self, forKey: .loadedContactFraction) ?? d.loadedContactFraction
        loadIDWExponent = try c.decodeIfPresent(Double.self, forKey: .loadIDWExponent) ?? d.loadIDWExponent
        deltaSignificanceThreshold = try c.decodeIfPresent(Double.self, forKey: .deltaSignificanceThreshold) ?? d.deltaSignificanceThreshold
        fallAccelThreshold = try c.decodeIfPresent(Double.self, forKey: .fallAccelThreshold) ?? d.fallAccelThreshold
        fallSustainSeconds = try c.decodeIfPresent(Double.self, forKey: .fallSustainSeconds) ?? d.fallSustainSeconds
        fallRecontactWindowSeconds = try c.decodeIfPresent(Double.self, forKey: .fallRecontactWindowSeconds) ?? d.fallRecontactWindowSeconds
        bosMarginBodyLengths = try c.decodeIfPresent(Double.self, forKey: .bosMarginBodyLengths) ?? d.bosMarginBodyLengths
        footSlipVelocityThreshold = try c.decodeIfPresent(Double.self, forKey: .footSlipVelocityThreshold) ?? d.footSlipVelocityThreshold
        proximateWindowSeconds = try c.decodeIfPresent(Double.self, forKey: .proximateWindowSeconds) ?? d.proximateWindowSeconds
        barnDoorLateralRatio = try c.decodeIfPresent(Double.self, forKey: .barnDoorLateralRatio) ?? d.barnDoorLateralRatio
        hipPeelMonotonicFraction = try c.decodeIfPresent(Double.self, forKey: .hipPeelMonotonicFraction) ?? d.hipPeelMonotonicFraction
        hipPeelMinimumRise = try c.decodeIfPresent(Double.self, forKey: .hipPeelMinimumRise) ?? d.hipPeelMinimumRise
        bentArmSlopeThreshold = try c.decodeIfPresent(Double.self, forKey: .bentArmSlopeThreshold) ?? d.bentArmSlopeThreshold
        loadAsymmetrySlopeThreshold = try c.decodeIfPresent(Double.self, forKey: .loadAsymmetrySlopeThreshold) ?? d.loadAsymmetrySlopeThreshold
        reachMarginSlopeThreshold = try c.decodeIfPresent(Double.self, forKey: .reachMarginSlopeThreshold) ?? d.reachMarginSlopeThreshold
        dwellRatioSlopeThreshold = try c.decodeIfPresent(Double.self, forKey: .dwellRatioSlopeThreshold) ?? d.dwellRatioSlopeThreshold
        armLoadSlopeThreshold = try c.decodeIfPresent(Double.self, forKey: .armLoadSlopeThreshold) ?? d.armLoadSlopeThreshold
        clearMagnitudeMultiple = try c.decodeIfPresent(Double.self, forKey: .clearMagnitudeMultiple) ?? d.clearMagnitudeMultiple
        largeMagnitudeMultiple = try c.decodeIfPresent(Double.self, forKey: .largeMagnitudeMultiple) ?? d.largeMagnitudeMultiple
        depthCoverageFloor = try c.decodeIfPresent(Double.self, forKey: .depthCoverageFloor) ?? d.depthCoverageFloor
        comCoverageFloor = try c.decodeIfPresent(Double.self, forKey: .comCoverageFloor) ?? d.comCoverageFloor
        interpolatedConfidenceFactor = try c.decodeIfPresent(Double.self, forKey: .interpolatedConfidenceFactor) ?? d.interpolatedConfidenceFactor
        registrationResidualLimit = try c.decodeIfPresent(Double.self, forKey: .registrationResidualLimit) ?? d.registrationResidualLimit
    }

    public static let fields: [Field] = [
        .init(group: "Pose", label: "Torso confidence floor", help: "Torso joints below this are untracked", kind: .double(\.jointConfidenceFloor, range: 0 ... 1, step: 0.01)),
        .init(group: "Pose", label: "Extremity confidence floor", help: "Wrists and ankles — Vision scores these lower", kind: .double(\.extremityConfidenceFloor, range: 0 ... 1, step: 0.01)),
        .init(group: "Pose", label: "Max interpolated gap (frames)", help: "Longest run of dropped frames bridged", kind: .int(\.maxInterpolatedGapFrames, range: 0 ... 60)),
        .init(group: "Pose", label: "Working frame rate", help: "Pose resampled to this before thresholds apply", kind: .double(\.workingFrameRate, range: 10 ... 60, step: 1)),

        .init(group: "Smoothing", label: "Min cutoff (Hz)", help: "Lower = smoother when still", kind: .double(\.smoothingMinCutoff, range: 0.1 ... 10, step: 0.1)),
        .init(group: "Smoothing", label: "Beta", help: "Higher = less lag on fast movement", kind: .double(\.smoothingBeta, range: 0 ... 20, step: 0.1)),
        .init(group: "Smoothing", label: "Derivative cutoff (Hz)", help: "Cutoff on the speed estimate", kind: .double(\.smoothingDerivativeCutoff, range: 0.1 ... 10, step: 0.1)),

        .init(group: "Contacts", label: "Velocity threshold (BL/s)", help: "Body-lengths/sec below which a limb is at rest", kind: .double(\.contactVelocityThreshold, range: 0.01 ... 3, step: 0.01)),
        .init(group: "Contacts", label: "Dwell frames", help: "Consecutive at-rest frames required", kind: .int(\.contactDwellFrames, range: 1 ... 40)),
        .init(group: "Contacts", label: "Merge radius (BL)", help: "Absorbs re-grips and shake-outs", kind: .double(\.contactMergeRadius, range: 0 ... 1.5, step: 0.02)),
        .init(group: "Contacts", label: "Merge gap (frames)", help: "Max frames between merged contacts", kind: .int(\.contactMergeGapFrames, range: 0 ... 60)),
        .init(group: "Contacts", label: "Confidence floor", help: "Mean joint confidence a contact must clear", kind: .double(\.contactConfidenceFloor, range: 0 ... 1, step: 0.01)),

        .init(group: "Route", label: "Cluster epsilon (BL)", help: "DBSCAN radius in body-lengths", kind: .double(\.holdClusterEpsilon, range: 0.05 ... 3, step: 0.05)),
        .init(group: "Route", label: "Cluster min points", help: "Contacts needed to seed a hold", kind: .int(\.holdClusterMinPoints, range: 1 ... 5)),
        .init(group: "Route", label: "Min plausible holds", help: "Below this, warn", kind: .int(\.minPlausibleHolds, range: 1 ... 10)),
        .init(group: "Route", label: "Max plausible holds", help: "Above this, warn", kind: .int(\.maxPlausibleHolds, range: 5 ... 60)),
        .init(group: "Route", label: "Attempt match radius (BL)", help: "Beyond this an attempt contact is off-route", kind: .double(\.routeMatchRadius, range: 0.05 ... 3, step: 0.05)),
        .init(group: "Route", label: "Top-out drop margin (BL)", help: "Hands going this far below the top hold end the climb; raise to disable", kind: .double(\.topOutDropMargin, range: 0.1 ... 10, step: 0.1)),
        .init(group: "Route", label: "Ground margin (BL)", help: "Feet within this of the lowest point are on the floor; the climb starts once both leave it", kind: .double(\.groundMargin, range: 0 ... 3, step: 0.05)),

        .init(group: "Depth", label: "Segment length percentile", help: "Percentile taken as true limb length", kind: .double(\.segmentLengthPercentile, range: 0.5 ... 1, step: 0.01)),
        .init(group: "Depth", label: "Confidence floor", help: "z suppressed below this", kind: .double(\.depthConfidenceFloor, range: 0 ... 1, step: 0.01)),
        .init(group: "Depth", label: "Smoothing alpha", help: "Higher = less smoothing on hip z", kind: .double(\.depthSmoothingAlpha, range: 0.01 ... 1, step: 0.01)),

        .init(group: "Metrics", label: "Straight-arm degrees", help: "Elbow angle counted as straight", kind: .double(\.straightArmDegrees, range: 90 ... 180, step: 1)),
        .init(group: "Metrics", label: "Loaded contact fraction", help: "%BW below which a contact isn't bearing", kind: .double(\.loadedContactFraction, range: 0 ... 0.5, step: 0.01)),
        .init(group: "Metrics", label: "Load IDW exponent", help: "Distance falloff for load sharing", kind: .double(\.loadIDWExponent, range: 0.5 ... 4, step: 0.1)),
        .init(group: "Metrics", label: "Delta significance", help: "Smaller deltas are noise, not findings", kind: .double(\.deltaSignificanceThreshold, range: 0 ... 1, step: 0.01)),

        .init(group: "Falls", label: "Accel threshold", help: "Body-lengths/s² treated as free fall", kind: .double(\.fallAccelThreshold, range: 1 ... 40, step: 0.5)),
        .init(group: "Falls", label: "Sustain seconds", help: "How long free fall must persist", kind: .double(\.fallSustainSeconds, range: 0.05 ... 2, step: 0.05)),
        .init(group: "Falls", label: "Re-contact window", help: "Re-contact inside this means dyno, not fall", kind: .double(\.fallRecontactWindowSeconds, range: 0.1 ... 3, step: 0.05)),
        .init(group: "Falls", label: "BOS margin", help: "How far COM must leave the polygon", kind: .double(\.bosMarginBodyLengths, range: 0 ... 0.5, step: 0.01)),
        .init(group: "Falls", label: "Foot slip velocity", help: "Downward ankle spike marking a slip", kind: .double(\.footSlipVelocityThreshold, range: 0.05 ... 2, step: 0.05)),
        .init(group: "Falls", label: "Proximate window (s)", help: "How far back the proximate cause looks", kind: .double(\.proximateWindowSeconds, range: 0.5 ... 6, step: 0.5)),
        .init(group: "Falls", label: "Barn-door lateral ratio", help: "Sideways vs downward COM exit", kind: .double(\.barnDoorLateralRatio, range: 1 ... 5, step: 0.1)),
        .init(group: "Falls", label: "Hip-peel monotonic fraction", help: "Share of frames that must be rising", kind: .double(\.hipPeelMonotonicFraction, range: 0.3 ... 1, step: 0.05)),
        .init(group: "Falls", label: "Hip-peel minimum rise (BL)", help: "Smaller rises are not reported", kind: .double(\.hipPeelMinimumRise, range: 0 ... 0.5, step: 0.01)),

        .init(group: "Fatigue trends", label: "Bent-arm slope", help: "Straight-arm decline per move", kind: .double(\.bentArmSlopeThreshold, range: -0.2 ... 0, step: 0.005)),
        .init(group: "Fatigue trends", label: "Load-asymmetry slope", help: "Imbalance growth per move", kind: .double(\.loadAsymmetrySlopeThreshold, range: 0 ... 0.2, step: 0.005)),
        .init(group: "Fatigue trends", label: "Reach-margin slope", help: "Extension growth per move", kind: .double(\.reachMarginSlopeThreshold, range: 0 ... 0.2, step: 0.005)),
        .init(group: "Fatigue trends", label: "Dwell-ratio slope", help: "Slowdown per move", kind: .double(\.dwellRatioSlopeThreshold, range: 0 ... 1, step: 0.05)),
        .init(group: "Fatigue trends", label: "Arm-load slope", help: "Weight moving onto the arms per move", kind: .double(\.armLoadSlopeThreshold, range: 0 ... 0.2, step: 0.005)),

        .init(group: "Wording", label: "\"Clearly\" multiple", help: "Above significance × this, a difference reads as clear", kind: .double(\.clearMagnitudeMultiple, range: 1 ... 6, step: 0.25)),
        .init(group: "Wording", label: "\"A lot\" multiple", help: "Above significance × this, a difference reads as large", kind: .double(\.largeMagnitudeMultiple, range: 1 ... 12, step: 0.25)),

        .init(group: "Coverage", label: "Depth coverage floor", help: "Share of a move needing a depth estimate", kind: .double(\.depthCoverageFloor, range: 0 ... 1, step: 0.05)),
        .init(group: "Coverage", label: "COM coverage floor", help: "Share of a move needing a COM", kind: .double(\.comCoverageFloor, range: 0 ... 1, step: 0.05)),
        .init(group: "Coverage", label: "Interpolated confidence factor", help: "Discount on a bridged joint position", kind: .double(\.interpolatedConfidenceFactor, range: 0 ... 1, step: 0.05)),

        .init(group: "Registration", label: "Residual limit", help: "Above this, clips aren't comparable", kind: .double(\.registrationResidualLimit, range: 0.001 ... 0.2, step: 0.002))
    ]

    public subscript(double field: WritableKeyPath<TuningConfig, Double>) -> Double {
        get { self[keyPath: field] }
        set { self[keyPath: field] = newValue }
    }
}

/// A named, saved `TuningConfig`, so a promising set survives a gym session.
public struct NamedTuningConfig: Sendable, Codable, Hashable, Identifiable {
    public var id: UUID
    public var name: String
    public var config: TuningConfig
    public var savedAt: Date

    public init(id: UUID = UUID(), name: String, config: TuningConfig, savedAt: Date = Date()) {
        self.id = id
        self.name = name
        self.config = config
        self.savedAt = savedAt
    }
}
