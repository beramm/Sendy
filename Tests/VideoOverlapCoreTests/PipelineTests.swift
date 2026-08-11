import Testing
import Foundation
@testable import VideoOverlapCore

@Suite("Smoothing")
struct PoseSmootherTests {

    /// Task 1.4 — a noisy sine shows reduced jitter and acceptable lag.
    @Test("1€ filter reduces jitter without unacceptable lag")
    func noisySine() {
        let n = 300
        let rate = 30.0
        var generator = SystemRandomNumberGenerator()
        var noisy: [PoseFrame] = []
        var truth: [Double] = []
        for i in 0 ..< n {
            let t = Double(i) / rate
            let clean = 0.5 + 0.1 * sin(2 * .pi * 0.5 * t)
            truth.append(clean)
            let noise = Double.random(in: -0.01 ... 0.01, using: &generator)
            var frame = SyntheticClimb.standingFrame(index: i, time: t)
            frame.joints[.leftWrist] = Joint(point: Point2D(x: 0.4, y: clean + noise), confidence: 0.9)
            noisy.append(frame)
        }
        let sequence = PoseSequence(frames: noisy, space: .wall, frameRate: rate, sourceWidth: 1080, sourceHeight: 1920)
        let smoothed = PoseSmoother().process(sequence, config: TuningConfig())

        func jitter(_ ys: [Double]) -> Double {
            // Mean absolute second difference: high-frequency content only, so
            // the sine itself contributes almost nothing.
            var total = 0.0
            for i in 1 ..< (ys.count - 1) { total += abs(ys[i + 1] - 2 * ys[i] + ys[i - 1]) }
            return total / Double(max(1, ys.count - 2))
        }
        let rawYs = noisy.map { $0.joints[.leftWrist]!.point.y }
        let smoothYs = smoothed.frames.map { $0.joints[.leftWrist]!.point.y }

        #expect(jitter(smoothYs) < jitter(rawYs) * 0.5)

        // Lag, measured as the shift that best matches the smoothed signal to
        // the clean one. "Acceptable" is defined against what this filter is
        // for: contact detection reads dwell boundaries, so more than about
        // three frames of group delay at 30fps would start moving them.
        func error(shift: Int) -> Double {
            var total = 0.0
            var count = 0
            for i in 100 ..< (n - shift) {
                total += abs(smoothYs[i + shift] - truth[i])
                count += 1
            }
            return total / Double(max(1, count))
        }
        let bestShift = (0 ... 10).min { error(shift: $0) < error(shift: $1) }!
        #expect(bestShift <= 3, "group delay of \(bestShift) frames")
        // At its best shift the filter must actually reproduce the signal.
        #expect(error(shift: bestShift) < 0.006)
    }

    @Test("Short tracking gaps are bridged, long ones are not")
    func gapHandling() {
        var sequence = SyntheticClimb.climb(moves: 8)
        // A 5-frame gap (bridged) and a 40-frame gap (abandoned).
        for i in 20 ..< 25 { sequence.frames[i].joints[.leftWrist] = nil }
        for i in 60 ..< 100 where i < sequence.frames.count { sequence.frames[i].joints[.leftWrist] = nil }
        let smoothed = PoseSmoother().process(sequence, config: TuningConfig())
        #expect(smoothed.frames[22].joints[.leftWrist] != nil)
        #expect(smoothed.frames[80].joints[.leftWrist] == nil)
        #expect(smoothed.warnings.contains { $0.contains("untracked") })
    }
}

@Suite("Contacts and route")
struct ContactRouteTests {

    @Test("Contacts land on the dwells of a synthetic climb")
    func contactsOnDwells() {
        let sequence = SyntheticClimb.climb(moves: 4, dwellFrames: 20, moveFrames: 6)
        let scale = ClimbScale(sequence: sequence)
        let result = ContactDetector().detect(sequence, scale: scale, config: TuningConfig())
        // Four hand moves plus two foot moves over five dwells: every extremity
        // should register at least one contact.
        for joint in JointName.extremities {
            #expect(result.contacts.contains { $0.joint == joint }, "no contact for \(joint.rawValue)")
        }
        // Nothing should be detected mid-move: every contact must overlap a
        // frame where that limb is stationary.
        for contact in result.contacts {
            #expect(contact.frameCount >= TuningConfig().contactDwellFrames)
        }
    }

