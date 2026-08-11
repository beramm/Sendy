import Foundation

/// One merge that happened, kept so the `segment` diagnostic can show *why*
/// two contacts became one. Guessing at this from a warning count is what let
/// the merge-radius bug survive.
public struct MergeRecord: Sendable, Codable, Hashable {
    public var joint: JointName
    public var keptRange: ClosedRange<Int>
    public var absorbedRange: ClosedRange<Int>
    /// Body-lengths between the two contact positions.
    public var distance: Double
    /// Frames between the end of one and the start of the next.
    public var gapFrames: Int

    public init(joint: JointName, keptRange: ClosedRange<Int>, absorbedRange: ClosedRange<Int>, distance: Double, gapFrames: Int) {
        self.joint = joint
        self.keptRange = keptRange
        self.absorbedRange = absorbedRange
        self.distance = distance
        self.gapFrames = gapFrames
    }
}

public struct ContactResult: Sendable, Codable {
    public var contacts: [Contact]
    /// Contacts detected before merging. The difference between this and
    /// `contacts.count` is how much merging changed the route.
    public var rawContactCount: Int = 0
    public var merges: [MergeRecord] = []
    /// Per-frame speed for each extremity, body-lengths/sec, `nil` where the
    /// joint wasn't tracked. Kept because the threshold-tuning harness plots it
    /// and because "why was there no contact here" is the question you ask most
    /// on a gym floor.
    public var speeds: [JointName: [Double?]]
    public var warnings: [String]

    public init(
        contacts: [Contact],
        speeds: [JointName: [Double?]],
        warnings: [String],
        rawContactCount: Int = 0,
        merges: [MergeRecord] = []
    ) {
        self.contacts = contacts
        self.speeds = speeds
        self.warnings = warnings
        self.rawContactCount = rawContactCount
        self.merges = merges
    }
}

/// A limb at rest on a hold, from velocity and dwell. Never from image
/// segmentation.
///
/// The known-hard cases are shake-outs, hand matches, re-grips and smears —
/// see `plan.md` Q1. Merging handles re-grips and shake-outs; a hand match
/// produces two contacts at nearly the same position from *different* joints,
/// which is correct and lands in one DBSCAN cluster downstream.
public struct ContactDetector: Sendable {

    public init() {}

    public func detect(_ sequence: PoseSequence, scale: ClimbScale, config: TuningConfig) -> ContactResult {
        var contacts: [Contact] = []
        var speeds: [JointName: [Double?]] = [:]
        var warnings: [String] = []

        guard sequence.frames.count > 1 else {
            return ContactResult(
                contacts: [],
                speeds: [:],
                warnings: ["Too few pose frames to detect contacts."]
            )
        }

        for joint in JointName.extremities {
            let speed = speedTrack(sequence, joint: joint, scale: scale)
            speeds[joint] = speed
            contacts.append(contentsOf: runs(
                sequence: sequence,
                joint: joint,
                speeds: speed,
                config: config
            ))
        }

        let beforeMerge = contacts.count
        var merges: [MergeRecord] = []
        contacts = merge(contacts, scale: scale, config: config, records: &merges)
        contacts.sort(by: Contact.deterministicOrder)

        let weak = contacts.filter { $0.confidence < config.contactConfidenceFloor }
        contacts.removeAll { $0.confidence < config.contactConfidenceFloor }

        if contacts.isEmpty {
            warnings.append("No contacts detected. Raise the velocity threshold or lower the dwell frames.")
        }
        if !weak.isEmpty {
            warnings.append("Discarded \(weak.count) contacts below the confidence floor.")
        }
        if beforeMerge > contacts.count {
            warnings.append("Merged \(beforeMerge - contacts.count) near-duplicate contacts (re-grips, shake-outs).")
        }
        // The invariant that matters. Merging happens inside a hold; clustering
        // separates holds. Set the radii equal and merging silently deletes
        // moves — this is loud because it is the knob most likely to be dragged
        // in the tuning panel and the damage is invisible downstream.
        if config.contactMergeRadius >= config.holdClusterEpsilon {
            warnings.append(String(
                format: "Merge radius (%.2f BL) is not smaller than the hold cluster radius (%.2f BL). Contacts on *different* holds are being merged into one, which deletes moves from the route. Lower the merge radius.",
                config.contactMergeRadius, config.holdClusterEpsilon
            ))
        }
        return ContactResult(
            contacts: contacts, speeds: speeds, warnings: warnings,
            rawContactCount: beforeMerge, merges: merges
        )
    }

