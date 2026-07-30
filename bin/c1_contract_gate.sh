#!/usr/bin/env bash
# The app's contract writes, evaluated by the REAL rules and diffed against the GOLDEN FIXTURE.
#
# Two independent things, both necessary and neither sufficient:
#
#   1. the emulator runs the committed firestore.rules, so an accepted write is one the real project
#      accepts — this catches a write that is well-formed but forbidden;
#   2. the golden fixture was captured from real backend runs, so the diff catches a write that is
#      permitted but WRONG — the wrong sequence, a missing event, phase 0 dropped.
#
# Rules alone would pass a pipeline that emitted nothing. The fixture alone would pass a sequence the
# rules reject. With no e2e in existence this pair is the only mechanical proof that the app's
# implementation of the contract is faithful rather than plausible.
#
# Usage: bin/c1_contract_gate.sh <UDID>
set -euo pipefail

# Contract writes from a REAL platform run: pass a platform and its manifest through to c1_in_app.sh,
# which routes real platforms into the app (the only bundle with the owner's session). The write SEQUENCE is
# platform-independent — same pipeline, same emitter — so the golden fixture applies unchanged, and that is
# the point: it proves the contract holds for a run that actually drove a real platform.
PLATFORM="${2:-mockplatform}"
MANIFEST="${3:-}"
UDID="${1:?usage: c1_contract_gate.sh <UDID>}"
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUT="$REPO/artifacts/c1contract"
PY="$REPO/.venv/bin/python"
mkdir -p "$OUT"

UID_VALUE="owner-uid-c1"
RESEARCH_ID="rid-c1"
DEVICE_ID="dev-c1"

cleanup() {
  [ -n "${EMU_PID:-}" ] && kill "$EMU_PID" 2>/dev/null || true
  # Same reason as above: the recorded pid is not the whole emulator.
  for port in 8181 9199 4400 4500 9150; do
    lsof -ti:"$port" 2>/dev/null | xargs -r kill -9 2>/dev/null || true
  done
}
trap cleanup EXIT

# ⚠ Killed by PORT, not by the recorded pid. `firebase emulators:start` spawns java children that
# outlive the shell's `$!`, so the trap left a previous emulator running — and the gate then read TWO
# runs' events (17 where 9 were expected) and reported it as an emitter fault. Freeing the ports first
# is what makes each invocation actually independent.
for port in 8181 9199 4400 4500 9150; do
  lsof -ti:"$port" 2>/dev/null | xargs -r kill -9 2>/dev/null || true
done
sleep 1

echo "==> starting the Firestore + Auth emulators"
(cd "$REPO" && firebase emulators:start --only firestore,auth \
  --config firebase.emulator.json --project demo-sr > "$OUT/emulator.log" 2>&1 &
  echo $! > "$OUT/emulator.pid")
EMU_PID="$(cat "$OUT/emulator.pid")"
for _ in $(seq 1 60); do
  curl -fsS -o /dev/null "http://127.0.0.1:8181/" && curl -fsS -o /dev/null "http://127.0.0.1:9199/" && break
  sleep 1
done
curl -fsS -o /dev/null "http://127.0.0.1:8181/" || { echo "!! emulator never came up"; exit 1; }

echo "==> seeding the research document as the SERVER would"
"$PY" "$REPO/bin/c1_contract_seed.py" "$UID_VALUE" "$RESEARCH_ID" "$DEVICE_ID" \
  > "$OUT/seed.json"
CUSTOM_TOKEN="$("$PY" -c "import json,sys; print(json.load(open('$OUT/seed.json'))['customToken'])")"

echo "==> running the app, emitting the run's contract writes"
# Passed through simctl's child environment, so the app authenticates as the synthetic device the
# rules expect rather than as an ambient principal.
SIMCTL_CHILD_SR_EMULATOR_HOST="127.0.0.1:8181" \
SIMCTL_CHILD_SR_CUSTOM_TOKEN="$CUSTOM_TOKEN" \
SIMCTL_CHILD_SR_UID="$UID_VALUE" \
SIMCTL_CHILD_SR_RESEARCH_ID="$RESEARCH_ID" \
SIMCTL_CHILD_SR_DEVICE_ID="$DEVICE_ID" \
  bash "$REPO/bin/c1_in_app.sh" "$UDID" "${PLATFORM:-mockplatform}" "${MANIFEST:-}" 2>&1 \
    | tee "$OUT/run.log" || true

echo "==> diffing the emitted sequence against the golden fixture"
"$PY" "$REPO/bin/c1_contract_verify.py" "$OUT/run.log" "$UID_VALUE" "$RESEARCH_ID" \
  | tee "$OUT/report.txt"
