import Foundation

/// A single thing worth telling the climber, with a cause attached where the
/// measurements support one.
public struct Finding: Sendable, Hashable {
    /// Short, plain, no figures. Becomes the headline or an observation.
    public var claim: String
    /// Why it happened, when two measurements together license saying so.
    /// `nil` when the metric stands alone.
    public var because: String?
    /// Something to try next go. Never a number to hit.
    public var drill: String?
    /// The metrics behind it, in ranked order. Drives the evidence lines and
    /// the direction guard.
    public var metrics: [MetricDelta]
    /// True when the attempt did this *better* than the reference climber.
    /// Kept explicit so nothing downstream has to infer polarity — inferring it
    /// is exactly how "Attempt Lagging Behind" got emitted for a better move.
    public var attemptIsWorse: Bool

    public init(claim: String, because: String? = nil, drill: String? = nil, metrics: [MetricDelta], attemptIsWorse: Bool) {
        self.claim = claim
        self.because = because
        self.drill = drill
        self.metrics = metrics
        self.attemptIsWorse = attemptIsWorse
    }

    public var primaryMetric: MetricKind? { metrics.first?.kind }

    /// What a reader sees: claim plus cause, as one sentence.
    public var text: String {
        guard let because else { return claim }
        return "\(claim) \(because)"
    }
}

/// Turns a `SectionDelta` into findings — **in Swift, deterministically**.
///
/// This exists because listing metrics is not coaching. "Your arms took more
/// load", "your hips were further out" and "your arms were bent for longer" are
/// three readings of one story: the hips being off the wall put the weight on
/// the arms. A coach says the story; the app was saying the readings.
///
/// It also fixes a failure mode the language model had on its own. Given bare
/// labelled numbers with no indication of which direction is good, the model
/// announced "Attempt Lagging Behind Reference" for a move where the attempt's
/// path was *shorter* — better. Here the polarity is decided by code that knows
/// `MetricKind.lowerIsBetter`, and the model never gets to choose it.
public struct FindingComposer: Sendable {

    public var config: TuningConfig

    public init(config: TuningConfig = TuningConfig()) {
        self.config = config
    }

    public func compose(_ delta: SectionDelta) -> [Finding] {
        let significant = delta.significantDeltas(threshold: config.deltaSignificanceThreshold)
        guard !significant.isEmpty else { return [] }

        var findings = causalFindings(delta, significant: significant)
        // Metrics already spoken for by a causal finding must not be repeated
        // as a standalone observation.
        let spoken = Set(findings.flatMap { $0.metrics.map(\.kind) })

        for d in significant where !spoken.contains(d.kind) {
            if let finding = standalone(d, delta: delta) { findings.append(finding) }
        }
        // Two findings is what a person can act on. More is a list again.
        return Array(findings.prefix(2))
    }

    // MARK: Causal rules

