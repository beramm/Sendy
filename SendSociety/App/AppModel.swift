import Foundation
import SwiftUI
import Observation
import PhotosUI

/// Which comparison view is on screen.
///
/// **View-layer only.** Switching modes must not re-run a single pipeline
/// stage — everything every mode needs is already in `ProcessedSession`.
///
/// The alpha-composited `overlay` mode was removed rather than kept as a
/// further tab. Its known weakness was recorded in `plan.md` from the start —
/// two differently-sized bodies superimposed read as clutter, because the wall
/// lines up and the humans do not — and `skeletonOverlay` covers the question
/// it was actually being used for: whether the tracker is seeing the climber.
enum ComparisonMode: String, CaseIterable, Identifiable {
    case sideBySide
    case skeletonOverlay
    case skeletonOnly
    case skeleton3D

    var id: String { rawValue }

    var label: String {
        switch self {
        case .sideBySide: "Side by side"
        case .skeletonOverlay: "Skeleton overlay"
        case .skeletonOnly: "Skeleton"
        case .skeleton3D: "Skeleton 3D"
        }
    }
}

enum ProcessingState: Equatable {
    case idle
    case running(stage: String, stageIndex: Int, fraction: Double)
    case done
    case failed(String)
}

/// Where a clip slot is in its import. **Per role, not per app** — the two
/// pickers can be driven at the same time, and a spinner that doesn't say
/// which clip it belongs to is worse than no spinner.
enum ClipImportState: Equatable {
    case idle
    case loading
    case failed(String)
}

/// The screens the main flow can push. Leaf screens (capture, review, route
/// correction, move list) stay destination-based links — they are one-offs
/// that nothing ever needs to address by value.
enum AppRoute: Hashable {
    case setup
    case results
    /// Stage timings, statuses and warnings. **Not in the main flow** — the
    /// pipeline runs from the clips screen and lands on results. This is the
    /// debugging surface, reached from results when a number looks wrong.
    case report
    case tuning
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
    /// Navigation stack for the main flow, so creating a session can land the
    /// user on the clips screen without them having to find a row.
    var path: [AppRoute] = []
    var referenceImport: ClipImportState = .idle
    var attemptImport: ClipImportState = .idle
    /// Sources with pose already cached for every video, so the picker can say
    /// which switches are instant and which mean re-extracting.
    var cachedPoseSources: Set<PoseSource> = []

    private var processingTask: Task<Void, Never>?

    init() {
        Task { await refresh() }
    }

    // MARK: Readiness

    var isImporting: Bool {
        referenceImport == .loading || attemptImport == .loading
    }

    /// The submit gate. Both a reference and at least one attempt, and nothing
    /// still copying out of Photos.
    var canProcess: Bool {
        session?.isReadyToProcess == true && !isImporting
    }

    /// Why the submit button is disabled, in the user's terms. `nil` when it
    /// isn't — a disabled control with no stated reason is a dead end.
    var blockedReason: String? {
        guard let session else { return "Create a session first." }
        if isImporting { return "Waiting for a clip to finish importing." }
        if session.reference == nil { return "Add a reference climb — the stronger climber." }
        if session.attempts.isEmpty { return "Add at least one attempt of your own." }
        return nil
    }

    func importState(for role: VideoRef.Role) -> ClipImportState {
        role == .reference ? referenceImport : attemptImport
    }

    private func setImportState(_ state: ClipImportState, for role: VideoRef.Role) {
        if role == .reference { referenceImport = state } else { attemptImport = state }
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

    /// Creating a session lands on the clips screen. There is nothing to do
    /// with a session that has no clips, so making the user find a row first
    /// is a step that only exists to be skipped.
    func newSession(name: String) async {
        do {
            let created = try await store.create(name: name)
            session = created
            config = created.config
            processed = nil
            state = .idle
            attemptIndex = 0
            clearImportStates()
            path = [.setup]
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
        clearImportStates()
        path = [.setup]
    }

    func delete(_ s: ClimbSession) async {
        await store.delete(id: s.id)
        if session?.id == s.id {
            session = nil
            processed = nil
            state = .idle
            clearImportStates()
            path = []
        }
        await refresh()
    }

    private func clearImportStates() {
        referenceImport = .idle
        attemptImport = .idle
    }

    // MARK: Clips

    /// The whole picker-to-disk path, owned by the model so the slot it belongs
    /// to is known throughout. The view used to hold one shared `importing`
    /// flag for both pickers, so two concurrent imports cleared each other's
    /// spinner and a failure surfaced on a screen the user had already left.
    func importPicked(_ item: PhotosPickerItem, role: VideoRef.Role) async {
        guard session != nil else { return }
        setImportState(.loading, for: role)
        do {
            // Copy out of Photos into the session directory: a Photos asset URL
            // is not stable, and a session that loses its video can never be
            // reprocessed.
            guard let movie = try await item.loadTransferable(type: VideoFile.self) else {
                setImportState(.failed("Could not read that video."), for: role)
                return
            }
            defer { try? FileManager.default.removeItem(at: movie.url) }
            try await persist(movie.url, role: role)
            setImportState(.idle, for: role)
        } catch {
            setImportState(.failed(error.localizedDescription), for: role)
        }
    }

    /// Recording path. Same states as the picker path, so the clips screen
    /// reads the same however the video arrived.
    func addVideo(from url: URL, role: VideoRef.Role) async {
        guard session != nil else { return }
        setImportState(.loading, for: role)
        do {
            try await persist(url, role: role)
            setImportState(.idle, for: role)
        } catch {
            setImportState(.failed("Could not import the video: \(error.localizedDescription)"), for: role)
        }
    }

    private func persist(_ url: URL, role: VideoRef.Role) async throws {
        guard var current = session else { return }
        // Replacing the reference deletes the old file first — overwriting the
        // ref alone would orphan a video inside the session directory forever.
        if role == .reference, let existing = current.reference {
            await store.removeVideo(session: current, video: existing)
            current.reference = nil
        }
        let label = role == .reference ? "Reference" : "Attempt \(current.attempts.count + 1)"
        let ref = try await store.importVideo(from: url, into: current, role: role, label: label)
        if role == .reference {
            current.reference = ref
        } else {
            current.addAttempt(ref)
        }
        try await store.save(current)
        session = current
        invalidateResults()
        await refresh()
    }

    /// Removes a clip and everything derived from it. Labels of the surviving
    /// attempts are deliberately **not** renumbered: a relabelled attempt would
    /// stop matching whatever a previous processed run reported.
    func removeVideo(_ ref: VideoRef) async {
        guard var current = session else { return }
        await store.removeVideo(session: current, video: ref)
        if current.reference?.id == ref.id {
            current.reference = nil
        } else {
            current.attempts.removeAll { $0.id == ref.id }
        }
        do {
            try await store.save(current)
            session = current
            attemptIndex = min(attemptIndex, max(0, current.attempts.count - 1))
            invalidateResults()
            await refresh()
        } catch {
            lastError = error.localizedDescription
        }
    }

    /// The clips changed, so anything computed from them is stale.
    private func invalidateResults() {
        processed = nil
        state = .idle
        path.removeAll { $0 == .results || $0 == .report }
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
