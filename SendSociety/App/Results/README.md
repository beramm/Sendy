# Results architecture and product decisions

This is the implementation and product decision record for the Results feature. It is written for people and AI coding agents. Read it before changing result navigation, playback synchronization, sequence analytics, insight wording, metric availability, or presentation.

## Maintenance contract

This is living documentation. **Every change that alters Results behavior, architecture, analytics, or presentation must update this file in the same code change.** A Results change is incomplete when implementation and documentation disagree.

Update the relevant sections when changing:

- what a sequence means or how numbered navigation works;
- Side by Side, Overlay, skeleton, playback, scrubbing, or synchronization;
- sequence-analysis inputs, aggregation, priority, output, fall, or divergence handling;
- paired main-difference observation/cause vocabulary, ranking, availability, or color meaning;
- metrics, comparison availability, empty states, or low-confidence behavior;
- Results file ownership or architecture.

For AI agents: inspect this file before editing `SendSociety/App/Results`, `SequenceAnalysisComposer`, the sequence overloads in `MetricsEngine`, or Results-related code in `ProcessingPipeline`. Update existing rules rather than appending a contradictory changelog.

## Architecture

- `SendSociety/App/Results/ResultsView.swift` is the production root view and owns sequence navigation and synchronized playback.
- Every Results-owned Swift file lives directly under `SendSociety/App/Results`.
- `ResultPosition.swift` must remain in this folder. It defines `MovePosition`, the playhead state required by `ResultsView`.

## Product goal

Results compares two climbing videos one **sequence** at a time. A sequence is an anchor-to-anchor span and may contain different numbers of moves for the reference and attempt climbers.

The screen should:

1. Show synchronized visual evidence.
2. Let the user select a sequence.
3. Present one shared main difference for the whole sequence from REF's side and YOU's side, written as one natural sentence per card.
4. Prefer a deterministic, licensed observation-and-cause pair. When the measurements show a real difference but do not license causality, report the strongest measured contrast honestly instead of displaying **Causal insight unavailable**.
5. Keep supporting measurements available without making them the main story.

## Approved sequence-detail presentation

`Sequence Detail.png` is the current result-screen reference. `Tutorial.png` is the current Detailed Analytics sheet reference. Treat both as layout references; their placeholder metric copy is not product data.

- The close button sits alone at the top trailing edge. Display controls occupy a row below it.
- Side by Side and Overlay use a two-option control. The selected segment is white with black text; the unselected segment uses muted text on the shared dark surface.
- The skeleton and overflow buttons use the same dark surface and `18pt` continuous radius. The skeleton button uses the supplied `ResultsSkeleton` SVG; its active background is accent green and its icon is black.
- Side-by-side video panes use the source aspect ratio and a `16pt` continuous radius. REF and YOU are dark capsule badges inside the footage, with REF text in accent green and YOU text in blue.
- Skeleton identity is stable in every display mode: REF is accent green and YOU is blue. Do not use the old orange attempt color.
- Overlay preserves the processed wall-plate image, route marks, and both synchronized skeletons. It has exactly the same width and height as one Side by Side pane and is centered in the row. Wall and skeleton geometry remain aspect-fit and at the same scale as one video pane. The diagnostic gray fallback is disabled; a missing wall plate exposes the near-black Results surface.
- Sequence buttons use a `15pt` radius and intentionally vary in width: ordinary buttons are `52pt`, move-count-different buttons are `64pt`, and the selected button is `72pt` wide and `48pt` tall. A reference/attempt move-count difference uses the bright accent with dark text. Selection uses the same accent plus bold numbering and the largest dimensions. A fall takes priority: red background, white text, and a small `F`; bold type and the selected dimensions still communicate selection.
- Playback uses a plain white play/pause symbol beside the scrubber. Playback and scrubbing are always synchronized.
- Plain centered text identifies `Sequence n of count` below playback. It has no capsule or other background; `Sequence` is muted and `n of count` is white and bold.
- Two equal-width near-black cards use a `16pt` continuous radius and compact `112pt` minimum height. Each card shows its colored REF/YOU badge, that climber's duration for the selected sequence, and one centered sentence for its side of the same analysis. Insight text has no line cap: it wraps completely and the card grows vertically instead of truncating with an ellipsis. Licensed observation and cause remain separate in Core and are joined with “because.” A non-causal secondary contrast uses “while”; one significant measurement stands alone. Do not show Observation/Cause subtitles, separate sections, a divider, or separate cause styling. Muted unavailable cards are reserved for absent or unreliable comparison data, not for a missing causal rule.
- The analytics entry point is always titled **Detailed Analytics** with a trailing chevron, a `16pt` radius, and a compact `56pt` minimum height.
- The Detailed Analytics sheet uses a fixed opaque gray surface, a `30pt` top radius, the system drag indicator, and a `0.61` initial detent. Its centered title renders **Detailed** in white and **Analytics** in accent green. Each metric has a slim white leading rule, title and unit, then YOU and REFERENCE bars. Identity remains consistent with Results: REF/REFERENCE is green and YOU is blue. The sheet owns both metric rows and explanations for unavailable numbers.

