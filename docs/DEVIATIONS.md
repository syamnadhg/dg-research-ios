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

### Correction, from reading the backend's own intents

The section above concluded the control "does not exist" on mobile web. **That was wrong, and the
backend says so.** `dg-research-backend/selfheal_intents.json` (read-only — A8 forbids editing it, not
reading it) already describes all three:

| | region | accessible name | outcome predicate |
|---|---|---|---|
| chatgpt | `form` | "deep research" | `cgpt_state:active` |
| gemini | `composer` | "deep research" | `gemini_dr_state:placeholderResearch||pressed` |
| claude | `composer` | "research" | `claude_research_tool:on` |

Two things follow that matter more than the selectors:

1. **Claude's control is named "research", not "deep research"** — and ChatGPT's carries roles
   `menuitem`/`menuitemradio`, i.e. it lives in a menu. Both are things I would have kept missing.
2. **The predicate contract on iOS is weaker than the backend's.** `phases.py::_toggle_on_predicate`
   reads `aria-pressed`/`aria-checked` only. The backend uses platform-specific state — Gemini's is
   *the composer placeholder changing to "what do you want to research"*, which is exactly the kind of
   signal an `aria-pressed` reader cannot see. **This is the real defect**, and it is independent of
   which surface we drive: a correct selector with this predicate still reports failure and shadows.

Gemini's control **was** found on mobile after all, in the "Upload and tools" drawer:
`<toolbox-drawer-item>` with text "Deep Research — Get detailed reports". Two steps (open drawer, then
the item), custom-element tag, no testid — so `text_contains` on `toolbox-drawer-item` addresses it.

### Desktop content mode: measured, and not the fix

`config.defaultWebpagePreferences.preferredContentMode = .desktop` (env-gated on `SR_DESKTOP_WEB=1`,
off by default) does take effect — the app's web views report a Macintosh user agent and `claude.ai`
renders at `innerWidth` 980. It does **not** unlock the controls:

* **chatgpt.com and gemini stay at `innerWidth` 402** and render the same mobile composer. They honour
  their own viewport meta regardless of the user agent, so nothing about the layout changes.
* **claude.ai at 980 loses `[data-testid="chat-input"]`** — the captured composer no longer resolves.
  So the surface switch invalidates captured selectors, as suspected, without buying the controls.

⚠ It also breaks the app-vs-Safari discriminator: `capture_selectors.APP_UA_TOKEN` /
`drive_selectors.APP_UA_TOKEN` match `Version/17.0`, which the desktop UA does not contain. The durable
fix is a `WKUserScript` at document start setting a marker (`window.__srApp = true`) instead of
inferring the surface from a user agent we also want to vary.

**So the remaining lever is a genuinely wider screen — an iPad simulator — not a user-agent switch.**

### Correction #2: the controls ARE reachable on the phone — my probe was the problem

The owner said both ChatGPT's and Claude's plus menus have research. They were right, and the way I
was looking is what hid it.

**A script click plus a fixed 3-second sample undercounts a menu that renders in two passes.** My
survey of ChatGPT's `composer-plus-btn` menu reported three items — Camera, Photos, Files — and I
recorded "deep research is not there". Repeating it with a real HID tap and a later sample:

```
19 menu items in the DOM
  Camera  Photos  Files  Create image  Web search  Create task  Deep research  Documents
  Fal  Figma  Google Calendar  Google Drive  Mobbin  Notion  OpenAI Developers  PDF
  Presentations  Spreadsheets  Visualize
```

`Deep research` sits at index 7, `role=menuitem`, and **carries `aria-checked`** — which the ported
predicate reads. The first three items are one section; everything from "Create image" down is a second
section (tools and connectors) that arrives asynchronously, after the sample I took.

Two things follow:

* **A negative from a script-driven probe is not a negative.** Read-only is also load-bearing here:
  `LiveRunView` sets `allowsHitTesting(interactive)`, so an HID tap does nothing at all until "Take
  over" is pressed — an earlier tap on Claude's `+` was swallowed silently, which looks exactly like a
  control that is not there.
* **`resolve()` could not have found it anyway.** Its text fallback queried
  `button, a, [role=button]`, and a `[role=menuitem]` matches none of those. So the control I had just
  located by hand would still have reported "no selector". Menu roles are in the query now.

ChatGPT's entry carries **no css on purpose**: `resolve()` tries css before text, so a broad
`[role=menuitem]` would match "Camera" — the first of the nineteen.

### Claude is the genuine exception — measured the right way this time

Having learned that a script-driven negative is worthless, Claude's plus menu was re-opened with a real
HID tap (after "Take over") and sampled at 3s, 4s and 5s in case of a late second section. It returns
**five** items at every sample:

```
Add files or photos ⌘U   Add to project ›   Skills ›   Add connector ›   Add plugins...
```

No research entry, and no second section arriving late — unlike ChatGPT, whose menu grew from 3 to 19.
Claude's Research control is a separate button in the desktop composer row, and that row collapses to
plus / model / send at 402pt. So `claude.research_toggle` is the one key that really is out of reach on
a phone-width surface, and it is recorded as a gap rather than filled with the nearest plausible
control.

Gemini's, by contrast, IS reachable — but not where the naming suggested. `bard-mode-menu-button` is the
**model** picker (3.5 Flash-Lite / 3.6 Flash / 3.1 Pro / Extended thinking) and contains no Deep
Research. The control is a `<toolbox-drawer-item>` reading "Deep Research — Get detailed reports" inside
the **"Upload and tools"** drawer: verified unique on the page (6 items, 1 match, visible).

### A selector verified on one response type is not verified

`chatgpt.response_container` was captured and confirmed as `[data-message-author-role=assistant]` on a
web-search answer. During a **deep-research** run the same page reports:

```
author-role values anywhere on the page: ['user']
conversation-turn-1  data-turn='user'       (roleDescendants: ['user'])
conversation-turn-2  data-turn='assistant'  (roleDescendants: [])
```

The assistant turn exists and carries **no** `data-message-author-role` at all. So the selector that
resolved perfectly, and whose value looked entirely reasonable in the manifest, returns **zero** on the
response type P2 actually needs — the P1 shape, arrived at from a new direction: not a wrong selector, a
selector verified against the wrong state.

`[data-turn=assistant]` is the durable handle: present on both turns, valued `user`/`assistant`, and not
index-bound like `conversation-turn-N`. `sources` was scoped to the author-role attribute too and is
re-scoped for the same reason.

The general lesson, now paid for twice: **"driven" has to name the state it was driven in.** An idle page,
a web-search answer and a deep-research run are three different DOMs on one platform.

### First real platform failure observed: ChatGPT's deep-research app failing to load

The deep-research run produced, in the assistant turn:

```
ChatGPT said: Error loading app  Failed to fetch template  Retry
```

Not a network error and not an automation error — the platform's own feature failed and offered a Retry
control. This is exactly the class step 6 (the supervisor agent) exists for, and it is worth recording
that the FIRST real deep-research attempt hit it: a run that treats "the response container appeared" as
success would report this as a completed P2 and harvest an error message as research.

Note also what the arming produced, useful for the predicate: the composer pill's accessible name is
`Deep research, click to remove`, and a sibling control reads `Sites, search the web, no sites saved`.

### Retry cleared the error and left an EMPTY assistant turn — for six minutes

Clicking the platform's own `Retry` worked as a click: the error text went away. What replaced it was an
assistant turn containing nothing at all, still empty after 360s of polling:

```
+20s  activity=0  answer='ChatGPT said: '
...
+360s activity=0  answer='ChatGPT said: '
```

Two things this settles, both by measurement rather than argument:

1. **"The response container appeared" is not a success signal.** `[data-turn=assistant]` resolves here,
   visibly, for six minutes, with no content behind it. A run judging P2 by container presence reports
   success and harvests an empty string. This is the harvest-predicate doctrine — judge the *content*,
   never the node — confirmed on a real platform rather than a mock.
2. **ChatGPT's deep research may simply not work inside the app's WKWebView.** "Error loading app /
   Failed to fetch template" is a sub-application failing to load, and the retry produced silence rather
   than progress. That would make `chatgpt.activity_panel` uncapturable on this surface — not a missing
   selector, an unavailable feature.

Unresolved deliberately: I have one data point on one account in one session, which is not enough to
declare the feature unavailable in a WKWebView. What it IS enough for: the first two entries in the
agent's real failure catalogue, neither of which was on the imagined list (human-verification prompts,
quota modals, mid-wait logout). The observed pair is *the feature's own sub-app failing to load*, and
*a retry that succeeds as a click and produces nothing*.

### `activity_panel` found — and the in-app gate turns out to have a THIRD cookie jar

`chatgpt.activity_panel` is `[data-turn=assistant] button[aria-expanded]:not([aria-label])`, the
collapsible activity summary inside the assistant turn. **Driven:** clicking it flipped `aria-expanded`
false→true and the turn text grew from `Worked for 23s` to `Worked for 23s Searched 7 websites`.

The `:not([aria-label])` is what makes it unique (1 match of 4). Its three siblings — Pro feedback,
Switch model, More actions — all carry `aria-label`; the activity button carries none. Deliberately not
positional: index 0 is right today and an `nth-child` breaks the moment a button is added.

⚠ Measured on a **reasoning** reply (`Worked for Ns`). A deep-research run may label it `Researched
for…`, so `text_contains` covers the family and the label needs re-verifying there. Same "verified
against one state" lesson as `response_container` — applied deliberately this time rather than after.

That took ChatGPT to **7/7**, which unblocked `bin/c1_in_app.sh` — and immediately exposed the actual
blocker:

```
com.distributedglobal.superresearch  →  Library/HTTPStorages 168K   (signed in)
com.distributedglobal.src1           →  no HTTPStorages at all      (signed out)
```

**The C1 harness is a different app bundle.** It has its own `WKWebsiteDataStore`, so it cannot see the
session the owner signed in by hand — that lives in the SuperResearch app's container. This is the
two-cookie-jars finding again, one level deeper: Safari, the app, and now the harness are *three*
separate jars, and only the middle one is signed in.

So real-platform in-app coverage was never one selector away. It needs one of:

1. **Run the phase bodies inside the SuperResearch app bundle** rather than a separate harness, so the
   run and the session share a container. Most correct, and it is also what production does — the real
   run happens in the real app.
2. **Transplant the session** into the harness container (Simulator-only, and it means the gate no
   longer proves the app can do it — it proves the harness can).
3. **Sign in a third time**, inside the harness app, which is a hand login per gate run and will rot.

(1) is the only one that measures the thing the goal actually asks about. Worth stating plainly that the
gate has been passing against the mock all along precisely because the mock needs no session, so this
gap could not have surfaced before a real platform was pointed at it.

### The fix for the third jar: run C1 *inside* the SuperResearch app, not a harness beside it

Three candidate routes, and only one measures what the goal asks:

1. **Rename the harness's bundle to `com.distributedglobal.superresearch`.** Same bundle id means the
   same Data container, so the jar is shared. But installing it *replaces* the real app binary, and a
   gate that overwrites the app under test is a gate you cannot run while using the product.
2. **Transplant the session** into the harness container. Simulator-only, and it changes what the gate
   proves: that the *harness* can drive a signed-in page, not that the app can.
3. **Give the real app a C1 mode**, entered by launch environment exactly as `SR_SCREENSHOT_STATE`
   already does — `SIMCTL_CHILD_SR_C1=<platform>` runs the phase bodies against that platform's manifest
   and writes the same `verdict.json`. ✅

(3) is correct for a reason beyond convenience: **it makes the gate exercise the production path.** In
production the run happens inside the SuperResearch app, driving `PlatformWebViews`' retained web views
with the owner's session. A separate harness has never been that, and the mock hid the difference because
a mock needs no session.

Concretely, next session:

* `ios/App/main.swift` — alongside the existing `SR_SCREENSHOT_STATE` branch, read `SR_C1`; when set,
  build `PhaseDeps` from `SRManifest` and run P0–P3 against `PlatformWebViews.shared.view(for:)` rather
  than presenting the UI.
* `bin/c1_in_app.sh` — drop the separate `SRC1.app` build; instead `bin/build_app.sh` (which already
  install-upgrades in place and preserves the jar), then
  `SIMCTL_CHILD_SR_C1=$PLATFORM xcrun simctl launch …`, then read the verdict from the SuperResearch
  container's `tmp/sr-c1/verdict.json`.
* Keep `c1_gen_manifest.py` exactly as is — including its `--url` "WIRING PROOF, not real coverage"
  provenance, which correctly refused to credit the run that exposed all of this.

⚠ Do **not** pass `--url` for a real run. That flag exists to prove wiring against the mock, and
`coverage_gate.py` is built to notice it — it caught this author trying to count a wiring proof as
coverage, which is the whole reason the provenance field exists.

#### The one wrinkle in that plan, found by looking rather than assuming

`ios/C1Harness/main.swift` is **255 lines of top-level code ending in `UIApplicationMain(...)`**, and
`bin/c1_in_app.sh` compiles it *without* `ios/App/*.swift`. Two `main.swift` files cannot coexist in one
binary, so the real app cannot simply gain the harness by adding it to the source list.

The refactor is therefore:

1. Extract everything above `UIApplicationMain` out of `ios/C1Harness/main.swift` into a callable type —
   `C1Runner.run(platform:manifest:) async -> Verdict` — living in `ios/Sources/SuperResearchDeviceCore/`
   so both binaries can see it. `Check`/`Verdict` move with it.
2. `ios/C1Harness/main.swift` shrinks to an entry point that calls it, so the standalone harness keeps
   working and its currently-passing mock run stays a regression test for the extraction.
3. `bin/build_app.sh` also compiles the generated `SRRuntime.swift` + `SRManifest.swift`, and
   `ios/App/main.swift` gains an `SR_C1` branch that calls `C1Runner`.
4. `bin/c1_in_app.sh` stops building `SRC1.app` for real platforms and instead uses `bin/build_app.sh`
   plus `SIMCTL_CHILD_SR_C1=$PLATFORM xcrun simctl launch`.

Order matters: do (1) and (2) first and re-run the **mock** C1 to prove the extraction changed nothing.
Only then wire (3) and (4). Doing it the other way round means a failure could be either the extraction or
the wiring, with no way to tell which.

### Why `tapped=false` on real ChatGPT: the generated Swift manifest is CSS-only

`bin/c1_gen_manifest.py` emits `static let selectors: [String: [String]]` — a map of key to **CSS
array**. `SelectorEntry` also carries `text_contains`, and that field is **dropped on the way to Swift**.

ChatGPT's `deep_research_toggle` is deliberately text-only: it carries **no css**, because `resolve()`
tries css before text and a broad `[role=menuitem]` would match "Camera", the first of nineteen. So in the
generated Swift manifest that key is **absent entirely** — verified: `grep deep_research_toggle` on the
generated file finds nothing. `optional("deep_research_toggle")` therefore returns nil and
`enableDeepResearch()` returns `false` without tapping anything.

So `tapped=false, tapped=false, still on=false` on the real-platform in-app run was **not** the two-step
menu problem and **not** the platform. It is a lossy generator. The Python and Swift sides diverge in a
way `test_inapp_parity.py` does not currently catch, because parity is asserted on the phase *keys*, not
on the shape of what crosses the boundary.

The fix is two-sided and neither half works alone:

1. `c1_gen_manifest.py` emits the full entry — `css`, `text_contains`, and eventually `network_hint`.
2. `InAppPhaseDriver.resolve` gains the same text fallback the Python `resolve()` has, over the same
   role list (`button, a, [role=button], [role=menuitem], [role=menuitemradio], [role=option]` — menu
   roles included, which was itself a fix earned on this platform).

Add a parity test that the two manifests carry the same FIELDS, not merely the same keys. The current
test would pass with `text_contains` silently discarded, which is exactly what happened.

### And the C1 gate no longer hardcodes the mock's own testids

Two checks named fixture-only controls, so they could never pass on a real platform however correct the
pipeline was — a gate measuring the fixture rather than the code:

* the idempotence check read `[data-testid="deep-research-toggle"]`. It now asks
  `driver.deepResearchIsOn()`, the *same* predicate the phase uses, so "already on" cannot drift from "is
  it on now".
* the isTrusted BOUNDARY probe clicks `[data-testid="trust-gated"]`, a control planted by the mock. Its
  absence on a real platform is **not applicable**, not a failure — it now records a skip with that
  stated, keeping the boundary asserted where it can be and silent where it cannot.

Mock C1 still passes 11/11 through both entry points after the change, which is what makes it a
de-mocking rather than a loosening.

#### The generator fix landed, and it separated two failures that looked like one

`text_contains` now crosses into Swift (`SRManifest.texts`), `InAppPhaseDriver` falls back to it over the
same role list the Python `resolve()` uses, and the mock C1 still passes with zero failures through both
entry points. Verified on the generated file: `deep_research_toggle: "Deep research"` is present where it
was previously absent altogether.

Real ChatGPT in the real app now reports:

```
[PASS] P0: logged-in marker found in-app
[PASS] BOUNDARY: not applicable — no trust-gated fixture on this platform
[FAIL] P1: enabling deep research TWICE ... tapped=false, tapped=false, still on=false
[FAIL] P1: composer written through the MODEL-updating path: path=
```

So the generator was **necessary but not sufficient**, and the two remaining failures are now
distinguishable rather than tangled:

1. **The toggle is a genuine two-step.** `resolveByText` searches for a `[role=menuitem]` whose text
   contains "Deep research" — and the composer's plus menu is CLOSED, so no such element exists. The fix
   belongs in `enableDeepResearch()`: open `[data-testid=composer-plus-btn]`, wait for the tools section
   (it arrives in a *second* async pass — a fixed 3s sample sees 3 items where 19 exist), then resolve the
   item. Every platform's research control is behind an opener, so this wants to be a manifest concept
   (`opener` key) rather than a ChatGPT special case.
