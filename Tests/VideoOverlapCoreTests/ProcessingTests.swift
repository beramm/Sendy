import Testing
import Foundation
@testable import VideoOverlapCore

/// Counts how many times pose extraction actually ran.
final class SpyExtractor: PoseExtractor, @unchecked Sendable {
    private let lock = NSLock()
    private var _calls = 0
    var calls: Int { lock.withLock { _calls } }

    let reference: PoseSequence
    let attempt: PoseSequence

    init(reference: PoseSequence, attempt: PoseSequence) {
        self.reference = reference
        self.attempt = attempt
    }

    func extract(url: URL, config: TuningConfig, progress: @Sendable @escaping (Double) -> Void) async throws -> PoseSequence {
        lock.withLock { _calls += 1 }
        progress(1)
        // The first video handed to the pipeline is the reference.
        return lock.withLock { _calls } == 1 ? reference : attempt
    }
}

final class SpyPose3DExtractor: Pose3DExtractor, @unchecked Sendable {
    private let lock = NSLock()
    private var _calls = 0
    var calls: Int { lock.withLock { _calls } }
    let sequence: PoseSequence3D?
    let failure: Error?

    init(sequence: PoseSequence3D? = nil, failure: Error? = nil) {
        self.sequence = sequence
        self.failure = failure
    }

    func extract(
        url: URL,
        config: TuningConfig,
        progress: @Sendable @escaping (Double) -> Void
    ) async throws -> PoseSequence3D {
        lock.withLock { _calls += 1 }
        if let failure { throw failure }
        progress(1)
        return sequence!
    }
}

final class SpyCombinedPoseExtractor: CombinedPoseExtractor, @unchecked Sendable {
    private let lock = NSLock()
    private var _calls = 0
    var calls: Int { lock.withLock { _calls } }
    let bundle: PoseExtractionBundle

    init(bundle: PoseExtractionBundle) {
        self.bundle = bundle
    }

    func extract(
        url: URL,
        config: TuningConfig,
        progress: @Sendable @escaping (Double) -> Void
    ) async throws -> PoseExtractionBundle {
        lock.withLock { _calls += 1 }
        progress(1)
        return bundle
    }
}

@Suite("Processing")
struct ProcessingTests {

    func pose3D(from pose: PoseSequence, emptyAt emptyIndex: Int? = nil) -> PoseSequence3D {
        PoseSequence3D(
            frames: pose.frames.map { frame in
                let joints: [JointName: Joint3D] = frame.index == emptyIndex
                    ? [:]
                    : [.root: Joint3D(point: Point3D(x: 0, y: 0, z: -2), confidence: 0.9)]
                return PoseFrame3D(index: frame.index, timeSeconds: frame.timeSeconds, joints: joints)
            },
            frameRate: pose.frameRate,
            sourceWidth: pose.sourceWidth,
            sourceHeight: pose.sourceHeight
        )
    }

    func makeSession(store: SessionStore) async throws -> ClimbSession {
        var session = try await store.create(name: "test")
        // The pipeline needs files to exist for the alignment stage to try; it
        // must degrade rather than throw when they can't be decoded.
        let videosDir = await store.directory(for: session.id).appendingPathComponent("videos")
        try FileManager.default.createDirectory(at: videosDir, withIntermediateDirectories: true)
        let reference = VideoRef(filename: "ref.mov", role: .reference, label: "Reference")
        let attempt = VideoRef(filename: "att.mov", role: .attempt, label: "Attempt 1")
        try Data().write(to: videosDir.appendingPathComponent(reference.filename))
        try Data().write(to: videosDir.appendingPathComponent(attempt.filename))
        session.reference = reference
        session.attempts = [attempt]
        try await store.save(session)
        return session
    }

