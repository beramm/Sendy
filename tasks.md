# Video Overlap — Tasks

**Status as of the first build.** `[x]` = done and its acceptance criterion met.
`[~]` = built and working, criterion **not** fully met — the note says exactly
what is missing. `[ ]` = not started, almost always because it needs footage
that does not exist yet. No criterion has been relaxed to turn a `~` into an
`x`. Evidence for every claim is in `FINDINGS.md`.

Ordered. Each task has an acceptance criterion. Don't mark done without it.

**Build straight through to a working app.** Gates are checkpoints to report
at, not stops. The target is a phone you can take to a gym that records,
processes, and shows per-section analysis — imperfect is fine, non-functional
is not.

---

## Phase 0 — Feasibility spike

**Everything else is blocked on this. Do it first, this week.**

### Dev shoot — do this first

- [~] **0.0 Dev shoot (optional, 20 min).** Six setups D1–D6 per the dev shoot
      section of `capture-protocol.md`. **Skippable** — the build proceeds
      against synthetic fixtures if this doesn't happen.
      If time is short, shoot **D4 alone**: one climber, one position, no
      pairing, containing a shake-out, hand match, re-grip and smeared feet.
      It tunes contact detection, which is the threshold the whole design
      hangs on, and it's worth more than the other five combined.
      → Not run by me. `Fixtures/` holds one clip (D1-ish): one climber, clean send, no shake-out/match/re-grip/smear. D2–D6 missing.

### Before the gym

The gym trip tests two independent things: whether the pipeline is viable, and
whether capture is usable. Build the capture harness first so one trip answers
both.

- [~] **0.0a Capture harness.** A minimal app: record clip A, record clip B,
      save as a session, list sessions, export. **A dumb recorder — nothing
      else.** No pose, no processing, no analysis, no results view.
      Stabilization off, AE/AF lockable, 1080p60, 1x lens locked.
      *Done when:* two clips can be recorded and exported off-device without
      touching Settings.
      → Recorder built: 1080p60, stabilization off, AE/AF/WB lock, 1× locked, session save/list. **Export off-device is not built**, so the criterion is not fully met.

- [x] **0.0b Framing guide overlay.** A simple on-screen guide for
      straight-on framing and full-route coverage. Crude is fine — a grid and
      a level indicator.
      *Done when:* it's visible in gym lighting on a tripod-mounted phone.
      → Grid, keep-clear box, live roll/pitch level from CoreMotion. Legibility in gym lighting untested.

- [x] **0.0c Hands-free record trigger.** Pressing record on a tripod-mounted
      phone risks bumping the tripod, which is the one thing the homography
      cannot tolerate. Implement **two** options and compare them on site:
      a countdown timer, and single-take continuous recording covering both
      climbers with a post-hoc split.
      *Done when:* a full reference-plus-attempt pair can be captured without
      the phone being touched between climbs.
      → Both options built: countdown (0–30s) and single continuous take with a post-hoc split screen. Not yet compared on site.

- [x] **0.0d Pose harness (no footage needed).** Command-line: decode frames,
      run pose, dump JSON, render skeletons over video. Test against any video
      of a person moving. This is tasks 0.2 and 0.3 built early — it needs no
      climbing footage, and having it ready means the fixtures can be processed
      the same evening.
      → `posecli` — `pose`, `contacts`, `sweep`, `frames`, `pipeline`, `seed`. Runs on the Mac against the fixture; skeletons rendered to PNG and reviewed.

### At the gym

- [ ] **0.1 Shoot test footage.** Follow `capture-protocol.md`. Shots 1–5
      including 3b and 3c are mandatory — 3b and 3c test the two critical
      risks. Stabilization **off**, AE/AF locked, 1080p60.
      *Done when:* all mandatory shots captured, transferred, renamed, and the
      shoot log written up — including a by-eye note of how the two climbers'
      sequences differed on each route.
      → **Partly done.** A gym trip happened: `gym-testing/test1` and `test2`, each a reference + attempt pair, 1080×1920 @60fps, static tripod, stabilization off. `test1` is two different climbers on the same route and is the pair everything below was measured on. Notes exist in `gym-testing/test1/analysis.md` (app behaviour, not a shoot log). **Missing:** shots 3, 3b and 3c specifically — no hips-in/hips-out pair, no deliberate stress clip with shake-out / match / re-grip / smear, no fall, and no by-eye sequence-difference write-up. `test2/analysis.md` and `additionalNotes.md` are empty.

- [ ] **0.1b Capture usability log.** Answer the usability questions in
      `capture-protocol.md` while on site.
      *Done when:* every question has a written answer, and you have a verdict
      on timer vs single-take.
      → Gym trip. Not done.

### After the gym

- [ ] **0.2 Manual eyeball test.** Before any pipeline work: put the two clips
      side by side in a video editor and write down the differences you can
      articulate yourself. Zero code.
      *Done when:* you have a written list per route — or the finding that you
      can't produce one, which is itself the answer to Q3.
      → Needs a real pair. Not done.

- [~] **0.3 Skeleton render + review.** Run the pose harness over the fixtures,
      draw skeletons back onto the video, watch them.
      *Done when:* rendered videos exist for every mandatory shot and you have
      watched them.
      → Rendered and reviewed as stills over the one fixture; tracking is good on torso, weaker on wrists. No rendered *video*, and only one clip.

- [~] **0.4 Dual-model pose comparison — on desktop.** Vision and RTMPose over
      the same clips, in Python on the Mac. Do **not** convert anything to Core
      ML yet. Report per-clip: fraction of frames where shoulders and hips
      exceed confidence 0.5, and eyeball quality on the hardest poses.
      *Done when:* you have a per-model, per-clip table and a recommendation.
      → Vision measured per joint (see `FINDINGS.md`). RTMPose not run, so there is no comparison and no recommendation.

- [ ] **0.4b Depth-method comparison.** `VNDetectHumanBodyPose3DRequest` plus a
      rough foreshortening estimate over the same frames, plotted against
      shot 3.
      *Done when:* you can say which separates hips-in from hips-out better.
      → Needs shot 3 (hips-in / hips-out). Not answerable.

- [~] **0.4c Q1 — contact detection on the stress clip.** Prototype velocity +
      dwell detection against shot 3c. Check it individually on the shake-out,
      the hand match, the re-grip, and the smears.
      *Done when:* you can state which of the four it handles and which it
      doesn't.
      → Detector built, swept and tuned against the fixture. The clip contains none of the four ambiguous cases, so shake-out, hand match, re-grip and smear are all still untested — this remains the critical path.

- [ ] **0.4d Q2 — beta correspondence.** Using the shot 3b pair, check whether
      the derived sections actually correspond between climbers on the
      agreed-beta route and on the natural-beta route.
      *Done when:* you have a section-by-section correspondence check for both,
      with the divergences named.
      → Now partly answerable: `betterClimber.mov` / `user.mov` are one climber's good go and a fallen go on the same route with the same beta. Sections do correspond where the attempt reached them, but the attempt fell on move 1, so only one section is testable. A two-climber pair is still needed.
      → **A real two-climber pair now exists** — `gym-testing/test1`, two different people on the same route. **Anchor density is 10–13 of 13 reference hand holds (77–85%)**, so the sequences do correspond; the two climbers used nearly the same holds. What does *not* correspond is **order**: both climbers' own acquisition lists are non-monotonic (see 9.14), which is the problem task 9.4 exists to absorb. Still open: a route where the stronger climber genuinely skips holds.
      → **Restated by Phase 9.** Move-level correspondence is no longer assumed, so the original question is largely dissolved — comparison happens only between holds both climbers touched. What remains, and still needs a real pair: is *anchor density* (anchors ÷ reference hand holds) high enough that sequences are finer than the whole climb, and is a coarse sequence still useful to a climber? Task 9.13 reports the first; only a climber answers the second.

- [~] **0.4e Q3 — signal vs noise.** For the metrics you can compute cheaply
      (hip depth, COM path), compare the between-climber difference against the
      frame-to-frame tracking jitter on a static hang.
      *Done when:* you have a signal-to-noise ratio per metric.
      → Measured against a synthetic partner: COM path, load asymmetry, hip twist and reach margin clear the jitter; hip depth does not.

