import Foundation

/// A contact tied to a route hold, or explicitly not tied to one.
public struct MatchedContact: Sendable, Codable, Hashable {
    public var contact: Contact
    /// `nil` means off-route: the climber used a hold the reference climber
    /// never touched. That is itself a meaningful difference, so it is kept and
    /// reported rather than discarded.
    public var holdID: Int?

    public init(contact: Contact, holdID: Int?) {
        self.contact = contact
        self.holdID = holdID
    }
}

public struct MatchResult: Sendable, Codable {
    public var matched: [MatchedContact]
    public var warnings: [String]

    public var offRoute: [MatchedContact] { matched.filter { $0.holdID == nil } }

    /// Hand acquisitions in order: the frames at which a hand arrived somewhere
    /// new. These are the move boundaries.
    ///
    /// **State is per hand, and a hand's hold persists until that hand goes
    /// somewhere else.** Not until its contact ends — until it moves. Those are
    /// different, and the difference is the whole bug this replaced.
    ///
    /// The previous rule skipped a contact only when it repeated the
    /// *immediately previous* hold, anywhere in the combined stream. Measured
    /// on `gym-testing/test1`, the reference climb came out as
    /// `7 → 8 → 10 → 7 → 11 → 12 → 11 → 14 → 11 → 16 → 14 → 18 → 16 → 18` —
    /// 19 moves from a route a climber counts as 8–11.
    ///
    /// Every one of those apparent returns is the *same hand* re-grabbing the
    /// *same hold* after a gap of 14–59 frames:
    ///
    /// ```
    /// leftWrist  211-372 → hold 7
    /// rightWrist 368-613 → hold 10
    /// leftWrist  389-564 → hold 7     ← same hand, same hold, 17-frame gap
    /// ```
    ///
    /// `ContactDetector` merging is meant to absorb exactly this, and misses it
    /// because `contactMergeGapFrames` is 8 — a shake-out or a re-grip takes
    /// longer than 0.27s. Raising that threshold is the wrong lever: it is a
    /// position-based merge and widening it risks swallowing genuine
    /// neighbouring holds, which is the Phase 7 bug in the other direction.
    ///
    /// Holding the hold per hand fixes it at the right level. A hand that lets
    /// go and takes the same hold again has not moved through the route, no
    /// matter how long the gap. Under this rule the same clip yields
    /// `2 → 3 → 5 → 6 → 7 → 8 → 10 → 11 → 12 → 14 → 16 → 18 → 19` — 12 moves,
    /// strictly increasing in route order.
    ///
    /// Three cases are deliberately *not* boundaries:
    ///
    /// - **Re-grip / shake-out.** A hand takes again the last hold it took.
    /// - **Hand match.** The second hand joins the hold the first is currently
    ///   holding. Both hands end on one hold, but the climber has not moved
    ///   through the route. Detected from live contact overlap, since this is
    ///   the one case that genuinely depends on *when* the other hand let go.
    /// - **Repeat of a match.** Either hand re-taking a hold it just matched on.
    ///
    /// A hand returning to a hold it left *via another hold* **is** a boundary —
    /// a down-climb, or a hold used twice with a real move in between, is two
    /// moves and reports as two. That is what per-hand state buys over "first
    /// acquisition of each hold wins", which cannot express it at all.
    public var handAcquisitions: [(frame: Int, holdID: Int)] {
        // Two explicit pairs of variables rather than dictionaries keyed by
        // joint: `Dictionary` iteration order is randomised per process in
        // Swift and has already produced a non-deterministic route once here.
        //
        // `last` is where the hand went most recently and never expires.
        // `until` is when its contact ended, and is only consulted for the
        // hand-match case.
        var leftHold: Int?, leftUntil = Int.min
        var rightHold: Int?, rightUntil = Int.min
        var out: [(frame: Int, holdID: Int)] = []

        let handContacts = matched
            .filter(\.contact.isHand)
            .sorted { Contact.deterministicOrder($0.contact, $1.contact) }

        for m in handContacts {
            guard let id = m.holdID else { continue }
            let start = m.contact.startFrame
            let isLeft = m.contact.joint.isLeft

            let ownLast = isLeft ? leftHold : rightHold
            let otherHold = isLeft ? rightHold : leftHold
            let otherUntil = isLeft ? rightUntil : leftUntil

            // The hand is where it already was: a re-grip, not a move.
            let reGrip = ownLast == id
            // The other hand is on this hold right now: a match, not a move.
            let match = otherHold == id && otherUntil >= start

            if !reGrip && !match {
                out.append((start, id))
            }

            if isLeft {
                leftHold = id
                leftUntil = m.contact.endFrame
            } else {
                rightHold = id
                rightUntil = m.contact.endFrame
            }
        }
        return out
    }
}

/// Nearest-neighbour matching of contacts to an already-built route.
public struct RouteMatcher: Sendable {

    public init() {}

    public func match(
        contacts: [Contact],
        to route: Route,
        scale: ClimbScale,
        config: TuningConfig
    ) -> MatchResult {
        var matched: [MatchedContact] = []
        for c in contacts {
            var best: Int?
            var bestD = config.routeMatchRadius
            for h in route.holds {
                let d = scale.distance(h.position, c.position)
                if d <= bestD {
                    bestD = d
                    best = h.id
                }
            }
            matched.append(MatchedContact(contact: c, holdID: best))
        }
        var warnings: [String] = []
        let off = matched.filter { $0.holdID == nil }.count
        if off > 0 {
            warnings.append("\(off) contacts matched no hold on the reference route — reported as off-route, not as technique differences.")
        }
        if !contacts.isEmpty && matched.allSatisfy({ $0.holdID == nil }) {
            warnings.append("No contact matched the reference route at all. The two clips may not show the same route, or registration may have failed.")
        }
        return MatchResult(matched: matched, warnings: warnings)
    }
}
