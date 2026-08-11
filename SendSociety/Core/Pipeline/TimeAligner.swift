import Foundation

public struct WarpPair: Sendable, Codable, Hashable {
    public var referenceFrame: Int
    public var attemptFrame: Int

    public init(referenceFrame: Int, attemptFrame: Int) {
        self.referenceFrame = referenceFrame
        self.attemptFrame = attemptFrame
    }
}

/// A monotonic mapping from reference frames to attempt frames for one section.
public struct WarpPath: Sendable, Codable, Hashable {
    public var sectionIndex: Int
    public var pairs: [WarpPair]
    /// Mean DTW cost per step. High means the two climbers did visibly
    /// different things — worth surfacing rather than hiding.
    public var meanCost: Double

    public init(sectionIndex: Int, pairs: [WarpPair], meanCost: Double) {
        self.sectionIndex = sectionIndex
        self.pairs = pairs
        self.meanCost = meanCost
    }

    public var isEmpty: Bool { pairs.isEmpty }

    /// Attempt frame corresponding to a reference frame. Nearest match on the
    /// path — never an interpolation across a discontinuity.
    public func attemptFrame(forReference ref: Int) -> Int? {
        guard !pairs.isEmpty else { return nil }
        var best = pairs[0]
        var bestD = abs(pairs[0].referenceFrame - ref)
        for p in pairs where abs(p.referenceFrame - ref) < bestD {
            best = p
            bestD = abs(p.referenceFrame - ref)
        }
        return best.attemptFrame
    }

    public func referenceFrame(forAttempt att: Int) -> Int? {
        guard !pairs.isEmpty else { return nil }
        var best = pairs[0]
        var bestD = abs(pairs[0].attemptFrame - att)
        for p in pairs where abs(p.attemptFrame - att) < bestD {
            best = p
            bestD = abs(p.attemptFrame - att)
        }
        return best.referenceFrame
    }

    public var isMonotonic: Bool {
        for i in 1 ..< max(1, pairs.count) {
            if pairs[i].referenceFrame < pairs[i - 1].referenceFrame { return false }
            if pairs[i].attemptFrame < pairs[i - 1].attemptFrame { return false }
        }
        return true
    }
}

/// Dynamic time warping, anchored at section boundaries.
///
/// One climber is faster. Timestamps are never compared directly anywhere in
/// this app; all cross-climb comparison happens on warped indices or at section
/// boundaries. DTW runs *within* a section so one badly-tracked move cannot
/// corrupt alignment everywhere else.
public struct TimeAligner: Sendable {

    public init() {}

    /// Per-frame feature vector: joint positions relative to the hip centre and
    /// scaled by torso length, plus the COM offset and the contact bitmask.
    ///
    /// Hip-relative and torso-scaled is what makes the feature comparable
    /// between a tall climber and a short one — an absolute joint position
    /// would make the two climbers' sizes dominate the distance.
    public static func features(
        frame: PoseFrame,
        scale: ClimbScale,
        contacts: Set<JointName>
    ) -> [Double] {
        var out: [Double] = []
        let origin = frame.hipCenter ?? .zero
        let torso = frame.torsoLength.map { max($0, 1e-6) } ?? scale.torsoLength
        let ordered: [JointName] = [
            .leftShoulder, .rightShoulder, .leftElbow, .rightElbow,
            .leftWrist, .rightWrist, .leftHip, .rightHip,
            .leftKnee, .rightKnee, .leftAnkle, .rightAnkle, .neck, .nose
        ]
        for name in ordered {
            if let p = frame.joints[name]?.point {
                let v = scale.iso.vector(from: origin, to: p)
                out.append(v.x / torso)
                out.append(v.y / torso)
            } else {
                // An untracked joint contributes zero offset rather than an
                // invented position. It costs nothing and biases nothing.
                out.append(0)
                out.append(0)
            }
        }
        for name in JointName.extremities {
            // Contact state is weighted heavily: two climbers with the same
            // limbs on the wall are at the same point in the move, whatever
            // their limbs are doing in between.
            out.append(contacts.contains(name) ? 2.0 : 0)
        }
        return out
    }

    /// Builds a per-frame contact-state lookup.
    public static func contactStates(contacts: [Contact], frameCount: Int) -> [Set<JointName>] {
        var out = [Set<JointName>](repeating: [], count: max(0, frameCount))
        for c in contacts {
            let lower = max(0, c.startFrame)
            let upper = min(frameCount - 1, c.endFrame)
            guard lower <= upper else { continue }
            for i in lower ... upper { out[i].insert(c.joint) }
        }
        return out
    }

