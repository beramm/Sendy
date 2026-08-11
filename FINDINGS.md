# Findings — first build, Phases 0–5

Written against the single dev fixture in `Fixtures/` (`IMG_4851 2.mov`,
1080×1920 portrait, 30fps, 32s, one climber, clean send). Everything below is
measured, not estimated. Where a criterion could not be met it says so rather
than being relaxed.

---

## How to reproduce any of this

```bash
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
swift test                                              # 49 tests
./.build/release/posecli pose "Fixtures/IMG_4851 2.mov" --out ref.json
./.build/release/posecli sweep ref.json                 # threshold grid
./.build/release/posecli frames "Fixtures/IMG_4851 2.mov" ref.json --indices 240 --holds
./.build/release/posecli pipeline ref.mov attempt.mov   # whole pipeline, end to end
```

`xcode-select` points at CommandLineTools on this machine, so every build needs
`DEVELOPER_DIR` set as above.

---

## Phase 0 — the three questions

### Q1 — is contact detection clean enough? **Partly. It is the weak link.**

Vision tracks the torso on this clip very well and the wrists poorly:

| joint | frames above conf 0.5 | frames above 0.3 |
|---|---|---|
| shoulders / hips / root | 97–99% | 100% |
| knees / ankles | 80–86% | 97–99% |
| right wrist | 68% | 88% |
| **left wrist** | **39%** | **65%** |

Contact detection depends on exactly the joint Vision tracks worst. With the
tuned defaults the clip yields 19 contacts → 10 holds → 7 hand holds → 8 moves,
which is plausible for this problem, but the margin is thin and left-hand
contacts are the ones that drop.

The stress cases from `capture-protocol.md` shot 3c (shake-out, hand match,
re-grip, smeared feet) **could not be tested** — this fixture contains none of
them deliberately. Merging handles re-grips and shake-outs by construction, and
a hand match produces two contacts from two different joints that land in one
cluster, which is correct. Smears are untested and are the case most likely to
fail.

### Q2 — do the two climbers' sequences correspond? **Untested.**

There is one clip. No real pair exists, so this cannot be answered. The
machinery for the "no" answer is built and tested: divergent beta is reported as
a finding (`BetaDivergence`) and metric comparison is suppressed for that move
rather than producing a confident comparison of two different moves.

### Q3 — are the differences larger than the noise? **Partly answered.**

Against a synthetic partner (the fixture time-compressed to 0.8× and shifted),
per-move differences came out well clear of frame-to-frame jitter on COM path
length, load asymmetry, hip twist and reach margin. **Hip depth did not** — see
the Phase 3 checkpoint below. A real pair is still needed.

---

## The change that mattered most: thresholds in body-lengths, not wall-widths

The first run of contact detection over the fixture collapsed the whole route
into one blob: DBSCAN at ε = 0.045 wall-widths chained every contact together.
The cause was not the clustering. On this clip the climber's torso is **0.068
wall-widths**, so ε was two-thirds of a body length — enormous.

A threshold in wall-widths silently depends on how far back the tripod stood.
That contradicts the project's own second rule, so every spatial and velocity
threshold is now expressed in **body-lengths**, converted through `ClimbScale`.
`ModelTests.scaleIsFramingIndependent` asserts that the same climb filmed at
half the size produces the identical contact count.

Defaults chosen from the fixture's own speed distribution (extremity speed:
p25 ≈ 0.25 BL/s, median ≈ 0.5 BL/s, p90 ≈ 3 BL/s):

| threshold | default | basis |
|---|---|---|
| `contactVelocityThreshold` | 0.30 BL/s | between p25 and median; the sweep is flat from 0.20–0.40 |
| `contactDwellFrames` | 6 | sweep: 3 over-fires, 12 loses hand holds entirely |
| `holdClusterEpsilon` | 0.55 BL | holds a climber can use as separate sit about a torso apart |
| `contactMergeRadius` | 0.55 BL | absorbs re-grips without merging adjacent holds |
| `smoothingBeta` | 4.0 | measured, see below |

The sweep grid (`posecli sweep`, contacts/holds/handHolds):

```
v\N          3           4           6           8          12
0.10    12/ 6/ 3    10/ 6/ 1     7/ 4/ 1     3/ 2/ 0     0/ 0/ 0
0.20    21/10/ 7    20/10/ 7    16/ 9/ 6    15/ 8/ 5     8/ 5/ 2
0.30    27/10/ 7    24/10/ 7    19/10/ 7    17/11/ 7    13/10/ 5
0.60    28/10/ 6    26/ 8/ 5    25/ 8/ 5    20/ 9/ 6    18/10/ 6
```

