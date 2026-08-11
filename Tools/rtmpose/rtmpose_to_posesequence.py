#!/usr/bin/env python3
"""Run RTMPose over a video and emit the PoseSequence JSON the Swift pipeline reads.

The point of this script is that it produces the *same file format* as
`posecli pose`, so a different pose model drops into the existing pipeline with
no Swift changes at all:

    ./rtmpose.sh Fixtures/user.mov --out rtm_att.json
    ./.build/release/posecli segment rtm_att.json
    ./.build/release/posecli jitter  rtm_att.json
    ./.build/release/posecli compare ref.mov att.mov --b-ref rtm_ref.json --b-att rtm_att.json

Two things it deliberately does not do:

* It does not touch the app. The no-network constraint in CLAUDE.md is about the
  *app*; this is a desktop evaluation tool, and the model it downloads here would
  be converted and bundled before anything ships.
* It does not resample or smooth. `PoseSmoother` and the working-frame-rate
  downsample live in Swift and must stay there, or the two trackers would be
  compared through different preprocessing.
"""

import argparse
import json
import sys
import time

import cv2
import numpy as np

# COCO-WholeBody index → the 19 JointName cases the Swift side knows.
#
# RTMPose wholebody gives 133 keypoints: 0-16 body (COCO), 17-22 feet,
# 23-90 face, 91-132 hands. Only the body subset maps onto JointName today; the
# feet indices are kept below because they are the reason for running this at
# all, and they are what task 8.7 measures.
COCO_TO_JOINT = {
    0: "nose",
    1: "leftEye",
    2: "rightEye",
    3: "leftEar",
    4: "rightEar",
    5: "leftShoulder",
    6: "rightShoulder",
    7: "leftElbow",
    8: "rightElbow",
    9: "leftWrist",
    10: "rightWrist",
    11: "leftHip",
    12: "rightHip",
    13: "leftKnee",
    14: "rightKnee",
    15: "leftAnkle",
    16: "rightAnkle",
}

# Foot keypoints in COCO-WholeBody order, per side.
FOOT_INDICES = {
    "leftBigToe": 17, "leftSmallToe": 18, "leftHeel": 19,
    "rightBigToe": 20, "rightSmallToe": 21, "rightHeel": 22,
}


def keypoints_to_joints(keypoints, scores, width, height, min_score):
    """One frame's keypoints → the `[JointName: Joint]` dictionary Swift expects.

    Vision reports normalized coordinates with the origin at the **bottom left**
    and y increasing upward. OpenCV gives pixels from the top left. Getting this
    flip wrong would put every skeleton upside down and, worse, would look
    plausible in aggregate statistics — so it happens in exactly one place.
    """
    joints = {}
    for index, name in COCO_TO_JOINT.items():
        if index >= len(keypoints):
            continue
        x, y = keypoints[index][0], keypoints[index][1]
        score = float(scores[index]) if index < len(scores) else 0.0
        if score < min_score:
            continue
        if not (np.isfinite(x) and np.isfinite(y)):
            continue
        joints[name] = {
            "point": {"x": float(x) / width, "y": 1.0 - float(y) / height},
            "confidence": score,
        }

    # `neck` and `root` are not COCO keypoints. Vision reports both, and the
    # Swift side uses them, so they are derived rather than left missing —
    # otherwise the two trackers would differ for a reason that has nothing to
    # do with tracking quality.
    def midpoint(a, b, key):
        if a in joints and b in joints:
            pa, pb = joints[a]["point"], joints[b]["point"]
            joints[key] = {
                "point": {"x": (pa["x"] + pb["x"]) / 2, "y": (pa["y"] + pb["y"]) / 2},
                "confidence": min(joints[a]["confidence"], joints[b]["confidence"]),
            }

    midpoint("leftShoulder", "rightShoulder", "neck")
    midpoint("leftHip", "rightHip", "root")
    return joints


