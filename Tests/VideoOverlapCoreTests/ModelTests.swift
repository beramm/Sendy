import Testing
import Foundation
@testable import VideoOverlapCore

// Task 1.2 — core value types round-trip through JSON.

@Suite("Core value types")
struct ModelTests {

    func roundTrip<T: Codable & Equatable>(_ value: T) throws -> T {
        let data = try JSONEncoder().encode(value)
        return try JSONDecoder().decode(T.self, from: data)
    }

    @Test("PoseFrame round-trips")
    func poseFrameRoundTrip() throws {
        let frame = SyntheticClimb.standingFrame(index: 7, time: 0.233)
        #expect(try roundTrip(frame) == frame)
    }

    @Test("PoseSequence round-trips with warnings intact")
    func poseSequenceRoundTrip() throws {
        var sequence = SyntheticClimb.climb(moves: 2)
        sequence.warnings = ["a warning that must survive"]
        let decoded = try roundTrip(sequence.frames)
        #expect(decoded.count == sequence.frames.count)
        let data = try JSONEncoder().encode(sequence)
        let back = try JSONDecoder().decode(PoseSequence.self, from: data)
        #expect(back.warnings == sequence.warnings)
        #expect(back.space == .wall)
    }

    @Test("Contact, Hold, Route and Section round-trip")
    func pipelineTypesRoundTrip() throws {
        let contact = Contact(joint: .leftWrist, startFrame: 3, endFrame: 20, position: Point2D(x: 0.4, y: 0.5), confidence: 0.7)
        #expect(try roundTrip(contact) == contact)

        let hold = Hold(id: 2, position: Point2D(x: 0.4, y: 0.5), firstUsedBy: .leftWrist, ordinal: 2, contactCount: 3, firstFrame: 3)
        #expect(try roundTrip(hold) == hold)

        let route = Route(holds: [hold], warnings: ["kept"])
        #expect(try roundTrip(route) == route)

        let section = Section(
            index: 0, fromHold: hold, toHold: hold,
            referenceRange: 0 ..< 30, attemptRange: 5 ..< 40,
            divergence: BetaDivergence(kind: .offRouteHold, detail: "d", positions: [Point2D(x: 0.1, y: 0.2)])
        )
        #expect(try roundTrip(section) == section)
    }

    @Test("ClimbSession takes a second attempt without touching the reference")
    func sessionAttempts() throws {
        var session = ClimbSession(name: "test")
        session.grade = .v4
        session.reference = VideoRef(filename: "ref.mov", role: .reference, label: "Reference")
        session.addAttempt(VideoRef(filename: "a1.mov", role: .attempt))
        let referenceBefore = session.reference
        session.addAttempt(VideoRef(filename: "a2.mov", role: .attempt))
        #expect(session.attempts.count == 2)
        #expect(session.reference == referenceBefore)
        #expect(session.attempts[1].label == "Attempt 2")
        #expect(try roundTrip(session) == session)
    }

    @Test("Climb grades cover V1 through V9")
    func climbGradeRange() throws {
        #expect(ClimbGrade.allCases.map(\.rawValue) == Array(1 ... 9))
        #expect(ClimbGrade.v9.displayName == "V9")
        #expect(try roundTrip(ClimbGrade.v9) == .v9)
    }

    @Test("Sessions saved before grades existed still decode")
    func oldSessionWithoutGradeDecodes() throws {
        let encoded = try JSONEncoder().encode(ClimbSession(name: "legacy"))
        var object = try JSONSerialization.jsonObject(with: encoded) as! [String: Any]
        object.removeValue(forKey: "grade")
        let oldData = try JSONSerialization.data(withJSONObject: object)

        let decoded = try JSONDecoder().decode(ClimbSession.self, from: oldData)
        #expect(decoded.grade == nil)
    }

    @Test("Capture orientation survives a session round-trip")
    func captureOrientationRoundTrip() throws {
        let orientation = CaptureOrientation(
            gravityX: 0.05,
            gravityY: -0.98,
            gravityZ: 0.19
        )
        var session = ClimbSession(name: "aligned pair")
        session.reference = VideoRef(
            filename: "reference.mov",
            role: .reference,
            captureOrientation: orientation
        )

        let decoded = try roundTrip(session)
        #expect(decoded.reference?.captureOrientation == orientation)
    }

