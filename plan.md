# Video Overlap — Technical Plan

---

## 1. The problem, stated precisely

Given two videos of two different people climbing the same route from
approximately the same camera position, produce:

1. A visual overlay where the two climbers' bodies are spatially and temporally
   aligned.
2. A segmentation of each climb into hold-to-hold **moves**, grouped into
   **sequences** bounded by holds both climbers used (§3.5).
3. Per-sequence quantitative differences in body position and load.
4. Per-sequence natural-language coaching derived from (3).

Everything on-device, no network.

---

## 2. Why this is tractable

Three problems that look hard have cheap solutions here:

**"How do we find the holds?"** We don't. The reference climber's hands and
feet touch every hold on the route, in order. Cluster the contact points and
the route falls out of the data. This removes the entire segmentation
dependency from the PoC.

**"How do we sync two climbers at different speeds?"** Dynamic Time Warping
over the pose feature sequence, with hold-contact events as hard anchors. This
is strictly better than a manual speed slider, which can only apply one linear
rate to a non-linear difference.

**"How do we get depth from a straight-on camera?"** Limb foreshortening. A
segment pointing toward the camera projects shorter by `cos θ`. Anchored at
contact points where z ≈ 0, this recovers a usable hip-distance-from-wall
signal from a single 2D camera.

**"How do we compare two climbers who don't do the same moves?"** We stop
pretending they do. The two climbers touch a *subset* of the same holds with
their hands, and those shared holds are the only points where the two climbs
provably line up. Group between them. What happens inside a group is allowed to
differ in move count, in feet, and in hand order — and that difference is the
finding, not an obstacle to producing one. See §3.5.

---

## 3. Stage-by-stage design

### 3.1 Pose extraction

`VNDetectHumanBodyPoseRequest` over decoded frames via `AVAssetReader`. Target
30fps; downsample if the source is 60. Output:

```swift
struct PoseFrame: Sendable {
    let index: Int
    let time: CMTime
    let joints: [JointName: Joint]   // Joint = (point: CGPoint, confidence: Float)
}
```

Reject frames where torso joints (shoulders, hips) fall below confidence 0.3 —
these are almost always tracking failures, and interpolating across them is
better than propagating garbage.

**Smoothing:** 1€ filter per joint, tuned for low lag on fast movement. Vision
output is jittery enough that raw velocity is unusable for contact detection.

### 3.2 Wall alignment (homography)

`VNHomographicImageRegistrationRequest` between a reference frame from each
video. Climbing walls are ideal for this — holds are high-contrast, textured,
non-repeating features.

Pick registration frames from moments when the climber occupies the least
image area (usually first or last frame, climber at the bottom or off frame).
Optionally mask out the climber's bounding box using the pose data before
registration.

Output: `matrix_float3x3` mapping each video into a shared wall space,
normalized to `[0,1]`. **Every downstream coordinate is wall space.**

Validation: reproject a grid of matched features and check residual error. If
mean residual exceeds a threshold, the two videos aren't comparable — tell the
user to re-record rather than producing garbage analysis.

### 3.3 Contact detection

For each of the four extremity joints (wrists, ankles):

```
velocity[i] = |p[i] − p[i−1]| / Δt          (wall space, normalized units)
contact if velocity < v_thresh for ≥ N consecutive frames
```

Start with `v_thresh` ≈ 0.01 wall-widths/sec and `N` = 8 frames (~0.27s at
30fps). These need tuning against real footage — treat them as configuration,
not constants.

Emit:

```swift
struct Contact: Sendable {
    let joint: JointName
    let startFrame: Int
    let endFrame: Int
    let position: CGPoint      // wall space, median over the dwell
}
```

A hand adjusting on a hold (matching, re-gripping) produces two contacts at
nearly the same position. Merge contacts of the same joint within a small
spatial and temporal radius.

### 3.4 Route derivation

Cluster all reference-climb contacts spatially (DBSCAN, ε ≈ 0.03 wall-widths).
Each cluster is a hold. Order by earliest contact time.

```swift
struct Hold: Sendable {
    let id: Int
    let position: CGPoint
    let firstUsedBy: JointName    // hand or foot — informs move boundaries
    let ordinal: Int
}
```

