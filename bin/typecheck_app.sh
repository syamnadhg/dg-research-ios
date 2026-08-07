#!/usr/bin/env bash
# Type-check the iOS app WITHOUT building, installing or launching it.
#
# Why this exists as its own gate: `swift test` compiles the SPM target only
# (`ios/Sources` + `ios/Tests`). It never sees `ios/App`, because the app is built by a single
# `swiftc` invocation in `bin/build_app.sh` rather than by the package graph. So a green suite says
# nothing at all about whether the *views* still compile — and the views are half the app.
#
# `build_app.sh` would catch it, but it also regenerates constants, signs, installs and relaunches,
# which is far too much to run after every edit and which restarts a paired, logged-in app.
# `-typecheck` does the front-end work only: no object files, no bundle, ~2s.
#
# Usage: bin/typecheck_app.sh
set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BUILD="$REPO/artifacts/typecheck"
mkdir -p "$BUILD"
SDK="$(xcrun --sdk iphonesimulator --show-sdk-path)"

# The generated constants are compile-time inputs (SR_C1 mode reads them), so a type-check needs
# them present. Regenerated every run for the same reason build_app.sh does: a stale SRManifest is
# a difference between what this gate checks and what actually ships.
"$REPO/.venv/bin/python" "$REPO/bin/c1_gen_manifest.py" "${SR_C1_PLATFORM:-mockplatform}" \
  "$BUILD/SRManifest.swift" >/dev/null
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

# Same file set and same target triple as build_app.sh, so a pass here means that build compiles.
# If those two lists ever drift this gate becomes decorative, which is why they are kept adjacent.
exec xcrun swiftc \
  -typecheck \
  -sdk "$SDK" \
  -target arm64-apple-ios17.0-simulator \
  -framework UIKit -framework WebKit -framework SwiftUI -framework CoreImage \
  "$BUILD/SRRuntime.swift" \
  "$BUILD/SRManifest.swift" \
  "$REPO"/ios/Sources/SuperResearchDeviceCore/*.swift \
  "$REPO"/ios/Shared/*.swift \
  "$REPO"/ios/App/*.swift
