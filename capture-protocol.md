# Capture Protocol — Phase 0 Gym Shoot

Everything in this project is gated on Phase 0. Phase 0 is gated on this
footage. A bad shoot costs you another gym trip, so read this before you go.

Bring a printed or offline copy — gym wifi is unreliable and you'll need the
shot list on the floor.

---

## Dev shoot — 20 minutes, do this FIRST

Before the real trip, before the build. This footage exists so thresholds get
tuned while each stage is written, instead of guessed and found wrong on a gym
floor. It does not need to be good. It needs to exist.

**Use the stock Camera app.** Don't wait for the capture harness — that's part
of what this footage is for. Settings → Camera → 1080p60, turn off enhanced
stabilization. Long-press to lock AE/AF before each clip. A tripod is ideal but
a phone propped against a bag works, as long as **it doesn't move between the
two clips of a pair**.

Six setups, roughly 20 minutes including faff:

| # | Clip | Why it's in the dev set |
|---|---|---|
| D1 | Climber A, easy route, clean send, whole route in frame | The workhorse. Every stage gets developed against this. |
| D2 | Climber B, **same route, same camera position** | Makes homography, DTW and the whole comparison path testable |
| D3 | Same climber, same move, **hips deliberately in**, then **hips deliberately out**. Exaggerate. | Decides the depth method — a big design branch. 60 seconds to shoot. |
| D4 | One route containing a **shake-out**, a **hand match**, a **re-grip**, and **smeared feet** | Tunes contact detection, the single most important threshold in the project |
| D5 | One fall, and one dyno that sticks | Fall detector plus its false-positive case. Can be two short clips. |
| D6 | 5 seconds of the empty wall, same position as D1 | Clean plate for homography |

Skip everything else — pump-out, tripod bump, adversarial conditions,
resolution comparison, beta-divergence pairs. Those belong to the real trip.

Transfer them the same day, name them D1–D6, and drop them in `Fixtures/`
before starting the build.

---

## Equipment

- Phone + **tripod with a phone mount**. Handheld is not usable — the
  homography step assumes a fixed camera between the two clips of a pair.
- A climbing partner who is meaningfully stronger than you. The whole product
  depends on there being a real technique gap.
- Tape or chalk to mark the tripod's floor position, so you can restore it if
  it gets bumped.
- A notebook or notes app for the shoot log.

---

## Camera settings — get these right or reshoot

| Setting | Value | Why |
|---|---|---|
| **Video stabilization** | **OFF** | OIS and digital stabilization warp and shift the frame per-frame. This silently destroys the homography and you won't notice until Phase 2. Non-obvious and the most likely thing to ruin the shoot. |
| **AE/AF lock** | **ON** | Auto-exposure drifts as the climber moves across the frame, changing apparent contrast between clips and breaking feature matching. Long-press to lock before recording. |
| Resolution / frame rate | **1080p60** | Contact detection is velocity-based, so temporal resolution matters more than spatial. 60fps halves your velocity noise. |
| Zoom | **1x only** | Digital zoom degrades the pose input; switching lenses mid-shoot changes intrinsics. |
| Orientation | Portrait for tall routes | Frame the whole route with the climber filling as much frame height as possible. |

**Shoot one extra clip at 4K30** (shot 11) so you can compare whether spatial
resolution or frame rate helps pose quality more. Cheap to capture, expensive
to go back for.

---

## Framing rules

- Camera **straight on** to the wall, not angled. Perpendicular as you can
  judge by eye.
- Whole route in frame: start holds, finish hold, and headroom above the finish
  for a fall.
- Include some **wall either side of the climber**. The homography needs hold
  features that aren't occluded by the body.
- Start recording ~2 seconds before the climber leaves the ground and stop
  ~2 seconds after they top out or land. You need clean head and tail.
- **Do not touch the tripod between the two clips of a pair.** Not to check
  framing, not to adjust anything.
- Shoot each pair **back to back**. Lighting shifts and other climbers moving
  through frame both hurt.

---

## Shot list

Shots 1–5 (including 3b and 3c) are mandatory. Without them Phase 0 cannot
answer its three questions. Shots 3b and 3c test the two critical risks — beta
divergence and contact ambiguity — so if time runs short, cut shots 7–11
before cutting those.

### 1. Baseline pair — easy route ★ mandatory
Reference climber then you, on a V0–V2. Both clean sends.
**Validates:** happy path, pose quality gate (0.4), contact detection, route
derivation.

### 2. Baseline pair — harder route ★ mandatory
Same, on something at your limit-ish (V3–V4). More sections, more interesting
movement.
**Validates:** route derivation on a longer sequence, section segmentation.

### 3. Hips-in / hips-out pair ★ mandatory
**Same climber, same move, twice.** Once with hips deliberately pressed close
to the wall, once deliberately sagging away. Exaggerate both — this is a
calibration target, not a technique demo.
**Validates:** task 0.4b, the entire depth-method decision. Without this you
cannot choose between foreshortening and the 3D request.

### 4. Falls ×3 ★ mandatory
Genuine falls at different points on a route — low, mid, and near the top. Land
safely; don't manufacture dangerous ones.
**Validates:** fall detector, base-of-support analysis.