    /// Tasks 1.2c and 4.8 — **reprocessing must never re-run pose extraction.**
    @Test("Reprocessing with a new config runs zero pose extractions")
    func reprocessUsesCache() async throws {
        let root = URL.temporaryDirectory.appendingPathComponent("VOTest-\(UUID().uuidString)")
        let store = SessionStore(root: root)
        defer { try? FileManager.default.removeItem(at: root) }

        let session = try await makeSession(store: store)
        let spy = SpyExtractor(
            reference: SyntheticClimb.climb(moves: 4),
            attempt: SyntheticClimb.climb(moves: 4, speedFactor: 1.4)
        )
        let pipeline = ProcessingPipeline(store: store, extractor: spy, analysisProvider: TemplateAnalysisProvider())

        var config = TuningConfig()
        _ = try await pipeline.process(session: session, config: config)
        #expect(spy.calls == 2, "first run should extract both videos")

        // Change a threshold and reprocess.
        config.contactVelocityThreshold *= 1.5
        let start = Date()
        let second = try await pipeline.process(session: session, config: config)
        let elapsed = Date().timeIntervalSince(start)

        #expect(spy.calls == 2, "reprocessing must not re-run Vision")
        #expect(second.stages.first { $0.name == "Pose extraction" }?.detail.contains("cache") == true)
        // Task 4.8: a 60s session reprocesses in under 3 seconds. The synthetic
        // climb is shorter, so this is a floor, not the real measurement.
        #expect(elapsed < 3.0, "reprocess took \(elapsed)s")
    }

    @Test("Combined extraction keeps every 2D and 3D frame synchronized")
    func combinedTimelineParity() {
        let pose = SyntheticClimb.climb(moves: 2)
        let pose3D = pose3D(from: pose, emptyAt: 5)
        let bundle = PoseExtractionBundle(pose: pose, pose3D: pose3D)

        #expect(bundle.hasSynchronizedTimeline())
        #expect(pose.frames.count == pose3D.frames.count)
        #expect(pose3D.frames[5].joints.isEmpty)
        for index in pose.frames.indices {
            #expect(pose.frames[index].index == pose3D.frames[index].index)
            #expect(abs(pose.frames[index].timeSeconds - pose3D.frames[index].timeSeconds) < 1e-9)
        }
    }

    @Test("Pose cache matrix runs only the detector that is missing")
    func cacheMatrix() async throws {
        enum CacheCase: CaseIterable { case neither, only2D, only3D, both }

        for cacheCase in CacheCase.allCases {
            let root = URL.temporaryDirectory.appendingPathComponent("VOTest-\(UUID().uuidString)")
            let store = SessionStore(root: root)
            defer { try? FileManager.default.removeItem(at: root) }
            let session = try await makeSession(store: store)
            let video = try #require(session.reference)
            let pose = SyntheticClimb.climb(moves: 2)
            let pose3D = pose3D(from: pose)

            if cacheCase == .only2D || cacheCase == .both {
                try await store.cachePose(pose, session: session, video: video, source: .vision)
            }
            if cacheCase == .only3D || cacheCase == .both {
                try await store.cachePose3D(pose3D, session: session, video: video)
            }

            let poseSpy = SpyExtractor(reference: pose, attempt: pose)
            let pose3DSpy = SpyPose3DExtractor(sequence: pose3D)
            let combinedSpy = SpyCombinedPoseExtractor(bundle: PoseExtractionBundle(pose: pose, pose3D: pose3D))
            let pipeline = ProcessingPipeline(
                store: store,
                extractor: poseSpy,
                pose3DExtractor: pose3DSpy,
                combinedPoseExtractor: combinedSpy
            )

            let result = try await pipeline.poseData(
                for: video, session: session, config: TuningConfig(), progress: { _ in }
            )
            #expect(result.pose3D != nil)

            switch cacheCase {
            case .neither:
                #expect(combinedSpy.calls == 1)
                #expect(poseSpy.calls == 0)
                #expect(pose3DSpy.calls == 0)
            case .only2D:
                #expect(combinedSpy.calls == 0)
                #expect(poseSpy.calls == 0)
                #expect(pose3DSpy.calls == 1)
            case .only3D:
                #expect(combinedSpy.calls == 0)
                #expect(poseSpy.calls == 1)
                #expect(pose3DSpy.calls == 0)
            case .both:
                #expect(combinedSpy.calls == 0)
                #expect(poseSpy.calls == 0)
                #expect(pose3DSpy.calls == 0)
            }
        }
    }

