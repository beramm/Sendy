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
                ProgressView()
                    .controlSize(.large)
                    .tint(AppTheme.accent)
                Text(title).font(.largeTitle.bold())
                Text(detail).font(.title3).foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                if case .running(_, let index, let fraction) = model.state {
                    ProgressView(value: Double(index) + fraction, total: Double(ProcessingPipeline.stageCount))
                        .tint(AppTheme.accent).padding(.horizontal, 42)
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
        .onChange(of: model.state) { _, state in
            guard state == .done, model.processed != nil else { return }
            model.path.removeAll { $0 == .processing }
            if model.path.last != .results { model.path.append(.results) }
        }
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

#Preview("Analysing") {
    FlowPreviewContainer(session: FlowPreviewData.ready) { ProcessingView() }
}