Sanity checks: a route with more than ~25 holds or fewer than 3 almost
certainly indicates contact-detection failure. Surface this rather than
proceeding.

**Matching the attempt:** for each attempt contact, nearest-neighbour to a
route hold within a radius. Contacts with no match are *off-route holds* —
worth surfacing to the user, since using a hold the reference climber didn't
is itself a meaningful difference.

### 3.5 Segmentation — three levels

A single level was wrong. The original `Section` was defined from the
*reference's* hand acquisitions and the attempt's frame range was stapled onto
it, which silently assumes both climbers made the same moves in the same order.
They don't, and that assumption is what Phase 0 Q2 was worried about. Three
levels replace it.

**Move** — the span from one **hand** hold acquisition to the next, *for one
climber*. Feet move within a move; hands define it. This is what the old
`Section` was, minus the cross-climber assumption. **The unit of measurement.**

**Beta** — one climber's whole ordered list of moves through the route. The
reference has a beta; each attempt has its own. A beta belongs to one climber
and is computed without any knowledge of the other.

**Sequence** — the span between two successive **anchor** holds. An anchor is a
route hold that a **hand of the reference and a hand of the attempt** both
contacted. Either hand counts; it need not be the same hand on both sides. Feet
never create anchors. **The unit of comparison.**

A sequence contains at least one move from each climber, and the counts are
free to differ. That is the point:

> Three holds `a`, `b`, `c` and footholds `a0`, `b0`, `c0`. Both climbers start
> hands on `a`, feet on `a0`. The reference reaches `a → c` directly, feet
> still: **one move**. The attempt cannot span it, so it steps `a0 → b0`,
> matches left hand to `b`, then right hand to `c`: **three moves**. Both
> climbers touched `a` and `c` with a hand, so both are anchors, and the whole
> thing is **one sequence** — reference 1 move, attempt 3.

"You took three moves where they took one" is then a measured structural fact
rather than a metric comparison that has to be suppressed.

```swift
struct Move: Sendable {              // was Section
    let index: Int                   // within its own climber's beta
    let fromHold: Hold
    let toHold: Hold
    let frameRange: Range<Int>       // one climber only
}

struct Beta: Sendable {
    let role: ClimbRole              // .reference | .attempt(UUID)
    let moves: [Move]
}

struct ClimbSequence: Sendable {     // NOT `Sequence` — collides with Swift's own
    let index: Int
    let fromAnchor: Hold
    let toAnchor: Hold
    let referenceMoves: Range<Int>   // indices into the reference beta
    let attemptMoves: Range<Int>     // indices into the attempt beta
    let moveCountDelta: Int          // attempt − reference; a finding in itself
}
```

**Naming warning.** `Sequence` is a Swift standard-library protocol and
`PoseSequence` already exists. Naming this type `Sequence` will not compile
cleanly and will produce confusing diagnostics — the same trap as
`Observation` in task 6.4. `ClimbSequence`.

**Anchor ordering.** An attempt can touch shared holds out of the reference's
order — a downclimb, a reversal, a hold used twice. Anchors are therefore the
**longest increasing subsequence** of shared hand holds in reference order.
Shared holds that don't fit that ordering stay *inside* a sequence as ordinary
moves rather than creating a boundary that would go backwards.

**Truncation.** An anchor requires a contact from both climbers, so once the
attempt falls there are no further anchors by construction. Sequences end
there. The remaining reference moves are reported as unreached reference-only
territory, not as empty sequences: "sequence 3 of 3 reached, 5 more in the
reference."

**Degenerate case.** If no anchor exists past the start — the two climbers
share no hand holds at all — emit one sequence spanning the whole climb with a
warning, and report structure only. Fail soft, never blank.

### 3.6 Time alignment

Within each sequence, DTW over a per-frame feature vector:

```
[ normalized joint positions (16 values, scale-normalized by torso length),
  COM position (2),
  contact state bitmask (4) ]
```

**Sequence** boundaries are hard anchors — DTW runs *within* a sequence, not
across the whole climb, and **not** within a move. This prevents a single
badly-tracked move from corrupting alignment everywhere else.