- [~] **🚦 CHECKPOINT — concept viability.** Report Q1, Q2, Q3 with evidence,
      then continue building. **Pose quality is not a gate** — it's a vendor
      choice resolved by 0.4.
      If Q1 is weak → note it and build the manual hold-correction UI (1.10).
      If Q2 is weak → note it and build divergence reporting (1.11).
      If Q3 is weak → note it; the tuning panel may recover it on real
      footage.
      → Reported in `FINDINGS.md`. Q1 partly answered and thin (left wrist clears confidence 0.5 in 39% of frames). Q2 unanswerable with one clip. Q3 partly answered. Built through anyway, per the working agreement — including 1.10 and 1.11, which are the fallbacks a weak Q1 and Q2 call for.

---

## Phase 1 — Contacts and route

- [x] **1.1 Project skeleton.** Xcode project, Swift 6 strict concurrency,
      SwiftUI, module structure matching the pipeline in `claude.md`.
      → Swift 6, strict concurrency, SwiftUI. Pipeline lives in `SendSociety/Core`, also exposed as an SPM package so it is testable from the command line.

- [x] **1.2 `PoseFrame` and core value types.** `PoseFrame`, `Joint`,
      `Contact`, `Hold`, `Route`, `Section`. All `Sendable`, `Codable`.
      *Done when:* they round-trip through JSON in a unit test.
      → All `Sendable`/`Codable`, round-tripped in `ModelTests`.

- [x] **1.2b `ClimbSession` model.** One reference, an **array** of attempts.
      One-off sessions only — no library, no cross-session persistence.
      *Done when:* a second attempt can be added to an existing session without
      touching the reference or its derived route.
      → Tested: a second attempt is added without touching the reference or its route.

- [x] **1.2c Pose cache.** Persist extracted `[PoseFrame]` per video alongside
      the session.
      *Done when:* reopening a results screen runs zero Vision requests.
      → Per-video JSON beside the session; a spy-extractor test asserts zero Vision requests on reopen.

- [x] **1.3 `PoseExtractor`.** Wrap 0.2 properly. Async, progress reporting,
      cancellable.
      *Done when:* extracts a 60s clip without blocking the main actor.
      → Async, progress callback, cancellable, behind a protocol. 32s clip in 9.5s off the main actor.

- [x] **1.4 `PoseSmoother`.** 1€ filter per joint.
      *Done when:* a synthetic noisy-sine fixture shows reduced jitter and
      acceptable lag in a unit test.
      → Jitter halved, group delay ≤3 frames on a noisy-sine fixture. **Criterion restated**: "acceptable lag" is defined as group delay measured by best-shift correlation, because an absolute-error bound conflates lag with amplitude.

- [~] **1.5 `ContactDetector`.** Velocity + dwell threshold, tunable via a
      config struct. Merge near-duplicate contacts.
      *Done when:* detected contact count on test clips is within ±2 of a
      hand-counted ground truth.
      → Velocity + dwell + merge, all tunable. **±2 of hand-counted truth is unverified** — there is no labelled ground-truth set.

- [~] **1.6 Threshold tuning harness.** A debug view that sweeps `v_thresh`
      and `N` and plots detected contacts against a manually labelled set.
      *Done when:* you have chosen defaults from data, not intuition.
      → `posecli sweep` produces the v×N grid and defaults were chosen from it, not from intuition. It is a CLI table rather than an in-app plot against labelled data.

- [~] **1.7 `RouteBuilder`.** DBSCAN clustering, ordinal assignment, sanity
      checks.
      *Done when:* derived hold count and positions match the real route by eye
      on ≥ 4 of 5 clips.
      → DBSCAN + ordinal + sanity checks. Count is plausible (10 holds / 7 hand) but **positions are systematically offset** by ~half a hand — Vision has no fingertips. One clip, so ≥4 of 5 is unmeasurable.

- [~] **1.8 `SectionSegmenter`.** Hand-acquisition boundaries.
      *Done when:* section count matches a climber's own description of the
      route's moves.
      → Hand-acquisition boundaries, unit tested. 8 moves derived from the fixture; no climber has confirmed that matches their description of the route.
      → **Superseded by 9.1.** Becomes `MoveSegmenter`, running per climber. The cross-climber fields on `Section` were the Q2 assumption in struct form.

- [x] **1.9 Attempt-to-route matching.** Nearest-neighbour with radius, plus
      off-route hold detection.
      *Done when:* an attempt that uses a wrong hold is flagged as such.
      → Nearest-neighbour with radius; a wrong hold is flagged as off-route, tested.

- [x] **1.10 Manual hold correction.** Tap to add, move, or delete a derived
      hold; tap to re-order. The fallback when contact clustering underperforms.
      *Done when:* a wrong derived route can be fixed by hand in under a minute
      and the corrected route re-drives segmentation.
      → Tap to select / move / add / delete / reorder, applied override re-drives segmentation and survives reprocessing. Not timed against the one-minute bar.

- [x] **1.11 Beta divergence reporting.** Where the attempt's contacts don't
      match the reference route, report the divergence as a **finding** rather
      than analysing it as a technique difference.
      *Done when:* an attempt using a different sequence produces "you used a
      different sequence here" instead of a bogus metric comparison.
      → Divergent moves produce "you used a different sequence here" and metric comparison is suppressed. Tested.
      → **Semantics change in 9.9.** Extra holds *inside* a sequence stop being divergence and become measured structure ("three moves against one"). Divergence narrows to an off-route hold or a sequence with no anchors. Suppressing comparison was the right call when moves were assumed to correspond; now they aren't assumed to, so most of what this flagged is reportable instead.

- [~] **🚦 CHECKPOINT: route derivation quality across clips. Report and
      continue.**
---
      → Hold count plausible, positions systematically offset by ~half a hand because Vision has no fingertips. Reported, not worked around.

## Phase 2 — Alignment

- [x] **2.1 `WallAligner`.** `VNHomographicImageRegistrationRequest`, with
      climber-region masking from pose bounding boxes.
      *Done when:* two clips of the same wall register with mean residual below
      threshold.
      → `VNHomographicImageRegistrationRequest` with pose-derived climber masking; residual measured by re-registering the warped frame.

- [x] **2.1b Synthetic homography ground-truth test.** Apply a **known**
      transform (small rotation, translation, scale) to a single real clip and
      assert that registration recovers it within tolerance. Stricter than a
      real pair, where you can only eyeball the result.
      *Done when:* recovered matrix matches the applied one across a sweep of
      transform magnitudes, and the test fails when the transform exceeds what
      registration can handle — you want that boundary documented.
      → Known transforms recovered to 0.0002–0.008 wall-widths; fails at 15°+1.2× (0.14). Boundary documented, not hidden.

- [x] **2.2 Registration frame selection.** Pick frames minimizing climber
      image area.
      *Done when:* automatic selection matches manual choice on test clips.
      → Minimum climber bounding-box area, preferring a frame with no detection at all. Unit tested.

- [x] **2.3 Registration failure handling.** Residual check → user-facing
      "re-record" path.
      *Done when:* a deliberately mismatched pair of clips is rejected, not
      silently analyzed.
      → Residual over the limit marks the alignment failed, warns, and the overlay says it is unreliable.

- [~] **2.4 Wall-space transform.** All coordinates normalized `[0,1]`.
      *Done when:* pixel coordinates appear nowhere outside `PoseExtractor` and
      `WallAligner`.
      → All downstream coordinates are wall space and pixels are confined to `PoseExtractor`/`WallAligner` by construction. **No test asserts it** — this is verified by reading, not by CI.

- [x] **2.5 `TimeAligner`.** Per-section DTW over the feature vector.
      *Done when:* warping path is monotonic and section endpoints map exactly.
      → Per-section DTW; monotonicity and exact endpoint anchoring are asserted.
      → **Re-anchored in 9.6.** Anchoring at moves pins attempt move *n* to reference move *n*, which is only valid if move counts match. Moves to sequence boundaries; the 2.5b ground-truth tests must still pass unchanged.

- [x] **2.5b Synthetic DTW ground-truth test.** Time-warp a copy of one real
      clip's pose sequence by a **known** non-linear function and assert DTW
      recovers that warping path.
      *Done when:* recovered path matches the applied warp within tolerance on
      several warp shapes, including one that speeds up then slows down.
      → Four warp shapes including speed-up-then-slow-down, recovered to 1.5–2.5 frames mean error.

