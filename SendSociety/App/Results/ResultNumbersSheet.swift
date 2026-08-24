import SwiftUI

struct ResultNumbersSheet: View {
    let insight: SequenceAnalysis

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 5) {
                Text("Detailed")
                    .foregroundStyle(.white)
                Text("Analytics")
                    .foregroundStyle(AppTheme.accent)
            }
            .font(.system(size: 22, weight: .semibold))
            .padding(.top, 34)
            .padding(.bottom, 24)

            if insight.metrics.isEmpty {
                ContentUnavailableView(
                    "Numbers unavailable",
                    systemImage: "chart.bar.xaxis",
                    description: Text(
                        insight.numbersUnavailableReason
                            ?? "No measurements are available for this sequence."
                    )
                )
                .frame(maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: 12) {
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
                            .padding(.bottom, 4)
                        }

                        ForEach(insight.metrics, id: \.kind) { metric in
                            MetricComparisonRow(
                                metric: metric,
                                comparisonIsValid: insight.comparisonIsValid
                            )
                        }
                    }
                    .padding(.horizontal, 24)
                    .padding(.bottom, 32)
                }
                .scrollIndicators(.hidden)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(ResultsStyle.sheetSurface)
        .presentationDetents([.fraction(0.61), .large])
        .presentationDragIndicator(.visible)
        .presentationCornerRadius(30)
        .presentationBackground(ResultsStyle.sheetSurface)
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
                .fill(.white.opacity(0.82))
                .frame(width: 3)

            VStack(alignment: .leading, spacing: 9) {
                HStack(alignment: .firstTextBaseline) {
                    Text(metric.kind.displayName)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(.white)
                    Spacer(minLength: 8)
                    Text(metric.kind.unit)
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundStyle(ResultsStyle.secondaryText)
                }

                valueBar(
                    label: "YOU",
                    value: metric.attempt,
                    fraction: presentation.fraction(for: metric.attempt),
                    color: ResultsStyle.attempt
                )

                if comparisonIsValid {
                    valueBar(
                        label: "REFERENCE",
                        value: metric.reference,
                        fraction: presentation.fraction(for: metric.reference),
                        color: ResultsStyle.reference
                    )
                } else {
                    HStack(spacing: 8) {
                        Text("REFERENCE")
                            .font(.caption2.weight(.bold))
                            .foregroundStyle(ResultsStyle.reference)
                            .frame(width: 90, alignment: .leading)
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
                .frame(width: 90, alignment: .leading)

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
                .foregroundStyle(ResultsStyle.secondaryText)
                .frame(width: 48, alignment: .trailing)
        }
    }
}
