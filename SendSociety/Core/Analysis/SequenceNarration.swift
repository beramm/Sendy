import Foundation

/// One measurement, said the way a provider is allowed to see it.
///
/// The figures stay in Swift. What crosses is the metric's name, what it
/// means, and **the finished phrase for each climber** — the same wording the
/// composer puts on the cards, with its direction already decided.
///
/// The phrasing matters more than it looks. Handed a direction to interpret —
/// `Hips off level: clearly lower` — the on-device model read it as a place on
/// the wall and swapped the two climbers. Handed `kept the hips more level` it
/// has nothing left to get backwards, because Swift already got it right.
public struct MeasurementBrief: Sendable, Hashable {
    public var name: String
    /// The plain-language definition shown to the reader in the Differences
    /// sheet. The provider gets the same one, so its prose and the glossary
    /// under it describe the same measurement.
    public var meaning: String
    /// What each climber did on this measurement, already worded.
    public var referencePhrase: String
    public var attemptPhrase: String

    public init(name: String, meaning: String, referencePhrase: String, attemptPhrase: String) {
        self.name = name
        self.meaning = meaning
        self.referencePhrase = referencePhrase
        self.attemptPhrase = attemptPhrase
    }

    public func phrase(forAttempt isAttempt: Bool) -> String {
        isAttempt ? attemptPhrase : referencePhrase
    }
}

/// Everything a provider is shown about one comparison sequence, and nothing
/// else.
///
/// It carries **claims, never measurements**. The headlines and sentences in
/// here were decided in Swift from `MetricKind.lowerIsBetter` and the measured
/// direction; a provider's job is to say them better, not to work out what
/// they are. Nothing numeric crosses this boundary, which is what makes
/// `NumberGuard`'s absolute rule enforceable on the way back: any digit in the
/// output was invented.
public struct SequenceNarrationRequest: Sendable, Hashable {
    public var sequenceIndex: Int
    public var kind: SequenceAnalysis.Kind
    /// The deterministic card phrases. A model may replace these; if it does
    /// not, or its version fails a guard, these are what the cards show.
    public var referenceHeadline: String
    public var attemptHeadline: String
    /// The long-form claims the Differences sheet reads today.
    public var referenceSentence: String
    public var attemptSentence: String
    /// The measurements behind the finding: what each one is, which climber
    /// was higher, and how big the gap was in words. Never a value.
    public var measurements: [MeasurementBrief]

    public var measurementNames: [String] { measurements.map(\.name) }
    public var comparisonIsValid: Bool
    public var unavailableReason: String?
    /// The measurements behind the finding, kept so `AnatomyGuard` can decide
    /// which body parts the prose is entitled to name.
    public var metricKinds: [MetricKind]
    /// Set only when the measurement licenses a direction, so `DirectionGuard`
    /// can check the prose still agrees with it. Nil for directionless metrics
    /// and for structural findings, where there is no better or worse.
    public var attemptIsWorse: Bool?
    /// The proximate/distal split, when this sequence is part of a fall. Kept
    /// separate because flattening it into coaching prose throws away the
    /// thing the fall analyser exists for.
    public var fallContext: String?

    public init(
        sequenceIndex: Int,
        kind: SequenceAnalysis.Kind,
        referenceHeadline: String,
        attemptHeadline: String,
        referenceSentence: String,
        attemptSentence: String,
        measurements: [MeasurementBrief] = [],
        metricKinds: [MetricKind] = [],
        comparisonIsValid: Bool,
        unavailableReason: String? = nil,
        attemptIsWorse: Bool? = nil,
        fallContext: String? = nil
    ) {
        self.sequenceIndex = sequenceIndex
        self.kind = kind
        self.referenceHeadline = referenceHeadline
        self.attemptHeadline = attemptHeadline
        self.referenceSentence = referenceSentence
        self.attemptSentence = attemptSentence
        self.measurements = measurements
        self.metricKinds = metricKinds
        self.comparisonIsValid = comparisonIsValid
        self.unavailableReason = unavailableReason
        self.attemptIsWorse = attemptIsWorse
        self.fallContext = fallContext
    }

