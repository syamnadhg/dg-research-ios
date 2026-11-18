#!/usr/bin/env bash
# Pull the run traces off the Simulator and print them.
#
# ⭐ The whole reason `RunLog` writes a FILE. A run takes 30 to 90 minutes and the questions
# afterwards are always the same — which step did it stop at, what did the page hand back, how long
# did each wait take — and a `log stream` nobody attached before the interesting moment cannot
# answer any of them.
#
# Usage:
#   bin/run_log.sh <UDID>              # list the traces, newest last, and print the newest
#   bin/run_log.sh <UDID> <RESEARCH>   # print one research's trace
#   bin/run_log.sh <UDID> --follow     # tail the newest as it is written
set -uo pipefail

UDID="${1:-}"
WHICH="${2:-}"
BUNDLE_ID="com.distributedglobal.superresearch"

if [ -z "$UDID" ]; then
  echo "usage: bin/run_log.sh <UDID> [<researchId>|--follow]" >&2
  exit 2
fi

CONTAINER="$(xcrun simctl get_app_container "$UDID" "$BUNDLE_ID" data 2>/dev/null)"
if [ -z "$CONTAINER" ]; then
  echo "the app is not installed on $UDID (or the Simulator is not booted)" >&2
  exit 1
fi

DIR="$CONTAINER/Library/Application Support/SuperResearch/runs"
if [ ! -d "$DIR" ]; then
  # ⚠ Said plainly rather than as an empty result. "No traces" and "no runs have happened" are the
  # same output otherwise, and only one of them is a problem.
  echo "no run traces yet — $DIR does not exist. A trace appears when a run is CLAIMED." >&2
  exit 1
fi

# Newest last, so the interesting one is at the bottom of the listing.
#
# ⛔ NOT `mapfile`. macOS ships **bash 3.2**, where `mapfile` does not exist — and the failure is
# the worst possible shape for this tool: the array comes back EMPTY, so it reports "no run traces"
# at exactly the moment there are some, which reads as "the run never started".
LOGS=()
while IFS= read -r line; do
  [ -n "$line" ] && LOGS+=("$line")
done < <(ls -t "$DIR"/*.log 2>/dev/null | tail -r)
if [ "${#LOGS[@]}" -eq 0 ]; then
  echo "no run traces in $DIR yet" >&2
  exit 1
fi

echo "==> traces in $DIR"
for f in "${LOGS[@]}"; do
  printf '    %s  (%s lines, last written %s)\n' \
    "$(basename "$f")" "$(wc -l < "$f" | tr -d ' ')" "$(date -r "$f" '+%H:%M:%S')"
done
echo

TARGET="${LOGS[${#LOGS[@]}-1]}"
if [ -n "$WHICH" ] && [ "$WHICH" != "--follow" ]; then
  TARGET="$DIR/run-$WHICH.log"
  if [ ! -f "$TARGET" ]; then
    echo "no trace for research '$WHICH'" >&2
    exit 1
  fi
fi

echo "==> $(basename "$TARGET")"
if [ "$WHICH" = "--follow" ]; then
  exec tail -f "$TARGET"
fi
cat "$TARGET"