Anchoring at moves, which is what the first build did, is wrong for the reason
in §3.5: it pins attempt move *n* to reference move *n* when the two may not
describe the same span of wall. In the `a → c` example it would pin the
attempt's `a → b` to the reference's `a → c` and warp time to make them match.
Sequence boundaries are the only frames where both climbers are provably in the
same place, so they are the only defensible anchors — and inside a sequence DTW
is free to map three moves onto one, which is exactly what it is for.

Output: a warping path mapping attempt frames to reference frames, used for
both the overlay and for frame-level metric comparison.

### 3.7 Metrics

**Centre of mass.** Weighted sum of segment centroids using Dempster's body
segment parameters (trunk 0.497, head 0.081, thigh 0.100, shank 0.0465,
foot 0.0145, upper arm 0.028, forearm 0.016, hand 0.006 — each limb value
applied per side). Fully determined by the 19 joints.

**Depth (z) via foreshortening.** Per segment:

```
L_true   = 95th percentile of observed segment length over the whole climb
ratio    = clamp(L_observed / L_true, 0, 1)
z_local  = L_true · √(1 − ratio²)
conf     = 1 − ratio          // low when limb is near wall-parallel
```

Chain from a contact anchor (z = 0) outward: ankle → knee → hip. Where both
legs are in contact, average the two hip estimates weighted by confidence.
Temporally smooth. Emit `nil` below a confidence floor rather than a bad
number.

Scale: convert wall-space units to metres using the climber's estimated height
(torso-length calibration), or leave as body-lengths — arguably a *better* unit
for comparing two differently-sized climbers.

**Load distribution.** Inverse Distance Weighting from COM to each contact
point, as in the reference project. Frame it in the UI as *relative* load, not
measured force — it's a heuristic, not physics.

**Units — no climber profile.** There is no height or weight input. Everything
computes and reports in **body-lengths** (normalized by torso length), which is
what makes two differently-sized climbers comparable in the first place.

Why weight is absent: IDW produces load **fractions**, determined entirely by
geometry. Mass only converts % into kg — it adds no accuracy. Worse, absolute
kg actively corrupts cross-climber comparison, since a heavier climber shows
higher arm load on every move with identical technique. That's noise, not
signal.

Why height is absent: it was only ever a display conversion, turning
"0.18 body-lengths" into "14cm". Pure render-time multiply, additive later,
buys nothing for the PoC.

If a kilogram or centimetre value ever reaches `MetricsEngine` or
`SequenceDelta`, that's a bug.

**Measure per move, compare per sequence.**

Metrics are computed over a **move**, for one climber, exactly as before — a
metric is a per-frame quantity aggregated over a span, and the move is the
smallest span that means anything. This is what makes "you replaced that foot
three times on the second move" expressible.

Deltas are computed over a **sequence**, by aggregating each climber's moves
within it. A delta needs two spans that denote the same thing, and moves do
not: in the `a → c` example the attempt's first move is `a → b` while the
reference's is `a → c`. Pairing them by index compares unrelated spans, which
is the failure the sequence layer exists to remove.

Aggregation rule per metric family, so this isn't decided ad hoc:

| family | across moves in a sequence |
|---|---|
| path lengths, times, counts (COM path, dwell, foot placements) | sum |
| shares and ratios (arm load, straight-arm, unweighted foot time) | time-weighted mean |
| peaks (COM peak velocity, arm load peak, hip depth peak) | max |
| at-latch quantities (reach margin) | value at the sequence's closing anchor |

Move-level findings that need **no partner** — arm load, foot commitment
latency, hesitation — still report against their own move inside the sequence.
Only *comparisons* move up a level.

**Derived per-move metrics:**

| Metric | Definition | Coaching value |
|---|---|---|
| Hip distance from wall | z at hip, mean and peak | The classic beginner tell |
| Straight-arm ratio | fraction of the move with elbow > 150° | Energy efficiency |
| COM path length | arc length of COM in wall space | Wasted movement |
| COM peak velocity | max ‖dCOM/dt‖ | Static vs dynamic style |
| Load asymmetry | L/R imbalance in IDW load | Over-pulling one side |
| Foot placement count | foot contacts within the move | Fidgeting vs commitment |
| **Move count** | moves the climber used to cross the sequence | The `a → c` case: three moves against one |
| Hip twist | shoulder-line vs hip-line angle | Flagging, backstepping |
| Reach margin | COM-to-target-hold distance at latch | Efficient body position |

