import Foundation
#if canImport(FoundationModels)
import FoundationModels
#endif

/// Times the two Foundation Models calls the Results screen depends on, on the
/// device that will actually run them.
///
/// This exists because iteration 12 sizes a background queue against a number
/// nobody had measured. Run it with `--measure-model`; it prints to stdout and
/// exits, so `devicectl device process launch --console` is the whole harness.
/// Debug scaffolding, and it never runs in the ordinary launch path.
enum ModelLatencyBenchmark {
    static var isRequested: Bool {
        ProcessInfo.processInfo.arguments.contains("--measure-model")
    }

    /// Prints what the Results screen would actually show, for every sequence
    /// of every saved climb on this phone, plus a run of the on-device model
    /// over the states that are hard to catch on real footage.
    ///
    /// The Simulator can run neither Vision nor Foundation Models, so this is
    /// the only way to check the generated copy without standing at a wall.
    static var verificationRequested: Bool {
        ProcessInfo.processInfo.arguments.contains("--verify-narration")
    }

    /// Builds a saved climb from fixture clips pushed into `Documents/seed`,
    /// so the Results screen can be checked on a phone without a trip to a
    /// gym. Pose is seeded from the JSON pulled off a real device, so Vision
    /// never re-runs and the result is byte-for-byte the one the gym produced.
    static var seedRequested: Bool {
        ProcessInfo.processInfo.arguments.contains("--seed-session")
    }

    /// A sequence with a clear, ordinary arm-load-from-hip-position finding —
    /// the shape most prompts will have. Built by hand rather than from a clip
    /// so the measurement is of the model, not of Vision.
    static func sampleRequest(index: Int = 3) -> SequenceNarrationRequest {
        SequenceNarrationRequest(
            sequenceIndex: index,
            kind: .coaching,
            referenceHeadline: "Less weight on arms",
            attemptHeadline: "More weight on arms",
            referenceSentence: "The other climber kept more weight off the arms because they stayed closer to the wall.",
            attemptSentence: "You put more weight through the arms because you stayed farther from the wall.",
            measurements: [
                MeasurementBrief(
                    name: MetricKind.armLoadShare.displayName,
                    meaning: MetricKind.armLoadShare.plainMeaning,
                    referencePhrase: "kept more weight off the arms",
                    attemptPhrase: "put more weight through the arms"
                ),
                MeasurementBrief(
                    name: MetricKind.hipDistanceMean.displayName,
                    meaning: MetricKind.hipDistanceMean.plainMeaning,
                    referencePhrase: "stayed closer to the wall",
                    attemptPhrase: "stayed farther from the wall"
                ),
                MeasurementBrief(
                    name: MetricKind.straightArmRatio.displayName,
                    meaning: MetricKind.straightArmRatio.plainMeaning,
                    referencePhrase: "used straighter arms",
                    attemptPhrase: "climbed with more bent arms"
                ),
                MeasurementBrief(
                    name: MetricKind.footPlacementCount.displayName,
                    meaning: MetricKind.footPlacementCount.plainMeaning,
                    referencePhrase: "used fewer foot placements",
                    attemptPhrase: "used more foot placements"
                )
            ],
            metricKinds: [.armLoadShare, .hipDistanceMean],
            comparisonIsValid: true,
            attemptIsWorse: true
        )
    }

    /// The move-level delta the pipeline already sends the model, once per
    /// move, on every run today. Included because iteration 12's cost has to
    /// be read against a bill the app is already paying, not against zero.
    static func sampleDelta(index: Int = 3) -> SectionDelta {
        SectionDelta(
            sectionIndex: index,
            sectionName: "Move \(index + 1)",
            deltas: [
                MetricDelta(kind: .armLoadShare, reference: 0.30, attempt: 0.82, confidence: 1),
                MetricDelta(kind: .hipDistanceMean, reference: 0.20, attempt: 0.78, confidence: 1)
            ],
            divergence: nil,
            attemptReached: true,
            alignmentCost: 0.2
        )
    }

    static func run() async {
        func emit(_ line: String) {
            print("BENCH|\(line)")
            fflush(stdout)
        }

        emit("device=\(deviceDescription())")

        #if canImport(FoundationModels)
        guard #available(iOS 26.0, macOS 26.0, *) else {
            emit("unavailable: OS predates Foundation Models")
            return
        }
        let model = SystemLanguageModel.default
        guard model.isAvailable else {
            emit("unavailable: \(String(describing: model.availability))")
            return
        }
        emit("available=yes")

