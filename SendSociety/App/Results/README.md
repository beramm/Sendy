# Results architecture and product decisions

This is the implementation and product decision record for the Results feature. It is written for people and AI coding agents. Read it before changing result navigation, playback synchronization, sequence analytics, insight wording, metric availability, or presentation.

## Maintenance contract

This is living documentation. **Every change that alters Results behavior, architecture, analytics, or presentation must update this file in the same code change.** A Results change is incomplete when implementation and documentation disagree.

Update the relevant sections when changing:

- what a sequence means or how numbered navigation works;
- Side by Side, Overlay, skeleton, playback, scrubbing, or synchronization;
- sequence-analysis inputs, aggregation, priority, output, fall, or divergence handling;
- observation/cause wording or color meaning;
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
3. Present exactly one primary finding for that whole sequence.
4. Express the finding as an observation plus a cause when measurements support a cause.
5. Keep supporting measurements available without making them the main story.

## Approved sequence-detail presentation

`Sequence Detail.png` is the current visual reference.

- The close button sits alone at the top trailing edge. Display controls occupy a row below it.
- Side by Side and Overlay use a two-option control. The selected segment is white with black text; the unselected segment uses muted text on the shared dark surface.
- The skeleton and overflow buttons use the same dark surface and `18pt` continuous radius. The active skeleton button is white with a black icon.
- Side-by-side video panes use the source aspect ratio and a `16pt` continuous radius. REF and YOU are white capsule badges inside the footage.
- Overlay preserves the processed wall-plate image, route marks, and both synchronized skeletons. It has exactly the same width and height as one Side by Side pane and is centered in the row. Wall and skeleton geometry remain aspect-fit and at the same scale as one video pane. The diagnostic gray fallback is disabled; a missing wall plate exposes the near-black Results surface.
- Sequence buttons use a `15pt` radius. A reference/attempt move-count difference uses the bright accent with dark text. Selection uses the same accent plus bold numbering and a larger scale. A fall takes priority: red background, white text, and a small `F`; bold type and scale still communicate selection.
- Playback uses a plain white play/pause symbol beside the scrubber. Playback and scrubbing are always synchronized.
- The insight and Detailed Analytics surfaces use an opaque near-black fill and `30pt` continuous radius.
- Observation and cause are separate sentences: observation is white; a supported cause is accent green.
- The analytics entry point is always titled **Detailed Analytics** with a trailing chevron. Its sheet owns both metric rows and explanations for unavailable numbers.

These are fixed visual tokens. Avoid adding `.glassEffect` to these Results surfaces because it changes their color and apparent radius across backgrounds.

## Clarification record: original ten questions

The wording below is condensed from the design conversation while preserving the user's answers and resulting behavior.

### 1. What do the numbered buttons represent?

**User answer:** The numbered buttons represent the sequence.

**Decision:** The selected number indexes `ProcessedSession.sequences.sequences`, not an individual move. The strip centers when all sequences fit and scrolls when they do not.

Marker states:

- fall in sequence: red with `F`;
- different reference/attempt move counts: bright accent;
- selected: bright accent, bold number, and larger scale;
- fall overrides the background color when states overlap;
- ordinary unselected sequence: neutral dark surface.

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

**Decision:** Show one prioritized insight, not a metric dump or a list of every move finding.

### 4. What is the insight structure?

**User answer:** Just observation and cause.

**Decision:** Use `SequenceAnalysis.observation` plus optional `SequenceAnalysis.cause`. Drills, warnings, and multiple per-move observations stay out of the main card.

### 5. Which text receives the green accent?

**User answer:** The cause.

**Decision:** Observation is white. Green is reserved for a measured cause. When `cause` is absent, all text is intentionally white. Do not invent a cause merely to guarantee green text.

### 6. How should supporting detail be presented?

**User answer:** Use the recommended approach.

**Accepted recommendation:** Keep the main card concise and put only measurements supporting the selected sequence finding in Detailed Analytics.

### 7. Were the original analytics per move, and how did the old implementation work?

**User answer:** Asked how the implementation worked because the user did not write it.

**Answer:** The deleted diagnostic screen navigated by sequence but displayed every per-move `SectionAnalysis` whose reference move belonged to that sequence. That was sequence-shaped navigation, not sequence-level coaching.

**Current decision:** The pipeline creates one `SequenceAnalysis` for every `ClimbSequence`, and `ResultsView` presents that item directly. It must not select, merge, or generate coaching prose from per-move analyses. The pipeline still produces `[SectionAnalysis]` for provider compatibility and instrumentation, but Results does not display it.

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
5. Runs deterministic finding rules against the sequence delta.
6. Selects one primary finding and at most four supporting metrics.
7. Returns one observation with an optional defensible cause.

