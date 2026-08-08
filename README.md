# dg-research-ios

The iOS track for Super Research: an iOS-Simulator browser substrate, a vendored Firestore
contract layer, and a native app the owner uses.

## ⛔ A8 — AMENDED, and the guard is RED on purpose

⚠ **Read this before you run the suite.** `purity.assert_pristine()` **fails right now, deliberately**,
and its failure text will tell you to do the wrong thing.

* **`dg-research-backend` is read-only.** Not a line. Vendor rather than edit; ask if you need it changed.
* **`dg-research` is writable with the owner's say-so, per change** — the owner lifted A8 for frontend
  work the iOS side needed, and two commits are pushed. So both guarded HEADs have moved and the guard
  says so, correctly.
* ⛔ **Do NOT regenerate `fixtures/a8_baseline.json` to make it green.** That is the one response that
  destroys the guard's value: the next *unauthorised* change would then look identical to this
  authorised one.
* ⛔ **Do NOT `git stash pop` in either repo.** The guard also prints, once per file, that a backend
  change *"was DISCARDED … recover it before doing anything else."* **That message is stale.** The wave
  was measured against `origin/master`, found to be a superseded copy, and stashed with a backup;
  `dg-research-backend` is clean and level with its remote. See `docs/DEVIATIONS.md`.
* **`bin/all_gates.sh` collects failures rather than aborting**, so every other gate still runs. **A8 red
  is the only acceptable failure; everything else must pass.**

The full reasoning is `EmulatorRecipe.md` §0. What A8 still enforces, and how:

```bash
PYTHONPATH=. .venv/bin/python -m pytest emubackend/tests -q      # 186 tests
PYTHONPATH=. .venv/bin/python -c "from emubackend import purity; purity.assert_pristine()"
```

`purity.assert_pristine()` pins both repos' `HEAD`, flags any tracked-file change, flags any
*new* untracked file, and content-digests `build/`, `dist/` and `superresearch.egg-info/` —
because those are `.gitignore`d in the backend, so a write there is invisible to
`git status` rather than harmless. See `docs/DEVIATIONS.md`.

## Layout

| Path | What |
|---|---|
| `emubackend/berepo.py` | read-only `sys.path` bridge to the BE checkout |
| `emubackend/purity.py` | the A8 guard |
| `emubackend/substrate/iwdp.py` | DOM/read channel — WebKit remote inspector via `ios_webkit_debug_proxy` |
| `emubackend/substrate/hid.py` | trusted-input channel — AXe |
| `emubackend/substrate/geometry.py` | CSS-pixel → screen-point mapping, measured not assumed |
| `emubackend/substrate/runtime_js.py` | the injected in-page runtime (`window.__sr`) |
| `emubackend/substrate/backend.py` | `BrowserBackend` ABC + `IOSSimulatorBackend` |
| `emubackend/substrate/page_shim.py` | the Playwright-`Page`-shaped surface ported code calls |
| `emubackend/contract/identity.py` | A10 second-device identity; guarded state dir |
| `emubackend/contract/_keystore_vendored.py` | generated — `bin/vendor_auth.py`, do not hand-edit |
| `emubackend/contract/values.py` | Firestore REST value encoding |
| `emubackend/contract/rest.py` | REST transport + the 401/403 credential heal |
| `emubackend/contract/events.py` | `pipeline_events` shape + the monotonic `seq` guard |
| `emubackend/contract/pending_decision.py` | the five `pendingDecision` clobber rules |
| `emubackend/contract/fixtures.py` | golden-fixture capture / normalise / compare |
| `bin/b0a_gate.py` | the B0a substrate gate |
| `bin/b1_smoke.py` | the B1 seam smoke test |
| `bin/mutate.py` | the mutation harness (every guard must be provably breakable) |
| `fixtures/b0a/` | the probe page |
| `docs/FIRESTORE_CONTRACT.md` | the executable spec for pairing / queue / events |
| `docs/DEVIATIONS.md` | where and why this repo departs from `EmulatorRecipe.md` |

Everything lives under the single `emubackend` package on purpose: with the BE checkout on
`sys.path`, the names `research`, `models`, `prompts`, `vision`, `vision_test`, `narrate`,
`selfheal`, `auth`, `scripts` are taken, and `tests`, `tools`, `agent`, `build`, `dist` would
merge as implicit namespace packages.

## Setup

```bash
uv venv --python 3.13
uv pip install pytest websocket-client
brew install ios-webkit-debug-proxy cameroncooke/axe/axe
```

Optional: `DG_BE_CHECKOUT=/path/to/dg-research-backend` (defaults to the sibling directory).

## B0a — substrate gate: **PASS** (2026-07-29)

iPhone 17 Pro · iOS 26.5 · Xcode 26.6 · IWDP 1.9.2 · AXe 1.8.0 · screen 402×874pt

| Case | Result |
|---|---|
| A — trusted tap, plain page | **PASS** — `isTrusted`, hit `t1`, top chrome 62pt |
| B — trusted tap, scrolled page | **PASS** — scrolled to y≈1740, `innerHeight` 714→754 (iOS 26 collapses the *bottom* toolbar), hit `t2` |
| C — trusted tap, keyboard open | **PASS** — `visualViewport.height` 714→377 while `innerHeight` stayed 714, hit `t3` |
| D — cookie survives `simctl` reboot | **PASS** — reached disk in 3s, present after shutdown/boot |

```bash
python bin/b0a_gate.py --udid <UDID>        # writes artifacts/b0a/verdict.json
```

### What the gate taught us (all four are in the code as guards)