    @Test("Re-grips merge into one contact")
    func mergeRegrip() {
        let scale = ClimbScale(iso: .square, torsoLength: 0.1)
        var config = TuningConfig()
        config.contactMergeRadius = 0.5     // body-lengths
        config.contactMergeGapFrames = 20
        let a = Contact(joint: .leftWrist, startFrame: 0, endFrame: 10, position: Point2D(x: 0.5, y: 0.5), confidence: 0.8)
        let b = Contact(joint: .leftWrist, startFrame: 20, endFrame: 30, position: Point2D(x: 0.51, y: 0.505), confidence: 0.8)
        var records: [MergeRecord] = []
        let merged = ContactDetector().merge([a, b], scale: scale, config: config, records: &records)
        #expect(merged.count == 1)
        #expect(merged[0].startFrame == 0 && merged[0].endFrame == 30)
        #expect(records.count == 1, "a merge must be recorded so it can be inspected")
    }

    /// Task 7.1. Merging works *inside* a hold; clustering separates holds. When
    /// both radii were 0.55 body-lengths a hand leaving one hold and landing on
    /// a neighbour was merged into a single contact, deleting the move before
    /// clustering ever saw it. This pins the two apart.
    @Test("Merging never joins contacts on two different holds")
    func mergeDoesNotCrossHolds() {
        let scale = ClimbScale(iso: .square, torsoLength: 0.1)
        let config = TuningConfig()
        #expect(config.contactMergeRadius < config.holdClusterEpsilon,
                "the defaults must keep merging strictly inside a hold")