**1€ filter beta.** The published default (0.007) does nothing at all in
normalized coordinates — joint speeds are order 0.1–1/s, so the adaptive cutoff
never lifts. Measured group delay at 0.007 was ~5 frames at 30fps, which moves
dwell boundaries. At beta 4.0 it is ≤ 3 frames with jitter still halved.

---

## Checkpoints

### 🚦 Phase 1 — route derivation quality: **inconclusive, with a known bias**

Derived hold count (10, of which 7 hand) is plausible. Hold **positions are
systematically offset** from the actual holds by roughly half a hand: Vision's
wrist joint is the wrist, not the fingers, and its ankle is the ankle, not the
toe. This is the "19 joints, no extremities" constraint in `CLAUDE.md` biting
exactly where it said it would.

Rendered overlays (`posecli frames … --holds`) show derived holds sitting
consistently *inside* the climber from the real hold. For clustering and section
boundaries this is harmless — the bias is the same for both climbers — but the
"positions match the real route by eye" criterion is **not met**, and would need
either a fingertip-capable pose model or the manual correction UI (built, task
1.10).

Two other real-footage findings, both fixed:

- **A false fall before the climb starts.** The climber walks to the wall with
  no contacts and a bobbing COM, which read as free fall. Fall detection now
  ignores everything before the first contact.
- **Garbage on the last move.** A truncated attempt's final section ran to the
  end of the file, dragging the climber walking away into the metrics (COM path
  13.3 body-lengths on one move). Sections now end at the last contact.

### 🚦 Phase 2 — alignment quality: **passed, with the limit documented**

Registration was tested against **known** homographies applied to a real frame,
which is stricter than eyeballing a real pair. Mean recovery error over a 5×5
grid, in wall-widths:

| applied transform | recovery error |
|---|---|
| translate 0.5% | 0.00016 |
| translate 2% | 0.00034 |
| rotate 2° | 0.00008 |
| rotate 5° + scale 1.03 + translate 2% | 0.0082 |
| rotate 15° + scale 1.20 | **0.140 — beyond the limit** |

So registration is reliable well past any plausible tripod nudge and fails at a
gross re-framing, which is the boundary you want documented. The failure is
detected (residual > `registrationResidualLimit`) and surfaced as "re-record"
rather than silently analysed.

Two conventions had to be established empirically and are now pinned by tests:
`VNHomographicImageRegistrationRequest.warpTransform` operates in **pixels**,
and it maps **reference → floating**, the opposite of what the aligner needs.
A separate test pins the direction of the warp function itself, so a sign error
in one cannot cancel a sign error in the other and pass unnoticed.

DTW recovers known non-linear time warps to a mean of **1.5–2.5 frames** across
four warp shapes, including one that speeds up then slows down. Paths are
monotonic and section endpoints map exactly.

### 🚦 Phase 3 — hip-distance signal quality: **failed on this fixture**

The foreshortening depth estimate is the weakest number in the app.

- It only produces a value when a foot is anchored on the wall, since the chain
  needs a z ≈ 0 anchor.
- The sign of each segment's `z_local` is **not recoverable from one view**, so
  the chain sums magnitudes. That makes the output an upper bound on how far the
  hip is out — monotone in the quantity a coach cares about, but not a
  measurement of it.
- Near the wall plane the derivative is flat, so the confidence gate suppresses
  a large fraction of frames.

On the fixture, hip depth was available for enough frames to report on most
moves, but there is no hips-in/hips-out pair (`capture-protocol.md` shot 3) to
calibrate against, so **the criterion cannot be evaluated**. Shooting shot 3 is
the single highest-value thing the next gym trip can do for this metric.

Everything else in Phase 3 is unit-tested: COM lands at 27% of torso height
above the hips on a standing pose, IDW loads sum to exactly 1.0, the base of
support reports 2.5 body-lengths for a COM 0.25 wall-units outside a 0.1-torso
climber's polygon, and a dyno does not read as a fall.

### 🚦 Phase 4 — analysis usefulness: **plausible, unreviewed by a climber**

Template output on the real pair reads like this:

> **Move 4: latching from further away** — You latched the hold with your centre
> of mass 1.59 body-lengths away, against 0.95. Your centre of mass travelled
> 2.83 body-lengths through this move against 3.46 — 0.62 more.
> *Try: move your body closer to the target hold before reaching for it.*

> **You came off on move 8, but it started on move 1.** Your centre of mass left
> the base of support 0.19 body-lengths before you came off, and did not return.

The cross-section attribution shape works. Whether a climber agrees it is
*correct* is the actual gate, and that has not been tested.

---

## A bug worth naming: the pipeline was non-deterministic

