import Foundation
#if canImport(FoundationModels)
import FoundationModels
#endif

/// Apple's on-device model, used **only to phrase claims that Swift already
/// decided**.
///
/// The division of labour is the whole design. `FindingComposer` decides what is
/// true, which direction is good, and what to suggest — all in code, from
/// `MetricKind.lowerIsBetter`. The model receives finished claims in plain
/// English and rewrites them so they sound like a person rather than a report.
/// It never sees a raw delta, never picks a polarity, and never sees a figure.
///
/// That split came out of a real failure: given bare labelled numbers, the model
/// wrote "Attempt Lagging Behind Reference" for a move where the attempt was
/// *better*, and "Try: Increase attempt's hip twist by 3.00" as advice. Both are
/// impossible now — it cannot get a direction wrong when it isn't choosing one,
/// and it cannot quote a number when its output is rejected for containing one.
struct FoundationModelsProvider: AnalysisProvider {
    let name = "Foundation Models"
    var config: TuningConfig
    private let fallback: TemplateAnalysisProvider
    private let composer: FindingComposer

    init(config: TuningConfig = TuningConfig()) {
        self.config = config
        self.fallback = TemplateAnalysisProvider(config: config)
        self.composer = FindingComposer(config: config)
    }

    var isAvailable: Bool {
        get async {
            #if canImport(FoundationModels)
            if #available(iOS 26.0, macOS 26.0, *) {
                return SystemLanguageModel.default.isAvailable
            }
            #endif
            return false
        }
    }

    /// Everything the model is ever shown. Claims, not measurements.
    static func prompt(for delta: SectionDelta, findings: [Finding]) -> String {
        var lines: [String] = []
        lines.append("You are a bouldering coach talking to a climber who has just watched their attempt next to a stronger climber's.")
        lines.append("")
        lines.append("Here is what was measured on move \(delta.sectionIndex + 1). These conclusions are already correct — your job is only to say them well.")
        lines.append("")
        for finding in findings {
            lines.append("- \(finding.text)")
            if let drill = finding.drill { lines.append("  suggested: \(drill)")}
        }
        lines.append("")
        lines.append("""
        Rules:
        - Never write a number, a percentage, or a unit. Not one. The figures are shown separately.
        - Do not reverse, soften or strengthen the conclusions above. If they say the climber did something well, say so.
        - Talk like a person at the wall, not like a report. No headings such as "Move Efficiency" and no phrases like "the attempt" or "the reference" — say "you" and "they".
        - Advice must be something a climber can try. Never "increase X" or "reduce Y".
        - Never guess at how they felt: no fear, confidence, hesitation, commitment or intent. You cannot see that in a video.
        - If nothing is wrong, say that plainly and give no drill.
        """)
        lines.append("")
        lines.append("""
        Examples of the voice:

        claim: "You were holding yourself on with your arms more than they were. Your hips sat further off the wall, so your weight had nowhere to go but onto your hands."
        good: headline "your arms did the work"; observation "You were hanging off your arms here where they were standing on their feet — your hips were out from the wall, so there was nowhere else for your weight to go."; drill "Turn a hip in and let it touch the wall before you reach."

        claim: "You did this move more directly than they did, and with less on your arms."
        good: headline "nothing to fix here"; observation "You went straight to it and kept the weight off your arms. This one was clean."; drill omitted.
        """)
        return lines.joined(separator: "\n")
    }

    func analyze(_ delta: SectionDelta) async throws -> SectionAnalysis {
        // Code decides everything that can be wrong. If there is nothing to
        // say, there is nothing for the model to do.
        let findings = composer.compose(delta)
        let template = try await fallback.analyze(delta)
        guard !findings.isEmpty, delta.divergence == nil, delta.attemptReached else {
            return template
        }

        #if canImport(FoundationModels)
        if #available(iOS 26.0, macOS 26.0, *), SystemLanguageModel.default.isAvailable {
            do {
                let session = LanguageModelSession()
                let response = try await session.respond(
                    to: Self.prompt(for: delta, findings: findings),
                    generating: GeneratedSectionAnalysis.self
                )
                // The model rewrote the claims; the evidence stays code-generated
                // and is zipped back on so nothing loses its measurement.
                let observations = zip(response.content.observations, findings).map { text, finding in
                    AnalysisNote(
                        text: text,
                        evidence: finding.metrics.map(AnalysisNote.evidence(for:)).joined(separator: "\n"),
                        metric: finding.primaryMetric
                    )
                }
                let candidate = SectionAnalysis(
                    sectionIndex: delta.sectionIndex,
                    headline: "\(delta.sectionName): \(response.content.headline)",
                    observations: observations.isEmpty ? template.observations : observations,
                    drill: response.content.drill,
                    source: name
                )
                if let rejected = Self.guardFailure(candidate, delta: delta, findings: findings) {
                    var safe = template
                    safe.warnings.append("On-device model output was discarded: \(rejected). Showing the written analysis instead.")
                    return safe
                }
                return candidate
            } catch {
                var safe = template
                safe.warnings.append("On-device model failed (\(error.localizedDescription)). Showing the written analysis instead.")
                return safe
            }
        }
        #endif
        return template
    }

    func analyzeFall(_ report: FallReport, sections: [SectionDelta]) async throws -> SectionAnalysis? {
        // Fall copy stays templated regardless of model availability. The
        // mechanical-fact versus fatigue-hypothesis split is the whole point of
        // that text, and a paraphrase can blur it.
        try await fallback.analyzeFall(report, sections: sections)
    }

    /// Returns a reason when the output must be rejected.
    static func guardFailure(_ analysis: SectionAnalysis, delta: SectionDelta, findings: [Finding]) -> String? {
        let text = analysis.allText
        if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return "it came back empty" }

        // Absolute, not tolerance-based: the figures live in the evidence lines,
        // so any digit in the prose is unsupported by construction.
        let strays = NumberGuard.straySignificantDigits(
            in: text,
            allowingMoveOrdinals: Set(findings.isEmpty ? [] : [delta.sectionIndex + 1])
        )
        if !strays.isEmpty {
            return "it quoted numbers, which belong in the measurement line, not the advice"
        }
        let units = NumberGuard.forbiddenUnitsPresent(in: text)
        if !units.isEmpty { return "it used units this app does not have (\(units.joined(separator: ", ")))" }
        let speculation = SpeculationGuard.violations(in: text)
        if !speculation.isEmpty { return "it speculated about the climber's state of mind (\(speculation.joined(separator: ", ")))" }
        if let primary = findings.first,
           let direction = DirectionGuard.violation(in: text, attemptIsWorse: primary.attemptIsWorse) {
            return direction
        }
        return nil
    }
}

#if canImport(FoundationModels)
@available(iOS 26.0, macOS 26.0, *)
@Generable
struct GeneratedSectionAnalysis {
    @Guide(description: "A short lower-case phrase naming what happened on this move. No numbers. Example: 'your arms did the work'.")
    var headline: String

    @Guide(description: "Rewrite each claim you were given as one or two sentences a coach would say at the wall. Same meaning, same direction, no numbers.", .count(1...2))
    var observations: [String]

    @Guide(description: "One thing to try next go, in plain words. Omit if the climber did nothing wrong.")
    var drill: String?
}
#endif
