import Foundation
import SwiftUI
import Observation

/// Which of the three comparison views is on screen.
///
/// **View-layer only.** Switching modes must not re-run a single pipeline
/// stage — everything all three modes need is already in `ProcessedSession`.
enum ComparisonMode: String, CaseIterable, Identifiable {
    case sideBySide
    case overlay
    case skeletonOnly

    var id: String { rawValue }

    var label: String {
        switch self {
        case .sideBySide: "Side by side"
        case .overlay: "Overlay"
        case .skeletonOnly: "Skeleton"
        }
    }
}

enum ProcessingState: Equatable {
    case idle
    case running(stage: String, stageIndex: Int, fraction: Double)
    case done
    case failed(String)
}

@MainActor
@Observable
final class AppModel {
    let store = SessionStore()
    var sessions: [ClimbSession] = []
    var session: ClimbSession?
    var processed: ProcessedSession?
    var config = TuningConfig()
    var savedConfigs: [NamedTuningConfig] = []
    var state: ProcessingState = .idle
    var attemptIndex = 0
    /// Instrumentation for task 2.9: incremented every time the pipeline runs.
    /// The results screen shows it, so a mode switch that secretly reprocesses
    /// is visible rather than merely believed impossible.
    var pipelineRunCount = 0
    var lastError: String?
    var analysisProviderName = "Template"
    /// Sources with pose already cached for every video, so the picker can say
    /// which switches are instant and which mean re-extracting.
    var cachedPoseSources: Set<PoseSource> = []

    private var processingTask: Task<Void, Never>?

    init() {
        Task { await refresh() }
    }

    func refresh() async {
        sessions = await store.listSessions()
        savedConfigs = await store.savedConfigs()
        if let session { cachedPoseSources = await store.cachedSources(session: session) }
    }

    /// Switching pose model **re-extracts**, unlike every `TuningConfig` field.
    /// The cache is keyed by source, so switching back is instant and the two
    /// models can never read each other's pose.
    func setPoseSource(_ source: PoseSource) async {
        guard var current = session, current.poseSource != source else { return }
        current.poseSource = source
        try? await store.save(current)
        session = current
        processed = nil
        state = .idle
        await refresh()
    }

    // MARK: Sessions

    func newSession(name: String) async {
        do {
            let created = try await store.create(name: name)
            session = created
            processed = nil
            state = .idle
            attemptIndex = 0
            await refresh()
        } catch {
            lastError = error.localizedDescription
        }
    }

    func open(_ s: ClimbSession) {
        session = s
        config = s.config
        processed = nil
        state = .idle
        attemptIndex = 0
    }

    func delete(_ s: ClimbSession) async {
        await store.delete(id: s.id)
        if session?.id == s.id { session = nil; processed = nil }
        await refresh()
    }

    func addVideo(from url: URL, role: VideoRef.Role) async {
        guard var current = session else { return }
        do {
            let label = role == .reference ? "Reference" : "Attempt \(current.attempts.count + 1)"
            let ref = try await store.importVideo(from: url, into: current, role: role, label: label)
            if role == .reference {
                current.reference = ref
            } else {
                current.addAttempt(ref)
            }
            try await store.save(current)
            session = current
            await refresh()
        } catch {
            lastError = "Could not import the video: \(error.localizedDescription)"
        }
    }

    func videoURL(_ ref: VideoRef) async -> URL? {
        guard let session else { return nil }
        return await store.videoURL(session: session, video: ref)
    }

    // MARK: Processing

    func process() {
        guard let session else { return }
        processingTask?.cancel()
        let config = self.config
        let attemptIndex = self.attemptIndex
        state = .running(stage: "Starting", stageIndex: 0, fraction: 0)
        processingTask = Task { [weak self] in
            guard let self else { return }
            // No extractor override: the pipeline picks one from the session's
            // pose source.
            let pipeline = ProcessingPipeline(
                store: self.store,
                analysisProvider: await AnalysisProviderFactory.make(config: config)
            )
            do {
                let result = try await pipeline.process(
                    session: session,
                    attemptIndex: attemptIndex,
                    config: config
                ) { progress in
                    Task { @MainActor in
                        self.state = .running(
                            stage: progress.stageName,
                            stageIndex: progress.stageIndex,
                            fraction: progress.fraction
                        )
                    }
                }
                self.processed = result
                self.pipelineRunCount += 1
                self.state = .done
                self.analysisProviderName = result.analyses.first?.source ?? "Template"
                var updated = session
                updated.config = config
                try? await self.store.save(updated)
                self.session = updated
            } catch is CancellationError {
                self.state = .idle
            } catch {
                if case ProcessingError.cancelled = error {
                    self.state = .idle
                } else {
                    self.state = .failed(error.localizedDescription)
                }
            }
        }
    }

    func cancelProcessing() {
        processingTask?.cancel()
        processingTask = nil
        state = .idle
    }

    // MARK: Tuning

    func saveConfig(named name: String) async {
        do {
            try await store.saveConfig(NamedTuningConfig(name: name, config: config))
            await refresh()
        } catch {
            lastError = error.localizedDescription
        }
    }

    func apply(_ named: NamedTuningConfig) {
        config = named.config
    }

    func resetConfig() {
        config = TuningConfig()
    }

    // MARK: Manual route correction (task 1.10)

    /// Replaces the derived route with a hand-corrected one and re-drives
    /// segmentation. The override is stored on the session so it survives
    /// reprocessing with different thresholds.
    func applyManualRoute(_ route: Route) async {
        guard var current = session else { return }
        var corrected = route
        corrected.holds = corrected.holds.enumerated().map { index, hold in
            var h = hold
            h.ordinal = index
            return h
        }
        current.manualRouteOverride = corrected
        try? await store.save(current)
        session = current
        process()
    }

    func clearManualRoute() async {
        guard var current = session else { return }
        current.manualRouteOverride = nil
        try? await store.save(current)
        session = current
        process()
    }
}

/// Runtime provider selection (task 4.4). Foundation Models when the device has
/// it, template otherwise — and the template provider is the primary path, so
/// the app produces analysis on every device.
enum AnalysisProviderFactory {
    static func make(config: TuningConfig) async -> any AnalysisProvider {
        let template = TemplateAnalysisProvider(config: config)
        #if canImport(FoundationModels)
        let model = FoundationModelsProvider(config: config)
        if await model.isAvailable { return model }
        #endif
        return template
    }
}
