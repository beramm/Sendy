import Foundation

/// Rule-based analysis. **The primary path**, not a fallback: it works on every
/// device, it cannot invent a number, and it is the baseline any model has to
/// beat.
///
/// The copy carries the claim; the figures live in each `AnalysisNote.evidence`
/// and are one tap away. That split is deliberate — the first version of this
/// file quoted every number inline so `NumberGuard` could verify it, and the
/// result read like a data structure with grammar.
public struct TemplateAnalysisProvider: AnalysisProvider {
    public let name = "Template"
    public var isAvailable: Bool { get async { true } }

    public var config: TuningConfig
    private let composer: FindingComposer

    public init(config: TuningConfig = TuningConfig()) {
        self.config = config
        self.composer = FindingComposer(config: config)
    }

    public func analyze(_ delta: SectionDelta) async throws -> SectionAnalysis {
        // Order matters. A move the attempt never reached is not a beta
        // difference — the climber fell or stopped before getting there — and
        // calling it "you climbed this differently" is both wrong and
        // discouraging. Reached-ness is checked first for that reason.
        // Checked before reached-ness. A move with no attempt footage is not
        // necessarily a move the attempt never got to — it can also be one it
        // climbed in a different order, leaving no stretch of video that sits
        // between the neighbouring moves. Those are opposite claims, and
        // telling a climber they didn't get somewhere they did get is the
        // discouraging kind of wrong.
        if let divergence = delta.divergence, divergence.kind == .differentHandOrder {
            return SectionAnalysis(
                sectionIndex: delta.sectionIndex,
                headline: "\(delta.sectionName): you climbed this in a different order",
                observations: [AnalysisNote(
                    text: divergence.detail,
                    evidence: "Beta divergence: differentHandOrder. No comparable span in the attempt."
                )],
                drill: nil,
                source: name
            )
        }
        guard delta.attemptReached else {
            return SectionAnalysis(
                sectionIndex: delta.sectionIndex,
                headline: "\(delta.sectionName): you didn't get this far",
                observations: [AnalysisNote(
                    text: "Your go ended before this move, so there's nothing to compare here yet.",
                    evidence: "Attempt frame range is empty for this section."
                )],
                drill: nil,
                source: name
            )
        }
        // Beta divergence is reported as a finding, never analysed as a
        // technique difference. Comparing metrics across two different moves
        // produces confident nonsense.
        // Coming off partway through a move is a truncation, not a difference
        // in beta.
        if let divergence = delta.divergence, divergence.kind == .truncated {
            return SectionAnalysis(
                sectionIndex: delta.sectionIndex,
                headline: "\(delta.sectionName): this is where your go ended",
                observations: [AnalysisNote(
                    // Deliberately does not promise a fall report. This copy
                    // was written assuming truncation implies a fall; it does
                    // not. On `gym-testing/test1` neither climber fell and the
                    // attempt clip simply ran out, and the sentence pointed at
                    // a report that was not there. `SectionDelta` has no fall
                    // field to condition on, and giving it one to phrase a
                    // sentence would be the wrong direction — when a fall does
                    // exist, `FallReport` renders on its own.
                    text: "You started this move but didn't finish it.",
                    evidence: divergence.detail
                )] + ownNumbers(delta),
                drill: nil,
                source: name
            )
        }
        if let divergence = delta.divergence {
            return SectionAnalysis(
                sectionIndex: delta.sectionIndex,
                headline: "\(delta.sectionName): you climbed this differently",
                observations: [
                    AnalysisNote(
                        text: divergence.detail,
                        evidence: "Beta divergence: \(divergence.kind.rawValue). A difference between two different moves would be a number about nothing, so none is given."
                    )
                ] + ownNumbers(delta),
                drill: "Try it their way once, then compare again.",
                source: name
            )
        }
        let findings = composer.compose(delta)
        guard !findings.isEmpty else {
            let measured = delta.deltas.filter { $0.delta != nil }.count
            return SectionAnalysis(
                sectionIndex: delta.sectionIndex,
                headline: "\(delta.sectionName): you climbed this much like they did",
                observations: [AnalysisNote(
                    text: measured > 0
                        ? "Nothing here stood out enough to be worth changing."
                        : "Nothing could be measured on this move.",
                    evidence: measured > 0
                        ? "\(measured) metrics computed, none above the significance threshold."
                        : "No metric was computable — check tracking quality for this range."
                )],
                drill: nil,
                source: name,
                warnings: measured == 0 ? ["No metric was computable for this move."] : []
            )
        }

        return SectionAnalysis(
            sectionIndex: delta.sectionIndex,
            headline: "\(delta.sectionName): \(headline(for: findings[0]))",
            observations: findings.map { finding in
                AnalysisNote(
                    text: finding.text,
                    evidence: finding.metrics.map(AnalysisNote.evidence(for:)).joined(separator: "\n"),
                    metric: finding.primaryMetric
                )
            },
            drill: findings.compactMap(\.drill).first,
            source: name
        )
    }

