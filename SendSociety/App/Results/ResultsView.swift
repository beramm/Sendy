import SwiftUI

/// Position on the climb, expressed as **sequence N of M plus an offset within
/// the sequence**.
///
/// Indexed by sequence, not by move and not by time. There is no shared clock —
/// one climber may take 7s through a stretch and the other 1s — and a move
/// index is no better, because the two climbers can take a different number of
/// moves across the same span. "Move 6" then names two different places at
/// once. A sequence is bounded by holds both of them actually took, so it names
/// one position in a locked pair by construction.
struct MovePosition: Equatable {
    /// Index into `ProcessedSession.sequences.sequences`.
    var sectionIndex: Int = 0
    /// 0...1 within the sequence.
    var offset: Double = 0
}

struct ResultsView: View {
    @Environment(AppModel.self) private var model

    @State private var mode: ComparisonMode = .sideBySide
    @State private var position = MovePosition()
    @State private var overlays = AnalyticalOverlays()
    @State private var syncLocked = true
    @State private var attemptOffsetOverride: Double?
    @State private var showWarnings = false

    var body: some View {
        Group {
            if let processed = model.processed {
                content(processed)
            } else {
                // Fail soft: never a blank screen.
                List {
                    SwiftUI.Section("Nothing processed yet") {
                        Text("Run the pipeline to see results.")
                        Button("Process") { model.process() }
                    }
                }
            }
        }
        .navigationTitle("Results")
    }

    @ViewBuilder
    private func content(_ processed: ProcessedSession) -> some View {
        VStack(spacing: 8) {
            if processed.sections.isEmpty {
                // Task 5.8 — legible, not pretty.
                errorPanel(processed)
            } else {
                Picker("Mode", selection: $mode) {
                    ForEach(ComparisonMode.allCases) { Text($0.label).tag($0) }
                }
                .pickerStyle(.segmented)
                .padding(.horizontal)

                comparison(processed)
                    .frame(maxHeight: .infinity)

                MoveScrubber(
                    processed: processed,
                    position: $position,
                    syncLocked: $syncLocked,
                    attemptOffsetOverride: $attemptOffsetOverride
                )
                .padding(.horizontal)

                if mode == .skeletonOnly {
                    OverlayToggles(overlays: $overlays).padding(.horizontal)
                }

                currentAnalysis(processed)
            }

            HStack {
                NavigationLink("Moves") { SectionListView(jumpTo: { jump(processed, toMove: $0) }) }
                NavigationLink("Raw metrics") { RawMetricsView() }
                NavigationLink("Route") { RouteCorrectionView() }
                NavigationLink("Tuning") { TuningPanelView() }
            }
            .buttonStyle(.bordered)
            .font(.footnote)

            HStack {
                Button("\(processed.warnings.count) warnings") { showWarnings = true }
                    .font(.caption)
                    .disabled(processed.warnings.isEmpty)
                Spacer()
                // Instrumentation for task 2.9: this number must not change
                // when the mode picker changes.
                Text("pipeline runs: \(model.pipelineRunCount) · \(processed.analyses.first?.source ?? "—")")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal)
        }
        .sheet(isPresented: $showWarnings) {
            NavigationStack {
                List(Array(processed.warnings.enumerated()), id: \.offset) { _, warning in
                    Text(warning).font(.callout)
                }
                .navigationTitle("Warnings")
            }
        }
    }

    // MARK: Comparison surfaces

    @ViewBuilder
    private func comparison(_ processed: ProcessedSession) -> some View {
        let frames = resolvedFrames(processed)
        switch mode {
        case .skeletonOnly:
            SkeletonCanvas(
                referenceFrame: processed.referencePose.frame(at: frames.reference),
                attemptFrame: frames.attempt.flatMap { processed.attemptPose.frame(at: $0) },
                referenceMetrics: processed.referenceMetrics.frame(at: frames.reference),
                attemptMetrics: frames.attempt.flatMap { processed.attemptMetrics.frame(at: $0) },
                referenceScale: processed.referenceScale,
                attemptScale: processed.attemptScale,
                route: processed.route,
                overlays: overlays
            )
        case .sideBySide:
            HStack(spacing: 4) {
                ClimberPane(
                    title: "Reference",
                    video: processed.session.reference,
                    pose: processed.referencePose,
                    frameIndex: frames.reference
                )
                ClimberPane(
                    title: processed.attempt?.label ?? "Attempt",
                    video: processed.attempt,
                    pose: processed.attemptPose,
                    frameIndex: frames.attempt,
                    unavailableReason: currentSequence(processed)?.attemptReached == false
                        ? "no footage for this sequence"
                        : "not reached"
                )
            }
        case .overlay:
            OverlayPane(
                processed: processed,
                referenceFrameIndex: frames.reference,
                attemptFrameIndex: frames.attempt
            )
        }
    }