    /// Builds the request from a composed analysis. One place, so the model
    /// and the template provider are shown exactly the same thing.
    public init?(
        analysis: SequenceAnalysis,
        config: TuningConfig = TuningConfig(),
        fallContext: String? = nil
    ) {
        guard let reference = analysis.referenceFinding,
              let attempt = analysis.attemptFinding
        else { return nil }

        let kinds = [reference.metricKind, attempt.metricKind].compactMap { $0 }
        self.init(
            sequenceIndex: analysis.sequenceIndex,
            kind: analysis.kind,
            referenceHeadline: reference.headline ?? reference.observation,
            attemptHeadline: attempt.headline ?? attempt.observation,
            referenceSentence: reference.sentence(subject: "The other climber", causeSubject: "they"),
            attemptSentence: attempt.sentence(subject: "You", causeSubject: "you"),
            measurements: Self.briefs(for: analysis, findingKinds: kinds, config: config),
            metricKinds: Self.evidenceKinds(for: analysis, findingKinds: kinds),
            comparisonIsValid: analysis.comparisonIsValid,
            unavailableReason: reference.unavailableReason ?? analysis.numbersUnavailableReason,
            attemptIsWorse: analysis.metrics
                .first { $0.kind == attempt.metricKind }?
                .attemptIsWorse,
            fallContext: fallContext
        )
    }

    /// The measurements the composer actually chose for this pair — the
    /// observation's and its cause's — named the way Detailed Analytics names
    /// them, so a reader who goes looking finds the same rows.
    ///
    /// `SequenceDifferenceFinding` records only the outcome metric, so the
    /// cause is recovered from the evidence the composer ranked to the top.
    /// Turns the finding's evidence into what a provider may see: names,
    /// meanings, directions and magnitude words. Every figure stays behind.
    static func briefs(
        for analysis: SequenceAnalysis,
        findingKinds: [MetricKind],
        config: TuningConfig
    ) -> [MeasurementBrief] {
        let kinds = evidenceKinds(for: analysis, findingKinds: findingKinds)
        let delta = SectionDelta(
            sectionIndex: analysis.sequenceIndex,
            sectionName: "Sequence",
            deltas: analysis.metrics,
            divergence: nil,
            attemptReached: true,
            alignmentCost: nil
        )
        return kinds.compactMap { kind -> MeasurementBrief? in
            guard let metric = analysis.metrics.first(where: { $0.kind == kind }),
                  let reference = metric.reference,
                  let attempt = metric.attempt,
                  delta.magnitude(of: metric, config: config).isWorthReporting
            else { return nil }
            let phrases = SequenceAnalysisComposer.differencePhrases(for: kind)
            let referenceIsHigher = reference > attempt
            return MeasurementBrief(
                name: kind.displayName,
                meaning: kind.plainMeaning,
                referencePhrase: lowercasedFirst(referenceIsHigher ? phrases.higher : phrases.lower),
                attemptPhrase: lowercasedFirst(referenceIsHigher ? phrases.lower : phrases.higher)
            )
        }
    }

    static func lowercasedFirst(_ value: String) -> String {
        guard let first = value.first else { return value }
        return first.lowercased() + String(value.dropFirst())
    }

    static func evidenceKinds(
        for analysis: SequenceAnalysis,
        findingKinds: [MetricKind]
    ) -> [MetricKind] {
        var seen: Set<MetricKind> = []
        return Array(
            (findingKinds + analysis.metrics.map(\.kind))
                .filter { seen.insert($0).inserted }
                .prefix(4)
        )
    }
}

