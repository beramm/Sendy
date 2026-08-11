import Foundation

/// One climber's span between two successive **hand** hold acquisitions.
///
/// Named `MoveSpan` rather than `Move` only because `Section` still carries
/// that role in the older single-level path; the two coexist while the rename
/// in task 9.1 is outstanding. This is the per-climber unit — it knows nothing
/// about the other climb.
public struct MoveSpan: Sendable, Codable, Hashable {
    public var index: Int
    public var fromHoldID: Int
    public var toHoldID: Int
    public var frameRange: Range<Int>

    public init(index: Int, fromHoldID: Int, toHoldID: Int, frameRange: Range<Int>) {
        self.index = index
        self.fromHoldID = fromHoldID
        self.toHoldID = toHoldID
        self.frameRange = frameRange
    }
}

/// One climber's whole ordered line through the route.
///
/// The reference has one, each attempt has its own, and they are computed
/// independently — a beta takes no argument referring to the other climb. That
/// independence is the point: it is what stops move *n* of one climber being
/// silently assumed to mean the same thing as move *n* of the other.
public struct Beta: Sendable, Codable, Hashable {
    public var moves: [MoveSpan]

    public init(moves: [MoveSpan]) { self.moves = moves }

    /// Ordered hand acquisitions as (frame, holdID), which is what the sequence
    /// builder anchors on.
    public var acquisitions: [(frame: Int, holdID: Int)] {
        guard let first = moves.first else { return [] }
        return [(first.frameRange.lowerBound, first.fromHoldID)]
            + moves.map { ($0.frameRange.upperBound - 1, $0.toHoldID) }
    }
}

/// The span between two successive **anchors**, where an anchor is a route hold
/// that a hand of the reference *and* a hand of the attempt both contacted.
///
/// **The unit of comparison.** A sequence holds at least one move from each
/// climber and the counts are free to differ — that difference is the finding,
/// not a problem. The reference reaching straight through where the attempt
/// steps a foot, matches a hand, then reaches, is one sequence of one move
/// against three.
///
/// Called `ClimbSequence` and never `Sequence`: the latter is a Swift standard
/// library protocol and `PoseSequence` already exists. The same collision cost
/// a day when `Observation` was chosen in task 6.4.
public struct ClimbSequence: Sendable, Codable, Hashable, Identifiable {
    public var index: Int
    public var fromAnchorID: Int
    public var toAnchorID: Int
    /// Frame spans, one per climber. Neither is derived from the other.
    public var referenceRange: Range<Int>
    public var attemptRange: Range<Int>
    /// Indices into each climber's own beta.
    public var referenceMoves: Range<Int>
    public var attemptMoves: Range<Int>

    public init(
        index: Int,
        fromAnchorID: Int,
        toAnchorID: Int,
        referenceRange: Range<Int>,
        attemptRange: Range<Int>,
        referenceMoves: Range<Int>,
        attemptMoves: Range<Int>
    ) {
        self.index = index
        self.fromAnchorID = fromAnchorID
        self.toAnchorID = toAnchorID
        self.referenceRange = referenceRange
        self.attemptRange = attemptRange
        self.referenceMoves = referenceMoves
        self.attemptMoves = attemptMoves
    }

    public var id: Int { index }
    public var displayName: String { "Sequence \(index + 1)" }
    public var attemptReached: Bool { !attemptRange.isEmpty }

    /// Attempt moves minus reference moves. The headline structural finding:
    /// positive means the attempt needed more moves to cross the same span.
    public var moveCountDelta: Int { attemptMoves.count - referenceMoves.count }

    /// Attempt frames per reference frame.
    ///
    /// Worth carrying because it is what decides whether locked playback can
    /// work. A sequence at 7:1 cannot be shown move-for-move at all, and the
    /// scrubber needs to know that rather than warping and hoping.
    public var frameRatio: Double {
        referenceRange.isEmpty ? 0 : Double(attemptRange.count) / Double(referenceRange.count)
    }
}

public struct SequenceResult: Sendable, Codable {
    public var sequences: [ClimbSequence]
    public var referenceBeta: Beta
    public var attemptBeta: Beta
    /// Route hand holds both climbers used, in reference order.
    public var anchorIDs: [Int]
    /// Anchors ÷ reference hand holds. The number that says whether this whole
    /// layer is useful on a given pair, or whether the two climbers shared so
    /// few holds that everything collapses into one sequence.
    public var anchorDensity: Double
    public var warnings: [String]

    public init(
        sequences: [ClimbSequence], referenceBeta: Beta, attemptBeta: Beta,
        anchorIDs: [Int], anchorDensity: Double, warnings: [String]
    ) {
        self.sequences = sequences
        self.referenceBeta = referenceBeta
        self.attemptBeta = attemptBeta
        self.anchorIDs = anchorIDs
        self.anchorDensity = anchorDensity
        self.warnings = warnings
    }
}