    @Test("Gravity-derived capture angles use portrait camera level as zero")
    func captureOrientationAngles() {
        let level = CaptureOrientation(gravityX: 0, gravityY: -1, gravityZ: 0)
        #expect(abs(level.rollDegrees) < 1e-9)
        #expect(abs(level.pitchDegrees) < 1e-9)

        let tilted = CaptureOrientation(gravityX: 0.1, gravityY: -0.98, gravityZ: 0.2)
        #expect(tilted.rollDegrees > 0)
        #expect(tilted.pitchDegrees > 0)
    }

    @Test("Videos saved before capture alignment existed still decode")
    func oldVideoRefWithoutOrientationDecodes() throws {
        let original = VideoRef(filename: "old.mov", role: .reference)
        let encoded = try JSONEncoder().encode(original)
        var object = try JSONSerialization.jsonObject(with: encoded) as! [String: Any]
        object.removeValue(forKey: "captureOrientation")
        let oldData = try JSONSerialization.data(withJSONObject: object)

        let decoded = try JSONDecoder().decode(VideoRef.self, from: oldData)
        #expect(decoded.captureOrientation == nil)
    }

    @Test("Homography inverts and composes")
    func homographyMath() {
        let h = Homography(m: [1.1, 0.05, 0.02, -0.03, 0.95, 0.01, 0.0001, 0.0002, 1])
        let inverse = h.inverted
        #expect(inverse != nil)
        let p = Point2D(x: 0.3, y: 0.7)
        let round = inverse!.apply(to: h.apply(to: p))
        #expect(abs(round.x - p.x) < 1e-9)
        #expect(abs(round.y - p.y) < 1e-9)
    }

    @Test("Thresholds in body-lengths are independent of framing")
    func scaleIsFramingIndependent() {
        // The same climb filmed from twice as far away must measure the same.
        let near = SyntheticClimb.climb(moves: 3)
        var far = near
        for i in far.frames.indices {
            for (name, joint) in far.frames[i].joints {
                far.frames[i].joints[name] = Joint(
                    point: Point2D(x: 0.5 + (joint.point.x - 0.5) * 0.5, y: 0.5 + (joint.point.y - 0.5) * 0.5),
                    confidence: joint.confidence
                )
            }
        }
        let nearScale = ClimbScale(sequence: near)
        let farScale = ClimbScale(sequence: far)
        #expect(farScale.torsoLength < nearScale.torsoLength)

        let config = TuningConfig()
        let nearContacts = ContactDetector().detect(near, scale: nearScale, config: config)
        let farContacts = ContactDetector().detect(far, scale: farScale, config: config)
        #expect(nearContacts.contacts.count == farContacts.contacts.count)
    }
}

@Suite("Saved config compatibility")
struct TuningConfigCompatibilityTests {

    /// A session saved before a threshold existed must still open.
    ///
    /// This is not hypothetical: `gym-testing/test1` was seeded onto a phone,
    /// then `groundMargin` and `topOutDropMargin` were added, and the session
    /// on the device still held the 44-key config. Swift's synthesised
    /// `Decodable` throws on a missing key, so without care the whole session
    /// becomes unopenable — losing a recording because a slider was added
    /// later would be the worst possible failure for a debug harness.
    @Test("A config saved without a newer field still decodes")
    func olderConfigDecodes() throws {
        let encoded = try JSONEncoder().encode(TuningConfig())
        var object = try JSONSerialization.jsonObject(with: encoded) as! [String: Any]
        object.removeValue(forKey: "groundMargin")
        object.removeValue(forKey: "topOutDropMargin")
        let trimmed = try JSONSerialization.data(withJSONObject: object)

        let decoded = try? JSONDecoder().decode(TuningConfig.self, from: trimmed)
        #expect(decoded != nil, "a config missing a newer field must still decode")
        // …and the absent fields must come back as their defaults, not zero,
        // because zero disables both rules silently.
        #expect(decoded?.groundMargin == TuningConfig().groundMargin)
        #expect(decoded?.topOutDropMargin == TuningConfig().topOutDropMargin)
    }