The golden-metric test passed, then failed, then passed on identical input.
Cause: `Dictionary` iteration order is randomised per process in Swift, and both
contact merging and hold clustering iterated dictionaries. Hold ids and merge
outcomes could differ run to run.

That would have been maddening on a gym floor — you change a threshold, the
route changes, and you cannot tell whether the threshold did it. Both stages now
use a total ordering (`Contact.deterministicOrder`), and three consecutive full
test runs agree.

---

## Measured performance

| operation | time |
|---|---|
| pose extraction, 32s clip, 1080p → 30fps | **9.5s** (~116 fps) |
| everything downstream of pose | **< 0.25s** |
| reprocess after a threshold change | **< 0.1s**, zero Vision requests |

The reprocess guarantee is enforced by a test with a spy extractor that counts
calls: it must still read 2 after a second run with a different config.

---

## What is not built or not verified

- **Task 0.4 (Vision vs RTMPose on desktop).** Not done. Vision's numbers are
  above; there is nothing to compare them against. `PoseExtractor` is a protocol
  precisely so this stays a vendor swap.
- **Task 0.4b (depth-method comparison).** Needs shot 3.
- **Tasks 0.1, 0.1b, 0.2 (gym shoot, usability log, manual eyeball test).** These
  are things to do at a gym, not code.
- **Live playback.** All three comparison modes render **stills** at the current
  scrub position rather than running two synchronised players. This follows from
  the design — there is no shared clock, so "playing together" means stepping
  both along the DTW path anyway — but it means there is no play button.
- **Simulator UI walkthrough.** The app builds, installs, launches, and lists a
  seeded fixture session (verified by screenshot). Driving it further needed
  simulator input access, which was declined while unattended, so the results
  screen has **not** been exercised interactively. The pipeline behind it was
  verified end to end on the real fixture through `posecli pipeline`.