    /// The climber's **own** measurements for a move, with no reference value
    /// and no delta.
    ///
    /// A move where the two climbers did different things has no honest
    /// comparison — that is the third rule and it does not bend. What it does
    /// have is a well-measured attempt, and "nothing fair to compare" was
    /// throwing that away: on `gym-testing/test1` the attempt diverged on six
    /// of ten moves and the screen went quiet for all six, including the move
    /// it fell on.
    ///
    /// So: state what *you* did, as fact, and say nothing about them. Confidence
    /// is the attempt's own, not the comparison's, because there is no
    /// comparison here to be the weaker half of.
    func ownNumbers(_ delta: SectionDelta) -> [AnalysisNote] {
        // Ordered by what a climber can act on, not by magnitude — these are
        // facts about one climb, so there is no "biggest difference" to rank by.
        let kinds: [MetricKind] = [
            .hipDistanceMean, .armLoadShare, .straightArmRatio,
            .loadAsymmetry, .footPlacementCount
        ]
        var notes: [AnalysisNote] = []
        var unavailable: [MetricKind] = []
        for kind in kinds {
            guard let d = delta.delta(kind) else { continue }
            // A number carried at 3% confidence is not a measurement, and hip
            // depth reaches that whenever the limbs sit near the wall plane —
            // which is most of a slab. Suppressed, and said out loud, rather
            // than printed as though it were known.
            guard let value = d.attempt, d.attemptConfidence >= config.jointConfidenceFloor else {
                unavailable.append(kind)
                continue
            }
            notes.append(AnalysisNote(
                text: Self.ownSentence(kind, value: value),
                evidence: String(format: "%@ on your climb: %.2f %@ · confidence %.0f%% · your number only, not a comparison",
                                 kind.displayName, displayValue(kind, value), kind.unit, d.attemptConfidence * 100),
                metric: kind
            ))
        }
        if notes.isEmpty {
            notes.append(AnalysisNote(
                text: "Nothing could be measured on your side of this move either.",
                evidence: unavailable.isEmpty
                    ? "No metric was computable for the attempt here."
                    : "Not computable for the attempt: " + unavailable.map(\.rawValue).joined(separator: ", ")
            ))
        } else if !unavailable.isEmpty {
            notes.append(AnalysisNote(
                text: "Some of it couldn't be measured here.",
                evidence: "Not computable for the attempt: " + unavailable.map(\.rawValue).joined(separator: ", ")
            ))
        }
        return notes
    }

    /// Percentages are stored as fractions and read as percentages.
    func displayValue(_ kind: MetricKind, _ value: Double) -> Double {
        kind.unit == "%" ? value * 100 : value
    }

    /// One sentence per metric, about the climber's own move. No comparative
    /// adverbs — there is nothing to compare against here.
    static func ownSentence(_ kind: MetricKind, value: Double) -> String {
        switch kind {
        case .hipDistanceMean, .hipDistancePeak:
            return String(format: "Your hips sat about %.2f body-lengths off the wall through this move.", value)
        case .armLoadShare, .armLoadPeak:
            return String(format: "About %.0f%% of your weight went through your arms here.", value * 100)
        case .straightArmRatio:
            return String(format: "Your arms were straight %.0f%% of the time on this move.", value * 100)
        case .loadAsymmetry:
            return String(format: "Your weight sat %.0f%% to one side rather than evenly across both.", value * 100)
        case .footPlacementCount:
            return String(format: "You placed a foot %.0f time%@ on this move.", value, value == 1 ? "" : "s")
        case .footCommitmentSeconds:
            return String(format: "It took you about %.1fs to trust a foot once it was on.", value)
        case .unweightedFootTime:
            return String(format: "Your feet were on but carrying nothing %.0f%% of the time.", value * 100)
        case .feetSetBeforeReach:
            return String(format: "Your feet were set before the reach %.0f%% of the time.", value * 100)
        case .comPathLength:
            return String(format: "Your centre of mass travelled %.2f body-lengths across this move.", value)
        case .comPeakVelocity:
            return String(format: "Your fastest body movement here was %.2f body-lengths/s.", value)
        case .hipTwist:
            return String(format: "Your hips turned about %.0f° away from square to the wall.", value)
        case .reachMargin:
            return String(format: "You latched the hold from about %.2f body-lengths of extension.", value)
        case .sectionDwellRatio:
            return String(format: "You spent %.2f× as long here as the reference climber spent on their version.", value)
        }
    }