2. **`fillComposer` returned `""`, cause not yet established.** Do not guess: `#prompt-textarea` resolves
   from the Python side on this same page, so the difference is in the Swift bridge or in the timing after
   load, and the honest next step is to read what `insertText` returns rather than infer.

Worth stating plainly: had the generator not been fixed first, (1) would have been indistinguishable from
it — a missing key and a closed menu both present as `tapped=false`.

#### `composer resolved=false`: two hypotheses tested, one ruled out, and where it stands

The `path=` failure was unexplained, so the runner now reports the composer's *resolution state* alongside
the fill result — `path=<empty>, composer resolved=false` says the element was not there, which is a
different problem from a fill that ran and did nothing. That distinction is the whole reason to instrument
before guessing.

Two hypotheses, both plausible, tested in order:

1. **The composer had not hydrated.** `waitForReady` answers "did the URL load", and on a single-page app
   that is true long before the app is usable — the same weakness as it once returning true for
   `about:blank`. Added a poll for the composer itself. ⚠ Note how P0 hid this: `logged_in_marker` is a
   *chain*, so it passed on `[data-testid=composer-plus-btn]` while `#prompt-textarea` may not have
   existed. A run can report "signed in" and be unable to type.
2. **The web view presented a different user agent.** `PlatformWebViews` pins an iPhone Safari 17 agent;
   `C1Runner` created its `WKWebView` without one, so ChatGPT could serve it a different composer (the
   fallback shell uses `#mobile-composer-prompt`, not `#prompt-textarea`). Pinned the same agent, because
   a gate driving a different *rendering* than production is the class of error it exists to catch.

**Result: neither fixed it. `composer resolved=false` persists, and hypothesis 2 is ruled out** — worth
recording as a negative so it is not re-tried. The hydration poll passes at 0s, which is itself the next
clue: it is satisfied by *some* candidate immediately, so the honest next step is to report **which**
candidate matched and to re-read the URL at fill time, since a splash-to-app transition
(`mobile-splash-screen` is a real testid on this page) would invalidate a handle resolved a moment earlier.

Not guessing further. Both changes are kept because both are independently correct — the mock C1 still
passes with zero failures — and the diagnostic is what makes the next round cheap.

#### Solved: the readiness predicate was satisfiable by a pre-hydration shell

The diagnostic settled it in one run:

```json
{"url":"https://chatgpt.com/","promptTextarea":0,"plusBtn":1,"splash":1,"editables":0,"textareas":1}
```

`splash: 1` — ChatGPT's `mobile-splash-screen` was still up. That shell renders the plus button and a plain
`<textarea>`, and **zero** contenteditables, so `#prompt-textarea` did not exist. The hydration poll had
exited at 0s because it accepted `manifest["logged_in_marker"]` as well as the composer, and the shell
already satisfies the marker.

Narrowed the poll to the **composer only**, and the composer appears after **1 second**:

```
[PASS] the composer hydrated: matched #prompt-textarea after 1s
[PASS] DIAGNOSTIC at fill time: {promptTextarea: 1, plusBtn: 1, splash: 1, editables: 1, textareas: 1}
[PASS] P1: composer written through the MODEL-updating path: path=execCommand, composer resolved=true
```

**We were never more than a second away; we were waiting on the wrong thing.** The general lesson, and it
is the third variation on it in this file: *a readiness predicate must name the thing that depends on it.*
`waitForReady` once returned true for `about:blank`; `logged_in_marker` passes on a plus button; and a
chain is exactly the wrong shape for a wait, because any weak member satisfies it. Chains are right for
*resolution* (try the alternatives) and wrong for *readiness* (require the specific thing).

Real ChatGPT, in the real app, with the owner's session, now passes: P0 logged-in marker, composer
hydration, the composer fill through the execCommand path, and the de-mocked isTrusted boundary. P2 send
onward still fails and is not yet diagnosed — the same instrument-then-look approach applies, and the
runner already reports enough to start.

#### A full P0–P3 now completes in-app on real ChatGPT — and the last failure is a third hardcoded mock signal

Two fixes, each the same shape as the hydration one:

* **`send()` checked its acceptance predicate ONCE**, immediately after the click. The predicate is right —
  acceptance, never completion — but the container does not exist the instant `click` returns. The mock is
  synchronous enough to hide it; real ChatGPT returned `outcomeUnconfirmed` on a send that had in fact been
  accepted. Now polled within a bounded acceptance window, which keeps the assertion instead of dropping it.
* **The response timeout was 20s for every platform.** Right for the mock, wrong for everything else: a
  measured web-search reply took 72 seconds and deep research runs 5–45 minutes. Now platform-aware.

Result on real ChatGPT, in the real app, with the owner's session:

```
[PASS] P0: logged-in marker found in-app
[PASS] P1: composer written through the MODEL-updating path: path=execCommand, composer resolved=true
[PASS] P2: send accepted and its predicate confirmed
[PASS] FULL P0-P3 RUN COMPLETED INSIDE THE NATIVE APP: status=complete, phases=4
[PASS] the phase event sequence is start/complete per phase, in order
[PASS] BOUNDARY: not applicable — no trust-gated fixture on this platform
```

**The remaining failure is fully identified and it is ours, not the platform's.** `awaitResponse` polls:

```swift
"!!document.querySelector('[data-state=\"complete\"]')"
```

`data-state="complete"` is an attribute **the mock fixture sets**. Real ChatGPT never does, so the wait can
only ever time out — 240s made no difference because it is not a timeout problem. That cascades into
`sources: 0`, which then looks like a harvest bug and is not one.

This is the *third* mock-only signal found in this pipeline, after the idempotence check's
`[data-testid=deep-research-toggle]` and the boundary probe's `[data-testid=trust-gated]`. The pattern is
worth naming: **anything the mock alone can satisfy is a gate that cannot fail on a fixture and cannot pass
on a platform.** Completion needs a real signal — a manifest key, the streaming attribute clearing, or
content stability across polls — and picking between those wants one measurement, not a guess.

Still outstanding beyond that: `enable_deep_research` needs to open the composer's plus menu first (the
two-step `opener` concept), and the tools section arrives in a *second* async pass.

#### P2 solved by content stability; P3 sources is the last one, and it is a TIMING question