    @Test("A 3D extraction failure preserves valid cached 2D pose")
    func pose3DFailureIsNonFatal() async throws {
        let root = URL.temporaryDirectory.appendingPathComponent("VOTest-\(UUID().uuidString)")
        let store = SessionStore(root: root)
        defer { try? FileManager.default.removeItem(at: root) }
        let session = try await makeSession(store: store)
        let video = try #require(session.reference)
        let pose = SyntheticClimb.climb(moves: 2)
        try await store.cachePose(pose, session: session, video: video, source: .vision)

        let failed3D = SpyPose3DExtractor(failure: PoseExtractionError.readerFailed("3D fixture failure"))
        let pipeline = ProcessingPipeline(store: store, pose3DExtractor: failed3D)
        let result = try await pipeline.poseData(
            for: video, session: session, config: TuningConfig(), progress: { _ in }
        )

        #expect(result.pose.count == pose.count)
        #expect(result.pose3D == nil)
        #expect(result.warnings.contains { $0.contains("analytical 2D results remain valid") })
        #expect(failed3D.calls == 1)
    }

    @Test("A complete analytical run succeeds when 3D extraction fails")
    func processSurvives3DFailure() async throws {
        let root = URL.temporaryDirectory.appendingPathComponent("VOTest-\(UUID().uuidString)")
        let store = SessionStore(root: root)
        defer { try? FileManager.default.removeItem(at: root) }
        let session = try await makeSession(store: store)
        let poseSpy = SpyExtractor(
            reference: SyntheticClimb.climb(moves: 4),
            attempt: SyntheticClimb.climb(moves: 4, speedFactor: 1.2)
        )
        let failed3D = SpyPose3DExtractor(failure: PoseExtractionError.readerFailed("3D fixture failure"))
        let pipeline = ProcessingPipeline(
            store: store,
            extractor: poseSpy,
            pose3DExtractor: failed3D,
            analysisProvider: TemplateAnalysisProvider()
        )

        let result = try await pipeline.process(session: session, config: TuningConfig())
        #expect(!result.referencePose.isEmpty)
        #expect(!result.attemptPose.isEmpty)
        #expect(result.referencePose3D == nil)
        #expect(result.attemptPose3D == nil)
        #expect(!result.sections.isEmpty)
        #expect(result.stages.first?.status == .degraded)
        #expect(result.warnings.contains { $0.contains("analytical 2D results remain valid") })
    }

    /// Task 4.10 — a deliberately broken session still renders something
    /// inspectable at every stage.
    @Test("A session whose videos cannot be decoded still produces output")
    func failsSoft() async throws {
        let root = URL.temporaryDirectory.appendingPathComponent("VOTest-\(UUID().uuidString)")
        let store = SessionStore(root: root)
        defer { try? FileManager.default.removeItem(at: root) }

        let session = try await makeSession(store: store)
        let spy = SpyExtractor(
            reference: SyntheticClimb.climb(moves: 4),
            attempt: SyntheticClimb.climb(moves: 4, speedFactor: 1.3)
        )
        let pipeline = ProcessingPipeline(store: store, extractor: spy)
        let result = try await pipeline.process(session: session, config: TuningConfig())

        // The video files are empty, so registration cannot run.
        let alignment = try #require(result.stages.first { $0.name == "Wall alignment" })
        #expect(alignment.status == .degraded)
        #expect(!alignment.warnings.isEmpty)

        // Everything downstream still produced something.
        #expect(!result.route.holds.isEmpty)
        #expect(!result.sections.isEmpty)
        #expect(result.analyses.count == result.sections.count)
        #expect(result.stages.count == ProcessingPipeline.stageCount)
        #expect(result.stages.allSatisfy { $0.seconds >= 0 })
        // And no stage silently swallowed its warnings.
        #expect(!result.warnings.isEmpty)
    }

