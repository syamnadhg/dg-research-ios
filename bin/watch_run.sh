#!/usr/bin/env bash
# Tail the app's own log, live.
#
# ⛔ Use this instead of `log show --last Nm`. `log show` rescans the whole system buffer and takes
# 20-60 SECONDS per invocation on this machine, which during a live run means every observation is a
# minute stale and costs a minute to get. `log stream` with a predicate is instant and continuous —
# the difference between watching a run and periodically guessing at one.
#
# Usage:
#   bin/watch_run.sh <UDID>            # every [SR] line
#   bin/watch_run.sh <UDID> tier       # only lines containing "tier"
#
# The per-run trace file is the durable record and outlives the process:
#   ls -t ~/Library/Developer/CoreSimulator/Devices/<UDID>/data/Containers/Data/Application/*/Library/Application\ Support/SuperResearch/runs/
set -euo pipefail

UDID="${1:?usage: watch_run.sh <UDID> [filter]}"
FILTER="${2:-}"

echo "==> streaming [SR] lines from $UDID (Ctrl+C to stop)"
if [ -n "$FILTER" ]; then
  echo "==> filtered to lines containing: $FILTER"
fi

# `composedMessage` rather than `eventMessage`: NSLog formats its arguments, and the predicate has to
# match the FORMATTED line or every `%@` line is missed.
xcrun simctl spawn "$UDID" log stream \
  --style compact \
  --predicate 'composedMessage CONTAINS "[SR]"' \
| { if [ -n "$FILTER" ]; then grep --line-buffered -i -- "$FILTER"; else cat; fi; }
