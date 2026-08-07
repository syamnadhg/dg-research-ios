#!/usr/bin/env bash
# Build, install and launch the Super Research iOS app in the Simulator.
#
# No Xcode project and no signing identity: Simulator builds are unsigned, so ad-hoc
# `codesign -s -` is enough. An Apple Developer account is only needed for a real device.
#
# Usage:
#   bin/build_app.sh <UDID>                  # build, install (in place), launch
#   bin/build_app.sh <UDID> --shots          # also screenshot the paired and unpaired states
#   bin/build_app.sh <UDID> --clean          # DESTROY the app's data first (see below)
set -euo pipefail

UDID="${1:?usage: build_app.sh <UDID> [--shots] [--clean]}"
SHOTS=""
CLEAN=""
for arg in "${@:2}"; do
  case "$arg" in
    --shots) SHOTS="--shots" ;;
    --clean) CLEAN="--clean" ;;
    *) echo "unknown flag: $arg" >&2; exit 2 ;;
  esac
done
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BUILD="$REPO/artifacts/app"
APP="$BUILD/SuperResearch.app"
BUNDLE_ID="com.distributedglobal.superresearch"

rm -rf "$BUILD"; mkdir -p "$APP"
SDK="$(xcrun --sdk iphonesimulator --show-sdk-path)"

# The C1 mode in main.swift needs SRManifest/SRRuntime, so they are generated for every build.
# Defaults to mockplatform: a plain `build_app.sh` must keep working with no arguments, and the platform
# actually under test is chosen by bin/c1_in_app.sh when it regenerates them.
echo "==> generating the C1 constants (SR_C1 mode needs them at compile time)"
C1PLATFORM="${SR_C1_PLATFORM:-mockplatform}"
"$REPO/.venv/bin/python" "$REPO/bin/c1_gen_manifest.py" "$C1PLATFORM" "$BUILD/SRManifest.swift" \
  ${SR_C1_MANIFEST:+--manifest "$SR_C1_MANIFEST"} ${SR_C1_URL:+--url "$SR_C1_URL"} >/dev/null
"$REPO/.venv/bin/python" - "$BUILD/SRRuntime.swift" <<'GENPY'
import sys
from pathlib import Path
sys.path.insert(0, str(Path.cwd()))
from emubackend.substrate.runtime_js import RUNTIME_JS
Path(sys.argv[1]).write_text(
    "// GENERATED from emubackend/substrate/runtime_js.py - do not edit.\n"
    "enum SRRuntime {\n"
    '    static let source = #"""\n' + RUNTIME_JS + '\n"""#\n'
    "}\n"
)
GENPY