    /// Reference frame from the scrub position, attempt frame from the DTW
    /// path. Same *move*, never same timestamp.
    private func resolvedFrames(_ processed: ProcessedSession) -> (reference: Int, attempt: Int?) {
        let sequences = processed.sequences.sequences
        guard sequences.indices.contains(position.sectionIndex) else { return (0, nil) }
        let sequence = sequences[position.sectionIndex]
        let referenceFrame = frame(in: sequence.referenceRange, offset: position.offset)

        if syncLocked {
            let path = processed.sequenceWarpPaths.first { $0.sectionIndex == sequence.index }
            return (referenceFrame, path?.attemptFrame(forReference: referenceFrame))
        }
        // Unlocked: the attempt pane scrubs on its own clock. The escape hatch
        // exists because DTW will sometimes misalign a sequence, and locked
        // mode makes that failure impossible to inspect.
        guard sequence.attemptReached else { return (referenceFrame, nil) }
        return (referenceFrame, frame(in: sequence.attemptRange, offset: attemptOffsetOverride ?? position.offset))
    }

    /// The sequence the scrubber is currently on.
    private func currentSequence(_ processed: ProcessedSession) -> ClimbSequence? {
        let sequences = processed.sequences.sequences
        guard sequences.indices.contains(position.sectionIndex) else { return nil }
        return sequences[position.sectionIndex]
    }

    private func frame(in range: Range<Int>, offset: Double) -> Int {
        guard !range.isEmpty else { return range.lowerBound }
        let span = Double(range.count - 1)
        return range.lowerBound + Int((span * offset.clamped(to: 0 ... 1)).rounded())
    }

    // MARK: Panels

