import Foundation
@testable import VideoOverlapCore

/// Synthetic pose fixtures.
///
/// Logic tests must not require video files — `CLAUDE.md` is explicit about
/// that, and it is what keeps these runnable in CI on a machine with no
/// climbing footage.
enum SyntheticClimb {

    /// A standing figure, arms down, feet on the ground. Proportions are
    /// roughly human so COM lands where a human's does.
    static func standingFrame(index: Int = 0, time: Double = 0, hipY: Double = 0.5) -> PoseFrame {
        let torso = 0.12
        let shoulderY = hipY + torso
        var joints: [JointName: Joint] = [:]
        func put(_ name: JointName, _ x: Double, _ y: Double, _ c: Double = 0.9) {
            joints[name] = Joint(point: Point2D(x: x, y: y), confidence: c)
        }
        put(.nose, 0.5, shoulderY + 0.07)
        put(.neck, 0.5, shoulderY + 0.02)
        put(.leftShoulder, 0.45, shoulderY)
        put(.rightShoulder, 0.55, shoulderY)
        put(.leftElbow, 0.44, shoulderY - 0.09)
        put(.rightElbow, 0.56, shoulderY - 0.09)
        put(.leftWrist, 0.43, shoulderY - 0.17)
        put(.rightWrist, 0.57, shoulderY - 0.17)
        put(.leftHip, 0.47, hipY)
        put(.rightHip, 0.53, hipY)
        put(.root, 0.5, hipY)
        put(.leftKnee, 0.47, hipY - 0.13)
        put(.rightKnee, 0.53, hipY - 0.13)
        put(.leftAnkle, 0.47, hipY - 0.26)
        put(.rightAnkle, 0.53, hipY - 0.26)
        return PoseFrame(index: index, timeSeconds: time, joints: joints)
    }

    /// A climb: `moves` hand movements, each a dwell then a reach. Extremities
    /// sit still on holds during the dwell, which is what `ContactDetector`
    /// is meant to find.
    ///
    /// - Parameters:
    ///   - dwellFrames: frames a limb rests on a hold
    ///   - moveFrames: frames a limb takes to travel
    ///   - rise: vertical gain per move, in wall units
    static func climb(
        moves: Int = 4,
        dwellFrames: Int = 15,
        moveFrames: Int = 6,
        rise: Double = 0.06,
        frameRate: Double = 30,
        speedFactor: Double = 1.0
    ) -> PoseSequence {
        var frames: [PoseFrame] = []
        var index = 0
        var hipY = 0.20

        // Hand and foot targets, updated as the climber moves up.
        var leftHand = Point2D(x: 0.43, y: 0.37)
        var rightHand = Point2D(x: 0.57, y: 0.37)
        var leftFoot = Point2D(x: 0.47, y: 0.06)
        var rightFoot = Point2D(x: 0.53, y: 0.06)

        func emit(_ hipY: Double, _ lh: Point2D, _ rh: Point2D, _ lf: Point2D, _ rf: Point2D) {
            var frame = standingFrame(index: index, time: Double(index) / frameRate, hipY: hipY)
            let torso = 0.12
            let shoulderY = hipY + torso
            frame.joints[.leftWrist] = Joint(point: lh, confidence: 0.85)
            frame.joints[.rightWrist] = Joint(point: rh, confidence: 0.85)
            frame.joints[.leftAnkle] = Joint(point: lf, confidence: 0.85)
            frame.joints[.rightAnkle] = Joint(point: rf, confidence: 0.85)
            frame.joints[.leftElbow] = Joint(point: (Point2D(x: 0.45, y: shoulderY) + lh) * 0.5, confidence: 0.8)
            frame.joints[.rightElbow] = Joint(point: (Point2D(x: 0.55, y: shoulderY) + rh) * 0.5, confidence: 0.8)
            frame.joints[.leftKnee] = Joint(point: (Point2D(x: 0.47, y: hipY) + lf) * 0.5, confidence: 0.8)
            frame.joints[.rightKnee] = Joint(point: (Point2D(x: 0.53, y: hipY) + rf) * 0.5, confidence: 0.8)
            frames.append(frame)
            index += 1
        }

        let dwell = max(1, Int(Double(dwellFrames) * speedFactor))
        let move = max(1, Int(Double(moveFrames) * speedFactor))

        for m in 0 ..< moves {
            for _ in 0 ..< dwell { emit(hipY, leftHand, rightHand, leftFoot, rightFoot) }
            // Alternate which hand moves.
            let target = m % 2 == 0 ? leftHand : rightHand
            let next = Point2D(x: target.x, y: target.y + rise)
            for s in 1 ... move {
                let t = Double(s) / Double(move)
                let moving = target + (next - target) * t
                emit(hipY + rise * t * 0.5,
                     m % 2 == 0 ? moving : leftHand,
                     m % 2 == 0 ? rightHand : moving,
                     leftFoot, rightFoot)
            }
            if m % 2 == 0 { leftHand = next } else { rightHand = next }
            hipY += rise * 0.5
            // Feet follow every other move.
            if m % 2 == 1 {
                leftFoot = Point2D(x: leftFoot.x, y: leftFoot.y + rise)
                rightFoot = Point2D(x: rightFoot.x, y: rightFoot.y + rise)
            }
        }
        for _ in 0 ..< dwell { emit(hipY, leftHand, rightHand, leftFoot, rightFoot) }

        return PoseSequence(frames: frames, space: .wall, frameRate: frameRate, sourceWidth: 1080, sourceHeight: 1920)
    }

    /// The fixture clip, if it is present. Tests that need real footage skip
    /// rather than fail when `Fixtures/` is empty.
    static var fixtureVideoURL: URL? {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // VideoOverlapCoreTests
            .deletingLastPathComponent()   // Tests
            .deletingLastPathComponent()   // repo root
        let dir = root.appendingPathComponent("Fixtures")
        let contents = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
        return contents.first { ["mov", "mp4", "m4v"].contains($0.pathExtension.lowercased()) }
    }
}
