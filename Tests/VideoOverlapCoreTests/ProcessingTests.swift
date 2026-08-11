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

@Suite("Processing")
struct ProcessingTests {

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

    /// Task 8.0 — the trap. Without the source in the cache key, switching pose
    /// model reads the *other* model's cached pose, so you compare a tracker
    /// against itself, see no difference, and conclude the models are
    /// equivalent. The "reprocessing never re-extracts" guarantee makes the
    /// stale read the designed behaviour rather than an obvious bug.
    @Test("Switching pose source does not read the other source's cache")
    func cacheIsKeyedBySource() async throws {
        let root = URL.temporaryDirectory.appendingPathComponent("VOSrc-\(UUID().uuidString)")
        let store = SessionStore(root: root)
        defer { try? FileManager.default.removeItem(at: root) }

        var session = try await makeSession(store: store)
        let reference = try #require(session.reference)

        // Two obviously different sequences, one per source.
        let visionPose = SyntheticClimb.climb(moves: 4)
        let otherPose = SyntheticClimb.climb(moves: 2)
        #expect(visionPose.count != otherPose.count)

        try await store.cachePose(visionPose, session: session, video: reference, source: .vision)
        try await store.cachePose(otherPose, session: session, video: reference, source: .rtmPose)

        let readVision = await store.cachedPose(session: session, video: reference, source: .vision)
        let readOther = await store.cachedPose(session: session, video: reference, source: .rtmPose)
        #expect(readVision?.count == visionPose.count)
        #expect(readOther?.count == otherPose.count)
        #expect(readVision?.count != readOther?.count, "the two sources returned the same pose")

        // A source with nothing cached must miss, not fall back to the other.
        session.poseSource = .rtmPose
        let attempt = try #require(session.attempts.first)
        #expect(await store.cachedPose(session: session, video: attempt, source: .rtmPose) == nil)
        #expect(await store.hasCachedPose(session: session, video: attempt, source: .rtmPose) == false)
    }

    /// The pipeline must pick its extractor from the session, and an
    /// unavailable model must fail with its own reason rather than silently
    /// running Vision — a silent fallback produces a "comparison" in which both
    /// sides are the same model.
    @Test("An unavailable pose source fails loudly instead of falling back")
    func unavailableSourceFailsLoudly() async throws {
        let root = URL.temporaryDirectory.appendingPathComponent("VOSrc-\(UUID().uuidString)")
        let store = SessionStore(root: root)
        defer { try? FileManager.default.removeItem(at: root) }

        var session = try await makeSession(store: store)
        session.poseSource = .rtmPose
        try await store.save(session)

        #expect(PoseExtractorFactory.isAvailable(.vision))
        #expect(!PoseExtractorFactory.isAvailable(.rtmPose), "flip this when the model is bundled")

        // No extractor override, so the pipeline resolves one from the session.
        let pipeline = ProcessingPipeline(store: store)
        await #expect(throws: PoseExtractionError.self) {
            _ = try await pipeline.process(session: session, config: TuningConfig())
        }
    }

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