/// One sequence's generated text: the pair of card phrases and the pair of
/// paragraphs behind them.
///
/// Produced by the pipeline and cached with the session. **A view never asks
/// for one** — text that is regenerated on a reopen is text that changes under
/// the reader.
public struct SequenceNarration: Sendable, Hashable, Codable {
    public var referenceHeadline: String
    public var attemptHeadline: String
    public var referenceNarrative: String
    public var attemptNarrative: String
    /// Which provider produced it, so template output is distinguishable from
    /// on-device model output at a glance.
    public var source: String

    public init(
        referenceHeadline: String,
        attemptHeadline: String,
        referenceNarrative: String,
        attemptNarrative: String,
        source: String
    ) {
        self.referenceHeadline = referenceHeadline
        self.attemptHeadline = attemptHeadline
        self.referenceNarrative = referenceNarrative
        self.attemptNarrative = attemptNarrative
        self.source = source
    }

}

/// What a card phrase has to satisfy before it is allowed on screen.
///
/// A model asked for four words will sometimes write twelve, and asking nicely
/// in the prompt is not enforcement. These are the checks that make the prompt
/// binding: fail any of them and the deterministic phrase stands.
public enum HeadlineGuard {
    public static let maximumWords = 6

    /// Returns a reason the phrase must be rejected, or nil when it may show.
    public static func failure(_ phrase: String) -> String? {
        let trimmed = phrase.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return "it came back empty" }