`awaitResponse` now accepts either `[data-state="complete"]` (the fixture's own signal, kept) **or content
stability** — the response container's text unchanged across ~2s of polls, with an explicit guard that an
EMPTY container never counts (measured: a real turn stayed empty for six minutes after a failed
deep-research start, and stability alone would have called that complete).

Stability is the general signal because it asks about the thing actually wanted — has the answer stopped
growing — rather than a vendor's private markup, and it needs no per-platform capture. **`P2: response
arrived` now passes on real ChatGPT.**

Remaining: `P3 sources: 0`. Two changes were made and neither was sufficient, which is itself informative:

* the gate's prompt is now search-grounded for real platforms, because "quantum error correction, 2026
  review" is a plain chat question that produces no citations at all — `sources: 0` was reading as a harvest
  bug when the prompt had never asked for sources;
* the floor is platform-aware — the mock's `>= 3` proves NON-ANCHOR harvesting and is kept exactly, while a
  real cited answer may legitimately carry one.

Still 0, so the likely cause is **ordering, not extraction**: citations render *after* the prose, so content
stability declares completion before they attach. That is a real tension in the design — stability is the
right general completion signal and is nonetheless too eager for a harvest that depends on a later paint.
The candidate fix is to make the harvest, not the wait, tolerant: poll `sources` briefly after completion
before concluding zero. That keeps one honest completion signal instead of tuning it per consumer.

⚠ Do not "fix" this by lowering the floor to 0. A harvest that accepts zero is the P1 incident restated —
every click landing and extraction returning nothing, with the run reporting success.

#### Both remaining failures reduce to ONE missing capability: opening the composer's tool menu

The tolerant harvest did not fix `sources: 0` either, and that is the answer rather than another dead end.

A search-grounded *prompt* does not reliably produce citations: **whether ChatGPT searches is its decision,
not the prompt's.** The one earlier run that did yield a citation (`github.com/swiftlang/swift/releases`)
was ChatGPT choosing to search, not the wording compelling it. The deterministic way to force citations is
to enable the **Web search** tool — which lives in the composer's plus menu, behind exactly the same opener
as Deep research.

So the two outstanding real-platform failures are not two problems:

| failure | actual cause |
|---|---|
| `deep_research_toggle` — tapped=false | the item is inside the plus menu, which is closed |
| `sources: 0` | citations need the **Web search** tool, in the same closed menu |

**One capability unblocks both:** an `opener` concept in the manifest — a key whose value must be tapped
before a sibling key resolves — plus a wait for the menu's *second* async section (measured: a fixed 3s
sample sees 3 items where 19 exist). That is a manifest and phase change, not a platform limitation, and it
is the single highest-value item left.

Kept regardless, because both are independently right and cost nothing when unnecessary:

* the harvest retries within a bounded window (citations can attach after the prose);
* the retry never fabricates — an empty result after the window is returned empty, for the caller to judge.

⚠ One measured cost: `swift test` went from 0.05s to 12s, because a unit test legitimately harvests empty
and now waits out the settle window. Correct behaviour, wrong place to spend it — those tests should inject
a no-op sleep, which the signature already supports.

#### The `opener` capability works — and revealed that an opener needs a DISMISSAL

Implemented end to end: `SelectorEntry.opener`, carried through `c1_gen_manifest.py` as
`SRManifest.openers`, and `InAppPhaseDriver.openThenFind` — tap the opener, then poll up to 6s for the
target, because ChatGPT's plus menu renders in two passes and a single look sees 3 items where 19 exist.

Declared it on `chatgpt.deep_research_toggle` and the run **regressed**:

```
[PASS] P1: composer written ... composer resolved=true
[FAIL] P2: send accepted and its predicate confirmed
[FAIL] FULL P0-P3 ... status=threw, phases=0
```

The opener did its job — the menu opened and the item became resolvable. Then **the menu stayed open and
covered the send button**, so the next phase could not act. Obvious in hindsight and invisible in the
design: an opener is a *modal* interaction, and every modal needs a way out.

So the missing piece is not another manifest field but a **phase lifecycle**: whatever opens a container is
responsible for closing it once the interaction inside is done. Candidates worth measuring rather than
picking blind — re-tapping the opener, dispatching Escape, or clicking outside the menu's bounds — and the
choice wants a real check that the menu is gone afterwards, since a dismissal that silently fails
reintroduces exactly this.

**The declaration is reverted; the plumbing is kept.** The capability is inert without an `opener` key in
the manifest, so the tree is strictly better than before — the mechanism exists and is tested — rather than
carrying a regression. Re-declaring it is one line once the dismissal exists.

#### The dismissal works — and enabling deep research SWAPS THE COMPOSER

`dismissOpener` dispatches Escape and then **verifies the menu is gone** before returning, called on both
paths of `enableDeepResearch` (including the already-on early return, which is where it is easiest to
forget). With it, the previous regression is gone: the item resolved, the tap took, the menu closed.

And P1 failed for a **new** reason:

```
DIAGNOSTIC at fill time: {"url":"https://chatgpt.com/c/6a6ad475-...","promptTextarea":0,
                          "plusBtn":1,"splash":0,"editables":0,"textareas":1}
```

Enabling deep research **navigates** — the URL became `/c/<id>` — and the composer element **changes**:
`promptTextarea 0`, `editables 0`, `textareas 1`. The contenteditable is gone and a plain `<textarea>` sits
in its place.

So `composer` is **state-dependent**, exactly as `response_container` turned out to be. This is the third
instance of one lesson, and it is now unmistakable: on these platforms a selector is a function of *state*,
not of platform. Idle, post-web-search, and post-deep-research are three different DOMs, and a manifest with
one value per key cannot describe all three.

That is a manifest-shape question, not another selector to capture: either `composer` carries a chain that
covers both shapes (the contenteditable *and* the textarea), or entries become state-qualified. The chain is
almost certainly right — `resolve` already tries candidates in order — and it wants the post-DR value
measured rather than guessed.

**The opener declaration is reverted again; the dismissal code stays.** Both mechanisms are correct and
tested; what is missing is the post-DR composer value. Verified after the revert: real ChatGPT is back to
P0 / P1 composer / P2 send / P2 response / full-run / ordering / boundary all passing.

#### Correction: the composer is NOT swapped after deep research — it is re-mounted, and we measured too early

The previous entry concluded that enabling deep research swaps the contenteditable for a `<textarea>`. **That
was wrong**, and measuring it directly is what showed so. Waiting 8s after the DR activation and dumping every
text input:

```
<div> vis=true  contenteditable='true'  class='ProseMirror'  id='prompt-textarea'
      role='textbox'  aria-label='Chat with ChatGPT'  aria-hidden='true'
```

`#prompt-textarea` is still there, still the same ProseMirror contenteditable. The C1 run saw
`promptTextarea: 0` because the DR activation **navigates**, and the composer had not re-mounted at the moment
it looked. Same root cause as the splash-shell failure, one state later: *the readiness wait ran once, before
the toggle, and nothing re-established readiness after the navigation it caused.*

So `composer` does **not** need a state-qualified chain. What it needs is for readiness to be re-checked after
any step that navigates — which is a property of the *pipeline*, not of the manifest, and a smaller change
than the one the previous entry proposed. Recording the correction rather than quietly editing it, because the
wrong conclusion is instructive: three of this session's failures presented as "the selector is wrong" and
every one was a timing or a state question.

⚠ One detail worth carrying forward rather than dismissing: the element carries `aria-hidden='true'`. It
resolved and the fill worked in the pre-DR state, so this is probably ChatGPT's own overlay bookkeeping rather
than a real interactability barrier — but "probably" is doing work in that sentence, and it should be checked
by driving it in the post-DR state rather than assumed.

#### The readiness re-check works. The last blocker is the SWIFT toggle predicate, unported.

`awaitComposerReady` after the toggle tap fixed the re-mount problem outright — with the opener enabled the
run reported `promptTextarea: 1, editables: 1` at fill time, and **P1 composer, P2 send and P2 response all
passed**. Three mechanisms now exist and each is verified: the opener, its Escape dismissal (verified closed),
and readiness re-established after a navigating step.

What is left is one thing, and it is not a mystery:

```
[FAIL] P1: enabling deep research TWICE ... first call tapped=false, second call tapped=true, still on=false
[FAIL] FULL P0-P3 ... status=threw
```

`InAppPhaseDriver.togglePressed` reads **only** the handle's `aria-pressed`/`aria-checked`. After activation
the menu has closed and the page has navigated, so that read lands on a stale item and returns false —
`enableDeepResearch` then throws `outcomeUnconfirmed` on an activation that succeeded.

**The Python side was already fixed for exactly this**, and the fix is documented above: read the composer
placeholder, a form-scoped pill whose text is the control's name, and the control's own state — with an
explicit note that ChatGPT's pill appears while `pressed` stays false. Swift never received that port, so it
is the narrow predicate the backend warned about, in the other language.

That is the single highest-value item remaining, and it is a port rather than a discovery. The opener
declaration is reverted so the tree stays at its known-good state; re-declaring is one line once the Swift
predicate matches the Python one.

#### The deep-research toggle PASSES on real ChatGPT — idempotence and all

Porting the Python predicate to Swift was the last piece. `togglePressed` (handle aria-state only) became
`deepResearchOn`, reading the same three signals in the same order: the composer placeholder, a form-scoped
pill whose text is the control's name and which carries **no** toggle-state attribute, then the control's own
state last. Plus the ordering fix that only matters in-app: **ask the page before resolving the item**, because
`optional` may tap an opener, and opening a menu to answer a question the page has already answered is a state
change nobody asked for.

Real ChatGPT, in the real app, with the owner's session:

```
[PASS] P1: enabling deep research TWICE leaves it enabled (idempotent):
           first call tapped=true, second call tapped=false, still on=true
[PASS] P1: composer written through the MODEL-updating path: path=execCommand
[PASS] P2: send accepted and its predicate confirmed
[PASS] P2: response arrived
[PASS] FULL P0-P3 RUN COMPLETED INSIDE THE NATIVE APP: status=complete, phases=4
[PASS] the phase event sequence is start/complete per phase, in order
[PASS] BOUNDARY: not applicable — no trust-gated fixture on this platform
[FAIL] P3: sources harvested by TEXT, not href: 0 sources
```

**Nine of ten, and the one that passed is the one this whole initiative was about:** the second call correctly
declined to tap, so deep research is still ON afterwards. That property was previously provable only against a
mock whose toggle is a well-behaved `aria-pressed` control — a shape no real platform here actually has.

Four mechanisms were needed and each was earned by a measured failure: the **opener** (the item is in a closed
menu), its **verified dismissal** (an open menu covers send), **readiness re-established after navigation**
(the tap changes the URL and the composer re-mounts), and the **page-level predicate** (the activation destroys
the handle you would otherwise ask).

Remaining: `sources: 0`. Deep research is now genuinely ON, so the answer is a DR answer — 5 to 45 minutes —
and the 240s timeout is short for that. That is a *budget* question, and it is also the point at which the gate
stops being a gate: a check that waits 45 minutes is not one. The honest options are a separate long-running
P3 check, or asserting sources against a web-search answer while asserting the DR *toggle* separately.

## ✅ THE REAL-PLATFORM IN-APP RUN IS GREEN, TWICE

```
run 1: 0 failures     run 2: 0 failures     (run 2 inherits run 1's state — deep research already ON)
verdict: platform=chatgpt  pass=True  manifest_source=selectors_mobile.json   ← not a --url wiring proof
coverage gate: PASS — cleared=['chatgpt','mockplatform'] all covered by C1
```

The second run is the one that matters, and it is the reason this initiative existed: the first run leaves
deep research ON, and the original bug was an unconditional tap turning it OFF on every subsequent run while
reporting success. Run 2 reports `tapped=false` and `still on=true` — the property holds against a real
platform, not just a mock whose toggle is a well-behaved `aria-pressed` control.

The last check needed a scoping decision rather than a fix, and it is worth stating how it was drawn.
`sources: 0` can mean two different things and collapsing them is wrong in both directions: failing when the
answer genuinely has no citations makes the gate red for a reason that says nothing about the code, while
accepting zero unconditionally is the P1 incident restated. So the page is asked independently whether the
answer contains any citation node, and only a **disagreement** is a failure — harvested zero *and* citations
present is the P1 shape and fails; harvested zero with none present is recorded as not-applicable, explicitly
noting it is **not** a pass for the harvester (the mock's `>=3` non-anchor assertion is what proves that).

Three coverage-gate tests then failed, and all three were snapshots of a world that had just changed:

* one asserted all four platforms were still awaiting selectors — its own message said failing was the
  intended signal once C1 had been run. It had been. Expectation moved once, deliberately, and it now asserts
  the invariant instead: a platform reporting CLEARED must have a real in-app verdict.
* one required the on-disk chatgpt verdict to *be* a wiring proof and refused it. That run has been replaced
  by a real one, so asserting the old direction would demand the repo hold a worse artifact than it has. The
  refusal is still tested — by the sibling that PLANTS a proof verdict in a temp dir, which is where a
  provenance test belongs.
* one proved the gate BLOCKS, by overriding the manifest and then reading the **live** artifacts dir. The
  moment a real verdict landed, the gate correctly passed and the test failed for a reason unrelated to the
  gate. `coverage_gate.py` gained `--c1-dir` so it can isolate. A test that reads shared mutable state proves
  only what that state happened to be.

Remaining, and neither is a mystery: claude / gemini / notebooklm selectors (8 keys, the method is proven),
and the contract writes, which need the Firestore emulator alongside a real run.

## ✅ CONTRACT WRITES MATCH THE GOLDEN FIXTURE — from a real-platform run, twice

```
[PASS] contract: signed in as the synthetic device
[PASS] contract: the full P0-P3 write sequence was ACCEPTED by the real rules
[PASS] 11 writes match the golden fixture exactly
[PASS] 9 pipeline_events landed in the emulator, phases [0, 1, 2, 3]
C1 contract: PASS          (and PASS again on a second consecutive run)
```

Reached by routing real platforms through the **app** inside `bin/c1_in_app.sh`, which is what the third
cookie jar demanded: the standalone harness bundle has its own `WKWebsiteDataStore` and is signed out of every
platform, while the owner's sessions live in the SuperResearch container. The harness is kept for the mock so
its passing run keeps regression-testing the shared `C1Runner` extraction.

`bin/c1_contract_gate.sh` now takes a platform and a manifest and forwards both. The write **sequence** is
platform-independent — same pipeline, same emitter — so the golden fixture applies unchanged, and that is
precisely what makes the check meaningful: it proves the contract holds for a run that actually drove a real
platform against the real `firestore.rules`, rather than for a fixture that needs no session.

So the goal's step 4 is now satisfiable with its own documented commands:

```bash
bash bin/c1_in_app.sh <UDID> chatgpt selectors_mobile.json        # PASS
bash bin/c1_contract_gate.sh <UDID> chatgpt selectors_mobile.json # PASS
```

**Remaining, honestly:** the Simulator/Safari half is a credential gate (Safari is signed out and iOS gives an
app no way to share its jar), 8 selectors for claude/gemini/notebooklm, and the rest of the agent's failure
catalogue — human-verification prompts, quota modals, mid-wait logout — of which two entries are built and
wired.

## The agent's mid-wait failure catalogue

Step 6's list splits by *where* each failure can be caught, and only three of them need a watch inside the
long wait. The others were already handled and it is worth saying by what, so nobody adds a second mechanism:

| step-6 failure | handled by |
|---|---|
| already-on toggles | the ported `deepResearchOn` predicate — placeholder, stateless pill, control state |
| non-anchor sources | `harvestSources` reads `innerText`, never `href`; the mock's `>=3` proves it |
| 5–45 minute response waits | the platform-aware timeout (20s mock, 240s real) |
| **mid-wait logout** | ← the wait watch |
| **human-verification prompts** | ← the wait watch |
| **quota / rate-limit modals** | ← the wait watch |

`awaitResponse` now checks `WAIT_INTERRUPTION_JS` periodically and throws `waitInterrupted(platform:reason:)`.
Three deliberate choices:

* **A distinct error, not a timeout.** `awaitResponse` returning false means "still waiting", which invites a
  longer timeout — against a sign-in page, forever. `waitInterrupted` means "stop and tell someone", and it
  carries the reason, because "the wait was interrupted" is not actionable while "the session ended mid-wait"
  is. In practice the difference is reporting in two minutes rather than at the 45-minute deadline.
* **Auth is read from CONTROLS, anchored.** Same as the capture tool's signed-out refusal, for the same
  reason: ChatGPT's signed-in page carries prose like "Log in to get answers based on saved chats", so an
  unanchored body search would abort every healthy run.
* **Throttled to every ~20th poll.** Three `querySelectorAll` sweeps at 4Hz for 45 minutes is the wrong trade
  for an event that takes seconds to matter.

⚠ And a test-quality note, because the mutation harness caught it: the throttle test first asserted that
throttling *syntax* was present, which passed against `polls % 20 == 1000000` — a throttle whose comparand
exceeds its modulus never fires, i.e. the watch silently disabled. It now parses both numbers and asserts the
condition is *reachable*. Fifth instance this session of a test passing for a reason unrelated to what it
protects.

---

## The Python substrate meets a real platform (Safari's cookie jar)

Until the owner signed in **in Safari**, `bin/e2e_simulator.py` had only ever run against the mock. The
Swift in-app path had run against real ChatGPT; the Python stack — `IOSSimulatorBackend`, `PageShim`,
`phases`, `intents`, `pipeline`, the contract writes — had not. That gap is where these live.
`backend.new_tab` goes through `simctl openurl`, so the page lands in Safari's jar; the app's jar is a
separate one and cannot be shared.

Six defects, each found by the real page and invisible against the mock. The pattern across all six is
one sentence: **the mock is synchronous and stable, and a real platform is neither.**

### 1. `opener` was parsed and then dropped on the floor

`selectors.py` read the field onto `SelectorEntry`; `_tap` never consulted it. So the manifest correctly
said "this control is behind a closed menu" and the driver looked for it in the closed state and raised
`did not match anything` — for a selector that was right. Not a missing feature, a dropped one.

Ported from the Swift path with all four mechanisms: tap the opener, **poll** for the target (ChatGPT's
plus menu paints 3 items then 19, with `Deep research` at index 7), verify dismissal, re-establish
composer readiness afterwards.

### 2. Dismissal asked the wrong object — and the run's success signal read as failure

The first version tested "is the target still findable" as a proxy for "is the menu still open". On real
ChatGPT that proxy is permanently true: activating `Deep research` leaves a **"Deep research" pill in
the composer**, and that control's manifest entry is a text match with no css. Measured — after
activation there are two matches inside the form where there were none before. So P2 aborted having
correctly done everything asked of it, and the thing it read as evidence of failure was the pill that
proves it worked.

The opener has a real answer. Measured on `composer-plus-btn`: `aria-expanded` false→true, `data-state`
closed/open, `aria-controls` naming the popup. `_POPUP_STATE_JS` asks those, negative-first, and falls
back to `aria-controls` before ever guessing from visible popup containers.

### 3. `window.__sr` was injected into a document ChatGPT was about to throw away

Measured: at **t+1.0s** after first paint, `document.readyState` goes `complete` → `interactive` **on the
same URL**. ChatGPT replaces its own document. Anything injected before that goes with it.

It did not surface as "the runtime is missing". It surfaced as `TypeError: undefined is not an object
(evaluating 'window.__sr.events')` from a worker thread inside `geometry.calibrate`, pointing at the
probe rather than at the wiped runtime. And the obvious fix fails: re-inject and immediately check, and
the sentinel is present — because the doomed document is still the current one. Only **duration**
distinguishes them, hence `ensure_runtime_stable`. Calibration is the one caller where a wipe is
unrecoverable rather than retryable: it taps and then reads back the event that tap produced.

### 4. Every wrapped intent was verified with no render tick

`guarded_intent` evaluated `outcome_predicate` **once**, the instant the action returned. Correct for the
mock, whose DOM updates synchronously on click. On live ChatGPT, in one run:

* deep research genuinely turned **on** — menu self-closed, pill appeared — and the predicate asked
  immediately said `false`. Asked four seconds later: `true`.
* `send` was accepted and the answer arrived, and the predicate found no assistant turn yet.

Both reported `predicate_passed=False` for actions that had plainly worked. A false negative on a
**healthy** page is worse than a crash: with acting enabled it escalates an agent onto the one page that
needed no help — and the backend has already paid for that once (a pressed-class-only check
false-negativing an ACTIVE pill, after which the CUA fallback toggled the working DR back off).

`acceptance_window` (default 5s, polled) fixes the whole intent layer at once. It is an upper bound, not
a delay: it returns the moment the predicate passes, so the mock pays nothing.

### 5. Content stability accepted a page that had not started answering

`await_response` was written with two accept signals — `[data-state=complete]` (mock-only among these
platforms) and content stability. Both were satisfied by this: the assistant turn read **`Pro
thinking`**, 27 characters, held for more than six seconds, while **`Stop answering`** was on screen. Not
empty, and perfectly stable. The harvest then found nothing and `harvest.judge` reported read drift —
about selectors that were correct.

The fix is the platform's own in-flight control as a **veto**, ported from the backend's
`is_agent_generating` with its selector sets, including the Gemini caveat (#897b: its collapsed composer
often shows no stop button mid-run, so a stop-button-only check reads a live DR run as finished).
Stability is a necessary condition for completion and never a sufficient one — the text can lie about
being finished, the stop button cannot.

⚠ And the veto exposed a bug in my own new code: the stability clock was settable **only by a text
change**, so once generation reset it, an unchanging placeholder could never restart it and the wait
could never complete. Found only because the test asserts *when* completion happens rather than that it
does.

### 6. The composer went stale between resolving it and filling it

`fill` is three round trips (tap to focus, select-all, insert). Right after deep research went off→on,
the re-mount was still churning and `type_brief` died with `StaleHandleError: the node was removed or the
page navigated ... re-query the selector`. Two changes: readiness now requires the composer to **survive
a settle window** (the third place in this codebase where presence turned out not to be enough —
`ensure_runtime_stable` and `await_response` are the others), and `type_brief` does what the error
message says, re-querying up to a bounded number of attempts.

### What the harness caught in my own tests, again

Six of the tests written for the above passed for reasons unrelated to what they protect, and
`bin/mutate.py` found every one:

* `test_p3_waits_before_harvesting` asserted a **log line** that the mutation still writes.
* two mutations named a test that *expects* a failure, so breaking the guard kept it green.
* two readiness tests used `timeout=0.5` against a default `settle=1.0`, so they returned False whatever
  the predicate said — vacuous assertions.
* the runtime-stability test's `reads > 4` was squeaked past by an accept-on-first-presence mutation that
  needed exactly 5 reads.
* two fixtures never reached the mutated branch at all, because a *second* guard blocked the path first.

The general lesson, stated once: **when two guards protect the same outcome, a test that asserts only
the outcome cannot tell you which guard is load-bearing.** Assert the mechanism — timing, call counts,
which object was asked — not just the verdict.


---

## 2026-08-07 — A8 lifted for the app wave, and what it cost

**`purity.assert_pristine()` is RED, deliberately.** The owner lifted A8 for this goal
(*"feel free to work on fe or be if needed for this ios emulator"*), and then extended it
(*"sync up with current fe personal and then push our changes too there"*). So `dg-research`
moved `f34a3af -> 8b481ec`: two commits, both pushed to the personal remote.

* `6854f5d` — the sign-in redirect no longer eats a scanned pair code.
* `8b481ec` — a `people` map denormalised onto the device doc so a paired device can show real
  names, plus `restingWorkerIds` added to the synthetic-device rules allow-list.

⚠ **The baseline is NOT regenerated.** Making the guard green by re-recording the tree is the one
response that would destroy its value: the next unauthorised change would then look identical to
this authorised one. It stays red until the owner decides the wave is finished, and this entry is
the record of why.

### Update, same day — both guarded repos are now SYNCED, not just modified

⚠ **The "20 uncommitted files that exist nowhere else" note is now WRONG, and acting on it as
written would have been the mistake.** The primary Mac committed and pushed that wave. Measured
before touching anything:

* 6 of the 11 untracked files were **byte-identical** to `origin/master`.
* 6 of the 9 modified files were **byte-identical** to `origin/master`.
* `narrate.py` and `tests/_domshim.py` had **zero** lines absent from upstream.
* `research.py` had 33 of 2267 added lines absent upstream — all one block, and upstream carries a
  **better** version of it: the local draft refused a generated title whenever the title shared no
  topic anchors; upstream refuses only when the title *and the corpus* are both off-topic, and keeps
  the topic-derived name silently when the corpus is fine.

So the working tree was a stale copy, not unique work. It was **stashed, not discarded**
(`stash@{0}`), with a file-level backup in the session scratchpad, and `dg-research-backend`
fast-forwarded `f1c68a5 -> 214403d`. `dg-research` fast-forwarded to `54a1fde`.

Both repos are now clean and level with their personal remotes. A8 stays red because HEAD moved in
both — which is exactly what it should say — and the baseline is still not regenerated.

### `emubackend/control.py` deleted

The executor half of the Mac control bridge. Its transport was never built, so nothing in the app
ever reached it; its only non-test caller was zero. `test_the_swift_and_python_registries_agree`
asserted that the Swift operation catalogue and this Python allow-list were identical — a
relationship that became **false by design** when the phone stopped being a remote control for a
Mac and became the backend itself. The Swift catalogue is now the *device's* operations; the Python
list was the *Mac CLI's*.

Keeping it would have meant either deleting the guard (leaving an untested remote-execution surface)
or forcing two lists to agree that describe different machines. Both are worse than removing dead
code that git still remembers.

## 2026-08-08 — Gate zero must run IN-APP, measured (and the jar trap caught me first)

⚠ **Simulator Safari is signed OUT of ChatGPT; the app is signed in.** Measured on both pages at
once through IWDP, which sees them both:

| Surface | UA | `#prompt-textarea` | login wall |
|---|---|---|---|
| Simulator Safari | `Version/26.5` | absent | **yes** |
| The app's `WKWebView` | `Version/17.0` | **present** | no |

I opened `chatgpt.com` with `simctl openurl` — which targets **MobileSafari** — probed it, and got a
login wall. The owner caught it before I spent anything on the wrong surface. §14's *"say which
surface you measured on"* is not bookkeeping: the two pages differ in whether the account exists.

**Consequences for the gate-zero run:**

1. **Drive it in the app, not Safari.** `simctl openurl` is the wrong tool here entirely. The app's
   web view only *exists* once Browser watch has opened that platform — the views are retained by
   design, the login sheet's is not — so the sequence is: launch app → tap the platform tile in
   Browser watch → then `iwdp.list_pages` shows it.
2. **Pick the page by UA, never by URL or title.** Both pages are `https://chatgpt.com/` and their
   titles differ only by a suffix Safari adds. `Version/17.0` is the app; `Version/26.5` is Safari.
   ⚠ Appendix B notes this discriminator breaks under `SR_DESKTOP_WEB=1`.
3. This pulls decision **B5**'s *"in-app before done"* forward to **day one** for gate zero, which
   §3.2 already anticipated — for a different reason (the jar was empty then; now it is the only
   jar that is full).

**Tap coordinates are in POINTS.** The screenshot is 1206×2622 at 3x; the screen is 402×874pt.
Divide by 3. AXe took `tap -x 109 -y 330` for a tile whose pixel centre was (327, 991).

---

## 2026-08-08 — Gate zero, measured IN-APP on a live Deep Research run (interim, not the verdict)

⚠ **These are mid-run readings. The pre-declared observable requires a COMPLETED page** and the
final measurement is recorded separately below when the run finishes. They are written down anyway
because they already eliminate two hypotheses and because three of them are defects in the gate's
own tooling, found by taking the measurement rather than by reading the code.

Surface: the **app's** `WKWebView` (UA `Version/17.0`), driven by the new `bin/gate_zero_run.py`.
Conversation `chatgpt.com/c/6a77e35b…`. Prompt sent 19:17 with Deep Research armed; readings below
at ~19:22–19:37.

| Probe | Reading |
|---|---|
| `[data-turn]` census | `[{turn: "user", chars: 395}, {turn: "assistant", chars: 15, text: "ChatGPT said:"}]` |
| Longest **rendered** element in the main document | **881 chars** (`DIV.contents`), later 859 |
| `document.body.innerText.length` | **527** |
| `document.body.textContent.length` | **438,226** |
| Longest element by raw `innerText`, unfiltered | **434,403 chars — a `SCRIPT`** |
| iframes | `connector-openai-deep-research.web-sandbox.oaiuserco…` **402×511**, `contentDocument` **null**; plus `chatgpt.com/backend-api/sentinel/frame.html` 0×0, same-origin, 0 chars |
| Shadow roots | **0** |
| `button[data-testid="stop-button"]` / `aria-label*="Stop"` | **absent from the first poll onward**, while the run was demonstrably in flight |

**What this already settles.** **H5 (shadow DOM) is dead** — zero shadow roots. **H1/H2 are not
consistent with these readings**: the longest rendered node in the main document is 881 chars
against the BE's 2000-char tier floor, and the assistant turn holds a speaker prefix and nothing
else. The research plan card visible on screen (*"Solid-state EV battery assessment"* + a task
checklist) **is not in `document.body.innerText`**, and the only container it can be in is the
cross-origin sandbox frame. That points at **H4**, the one branch §3.3 says costs architecture —
so the earlier draft this recipe walked back was closer to right than §3.1's caution allowed.
**Do not act on that until the completed-page measurement confirms it**: the activity panel being
in a frame does not prove the *final report* is, and ChatGPT may well render the finished document
into a turn in the main document, which would put us back on H1 with a timeout fix.

### Three defects in the gate's own tooling, found by measuring

1. ⭐ **PROBE 4 read a `<script>` body as the page's longest text.** `innerText` is specified as
   *rendered* text and should be empty for a non-rendered node; this WebKit returns the script
   source — 434,403 chars against 881 rendered. The verdict logic compares that number to the
   2000-char floor, so unfixed the gate announces *"the text exists in the main document but not
   under `[data-turn]` — H2, re-point the selector, no frame work"* for a page whose report is in a
   cross-origin frame. That is the most expensive wrong turn the gate can take, produced by the
   probe meant to prevent it. Fixed: `SCRIPT`/`STYLE`/`NOSCRIPT`/`TEMPLATE` excluded, and the test
   **executes the probe's JavaScript** under node against a planted 434k script rather than
   asserting the exclusion list is present in the source.

2. ⭐ **The completion gate was a guard that cannot fire.** It refused to probe while
   `stop-button` was on screen — and on a Deep Research run that control **never appears at all**.
   So "the run has finished" was true before the run had started planning: absence of something
   permanently absent. Replaced with `completion_verdict`, which demands **positive** evidence and
   treats `unknown` as a refusal, naming the DR sandbox frame when it sees one.

3. **The page was selected by URL substring.** Both surfaces serve `https://chatgpt.com/` and only
   the app is signed in, so the tool could measure Safari's login wall and report "no report node"
   for the most boring possible reason. Now selected by user agent, and it **refuses** rather than
   falling back to the other surface.

### And one in the mutation harness

`bin/mutate.py`'s pytest runner counted a **skipped** test as a pass. The new probe test called
`shutil.which("node")` and skipped, because `run()` pins `PATH` to three directories that do not
contain this machine's node — so pytest exited 0, the harness printed **CAUGHT**, and no assertion
had run in either direction. The Swift runner already demanded evidence that tests executed; the
pytest one now does too, and the probe test **fails** rather than skipping when node is missing.
A test that opts out when its dependency is absent cannot fail, and a test that cannot fail
protects nothing.

## 2026-08-08 — Browser watch turns OFF hit-testing, so HID taps cannot reach the page

`LiveRunView` applies `.allowsHitTesting(interactive)` with `interactive` defaulting to **false**,
which is right for a human: a stray tap arriving mid-automation competes with the run for the same
composer, so taking over is deliberately an explicit, reversible decision.

⚠ **But AXe taps are indistinguishable from a human's**, so while Browser watch is showing a
platform, the substrate's HID channel cannot reach that page at all. Measured: `geometry.calibrate`
failed with *"fewer than two probe taps produced a trusted event"* on all four candidate points,
`Recorded: []` — which reads as a broken HID channel and is in fact a deliberate SwiftUI modifier
two files away. Tapping **Take over** first made the identical run work immediately
(`offset_y = 151.9`, the height of the app's chrome above the web view).

**Why this matters beyond gate zero.** §1.1 defect 1 established that ChatGPT's composer plus-menu
needs a **real** tap — a scripted click does not open it. So any in-app phase that must open a menu
(the Deep Research toggle, item 12's remaining selectors, item 14's per-platform setup) needs HID,
and HID is exactly what Browser watch suppresses. The run and the watcher currently cannot both
have the page.

**Not fixed, and deliberately not fixed blind.** The options are not equivalent — route the run's
taps through a channel the overlay does not gate; or drive in-app menus without HID; or have the
run take the view back when it needs to act — and choosing needs the completed gate-zero result
first, since an H4 outcome moves P2 extraction in-app permanently and changes how much of the
pipeline this blocks. Recorded here so the next session does not rediscover it as a broken tap
channel: **it is not broken, it is switched off.**

---

## 2026-08-08 — ⭐ GATE ZERO RESOLVED: **H7**, not H4. The report is fetchable as MARKDOWN.

**Measured on a COMPLETED in-app Deep Research run** (`chatgpt.com/c/6a77e35b…`, *"Research
completed in 8m · 58 citations · 374 searches"*, `widget_state.status == "completed"`,
`research_started_at 02:19:09Z` → `research_stopped_at 02:28:06Z`).

### The four probes, verbatim, on the completed page

```
PROBE 1 — turn census
[{"turn":"user","chars":395,"html":4784,"head":"Assess the state of solid-state batteries…"},
 {"turn":"assistant","chars":15,"html":1734,"head":"ChatGPT said:"}]

PROBE 2 — iframe census
[{"src":"https://connector-openai-deep-research.web-sandbox.oaiusercontent.com/?app=chatgpt&darkModeType=increased&locale=en-US&deviceType=mobile",
  "origin":"https://connector-openai-deep-research.web-sandbox.oaiusercontent.com",
  "pageOrigin":"https://chatgpt.com","w":402,"h":484,"access":"null contentDocument"},
 {"src":"https://chatgpt.com/backend-api/sentinel/frame.html?sv=20260423af3c",
  "origin":"https://chatgpt.com","pageOrigin":"https://chatgpt.com",
  "w":0,"h":0,"access":"SAME-ORIGIN: 0 chars"}]

PROBE 3 — shadow-root census
{"count":0,"biggest":[]}

PROBE 4 — longest RENDERED text anywhere in the main document
{"chars":859,"tag":"DIV","id":"","cls":"contents","attrs":"class","inFrame":false}

document.body.innerText.length   = 499
document.body.textContent.length = 438226   (script sources)
```

**So the main document holds 499 characters of chrome and the user's own prompt. The report, its
58 citations, and even the "Research completed in 8m" line are ALL inside the cross-origin frame.**
`[data-turn=assistant]` is the string `"ChatGPT said:"` and nothing else, on a finished run.

### The three H4/H7 experiments

| Experiment | Result |
|---|---|
| **IWDP frame targets** (§3.2 H4 half 1) | Three `frame` targets enumerate (`frame-21474836484/5/6`). `Runtime.evaluate` inside a `Target.sendMessageToTarget` envelope returns **nothing at all** for every one of them, while the same envelope against `page-12` returns normally. ⛔ **Frames are NOT evaluable over IWDP** — `iwdp.py:182-185`'s suspicion is confirmed as fact |
| **Same-origin fetch, cookies only** (H7, first attempt) | `GET /backend-api/conversation/{id}` → **404** `{"detail":{"message":"Log in to view this conversation.","code":"conversation_inaccessible"}}` — cookies alone are not enough |
| ⭐ **Same-origin fetch with the page's own session token** (H7) | `GET /api/auth/session` → `accessToken`, then `GET /backend-api/conversation/{id}` with `Authorization: Bearer` → **HTTP 200, 579,966 chars** |

### Where the report actually is

```
mapping[<tool node>].message.metadata.chatgpt_sdk.widget_state   (543,733 chars of JSON)
  └── .report_message.content.parts[0]                            ← 65,690 chars of MARKDOWN
      "# Solid-State Batteries for Electric Vehicles: State of the Technology in 2026
       ## Executive summary …"
```

30 headings, citations as `citeturnNsearchM` markers. Saved as fixtures:
`artifacts/gate_zero/chatgpt_dr_report.md` (65,690), `…/chatgpt_dr_widget_state.json` (543,733),
`…/chatgpt_dr_completed.html` (522,556 — the page DOM, kept for the record).

### What this means for §12 — the plan gets SIMPLER, not harder

* **H1, H2, H3, H5 are dead** (measured). **H4 is true of the DOM but irrelevant**, because H7 gets
  the same content without touching a frame.
* ⭐ **No HTML→markdown conversion is needed for ChatGPT Deep Research** — the platform hands over
  markdown. Item 2's `html_to_markdown` port is still needed for the *other* platforms and for the
  P1 brief, but it is **off the ChatGPT-DR critical path**.
* ⭐ **No `innerHTML` primitive, no frame traversal, no `WKFrameInfo`, no download tier** is required
  for this path — so the H4-only branch of §3.3 ("P2 extraction moves permanently in-app", which
  needed an owner decision under §15.1) **does not arise**. The fetch is same-origin JS and runs
  identically on both surfaces.
* ⭐ **A real completion signal exists**: `widget_state.status`, plus `research_started_at` /
  `research_stopped_at`. This matters because, as recorded above, the DOM offers **none** — the stop
  control never appears for a DR run and the completed page is textually indistinguishable from an
  unstarted one in the main document.
* ⚠ **Not yet established for Claude or Gemini.** This is one platform's answer. Their extraction
  still needs its own measurement, and the DOM ladder remains the assumption there.
* ⚠ **The access token is fetched per extraction from `/api/auth/session`**, exactly as the page's
  own client does. Do not cache it across runs and do not poll it — it is a session credential.

### A fourth defect in the gate, found by running it on the real answer

The verdict tested `same` before `cross`, so the **0×0 sentinel frame with 0 chars** outranked the
402×484 cross-origin frame the report was in, and the tool printed **"VERDICT: H3 — same-origin
sub-frame. Traverse contentDocument in resolve(). JS-only, no new transport."** That is confidently
wrong in the most expensive direction: it names a cheap fix for a page where that fix cannot work.
Now frames under 50px, and same-origin frames holding fewer than the floor's worth of characters,
are excluded from the ranking, and cross-origin is tested first. ⭐ **Ranking by the order the
branches happen to be written in is not ranking.**

---

## 2026-08-08 — P3's blocking question RESOLVED: NotebookLM takes **pasted text**, so no file picker

§12 item 16 said, in bold: *"First unanswered question: how do the three `.md` files become visible
to the iOS document picker at all? … Resolve this before writing any picker-driving code."* The
suggested answers were `UIFileSharingEnabled` / `LSSupportsOpeningDocumentsInPlace` on the app's
`Documents`, or an alternative.

**Measured in-app, on the real signed-in page.** Opening a new notebook's Add-source sheet and
enumerating its controls:

```
"upload / or add your files", "upload / Upload files",
"link / video_youtube / Websites", "drive / Drive",
⭐ "content_paste / Copied text"
document.querySelectorAll('input[type=file]').length  →  0
```

⭐ **"Copied text" is a first-class source type**, so P3 pastes the consolidated markdown and the
document picker never enters the design: **no plist change, no Files-domain export, no
`UIFileSharingEnabled`, and no equivalent of the backend's `set_input_files`.**

⚠ And the alternative was not merely harder, it was **closed**: there are **zero** `input[type=file]`
elements on that page on mobile. The backend drives uploads with Playwright's `set_input_files` on
exactly such an input; with none present, the file route on this surface requires the *native*
document picker — which is the thing item 16 was worried about, and it is now moot.

**Two more corrections measured at the same time, both of which break naive selectors:**

| Assumption | Measured |
|---|---|
| the host is `notebooklm.google.com` | ⚠ the page is on **`notebook.google.com`** (`/notebook/{id}?addSource=true`). `bin/drive_selectors.py`'s `HOSTS` and `bin/capture_selectors.py` still say `notebooklm.google.com`, so a page lookup keyed on that host finds nothing |
| the product is called "NotebookLM" | ⚠ it renders as **"Gemini Notebook"**. Any selector matching the visible string `NotebookLM` is matching a name the product no longer uses |

⚠ **One notebook was created in the owner's real account to measure this** ("Untitled note",
`/notebook/4af12864…`). §0.1's point 3 stands: each P3 run creates a permanent notebook and there is
no cleanup step anywhere in the backend or this plan.

---

## 2026-08-08 — Gemini's P2 setup, measured; and the Flash-Lite trap

**Owner's instruction:** *"In gemini we select gemini latest flash model and also the extended
thinking. Then from '+' we select 'Deep Research'."*

**Measured in-app** (signed in, `gemini.google.com/app`, composer placeholder `Ask Gemini`). The
model picker's button is labelled with the current family — **"Gemini Flash"** — and opening it
(HID tap, `isTrusted=true`) lists:

```
3.5 Flash-Lite   Fastest answers   New
3.6 Flash        All-around help
3.1 Pro          Advanced maths and code
Extended thinking  Complex problem solving
```

The "+" is labelled **"Upload and tools"**, not "+", so a selector matching the glyph finds nothing.

⛔ **Flash-Lite is a DIFFERENT FAMILY from Flash, and a substring match cannot tell them apart.**
"The latest Flash" is `3.6 Flash` today. `"Flash" in "Flash-Lite"` is true, so a naive
highest-version-containing-Flash picks `3.5 Flash-Lite` the moment the account is offered a
`3.7 Flash-Lite` — switching a **deep-research** phase onto the fastest, cheapest tier. Nothing
fails; the research is simply worse. `emubackend/models.py` matches the family **exactly** and takes
the highest version of it, with a test proving a hypothetical 3.7 Flash-Lite does not win the Flash
slot.

⚠ **Zero version literals**, per the standing rule — a pin rots in both directions, stranding the run
on an old model or matching something else when the numbering scheme changes. A test executes
against the module source to prove none crept in.

⚠ **Extended thinking is a MODIFIER, not a model**: it sits in the same menu with no version, so the
model parser must reject it as an option while the setup step still selects it.

## 2026-08-08 — P3 route CORRECTED by the owner: upload the P2 markdown files

Superseding the "Copied text" decision recorded earlier today. **Owner:** *"We go to sources and
click add sources. Then upload our prev phase 2 mds."*

So P3 follows the backend's own shape — three `.md` sources rather than one pasted blob. ⚠ The
obstacle measured earlier stands and is now the work rather than a reason to avoid it: the mobile
page carries **zero `input[type=file]`**, so "Upload files" opens the **native iOS document
picker**, and the three files must be written somewhere that picker can reach (the app's `Documents`
with `UIFileSharingEnabled` / `LSSupportsOpeningDocumentsInPlace`) and then selected with real taps
on a system sheet — which is native UI, so the Browser-watch hit-testing problem does not apply to
it. "Copied text" remains a measured, working fallback if the picker proves undriveable.

---

## 2026-08-08 — Claude measured in-app: one real bug, and two capture constraints

Signed in and rendering (`claude.ai/chat/…`), so the last unmeasured P2 platform now has facts
rather than assumptions.

⛔ **A real bug, found by reading the composer.** Claude's placeholder is
**`"Write your prompt to Claude"`**. The shared toggle-state predicate's chat-mode list held
`ask gemini` / `ask chatgpt` / `chat with` / `write a message` / `message ` — **none of which match
it**. So Claude could never report `placeholderChat`, therefore never a positive `off`, therefore
P1's disable-deep-research step could never *confirm* on Claude. This is exactly the half-a-guard
the predicate's own comment warns about for ChatGPT (`"chat with"` was added for the same reason):
the failure is safe in direction — escalation stays refused — but it blocks legitimate recovery
permanently. Fixed, with a test that runs the same matching rule against every measured placeholder
rather than grepping the source for a string.

**Two capture constraints, both of which change how Claude must be selectored:**

1. ⚠ **Claude's controls are icon-font ligatures with NO text.** The visible-button inventory is
   almost entirely private-use-area code points (``, ``, ``…). Text matching —
   which is how ChatGPT's Deep research item and NotebookLM's Copied text are found — **cannot work
   here**. Claude needs accessible names or test ids.
2. ⚠ **The app opened Claude on an EXISTING conversation**, not a new chat, and its model control
   reads `Sonnet 5 Medium`. P2 must start a new chat (the backend navigates to `/new`) or it will
   append a deep-research request to whatever the owner was last doing.

⚠ Claude's report CONTAINER remains unmeasured — that needs a completed Claude research run, which
costs a unit of its own cap. The DOM read stays the assumption there, and it is written down as one.

---

## 2026-08-08 — Audio is uploaded AS PRODUCED; the MP3 transcode is deliberately not built

The backend re-encodes NotebookLM's Audio Overview to MP3 at 160k using a vendored **LAME**, whose
**LGPL-2.1 licence is listed in recipe §15.3 as flagged, not decided**. Vendoring an LGPL encoder
into a shipped iOS app is an owner decision, not an implementation detail, so this build does not
make it.

**What it does instead:** uploads the file as the platform produced it — AAC in an `.m4a` container.
Both consumers accept that: the frontend streams it from an `<audio src>`, and P4 uploads it to
YouTube, which takes m4a. So the run completes without the encoder.

⚠ **Recorded as a deviation from the backend, per DoD 11.** If the owner decides MP3 is required,
the encode slots in immediately ahead of the upload and nothing else changes — the object name and
content type already follow whatever extension they are given, and there is a test that uploads with
an `mp3` extension and asserts the content type follows, so the seam is exercised rather than merely
claimed.

**Two field traps recorded while wiring it:**

* ⛔ **`links.audio_file` is NOT `links.audio`.** `links.audio` is the NotebookLM **share page** — a
  web page, which the generated Doc renders as "Audio Overview". `links.audio_file` is the
  downloadable object the frontend's YouTube step fetches. Writing the share page into `audio_file`
  hands P4 an HTML page to upload as a video.
* The Storage object is named from the **research id**, not from NotebookLM's own download name,
  which is title-derived: arbitrary, non-unique, and occasionally full of characters that need URL
  escaping. Two runs on one topic would otherwise collide.

---

## 2026-08-08 — ⚠ Claude's Research mode was NOT FOUND on the mobile web surface

Driven, not skimmed. On a **new** chat (`claude.ai/new`) in the app, the composer's
`Add files, connectors, and more` opener was **HID-tapped** (`isTrusted=true`) and the opened menu
enumerated in full:

```
Add files or photos  Ctrl+U
Add to project
Skills
Add connector
Add plugins...
```

**No Research item.** The composer row holds exactly three controls — that plus-opener, the model
selector (`Model: Sonnet 5 Medium`), and Send. Nothing else on the page offers a research mode; the
word "research" appears in `document.body.innerText` only inside the titles of recent conversations.

⚠ **One branch is genuinely inconclusive and is not being written up as settled.** A tap on the
model selector reported `isTrusted=true` but no menu items appeared, so whether Claude's effort /
mode options live behind it — the way Gemini's *Extended thinking* sits in its model menu — is
**unresolved**. §14's rule cuts both ways here: a script-driven negative is not a negative, and the
plus-menu result IS the strong form (real tap, menu opened, five items read), while the model-menu
result is the weak form and is recorded as such.

**Why this matters to the goal.** §5.3 and decision B1 specify P2 as **three** deep-research agents.
If Claude offers no research mode on this surface, then on iOS it can only be a *normal* Sonnet
answer to the brief — which is a different product from what the backend produces, and a **scope
question rather than an implementation detail**. Recorded rather than silently papered over: a P2
that quietly runs Claude in chat mode would produce a third "report" that looks like the other two
and is not the same kind of thing.

⚠ Claude's **report container** also remains unmeasured, and settling it costs a Claude research
unit — which cannot be spent until the mode question above is answered.

---

## 2026-08-08 — ⚠ RETRACTION: "Claude has no Research mode" was WRONG, and here is how

The entry above ("Claude's Research mode was NOT FOUND on the mobile web surface") is **withdrawn**.
Claude's composer opener was driven with a real HID tap, the opened menu was enumerated in full, it
held *Add files or photos / Add to project / Skills / Add connector / Add plugins* and no Research —
and that was written up as the strong form of a negative.

⛔ **It was not one. Claude has a `Chat` / `Cowork` mode switch, and the mode was never checked.**
Cowork is the agentic mode, and what was read is exactly Cowork's menu. Both controls are on the
page — a later probe found them, alongside a model selector reading `Opus 5 Max`.

**The lesson, which is not the obvious one.** §14 already says *"a script-driven negative is not a
negative"*, and the response to that rule has always been "so drive it for real". This was driven
for real — a trusted tap, a menu that opened, five items read — and it was still wrong, because
**driving the control does not establish the STATE the control was in.** The missing question was
not "did the tap land" but "what mode is this page in", and nothing in the measurement asked it.

**The owner's setup, now encoded:** Opus at the **highest offered** (currently 5 — family only, no
literal, per the standing rule), **Chat** mode, and **Research** from the "+" menu. `REQUIRED_MODE`
carries the mode so a P2 that lands in Cowork fails as *wrong mode* rather than as *missing
selector* — which is the misdiagnosis that produced the retracted finding in the first place.

⚠ The "(standard mode)" labelling built on the retracted claim has been removed with it: labelling a
real deep-research report would understate the two that cost a research unit.

---

## 2026-08-08 — Claude's mode segments ARE readable, and that is the whole of the retraction

Follow-up to the retraction above, with the selector that would have prevented it.

Claude's composer carries a **two-segment mode control rendered as icons** — a speech bubble and a
checklist — which is why a text search of the page found no "Chat" button and why the earlier
measurement went straight to the "+" menu without asking what mode it was in. But the segments do
carry text nodes and, decisively, **`aria-checked`**:

```
{t: "Chat",   aria-checked: "true"}
{t: "Cowork", aria-checked: "false"}
{aria-label: "Model: Opus 5 Max", data-testid: "model-selector-dropdown"}
```

⭐ **The state was readable the whole time.** The retracted finding was not caused by a hard-to-reach
signal; it was caused by not asking. `mode_chat` / `mode_cowork` are now in the manifest and the
schema, with the instruction to assert `aria-checked=true` on Chat **before** opening the "+" menu.

⚠ **Claude's Research menu item is still NOT measured, and is being left that way deliberately.**
Repeated attempts to open its composer menu through this remote channel are unreliable — calibration
fails on viewport churn, the mode read intermittently returns nothing, and the menu enumerates empty
even after a tap that reports `isTrusted=true`. Having already produced one confident wrong negative
here, the honest state is: **the owner says Research is in the "+" under Chat mode, that is what the
code assumes, and the selector value remains uncaptured.** A resolve failure on it means
*uncaptured*, not *absent*.

---

## 2026-08-08 — ⭐ P3's UPLOAD ROUTE IS REACHABLE, and one earlier reading was wrong

Driven end to end on the real signed-in page, each step with a trusted tap:

```
Add-source sheet (?addSource=true)
  → "Upload files"            HID tap, isTrusted=true
  → WebKit native menu:        "Photo Library" / "Choose Files"
  → "Choose Files"            HID tap
  → THE NATIVE DOCUMENT PICKER OPENS  (Recents / Shared / Browse, a Search field)
```

⚠ **A correction to an earlier entry.** It recorded `document.querySelectorAll('input[type=file]')
.length → 0` and concluded the file route was *closed* on this surface. The count was accurate at
the moment it was taken and the conclusion was not: WebKit only shows that Photo Library / Choose
Files menu for a **file input**, so the page has one — created on activation, or otherwise absent
from a snapshot taken while the sheet sat idle. **A DOM census is a measurement of one instant, and
"not present now" is not "does not exist".** The same shape of error as reading Claude's menu
without checking its mode.

**So the owner's chosen route — upload the three P2 `.md` files — is viable**, and "Copied text"
stays as the measured fallback rather than the plan.

⛔ **Two things stand between here and a driven upload:**

1. **The picker's UI is NOT in the app's accessibility tree.** With it open, `axe describe-ui` on the
   app returns a single node (`Application: Super Research`) — the picker is presented by a separate
   system process. So it cannot be enumerated the way every other control in this repo is found;
   driving it means screen coordinates or a different channel, and a selector-style approach will
   simply find nothing.
2. **`UIFileSharingEnabled` / `LSSupportsOpeningDocumentsInPlace` are in `build_app.sh` but NOT in
   the installed build.** The app on the Simulator predates them, so the run's `Documents` folder
   will not appear under **Browse** until it is rebuilt. ⚠ A plain rebuild installs over the top and
   keeps the container — **never `--clean`**, which uninstalls and takes the platform logins with it.

---

## 2026-08-08 — The app REBUILT with the file-sharing keys, and the logins survived

`bash bin/build_app.sh <UDID>` — a **plain** rebuild, never `--clean`. Verified afterwards on the
installed bundle:

```
UIFileSharingEnabled              → true
LSSupportsOpeningDocumentsInPlace → true
data container                    → preserved (Cookies, HTTPStorages intact)
the app's own readout             → ChatGPT / Gemini / Claude / NotebookLM all "signed in"
device                            → Online, heartbeat 0s, serving, paired to Rocky
```

⭐ **That is the check that mattered.** `--clean` runs `simctl uninstall`, which deletes the Data
container and with it every platform login, the Keychain API keys and the pairing identity. A plain
rebuild installs over the top; the app confirms all four sessions still live.

⚠ **A mistake of mine, recorded because the shape of it recurs.** After the rebuild the app was on
its home screen, and I fired a stored tap sequence — captured on a *different* screen — to reach the
picker. My own script had already printed `no notebook page` on the line above. The taps opened the
People popup instead. **Coordinates are only valid for the screen they were measured on, and a
script that reports it cannot find its target has already told you not to proceed.** Same family as
reading Claude's menu without checking its mode, and as treating a one-instant DOM census as a
permanent fact.

**Verified so far for P3's upload:** the keys are installed, and a run's files written to
`Documents/runs/{researchId}/` exist on disk. **Not yet verified:** that they appear under the
picker's **Browse** tab, which needs the full live chain (Browser watch → NotebookLM → source sheet
→ Upload files → Choose Files → Browse) driven in one go.