Direct range measurement matters when one climber uses one move and the other uses several. Their individual moves do not correspond, but their complete movement between two shared anchors does.

## Core integration owned by Results

The Results UI is flat under `SendSociety/App/Results`, but its data contract intentionally crosses into `SendSociety/Core`. These Core changes are part of the Results feature and must be maintained together with this README.

### `Core/Analysis/SequenceAnalysisComposer.swift`

- Defines `SequenceAnalysis`, the one-result-per-sequence model consumed by `ResultsView`.
- Stores the observation, optional cause, supporting metrics, comparison validity, unavailable reason, and contributing move indices.
- Composes one prioritized result from a direct whole-sequence delta when available.
- Uses move deltas only for fall attribution or deterministic fallback evidence.
- Keeps additive metrics such as COM path length and foot-placement count as totals; other metrics are confidence-weighted typical values.
- Limits supporting metrics to four and never invents a cause for a move-count difference.

### `Core/Metrics/MetricsEngine.swift`

- Adds `sequenceMetrics(climbSequence:range:metrics:poseSequence:contacts:targetHold:config:)` so a complete anchor-to-anchor range can be measured independently of its internal move count.
- Refactors move and sequence measurement through the same private `rangeMetrics` implementation, preventing the two paths from drifting.
- Adds a sequence-specific `delta` overload. Its `SectionDelta` is indexed and named by the sequence and deliberately has no move-level `BetaDivergence`, because different intermediate moves do not invalidate two reliable shared endpoints.
- Existing move-level `sectionMetrics` and `delta(section:...)` behavior remains available for pipeline compatibility.

### `Core/Processing/ProcessingPipeline.swift`

- Extends `ProcessedSession` with `sequenceDeltas` and `sequenceAnalyses` alongside the existing move-level `deltas` and `analyses`.
- Adds `analysis(forSequence:)` and `delta(forSequence:)` lookup helpers used by Results and tests.
- Measures direct sequence spans only when both anchors are valid, distinct, reached, and mapped to a target hold.
- Uses each sequence's DTW mean cost when building the direct delta.
- Runs `SequenceAnalysisComposer` once for every `ClimbSequence`, including sequences without a valid direct comparison so each sequence still receives an honest unavailable, structural, fall, or attempt-only result.
- Keeps move-level analyses for provider compatibility and instrumentation; `ResultsView` reads only sequence analyses.
- Reports both move and sequence counts in the Metrics and Analysis pipeline stages.

### Core verification

- `Tests/VideoOverlapCoreTests/SequenceAnalysisTests.swift` verifies cross-move composition, move-count structural findings, attempt-only divergence handling, shared-anchor comparability, and open-ended non-comparison.
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

## Insight color behavior

Green means **cause**, not generic emphasis.

- Observation plus supported cause: white observation, green cause.
- Structural observation without supported cause: all white.
- Similar, divergent, unavailable, and fall results may contain green only when their data includes a cause or explanation in the cause field.

If the product later requires emphasis in every insight, extend the model to distinguish cause, evidence, and generic emphasis. Do not silently color arbitrary observation words green.

## Detailed Analytics availability

`SequenceAnalysis.metrics` contains only reliable metrics relevant to the selected finding. It may be empty when:

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
3. Coaching finding supported by direct sequence metrics.
4. Structural move-count difference.
5. Similar-to-reference result with reliable metrics.
6. Unavailable result.

Invariants:

- Produce exactly one main result per sequence.
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
- `SendSociety/Core/Analysis/SequenceAnalysisComposer.swift`: sequence analysis model and composition rules.
- `SendSociety/Core/Metrics/MetricsEngine.swift`: whole-sequence measurement and sequence-delta construction.
- `SendSociety/Core/Processing/ProcessingPipeline.swift`: constructs move and sequence outputs.
- `Tests/VideoOverlapCoreTests/SequenceAnalysisTests.swift`: sequence aggregation and integrity tests.
- `Tests/VideoOverlapCoreTests/ProcessingTests.swift`: pipeline result-count integration test.

## Verification expectations

When changing Results:

1. Run Swift package tests, especially `SequenceAnalysisTests`.
2. Build the iOS app with code signing disabled.
3. Inspect supported cause, observation without cause, valid comparison, attempt-only metrics, unavailable numbers, not reached, fall, move-count difference, and multi-sequence navigation.
4. Confirm both panes remain synchronized during sequence changes, scrubbing, and playback.
