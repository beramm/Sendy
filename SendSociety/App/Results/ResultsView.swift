import SwiftUI

private enum ResultsDisplayMode: String, CaseIterable, Identifiable {
    case sideBySide = "Side by Side"
    case overlay = "Overlay"

    var id: String { rawValue }
}

struct ResultsView: View {
    private static let playbackStep = 0.125

    @Environment(AppModel.self) private var model

    @State private var displayMode: ResultsDisplayMode = .sideBySide
    @State private var skeletonEnabled = false
    /// One switch, not six. The skeleton button asks for the body; this asks
    /// for everything measured about it. Two states are legible standing at a
    /// wall; a list of six checkboxes is not.
    @State private var liveAnalytics = false
    /// Which chip the sequence strip currently holds in its middle. Bound to
    /// the scroll view, so it tracks a drag as well as a tap.
    @State private var centredSequence: Int?
    @State private var sharedVideo: SharedVideo?
    @State private var position = MovePosition()
    @State private var isPlaying = false
    @State private var isScrubbing = false
    @State private var showNumbers = false
    @State private var frameCache = FrameImageCache()
    private let showsPreviewArtwork: Bool

    init(
        initialPosition: MovePosition = MovePosition(),
        showsPreviewArtwork: Bool = false
    ) {
        _position = State(initialValue: initialPosition)
        self.showsPreviewArtwork = showsPreviewArtwork
    }

    var body: some View {
        ZStack {
            AppBackground()

            if let processed = model.processed,
               !processed.sequences.sequences.isEmpty {
                results(processed)
            } else {
                unavailableState
            }
        }
        .foregroundStyle(.white)
        .navigationBarBackButtonHidden(true)
        .toolbar(.hidden, for: .navigationBar)
        .task(id: isPlaying) { await runPlayback() }
    }

    private func results(_ processed: ProcessedSession) -> some View {
        GeometryReader { geometry in
            ScrollView {
                VStack(spacing: 0) {
                    header
                        .padding(.bottom, 16)

                    comparison(processed)
                        .frame(height: comparisonHeight(for: geometry.size, processed: processed))

                    sequencePicker(processed)
                        .padding(.top, 20)

                    playbackControls
                        .padding(.top, 18)

                    insightCards(processed)
                        .padding(.top, 18)

                    numbersButton(processed)
                        .padding(.top, 18)
                        .padding(.bottom, 24)
                }
                .padding(.horizontal, 18)
                .frame(minHeight: geometry.size.height, alignment: .top)
            }
            .scrollIndicators(.hidden)
        }
        .sheet(isPresented: $showNumbers) {
            if let insight = currentInsight(processed) {
                ResultNumbersSheet(insight: insight)
            }
        }
        .onChange(of: displayMode) { _, mode in
            if mode == .overlay { skeletonEnabled = true }
        }
        // Live Analytics draws onto the body, so it implies the body. Asking
        // for it with the skeleton off produced a screen where the switch did
        // nothing visible in Side by Side.
        .onChange(of: liveAnalytics) { _, on in
            if on { skeletonEnabled = true }
        }
        // And the implication holds in reverse. Dismissing the skeleton
        // dismisses everything drawn on it, so a Live Analytics switch left
        // ticked afterwards is reporting a state the screen is not in.
        .onChange(of: skeletonEnabled) { _, on in
            if !on { liveAnalytics = false }
        }
        .onChange(of: position.sectionIndex) { _, _ in
            isPlaying = false
            position.offset = 0
        }
        .onAppear { clampPosition(to: processed) }
        .sheet(item: $sharedVideo) { shared in
            VideoShareSheet(url: shared.url)
        }
    }