    /// Each rule needs every one of its metrics to be significant *and* pointing
    /// the same way. A rule that fires on one metric alone would be inventing
    /// the causal link rather than measuring it.
    func causalFindings(_ delta: SectionDelta, significant: [MetricDelta]) -> [Finding] {
        var out: [Finding] = []
        func worse(_ kind: MetricKind) -> MetricDelta? {
            significant.first { $0.kind == kind && $0.attemptIsWorse == true }
        }
        func better(_ kind: MetricKind) -> MetricDelta? {
            significant.first { $0.kind == kind && $0.attemptIsWorse == false }
        }

        // Hips off the wall → weight onto the arms. The classic beginner tell,
        // and the one case where the app can name a cause with confidence
        // because the mechanism is geometric, not statistical.
        if let arms = worse(.armLoadShare), let hips = worse(.hipDistanceMean) {
            out.append(Finding(
                claim: "You were holding yourself on with your arms more than they were.",
                because: "Your hips sat further off the wall, so your weight had nowhere to go but onto your hands.",
                drill: "Try turning a hip into the wall before you reach, so your feet take the weight instead of your fingers.",
                metrics: [arms, hips],
                attemptIsWorse: true
            ))
        }

        // Feet on the wall but not pushing. Distinct from having no feet on,
        // and the thing coaches mean by "use your feet".
        if let arms = worse(.armLoadShare), let feet = worse(.unweightedFootTime), out.isEmpty {
            out.append(Finding(
                claim: "Your feet were on the holds but not taking any weight.",
                because: "Everything went through your hands instead, which is what makes a move like this feel harder than it is.",
                drill: "Push through the foothold as you move — you should feel the hold under your toe take some of you.",
                metrics: [arms, feet],
                attemptIsWorse: true
            ))
        }

        // Task 7.6 — the hand went first and the feet followed. This is the
        // footwork fault that shows up most on video and is invisible in a
        // placement count.
        if let feet = worse(.feetSetBeforeReach), let arms = worse(.armLoadShare), out.isEmpty {
            out.append(Finding(
                claim: "You went for the hold first and sorted your feet out afterwards.",
                because: "That leaves you hanging off your arms while you fix your feet, which is where the extra effort went.",
                drill: "Set both feet where you want them, then move your hand. Feet first, hand second.",
                metrics: [feet, arms],
                attemptIsWorse: true
            ))
        }

        // Slow to trust a foot, and it cost time on the wall.
        if let commitment = worse(.footCommitmentSeconds), let dwell = worse(.sectionDwellRatio), out.isEmpty {
            out.append(Finding(
                claim: "You were slow to trust your feet on this move.",
                because: "Each foot sat on its hold a while before you put any weight through it, and that hesitation is most of the extra time you spent here.",
                drill: "Once the foot is on, press into it straight away — commit to it rather than testing it.",
                metrics: [commitment, dwell],
                attemptIsWorse: true
            ))
        }

        // Searching for feet mid-move rather than committing.
        if let path = worse(.comPathLength), let placements = worse(.footPlacementCount) {
            out.append(Finding(
                claim: "You spent this move hunting for feet rather than committing to one.",
                because: "Each adjustment moved your whole body, so you covered more ground than the move needed.",
                drill: "Pick the foothold before you weight it, and place it once.",
                metrics: [path, placements],
                attemptIsWorse: true
            ))
        }

        // Reaching from too far out, with the arms already loaded.
        if let reach = worse(.reachMargin), let arms = worse(.armLoadShare), out.isEmpty {
            out.append(Finding(
                claim: "You were reaching for the next hold from further away than they were.",
                because: "That leaves you pulling in with your arms at full stretch instead of moving your body in first.",
                drill: "Move your hips towards the hold before your hand goes for it.",
                metrics: [reach, arms],
                attemptIsWorse: true
            ))
        }

        // Bent arms plus arm load: hanging and pulling at the same time.
        if let straight = worse(.straightArmRatio), let arms = worse(.armLoadShare), out.isEmpty {
            out.append(Finding(
                claim: "You held this move with bent arms while your arms were also taking most of your weight.",
                because: "That is the most tiring way to stay on the wall — the reference climber hung straighter and let the skeleton do the work.",
                drill: "Between moves, let your arms straighten and hang off the bones rather than the muscle.",
                metrics: [straight, arms],
                attemptIsWorse: true
            ))
        }

        // The coach's own read, in his own order: the pelvis explains the arm.
        // A hip that stays square to the wall leaves the arm to lever the body
        // in, and the lat angle is where that shows up. Two measurements, one
        // mechanism — which is the bar for naming a cause here.
        if let pulling = worse(.pullingArmTime), let turn = worse(.pelvisTurn), out.isEmpty {
            out.append(Finding(
                claim: "You stayed square to the wall and pulled yourself in with your arms.",
                because: "They turned a hip into the wall instead, which puts the reach on the legs rather than on the lats.",
                drill: "Before the reach, turn the hip on your reaching side towards the wall until your shoulder comes with it.",
                metrics: [pulling, turn],
                attemptIsWorse: true
            ))
        }

        // Leaning off the plumb line loads one arm and the opposite leg. The
        // coach reads this off a single still; here it is two measurements that
        // have to agree before anything is said.
        if let lean = worse(.torsoLean), let asymmetry = worse(.loadAsymmetry), out.isEmpty {
            out.append(Finding(
                claim: "You hung off to one side rather than under your hands.",
                because: "Your body sat further off vertical than theirs, so one arm and the opposite leg carried most of the move.",
                drill: "Get your hips under the hand you are pulling on before you move — the weight should feel even across both arms.",
                metrics: [lean, asymmetry],
                attemptIsWorse: true
            ))
        }

        // Hips off level plus load on the arms: the pelvis dropping on one side
        // is what pulls the weight back onto the hands.
        if let tilt = worse(.pelvisTilt), let arms = worse(.armLoadShare), out.isEmpty {
            out.append(Finding(
                claim: "One hip dropped through this move.",
                because: "With the pelvis tilted, the low side stops pressing into its foot and the weight goes back onto your hands.",
                drill: "Keep the hips level as you move up — press the low foot down until both hips sit on one line.",
                metrics: [tilt, arms],
                attemptIsWorse: true
            ))
        }

        // Something done well. Worth saying — an app that only ever finds fault
        // is one people stop reading.
        if out.isEmpty, let path = better(.comPathLength), let arms = better(.armLoadShare) {
            out.append(Finding(
                claim: "You did this move more directly than they did, and with less on your arms.",
                because: nil,
                drill: nil,
                metrics: [path, arms],
                attemptIsWorse: false
            ))
        }
        return out
    }

