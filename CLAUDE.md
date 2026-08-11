# CLAUDE.md — Video Overlap

Context file for Claude Code. Read this before touching anything.

---

## What this is

An iOS app for indoor bouldering. The user films a stronger climber sending a
route (phone on a tripod), then films their own attempt on the same route from
the same tripod position. The app aligns the two clips, splits the climb into
hold-to-hold moves, groups those into sequences bounded by the holds both
climbers used, and produces a per-sequence breakdown of what the two climbers
did differently.

Working name: **Video Overlap**. Not final. Don't hardcode it in user-facing
strings — use a localized constant.

---

## Non-negotiable constraints

| Constraint | Value | Why |
|---|---|---|
| Platform | iOS only, native | Explicit product decision |
| Network | **None.** Zero backend, zero API calls | Explicit product decision |
| Pose | Apple Vision, on-device | Explicit product decision |
| Text generation | Apple Foundation Models, on-device | Follows from "no backend" |
| Camera | Straight-on to the wall | Explicit product decision |

If a task seems to require a server, **stop and flag it** rather than
introducing one. The no-backend rule is a product constraint, not a
preference.

---

## The single most important architectural rule

> **Code measures. The model narrates.**

Every number in this app — centre of mass, hip distance from wall, limb load,
joint angles, timing — is computed by deterministic Swift. The language model
never estimates, infers, or produces a quantity. It receives a struct of
already-computed metrics and writes a sentence about them.

Any code path where an LLM produces a number is a bug. Any prompt that asks a
model "how far was the hip from the wall" is a bug. The model gets
`hipDistanceFromWall: 0.31` and explains what that means for the climber.

This is what makes an on-device 3B model sufficient, and it's what keeps the
output trustworthy.

## Second rule: comparison is always normalized

Never compare two climbers in absolute units. Load is %bodyweight. Distances
are body-lengths, normalized by torso length. A heavier or taller climber must
not show a "difference" that is purely a consequence of their size.

There is **no climber profile** — no height, no weight. Mass adds nothing to a
geometric load model, and height was only ever a display conversion. If a
kilogram or centimetre value reaches `MetricsEngine` or `SequenceDelta`, that's
a bug.

## Third rule: measure per move, compare per sequence

A metric is computed over one climber's **move**. A delta is computed over a
**sequence**, aggregating each climber's moves within it.

The reason is that a delta needs two spans that denote the same thing, and
moves don't. Two climbers cross the same span of wall with different numbers of
moves — the reference reaches straight through where the attempt steps a foot,
matches a hand, then reaches. Pairing those by index compares unrelated spans
and produces a confident number about nothing.

Anchors are the fix: comparison happens only between holds both climbers
actually touched with a hand, so the spans correspond by construction. A
differing move count inside a sequence is then a **finding** — "three moves
against one" — not a problem to suppress.

Consequences that are easy to get wrong:

- **DTW anchors at sequence boundaries, never at move boundaries.** Anchoring
  at moves assumes the correspondence this rule exists to establish.
- **The scrubber is indexed by sequence.** A move index doesn't name one
  position in a locked pair when the two panes have different move counts.
- **Sequences belong to a (reference, attempt) pair, not to the route.** Two
  attempts on one route can partition differently. Only `Route` and the
  reference's own `Beta` are shared.
- Move-level findings that need **no partner** — arm load, foot commitment,
  hesitation — still report per move. Only *comparisons* move up a level.

Full design in `plan.md` §3.5; tasks in Phase 9.

## Fourth rule: this is a debug harness, not a product

Visual polish is explicitly not a goal. Build the plainest UI that lets you
inspect pipeline output — system fonts, default controls, no custom styling, no
animation, no empty-state illustrations. Numbers on screen beat a nice layout.

Do not spend effort on: onboarding, app icon, colour schemes, transitions,
haptics, accessibility polish, or App Store readiness. If a task can be
satisfied by a debug view with a text dump, do that.

This inverts the usual instinct on the comparison views: build them ugly and
functional, and only once the pipeline behind them is proven.

## Working agreement — how to execute this project

**Goal: a working end-to-end app, fast.** Record two clips -> process ->
moves -> sequences -> comparison views -> per-sequence analysis. Build straight
through Phases 1-5. Do not stop at a gate to wait for sign-off.

**Gates are checkpoints, not stops.** When you reach one, state plainly whether
it passed, failed, or is inconclusive, and what the evidence was. Then keep
building. A failed checkpoint is information for the next iteration, not a
reason to halt -- the point is to get something testable at a gym and iterate
from real notes.

