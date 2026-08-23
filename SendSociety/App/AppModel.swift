import Foundation
import SwiftUI
import Observation
import PhotosUI
import AVFoundation

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
    case processing
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
    /// **Wall clock from tapping Process to the results being on screen**, in
    /// seconds — not the sum of the stage timings.
    ///
    /// The stage report already says where the time went inside the pipeline,
    /// but a stage table that adds up to 4s does not answer "why did that take
    /// half a minute". This is the number a gym trip is actually spent on:
    /// video decode, Vision, and everything between the tap and the output.
    /// Nil until a run finishes; a cancelled or failed run leaves the previous
    /// value alone rather than reporting a partial one.
    var lastProcessingSeconds: Double?
    /// True while `lastProcessingSeconds` describes a run that read pose from
    /// cache. A cached reprocess and a cold first run differ by an order of
    /// magnitude, and a bare number that silently means either is misleading.
    var lastProcessingWasCached = false
    var analysisProviderName = "Template"
    /// Navigation stack for the main flow, so creating a session can land the
    /// user on the clips screen without them having to find a row.
    var path: [AppRoute] = []
    var referenceImport: ClipImportState = .idle
    var attemptImport: ClipImportState = .idle
    /// Sources with pose already cached for every video, so the picker can say
    /// which switches are instant and which mean re-extracting.
    var cachedPoseSources: Set<PoseSource> = []
    /// Where the current session's name came from, so the clips screen can say
    /// so plainly. `.date` is stated, never apologised for.
    var sessionNameSource: SessionNameSource = .date

    private var processingTask: Task<Void, Never>?
    private let videoLocationReader = VideoLocationReader()

    /// Cache first, network second, date last — the ordering lives in
    /// `SessionNamer`; this only supplies the geocoder it may or may not reach.
    private var namer: SessionNamer {
        #if os(iOS)
        SessionNamer(geocoder: MapKitReverseGeocoder())
        #else
        SessionNamer()
        #endif
    }

    init() {
        Task { await refresh() }
    }

#if DEBUG
    /// In-memory state for SwiftUI previews. It intentionally bypasses the
    /// store refresh so preview fixtures never race with on-disk sessions.
    init(previewSession: ClimbSession? = nil, previewSessions: [ClimbSession] = []) {
        session = previewSession
        sessions = previewSessions
        if let previewSession { config = previewSession.config }
    }