    @Test("Progress reports every stage in order")
    func progressReporting() async throws {
        let root = URL.temporaryDirectory.appendingPathComponent("VOTest-\(UUID().uuidString)")
        let store = SessionStore(root: root)
        defer { try? FileManager.default.removeItem(at: root) }

        let session = try await makeSession(store: store)
        let spy = SpyExtractor(reference: SyntheticClimb.climb(moves: 3), attempt: SyntheticClimb.climb(moves: 3))
        let pipeline = ProcessingPipeline(store: store, extractor: spy)

        let recorder = ProgressRecorder()
        _ = try await pipeline.process(session: session, config: TuningConfig()) { p in
            recorder.record(p.stageIndex)
        }
        let indices = recorder.indices
        #expect(indices.first == 0)
        #expect(indices.max() == ProcessingPipeline.stageCount - 1)
        #expect(zip(indices, indices.dropFirst()).allSatisfy { $1 >= $0 }, "stage index went backwards")
    }

    @Test("A saved tuning config round-trips")
    func savedConfigs() async throws {
        let root = URL.temporaryDirectory.appendingPathComponent("VOTest-\(UUID().uuidString)")
        let store = SessionStore(root: root)
        defer { try? FileManager.default.removeItem(at: root) }

        var config = TuningConfig()
        config.contactDwellFrames = 11
        let named = NamedTuningConfig(name: "gym session 1", config: config)
        try await store.saveConfig(named)
        let loaded = await store.savedConfigs()
        #expect(loaded.count == 1)
        #expect(loaded[0].config.contactDwellFrames == 11)
    }
}

final class ProgressRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var _indices: [Int] = []
    var indices: [Int] { lock.withLock { _indices } }
    func record(_ i: Int) { lock.withLock { _indices.append(i) } }
}

@Suite("Golden metrics")
struct GoldenMetricsTests {

    /// Task 3.16 — frozen metric outputs. Drift fails CI.
    ///
    /// The values below were produced by this pipeline on the synthetic climb
    /// and are not independently verified physics — they are a change detector.
    /// If a deliberate change moves them, update the numbers **and say why in
    /// the commit**.
    @Test("Metrics on the synthetic climb have not drifted")
    func goldenValues() throws {
        let sequence = SyntheticClimb.climb(moves: 4, dwellFrames: 15, moveFrames: 6)
        let scale = ClimbScale(sequence: sequence)
        let config = TuningConfig()
        let contacts = ContactDetector().detect(sequence, scale: scale, config: config).contacts
        let route = RouteBuilder().build(contacts: contacts, scale: scale, config: config)
        let match = RouteMatcher().match(contacts: contacts, to: route, scale: scale, config: config)
        let segmentation = SectionSegmenter().segment(
            route: route, reference: match, attempt: match,
            referenceFrameCount: sequence.count, attemptFrameCount: sequence.count
        )
        let metrics = MetricsEngine().measure(sequence: sequence, contacts: contacts, scale: scale, config: config)

        // Structural golden values.
        #expect(sequence.count == 99)
        #expect(abs(scale.torsoLength - 0.12) < 0.005, "torso \(scale.torsoLength)")
        #expect(contacts.count == 12, "contacts \(contacts.count)")
        #expect(route.holds.count == 9, "holds \(route.holds.count)")
        #expect(segmentation.sections.count == 5, "sections \(segmentation.sections.count)")

        // Whole-climb COM travel, which is non-zero and therefore a real drift
        // detector — a single section of this fixture is mostly a dwell.
        var wholeClimbPath = 0.0
        var previous: Point2D?
        for f in metrics.frames {
            guard let com = f.com else { continue }
            if let p = previous { wholeClimbPath += scale.distance(p, com) }
            previous = com
        }
        #expect(abs(wholeClimbPath - 1.000) < 0.02, "whole-climb COM path \(wholeClimbPath)")

        guard let section = segmentation.sections.first else { return }
        let sectionMetrics = MetricsEngine().sectionMetrics(
            section: section, range: section.referenceRange, metrics: metrics,
            sequence: sequence, contacts: contacts, targetHold: section.toHold, config: config
        )

        func check(_ kind: MetricKind, _ expected: Double, tolerance: Double) {
            guard let value = sectionMetrics[kind].value else {
                Issue.record("\(kind.rawValue) unavailable — it was available when the golden values were frozen")
                return
            }
            #expect(abs(value - expected) < tolerance, "\(kind.rawValue) = \(value), frozen at \(expected)")
        }
        check(.hipDistanceMean, 1.0704, tolerance: 0.02)
        check(.hipDistancePeak, 1.0704, tolerance: 0.02)
        check(.armLoadShare, 0.6398, tolerance: 0.01)
        check(.armLoadPeak, 0.6398, tolerance: 0.01)
        check(.unweightedFootTime, 0.0, tolerance: 0.01)
        check(.straightArmRatio, 1.0, tolerance: 0.02)
        check(.comPathLength, 0.0, tolerance: 0.01)
        check(.loadAsymmetry, 0.0, tolerance: 0.005)
        check(.footPlacementCount, 2.0, tolerance: 0.01)
        check(.hipTwist, 0.0, tolerance: 0.5)
        check(.reachMargin, 1.1310, tolerance: 0.02)
    }
}