        let request = sampleRequest()
        let headlinePrompt = FoundationModelsProvider.headlinePrompt(for: request)

        // The first generation of a process pays for loading the model. That
        // cost is real but it is paid once, so it is reported separately
        // rather than averaged into the per-call figure.
        let warmStart = Date()
        do {
            let session = LanguageModelSession()
            _ = try await session.respond(
                to: headlinePrompt,
                generating: GeneratedSequenceHeadlines.self,
                options: FoundationModelsProvider.headlineOptions
            )
            emit(String(format: "cold-headline=%.2fs", Date().timeIntervalSince(warmStart)))
        } catch {
            emit("cold-headline failed: \(error)")
            return
        }

        var headlineTimes: [Double] = []
        var narrativeTimes: [Double] = []
        var lastHeadlines = (reference: request.referenceHeadline, attempt: request.attemptHeadline)

        for iteration in 1 ... 3 {
            do {
                let t0 = Date()
                let session = LanguageModelSession()
                let headlines = try await session.respond(
                    to: FoundationModelsProvider.headlinePrompt(for: request),
                    generating: GeneratedSequenceHeadlines.self,
                    options: FoundationModelsProvider.headlineOptions
                )
                let headlineSeconds = Date().timeIntervalSince(t0)
                headlineTimes.append(headlineSeconds)
                lastHeadlines = (
                    headlines.content.referenceHeadline,
                    headlines.content.attemptHeadline
                )
                emit(String(
                    format: "headline[%d]=%.2fs ref=%@ | you=%@",
                    iteration, headlineSeconds,
                    headlines.content.referenceHeadline,
                    headlines.content.attemptHeadline
                ))

                let t1 = Date()
                let narrativeSession = LanguageModelSession()
                let narratives = try await narrativeSession.respond(
                    to: FoundationModelsProvider.narrativePrompt(for: request, headlines: lastHeadlines),
                    generating: GeneratedSequenceNarratives.self,
                    options: FoundationModelsProvider.narrativeOptions
                )
                let narrativeSeconds = Date().timeIntervalSince(t1)
                narrativeTimes.append(narrativeSeconds)
                emit(String(format: "narrative[%d]=%.2fs", iteration, narrativeSeconds))
                emit("narrative[\(iteration)].ref=\(narratives.content.referenceNarrative)")
                emit("narrative[\(iteration)].you=\(narratives.content.attemptNarrative)")
            } catch {
                emit("iteration \(iteration) failed: \(error)")
            }
        }

        // The existing per-move call, for comparison.
        var moveTimes: [Double] = []
        let provider = FoundationModelsProvider()
        for iteration in 1 ... 3 {
            let t0 = Date()
            if (try? await provider.analyze(sampleDelta())) != nil {
                let seconds = Date().timeIntervalSince(t0)
                moveTimes.append(seconds)
                emit(String(format: "existing-move-analyze[%d]=%.2fs", iteration, seconds))
            } else {
                emit("existing-move-analyze[\(iteration)] failed")
            }
        }

        report("headline", headlineTimes, emit: emit)
        report("narrative", narrativeTimes, emit: emit)
        let perSequence = (headlineTimes.reduce(0, +) + narrativeTimes.reduce(0, +))
            / Double(max(1, min(headlineTimes.count, narrativeTimes.count)))
        emit(String(format: "per-sequence-both-calls=%.2fs", perSequence))
        emit(String(format: "projected-9-sequences-headlines-only=%.1fs", mean(headlineTimes) * 9))
        emit(String(format: "projected-9-sequences-both=%.1fs", perSequence * 9))
        report("existing-move-analyze", moveTimes, emit: emit)
        emit(String(format: "existing-cost-14-moves=%.1fs", mean(moveTimes) * 14))
        emit(String(format: "added-cost-4-sequences=%.1fs", perSequence * 4))
        #else
        emit("unavailable: FoundationModels does not import on this platform")
        #endif
    }

    private static func report(_ label: String, _ times: [Double], emit: (String) -> Void) {
        guard !times.isEmpty else {
            emit("\(label): no successful calls")
            return
        }
        let sorted = times.sorted()
        emit(String(
            format: "%@ warm: min=%.2fs median=%.2fs max=%.2fs n=%d",
            label, sorted.first ?? 0, sorted[sorted.count / 2], sorted.last ?? 0, sorted.count
        ))
    }

    private static func mean(_ values: [Double]) -> Double {
        values.isEmpty ? 0 : values.reduce(0, +) / Double(values.count)
    }

    private static func deviceDescription() -> String {
        #if os(iOS)
        var info = utsname()
        uname(&info)
        let machine = withUnsafePointer(to: &info.machine) {
            $0.withMemoryRebound(to: CChar.self, capacity: 1) { String(cString: $0) }
        }
        return "\(machine) iOS \(ProcessInfo.processInfo.operatingSystemVersionString)"
        #else
        return ProcessInfo.processInfo.operatingSystemVersionString
        #endif
    }
}