        // Two holds exactly one cluster-epsilon apart — by definition distinct.
        let separation = config.holdClusterEpsilon * scale.torsoLength
        let first = Contact(joint: .leftWrist, startFrame: 0, endFrame: 10,
                            position: Point2D(x: 0.5, y: 0.5), confidence: 0.9)
        let second = Contact(joint: .leftWrist, startFrame: 12, endFrame: 22,
                             position: Point2D(x: 0.5 + separation, y: 0.5), confidence: 0.9)
        var records: [MergeRecord] = []
        let merged = ContactDetector().merge([first, second], scale: scale, config: config, records: &records)
        #expect(merged.count == 2, "two holds became one contact — this is the bug")
        #expect(records.isEmpty)
    }

    /// A chain of small steps must not walk across the wall one hold at a time.
    @Test("Chained merges do not drift away from where the run started")
    func mergeDoesNotDrift() {
        let scale = ClimbScale(iso: .square, torsoLength: 0.1)
        var config = TuningConfig()
        config.contactMergeRadius = 0.2
        config.contactMergeGapFrames = 8
        let step = 0.19 * scale.torsoLength
        let contacts = (0 ..< 5).map { i in
            Contact(joint: .leftWrist, startFrame: i * 12, endFrame: i * 12 + 6,
                    position: Point2D(x: 0.4 + Double(i) * step, y: 0.5), confidence: 0.9)
        }
        var records: [MergeRecord] = []
        let merged = ContactDetector().merge(contacts, scale: scale, config: config, records: &records)
        let span = (merged.map(\.position.x).max() ?? 0) - (merged.map(\.position.x).min() ?? 0)
        #expect(merged.count > 1, "a walking sequence must not collapse to one contact")
        #expect(span > step * 2, "merged positions drifted across the wall, span \(span)")
    }

    /// Task 7.2. A hold a foot touched first is still a hand hold once a hand
    /// uses it — the old behaviour fixed it as a foot hold forever, which cost
    /// the real fixture two thirds of its hand holds.
    @Test("A hold used by both a foot and a hand reports as both")
    func handAndFootHold() {
        let scale = ClimbScale(iso: .square, torsoLength: 0.1)
        let config = TuningConfig()
        let position = Point2D(x: 0.5, y: 0.5)
        let contacts = [
            // Foot gets there first.
            Contact(joint: .leftAnkle, startFrame: 0, endFrame: 20, position: position, confidence: 0.9),
            // Hand matches on it much later.
            Contact(joint: .rightWrist, startFrame: 200, endFrame: 240, position: position, confidence: 0.9)
        ]
        let route = RouteBuilder().build(contacts: contacts, scale: scale, config: config)
        let hold = route.holds.first
        #expect(hold?.usedByFeet == true)
        #expect(hold?.usedByHands == true)
        #expect(hold?.isHandHold == true, "a hand used it, so it is a hand hold")
        #expect(hold?.isMatchedHold == true)
        #expect(route.handHolds.count == 1)
        #expect(route.footHolds.count == 1, "it is both, and counts in both")
    }

    @Test("Distinct holds do not merge into one cluster")
    func dbscanSeparates() {
        let scale = ClimbScale(iso: .square, torsoLength: 0.1)
        var config = TuningConfig()
        config.holdClusterEpsilon = 0.5      // 0.05 wall units
        let contacts = [
            Contact(joint: .leftWrist, startFrame: 0, endFrame: 10, position: Point2D(x: 0.40, y: 0.50), confidence: 0.9),
            Contact(joint: .rightWrist, startFrame: 0, endFrame: 10, position: Point2D(x: 0.41, y: 0.51), confidence: 0.9),
            Contact(joint: .leftWrist, startFrame: 40, endFrame: 60, position: Point2D(x: 0.70, y: 0.80), confidence: 0.9)
        ]
        let route = RouteBuilder().build(contacts: contacts, scale: scale, config: config)
        #expect(route.holds.count == 2)
        #expect(route.holds[0].firstFrame == 0)
        #expect(route.holds[1].firstFrame == 40)
    }

    @Test("An implausible hold count is surfaced, not swallowed")
    func routeSanityWarnings() {
        let scale = ClimbScale(iso: .square, torsoLength: 0.1)
        let config = TuningConfig()
        let contacts = [Contact(joint: .leftWrist, startFrame: 0, endFrame: 5, position: .zero, confidence: 0.9)]
        let route = RouteBuilder().build(contacts: contacts, scale: scale, config: config)
        #expect(route.holds.count == 1)
        #expect(!route.warnings.isEmpty)
    }

    @Test("An off-route hold is flagged rather than analysed")
    func offRouteDetection() {
        let scale = ClimbScale(iso: .square, torsoLength: 0.1)
        var config = TuningConfig()
        config.routeMatchRadius = 0.5
        let route = Route(holds: [
            Hold(id: 0, position: Point2D(x: 0.4, y: 0.4), firstUsedBy: .leftWrist, ordinal: 0, contactCount: 2, firstFrame: 0),
            Hold(id: 1, position: Point2D(x: 0.5, y: 0.6), firstUsedBy: .rightWrist, ordinal: 1, contactCount: 2, firstFrame: 30)
        ])
        let attemptContacts = [
            Contact(joint: .leftWrist, startFrame: 0, endFrame: 10, position: Point2D(x: 0.4, y: 0.4), confidence: 0.9),
            Contact(joint: .rightWrist, startFrame: 20, endFrame: 30, position: Point2D(x: 0.9, y: 0.2), confidence: 0.9)
        ]
        let match = RouteMatcher().match(contacts: attemptContacts, to: route, scale: scale, config: config)
        #expect(match.offRoute.count == 1)
        #expect(match.warnings.contains { $0.contains("off-route") })
    }

    @Test("Sections are bounded by hand acquisitions")
    func segmentation() {
        let scale = ClimbScale(iso: .square, torsoLength: 0.1)
        var config = TuningConfig()
        config.routeMatchRadius = 0.5
        let holds = [
            Hold(id: 0, position: Point2D(x: 0.40, y: 0.40), firstUsedBy: .leftWrist, ordinal: 0, contactCount: 1, firstFrame: 0),
            Hold(id: 1, position: Point2D(x: 0.50, y: 0.55), firstUsedBy: .rightWrist, ordinal: 1, contactCount: 1, firstFrame: 30),
            Hold(id: 2, position: Point2D(x: 0.45, y: 0.70), firstUsedBy: .leftWrist, ordinal: 2, contactCount: 1, firstFrame: 60),
            Hold(id: 3, position: Point2D(x: 0.48, y: 0.10), firstUsedBy: .leftAnkle, ordinal: 3, contactCount: 1, firstFrame: 5)
        ]
        let route = Route(holds: holds)
        func contacts(_ offset: Int) -> [Contact] {
            [
                Contact(joint: .leftWrist, startFrame: 0 + offset, endFrame: 20 + offset, position: holds[0].position, confidence: 0.9),
                Contact(joint: .rightWrist, startFrame: 30 + offset, endFrame: 50 + offset, position: holds[1].position, confidence: 0.9),
                Contact(joint: .leftWrist, startFrame: 60 + offset, endFrame: 80 + offset, position: holds[2].position, confidence: 0.9),
                Contact(joint: .leftAnkle, startFrame: 5 + offset, endFrame: 80 + offset, position: holds[3].position, confidence: 0.9)
            ]
        }
        let reference = RouteMatcher().match(contacts: contacts(0), to: route, scale: scale, config: config)
        let attempt = RouteMatcher().match(contacts: contacts(10), to: route, scale: scale, config: config)
        let result = SectionSegmenter().segment(
            route: route, reference: reference, attempt: attempt,
            referenceFrameCount: 100, attemptFrameCount: 110
        )
        // Three hand acquisitions → two moves. Feet do not create boundaries.
        #expect(result.sections.count == 2)
        // Ranges include the arrival frame — a move ends with the hold taken,
        // so consecutive moves share their boundary frame.
        #expect(result.sections[0].referenceRange == 0 ..< 31)
        #expect(result.sections[0].attemptRange == 10 ..< 41)
        #expect(result.sections.allSatisfy { $0.attemptReached })
    }

    @Test("Skipping a hold and carrying on is not the end of the go")
    func skippedTargetIsNotTruncation() {
        let (route, scale, config) = ladderRoute()
        func hand(_ j: JointName, _ s: Int, _ e: Int, _ h: Int) -> Contact {
            Contact(joint: j, startFrame: s, endFrame: e, position: route.holds[h].position, confidence: 0.9)
        }
        // Reference uses all four holds in order.
        let reference = RouteMatcher().match(
            contacts: [
                hand(.leftWrist, 0, 20, 0), hand(.rightWrist, 30, 50, 1),
                hand(.leftWrist, 60, 80, 2), hand(.rightWrist, 90, 110, 3)
            ],
            to: route, scale: scale, config: config
        )
        // The attempt skips hold 1 entirely but climbs to the top.
        let attempt = RouteMatcher().match(
            contacts: [
                hand(.leftWrist, 0, 20, 0), hand(.leftWrist, 60, 80, 2), hand(.rightWrist, 90, 110, 3)
            ],
            to: route, scale: scale, config: config
        )
        let result = SectionSegmenter().segment(
            route: route, reference: reference, attempt: attempt,
            referenceFrameCount: 120, attemptFrameCount: 120
        )
        // An attempt ends once, and this one did not end at all.
        let truncatedCount = result.sections.filter { $0.divergence?.kind == .truncated }.count
        #expect(truncatedCount == 0)
        #expect(result.sections[0].divergence?.kind == .skippedHold)

        // No move may claim frames belonging to a later one.
        for (a, b) in zip(result.sections, result.sections.dropFirst())
        where !a.attemptRange.isEmpty && !b.attemptRange.isEmpty {
            #expect(a.attemptRange.upperBound <= b.attemptRange.upperBound)
        }
    }

    @Test("A skipped move's span ends at the attempt's next hold, not a distant one")
    func skippedMoveSpanIsNarrow() {
        let (route, scale, config) = ladderRoute()
        func hand(_ j: JointName, _ s: Int, _ e: Int, _ h: Int) -> Contact {
            Contact(joint: j, startFrame: s, endFrame: e, position: route.holds[h].position, confidence: 0.9)
        }
        let reference = RouteMatcher().match(
            contacts: [
                hand(.leftWrist, 0, 20, 0), hand(.rightWrist, 30, 50, 1),
                hand(.leftWrist, 60, 80, 2), hand(.rightWrist, 90, 110, 3)
            ],
            to: route, scale: scale, config: config
        )
        // The attempt takes hold 1 *before* hold 0 — out of the reference's
        // order — then carries on to 2 and 3 much later. Move 1 (0 → 1) cannot
        // find a forward span, and must not swallow everything up to hold 3.
        let attempt = RouteMatcher().match(
            contacts: [
                hand(.rightWrist, 0, 20, 1),
                hand(.leftWrist, 40, 60, 0),
                hand(.leftWrist, 80, 100, 2),
                hand(.rightWrist, 300, 340, 3)
            ],
            to: route, scale: scale, config: config
        )
        let result = SectionSegmenter().segment(
            route: route, reference: reference, attempt: attempt,
            referenceFrameCount: 120, attemptFrameCount: 400
        )
        let move = result.sections[0]
        #expect(move.divergence?.kind == .skippedHold)
        // Ends at the attempt's next acquisition (frame 80), not at hold 3's
        // arrival (frame 300) and not at the end of the clip.
        #expect(move.attemptRange == 40 ..< 81)
    }

    @Test("Hands used after topping out don't become moves")
    func topOutEndsTheClimb() {
        // Four holds climbing, then a fifth well below the top — the climber
        // coming down or reaching past after the send.
        let positions = [0.20, 0.40, 0.60, 0.85, 0.55]
        let holds = positions.enumerated().map { i, y in
            Hold(id: i, position: Point2D(x: 0.45, y: y), firstUsedBy: .leftWrist,
                 ordinal: i, contactCount: 1, firstFrame: i * 30)
        }
        let route = Route(holds: holds)
        var config = TuningConfig()
        config.routeMatchRadius = 0.5
        let scale = ClimbScale(iso: .square, torsoLength: 0.1)
        let contacts = holds.enumerated().map { i, h in
            Contact(joint: i.isMultiple(of: 2) ? .leftWrist : .rightWrist,
                    startFrame: i * 30, endFrame: i * 30 + 20, position: h.position, confidence: 0.9)
        }
        let match = RouteMatcher().match(contacts: contacts, to: route, scale: scale, config: config)
        let result = SectionSegmenter().segment(
            route: route, reference: match, attempt: match,
            referenceFrameCount: 200, attemptFrameCount: 200,
            scale: scale, config: config
        )
        // Five acquisitions would be four moves; the post-top one is dropped.
        #expect(result.sections.count == 3)
        #expect(result.sections.last?.toHold.id == 3)
        #expect(result.warnings.contains { $0.contains("topping out") })

        // Raising the margin disables it — a traverse or a low finish needs that.
        var permissive = config
        permissive.topOutDropMargin = 10
        let untrimmed = SectionSegmenter().segment(
            route: route, reference: match, attempt: match,
            referenceFrameCount: 200, attemptFrameCount: 200,
            scale: scale, config: permissive
        )
        #expect(untrimmed.sections.count == 4)
    }

    @Test("No reached move gets a one-frame attempt span")
    func noFrozenAttemptPane() {
        let (route, scale, config) = ladderRoute()
        func hand(_ j: JointName, _ s: Int, _ e: Int, _ h: Int) -> Contact {
            Contact(joint: j, startFrame: s, endFrame: e, position: route.holds[h].position, confidence: 0.9)
        }
        let reference = RouteMatcher().match(
            contacts: [
                hand(.leftWrist, 0, 20, 0), hand(.rightWrist, 30, 50, 1),
                hand(.leftWrist, 60, 80, 2), hand(.rightWrist, 90, 110, 3)
            ],
            to: route, scale: scale, config: config
        )
        // The attempt skips hold 1 — it goes 0, then straight to 2. Move 2
        // (1 → 2) therefore has a target the attempt reached and a source it
        // never used.
        let attempt = RouteMatcher().match(
            contacts: [
                hand(.leftWrist, 0, 30, 0), hand(.rightWrist, 60, 90, 2), hand(.leftWrist, 120, 150, 3)
            ],
            to: route, scale: scale, config: config
        )
        let result = SectionSegmenter().segment(
            route: route, reference: reference, attempt: attempt,
            referenceFrameCount: 120, attemptFrameCount: 160
        )
        // A single frame is not a small span, it is an absent one — the pane
        // cannot move and reads as a broken player.
        for move in result.sections where move.attemptReached {
            #expect(move.attemptRange.count > 1)
        }
        // Moves 1 and 2 both want the attempt's single 0-60 stretch, since it
        // skipped the hold between them. Only the first keeps it; the second
        // is left with no footage and says so, rather than claiming the
        // climber never got there.
        #expect(result.sections[0].attemptRange == 0 ..< 61)
        #expect(result.sections[1].divergence?.kind == .differentHandOrder)
        #expect(result.sections[1].attemptRange.isEmpty)
    }

    @Test("A genuinely truncated attempt marks exactly one move")
    func truncationMarksOneMove() {
        let (route, scale, config) = ladderRoute()
        func hand(_ j: JointName, _ s: Int, _ e: Int, _ h: Int) -> Contact {
            Contact(joint: j, startFrame: s, endFrame: e, position: route.holds[h].position, confidence: 0.9)
        }
        let reference = RouteMatcher().match(
            contacts: [
                hand(.leftWrist, 0, 20, 0), hand(.rightWrist, 30, 50, 1),
                hand(.leftWrist, 60, 80, 2), hand(.rightWrist, 90, 110, 3)
            ],
            to: route, scale: scale, config: config
        )
        // The attempt comes off after hold 1 and never touches 2 or 3.
        let attempt = RouteMatcher().match(
            contacts: [hand(.leftWrist, 0, 20, 0), hand(.rightWrist, 30, 50, 1)],
            to: route, scale: scale, config: config
        )
        let result = SectionSegmenter().segment(
            route: route, reference: reference, attempt: attempt,
            referenceFrameCount: 120, attemptFrameCount: 120
        )
        let truncated = result.sections.filter { $0.divergence?.kind == .truncated }
        #expect(truncated.count == 1)
        // …and it is the move the attempt actually started, not a later one it
        // never entered.
        #expect(truncated.first?.index == 1)
        // The truncated span stops at the last contact, not the last frame.
        #expect(result.sections[1].attemptRange.upperBound <= 51)
    }

    // MARK: - Hand acquisitions are per-hand
    //
    // These pin the rule that a hand's hold persists until *that hand* moves
    // elsewhere, not until its contact ends. On `gym-testing/test1` the older
    // rule — skip only an immediate repeat of the previous hold in the combined
    // stream — turned 12 real moves into 19, because a shake-out longer than
    // `contactMergeGapFrames` reads as a fresh acquisition.

    /// Four holds in a line, wide match radius, so matching is never the thing
    /// under test.
    private func ladderRoute() -> (Route, ClimbScale, TuningConfig) {
        let holds = (0 ..< 4).map { i in
            Hold(
                id: i,
                position: Point2D(x: 0.4 + 0.02 * Double(i), y: 0.2 + 0.15 * Double(i)),
                firstUsedBy: .leftWrist, ordinal: i, contactCount: 1, firstFrame: i * 10
            )
        }
        var config = TuningConfig()
        config.routeMatchRadius = 0.5
        return (Route(holds: holds), ClimbScale(iso: .square, torsoLength: 0.1), config)
    }

    @Test("A hand re-gripping its own hold after a long gap is not a move")
    func reGripIsNotAnAcquisition() {
        let (route, scale, config) = ladderRoute()
        // The shape measured on the real reference clip: left takes hold 0,
        // right moves on to hold 1, then left re-grabs hold 0 after a gap far
        // longer than the merge window.
        let contacts = [
            Contact(joint: .leftWrist, startFrame: 0, endFrame: 60, position: route.holds[0].position, confidence: 0.9),
            Contact(joint: .rightWrist, startFrame: 40, endFrame: 200, position: route.holds[1].position, confidence: 0.9),
            Contact(joint: .leftWrist, startFrame: 100, endFrame: 180, position: route.holds[0].position, confidence: 0.9)
        ]
        let acquisitions = RouteMatcher()
            .match(contacts: contacts, to: route, scale: scale, config: config)
            .handAcquisitions
        #expect(acquisitions.map(\.holdID) == [0, 1])
    }

    @Test("Matching the second hand onto an occupied hold is not a move")
    func handMatchIsNotAnAcquisition() {
        let (route, scale, config) = ladderRoute()
        let contacts = [
            Contact(joint: .leftWrist, startFrame: 0, endFrame: 200, position: route.holds[0].position, confidence: 0.9),
            // Right joins the hold left is still holding, then leaves for the
            // next one. Only the departure is a move.
            Contact(joint: .rightWrist, startFrame: 50, endFrame: 120, position: route.holds[0].position, confidence: 0.9),
            Contact(joint: .rightWrist, startFrame: 150, endFrame: 250, position: route.holds[1].position, confidence: 0.9)
        ]
        let acquisitions = RouteMatcher()
            .match(contacts: contacts, to: route, scale: scale, config: config)
            .handAcquisitions
        #expect(acquisitions.map(\.holdID) == [0, 1])
    }

    @Test("Returning to a hold via another hold is a move, both times")
    func genuineReturnIsAnAcquisition() {
        let (route, scale, config) = ladderRoute()
        // A down-climb: left goes 0 → 2 → 0. The middle move is real, so the
        // return is real too. This is what per-hand state buys over
        // "first acquisition of each hold wins", which cannot express it.
        let contacts = [
            Contact(joint: .leftWrist, startFrame: 0, endFrame: 40, position: route.holds[0].position, confidence: 0.9),
            Contact(joint: .leftWrist, startFrame: 60, endFrame: 100, position: route.holds[2].position, confidence: 0.9),
            Contact(joint: .leftWrist, startFrame: 120, endFrame: 160, position: route.holds[0].position, confidence: 0.9)
        ]
        let acquisitions = RouteMatcher()
            .match(contacts: contacts, to: route, scale: scale, config: config)
            .handAcquisitions
        #expect(acquisitions.map(\.holdID) == [0, 2, 0])
    }

    @Test("Two hands alternating up a route produce one move each, in order")
    func alternatingHandsAreMonotonic() {
        let (route, scale, config) = ladderRoute()
        // Left 0, right 1, left 2, right 3 — a normal ladder — with a re-grip
        // on the trailing hand between each, which is what the old rule
        // doubled up. Expect four acquisitions, strictly increasing.
        let contacts = [
            Contact(joint: .leftWrist, startFrame: 0, endFrame: 50, position: route.holds[0].position, confidence: 0.9),
            Contact(joint: .rightWrist, startFrame: 30, endFrame: 90, position: route.holds[1].position, confidence: 0.9),
            Contact(joint: .leftWrist, startFrame: 70, endFrame: 110, position: route.holds[0].position, confidence: 0.9),
            Contact(joint: .leftWrist, startFrame: 130, endFrame: 190, position: route.holds[2].position, confidence: 0.9),
            Contact(joint: .rightWrist, startFrame: 160, endFrame: 210, position: route.holds[1].position, confidence: 0.9),
            Contact(joint: .rightWrist, startFrame: 230, endFrame: 280, position: route.holds[3].position, confidence: 0.9)
        ]
        let acquisitions = RouteMatcher()
            .match(contacts: contacts, to: route, scale: scale, config: config)
            .handAcquisitions
        #expect(acquisitions.map(\.holdID) == [0, 1, 2, 3])
        #expect(zip(acquisitions, acquisitions.dropFirst()).allSatisfy { $0.frame < $1.frame })
    }
}

