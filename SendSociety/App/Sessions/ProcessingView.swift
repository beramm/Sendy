//
//  ProcessingView.swift
//  SendSociety
//
//  Created by Dzikry Aji Santoso on 19/08/26.
//
import SwiftUI

/// A deliberately separate hand-off screen: processing no longer competes with
/// the clip setup UI, and the current pipeline stage remains visible throughout.
struct ProcessingView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        ZStack {
            AppBackground()
            VStack(spacing: 24) {
                ProcessingHoldsAnimation()
                Text(title).font(.largeTitle.bold().monospaced())
                Text(detail).font(.title3.monospaced()).foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    // Running only. The same `Text` carries the failure
                    // reassurance and the idle string, and a pulsing failure
                    // message reads as a process that is still going.
                    .pulsing(isRunning)
                if case .running(_, let index, let fraction) = model.state {
                    // Clamped because a stage reporting a fraction slightly past
                    // 1 would otherwise print "101%" — the bar itself clips, but
                    // the number would not.
                    let progress = min(1, max(0, (Double(index) + fraction) / Double(ProcessingPipeline.stageCount)))
                    VStack(spacing: 10) {
                        ProgressView(value: progress)
                            .tint(AppTheme.accent)
                        // Monospaced digits so the layout does not twitch as the
                        // number counts up.
                        Text(progress.formatted(.percent.precision(.fractionLength(0))))
                            .font(.subheadline.monospaced())
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                    }
                    .padding(.horizontal, 42)
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel("Analysis progress")
                    .accessibilityValue(progress.formatted(.percent.precision(.fractionLength(0))))
                    Button("Cancel", role: .destructive) { model.cancelProcessing() }
                }
                if case .failed(let message) = model.state {
                    Text(message).foregroundStyle(.orange).multilineTextAlignment(.center)
                    Button("Try again") { model.process() }.buttonStyle(.borderedProminent)
                }
            }
            .padding(32).foregroundStyle(.white)
        }
        .navigationBarBackButtonHidden(true)
        // **One path assignment, not a pop followed by a push.** Removing
        // `.processing` and appending `.results` as two mutations in the same
        // update is a pop and a push of the same `NavigationStack` in one tick,
        // and the stack can settle on neither — which strands the run on
        // "Comparison ready" with no back button and no way forward.
        .onChange(of: model.state) { _, _ in model.advanceToResultsIfReady() }
        // Covers the run that finished before this view was on screen: there is
        // no state *change* left to observe in that case, and without this the
        // screen waits for an event that has already happened.
        .task { model.advanceToResultsIfReady() }
    }

    private var isRunning: Bool {
        if case .running = model.state { return true }
        return false
    }

    private var title: String {
        if case .done = model.state { return "Comparison ready" }
        if case .failed = model.state { return "Analysis needs another try" }
        return "Analysing…"
    }

    private var detail: String {
        if case .running(let stage, _, _) = model.state { return stage }
        if case .failed = model.state { return "Your clips are still here — you can retry safely." }
        return "Preparing your comparison"
    }
}

private struct ProcessingHoldsAnimation: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var visibleHoldCount = 0

    private let frameAssetNames = [
        "ProcessingHold1",
        "ProcessingHold2",
        "ProcessingHold3",
        "ProcessingHold4"
    ]

    var body: some View {
        ZStack {
            ForEach(frameAssetNames.indices, id: \.self) { index in
                Image(frameAssetNames[index])
                    .resizable()
                    .scaledToFit()
                    .opacity(index < visibleHoldCount ? 1 : 0)
            }
        }
        .frame(maxHeight: 520)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Analysing route holds")
        .task { await animateHolds() }
    }

    @MainActor
    private func animateHolds() async {
        while !Task.isCancelled {
            withAnimation(.easeOut(duration: reduceMotion ? 0.15 : 0.3)) {
                visibleHoldCount = 0
            }

            guard await wait(for: .milliseconds(350)) else { return }

            for count in 1...4 {
                withAnimation(.spring(response: reduceMotion ? 0.2 : 0.35, dampingFraction: 0.78)) {
                    visibleHoldCount = count
                }
                guard await wait(for: .milliseconds(450)) else { return }
            }

            guard await wait(for: .milliseconds(650)) else { return }
        }
    }

    private func wait(for duration: Duration) async -> Bool {
        do {
            try await Task.sleep(for: duration)
            return !Task.isCancelled
        } catch {
            return false
        }
    }
}

#Preview("Analysing") {
    FlowPreviewContainer(session: FlowPreviewData.ready) { ProcessingView() }
}