    /// DTW over two feature sequences. Endpoints are hard anchors: `(0,0)` and
    /// `(n-1, m-1)` are always on the path, which is what makes section
    /// boundaries line up exactly.
    public static func warp(reference: [[Double]], attempt: [[Double]]) -> (path: [WarpPair], meanCost: Double) {
        let n = reference.count, m = attempt.count
        guard n > 0, m > 0 else { return ([], .infinity) }

        var cost = [[Double]](repeating: [Double](repeating: .infinity, count: m + 1), count: n + 1)
        cost[0][0] = 0
        for i in 1 ... n {
            for j in 1 ... m {
                let d = distance(reference[i - 1], attempt[j - 1])
                let best = min(cost[i - 1][j], cost[i][j - 1], cost[i - 1][j - 1])
                cost[i][j] = d + best
            }
        }

        var path: [WarpPair] = []
        var i = n, j = m
        var steps = 0
        while i > 0 && j > 0 {
            path.append(WarpPair(referenceFrame: i - 1, attemptFrame: j - 1))
            steps += 1
            let diag = cost[i - 1][j - 1]
            let up = cost[i - 1][j]
            let left = cost[i][j - 1]
            if diag <= up && diag <= left {
                i -= 1; j -= 1
            } else if up <= left {
                i -= 1
            } else {
                j -= 1
            }
        }
        path.reverse()
        let total = cost[n][m]
        return (path, steps > 0 && total.isFinite ? total / Double(steps) : .infinity)
    }

    static func distance(_ a: [Double], _ b: [Double]) -> Double {
        var sum = 0.0
        for k in 0 ..< min(a.count, b.count) {
            let d = a[k] - b[k]
            sum += d * d
        }
        return sum.squareRoot()
    }

    /// Aligns one section. Returns an empty path when the attempt never reached
    /// the section — a truncated attempt is normal, not an error.
    public func align(
        section: Section,
        reference: PoseSequence,
        attempt: PoseSequence,
        referenceScale: ClimbScale,
        attemptScale: ClimbScale,
        referenceContacts: [Set<JointName>],
        attemptContacts: [Set<JointName>]
    ) -> WarpPath {
        align(
            index: section.index,
            referenceRange: section.referenceRange, attemptRange: section.attemptRange,
            reference: reference, attempt: attempt,
            referenceScale: referenceScale, attemptScale: attemptScale,
            referenceContacts: referenceContacts, attemptContacts: attemptContacts
        )
    }

    /// Warp one span of each climb onto the other.
    ///
    /// Takes ranges rather than a `Section` so the same code can anchor at
    /// **sequence** boundaries, which is the only place the two climbs are
    /// provably in the same position. Anchoring at moves assumes attempt move
    /// *n* means the same as reference move *n*, and where it does not, DTW has
    /// no way to spread the mismatch: it absorbs the whole unmatched stretch at
    /// one point in the path, which is what a climber sees as teleporting.
    public func align(
        index: Int,
        referenceRange: Range<Int>,
        attemptRange: Range<Int>,
        reference: PoseSequence,
        attempt: PoseSequence,
        referenceScale: ClimbScale,
        attemptScale: ClimbScale,
        referenceContacts: [Set<JointName>],
        attemptContacts: [Set<JointName>]
    ) -> WarpPath {
        guard !referenceRange.isEmpty, !attemptRange.isEmpty else {
            return WarpPath(sectionIndex: index, pairs: [], meanCost: .infinity)
        }
        let refIndices = Array(referenceRange).filter { $0 < reference.count }
        let attIndices = Array(attemptRange).filter { $0 < attempt.count }
        guard !refIndices.isEmpty, !attIndices.isEmpty else {
            return WarpPath(sectionIndex: index, pairs: [], meanCost: .infinity)
        }

        let refFeatures = refIndices.map {
            Self.features(frame: reference.frames[$0], scale: referenceScale, contacts: referenceContacts.indices.contains($0) ? referenceContacts[$0] : [])
        }
        let attFeatures = attIndices.map {
            Self.features(frame: attempt.frames[$0], scale: attemptScale, contacts: attemptContacts.indices.contains($0) ? attemptContacts[$0] : [])
        }

        let (rawPath, meanCost) = Self.warp(reference: refFeatures, attempt: attFeatures)
        let pairs = rawPath.map {
            WarpPair(referenceFrame: refIndices[$0.referenceFrame], attemptFrame: attIndices[$0.attemptFrame])
        }
        return WarpPath(sectionIndex: index, pairs: pairs, meanCost: meanCost)
    }
}