@Suite("Pose source")
struct PoseSourceTests {

    func makeSession(store: SessionStore) async throws -> ClimbSession {
        var session = try await store.create(name: "source test")
        let videos = await store.directory(for: session.id).appendingPathComponent("videos")
        try FileManager.default.createDirectory(at: videos, withIntermediateDirectories: true)
        let reference = VideoRef(filename: "ref.mov", role: .reference, label: "Reference")
        let attempt = VideoRef(filename: "att.mov", role: .attempt, label: "Attempt 1")
        try Data().write(to: videos.appendingPathComponent(reference.filename))
        try Data().write(to: videos.appendingPathComponent(attempt.filename))
        session.reference = reference
        session.attempts = [attempt]
        try await store.save(session)
        return session
    }

    /// Both the cache-keying trap and the loud-failure test needed a *second*
    /// `PoseSource` to exercise. RTMPose was removed, so they are gone with it —
    /// the guarantees still hold in `SessionStore.poseURL` and
    /// `UnavailablePoseExtractor`, and these tests come back the moment a second
    /// source does.

    @Test("A session saved before pose sources existed still decodes")
    func decodesLegacySession() throws {
        // Exactly what old sessions on disk look like: no poseSource key.
        let json = """
        {"id":"\(UUID().uuidString)","createdAt":760000000,"name":"old",
         "attempts":[],"config":\(String(data: try JSONEncoder().encode(TuningConfig()), encoding: .utf8)!)}
        """
        let session = try JSONDecoder().decode(ClimbSession.self, from: Data(json.utf8))
        #expect(session.poseSource == .vision)
        #expect(session.name == "old")
    }

    @Test("Pose source is not a TuningConfig field")
    func poseSourceIsNotTuning() {
        // Every TuningConfig field obeys "changing this re-runs from contact
        // detection and never re-extracts". Pose source must re-extract, so it
        // belongs to the session. This asserts nobody moves it later.
        let encoded = try! JSONEncoder().encode(TuningConfig())
        let text = String(data: encoded, encoding: .utf8)!
        #expect(!text.contains("poseSource"))
        #expect(!TuningConfig.fields.contains { $0.label.lowercased().contains("pose model") })
    }
}