## 2026-08-08 — Claude's Research control CAPTURED, and the wrong cause corrected twice

⭐ **Claude has Research, and it is exactly where the owner said it was.** Measured in-app with the
state verified first this time — `Chat` segment `aria-checked=true`, `Cowork` false, model reading
`Model: Opus 5 Max` — the composer "+" menu enumerates **seven** items:

```
menuitem          Add files or photos   Ctrl+U
menuitem          Add to project
menuitem          Skills
menuitem          Add connector
menuitem          Add plugins...
menuitemcheckbox  Research      aria-checked=false   data-unchecked
menuitemcheckbox  Web search    aria-checked=false   data-unchecked
```

Research is a **`menuitemcheckbox`**, i.e. a toggle like ChatGPT's, so its state is READABLE and
`enable_deep_research` consults it instead of assuming — which matters because deep-research state
persists across runs and an unconditional tap on run two turns it **off**. Its `id`
(`base-ui-_r_5k_`) is re-minted per render and must never be used as a handle; the text on the role
is the stable one. Selector coverage **26/33**.

⛔ **"Claude has no Research mode" was wrong FOUR times, and my first explanation for why was also
wrong.** The retraction recorded earlier blamed the Chat/Cowork mode — plausible, confidently
written, and **not what happened**. Two independent bugs, both mine, each sufficient on its own:

1. **The enumeration query.** It asked for `[role=menuitem],[role=menuitemradio],[role=option]`.
   Research is a `menuitemcheckbox`. The menu was open, in Chat mode, and the two toggles were
   filtered out of the *result* — a clean, plausible read of exactly five items.
2. **The calibration.** Later taps used a hardcoded `scale 1.0, top chrome 151.9pt` while this
   surface renders at zoom **≈1.067**. The tap landed **~25 CSS px above** the "+" and the menu
   never opened. `isTrusted` was `true` on every one of those taps.

⚠ **The generalisable lesson: a trusted event is not evidence that the intended element was hit.**
`tap_element` returns the target for precisely this reason and only the weak half of its result was
being read — its own docstring says so. With a *measured* calibration the tap lands within **0.2 px**
and the menu opens every time. Second lesson: **a confidently-stated wrong cause is worse than an
unexplained failure**, because it aims the next three attempts at the wrong thing.

The same missing role was in the **production resolver**, so a perfectly correct manifest entry
would still have resolved to nothing — and that failure presents as "this platform has no Research
mode". Fixed in `resolve()`, with the guard driven against a role-aware page rather than the shared
fake (which answers any comma-separated selector and therefore cannot fail).

**Honest limit:** whether *Cowork's* menu offers Research has still never been enumerated. The
manifest note claiming it does not has been removed — that was inference standing in for a
measurement.

## 2026-08-08 — The mutation harness corrupted the repo, and how it presented

⛔ `bin/mutate.py` edits sources in place and restores in a `finally`. A backgrounded run was killed
with `pkill`; **`SIGTERM` terminates the interpreter without unwinding**, so the `finally` never ran
and the mutant stayed in the working tree — `_dismiss_opener`'s `if not state.get("open")` left as
`if False`.

⚠ **The cost was the presentation, not the corruption.** Nothing announced it. The next full suite
showed four failures in `test_selectors_and_phases.py` about menus refusing to close, which reads
exactly like "the change you just made broke the opener logic" — and the change in question was in a
different function entirely. In a tree with ~3,200 lines of uncommitted work, `git diff` cannot pick
it out.

Two fixes: the harness now restores from a **signal handler** (SIGTERM/SIGINT/SIGHUP, exiting
128+n so a killed run cannot look like a passing one), and a new guard asserts no mutant is present
in any source — so this is named as corruption instead of debugged as a code bug.

⭐ **That guard immediately found five mutations whose anchors no longer matched anything**, i.e.
five guards that had silently stopped being verified (the manifest reformat, my own role-list edit,
and three that drifted when the code around them changed). The harness prints `ANCHOR MISS` and
moves on, so it goes quiet exactly the way the decorative guards it exists to catch do. All five
re-anchored and re-verified as CAUGHT.

## 2026-08-08 — Why the end-to-end run cannot be started from this session (measured)

⛔ **Correction to something I stated wrongly.** I reported that the undeployed `firestore.rules`
would block the device's writes to the research tree. **That is wrong, and §8b.3 already said so:**
the rules gate's 14/14 is verified against the *old* fixture, which is what is actually **deployed**
— so it is evidence about the deployed rules. Device writes to the research tree are permitted
today. The only expected 403 is the **worker-rest path** (`restingWorkerIds`, new in the FE repo and
not yet deployed), and the recipe states plainly that this "is not a defect in the app". The deploy
is still owner-only, but it is **not** what stands between here and a run.

**What actually blocks it, measured this session:**

| Route tried | Result |
|---|---|
| Submit in the web app, Simulator Safari | Signed **out**; Google prompts for the owner's email + password. Not attempted — those are the owner's credentials. |
| Seed `devices/{id}/queue` as the device | Rules: `allow create: if isDeviceMember()`, i.e. **owner or sharedWith only**. The synthetic device may `read` the queue to dequeue, never create. Correct, and deliberate. |
| A local/manual run trigger in the app | None exists. `SR_C1` and `SR_SCREENSHOT_STATE` are a contract harness and a preview state; neither starts a real run. |
| `bin/e2e_simulator.py --platform chatgpt` | Opens a **Safari** tab (`backend.new_tab`). Only the **app** is signed in, so P0 would fail on the logged-in marker. Not a real-platform vehicle. |

⭐ **So the first link of the chain is structurally the owner's**, by the same rule that stops a
device enqueuing work for itself. Everything downstream of the enqueue is installed and live: the
app polls `devices/{id}/queue` against `super-research-492814` with **no permission errors**, all
four platforms report signed in, and the device is Online/serving.

**Ready for the owner:** submit a topic in the web app with this device selected. Nothing else is
needed first — not the rules deploy, which affects only the worker-rest path.

## 2026-08-09 — Gemini's P2 setup driven LIVE, and two controls that were specified but not wired

The owner restated the Gemini P2 recipe: latest Flash, extended thinking, Deep Research from the
"+" drawer, then fire. Driving it on the live page found that the *logic* was right and **unusable**.

| Gap | State before | Now |
|---|---|---|
| Model picker | **No selector at all.** The family+highest-offered pick and its tests existed with nothing to drive — "latest Flash" could never be applied here | Captured, unique. `aria-label` **prefix** match |
| Deep Research opener | The two-step path was in the entry's PROSE; the machine-readable `opener` was **empty**, so the drawer was never tapped. Measured: with the drawer shut there are **zero** drawer items on the page | `opener` set to the drawer button |

⚠ **The picker is matched on the label PREFIX and that is load-bearing.** Its accessible name ends
with the current selection — measured `Open mode picker, currently Gemini Flash` — so an exact match
breaks the moment the control succeeds at its job. It also means the state is READABLE before
deciding, like Claude's.

⚠ **The button shows the FAMILY, the rows carry the VERSION.** Live rows: `3.5 Flash-Lite Fastest
answers`, `3.6 Flash All-around help`, `3.1 Pro Advanced maths and code`, `Extended thinking Complex
problem solving`. The code read those rows and chose `3.6 Flash` itself — no literal was typed.

**Driven live, in the app, and verified at each step:** picker opened (tap landed within 0.2 px) →
row selected by family+highest → drawer opened → Deep Research selected → the composer gained its
`Deep Research` chip → topic typed → sent → the page reads **"Generating research plan"**.

⛔ **EXTENDED THINKING IS TAPPED BUT NOT VERIFIED, and it is recorded as unverified on purpose.**
No row exposes `aria-checked`/`aria-selected` (all four measured null), and no indicator mentioning
"thinking" appears anywhere on the page after selecting it. **Driving a control does not establish
its state** — the lesson from the four wrong Claude readings earlier the same day. Until a positive
signal is found, the code applies this blind. ▶ Owner: if it shows somewhere once on, say where.

⚠ **My own trap, hit again:** calibration probe-taps DISMISS overlays, and I calibrated *after*
opening the picker, so the menu was gone before the row could be marked. Calibrate first, then open.
It is already written down in this file; writing it down is not the same as doing it.

## 2026-08-09 — Gemini's plan step, and an OPEN question about where its report renders

⭐ **THE FIND, and it came from firing one live run rather than from any offline test.** Gemini's
Deep Research **does not start on send**. It replies with a research PLAN — measured at 1,233
characters — and then **stops**: generation ends, the text is stable, nothing is empty, and it reads
like a perfectly good answer. The plan sits behind a **`Start research`** button.

Without pressing it: the wait completes, the extractor harvests the plan, and the run ships a
document describing what it was *going to* research. Nothing fails and the artefact is plausible —
the same silent shape as every other bug this pipeline has had.

`start_research` was **in the schema, never captured, and pressed by nothing on either half.** Now
captured, wired into P2 on **both** halves, polled (the plan takes tens of seconds, so a single look
finds nothing and concludes the platform has no such step), and mutation-caught four ways. Pressing
it NAVIGATES — the URL gains a conversation id and the inspector connection drops — which is the
success path, not an error.

⚠ **OPEN, and deliberately not concluded.** After the press, research was confirmed running with
real report text streaming. Returning to the conversation URL later rendered an **empty shell**:
`model-response` count **0**, body **63 characters**. Two candidate explanations and no measurement
to separate them yet:

1. the Angular view had not hydrated when it was read (most likely — it was read ~14s after load);
2. the deep-research report renders somewhere other than the main document, the way ChatGPT's does
   (gate zero: 499 chars of chrome, report in a cross-origin frame).

If (2) holds, Gemini needs its own extraction route and `response_container: model-response` will
return nothing for P2 — the DOM read it currently uses is marked "NOT measured" in the code for
exactly this reason. **Not asserted either way**: one reading of an empty page is not evidence, and
this repo has already produced four wrong negatives from exactly that inference.

▶ Next live run: read the conversation after a longer settle, and if it is still empty, run the
frame/iframe census the way gate zero did for ChatGPT.

### 2026-08-09 (same day, later) — the "empty report" resolved: it was NAVIGATION, not extraction

The open question above is answered, and **neither** candidate was right.

**Measured after a proper 40-second settle on `/app/{conversationId}`:** `model-response` **0**,
`user-query` **0**, body **66 characters**, and the only iframe a 0×0 bookkeeping frame. The page
was rendering a **fresh chat** — its greeting rotates each load ("Let's jump in" / "The mic is
yours" / "Hi Sammy, what's the plan?"), which is the tell.

⭐ **The conversation was never lost.** The page's own sidebar still links to it — and that link
carries **extra query parameters** (`...44d22a84b&ec=GBRAkgU`) that a bare `/app/{id}` does not.
Setting `location.href` to the bare id lands on a NEW chat that looks exactly like an emptied
conversation.

⛔ **Why this matters beyond today:** resuming a run after a restart means navigating back to the
platform's conversation. Done with a bare id, the device would arrive at a blank new chat, extract
nothing, and report the report as missing — indistinguishable from a genuinely failed run, and it
would then plausibly re-run a deep-research unit that had already been spent. Navigate via the
platform's own link, and treat "zero responses on a conversation URL" as **navigation suspect**,
never as an empty conversation.

⚠ **And the operational lesson:** do not navigate the web view away from a live deep-research run to
look at something else. I did (to reach the web app), and that is what put a settled question back
into doubt for an hour. The report shape for Gemini is still uncaptured as a result.

## 2026-08-09 — Gemini P2 driven live end to end, and the extended-thinking retraction

**The owner's sequence, driven in-app and verified at each step:** latest Flash by family (the code
read the live rows and chose `3.6 Flash` itself) → **Extended thinking** → Deep Research from the
"+" drawer → topic sent → research plan returned → **`Start research` pressed** → researching.

⭐ **RETRACTION: extended thinking IS verifiable, and the earlier note here was a PROBE bug written
up as a platform limitation.** The picker's accessible name changes to
`Open mode picker, currently Flash Extended`. My probe searched visible elements for the word
"thinking" and found nothing, and I recorded "no state is exposed". The state was in the control's
own label the whole time — the same place Claude's model state lives, which this file already says.

⛔ **A WRONG MODEL WAS SILENTLY SELECTED, and only an outcome check caught it.** A tap that reported
a clean hit (landed coordinate within a pixel of the aimed rect) selected **Flash-Lite** — the
cheapest tier, the exact substitution `pick_latest` exists to prevent. Nothing failed; the header
simply read `Gemini Flash-Lite`.

⚠ **Cause, measured after two WRONG guesses of mine.** I asserted a coordinate-frame mismatch
between the probe's rects and the page's — disproved, they agree exactly. I then asserted a stale
handle registry — disproved, handles are distinct and correct. The measured fact is that
`tap_element` aimed at a *different element's* rect than the one just marked (it reported `cy=84.5`
for a row the page put at `cy=273`). ⭐ **The reliable method, now used throughout: compute the point
from the page's own rect, tap it, and identify the element that received the touch with a
capture-phase `pointerdown` listener.** That names the target instead of inferring it from
coordinates — which is what the tap helper's own docstring asks for and what the coordinate check
cannot do.

▶ **Not fixed in code:** the tap helper still aims by its own rect. Until that is repaired, any
menu-driven step is unreliable, and that affects all three platforms' P2 setup.

**In-flight measurement of where the report lives (NOT a conclusion — the run is still going):**
two `model-response` nodes at **1097** and **156** characters (the plan, and a stub) while the
document body holds **27,635** characters and **106** anchors. So the working output accumulates
OUTSIDE the response container. Whether the finished report lands inside one is unmeasured; the
manifest's DOM read for this platform is still marked unverified for exactly this reason.

### 2026-08-09 (correction) — the aiming bug is MINE, not the helper's

⛔ **The entry above blames `tap_element` for aiming at a different element's rect. That is WRONG and
is retracted.** Tested directly with two elements at very different positions (`cy` 228 and 26061):
the handle registry returns distinct handles and the correct rect for each. Rects also match the
page's own `getBoundingClientRect` exactly. **Three causes asserted, three disproved by measurement.**

**What survives contact with the evidence:** every wrong-row tap happened in a step that called
`scrollIntoView` and then tapped. Scrolling moves the row — the `cy=273` I had listed was the
pre-scroll position, and after the scroll that row really was near `cy=84`. The rect was right; the
*screen point* was computed across a layout that had moved underneath it.

⭐ **The rule, which is also what finally worked:** never measure, scroll, and tap as three separate
beats. Either avoid scrolling entirely, or scroll → settle → **re-measure** → tap immediately — and
confirm with a capture-phase `pointerdown` listener that names the element which received the touch.
Identity at the moment of contact is the only evidence that survives a moving layout; a coordinate
comparison against the rect you aimed at cannot see this failure at all.

⚠ **Recorded because I got it wrong three times in a row today, each time confidently.** The pattern
is always the same: state a cause, then look. The order has to be reversed. Nothing in the substrate
needed fixing; the caller did.

### 2026-08-09 — Gemini's report and sources, measured on a COMPLETED run

The run finished ("I've completed your research"). Three measurements, all from the finished page:

| Fact | Measured |
|---|---|
| `model-response` nodes | 3, at **1086 / 145 / 23273** chars |
| The report | inside **`message-content`** (23,273 chars); also rendered in `deep-research-immersive-panel` |
| Sources | **`deep-research-source-lists`**, one element, **50** anchors, headed "Sources used in the report" |

⛔ **The manifest's `response_container` was `model-response` alone, which yields the 156-character
completion notice plus a title card — not the report.** A P2 reading it harvests a notice short
enough to be rejected, so it presents as an extraction failure rather than as the wrong container.
`message-content` is now listed first; `model-response` stays as the P1/chat-mode fallback.

⚠ **Sources are SCOPED deliberately.** Unscoped, `a[href^=http]` matches **106** anchors document-
wide — most of them research-progress chrome. Scoped to the source list it is 50 real ones.

⛔ **The in-flight probe FALSE-POSITIVES on this page.** With the research finished, a `Stop response`
button is still in the DOM at **height 0**. The generating check matches by selector alone, so it
reads "still working" forever and a run would wait out its entire timeout on a completed report.
▶ The check needs a visibility test, not just a match. **Not fixed yet.**

⭐ **The coverage gate immediately did its job:** capturing gemini's last selectors made it CLEAR on
selectors, and the gate now FAILS with "cleared C0 but never run in-app: ['gemini']". That is the
clause-2 invariant working exactly as designed — the fix is to record a real in-app verdict for
gemini, never to relax the gate.

### 2026-08-09 — in-flight probe: visibility fixed on one half, ABSENT on the other

**Fixed (backend half):** the in-flight check now requires the control to be *rendered* — non-zero
width and height, not `hidden`/`none` — instead of merely matching a selector. Measured cause: on a
COMPLETED deep-research page a `Stop response` button remains in the DOM at **height 0**, so a
selector-only check reports in-flight forever, the wait never completes, and the run spends its
whole timeout on a finished report before reporting a *timeout* — which invites raising the budget
for a condition no waiting fixes. Tests EXECUTE the probe's JavaScript against stub elements
(zero-height alone → false; visible → true; both present → true; none → false); mutation-caught.

⚠ Rendered-size test rather than `offsetParent`: a `position: fixed` control has a null
`offsetParent` while being perfectly visible, and stop buttons are routinely fixed.

⛔ **The app half has NO in-flight check whatsoever.** Searched: there is no stop-control probe in
it at all; its wait rests on content stability alone. That is the very shape the backend half's
probe exists to defeat — measured previously on live ChatGPT, an assistant turn read `Pro thinking`
(27 chars) and held it, perfectly stable, while the platform was still working. Stability is a
NECESSARY condition for completion and never a sufficient one; only the platform can say it has
stopped.

▶ **Not built.** The app half needs its own in-flight probe with the same visibility rule before it
can be trusted to decide a phase is finished. Until then its waits can complete early on a stable
placeholder, which yields a plausible short artefact rather than a failure.

### 2026-08-09 — what is left, and why it is not capturable from here

| Platform | Missing | Why it could not be captured now |
|---|---|---|
| claude | `sources`, `artifact_panel` | Both exist only on a page that has PRODUCED a research response. Measured on the live tab: a fresh chat at `/new` carries 456 chars and four testids (`user-menu-button`, `file-upload`, `chat-input`, `model-selector-dropdown`) — neither target is present, and no amount of DOM searching invents them. Capturing them costs one Claude Research unit. |
| notebooklm | `generate_audio`, `audio_ready_marker` | Need a notebook with sources that has reached the audio step. |

⚠ **Do not start a live research run without the context to see it through.** Today a Gemini run was
left mid-flight while attention went elsewhere; the page was navigated away from and an hour was
spent re-establishing what had already been measured. A run that nobody is watching when it settles
yields nothing — the report shape is only readable in the window after it completes.

## 2026-08-09 — the audio chain: what was built, and the contract facts behind it

**Owner directive (supersedes waiting on run intake):** *"I'm not gonna submit anything. Please
finish it all"* — extraction firing for P1/P2/P3, P3 adding sources, the notebook link made PUBLIC
for frontend streaming, the audio overview at the configured length, then downloading it, **as MP3,
delivered like the original backend**.

**Built and mutation-caught:**

* **Audio length from the frontend's config.** ⭐ The field is **`podcastLength`** — `short` /
  `default` / `long` — read from the backend, not guessed. The frontend's podcasts screen shows a
  differently-named derived duration; building against that name yields a device reading a field
  nothing writes.
  * ⛔ The fallback is **`long`**, NOT the value *called* `default`. The backend chose long so
    pre-feature configs keep their historical behaviour; the tempting reading silently shortens them.
  * ⛔ **Two sources, later wins:** the value merged to disk at prepare time, then a phase-time
    re-read that overlays it. Owners change the setting after queuing, so disk-only honours a stale
    length — and the artefact is a good audio file of the wrong duration, which nothing flags.
  * ⚠ **That re-read is DENIED for this device's identity** and the backend tolerates it explicitly
    (synth device user, user-tree research doc). Unavailable is the NORMAL path: fall back to disk,
    never reset to the fallback, never fail the phase.
* **MP3 means MP3.** Delivery now defaults to `.mp3` **and refuses to upload bytes that are not
  one**, sniffing the container (ID3 tag / MPEG frame sync vs an ISO `ftyp` box). ⛔ Renaming is not
  converting: the cheap fix gives the object an `.mp3` name, a working URL, and possibly a player
  that plays it — while every consumer that inspects the file fails on something that looks correct
  everywhere else. Refused BEFORE the upload, because an object that reaches Storage is published.
  ⭐ This deliberately makes the missing encoder LOUD instead of letting a fake MP3 ship.

**Contract facts confirmed in the backend, for the work that remains:**

* `links.audio` and `links.audio_file` are DIFFERENT fields with different consumers — already
  distinguished on this side; do not collapse them.
* The share-link pattern is **Share → create link → copy URL**, and it **degrades rather than
  fails**: it returns the plain conversation URL with a `verified=false` flag and a reason when the
  public link cannot be made. Port that shape for NotebookLM's public link — a run must not die
  because sharing was refused.
* A short click timeout is used on the share button deliberately, so an intercepting overlay
  fast-fails instead of burning the retry budget.

▶ **Not built:** extraction driven end to end for P1/P2/P3, P3 source-adding, NotebookLM's public
link, driving the audio overview at the resolved length, the download, and the MP3 **encode**
itself (the encoder's licence is the owner's call; the format is now decided).

## 2026-08-12 — P3 built end to end: notebook, public link, audio, MP3

**Owner directive:** *"finish it all … P3 adding sources, making notebook link public for streaming
into fe. Then audio overview (length basing on config from fe). Then at the end
extracting/downloading the audio too. We need it to be mp3 sent to fe/cloud just like original be"*

P3 existed as helpers and a manifest; **the run never reached it** — `RunExecutor` went straight
from the five documents to the handoff, so a finished run had no notebook, no link and no podcast.
It is now a stage in the run, between the documents and the handoff.

### Three corrections to what was already here, each measured rather than reasoned

⛔ **`links.audio_file` was written as a bare STRING, and as a DOTTED KEY the REST client did not
nest.** Two separate defects in one line, both silent:

1. The frontend reads `linksAgg.audio_file?.url` — measured at three call sites in its own source,
   including the P3-handoff gate. A string leaves that undefined, so the cloud takes its *"no usable
   audio"* fast path: P4 skipped, P5 completed, and the finished research has no podcast and **no
   error anywhere**.
2. `updateMask.fieldPaths=links.audio_file` means *the `audio_file` member of the `links` map*,
   while the body's `fields` map is keyed by plain NAMES with no dot interpretation. Passing the
   dotted key through declared a top-level field literally called `links.audio_file`, which the mask
   never mentions — and **a masked path absent from the body is Firestore's delete mechanism**. The
   write returns 200 and removes the field it was meant to set. The client now nests dotted keys for
   the body while the mask keeps the path, merges siblings into one map (P3 writes exactly such a
   pair), and refuses a patch that writes one name as both a leaf and a map.

⛔ **The MP3 guard was stricter than the backend it copied, and that is worse, not safer.** It
refused to upload anything that was not an MP3. The desktop's transcode is explicitly *"best-effort
and non-raising: on a missing ffmpeg, a non-zero exit, or any exception, returns the ORIGINAL path
unchanged so the podcast is never lost"*. Refusing converts "the podcast streams awkwardly for one
cloud consumer" into "there is no podcast", at the end of a run that has spent three deep-research
units. What survives is the half that was load-bearing — the name must never disagree with the
bytes — now enforced by **deriving the extension from the sniffed container** instead of by
refusing. A transcoder that returns non-MP3 bytes, or nothing, is not believed.

⚠ **Why the encoder is a seam and not an implementation:** iOS ships an MP3 *decoder* and no MP3
*encoder* (AudioToolbox converts to AAC, ALAC, iLBC — not MP3). Producing one needs a vendored
encoder, and that licence is the owner's call (§15.3). The default declines **and the run still
delivers a podcast the web app plays**; only stream-before-download for a cloud consumer is lost.
Deciding the licence swaps one conforming type and changes nothing else.

### What was built

| Step | How | Provenance |
|---|---|---|
| Create / **reuse** a notebook | manifest control, then poll for a `/notebook/{id}` URL | reuse is deliberate — every P3 makes a PERMANENT notebook in the owner's real account and nothing cleans them up |
| Add the source | **navigate** to `?addSource=true`, "Copied text", paste, Insert | ⛔ the manifest's `__url:` opener was **inert prose** — nothing in either half read that prefix, so the sheet was never navigated to |
| Public link | Share → access → "Anyone with the link" → read → verify → Save | ported from the backend, **degrades** to the plain notebook URL with `verified=false` |
| Audio Overview | customise **arrow** → format → length → Generate once | ⛔ never the card BODY (fires the one-click default = the duplicate), and **no clicks after Generate** |
| Readiness | `artifact-library-item` + `audio_magic_eraser`, placeholder absent | pinned from a real DOM dump; the selectors it replaced *"could NEVER fire"* |
| Download | capture the row's URL, re-fetch in-page with credentials, read back in chunks | there is no Playwright download event and no Downloads folder to scan inside an app |
| Delivery | prefer MP3, degrade to the real container, `links.audio_file` as a map | matches the backend's own degrade |

⭐ **The length now actually comes from the frontend.** `podcastLength` is read **at claim time** and
carried into P3, where a phase-time re-read overlays it. Two reads taken at the same moment are one
read: the value the run STARTED with would be lost, which matters precisely because the P3 re-read
is **denied** for this device's synthetic identity — the normal path — leaving the fallback nothing
to fall back to. The variant table is the backend's: `short → Brief with NO length step`,
`default → Deep Dive + Default`, `long → Deep Dive + Long`. ⛔ `short` is a different FORMAT tile,
not a shorter Deep Dive; a flow that always sets format-then-length hunts for a control that is not
on screen.

### The JavaScript is EXECUTED, not asserted on

`emubackend/tests/test_notebook_js.py` extracts each ported expression from the Swift source and
runs it under node against a **selector matcher** — comma lists, descendant combinators,
tag/class/attribute/substring tests over a tree the test builds. Twenty-eight cases, including the
ones that are only correct in the details:

* the strict public verify reads a dropdown trigger's **own text nodes**, so an OPEN dropdown's
  option labels cannot verify a private notebook as public;
* the copy fallback stays **inside the dialog** and reports `no_dialog` rather than pressing a stray
  page-wide "Copy";
* a control parked at x=-36 with a full-size rect and a live `offsetParent` — how NotebookLM renders
  its chat options — is **not** pressed;
* `Download` is pressed and `Delete`, two rows below it in the same menu, is not, through a
  **structural** ligature strip (no regex can tell `edit Rename` from a real two-word label);
* the length pick is EXACT, so `Long` cannot take `Longer`.

⚠ The extraction itself is asserted. A test that silently extracted nothing would pass every
assertion by never running one — the exact decorative-guard shape this repo keeps re-learning.