### 3.8 Fall detection and cause attribution

**Detection.** A fall is: all four extremity contacts released within a short
window, COM vertical acceleration approaching g, sustained for ≥ 0.3s, with no
re-contact. The re-contact clause is what distinguishes a fall from a dyno — a
dyno releases all limbs but the COM travels up or laterally first and the
movement resolves in contact.

Emit the fall frame, the fall **move**, its enclosing **sequence**, and a
confidence.

**Attribution.** Do not analyze the fall frame. Walk backward and find where
divergence from the reference climb began. Two windows:

- *Proximate* — the 1–3s preceding the release.
- *Distal* — earlier **sequences** where accumulated cost originated.

Attribution reports the sequence, because that is the unit the reference
climber can be compared against. Naming the move within it is fine and useful —
"it started in sequence 2, on your second foot swap" — but the *claim* about
the reference climber's behaviour has to be made at sequence level.

Signals, split by epistemic status. This split must survive into the UI copy.

**Mechanical (demonstrable — state as fact):**

| Signal | Definition |
|---|---|
| COM outside base of support | COM projection exits the polygon of loaded contacts and isn't recovered. The strongest signal available. |
| Barn-door rotation | COM exits BOS on the lateral axis with a rotational component |
| Foot cut / slip | Ankle contact ends with downward velocity spike while hands remain loaded, with no preceding unweighting. Unweighting is what separates a slip from an intentional foot move. |
| Hip peel | Hip z rising monotonically before release — load transferring to arms |

**Fatigue proxies (correlational — state as hypothesis):**

| Signal | Definition |
|---|---|
| Bent-arm accumulation | Straight-arm ratio declining across sequences |
| Sequence dwell ratio | Attempt time in sequence ÷ reference time in sequence |
| Load asymmetry trend | L/R IDW imbalance increasing over the climb |
| Reach margin decay | Latching holds at progressively higher extension |

**Output.** A `FallReport` naming the mechanical cause at the fall, plus the
earliest sequence where a contributing signal crossed threshold, plus the
reference climber's behaviour in that same sequence. The target output shape is
"you came off in sequence 5, but it started in sequence 2" —
cross-sequence attribution is the differentiating feature.

**Do not claim** to distinguish pumped from scared from misread beta. Pose data
does not contain that. The `AnalysisProvider` prompt must forbid speculation
about the climber's mental state.

**Data model consequences.**

- A fallen attempt is truncated. An anchor needs a contact from both climbers,
  so a fall ends the anchor list by construction: report the sequences reached
  and name the remaining reference moves as unreached, never as empty
  sequences.
- Sequences are a property of a **(reference, attempt) pair**, not of the
  route. A second attempt gets its own anchor set and its own partition, and
  the sequence count can legitimately differ between two attempts on the same
  route. Only `Route` and the reference's own `Beta` are shared across attempts.
- Multiple attempts against one reference is the natural usage pattern — fall,
  adjust, retry. `Attempt` is a collection, not a singleton.
- A reference climb that contains a fall is not a valid reference. Reject it.

### 3.9 Analysis text

```swift
protocol AnalysisProvider {
    func analyze(_ delta: SequenceDelta) async throws -> SequenceAnalysis
}
```

`SequenceDelta` is the old `SectionDelta` computed one level up (§3.7): the
reference's aggregate against the attempt's aggregate over the same sequence,
plus `moveCountDelta` and the list of holds each climber used to get across.
The rule that the model never authors a number is unchanged — it now narrates
a sequence's numbers rather than a move's.

Implementations:

1. `TemplateAnalysisProvider` — rule-based, ranks metric deltas by magnitude
   against thresholds, emits templated text. **Build this first.** It's the
   floor, works on every device, and is the baseline the model must beat.
2. `FoundationModelsProvider` — Apple on-device model with `@Generable` guided
   generation. Input is the `SequenceDelta` struct, never an image, never raw
   pose. Output is a typed struct: headline, one or two observations, one
   suggested drill.