**Nothing is hardcoded that hasn't been validated against real footage.** Every
threshold -- contact velocity, dwell frames, DBSCAN radius, confidence floors,
smoothing constants -- lives in a `TuningConfig` struct exposed as a runtime
debug control. Defaults are guesses until real climbing footage says otherwise,
and the app must let those guesses be corrected on site without a rebuild.

**Every stage must be re-runnable on a saved session.** Changing a threshold
re-processes from cached pose data. It must never require re-recording, and
must never re-run pose extraction.

**Fail soft, never blank.** A stage that can't produce a good result produces a
degraded one plus a visible warning -- never an empty screen. If route
derivation finds two holds instead of nine, show the two and say so. Debugging
on a gym floor needs output, not error states.

**Never weaken an acceptance criterion to satisfy it.** If a criterion can't be
met, say so and move on. Don't quietly relax a threshold until something
passes; surface it as a finding.

**Escalate rather than work around** on: anything needing a backend or network
call, anything needing a paid API, and any change to the constraints table
above. These were decided deliberately.

**Build order note:** capture and pose extraction come first and are
independent. Pose can be developed against any video of a person moving --
climbing footage is needed for tuning, not for building.

**One real clip is enough to build the whole pipeline.** Most stages need only
a single climber: pose, contact detection, route derivation, segmentation,
metrics and fall detection all operate on one climb. For the two that appear to
need a matched pair, derive a synthetic partner from the same clip:

- `WallAligner` — apply a **known** homography to the clip and assert
  registration recovers it. Stricter than a real pair, since you have ground
  truth instead of an eyeball check.
- `TimeAligner` — time-warp a copy of the pose sequence by a **known**
  non-linear function and assert DTW recovers that path.

Prefer these synthetic tests over real-pair tests even once real pairs exist —
they assert against a known answer, and they run in CI.

**Dev fixtures are optional and may not exist yet.** If `Fixtures/` is empty,
build and test against synthetic `PoseFrame` fixtures and any video of a person
moving — do not block on climbing footage, and do not fabricate placeholder
video files. Thresholds ship as documented guesses, corrected later through the
tuning panel.

If climbing clips do appear in `Fixtures/`, tune against them immediately. Note
that most stages need only a **single** climber: pose, contact detection, route
derivation, segmentation, metrics and fall detection all operate on one climb.
Only `WallAligner` and `TimeAligner` require a matched pair. A lone clip
containing a shake-out, hand match, re-grip and smeared feet is the highest
value fixture in the project, because it is what decides whether
`ContactDetector` works.

## Domain glossary

Use these terms consistently in code and comments.

- **Reference climb** — the stronger climber's video. Not "pro", not "friend".
- **Attempt** — the user's own climb.
- **Contact** — a limb (wrist or ankle) at rest on a hold. Detected from
  velocity, not from image segmentation.
- **Hold** — a cluster of contacts in wall space. Derived, not detected.
- **Route** — the ordered list of holds, derived from the reference climb.
- **Move** — the span between two successive *hand* hold acquisitions, **for one
  climber**. Feet move within a move; hands define it. **The unit of
  measurement.** Was called `Section`; the rename is deliberate, see below.
- **Beta** — one climber's whole ordered list of moves through the route. The
  reference has one, each attempt has its own, and they are computed
  independently.
- **Anchor** — a route hold that a hand of the reference *and* a hand of the
  attempt both contacted. Either hand; it need not be the same hand on both
  sides. Feet never create anchors.
- **Sequence** — the span between two successive anchors. **The unit of
  comparison.** In code it is `ClimbSequence`, never `Sequence` — that name
  collides with the Swift standard library, and `PoseSequence` already exists.
- **Wall space** — the canonical 2D coordinate frame both videos are warped
  into via homography. All geometry lives here. Never compare raw pixel
  coordinates across two videos.
- **z** — distance out from the wall plane, toward the camera. Estimated from
  limb foreshortening. Always positive.
- **Base of support (BOS)** — polygon spanned by the currently loaded contact
  points. COM leaving it is the mechanical definition of falling.
- **Proximate / distal cause** — a fall's proximate cause is in the 1–3s before
  release; the distal cause is the earlier *sequence* where the problem started.
  Cross-sequence attribution is the point of the feature, so never report only
  the proximate cause.

---

## Pipeline

Each stage is a separate type with a protocol. Stages are pure where possible —
input in, value type out, no shared mutable state.

