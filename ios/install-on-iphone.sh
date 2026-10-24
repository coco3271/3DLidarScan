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

# --- the full Xcode app (the Command Line Tools alone can't build for or install on an iPhone) --------
DEV_DIR=$(xcode-select -p 2>/dev/null || true)
if [ ! -x "$DEV_DIR/usr/bin/xcodebuild" ] || [[ "$DEV_DIR" == *CommandLineTools* ]]; then
  # use Xcode.app for this script without changing the system setting (no sudo needed)
  XCODE_APP=$(ls -d /Applications/Xcode.app /Applications/Xcode*.app 2>/dev/null | head -1 || true)
  if [ -z "$XCODE_APP" ]; then
    XCODE_APP=$(mdfind "kMDItemCFBundleIdentifier == 'com.apple.dt.Xcode'" 2>/dev/null | head -1 || true)
  fi
  if [ -z "$XCODE_APP" ]; then
    cat <<'MSG'
The full Xcode app isn't installed (this Mac only has the Command Line Tools, which can't
install apps on an iPhone). Install "Xcode" from the Mac App Store, open it once and let it
finish installing components (choose iOS when asked), then rerun this script.
MSG
    exit 1
  fi
  export DEVELOPER_DIR="$XCODE_APP/Contents/Developer"
  echo "Using $XCODE_APP (xcode-select points at the Command Line Tools; to make Xcode the default:"
  echo "  sudo xcode-select -s \"$DEVELOPER_DIR\")"
fi
XCODE_MAJOR=$(xcodebuild -version 2>/dev/null | sed -n 's/^Xcode \([0-9]*\).*/\1/p')
if [ -z "$XCODE_MAJOR" ]; then
  echo "Xcode isn't set up yet. Open Xcode once (accept the license, install the iOS components), or run:"
  echo "  sudo xcodebuild -license accept && xcodebuild -runFirstLaunch"
  exit 1
fi
if [ "$XCODE_MAJOR" -lt 15 ]; then
  echo "Xcode $XCODE_MAJOR is too old (needs 15 or newer for iOS 17 / RoomPlan). Update Xcode in the App Store."
  exit 1
fi
# first-launch components (device support, etc.); quick when already installed
xcodebuild -runFirstLaunch >/dev/null 2>&1 || true
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
  build > build.log 2>&1 || true
grep -E "error:|warning: .*(sign|provision)|BUILD (SUCCEEDED|FAILED)" build.log | sort -u || true
APP=build/Build/Products/Debug-iphoneos/LidarWalkthrough.app
if ! grep -q "BUILD SUCCEEDED" build.log || [ ! -d "$APP" ]; then
  if grep -qiE "iOS [0-9.]+ is not installed|platform.*not installed|Unable to find a destination" build.log; then
    echo "Xcode is missing the iOS platform for this phone. Run: xcodebuild -downloadPlatform iOS  (or Xcode › Settings › Components), then rerun."
  elif grep -qiE "No Account for Team|No signing certificate|requires a development team|provisioning profile" build.log; then
    echo "Signing problem: in Xcode › Settings › Accounts make sure your Apple ID is signed in, then rerun."
  fi
  echo "Build failed; full log: ios/build.log. You can also open ios/LidarWalkthrough.xcodeproj in Xcode and press Run."
  exit 1
fi

xcrun devicectl device install app --device "$DEVICE" "$APP"
if ! xcrun devicectl device process launch --device "$DEVICE" "$BUNDLE_ID"; then
  cat <<'MSG'
Installed, but iOS blocked the launch. On the iPhone: Settings › General › VPN & Device Management ›
your Apple ID › Trust. Then open "3D LiDAR Scan" from the home screen.
MSG
fi
echo "Done: \"3D LiDAR Scan\" is on your iPhone."
