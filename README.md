# dg-research-ios

The iOS track for Super Research: an iOS-Simulator browser substrate, a vendored Firestore
contract layer, and (later) the native app.

## ⛔ The one hard rule (A8)

`dg-research-backend` and `dg-research` are **not modified by this repo. Not a line.** The
backend is a **read-only** dependency, reached through `emubackend.berepo`.

This is enforced, not merely stated:

```bash
PYTHONPATH=. .venv/bin/python -m pytest emubackend/tests -q      # 73 tests
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
| `emubackend/contract/` | ⏳ **not yet written** — the vendored Firestore-contract layer |
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

### Still owed for B1

- the vendored `emubackend/contract/` layer — **one** cohesive copy, never N one-off helpers
- `auth/` vendored with its three hardcoded path constants parameterized (A10)
- the golden-fixture capture harness — start early, fixtures accrue at 1–3 runs/week

The spec for all three is `docs/FIRESTORE_CONTRACT.md`; none of it needs re-deriving from the
backend.

## Testing

```bash
PYTHONPATH=. .venv/bin/python -m pytest emubackend/tests -q   # 73 tests
python bin/mutate.py                                          # 18 mutations, all must be CAUGHT
python bin/b0a_gate.py --udid <UDID>                          # substrate gate, needs a Simulator
python bin/b1_smoke.py --udid <UDID>                          # seam smoke, needs a Simulator
```

Every guard here protects against a specific silent-failure mode, so `bin/mutate.py` breaks
each one and asserts the matching test turns red. A guard nobody proved can fail is decoration.
