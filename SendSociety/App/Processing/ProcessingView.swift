import SwiftUI

/// Task 5.3 — a plain progress list across pipeline stages, cancellable, with
/// stage names and timings. The timings are here because profiling needs them,
/// not because they look good.
struct ProcessingView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        List {
            switch model.state {
            case .idle:
                SwiftUI.Section {
                    Button("Process") { model.process() }
                    Text("Pose is cached per video. Reprocessing after a threshold change re-runs from contact detection onward and never re-runs Vision.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            case .running(let stage, let index, let fraction):
                SwiftUI.Section("Running") {
                    ProgressView(value: Double(index) + fraction, total: Double(ProcessingPipeline.stageCount))
                    Text("\(stage) — stage \(index + 1) of \(ProcessingPipeline.stageCount)")
                    Button("Cancel", role: .destructive) { model.cancelProcessing() }
                }
            case .failed(let message):
                SwiftUI.Section("Failed") {
                    Text(message).foregroundStyle(.red)
                    Button("Try again") { model.process() }
                }
            case .done:
                EmptyView()
            }

            if let processed = model.processed {
                SwiftUI.Section("Stages") {
                    ForEach(processed.stages) { stage in
                        HStack {
                            Text(statusSymbol(stage.status))
                            VStack(alignment: .leading) {
                                Text(stage.name)
                                if !stage.detail.isEmpty {
                                    Text(stage.detail).font(.caption).foregroundStyle(.secondary)
                                }
                            }
                            Spacer()
                            Text(String(format: "%.2fs", stage.seconds))
                                .font(.system(.caption, design: .monospaced))
                                .foregroundStyle(.secondary)
                        }
                    }
                }

                if !processed.warnings.isEmpty {
                    SwiftUI.Section("Warnings (\(processed.warnings.count))") {
                        ForEach(Array(processed.warnings.enumerated()), id: \.offset) { _, warning in
                            Text(warning).font(.caption)
                        }
                    }
                }

                SwiftUI.Section {
                    NavigationLink("Results") { ResultsView() }
                    NavigationLink("Tuning") { TuningPanelView() }
                    Button("Reprocess with current tuning") { model.process() }
                }
            }
        }
        .navigationTitle("Process")
        .onAppear {
            if model.processed == nil, case .idle = model.state { model.process() }
        }
    }

    private func statusSymbol(_ status: StageStatus) -> String {
        switch status {
        case .ok: "✓"
        case .degraded: "!"
        case .failed: "✕"
        case .skipped: "–"
        }
    }
}