These are fixed visual tokens. Avoid adding `.glassEffect` to these Results surfaces because it changes their color and apparent radius across backgrounds.

## Clarification record: original ten questions

The wording below is condensed from the design conversation while preserving the user's answers and resulting behavior.

### 1. What do the numbered buttons represent?

**User answer:** The numbered buttons represent the sequence.

**Decision:** The selected number indexes `ProcessedSession.sequences.sequences`, not an individual move. The strip centers when all sequences fit and scrolls when they do not.

Marker states:

- fall in sequence: red with `F`;
- different reference/attempt move counts: bright accent;
- selected: bright accent, bold number, and the widest/tallest button dimensions;
- fall overrides the background color when states overlap;
- ordinary unselected sequence: neutral dark surface.

Move-count difference is navigation context only. It must never produce **Used fewer moves** or **Used more moves** in the insight cards because that states a difference without explaining its cause.

### 2. What do Side by Side, Overlay, and the skew button do?

**User answer:** Side by Side is the normal video view. The skew button shows skeletons over those videos. Overlay shows the comparison skeletons only, and the skew button is always on in Overlay.

**Current decision:**

- **Side by Side + skew off:** two synchronized video panes.
- **Side by Side + skew on:** two synchronized videos with their skeletons.
- **Overlay:** the original processed wall image with both comparison skeletons. The later request to make it “like Side by Side” applied only to the size and aspect-ratio presentation, not to replacing the wall image with video.
- Skeleton display is mandatory in Overlay and cannot be turned off there.

The Overlay card uses the dimensions of one Side by Side pane and is centered. The wall plate, route, reference skeleton, attempt skeleton, center of mass, and base of support share one aspect-fitted reference/wall rectangle. Never stretch normalized coordinates to fill the whole row. `normalizeBodyLength` is `false`, so both skeletons keep their tracked wall-space positions and relative sizes.

### 3. What should the main text represent?

**User answer:** The primary coaching insight.

**Current decision:** The paired cards show the selected sequence's strongest shared measured difference. A licensed cause is preferred—for example REF **Kept more weight off the arms** because they **Stayed closer to the wall**, while YOU **Put more weight through the arms** because they **Stayed farther from the wall**. If no causal pair clears the thresholds, the cards show the strongest measured body-position contrast with contextual wording rather than claiming causality or pretending no insight exists. The cards never select unrelated traits independently.

### 4. What is the insight structure?

**User answer:** Just observation and cause.

