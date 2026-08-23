import SwiftUI

/// Task 5.3 — stage names, statuses, timings and every warning the run
/// produced. The timings are here because profiling needs them, not because
/// they look good.
///
/// **Not part of the flow.** The pipeline runs from the clips screen and lands
/// on the comparison; nobody should have to cross a table of stage timings to
/// reach their results. This is where you come when a number on the results
/// screen looks wrong, so it is reached from there.
struct PipelineReportView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        List {
            switch model.state {
            case .running(let stage, let index, let fraction):
                SwiftUI.Section("Running") {
                    ProgressView(value: Double(index) + fraction, total: Double(ProcessingPipeline.stageCount))
                    Text("\(stage) — stage \(index + 1) of \(ProcessingPipeline.stageCount)")
                    Button("Cancel", role: .destructive) { model.cancelProcessing() }
                }
            case .failed(let message):
                SwiftUI.Section("Failed") {
                    Label(message, systemImage: "xmark.octagon.fill")
                        .foregroundStyle(.red)
                    Button("Try again") { model.process() }
                }
            case .idle, .done:
                if let processed = model.processed {
                    SwiftUI.Section {
                        // Reports the **worst stage**, not merely that the run
                        // returned. A green tick over a pipeline that found zero
                        // contacts is the one lie this screen must never tell.
                        let outcome = outcome(of: processed)
                        Label(outcome.title, systemImage: outcome.symbol)
                            .foregroundStyle(outcome.tint)
                        Text(completionSummary(processed))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                } else {
                    SwiftUI.Section {
                        Text("Nothing processed yet.").foregroundStyle(.secondary)
                    }
                }
            }

            if let processed = model.processed {
                SwiftUI.Section("Stages") {
                    ForEach(processed.stages) { stage in
                        HStack {
                            statusSymbol(stage.status)
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

                    // **Submit to output, and the gap between it and the
                    // stages.** The stage rows only cover the pipeline; the
                    // wait a climber standing at a wall actually experiences
                    // starts at the tap. When the two disagree, the difference
                    // is where to look next.
                    if let seconds = model.lastProcessingSeconds {
                        let staged = processed.stages.reduce(0) { $0 + $1.seconds }
                        HStack {
                            Text("Submit → output").bold()
                            Spacer()
                            Text(String(format: "%.2fs", seconds))
                                .font(.system(.caption, design: .monospaced))
                        }
                        HStack {
                            Text("Outside the stages above")
                            Spacer()
                            Text(String(format: "%.2fs", max(0, seconds - staged)))
                                .font(.system(.caption, design: .monospaced))
                                .foregroundStyle(.secondary)
                        }
                        .font(.caption)
                        Text(model.lastProcessingWasCached
                             ? "Pose came from cache. A first run on these clips pays for Vision over the whole video and is not comparable."
                             : "Full extraction — Vision ran over both clips.")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
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
                    NavigationLink("Tuning", value: AppRoute.tuning)
                    Button("Reprocess with current tuning") { model.process() }
                    Text("Pose is cached per video. Reprocessing after a threshold change re-runs from contact detection onward and never re-runs Vision.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .navigationTitle("Pipeline report")
    }

    private func outcome(of processed: ProcessedSession) -> (title: String, symbol: String, tint: Color) {
        let statuses = processed.stages.map(\.status)
        if statuses.contains(.failed) {
            let failed = statuses.filter { $0 == .failed }.count
            return ("Finished with \(failed) failed \(failed == 1 ? "stage" : "stages")",
                    "xmark.octagon.fill", .red)
        }
        if statuses.contains(.degraded) {
            return ("Finished, some stages degraded", "exclamationmark.triangle.fill", .orange)
        }
        return ("All stages passed", "checkmark.circle.fill", .green)
    }

    private func completionSummary(_ processed: ProcessedSession) -> String {
        let sequences = processed.sequences.sequences.count
        let moves = processed.sections.count
        let warnings = processed.warnings.count
        return "\(count(sequences, "sequence")) · \(count(moves, "move")) · \(count(warnings, "warning"))"
    }

    private func count(_ n: Int, _ noun: String) -> String {
        "\(n) \(noun)\(n == 1 ? "" : "s")"
    }

    /// SF Symbols with semantic colour rather than `✓ ! ✕ –`: the glyphs were
    /// unreadable at caption size and carried no colour, so a degraded stage
    /// looked identical to a passing one at a glance.
    @ViewBuilder
    private func statusSymbol(_ status: StageStatus) -> some View {
        switch status {
        case .ok: Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
        case .degraded: Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
        case .failed: Image(systemName: "xmark.octagon.fill").foregroundStyle(.red)
        case .skipped: Image(systemName: "minus.circle").foregroundStyle(.secondary)
        }
    }
}