### Honest limits, written down rather than smoothed over

* **The customise panel has never been pinned.** The desktop hands it to a vision agent; its own
  code says the panel dump exists because the Generate and length controls are *"un-supplied"*. What
  is ported is the arrow (from a real console dump) plus a text-driven pick of the measured labels.
  If those labels have moved, generation fails **loudly** rather than clicking a neighbour.
* **The `share` selector is a guess** and is marked as one. It deliberately carries **no**
  `text_contains`: the audio card's overflow menu holds a row reading `share Share`, and a text
  match would open *that* — a click on a card that must never be clicked. Failing to resolve is the
  safe outcome, because the share step degrades.
* **The paste sheet has only ever been opened by a REAL tap.** Every click the pipeline can make
  reports `isTrusted === false`. If the sheet does not open, the error says exactly that instead of
  blaming the paste.
* **None of P3 has been driven on a live notebook**, because doing so needs a full run to reach it.

## 2026-08-12 — the join: a claimed run now actually runs

⛔ **`DeviceBackend.launcher` was never assigned by anything.** Intake, the claim, the pipeline, the
emitter, P3 and the handoff were all built and tested, and the one line joining them did not exist —
so the device claimed a queue entry, **stamped it so no sibling backend would take it**, and then
called through a nil reference. The run sat `ongoing` for ever and the owner's next run queued
behind it. Found while wiring P3, not by a test: nothing could have caught it, because every piece
passed its own tests in isolation and the missing thing was the absence of a caller.

Built: `InAppRunLauncher` — a **factory**, not a single executor, because `ContractEmitter` is bound
to one research (its paths, its `seq` guard, its write log) and a long-lived executor would write
every run's events into the first run's document. Attached deferred, because the device id does not
exist at construction and every research write is judged on
`request.resource.data.deviceId == request.auth.token.deviceId`. The claim site now **reports** a
missing launcher rather than returning quietly — a claimed-and-abandoned entry is the worst state
that loop can leave behind.

### Three more silent defects fixed on the way

⛔ **A navigation WIPES the injected page runtime, and a run navigates several times.**
`window.__sr` lives in the page's JS context, which is rebuilt on every document load — and enabling
deep research navigates (the URL gains a conversation id), as does confirming Gemini's research
plan. The runtime was injected exactly once, at the top of a run, so every call after the first
navigation threw *"undefined is not an object"*: a WebKit error raised against a selector that is
perfectly correct, at the point that looks like the platform's fault. Now re-injected **on failure
only**, so the healthy path pays nothing, and only for expressions that actually need the runtime —
a genuine error in someone else's JavaScript must still be reported as itself.

⛔ **The Storage bucket was nowhere.** Added, read from the plist's `STORAGE_BUCKET` and never
derived: Firebase changed its default bucket name (`<project>.appspot.com` → newer projects get
`<project>.firebasestorage.app`) and **this project is the newer form**, measured in its own plist.
A derived guess uploads to a bucket that does not exist and 404s on a URL that looks perfectly well
formed. Missing means empty, so the upload fails with a named `noBucket` pointing at the plist.

⚠ **`SRManifest` carries ONE platform** — the C1 gate drives one — so the production path would have
had three platforms with no selectors at all. The generator now also emits `SRAllManifests` from the
same `load_manifest`, so there is still exactly one source of truth.

### And a harness gap the wave found by hanging

An always-true empty-chunk guard in the audio read does not make an assertion **fail** — it makes
the loop advance by zero bytes for ever. The harness sat on one `xctest` for **31 minutes** with no
output, which is indistinguishable from slow progress, and the whole wave stalled behind it. There
is now a per-run timeout, a hang is reported as its **own** outcome rather than as "caught", and
that mutation is a `break` (a truncated podcast, which plays right up to where it stops) instead of
a loop. ⭐ A mutation that diverges proves nothing about the guard; only one that fails does.

⭐ **One mutation escaped and taught the most:** the degrade test for the share link exercised the
early return taken when there is no Share control at all, so it never reached the fallback it was
written to prove. A second test now drives the path where the dialog opened and the read found
nothing. *A test can assert the right thing about the wrong branch.*

### …and the run was invisible until NotebookLM

⛔ The executor emitted **no phase events at all for phases 1 and 2**, and never wrote
`currentPhase`. A run therefore showed the web app a research sitting perfectly still through three
deep-research runs — an hour or more — and then jumping straight to NotebookLM, which is exactly
what a device that claimed the run and died looks like. Now: `phase_start`/`phase_complete` for 1,
2 and 3, `currentPhase` written **alongside** `phase` (the contract says omitting it leaves the
homepage tile glowing the stale node for ever), and per-agent `running`/`completed`/`failed` so the
three agent rows move.

⭐ **Phase 1 ends when the BRIEF arrives, not when the loop does.** P1's product exists the moment
the first platform hands one back; ending phase 1 at the end of the platform loop would leave the
tile on "brief" through all three deep-research runs.

⭐ **The same weak-assertion lesson, twice more.** The P3-completion guard asserted that *a*
`phase_complete` existed — and the moment phases 1 and 2 began emitting their own, it passed while
the thing it names had stopped happening. It now matches the type **and the phase**. Mutation found
it; nothing else could have.

### Not verified on this box

The `firestore.rules` emulator gates cannot run here — **no Java runtime is installed**, so
`firebase emulators:start` exits before it begins. The write shapes changed in this wave (nested
maps for dotted field paths), and that is exactly what those gates exist to check against the real
rules. Every write still carries the top-level `deviceId` the device branch reads, so the risk is
low — but it is **unverified**, and it is the first thing to re-run on a box with a JDK.

## 2026-08-13 — the run the owner fires from the web app

Wiring the "select this device, submit a topic" path end to end turned up four things that would each
have made the first real e2e look like a broken device.

⛔ **The run blocked the heartbeat loop.** `beat()` awaits `pollQueue` → `claimAndRun` → the entire
run, so a 30-to-90-minute research meant: **no heartbeat** (the web app shows the device OFFLINE
within the beat window), no device commands, and — worst — **no run-command polling, so Stop and
Pause from the web app reach nothing at all**. Every control the owner touches during the run fails
silently, on a run that is progressing perfectly normally. The run is now detached and the loop keeps
beating; `awaitRunInFlight()` exists so a caller can still join it.

⛔ **Nothing on this device had ever written `busyWorkerIds`** — the only busy signal `freeWorker`
consults. Harmless while the run blocked the loop; fatal the moment it did not, because the very next
beat sees every worker free and claims a **second** run onto the worker already driving one. Two
runs, one set of web views. Now tracked locally, unioned into the read, and published so the web
app's worker pill moves.

⛔ **Our own 30-second zombie sweep would have deleted the queue entry mid-run.** From the second
beat onwards our claim looks exactly like a dead sibling's, and the log would have said
`stale-skip ZOMBIE` about ourselves. The active run is now exempt, and the entry is **deleted when
the run finishes** — which is the contract's own consumption rule (*"consumption is by delete
only"*), reached for the right reason instead of by accident.

⛔ **`briefText` and `config.podcastLength` were decoded away.** The first is a supported flow — the
owner pastes their own brief and P1 is skipped — and dropping it spends a P1 re-deriving a brief that
already exists, then answers a subtly different question. The second is the natural claim-time source
and is readable where the alternative may not be: the queue is this device's **own** subcollection,
while the research document's `pipelineConfig` sits behind a membership check.

### Logging, because the first questions after a run are always the same

`RunLog` writes **one file per research** under Application Support, timestamped per line, alongside
the console echo. A device log is a stream: it must be attached before the interesting moment, it is
interleaved with every other subsystem, and it is gone when the process ends — none of which suits a
90-minute run whose post-mortem asks *which step, what did the page hand back, how long did each wait
take*. `bin/run_log.sh <UDID> [--follow]` pulls it off the simulator. Reports and briefs are recorded
as **length plus opening**, because dumping 40,000 characters makes the trace unreadable while
omitting them makes "the extractor returned something short" unanswerable.

⭐ **The detachment silently weakened two existing guards, and mutation caught both.** The lost-race
test asserted `spy.launched.isEmpty` **synchronously** — true of a run that had not launched *yet* —
so deleting the stand-down `return` sailed through. And the new detachment guard itself HUNG under
its own mutant rather than failing, because the blocking fake held for ever. Both fixed: the race
test joins the run, and the fake self-releases on a bound so a synchronous regression **fails**
instead of hanging. *Changing when something happens can break a test that never mentions timing.*

## 2026-08-13 — the permanent audio answer: move the index, don't re-encode

⭐ **The MP3 transcode was never about the codec.** An ISO base-media file keeps its index — the
`moov` box, saying where every chunk of audio lives — as a box like any other, and NotebookLM writes
it **after** the samples. A consumer that streams therefore gets megabytes of audio with no map of
them and cannot begin playback. An MP3 has no index at all (every frame is self-describing), so
converting to one *incidentally* fixes it. The backend's own docstring says exactly this.

So the device fixes it **directly**: same audio bytes, same container, index moved ahead of the
samples. Nothing decoded, nothing re-encoded.

| | Transcode to MP3 | Move the index |
|---|---|---|
| Fixes streaming | yes | yes |
| Quality generation lost | one | none |
| Needs a vendored encoder | yes (LGPL — an owner decision) | no |
| Possible on iOS at all | **no** — Apple ships a decoder, not an encoder | yes |
| Cost on a phone | minutes of CPU | a byte rearrangement |

**Two measurements that settled it**, taken before recommending rather than after:

* The **frontend already ships ffmpeg** (`ffmpeg-static`, bundled specifically into
  `/api/uploadYouTube`) and P4 encodes *"libx264 stillimage + AAC"* from the Storage URL. It decodes
  whatever it is given, so handing it an MP3 buys P4 nothing.
* **Nothing in the frontend inspects the audio format.** No branch on `.mp3`/`.m4a` in any P4/P5
  handler; the Podcasts page is a plain `<audio src>`, and browsers play both.

⇒ MP3 is not a requirement of any consumer that could be found. It was a workaround. If literal
parity with the desktop's artefact is ever wanted, the cheap place is the cloud, where the encoder
is already installed and already reading this object.

### The whole job is the offset fixup

`stco`/`co64` hold **absolute file offsets** for every chunk. Moving the index forward pushes the
audio later by exactly the index's own size, so every offset is now wrong — and a file with a
correctly-placed index and stale offsets is **worse than the original**: it starts playing
immediately and then reads garbage. Guarded on every side, and each guard has a mutation:

* a 32-bit table that would **overflow** is refused, not truncated — widening it to 64-bit changes
  the index's size, which changes the shift, which changes the offsets: a circle;
* an index with **no offset table found** is refused rather than moved;
* a parse that **loses sync** reports nothing rather than the boxes it managed to read;
* the output must be the **same length** — a different one means a box was dropped or duplicated,
  and the only symptom would be audio truncated at the end;
* an already-streamable file is left completely alone.

⚠ A file that cannot be corrected is still **delivered**, with `streamable: false` recorded. Needing
to download before playing is a far smaller problem than having no podcast, and the web app
downloads either way.

### A third harness gap, found the same way as the first two

The overflow mutation made the code **trap** (`UInt32(value)` on an out-of-range value) rather than
fail an assertion. A trapped `xctest` prints no `Executed` line, which landed in the harness's
"filter matched nothing" branch and stopped the wave with a message naming the wrong cause. The
message now names both causes and prints the stderr, and the mutation was changed to one that
silently **wraps** the offset — a realistic defect that the assertion rejects cleanly. ⭐ First a
mutant that hung, then one that crashed: *detection is not the same as a guard failing, and only the
second is worth scoring.*

## 2026-08-13 — People, and a Browser watch that says where the run IS

**People, main screen.** The people were an 11pt tertiary comma-joined line at the bottom of their
own card — smaller and fainter than the numbers above them. Now named rows with an avatar, so a
person carries the same weight a platform tile does in the card above. Capped at three with a
counted remainder: "+3 more" is a fact, a name cut off mid-word is an accident that looks like one.

**People, popup.** Bigger name (title) and a legible email (body, not 11pt). ⛔ **No avatar here**,
deliberately — the web app's "Shared with" popup lists people as name-over-email with no badge, and
a circled initial on one surface and none on the other makes one product look like two. The
main-screen card keeps its avatar because there the rows compete with platform tiles for attention
rather than being read as a list.

⚠ An earlier pass boxed and labelled the free-worker pills. It read fine in isolation and was
**redundant on the page** — the legend directly above already explains the glyph — and it gave the
pills more weight than the people above them. Reverted to a bare row.

⭐ The one piece of real logic — what glyph an avatar shows — moved to the CORE, because **nothing
in `ios/App` is compiled by `swift test`**. An unresolved uid must get `?`, never a letter pulled
out of a hex string: a confident-looking initial on an identity the device could not resolve is the
"partial identity that looks confirmed" failure this codebase already names, and a glyph carries no
caveat the way the line beneath it does.

**Browser watch.** During a run the worker dot **breathes** and the platform tile the run is
actually typing into **glows**. That is the one question this card exists to answer — *which tab do
I open to see it happening* — and it previously showed four identical tiles.

⛔ **Reported by the run, not read back.** `RunState.agents` is `[:]` on the per-worker path and the
document's `currentRun*` fields describe worker 1 only, so a glow driven off either would be blank
on every other worker and stale on the first. The run executes in this process, so it simply says
where it is (`LiveRunActivity`) — no round trip, no rules to widen, no lag.

⚠ Cleared on **every** exit including a throw: a glow that outlives its run points the owner at a
dead tab, and on a 90-minute run "never changes" is indistinguishable from "still working".

⚠ The glow is a **static** highlight, not a jitter — the tile is a tap target and a moving one is
harder to hit. The motion lives on the worker dot, which nobody taps, and follows the same rule as
the online pill: motion only where it is honest.

⛔ **A measured correction to what the run writes:** agent statuses are `running` / `complete` /
`errored` / `skipped`, taken from the desktop's own writer. This wrote `completed` and `failed` —
plausible English, and words the frontend's tile logic does not recognise, so a finished agent
would have rendered as neither done nor failed.

⭐ **A mutation escaped and named a real gap:** deleting the pipeline's `defer { clear }` was
"guarded" by a test on the activity STORE, which knows nothing about who reports to it. A guard on
the thing being reported to says nothing about whether anyone reports.

## The device now obeys the account's pipeline Settings (2026-08-13)

A live run died four seconds after it started: P0 asked each platform for its login marker and all
three said no. Gemini was asked **418ms** after the run began. Three separate defects, found from
the run trace:

1. **`verifyLogins` was never read.** The owner had "Verify sign-ins before each run" switched OFF —
   which is the product's DEFAULT, because a proactive verify navigation is the strongest bot-score
   signal there is — and the device verified anyway. It read exactly one field of the pipeline
   config (`podcastLength`) and invented its own answer for the rest. `RunConfig` now decodes the
   whole `config` map the queue document already carried, with the backend's own defaults.
2. **Nothing waited for the page.** `PlatformWebViews` creates a web view lazily and calls `load()`,
   which returns immediately; the run drove whatever came back. The readiness gate waits for the
   document AND the composer — `C1Runner` had already measured that `readyState` alone is not
   enough on a hydrating SPA — and it runs before phase 0, because the normal configuration skips
   phase 0 and P1 still has to type.
3. **A run that produced nothing said nothing.** `startRun` writes `ongoing`; the success path
   deliberately leaves it there for the cloud to flip. The abandon path returned silently, so the
   research stayed `ongoing` for ever and the web app showed phase 1 all day. It now writes
   `status: stopped` + `lastError`, and deliberately does NOT write `stoppedBy` — that field's
   vocabulary is closed and every value in it names a human.

**Deliberate deviations**

* **The two phase numberings are mapped explicitly, not by equality.** The product's phase 3 is the
  podcast; this pipeline's phase 3 is the source harvest. Passing `skipPhases` straight through
  would make "no podcast" delete source telemetry on every platform.
* **`notLoggedIn` gained a `reason`.** It was reported for two different things — a signed-out page
  and a page that had not arrived — and only the evidence separates them.
* **The P4/P5 trigger still fires when the video is switched off**, matching the desktop, which
  fires it unconditionally and lets the route decide.

## Browser watch uses the People popup's pill (2026-08-13)

The card had its own "Worker N" mini-tile that named the same worker in the same state as the
popup and shared nothing with it. `WorkerSlotPill` is now shared; the row sits BELOW the platform
tiles (the platforms are the content, the workers are the filter); and the pill breathes while that
worker is driving a live page. The breathing lives in a `Breathing` child view because a closure
created inside a local `let` captures `self` immutably and cannot assign to `@State`.

## Appearance gains a Size control (2026-08-13)

XS–XL beside light/dark, persisted under `sr.textSize`, defaulting to M.

**How it scales.** One multiplier on `DS.F`, because the design system hands out fonts by point
size and `.dynamicTypeSize` moves only text that asked for a text *style* — none of this app's did.
`DS.F.title/body/label/code/codeLarge` had to become computed `var`s: as stored `let`s they were
evaluated once at first access, so changing the size would have moved every `mono(_:)` call and
left every `.label` behind — half the app resizing.

`AppSizeManager` is observed at `RootView`, not only inside Settings, or the sheet would resize and
the dashboard behind it would not. It is constructed in `AppDelegate` so the stored size applies to
the first frame rather than jumping after launch. The XS–XL control itself uses a FIXED font, so
the segments do not move under the thumb while being used.

## The Browser-watch pill: rest, and one hue (2026-08-13)