**Superseding decision:** The designer replaced the single comparison card with paired REF and YOU analyses. Results reads `SequenceAnalysis.referenceFinding` and `SequenceAnalysis.attemptFinding`; both are produced by one main-difference decision. Observation and cause are an internal reasoning structure, not two visible UI sections. `SequenceDifferenceFinding.sentence(subject:causeSubject:)` joins a licensed cause with “because,” or a supporting but non-causal measurement with “while.” If only one reliable difference clears significance, it remains a plain observation. The comparative `SequenceAnalysis.observation` and optional `SequenceAnalysis.cause` remain in Core for structural, fall, comparison-validity, and unavailable explanations. Drills, warnings, and multiple per-move observations remain out of the main screen.

### 5. Which text receives the green accent?

**User answer:** The cause.

**Superseding decision:** Green now identifies REF, while blue identifies YOU. The badges, skeletons, and Detailed Analytics bars follow that identity contract. Main finding text is white when available and muted when unavailable. Green is no longer a marker for the old cause sentence.

### 6. How should supporting detail be presented?

**User answer:** Use the recommended approach.

**Accepted recommendation:** Keep both main cards concise and put the selected sequence's supporting measurements in Detailed Analytics. When comparison is invalid, never synthesize a reference value merely to complete the visual pair.

### 7. Were the original analytics per move, and how did the old implementation work?

**User answer:** Asked how the implementation worked because the user did not write it.

**Answer:** The deleted diagnostic screen navigated by sequence but displayed every per-move `SectionAnalysis` whose reference move belonged to that sequence. That was sequence-shaped navigation, not sequence-level coaching.

**Current decision:** The pipeline creates one `SequenceAnalysis` container for every `ClimbSequence`. That container includes paired REF/YOU wording for one shared main difference, the existing comparison state, and supporting numbers. `ResultsView` must not select, merge, or generate coaching prose from per-move analyses. The pipeline still produces `[SectionAnalysis]` for provider compatibility and instrumentation, but Results does not display it.

### 8. How should divergent or non-comparable sequences work?

**User answer:** Use the recommended approach.

**Accepted recommendation:** Never show a false reference comparison. Describe structural differences when hold order differs or the attempt is truncated. Reliable attempt-only metrics may be shown without reference values. If the attempt did not reach a sequence, explain that instead of fabricating metrics.

### 9. How did the original implementation synchronize playback?

**User answer:** Asked how it worked because the user did not write it.

**Answer:** Position was sequence index plus normalized offset. With sync lock enabled, reference frames mapped to attempt frames through `sequenceWarpPaths` dynamic-time-warping paths. The deleted diagnostic screen also had a manual unlock escape hatch.

### 10. Should Results playback always remain synchronized?

**User answer:** Yes, always sync.

**Decision:** Results exposes no unlock control. Playback, scrubbing, and sequence changes stay locked, with attempt frames resolved through `sequenceWarpPaths`.

## Sequence-level analytics

`ProcessingPipeline` produces direct anchor-to-anchor `[SectionDelta]` values in `sequenceDeltas` and one `[SequenceAnalysis]` for every `ClimbSequence`.

`SequenceAnalysisComposer`:

1. Measures the reference's complete anchor-to-anchor range.
2. Measures the attempt's complete range between the same anchors.
3. Builds a delta from those two whole-span measurements.
4. Uses move deltas only for fall attribution or as fallback evidence when a direct sequence comparison cannot be built.
5. Resolves fall and non-comparable structural states before metric ranking.
6. Keeps move-count differences in the sequence-strip state but excludes them from insight selection.
7. Builds candidate findings from a sequence-specific causal catalog. Both metrics must be significant, confident, and point in the licensed same/opposite direction.
8. Ranks causal candidates by their weaker normalized signal, so a large observation cannot borrow credibility from a barely visible cause. Body-position and COM relationships appear before the legacy arm/foot relationships to avoid an arm-first tie bias.
9. Returns two `SequenceDifferenceFinding` values from the selected shared evidence. Licensed pairs use “outcome because cause.”
10. When no causal pair is licensed, uses the two strongest significant measurements as an explicitly contextual “outcome while context” pair; if only one is significant, reports that observation alone. If reliable measurements exist but none is significant, reports measured similarity.
11. Uses unavailable cards only when the comparison itself or its measurements are absent/unreliable. Move count stays navigation context and never becomes a biomechanical cause.
12. Keeps reliable supporting measurements in Detailed Analytics, with the selected observation metric first, up to four unique metrics.
13. Retains the comparative observation/cause for fall, structure, validity, and unavailable explanations.