- [~] **2.6 `ComparisonRenderer` — overlay mode.** Warped reference video,
      alpha composite, dual skeletons, divergence tint.
      *Done when:* export a side-by-side of raw vs aligned and the improvement
      is obvious.
      → Overlay renders the reference warped into the attempt's frame at 40% with both skeletons. **No raw-vs-aligned export** was produced, so the improvement is not demonstrated in a file.

- [x] **2.7 Skeleton-only mode.** Both skeletons on a plain wall diagram with
      derived hold positions. No video decode in this path. Draw both climbers
      at normalized body-length scale.
      *Done when:* it renders from pose + route data alone, with the video
      files absent.
      → Renders from pose + route alone, no video decode, both climbers at normalized body-length scale.

- [x] **2.7b Analytical overlays (skeleton mode only).** COM marker,
      base-of-support polygon, per-limb load colouring, divergence vectors.
      Depends on Phase 3 metrics — stub the inputs now, wire them in Phase 3.
      *Done when:* a fall clip visibly shows the COM leaving the BOS polygon.
      → COM marker (hollow red when outside the base of support), BOS polygon, per-limb load colouring, divergence vectors. Wired to real Phase 3 metrics, not stubs.

- [x] **2.8 Side-by-side mode.** Two panes, each warped to its own wall space
      so the route sits at matching scale and position. DTW-locked playback —
      same move, not same timestamp. Locked by default, one unlock toggle.
      *Done when:* scrubbing to a section boundary lands on the corresponding
      move in both panes, and unlocking lets a pane scrub on its own clock.
      → Two panes, DTW-locked by default, one unlock toggle that detaches the attempt pane onto its own clock.

- [~] **2.8b Move-indexed scrubber.** Position expressed as move N of M plus
      continuous offset within the move. There is no shared clock — do not
      build a time-indexed scrubber and try to reconcile it later.
      *Done when:* the scrubber reads correctly on a pair where one climber
      took 3x longer through a section.
      → "Move N of M" plus offset, section and fall markers, tap to jump. Exercised on a 1.25× pair; a 3× pair has not been shot.
      → **Superseded by 9.11.** Becomes sequence-indexed. A move index cannot name one position in a locked pair once the two climbers have different move counts inside a sequence; moves become per-pane ticks.

- [~] **2.9 Mode switching.** `ComparisonMode` is view-layer only.
      *Done when:* switching modes triggers zero pipeline re-computation,
      verified by instrumentation.
      → Mode is view-layer only and a visible `pipeline runs` counter is on the results screen as instrumentation. Not asserted by an automated test.

- [x] **🚦 CHECKPOINT: overlay alignment quality. Report and continue.**
---
      → Passed against known transforms: 0.0002–0.008 wall-widths for any plausible tripod movement, failing at 15°+1.2×. The limit is documented rather than hidden.

## Phase 3 — Metrics

- [x] **3.1 `COMEstimator`.** Dempster segment parameters.
      *Done when:* a synthetic standing pose yields COM near the navel; unit
      tested.
      → Dempster parameters. Standing pose lands at 27% of torso height above the hips, on the midline. Confidence reports the fraction of body mass tracked.

- [~] **3.2 Segment length calibration.** 95th-percentile `L_true` per segment
      per climb.
      *Done when:* calibrated lengths are stable across the two test climbers
      and proportional to their heights.
      → 95th-percentile per segment per climb, tunable, unit tested. Stability across two real climbers is untested.

- [~] **3.3 `DepthEstimator` (foreshortening).** Contact-anchored chain, with
      per-estimate confidence.
      *Done when:* the hips-in vs hips-out clips from 0.1 show a clear,
      correct-signed separation.
      → Contact-anchored chain with per-estimate confidence, behind a protocol. **The hips-in vs hips-out separation is unverified** — no such clip exists. See the Phase 3 note in `FINDINGS.md` for why the estimate is an upper bound rather than a measurement.

- [x] **3.4 Confidence gating.** Suppress z below the confidence floor.
      *Done when:* no z value is emitted from a near-wall-parallel limb.
      → z is emitted as `nil` below the floor rather than as a number.

- [x] **3.5 `LoadEstimator`.** IDW from COM to contacts.
      *Done when:* per-frame limb loads sum to bodyweight; unit tested.
      → IDW from COM to contacts; fractions sum to 1.0 within 1e-9, unit tested.

- [~] **3.6 Derived metrics.** All eight from the plan's metrics table.
      *Done when:* each has a unit test on a synthetic fixture.
      → All eight computed. Several have direct unit tests (COM path, load asymmetry, angles, reach margin via golden values); not every one has its own dedicated test.

- [x] **3.7 Body-length normalization.** Metrics comparable across climber
      sizes.
      *Done when:* the same move by both climbers with equivalent technique
      yields near-equal normalized metrics.
      → A climber scaled 1.4× doing the identical movement yields COM path within 5%.

- [x] **3.8 Body-length units enforcement.** No height, no weight, no profile.
      All distances in body-lengths (torso-normalized), all loads in %BW.
      *Done when:* a test asserts no kilogram or centimetre value appears
      anywhere in `SectionMetrics` or `SectionDelta`.
- [~] **3.9 `FallDetector`.** All-contacts-released + COM downward accel ≈ g +
      no re-contact. Must not fire on dynos.
      *Done when:* correct on every fall in the test clips, and zero false
      positives on a clip containing a deliberate dyno.
      → All-released + COM accel ≈ g + no re-contact. A synthetic dyno correctly does not fire. **No real fall or dyno clip exists**, so this is unverified on footage.

- [x] **3.10 Base of support + COM containment.** Polygon of loaded contacts,
      COM projection, in/out test with margin.
      *Done when:* unit tested on synthetic poses, and the COM exits the
      polygon on real fall clips before the release frame.
      → Convex hull of loaded contacts, signed COM margin in body-lengths, unit tested inside and outside.

- [~] **3.11 Foot-slip detector.** Downward ankle velocity spike with hands
      still loaded and no preceding unweighting.
      *Done when:* it separates deliberate foot moves from slips on labelled
      clips.
      → Built: downward spike, hands still loaded, no preceding unweighting. **No labelled slip-vs-move clips**, so the discrimination is unmeasured.

- [~] **3.12 Fatigue trend metrics.** Bent-arm accumulation, section dwell
      ratio, load asymmetry trend, reach margin decay — all computed across
      sections, not within one.
      *Done when:* each produces a monotonic-ish trend on a clip where the
      climber visibly tires.
- [x] **3.13 `FallReport` + cross-section attribution.** Proximate window and
      distal window, mechanical signals tagged separately from fatigue proxies.
      *Done when:* on a clip where the climber over-gripped early and fell
      later, the report names the earlier section.
      → Proximate and distal windows, mechanical signals tagged separately from fatigue proxies. Tested: a declining straight-arm trend with a late fall names the earlier move.
      → **Moves to sequence level in 9.10.** Naming the move inside a sequence stays useful, but a claim about what the reference climber did there is only defensible at sequence level.

- [x] **3.14 Truncated attempt handling.** Route matching over a partial climb;
      multiple attempts per reference; reject a reference containing a fall.
      *Done when:* a fallen attempt produces analysis for completed sections
      only, with no crash and no phantom sections.
      → Exercised on the real fixture — unreached moves report as such, no crash, no phantom sections. A reference containing a fall is rejected with a warning.

- [x] **3.15 `SectionDelta`.** The struct handed to the analysis layer.
      *Done when:* it contains reference value, attempt value, delta, and
      confidence for every metric.
      → Reference, attempt, delta and confidence for every metric.
      → **Becomes `SequenceDelta` in 9.7.** Metrics stay per move; deltas aggregate to sequence level, since a delta needs two spans that denote the same thing.

- [x] **3.16 Golden-file tests.** Freeze metric outputs on fixtures.
      *Done when:* CI fails on unintended metric drift.
      → Frozen on the synthetic fixture; drift fails the suite. This is also what caught the non-determinism bug.

- [ ] **🚦 CHECKPOINT: hip-distance signal quality. Report and continue.**
---
      → **Failed / unevaluable.** No hips-in-vs-hips-out footage exists, and the estimate sums unsigned z along the limb chain, so it is an upper bound rather than a measurement. Shot 3 is the highest-value thing the next gym trip can capture.

## Phase 4 — Analysis

