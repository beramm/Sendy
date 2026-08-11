import Foundation

/// Groups both climbers' moves into sequences bounded by holds they both used.
///
/// The only stage that sees both climbs. `MoveSegmenter` runs once per climber
/// and takes no argument referring to the other; everything cross-climb starts
/// here, which is what keeps the correspondence explicit instead of assumed.
public struct SequenceBuilder: Sendable {

    public init() {}

    public func build(
        route: Route,
        referenceAcquisitions: [(frame: Int, holdID: Int)],
        attemptAcquisitions: [(frame: Int, holdID: Int)],
        referenceFrameCount: Int,
        attemptFrameCount: Int
    ) -> SequenceResult {
        var warnings: [String] = []

        let referenceBeta = beta(from: referenceAcquisitions, frameCount: referenceFrameCount)
        let attemptBeta = beta(from: attemptAcquisitions, frameCount: attemptFrameCount)

        // First arrival per hold, per climber. A hold taken twice anchors on the
        // first visit; the second is a move inside a sequence.
        var referenceArrival: [Int: Int] = [:]
        for a in referenceAcquisitions where referenceArrival[a.holdID] == nil { referenceArrival[a.holdID] = a.frame }
        var attemptArrival: [Int: Int] = [:]
        for a in attemptAcquisitions where attemptArrival[a.holdID] == nil { attemptArrival[a.holdID] = a.frame }

        // A hold both climbers took **with a hand**. Either hand, and it need
        // not be the same hand on both sides. Feet never anchor: a foot on a
        // hold says nothing about where the climber's hands are, and the whole
        // point of an anchor is that both bodies are demonstrably in the same
        // place.
        let sharedInReferenceOrder = referenceAcquisitions
            .map(\.holdID)
            .reduce(into: [Int]()) { out, id in
                if attemptArrival[id] != nil, !out.contains(id) { out.append(id) }
            }

        // **Anchors must increase in both climbers' orders.**
        //
        // An attempt can take shared holds out of the reference's sequence — a
        // reversal, a downclimb, a hold taken early and re-taken. Anchoring on those
        // produces a sequence that runs backwards in one pane, which is exactly
        // the defect this layer exists to remove. Keeping the longest
        // increasing subsequence by attempt arrival time keeps the largest set
        // of anchors that are consistent for both, and demotes the rest to
        // ordinary moves inside a sequence.
        let anchorIDs = longestIncreasingByAttemptTime(sharedInReferenceOrder, arrival: attemptArrival)

        let referenceHandHolds = Set(referenceAcquisitions.map(\.holdID)).count
        let density = referenceHandHolds > 0 ? Double(anchorIDs.count) / Double(referenceHandHolds) : 0

        if anchorIDs.count < sharedInReferenceOrder.count {
            let demoted = sharedInReferenceOrder.count - anchorIDs.count
            warnings.append(
                "\(demoted) hold\(demoted == 1 ? "" : "s") both climbers used could not anchor a sequence, "
                + "because the attempt took them in a different order. They are still compared inside the sequences around them."
            )
        }
        guard anchorIDs.count >= 2 else {
            warnings.append(
                "The two climbers share fewer than two hand holds in a consistent order, so the climb is one "
                + "sequence. Structure is still reported; per-metric comparison is not meaningful here."
            )
            let whole = ClimbSequence(
                index: 0,
                fromAnchorID: anchorIDs.first ?? -1,
                toAnchorID: anchorIDs.first ?? -1,
                referenceRange: 0 ..< max(referenceFrameCount, 1),
                attemptRange: 0 ..< max(attemptFrameCount, 1),
                referenceMoves: 0 ..< referenceBeta.moves.count,
                attemptMoves: 0 ..< attemptBeta.moves.count
            )
            return SequenceResult(
                sequences: [whole], referenceBeta: referenceBeta, attemptBeta: attemptBeta,
                anchorIDs: anchorIDs, anchorDensity: density, warnings: warnings
            )
        }

        var sequences: [ClimbSequence] = []
        for i in 0 ..< (anchorIDs.count - 1) {
            let fromID = anchorIDs[i]
            let toID = anchorIDs[i + 1]
            guard let refStart = referenceArrival[fromID], let refEnd = referenceArrival[toID],
                  let attStart = attemptArrival[fromID], let attEnd = attemptArrival[toID]
            else { continue }

            // Inclusive of the arrival frame: a sequence ends with the anchor
            // taken, so consecutive sequences share their boundary frame.
            sequences.append(ClimbSequence(
                index: sequences.count,
                fromAnchorID: fromID,
                toAnchorID: toID,
                referenceRange: refStart ..< min(refEnd + 1, max(referenceFrameCount, refStart + 1)),
                attemptRange: attStart ..< min(attEnd + 1, max(attemptFrameCount, attStart + 1)),
                referenceMoves: moveRange(in: referenceBeta, from: fromID, to: toID),
                attemptMoves: moveRange(in: attemptBeta, from: fromID, to: toID)
            ))
        }
        return SequenceResult(
            sequences: sequences, referenceBeta: referenceBeta, attemptBeta: attemptBeta,
            anchorIDs: anchorIDs, anchorDensity: density, warnings: warnings
        )
    }

    // MARK: - Pieces

    func beta(from acquisitions: [(frame: Int, holdID: Int)], frameCount: Int) -> Beta {
        guard acquisitions.count >= 2 else { return Beta(moves: []) }
        var moves: [MoveSpan] = []
        for i in 0 ..< (acquisitions.count - 1) {
            let from = acquisitions[i]
            let to = acquisitions[i + 1]
            moves.append(MoveSpan(
                index: moves.count,
                fromHoldID: from.holdID,
                toHoldID: to.holdID,
                frameRange: from.frame ..< min(to.frame + 1, max(frameCount, from.frame + 1))
            ))
        }
        return Beta(moves: moves)
    }

    /// Which of a climber's own moves fall between two anchors.
    func moveRange(in beta: Beta, from: Int, to: Int) -> Range<Int> {
        guard let start = beta.moves.firstIndex(where: { $0.fromHoldID == from }) else { return 0 ..< 0 }
        guard let end = beta.moves[start...].firstIndex(where: { $0.toHoldID == to }) else {
            return start ..< beta.moves.count
        }
        return start ..< (end + 1)
    }

    /// Longest subsequence whose attempt arrival times increase.
    ///
    /// Plain O(n²) dynamic programming: anchor counts here are single digits,
    /// and the patience-sorting version would be harder to read for no gain
    /// at this size. Ties are impossible — arrivals are distinct frames.
    func longestIncreasingByAttemptTime(_ ids: [Int], arrival: [Int: Int]) -> [Int] {
        guard !ids.isEmpty else { return [] }
        let times = ids.map { arrival[$0] ?? Int.max }
        var best = [Int](repeating: 1, count: ids.count)
        var previous = [Int](repeating: -1, count: ids.count)
        for i in ids.indices {
            for j in 0 ..< i where times[j] < times[i] && best[j] + 1 > best[i] {
                best[i] = best[j] + 1
                previous[i] = j
            }
        }
        guard var cursor = best.indices.max(by: { best[$0] < best[$1] }) else { return [] }
        var chain: [Int] = []
        while cursor >= 0 {
            chain.append(ids[cursor])
            cursor = previous[cursor]
        }
        return chain.reversed()
    }
}