    @ViewBuilder
    private func currentAnalysis(_ processed: ProcessedSession) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 6) {
                let moveIndices = currentSequence(processed).map { Array($0.referenceMoves) } ?? []
                if let fall = processed.fallAnalysis,
                   moveIndices.contains(fall.sectionIndex) || moveIndices.contains(processed.fallReport.distalSectionIndex ?? -1) {
                    Text(fall.headline).font(.headline).foregroundStyle(.red)
                    ForEach(fall.observations) { AnalysisNoteRow(note: $0) }
                    Button("Show me why") { drillIntoFall(processed) }
                        .font(.caption)
                }
                // A sequence can hold more than one of the reference's moves,
                // so it shows all of their analyses rather than picking one.
                // Metrics are still measured per move; only the comparison and
                // the scrubbing happen per sequence.
                ForEach(moveIndices, id: \.self) { index in
                    if let analysis = processed.analysis(forSection: index) {
                        Text(analysis.headline).font(.headline)
                        ForEach(analysis.observations) { AnalysisNoteRow(note: $0) }
                        if let drill = analysis.drill {
                            Text("Try: \(drill)").font(.callout).foregroundStyle(.secondary)
                        }
                        ForEach(analysis.warnings, id: \.self) {
                            Text($0).font(.caption2).foregroundStyle(.orange)
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal)
        }
        .frame(height: 140)
    }

    @ViewBuilder
    private func errorPanel(_ processed: ProcessedSession) -> some View {
        List {
            SwiftUI.Section("No moves could be derived") {
                Text("The pipeline ran but produced no moves, so there is nothing to compare. What it did find:")
                    .font(.callout)
                LabeledContent("Reference contacts", value: "\(processed.referenceContacts.count)")
                LabeledContent("Attempt contacts", value: "\(processed.attemptContacts.count)")
                LabeledContent("Holds", value: "\(processed.route.holds.count)")
                LabeledContent("Hand holds", value: "\(processed.route.handHolds.count)")
                LabeledContent("Registration", value: processed.alignment.succeeded ? "ok" : "failed")
            }
            SwiftUI.Section("Warnings") {
                ForEach(Array(processed.warnings.enumerated()), id: \.offset) { _, warning in
                    Text(warning).font(.caption)
                }
            }
            SwiftUI.Section {
                NavigationLink("Open tuning") { TuningPanelView() }
                NavigationLink("Correct the route by hand") { RouteCorrectionView() }
            }
        }
    }

    /// Jump to the sequence containing a given reference **move**.
    ///
    /// Callers hold move indices — the fall report names a move, and the
    /// section list is per move — while the scrubber is indexed by sequence, so
    /// the translation lives here rather than at each call site.
    private func jump(_ processed: ProcessedSession, toMove moveIndex: Int) {
        let sequences = processed.sequences.sequences
        let target = sequences.firstIndex { $0.referenceMoves.contains(moveIndex) }
            ?? min(moveIndex, max(0, sequences.count - 1))
        position = MovePosition(sectionIndex: target, offset: 0)
    }

    /// Task 5.5 — tapping a fall finding lands on the frame where the COM
    /// leaves the base of support, in skeleton mode with the overlay on.
    private func drillIntoFall(_ processed: ProcessedSession) {
        mode = .skeletonOnly
        overlays.centreOfMass = true
        overlays.baseOfSupport = true
        guard let signal = processed.fallReport.mechanical.first(where: { $0.kind == .comOutsideBaseOfSupport })
                ?? processed.fallReport.mechanical.first,
              let frameIndex = signal.frameIndex,
              let section = processed.sections.first(where: { $0.attemptRange.contains(frameIndex) })
        else {
            if let index = processed.fallReport.fallSectionIndex { jump(processed, toMove: index) }
            return
        }
        // The frame is an attempt frame; walk the DTW path back to a reference
        // frame so the scrubber lands on the same move.
        let sequences = processed.sequences.sequences
        guard let sequenceIndex = sequences.firstIndex(where: { $0.referenceMoves.contains(section.index) }) else {
            jump(processed, toMove: section.index)
            return
        }
        let span = sequences[sequenceIndex].attemptRange
        let offset = span.count > 1
            ? Double(frameIndex - span.lowerBound) / Double(span.count - 1)
            : 0
        position = MovePosition(sectionIndex: sequenceIndex, offset: offset.clamped(to: 0 ... 1))
    }
}

