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