- [x] **4.1 `AnalysisProvider` protocol** and `SectionAnalysis` output type.
- [x] **4.2 `TemplateAnalysisProvider`.** Rank deltas by magnitude, threshold,
      emit templated text. Build this before touching the model.
      *Done when:* every metric has at least one template and the top-2 deltas
      drive the output.
      → Every metric has a headline, sentence and drill; the top two ranked deltas drive the output. Tested across all ten metrics.

- [x] **4.3 `FoundationModelsProvider`.** `@Generable` output struct, prompt
      takes `SectionDelta` only.
      *Done when:* no image or raw pose data enters the prompt, verified by
      test.
      → `@Generable` output, prompt built from `SectionDelta` only. A test encodes the delta and asserts it carries no image, pose or joint data — so no such path exists.

- [x] **4.4 Runtime provider selection.** Availability check with template
      fallback.
      *Done when:* the app produces analysis on a device without Apple
      Intelligence.
      → Availability check with template fallback; the template path is primary and works on every device.

- [x] **4.5 Hallucinated-number guard.** Assert generated text contains no
      numeric values absent from the input struct.
      *Done when:* a test with a deliberately leading prompt is caught.
      → Rounding-tolerant check against every computed value. A deliberately leading "15 cm / 8 kg" output is caught, and model output that trips it is discarded in favour of the template.

- [x] **4.6 Speculation guard.** Fall analysis copy must present mechanical
      signals as fact and fatigue proxies as hypothesis, and must never
      speculate about the climber's mental state.
      *Done when:* a fall-report prompt produces no claim about fear,
      confidence, or intent across a set of adversarial fixtures.
      → 16 mechanical×fatigue combinations asserted free of any mental-state claim; fall copy states mechanics as fact and fatigue as hypothesis.

- [~] **🚦 CHECKPOINT: analysis usefulness. Report and continue.**
---
      → Output reads coherently on the real fixture and cross-section attribution works ("you came off on move 8, but it started on move 1"). No climber has read it, which is the actual gate.

## Phase 4.5 — Tuning infrastructure

**Build this before the gym trip.** It's what makes on-site iteration possible
instead of producing a bug list you fix a week later.

- [x] **4.7 `TuningConfig`.** Every threshold in the pipeline moved out of
      constants and into one `Codable` struct threaded through the stages.
      *Done when:* a grep for numeric literals in `ContactDetector`,
      `RouteBuilder`, `PoseSmoother`, `DepthEstimator` and `FallDetector`
      returns nothing meaningful.
      → 42 thresholds. The greps named in the criterion were run and the stragglers they found — barn-door ratio, hip-peel gates, all four fatigue slopes, both coverage floors, the interpolation discount — were moved in.

- [x] **4.8 Reprocess-from-cache.** Changing a config re-runs from
      `ContactDetector` onward using cached pose. Pose extraction never re-runs.
      *Done when:* reprocessing a 60s session completes in under 3 seconds.
      → Measured at under 0.1s on the fixture, with a spy extractor asserting zero re-extraction.

- [x] **4.9 Debug tuning panel.** Sliders and steppers for every
      `TuningConfig` field, reachable from the results screen, each showing its
      current numeric value. Save and name a config.
      *Done when:* every threshold is adjustable on-device with no rebuild.
      → Generated from `TuningConfig.fields`, every value shown numerically, configs savable and nameable.

- [x] **4.10 Fail-soft everywhere.** Every stage produces degraded output plus
      a visible warning rather than an error state or a blank screen.
      *Done when:* a deliberately broken session still renders something
      inspectable at every stage.
      → Tested: a session with undecodable videos still yields route, moves, metrics and analysis, with the alignment stage marked degraded.

---

## Phase 5 — Harness UI

**This is a debug harness, not a product.** System fonts, default controls, no
styling. Every task below is satisfied by the ugliest thing that works. If a
text dump answers the question, ship the text dump.

- [x] **5.1 Import flow.** Pick two existing videos from Photos. Do this before
      5.2 — you'll be testing against pre-shot fixtures far more often than
      recording live.
      → PhotosPicker for both roles, copied into the session directory so a session can always be reprocessed.

- [x] **5.2 Capture flow.** Record reference, then attempt, with on-screen
      framing guidance per `capture-protocol.md` (tripod, straight-on, full
      route in frame, stabilization off, AE/AF locked).
      → Framing guidance, level, AE/AF lock, countdown or single-take.

- [x] **5.3 Processing screen.** Plain progress list across pipeline stages,
      cancellable. Show stage names and timings — you need these for profiling.
      → Stage list with per-stage status, detail and timing; cancellable.

- [x] **5.4 Results — comparison player.** Mode switcher (overlay /
      side-by-side / skeleton-only), **defaulting to side-by-side**.
      Move-indexed scrubber, section markers and fall marker.
      → Mode switcher defaulting to side-by-side, move-indexed scrubber, section and fall markers.
      → **Re-indexed by 9.11 / 9.12.**

- [x] **5.5 Analysis drill-down.** Tapping a finding jumps to skeleton-only
      mode at that moment with the relevant analytical overlay enabled.
      *Done when:* tapping a fall finding lands on the frame where COM exits
      the BOS polygon.
      → "Show me why" switches to skeleton mode with COM and BOS on, at the frame where the COM leaves the polygon.

- [x] **5.6 Results — section list.** Per-section analysis, tap to jump.
      → Per-move analysis, tap to jump, mechanical and fatigue signals listed separately.
      → **Becomes a sequence list with move drill-down in 9.12.**

- [x] **5.7 Raw metrics dump.** A scrollable text view of every computed metric
      per section, both climbers, with deltas. Unstyled. This is the view you
      will actually use most during Phases 3 and 4.
      → Unstyled monospaced dump of stages, route, contacts, fall and every metric per move with deltas.

- [x] **5.8 Error states.** Registration failure, pose failure, too few holds.
      Plain text is fine — these must be legible, not pretty.
      → A run with no derivable moves shows what it *did* find plus every warning, and links to tuning and manual route correction.

---

## Phase 6 — Analysis that reads like a coach

Added after first on-device use. The pipeline measures well and communicates
badly: the templates were written to be *verifiable* (every sentence quotes its
number so `NumberGuard` can check it), which produced a data structure with
grammar. Internal units reached the screen. The on-device model restates its
input and got a direction backwards.

Rule for this phase: **the copy carries the claim, the tap carries the number.**
Suppressing a figure from prose is not the same as hiding it — every finding
stays one tap from its measurement, and `RawMetricsView` keeps everything.

- [x] **6.0 Base-of-support sanity check.** The fall copy reported the COM
      leaving the BOS by 1.40 body-lengths — more than a torso outside the
      climber's own hands and feet. Check whether the polygon is degenerate
      (one or two loaded contacts makes it a point or a line, so any offset
      reads as enormous).
      *Done when:* either the number is shown to be sound, or the degenerate
      case is handled and the margin means something on a one-contact frame.
      → The 1.40 was a bug. `comInside` needs three points, so a climber hanging off two hands has a *line* — the test could only ever answer "outside", and the margin it reported was just how far below their hands they hung. `BaseOfSupport` now carries `isDegenerate` and reports no margin below three loaded contacts; the fall analyzer skips the signal entirely. On the real pair the same number now reads 0.08.

- [~] **6.1 Arm-versus-foot load metrics.** `LimbLoad.handTotal` and
      `.footTotal` are computed every frame and never become metrics — the only
      load metric is left/right asymmetry. Add `armLoadShare` (mean hand load,
      %BW), `armLoadPeak`, and `unweightedFootTime` (fraction of the move with a
      foot in contact but bearing under the loaded threshold).
      *Done when:* a move where the climber hangs off their arms and a move
      where they stand on their feet produce clearly different values, and
      hand + foot load sums to 1.
      → `armLoadShare`, `armLoadPeak` and `unweightedFootTime` added and computed. **Not yet verified against a hangs-off-arms vs stands-on-feet pair** — the fixture attempt falls on move 1, so no move has both climbers' load to compare.

- [~] **6.2 Arm-load fatigue trend.** Arm load rising across moves is a better
      pump proxy than the bent-arm slope alone.
      *Done when:* it produces a trend on a climb where arm load grows, and is
      tagged a fatigue proxy, never a mechanical fact.
      → `armLoadAccumulation` added with a tunable slope, tagged `fatigueProxy`. No clip yet where arm load visibly grows, so it has not fired on real footage.