- **Smears, matches and shake-outs** (Q1's hard cases) and **any real climber
  pair** (Q2). Both need footage that does not exist yet.

---

# Phase 7 — what the real pair settled

`betterClimber.mov` (26s, a clean go) and `user.mov` (14s, the same climber
falling) — one person, same route, same beta, 720×1280 at 60fps, static camera.
Measured drift within each clip is 0.0001–0.0003 wall-widths, so the camera did
not move; an earlier claim that it panned was wrong and is retracted.

## Two segmentation bugs, both fixed

**The merge radius was eating moves.** `contactMergeRadius` and
`holdClusterEpsilon` both defaulted to 0.55 body-lengths. Merging is meant to
absorb a re-grip *within* a hold; clustering decides when two contacts are
*different* holds. Equal radii meant a hand leaving one hold and landing on a
neighbour within 0.67s was merged into a single contact — the move was destroyed
before clustering could see it.

| | before | after |
|---|---|---|
| raw contacts | 44 | 44 |
| after merging | 24 | **34** |
| holds | 16 | **18** |
| moves | 6 | **7** |

Merge radius is now 0.20 BL with an 8-frame gap, and every surviving merge on
the reference clip measures 0.018–0.155 BL — all genuine re-grips. A chained
merge is now also anchored to where the run started, so a sequence of small
steps cannot walk across the wall one hold at a time. The invariant
(merge < cluster) is warned about at runtime and pinned by a test.

**A hold a foot touched first was a foot hold forever.** `isHandHold` read
`firstUsedBy`, set from the earliest contact in the cluster. Holds now carry
`usedByHands` and `usedByFeet` independently, and both can be true — which is
the normal case for a hold you stand on and later match hands on.

`holdClusterEpsilon` moved 0.55 → 0.40 BL. Swept on the real clip the derived
move count is flat at 7–8 across 0.30–0.55 and drops to 6 by 0.70, so this sits
in the middle of the stable band rather than at its edge.

## Q1, answered with numbers: pose is the wall

The attempt clip cannot be segmented past move 1, and no threshold fixes it.

Per-joint confidence, fraction of frames above 0.5:

| joint | attempt | reference |
|---|---|---|
| hips / shoulders | 69–72% | 87–89% |
| ankles | 65–66% | 80–88% |
| right wrist | 59% | 62% |
| **left wrist** | **17%** | **26%** |

Mean left-wrist confidence on the attempt is **0.27**.

The consequence is visible in the contact list: **every hand contact in the
attempt falls between frames 48 and 167 of 432.** After that Vision reports no
wrists at all, while the ankles keep tracking and visibly climb (x 0.27 → 0.67).

Both plausible remedies were swept and are completely flat:

| extremity confidence floor | 0.30 | 0.20 | 0.15 | 0.10 |
|---|---|---|---|---|
| hand acquisitions | 1 | 1 | 1 | 1 |

| interpolation gap (frames) | 12 | 30 | 60 | 90 |
|---|---|---|---|---|
| hand acquisitions | 1 | 1 | 1 | 1 |

You cannot interpolate across a joint that was never detected. This is the Q1
risk from `plan.md` — "everything rests on limb-at-rest being separable from
limb-moving" — and the answer is that on this footage the limb is not *detected*,
let alone separable. Contact detection depends entirely on the joint Vision
tracks worst.

**Implication for the vendor decision.** `PoseExtractor` is a protocol precisely
for this. Task 0.4 (Vision vs RTMPose on desktop) has been the least urgent open
task all along; it is now the most. RTMPose's 133 keypoints would also lift the
"no fingers, no toes" constraint that makes derived hold positions sit half a
hand inside the real ones.

## Two footwork metrics, built and unverified

`feetSetBeforeReach` — the fraction of hand releases in a move where both feet
were already down and loaded. Unit-tested at 1.0 for feet-first and 0.0 for
hand-first. `footCommitmentSeconds` — time from placing a foot to that foot
taking load. Unit-tested at 0.07s prompt versus 2.0s hesitant.

Neither has fired on real footage, because the attempt yields one move. They are
correct and idle.

## A separate extremity confidence floor

Added regardless: `extremityConfidenceFloor` (0.15) alongside
`jointConfidenceFloor` (0.30). One number for both was wrong in principle — the
torso floor rejects whole-frame tracking failures, while the extremity floor
gates the measurement itself, and Vision scores the two groups very differently.
It does not rescue this clip, but it stops a systematically less-confident joint
being judged by a torso's standard.

---

# Phase 8 groundwork — measuring the tracker question

## The noise floor, measured

`posecli jitter` reports how far a joint moves frame-to-frame **during a
detected contact** — a limb the pipeline believes is at rest, so whatever it
moves is noise.

| | median | p90 | max |
|---|---|---|---|
| wrists | 0.26–0.39 px | ~0.6 px | ~1.0 px |
| ankles | 0.20–0.25 px | ~0.5 px | ~0.9 px |

Sub-pixel, on smoothed Vision output. A toe rolling onto an edge moves roughly
**7–9 px** at current framing (torso 57–75 px, foot 14–19 px), so the signal for
foot micro-movement sits **15–30× above the floor**.

This retracts an earlier claim that a 14-pixel foot is too small for toe
tracking. That conflated *localization accuracy* — can a model put the toe in
the right place — with *relative precision* — can it see the toe move.
Micro-movement only needs the second, and there is ample room for it.

The open question is therefore not the arithmetic but whether RTMPose's foot
keypoints are stable at that scale. `posecli compare --jitterlimit 2.0` decides
it: at or below 2 px of at-rest jitter, "quiet feet", heel drop and edge roll
are all measurable; above it, the answer is closer framing rather than a
different model.

## Degraded pose does not produce degraded-looking output

`posecli compare` runs the real `ProcessingPipeline` once per tracker with pose
supplied rather than extracted, and diffs everything through to the sentences a
climber reads. Validated by comparing Vision against a copy of itself with 40%
of wrist readings deleted:

| | Vision | 40% of wrists removed |
|---|---|---|
| moves | 7 | 9 |
| moves the attempt reached | 1 | 2 |
| fall detected | move 1 | move 9 |
| move 1 verdict | "this is where your go ended" | **"you stood on your feet"** |

The degraded run is *more flattering*. It tells a climber who fell that they
kept weight through their feet and got their body closer to the hold than the
reference climber did. Nothing in the output indicates lower confidence.

This is the actual risk in swapping pose models, and it is not "the new model
might be worse". It is that **pipeline output is confidently different under
degraded input, with no visible signal of it.** Recorded as task 8.4b: pose
quality needs to reach the results screen, and analysis needs to be hedged or
suppressed when the tracking behind it is too thin.

It is also why the comparison had to go all the way to the analysis text.
Stopping at per-joint confidence would have shown a tracker that looked slightly
worse and hidden that it changed the entire verdict.

## A default reverted by its own evidence

`extremityConfidenceFloor` was added at 0.15 on the reasoning that Vision scores
extremities lower than the torso, so they deserve a lower bar. Swept, it is
worse:

| extremity floor | 0.30 | 0.25 | 0.20 | 0.15 | 0.10 |
|---|---|---|---|---|---|
| reference moves | **7** | 6 | 6 | 6 | 6 |
| attempt hand acquisitions | 1 | 1 | 1 | 1 | 1 |

Low-confidence wrist positions are *noisy* positions, and noise raises velocity,
which destroys the at-rest runs contact detection depends on. Default returned
to 0.30. The field stays, because a different pose model will have a different
confidence distribution and this is the knob that lets it be judged on its own
scale rather than Vision's.

## A rendering bug that was being read as a tracking failure

Skeleton mode normalises each climber by their **per-frame** torso length, used
as a divisor. On the reference clip the minimum per-frame torso is 0.0044
against a median of 0.0447 — ten times too small — which turned the intended
2.2× scale factor into 23× and flung every joint off the diagram. It affected 24
of 747 frames, often enough to hit while scrubbing, and made Vision look far
worse than it is.

Fixed by rejecting a per-frame torso outside 0.5–2× the climb median, clamping
the factor to 0.25–4×, and declining to draw a skeleton at all when the torso is
missing — the diagram now says tracking was lost rather than drawing a scribble.

---

# Phase 8 — Vision vs RTMPose, decided

RTMPose run on desktop over both fixtures via `Tools/rtmpose/rtmpose.sh`
(rtmlib over ONNXRuntime), emitting the same `PoseSequence` JSON the Swift
pipeline reads. Compared with `posecli compare`, which runs the **real**
`ProcessingPipeline` once per tracker and diffs everything through to the
sentences a climber would read.

## RTMPose wins, and it changes the product rather than a metric

| | Vision | RTMPose |
|---|---|---|
| left wrist tracked >0.5 (attempt) | 17% | **71%** |
| left wrist tracked >0.5 (reference) | 25% | **77%** |
| **longest wrist dropout** | **121 frames** | **0** |
| holds | 18 | 19 |
| hand holds | 6 | 9 |
| moves derived | 7 | **10** |
| **moves the attempt reached** | **1** | **5** |

The wrist dropout that blocked Phase 7 is gone — zero-frame maximum on both
clips. Vision produced one usable move on the attempt and "you didn't get this
far" for everything else. RTMPose produces five moves of real analysis:

> **Move 1** — You held this move with bent arms while your arms were also
> taking most of your weight. That is the most tiring way to stay on the wall.
> **Move 2** — You took a more direct line through this move than they did.
> **Move 3** — You used 1 hold here that the reference climber did not.
> **Move 4** — This is where your go ended.

## Toes are usable at current framing

The reason for wanting RTMPose in the first place. Foot keypoint movement
measured **during at-rest frames**, which is the noise floor micro-movement has
to clear:

| | median | p90 | heel→toe span |
|---|---|---|---|
| attempt (torso 76 px) | **0.40–0.53 px** | 1.2–1.8 px | 27.5 px |
| reference (torso 56 px) | 0.63–1.02 px | 1.3–3.9 px | 16.7 px |

Against the 2.0 px acceptance limit, both pass. A foot rolling onto an edge
moves the toe several pixels against a sub-pixel floor, so "quiet feet", heel
drop and edge roll are measurable — comfortably on the attempt, marginally on
the reference where the climber is smaller in frame. Filming closer buys
headroom but is no longer a precondition.

This retracts the earlier "a 14 px foot is too small" claim twice over: the
foot is larger than estimated, and the relevant quantity was never absolute
localization anyway.

## Thresholds transfer; no per-source tuning was needed

RTMPose is smoother — extremity speed p25 is about half Vision's (0.12 against
0.30 BL/s). The obvious move is a second set of defaults, and the sweep says
don't:

| velocity threshold | 0.20 | 0.30 | 0.40 |
|---|---|---|---|
| moves (RTMPose reference) | 9 | 10 | 13 |

Vision's 0.30 default sits inside the stable band. Building per-source defaults
holding identical numbers would be speculative machinery, and choosing different
numbers without by-eye ground truth would be fake precision. The
`extremityConfidenceFloor` field stays as the hook if a future model needs it.

## On-device path: ONNX Runtime, not Core ML

`coremltools` dropped ONNX support at v6, so Core ML would mean
onnx → torch → coreml, which is fragile for a model with SimCC decoding.
Microsoft ships an official Swift package for ONNX Runtime (1.24.2).

The better argument is numerics. Running the **same** `.onnx` file on device
means the desktop comparison above transfers exactly. A conversion introduces a
third artifact, and any difference on device could not be attributed to the
model or to the conversion without redoing the whole comparison.

Practical measurements:

| | pose model | detector | left wrist >0.5 |
|---|---|---|---|
| balanced | 218 MB | 97 MB | 71% |
| lightweight | 123 MB | 19 MB | 50% |

Lightweight gives back half the gain and is not worth it. The **detector is not
needed at all** — Vision already locates the climber for free, so the split is
Vision for detection, RTMPose for keypoints, which removes 19–97 MB and one
moving part. Model size is not a constraint for a harness installed via Xcode;
App Store limits do not apply here.

## Pose JSON is now an interchange format

