import SwiftUI

struct ResultNumbersSheet: View {
    @Environment(\.dismiss) private var dismiss

    let insight: SequenceAnalysis

    var body: some View {
        NavigationStack {
            Group {
                if insight.metrics.isEmpty {
                    ContentUnavailableView(
                        "Numbers unavailable",
                        systemImage: "chart.bar.xaxis",
                        description: Text(insight.numbersUnavailableReason ?? "No measurements are available for this sequence.")
                    )
                } else {
                    ScrollView {
                        LazyVStack(spacing: 18) {
                            if !insight.comparisonIsValid {
                                Label {
                                    VStack(alignment: .leading, spacing: 3) {
                                        Text("Reference comparison unavailable")
                                            .fontWeight(.semibold)
                                        Text(comparisonUnavailableExplanation)
                                    }
                                } icon: {
                                    Image(systemName: "exclamationmark.triangle")
                                }
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .frame(maxWidth: .infinity, alignment: .leading)
                            }

                            ForEach(insight.metrics, id: \.kind) { metric in
                                MetricComparisonRow(
                                    metric: metric,
                                    comparisonIsValid: insight.comparisonIsValid
                                )
                            }
                        }
                        .padding(20)
                    }
                }
            }
            .navigationTitle("THE NUMBERS")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done", systemImage: "xmark") { dismiss() }
                        .labelStyle(.iconOnly)
                }
            }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
    }

    private var comparisonUnavailableExplanation: String {
        insight.cause
            ?? insight.numbersUnavailableReason
            ?? "The clips do not share two reliable anchors around this sequence. Your measurements are shown without a reference value."
    }
}

private struct MetricComparisonRow: View {
    let metric: MetricDelta
    let comparisonIsValid: Bool

    private var presentation: MetricPresentation {
        MetricPresentation(kind: metric.kind, values: [metric.attempt, metric.reference].compactMap { $0 })
    }

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Capsule()
                .fill(.white.opacity(0.8))
                .frame(width: 3)

            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .firstTextBaseline) {
                    Text(metric.kind.displayName)
                        .font(.subheadline.weight(.semibold))
                    Spacer()
                    Text(metric.kind.unit)
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                }

                valueBar(
                    label: "YOU",
                    value: metric.attempt,
                    fraction: presentation.fraction(for: metric.attempt),
                    color: AppTheme.accent
                )

                if comparisonIsValid {
                    valueBar(
                        label: "REFERENCE",
                        value: metric.reference,
                        fraction: presentation.fraction(for: metric.reference),
                        color: .cyan
                    )
                } else {
                    HStack {
                        Text("REFERENCE")
                            .font(.caption2.weight(.bold))
                            .foregroundStyle(.cyan)
                            .frame(width: 84, alignment: .leading)
                        Text("Not comparable")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .accessibilityElement(children: .combine)
    }

    private func valueBar(label: String, value: Double?, fraction: Double, color: Color) -> some View {
        HStack(spacing: 8) {
            Text(label)
                .font(.caption2.weight(.bold))
                .foregroundStyle(color)
                .frame(width: 84, alignment: .leading)

            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    Capsule().fill(.white.opacity(0.09))
                    Capsule()
                        .fill(color)
                        .frame(width: geometry.size.width * fraction)
                }
            }
            .frame(height: 10)

            Text(presentation.format(value))
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 54, alignment: .trailing)
        }
    }
}