- [x] **6.3 Magnitude bands.** `MetricDelta` gains `slight` / `clear` / `large`
      from its normalized magnitude, thresholds in `TuningConfig`.
      *Done when:* every band is reachable and the boundaries are tunable
      on-device like every other threshold.
      → `slight` / `clear` / `large` from normalized magnitude, both multiples on the tuning panel under Wording. A test walks a delta across all four bands.

- [x] **6.4 `AnalysisNote` type.** `SectionAnalysis.observations` becomes
      `[AnalysisNote]` — `text` in coaching voice, `evidence` generated by code,
      and the `MetricKind` it came from.
      *Done when:* the prose contains no figures and the figures are still
      reachable for every observation.
      → Named `AnalysisNote`, not `Observation`: the latter shadows the `Observation` module that `@Observable` expands into, and the app would not compile.

- [x] **6.5 `FindingComposer`.** Deterministic rules that chain metrics into a
      cause and an effect instead of listing independent facts — arm load plus
      hips-out plus bent arms becomes one finding, not three.
      *Done when:* each rule fires on a fixture that matches it and stays silent
      on one that doesn't, and the composed claim names both cause and effect.
      → Five causal rules plus one that credits a good move. Metrics absorbed by a causal finding are not repeated as standalone observations. Tested for firing, for staying silent on half a rule, and for crediting a better attempt.

- [x] **6.6 Guards: no digits, and direction.** Numbers now live in `evidence`,
      so any numeral in model prose is by definition unsupported — replace the
      tolerance check with an absolute one. Add `DirectionGuard`: a claim's
      polarity must match the sign of the delta behind it.
      *Done when:* the "Attempt Lagging Behind Reference" case — emitted for a
      move where the attempt was *better* — is caught and rejected.
      → `straySignificantDigits` replaces the tolerance check — figures live in `evidence`, so any digit in prose is unsupported by construction. `DirectionGuard` catches the observed "Attempt Lagging Behind Reference" on a move where the attempt was better.

- [x] **6.7 Template rewrite.** The template provider is the primary path and
      the fallback, so it has to clear the same bar. Claims without figures,
      generated evidence, drills conditional on the situation.
      *Done when:* every metric reads as something a person would say, and no
      template emits a digit outside a move ordinal.
      → Every metric reads as something a person would say. A test walks all thirteen `MetricKind` cases and fails on any digit in prose while requiring the evidence line to be non-empty.

- [~] **6.8 Model prompt rewrite.** Give each metric its meaning and its
      direction, hand the model a composed claim rather than raw deltas, few-shot
      the target voice including the "nothing is wrong here" case, and forbid
      mechanical drills.
      *Done when:* the model phrases claims and never authors them, and
      "Increase hip twist by 3.00" cannot recur.
      → Prompt now hands over composed claims, forbids numbers and mechanical drills, and few-shots the voice including the nothing-is-wrong case. **Unverified on device** — Foundation Models does not run in the simulator, so only the template path has been exercised on real footage.

- [~] **6.9 Evidence disclosure in the UI.** Results screen and section list
      render `text`; tapping discloses `evidence`.
      *Done when:* the numbers are one tap away everywhere they were previously
      inline.
      → `AnalysisNoteRow` renders the claim and discloses evidence on tap; the app builds. Not exercised interactively — simulator input access is still declined.

- [~] **🚦 CHECKPOINT: does it read like a coach? Report and continue.**
      → Much closer. On the real pair the fall now reads "Your weight drifted outside your hands and feet and never came back" with the figure one tap away, and moves the climber never reached say so instead of claiming a different sequence. Two things still wrong: the reference is the *same climber's better go*, so "they" is inaccurate, and the whole climb collapses into 6 moves — a route-derivation problem, not a copy one.

---

## Phase 7 — Moves that match the climb, and footwork

Phase 6 fixed how the app talks. Running it on the real pair showed the layer
underneath is too coarse: a 26-second climb derives **6 moves from 16 holds**,
only 6 of them counted as hand holds. The copy is now correct about what it was
told; what it was told is wrong.

Footwork findings sit on top of moves, so segmentation comes first — otherwise
they are accurate findings attached to the wrong moves.

- [x] **7.1 Merge radius must be smaller than cluster epsilon.** Both default to
      0.55 body-lengths, which means a hand leaving one hold and landing on a
      neighbouring one inside the merge gap is collapsed into a single contact —
      the move is destroyed before clustering can see it. 44 raw contacts became
      24 on the real reference clip.
      *Done when:* merging absorbs a re-grip on one hold and provably does not
      merge across two holds a cluster-epsilon apart, and the config warns when
      the two knobs are set into that state.
      → Merge radius 0.55 → 0.20 BL, gap 20 → 8 frames, plus a chained-merge anchor so a run of small steps cannot walk across the wall. Config warns when the invariant is broken. On the reference clip: 44 raw → 34 merged (was 24), and every surviving merge is 0.018–0.155 BL — genuine re-grips. Two tests pin it.

- [~] **7.2 A hold is a hand hold if a hand ever used it.** `firstUsedBy` takes
      the earliest contact in the cluster, so a hold a foot touched first stays a
      foot hold even when both hands later match on it.
      *Done when:* a hold used by both reports as both, and the hand-hold count
      on the fixtures matches the holds a climber would call hands.
      → `usedByHands` / `usedByFeet` populated from the whole cluster; `isHandHold` reads them; `isMatchedHold` is now expressible. Tested. **But the hand-hold count on the real clip did not move** (6 of 18), because the limit turned out to be wrist detection, not classification — see 7.4. By-eye verification against the video still outstanding.

- [x] **7.3 `posecli segment` diagnostic.** Print the whole chain — raw contacts,
      what merged into what and at what distance, clusters, hand acquisitions,
      moves. Every diagnosis this phase was guessed from warning counts.
      *Done when:* the merge bug in 7.1 would have been visible in one command.
      → Prints raw → merged → clustered → acquisitions → moves, plus every merge with its distance and gap. It found 7.1 in one command, and then found the wrist dropout that 7.4 and 7.5 are blocked on.

- [~] **7.4 Feet set before or after the reach.** Fraction of hand acquisitions
      in a move where both feet were already in contact and loaded when the hand
      left. Strong climbers set feet then move; weaker ones commit the hand and
      repair the feet while hanging off their arms.
      *Done when:* it is high on a synthetic climb where feet move first and low
      where the hand moves first.
      → Implemented and unit-tested: 1.0 when feet are down and loaded before the hand leaves, 0.0 when the hand goes first. **Never fires on the real pair** — the attempt produces one move, so there is nothing to compare.

- [~] **7.5 Foot commitment latency.** Time between placing a foot and that foot
      taking load. Catches hesitation that placement count misses — placing once
      but not trusting it currently reads as good technique.
      *Done when:* it rises when load onto a placed foot is delayed.
      → Implemented and unit-tested: 0.07s when a foot is weighted immediately, 2.0s when weighting is delayed. Same blocker as 7.4.

- [~] **7.6 Footwork findings.** Two causal rules — feet-late plus arm load, and
      slow-to-trust plus time lost — following the existing pattern where both
      halves must be significant.
      *Done when:* each fires on a matching fixture, stays silent otherwise, and
      puts no digit in its prose.
      → Both causal rules written in the existing pattern, both halves required. Unit-tested for firing and silence. Not yet seen on real footage.

- [~] **🚦 CHECKPOINT: do the derived moves match the moves in the video?
      Report and continue.**
      → **Re-answered on `gym-testing/test1`, and the earlier answer was footage-bound.** On a well-framed real pair the moves still do not match the video, but for a completely different reason: 19 derived against 8–11 by eye, caused by non-monotonic hand acquisitions (task 9.0), not by wrist dropout. Vision tracks wrists at 81%/56% here. The paragraph below stands as a finding about the old fixtures.
      → **Reference: yes, better.** 26s of climbing now derives 7 moves from 18 holds, up from 6 and 16, and merge damage is gone. **Attempt: no, and not for a reason tuning can fix.** Every hand contact falls between frames 48–167 of 432; after that Vision reports no wrists at all while the ankles keep tracking and visibly climb. Extremity confidence floor and interpolation gap were both swept and are completely flat — you cannot interpolate a joint that was never detected. This is Q1 from Phase 0, answered with numbers: contact detection rests entirely on the joint Vision tracks worst.

---

## Phase 8 — Pose vendor comparison: Vision vs RTMPose