Direct range measurement matters when one climber uses one move and the other uses several. Their individual moves do not correspond, but their complete movement between two shared anchors does.

### Shared main-difference selection

The card pair answers one question: **what was most different in this sequence?** Selection order is:

1. fall or its attributed cause sequence;
2. non-comparable structure such as truncation, different hold order, or another divergence;
3. the strongest licensed causal finding whose two metrics both clear significance and confidence requirements, with a clear hip-supported finding preferred over a stronger non-hip finding;
4. the strongest two significant metrics as contextual evidence, joined with “while,” when no causal relationship is licensed;
5. a single significant observation when it is the only reliable difference;
6. measured similarity when reliable metrics exist but remain below significance;
7. unavailable cards only when comparison data is missing or below the reliability floor.

Both cards always use the same primary `MetricKind`, and a two-metric sentence uses the same secondary `MetricKind` on both sides. The higher and lower values receive complementary wording. The `relationship` field distinguishes a licensed **because** statement from honest **while** context, so Results never turns correlation into causation. This is relative wording, not an absolute technique classification.

Hip priority is intentionally conditional rather than absolute. A causal pair involving hip distance, hip rotation, or hip tilt receives first priority only when its weaker measurement reaches the configured **clear** magnitude (`deltaSignificanceThreshold × clearMagnitudeMultiple`). If the hip evidence is slight, low-confidence, unavailable, or has no licensed relationship, the selector uses the strongest valid non-hip pair instead. This keeps the coaching centered on the pelvis without turning tracking noise into advice.

### Insight measurement catalog

The sequence pipeline intentionally covers more than arms and feet. The current list is:

- hip distance from the wall: start-window, finish-window, mean, and peak;
- pelvis position: turn, tilt, and torso lean across the sequence plus start-window and finish-window values;
- center of mass: total path length, direct start-to-finish displacement, path directness (`displacement / path length`), and peak velocity;
- lower-body position: knee drive, feet set before reaching, foot commitment time, unweighted-foot time, and foot placements;
- reach and balance: reach margin, left/right load asymmetry, and diagonal load imbalance;
- upper-body use: mean/peak arm load, straight-arm ratio, active pulling time, back/shoulder levering time, and bent-loaded-arm time;
- timing: sequence dwell ratio.

Start and finish values use the first/last 10% of frames, capped at five frames, rather than one potentially noisy frame. Hip depth and COM endpoints retain their estimator confidence and coverage gates. Pelvis turn remains confidence-weighted because near-square projected hip width is unstable. These measurements are computed in Swift; prose never estimates them from the image.

### Causal direction contract

Every licensed pair is ordered as **observed outcome because measured cause**. Reversing these roles produces misleading sentences and is a bug. The current mappings are:

- finish hip distance because finish pelvis turn changed in the opposite direction;
- finish hip distance because knee drive changed in the opposite direction;
- reach distance because finish hip distance changed in the same direction;
- COM path directness because foot-placement count changed in the opposite direction;
- COM path length because foot-placement count changed in the same direction;
- start-to-finish COM progress because COM directness changed in the same direction;
- longer sequence time because COM path length increased or path directness decreased;
- less even loading because finish torso lean or finish pelvis tilt increased;
- finish pelvis turn because knee drive changed in the same direction;
- arm load because hips stayed farther from the wall;
- arm load because finish hip distance increased;
- arm load because the feet remained unweighted;
- arm load because the hand moved before the feet were set;
- longer sequence time because weight was committed to a foot later;
- longer centre-of-mass path because more foot placements were used;
- arm load because the climber reached from farther away;
- arm load because the arms stayed more bent; therefore write **kept more weight off the arms because they used straighter arms**, never **used straighter arms because they kept weight off the arms**;
- longer back/shoulder levering or bent loaded-arm time because average hip distance increased;
- longer back/shoulder levering or bent loaded-arm time because the hips stayed squarer to the wall;
- longer back/shoulder levering because more weight stayed on the arms;
- longer time holding bent, loaded arms because more weight stayed on the arms;
- longer active pulling because the hips stayed square to the wall;
- less even loading because the torso leaned farther off vertical;
- arm load because the pelvis stayed more tilted.