/// Task 6.4/6.9 — the claim is what you read; the measurement is one tap away.
///
/// Numbers were removed from the prose, not from the app. Hiding them would
/// make the analysis unauditable, which is the opposite of the intent.
struct AnalysisNoteRow: View {
    let note: AnalysisNote
    @State private var showEvidence = false

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(alignment: .top, spacing: 4) {
                Text(note.text).font(.callout)
                Image(systemName: showEvidence ? "chevron.down" : "chevron.right")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            .contentShape(Rectangle())
            .onTapGesture { showEvidence.toggle() }

            if showEvidence {
                Text(note.evidence)
                    .font(.system(.caption2, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - Scrubber

/// Task 2.8b — position is move N of M plus a continuous offset within the
/// move. It reads correctly on a pair where one climber took 3× longer.
struct MoveScrubber: View {
    let processed: ProcessedSession
    @Binding var position: MovePosition
    @Binding var syncLocked: Bool
    @Binding var attemptOffsetOverride: Double?

    var body: some View {
        VStack(spacing: 4) {
            HStack {
                Button {
                    position = MovePosition(sectionIndex: max(0, position.sectionIndex - 1), offset: 0)
                } label: { Image(systemName: "chevron.left") }
                .disabled(position.sectionIndex == 0)

                Text(label)
                    .font(.system(.subheadline, design: .monospaced))
                    .frame(maxWidth: .infinity)

                Button {
                    position = MovePosition(
                        sectionIndex: min(processed.sequences.sequences.count - 1, position.sectionIndex + 1),
                        offset: 0
                    )
                } label: { Image(systemName: "chevron.right") }
                .disabled(position.sectionIndex >= processed.sequences.sequences.count - 1)
            }

            Slider(value: $position.offset, in: 0 ... 1)

            // One marker per sequence, widthed by how many reference moves it
            // holds, so a sequence covering two moves is visibly wider than one
            // covering a single move.
            HStack(spacing: 2) {
                ForEach(processed.sequences.sequences) { sequence in
                    Rectangle()
                        .fill(colour(for: sequence))
                        .frame(height: 10)
                        .frame(maxWidth: .infinity)
                        .layoutPriority(Double(max(1, sequence.referenceMoves.count)))
                        .overlay {
                            if moves(of: sequence).contains(where: { processed.fallReport.fallSectionIndex == $0.index }) {
                                Text("F").font(.system(size: 8, weight: .bold)).foregroundStyle(.white)
                            }
                            // A differing move count shows as the orange bar
                            // and is spelled out in the label above. It was
                            // also printed into the marker as "1v2", which at
                            // 7pt inside a 10pt bar, repeated across every
                            // sequence, was unreadable clutter rather than a
                            // finding.
                        }
                        .onTapGesture {
                            position = MovePosition(sectionIndex: sequence.index, offset: 0)
                        }
                }
            }

            Toggle("Sync locked to the reference climber's sequence", isOn: $syncLocked)
                .font(.caption)
                .onChange(of: syncLocked) { _, locked in
                    attemptOffsetOverride = locked ? nil : position.offset
                }
            if !syncLocked {
                Slider(value: Binding(
                    get: { attemptOffsetOverride ?? position.offset },
                    set: { attemptOffsetOverride = $0 }
                ), in: 0 ... 1)
                Text("Attempt pane detached — scrubbing on its own clock.")
                    .font(.caption2).foregroundStyle(.secondary)
            }
        }
    }

    private var label: String {
        let sequences = processed.sequences.sequences
        guard sequences.indices.contains(position.sectionIndex) else { return "no sequences" }
        let sequence = sequences[position.sectionIndex]
        var text = "Sequence \(position.sectionIndex + 1) of \(sequences.count)  \(Int(position.offset * 100))%"
        // Move counts per climber, which is the finding this layer exists to
        // surface: three moves against one is not a mismatch, it is the
        // difference worth reporting.
        let refMoves = sequence.referenceMoves.count
        let attMoves = sequence.attemptMoves.count
        if refMoves != attMoves { text += "  (\(refMoves) move\(refMoves == 1 ? "" : "s") vs your \(attMoves))" }
        if !sequence.attemptReached { text += "  (no attempt footage)" }
        // Truncation is a claim about the climber coming off, so it is read
        // from the moves inside this sequence rather than assumed from the
        // sequence itself.
        if moves(of: sequence).contains(where: { $0.divergence?.kind == .truncated }) {
            text += "  (came off here)"
        }
        return text
    }

    /// The reference's own moves inside a sequence.
    private func moves(of sequence: ClimbSequence) -> [Section] {
        sequence.referenceMoves
            .filter { processed.sections.indices.contains($0) }
            .map { processed.sections[$0] }
    }

    private func colour(for sequence: ClimbSequence) -> Color {
        if moves(of: sequence).contains(where: { processed.fallReport.fallSectionIndex == $0.index }) { return .red }
        if sequence.moveCountDelta != 0 { return .orange }
        if !sequence.attemptReached { return .gray }
        return sequence.index == position.sectionIndex ? .blue : .blue.opacity(0.35)
    }
}

struct OverlayToggles: View {
    @Binding var overlays: AnalyticalOverlays

    var body: some View {
        ViewThatFits {
            HStack {
                Toggle("COM", isOn: $overlays.centreOfMass)
                Toggle("BOS", isOn: $overlays.baseOfSupport)
                Toggle("Load", isOn: $overlays.limbLoad)
                Toggle("Diff", isOn: $overlays.divergenceVectors)
            }
            .toggleStyle(.button)
            .font(.caption)

            VStack(alignment: .leading) {
                Toggle("Centre of mass", isOn: $overlays.centreOfMass)
                Toggle("Base of support", isOn: $overlays.baseOfSupport)
                Toggle("Limb load", isOn: $overlays.limbLoad)
                Toggle("Divergence", isOn: $overlays.divergenceVectors)
            }
            .font(.caption)
        }
    }
}

// MARK: - Panes

struct ClimberPane: View {
    @Environment(AppModel.self) private var model
    let title: String
    let video: VideoRef?
    /// Only for the frame timestamp — the pane draws video, nothing derived.
    let pose: PoseSequence
    let frameIndex: Int?
    /// Why there is no frame, when there isn't one. "Not reached" and
    /// "different order" are opposite claims about the climber, and the pane
    /// used to assert the first for both.
    var unavailableReason: String = "not reached"

    @State private var image: CGImage?
    @State private var cache = FrameImageCache()

    var body: some View {
        VStack(spacing: 2) {
            Text(title).font(.caption2).foregroundStyle(.secondary)
            ZStack {
                if let image {
                    Image(decorative: image, scale: 1)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                } else {
                    Rectangle().fill(Color(white: 0.9))
                        .overlay { Text("no frame").font(.caption2).foregroundStyle(.secondary) }
                }
                // No skeleton over video. Two differently-sized bodies with
                // stick figures drawn on them read as clutter, and the video
                // modes are for watching the climb — the skeleton and its
                // analytical overlays belong in skeleton-only mode, which
                // exists precisely because they are illegible over footage.
                if frameIndex == nil {
                    Text(unavailableReason)
                        .font(.caption)
                        .padding(4)
                        .background(.thinMaterial)
                }
            }
        }
        .task(id: frameIndex) { await load() }
    }

    private func load() async {
        guard let video, let frameIndex, let frame = pose.frame(at: frameIndex) else {
            image = nil
            return
        }
        guard let url = await model.videoURL(video) else { return }
        image = await cache.image(url: url, seconds: frame.timeSeconds)
    }
}

/// Overlay mode. The reference frame is warped into the attempt's wall space
/// and composited over it, so you see one climber through the other.
///
/// Video only — no skeletons. Drawing stick figures on top of two bodies that
/// are already superimposed is what made this mode unreadable; the wall lines
/// up and the humans do not, and adding line art over that does not help.
/// Skeletons and the analytical overlays live in skeleton-only mode.
struct OverlayPane: View {
    @Environment(AppModel.self) private var model
    let processed: ProcessedSession
    let referenceFrameIndex: Int
    let attemptFrameIndex: Int?

    @State private var attemptImage: CGImage?
    @State private var referenceImage: CGImage?
    @State private var cache = FrameImageCache()

    var body: some View {
        ZStack {
            if let attemptImage {
                Image(decorative: attemptImage, scale: 1).resizable().aspectRatio(contentMode: .fit)
            } else {
                Rectangle().fill(Color(white: 0.9))
            }
            if let referenceImage {
                Image(decorative: referenceImage, scale: 1)
                    .resizable().aspectRatio(contentMode: .fit)
                    .opacity(0.4)
            }
            if !processed.alignment.succeeded {
                VStack {
                    Text("Registration failed — the two clips are not aligned. Treat this overlay as unreliable.")
                        .font(.caption)
                        .padding(6)
                        .background(.thinMaterial)
                    Spacer()
                }
            }
        }
        .task(id: attemptFrameIndex) { await load() }
    }

    private func load() async {
        guard let attempt = processed.attempt,
              let attemptURL = await model.videoURL(attempt),
              let referenceRef = processed.session.reference,
              let referenceURL = await model.videoURL(referenceRef) else { return }

        if let attemptFrameIndex, let frame = processed.attemptPose.frame(at: attemptFrameIndex) {
            attemptImage = await cache.image(url: attemptURL, seconds: frame.timeSeconds)
        }
        if let frame = processed.referencePose.frame(at: referenceFrameIndex),
           let raw = await cache.image(url: referenceURL, seconds: frame.timeSeconds) {
            // Wall space is the reference's own frame, so the reference is
            // warped by the inverse to land in the attempt's frame.
            if let inverse = processed.alignment.homography.inverted,
               let warped = WallAligner.warp(raw, by: inverse, like: raw) {
                referenceImage = warped
            } else {
                referenceImage = raw
            }
        }
    }
}