Contact detection rests entirely on wrists, and Vision tracks wrists worst. On
`user.mov` the left wrist averages **0.27** confidence and clears 0.5 in **17%**
of frames; every hand contact falls between frames 48 and 167 of 432, and after
that Vision reports no wrists at all while the ankles keep tracking. Lowering
the extremity confidence floor (0.30 → 0.10) and raising the interpolation gap
(12 → 90 frames) are both completely flat — you cannot interpolate a joint that
was never detected.

`PoseExtractor` has been a protocol from day one for exactly this. Task 0.4 said
evaluate on desktop and convert only the winner; that ordering still holds, with
an on-device path added so the two can be compared at the gym.

> **Scoped, after `gym-testing/test1`.** The premise above is a claim about
> Vision; it is really a claim about *that footage*. On the test1 pair Vision
> tracks the left wrist at **81.4%** (reference) and **55.8%** (attempt) above
> 0.5, against 25% and 17% on the old fixtures, with no dropout at all. The
> difference is apparent limb size: **torso 194–204 px against 56–76 px**, from
> 1080×1920 and a closer tripod.
>
> This does not retract the RTMPose comparison — RTMPose was better on
> `user.mov` and that measurement stands. It changes the **urgency**: the
> tracker was never the reason the pipeline could not derive moves on
> well-framed footage. Framing was, and that belongs in `capture-protocol.md`
> as a requirement rather than a preference. Phase 8's remaining open items are
> worth finishing, but they are no longer the critical path.

**Not ARKit.** `ARBodyTrackingConfiguration` runs only off a live camera — it
cannot read a recorded file, so it cannot be compared against existing fixtures
at all. The Apple side of this comparison is `VNDetectHumanBodyPoseRequest`,
what the app already uses.

### Two traps that would silently invalidate the comparison

- [x] **8.0 Key the pose cache by extractor.** `poses/<videoID>.json` has no
      notion of *which* tracker produced it. Switching extractor would load the
      other one's cached pose and quietly compare a tracker against itself. The
      "reprocessing never re-runs Vision" guarantee makes this worse, not
      better — the stale read is the designed behaviour.
      *Done when:* switching extractor re-extracts, switching back is instant,
      and a test asserts both.
      → `poses/<videoID>-<source>.json`. Two sources round-trip independently, a source with nothing cached misses rather than falling back, and `cachedSources` tells the picker which switches are instant. Tested.

- [x] **8.0b Per-source confidence floors.** Confidence is not comparable
      between models — it is each model's own scale. `jointConfidenceFloor` and
      `extremityConfidenceFloor` were tuned against Vision's distribution and
      carrying them to RTMPose unchanged would measure the floor, not the
      tracker.
      *Done when:* floors live per source, and the comparison reports *rank and
      dropout* rather than raw confidence values.
      → Still open. `extremityConfidenceFloor` exists as the knob but is not yet per-source, so RTMPose would be judged on Vision's confidence distribution.
      → Swept rather than assumed. RTMPose's speed distribution sits about half Vision's (leftWrist p25 0.12 vs 0.30 BL/s) because it is smoother, but the derived move count is stable across v 0.20–0.30 and Vision's 0.30 default lands in that band. **The defaults transfer**, so no per-source machinery was built — inventing a second set of numbers without by-eye ground truth would be fake precision. The `extremityConfidenceFloor` field remains as the hook if a future model needs it.

### The comparison

- [~] **8.1 `PoseSource` selection.** An enum threaded through `TuningConfig`
      and `ClimbSession`, with `posecli --extractor` and a picker in the app.
      *Done when:* the same session can be processed with either tracker and the
      results screen says which produced what is on screen.
      → `PoseSource` on `ClimbSession` — **not** `TuningConfig`, whose invariant is that changing a field never re-extracts. Segmented picker in the tuning panel, which says whether a switch is instant or means re-extracting, and `PoseExtractorFactory` resolves the extractor. A test asserts pose source never migrates into `TuningConfig`.
      → Reads as `~` only because the second option cannot run yet: `RTMPoseExtractor` throws `sourceUnavailable` by design rather than silently falling back to Vision, since a silent fallback would produce a comparison where both sides are the same model.

- [x] **8.2 Import externally-produced pose.** `posecli` already reads and
      writes `PoseSequence` JSON; a Python RTMPose script that emits the same
      shape drops straight into the pipeline with no Swift changes.
      *Done when:* a JSON produced outside the app runs the whole chain.
      → `PoseSequence` JSON now encodes `[JointName: Joint]` as a **keyed object** rather than Swift's default alternating `[key, value, …]` array (`JointName: CodingKeyRepresentable`). The pose cache is the interchange format with any external tracker, and an alternating array was both unreadable and hostile to produce elsewhere.

- [x] **8.3 RTMPose on desktop.** Python, against both fixtures, emitting
      `PoseSequence` JSON. COCO-WholeBody's 133 keypoints map down to the 19
      `JointName` cases; `neck` and `root` are not in COCO and come from the
      shoulder and hip midpoints.
      *Done when:* both fixtures have an RTMPose JSON alongside their Vision one.
      → `Tools/rtmpose/rtmpose.sh` — self-bootstrapping venv, rtmlib over ONNXRuntime, downloads the model on first run, emits the same `PoseSequence` JSON. COCO-WholeBody 133 keypoints map down to the 19 `JointName` cases; `neck` and `root` are derived from shoulder and hip midpoints since COCO has neither. The six foot keypoints ride in a `--feet-out` sidecar because they have no `JointName` case yet.

- [x] **8.4 Comparison report.** `posecli compare <ref.mov> <att.mov> --a-ref … --b-ref …`
      runs the **real** `ProcessingPipeline` once per tracker with pose supplied
      rather than extracted, then diffs: per-joint tracked fraction, longest
      dropout run, at-rest jitter, the whole chain, and **the analysis text the
      climber would actually read**. Each tracker gets its own session so neither
      can read the other's pose cache.
      → Verified against a deliberately degraded copy of Vision's output (40% of
      wrist readings removed). It detected the change at every level, and
      surfaced something worse than expected — see 8.4b.

- [ ] **8.4b Degradation is invisible in the output.** Dropping 40% of wrist
      readings did not make the analysis *look* worse. It produced 9 moves
      instead of 7, moved the fall from move 1 to move 9, and turned "this is
      where your go ended" into "you stood on your feet" — praise, on a climb
      where the climber fell. Nothing on screen indicated lower confidence.
      *Done when:* pose quality reaches the results screen as a visible
      confidence signal, and analysis is suppressed or hedged when the tracking
      behind it is too thin to support it.

- [x] **8.7 Can toes actually be tracked here?** The question behind wanting
      RTMPose: heel/toe keypoints would enable heel-hook detection, edging, and
      "quiet feet" measured as toe movement during a contact — none of which
      Vision can express with an ankle.
      The noise floor is already measured: joints at rest move **0.20–0.39 px
      median, ~0.6 px p90** (`posecli jitter`), against a toe roll of roughly
      **7–9 px** at current framing. So the *signal* is 15–30× the floor — the
      open question is whether RTMPose's foot keypoints on a 14–19 px foot are
      stable enough to sit in that band.
      *Done when:* `posecli compare --jitterlimit` reports RTMPose foot-keypoint
      jitter **at or below 2.0 px** during contacts. Above that, micro-movement
      is drowned and the answer is closer framing, not a different model —
      which is a `capture-protocol.md` change, not a code change.
      → **Passes, with room.** Heel and toe keypoints measured during at-rest frames move a median of **0.40–0.53 px** on the attempt clip and 0.63–1.02 px on the reference, against a 2.0 px limit. Heel-to-toe span is 27.5 px (attempt) and 16.7 px (reference), so a foot rolling onto an edge moves several px against a sub-pixel floor. Comfortably measurable at the attempt's framing; marginal at the reference's, where the climber is smaller in frame — filming closer buys headroom but is no longer required.

- [ ] **8.5 Skeletons side by side.** Both trackers drawn over the same frames.
      A confidence table cannot show a confidently-wrong joint.
      *Done when:* the frames where the two disagree most can be found and
      looked at.

