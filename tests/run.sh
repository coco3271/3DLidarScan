#!/usr/bin/env bash
# End-to-end check without an iPhone: synthesize a scan bundle (+ edge-case variants), run the
# vendored scan-to-threejs scripts, make_walkthrough.py and make_model.py on them, then drive the walkthrough
# (single file + web app) in headless Chromium and verify the photo cameras pixel by pixel.
# Needs python3 with numpy + Pillow, and node.
set -euo pipefail
cd "$(dirname "$0")/.."
OUT=tests/out
rm -rf "$OUT" && mkdir -p "$OUT"
S=ai-kit/scan-to-threejs/scripts

echo "== synthetic scan + variants"
python3 tests/make_fake_bundle.py "$OUT/FakeHouse" --zip
python3 tests/make_variants.py "$OUT/FakeHouse" "$OUT/variants"

echo "== scan-to-threejs scripts"
python3 "$S/bundle_plan.py" "$OUT/FakeHouse" -o "$OUT/plan.png"
python3 "$S/bundle_to_room.py" "$OUT/FakeHouse" -o "$OUT/house.json" > /dev/null
python3 "$S/prepare_photos.py" "$OUT/FakeHouse" "$OUT/house.json" "$OUT/photos-upright"
for v in single-room no-mesh no-depth no-photos ascii-ply raw-depth; do
  python3 "$S/bundle_to_room.py" "$OUT/variants/$v" --room 0 -o "$OUT/variants/$v-room.json" > /dev/null
done
python3 tests/test_kit.py "$OUT"

echo "== make_walkthrough.py"
python3 ai-kit/make_walkthrough.py "$OUT/FakeHouse.zip" -o "$OUT/walkthrough.html"
python3 ai-kit/make_walkthrough.py "$OUT/FakeHouse" -o "$OUT/walkthrough-from-folder.html" > /dev/null
for v in single-room no-mesh no-depth no-photos ascii-ply raw-depth; do
  python3 ai-kit/make_walkthrough.py "$OUT/variants/$v" -o "$OUT/variants/$v.html" > /dev/null
done
python3 ai-kit/make_walkthrough.py "$OUT/variants/flat-zip.zip" -o "$OUT/variants/flat-zip.html" > /dev/null

echo "== make_model.py"
# the fake photos are small (480 px): allow coarser floor textures so that path is exercised
python3 ai-kit/make_model.py "$OUT/FakeHouse.zip" -o "$OUT/model" --min-texture-res 60
for v in single-room no-depth no-photos; do
  python3 ai-kit/make_model.py "$OUT/variants/$v" -o "$OUT/variants/$v-model" > /dev/null
done
python3 tests/test_model.py "$OUT"

echo "== browser"
(cd tests && [ -d node_modules ] || npm install --silent)
node tests/e2e.mjs "$OUT"
echo "== photo cameras vs photos"
python3 tests/compare_poses.py "$OUT" "$OUT/FakeHouse"
python3 tests/compare_poses.py "$OUT" "$OUT/FakeHouse" model-
echo "OK — screenshots in $OUT"