/// Reads back the text the Results screen renders, headlessly.
///
/// Debug scaffolding, opt-in by launch argument. It reads the cache rather
/// than regenerating, which is also the assertion: reopening a saved climb has
/// to show the identical words.
enum NarrationVerification {
    static func run() async {
        func emit(_ line: String) {
            print("VERIFY|\(line)")
            fflush(stdout)
        }

        let store = SessionStore()
        let sessions = await store.listSessions()
        emit("saved climbs: \(sessions.count)")

        for session in sessions {
            guard let cached = await store.cachedProcessed(session: session) else {
                emit("\(session.name): no cached result")
                continue
            }
            emit("\(session.name): \(cached.sequenceAnalyses.count) sequences, provider \(cached.analyses.first?.source ?? "unknown")")
            for analysis in cached.sequenceAnalyses {
                let reference = analysis.referenceFinding
                let attempt = analysis.attemptFinding
                emit("  seq \(analysis.sequenceIndex + 1) [\(analysis.kind.rawValue)] narrated-by=\(analysis.narrationSource ?? "—")")
                emit("    REF card: \(reference?.cardSentence(causeSubject: "they") ?? "<no finding>")")
                emit("    YOU card: \(attempt?.cardSentence(causeSubject: "you") ?? "<no finding>")")
                emit("    REF lead: \(reference?.headline ?? "<none>")")
                emit("    YOU lead: \(attempt?.headline ?? "<none>")")
                emit("    REF sheet: \(analysis.referenceNarrative ?? "<no narrative>")")
                emit("    YOU sheet: \(analysis.attemptNarrative ?? "<no narrative>")")
                for phrase in [reference?.headline, attempt?.headline].compactMap({ $0 }) {
                    if let failure = HeadlineGuard.failure(phrase) {
                        emit("    !! headline would be rejected: \(failure) — \(phrase)")
                    }
                }
            }
        }

        // Then the states real footage rarely produces all at once, run
        // through the provider the device would actually use.
        let provider = await AnalysisProviderFactory.make(config: TuningConfig())
        emit("provider for fresh generation: \(provider.name)")
        for request in sampleRequests() {
            guard let narration = try? await provider.narrate(request) else {
                emit("[\(request.kind.rawValue)] narrate threw")
                continue
            }
            emit("[\(request.kind.rawValue)] REF card: \(narration.referenceHeadline)")
            emit("[\(request.kind.rawValue)] YOU card: \(narration.attemptHeadline)")
            emit("[\(request.kind.rawValue)] REF sheet: \(narration.referenceNarrative)")
            emit("[\(request.kind.rawValue)] YOU sheet: \(narration.attemptNarrative)")
            for phrase in [narration.referenceHeadline, narration.attemptHeadline] {
                if let failure = HeadlineGuard.failure(phrase) {
                    emit("[\(request.kind.rawValue)] !! headline escaped its guard: \(failure)")
                }
            }
            for text in [narration.referenceNarrative, narration.attemptNarrative] {
                if let failure = NarrativeGuard.failure(text, request: request) {
                    emit("[\(request.kind.rawValue)] !! narrative escaped its guard: \(failure)")
                }
            }
        }
    }

