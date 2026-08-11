# Sendy

An iOS app that compares two videos of the same bouldering route — a stronger
climber's send and your own attempt — and tells you what you did differently.

Film the reference climber with the phone on a tripod. Film your attempt from
the same position. The app aligns the two clips in space and time, splits each
climb into hold-to-hold moves, and produces a per-move breakdown of the
differences in body position, load and timing.

Everything runs on device. There is no backend, no API calls, and no account.

> **Status: research harness, not a product.** The pipeline works end to end on
> real footage. The UI is deliberately plain — system fonts, default controls —
> because the point is to inspect what the pipeline produced, not to look good
> doing it. Numbers on screen beat a nice layout.

## The rule that shapes everything

**Code measures. The model narrates.**

Every quantity — centre of mass, hip distance from the wall, limb load, joint
angles, timing — is computed by deterministic Swift. The language model never
estimates or produces a number. It receives a struct of already-computed
metrics and writes a sentence about them.

That is what makes a small on-device model sufficient, and it is what keeps the
output trustworthy. A code path where a language model produces a number is a
bug.

Two consequences worth stating up front:

- **Comparison is always normalized.** Distances are body-lengths, normalized by
  torso length; load is %bodyweight. There is no height or weight input. A
  heavier or taller climber must not show a "difference" that is purely a
  consequence of their size.
- **Nothing is hardcoded that hasn't been checked against real footage.** Every
  threshold lives in a `TuningConfig` exposed as runtime sliders, because
  defaults are guesses until climbing footage says otherwise, and they need
  correcting on a gym floor without a rebuild.

## How it works

Three problems that look hard have cheap solutions here.

**Finding the holds.** We don't. The reference climber's hands and feet touch
every hold on the route, in order. Cluster the contact points and the route
falls out of the data — no image segmentation, no hold detection model.

**Syncing two climbers at different speeds.** Dynamic time warping over the pose
feature sequence, anchored at hold contacts. Strictly better than a speed
slider, which can only apply one linear rate to a non-linear difference.

**Depth from a straight-on camera.** Limb foreshortening. A segment pointing
toward the camera projects shorter by `cos θ`. Anchored at contact points where
the limb is against the wall, this recovers a usable hip-distance signal from a
single 2D camera. It is the weakest number in the app and it is reported with a
confidence that suppresses it when the geometry is degenerate.

**Comparing climbers who don't do the same moves.** The hard one. A stronger
climber often doesn't do the same moves better — they do *different moves*. So
comparison happens only between holds **both** climbers touched with a hand.
What happens between two such holds is free to differ in move count, in feet,
and in hand order, and that difference is the finding rather than an obstacle to
producing one.

### Pipeline

```
VideoImporter
 └─ PoseExtractor        Apple Vision → [PoseFrame]
    └─ PoseSmoother      1€ filter, per joint
       └─ WallAligner    homography → shared wall space
          └─ ContactDetector    velocity + dwell → [Contact]
             └─ RouteBuilder    cluster reference contacts → Route
                └─ MoveSegmenter        per climber → Beta
                   └─ SequenceBuilder   both betas → [ClimbSequence]
                      └─ TimeAligner    DTW, anchored at sequences
                         └─ MetricsEngine
                            └─ SequenceDelta
                               ├─ FallAnalyzer     → FallReport
                               └─ AnalysisProvider → text
```

Each stage is a value type behind a protocol, pure where possible. `PoseExtractor`
is a protocol specifically so the pose model is a vendor choice rather than a
project risk — `PoseExtractorFactory.register` lets a model that needs a
dependency Core cannot link be supplied from the app target instead, and no
stage downstream knows which model produced the joints it reads.

An RTMPose extractor via ONNX Runtime lived behind that seam for a while and was
removed. It did track wrists better on the original fixtures, but the
measurement turned out to be footage-bound rather than tracker-bound — see the
framing note below — and Vision alone is enough on well-framed clips.

## Build and test

Requires Xcode. On a machine where `xcode-select` points at CommandLineTools:

```bash
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
swift build -c release
swift test
```

The pipeline lives in `SendSociety/Core` and is exposed twice — compiled into
the iOS app target, and as a SwiftPM package so tests and the CLI run on macOS.
**Tests need no video files.** They run on synthetic pose fixtures.

## posecli

The main debugging instrument, and the reason most bugs here got found rather
than guessed at.

```bash
./.build/release/posecli pose      clip.mov --out pose.json    # extract, with a per-joint quality table
./.build/release/posecli segment   pose.json                   # raw contacts → merges → clusters → moves
./.build/release/posecli sweep     pose.json                   # threshold grid
./.build/release/posecli jitter    pose.json                   # noise floor: joint movement while at rest
./.build/release/posecli pipeline  ref.mov attempt.mov         # whole chain, end to end
./.build/release/posecli compare   ref.mov attempt.mov --a-ref … --b-ref …
```

`segment` earns its keep most often — it prints the whole chain with every merge
and its distance, and has isolated a segmentation bug in one command more than
once. `compare` runs the real pipeline once per pose source and diffs everything
through to the sentences a climber would read, which matters because degraded
pose input does not produce degraded-*looking* output: it produces confidently
different output with nothing on screen to indicate lower confidence.

## Notes from real footage

Measured, not assumed:

- **Frame the climber large.** Vision's wrist confidence tracks apparent limb
  size closely — 81% of frames above confidence 0.5 at a ~200px torso, against
  17% at ~60px. No threshold recovers the difference, and contact detection
  depends entirely on wrists. This is the highest-leverage capture variable and
  it costs nothing.
- **Thresholds belong in body-lengths, not frame fractions.** A threshold in
  wall-widths silently depends on how far back the tripod stood.
- **Turn video stabilization off.** It warps the frame per-frame and breaks
  registration.
- **The tripod will move.** The homography step is mandatory, not an
  optimization. Registration recovers a known transform to ~0.0002 wall-widths
  for any plausible nudge and fails at gross re-framing, which is detected and
  surfaced as "re-record" rather than silently analysed.

Climbing footage is not in this repository — the clips show identifiable people
and carry GPS coordinates in their metadata. Nothing in the build or test path
needs it.

## Deliberately out of scope

Hold segmentation from images, outdoor and rope climbing, accounts, cloud sync,
sharing, multi-person detection, live analysis during recording, anything
requiring LiDAR.

## Licence

None yet.