3. `RemoteAnalysisProvider` — stub. Requires a backend. Escalate before
   implementing.

Selection at runtime: Foundation Models if `SystemLanguageModel.default`
is available, template otherwise.

### 3.10 Comparison views

Three view modes, all driven by the **same** `TimeAligner` output and the same
wall-space homography. Only compositing differs, so mode two and three are
cheap once mode one exists.

```swift
enum ComparisonMode { case overlay, sideBySide, skeletonOnly }
```

**Overlay.** Reference video warped into the attempt's frame via the inverse
homography, composited at ~40% alpha, temporally resampled along the DTW path.
Both skeletons drawn over it with a per-joint divergence tint. *Known weakness:*
two differently-sized bodies, even when correctly aligned, read as visual
clutter — the wall lines up and the humans don't. Don't assume this is the
best default.

**Side by side.** Two players, DTW-locked so both show the same *sequence*
rather than the same *timestamp*. Each pane warped to its own wall space so the
route appears at the same scale and position in both. Often clearer than
overlay for reading technique differences.

*Sync is locked by default with a single unlock toggle.* The escape hatch
exists because DTW will sometimes misalign a sequence, and locked mode makes
that failure impossible to inspect — for users and for you.

*There is no shared timeline.* Once playback is sequence-locked, the two clips
have no common clock: one climber may take 4s through a sequence and the other
11s — and may take three moves over it where the other took one.

**The scrubber is indexed by sequence, not by time and not by move** —
"sequence 4 of 9", with continuous position within the sequence. Move is not a
valid scrubber index for the same reason it is not a valid DTW anchor: the two
climbers have different move counts inside a sequence, so "move 6" does not
name one position in a locked pair.

Moves are drawn as **subdivisions inside the current sequence**, per pane, and
they can legitimately look different — one tick in the reference pane, three in
the attempt pane. That asymmetry is a feature of the display: it is the `a → c`
finding, visible without reading any text. Tapping a move tick scrubs that pane
to it, which unlocks only if the panes disagree about where that lands.

Sequence markers and the fall marker fall out of this naturally. Unlocking
means detaching a pane to scrub on its own clock.

**Skeleton only.** Both skeletons on a plain wall diagram with derived hold
positions, no video. Three things only this mode can do:

- **Scale normalization.** You can't rescale a video without distorting it; you
  can rescale a skeleton. This is the only view where both climbers can be
  drawn at identical body-length scale, making the comparison about shape
  rather than size.
- **Analytical overlays.** COM marker, base-of-support polygon, per-limb load
  colouring, divergence vectors. These are illegible over real footage and
  obvious on a stick figure. **The fall analysis is only properly viewable
  here** — the story is "COM exits the BOS polygon and doesn't return", which
  cannot be rendered over video.
- **Auditability.** The user can see the measurement behind each claim, which
  matters for trusting an app that tells them they're doing it wrong.

Renders with no video decode, so scrubbing is instant. Cheap to build because
Phase 0.3 produces skeleton rendering anyway.

**Default is side-by-side.** Skeleton-only is the drill-down reached by tapping
an analysis finding — the "show me why you said that" view, not the browsing
view. It is clinical and unshareable; don't make it the first thing a user
sees.

All three share: sequence-indexed scrubber with per-pane move ticks,
tap-to-jump, the current sequence's analysis text, and the fall marker when
present. Mode is a view-layer concern only — switching modes must not re-run
any pipeline stage.

Core Image for compositing, `Canvas` for skeletons. Metal only if profiling
demands it.

---

## 4. Phasing

**Build straight through to a working app.** The gates below are checkpoints to
report at, not stops. First-run behaviour on real footage will be wrong in
places — that's expected, and section 4.1 is how it gets fixed on site rather
than in a later sprint.

### 4.1 Runtime tuning — the thing that makes a gym trip productive

Every threshold in this pipeline is a guess until real climbing footage
contradicts it. So none of them are constants.