    /// One request per state the Results screen has to handle.
    static func sampleRequests() -> [SequenceNarrationRequest] {
        [
            ModelLatencyBenchmark.sampleRequest(),
            SequenceNarrationRequest(
                sequenceIndex: 5,
                kind: .fall,
                referenceHeadline: "Stayed on here",
                attemptHeadline: "Came off here",
                referenceSentence: "The other climber stayed on through this sequence.",
                attemptSentence: "You fell during this sequence.",
                comparisonIsValid: true,
                fallContext: "This is the sequence the go ended on, but what caused it started earlier in the climb."
            ),
            SequenceNarrationRequest(
                sequenceIndex: 6,
                kind: .structural,
                referenceHeadline: "Original hold order",
                attemptHeadline: "Different hold order",
                referenceSentence: "The other climber used the reference hold order.",
                attemptSentence: "You used a different hold order.",
                comparisonIsValid: false,
                unavailableReason: "The movements are not comparable, so no reference value is shown."
            ),
            SequenceNarrationRequest(
                sequenceIndex: 7,
                kind: .similar,
                referenceHeadline: "Much the same here",
                attemptHeadline: "Much the same here",
                referenceSentence: "The other climber matched you closely across the measured body positions.",
                attemptSentence: "You matched the reference closely across the measured body positions.",
                comparisonIsValid: true
            )
        ]
    }
}


/// Builds one saved climb from fixture files, using the real pipeline.
///
/// Debug scaffolding for checking the Results screen on a phone. It writes
/// through `saveClimb`'s own path — `cacheProcessed` then `save` — so the
/// climb it leaves behind is indistinguishable from one recorded at a wall,
/// including the cached generated text.
enum SessionSeeding {
    static let seedName = "Seeded fixture climb"

    @Sendable
    static func emit(_ line: String) {
        print("SEED|\(line)")
        fflush(stdout)
    }

    static func run() async {

        let documents = (try? FileManager.default.url(
            for: .documentDirectory, in: .userDomainMask, appropriateFor: nil, create: true
        )) ?? URL.temporaryDirectory
        let seed = documents.appendingPathComponent("seed", isDirectory: true)

        let referenceFile = seed.appendingPathComponent("reference.MOV")
        let attemptFile = seed.appendingPathComponent("attempt.MOV")
        guard FileManager.default.fileExists(atPath: referenceFile.path),
              FileManager.default.fileExists(atPath: attemptFile.path) else {
            emit("no fixtures at \(seed.path) — push reference.MOV and attempt.MOV first")
            return
        }

        let store = SessionStore()
        // Replace, not accumulate. Two climbs with the same name and different
        // generated text is how a stale run gets read as a current one.
        for existing in await store.listSessions() where existing.name == seedName {
            await store.delete(id: existing.id)
            emit("removed previous seed \(existing.id)")
        }
        do {
            var session = try await store.create(name: seedName)
            let reference = try await store.importVideo(from: referenceFile, into: session, role: .reference, label: "Reference")
            let attempt = try await store.importVideo(from: attemptFile, into: session, role: .attempt, label: "Attempt 1")
            session.reference = reference
            session.attempts = [attempt]
            session.grade = .v4
            try await store.save(session)

            for (name, video) in [("reference-poses.json", reference), ("attempt-poses.json", attempt)] {
                let url = seed.appendingPathComponent(name)
                guard let data = try? Data(contentsOf: url),
                      let sequence = try? JSONDecoder().decode(PoseSequence.self, from: data)
                else {
                    emit("no cached pose for \(name) — Vision will run, which takes minutes")
                    continue
                }
                try await store.cachePose(sequence, session: session, video: video, source: session.poseSource)
                emit("seeded pose: \(name) (\(sequence.frames.count) frames)")
            }

            let config = TuningConfig()
            let pipeline = ProcessingPipeline(
                store: store,
                analysisProvider: await AnalysisProviderFactory.make(config: config)
            )
            let started = Date()
            let processed = try await pipeline.process(session: session, config: config) { progress in
                emit(String(format: "  %@ %.0f%%", progress.stageName, progress.fraction * 100))
            }
            emit(String(format: "pipeline: %.1fs, %d sequences", Date().timeIntervalSince(started), processed.sequenceAnalyses.count))

            try await store.cacheProcessed(processed, session: session)
            try await store.save(session)
            emit("saved: \(session.name)")
        } catch {
            emit("failed: \(error)")
        }
    }
}