    /// Speed per frame in body-lengths/sec. `nil` where the joint is untracked in
    /// either this frame or the previous one — an unknown speed is not a slow
    /// speed, and treating it as one invents contacts.
    func speedTrack(_ sequence: PoseSequence, joint: JointName, scale: ClimbScale) -> [Double?] {
        var out = [Double?](repeating: nil, count: sequence.frames.count)
        for i in 1 ..< sequence.frames.count {
            guard
                let a = sequence.frames[i - 1].joints[joint]?.point,
                let b = sequence.frames[i].joints[joint]?.point
            else { continue }
            let dt = max(1e-4, sequence.frames[i].timeSeconds - sequence.frames[i - 1].timeSeconds)
            out[i] = scale.distance(a, b) / dt
        }
        // The first frame inherits the second's speed so a climber who starts
        // already matched on the start holds doesn't lose that contact.
        if sequence.frames.count > 1 { out[0] = out[1] }
        return out
    }

    private func runs(
        sequence: PoseSequence,
        joint: JointName,
        speeds: [Double?],
        config: TuningConfig
    ) -> [Contact] {
        var out: [Contact] = []
        var runStart: Int?

        func closeRun(end: Int) {
            guard let start = runStart else { return }
            runStart = nil
            let length = end - start + 1
            guard length >= config.contactDwellFrames else { return }
            var xs: [Double] = [], ys: [Double] = [], cs: [Double] = []
            for i in start ... end {
                guard let j = sequence.frames[i].joints[joint] else { continue }
                xs.append(j.point.x); ys.append(j.point.y); cs.append(j.confidence)
            }
            guard let mx = xs.median, let my = ys.median, let mc = cs.mean else { return }
            out.append(Contact(
                joint: joint,
                startFrame: start,
                endFrame: end,
                position: Point2D(x: mx, y: my),
                confidence: mc
            ))
        }

        for i in speeds.indices {
            let atRest = (speeds[i].map { $0 < config.contactVelocityThreshold } ?? false)
                && sequence.frames[i].joints[joint] != nil
            if atRest {
                if runStart == nil { runStart = i }
            } else {
                closeRun(end: i - 1)
            }
        }
        closeRun(end: speeds.count - 1)
        return out
    }

    /// A hand adjusting on a hold produces two contacts at nearly the same
    /// place. Merge same-joint contacts that are close in both space and time.
    func merge(_ contacts: [Contact], scale: ClimbScale, config: TuningConfig, records: inout [MergeRecord]) -> [Contact] {
        var byJoint: [JointName: [Contact]] = [:]
        for c in contacts { byJoint[c.joint, default: []].append(c) }

        var out: [Contact] = []
        // Fixed joint order: `Dictionary` iteration order is randomised per
        // process, and an order-dependent merge would make the whole pipeline
        // non-reproducible run to run.
        for joint in JointName.extremities {
            guard let group = byJoint[joint] else { continue }
            var sorted = group.sorted(by: Contact.deterministicOrder)
            var merged: [Contact] = []
            while let first = sorted.first {
                sorted.removeFirst()
                var current = first
                var didMerge = true
                while didMerge {
                    didMerge = false
                    for (idx, candidate) in sorted.enumerated() {
                        let gap = candidate.startFrame - current.endFrame
                        let distance = scale.distance(current.position, candidate.position)
                        guard gap <= config.contactMergeGapFrames,
                              distance <= config.contactMergeRadius,
                              // Chained merges must not drift: each absorbed
                              // contact has to stay near where the run started,
                              // or a sequence of small steps walks across the
                              // wall one hold at a time.
                              scale.distance(first.position, candidate.position) <= config.contactMergeRadius * 1.5
                        else { continue }
                        records.append(MergeRecord(
                            joint: joint,
                            keptRange: current.startFrame ... current.endFrame,
                            absorbedRange: candidate.startFrame ... candidate.endFrame,
                            distance: distance,
                            gapFrames: gap
                        ))
                        let wA = Double(current.frameCount)
                        let wB = Double(candidate.frameCount)
                        current = Contact(
                            id: current.id,
                            joint: current.joint,
                            startFrame: min(current.startFrame, candidate.startFrame),
                            endFrame: max(current.endFrame, candidate.endFrame),
                            position: (current.position * wA + candidate.position * wB) / (wA + wB),
                            confidence: (current.confidence * wA + candidate.confidence * wB) / (wA + wB)
                        )
                        sorted.remove(at: idx)
                        didMerge = true
                        break
                    }
                }
                merged.append(current)
            }
            out.append(contentsOf: merged)
        }
        return out
    }
}
