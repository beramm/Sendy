import SwiftUI

/// Task 5.6 — per-move analysis, tap to jump.
struct SectionListView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    var jumpTo: ((Int) -> Void)?

    var body: some View {
        List {
            if let processed = model.processed {
                if let fall = processed.fallAnalysis {
                    SwiftUI.Section("Fall") {
                        Text(fall.headline).font(.headline)
                        ForEach(fall.observations) { AnalysisNoteRow(note: $0) }
                        if let drill = fall.drill { Text(drill).font(.callout).foregroundStyle(.secondary) }
                        // The epistemic split survives into the copy.
                        if !processed.fallReport.mechanical.isEmpty {
                            Text("Measured mechanics").font(.caption).bold()
                            ForEach(processed.fallReport.mechanical) { Text("• \($0.detail)").font(.caption) }
                        }
                        if !processed.fallReport.fatigue.isEmpty {
                            Text("Possible contributing trends — correlations, not demonstrated causes")
                                .font(.caption).bold()
                            ForEach(processed.fallReport.fatigue) { Text("• \($0.detail)").font(.caption) }
                        }
                    }
                }

                ForEach(processed.sections) { section in
                    SwiftUI.Section(section.displayName) {
                        Button {
                            jumpTo?(section.index)
                            dismiss()
                        } label: {
                            VStack(alignment: .leading, spacing: 4) {
                                if let analysis = processed.analysis(forSection: section.index) {
                                    Text(analysis.headline).font(.subheadline).bold()
                                    ForEach(analysis.observations) { Text($0.text).font(.caption) }
                                } else {
                                    Text("No analysis for this move.").font(.caption).foregroundStyle(.secondary)
                                }
                                Text(subtitle(section, processed))
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            } else {
                Text("Nothing processed yet.")
            }
        }
        .navigationTitle("Moves")
    }

    private func subtitle(_ section: Section, _ processed: ProcessedSession) -> String {
        var parts = ["hold \(section.fromHold.ordinal + 1) → \(section.toHold.ordinal + 1)"]
        parts.append("ref frames \(section.referenceRange.lowerBound)–\(section.referenceRange.upperBound)")
        parts.append(section.attemptReached
                     ? "attempt \(section.attemptRange.lowerBound)–\(section.attemptRange.upperBound)"
                     : (section.unavailableReason ?? "not reached"))
        if let cost = processed.warpPath(forSection: section.index)?.meanCost, cost.isFinite {
            parts.append(String(format: "DTW cost %.2f", cost))
        }
        return parts.joined(separator: " · ")
    }
}

/// Task 5.7 — every computed metric per move, both climbers, with deltas.
/// Unstyled on purpose. This is the view you actually use during tuning.
struct RawMetricsView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        ScrollView([.horizontal, .vertical]) {
            Text(dump)
                .font(.system(.caption2, design: .monospaced))
                .textSelection(.enabled)
                .padding()
        }
        .navigationTitle("Raw metrics")
    }

    private var dump: String {
        guard let processed = model.processed else { return "Nothing processed yet." }
        var lines: [String] = []

        lines.append("SESSION  \(processed.session.name)")
        lines.append("attempt  \(processed.attempt?.label ?? "—")")
        lines.append(String(format: "torso    reference %.4f  attempt %.4f wall units", processed.referenceScale.torsoLength, processed.attemptScale.torsoLength))
        lines.append(String(format: "registration  residual %.5f  succeeded %@", processed.alignment.residual, processed.alignment.succeeded ? "yes" : "NO"))
        lines.append("homography    \(processed.alignment.homography.m.map { String(format: "%.4f", $0) }.joined(separator: " "))")
        lines.append("")

        lines.append("STAGES")
        for stage in processed.stages {
            lines.append(String(format: "  %-18@ %6.2fs  %@  %@", stage.name as NSString, stage.seconds, stage.status.rawValue, stage.detail))
        }
        lines.append("")

        lines.append("ROUTE  \(processed.route.holds.count) holds")
        lines.append("  id  by            x       y   contacts firstFrame")
        for hold in processed.route.holds {
            lines.append(String(format: "  %2d  %-12@ %.4f  %.4f  %6d  %8d",
                                hold.id, hold.firstUsedBy.rawValue as NSString,
                                hold.position.x, hold.position.y, hold.contactCount, hold.firstFrame))
        }
        lines.append("")

        lines.append("CONTACTS  reference \(processed.referenceContacts.count) / attempt \(processed.attemptContacts.count)")
        for (name, contacts) in [("REF", processed.referenceContacts), ("ATT", processed.attemptContacts)] {
            for c in contacts {
                lines.append(String(format: "  %@ %-12@ %4d-%4d  %.4f %.4f  conf %.2f",
                                    name, c.joint.rawValue as NSString, c.startFrame, c.endFrame,
                                    c.position.x, c.position.y, c.confidence))
            }
        }
        lines.append("")

        if processed.fallReport.occurred {
            lines.append("FALL  frame \(processed.fallReport.fallFrame ?? -1)  move \((processed.fallReport.fallSectionIndex ?? -1) + 1)  confidence \(String(format: "%.2f", processed.fallReport.confidence))")
            for s in processed.fallReport.mechanical { lines.append("  mechanical  \(s.kind.rawValue)  \(s.detail)") }
            for s in processed.fallReport.fatigue { lines.append("  fatigue     \(s.kind.rawValue)  \(s.detail)") }
            lines.append("")
        }

        lines.append("METRICS PER MOVE   (reference | attempt | delta | confidence)")
        for delta in processed.deltas {
            lines.append("")
            let unavailable = delta.attemptReached
                ? ""
                : (delta.divergence?.kind == .differentHandOrder ? "  [different order]" : "  [not reached]")
            lines.append("\(delta.sectionName)\(unavailable)\(delta.divergence.map { "  [\($0.kind.rawValue)]" } ?? "")")
            if let divergence = delta.divergence { lines.append("  \(divergence.detail)") }
            for metric in delta.deltas {
                lines.append(String(format: "  %-32@ %10@ %10@ %10@  %.2f  %@",
                                    metric.kind.displayName as NSString,
                                    format(metric.reference) as NSString,
                                    format(metric.attempt) as NSString,
                                    format(metric.delta) as NSString,
                                    metric.confidence,
                                    metric.kind.unit as NSString))
            }
        }

        lines.append("")
        lines.append("WARNINGS")
        for warning in processed.warnings { lines.append("  • \(warning)") }

        return lines.joined(separator: "\n")
    }

    private func format(_ v: Double?) -> String {
        guard let v else { return "—" }
        return String(format: "%.4f", v)
    }
}