    /// Removing a clip has to take its pose cache with it. The cache is keyed
    /// by video id and source, so anything left behind is unreachable — a
    /// silent leak of the largest files the app writes.
    @Test("Removing a video deletes its pose cache and leaves the other clip alone")
    func removeVideoClearsPoseCache() async throws {
        let root = URL.temporaryDirectory.appendingPathComponent("VOTest-\(UUID().uuidString)")
        let store = SessionStore(root: root)
        defer { try? FileManager.default.removeItem(at: root) }

        var session = try await store.create(name: "removal")
        let source = URL.temporaryDirectory.appendingPathComponent("clip-\(UUID().uuidString).mov")
        try Data("not really a movie".utf8).write(to: source)
        defer { try? FileManager.default.removeItem(at: source) }

        let reference = try await store.importVideo(from: source, into: session, role: .reference, label: "Reference")
        let attempt = try await store.importVideo(from: source, into: session, role: .attempt, label: "Attempt 1")
        session.reference = reference
        session.addAttempt(attempt)
        try await store.save(session)

        let pose = SyntheticClimb.climb(moves: 2)
        for video in session.allVideos {
            try await store.cachePose(pose, session: session, video: video, source: .vision)
        }

        await store.removeVideo(session: session, video: attempt)

        let attemptVideoURL = await store.videoURL(session: session, video: attempt)
        #expect(!FileManager.default.fileExists(atPath: attemptVideoURL.path))
        #expect(await store.hasCachedPose(session: session, video: attempt, source: .vision) == false)

        // The reference is untouched.
        let referenceVideoURL = await store.videoURL(session: session, video: reference)
        #expect(FileManager.default.fileExists(atPath: referenceVideoURL.path))
        #expect(await store.hasCachedPose(session: session, video: reference, source: .vision) == true)
    }

    @Test("A draft is invisible until session metadata is committed")
    func draftIsNotListed() async throws {
        let root = URL.temporaryDirectory.appendingPathComponent("VOTest-\(UUID().uuidString)")
        let store = SessionStore(root: root)
        defer { try? FileManager.default.removeItem(at: root) }

        var draft = try await store.createDraft(name: "Working title")
        #expect(await store.listSessions().isEmpty)

        draft.name = "Moon Board Project"
        draft.grade = .v4
        try await store.save(draft)

        let saved = try #require(await store.listSessions().first)
        #expect(saved.name == "Moon Board Project")
        #expect(saved.grade == .v4)
    }

    @Test("The sweep collects abandoned drafts and spares saved sessions")
    func sweepRemovesOnlyDrafts() async throws {
        let root = URL.temporaryDirectory.appendingPathComponent("VOTest-\(UUID().uuidString)")
        let store = SessionStore(root: root)
        defer { try? FileManager.default.removeItem(at: root) }

        let abandoned = try await store.createDraft(name: "Never finished")
        var saved = try await store.createDraft(name: "Finished")
        try await store.save(saved)
        saved.name = "Finished"

        await store.sweepAbandonedDrafts()

        let fm = FileManager.default
        #expect(!fm.fileExists(atPath: await store.directory(for: abandoned.id).path))
        #expect(fm.fileExists(atPath: await store.directory(for: saved.id).path))
        #expect(await store.listSessions().count == 1)
    }

    @Test("The sweep spares the draft currently being filled in")
    func sweepSparesLiveDraft() async throws {
        let root = URL.temporaryDirectory.appendingPathComponent("VOTest-\(UUID().uuidString)")
        let store = SessionStore(root: root)
        defer { try? FileManager.default.removeItem(at: root) }

        let live = try await store.createDraft(name: "In progress")
        await store.sweepAbandonedDrafts(keeping: live.id)

        #expect(FileManager.default.fileExists(atPath: await store.directory(for: live.id).path))
    }

}
