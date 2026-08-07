#!/usr/bin/env bash
# Render the frontend's app mark into the loose PNG icon set an unsigned .app bundle can use.
#
# ⚠ WHY THIS EXISTS. The hand-assembled bundle has no asset catalog, so `CFBundleIconName` — the
# modern key — is unavailable: it names an image set inside a compiled `Assets.car`. The only route
# left is the legacy `CFBundleIconFiles` list plus loose PNGs at the top level of the bundle, which
# iOS still honours. Until this ran, the app declared no icon at all and SpringBoard logged
# "Missing cached image for icon" — a blank home-screen tile that reads as a failed install.
#
# The source is `dg-research/public/favicon.svg`, which is the product's real mark: the web app's
# manifest icon, favicon, and apple-touch icon all point at it, so the phone now carries the same
# artwork as the web app rather than something invented for it.
#
# ⚠ No SVG rasteriser is installed on this box — rsvg-convert, resvg, inkscape, cairosvg and PIL are
# all absent, and `sips` cannot read SVG. `qlmanage` can: QuickLook has a built-in SVG generator.
# That is the only reason this is a shell script and not two lines of Python.
#
# Usage: bin/make_app_icon.sh [path/to/favicon.svg]
set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SRC="${1:-$REPO/../dg-research/public/favicon.svg}"
OUT="$REPO/ios/Assets/AppIcon"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

if [ ! -f "$SRC" ]; then
  echo "FATAL: no source mark at $SRC" >&2
  exit 1
fi

mkdir -p "$OUT"

echo "==> rasterising $(basename "$SRC") at 1024px (qlmanage)"
qlmanage -t -s 1024 -o "$WORK" "$SRC" >/dev/null 2>&1
MASTER="$WORK/$(basename "$SRC").png"
[ -f "$MASTER" ] || { echo "FATAL: qlmanage produced no thumbnail" >&2; exit 1; }

# ⚠ FLATTEN. An iOS app icon must be opaque and square — the system applies its own corner mask, and
# an icon with an alpha channel renders with black fringing or is rejected outright by icon tooling.
# The round trip through JPEG is the flatten: `sips` has no composite operation, and JPEG cannot
# carry alpha, so the encoder does the compositing. The mark is a night sky, so the black matte it
# composites onto is the artwork's own background rather than a visible box.
echo "==> flattening (the alpha channel must go)"
sips -s format jpeg -s formatOptions best "$MASTER" --out "$WORK/flat.jpg" >/dev/null
sips -s format png "$WORK/flat.jpg" --out "$WORK/flat.png" >/dev/null

if sips -g hasAlpha "$WORK/flat.png" | grep -q "hasAlpha: yes"; then
  echo "FATAL: the flattened master still has an alpha channel." >&2
  exit 1
fi

# The Apple badge, top-left. This device IS the iOS backend, and without it the phone's tile is
# identical to the web app's — the owner asked for the platform to be visible at a glance.
echo "==> compositing the Apple mark (top-left)"
swift "$REPO/bin/compose_app_icon.swift" "$WORK/flat.png" "$WORK/badged.png"
# Re-flatten: AppKit writes an alpha channel back in even when every pixel is opaque, and an icon
# with alpha is the exact defect the check above exists to catch.
sips -s format jpeg -s formatOptions best "$WORK/badged.png" --out "$WORK/badged.jpg" >/dev/null
sips -s format png "$WORK/badged.jpg" --out "$WORK/flat.png" >/dev/null
if sips -g hasAlpha "$WORK/flat.png" | grep -q "hasAlpha: yes"; then
  echo "FATAL: the badged master still has an alpha channel." >&2
  exit 1
fi

# Base name -> the two scales iOS resolves by suffix. ⚠ `CFBundleIconFiles` lists the BASE names
# only; iOS appends @2x/@3x and .png itself. Listing full filenames there is a common way to end up
# with a silently empty icon.
emit() {  # emit <basename> <@2x px> <@3x px>
  sips -Z "$2" "$WORK/flat.png" --out "$OUT/$1@2x.png" >/dev/null
  sips -Z "$3" "$WORK/flat.png" --out "$OUT/$1@3x.png" >/dev/null
  echo "    $1@2x.png ($2px)  $1@3x.png ($3px)"
}

echo "==> writing the icon set"
emit AppIcon60x60 120 180   # home screen
emit AppIcon40x40  80 120   # Spotlight
emit AppIcon29x29  58  87   # Settings

# The App Store / large slot. Harmless in a Simulator build and required the moment this is ever
# archived, so it is written now rather than discovered missing later.
sips -Z 1024 "$WORK/flat.png" --out "$OUT/AppIcon1024.png" >/dev/null
echo "    AppIcon1024.png (1024px)"

echo "==> done: $OUT"
