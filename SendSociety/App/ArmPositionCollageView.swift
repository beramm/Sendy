//import Foundation
//import CoreTransferable
//import UniformTypeIdentifiers

import SwiftUI
import Observation
import Foundation
import CoreGraphics

// =====================================================================
// MARK: - Keyframe selection & extraction
//
// Everything in this section is new. It reads pose data through types
// that already exist in the project (marked below with "// EXISTING:")
// rather than re-running Vision — this feature never calls
// VNDetectHumanBodyPoseRequest itself.
// =====================================================================

/// Tunables for keyframe selection. Exposed so sensitivity can be adjusted
/// from a settings sheet without re-extracting pose.
struct ArmKeyframeConfig: Equatable, Sendable {
    /// Wall-space distance (aspect-corrected, roughly `[0,1]`) a wrist must
    /// move relative to the *last selected keyframe* to count as a new
    /// position. Lower catches smaller adjustments; higher keeps only bigger
    /// reaches.
    var movementThreshold: Double = 0.05
    /// Minimum time between two selected keyframes, even if the threshold is
    /// crossed. Guards against tracking jitter producing near-duplicate
    /// frames a couple of pose-frames apart.
    var minimumKeyframeSpacing: Double = 0.2
    /// Below this confidence a wrist is treated as "not detected" for this
    /// frame — same convention as the rest of the pipeline (see
    /// `PoseFrame.torsoTracked(minConfidence:)` // EXISTING, PoseFrame.swift).
    var minimumJointConfidence: Double = 0.3
    /// Hard cap so a long or noisy climb can't produce an unbounded collage.
    var maximumKeyframes: Int = 40
    /// Thumbnails are capped to this dimension — full-resolution stills for
    /// 40 frames × 2 videos adds up fast in memory.
    var thumbnailMaxDimension: CGFloat = 480
}

/// One selected "new arm position" frame, with its source timestamp and the
/// wrist points that justified selecting it (kept in case a later pass wants
/// to draw them over the thumbnail).
///
/// `@unchecked Sendable`: `CGImage` isn't `Sendable` in the SDK, but it's
/// never mutated after creation, so handing it across isolation boundaries
/// is safe in practice.
struct ArmKeyframe: Identifiable, @unchecked Sendable {
    let id = UUID()
    let time: Double
    let image: CGImage
    // EXISTING type: Point2D — see Geometry.swift. Normalized wall-space
    // point, origin bottom-left, y up.
    let leftWrist: Point2D?
    let rightWrist: Point2D?
}

enum ArmKeyframeError: LocalizedError {
    case noFramesTracked

    var errorDescription: String? {
        "No usable arm positions were found — check the climber's arms are visible throughout the clip."
    }
}

/// Pure selection logic over pose already extracted by the project's
/// `PoseExtractor`. No Vision calls here — this only decides *which*
/// already-tracked frames are distinct enough to keep.
enum ArmKeyframeSelector {
    static func selectFrames(from sequence: PoseSequence, config: ArmKeyframeConfig) -> [PoseFrame] {
        // EXISTING types used in this function's signature:
        // - PoseSequence, PoseFrame — PoseFrame.swift
        guard !sequence.isEmpty else { return [] }  // EXISTING: PoseSequence.isEmpty

        var selected: [PoseFrame] = []
        // Compared against the last *selected keyframe*, not the previous
        // pose frame — otherwise slow, continuous drift never crosses the
        // per-step threshold even once it's moved a long way in total.
        var lastWrists: (left: Point2D?, right: Point2D?)?
        var lastKeyframeTime = -Double.greatestFiniteMagnitude

        for frame in sequence.frames {
            // EXISTING: PoseFrame.point(_:minConfidence:) — PoseFrame.swift.
            // .leftWrist / .rightWrist are cases of the EXISTING JointName
            // enum (PoseFrame.swift).
            let left = frame.point(.leftWrist, minConfidence: config.minimumJointConfidence)
            let right = frame.point(.rightWrist, minConfidence: config.minimumJointConfidence)
            guard left != nil || right != nil else { continue }
            let current = (left: left, right: right)

            let isFirstTrackedFrame = lastWrists == nil
            let movedEnough = hasMovedEnough(
                from: lastWrists, to: current,
                threshold: config.movementThreshold, xScale: sequence.xScale
                // EXISTING: PoseSequence.xScale — aspect-correction factor,
                // see its doc comment in PoseFrame.swift.
            )
            let spacingOK = frame.timeSeconds - lastKeyframeTime >= config.minimumKeyframeSpacing

            if isFirstTrackedFrame || (movedEnough && spacingOK) {
                selected.append(frame)
                lastWrists = current
                lastKeyframeTime = frame.timeSeconds
                if selected.count >= config.maximumKeyframes { break }
            }
        }
        return selected
    }

