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
        ZStack {
            AppBackground()
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
        }
        .navigationTitle("Results")
    }

    @ViewBuilder
    private func content(_ processed: ProcessedSession) -> some View {
        if processed.sections.isEmpty {
            // Task 5.8 — legible, not pretty.
            VStack(spacing: 8) {
                errorPanel(processed)
                footer(processed)
            }
            .sheet(isPresented: $showWarnings) { warningsSheet(processed) }
        } else {
            // **The page scrolls, not a panel inside it.**
            //
            // Every fixed-height box on this screen was competing with the
            // video for the same points, and the analysis text ended up in a
            // 140pt window with its own scrollbar — a scroll gesture that only
            // worked if your thumb landed on the right third of the screen.
            // One outer scroll view puts every gesture in the same place and
            // lets the video keep a real share of the height.
            GeometryReader { geometry in
                ScrollView {
                    VStack(spacing: 8) {
                        Picker("Mode", selection: $mode) {
                            ForEach(ComparisonMode.allCases) { Text($0.label).tag($0) }
                        }
                        .pickerStyle(.segmented)
                        .padding(.horizontal)

                        // A definite height: `maxHeight: .infinity` inside a
                        // scroll view resolves to the content's own ideal size,
                        // which for a video pane is nothing.
                        comparison(processed)
                            .frame(height: max(300, geometry.size.height * 0.62))

                        MoveScrubber(
                            processed: processed,
                            position: $position,
                            syncLocked: $syncLocked,
                            attemptOffsetOverride: $attemptOffsetOverride
                        )
                        .padding(.horizontal)

                        if mode == .skeletonOnly || mode == .skeletonOverlay {
                            OverlayToggles(
                                overlays: $overlays,
                                showsDivergence: mode == .skeletonOnly,
                                showsBackdrop: mode == .skeletonOnly && processed.wallPlate != nil
                            )
                                .padding(.horizontal)
                        }

                        currentAnalysis(processed)
                        footer(processed)
                    }
                }
            }
            .sheet(isPresented: $showWarnings) { warningsSheet(processed) }
        }
    }

    @ViewBuilder
    private func footer(_ processed: ProcessedSession) -> some View {
        VStack(spacing: 8) {
            HStack {
                NavigationLink("Moves") { SectionListView(jumpTo: { jump(processed, toMove: $0) }) }
                NavigationLink("Raw metrics") { RawMetricsView() }
                NavigationLink("Route") { RouteCorrectionView() }
                NavigationLink("Tuning") { TuningPanelView() }
                // Stage timings, statuses and warnings. The run no longer has a
                // screen of its own, so this is where it lives.
                NavigationLink("Report", value: AppRoute.report)
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
                Text("pipeline runs: \(model.pipelineRunCount) · \(processed.analyses.first?.source ?? "—")\(model.processingTimeSummary.map { " · \($0)" } ?? "")")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal)
        }
    }

    @ViewBuilder
    private func warningsSheet(_ processed: ProcessedSession) -> some View {
        NavigationStack {
            List(Array(processed.warnings.enumerated()), id: \.offset) { _, warning in
                Text(warning).font(.callout)
            }
            .navigationTitle("Warnings")
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
                overlays: overlays,
                wallPlate: processed.wallPlate?.image
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
        case .skeletonOverlay:
            HStack(spacing: 4) {
                SkeletonOverlayPane(
                    title: "Reference",
                    video: processed.session.reference,
                    pose: processed.referencePose,
                    frameIndex: frames.reference,
                    metrics: processed.referenceMetrics.frame(at: frames.reference),
                    scale: processed.referenceScale,
                    colour: .green,
                    // Wall space is the reference's own image space.
                    transform: nil,
                    overlays: overlays
                )
                SkeletonOverlayPane(
                    title: processed.attempt?.label ?? "Attempt",
                    video: processed.attempt,
                    pose: processed.attemptPose,
                    frameIndex: frames.attempt,
                    metrics: frames.attempt.flatMap { processed.attemptMetrics.frame(at: $0) },
                    scale: processed.attemptScale,
                    colour: .orange,
                    // The attempt's pose was warped into wall space; put it back
                    // into its own frame before drawing it on its own video.
                    transform: processed.alignment.homography.inverted,
                    overlays: overlays,
                    unavailableReason: currentSequence(processed)?.attemptReached == false
                        ? "no footage for this sequence"
                        : "not reached"
                )
            }
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

    /// The long form of the abbreviations in the scrubber label. It lives here,
    /// in a panel that scrolls, rather than under the video where it wrapped to
    /// three lines — and every line under the video is a line of climber.
    private func sequenceExplanation(_ processed: ProcessedSession) -> String? {
        guard let sequence = currentSequence(processed) else { return nil }
        var parts: [String] = []
        let refMoves = sequence.referenceMoves.count
        let attMoves = sequence.attemptMoves.count
        if refMoves != attMoves {
            parts.append("\(refMoves) move\(refMoves == 1 ? "" : "s") for them against \(attMoves) for you")
        }
        if sequence.toAnchorID < 0 {
            parts.append("everything after hold \(sequence.fromAnchorID), the last hold you both used — anchored at one end only, so nothing in it is compared")
        }
        if !sequence.attemptReached { parts.append("no attempt footage in this span") }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    @ViewBuilder
    private func currentAnalysis(_ processed: ProcessedSession) -> some View {
        Group {
            VStack(alignment: .leading, spacing: 6) {
                if let explanation = sequenceExplanation(processed) {
                    Text(explanation).font(.caption).foregroundStyle(.secondary)
                }
                let moveIndices = currentSequence(processed).map { Array($0.referenceMoves) } ?? []
                // **Where you fell and where it started are different claims.**
                //
                // Cross-sequence attribution is the point of the feature, so the
                // fall report deliberately appears on the earlier sequence too —
                // but it showed the same red "You came off on move 5" headline
                // there, which reads as the fall having happened on whichever
                // sequence you are standing on. Same report, two sequences, and
                // no way to tell which one you were looking at.
                if let fall = processed.fallAnalysis {
                    let here = moveIndices.contains(fall.sectionIndex)
                    let startedHere = moveIndices.contains(processed.fallReport.distalSectionIndex ?? -1)
                    if here || startedHere {
                        Text(here ? fall.headline : distalHeadline(processed))
                            .font(.headline)
                            .foregroundStyle(here ? .red : .orange)
                        ForEach(fall.observations) { AnalysisNoteRow(note: $0) }
                        Button(here ? "Show me why" : "Take me to the fall") { drillIntoFall(processed) }
                            .font(.caption)
                    }
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
        // No fixed height and no scroll view of its own: the text flows to its
        // full length and the page carries it. Nothing here is clipped, so
        // there is no hidden content to discover by scrolling the right third
        // of the screen.
    }

    /// Shown on the sequence where the earliest contributing signal fired, which
    /// is not the sequence the climber came off on.
    private func distalHeadline(_ processed: ProcessedSession) -> String {
        let fell = (processed.fallReport.fallSectionIndex ?? 0) + 1
        return "This is where the fall started — you came off later, on move \(fell)."
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
            //
            // **Widths are computed, not expressed as layout priority.** The
            // first version used `.layoutPriority(moveCount)`, which is not a
            // weight — an HStack hands the space to the highest priority first,
            // so the six-move sequence took the whole row and the other two
            // collapsed to nothing. On gym-testing/test1 that rendered as a
            // single red bar with the fall marker in the middle, which reads as
            // "every sequence is the fall".
            GeometryReader { geometry in
                let sequences = processed.sequences.sequences
                let weights = sequences.map { Double(max(1, $0.referenceMoves.count)) }
                let total = max(1, weights.reduce(0, +))
                let gaps = Double(max(0, sequences.count - 1)) * 2
                let available = max(0, geometry.size.width - gaps)
                HStack(spacing: 2) {
                    ForEach(Array(zip(sequences, weights)), id: \.0.id) { sequence, weight in
                        Rectangle()
                            .fill(colour(for: sequence))
                            .frame(width: max(3, available * weight / total), height: 10)
                            .overlay {
                                if moves(of: sequence).contains(where: { processed.fallReport.fallSectionIndex == $0.index }) {
                                    Text("F").font(.system(size: 8, weight: .bold)).foregroundStyle(.white)
                                }
                                // A differing move count shows as the orange bar
                                // and is spelled out in the label above. It was
                                // also printed into the marker as "1v2", which
                                // at 7pt inside a 10pt bar, repeated across
                                // every sequence, was unreadable clutter rather
                                // than a finding.
                            }
                            .onTapGesture {
                                position = MovePosition(sectionIndex: sequence.index, offset: 0)
                            }
                    }
                }
                .frame(width: geometry.size.width, alignment: .leading)
            }
            .frame(height: 10)

            Toggle("Sync locked to the reference's sequence", isOn: $syncLocked)
                .font(.caption)
                .lineLimit(1)
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

    /// One line, because it sits directly under the video and every line it
    /// wraps to is a line of climber taken off the screen. The long forms of
    /// these clauses moved into the analysis panel, which is scrollable.
    private var label: String {
        let sequences = processed.sequences.sequences
        guard sequences.indices.contains(position.sectionIndex) else { return "no sequences" }
        let sequence = sequences[position.sectionIndex]
        var text = "Seq \(position.sectionIndex + 1)/\(sequences.count)  \(Int(position.offset * 100))%"
        // Move counts per climber, which is the finding this layer exists to
        // surface: three moves against one is not a mismatch, it is the
        // difference worth reporting.
        let refMoves = sequence.referenceMoves.count
        let attMoves = sequence.attemptMoves.count
        if refMoves != attMoves { text += "  \(refMoves)v\(attMoves)" }
        if !sequence.attemptReached { text += "  no footage" }
        // The tail has one anchor, not two. Saying so is the difference between
        // "the app compared these and found nothing" and "there is nothing here
        // that can be compared" — and the fall lives in this span.
        if sequence.toAnchorID < 0 { text += "  tail" }
        // Truncation is a claim about the climber coming off, so it is read
        // from the moves inside this sequence rather than assumed from the
        // sequence itself.
        if moves(of: sequence).contains(where: { $0.divergence?.kind == .truncated }) {
            text += "  came off"
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
    /// Divergence vectors join the two climbers' joints, which only means
    /// something on one shared diagram. In skeleton-overlay mode each climber
    /// is on their own footage, so there is no line to draw between them.
    var showsDivergence = true
    /// Off when there is no plate to show — a toggle for a picture that does
    /// not exist reads as a broken toggle. The stage report says why it is
    /// missing.
    var showsBackdrop = true

    var body: some View {
        ViewThatFits {
            HStack {
                Toggle("COM", isOn: $overlays.centreOfMass)
                Toggle("BOS", isOn: $overlays.baseOfSupport)
                Toggle("Load", isOn: $overlays.limbLoad)
                Toggle("Hips", isOn: $overlays.pelvisTriangle)
                Toggle("Plumb", isOn: $overlays.plumbLine)
                Toggle("Knees", isOn: $overlays.kneeLine)
                if showsDivergence { Toggle("Diff", isOn: $overlays.divergenceVectors) }
                if showsBackdrop { Toggle("Wall", isOn: $overlays.wallBackdrop) }
            }
            .toggleStyle(.button)
            .font(.caption)

            VStack(alignment: .leading) {
                Toggle("Centre of mass", isOn: $overlays.centreOfMass)
                Toggle("Base of support", isOn: $overlays.baseOfSupport)
                Toggle("Limb load", isOn: $overlays.limbLoad)
                Toggle("Pelvis triangle", isOn: $overlays.pelvisTriangle)
                Toggle("Plumb line", isOn: $overlays.plumbLine)
                Toggle("Knee over toe", isOn: $overlays.kneeLine)
                if showsDivergence { Toggle("Divergence", isOn: $overlays.divergenceVectors) }
                if showsBackdrop { Toggle("Wall backdrop", isOn: $overlays.wallBackdrop) }
            }
            .font(.caption)
        }

        if showsBackdrop, overlays.wallBackdrop {
            HStack {
                Text("Wash").font(.caption2).foregroundStyle(.secondary)
                Slider(value: $overlays.wallWash, in: 0 ... 1)
                Text(String(format: "%.0f%%", overlays.wallWash * 100))
                    .font(.caption2).monospacedDigit().foregroundStyle(.secondary)
            }
        }

        // A three-state marker nobody can read is a two-state marker plus
        // confusion. The key costs one line and answers the question at the
        // point it gets asked.
        if overlays.pelvisTriangle || overlays.plumbLine {
            Text("Pelvis triangle = hips + pubic bone · yellow = your line, white dashed = vertical")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }

        if overlays.centreOfMass {
            Text("COM  filled = inside BOS · red = outside · white dashed = no polygon")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
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
    @State private var decodeFailure: String?
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
                    Rectangle().fill(Color(.secondarySystemFill))
                        .overlay { Text("no frame").font(.caption2).foregroundStyle(.secondary) }
                }
                // A decode that failed is a different thing from a frame that
                // does not exist, and saying which is the difference between
                // "the pipeline found nothing here" and "the scrubber outran
                // the decoder". The last good frame stays on screen underneath.
                if let decodeFailure {
                    VStack {
                        Spacer()
                        Text(decodeFailure)
                            .font(.caption2)
                            .padding(4)
                            .background(.thinMaterial)
                    }
                }
                // No skeleton here. This pane is for watching the climb; the
                // skeleton over footage is its own mode, where one skeleton
                // sits on one climber in its own pane. Drawing it here as well
                // would put line art over a picture that is already legible.
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

    /// **Never blanks the pane on a failed decode.**
    ///
    /// `.task(id:)` cancels the previous load on every scrubber tick, and a
    /// cancelled `AVAssetImageGenerator` returns nothing. Assigning that nothing
    /// straight into `image` is what made dragging the scrubber flash "no
    /// frame": the pipeline was fine and the decoder was simply behind. The last
    /// good frame stays up, and only a real absence — no frame index, no pose
    /// frame — clears it.
    private func load() async {
        guard let video, let frameIndex, let frame = pose.frame(at: frameIndex) else {
            image = nil
            decodeFailure = nil
            return
        }
        // Settle before decoding. Every scrubber tick cancels the previous
        // load, and a 4K frame takes longer to decode than a drag takes to
        // move — so during a continuous drag no decode ever finished and the
        // pane held its last frame while the skeleton tracked the slider. The
        // sleep is cancelled along with the task, so only the position the
        // finger stopped on actually decodes. First frame is immediate.
        if image != nil {
            try? await Task.sleep(for: .milliseconds(70))
            guard !Task.isCancelled else { return }
        }
        guard let url = await model.videoURL(video) else {
            decodeFailure = "the video file for this clip is missing from the session"
            return
        }
        if let decoded = await cache.image(url: url, seconds: frame.timeSeconds) {
            image = decoded
            decodeFailure = nil
        } else if !Task.isCancelled {
            decodeFailure = String(format: "frame %d (%.2fs) wouldn't decode", frameIndex, frame.timeSeconds)
        }
    }
}