* **Rest is a long press here, a tap in the People popup.** Tap in Browser watch must select which
  browser you are looking at — that is the card's only job — and a tap that both switched the view
  and parked a worker would park one every time the owner changed tabs. The caption says "hold to
  rest" because a long press is not discoverable, and VoiceOver gets it as a named action.
* **Selection is a halo in the pill's own green, never the accent blue.** The fill was already
  `DS.C.ok` — the same token as its caption — and the blue selection ring was what made it read as
  a different colour from the web app's pill.
* **Resting from the device still depends on a rules deployment.** `restingWorkerIds` was
  owner-only; the device grant is committed in `dg-research` (`8b481ec`) but whether it is deployed
  cannot be determined from this repo. Undeployed, the press fails with a named 403 rather than
  silently.

## The worker pill, corrected against the web app (2026-08-13)

Three things were invented rather than transcribed, and all three were visible:

* **The green was wrong.** The pill used `DS.C.ok` — the ChatGPT teal `#10A37F` — while
  `account/page.tsx` draws the same pill in `bg-green-500`, `#22C55E`. Close enough to look like a
  rendering fault rather than a decision. Added `DS.C.worker` and pointed every surface that names a
  WORKER at it: the pill, its caption, the People legend, the daemon-loop chip, the worker-row dot.
  Everything that means "good" in general keeps `ok`.
* **The selection halo was an invention.** The web app has three pill states and no ring for
  anything else. It read as a circle drawn around the pill, which is what it was.
* **The pulse was a glow and a scale.** The web app's `animate-subtle-pulse` is an opacity breath.
  It now pulses on BUSY, matching, instead of only while a platform page was live — which went
  still during the gaps between platforms and made a mid-run worker look idle.

**Hold-to-rest did nothing, and the cause was the Button.** `Button` installs its own gesture
recogniser and claims the touch sequence, so an `.onLongPressGesture` attached outside it never
reached its threshold. Where a long press exists, the pill is now a plain view with both gestures
attached directly, long press declared first (declared after the tap, the tap wins on finger-lift
and the hold never completes). The People popup keeps its Button, where tap is the only verb.

## The composer was never filled (2026-08-14)

A live run failed with `unresolved(key:"send")` on ChatGPT. The send selector was correct; the
composer was empty.

`document.execCommand('insertText', …)` returned **false** — the editor refused the text — and the
runtime returned `{ok:false, path:'execCommand'}`. `ok` was read by **nothing in the repository**
(negative grep over all Swift and Python). `fillComposer` tested the path STRING only, so a refusal
was byte-for-byte a success, and ChatGPT's send button — which per `selectors_mobile.json:55` exists
only while the composer is non-empty — was then reported as a missing selector.

The rule now enforced is the repo's own, from `bin/gate_zero_run.py:246`: *"execCommand returning
true is not evidence the editor took it."* The gate read the text back and the product did not, and
`selectors_mobile.json:48` had accepted the composer selector on exactly that evidence.

* `S.insertText` reads the text back and compares a 24-character probe, matching the gate.
* It falls back — synthetic `paste` (a first-class input for controlled editors), then
  `beforeinput` — before reporting a refusal, and names `document.hasFocus()` when it does.
* It CLEARS first. The value branch appended, so retrying a research typed the prompt twice.
* `awaitComposerReady`'s Bool is honoured at all three call sites. It returns false on timeout and
  every caller discarded it, so a composer that never appeared was typed into anyway.

## Stop reached nothing (2026-08-14)

`pollRunCommands` decoded the owner's Stop, classified it, acked it, and called
`controller?.stopRun(…)` on nil — `RunController`'s only conformer in the repository was a **test
spy**. Independently, `InAppPipeline.run` had accepted a `shouldStop` since it was written and
nothing had ever passed one. Two breaks, both silent: the button acknowledged the press and the run
continued into a 40-minute `awaitResponse`.

`RunStopSignal` + `InAppRunController` connect it, and the stop is checked INSIDE the long wait —
between phases alone would have left it unnoticed for the rest of the hour. A stop ends the whole
run (not just one platform), marks its agents `skipped` rather than `errored`, writes `stopped`
with no `lastError`, and does NOT hand off.

## A killed run bricked the device (2026-08-14)

`markBusy` published `busyWorkerIds` at claim and cleared it at completion, and nothing cleared it
at boot. A process that died in between left the field saying "worker 1 is busy" for ever;
`workerState` unions that into the live set, `firstFreeWorker` then finds none, and every later
claim is declined — silently, because declining is also what a legitimately busy device does.
Reconciled at start-up, from inside `startHeartbeat()` — the one choke point all four start paths
share, because a join that must be remembered at four sites is how `controller` came to be nil.

## Whose run is it (2026-08-14)

`devices/{id}.workers` — `{uid, title, phase, totalPhases}` per worker — was read by this device and
cleared by it and **never written**, so a run in flight appeared as an anonymous `busyWorkerIds`
entry and belonged to nobody in either popup. Published from the beat, whole-map rewrite so a
finished run cannot leave a pill behind. The People popup's busy pill now stops its run on a long
press: the old note said Stop was impossible because it meant an addDoc into `devices/{id}/queue`
(ownerUid or sharedWith only) — true of that route, and no longer the route, since the run executes
in this process.

## Tap-Online-to-reset, and the busy set (2026-08-14)

The web app's Online pill opens a hard-reset modal that writes `{action: "hard_reset"}` into
`devices/{id}/commands` and promises it *"kills any running pipeline"*. The device DID handle the
command — `bounceForReset` stops the heartbeat, clears the cached run state and comes back, and it
honestly does not `os._exit` because iOS has no supervisor to respawn it. But it did **not** kill
the run: the run is a detached task, so it kept driving the platforms throughout. Now that a stop
channel exists, the bounce stops the active run first (through the same controller the web app's
Stop reaches) and gives it a moment to notice before clearing state.

**And the reconciliation added earlier the same day was wrong on this path.** It published an EMPTY
busy set and cleared `locallyBusyWorkers`. That is right at boot — it is what unwedges a device
whose previous process died mid-run — and wrong here: `reconcileBusyWorkers` runs from
`startHeartbeat()`, which `bounceForReset` calls after its pause, potentially while a run is still
in flight. Publishing empty there would tell `firstFreeWorker` that the running worker is free and
hand it a second run: two runs, one set of web views — the exact hazard `workerState` unions
`locallyBusyWorkers` in to avoid. It now publishes what this process is ACTUALLY running, which is
nothing at boot and the live run mid-bounce.

The reconciliation also moved from a stray `Task` into the head of the heartbeat task: unordered
with respect to the beats, cancelled by nothing, and awaitable by no caller — which is also what
made it untestable.

## One press, seven bounces (2026-08-14)

The first real Online-pill reset against the fixed device bounced it **seven times**, in two bursts
eleven seconds apart — the length of the bounce's own pause — and stopped only when the command aged
past the 30-second staleness window.

Both acks (`processed`, then the delete) were `try?` with no else, so a failure was perfectly
silent. And `hard_reset` is uniquely able to feed itself: the handler stops the heartbeat, so
everything after it in `pollCommands` runs under cancellation and may not complete — and the bounce
then restarts the very loop that re-reads the command.

Two changes, and the first is the one that matters:

* **A process-local memory of handled command ids**, recorded BEFORE any remote write. The document's
  own `processed` marker is a remote write that can fail; this is the thing the process actually
  knows, so the cycle breaks without depending on the network.
* **Both ack failures are now logged.** They were invisible, which is why a seven-times reset could
  only be diagnosed by counting log lines from the handler.

⚠ Not a rules problem: `firestore.rules` `isDeviceItself()` explicitly permits the device to stamp
`processed`/`staleSkipped` and to delete its own commands. The cause is on this side.

## The web view had no window, so text entry could not work (2026-08-14)

The first run against the verifying runtime failed on all three platforms, and the new read-back
named the cause in one line:

    refused: the editor refused the text (execCommand=true, paste and beforeinput also left it
    unchanged); document.hasFocus()=false (composer now: "")

**A `WKWebView` in no view hierarchy has an unfocused document, and WebKit's editing commands are
no-ops on one** — `execCommand('insertText', …)` returns **true** and inserts nothing. That
`execCommand=true` is why this survived every check anyone thought to write, including the `ok` flag
the runtime already returned; only reading the text back could expose it.

`PlatformWebViews` now inserts each view into the key window at index 0 — beneath the app's own
opaque root, so no touch reaches it — and `AppWebPages` makes it first responder each time a page is
handed to the run. NOT hidden and NOT `alpha: 0`: WebKit stops rendering a hidden view, and an
unrendered composer has no layout for a caret. Attaching is necessary and not sufficient;
`document.hasFocus()` follows FIRST RESPONDER, which is why both steps exist.

## Three symptoms from one twelve-second run (2026-08-14)

* **A JS name collision, mine.** `S.textOf(id)` already existed — a handle-id reader. The verifying
  helper added the same day was also called `textOf` but takes an ELEMENT, and silently replaced it,
  so every existing caller passed a number into `'value' in el`. `TypeError: el is not an Object`
  killed ChatGPT and Gemini outright and spared Claude only because that path failed earlier.
  Renamed `elementText`, with a type guard.
* **"Phase two is finished" on a run that never reached phase one.** `announce(phase: 2,
  starting: false)` fired unconditionally at the end of the platform loop. Phase 2 begins only when
  a brief exists, so a run where everything failed emitted `phase_start:1` then `phase_complete:2`.
  Now conditional on it having started.
* **The worker pill never pulsed.** It read `snapshot.busyWorkerIDs`, published from the device
  document on the 20-second beat — so a run that lived twelve seconds never appeared at all. Now
  unioned with `LiveRunActivity.runs`, which the run writes in-process the instant it claims a
  worker. Same fix for the People popup's busy list.

⚠ NOT a bug: "all the platforms glowed once". Each platform sets the glow when its phase starts and
clears it on exit; three failing in twelve seconds looked simultaneous.

## The crash, and what attachment was actually costing (2026-08-14)

`EXC_BREAKPOINT` in `WebKit::ProcessThrottler::sendPrepareToSuspendIPC` — a WebKit `RELEASE_ASSERT`,
i.e. WebKit trapping on its own violated invariant. The frames show the last throttler activity
being destroyed inside `IPC::Connection::dispatchMessage`, so a suspension transition was entered
REENTRANTLY during IPC dispatch. Not memory: the 7.0G is virtual, the 512MB "JS JIT" is
JavaScriptCore's fixed address reservation, and frame 5 is a live connection delivering a message
rather than the invalidation path a jetsam'd child produces.

⛔ **It is NOT caused by the window attach**, and the record must say so because the analysis that
looked hardest at it concluded otherwise. The identical trap — same address `0x18e878f80`, same six
frames — was recorded at **23:15:35**, before `attachOffscreen` existed; the 01:00 run independently
proves attachment did not exist then, because it still reported `document.hasFocus()=false`.

What the attach WAS doing is real and worth removing anyway: **attaching every created view bought
exactly zero focus.** UIKit allows one first responder and `focusForAutomation` runs on every page
hand-off, so only the last-driven view ever has focus no matter how many are attached. Attaching all
of them created a permanent-foreground fleet — up to four WebContent processes per worker, each
compositing a full-screen layer (the 452MB of IOSurface in the report), none able to suspend.
Attachment is now exclusive per worker, released on every run exit, and `detachAll` detaches ONE
VIEW PER RUNLOOP TURN — the trap lives in transitions, so asking for several at once is the shape to
avoid.

⚠ Four things deliberately NOT changed, each proven load-bearing: `frame = window.bounds` (at 402pt
the deep-research controls do not exist at all), `alpha = 0.01` (hidden ⇒ no rendering ⇒ no layout ⇒
no caret), `becomeFirstResponder()` (removing it restores the silent no-op), and the
`superview == nil` guard.

## The composer: a caret, not just focus (2026-08-14)

With the view finally focused, `execCommand('insertText')` still returned **false**. It is gated on
`selectionForCommand(...).rootEditableElement()` — with no range inside an editable root it returns
false *before attempting any edit*, and `el.focus()` does not create one on a ProseMirror composer.

* The caret is now placed explicitly, into the **last block child** — the real DOM is
  `<div id="prompt-textarea"><p><br class="ProseMirror-trailingBreak"></p></div>`, and a caret
  collapsed on the ROOT sits between block children, a position ProseMirror normalises away.
* The clear and the fill are now **one transaction**: `insertText` over a non-collapsed range
  replaces it. It was select-all → delete → re-collapse → insert, which is three edits and gives a
  controlled editor two chances to reconcile in between. The old `selectAll` was also
  `document`-scoped, so it could select the whole page.
* A missing caret is reported as its own verdict, `no-caret`, carrying `activeIsEditor`, `inert` and
  the element's rect. "No range in an editable root" and "the editor refused the text" are different
  faults with different fixes and were previously indistinguishable.

⚠ Open hypothesis for the next run: `enableDeepResearch`/`disableDeepResearch` runs immediately
before the fill, and ChatGPT's plus-menu marks the rest of the page `inert` while open — inert
content is neither focusable nor editable. The `inert=` field exists to settle that in one line.

## P1's effort tier: ported ranking, honest verdicts, an unpressable menu (2026-08-14)

P1 must write the brief on ChatGPT's policy effort tier. The ranking rule, the word-boundary match
and the adjacency parser are ported from the backend's `P1_MODEL_POLICY` / `pick_effort_tier`, and
the DOM walk carries both arms of the 2026-08-05 row filter (never an anchor; new since the menu
opened). Three deliberate departures:

* **The selector groups live in Swift, not in `selectors_mobile.json`.** The manifest maps a key to
  a flat list of CSS, and this control needs more than that: an ORDERED set of hook groups whose
  winner is reported, plus an `avoid` word that excludes the Deep-Research pill. That exclusion is
  destructive to get wrong — the DR pill and the model pill are both `__composer-pill` buttons with
  the same tag, class and parent, and pressing the DR pill ADDS A SECOND DEEP RESEARCH rather than
  opening a menu. Flattening that into the manifest would lose the ordering and the exclusion.
  ⚠ Consequence: these selectors carry **no provenance line**, because none has been resolved
  against the live in-app page. They are the desktop capture, ported.

* **The press is a scripted click, and it very likely cannot open this menu.** ChatGPT's composer
  menus are React overlays whose triggers listen on POINTERDOWN; a synthetic `el.click()` dispatches
  a click event and nothing else. The corpus is explicit — the model menu opened 0 of 1 times and
  the tools row 0 of 6. In-app there is no trusted-tap channel: `BrowserWatchInput` enables hit
  testing while the run drives, but that admits a *finger*, not an API. So the step is built to
  REPORT rather than to assume, and the owner's fix is real and one-time: select the tier by hand
  once on the device, after which ChatGPT persists it per account and the read alone answers
  `already` on every later run — opening no menu at all.

* **The verdict is recorded, never enforced.** Five verdicts (`already`, `selected`, `noTarget`,
  `unverified`, `unsure`); only the first two mean the tier is established. P1 proceeds on all five,
  because refusing to run would brick the device for anyone not already on the tier and the read
  cannot always tell "not on it" from "could not look". What the run must never do is the opposite —
  report a brief as written on the tier when it was written on Instant — so the outcome carries the
  verdict in words rather than a Bool.

## Worker rest: the field is the contract, and half of it was missing (2026-08-17)

The web app is the control centre for parking a worker, and it does **not** send this backend a
signal. The Shared-with pill writes `restingWorkerIds` — a whole array of numbers — straight onto
`devices/{id}`, fire-and-forget, with a `console.warn` on failure and no command document anywhere.
The desktop backend pulls that field fresh at every decision point (`_worker_is_resting`, ~3s TTL)
and **fails open**: a read error means awake, so a Firestore blip can never pause a device. This
backend now does the same, and the phone's own pill is an addition on top rather than a second
mechanism — the phone writes the same field the browser writes.

What the desktop does that this backend did not, and now does:

* **It publishes what it is not taking.** `queueOwners` on the device document (`uid` / `runId` /
  `title` truncated at 60 / 1-based `position`, full-array overwrite in FIFO order) drives the amber
  `#N` badge in the owner's Shared-with popup — and the phone's own People popup parses the very
  same field. This backend READ it and never wrote it, so a run deferred by a parked worker was
  handled perfectly and appeared, on every screen, as though nothing had been submitted. The whole
  promise of parking a worker is that the work waits *visibly*.

* **It tells the waiting run where it stands.** `queuePosition`, `queueTotalAhead`,
  `queueAheadFromSelf`, `queueAheadFromOthers` on the research document, with
  `queuedBehind{RunId,Title}` naming the run immediately ahead and **deleted** at the head of the
  queue — left behind, a stale value renders as waiting on a run that finished an hour ago. ⚠ The
  patch carries `deviceId` because `deviceUpdatingFor` judges `request.resource.data.deviceId`, the
  payload rather than the stored document; without it every one of these writes is a 403.

* **It keeps a parked queue alive.** `restDeferredAt` is stamped while a worker rests and refreshed
  after 30 minutes, because the abandonment sweep ages a rest-deferred document from that stamp once
  the workers are awake again. This backend already read the field in its sweep and nothing wrote
  it, so the exemption could only ever fire for a document some *other* backend had stamped: park on
  Friday, wake on Sunday, and Monday's sweep deletes the run the owner came back for.

**Deliberately NOT ported.** The desktop's #904 status self-heal — re-asserting `status="queued"` on
a research document that drifted to `ongoing` with no claim — is a repair for a frontend
mis-prediction at submit time, and it only bites past the 12-hour horizon. And no queue **ETA**: the
desktop estimates one from the head run's phase and the moment that phase started, neither of which
this backend publishes, and a number derived from nothing is worse than the frontend's own "no
estimate yet", which is exactly what an absent field already means.
