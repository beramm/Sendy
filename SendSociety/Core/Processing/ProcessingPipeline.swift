import Foundation
import CoreGraphics

public enum StageStatus: String, Sendable, Codable {
    case ok
    /// Produced something usable, with a caveat the user must see.
    case degraded
    /// Produced nothing usable. The pipeline continues with a substitute so the
    /// screen is never blank.
    case failed
    case skipped
}

public struct StageReport: Sendable, Codable, Hashable, Identifiable {
    public var name: String
    public var seconds: Double
    public var status: StageStatus
    public var detail: String
    public var warnings: [String]

    public var id: String { name }

    public init(name: String, seconds: Double, status: StageStatus, detail: String = "", warnings: [String] = []) {
        self.name = name
        self.seconds = seconds
        self.status = status
        self.detail = detail
        self.warnings = warnings
    }
}

/// Everything a results screen needs. Produced once; switching comparison modes
/// must not re-run any of it.
public struct ProcessedSession: Sendable, Codable {
    public var session: ClimbSession
    public var attemptIndex: Int
    public var config: TuningConfig

    /// Both in wall space.
    public var referencePose: PoseSequence
    public var attemptPose: PoseSequence
    /// Camera-relative data for visualization only. It never enters analysis.
    public var referenceScale: ClimbScale
    public var attemptScale: ClimbScale
    public var referenceContacts: [Contact]
    public var attemptContacts: [Contact]
    public var route: Route
    public var sections: [Section]
    /// Sequences: the span between two holds **both** climbers took with a
    /// hand, holding however many moves each of them needed to cross it.
    ///
    /// The unit of comparison, where `sections` is the unit of measurement. A
    /// sequence is allowed to contain three of one climber's moves against one
    /// of the other's — that difference is a finding, not a mismatch to
    /// suppress.
    public var sequences: SequenceResult
    public var warpPaths: [WarpPath]
    /// Warping paths anchored at **sequence** boundaries — what locked
    /// playback uses. `warpPaths` above is move-anchored and is what per-move
    /// metrics align against.
    public var sequenceWarpPaths: [WarpPath]
    public var referenceMetrics: ClimbMetrics
    public var attemptMetrics: ClimbMetrics
    public var referenceSectionMetrics: [SectionMetrics]
    public var attemptSectionMetrics: [SectionMetrics]
    public var deltas: [SectionDelta]
    /// Direct anchor-to-anchor measurements. Unlike move deltas, these remain
    /// comparable when the climbers use different moves between shared anchors.
    public var sequenceDeltas: [SectionDelta]
    /// Detailed move-level output retained for provider compatibility and
    /// instrumentation. The Results UI does not present this array.
    public var analyses: [SectionAnalysis]
    /// One Results container per comparison sequence, including the paired
    /// REF/YOU wording for one shared main difference and comparison detail.
    public var sequenceAnalyses: [SequenceAnalysis]
    public var fallReport: FallReport
    public var fallAnalysis: SectionAnalysis?
    public var alignment: AlignmentResult
    /// The wall with the climber removed, derived from the reference clip.
    ///
    /// **A backdrop, never evidence.** Nothing in `MetricsEngine`,
    /// `RouteBuilder` or `ContactDetector` may read it. Nil when it could not
    /// be built, in which case the skeleton view keeps its plain background and
    /// the stage report says why.
    public var wallPlate: WallPlate? = nil
    public var stages: [StageReport]

    /// `WallPlate` wraps a `CGImage`, so the image itself remains in the
    /// existing PNG cache. Everything else is Codable and is saved as the
    /// completed result, including the Foundation Models prose. Loading a
    /// saved climb restores the PNG separately and never invokes the provider.
    enum CodingKeys: String, CodingKey {
        case session
        case attemptIndex
        case config
        case referencePose
        case attemptPose
        case referenceScale
        case attemptScale
        case referenceContacts
        case attemptContacts
        case route
        case sections
        case sequences
        case warpPaths
        case sequenceWarpPaths
        case referenceMetrics
        case attemptMetrics
        case referenceSectionMetrics
        case attemptSectionMetrics
        case deltas
        case sequenceDeltas
        case analyses
        case sequenceAnalyses
        case fallReport
        case fallAnalysis
        case alignment
        case stages
    }