echo "==> compiling"
# The pure-Swift core is compiled in alongside the app sources. It has no dependencies, so this
# needs no package graph — which is what keeps the build a single command with nothing to resolve.
xcrun swiftc \
  -sdk "$SDK" \
  -target arm64-apple-ios17.0-simulator \
  -framework UIKit -framework WebKit -framework SwiftUI -framework CoreImage \
  -o "$APP/SuperResearch" \
  "$BUILD/SRRuntime.swift" \
  "$BUILD/SRManifest.swift" \
  "$REPO"/ios/Sources/SuperResearchDeviceCore/*.swift \
  "$REPO"/ios/Shared/*.swift \
  "$REPO"/ios/App/*.swift

echo "==> Info.plist"
cat > "$APP/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleExecutable</key><string>SuperResearch</string>
  <key>CFBundleIdentifier</key><string>$BUNDLE_ID</string>
  <key>CFBundleName</key><string>Super Research</string>
  <key>CFBundleDisplayName</key><string>Super Research</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>CFBundleShortVersionString</key><string>0.1.0</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <!-- ⚠ The icon, via the LEGACY key set, and that is forced rather than chosen. CFBundleIconName
       names an image set inside a compiled Assets.car, and this bundle is assembled by hand with no
       asset catalog to compile — so the modern key silently resolves to nothing. CFBundleIconFiles
       plus loose PNGs at the top level of the bundle is the route iOS still honours.

       (No backticks anywhere in this comment: this here-doc is UNQUOTED so the plist can interpolate
       the bundle id, which means the shell also executes anything in backticks. Two words wrapped in
       backticks inside this XML comment ran as commands the first time it was written.)

       The strings here are BASE NAMES ONLY. iOS appends @2x / @3x and .png itself; writing the full
       filename is the standard way to end up with a blank tile and no error anywhere. Without any of
       this the app declared no icon at all, and SpringBoard logged "Missing cached image for icon" —
       which on a home screen is indistinguishable from the app not being installed. -->
  <key>CFBundleIcons</key>
  <dict>
    <key>CFBundlePrimaryIcon</key>
    <dict>
      <key>CFBundleIconFiles</key>
      <array>
        <string>AppIcon29x29</string>
        <string>AppIcon40x40</string>
        <string>AppIcon60x60</string>
      </array>
      <key>UIPrerenderedIcon</key><false/>
    </dict>
  </dict>
  <key>LSRequiresIPhoneOS</key><true/>
  <key>MinimumOSVersion</key><string>17.0</string>
  <key>UIUserInterfaceStyle</key><string>Dark</string>
  <!-- ⚠ Without a launch-screen declaration iOS renders the app at a LEGACY screen size and
       letterboxes it — black bars top and bottom, which look like a layout bug in the app rather
       than a missing Info.plist key. UILaunchScreen (iOS 14+) opts into the real display. -->
  <key>UILaunchScreen</key>
  <dict>
    <key>UIColorName</key><string></string>
  </dict>
  <key>UISupportedInterfaceOrientations</key>
  <array><string>UIInterfaceOrientationPortrait</string></array>
  <!-- Scoped to loopback so the emulator fixtures load. A blanket NSAllowsArbitraryLoads would
       also permit every other insecure origin, which is not what a fixture should buy. -->
  <key>NSAppTransportSecurity</key>
  <dict>
    <key>NSAllowsLocalNetworking</key><true/>
    <key>NSExceptionDomains</key>
    <dict>
      <key>127.0.0.1</key>
      <dict><key>NSExceptionAllowsInsecureHTTPLoads</key><true/></dict>
    </dict>
  </dict>
</dict>
</plist>
PLIST

# The plist is copied in when present. It is required for the Firebase path and absent by design in
# a fresh clone, so its absence is a note rather than a failure.
if [ -f "$REPO/ios/GoogleService-Info.plist" ]; then
  cp "$REPO/ios/GoogleService-Info.plist" "$APP/GoogleService-Info.plist"
  echo "==> bundled GoogleService-Info.plist"
else
  echo "==> NOTE: no GoogleService-Info.plist — the Firebase path will be unavailable"
fi

# Brand icons, copied out of the frontend's public/icons at repo-setup time. Loose resources rather
# than an asset catalog, because this bundle is assembled by hand and has no catalog to compile.
if [ -d "$REPO/ios/Assets" ]; then
  cp "$REPO"/ios/Assets/*.png "$APP/" 2>/dev/null || true
  echo "==> bundled $(ls "$REPO/ios/Assets"/*.png 2>/dev/null | wc -l | tr -d ' ') brand icons"
fi

# The app icon set, flat at the top level of the bundle — `CFBundleIconFiles` resolves relative to
# the bundle root, not to a subdirectory. Generated by bin/make_app_icon.sh from the frontend's own
# favicon.svg, so the phone carries the same mark as the web app.
if [ -d "$REPO/ios/Assets/AppIcon" ]; then
  cp "$REPO"/ios/Assets/AppIcon/*.png "$APP/" 2>/dev/null || true
  echo "==> bundled the app icon set"
else
  echo "==> NOTE: no app icon set — run bin/make_app_icon.sh (the home screen tile will be blank)"
fi

# ⚠ NO ENTITLEMENTS — and this is measured, not an oversight. Do not "fix" it by adding them.
#
# The Keychain would be the right home for the pairing identity, and it does not work in this build:
# an ad-hoc signature carries no `application-identifier`, so the app has no keychain access group
# and every `SecItemAdd` fails with errSecMissingEntitlement (-34018). Verified directly — after a
# pairing that reported success, the simulator's keychain DB (WAL included) held no row for our
# service, and the device presented as never-paired on the next launch.
#
# The obvious remedy does not work either. Signing with `application-identifier` +
# `keychain-access-groups` embeds correctly (confirmed with `codesign -d --entitlements`) but then
# SpringBoard REFUSES TO LAUNCH the app: "The request was denied by service delegate
# (SBMainWorkspace)", process exits immediately as <invalid>. Tried with a bare bundle id and with a
# fake team prefix; both denied. Re-signing with no entitlements launches instantly. An unprovisioned
# Simulator build simply cannot hold entitlements.
#
# So `DeviceIdentityStore` falls back to a protected file in the app container when the Keychain
# proves unwritable, and says so in the log. A real device build gets a provisioning profile and uses
# the Keychain as intended.
echo "==> ad-hoc signing (no entitlements — see the comment above before changing this)"
codesign --force --sign - --timestamp=none "$APP" >/dev/null 2>&1 || codesign --force --sign - "$APP"

echo "==> installing"
xcrun simctl bootstatus "$UDID" -b >/dev/null 2>&1 || true
# `simctl install` over an existing bundle UPGRADES it in place and keeps the Data container.
#
# ⚠ There used to be an unconditional `simctl uninstall` here, and it cost real work. Uninstall
# deletes the Data container, which on this app holds three things that are expensive to recreate:
# the WKWebView cookie jar (every platform login the owner did by hand, 2FA included), the Keychain
# API keys, and the paired device identity. So every rebuild silently signed the device out of
# ChatGPT/Gemini/Claude/NotebookLM and unpaired it — measured, not theorised: after a rebuild the
# container had no `Library/WebKit/WebsiteData` at all and all four platforms surveyed as logged
# out. It also produced the "the app restarted by itself" symptom mid-pairing, because uninstalling
# a foreground app terminates it (`SBWorkspaceTerminateApplication: "uninstalling app"`).
#
# Cleaning is now opt-in, because destroying a hand-made login should be something you asked for.
if [ "$CLEAN" = "--clean" ]; then
  echo "    --clean: erasing app data (logins, API keys, pairing identity)"
  xcrun simctl uninstall "$UDID" "$BUNDLE_ID" >/dev/null 2>&1 || true
fi
xcrun simctl install "$UDID" "$APP"

if [ "$SHOTS" = "--shots" ]; then
  mkdir -p "$REPO/artifacts/app/shots"
  for state in paired unpaired; do
    xcrun simctl terminate "$UDID" "$BUNDLE_ID" >/dev/null 2>&1 || true
    SIMCTL_CHILD_SR_SCREENSHOT_STATE="$state" xcrun simctl launch "$UDID" "$BUNDLE_ID" >/dev/null
    sleep 3
    axe screenshot --udid "$UDID" --output "$REPO/artifacts/app/shots/$state.png" >/dev/null
    echo "==> shot: artifacts/app/shots/$state.png"
  done
else
  xcrun simctl launch "$UDID" "$BUNDLE_ID" >/dev/null
  echo "==> launched. open -a Simulator to see it."
fi
