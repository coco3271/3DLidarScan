#!/usr/bin/env bash
# End-to-end check without an iPhone: synthesize a scan bundle, run the vendored
# scan-to-threejs scripts and make_walkthrough.py on it, then open the walkthrough
# (single file + web app) in headless Chromium. Needs python3 with numpy + Pillow, node.
set -euo pipefail
cd "$(dirname "$0")/.."
OUT=tests/out
rm -rf "$OUT" && mkdir -p "$OUT"
S=ai-kit/scan-to-threejs/scripts

python3 tests/make_fake_bundle.py "$OUT/FakeHouse" --zip
python3 "$S/bundle_plan.py" "$OUT/FakeHouse" -o "$OUT/plan.png"
python3 "$S/bundle_to_room.py" "$OUT/FakeHouse" -o "$OUT/house.json"
python3 "$S/bundle_to_room.py" "$OUT/FakeHouse" --room 1 -o "$OUT/room-1.json"
python3 "$S/prepare_photos.py" "$OUT/FakeHouse" "$OUT/house.json" "$OUT/photos-upright"
python3 ai-kit/make_walkthrough.py "$OUT/FakeHouse.zip" -o "$OUT/walkthrough.html"
python3 ai-kit/make_walkthrough.py "$OUT/FakeHouse" -o "$OUT/walkthrough-from-folder.html"
python3 -m py_compile ai-kit/make_walkthrough.py

(cd tests && [ -d node_modules ] || npm install --silent)
node tests/viewer_smoke.mjs "$OUT/walkthrough.html" "$OUT" "$OUT/FakeHouse.zip"
echo "OK — screenshots in $OUT"
