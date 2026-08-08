#!/usr/bin/env bash
# Bring up THIS project's simulator — and make it the one Simulator.app opens next time.
#
# ⚠ THE INCIDENT. On 2026-08-07 the Mac rebooted. CoreSimulatorService found SR-iPhone17Pro in a
# stale `Booted` state and shut it down; Simulator.app then booted its own remembered
# `CurrentDeviceUDID`, which pointed at a stock `iPhone 17` that had never had anything installed.
# The owner opened the Simulator, saw a clean home screen and concluded the app had vanished. It had
# not — it was untouched on a device that was no longer booted.
#
# Two things make that easy to repeat on this Mac: there are THREE devices whose names begin
# "iPhone 17" across two runtimes, and Simulator.app rewrites `CurrentDeviceUDID` every time anyone
# switches device in its menu. So the remembered device drifts, silently, and the only symptom is a
# blank home screen.
#
# This script is the one way to bring the right phone up. It resolves by NAME (not by "first
# booted"), boots it, and pins Simulator.app's remembered device so the next plain open of the
# Simulator lands here too.
#
# Usage:
#   bin/sim.sh              # boot it, pin it, open Simulator.app
#   bin/sim.sh --check      # report only; change nothing, exit 1 if something is off
#   bin/sim.sh --udid       # print ONLY the udid, boot nothing — for `UDID=$(bin/sim.sh --udid)`
#
# ⚠ `--udid` exists so that no script and no document ever hardcodes one again. Every command in
# EmulatorRecipe.md Appendix B pinned the old device's UDID as a literal, which is what let the
# incident above go unnoticed: the commands kept running, against a phone with none of the logins.
set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
NAME="SR-iPhone17Pro"
BUNDLE_ID="com.distributedglobal.superresearch"
CHECK=""
[ "${1:-}" = "--check" ] && CHECK="1"

udid_for_name() {
  # Anchored on "NAME (" so "iPhone 17" cannot match "iPhone 17 Pro Max".
  xcrun simctl list devices \
    | sed -n "s/^ *${NAME} (\([0-9A-Fa-f-]\{36\}\)).*/\1/p" \
    | head -1
}

UDID="$(udid_for_name)"
if [ -z "$UDID" ]; then
  echo "FATAL: no simulator named '$NAME'. Create it, or update NAME in this script." >&2
  exit 1
fi

# ⚠ Before any other output. `--udid` is meant for `UDID=$(bin/sim.sh --udid)`, so a single stray
# echo above this line would be captured into the variable and every downstream simctl call would
# fail on a UDID with a banner glued to it. The missing-device case still exits non-zero above, so
# command substitution yields an empty string rather than a plausible-looking wrong one.
if [ "${1:-}" = "--udid" ]; then
  echo "$UDID"
  exit 0
fi

# Where the app really is, read off the filesystem rather than via simctl — `get_app_container`
# needs the device booted, and "is it shut down" is exactly the question being asked.
APP_ON=""
for d in "$HOME/Library/Developer/CoreSimulator/Devices"/*/; do
  if grep -ql "$BUNDLE_ID" "$d"data/Containers/Bundle/Application/*/*.app/Info.plist 2>/dev/null; then
    APP_ON="$APP_ON $(basename "$d")"
  fi
done
APP_ON="$(echo "$APP_ON" | tr -s ' ' | sed 's/^ //;s/ $//')"

BOOTED="$(xcrun simctl list devices booted | sed -n 's/.*(\([0-9A-Fa-f-]\{36\}\)) (Booted).*/\1/p' | tr '\n' ' ')"
REMEMBERED="$(defaults read com.apple.iphonesimulator CurrentDeviceUDID 2>/dev/null || echo "(unset)")"

echo "device      $NAME"
echo "udid        $UDID"
echo "app is on  ${APP_ON:-(nowhere)}"
echo "booted     ${BOOTED:-(none)}"
echo "remembered  $REMEMBERED"

# The check that would have caught the incident before it cost an hour: the app lives on a device
# that is not the one Simulator.app will open.
PROBLEM=""
case " $APP_ON " in
  *" $UDID "*) : ;;
  "  ") echo "⚠ the app is not installed on ANY simulator — run bin/build_app.sh $UDID" ;;
  *) echo "⚠ the app is installed on a DIFFERENT device than '$NAME'"; PROBLEM="1" ;;
esac
if [ "$REMEMBERED" != "$UDID" ]; then
  echo "⚠ Simulator.app would open $REMEMBERED, not '$NAME' — this is the blank-home-screen trap"
  PROBLEM="1"
fi

if [ -n "$CHECK" ]; then
  [ -n "$PROBLEM" ] && exit 1
  echo "ok"
  exit 0
fi

case " $BOOTED " in
  *" $UDID "*) echo "==> already booted" ;;
  *)
    echo "==> booting"
    xcrun simctl boot "$UDID" >/dev/null 2>&1 || true
    xcrun simctl bootstatus "$UDID" -b >/dev/null 2>&1 || true
    ;;
esac

# Pin it. This is the line that stops the next reboot picking a different phone: Simulator.app boots
# whatever this default names, and nothing else in the repo ever set it.
defaults write com.apple.iphonesimulator CurrentDeviceUDID -string "$UDID"
open -a Simulator
echo "==> $NAME is up and is now the device Simulator.app opens by default"