    private static func hasMovedEnough(
        from previous: (left: Point2D?, right: Point2D?)?,
        to current: (left: Point2D?, right: Point2D?),
        threshold: Double,
        xScale: Double
    ) -> Bool {
        guard let previous else { return true }
        // Aspect-corrected, per PoseSequence.xScale's own doc comment
        // (EXISTING, PoseFrame.swift): normalized coordinates squash the
        // wider axis, so x needs scaling before it's comparable to y.
        func distance(_ a: Point2D?, _ b: Point2D?) -> Double? {
            guard let a, let b else { return nil }
            let dx = (a.x - b.x) * xScale
            let dy = a.y - b.y
            return (dx * dx + dy * dy).squareRoot()
        }
        let deltas = [distance(previous.left, current.left), distance(previous.right, current.right)]
            .compactMap { $0 }
        return deltas.contains { $0 >= threshold }
    }
}

/// Builds displayable keyframes for one video: reuses cached pose exactly the
/// way `ProcessingPipeline.pose(for:session:config:progress:)` does (see
/// ProcessingPipeline.swift — never re-runs Vision if this session's pose
/// source is already cached), selects frames, then pulls a thumbnail image
/// for each *selected* timestamp only — not every sampled frame — since a
/// full decode pass for 40+ candidate frames per video is the expensive part.
enum ArmKeyframeBuilder {
    static func build(
        session: ClimbSession,          // EXISTING: ClimbSession.swift
        video: VideoRef,                // EXISTING: ClimbSession.swift
        store: SessionStore,             // EXISTING: SessionStore.swift
        config: ArmKeyframeConfig,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws -> [ArmKeyframe] {
        let source = session.poseSource  // EXISTING: ClimbSession.poseSource (PoseSource.swift)
        let sequence: PoseSequence
        // EXISTING: SessionStore.cachedPose(session:video:source:) — the same
        // disk cache ProcessingPipeline reads, keyed by session + video +
        // pose source. A hit here means this screen never touches Vision.
        if let cached = await store.cachedPose(session: session, video: video, source: source) {
            sequence = cached
        } else {
            // EXISTING: SessionStore.videoURL(session:video:)
            let url = await store.videoURL(session: session, video: video)
            // EXISTING: PoseExtractorFactory.make(_:) — PoseSource.swift.
            // Returns the same `any PoseExtractor` (e.g. VisionPoseExtractor,
            // PoseExtractor.swift) the main pipeline uses.
            let extractor = PoseExtractorFactory.make(source)
            // Pose extraction dominates the wait when nothing is cached yet;
            // thumbnail generation below gets the remaining share.
            // EXISTING: PoseExtractor.extract(url:config:progress:) —
            // PoseExtractor.swift. `session.config` is the EXISTING
            // TuningConfig (TuningConfig.swift).
            sequence = try await extractor.extract(url: url, config: session.config) { fraction in
                progress(fraction * 0.7)
            }
            // EXISTING: SessionStore.cachePose(_:session:video:source:) —
            // writes to the same cache ProcessingPipeline reads from, so a
            // later full "Process" run also skips Vision for this video.
            try? await store.cachePose(sequence, session: session, video: video, source: source)
        }

        let frames = ArmKeyframeSelector.selectFrames(from: sequence, config: config)
        guard !frames.isEmpty else { throw ArmKeyframeError.noFramesTracked }

        let url = await store.videoURL(session: session, video: video)  // EXISTING, see above
        var keyframes: [ArmKeyframe] = []
        keyframes.reserveCapacity(frames.count)
        for (index, frame) in frames.enumerated() {
            try Task.checkCancellation()
            // EXISTING: VideoFrameSource.image(url:seconds:maximumSize:) —
            // WallAligner.swift. The same frame-grab utility the pipeline
            // uses for registration and the overlay renderer; reused here
            // instead of writing a second AVAssetImageGenerator wrapper.
            let image = try await VideoFrameSource.image(
                url: url,
                seconds: frame.timeSeconds,
                maximumSize: CGSize(width: config.thumbnailMaxDimension, height: config.thumbnailMaxDimension)
            )
            keyframes.append(ArmKeyframe(
                time: frame.timeSeconds,
                image: image,
                leftWrist: frame.point(.leftWrist),   // EXISTING: PoseFrame.point(_:minConfidence:)
                rightWrist: frame.point(.rightWrist)
            ))
            progress(0.7 + 0.3 * Double(index + 1) / Double(frames.count))
        }
        return keyframes
    }
}

// =====================================================================
// MARK: - View model
// =====================================================================

/// Drives keyframe extraction for both clips and holds the results. A
/// `@State`-owned `@Observable` rather than folded into `AppModel`
/// (EXISTING, AppModel.swift) — this feature's state (two load states, two
/// frame arrays, a sensitivity config) has nothing to do with session/clip
/// management, and nothing else in the app reads it.
@MainActor
@Observable
final class CollageComparisonModel {
    enum LoadState: Equatable {
        case idle
        case loading(Double)
        case loaded
        case failed(String)
    }

