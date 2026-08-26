import SwiftUI

/// The full write-up behind the two cards: the same difference said from each
/// climber's side, at length, then what each measurement behind it actually
/// is.
///
/// **No figures here.** Every number in this sheet was in Detailed Analytics
/// too, one tap away and drawn as a comparison rather than a bare value, so
/// printing them twice bought nothing and made this read like a second table.
/// What this sheet has that the other does not is the prose — four
/// measurements joined into something a climber can act on — and the glossary
/// saying what each measurement means.
///
/// **This view never generates anything.** The prose was written by the
/// pipeline and cached with the session, so reopening a saved climb shows the
/// identical words. A sheet that called the provider would produce different
/// text on every present, which is worse than no text at all.
///
/// It is not a second Detailed Analytics. That sheet is the ranked reference
/// table for every measurement in the sequence and assumes the reader already
/// knows what each row is. This one takes the two measurements the finding
/// actually rests on, prints each climber's value, and says in a sentence what
/// the measurement is — the only place in the app that explains a metric
/// rather than printing it.
///
/// Scope is the current sequence and nothing else. The scrubber, the cards and
/// Detailed Analytics are all per-sequence; a sheet that silently widened
/// would be the one thing on this screen that did.
struct SequenceDifferencesSheet: View {
    let insight: SequenceAnalysis
    /// Only ever read for the sequences the fall touches. A climb with no fall
    /// renders exactly as before.
    var fallReport: FallReport = .none

    /// The measurements the finding rests on — the same four the narration was
    /// written from, so the glossary explains exactly what the prose above it
    /// is talking about.
    private var evidence: [MetricDelta] {
        Array(insight.metrics.prefix(4))
    }