    /// Every warning from every stage, in pipeline order. The results screen
    /// shows these; none are swallowed.
    public var warnings: [String] { stages.flatMap(\.warnings) }

    public var attempt: VideoRef? {
        session.attempts.indices.contains(attemptIndex) ? session.attempts[attemptIndex] : nil
    }

    public func warpPath(forSection index: Int) -> WarpPath? {
        warpPaths.first { $0.sectionIndex == index }
    }

    public func analysis(forSection index: Int) -> SectionAnalysis? {
        analyses.first { $0.sectionIndex == index }
    }

    public func analysis(forSequence index: Int) -> SequenceAnalysis? {
        sequenceAnalyses.first { $0.sequenceIndex == index }
    }

    public func delta(forSequence index: Int) -> SectionDelta? {
        sequenceDeltas.first { $0.sectionIndex == index }
    }
}

public struct ProcessingProgress: Sendable {
    public var stageName: String
    public var stageIndex: Int
    public var stageCount: Int
    public var fraction: Double

    public init(stageName: String, stageIndex: Int, stageCount: Int, fraction: Double) {
        self.stageName = stageName
        self.stageIndex = stageIndex
        self.stageCount = stageCount
        self.fraction = fraction
    }
}

public enum ProcessingError: Error, LocalizedError {
    case noReference
    case noAttempt
    case cancelled

    public var errorDescription: String? {
        switch self {
        case .noReference: "This session has no reference climb."
        case .noAttempt: "This session has no attempt to compare."
        case .cancelled: "Processing cancelled."
        }
    }
}