    /// Headlines are short and lower-case after the move name — a phrase, not a
    /// report title. "Move 4: your arms did the work" reads; "Move Efficiency:
    /// Attempt Lagging Behind Reference" does not.
    func headline(for finding: Finding) -> String {
        guard let kind = finding.primaryMetric else { return "worth a look" }
        let better = !finding.attemptIsWorse
        switch kind {
        case .armLoadShare, .armLoadPeak: return better ? "your feet did the work" : "your arms did the work"
        case .unweightedFootTime: return better ? "you stood on your feet" : "your feet were along for the ride"
        case .feetSetBeforeReach: return better ? "feet set before you moved" : "hand first, feet after"
        case .footCommitmentSeconds: return better ? "you trusted your feet" : "slow to trust your feet"
        case .hipDistanceMean, .hipDistancePeak: return better ? "hips tight to the wall" : "hips away from the wall"
        case .straightArmRatio: return better ? "you hung straight" : "you held it bent-armed"
        case .comPathLength: return better ? "a direct line" : "more movement than the move needed"
        case .comPeakVelocity: return (finding.metrics.first?.delta ?? 0) > 0 ? "you went for it" : "you kept it static"
        case .loadAsymmetry: return better ? "evenly weighted" : "one side took it"
        case .footPlacementCount: return better ? "feet placed once" : "a lot of foot shuffling"
        case .hipTwist: return "a different body position"
        case .reachMargin: return better ? "you moved in before reaching" : "you reached from too far out"
        case .sectionDwellRatio: return finding.attemptIsWorse ? "this one cost you time" : "quicker than them here"
        }
    }

    // MARK: Fall

    public func analyzeFall(_ report: FallReport, sections: [SectionDelta]) async throws -> SectionAnalysis? {
        guard report.occurred else { return nil }
        let moveLabel = report.fallSectionIndex.map { "move \($0 + 1)" } ?? "a move I couldn't pin down"
        var observations: [AnalysisNote] = []

        // Mechanical signals are demonstrable: state them as fact.
        for signal in report.mechanical {
            observations.append(AnalysisNote(
                text: Self.plainText(for: signal),
                evidence: "\(signal.kind.rawValue) · mechanical · " + signal.detail
            ))
        }
        if report.mechanical.isEmpty {
            observations.append(AnalysisNote(
                text: "I couldn't see a clear mechanical reason in the moments before you came off.",
                evidence: "No mechanical signal crossed threshold in the proximate window."
            ))
        }

        // Fatigue proxies are correlational. The hedging in this wording is not
        // padding — it is the epistemic split the plan requires, carried into
        // the copy.
        for signal in report.fatigue {
            observations.append(AnalysisNote(
                text: Self.plainText(for: signal),
                evidence: "\(signal.kind.rawValue) · fatigue proxy, correlational · " + signal.detail
            ))
        }

        var headline = "You came off on \(moveLabel)"
        if let distal = report.distalSectionIndex, distal != report.fallSectionIndex {
            headline += ", but it started earlier"
            observations.append(AnalysisNote(
                text: "The first sign of it shows up back on move \(distal + 1), several moves before you actually fell.",
                evidence: "Earliest contributing signal: section index \(distal)."
            ))
        }

        return SectionAnalysis(
            sectionIndex: report.fallSectionIndex ?? 0,
            headline: headline + ".",
            observations: observations,
            drill: report.distalSectionIndex.map { "Work move \($0 + 1) rather than the one you fell on." },
            source: name,
            warnings: report.warnings
        )
    }

    /// Fall signals, said the way a person would say them. The measured detail
    /// moves into the evidence line.
    static func plainText(for signal: FallSignal) -> String {
        switch signal.kind {
        case .comOutsideBaseOfSupport:
            "Your weight drifted outside your hands and feet and never came back — past that point you're hanging on rather than standing on anything."
        case .barnDoor:
            "It went sideways rather than straight down. That's a barn door — the wall swung you out around your holds."
        case .footSlip:
            "Your foot came off downward while your hands were still loaded, with no unweighting first. That's a slip, not a foot move."
        case .hipPeel:
            "Your hips had been creeping away from the wall through the seconds before you dropped, which is what put the weight on your arms."
        case .bentArmAccumulation:
            "Your arms were bending earlier and earlier as the climb went on. That's consistent with tiring, though I can't prove it from the video."
        case .armLoadAccumulation:
            "More and more of your weight went through your arms as you got higher. Possibly tiring feet, possibly trusting them less — not something the video can settle."
        case .sectionDwellRatio:
            "You were taking longer on each move as the climb went on. Could be tiring, could be reading the route — not demonstrated either way."
        case .loadAsymmetryTrend:
            "You leaned harder on one side as the climb went on. Might be favouring it; the video can't say why."
        case .reachMarginDecay:
            "You were latching each hold from further out as you got higher. Possibly reaching rather than moving in — not demonstrated."
        }
    }
}
