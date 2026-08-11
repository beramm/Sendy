# Fixtures

**The video is not in this repository.** `.gitignore` excludes it deliberately:
the clips show identifiable people, iPhone writes GPS coordinates into the
QuickTime metadata, and together they run to roughly 350MB against a repository
that is otherwise under a megabyte.

Nothing here is required to build or test. `swift test` runs entirely on
synthetic `PoseFrame` fixtures — 78 tests, no video files touched. Footage is
needed only to *tune* thresholds and to reproduce the measurements in
`FINDINGS.md`.

## What the clips are

| path | what it is | why it matters |
|---|---|---|
| `Fixtures/IMG_4851 2.mov` | 1080×1920, 30fps, 32s. One climber, clean send. | The original dev fixture. Every Phase 0–5 threshold was chosen against it. |
| `Fixtures/betterClimber.mov` | 720×1280, 60fps, 26s. Clean go. | Reference half of the Phase 7/8 pair. |
| `Fixtures/user.mov` | 720×1280, 60fps, 14s. Same climber, same route, same beta, falls. | The clip that exposed Vision's wrist dropout — left wrist above confidence 0.5 in 17% of frames. |
| `gym-testing/test1/{reference,attempt}.mov` | 1080×1920, 60fps, 53s / 29s. **Two different climbers**, same green route up an arête, static tripod. | The first real two-climber pair. Anchor density, the per-hand acquisition bug and the truncation cascade were all measured here. |
| `gym-testing/test2/{reference,attempt}.MOV` | 1080×1920, 60fps, 41s / 58s. | Shot the same session. Not yet analysed. |

## How to obtain them

Ask the repository owner. They are not published anywhere, by design — see
above.

## Shooting your own

Follow `capture-protocol.md`. Two things it does not currently emphasise enough,
both learned from `gym-testing/test1`:

- **Frame the climber large.** Vision's wrist confidence tracks apparent limb
  size closely. Torso at ~200px gives 81% left-wrist tracking; torso at ~60px
  gives 17%, and no threshold recovers it. This is the single highest-leverage
  capture variable and it costs nothing.
- **Keep bystanders out of frame.** One person in shot is an explicit
  assumption. A second person entering frame can capture the person detector,
  which feeds the RTMPose crop.

Stabilization **off**, AE/AF locked, 1× lens, tripod untouched between the two
takes.

## Reproducing the measurements

```bash
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
swift build -c release
./.build/release/posecli pose gym-testing/test1/reference.mov --out .work/ref.json
./.build/release/posecli segment .work/ref.json
./.build/release/posecli pipeline gym-testing/test1/reference.mov gym-testing/test1/attempt.mov
```

`posecli` also has `contacts`, `sweep`, `jitter`, `frames`, `compare`, `rtmpose`,
`agree`, `drift` and `seed`. `segment` is the one that earns its keep most often
— it prints the whole chain from raw contacts through merges, clusters and hand
acquisitions to moves, and has found two segmentation bugs in one command each.