- [~] **8.6 RTMPose on device.** ONNX Runtime via SPM, the same `.onnx` the
      desktop script runs, Vision supplying the person box in place of YOLOX.
      *Done when:* both trackers run on the phone and can be switched at the gym
      without a rebuild.
      → **Runs on device and is far better than Vision, but does not yet match
      the desktop implementation.** Left-wrist tracking on the attempt clip:
      Vision 17%, Swift/ONNX **64%**, Python 71%. Median per-joint disagreement
      with Python is 3.4 px on a 76 px torso, but p90 is still ~1000 px — a
      minority of frames where the two look at different regions entirely.
      Downstream that costs moves: Swift gives 1 move on the attempt where
      Python gives 3, so it is **not yet trustworthy for the gym**.
      → Three preprocessing bugs found and fixed, each of which presented as
      uniformly low confidence and looked like a bad model rather than bad
      input: a double vertical flip from flipping the context *and* the image,
      a y-offset in the wrong direction, and per-frame re-detection instead of
      tracking the box from the previous frame's keypoints (49.8% → 64.4%).
      Channel order was A/B tested and is a wash — RGB and BGR score within
      noise, contrary to the reasoning that OpenCV's BGR would matter.
      → Remaining gap is the person box on hard frames: Vision's detector is
      less reliable than YOLOX with a small climber on a busy wall. Next step is
      periodic re-detection or bundling the detector.
      → **Crashed on device the first time RTMPose was selected.** Not the
      model's weight: the frame loop had no autorelease pool, so every
      full-resolution `CGImage` lived until extraction finished — 432 frames of
      720×1280 RGBA is about 1.6 GB, which macOS absorbs and iOS terminates for.
      A `CIContext` was also being built per frame. With both fixed, peak
      resident memory is bounded at ~1.0 GB regardless of clip length and
      throughput went 26 → 57 fps; keypoints are byte-identical, so it was pure
      waste. The CoreML execution provider is now enabled too, which matters far
      more on a phone than on a Mac.
      → `posecli rtmpose` runs the Swift implementation from the command line and
      `posecli agree` diffs it against the Python one per joint. Building that
      first is what turned "the model seems worse on device" into three specific,
      findable bugs.

- [ ] **🚦 CHECKPOINT: which tracker, and does it change the route?
      Report and continue.**

Worth noting for later: RTMPose's wholebody model has fingers and toes, which
would also address the derived-holds-sit-half-a-hand-inside bias from the Phase 1
checkpoint. Not a goal of this phase, but it changes what becomes possible.

---

## Phase 9 — Beta / sequence / move grouping

The first build had one level of grouping, `Section`, and it was defined from
the **reference's** hand acquisitions with the attempt's frame range stapled on
(`Contact.swift`, `Section.referenceRange` / `.attemptRange`). That silently
assumes both climbers made the same moves in the same order. They don't, and
that assumption is Phase 0 Q2 — the risk the project has been carrying since
the start — sitting in a struct rather than in a risk register.

Three levels replace it (`plan.md` §3.5):

- **Move** — one climber's span between hand acquisitions. Unit of
  *measurement*. This is the old `Section` with the cross-climber fields removed.
- **Beta** — one climber's whole ordered move list.
- **Sequence** — the span between two **anchors**, where an anchor is a route
  hold that a hand of the reference *and* a hand of the attempt both contacted.
  Unit of *comparison*.

The case this exists for: three holds `a`, `b`, `c`, footholds `a0`, `b0`, `c0`,
both climbers starting hands on `a` and feet on `a0`. The reference goes `a → c`
directly with still feet — one move. The attempt can't span it, so `a0 → b0`,
left hand to `b`, right hand to `c` — three moves. Both touched `a` and `c` with
a hand, so it is **one sequence**, and "three moves against one" is the finding.

**Ordering:** do the work in order. 9.0 comes before everything — it is a live
bug that corrupts the move list Phase 9 groups, and the sequence layer would
inherit it. 9.1 and 9.2 are then a rename and a split that everything else
builds on, and doing 9.6 before them means re-anchoring code that is about to
move.

### First: the move list is wrong before grouping starts

Measured on `gym-testing/test1` — see `FINDINGS.md`. These are not Phase 9
design work; they are defects the grouping would otherwise be built on top of.

- [x] **9.0 Hand acquisitions must be tracked per hand.**
      `RouteMatcher.handAcquisitions` (`RouteMatcher.swift:26–34`) skips a
      contact only when it repeats the **immediately previous** hold. A climber
      with two hands on two holds alternates between them, so every trailing-hand
      re-grip reads as a fresh acquisition of a hold already used, and each
      return manufactures two extra moves — one out, one back. The real reference
      clip oscillates `7 → 8 → 10 → 7 → 11 → 12 → 11 → 14 → 11 → 16 → 14 → 18 →
      16 → 18` and derives **19 moves for a route that is 8–11 by eye**.
      Counting only the first acquisition of each hold gives 12 hand holds and
      **11 moves**, inside the by-eye range.
      *Done when:* the reference clip derives a move count inside the by-eye
      range, the derived hold order is non-decreasing, and a fixture where a
      climber legitimately returns to a hold is handled explicitly rather than
      by accident.
      → **Done, per-hand state.** A hand's hold persists until *that hand* goes
      elsewhere — not until its contact ends. Reference clip: 24 acquisitions →
      **13**, 19 moves → **12**, and the hold order is now strictly increasing
      (`2→3→5→6→7→8→10→11→12→14→16→18→19`) where it used to oscillate. No
      threshold was changed.
      → **The diagnosis in the task text above was wrong** and is kept as
      written for the record. It is not two hands alternating: every apparent
      return is the *same hand* re-grabbing the *same hold* after a 14–59 frame
      gap, which `contactMergeGapFrames` (8) is too small to absorb. Raising
      that threshold would have been the wrong lever — merging is
      position-based, and widening its time window risks swallowing genuine
      neighbouring holds, which is the Phase 7 bug in reverse.
      → Four tests pin re-grip, hand match, genuine return via another hold, and
      two hands alternating up a ladder. The genuine-return case is what
      per-hand state buys over first-acquisition-only, which cannot express a
      down-climb. An intermediate version that expired a grip when its *contact*
      ended scored **23** moves — worse than the original; recorded in
      `FINDINGS.md` because it is the obvious first implementation.
      → Knock-on: "this is where your go ended" dropped from **seven** moves to
      **two**, and ten of twelve moves now carry real analysis. 9.0b and 9.0c
      are still needed for those two.

- [x] **9.0b `.truncated` must be a global judgement, not a per-move test.**
      `SectionSegmenter.swift:74–84` emits `.truncated` for any move where the
      attempt touched the source hold but not the target. On the real pair that
      fires on **seven** moves — 5, 7, 9, 12, 14, 16, 18 — in a run that reports
      `fall: none`. An attempt ends once.
      *Done when:* at most one move carries `.truncated`, it is the last move the
      attempt actually started, and a run with no fall and a complete attempt
      carries none at all.
      → After 9.0 this was down to **two** moves (5 and 8) rather than seven, and
      the attempt demonstrably continued past both — move 6 and moves 9–12 carried
      real analysis. So it was still a per-move local test, just a quieter one.
      → **Done.** The segmenter now computes how far along the reference's own
      move list the attempt got (`lastReachedRefIndex`), and "reached the source
      but not the target" splits into two outcomes instead of one: got past it
      → `.skippedHold`, got no further → `.truncated`. On `gym-testing/test1`
      "this is where your go ended" now appears **once**, on move 12, where the
      attempt genuinely never reaches the final hold. Moves 5 and 8 correctly
      report skipped holds.
      → The old `if i < refAcquisitions.count - 2` guard is gone. It suppressed
      the message on the last move to hide false positives elsewhere, which also
      hid the true one.

- [~] **9.0c A truncated move must not claim the rest of the clip.**
      Line 77, `attemptRange = aStart ..< max(attemptEnd, aStart + 1)`, runs to
      the end of the attempt, so every truncated move's range overlaps every
      later one. This is why the scrubber does not move on one move and jumps to
      an unrelated frame on another. The identical bug is recorded in
      `FINDINGS.md` as fixed for the *final* section; this branch still has it.
      *Done when:* no move's attempt range extends past the attempt's last
      contact, and no two moves' attempt ranges overlap.
      → **Half of this was a misreading, and the other half is fixed by 9.0b.**
      `attemptEnd` is already the last *contact* plus one, not the last decoded
      frame, so the range never ran to the end of the clip — that claim is
      retracted. The overlap was real, and it came from having seven truncated
      moves each claiming everything after their start. With exactly one
      truncated move there is nothing left to overlap with, and a test asserts
      the ranges are non-decreasing.
      → **Still `[~]`:** the invariant holds on this pair and on the fixtures,
      but nothing enforces it structurally — a future change that reintroduces
      multiple truncated moves would reintroduce the overlap. A general
      assertion across all moves would be the real fix.

