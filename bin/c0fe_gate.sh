#!/usr/bin/env bash
# The C0-FE gate: the device pairs end to end against the REAL firestore.rules, with no credentials.
#
# Starts the Firestore + Auth emulators and the frontend-route fixture, runs the Swift pairing gate,
# and writes artifacts/c0fe/verdict.json.
#
# Why this is a real gate and not a mock: the rules ARE the contract. Every write the *device* makes
# here is evaluated by the committed ruleset, so an accepted write is one the real project accepts.
# What stays owner-gated — and what the verdict records as unverified — is whether the DEPLOYED ruleset
# matches this repo's file, and whether the real /api/devices/initiate-pair behaves like the fixture.
#
# Usage: bin/c0fe_gate.sh
set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUT="$REPO/artifacts/c0fe"
mkdir -p "$OUT"
PY="$REPO/.venv/bin/python"

cleanup() {
  [ -n "${FIXTURE_PID:-}" ] && kill "$FIXTURE_PID" 2>/dev/null || true
  [ -n "${EMU_PID:-}" ] && kill "$EMU_PID" 2>/dev/null || true
}
trap cleanup EXIT

echo "==> starting the Firestore + Auth emulators"
(cd "$REPO" && firebase emulators:start --only firestore,auth \
  --config firebase.emulator.json --project demo-sr > "$OUT/emulator.log" 2>&1 &
  echo $! > "$OUT/emulator.pid")
EMU_PID="$(cat "$OUT/emulator.pid")"

# Waited for rather than slept past: emulator start time varies with machine load, and a fixed sleep
# either wastes time or fails intermittently — the second being much worse in a gate.
for _ in $(seq 1 60); do
  if curl -fsS -o /dev/null "http://127.0.0.1:8181/" \
     && curl -fsS -o /dev/null "http://127.0.0.1:9199/"; then
    break
  fi
  sleep 1
done
curl -fsS -o /dev/null "http://127.0.0.1:8181/" || { echo "!! firestore emulator never came up"; exit 1; }
curl -fsS -o /dev/null "http://127.0.0.1:9199/" || { echo "!! auth emulator never came up"; exit 1; }
echo "==> emulators up (firestore :8181, auth :9199)"

echo "==> starting the frontend-route fixture"
"$PY" "$REPO/bin/c0fe_fixture.py" > "$OUT/fixture.log" 2>&1 &
FIXTURE_PID=$!
for _ in $(seq 1 30); do
  curl -fsS -o /dev/null -X POST "http://127.0.0.1:8907/nope" 2>/dev/null && break
  # A 404 means it is listening, which is what we need; curl -f treats it as failure, so the check is
  # "did we get any HTTP response at all".
  curl -sS -o /dev/null -w "" "http://127.0.0.1:8907/" 2>/dev/null && break
  sleep 0.5
done

echo "==> running the Swift pairing gate against the real rules"
set +e
(cd "$REPO/ios" && SR_EMULATOR_HOST="127.0.0.1:8181" \
  swift test --filter C0FEPairingGateTests 2>&1) | tee "$OUT/gate.log"
STATUS="${PIPESTATUS[0]}"
set -e

PASSED="$(grep -c "' passed (" "$OUT/gate.log" || true)"
FAILED="$(grep -c "' failed (" "$OUT/gate.log" || true)"

"$PY" - "$OUT/verdict.json" "$PASSED" "$FAILED" "$STATUS" <<'PY'
import json, sys
path, passed, failed, status = sys.argv[1], int(sys.argv[2]), int(sys.argv[3]), int(sys.argv[4])
json.dump({
    "gate": "C0-FE",
    "what": "the device pairs end to end against the committed firestore.rules, no credentials",
    "passed": passed,
    "failed": failed,
    "ok": failed == 0 and status == 0 and passed > 0,
    "verified": [
        "the server mints the code; the device only formats it for display",
        "the pending document is readable with NO session (the bootstrap)",
        "signInWithCustomToken yields a session carrying the deviceId claim",
        "the atomic pair-confirm is accepted and REMOVES expireAt (cancels the TTL)",
        "a write with one extra field is rejected 403 by the real rules",
        "the steady-state heartbeat keeps being accepted after expireAt is gone",
    ],
    "still_owner_gated": [
        "whether the DEPLOYED ruleset matches fixtures/rules/firestore.rules",
        "whether the real /api/devices/initiate-pair behaves like bin/c0fe_fixture.py",
        "the FE Account page showing this device Online (needs the real project)",
    ],
}, open(path, "w"), indent=2)
print(f"\n==> verdict: {passed} passed / {failed} failed -> {path}")
PY

exit "$STATUS"
