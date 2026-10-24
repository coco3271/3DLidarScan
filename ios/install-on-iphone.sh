#!/usr/bin/env bash
# Build the app and install it on the iPhone plugged into this Mac, then launch it.
#
#   cd ios && ./install-on-iphone.sh
#
# Needs: Xcode (App Store), your Apple ID added in Xcode › Settings › Accounts (a free one works),
# the iPhone unlocked, "Trust This Computer" accepted, and Developer Mode on
# (iPhone Settings › Privacy & Security › Developer Mode, then restart the phone).
# Optional: TEAM_ID=ABCDE12345 BUNDLE_ID=com.you.lidarscan DEVICE=<udid> ./install-on-iphone.sh
set -euo pipefail
cd "$(dirname "$0")"

command -v xcodebuild >/dev/null || { echo "Xcode is missing: install it from the App Store, open it once, then rerun."; exit 1; }
if ! command -v xcodegen >/dev/null; then
  command -v brew >/dev/null || { echo "Install Homebrew (https://brew.sh) or XcodeGen, then rerun."; exit 1; }
  brew install xcodegen
fi
xcodegen --quiet

# --- the connected iPhone ------------------------------------------------------------------------
if [ -z "${DEVICE:-}" ]; then
  JSON=$(mktemp)
  xcrun devicectl list devices --json-output "$JSON" >/dev/null
  DEVICE=$(python3 - "$JSON" <<'PY'
import json, sys
devices = json.load(open(sys.argv[1]))["result"]["devices"]
phones = [d for d in devices if d.get("hardwareProperties", {}).get("platform") == "iOS"]
# prefer a USB-connected phone
phones.sort(key=lambda d: d.get("connectionProperties", {}).get("transportType") != "wired")
if phones:
    d = phones[0]
    print(d["hardwareProperties"]["udid"])
    print(f"Using {d['deviceProperties']['name']} ({d['hardwareProperties'].get('marketingName', '')})", file=sys.stderr)
PY
)
  rm -f "$JSON"
fi
[ -n "$DEVICE" ] || { echo "No iPhone found. Plug it in with a cable, unlock it, tap Trust, and rerun."; exit 1; }

# --- signing: your Apple Development certificate's team -------------------------------------------
if [ -z "${TEAM_ID:-}" ]; then
  TEAM_ID=$(security find-certificate -c "Apple Development" -p 2>/dev/null \
    | openssl x509 -noout -subject 2>/dev/null | sed -n 's/.*OU *= *\([A-Z0-9]\{10\}\).*/\1/p' | head -1 || true)
fi
if [ -z "$TEAM_ID" ]; then
  cat <<'MSG'
No signing team found. In Xcode: Settings › Accounts › + › Apple ID, sign in, select your team,
click "Manage Certificates…" › + › Apple Development. Then rerun this script.
(Or set it explicitly: TEAM_ID=ABCDE12345 ./install-on-iphone.sh)
MSG
  exit 1
fi
# bundle IDs must be unique to your team (free accounts can't reuse someone else's)
BUNDLE_ID=${BUNDLE_ID:-com.lidarscan.$(echo "$TEAM_ID" | tr 'A-Z' 'a-z').walkthrough}
echo "Team $TEAM_ID · bundle $BUNDLE_ID · device $DEVICE"

# --- build, install, launch -----------------------------------------------------------------------
xcodebuild -project LidarWalkthrough.xcodeproj -scheme LidarWalkthrough -configuration Debug \
  -destination "id=$DEVICE" -derivedDataPath build \
  -allowProvisioningUpdates -allowProvisioningDeviceRegistration \
  DEVELOPMENT_TEAM="$TEAM_ID" PRODUCT_BUNDLE_IDENTIFIER="$BUNDLE_ID" CODE_SIGN_STYLE=Automatic \
  build | grep -E "error|warning: .*(sign|provision)|BUILD (SUCCEEDED|FAILED)" || true
APP=build/Build/Products/Debug-iphoneos/LidarWalkthrough.app
[ -d "$APP" ] || { echo "Build failed (see above). Opening the project in Xcode may show the signing fix: open LidarWalkthrough.xcodeproj"; exit 1; }

xcrun devicectl device install app --device "$DEVICE" "$APP"
if ! xcrun devicectl device process launch --device "$DEVICE" "$BUNDLE_ID"; then
  cat <<'MSG'
Installed, but iOS blocked the launch. On the iPhone: Settings › General › VPN & Device Management ›
your Apple ID › Trust. Then open "3D LiDAR Scan" from the home screen.
MSG
fi
echo "Done: \"3D LiDAR Scan\" is on your iPhone."