    // MARK: Standalone claims

    /// One metric, no cause available. Still said as a claim rather than a
    /// reading — "your hips were further off the wall", not "hip distance was
    /// 0.31 against 0.22".
    func standalone(_ d: MetricDelta, delta: SectionDelta) -> Finding? {
        let magnitude = delta.magnitude(of: d, config: config)
        guard magnitude.isWorthReporting else { return nil }
        let worse = d.attemptIsWorse ?? false
        let much = magnitude == .large ? " a lot" : (magnitude == .clear ? "" : " slightly")

        switch d.kind {
        case .armLoadShare, .armLoadPeak:
            return Finding(
                claim: worse
                    ? "More of your weight went through your arms\(much) than theirs."
                    : "You kept more of your weight off your arms than they did.",
                drill: worse ? "Look for a foot that lets you stand up into the move instead of pulling through it." : nil,
                metrics: [d], attemptIsWorse: worse
            )
        case .feetSetBeforeReach:
            return Finding(
                claim: worse
                    ? "You tended to move your hand before your feet were ready."
                    : "You had your feet set before you moved, as they did.",
                drill: worse ? "Get both feet where you want them before the hand goes." : nil,
                metrics: [d], attemptIsWorse: worse
            )
        case .footCommitmentSeconds:
            return Finding(
                claim: worse
                    ? "You took\(much) longer than they did to put weight on a foot once it was placed."
                    : "You committed to your feet as soon as they were on.",
                drill: worse ? "Press into the hold as the foot lands rather than testing it first." : nil,
                metrics: [d], attemptIsWorse: worse
            )
        case .unweightedFootTime:
            return Finding(
                claim: worse
                    ? "Your feet were on the wall but not doing much of the work."
                    : "You kept weight through your feet throughout.",
                drill: worse ? "Press into the foothold and feel it take some of you before you move." : nil,
                metrics: [d], attemptIsWorse: worse
            )
        case .hipDistanceMean, .hipDistancePeak:
            return Finding(
                claim: worse
                    ? "Your hips sat\(much) further off the wall than theirs."
                    : "You kept your hips closer to the wall than they did.",
                drill: worse ? "Turn a hip in and let it come to the wall before you reach." : nil,
                metrics: [d], attemptIsWorse: worse
            )
        case .straightArmRatio:
            return Finding(
                claim: worse
                    ? "You held on with bent arms for more of this move than they did."
                    : "You kept your arms straighter than they did.",
                drill: worse ? "Let the arms straighten between moves and pull only as you move." : nil,
                metrics: [d], attemptIsWorse: worse
            )
        case .comPathLength:
            return Finding(
                claim: worse
                    ? "You moved around\(much) more than the move needed."
                    : "You took a more direct line through this move than they did.",
                drill: worse ? "Try to travel the shortest line between the two positions." : nil,
                metrics: [d], attemptIsWorse: worse
            )
        case .comPeakVelocity:
            // Directionless: faster is neither good nor bad, it is a style.
            let faster = (d.delta ?? 0) > 0
            return Finding(
                claim: faster
                    ? "You did this move more dynamically than they did."
                    : "You did this move more statically than they did.",
                metrics: [d], attemptIsWorse: false
            )
        case .loadAsymmetry:
            return Finding(
                claim: worse
                    ? "You leaned\(much) harder on one side than they did."
                    : "You shared the move more evenly between both sides than they did.",
                drill: worse ? "Run the move again deliberately loading the quiet side." : nil,
                metrics: [d], attemptIsWorse: worse
            )
        case .footPlacementCount:
            return Finding(
                claim: worse
                    ? "You reset your feet more times than they did."
                    : "You placed your feet once and left them, as they did.",
                drill: worse ? "Choose the foothold before you move onto it." : nil,
                metrics: [d], attemptIsWorse: worse
            )
        case .hipTwist:
            return Finding(
                claim: "You faced the wall differently through this move than they did.",
                drill: "Try it square-on and with a hip turned in, and see which feels lighter on the arms.",
                metrics: [d], attemptIsWorse: false
            )
        case .reachMargin:
            return Finding(
                claim: worse
                    ? "You latched the hold from further out than they did."
                    : "You got your body closer to the hold before taking it than they did.",
                drill: worse ? "Bring your hips towards the hold before your hand leaves." : nil,
                metrics: [d], attemptIsWorse: worse
            )
        case .pelvisTilt:
            return Finding(
                claim: worse
                    ? "One of your hips sat\(much) lower than the other through this move."
                    : "You kept your hips more level than they did.",
                drill: worse ? "Press down through the low foot until both hips sit on the same line." : nil,
                metrics: [d], attemptIsWorse: worse
            )
        case .pelvisTurn:
            return Finding(
                claim: worse
                    ? "You stayed squarer to the wall than they did."
                    : "You turned a hip into the wall more than they did.",
                drill: worse ? "Try the move again with the hip on your reaching side turned in to the wall." : nil,
                metrics: [d], attemptIsWorse: worse
            )
        case .torsoLean:
            return Finding(
                claim: worse
                    ? "You hung\(much) further off vertical than they did."
                    : "You stayed more directly under your hands than they did.",
                drill: worse ? "Move your hips under the hand you are pulling on before you commit to the reach." : nil,
                metrics: [d], attemptIsWorse: worse
            )
        case .kneeDrive:
            return Finding(
                claim: worse
                    ? "You kept your knees stacked over your feet where they dropped a knee in."
                    : "You drove a knee across your foot to get in close, as they did.",
                drill: worse ? "Turn the knee in across the toe and let the hip follow it to the wall." : nil,
                metrics: [d], attemptIsWorse: worse
            )
        case .pullingArmTime:
            return Finding(
                claim: worse
                    ? "You spent\(much) more of this move actually pulling than they did."
                    : "You pulled less than they did to get through this.",
                drill: worse ? "Look for the foot that lets you stand up into the hold instead of pulling in to it." : nil,
                metrics: [d], attemptIsWorse: worse
            )
        case .diagonalLoadBalance:
            return Finding(
                claim: worse
                    ? "Your weight sat on one diagonal — one hand and the opposite foot took the move."
                    : "You spread the move across both diagonals more evenly than they did.",
                drill: worse ? "Set the quiet foot and press it as you pull, so both diagonals share the move." : nil,
                metrics: [d], attemptIsWorse: worse
            )
        case .sectionDwellRatio:
            let slower = (d.attempt ?? 1) > 1
            return Finding(
                claim: slower
                    ? "You spent longer on this move than they did."
                    : "You moved through this quicker than they did.",
                drill: slower ? "Rehearse this move on its own until the sequence stops needing thought." : nil,
                metrics: [d], attemptIsWorse: slower
            )
        }
    }
}