@Suite("Sequences")
struct SequenceBuilderTests {

    private func route(_ n: Int) -> Route {
        Route(holds: (0 ..< n).map { i in
            Hold(id: i, position: Point2D(x: 0.4, y: 0.2 + 0.1 * Double(i)),
                 firstUsedBy: .leftWrist, ordinal: i, contactCount: 1, firstFrame: i * 10)
        })
    }

    /// The case the whole layer exists for, from the project's own worked
    /// example: holds a, b, c with footholds. The reference reaches a → c
    /// directly with still feet — one move. The attempt cannot span it, so it
    /// steps a foot, matches a hand to b, then reaches c — three moves.
    /// Both took a and c with a hand, so it is **one sequence**.
    @Test("Three moves against one is one sequence, not a mismatch")
    func aToCIsOneSequence() {
        let result = SequenceBuilder().build(
            route: route(3),
            referenceAcquisitions: [(0, 0), (100, 2)],
            attemptAcquisitions: [(0, 0), (60, 1), (120, 2)],
            referenceFrameCount: 200, attemptFrameCount: 200
        )
        #expect(result.sequences.count == 1)
        let s = result.sequences[0]
        #expect(s.fromAnchorID == 0 && s.toAnchorID == 2)
        #expect(s.referenceMoves.count == 1)
        #expect(s.attemptMoves.count == 2, "attempt crosses a→b→c")
        #expect(s.moveCountDelta == 1)
        // Hold 1 is the attempt's alone, so it cannot anchor.
        #expect(result.anchorIDs == [0, 2])
    }

