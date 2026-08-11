import SwiftUI

/// Position on the climb, expressed as **move N of M plus an offset within the
/// move**. There is no shared clock — one climber may take 4s through a move
/// and the other 11s — so there is no time-indexed scrubber to reconcile later.
struct MovePosition: Equatable {
    var sectionIndex: Int = 0
    /// 0...1 within the move.
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
                NavigationLink("Moves") { SectionListView(jumpTo: jump) }
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
                    unavailableReason: processed.sections.indices.contains(position.sectionIndex)
                        ? (processed.sections[position.sectionIndex].unavailableReason ?? "not reached")
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
        guard processed.sections.indices.contains(position.sectionIndex) else { return (0, nil) }
        let section = processed.sections[position.sectionIndex]
        let referenceFrame = frame(in: section.referenceRange, offset: position.offset)

        if syncLocked {
            let attempt = processed.warpPath(forSection: section.index)?.attemptFrame(forReference: referenceFrame)
            return (referenceFrame, attempt)
        }
        // Unlocked: the attempt pane scrubs on its own clock. The escape hatch
        // exists because DTW will sometimes misalign a move, and locked mode
        // makes that failure impossible to inspect.
        guard section.attemptReached else { return (referenceFrame, nil) }
        return (referenceFrame, frame(in: section.attemptRange, offset: attemptOffsetOverride ?? position.offset))
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
                if let fall = processed.fallAnalysis,
                   fall.sectionIndex == position.sectionIndex || processed.fallReport.distalSectionIndex == position.sectionIndex {
                    Text(fall.headline).font(.headline).foregroundStyle(.red)
                    ForEach(fall.observations) { AnalysisNoteRow(note: $0) }
                    Button("Show me why") { drillIntoFall(processed) }
                        .font(.caption)
                }
                if let analysis = processed.analysis(forSection: position.sectionIndex) {
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

    private func jump(to sectionIndex: Int) {
        position = MovePosition(sectionIndex: sectionIndex, offset: 0)
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
            if let index = processed.fallReport.fallSectionIndex { jump(to: index) }
            return
        }
        // The frame is an attempt frame; walk the DTW path back to a reference
        // frame so the scrubber lands on the same move.
        let offset: Double
        if section.attemptRange.count > 1 {
            offset = Double(frameIndex - section.attemptRange.lowerBound) / Double(section.attemptRange.count - 1)
        } else {
            offset = 0
        }
        position = MovePosition(sectionIndex: section.index, offset: offset)
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
                        sectionIndex: min(processed.sections.count - 1, position.sectionIndex + 1),
                        offset: 0
                    )
                } label: { Image(systemName: "chevron.right") }
                .disabled(position.sectionIndex >= processed.sections.count - 1)
            }

            Slider(value: $position.offset, in: 0 ... 1)

            // Section markers and the fall marker fall out of move indexing
            // naturally.
            HStack(spacing: 2) {
                ForEach(processed.sections) { section in
                    Rectangle()
                        .fill(colour(for: section))
                        .frame(height: 10)
                        .overlay {
                            if processed.fallReport.fallSectionIndex == section.index {
                                Text("F").font(.system(size: 8, weight: .bold)).foregroundStyle(.white)
                            } else if processed.fallReport.distalSectionIndex == section.index {
                                Text("·").font(.system(size: 8, weight: .bold)).foregroundStyle(.white)
                            }
                        }
                        .onTapGesture {
                            position = MovePosition(sectionIndex: section.index, offset: 0)
                        }
                }
            }

            Toggle("Sync locked to the reference climber's move", isOn: $syncLocked)
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
        guard processed.sections.indices.contains(position.sectionIndex) else { return "no moves" }
        let section = processed.sections[position.sectionIndex]
        var text = "Move \(position.sectionIndex + 1) of \(processed.sections.count)  \(Int(position.offset * 100))%"
        if let reason = section.unavailableReason { text += "  (\(reason))" }
        switch section.divergence?.kind {
        case .truncated: text += "  (came off here)"
        case .some: text += "  (different sequence)"
        case .none: break
        }
        return text
    }

    private func colour(for section: Section) -> Color {
        if processed.fallReport.fallSectionIndex == section.index { return .red }
        if section.divergence != nil { return .orange }
        if !section.attemptReached { return .gray }
        return section.index == position.sectionIndex ? .blue : .blue.opacity(0.35)
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
