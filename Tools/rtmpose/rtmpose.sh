#!/bin/bash
# Runs RTMPose in the project-local venv. Creates it on first use.
set -e
here="$(cd "$(dirname "$0")" && pwd)"
if [ ! -x "$here/.venv/bin/python" ]; then
  echo "creating venv…" >&2
  python3 -m venv "$here/.venv"
  "$here/.venv/bin/pip" install --quiet --upgrade pip
  "$here/.venv/bin/pip" install --quiet rtmlib onnxruntime opencv-python
fi
exec "$here/.venv/bin/python" "$here/rtmpose_to_posesequence.py" "$@"