Start/finish posture pairs that do not match a licensed mechanism can still appear together with **while**, but never with **because**. This is important for hip placement and body position: the difference remains visible without manufacturing a biomechanical explanation.

`Finding.metrics` preserves this semantic order: index 0 is the observation/outcome and index 1 is the cause. `SequenceAnalysisComposer` must use `Finding.observationMetric` and `Finding.causeMetric` rather than inferring roles from normalized magnitude.

The current `kneeDrive` sequence metric stores only the larger absolute left/right magnitude. It does not preserve which knee produced it. Therefore Results must say **more/less knee drive** and must not claim **right leg** or **left leg** until Core carries side identity through the metric model.

## Core integration owned by Results

The Results UI is flat under `SendSociety/App/Results`, but its data contract intentionally crosses into `SendSociety/Core`. These Core changes are part of the Results feature and must be maintained together with this README.

### `Core/Analysis/SequenceAnalysisComposer.swift`

- Defines `SequenceDifferenceFinding` and `SequenceAnalysis`, the one-container-per-sequence model consumed by `ResultsView`.
- Stores paired reference and attempt analyses for one shared main difference. Each side carries an observation, optional secondary measurement, relationship (`because` or contextual `while`), supporting metrics, comparison validity, unavailable reason, and contributing move indices. Its sentence formatter combines these without visible substructure.
- Resolves fall and non-comparable states first, then ranks complete causal findings using the existing normalized significance scale. Move-count structure does not pre-empt a metric insight.
- Generates complementary wording from the same metrics for REF and YOU. A measured difference without a licensed cause becomes contextual/single-metric wording, not **Causal insight unavailable**.
- Composes one prioritized result from a direct whole-sequence delta when available.
- Uses move deltas only for fall attribution or deterministic fallback evidence.
- Keeps additive metrics such as COM path length, COM displacement, and foot-placement count as totals when direct sequence measurement is unavailable; other fallback metrics are confidence-weighted typical values.
- Limits supporting metrics to four and never presents move count as a coaching insight.

### `Core/Metrics/MetricsEngine.swift`

- Adds `sequenceMetrics(climbSequence:range:metrics:poseSequence:contacts:targetHold:config:)` so a complete anchor-to-anchor range can be measured independently of its internal move count.
- Refactors move and sequence measurement through the same private `rangeMetrics` implementation, preventing the two paths from drifting.
- Measures stable start/finish windows for hip distance, pelvis tilt, pelvis turn, and torso lean, plus direct COM displacement and COM path directness. It also separates loaded-arm effort into back/shoulder levering (`latLoadTime`), bent loaded-arm holding (`elbowFlexTime`), and the overlap where both occur (`pullingArmTime`). These metrics feed both Results insights and Detailed Analytics.
- Adds a sequence-specific `delta` overload. Its `SectionDelta` is indexed and named by the sequence and deliberately has no move-level `BetaDivergence`, because different intermediate moves do not invalidate two reliable shared endpoints.
- Existing move-level `sectionMetrics` and `delta(section:...)` behavior remains available for pipeline compatibility.

### `Core/Processing/ProcessingPipeline.swift`