#endif

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
    /// A nil or empty name means the app names it. The session starts with a
    /// date name because the coordinate lives in the clips, which do not exist
    /// yet — it re-resolves in `persist` once a reference lands.
    func newSession(name: String?) async {
        let typed = (name ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let resolved: ResolvedSessionName = typed.isEmpty
            ? SessionNamer.dateName(Date())
            : ResolvedSessionName(name: typed, source: .user)
        do {
            var created = try await store.create(name: resolved.name)
            created.nameSource = resolved.source
            try await store.save(created)
            session = created
            sessionNameSource = created.nameSource
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
        sessionNameSource = s.nameSource
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

    /// Starts a Photos import without making the presenting view wait for the
    /// copy. Setting the slot state before creating the task lets capture pop
    /// immediately while the setup card already knows to show its spinner.
    func beginImport(_ item: PhotosPickerItem, role: VideoRef.Role) {
        setImportState(.loading, for: role)
        Task { await importPicked(item, role: role) }
    }

    /// Recording equivalent of ``beginImport(_:role:)``.
    func beginAddingVideo(from url: URL, role: VideoRef.Role) {
        setImportState(.loading, for: role)
        Task { await addVideo(from: url, role: role) }
    }

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
            try await persist(movie.url, role: role, photoItem: item)
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

    /// Exports and replaces one clip while keeping the old file usable until
    /// the replacement is safely stored. Setup stays visible and shows the
    /// progress indicator over the affected climber card.
    func beginTrimming(_ video: VideoRef, from startSeconds: Double, to endSeconds: Double) {
        let role = video.role
        setImportState(.loading, for: role)
        Task {
            do {
                guard let sourceURL = await videoURL(video) else {
                    throw CocoaError(.fileNoSuchFile)
                }
                let output = try await Self.exportTrimmedVideo(
                    sourceURL: sourceURL,
                    startSeconds: startSeconds,
                    endSeconds: endSeconds
                )
                defer { try? FileManager.default.removeItem(at: output) }
                try await persistReplacement(output, replacing: video)
                setImportState(.idle, for: role)
            } catch {
                setImportState(.failed("Could not trim the video: \(error.localizedDescription)"), for: role)
            }
        }
    }

    private func persist(_ url: URL, role: VideoRef.Role, photoItem: PhotosPickerItem? = nil) async throws {
        guard var current = session else { return }
        // Replacing the reference deletes the old file first — overwriting the
        // ref alone would orphan a video inside the session directory forever.
        if role == .reference, let existing = current.reference {
            await store.removeVideo(session: current, video: existing)
            current.reference = nil
        }
        let label = role == .reference ? "Reference" : "Attempt \(current.attempts.count + 1)"
        var ref = try await store.importVideo(from: url, into: current, role: role, label: label)
        ref.coordinate = await coordinate(of: url, photoItem: photoItem)
        if role == .reference {
            current.reference = ref
        } else {
            current.addAttempt(ref)
        }
        await resolveName(of: &current, using: ref)
        try await store.save(current)
        session = current
        sessionNameSource = current.nameSource
        invalidateResults()
        await refresh()
    }

    private func persistReplacement(_ url: URL, replacing original: VideoRef) async throws {
        guard var current = session else { return }
        let attemptIndex: Int?
        if original.role == .reference {
            guard current.reference?.id == original.id else { return }
            attemptIndex = nil
        } else {
            guard let index = current.attempts.firstIndex(where: { $0.id == original.id }) else { return }
            attemptIndex = index
        }

        var replacement = try await store.importVideo(
            from: url,
            into: current,
            role: original.role,
            label: original.label
        )
        // Carried across rather than re-read: a passthrough export does not
        // reliably keep the location metadata, and the clip was filmed at the
        // same gym it was filmed at before it was trimmed.
        replacement.coordinate = original.coordinate

        if original.role == .reference {
            current.reference = replacement
        } else if let index = attemptIndex {
            current.attempts[index] = replacement
        }

        try await store.save(current)
        await store.removeVideo(session: current, video: original)
        session = current
        invalidateResults()
        await refresh()
    }

    private nonisolated static func exportTrimmedVideo(
        sourceURL: URL,
        startSeconds: Double,
        endSeconds: Double
    ) async throws -> URL {
        let duration = endSeconds - startSeconds
        guard startSeconds >= 0, duration > 0.05 else {
            throw CocoaError(.fileReadCorruptFile)
        }

        let asset = AVURLAsset(url: sourceURL)
        let output = URL.temporaryDirectory
            .appendingPathComponent("trim-\(UUID().uuidString).mov")
        nonisolated(unsafe) let exporter = AVAssetExportSession(
            asset: asset,
            presetName: AVAssetExportPresetPassthrough
        )
        guard let exporter else {
            throw CocoaError(.featureUnsupported)
        }
        exporter.timeRange = CMTimeRange(
            start: CMTime(seconds: startSeconds, preferredTimescale: 600),
            duration: CMTime(seconds: duration, preferredTimescale: 600)
        )
        try await exporter.export(to: output, as: .mov)
        return output
    }

    // MARK: Naming (task 12)

    /// **File first, Photos second.** The file read is free and silent; the
    /// Photos read costs a library permission prompt, so it is only reached
    /// when the file carried nothing — which for a `PHPicker` export is most of
    /// the time, because the picker strips location on the way out.
    private func coordinate(of url: URL, photoItem: PhotosPickerItem?) async -> Coordinate2D? {
        if let fromFile = await videoLocationReader.coordinate(of: url) { return fromFile }
        #if os(iOS)
        if let photoItem { return await PhotoLibraryLocationReader.coordinate(for: photoItem) }
        #endif
        return nil
    }

    /// Names a session from where it was filmed, if it is still the app's name
    /// to choose.
    ///
    /// The reference clip decides, because that is the climb the session is
    /// about; an attempt only gets a say when there is no reference coordinate
    /// yet. A session that already has a coordinate is not re-resolved — the
    /// gym did not move between clips.
    private func resolveName(of session: inout ClimbSession, using ref: VideoRef) async {
        guard !session.hasUserName else { return }
        guard let coordinate = ref.coordinate else { return }
        let isBetterSource = ref.role == .reference || session.coordinate == nil
        guard isBetterSource, session.coordinate != coordinate else { return }

        session.coordinate = coordinate
        let resolution = await namer.resolve(
            coordinate: coordinate,
            capturedAt: session.createdAt,
            book: await store.placemarks()
        )
        if let book = resolution.updatedBook {
            try? await store.savePlacemarks(book)
        }
        // A date result changes nothing: the session already has a date name,
        // and rewriting it would only churn the row.
        guard resolution.name.source != .date else { return }
        session.name = resolution.name.name
        session.nameSource = resolution.name.source
    }

    /// Renaming is the correction mechanism for the whole naming feature, so it
    /// does two things: it locks the session's name against any later resolve,
    /// and it teaches the placemark book — so the *next* session at this gym
    /// inherits the name the climber actually uses rather than Apple's label
    /// for the building.
    func renameSession(to name: String) async {
        guard var current = session else { return }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != current.name else { return }

        current.name = trimmed
        current.nameSource = .user
        if let coordinate = current.coordinate {
            await store.rememberPlacemark(
                name: SessionNamer.placeComponent(of: trimmed),
                at: coordinate,
                confirmedByUser: true
            )
        }
        do {
            try await store.save(current)
            session = current
            sessionNameSource = current.nameSource
            await refresh()
        } catch {
            lastError = error.localizedDescription
        }
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
        // Started here rather than inside the pipeline: the question is how
        // long the user waits, which includes building the provider and
        // whatever the pipeline does before its first stage report.
        let submittedAt = Date()
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
                self.lastProcessingSeconds = Date().timeIntervalSince(submittedAt)
                self.lastProcessingWasCached = result.stages
                    .first { $0.name == "Pose extraction" }?.detail.contains("cached") == true
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

    /// Submit-to-output time, formatted, or nil before the first finished run.
    ///
    /// Says whether pose came from cache, because the two numbers are not
    /// comparable: a cold run pays for Vision over the whole clip and a
    /// reprocess does not.
    var processingTimeSummary: String? {
        guard let seconds = lastProcessingSeconds else { return nil }
        let time = seconds < 10
            ? String(format: "%.1fs", seconds)
            : String(format: "%.0fs", seconds)
        return "\(time) \(lastProcessingWasCached ? "(cached pose)" : "(full extraction)")"
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