```swift
struct TuningConfig: Sendable, Codable {
    var contactVelocityThreshold: Double
    var contactDwellFrames: Int
    var contactMergeRadius: Double
    var holdClusterEpsilon: Double
    var jointConfidenceFloor: Double
    var depthConfidenceFloor: Double
    var smoothingBeta: Double
    var straightArmDegrees: Double
    var fallAccelThreshold: Double
    var fallSustainSeconds: Double
}
```

Requirements:

- Exposed as a debug panel of sliders and steppers, reachable from the results
  screen. Ugly is fine.
- **Re-processing a saved session must not re-run pose extraction.** Pose is
  cached per video; changing a threshold re-runs only from `ContactDetector`
  onward. This is the difference between a 2-second and a 90-second feedback
  loop, and it decides whether on-site tuning is actually usable.
- Configs are savable and nameable, so a promising set survives the session.
- Every value shown with its current number, not just a slider position.

The on-site loop is: record → process → looks wrong → adjust → reprocess →
look again. You leave the gym with tuned values instead of a bug list.

### Phase 0 — Concept spike (highest priority)

The gym trip tests whether **the concept works**, not whether Vision works.
Pose model choice is a swappable implementation detail; run Vision and RTMPose
against the same clips **on desktop** and pick the winner. Only convert the
winner to Core ML.

Three questions, in order of how badly a "no" hurts:

**Q1 — Is contact detection clean enough?** Everything rests on
"limb at rest on a hold" being separable from "limb moving." Real climbing is
messier than that: shake-outs, re-grips, hand matches, smears on volumes with
no discrete contact point. If contact detection is mushy, route derivation,
move segmentation and DTW anchoring all fail together. **This is the
critical path.**

**Q2 — Do the two climbers' moves correspond?** *Largely dissolved by the
sequence layer (§3.5), and restated.*

The original worry: a stronger climber doesn't do the same moves better, they
do *different moves* — heel hook instead of a toe, a skipped foothold, a
different hand order — so "your difference on move 4" compares moves that
aren't the same move. That was true, and it was true because move-level
correspondence was assumed rather than established.

Sequences remove the assumption. Comparison happens only between holds both
climbers actually touched with a hand, so the spans being compared correspond
by construction, and a differing move count inside a sequence becomes the
headline finding instead of a source of bogus deltas.

What survives as a real question, and still needs two real climbers:

- **Do enough shared anchors exist?** If a strong climber and a weak one share
  only two hand holds on a nine-hold route, the climb is two sequences and the
  analysis is coarse. This is measurable the moment a real pair exists:
  *anchors ÷ reference hand holds* is the number to report.
- **Is a coarse sequence still useful?** "You took five moves across this span
  where they took two" may be the most useful thing the app can say, or too
  blunt to act on. A climber has to answer that.

**Q3 — Are the differences large enough to measure?** Is hip-from-wall between
the two climbers 15cm or 3cm? If the signal sits inside the tracking noise, the
analysis has nothing to report regardless of model quality.

**Gate:** all three answered yes, or a clear scoping change identified. Pose
quality is a sub-question of Q1, not a gate in its own right.

**Cheapest test first:** before any pipeline work, watch the two clips side by
side in a video editor and try to articulate the differences yourself. If a
human can't, the app can't. This tests Q2 and Q3 for free.

### Phase 1 — Contacts and route
Contact detection, clustering, route derivation, move segmentation.
**Gate:** derived route matches the actual route, verified by eye, on ≥ 4 of 5
test clips.

### Phase 2 — Alignment
Homography, DTW, overlay rendering.
**Gate:** the overlay visually lines up, and stays lined up through a full
climb.

### Phase 3 — Metrics
COM, foreshortening depth, load, all derived metrics.
**Gate:** hip-distance estimate correlates with visual judgment on clips
deliberately filmed with hips in vs. hips out.

### Phase 4 — Analysis
Template provider, then Foundation Models provider.
**Gate:** a climber reads the output and agrees it's correct and useful.

### Phase 5 — App
Capture flow, sequence scrubber, results UI.

### Phase 9 — Beta / sequence / move grouping
The three-level model in §3.5. Move segmentation per climber, anchor derivation
across the pair, DTW and comparison re-anchored at sequence boundaries.
**Gate:** on a real pair, anchors ÷ reference hand holds is high enough that
sequences are finer than "the whole climb", and a climber agrees the sequence
boundaries are where they'd say one part of the route ends and the next begins.