    var referenceState: LoadState = .idle
    var attemptState: LoadState = .idle
    var referenceKeyframes: [ArmKeyframe] = []
    var attemptKeyframes: [ArmKeyframe] = []
    var config = ArmKeyframeConfig()

    // EXISTING: VideoRef.Role — ClimbSession.swift ( .reference / .attempt ).
    private var tasks: [VideoRef.Role: Task<Void, Never>] = [:]
    /// In-memory only, keyed by video id + the config that produced it. Pose
    /// itself is already cached to disk by `SessionStore` (EXISTING) the same
    /// way the main pipeline caches it — a relaunch still skips Vision — so
    /// this cache only saves re-running keyframe selection and re-decoding
    /// thumbnails for a sensitivity setting already seen this launch.
    private var cache: [String: [ArmKeyframe]] = [:]

    func load(session: ClimbSession, reference: VideoRef, attempt: VideoRef, store: SessionStore) {
        load(video: reference, role: .reference, session: session, store: store)
        load(video: attempt, role: .attempt, session: session, store: store)
    }

    func cancelAll() {
        tasks.values.forEach { $0.cancel() }
    }

    private func load(video: VideoRef, role: VideoRef.Role, session: ClimbSession, store: SessionStore) {
        let key = cacheKey(videoID: video.id, config: config)
        if let cached = cache[key] {
            setKeyframes(cached, for: role)
            setState(.loaded, for: role)
            return
        }

        tasks[role]?.cancel()
        setState(.loading(0), for: role)
        let config = self.config

        // Same unstructured-Task + nested `Task { @MainActor in ... }`
        // progress-hop pattern AppModel.process() uses (EXISTING,
        // AppModel.swift) — kept consistent rather than inventing a
        // different concurrency style for this one screen.
        tasks[role] = Task { [weak self] in
            guard let self else { return }
            do {
                let frames = try await ArmKeyframeBuilder.build(
                    session: session, video: video, store: store, config: config
                ) { fraction in
                    Task { @MainActor in self.setState(.loading(fraction), for: role) }
                }
                guard !Task.isCancelled else { return }
                self.cache[key] = frames
                self.setKeyframes(frames, for: role)
                self.setState(.loaded, for: role)
            } catch is CancellationError {
                // Superseded by a newer load (sensitivity changed mid-run) —
                // leave whatever state that load sets.
            } catch {
                self.setState(.failed(error.localizedDescription), for: role)
            }
        }
    }

    private func setState(_ state: LoadState, for role: VideoRef.Role) {
        if role == .reference { referenceState = state } else { attemptState = state }
    }

    private func setKeyframes(_ frames: [ArmKeyframe], for role: VideoRef.Role) {
        if role == .reference { referenceKeyframes = frames } else { attemptKeyframes = frames }
    }

    private func cacheKey(videoID: UUID, config: ArmKeyframeConfig) -> String {
        "\(videoID)-\(config.movementThreshold)-\(config.minimumKeyframeSpacing)-\(config.minimumJointConfidence)-\(config.maximumKeyframes)"
    }
}

// =====================================================================
// MARK: - Views
// =====================================================================

/// Side-by-side vertical collages: every frame is a new arm position, one
/// column per clip. Reads pose through the same cache the main pipeline
/// uses, so this is instant after a session has been processed once, and
/// works even before it has — it doesn't need `ProcessedSession` or the
/// homography/contact-detection stages, only pose.
struct ArmPositionCollageView: View {
    // EXISTING: AppModel — AppModel.swift. Injected via .environment(model)
    // in SendSocietyApp.swift, same as every other screen in the app.
    @Environment(AppModel.self) private var model
    @State private var comparison = CollageComparisonModel()
    @State private var showingSettings = false

