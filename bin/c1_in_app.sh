#!/usr/bin/env bash
# The C1 gate: a full P0-P3 run INSIDE the native app, driving the app's own WKWebView.
#
# C0 answered "can the app talk to a page at all". This runs the real orchestrator — the same phase
# sequence, predicates and ordering invariants — against the same mock platform the Simulator gate uses.
#
# Why an app rather than `swift test`: SwiftPM's harness has no app bundle and no WebProcess host, so a
# WKWebView cannot even be instantiated there. The orchestrator's logic is unit-tested against a fake
# page (InAppPipelineTests); this supplies the real WebKit host, which is the part that cannot be faked.
#
# ⚠ The runtime JS is GENERATED from emubackend/substrate/runtime_js.py. One source of truth: a second
# hand-maintained copy would drift from the one that has Simulator evidence behind it.
#
# Usage: bin/c1_in_app.sh <UDID>
set -euo pipefail

UDID="${1:?usage: c1_in_app.sh <UDID>}"
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BUILD="$REPO/artifacts/c1"
APP="$BUILD/SRC1.app"
BUNDLE_ID="com.distributedglobal.src1"
PORT=8901
PY="$REPO/.venv/bin/python"

rm -rf "$BUILD"; mkdir -p "$APP"

echo "==> serving the mock platform on :$PORT"
if ! curl -fsS -o /dev/null "http://127.0.0.1:$PORT/"; then
  (cd "$REPO/fixtures/mockplatform" && nohup python3 -m http.server "$PORT" --bind 127.0.0.1 \
    >/dev/null 2>&1 &)
  for _ in $(seq 1 20); do
    curl -fsS -o /dev/null "http://127.0.0.1:$PORT/" && break
    sleep 0.5
  done
fi

echo "==> generating the runtime constant from runtime_js.py"
"$PY" - "$BUILD/SRRuntime.swift" <<'PY'
import sys
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent if "__file__" in dir() else Path.cwd()
sys.path.insert(0, str(Path.cwd()))
from emubackend.substrate.runtime_js import RUNTIME_JS

# Emitted as a raw Swift string literal with a delimiter that cannot occur in JS source, so no
# escaping pass is needed and the payload stays byte-identical to the Python side's.
out = Path(sys.argv[1])
out.write_text(
    "// GENERATED from emubackend/substrate/runtime_js.py — do not edit.\n"
    "// One source of truth: a second hand-maintained copy of the runtime would drift from the one\n"
    "// that has real-Simulator evidence behind it.\n"
    "enum SRRuntime {\n"
    '    static let source = #"""\n'
    + RUNTIME_JS
    + '\n"""#\n'
    "}\n"
)
print(f"    wrote {out.name} ({len(RUNTIME_JS)} bytes of runtime)")
PY

echo "==> compiling the C1 harness app"
SDK="$(xcrun --sdk iphonesimulator --show-sdk-path)"
xcrun swiftc \
  -sdk "$SDK" \
  -target arm64-apple-ios17.0-simulator \
  -framework UIKit -framework WebKit \
  -o "$APP/SRC1" \
  "$BUILD/SRRuntime.swift" \
  "$REPO"/ios/Sources/SuperResearchDeviceCore/*.swift \
  "$REPO/ios/C1Harness/main.swift"

cat > "$APP/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleExecutable</key><string>SRC1</string>
  <key>CFBundleIdentifier</key><string>$BUNDLE_ID</string>
  <key>CFBundleName</key><string>SRC1</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>CFBundleShortVersionString</key><string>1.0</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>LSRequiresIPhoneOS</key><true/>
  <key>MinimumOSVersion</key><string>17.0</string>
  <key>UILaunchScreen</key><dict/>
  <!-- Scoped to loopback. A blanket NSAllowsArbitraryLoads would also permit every other insecure
       origin, which is not what a fixture should buy. -->
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

codesign --force --sign - "$APP" >/dev/null 2>&1 || codesign --force --sign - "$APP"

echo "==> installing and running in the Simulator"
xcrun simctl bootstatus "$UDID" -b >/dev/null 2>&1 || true
xcrun simctl uninstall "$UDID" "$BUNDLE_ID" >/dev/null 2>&1 || true
xcrun simctl install "$UDID" "$APP"

set +e
xcrun simctl launch --console-pty "$UDID" "$BUNDLE_ID" 2>&1 | tee "$BUILD/run.log"
set -e

# The app writes its verdict into its own container, so it is copied out to the repo's artifacts.
CONTAINER="$(xcrun simctl get_app_container "$UDID" "$BUNDLE_ID" data 2>/dev/null || true)"
FOUND="$(find "$CONTAINER" -name verdict.json -path '*sr-c1*' 2>/dev/null | head -1)"
if [ -n "$FOUND" ]; then
  cp "$FOUND" "$BUILD/verdict.json"
  "$PY" -c "
import json, sys
d = json.load(open('$BUILD/verdict.json'))
print()
for r in d['results']:
    print(('  [PASS] ' if r['pass'] else '  [FAIL] ') + r['check'] + (': ' + r['detail'] if r['detail'] else ''))
print()
print('C1 in-app: ' + ('PASS' if d['pass'] else 'FAIL') + '  -> $BUILD/verdict.json')
sys.exit(0 if d['pass'] else 1)
"
else
  echo "!! no verdict.json produced — see $BUILD/run.log"
  exit 1
fi