---

## 5. Risk register

| Risk | Severity | Mitigation |
|---|---|---|
| Contact detection too mushy to derive a route — shake-outs, re-grips, matches, smears | **Critical** | Phase 0 Q1; tunable thresholds; manual hold-correction UI as fallback. If unfixable, the whole hold-derived design collapses. |
| Two climbers use different beta, so moves don't correspond | ~~Critical~~ → Medium | **Addressed structurally by §3.5.** Comparison happens only between shared hand holds, so corresponding spans are corresponding by construction and a differing move count becomes the finding. |
| Too few shared hand holds, so sequences are too coarse to be useful | **Critical** | The residue of Q2, and the new critical risk. Report anchors ÷ reference hand holds on every pair. If it is low, the fallback is comparing structure only — move counts, holds used, time — and dropping per-metric deltas. |
| Differences smaller than tracking noise | High | Phase 0 Q3; the manual eyeball test answers this before any code |
| Pose model can't track climbing poses | Medium | **Swappable.** Evaluate Vision vs RTMPose on desktop; convert the winner to Core ML. Not a project risk, a vendor choice. |
| Homography fails on plain or repetitive walls | Medium | Detect via residual error, prompt re-record. Single-take capture largely sidesteps it. |
| Foreshortening z too noisy to be useful | Medium | Confidence gating; ship without it if needed — other metrics stand alone |
| Capture setup too slow or socially awkward for real use | Medium | Phase 0 usability log. A usage problem no analysis quality can fix. |
| Foundation Models output too generic | Low | Template provider is the fallback and already exists |
| Foundation Models device requirement excludes users | Low | Template provider covers all devices |
| Two climbers of very different size skew comparison | Low | Body-length normalization throughout |

---

## 6. Decisions taken

- **No hold segmentation in the PoC.** Route is derived from reference-climb
  contacts. Segmentation is a phase-2 feature and connects to the separate
  spray wall project.
- **Straight-on camera.** Depth recovered via limb foreshortening rather than
  an oblique angle, accepting reduced accuracy for a simpler capture flow.
- **On-device throughout.** No backend. This constrains text generation to
  Apple Foundation Models, which is acceptable because the model only narrates
  pre-computed numbers.
- **DTW, not a speed slider.** Automatic non-linear alignment.
- **Three levels: beta → sequence → move.** A **move** is one climber's span
  between hand acquisitions and is the unit of *measurement*. A **sequence** is
  the span between two holds **both climbers touched with a hand** and is the
  unit of *comparison*. A **beta** is one climber's whole move list. Feet never
  create boundaries at either level.
- **Move counts inside a sequence are allowed to differ, and the difference is
  the finding.** Three moves against one is reported as structure, not
  suppressed as divergence.
- **Sequences belong to a (reference, attempt) pair**, not to the route. Two
  attempts on the same route can partition into different sequences.
- **DTW and all comparison anchor at sequence boundaries**, never at move
  boundaries — moves are not guaranteed to correspond and pinning them assumes
  the thing the sequence layer exists to establish.
- **No climber profile — no height, no weight.** All units are body-lengths and
  %bodyweight. Mass adds no accuracy to a geometric load model and corrupts
  cross-climber comparison; height was only a display conversion. Both are
  additive later at the render layer.
- **Three comparison views** (overlay, side-by-side, skeleton-only) off one
  alignment pipeline. **Side-by-side is the default**; skeleton-only is the
  drill-down from an analysis finding.
- **One-off session pairs, no reference library.** A library adds persistence,
  migrations, thumbnails and storage management, none of which de-risk the
  pipeline. Two constraints make it additive later rather than a rewrite:
  `ClimbSession` owns one reference and an **array** of attempts (retry after
  a fall is normal within a single session), and extracted pose is cached per
  video so results screens never re-run Vision.
- **No shared timeline.** DTW-locked playback means the scrubber is indexed by
  **sequence**, not by time and not by move — the two climbers have different
  move counts inside a sequence, so a move index does not name one position in
  a locked pair. Moves appear as per-pane ticks within the current sequence.
  Sync locked by default, one unlock toggle.