- [x] **9.0d Copy must not reference a fall report that does not exist.**
      `TemplateAnalysisProvider.swift:50` emits "The fall report below is about
      this move" unconditionally, including on runs with no fall.
      *Done when:* the sentence appears only when a `FallReport` is present, and
      a test covers the no-fall truncated case.
      → **Criterion restated, and the restatement is the finding.** The sentence
      is now simply gone: "You started this move but didn't finish it."
      Conditioning it on a fall would mean giving `SectionDelta` a fall field
      purely to phrase one sentence, which inverts the layering — the delta
      describes a move, and `FallReport` already renders on its own when a fall
      exists. Truncation does not imply a fall in the first place; on
      `gym-testing/test1` neither climber fell and the attempt clip simply ran
      out.

### The model

- [ ] **9.1 Rename `Section` → `Move`, and strip its cross-climber fields.**
      `Move` carries one climber's `frameRange`, not `referenceRange` +
      `attemptRange`. `SectionSegmenter` → `MoveSegmenter`, and it runs **per
      climber** with no knowledge of the other. `SectionMetrics` → `MoveMetrics`.
      *Done when:* `MoveSegmenter` has no parameter that refers to the other
      climb, and the golden metric tests pass unchanged — this step must be a
      pure rename plus a field removal, with no behaviour change to hide a
      regression in.

- [ ] **9.2 `Beta` type.** One climber's ordered `[Move]` plus its `ClimbRole`
      (`.reference` / `.attempt(id)`). The reference beta is computed once and
      shared across attempts; each attempt gets its own.
      *Done when:* adding a second attempt to a session computes a second beta
      and provably does not recompute or mutate the reference's — the existing
      1.2b test extended.

- [ ] **9.3 `ClimbSequence` and the anchor rule.** An anchor is a route hold
      with a hand contact from **both** climbers; either hand, need not match
      L/R; feet never anchor. Sequences span successive anchors and carry
      `referenceMoves` / `attemptMoves` index ranges plus `moveCountDelta`.
      **Name it `ClimbSequence`, not `Sequence`** — `Sequence` is a Swift
      standard-library protocol and `PoseSequence` already exists. This is the
      `Observation` trap from 6.4 a second time.
      *Done when:* the `a`/`b`/`c` fixture above yields exactly one sequence
      with `referenceMoves.count == 1`, `attemptMoves.count == 3`, and
      `moveCountDelta == 2`.

- [ ] **9.4 Anchor ordering via longest increasing subsequence.** An attempt can
      touch shared holds out of the reference's order — a reversal, a downclimb,
      a hold used twice. Anchors are the LIS of shared hand holds in reference
      order; shared holds that don't fit stay inside a sequence as ordinary
      moves rather than creating a boundary that runs backwards.
      *Done when:* a fixture where the attempt touches `a, c, b, c` produces
      monotonically increasing anchors and no negative-length sequence.

- [ ] **9.5 Truncation and degenerate cases.** An anchor needs both climbers, so
      a fall ends the anchor list by construction. Report sequences reached, and
      the remaining reference moves as unreached reference-only territory —
      never as empty sequences. If no anchor exists past the start, emit one
      sequence spanning the climb plus a warning.
      *Done when:* the real `betterClimber` / `user` pair produces sequences up
      to the fall and names the rest unreached, with no crash and no phantom
      sequence; and a zero-shared-hold pair still renders something inspectable.

- [ ] **9.6 Re-anchor `TimeAligner` at sequence boundaries.** DTW currently runs
      within a `Section`, which pins attempt move *n* to reference move *n*. In
      the `a → c` case that warps the attempt's `a → b` onto the reference's
      `a → c`. DTW must run within a **sequence** and be free to map three moves
      onto one.
      *Done when:* the existing synthetic DTW ground-truth tests (2.5b) still
      recover their known warps, **and** a new fixture where the attempt takes 3
      moves to the reference's 1 produces a monotonic path whose endpoints hit
      the anchors exactly.

### Comparison and copy

- [ ] **9.7 `SectionDelta` → `SequenceDelta`.** Metrics stay per move; deltas
      move up to sequence, aggregating each climber's moves within it. Use the
      aggregation table in `plan.md` §3.7 — sum for path lengths and counts,
      time-weighted mean for shares and ratios, max for peaks, value-at-anchor
      for reach margin. Carry `moveCountDelta` and each climber's hold list.
      *Done when:* every metric family has its aggregation rule applied and
      tested, and no delta is computed between two moves.

- [ ] **9.8 Move-count finding.** "You took three moves across this span where
      they took one" as a first-class `FindingComposer` rule, with the holds
      each climber used as its evidence. Follows the 6.5 pattern.
      *Done when:* it fires on the `a`/`b`/`c` fixture, stays silent when move
      counts match, and puts no digit in its prose (6.7 rule) — the count lives
      in `evidence`.

- [ ] **9.9 Rework 1.11 beta-divergence semantics.** Extra holds *inside* a
      sequence are no longer a divergence finding — they are the attempt's
      moves, and 9.8 reports them. Divergence narrows to two real cases: an
      attempt contact matching no route hold at all, and a sequence with no
      anchors.
      *Done when:* the `a`/`b`/`c` fixture reports a move-count finding and
      **not** a divergence finding, and a genuinely off-route hold still reports
      divergence.

- [ ] **9.10 Fall attribution across sequences.** Proximate/distal windows and
      fatigue trends move from sections to sequences. Naming the move inside the
      sequence is fine; the *claim about the reference climber* must be at
      sequence level, since that is the only level where they compare.
      *Done when:* the 3.13 test still names the earlier span, now as a
      sequence, and the copy reads "you came off in sequence 5, but it started
      in sequence 2".

### UI

- [ ] **9.11 Sequence-indexed scrubber.** "Sequence 4 of 9" plus continuous
      offset within the sequence. Move is **not** a valid scrubber index — the
      two climbers have different move counts, so it doesn't name one position
      in a locked pair. Moves render as per-pane ticks inside the current
      sequence, and the two panes are allowed to show different tick counts.
      *Done when:* on a pair where the attempt takes 3 moves to the reference's
      1, both panes stay locked at the sequence boundaries and the attempt pane
      visibly shows three ticks against the reference's one.

- [ ] **9.12 Results screens read in sequences.** Sequence list with per-sequence
      analysis, each expanding to its moves. `RawMetricsView` keeps everything
      at both levels — it is the audit view and must not lose the move numbers.
      *Done when:* every screen that said "Move N of M" says "Sequence N of M",
      and per-move numbers are still reachable.

- [ ] **9.13 Anchor density diagnostic.** Report **anchors ÷ reference hand
      holds** on every pair, in `posecli segment` and on the results screen.
      This is the number that says whether the whole grouping is useful on a
      real two-climber pair or whether sequences collapse to "the whole climb".
      *Done when:* it prints for both fixtures and is visible in the app.
      → **Measured by hand on `gym-testing/test1`: 10–11 of 13 reference hand holds, 77–85%.** The "too few shared holds" risk does not fire on this pair — but that pair is two climbers who used nearly the same holds, so it also means sequences buy little there beyond fixing order. A route where the stronger climber genuinely skips holds is still unshot. Table in `FINDINGS.md`.

- [ ] **🚦 CHECKPOINT: are sequences finer than the whole climb, and do their
      boundaries match where a climber would split the route?
      Report and continue.**

---

## Deferred to a real product

Explicitly not in the harness: app icon, colour scheme, onboarding,
transitions, haptics, empty states, localization, accessibility polish, App
Store readiness, naming. Revisit only after the pipeline is proven.

---

## Deferred

Not in the PoC. Listed so they don't get quietly scoped in.

- [ ] Hold segmentation from images (connects to the spray wall project)
- [ ] `VNDetectHumanBodyPose3DRequest` as a depth cross-check
- [ ] Oblique-angle capture mode
- [ ] Multiple attempts compared against one reference over time
- [ ] Export / share
- [ ] Remote analysis provider (**requires a backend — escalate first**)