1. **The Simulator is not auto-discovered by IWDP.** A bare `ios_webkit_debug_proxy` returns
   an empty device list. It needs `-s unix:<socket>`, and the socket is at a *randomly named*
   `/private/var/tmp/com.apple.launchd.<random>/com.apple.webinspectord_sim.socket`, read from
   the Simulator's own launchd job — **reallocated on every boot**. IWDP's own `--help`
   example shows a `/private/tmp/` path that does not exist.
2. **WebKit multiplexes the inspector behind the `Target` domain** (since iOS 12.2). A bare
   `Runtime.evaluate` is rejected with *"'Runtime' domain was not found"* — which reads as a
   missing feature rather than a missing envelope.
3. **A tap is a sequence, and its `click` is late.** Tap *N*'s `click` can land in the event
   list *ahead of* tap *N+1*'s `pointerdown`, carrying integer-rounded coordinates. Taking
   "the first trusted event" therefore silently returns the previous tap's position — it
   produced a derived scale of 241 instead of 1.
4. **The keyboard shrinks `visualViewport.height`, not `window.innerHeight`.** Any
   "is it visible" check built on `innerHeight` will aim at a point behind the keyboard.
   It does *not* change the coordinate transform, only what is visible.

Plus one operational rule: **never hard-stop a Simulator straight after a login.** Cookies
take a few seconds to reach `Cookies.binarycookies`; `simctl shutdown` before the flush loses
the session, which is indistinguishable from "the session did not persist".

## B1 — the seam: **built and proven on device** (2026-07-29)

`bin/b1_smoke.py` → **16/16 PASS** against a real Simulator (`artifacts/b1/smoke.json`):
runtime injection + idempotent re-injection, real mobile viewport, the handle registry, a
**trusted** `PageShim` click landing on the intended element, the calibration overlay cleaned
up afterwards, editor-aware `fill()`, a detached handle raising, and gesture scroll
invalidating the calibration.

**The trap this phase found — no desktop analogue.** IWDP will `Runtime.evaluate` in a
**background** MobileSafari tab, but AXe taps only reach the **foreground** one. A tap computed
from a background tab's DOM therefore lands on different content *and reports success*, and
nothing else in the stack notices. Every input path asserts foreground first. The consequence
for the P2 tab model is concrete: **one Simulator per platform, or strictly sequential
single-tab** — `switch_to` and `open_isolated_tab` are `BackendUnsupported`, because
MobileSafari's tab switcher is UI-only.

**Degraded on purpose**, each raising `BackendUnsupported` with the alternative named: private
tabs, tab switching, **host→guest file upload** (no `DOM.setFileInputFiles` equivalent, and a
real `<input type=file>` tap opens the native document picker — so NotebookLM source upload
stays on the desktop backend), download capture, OS clipboard (in-page `copy` interception
only), and `mouse.move` (touch has no hover).

## B1 — the contract layer: **done** (2026-07-29)

**A10 device identity.** Measured before copying: of the backend's four `auth/` modules only
`keystore.py` touches the filesystem (21 refs), so `pairing.py`, `credentials.py` and
`v2_flow.py` are *imported*, not duplicated. `keystore.py` is vendored by `bin/vendor_auth.py` —
a programmatic copy with **two** substituted lines and the upstream sha256 recorded, so drift
raises an alarm. Copied rather than reimplemented because a rewrite drops its subtler behaviours
(the keyring shadow purge on write, the retry-OSError-but-not-ValueError file loader, the audit
written *before* deletion), and a credential store is the wrong place to find that out.

**Pointing this keystore at `~/.super-research` is refused, not warned about** — sharing it would
overwrite the production daemon's device identity, or make this pipeline authenticate as the same
`deviceId` and race it on one `devices/{id}/queue`.

**The contract core**, as pure tested predicates: REST value encoding (`int` → `integerValue` or
rules deny it; `datetime` refused rather than coerced; field delete = updateMask-without-body),
the `pipeline_events` shape (`seq` is epoch-millis-forced-monotonic, **not** a counter; `phase=0`
is written; `agent=''` and empty `data` are omitted), the five `pendingDecision` clobber rules,
and the REST transport with the 401/403 credential heal and the two-query device union.

### Two things worth knowing

**Verifying beat trusting.** These were built from `docs/FIRESTORE_CONTRACT.md`, then checked
against `research.py` — which found a real bug in the first cut: upstream normalises with
`(agent or "").lower() or None`, so the agent comparison is case-insensitive *and* `''` means an
unconditional clear. Without both, the keep-guard is inverted for `''` and fires spuriously on a
casing difference.

**One recipe assumption does not hold.** §0.5.7b says to start capturing real backend runs now.
`backend.log` is 25 MB and contains no emitted event stream, so there is nothing to mine —
capturing a real run needs a backend edit (forbidden) or read credentials (owner-gated). The
engine and our-own-client capture are delivered; that half is a checkpoint.

### Still owed for B1

- the P0–P3 orchestrator itself (`emubackend/pipeline.py`), with every mutating intent written
  already wrapped in a `_selfheal_try`-shaped wrapper carrying an `outcome_predicate`
- a golden fixture captured from a real backend run — **owner-gated**, see above

## Testing

```bash
PYTHONPATH=. .venv/bin/python -m pytest emubackend/tests -q   # 186 tests
python bin/mutate.py                                          # 43 mutations, all must be CAUGHT
python bin/b0a_gate.py --udid <UDID>                          # substrate gate, needs a Simulator
python bin/b1_smoke.py --udid <UDID>                          # seam smoke, needs a Simulator
```

Every guard here protects against a specific silent-failure mode, so `bin/mutate.py` breaks
each one and asserts the matching test turns red. A guard nobody proved can fail is decoration.