- Extends `ProcessedSession` with `sequenceDeltas` and `sequenceAnalyses` alongside the existing move-level `deltas` and `analyses`.
- Adds `analysis(forSequence:)` and `delta(forSequence:)` lookup helpers used by Results and tests.
- Measures direct sequence spans only when both anchors are valid, distinct, reached, and mapped to a target hold.
- Uses each sequence's DTW mean cost when building the direct delta.
- Runs `SequenceAnalysisComposer` once for every `ClimbSequence`, including sequences without a valid direct comparison so each sequence still receives paired main-difference wording plus an honest unavailable, structural, fall, or attempt-only comparison state.
- Keeps move-level analyses for provider compatibility and instrumentation; `ResultsView` reads only sequence analyses.
- Reports both move and sequence counts in the Metrics and Analysis pipeline stages.

### Core verification

- `Tests/VideoOverlapCoreTests/SequenceAnalysisTests.swift` verifies cross-move composition, paired causal selection and direction, conditional hip-priority ranking, alignment between the selected sentence and its displayed evidence, hip-placement, COM, back/shoulder, and bent-loaded-arm causal rules, contextual body-position fallback, measured similarity, low-confidence unavailable findings, attempt-only divergence handling, shared-anchor comparability, and open-ended non-comparison.
- `Tests/VideoOverlapCoreTests/MetricsTests.swift` verifies that stable endpoint windows retain start/finish hip distance and posture plus COM displacement/directness.
- `Tests/VideoOverlapCoreTests/ProcessingTests.swift` verifies the pipeline produces exactly one `SequenceAnalysis` for every `ClimbSequence`.
- Any change to these Core contracts requires both the Swift package tests and the iOS build because Core output and Results presentation compile in separate targets.

### When reference comparison is valid

A sequence is comparable when both climbers have non-empty spans bounded by the same two shared hand-hold anchors. Different intermediate holds, skipped holds, different move counts, or a different internal order do not invalidate the whole-sequence comparison.

A sequence is non-comparable when reliable endpoints cannot be established, including:

- the open-ended tail after the final shared anchor;
- fewer than two shared hand holds in consistent order;
- a sequence the attempt did not reach;
- a missing or empty attempt range.

An internal move-level divergence does not by itself invalidate an anchor-bounded sequence.

## Identity color behavior

- REF is accent green in video badges, skeletons, difference-card badges, and Detailed Analytics.
- YOU is blue in the same surfaces.
- The complete available main-difference sentence is white; unavailable comparison text is muted. Cause text is not colored or styled separately inside the sentence.
- Accent green also marks the active skeleton button and move-count-different sequence buttons. Those are control/state meanings, not a third climber identity.
- Selection does **not** colour a sequence button. Selection is marked by position — the chosen chip scrolls to the centre of the strip — plus its existing height, width and weight. Green previously meant both "selected" and "move counts differ", which made an ordinary selected sequence indistinguishable from an unselected differing one. A strip short enough not to overflow cannot centre; size and weight carry it there.
- Fall remains red and takes priority over normal sequence-button background colors. The `F` glyph is gone — it collided with the number on the selected chip, and the fall is stated in full on the cards below. VoiceOver still announces it through the button's accessibility value.

## Why the attempt is "YOU" and not "Attempt"

The setup and capture screens name the two clips **Reference** and **Attempt**, per the domain glossary. Results deliberately does not follow: it says **YOU**.

Results is the app talking *to* the climber about *their own* climb, and its generated sentences are second person — "You fell during this sequence." `ResultsView` derives those subjects from the badge label itself, so renaming the badge to ATTEMPT without rewriting every finding into third person would put "ATTEMPT" above a card reading "You fell". The second person is the decision; the badge follows it.

## Detailed Analytics availability

`SequenceAnalysis.metrics` contains the four most divergent reliable sequence metrics — a presentation cap, not the limit of what is measured. `MetricKind` defines forty metrics and the pipeline computes all of them; the ranked remainder is carried in `SequenceAnalysis.additionalMetrics` and reached through the sheet's "Show all measurements" disclosure. `SequenceAnalysis.suppressedMetricCount` reports how many metric *kinds* were computed here but never cleared the confidence floor, so an absent metric is distinguishable from one that merely ranked low.