    /// Task 9.4. The attempt taking a shared hold out of the reference's order
    /// must not create a sequence that runs backwards — that is the defect the
    /// move-level layer had, seen on gym-testing/test1 as the climber
    /// teleporting.
    @Test("A hold taken out of order is demoted rather than anchoring backwards")
    func outOfOrderHoldDoesNotAnchor() {
        let result = SequenceBuilder().build(
            route: route(4),
            referenceAcquisitions: [(0, 0), (50, 1), (100, 2), (150, 3)],
            // The attempt takes hold 2 *before* hold 1.
            attemptAcquisitions: [(0, 0), (40, 2), (90, 1), (140, 3)],
            referenceFrameCount: 200, attemptFrameCount: 200
        )
        for s in result.sequences {
            #expect(!s.referenceRange.isEmpty)
            #expect(!s.attemptRange.isEmpty)
            #expect(s.attemptRange.lowerBound < s.attemptRange.upperBound)
        }
        // Spans advance monotonically in both panes, by construction.
        for (a, b) in zip(result.sequences, result.sequences.dropFirst()) {
            #expect(a.referenceRange.lowerBound <= b.referenceRange.lowerBound)
            #expect(a.attemptRange.lowerBound <= b.attemptRange.lowerBound)
        }
        #expect(result.warnings.contains { $0.contains("different order") })
    }

    @Test("No shared holds still produces something inspectable")
    func noAnchorsFailsSoft() {
        let result = SequenceBuilder().build(
            route: route(4),
            referenceAcquisitions: [(0, 0), (50, 1)],
            attemptAcquisitions: [(0, 2), (50, 3)],
            referenceFrameCount: 100, attemptFrameCount: 100
        )
        #expect(result.sequences.count == 1)
        #expect(result.anchorDensity == 0)
        #expect(!result.warnings.isEmpty)
    }

    @Test("Anchor density reports the fraction of reference hand holds shared")
    func anchorDensity() {
        let result = SequenceBuilder().build(
            route: route(4),
            referenceAcquisitions: [(0, 0), (50, 1), (100, 2), (150, 3)],
            attemptAcquisitions: [(0, 0), (80, 2), (160, 3)],
            referenceFrameCount: 200, attemptFrameCount: 200
        )
        #expect(result.anchorIDs == [0, 2, 3])
        #expect(abs(result.anchorDensity - 0.75) < 1e-9)
    }
}
