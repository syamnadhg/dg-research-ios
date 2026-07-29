#!/usr/bin/env bash
# Build, install and run the WKWebView harness as a REAL iOS app in the Simulator — phase C0's channel.
#
# No Xcode project and no signing identity, because Simulator builds are unsigned: ad-hoc
# `codesign -s -` is enough, and an Apple Developer account is only needed for a real device. So the
# WKWebView gate — which cannot run under `swift test`, since SwiftPM's harness provides no app bundle
# or WebProcess host — is reachable without any owner-gated credential.
#
# Usage: bin/c0_in_app.sh <UDID>
set -euo pipefail

UDID="${1:?usage: c0_in_app.sh <UDID>}"
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BUILD="$REPO/artifacts/apphost"
APP="$BUILD/SRHarness.app"
BUNDLE_ID="com.distributedglobal.srharness"
PORT=8901

rm -rf "$BUILD"
mkdir -p "$APP"

SDK="$(xcrun --sdk iphonesimulator --show-sdk-path)"

# The mock platform must be reachable from inside the Simulator (it shares the host's loopback).
if ! curl -fsS -o /dev/null "http://127.0.0.1:$PORT/"; then
  (cd "$REPO/fixtures/mockplatform" && nohup python3 -m http.server "$PORT" --bind 127.0.0.1 \
    >/dev/null 2>&1 &)
  for _ in $(seq 1 20); do
    curl -fsS -o /dev/null "http://127.0.0.1:$PORT/" && break
    sleep 0.5
  done
fi

echo "==> compiling for the simulator"
xcrun swiftc \
  -sdk "$SDK" \
  -target arm64-apple-ios17.0-simulator \
  -framework UIKit -framework WebKit \
  -o "$APP/SRHarness" \
  "$REPO/ios/AppHarness/main.swift"

echo "==> writing Info.plist"
cat > "$APP/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleExecutable</key><string>SRHarness</string>
  <key>CFBundleIdentifier</key><string>$BUNDLE_ID</string>
  <key>CFBundleName</key><string>SRHarness</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>CFBundleShortVersionString</key><string>1.0</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>LSRequiresIPhoneOS</key><true/>
  <key>UILaunchStoryboardName</key><string></string>
  <key>MinimumOSVersion</key><string>17.0</string>
  <!-- The mock platform is served over plain HTTP on loopback, which ATS blocks by default.
       Scoped to localhost only: a blanket NSAllowsArbitraryLoads would also permit every other
       insecure origin, which is not what a test fixture should buy. -->
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

echo "==> ad-hoc signing (no developer account needed for the Simulator)"
codesign --force --sign - --timestamp=none "$APP" >/dev/null 2>&1 || \
  codesign --force --sign - "$APP"

echo "==> installing"
xcrun simctl bootstatus "$UDID" -b >/dev/null 2>&1 || true
xcrun simctl uninstall "$UDID" "$BUNDLE_ID" >/dev/null 2>&1 || true
xcrun simctl install "$UDID" "$APP"

echo "==> launching (stdout captured)"
OUT="$BUILD/console.log"
# --console-pty streams the app's stdout back and returns when it exits.
xcrun simctl launch --console-pty "$UDID" "$BUNDLE_ID" 2>&1 | tee "$OUT" || true

echo
if grep -q "SRHARNESS_JSON" "$OUT"; then
  python3 - "$OUT" <<'PY'
import json, sys, pathlib
line = next(l for l in pathlib.Path(sys.argv[1]).read_text(errors="replace").splitlines()
            if "SRHARNESS_JSON" in l)
payload = json.loads(line.split("SRHARNESS_JSON", 1)[1].strip())
out = pathlib.Path(sys.argv[1]).parent / "verdict.json"
out.write_text(json.dumps(payload, indent=2) + "\n")
for r in payload["results"]:
    print(f"  [{'PASS' if r['pass'] else 'FAIL'}] {r['check']}: {r['detail']}")
print(f"\nC0 in-app (WKWebView): {'PASS' if payload['pass'] else 'FAIL'}  -> {out}")
sys.exit(0 if payload["pass"] else 1)
PY
else
  echo "no SRHARNESS_JSON in the console output — the app did not report. Raw tail:"
  tail -20 "$OUT"
  exit 1
fi