`SequenceAnalysis.metrics` contains reliable sequence metrics selected for comparative detail. Standalone metrics remain here even when they cannot produce a causal insight. When a causal metric drives the card pair, that observation metric is placed first. The array may be empty when:

- pose confidence is below the configured floor;
- the attempt never reached the sequence;
- the sequence is an open tail or lacks two reliable anchors;
- a fall or structural finding has no reliable supporting metric;
- neither comparison nor attempt-only measurement is reliable.

An empty metric list is valid. `numbersUnavailableReason` explains why. Detailed Analytics remains tappable whenever a `SequenceAnalysis` exists so that explanation is reachable.

## Insight priority and invariants

Priority:

1. Fall attributable to this sequence.
2. When direct comparison is unavailable: divergence, truncation, or not reached.
3. Strongest licensed causal finding.
4. Strongest contextual or standalone significant difference.
5. Measured similarity.
6. Unavailable only when comparison data is missing or unreliable.

Invariants:

- Produce exactly one `SequenceAnalysis` container and one paired main difference per sequence.
- Both metric-derived cards must refer to the same primary `MetricKind` and, when present, the same secondary `MetricKind`.
- For a `because` relationship, the observation metric must be the outcome and the cause metric must explain it. Never reverse them for ranking or wording.
- Observation and cause must render as one sentence per card with no subtitles or divider.
- Never label contextual evidence as causal. Use `whileContext`, and reserve unavailable state for missing/unreliable data.
- Never use move count as the insight; its difference is already communicated by the sequence-button state.
- Never force a difference below `deltaSignificanceThreshold`.
- Never infer a left/right limb label from the current side-agnostic knee-drive metric.
- Never claim reference comparison when `comparisonIsValid` is false.
- Do not invalidate an anchor-bounded sequence solely because an internal move diverges.
- Never invent a biomechanical cause from move count alone.
- Never hide why numbers are unavailable.
- Keep analytics in the core pipeline and formatting in the app layer.

## Important source files

All paths are relative to the repository root and all Results UI files are flat under `SendSociety/App/Results`:

- `ResultsView.swift`: production root, display modes, sequence selection, and synchronized playback.
- `ResultNumbersSheet.swift`: metrics and unavailable explanations.
- `MetricPresentation.swift`: metric labels, formatting, and domains.
- `ResultPosition.swift`: defines `MovePosition` as the selected sequence index plus normalized playback offset. Deleting it breaks `ResultsView`; it is presentation/playback state, not obsolete per-move analytics.
- `FrameImageCache.swift`: coarse/exact still-frame decoding and caching.
- `SkeletonCanvas.swift`: skeleton, wall plate, posture overlays, and aspect-fit mapping.
- `ComparisonVideoPane.swift`: aspect-fit video cards and visual tokens.
- `SendSociety/Assets.xcassets/ResultsSkeleton.imageset`: the designer-supplied template SVG used by the skeleton control.
- `SendSociety/Core/Analysis/SequenceAnalysisComposer.swift`: sequence analysis model and composition rules.
- `SendSociety/Core/Metrics/MetricsEngine.swift`: whole-sequence measurement and sequence-delta construction.
- `SendSociety/Core/Processing/ProcessingPipeline.swift`: constructs move and sequence outputs.
- `Tests/VideoOverlapCoreTests/SequenceAnalysisTests.swift`: sequence aggregation and integrity tests.
- `Tests/VideoOverlapCoreTests/ProcessingTests.swift`: pipeline result-count integration test.

## Verification expectations

When changing Results:

1. Run Swift package tests, especially `SequenceAnalysisTests`.
2. Build the iOS app with code signing disabled.
3. Inspect paired REF/YOU sentences for correct outcome-before-cause direction and natural grammar, no internal subtitles/divider, hip/COM/body-position variety, contextual `while` fallback, measured similarity, low-confidence unavailable cards, move count staying out of the insight, valid comparison, attempt-only metrics, not reached, fall, and multi-sequence navigation.
4. Confirm both panes remain synchronized during sequence changes, scrubbing, and playback.