    private var header: some View {
        VStack(spacing: 10) {
            HStack {
                Spacer()
                Button(action: closeResults) {
                    Image(systemName: "xmark")
                        .font(.system(size: 25, weight: .light))
                        .foregroundStyle(ResultsStyle.secondaryText)
                        .frame(width: 38, height: 38)
                        .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Return to clips")
            }

            HStack(spacing: 10) {
                HStack(spacing: 4) {
                    ForEach(ResultsDisplayMode.allCases) { mode in
                        Button {
                            displayMode = mode
                        } label: {
                            Text(mode.rawValue)
                                .font(.system(size: 17, weight: .regular))
                                .foregroundStyle(
                                    displayMode == mode
                                        ? Color.black
                                        : ResultsStyle.secondaryText
                                )
                                .frame(maxWidth: .infinity, minHeight: 36)
                                .background(
                                    displayMode == mode ? Color.white : Color.clear,
                                    in: .rect(cornerRadius: ResultsStyle.controlCornerRadius - 3)
                                )
                        }
                        .buttonStyle(.plain)
                        .accessibilityAddTraits(displayMode == mode ? .isSelected : [])
                    }
                }
                .padding(4)
                .background(
                    ResultsStyle.controlSurface,
                    in: .rect(cornerRadius: ResultsStyle.controlCornerRadius + 2)
                )
                .accessibilityElement(children: .contain)
                .accessibilityLabel("Video display")

                Button {
                    guard displayMode == .sideBySide else { return }
                    skeletonEnabled.toggle()
                } label: {
                    Image("ResultsSkeleton")
                        .renderingMode(.template)
                        .resizable()
                        .scaledToFit()
                        .frame(width: 25, height: 24)
                        .foregroundStyle(
                            skeletonIsActive
                                ? Color.black
                                : ResultsStyle.secondaryText
                        )
                        .frame(width: 58, height: 42)
                        .background(
                            skeletonIsActive ? AppTheme.accent : ResultsStyle.controlSurface,
                            in: .rect(cornerRadius: ResultsStyle.controlCornerRadius)
                        )
                }
                .buttonStyle(.plain)
                .allowsHitTesting(displayMode == .sideBySide)
                .accessibilityLabel("Skeleton comparison")
                .accessibilityValue(skeletonIsActive ? "On" : "Off")

                Menu {
                    Toggle(isOn: $liveAnalytics) {
                        Label("Show Live Analytics", systemImage: "chart.xyaxis.line")
                    }
                    // The clip as imported, handed to the share sheet — which
                    // carries "Save Video" for Photos, so it covers getting
                    // footage off the phone without the app asking for library
                    // write access of its own.
                    Button {
                        share(model.processed?.session.reference)
                    } label: {
                        Label {
                            Text("Export ")
                                + Text("REF").foregroundColor(ResultsStyle.reference)
                                + Text(" Video")
                        } icon: {
                            Image(systemName: "square.and.arrow.down")
                        }
                    }
                    .disabled(model.processed?.session.reference == nil)

                    Button {
                        share(model.processed?.attempt)
                    } label: {
                        Label {
                            Text("Export ")
                                + Text("YOU").foregroundColor(ResultsStyle.attempt)
                                + Text(" Video")
                        } icon: {
                            Image(systemName: "square.and.arrow.down")
                        }
                    }
                    .disabled(model.processed?.attempt == nil)
                } label: {
                    Image(systemName: "ellipsis")
                        .font(.system(size: 18, weight: .bold))
                        .foregroundStyle(.white)
                        .frame(width: 46, height: 42)
                        .background(
                            ResultsStyle.controlSurface,
                            in: .rect(cornerRadius: ResultsStyle.controlCornerRadius)
                        )
                }
                .accessibilityLabel("Overlay options")
            }
        }
        .padding(.top, 2)
    }

    @ViewBuilder
    private func comparison(_ processed: ProcessedSession) -> some View {
        let frames = resolvedFrames(processed)

        switch displayMode {
        case .overlay:
            GeometryReader { geometry in
                SkeletonCanvas(
                    referenceFrame: processed.referencePose.frame(at: frames.reference),
                    attemptFrame: frames.attempt.flatMap { processed.attemptPose.frame(at: $0) },
                    referenceMetrics: processed.referenceMetrics.frame(at: frames.reference),
                    attemptMetrics: frames.attempt.flatMap { processed.attemptMetrics.frame(at: $0) },
                    referenceScale: processed.referenceScale,
                    attemptScale: processed.attemptScale,
                    // No route, and holds forced off whatever the toggles
                    // say — the same call `SkeletonOverlayPane` makes, for the
                    // same reason: the wall plate is in the picture already,
                    // and numbered circles drawn over real holds are noise.
                    route: nil,
                    overlays: overlays.withoutHolds,
                    // Overlay is spatial evidence, so retain each climber's tracked
                    // size instead of normalizing both bodies to one torso length.
                    normalizeBodyLength: false,
                    // The card supplies the dark fallback around a missing wall
                    // plate; do not paint the diagnostic canvas's gray fill.
                    drawsBackground: false,
                    wallPlate: processed.wallPlate?.image
                )
                // Keep the wall image at exactly one Side by Side pane's size,
                // then center that single comparison pane in the full row.
                .frame(width: max(0, (geometry.size.width - 4) / 2), height: geometry.size.height)
                .background(ResultsStyle.panelSurface)
                .clipShape(.rect(cornerRadius: ResultsStyle.paneCornerRadius))
                .overlay {
                    RoundedRectangle(
                        cornerRadius: ResultsStyle.paneCornerRadius,
                        style: .continuous
                    )
                    .stroke(Color.white.opacity(0.10), lineWidth: 0.5)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
            }

        case .sideBySide:
            HStack(spacing: 4) {
                if skeletonEnabled {
                    SkeletonOverlayPane(
                        title: "Reference",
                        video: processed.session.reference,
                        pose: processed.referencePose,
                        frameIndex: frames.reference,
                        metrics: processed.referenceMetrics.frame(at: frames.reference),
                        scale: processed.referenceScale,
                        colour: ResultsStyle.reference,
                        transform: nil,
                        overlays: overlays,
                        scrubbing: isScrubbing,
                        cache: frameCache,
                        badgeLabel: "REF",
                        badgeColor: ResultsStyle.reference
                    )
                    SkeletonOverlayPane(
                        title: processed.attempt?.label.nonEmpty ?? "You",
                        video: processed.attempt,
                        pose: processed.attemptPose,
                        frameIndex: frames.attempt,
                        metrics: frames.attempt.flatMap { processed.attemptMetrics.frame(at: $0) },
                        scale: processed.attemptScale,
                        colour: ResultsStyle.attempt,
                        transform: processed.alignment.homography.inverted,
                        overlays: overlays,
                        scrubbing: isScrubbing,
                        cache: frameCache,
                        badgeLabel: "YOU",
                        badgeColor: ResultsStyle.attempt,
                        unavailableReason: "Not reached"
                    )
                } else {
                    ComparisonVideoPane(
                        title: "Reference",
                        video: processed.session.reference,
                        pose: processed.referencePose,
                        frameIndex: frames.reference,
                        scrubbing: isScrubbing,
                        cache: frameCache,
                        badgeLabel: "REF",
                        badgeColor: ResultsStyle.reference,
                        showsPreviewArtwork: showsPreviewArtwork
                    )
                    ComparisonVideoPane(
                        title: processed.attempt?.label.nonEmpty ?? "You",
                        video: processed.attempt,
                        pose: processed.attemptPose,
                        frameIndex: frames.attempt,
                        scrubbing: isScrubbing,
                        cache: frameCache,
                        badgeLabel: "YOU",
                        badgeColor: ResultsStyle.attempt,
                        showsPreviewArtwork: showsPreviewArtwork,
                        unavailableReason: "Not reached"
                    )
                }
            }
        }
    }

    private func sequencePicker(_ processed: ProcessedSession) -> some View {
        let sequences = processed.sequences.sequences

        return HStack(spacing: 8) {
            Button { selectSequence(position.sectionIndex - 1, processed: processed) } label: {
                Image(systemName: "chevron.left")
                    .frame(width: 28, height: 48)
            }
            .buttonStyle(.plain)
            .disabled(position.sectionIndex == 0)

            GeometryReader { geometry in
                ScrollViewReader { proxy in
                    ScrollView(.horizontal) {
                        HStack(spacing: 8) {
                            ForEach(sequences) { sequence in
                                let selected = sequence.index == position.sectionIndex
                                let containsFall = sequenceContainsFall(sequence, processed: processed)
                                let hasDifferentMoveCount = sequence.moveCountDelta != 0

                                Button {
                                    selectSequence(sequence.index, processed: processed)
                                } label: {
                                    Text("\(sequence.index + 1)")
                                        .font(.system(
                                            size: 17,
                                            weight: selected ? .bold : .regular,
                                            design: .monospaced
                                        ))
                                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                                        .foregroundStyle(sequenceForeground(
                                            containsFall: containsFall,
                                            hasDifferentMoveCount: hasDifferentMoveCount
                                        ))
                                        .frame(
                                            width: sequenceButtonWidth(
                                                selected: selected,
                                                hasDifferentMoveCount: hasDifferentMoveCount
                                            ),
                                            height: selected ? 48 : 40
                                        )
                                        .background(
                                            sequenceBackground(
                                                containsFall: containsFall,
                                                hasDifferentMoveCount: hasDifferentMoveCount
                                            ),
                                            in: .rect(cornerRadius: 15)
                                        )
                                        .animation(.snappy(duration: 0.2), value: selected)
                                }
                                .buttonStyle(.plain)
                                .accessibilityLabel("Sequence \(sequence.index + 1) of \(sequences.count)")
                                .accessibilityValue(sequenceAccessibilityValue(
                                    containsFall: containsFall,
                                    hasDifferentMoveCount: hasDifferentMoveCount
                                ))
                                .accessibilityAddTraits(selected ? .isSelected : [])
                                .id(sequence.index)
                            }
                        }
                        .frame(minHeight: 52)
                        .scrollTargetLayout()
                    }
                    .scrollIndicators(.hidden)
                    // Half a pane of empty space at each end, so *every* chip
                    // can reach the middle. Without it a scroll can centre the
                    // interior of the list and nothing else: there is no
                    // content to the left of the first chip or the right of the
                    // last, so those two stay pinned to their edge — and
                    // sequence 1 is exactly where every run starts. As a
                    // content margin rather than padding on the stack, so
                    // `viewAligned` snapping measures from it and a chip comes
                    // to rest in the middle instead of against the edge.
                    .contentMargins(
                        .horizontal,
                        max(0, geometry.size.width / 2 - 36),
                        for: .scrollContent
                    )
                    // The strip is a picker, not a filmstrip: it settles on a
                    // chip rather than between two.
                    .scrollTargetBehavior(.viewAligned)
                    // **Scrolling selects.** Dragging a chip to the middle and
                    // having nothing happen is the bug this closes — the middle
                    // is where selection is *shown*, so it has to be where
                    // selection is *made* too.
                    .scrollPosition(id: $centredSequence, anchor: .center)
                    .onChange(of: centredSequence) { _, id in
                        guard let id, id != position.sectionIndex else { return }
                        selectSequence(id, processed: processed)
                    }
                    // Fade the strip out at both ends instead of letting the
                    // scroll view guillotine a chip mid-digit. The half-pane
                    // insets guarantee there is always more list past the edge,
                    // so something is always being cut — a chip dissolving into
                    // the background reads as "the list continues", where a
                    // hard vertical slice through a number reads as a layout
                    // bug.
                    .mask(
                        LinearGradient(
                            stops: [
                                .init(color: .clear, location: 0),
                                .init(color: .black, location: 0.07),
                                .init(color: .black, location: 0.93),
                                .init(color: .clear, location: 1)
                            ],
                            startPoint: .leading,
                            endPoint: .trailing
                        )
                    )
                    // Selection is marked by position, not by colour: the chosen
                    // chip slides to the middle. Matched to the chip's own
                    // `.snappy(duration: 0.2)` so growing and sliding read as one
                    // movement.
                    // Only for selections the scroll did not make itself —
                    // a tap or a chevron. Without the guard the two directions
                    // fight: a drag reports a new centre, that sets the
                    // selection, and the selection scrolls the strip out from
                    // under the finger that is still on it.
                    .onChange(of: position.sectionIndex) { _, index in
                        guard centredSequence != index else { return }
                        withAnimation(.snappy(duration: 0.2)) {
                            proxy.scrollTo(index, anchor: .center)
                        }
                    }
                    // A screen entered on a mid-list sequence starts centered
                    // rather than scrolling into place after the fact. `task`
                    // rather than `onAppear`: the first layout pass has not
                    // placed the chips yet when `onAppear` fires, so the scroll
                    // lands on nothing and sequence 1 stays at the leading edge.
                    .task {
                        centredSequence = position.sectionIndex
                        proxy.scrollTo(position.sectionIndex, anchor: .center)
                    }
                }
            }
            .frame(height: 52)

            Button { selectSequence(position.sectionIndex + 1, processed: processed) } label: {
                Image(systemName: "chevron.right")
                    .frame(width: 28, height: 48)
            }
            .buttonStyle(.plain)
            .disabled(position.sectionIndex >= sequences.count - 1)
        }
        // A detent tick as each chip passes through the middle. Triggered off
        // the centred chip rather than off `position`, so the feedback lands
        // with the movement under the finger rather than after the selection it
        // causes — and so a flick across several sequences ticks for each one.
        .sensoryFeedback(.selection, trigger: centredSequence)
    }

    private var playbackControls: some View {
        HStack(spacing: 12) {
            Button {
                if position.offset >= 1 { position.offset = 0 }
                isPlaying.toggle()
            } label: {
                Image(systemName: isPlaying ? "pause.fill" : "play.fill")
                    .font(.system(size: 24, weight: .semibold))
                    .frame(width: 44, height: 44)
                    .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(isPlaying ? "Pause" : "Play")

            Slider(value: $position.offset, in: 0 ... 1) { editing in
                isScrubbing = editing
                if editing { isPlaying = false }
            }
            .tint(.white)
        }
    }

    private func insightCards(_ processed: ProcessedSession) -> some View {
        let insight = currentInsight(processed)
        let count = processed.sequences.sequences.count

        return VStack(spacing: 14) {
            HStack(spacing: 7) {
                Text("Sequence")
                    .fontWeight(.regular)
                    .foregroundStyle(ResultsStyle.secondaryText)

                Text("\(position.sectionIndex + 1) of \(count)")
                    .fontWeight(.bold)
                    .foregroundStyle(.white)
            }
            .font(.system(size: 15, design: .monospaced))
            .accessibilityElement(children: .combine)
            .accessibilityLabel("Sequence \(position.sectionIndex + 1) of \(count)")

            HStack(alignment: .top, spacing: 8) {
                differenceCard(
                    label: "REF",
                    color: ResultsStyle.reference,
                    duration: referenceDurationLabel(processed),
                    finding: insight?.referenceFinding
                )
                differenceCard(
                    label: "YOU",
                    color: ResultsStyle.attempt,
                    duration: attemptDurationLabel(processed),
                    finding: insight?.attemptFinding
                )
            }
        }
    }

    private func differenceCard(
        label: String,
        color: Color,
        duration: String,
        finding: SequenceDifferenceFinding?
    ) -> some View {
        let resolved = finding ?? .unavailable("No sequence finding was produced.")
        let sentence = resolved.sentence(
            subject: label == "YOU" ? "You" : "The reference",
            causeSubject: label == "YOU" ? "you" : "they"
        )

        return VStack(spacing: 9) {
            HStack(alignment: .center) {
                Text(label)
                    .font(.system(size: 12, weight: .bold, design: .monospaced))
                    .foregroundStyle(color)
                    .padding(.horizontal, 10)
                    .frame(minHeight: 28)
                    .background(Color.black.opacity(0.72), in: .capsule)

                Spacer(minLength: 4)

                Text(duration)
                    .font(.system(size: 12, weight: .regular, design: .monospaced))
                    .foregroundStyle(ResultsStyle.secondaryText)
            }

            Spacer(minLength: 0)

            Text(sentence)
            .font(.system(size: 16, weight: .medium))
            .foregroundStyle(resolved.isAvailable ? Color.white : ResultsStyle.secondaryText)
            .multilineTextAlignment(.leading)
            .lineLimit(nil)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)

            Spacer(minLength: 0)
        }
        .padding(12)
        .frame(maxWidth: .infinity, minHeight: 112)
        .background(
            ResultsStyle.panelSurface,
            in: .rect(cornerRadius: ResultsStyle.panelCornerRadius)
        )
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(label), \(duration), \(sentence)")
        .accessibilityValue(resolved.unavailableReason ?? "")
    }

    private func numbersButton(_ processed: ProcessedSession) -> some View {
        let insight = currentInsight(processed)
        let canExplainState = insight != nil

        return Button { showNumbers = true } label: {
            HStack {
                Text("Detailed Analytics")
                    .font(.system(size: 18, weight: .regular, design: .monospaced))
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.system(size: 17, weight: .semibold))
            }
            .foregroundStyle(
                canExplainState
                    ? ResultsStyle.secondaryText
                    : Color.secondary
            )
            .padding(.horizontal, 24)
            .frame(maxWidth: .infinity, minHeight: 56)
            .background(
                ResultsStyle.panelSurface,
                in: .rect(cornerRadius: ResultsStyle.panelCornerRadius)
            )
        }
        .buttonStyle(.plain)
        // The sheet owns both the metric list and its empty explanation. Keep
        // this tappable when an analysis exists so low-confidence tracking does
        // not look like a broken control with no way to learn what happened.
        .disabled(!canExplainState)
    }

    private var unavailableState: some View {
        ContentUnavailableView {
            Label("No results yet", systemImage: "figure.climbing")
        } description: {
            Text("Process both clips before opening the comparison.")
        } actions: {
            Button("Return to clips", action: closeResults)
                .tint(AppTheme.accent)
                .buttonStyle(.borderedProminent)
        }
    }

    private var overlays: AnalyticalOverlays {
        liveAnalytics ? .live : .clean
    }

    private var skeletonIsActive: Bool {
        displayMode == .overlay || skeletonEnabled
    }

    private func sequenceContainsFall(_ sequence: ClimbSequence, processed: ProcessedSession) -> Bool {
        guard let fallIndex = processed.fallReport.fallSectionIndex else { return false }
        return sequence.referenceMoves.contains(fallIndex)
    }

    private func sequenceBackground(
        containsFall: Bool,
        hasDifferentMoveCount: Bool
    ) -> Color {
        if containsFall { return .red }
        if hasDifferentMoveCount { return AppTheme.accent }
        return ResultsStyle.panelSurface
    }

    private func sequenceButtonWidth(
        selected: Bool,
        hasDifferentMoveCount: Bool
    ) -> CGFloat {
        if selected { return 72 }
        if hasDifferentMoveCount { return 64 }
        return 52
    }

    private func sequenceForeground(
        containsFall: Bool,
        hasDifferentMoveCount: Bool
    ) -> Color {
        if containsFall { return .white }
        if hasDifferentMoveCount { return AppTheme.background }
        return ResultsStyle.secondaryText
    }

    private func sequenceAccessibilityValue(
        containsFall: Bool,
        hasDifferentMoveCount: Bool
    ) -> String {
        var states: [String] = []
        if containsFall { states.append("Fall detected in this sequence") }
        if hasDifferentMoveCount { states.append("Different number of moves") }
        return states.joined(separator: ", ")
    }

    private func currentInsight(_ processed: ProcessedSession) -> SequenceAnalysis? {
        guard let sequence = currentSequence(processed) else { return nil }
        return processed.analysis(forSequence: sequence.index)
    }

    private func resolvedFrames(_ processed: ProcessedSession) -> (reference: Int, attempt: Int?) {
        guard let sequence = currentSequence(processed) else { return (0, nil) }
        let referenceFrame = frame(in: sequence.referenceRange, offset: position.offset)
        let path = processed.sequenceWarpPaths.first { $0.sectionIndex == sequence.index }
        return (referenceFrame, path?.attemptFrame(forReference: referenceFrame))
    }

    private func currentSequence(_ processed: ProcessedSession) -> ClimbSequence? {
        let sequences = processed.sequences.sequences
        guard sequences.indices.contains(position.sectionIndex) else { return nil }
        return sequences[position.sectionIndex]
    }

    private func frame(in range: Range<Int>, offset: Double) -> Int {
        guard !range.isEmpty else { return range.lowerBound }
        return range.lowerBound + Int(
            (Double(range.count - 1) * offset.clamped(to: 0 ... 1)).rounded()
        )
    }

    /// Resolves a clip's on-disk location and hands it to the share sheet.
    ///
    /// The lookup is asynchronous, so the sheet is driven by the resolved URL
    /// rather than presented first and filled in later — a share sheet that
    /// opens on nothing is worse than one that opens a moment after the tap.
    private func share(_ video: VideoRef?) {
        guard let video else { return }
        Task {
            guard let url = await model.videoURL(video) else { return }
            sharedVideo = SharedVideo(url: url)
        }
    }

    private func selectSequence(_ index: Int, processed: ProcessedSession) {
        let upper = max(0, processed.sequences.sequences.count - 1)
        position = MovePosition(sectionIndex: index.clamped(to: 0 ... upper), offset: 0)
        isPlaying = false
    }

    private func clampPosition(to processed: ProcessedSession) {
        let upper = max(0, processed.sequences.sequences.count - 1)
        position.sectionIndex = position.sectionIndex.clamped(to: 0 ... upper)
        position.offset = position.offset.clamped(to: 0 ... 1)
    }

    private func comparisonHeight(for size: CGSize, processed: ProcessedSession) -> CGFloat {
        // Both display modes use one Side by Side pane's dimensions. Overlay
        // presents that same-size surface centered in the full comparison row.
        let availableWidth = max(0, size.width - 36)
        let paneWidth = max(0, (availableWidth - 4) / 2)
        let sourceAspect = CGFloat(processed.referencePose.xScale)
        guard sourceAspect.isFinite, sourceAspect > 0 else {
            return min(430, max(320, size.height * 0.43))
        }
        return paneWidth / sourceAspect
    }

    private func referenceDurationLabel(_ processed: ProcessedSession) -> String {
        guard let sequence = currentSequence(processed) else { return "—" }
        return clock(duration(of: sequence.referenceRange, in: processed.referencePose))
    }

    private func attemptDurationLabel(_ processed: ProcessedSession) -> String {
        guard let sequence = currentSequence(processed), sequence.attemptReached else { return "—" }
        return clock(duration(of: sequence.attemptRange, in: processed.attemptPose))
    }

    private func duration(of range: Range<Int>, in pose: PoseSequence) -> Double {
        guard !range.isEmpty,
              let start = pose.frame(at: range.lowerBound)?.timeSeconds,
              let end = pose.frame(at: range.upperBound - 1)?.timeSeconds
        else { return 0 }
        return max(0, end - start)
    }

    private func clock(_ seconds: Double) -> String {
        let whole = max(0, Int(seconds.rounded(.down)))
        return String(format: "%02d:%02d", whole / 60, whole % 60)
    }

    @MainActor
    private func runPlayback() async {
        guard isPlaying else { return }

        while isPlaying && !Task.isCancelled {
            try? await Task.sleep(for: .milliseconds(125))
            guard !Task.isCancelled, let processed = model.processed,
                  let sequence = currentSequence(processed)
            else { return }

            let seconds = max(0.1, duration(of: sequence.referenceRange, in: processed.referencePose))
            let next = position.offset + Self.playbackStep / seconds
            if next >= 1 {
                position.offset = 1
                isPlaying = false
            } else {
                position.offset = next
            }
        }
    }

    private func closeResults() {
        isPlaying = false
        if let setupIndex = model.path.lastIndex(of: .setup) {
            model.path = Array(model.path.prefix(setupIndex + 1))
        } else {
            model.path.removeAll()
        }
    }
}

private extension String {
    var nonEmpty: String? { isEmpty ? nil : self }
}