`[JointName: Joint]` encodes as a keyed object rather than Swift's default
alternating `[key, value, key, value]` array (`JointName: CodingKeyRepresentable`).
The pose cache is how any external tracker enters this pipeline, and the array
form was unreadable when debugging and needlessly hard to produce elsewhere.

## On-device RTMPose: works, not yet at parity

ONNX Runtime via SPM, running the **same** `.onnx` as the desktop script, with
Vision supplying the person box in place of the 97 MB YOLOX.

| left wrist tracked >0.5 (attempt clip) | |
|---|---|
| Apple Vision | 17% |
| **Swift + ONNX Runtime** | **64%** |
| Python reference | 71% |

Comfortably better than Vision, still short of the desktop implementation, and
the shortfall costs moves: 1 derived move on the attempt against Python's 3. It
is not yet trustworthy enough to take to a gym as the primary tracker.

### Three preprocessing bugs, all of which looked like a bad model

Every one presented as *uniformly low confidence across all joints* — the
symptom that reads as "this model is worse on device" and is actually bad input.

1. **Double vertical flip.** Flipping the context to work in top-left
   coordinates also flips the image drawn into it.
2. **Y-offset in the wrong direction**, from mixing top-left box coordinates
   with CoreGraphics' bottom-left origin. Together these produced a crop that
   was upside down with the climber sliding off the top edge.
3. **Per-frame re-detection** instead of tracking the box from the previous
   frame's keypoints, which is standard for top-down pose pipelines. Fixing it
   took left-wrist tracking from 49.8% to 64.4%.

Channel order was the *expected* culprit and was not one. OpenCV reads BGR and
the reference never converts, so feeding RGB looked wrong — but A/B tested with
the geometry correct, RGB and BGR score within noise of each other (0.47 vs 0.46
mean wrist confidence). Reasoning suggested it; measurement refuted it.

### The tooling was what made this tractable

`posecli rtmpose` runs the Swift implementation from the command line, and
`posecli agree` diffs it against the Python output per joint. Without them the
only available signal was "confidence is lower on device", which is compatible
with a dozen causes. With them, median disagreement of a few pixels alongside a
p90 of ~1000 px pointed straight at the box rather than the maths, and
`debugCropDirectory` showed the upside-down crop in one command.

### Remaining gap

Vision's person detector is less reliable than YOLOX with a small climber on a
busy wall. Median agreement is now 3.4 px on a 76 px torso, but p90 remains
~1000 px, so a minority of frames still look at the wrong region. The options
are periodic re-detection, a confidence-gated re-detect, or bundling a real
detector.

---

# The first real two-climber pair — `gym-testing/test1`

Reference and attempt are **two different people** climbing the same green route
up an arête, same tripod position, recorded 78 seconds apart. 1080×1920 at
60fps, iPhone 17. Reference 53.4s / 3204 frames, attempt 28.8s / 1732 frames.
Neither climber falls; the attempt clip simply ends while the climber is still
on the wall.

This is the footage Phase 0 Q2 and task 0.4d have been blocked on since the
project started. The Phase 0 note "there is one clip, no real pair exists" is
now out of date.

Reproduce:

```bash
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
swift build -c release
./.build/release/posecli pose gym-testing/test1/reference.mov --out .work/test1/ref-vision.json
./.build/release/posecli segment .work/test1/ref-vision.json
./.build/release/posecli pipeline gym-testing/test1/reference.mov gym-testing/test1/attempt.mov
```

## Vision is not the binding constraint here. The old footage was.

The Phase 7/8 conclusion — "contact detection rests entirely on wrists, and
Vision tracks wrists worst" — does not reproduce on this pair. Fraction of
frames above confidence 0.5:

| joint | old ref | old attempt | **test1 ref** | **test1 attempt** |
|---|---|---|---|---|
| left wrist | 25% | **17%** | **81.4%** | **55.8%** |
| right wrist | 62% | 59% | 89.3% | 83.7% |
| shoulders / hips | 87–89% | 69–72% | 99–100% | 100% |
| ankles | 80–88% | 65–66% | 96–100% | 97–100% |

There is no wrist dropout. The Phase 7 signature — every hand contact confined
to frames 48–167 of 432 — is absent; hand acquisitions run from frame 0 to
frame 1414 of 1601 on the reference and 0 to 842 of 865 on the attempt.

The difference is how big the climber is in frame. **Torso is 194–204 px here
against 56–76 px on the old fixtures** — roughly 3×, from 1080×1920 instead of
720×1280 plus a closer tripod. Vision's wrist confidence is a function of
apparent limb size, and the old fixtures sat below whatever threshold that is.