### 5. Dyno ★ mandatory
A deliberate dyno that the climber **sticks**. All four limbs leave the wall
and the sequence resolves in contact.
**Validates:** fall-detector false positives. A dyno is the only thing in
climbing that looks like a fall to a pose model. Without this clip you cannot
tune the detector.

### 3b. Same-beta pair ★ mandatory
The two climbers on one route, having **agreed the sequence beforehand** — same
hands, same feet, same order. Then a second pair on another route where the
stronger climber uses **whatever beta they'd naturally use**, with no
agreement.
**Validates:** Q2, whether section-by-section comparison holds when sequences
diverge. This is the concept risk, not a technical one. Note the actual
sequence differences in the log by eye — that's your ground truth.

### 3c. Contact-detection stress ★ mandatory
One route containing, deliberately: a **shake-out** (climber pauses, hangs one
arm, shakes it), a **hand match** (both hands on one hold), a **re-grip**
(adjust without moving off the hold), and **smeared feet** on a volume or bare
wall with no discrete hold.
**Validates:** Q1, the critical path. Every one of these is a case where "limb
at rest on a hold" is ambiguous, and route derivation depends on resolving all
of them.

### 6. Foot slip vs deliberate foot move
Two clips on the same route: one where a foot genuinely slips, one where the
same foot is moved intentionally.
**Validates:** slip detector (task 3.11). The distinguishing signal is
unweighting before an intentional move.

### 7. Pump-out
A long route or a traverse climbed until visibly fatigued, ideally ending in a
fall.
**Validates:** fatigue trend metrics (3.12), cross-section attribution (3.13).

### 8. Tripod-bump pair
Record a climb, **deliberately nudge the tripod**, record the second climb.
**Validates:** homography actually earns its place, and the registration
failure path (2.3).

### 9. Empty wall plate
5 seconds of the wall with nobody on it, from the same tripod position, for
each route you shoot.
**Validates:** clean homography reference frame, and lets you test registration
without any climber occlusion.

### 10. Adversarial set
Deliberately awkward conditions, one clip each:
- Climber in dark or low-contrast clothing
- Climber small in frame (camera further back)
- A very busy, high-density wall
- Another person moving through the background

**Validates:** where Vision's failure boundary actually sits. You want to find
this now, not from a user.

### 11. Resolution comparison
Re-shoot shot 1's reference climb at 4K30.
**Validates:** whether resolution or frame rate matters more for pose quality.

---

## Usability test — answer these on site

This trip tests the capture experience as well as the pipeline. Findings here
reshape the capture flow before it gets built properly, so write answers down
while you're standing there, not from memory afterward.

**The tripod problem.** Pressing record on a tripod-mounted phone risks bumping
it, and a bumped tripod between the two clips of a pair is the one thing the
homography can't absorb. Test both approaches and pick one:

- **Countdown timer** — press record, walk away, climb starts after N seconds.
  How long does N need to be? Does the dead air at the start of every clip
  become annoying?
- **Single continuous take** — one recording covering both climbers, split
  afterward. Camera pose identical by construction. How long do the files get?
  Is the trim step worse than the timer wait?

Verdict: ______________________

**Framing and setup**

- [ ] Can you frame a full route, start holds to finish, at gym distances? On
      which routes does it fail?
- [ ] How far back do you need to stand, and is there room for that in front of
      every wall?
- [ ] Portrait or landscape — which actually works for the walls at your gym?
- [ ] Is the tripod stable on crash-pad flooring? Does it sink or tilt?
- [ ] How long does a full setup take? Would you do it casually, or only on a
      dedicated session?

**On-site conditions**

- [ ] Screen legible under gym lighting, or is glare a problem?
- [ ] Does AE/AF lock actually hold across a whole clip?
- [ ] How often do other climbers walk through frame? Is it occasional or
      constant?
- [ ] Thermal throttling or battery drain over an hour of recording?
- [ ] Storage consumed per session?

**Social friction**

- [ ] How do other people react to a tripod pointed at a wall?
- [ ] Is your partner comfortable being filmed repeatedly, including falling?
- [ ] Would you feel fine doing this at a busy time, or only when it's quiet?

That last group matters more than it sounds. If setup is socially awkward or
takes ten minutes, the product has a usage problem no amount of analysis
quality fixes — and it's worth knowing before you build the analysis.

---

## Shoot log

For every clip, record:

- Filename / timestamp
- Which shot number it satisfies
- Climber (reference or you)
- Route and grade
- Outcome (send / fall at move N / slip)
- Anything unusual (someone walked through, tripod moved, lighting changed)

Do this **on the day**. Five hours of footage all looks identical a week later,
and mislabeled fixtures produce mysterious test failures.

---

## Pre-departure checklist

- [ ] Capture harness (task 0.0a–0.0c) installed and tested at home on a
      tripod, both trigger modes working
- [ ] Tripod and phone mount packed
- [ ] Phone storage free: budget ~5GB
- [ ] Video stabilization off
- [ ] 1080p60 selected
- [ ] Partner confirmed and briefed — they need to know you'll ask for a dyno
      and deliberate hips-out reps, which look strange without explanation
- [ ] Shot list available offline
- [ ] Battery, or a power bank

## On the way home

- [ ] Transfer clips off the phone the same day
- [ ] Rename to match shot numbers
- [ ] Write the shoot log up while it's fresh
- [ ] Watch shot 3 and shot 5 immediately — if either is unusable, you'll want
      to know before you've unpacked