/// Runs the stages in order and produces a `ProcessedSession`.
///
/// Two rules shape this type:
///
/// 1. **Pose extraction never re-runs** when a cached sequence exists. Changing
///    a threshold re-runs from `ContactDetector` onward, which is the
///    difference between a 2-second and a 90-second feedback loop.
/// 2. **Fail soft.** A stage that cannot produce a good result produces a
///    degraded one and a visible warning. No stage throws except on genuinely
///    missing inputs.
public actor ProcessingPipeline {
    public static let stageCount = 10

    let store: SessionStore
    /// Overrides the session's `poseSource` when set. Tests inject a spy here;
    /// the app leaves it nil and lets the session decide.
    let extractorOverride: (any PoseExtractor)?
    let analysisProvider: any AnalysisProvider

    public init(
        store: SessionStore,
        extractor: (any PoseExtractor)? = nil,
        analysisProvider: any AnalysisProvider = TemplateAnalysisProvider()
    ) {
        self.store = store
        self.extractorOverride = extractor
        self.analysisProvider = analysisProvider
    }

    public func process(
        session: ClimbSession,
        attemptIndex: Int = 0,
        config: TuningConfig,
        progress: @Sendable @escaping (ProcessingProgress) -> Void = { _ in }
    ) async throws -> ProcessedSession {
        guard let referenceRef = session.reference else { throw ProcessingError.noReference }
        guard session.attempts.indices.contains(attemptIndex) else { throw ProcessingError.noAttempt }
        let attemptRef = session.attempts[attemptIndex]

        var stages: [StageReport] = []
        var stageIndex = 0
        func report(_ name: String, _ start: Date, _ status: StageStatus, _ detail: String = "", _ warnings: [String] = []) {
            stages.append(StageReport(name: name, seconds: Date().timeIntervalSince(start), status: status, detail: detail, warnings: warnings))
        }
        func announce(_ name: String, _ fraction: Double) {
            progress(ProcessingProgress(stageName: name, stageIndex: stageIndex, stageCount: Self.stageCount, fraction: fraction))
        }

        // MARK: 1. Pose (cached)

        stageIndex = 0
        var t = Date()
        announce("Pose — reference", 0)
        let referenceData = try await poseData(for: referenceRef, session: session, config: config) { p in
            progress(ProcessingProgress(stageName: "Pose — reference", stageIndex: 0, stageCount: Self.stageCount, fraction: p * 0.5))
        }
        announce("Pose — attempt", 0.5)
        let attemptData = try await poseData(for: attemptRef, session: session, config: config) { p in
            progress(ProcessingProgress(stageName: "Pose — attempt", stageIndex: 0, stageCount: Self.stageCount, fraction: 0.5 + p * 0.5))
        }
        let rawReference = referenceData.pose
        let rawAttempt = attemptData.pose
        let sourceName = session.poseSource.displayName
        let cacheDetail = "\(sourceName) — Reference: \(referenceData.detail); Attempt: \(attemptData.detail)"
        report(
            "Pose extraction", t,
            rawReference.isEmpty || rawAttempt.isEmpty ? .failed : .ok,
            cacheDetail,
            rawReference.warnings + rawAttempt.warnings
                + referenceData.warnings + attemptData.warnings
        )

        try checkCancelled()

        // MARK: 2. Smoothing

        stageIndex = 1
        t = Date()
        announce("Smoothing", 0)
        let smoother = PoseSmoother()
        let smoothedReference = smoother.process(rawReference, config: config)
        let smoothedAttempt = smoother.process(rawAttempt, config: config)
        report("Smoothing", t, .ok, "1€ filter, per joint", [])

        try checkCancelled()

        // MARK: 3. Wall alignment

        stageIndex = 2
        t = Date()
        announce("Wall alignment", 0)
        let alignment = await align(
            session: session,
            referenceRef: referenceRef, attemptRef: attemptRef,
            referencePose: smoothedReference, attemptPose: smoothedAttempt,
            config: config
        )
        report(
            "Wall alignment", t,
            alignment.succeeded ? .ok : .degraded,
            alignment.residual.isFinite ? String(format: "residual %.4f wall-widths", alignment.residual) : "residual unknown",
            alignment.warnings
        )

        // Wall space is defined as the reference video's image space, so the
        // reference passes through and only the attempt is warped.
        var referencePose = smoothedReference
        referencePose.space = .wall
        let attemptPose = smoothedAttempt.warpedIntoWallSpace(by: alignment.homography)

        try checkCancelled()

        // MARK: 4. Wall backdrop

        // Built from the reference clip, because wall space *is* the reference
        // clip's image space — a plate from it needs no homography to sit under
        // the skeleton canvas. It runs off the pose that is already in hand, so
        // it never touches Vision, and it feeds nothing downstream: no metric,
        // no hold, no contact may read it.
        stageIndex = 3
        t = Date()
        announce("Wall backdrop", 0)
        let plateResult = await plate(
            for: referenceRef, session: session, pose: smoothedReference, config: config
        )
        report(
            "Wall backdrop", t,
            plateResult.plate == nil
                ? .failed
                : (plateResult.warnings.isEmpty ? .ok : .degraded),
            plateResult.plate.map { p in
                String(
                    format: "%.1f%% of the wall recovered from %d frames%@",
                    p.coverage * 100, p.sampleCount, plateResult.fromCache ? ", from cache" : ""
                )
            } ?? "no backdrop; the skeleton view uses a plain background",
            plateResult.warnings
        )

        try checkCancelled()

        // MARK: 5. Contacts

        stageIndex = 4
        t = Date()
        announce("Contacts", 0)
        let referenceScale = ClimbScale(sequence: referencePose)
        let attemptScale = ClimbScale(sequence: attemptPose)
        let detector = ContactDetector()
        let referenceContactResult = detector.detect(referencePose, scale: referenceScale, config: config)
        let attemptContactResult = detector.detect(attemptPose, scale: attemptScale, config: config)
        report(
            "Contacts", t,
            referenceContactResult.contacts.isEmpty ? .failed : .ok,
            "\(referenceContactResult.contacts.count) reference, \(attemptContactResult.contacts.count) attempt",
            referenceContactResult.warnings + attemptContactResult.warnings
        )

        try checkCancelled()

        // MARK: 6. Route

        stageIndex = 5
        t = Date()
        announce("Route", 0)
        let derivedRoute = RouteBuilder().build(contacts: referenceContactResult.contacts, scale: referenceScale, config: config)
        // A hand-corrected route wins over a derived one, and survives
        // reprocessing with different thresholds.
        let route = session.manualRouteOverride ?? derivedRoute
        report(
            "Route", t,
            route.holds.isEmpty ? .failed : (route.warnings.isEmpty ? .ok : .degraded),
            "\(route.holds.count) holds, \(route.handHolds.count) hand holds\(session.manualRouteOverride != nil ? " (hand-corrected)" : "")",
            route.warnings
        )

        // MARK: 7. Matching and segmentation

        stageIndex = 6
        t = Date()
        announce("Moves", 0)
        let matcher = RouteMatcher()
        let referenceMatch = matcher.match(contacts: referenceContactResult.contacts, to: route, scale: referenceScale, config: config)
        let attemptMatch = matcher.match(contacts: attemptContactResult.contacts, to: route, scale: referenceScale, config: config)
        let segmentation = SectionSegmenter().segment(
            route: route,
            reference: referenceMatch,
            attempt: attemptMatch,
            referenceFrameCount: referencePose.count,
            attemptFrameCount: attemptPose.count,
            scale: referenceScale,
            config: config
        )
        let sections = segmentation.sections

        // Sequences — the only stage that sees both climbs. Built from each
        // climber's own hand acquisitions, so neither beta is derived from the
        // other, and anchored only on holds both of them actually took.
        let sequenceResult = SequenceBuilder().build(
            route: route,
            // The segmenter's trimmed list, not the raw one, so sequence move
            // indices line up with `sections` exactly.
            referenceAcquisitions: segmentation.referenceAcquisitions.map { ($0.frame, $0.holdID) },
            attemptAcquisitions: attemptMatch.handAcquisitions,
            referenceFrameCount: referencePose.count,
            attemptFrameCount: attemptPose.count,
            config: config
        )
        report(
            "Moves", t,
            sections.isEmpty ? .failed : (segmentation.warnings.isEmpty ? .ok : .degraded),
            "\(sections.count) moves",
            attemptMatch.warnings + segmentation.warnings
        )

        try checkCancelled()

        // MARK: 8. Time alignment

        stageIndex = 7
        t = Date()
        announce("Time alignment", 0)
        let referenceContactStates = TimeAligner.contactStates(contacts: referenceContactResult.contacts, frameCount: referencePose.count)
        let attemptContactStates = TimeAligner.contactStates(contacts: attemptContactResult.contacts, frameCount: attemptPose.count)
        let aligner = TimeAligner()
        var warpPaths: [WarpPath] = []
        for (i, section) in sections.enumerated() {
            announce("Time alignment", Double(i) / Double(max(1, sections.count)))
            warpPaths.append(aligner.align(
                section: section,
                reference: referencePose, attempt: attemptPose,
                referenceScale: referenceScale, attemptScale: attemptScale,
                referenceContacts: referenceContactStates, attemptContacts: attemptContactStates
            ))
            try checkCancelled()
        }
        // **Playback anchors at sequences, not at moves.**
        //
        // A move-anchored path pins attempt move n to reference move n, which
        // is only valid when the two climbers made the same moves. Where they
        // did not, DTW cannot spread the mismatch and dumps it at one point in
        // the path — seen as the climber teleporting mid-scrub. Sequence
        // boundaries are the only frames where both are provably in the same
        // place, and inside one DTW is free to map three moves onto one.
        //
        // The move-level paths above stay: metrics are measured per move, and
        // that is what they align.
        var sequenceWarpPaths: [WarpPath] = []
        for sequence in sequenceResult.sequences {
            sequenceWarpPaths.append(aligner.align(
                index: sequence.index,
                referenceRange: sequence.referenceRange, attemptRange: sequence.attemptRange,
                reference: referencePose, attempt: attemptPose,
                referenceScale: referenceScale, attemptScale: attemptScale,
                referenceContacts: referenceContactStates, attemptContacts: attemptContactStates
            ))
            try checkCancelled()
        }

        let unaligned = warpPaths.filter(\.isEmpty).count
        report(
            "Time alignment", t,
            warpPaths.isEmpty ? .skipped : (unaligned > 0 ? .degraded : .ok),
            "\(warpPaths.count - unaligned) of \(warpPaths.count) moves aligned",
            unaligned > 0 ? ["\(unaligned) moves could not be time-aligned because the attempt has no frames there."] : []
        )

        // MARK: 9. Metrics

        stageIndex = 8
        t = Date()
        announce("Metrics", 0)
        let engine = MetricsEngine()
        let referenceMetrics = engine.measure(sequence: referencePose, contacts: referenceContactResult.contacts, scale: referenceScale, config: config)
        let attemptMetrics = engine.measure(sequence: attemptPose, contacts: attemptContactResult.contacts, scale: attemptScale, config: config)

        var referenceSectionMetrics: [SectionMetrics] = []
        var attemptSectionMetrics: [SectionMetrics] = []
        var deltas: [SectionDelta] = []
        for section in sections {
            let r = engine.sectionMetrics(
                section: section, range: section.referenceRange, metrics: referenceMetrics,
                sequence: referencePose, contacts: referenceContactResult.contacts,
                targetHold: section.toHold, config: config
            )
            let a = section.attemptReached ? engine.sectionMetrics(
                section: section, range: section.attemptRange, metrics: attemptMetrics,
                sequence: attemptPose, contacts: attemptContactResult.contacts,
                targetHold: section.toHold, config: config
            ) : nil
            referenceSectionMetrics.append(r)
            if let a { attemptSectionMetrics.append(a) }
            deltas.append(engine.delta(
                section: section, reference: r, attempt: a,
                alignmentCost: warpPaths.first { $0.sectionIndex == section.index }?.meanCost
            ))
        }

        // Measure complete anchor-to-anchor spans as Results analytics' source
        // of truth. The move deltas above cannot fairly compare a
        // reference move with a different attempt move, but a sequence whose
        // endpoints are shared anchors remains comparable as a whole.
        var sequenceDeltas: [SectionDelta] = []
        for climbSequence in sequenceResult.sequences {
            guard climbSequence.fromAnchorID >= 0,
                  climbSequence.toAnchorID >= 0,
                  climbSequence.fromAnchorID != climbSequence.toAnchorID,
                  climbSequence.attemptReached,
                  let targetHold = route.hold(id: climbSequence.toAnchorID)
            else { continue }

            let reference = engine.sequenceMetrics(
                climbSequence: climbSequence,
                range: climbSequence.referenceRange,
                metrics: referenceMetrics,
                poseSequence: referencePose,
                contacts: referenceContactResult.contacts,
                targetHold: targetHold,
                config: config
            )
            let attempt = engine.sequenceMetrics(
                climbSequence: climbSequence,
                range: climbSequence.attemptRange,
                metrics: attemptMetrics,
                poseSequence: attemptPose,
                contacts: attemptContactResult.contacts,
                targetHold: targetHold,
                config: config
            )
            sequenceDeltas.append(engine.delta(
                climbSequence: climbSequence,
                reference: reference,
                attempt: attempt,
                alignmentCost: sequenceWarpPaths.first { $0.sectionIndex == climbSequence.index }?.meanCost
            ))
        }
        report(
            "Metrics", t, .ok,
            "\(deltas.count) moves, \(sequenceDeltas.count) comparable sequences measured",
            referenceMetrics.warnings + attemptMetrics.warnings
        )

        try checkCancelled()

        // MARK: 10. Falls and analysis

        stageIndex = 9
        t = Date()
        announce("Analysis", 0)
        var fallReport = FallDetector().detect(
            metrics: attemptMetrics, sections: sections, useAttemptRange: true,
            config: config, contacts: attemptContactResult.contacts
        )
        fallReport = FallAnalyzer().analyze(
            report: fallReport, metrics: attemptMetrics, sections: sections,
            sectionMetrics: attemptSectionMetrics, deltas: deltas,
            contacts: attemptContactResult.contacts, config: config
        )

        // A reference climb that contains a fall is not a valid reference.
        var referenceWarnings: [String] = []
        let referenceFall = FallDetector().detect(
            metrics: referenceMetrics, sections: sections, useAttemptRange: false,
            config: config, contacts: referenceContactResult.contacts
        )
        if referenceFall.occurred {
            referenceWarnings.append("The reference climb appears to contain a fall. A fallen climb is not a valid reference — the derived route may be incomplete.")
        }

        var analyses: [SectionAnalysis] = []
        for (i, delta) in deltas.enumerated() {
            announce("Analysis", Double(i) / Double(max(1, deltas.count)))
            if let analysis = try? await analysisProvider.analyze(delta) {
                analyses.append(analysis)
            } else {
                analyses.append(SectionAnalysis(
                    sectionIndex: delta.sectionIndex,
                    headline: "\(delta.sectionName): analysis unavailable",
                    observations: [AnalysisNote(
                        text: "The analysis provider failed on this move. The measured numbers are still in the raw metrics view.",
                        evidence: "Provider \(analysisProvider.name) threw for section \(delta.sectionIndex)."
                    )],
                    drill: nil,
                    source: analysisProvider.name,
                    warnings: ["Analysis provider failed for move \(delta.sectionIndex + 1)."]
                ))
            }
        }
        let fallAnalysis = try? await analysisProvider.analyzeFall(fallReport, sections: deltas)
        let sequenceComposer = SequenceAnalysisComposer(config: config)
        let sequenceAnalyses = sequenceResult.sequences.map { sequence in
            sequenceComposer.compose(
                sequence: sequence,
                sectionDeltas: deltas,
                sequenceDelta: sequenceDeltas.first { $0.sectionIndex == sequence.index },
                fallReport: fallReport,
                fallAnalysis: fallAnalysis
            )
        }
        report(
            "Analysis", t, .ok,
            "\(analyses.count) moves, \(sequenceAnalyses.count) sequences, \(fallReport.occurred ? "fall detected" : "no fall")",
            fallReport.warnings + referenceWarnings
        )

        return ProcessedSession(
            session: session,
            attemptIndex: attemptIndex,
            config: config,
            referencePose: referencePose,
            attemptPose: attemptPose,
            referenceScale: referenceScale,
            attemptScale: attemptScale,
            referenceContacts: referenceContactResult.contacts,
            attemptContacts: attemptContactResult.contacts,
            route: route,
            sections: sections,
            sequences: sequenceResult,
            warpPaths: warpPaths,
            sequenceWarpPaths: sequenceWarpPaths,
            referenceMetrics: referenceMetrics,
            attemptMetrics: attemptMetrics,
            referenceSectionMetrics: referenceSectionMetrics,
            attemptSectionMetrics: attemptSectionMetrics,
            deltas: deltas,
            sequenceDeltas: sequenceDeltas,
            analyses: analyses,
            sequenceAnalyses: sequenceAnalyses,
            fallReport: fallReport,
            fallAnalysis: fallAnalysis,
            alignment: alignment,
            wallPlate: plateResult.plate,
            stages: stages
        )
    }

    // MARK: Helpers

    struct PoseDataResult: Sendable {
        var pose: PoseSequence
        var poseFromCache: Bool
        var warnings: [String]

        var detail: String { poseFromCache ? "cached" : "extracted" }
    }

    func checkCancelled() throws {
        if Task.isCancelled { throw ProcessingError.cancelled }
    }

    func poseData(
        for video: VideoRef,
        session: ClimbSession,
        config: TuningConfig,
        progress: @Sendable @escaping (Double) -> Void
    ) async throws -> PoseDataResult {
        let source = session.poseSource
        if let cached = await store.cachedPose(session: session, video: video, source: source) {
            progress(1)
            return PoseDataResult(pose: cached, poseFromCache: true, warnings: [])
        }
        let url = await store.videoURL(session: session, video: video)
        let extractor = extractorOverride ?? PoseExtractorFactory.make(source)
        let pose = try await extractor.extract(url: url, config: config, progress: progress)
        try? await store.cachePose(pose, session: session, video: video, source: source)
        progress(1)
        return PoseDataResult(pose: pose, poseFromCache: false, warnings: [])
    }

    /// Returns the pose sequence and whether it came from the cache.
    ///
    /// **This is the guarantee that reprocessing never re-runs Vision.** If it
    /// ever starts extracting on a cached video, `PoseCacheTests` fails.
    func pose(
        for video: VideoRef,
        session: ClimbSession,
        config: TuningConfig,
        progress: @Sendable @escaping (Double) -> Void
    ) async throws -> (PoseSequence, Bool) {
        let source = session.poseSource
        if let cached = await store.cachedPose(session: session, video: video, source: source) {
            progress(1)
            return (cached, true)
        }
        let url = await store.videoURL(session: session, video: video)
        let extractor = extractorOverride ?? PoseExtractorFactory.make(source)
        let sequence = try await extractor.extract(url: url, config: config, progress: progress)
        try? await store.cachePose(sequence, session: session, video: video, source: source)
        return (sequence, false)
    }

    /// The wall backdrop, from cache when one exists for these plate settings.
    ///
    /// Cached like pose, and for the same reason: reprocessing on a changed
    /// threshold is the tuning loop, and a decode pass over sixteen frames on
    /// every pass makes that loop slower for a picture that did not change.
    func plate(
        for video: VideoRef,
        session: ClimbSession,
        pose: PoseSequence,
        config: TuningConfig
    ) async -> (plate: WallPlate?, warnings: [String], fromCache: Bool) {
        if let cached = await store.cachedPlate(session: session, video: video, config: config) {
            return (cached, cached.warnings, true)
        }
        let url = await store.videoURL(session: session, video: video)
        let result = await WallPlateBuilder().build(url: url, pose: pose, config: config)
        if let plate = result.plate {
            try? await store.cachePlate(plate, session: session, video: video, config: config)
        }
        return (result.plate, result.warnings, false)
    }

    func align(
        session: ClimbSession,
        referenceRef: VideoRef,
        attemptRef: VideoRef,
        referencePose: PoseSequence,
        attemptPose: PoseSequence,
        config: TuningConfig
    ) async -> AlignmentResult {
        let referenceIndex = WallAligner.registrationFrameIndex(for: referencePose)
        let attemptIndex = WallAligner.registrationFrameIndex(for: attemptPose)
        guard let referenceFrame = referencePose.frame(at: referenceIndex),
              let attemptFrame = attemptPose.frame(at: attemptIndex) else {
            return .failed("No frames available to register the two clips; comparing them unaligned.")
        }
        let referenceURL = await store.videoURL(session: session, video: referenceRef)
        let attemptURL = await store.videoURL(session: session, video: attemptRef)
        do {
            let referenceImage = try await VideoFrameSource(url: referenceURL).image(atSeconds: referenceFrame.timeSeconds)
            let attemptImage = try await VideoFrameSource(url: attemptURL).image(atSeconds: attemptFrame.timeSeconds)
            return WallAligner().align(
                reference: referenceImage,
                attempt: attemptImage,
                referenceMask: referencePose.climberBounds(atFrame: referenceIndex),
                attemptMask: attemptPose.climberBounds(atFrame: attemptIndex),
                referenceFrameIndex: referenceIndex,
                attemptFrameIndex: attemptIndex,
                config: config
            )
        } catch {
            return .failed("Could not read a frame for registration (\(error.localizedDescription)); comparing the clips unaligned.")
        }
    }
}