        let words = trimmed.split(whereSeparator: \.isWhitespace)
        if words.count > maximumWords {
            return "it ran to \(words.count) words on a card sized for \(maximumWords)"
        }
        if !NumberGuard.numbers(in: trimmed).isEmpty {
            return "it quoted a number, which belongs in Detailed Analytics"
        }
        // The badge beside the phrase already says whose it is. A phrase that
        // opens with a subject is a sentence that lost its verb.
        let lead = words.first.map(String.init)?.lowercased() ?? ""
        if ["you", "your", "the", "they", "their"].contains(lead) {
            return "it started with a subject the REF/YOU badge already supplies"
        }
        if let last = trimmed.last, ".!?".contains(last) {
            return "it was punctuated as a sentence"
        }
        let units = NumberGuard.forbiddenUnitsPresent(in: trimmed)
        if !units.isEmpty { return "it used units this app does not have (\(units.joined(separator: ", ")))" }
        let speculation = SpeculationGuard.violations(in: trimmed)
        if !speculation.isEmpty {
            return "it speculated about the climber's state of mind (\(speculation.joined(separator: ", ")))"
        }
        return nil
    }

    /// Trims a phrase to the form the card renders: no surrounding whitespace
    /// and no trailing full stop. A headline is not a sentence.
    public static func tidied(_ phrase: String) -> String {
        var trimmed = phrase.trimmingCharacters(in: .whitespacesAndNewlines)
        while let last = trimmed.last, ".!?;:,".contains(last) {
            trimmed.removeLast()
        }
        return trimmed.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

/// What a Differences paragraph has to satisfy.
///
/// A paragraph is more room to invent a measurement than a sentence, not less,
/// so the same absolute number rule applies: the figures live in Detailed
/// Analytics, and any digit here is unsupported by construction. The sequence
/// ordinal is the one exception, and code templates that in.
public enum NarrativeGuard {
    /// `claim` is the one climber's deterministic sentence this paragraph was
    /// asked to rewrite. Optional so callers that only want the absolute
    /// checks — numbers, units, anatomy — can skip the causal comparison.
    /// `isAttempt` says whose paragraph this is, so the guard can check the
    /// prose only claims things from that climber's own list. Omit it to run
    /// the absolute checks alone.
    public static func failure(
        _ text: String,
        request: SequenceNarrationRequest,
        claim: String? = nil,
        isAttempt: Bool? = nil
    ) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return "it came back empty" }

        let strays = NumberGuard.straySignificantDigits(
            in: trimmed,
            allowingMoveOrdinals: [request.sequenceIndex + 1]
        )
        if !strays.isEmpty {
            return "it quoted numbers, which belong in Detailed Analytics, not the prose"
        }
        let units = NumberGuard.forbiddenUnitsPresent(in: trimmed)
        if !units.isEmpty { return "it used units this app does not have (\(units.joined(separator: ", ")))" }
        let speculation = SpeculationGuard.violations(in: trimmed)
        if !speculation.isEmpty {
            return "it speculated about the climber's state of mind (\(speculation.joined(separator: ", ")))"
        }
        let outcomes = OutcomeGuard.violations(in: trimmed)
        if !outcomes.isEmpty {
            return "it claimed an outcome nothing measured (\(outcomes.joined(separator: ", ")))"
        }
        let anatomy = AnatomyGuard.violations(
            in: trimmed,
            licensedBy: AnatomyGuard.licensedTerms(
                metricKinds: request.metricKinds,
                claims: [
                    request.referenceSentence, request.attemptSentence,
                    request.referenceHeadline, request.attemptHeadline
                ] + request.measurements.map(\.meaning)
            )
        )
        if !anatomy.isEmpty {
            return "it named a body part the measurement did not (\(anatomy.joined(separator: ", ")))"
        }
        if let attemptIsWorse = request.attemptIsWorse,
           let direction = DirectionGuard.violation(in: trimmed, attemptIsWorse: attemptIsWorse) {
            return direction
        }
        if let claim, let inverted = CausalOrderGuard.failure(in: trimmed, claim: claim) {
            return inverted
        }
        if let isAttempt, let crossed = crossTalk(in: trimmed, request: request, isAttempt: isAttempt) {
            return crossed
        }
        if let repeated = repetition(in: trimmed) {
            return repeated
        }
        return nil
    }

    /// Rejects a paragraph that gives one climber the other's half of a
    /// measurement.
    ///
    /// Every measurement crosses as a pair of finished phrases, one per
    /// climber, and they are opposites by construction. So a paragraph about
    /// the reference that contains the attempt's phrase for the same
    /// measurement has said both sides of one thing about one person — which
    /// is what happened on device: "They moved more directly. … They took a
    /// longer movement path." Both are true of that measurement; only one is
    /// true of that climber.
    ///
    /// Matching is on the whole phrase, which is safe because the phrases are
    /// code-written and the model quotes them close to verbatim. A paraphrase
    /// loose enough to slip past this is also loose enough not to be a
    /// contradiction.
    static func crossTalk(
        in text: String,
        request: SequenceNarrationRequest,
        isAttempt: Bool
    ) -> String? {
        let haystack = normalised(text)
        for measurement in request.measurements {
            let theirs = normalised(measurement.phrase(forAttempt: !isAttempt))
            let ours = normalised(measurement.phrase(forAttempt: isAttempt))
            guard !theirs.isEmpty, theirs != ours, haystack.contains(theirs) else { continue }
            return "it gave this climber the other one's side of \(measurement.name.lowercased())"
        }
        return nil
    }

    /// Rejects a paragraph that says the same sentence twice.
    ///
    /// Four near-synonymous measurements — path length, path directness, foot
    /// placements, time on the move — sent the model round in a loop, writing
    /// "you took a longer movement path because you used more foot placements"
    /// three times in one paragraph.
    static func repetition(in text: String) -> String? {
        let sentences = text
            .split(whereSeparator: { ".!?".contains($0) })
            .map { normalised(String($0)) }
            .filter { $0.count > 12 }
        var seen: Set<String> = []
        for sentence in sentences where !seen.insert(sentence).inserted {
            return "it repeated the same sentence"
        }
        return nil
    }

    static func normalised(_ text: String) -> String {
        text.lowercased()
            .split(whereSeparator: { !$0.isLetter && !$0.isWhitespace })
            .joined(separator: " ")
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
    }
}
