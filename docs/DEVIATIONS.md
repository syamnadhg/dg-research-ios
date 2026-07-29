# Deliberate deviations from `EmulatorRecipe.md`

The recipe is the plan of record. Where this repo departs from it, the departure is
recorded here with the reason, so a later reader can tell a considered choice from a
mistake. Nothing here weakens A8; two of the three strengthen it.

---

## D-1 — The BE is reached by `sys.path` injection, not `pip install -e`

**Recipe says** (§0.5, decision A8): the BE is a read-only dev dependency,
`-e ../dg-research-backend`.

**We do**: `emubackend.berepo.ensure_on_path()` appends the checkout to `sys.path`.

**Why**: the BE's `[build-system]` is `setuptools.build_meta`. `pip install -e` executes
that build backend **inside the BE checkout** and regenerates `superresearch.egg-info/`
there. The production `--serve` daemon runs from that same checkout. Worse, the BE's
`.gitignore` covers `*.egg-info/`, `build/` and `dist/`, so the write would be invisible
to `git status` — hidden rather than harmless.

A path append reaches the identical importable surface with zero writes. It is strictly
safer and strictly simpler, so there is no trade-off to weigh.

**Verified cheap**: walking `research.py`'s `ast.Module.body` shows its only non-stdlib
*module-level* imports are `models` and `prompts`, both BE-local. So no third-party
package is needed to `import research` at all. (A grep would have answered this wrongly
by also matching function-local imports — which is the whole reason `import research` is
fast: `patchright` loads lazily inside `Browser.start`, `google.cloud` imports are
function-local, and the entrypoint is `__main__`-guarded.)

---

## D-2 — The namespace-hazard list is wider than the recipe states

**Recipe says**: never create a top-level `models`, `auth`, or `scripts` module.

**Measured**: the BE checkout on `sys.path` claims **nine** module/package names —
`research`, `models`, `prompts`, `vision`, **`vision_test`**, `narrate`, `selfheal`,
`auth`, `scripts` — and additionally contains *plain* directories with no `__init__.py`:
`tests`, `tools`, `agent`, plus the build artifacts `build/` and `dist/`. Python 3 merges
same-named plain directories across `sys.path` entries into a single implicit namespace
package, so reusing any of those names is also unsafe, in a quieter and more confusing
way.

`build` deserves a specific note, because it was found by the test rather than by
reading: the BE's `build/` contains a **complete copy of the sources**
(`build/lib/research.py`, …), so `import build` resolves. Any packaging run in *this*
repo would create a second `build/`, and the two would merge into one namespace package
spanning both checkouts. That is not a technicality — it is a live foot-gun for anyone
who later runs `python -m build` here.

**We do**: everything this repo owns lives under the single `emubackend` package —
including its tests (`emubackend/tests/`), so a collision is impossible by construction
rather than avoided by vigilance. `bin/` holds shell entry points and is not importable.

---

## D-3 — A8 is enforced by a test, not by discipline

**Recipe says**: A8 as a prose rule; the definition of done requires that both repos
show zero modifications.

**We do**: `emubackend/purity.py` + `emubackend/tests/test_a8_purity.py` fingerprint both
guarded repos against `fixtures/a8_baseline.json`.

**Why the obvious implementation is not enough**: `git status` alone would miss the most
likely violation. The BE ignores `build/`, `dist/` and `*.egg-info/`, so the exact
failure D-1 describes is invisible to it. The guard therefore also content-digests those
directories, treats *new untracked files* as violations, and pins `HEAD` (committing to
the BE is a modification even if the tree ends up clean).

`queues/` is handled differently on purpose: the daemon writes a run directory there on
every real run, so digesting it against a stored baseline would go red for reasons
unrelated to us. It gets a **session-scoped** guard (`purity.no_queue_writes()`) instead
— nothing should appear there during our own work, which is the assertion that actually
catches `setup_firestore_run`.

---

## D-4 — `setup_firestore_run` and `init_firebase` are statically banned

**Recipe says**: never call `setup_firestore_run` (it writes `owner.json` into the BE
checkout's `queues/`, which the daemon's disk-restore scans).

**We do**: the same, plus `berepo.FORBIDDEN_BE_SYMBOLS` records both symbols with their
reasons and a test greps this repo for calls to them.

**Why**: this is the trap the recipe rates as most likely to dead-end the first
queue-triggered e2e, and "we wrote it down" is not a control. `init_firebase` is included
for the A10 reason — it would authenticate as the production daemon's `deviceId`,
putting two listeners on one `devices/{id}/queue`.

## Deep research is not a composer toggle on mobile web — on either platform

**Measured 2026-07-29** against real signed-in accounts in the app's web views, by opening every
plausible container rather than by inference:

| Where I looked | ChatGPT | Gemini |
|---|---|---|
| composer control row at rest | plus / model picker / dictation / voice | upload / microphone / send |
| `composer-plus-btn` menu | Camera, Photos, Files | — |
| model picker (`Pro`) | Instant 5.5, Medium, High, Extra High, Pro, GPT-5.6 Sol | — |
| sidebar (signed in) | Home, Search, New chat, Library, Projects, Scheduled, Plugins, Recents | — |
| mode picker (`bard-mode-menu-button`) | — | opens a **mode** list; Deep Research is one of them |

So **`deep_research_toggle` cannot be satisfied on either platform as specified.** The manifest key's
contract is one tap judged by `aria-pressed`/`aria-checked` (`phases.py::_toggle_on_predicate`), and:

* **Gemini** has the capability but the wrong shape — Deep Research is a *mode* selected from a menu,
  so there are two taps and no pressed state on the opener.
* **ChatGPT** does not expose it in the mobile web composer at all. The word appears in the
  *signed-out* marketing drawer and nowhere in the signed-in UI.

Why this matters more than a missing selector: capturing the nearest plausible control makes the run
tap something, read no pressed state, fail the predicate, correctly decline to escalate (toggles are
shadow-only without a positive off-signal) — and then complete a full P0–P3 **with deep research off
while reporting success**. That is the same failure the `enable_deep_research` idempotence guard was
written to prevent, arriving through a different door, and it is invisible in the output except as a
shallower answer.

Three ways out, and the choice is a product decision rather than a capture problem:

1. **Give the phase a mode-select shape** — open picker, choose item, verify by the picker's own label
   changing. Fits Gemini exactly. Does nothing for ChatGPT.
2. **Ask for a desktop surface.** The app pins an iPhone Safari 17 user agent; the desktop composer is
   where ChatGPT's research controls live. Untested, and a wider blast radius than it looks — every
   captured selector would need re-verifying against the desktop DOM.
3. **Accept P2 without the toggle on iOS** and say so, rather than shipping a run that silently does
   ordinary chat under a deep-research label.
