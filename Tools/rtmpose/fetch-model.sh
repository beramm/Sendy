#!/bin/bash
# Puts the RTMPose wholebody model where the app expects it.
# Not committed: 218MB. The desktop script caches the same file, so this reuses
# it when present rather than downloading twice.
set -e
root="$(cd "$(dirname "$0")/../.." && pwd)"
dest="$root/SendSociety/Models/rtmpose_wholebody.onnx"
# --lightweight swaps the 218MB wholebody model for the 123MB one. It is
# meaningfully worse — left-wrist tracking 71% vs 50% on the fixtures — so use
# it only when the large model will not run on device.
if [ "$1" = "--lightweight" ]; then
  name=rtmw-dw-l-m_simcc-cocktail14_270e-256x192_20231122
else
  name=rtmw-dw-x-l_simcc-cocktail14_270e-256x192_20231122
fi
cached=~/.cache/rtmlib/hub/checkpoints/$name.onnx
url=https://download.openmmlab.com/mmpose/v1/projects/rtmposev1/onnx_sdk/$name.zip

mkdir -p "$(dirname "$dest")"
if [ -f "$dest" ]; then echo "replacing existing model"; rm -f "$dest"; fi
if [ -f "$cached" ]; then cp "$cached" "$dest"; echo "copied from rtmlib cache → $dest"; exit 0; fi
tmp="$(mktemp -d)"
echo "downloading model…"
curl -L "$url" -o "$tmp/model.zip"
unzip -j -o "$tmp/model.zip" '*.onnx' -d "$tmp"
mv "$tmp"/*.onnx "$dest"
rm -rf "$tmp"
echo "wrote $dest"