def foot_keypoints(keypoints, scores, width, height):
    """The six foot keypoints, kept alongside for the task 8.7 jitter question.

    These have no `JointName` case, so they ride in a sidecar rather than in
    `joints` — adding unknown keys there would fail Swift's decoding.
    """
    out = {}
    for name, index in FOOT_INDICES.items():
        if index >= len(keypoints):
            continue
        score = float(scores[index]) if index < len(scores) else 0.0
        x, y = keypoints[index][0], keypoints[index][1]
        if not (np.isfinite(x) and np.isfinite(y)):
            continue
        out[name] = {
            "point": {"x": float(x) / width, "y": 1.0 - float(y) / height},
            "confidence": score,
        }
    return out


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("video")
    parser.add_argument("--out", required=True, help="PoseSequence JSON to write")
    parser.add_argument("--feet-out", help="optional sidecar with the 6 foot keypoints per frame")
    parser.add_argument("--rate", type=float, default=30.0, help="working frame rate; matches TuningConfig")
    parser.add_argument("--mode", default="balanced", choices=["performance", "lightweight", "balanced"])
    parser.add_argument("--min-score", type=float, default=0.0,
                        help="drop keypoints below this. Leave at 0 — the Swift side owns confidence gating")
    parser.add_argument("--backend", default="onnxruntime")
    args = parser.parse_args()

    from rtmlib import Wholebody

    capture = cv2.VideoCapture(args.video)
    if not capture.isOpened():
        sys.exit(f"could not open {args.video}")

    source_fps = capture.get(cv2.CAP_PROP_FPS) or 30.0
    width = int(capture.get(cv2.CAP_PROP_FRAME_WIDTH))
    height = int(capture.get(cv2.CAP_PROP_FRAME_HEIGHT))
    total = int(capture.get(cv2.CAP_PROP_FRAME_COUNT))

    # Never upsample: the working rate is a ceiling, exactly as in Swift.
    effective_rate = min(args.rate, source_fps)
    sample_interval = 1.0 / effective_rate

    print(f"{args.video}: {width}x{height} @ {source_fps:.2f}fps, {total} frames", file=sys.stderr)
    print(f"sampling to {effective_rate:.2f}fps · downloading model on first run…", file=sys.stderr)

    model = Wholebody(mode=args.mode, backend=args.backend, device="cpu")

    frames, feet_frames, warnings = [], [], []
    next_sample_time, emitted, decoded, untracked = 0.0, 0, 0, 0
    started = time.time()

    while True:
        ok, image = capture.read()
        if not ok:
            break
        pts = decoded / source_fps
        decoded += 1
        if pts + 1e-6 < next_sample_time:
            continue
        next_sample_time = pts + sample_interval

        keypoints, scores = model(image)
        if keypoints is None or len(keypoints) == 0:
            joints, feet = {}, {}
            untracked += 1
        else:
            # Exactly one climber in frame, by project constraint: take the
            # detection with the highest mean score.
            best = int(np.argmax([np.mean(s) for s in scores]))
            joints = keypoints_to_joints(keypoints[best], scores[best], width, height, args.min_score)
            feet = foot_keypoints(keypoints[best], scores[best], width, height)
            if not joints:
                untracked += 1

        frames.append({"index": emitted, "timeSeconds": pts, "joints": joints})
        feet_frames.append({"index": emitted, "timeSeconds": pts, "joints": feet})
        emitted += 1
        if emitted % 30 == 0:
            elapsed = time.time() - started
            print(f"  {emitted} frames · {emitted / max(elapsed, 1e-6):.1f} fps", end="\r", file=sys.stderr)

    capture.release()

    if not frames:
        warnings.append(f"No frames decoded from {args.video}.")
    elif untracked > len(frames) // 2:
        warnings.append(f"No person detected in {untracked} of {len(frames)} frames — check framing and lighting.")
    elif untracked:
        warnings.append(f"{untracked} of {len(frames)} frames had no detection.")
    warnings.append(f"Pose produced by RTMPose ({args.mode}), not Apple Vision.")

    sequence = {
        "frames": frames,
        "space": "image",
        "frameRate": effective_rate,
        "sourceWidth": width,
        "sourceHeight": height,
        "warnings": warnings,
    }
    with open(args.out, "w") as handle:
        json.dump(sequence, handle)

    if args.feet_out:
        with open(args.feet_out, "w") as handle:
            json.dump({**sequence, "frames": feet_frames}, handle)

    elapsed = time.time() - started
    print(f"\nwrote {args.out}: {len(frames)} frames in {elapsed:.1f}s "
          f"({len(frames) / max(elapsed, 1e-6):.1f} fps)", file=sys.stderr)
    for w in warnings:
        print(f"warning: {w}", file=sys.stderr)


if __name__ == "__main__":
    main()
