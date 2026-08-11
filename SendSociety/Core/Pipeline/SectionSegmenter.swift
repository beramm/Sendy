import Foundation

public struct SegmentationResult: Sendable, Codable {
    public var sections: [Section]
    public var warnings: [String]
    /// The reference hand acquisitions these sections were built from, **after**
    /// the ground-start and top-out trimming.
    ///
    /// Exposed because anything building a parallel structure — the sequence
    /// layer — has to share this exact list or its move indices silently drift
    /// out of step with `sections`. Passing the raw acquisitions instead put
    /// them one apart, so a sequence looked up the wrong move's analysis and
    /// the last one found none at all.
    public var referenceAcquisitions: [Acquisition]

    /// A named pair, because `(frame: Int, holdID: Int)` is not `Codable`.
    public struct Acquisition: Sendable, Codable, Hashable {
        public var frame: Int
        public var holdID: Int
        public init(frame: Int, holdID: Int) {
            self.frame = frame
            self.holdID = holdID
        }
    }

    public init(sections: [Section], warnings: [String], referenceAcquisitions: [Acquisition] = []) {
        self.sections = sections
        self.warnings = warnings
        self.referenceAcquisitions = referenceAcquisitions
    }
}

/// Splits the climb into sections at **hand** hold acquisitions. Feet move
/// within sections; hands define them, which is how climbers describe routes.
public struct SectionSegmenter: Sendable {

    public init() {}