    var body: some View {
        VStack(spacing: 0) {
            Text("Differences")
                .foregroundStyle(.white)
                .font(.system(size: 22, weight: .semibold))
                .padding(.top, 34)
                .padding(.bottom, 24)

            if hasAnything {
                ScrollView {
                    VStack(alignment: .leading, spacing: 30) {
                        // Reference above you, matching the row order in
                        // Detailed Analytics: the reference is what the
                        // comparison is read against, so the eye meets it
                        // first.
                        section(
                            title: "REFERENCE",
                            color: ResultsStyle.reference,
                            finding: insight.referenceFinding,
                            narrative: insight.referenceNarrative,
                            subject: "The other climber",
                            causeSubject: "they"
                        )

                        section(
                            title: "YOU",
                            color: ResultsStyle.attempt,
                            finding: insight.attemptFinding,
                            narrative: insight.attemptNarrative,
                            subject: "You",
                            causeSubject: "you"
                        )

                        if !fallLines.isEmpty { fallSection }
                        if !evidence.isEmpty { glossarySection }
                    }
                    .padding(.horizontal, 24)
                    .padding(.bottom, 32)
                }
                .scrollIndicators(.hidden)
            } else {
                ContentUnavailableView(
                    "No comparison here",
                    systemImage: "text.alignleft",
                    description: Text(unavailableReason)
                )
                .frame(maxHeight: .infinity)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(AppTheme.sheetSurface)
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
        .presentationCornerRadius(30)
        .presentationBackground(AppTheme.sheetSurface)
    }

    @ViewBuilder
    private func section(
        title: String,
        color: Color,
        finding: SequenceDifferenceFinding?,
        narrative: String?,
        subject: String,
        causeSubject: String
    ) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title)
                .font(.caption2.weight(.bold))
                .foregroundStyle(color)

            if let finding {
                // The card's phrase, repeated as the lead. It is what the
                // reader tapped, and the paragraph below was written to expand
                // it — showing one without the other loses that link.
                Text(finding.headline ?? finding.observation)
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(.white)

                Text(narrative ?? finding.sentence(subject: subject, causeSubject: causeSubject))
                    .font(.system(size: 15))
                    .foregroundStyle(finding.isAvailable ? Color.white.opacity(0.86) : ResultsStyle.secondaryText)

            } else {
                Text("Nothing was measured for this climber here.")
                    .font(.system(size: 15))
                    .foregroundStyle(ResultsStyle.secondaryText)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .fixedSize(horizontal: false, vertical: true)
    }

    /// What each measurement is, said once rather than under both climbers.
    private var glossarySection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("WHAT THESE MEAN")
                .font(.caption2.weight(.bold))
                .foregroundStyle(ResultsStyle.secondaryText)

            ForEach(evidence, id: \.kind) { metric in
                VStack(alignment: .leading, spacing: 3) {
                    Text(metric.kind.displayName)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.white)
                    Text(metric.kind.plainMeaning)
                        .font(.system(size: 13))
                        .foregroundStyle(ResultsStyle.secondaryText)
                }
                .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// The fall analysis, with its epistemic split intact.
    ///
    /// A mechanical signal is demonstrable from the geometry and is stated as
    /// fact. A fatigue proxy is correlational and is labelled as such — that
    /// distinction is the point of the fall analyser, and flattening the two
    /// into one list of "reasons" is exactly what it exists to prevent.
    private var fallSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("WHAT THE FALL ANALYSIS SAW")
                .font(.caption2.weight(.bold))
                .foregroundStyle(ResultsStyle.secondaryText)

            ForEach(fallLines, id: \.signal.id) { line in
                VStack(alignment: .leading, spacing: 3) {
                    Text(TemplateAnalysisProvider.plainText(for: line.signal))
                        .font(.system(size: 14))
                        .foregroundStyle(.white.opacity(0.86))
                    // A tag, not a second hedge. The fatigue copy above
                    // already ends "not demonstrated"; saying it again
                    // underneath read as the app arguing with itself.
                    Text(line.isMechanical ? "Measured directly" : "Pattern across the climb")
                        .font(.system(size: 12))
                        .foregroundStyle(ResultsStyle.secondaryText)
                }
                .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// The fall signals belonging to the moves this sequence covers.
    private var fallLines: [(signal: FallSignal, isMechanical: Bool)] {
        guard fallReport.occurred, insight.kind == .fall else { return [] }
        let moves = Set(insight.sourceSectionIndices)
        let mechanical = fallReport.mechanical
            .filter { moves.isEmpty || moves.contains($0.sectionIndex) }
            .map { (signal: $0, isMechanical: true) }
        let fatigue = fallReport.fatigue
            .filter { moves.isEmpty || moves.contains($0.sectionIndex) }
            .map { (signal: $0, isMechanical: false) }
        return mechanical + fatigue
    }

    /// True when there is at least one climber's finding to show. A sequence
    /// with neither gets the plain explanation instead of two empty headers.
    private var hasAnything: Bool {
        insight.referenceFinding != nil || insight.attemptFinding != nil
    }

    private var unavailableReason: String {
        insight.referenceFinding?.unavailableReason
            ?? insight.numbersUnavailableReason
            ?? "This sequence has no reliable comparison between the two climbs, so there is nothing to write up."
    }
}

#Preview {
    Color.black.sheet(isPresented: .constant(true)) {
        SequenceDifferencesSheet(insight: SequenceAnalysis(
            sequenceIndex: 3,
            kind: .coaching,
            observation: "You put more weight through the arms",
            cause: "you stayed farther from the wall",
            metrics: [
                MetricDelta(kind: .armLoadShare, reference: 0.28, attempt: 0.52, confidence: 0.9),
                MetricDelta(kind: .hipDistanceMean, reference: 0.19, attempt: 0.44, confidence: 0.8)
            ],
            comparisonIsValid: true,
            numbersUnavailableReason: nil,
            sourceSectionIndices: [4, 5],
            referenceFinding: SequenceDifferenceFinding(
                observation: "Kept more weight off the arms",
                headline: "Less weight on arms",
                cause: "Stayed closer to the wall",
                metricKind: .armLoadShare,
                confidence: 0.9
            ),
            attemptFinding: SequenceDifferenceFinding(
                observation: "Put more weight through the arms",
                headline: "More weight on arms",
                cause: "Stayed farther from the wall",
                metricKind: .armLoadShare,
                confidence: 0.9
            )
        ))
    }
}