    // EXISTING: AppModel.session, ClimbSession.reference/.attempts,
    // AppModel.attemptIndex — all read-only here, nothing new added to
    // AppModel itself.
    private var reference: VideoRef? { model.session?.reference }
    private var attempt: VideoRef? {
        guard let attempts = model.session?.attempts, !attempts.isEmpty else { return nil }
        return attempts[min(model.attemptIndex, attempts.count - 1)]
    }

    var body: some View {
        Group {
            if let session = model.session, let reference, let attempt {
                HStack(spacing: 1) {
                    CollageColumn(title: reference.label, state: comparison.referenceState, keyframes: comparison.referenceKeyframes)
                    Divider()
                    CollageColumn(title: attempt.label, state: comparison.attemptState, keyframes: comparison.attemptKeyframes)
                }
                .task { load(session: session, reference: reference, attempt: attempt) }
                .onDisappear { comparison.cancelAll() }
                .sheet(isPresented: $showingSettings) {
                    SensitivitySettingsView(config: $comparison.config) {
                        load(session: session, reference: reference, attempt: attempt)
                    }
                }
            } else {
                // EXISTING API: ContentUnavailableView (SwiftUI, iOS 17+).
                ContentUnavailableView(
                    "Need both clips",
                    systemImage: "figure.climbing",
                    description: Text("Add a reference and at least one attempt on the clips screen first.")
                )
            }
        }
        .navigationTitle("Arm positions")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("Sensitivity", systemImage: "slider.horizontal.3") { showingSettings = true }
            }
        }
    }

    private func load(session: ClimbSession, reference: VideoRef, attempt: VideoRef) {
        // EXISTING: AppModel.store — AppModel.swift ("let store = SessionStore()").
        comparison.load(session: session, reference: reference, attempt: attempt, store: model.store)
    }
}

private struct CollageColumn: View {
    let title: String
    let state: CollageComparisonModel.LoadState
    let keyframes: [ArmKeyframe]

    var body: some View {
        VStack(spacing: 0) {
            Text(title)
                .font(.subheadline.weight(.semibold))
                .lineLimit(1)
                .padding(.vertical, 8)
                .frame(maxWidth: .infinity)
                .background(.bar)

            switch state {
            case .idle:
                Spacer()
            case .loading(let fraction):
                VStack(spacing: 8) {
                    ProgressView(value: fraction).frame(width: 120)
                    Text("Finding arm positions…")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            case .failed(let message):
                VStack(spacing: 6) {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                    Text(message).font(.caption).multilineTextAlignment(.center)
                }
                .padding()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            case .loaded:
                ScrollView {
                    LazyVStack(spacing: 4) {
                        ForEach(keyframes) { frame in
                            Image(decorative: frame.image, scale: 1)
                                .resizable()
                                .aspectRatio(contentMode: .fit)
                                .overlay(alignment: .bottomTrailing) {
                                    Text(String(format: "%.1fs", frame.time))
                                        .font(.caption2.monospacedDigit())
                                        .padding(.horizontal, 4)
                                        .padding(.vertical, 2)
                                        .background(.black.opacity(0.6), in: .capsule)
                                        .foregroundStyle(.white)
                                        .padding(4)
                                }
                        }
                    }
                }
            }
        }
        .frame(maxWidth: .infinity)
    }
}

private struct SensitivitySettingsView: View {
    @Binding var config: ArmKeyframeConfig
    @Environment(\.dismiss) private var dismiss
    let onApply: () -> Void

    var body: some View {
        NavigationStack {
            Form {
                SwiftUI.Section("Movement threshold") {
                    Slider(value: $config.movementThreshold, in: 0.02...0.15)
                    Text("Lower catches smaller adjustments; higher keeps only bigger reaches.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                SwiftUI.Section("Minimum spacing") {
                    Slider(value: $config.minimumKeyframeSpacing, in: 0.05...1.0)
                    Text(String(format: "At least %.2fs between two keyframes.", config.minimumKeyframeSpacing))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Sensitivity")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Apply") { onApply(); dismiss() }
                }
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel", role: .cancel) { dismiss() }
                }
            }
        }
        .presentationDetents([.medium])
    }
}
#Preview{ArmPositionCollageView()}