    public func segment(
        route: Route,
        reference: MatchResult,
        attempt: MatchResult,
        referenceFrameCount: Int,
        attemptFrameCount: Int,
        scale: ClimbScale? = nil,
        config: TuningConfig = TuningConfig()
    ) -> SegmentationResult {
        // The climb ends at the last contact, not at the end of the file.
        // Clips have two seconds of head and tail by protocol, and letting a
        // section run to the last decoded frame drags the climber walking away
        // into the metrics.
        let attemptEnd = min(
            attemptFrameCount,
            (attempt.matched.map(\.contact.endFrame).max()).map { $0 + 1 } ?? attemptFrameCount
        )
        var warnings: [String] = []
        var refAcquisitions = reference.handAcquisitions

        // **The climb starts once both feet are off the floor.**
        //
        // Before that the climber is arranging themselves on the start holds,
        // and hands moving between them is setup, not climbing. On
        // `gym-testing/test1` the reference takes two hand holds at the same
        // height while its right foot is still down — a match onto the start
        // holds — which became "move 1" and compared against nothing
        // meaningful in the attempt.
        //
        // The floor is read from the data rather than assumed: the lowest foot
        // contact in the climb, plus `groundMargin`. On that pair ground
        // contacts sit at y 0.066–0.087 and the first foothold at 0.159, so the
        // separation is about a body-length.
        //
        // Ground contacts after the high point are ignored, because those are a
        // climber landing rather than starting.
        if let scale, config.groundMargin > 0 {
            let footContacts = reference.matched.map(\.contact).filter(\.isFoot)
            let topFrame = refAcquisitions
                .compactMap { a in (route.hold(id: a.holdID)?.position.y).map { (a.frame, $0) } }
                .max { $0.1 < $1.1 }?.0 ?? Int.max
            if let floor = footContacts.map(\.position.y).min() {
                let line = floor + config.groundMargin * scale.torsoLength
                let onGround = footContacts.filter { $0.position.y <= line && $0.endFrame <= topFrame }
                if let leftFloor = onGround.map(\.endFrame).max() {
                    let climbStart = leftFloor + 1
                    // Everything up to that frame is the starting position. Keep
                    // the last hold taken there as the first move's origin.
                    if let originIndex = refAcquisitions.lastIndex(where: { $0.frame <= climbStart }), originIndex > 0 {
                        refAcquisitions = Array(refAcquisitions.dropFirst(originIndex))
                        warnings.append(
                            "The climb is measured from frame \(climbStart), where both feet left the floor. "
                            + "\(originIndex) earlier hand hold\(originIndex == 1 ? "" : "s") were treated as the starting position."
                        )
                    }
                }
            }
        }

        // **A boulder ends at the top hold.**
        //
        // Hands that go somewhere lower afterwards are the climber coming down,
        // reaching past, or letting go — not a move on the route. Keeping them
        // invents moves the attempt can never reach, which then report as the
        // end of the attempt's go.
        //
        // Only trailing acquisitions are dropped, and only those clearly below
        // the high point, so a finishing match at roughly the same height
        // survives. Disabled by raising `topOutDropMargin`, which is what a
        // traverse or a genuinely low finish needs.
        if let scale, refAcquisitions.count >= 2 {
            let heights = refAcquisitions.map { route.hold(id: $0.holdID)?.position.y ?? 0 }
            if let peak = heights.max(), let topIndex = heights.firstIndex(of: peak) {
                let margin = config.topOutDropMargin * scale.torsoLength
                var cut = refAcquisitions.count
                while cut - 1 > topIndex, heights[cut - 1] < peak - margin {
                    cut -= 1
                }
                if cut < refAcquisitions.count {
                    let dropped = refAcquisitions.count - cut
                    let topHold = refAcquisitions[topIndex].holdID + 1
                    refAcquisitions = Array(refAcquisitions.prefix(cut))
                    warnings.append(
                        dropped == 1
                        ? "1 hand hold used after topping out on hold \(topHold) was left out of the moves. "
                          + "Raise the top-out drop margin if this route finishes low."
                        : "\(dropped) hand holds used after topping out on hold \(topHold) were left out of the moves. "
                          + "Raise the top-out drop margin if this route finishes low."
                    )
                }
            }
        }

        guard refAcquisitions.count >= 2 else {
            return SegmentationResult(
                sections: [],
                warnings: ["Fewer than two hand acquisitions on the reference climb, so the route has no moves to compare."]
            )
        }

        let attemptAcquisitions = attempt.handAcquisitions
        // First frame the attempt's hand reached each hold.
        var attemptArrival: [Int: Int] = [:]
        for a in attemptAcquisitions where attemptArrival[a.holdID] == nil {
            attemptArrival[a.holdID] = a.frame
        }

        // How far along the reference's own move list the attempt demonstrably
        // got. **An attempt ends once**, and this is what makes that
        // expressible.
        //
        // Without it, "reached the source hold but not the target" was read as
        // truncation on every move it happened to, so a climber who skipped a
        // hold and carried on was told "this is where your go ended" several
        // times over. On `gym-testing/test1` that fired on seven of nineteen
        // moves in a run that reported no fall at all.
        //
        // Skipping a hold and getting past it is a *beta difference*. Only the
        // move the attempt never got beyond is truncation.
        var lastReachedRefIndex = -1
        for (j, a) in refAcquisitions.enumerated() where attemptArrival[a.holdID] != nil {
            lastReachedRefIndex = j
        }

        var sections: [Section] = []
        for i in 0 ..< (refAcquisitions.count - 1) {
            let from = refAcquisitions[i]
            let to = refAcquisitions[i + 1]
            guard let fromHold = route.hold(id: from.holdID),
                  let toHold = route.hold(id: to.holdID) else { continue }

            // **A move ends with the hold taken, not one frame before it.**
            //
            // These ranges used to be half-open on the arrival frame, so
            // scrubbing to 100% of a move showed the last frame *before* the
            // hand landed, and the latch itself appeared as frame 0 of the next
            // move. On `gym-testing/test1` that read as the reference having
            // reached a new hold at the end of move 6 while the attempt had
            // not — and the attempt's latch then showing up at the start of
            // move 7.
            //
            // Consecutive moves therefore share one frame. That is correct: the
            // latch is both the end of one move and the start of the next, and
            // a climber describing the route would say so.
            let refRange = from.frame ..< min(to.frame + 1, max(referenceFrameCount, from.frame + 1))

            var attemptRange = 0 ..< 0
            var divergence: BetaDivergence?

            if let aStart = attemptArrival[from.holdID], let aEnd = attemptArrival[to.holdID], aEnd > aStart {
                attemptRange = aStart ..< min(aEnd + 1, max(attemptEnd, aStart + 1))
            } else if let aEnd = attemptArrival[to.holdID], attemptArrival[from.holdID] == nil {
                // Reached the target without ever using the source hold.
                divergence = BetaDivergence(
                    kind: .skippedHold,
                    detail: "You reached this hold without using hold \(from.holdID + 1) that the reference climber used.",
                    positions: [fromHold.position]
                )
                // Span the attempt's **approach** to the target, from whatever
                // it was holding beforehand.
                //
                // This used to be `aEnd - 1 ..< aEnd` — a single frame — which
                // left the attempt pane unable to move at all while the
                // reference pane played a whole move. Observed on
                // `gym-testing/test1` move 9 as a completely frozen attempt
                // video. A one-frame span is not a small span, it is an absent
                // one, and it reads as a broken player rather than as a
                // reported beta difference.
                let aStart = attemptAcquisitions.last { $0.frame < aEnd }?.frame ?? 0
                attemptRange = aStart ..< max(min(aEnd + 1, attemptEnd), aStart + 1)
            } else if let aStart = attemptArrival[from.holdID] {
                // Reached the source hold but not the target. Two very
                // different things look identical at this point, and only the
                // attempt's overall progress separates them.
                if lastReachedRefIndex > i {
                    // It got past this move without using the target hold —
                    // a skipped hold, not the end of the go.
                    //
                    // The span ends at the attempt's **own next hand
                    // acquisition**, not at the next hold the reference happens
                    // to visit later. Searching forward through the reference's
                    // order can land many holds away when the attempt took the
                    // route out of order, and the span then covers several
                    // reference moves' worth of climbing. Locked side-by-side
                    // playback maps that long attempt span onto one short
                    // reference move, so the attempt pane races through it —
                    // observed on `gym-testing/test1` move 5 as the climber
                    // appearing to teleport.
                    //
                    // This narrows it but does not make it right. The attempt
                    // genuinely covered more wall than the reference did
                    // between these two holds, and a move-to-move mapping has
                    // nowhere to put that. The fix is the sequence layer, where
                    // the two holds either side are anchors and the span is
                    // allowed to hold a different number of moves per climber.
                    var aEnd = attemptEnd
                    for a in attemptAcquisitions where a.frame > aStart {
                        aEnd = a.frame + 1
                        break
                    }
                    attemptRange = aStart ..< max(min(aEnd, attemptEnd), aStart + 1)
                    divergence = BetaDivergence(
                        kind: .skippedHold,
                        detail: "You got through this move without using hold \(to.holdID + 1) that the reference climber used.",
                        positions: [toHold.position]
                    )
                } else {
                    // Nothing later was reached, so this is genuinely where the
                    // attempt stopped. `attemptEnd` is the last contact, not the
                    // last decoded frame, so this does not drag the climber
                    // walking away into the metrics.
                    attemptRange = aStart ..< max(attemptEnd, aStart + 1)
                    divergence = BetaDivergence(
                        kind: .truncated,
                        detail: "The attempt starts this move but never reaches hold \(to.holdID + 1).",
                        positions: [toHold.position]
                    )
                }
            } else {
                divergence = BetaDivergence(
                    kind: .noContactsMatched,
                    detail: "The attempt has no matched hand contact for this move.",
                    positions: [fromHold.position, toHold.position]
                )
            }

            // Off-route contacts inside the attempt's window are a beta
            // divergence, not a metric difference. Report, don't analyse.
            if divergence == nil, !attemptRange.isEmpty {
                let strays = attempt.matched.filter {
                    $0.holdID == nil && $0.contact.startFrame >= attemptRange.lowerBound && $0.contact.startFrame < attemptRange.upperBound
                }
                if !strays.isEmpty {
                    divergence = BetaDivergence(
                        kind: .offRouteHold,
                        detail: "You used \(strays.count) hold\(strays.count == 1 ? "" : "s") here that the reference climber did not.",
                        positions: strays.map(\.contact.position)
                    )
                }
            }

            sections.append(Section(
                index: i,
                fromHold: fromHold,
                toHold: toHold,
                referenceRange: refRange,
                attemptRange: attemptRange,
                divergence: divergence
            ))
        }

        // **The attempt's spans must advance.**
        //
        // Moves are ordered in time, so the attempt's frame ranges have to be
        // too. They were not: on `gym-testing/test1` move 5's attempt span
        // started at frame 199 while move 4's started at 225 — the attempt
        // timeline running backwards between consecutive moves — and moves 7
        // and 8 shared the identical span 436-625, so the attempt pane replayed
        // the same footage for two different moves.
        //
        // Both come from the divergent branches choosing an end independently
        // of what the previous move already claimed. Clamping here rather than
        // in each branch keeps the invariant in one place, where it can be
        // read and tested.
        //
        // A move squeezed to nothing is left unreached rather than given a
        // one-frame span, because a pane that cannot move reads as a broken
        // player, not as a reported difference.
        var cursor = 0
        var squeezed = 0
        for i in sections.indices where !sections[i].attemptRange.isEmpty {
            let range = sections[i].attemptRange
            let lower = max(range.lowerBound, cursor)
            let upper = max(range.upperBound, lower)
            if upper - lower < 2 {
                sections[i].attemptRange = 0 ..< 0
                // **Not "unreached".** The attempt climbed this move; it just
                // took the holds in an order that leaves no stretch of its
                // video sitting between the neighbouring moves. Saying "you
                // didn't get this far" here would be a plain lie, and it is
                // the discouraging kind.
                sections[i].divergence = BetaDivergence(
                    kind: .differentHandOrder,
                    detail: "You didn't climb this as a separate move — you either went straight past a hold "
                          + "or took them in a different order, so there is no matching stretch of your climb here.",
                    positions: [sections[i].fromHold.position, sections[i].toHold.position]
                )
                squeezed += 1
            } else {
                sections[i].attemptRange = lower ..< upper
                // Consecutive moves share their boundary frame, so the next may
                // start one before this one ended.
                cursor = upper - 1
            }
        }
        if squeezed > 0 {
            warnings.append(
                "\(squeezed) move\(squeezed == 1 ? "" : "s") had no attempt footage left once the spans were "
                + "put in order — the attempt took these holds out of the reference's sequence."
            )
        }

        // Hand order divergence: the attempt visited the shared holds in a
        // different order.
        let refOrder = refAcquisitions.map(\.holdID)
        let attemptOrder = attemptAcquisitions.map(\.holdID).filter { refOrder.contains($0) }
        let refFiltered = refOrder.filter { attemptOrder.contains($0) }
        if !attemptOrder.isEmpty, attemptOrder != refFiltered {
            warnings.append("The attempt used the hand holds in a different order from the reference climb.")
        }

        let unreached = sections.filter { !$0.attemptReached }.count
        if unreached > 0 {
            warnings.append("\(unreached) of \(sections.count) moves were not reached by the attempt.")
        }
        return SegmentationResult(
            sections: sections, warnings: warnings,
            referenceAcquisitions: refAcquisitions.map { .init(frame: $0.frame, holdID: $0.holdID) }
        )
    }
}