**This does not retract the RTMPose comparison, it scopes it.** RTMPose was
better on `user.mov` and that measurement stands. What changes is the urgency:
the tracker was never the reason this project could not produce moves, on
footage framed like this. Framing was. That belongs in `capture-protocol.md` as
a hard requirement, not a preference.

Jitter confirms the same story. At-rest frame-to-frame movement during a
detected contact:

| | median | p90 | max |
|---|---|---|---|
| wrists | 0.40–0.46 px | ~1.2 px | 4.2–11.0 px |
| ankles | 0.33–0.53 px | ~1.2 px | 3.2–4.9 px |

Against a ~23 px toe roll at this framing, that is a signal-to-noise ratio of
about 50×, against 15–30× before.

## The arête does not defeat registration

The route climbs a corner where two wall faces meet, and both climbers use holds
on both faces. `WallAligner` fits a single homography, which assumes one plane,
so this looked like a problem.

**Measured residual: 0.00012 wall-widths.** The tripod did not move between the
two takes, so the reference→attempt transform is near identity and planarity
never gets tested. The homography is not doing real work on this pair, and it
succeeding here is not evidence that it would survive a moved tripod on a
non-planar wall. That remains untested.

What the non-planar wall *does* affect is unmeasured: wall space is not a flat
metric space across the corner, so a body-length threshold means something
slightly different on each face. No evidence yet that this matters.

## The real bug: hand acquisitions were not tracked per hand — FIXED

19 moves derived from a route that is 8–11 hand moves by eye. The cause was one
line.

`RouteMatcher.handAcquisitions` walked hand contacts in time order and skipped a
contact only when it repeated the **immediately previous** hold in the combined
stream:

```swift
if out.last?.holdID == id { continue }
```

The reference's acquisition list oscillated:

```
211 → hold 7    595 → hold 11    928 → hold 11  ←back
235 → hold 8    626 → hold 12    978 → hold 16
368 → hold 10   687 → hold 11 ←back   1046 → hold 14  ←back
389 → hold 7  ←back   837 → hold 14    1139 → hold 18
                                        1283 → hold 16  ←back
                                        1414 → hold 18
```

**The first explanation written here was wrong and is retracted.** It said this
was two hands on two holds alternating in the stream. The contact dump says
otherwise — every apparent return is the *same hand* re-grabbing the *same*
hold:

```
leftWrist  211-372 → hold 7
rightWrist 368-613 → hold 10
leftWrist  389-564 → hold 7     ← same hand, same hold, 17-frame gap
leftWrist  595-673 → hold 11
rightWrist 626-812 → hold 12
leftWrist  687-888 → hold 11    ← same hand, same hold, 14-frame gap
```

All nine of them, with gaps of 14–59 frames. `ContactDetector` merging exists to
absorb exactly this and misses them because `contactMergeGapFrames` is 8 — 0.27s
at the 30fps working rate, and a shake-out takes longer.

Raising the merge gap is the wrong lever: merging is position-based, and
widening its time window risks swallowing genuine neighbouring holds, which is
the Phase 7 bug in the other direction.

**Fix: a hand's hold persists until that hand goes somewhere else** — not until
its contact ends. A hand that lets go and takes the same hold again has not
moved through the route, however long the gap. Hand *matches* still need live
overlap, since "is the other hand on this hold right now" is the one case that
genuinely depends on when the other hand let go.

Result on the same clip, no threshold changed:

| | before | after |
|---|---|---|
| hand acquisitions | 24 | **13** |
| moves | 19 | **12** |
| hold order | `7→8→10→7→11→12→11→14→11→16→14→18→16→18` | `2→3→5→6→7→8→10→11→12→14→16→18→19` |

Strictly increasing, and 12 lands just above the 8–11 by-eye estimate.

Four tests pin the distinction — re-grip, hand match, genuine return via another
hold, and two hands alternating up a ladder. The genuine-return case is what
per-hand state buys over the simpler "first acquisition of each hold wins" rule,
which cannot express a down-climb at all.

An intermediate version that expired a grip when its *contact* ended scored
**23** moves — worse than the original — because it also treated a 25-frame
re-grip as a new arrival. Recorded because it is the obvious first
implementation and it is wrong.

## Everything in the gym notes cascades from that

`gym-testing/test1/analysis.md` reports "it said i fall, but i did not fall" on
moves 1 and 6. Reproduced, and worse than the note: **seven** moves — 5, 7, 9,
12, 14, 16, 18 — rendered "this is where your go ended", while the same run
reported `fall: none`.

**After the per-hand fix above: two, moves 5 and 8.** Then, after fixing the
classification below: **one**, on move 12, where the attempt genuinely never
reaches the final hold. Ten of twelve moves now carry real analysis instead of
"you didn't get this far".

Three distinct defects, all fixed:

1. **`.truncated` was a per-move local test.** It fired on any move where the
   attempt touched the source hold but not the target, with no global notion of
   where the go actually ended. Two very different things look identical at that
   point: a climber who *skipped* a hold and carried on, and a climber who
   stopped. The segmenter now computes how far along the reference's own move
   list the attempt got, and splits the branch — got past it → `.skippedHold`,
   got no further → `.truncated`.

   The old code also carried `if i < refAcquisitions.count - 2`, suppressing the
   message on the final move. That hid false positives elsewhere by also hiding
   the one true positive. Removed.

2. **A truncated move's attempt range overlapped every later one.** The claim
   that it "ran to the end of the clip" was wrong and is retracted: `attemptEnd`
   is already the last *contact* plus one. The overlap was real, though, and it
   came from having seven truncated moves each claiming everything after their
   own start. With one truncated move there is nothing to overlap.

3. **The copy referenced a fall report that did not exist.** "The fall report
   below is about this move" was emitted unconditionally. It now reads "You
   started this move but didn't finish it." Conditioning it on a fall would mean
   giving `SectionDelta` a fall field to phrase one sentence, which inverts the
   layering — `FallReport` renders on its own when there is one. Truncation does
   not imply a fall.

The by-eye reading of the note — "the app thinks I fell" — was not right, and
the truth was worse: the app did not think anyone fell, and said so, while seven
moves separately announced the go had ended.

Combined result on `gym-testing/test1`, with no threshold touched:

| | before | after |
|---|---|---|
| moves | 19 | **12** |
| "this is where your go ended" | 7 moves | **1**, on the move where it is true |
| moves with real analysis | 5 of 19 | **10 of 12** |
| tests | 72 | **78** |

## Anchor density on a real pair: 10–11 of 13

The number Phase 9 hangs on, computed by matching hand-hold cluster centroids
between the two independently-derived routes (1 BL ≈ 0.104 wall units here):

| reference hand hold | nearest attempt hand hold | distance |
|---|---|---|
| 8 (0.504, 0.588) | 9 (0.506, 0.583) | 0.05 BL |
| 16 (0.396, 0.841) | 18 (0.391, 0.843) | 0.05 BL |
| 18 (0.524, 0.890) | 20 (0.527, 0.889) | 0.03 BL |
| 14 (0.497, 0.815) | 16 (0.489, 0.810) | 0.09 BL |
| 10 (0.574, 0.649) | 12 (0.565, 0.651) | 0.09 BL |
| 7 (0.349, 0.572) | 10 (0.338, 0.565) | 0.13 BL |
| 3 (0.358, 0.368) | 5 (0.362, 0.353) | 0.15 BL |
| 2 (0.659, 0.360) | 3 (0.654, 0.339) | 0.21 BL |
| 5 (0.550, 0.477) | 7 (0.580, 0.481) | 0.29 BL |
| 11 (0.380, 0.732) | 13 (0.399, 0.698) | 0.37 BL |
| 6 (0.422, 0.436) | 8 (0.360, 0.407) | 0.66 BL — marginal |
| 12 (0.509, 0.702) | — | 0.73 BL — no match |
| 19 (0.305, 0.818) | — | 0.86 BL — no match |

**Anchor density ≈ 10/13 to 11/13, so 77–85%.** Two climbers of different
ability used nearly the same holds on this route.

Two readings of that, and both matter:

- **Good for Phase 9's feasibility.** Sequences will be nearly as fine-grained
  as moves here, not a collapse to one sequence over the whole climb. The
  "too few shared holds" risk does not fire on this pair.
- **Deflating for Phase 9's value on this pair specifically.** If both climbers
  use the same holds, grouping by shared holds buys little *on this route*.
  What it still buys is **ordering**: the acquisition oscillation above is
  exactly the non-monotonicity that task 9.4's longest-increasing-subsequence
  rule exists to absorb.

One pair is one pair. A route where the stronger climber genuinely skips holds
is still unshot.

## What this pair did not answer

- **Whether the fix order matters.** The 19 moves and the seven "go ended"
  messages are the *same* bug seen twice. Fixing acquisition monotonicity should
  be attempted before anything else, since the truncation cascade may simply
  stop existing.
- **A moved tripod on a non-planar wall.** Registration was never stressed here.
- **A real fall.** Neither climber fell, so `FallDetector` remains unverified on
  footage, as it has been since Phase 3.
- **A bystander stealing the person box.** A second person is visible at the
  left edge of the reference at ~45s. It did not measurably hurt Vision here —
  torso tracking is 99–100% — but `RTMPoseOnnxExtractor.personBox` takes
  Vision's highest-confidence detection, and that path is untested against this
  clip.