```
VideoImporter
    └─> PoseExtractor         Vision → [PoseFrame]
        └─> PoseSmoother      1€ filter, per joint
            └─> WallAligner   VNHomographicImageRegistrationRequest
                └─> ContactDetector    velocity + dwell → [Contact]
                    └─> RouteBuilder   cluster reference contacts → Route
                        └─> MoveSegmenter      per climber → Beta ([Move])
                            └─> SequenceBuilder  both betas → [ClimbSequence]
                                └─> TimeAligner  DTW, anchored at sequences
                                    └─> MetricsEngine  → MoveMetrics
                                        └─> SequenceDelta   aggregate + compare
                                            ├─> FallAnalyzer    → FallReport
                                            └─> AnalysisProvider → SequenceAnalysis
                                                └─> ComparisonRenderer
                                            (overlay | sideBySide | skeletonOnly)
```

`RouteBuilder` runs on the reference climb only. The attempt's contacts are
*matched* to the already-built route, never used to rebuild it.

`MoveSegmenter` runs **once per climber** and takes no argument referring to
the other climb. `SequenceBuilder` is the only stage that sees both.

---

## Things that will bite you

**Pose model is swappable; the concept is not.** `PoseExtractor` sits behind a
protocol precisely so Vision can be replaced with RTMPose or MoveNet without
touching anything downstream. Treat pose quality as a vendor choice, not a
project risk. The real risks are contact-detection ambiguity (shake-outs,
matches, re-grips, smears) and beta divergence between the two climbers — see
`plan.md` §4 Phase 0.

**19 joints, no extremities.** `VNDetectHumanBodyPoseRequest` gives you no
fingers and no toes. Grip analysis and precise foot placement are out of scope
on Vision. RTMPose's 133-keypoint output would change this — if the pose model
changes, revisit this constraint rather than assuming it still holds.

**Foreshortening breaks down near the wall plane.** The z estimate has a flat
derivative when a limb is nearly parallel to the wall, so small pixel errors
produce large z errors. Always emit z with a confidence value derived from
`L_observed / L_true`, and suppress the metric in the UI below threshold.

**The tripod will move.** Never assume the two videos share a camera pose. The
homography step is mandatory, not an optimization. Note also that iPhone video
stabilization warps the frame per-frame and breaks registration — fixtures are
shot with it off, per `capture-protocol.md`.

**Never compare timestamps directly.** One climber is faster. All cross-climb
comparison happens on DTW-warped indices or at **sequence** boundaries. This
extends to the UI: **there is no shared timeline**, so the scrubber is indexed
by sequence ("sequence 4 of 9"), never by time and never by move. Don't build a
time scrubber and try to reconcile it later.

**Sessions are one-off.** One reference, an array of attempts, no library and
no cross-session persistence. But `ClimbSession` must own attempts as a
collection from day one — retry after a fall is normal within a single session.
Extracted pose is cached per video; a results screen must never re-run Vision.

---

## Code conventions

- Swift 6, strict concurrency. Pipeline stages are `actor` or `Sendable`
  structs.
- SwiftUI + `@Observable`. No ViewModels holding Combine subjects.
- Value types for all pipeline data. `PoseFrame`, `Contact`, `Move`, `Beta`,
  `ClimbSequence`, `MoveMetrics` are `struct`, `Sendable`, `Codable`.
- Units are explicit in property names: `hipDistanceFromWallMeters`,
  `elbowAngleDegrees`. No bare `Double` for physical quantities in public API.
- Wall-space coordinates are normalized to `[0,1]` on both axes. Pixel
  coordinates never escape the stage that produced them.
- No force unwraps outside tests.

## Testing

- Pipeline stages get unit tests with synthetic `PoseFrame` fixtures. Don't
  require video files for logic tests.
- Keep 3–4 real gym clips in `Fixtures/` for integration tests. Commit them
  with Git LFS or keep them out of the repo and document how to obtain them.
- `MetricsEngine` outputs are golden-file tested. Metric drift should fail CI.

---

## Explicitly out of scope for the PoC

Do not build these unless asked:

- Hold segmentation / route classification from images
- Outdoor climbing, rope climbing, lead
- Accounts, cloud sync, sharing, social features
- Multi-person detection (assume exactly one climber in frame)
- Live/real-time analysis during recording
- Anything requiring LiDAR

## Deferred, but designed for

- `VNDetectHumanBodyPose3DRequest` as a cross-check on the foreshortening z
  estimate. The `DepthEstimator` protocol exists so this can slot in.
- A remote `AnalysisProvider` if on-device text quality proves insufficient.
  The protocol exists; the implementation is a stub. Adding it means adding a
  backend — escalate before doing so.
- Visual hold outlines in the overlay, once segmentation exists.
