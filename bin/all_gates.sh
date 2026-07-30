#!/usr/bin/env bash
# Run every gate, in dependency order, and fail if any of them fails.
#
# This exists because gates that are only ever run by hand are gates that drift out of date silently.
# In particular `coverage_gate.py` is *forward-looking* — it passes today and is designed to start
# failing the moment a real platform clears C0 without an in-app run — which is worth nothing unless
# something runs it without being asked.
#
# Ordered so a failure lands on the cheapest thing that broke: unit tests, then the credential-free
# contract gates, then the Simulator gates, then coverage last (it reads the others' verdicts).
#
# Usage:
#   bin/all_gates.sh                 # unit tests + emulator gates + coverage (no Simulator)
#   bin/all_gates.sh <UDID>          # everything, including the Simulator and in-app gates
set -uo pipefail

UDID="${1:-}"
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PY="$REPO/.venv/bin/python"
FAILED=()

run() {
  local name="$1"; shift
  echo ""
  echo "═══ $name"
  if "$@"; then
    echo "─── $name: PASS"
  else
    echo "─── $name: FAIL"
    FAILED+=("$name")
  fi
}

# A8 first and unconditionally. Everything else is meaningless if the existing repos were touched.
run "A8 isolation (BE/FE unmodified)" \
  "$PY" -c "from emubackend import purity; purity.assert_pristine()"

run "python unit tests" "$PY" -m pytest "$REPO/emubackend/tests" -q
run "swift unit tests" bash -c "cd '$REPO/ios' && swift test 2>&1 | tail -3"

# ⚠ `rules_verify.py` expects an emulator to already be running, and the first version of this runner
# wrapped it in `|| true` — which meant it reported PASS with no emulator at all. A gate runner that
# can mask a failure is worse than no runner, so it gets a real lifecycle: ports freed, emulator
# started, waited for, and the exit status passed through.
rules_with_emulator() {
  for port in 8181 9199 4400 4500 9150; do
    lsof -ti:"$port" 2>/dev/null | xargs -r kill -9 2>/dev/null || true
  done
  sleep 1
  (cd "$REPO" && firebase emulators:start --only firestore,auth \
    --config firebase.emulator.json --project demo-sr >/tmp/sr-rules-emu.log 2>&1 &)
  for _ in $(seq 1 60); do
    curl -fsS -o /dev/null "http://127.0.0.1:8181/" && break
    sleep 1
  done
  if ! curl -fsS -o /dev/null "http://127.0.0.1:8181/"; then
    echo "    the emulator never came up — see /tmp/sr-rules-emu.log"
    return 1
  fi
  local status=0
  "$PY" "$REPO/bin/rules_verify.py" || status=$?
  for port in 8181 9199 4400 4500 9150; do
    lsof -ti:"$port" 2>/dev/null | xargs -r kill -9 2>/dev/null || true
  done
  return $status
}

# Credential-free, so these run everywhere.
run "rules (real firestore.rules, emulator)" rules_with_emulator
run "C0-FE pairing (real rules)" bash "$REPO/bin/c0fe_gate.sh"

if [ -n "$UDID" ]; then
  run "B0a substrate (trusted taps)" "$PY" "$REPO/bin/b0a_gate.py" --udid "$UDID"
  run "B1 smoke" "$PY" "$REPO/bin/b1_smoke.py" --udid "$UDID"
  run "e2e P0-P3 + reboot survival" "$PY" "$REPO/bin/e2e_simulator.py" --udid "$UDID"
  run "C0 in-app (WKWebView)" bash "$REPO/bin/c0_in_app.sh" "$UDID"
  run "C1 in-app P0-P3" bash "$REPO/bin/c1_in_app.sh" "$UDID"
  run "C1 contract vs golden fixture" bash "$REPO/bin/c1_contract_gate.sh" "$UDID"
else
  echo ""
  echo "═══ Simulator gates SKIPPED (no UDID given)"
  echo "    B0a, B1, e2e, C0, C1 and the contract gate all need a booted Simulator."
  echo "    Pass a UDID to run them: bin/all_gates.sh \$(xcrun simctl list devices booted | ...)"
fi

# Last, because it reads the C1 verdict the gates above produce.
run "coverage (clause 2: every cleared platform runs in-app)" \
  "$PY" "$REPO/bin/coverage_gate.py"

# Needs no Simulator, so it runs unconditionally. Added after the repo's first push tripped GitHub's
# secret scanner on a Firebase Web API key that had been copied into docs/FIRESTORE_CONTRACT.md while
# documenting the pairing contract — public-by-design key, genuinely low severity, and still something a
# gate should have caught before a human's security alert did.
run "secrets (no credential-shaped literal in a tracked file)" \
  "$PY" "$REPO/bin/secret_scan.py"

echo ""
echo "════════════════════════════════════════════════"
if [ ${#FAILED[@]} -eq 0 ]; then
  echo "ALL GATES PASS"
  exit 0
fi
echo "FAILED: ${FAILED[*]}"
exit 1
