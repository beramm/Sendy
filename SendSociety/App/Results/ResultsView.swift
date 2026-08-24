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
    @State private var overlays = AnalyticalOverlays()
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

                    insightCard(processed)
                        .padding(.top, 24)

                    numbersButton(processed)
                        .padding(.top, 18)
                        .padding(.bottom, 32)
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
        .onChange(of: position.sectionIndex) { _, _ in
            isPlaying = false
            position.offset = 0
        }
        .onAppear { clampPosition(to: processed) }
    }

    private var header: some View {
        VStack(spacing: 18) {
            HStack {
                Spacer()
                Button(action: closeResults) {
                    Image(systemName: "xmark")
                        .font(.system(size: 28, weight: .light))
                        .foregroundStyle(ResultsStyle.secondaryText)
                        .frame(width: 44, height: 44)
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
                                .frame(maxWidth: .infinity, minHeight: 44)
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
                    Image(systemName: "skew")
                        .font(.system(size: 20, weight: .medium))
                        .foregroundStyle(
                            skeletonIsActive
                                ? Color.black
                                : ResultsStyle.secondaryText
                        )
                        .frame(width: 58, height: 52)
                        .background(
                            skeletonIsActive ? Color.white : ResultsStyle.controlSurface,
                            in: .rect(cornerRadius: ResultsStyle.controlCornerRadius)
                        )
                }
                .buttonStyle(.plain)
                .allowsHitTesting(displayMode == .sideBySide)
                .accessibilityLabel("Skeleton comparison")
                .accessibilityValue(skeletonIsActive ? "On" : "Off")

                Menu {
                    Toggle("Centre of mass", isOn: $overlays.centreOfMass)
                    Toggle("Base of support", isOn: $overlays.baseOfSupport)
                    Toggle("Limb load", isOn: $overlays.limbLoad)
                    Toggle("Pelvis triangle", isOn: $overlays.pelvisTriangle)
                    Toggle("Plumb line", isOn: $overlays.plumbLine)
                    Toggle("Knee over toe", isOn: $overlays.kneeLine)
                } label: {
                    Image(systemName: "ellipsis")
                        .font(.system(size: 18, weight: .bold))
                        .foregroundStyle(.white)
                        .frame(width: 46, height: 52)
                        .background(
                            ResultsStyle.controlSurface,
                            in: .rect(cornerRadius: ResultsStyle.controlCornerRadius)
                        )
                }
                .accessibilityLabel("Overlay options")
            }
        }
        .padding(.top, 6)
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
                    route: processed.route,
                    overlays: overlays,
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
                        colour: .green,
                        transform: nil,
                        overlays: overlays,
                        scrubbing: isScrubbing,
                        cache: frameCache,
                        badgeLabel: "REF"
                    )
                    SkeletonOverlayPane(
                        title: processed.attempt?.label.nonEmpty ?? "You",
                        video: processed.attempt,
                        pose: processed.attemptPose,
                        frameIndex: frames.attempt,
                        metrics: frames.attempt.flatMap { processed.attemptMetrics.frame(at: $0) },
                        scale: processed.attemptScale,
                        colour: .orange,
                        transform: processed.alignment.homography.inverted,
                        overlays: overlays,
                        scrubbing: isScrubbing,
                        cache: frameCache,
                        badgeLabel: "YOU",
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
                ScrollView(.horizontal) {
                    HStack(spacing: 8) {
                        ForEach(sequences) { sequence in
                            let selected = sequence.index == position.sectionIndex
                            let containsFall = sequenceContainsFall(sequence, processed: processed)
                            let hasDifferentMoveCount = sequence.moveCountDelta != 0

                            Button {
                                selectSequence(sequence.index, processed: processed)
                            } label: {
                                ZStack(alignment: .topTrailing) {
                                    Text("\(sequence.index + 1)")
                                        .font(.system(
                                            size: 17,
                                            weight: selected ? .bold : .regular,
                                            design: .monospaced
                                        ))
                                        .frame(maxWidth: .infinity, maxHeight: .infinity)

                                    if containsFall {
                                        Text("F")
                                            .font(.system(size: 9, weight: .bold, design: .rounded))
                                            .padding(6)
                                    }
                                }
                                .foregroundStyle(sequenceForeground(
                                    selected: selected,
                                    containsFall: containsFall,
                                    hasDifferentMoveCount: hasDifferentMoveCount
                                ))
                                .frame(width: 52, height: 48)
                                .background(
                                    sequenceBackground(
                                        selected: selected,
                                        containsFall: containsFall,
                                        hasDifferentMoveCount: hasDifferentMoveCount
                                    ),
                                    in: .rect(cornerRadius: 15)
                                )
                                .scaleEffect(selected ? 1.12 : 1)
                                .animation(.snappy(duration: 0.2), value: selected)
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel("Sequence \(sequence.index + 1) of \(sequences.count)")
                            .accessibilityValue(sequenceAccessibilityValue(
                                containsFall: containsFall,
                                hasDifferentMoveCount: hasDifferentMoveCount
                            ))
                            .accessibilityAddTraits(selected ? .isSelected : [])
                        }
                    }
                    // Center short lists instead of pinning them to the leading
                    // edge. Longer lists retain their intrinsic width and scroll.
                    .frame(minWidth: geometry.size.width, minHeight: 60, alignment: .center)
                }
                .scrollIndicators(.hidden)
            }
            .frame(height: 60)

            Button { selectSequence(position.sectionIndex + 1, processed: processed) } label: {
                Image(systemName: "chevron.right")
                    .frame(width: 28, height: 48)
            }
            .buttonStyle(.plain)
            .disabled(position.sectionIndex >= sequences.count - 1)
        }
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

    private func insightCard(_ processed: ProcessedSession) -> some View {
        let insight = currentInsight(processed)
        let count = processed.sequences.sequences.count

        return VStack(alignment: .leading, spacing: 18) {
            HStack {
                Text("Sequence")
                    .font(.system(size: 17, weight: .regular, design: .monospaced))
                    .foregroundStyle(ResultsStyle.secondaryText)

                Text("\(position.sectionIndex + 1) of \(count)")
                    .font(.system(size: 17, weight: .semibold, design: .monospaced))
                    .foregroundStyle(.black)
                    .padding(.horizontal, 13)
                    .frame(minHeight: 34)
                    .background(.white, in: .capsule)

                Spacer()
                Text(durationLabel(processed))
                    .font(.system(size: 16, weight: .regular, design: .monospaced))
                    .foregroundStyle(ResultsStyle.secondaryText)
                    .multilineTextAlignment(.trailing)
            }

            if let insight {
                VStack(alignment: .leading, spacing: 4) {
                    Text(sentence(insight.observation))
                        .foregroundStyle(.white)
                    if let cause = insight.cause, !cause.isEmpty {
                        Text(sentence(cause, capitalizing: true))
                            .foregroundStyle(AppTheme.accent)
                            .fontWeight(.semibold)
                    }
                }
                .font(.system(size: 23, weight: .regular))
                .lineSpacing(2)
                .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(24)
        .background(
            ResultsStyle.panelSurface,
            in: .rect(cornerRadius: ResultsStyle.panelCornerRadius)
        )
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
            .frame(maxWidth: .infinity, minHeight: 78)
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

    private var skeletonIsActive: Bool {
        displayMode == .overlay || skeletonEnabled
    }

    private func sequenceContainsFall(_ sequence: ClimbSequence, processed: ProcessedSession) -> Bool {
        guard let fallIndex = processed.fallReport.fallSectionIndex else { return false }
        return sequence.referenceMoves.contains(fallIndex)
    }

    private func sequenceBackground(
        selected: Bool,
        containsFall: Bool,
        hasDifferentMoveCount: Bool
    ) -> Color {
        if containsFall { return .red }
        if selected || hasDifferentMoveCount { return AppTheme.accent }
        return ResultsStyle.panelSurface
    }

    private func sequenceForeground(
        selected: Bool,
        containsFall: Bool,
        hasDifferentMoveCount: Bool
    ) -> Color {
        if containsFall { return .white }
        if selected || hasDifferentMoveCount { return AppTheme.background }
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

    private func sentence(_ value: String, capitalizing: Bool = false) -> String {
        var text = value.trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: ".!?"))
        if capitalizing, let first = text.first {
            text = first.uppercased() + String(text.dropFirst())
        }
        return text + "."
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

    private func durationLabel(_ processed: ProcessedSession) -> String {
        guard let sequence = currentSequence(processed) else { return "—" }
        return clock(duration(of: sequence.referenceRange, in: processed.referencePose))
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
