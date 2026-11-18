# EmulatorRecipe — finish the iOS emulator backend so it runs the real Super Research pipeline

**Version 5.1 · authoritative · rewritten 2026-07-30, amended 2026-08-08.** Supersedes v1–v4 entirely (v4 preserved as
`EmulatorRecipe.v4-superseded.md` for its hazard analysis and history). Everything the earlier versions
planned that is now *done* is in §1 so it is not rebuilt; everything they got *wrong* is corrected in §9.

> **This document is a one-shot ticket.** A fresh Claude with no memory of prior sessions should be able
> to execute it end to end. If you need context that is not here, that is a defect in this file — fix the
> file as you go.

> ### What changed in 5.1 (2026-08-08) — read this before the rest
>
> The **substrate and the app** moved on since 5.0 was written; the **pipeline** did not. Seven
> corrections, each applied in place below:
>
> 1. **A8 is amended, not absolute** — the owner authorised frontend work and it is pushed. See §0's
>    A8 block and `dg-research-ios/docs/DEVIATIONS.md` (*"A8 lifted for the app wave"*).
> 2. **§11's device-op bugs are FIXED** (§12 item 15 is done). Do not re-derive them.
> 3. **The Simulator UDID in Appendix B and §3.2 no longer exists.** Resolve by name — `bin/sim.sh`.
> 4. **Gate zero has a tool now**: `bin/gate_zero_probe.py`, which refuses to measure an unfinished
>    run. It has never been run against a completed page — the gate itself is still OPEN.
> 5. **§3.2's prerequisite is satisfied** — the owner has signed into the platforms inside the app.
> 6. ⭐ **NEW §8b — the run's two ends.** Every earlier draft planned the middle of a run and neither
>    end: nothing claimed a run off the web app's queue, and nothing handed off to the cloud for P4/P5.
>    Two new items (20, 21) and a new DoD clause 6b. **21 is on the critical path.**
> 7. ⭐ **NEW Appendix A2 — the backend as reference architecture.** `research.py` is 62,869 lines
>    in one file and this recipe cites it forty times without ever mapping it. A2 is that map,
>    symbol by symbol, plus the one function you must never call.
>
> Everything else — §2's reframe, §3's hypotheses, §12's list, §13's bar, §14's rules — is unchanged
> and was re-verified against the code on 2026-08-08.

---

## 0. How to use this document

1. **Read §1, §2 and §3 before touching code.** §2 corrects a structural misunderstanding that cost a
   full session; §3 is a hard gate that decides the design of everything downstream.
2. **Do §3 (the spike) first, and record its result** in `dg-research-ios/docs/DEVIATIONS.md` whichever
   way it goes. A negative result is a finding, not a failure.
3. **Work §12's list in order.** The critical path is marked; off-path items are for while a long
   real-platform run is in flight.
4. **Every claim carries a `file:line` anchor,** read first-hand on 2026-07-30. Lines drift — locate by
   symbol, and if an anchor is stale, fix it here.
5. **Where this says UNRESOLVED (§15), do not invent an answer.** Ask.

### 0.1 ⛔ WHAT THIS WORK CAN DESTROY — read before your first real run

This pipeline drives the **owner's real, paid accounts** and writes to their **production** Firebase
project. None of the following is recoverable by re-running.

**1. Deep Research quota is a hard monthly cap on a real paid account.** Every extractor iteration against
a live run burns one, times three platforms, and DoD 5 requires **two** full passes. Iterating §6 against
live DR runs can exhaust a month in days — and then the goal is blocked on a calendar, not on code.

> **Iterate against a CAPTURED DOM, not a live run.** Drive **one** real DR run to completion, dump the
> full page HTML to `artifacts/`, and develop the extractor, the guards and the floors against that
> fixture. Spend a live run only to *confirm*. `bin/capture_selectors.py` already writes candidate
> surveys; extend it to dump the completed-report DOM once and reuse it forever.

**2. Bot-flag risk on accounts that cannot be replaced.** The BE deliberately slowed its P2 completion
poll **30 s → 120 s** because *"rapid tab-switching at 30s intervals can look bot-like to
ChatGPT/Gemini/Claude"* (`BE research.py:538-543`). This recipe ports the BE's selectors and prompts —
**port its pacing too.** Do not add a tight poll loop against a real platform, and prefer one long wait
over many short probes.

**3. NotebookLM leaves permanent artifacts.** Each P3 run creates a **new notebook in the owner's real
Google account** (`BE research.py:38633`) and audio overviews have daily caps. There is **no cleanup step
anywhere in the BE or this plan**. Expect to accumulate notebooks; if that matters, add a cleanup item
before item 16, not after.

**4. Production Firestore.** Item 6's writer targets project `super-research-492814` under the owner's
real uid. **Stay on the Firestore emulator until the writer passes the rules gate and the golden diff**,
then use a single designated test `researches/{rid}`. Precedent: seven junk `devices/*` docs accumulated in
one evening (§15.2) — the existing warning in Appendix D covers device docs only, **not**
`researches/*/documents`.

**5. A 90-minute audio generation is not a retry loop.** `PHASE_3_AUDIO_MAX_MIN=90`
(`BE research.py:557`). Do not re-trigger it to test a downstream step; capture the audio once and develop
against the file.

---

**Repo roots.** `iOS` = `~/Downloads/SuperResearch/dg-research-ios` · `BE` =
`~/Downloads/SuperResearch/dg-research-backend` · `FE` = `~/Downloads/SuperResearch/dg-research`.

**⛔ A8 — AMENDED 2026-08-08, and the amendment is narrow.** The original rule was *`BE` and `FE` are
read-only dev dependencies, not one line modified*. The owner has since lifted it for frontend work
that the iOS side genuinely needs (*"if fe be needed any changes give our ios stuff, do"*), and two FE
commits are pushed. So the rule now reads:

* **`BE` (`dg-research-backend`) is still read-only.** Read it freely — that is how the deep-research
  toggle predicate, the modal sweep and the P1 prompt were all recovered — but **vendor rather than
  edit**. If you want to change it: stop, write down what you needed and why, and ask.
* **`FE` (`dg-research`) is writable WITH the owner's say-so, per change.** Not a standing licence.
  The iOS device must still speak the *existing* Firestore contract wherever it can, because every FE
  change is one more thing to keep in sync; change the FE only when the contract itself is the defect.

⚠ **`purity.assert_pristine()` is therefore RED, on purpose, and `bin/all_gates.sh` fails at its first
gate because of it.** Both guarded HEADs moved. **Do not regenerate `fixtures/a8_baseline.json` to make
it green** while the wave is open — that is the one response that destroys the guard's value, because
the next *unauthorised* change would then look identical to this authorised one. The record of what
moved and why is in `docs/DEVIATIONS.md`; regenerate only when the owner says the wave is closed, and
say so in that file when you do.

⚠ **The guard's own failure text tells you to do the wrong thing.** It prints, once per file, that
an uncommitted backend change *"was DISCARDED … This wave exists nowhere else; recover it before
doing anything else."* **That message is stale.** The wave was measured against `origin/master`,
found to be a superseded copy (upstream carried a strictly better version of the one block that
differed), and **stashed, not lost** — `stash@{0}`, plus a file-level backup. `dg-research-backend`
is clean and level with its remote. **Never `git stash pop` in `BE` or `FE` to quiet the guard.** The
full measurement is in `docs/DEVIATIONS.md` under *"both guarded repos are now SYNCED"*.

**What a healthy suite looks like during this wave:** `bin/all_gates.sh` collects failures rather
than aborting, so every gate still runs and you still see its result — but the run exits 1 because
gate 1 is red. **A8 is the only acceptable failure; every other gate must pass.** DoD 7 is therefore
unsatisfiable until the owner closes the wave, and that is expected, not a defect to engineer around.

---

## 1. Where we are

### 1.1 DONE — do not rebuild any of this

The substrate is finished and proven. This is real and non-trivial; discounting it wastes weeks.

| Capability | Evidence |
|---|---|
| Real iOS Simulator, booted, windowless-capable | `bin/b0a_gate.py`, 4/4 |
| **Trusted HID taps** via AXe into real MobileSafari *and* the app's `WKWebView` | measured: `isTrusted === true` for AXe, `false` for scripted |
| **Measured tap calibration** (CSS px ↔ screen px) with the one-retry-for-URL-bar-collapse policy | `emubackend/substrate/geometry.py`; `backend.py:342-395` (`_calibration`, retry ~:376-386), `tap` at `:396-432` |
| **IWDP DOM channel**, incl. per-boot socket rediscovery and `Target.sendMessageToTarget` envelopes | `emubackend/substrate/iwdp.py`; Appendix B |
| **Persistent logins surviving a Simulator reboot** | b0a case 4 |
| **An installable unsigned app**, no dev account needed | `bash bin/build_app.sh <UDID>` |
| **Real ChatGPT driven green twice in-app**: composer readiness, DR toggle (idempotent), `execCommand` fill reaching the editor's *model*, send with a verified predicate | `artifacts/c1/verdict-chatgpt.json` |
| **Contract writes verified 14/14 against the real `firestore.rules`** — which surfaced the `deviceId` custom-claim dependency | `bin/c0fe_gate.sh` |
| **Firebase iOS app registered**; pairing, QR, paste, a 5-stage pair flow with a Cancel exit | `ios/App/PairingFlow.swift` |
| ~583 Python + **199** Swift tests, mutation-tested throughout | `bin/mutate.py` · counts re-measured 2026-08-08 |

**Six real-platform defects were found and fixed on 2026-07-30**, every one invisible against a mock
because a mock is synchronous and stable. Keep them; they are load-bearing:

1. `opener` was parsed onto `SelectorEntry` and then **dropped** by `_tap` — the control sits in a closed
   menu. Now: tap the opener, then **poll** for the target (ChatGPT's plus menu paints 3 items, then 19).
2. **Dismissal asked the wrong object.** "Is the target still findable" as a proxy for "is the menu open"
   is permanently true on ChatGPT, because activating Deep research leaves a **"Deep research" pill** in
   the composer. Now `_POPUP_STATE_JS` asks the *opener* (`aria-expanded` / `data-state` /
   `aria-controls`), negative-first.
3. **ChatGPT replaces its own document** ~1 s after first paint (`readyState` goes `complete` →
   `interactive` on the *same URL*), taking `window.__sr` with it. Now `ensure_runtime_stable` requires
   the sentinel to **survive** a settle window — presence alone passes while the doomed document is still
   current, which is why re-inject-then-check does not work.
4. **Every wrapped intent was verified with no render tick.** `guarded_intent` now polls its
   `outcome_predicate` over an `acceptance_window` (default 5 s, returns early on pass). Before this the
   DR toggle genuinely turned on and `send` was genuinely accepted, and both reported
   `predicate_passed=False` — a false negative on a **healthy** page, which with acting enabled escalates
   an agent onto the one page that needed no help.
5. **Content stability accepted a page that had not started answering** (`Pro thinking`, 27 chars, stable
   6 s, with `Stop answering` on screen). Now the platform's own in-flight control **vetoes** completion —
   ported from the BE's `is_agent_generating`, including its Gemini breadth caveat (#897b).
6. **The composer went stale between resolve and fill.** `await_composer_ready` now requires a settle
   window, and `type_brief` re-queries up to a bounded number of attempts — which is what the stale
   error's own message prescribes.

### 1.2 ⭐ THE APP THE PIPELINE MUST FIT — added 2026-08-08, after the app wave

The pipeline is not being built beside an app; it is being built **into** one that now exists and
that the owner uses. Five properties of it constrain the work, and each was paid for:

* **A worker IS a browser profile.** `WorkerRegistry` + `WorkerDataStores` give each worker its own
  `WKWebsiteDataStore`, so two runs can drive the same platform without stealing each other's page.
  `workerCount` is read from the registry, never the literal `1` it used to be. A run is assigned to
  a **specific** worker by ordinal, and `busyWorkerIds` names those ordinals.
* ⛔ **Worker 1 keeps `WKWebsiteDataStore.default()` and must keep it forever.** Every login the
  owner made by hand lives in the default store. Giving worker 1 an identified store like the others
  would be tidier and would sign the device out of everything on the first launch after, with no
  error and nothing in any log — the cookies are still on disk, WebKit is just looking elsewhere.
  Same failure class as `build_app.sh`'s removed `simctl uninstall`.
* **Logins are INTERSECTED across workers, never unioned** (`WorkerProfiles.deviceLogins`). A P2
  handed to worker 2 fails outright if only worker 1 holds the ChatGPT cookie, and a union would
  report the device ready for work it cannot do — surfacing three phases later as a login wall. A
  platform nobody has measured is **omitted**, which is not the same as `false`.
* **There are more jars than the three in Appendix B.** Simulator Safari, the app, and the C1
  harness are three *families*; the app now holds one store per worker inside its own. "The platform
  is signed in" is meaningless without naming both the surface and the worker.
* **Progress must reach the phone's own UI, not only Firestore.** The app renders live phase state,
  and Browser Watch is how the owner watches a run happen. A run that only shows up in Firestore is
  a regression against what shipped.

### 1.2b What needs the owner's credentials, and WHEN

So that nothing blocks earlier than it must:

| Needs the owner | Not needed for |
|---|---|
| **A live Deep Research run** (gate zero, and every extractor confirmation) | — ask for this FIRST; it gates §3 |
| **A real pairing** — the first production write, and §13's in-app run | Gate zero; `bin/e2e_simulator.py` (stubbed HTTP transport, synthetic `uid-e2e`/`dev-e2e`); `bin/c1_contract_gate.sh` (local Firestore + auth emulators, synthetic `owner-uid-c1`) |
| **A NotebookLM notebook** (item 16), **deploying `firestore.rules`**, **an Apple Developer account** (C1 on a real device) | everything before them |

⚠ **Platform sign-in is already DONE** on both Simulator Safari and in-app. Do not ask for it again;
do ask before doing anything that could cost it (`--clean`, `simctl erase`, a shutdown within ~10 s
of a sign-in).

### 1.3 NOT DONE — this is the whole of §12

The **product flow**. In one sentence: *the substrate can drive a platform, and nothing in this repo can
produce, store, or deliver a research document.*

---

## 2. ⛔ THE REFRAME — read this or everything downstream is mis-aimed

**The iOS `P0–P3` is not a subset of the backend's `P0–P3`. It is a different pipeline wearing the same
phase numbers.** A full session on 2026-07-30 was spent iterating a gate to green against a model that
does not implement the product.

| Phase | Backend actually does | iOS currently does | iOS anchor |
|---|---|---|---|
| **P0** | Preflight: launch the persistent profile, probe Anthropic/CUA availability, optionally CUA-verify each platform's login **and Pro tier**, check API-key env, close probe tabs (`BE research.py:41918-42478`). `skipInitVerify` defaults **TRUE** | Resolve one `logged_in_marker` | `emubackend/phases.py:922-936` |
| **P1** | Produce a **brief document** on ChatGPT with Deep Research **OFF** and the **Pro** model, then **extract it as markdown**. The brief is P1's *product* and P2's *input* | Type the bare topic, tap send. Captures nothing — the docstring says "capture the brief"; the body has no read and no return value | `phases.py:938-949` |
| **P2** | **Three** agents (chatgpt, claude, gemini) with Deep Research **ON**, each fed **the brief**, each producing a **full markdown report** via a per-platform 3-tier extractor ladder | **One** platform, re-types `deps.topic`, then reads `innerText` of `sources` nodes | `phases.py:951-968`, `:964` |
| **P3** | **NotebookLM**: new notebook → upload the **3 reports** → **Audio Overview** → download `.m4a` → transcode → Storage → `links.audio_file` | Harvest citation **label text** (never `href`, never the report) | `phases.py:970-989`, `:883-895` |

**The product of a real run is a markdown document, and this repo has no representation of one.**

```
rg -n 'innerHTML|outerHTML|html_to_markdown' -g '*.py' -g '*.swift' \
  emubackend ios/Sources ios/App bin
→ 1 hit           (re-measured 2026-08-08)
   bin/gate_zero_probe.py:50   ← gate zero's OWN probe JS, not a capability
```

⚠ **Read that number precisely.** It was 0 on 2026-07-30 and the single hit since is the probe
tool's embedded JavaScript — the substrate still has **no `innerHTML` primitive**. `WebPage` exposes
only `evaluateJSON / querySelector / querySelectorAll / attribute / innerText / click / insertText`
(`InAppPipeline.swift:19-31`), and nothing anywhere converts HTML to markdown. Item 2 is unstarted.

The golden fixture the contract gate diffs against is **11 lines of pure progress telemetry** with no
content field anywhere (`fixtures/golden/p0_p3_happy_path.jsonl`).

⚠ **How to read the existing green artifacts.** `artifacts/e2e/verdict_chatgpt.json` and
`artifacts/c1/verdict-chatgpt.json` are **substrate** evidence. They prove taps land, sessions persist,
modes toggle, and progress reaches Firestore under the real rules. **They prove nothing about a run
producing output.** Never cite them as pipeline parity.

---

## 3. ✅ GATE ZERO — RESOLVED 2026-08-08 as **H7**. Read 3.0 first; 3.1–3.3 are the record of how.

### 3.0 ⭐ THE ANSWER — measured on a COMPLETED in-app Deep Research run

**The report is not in the DOM at all, and it does not need to be: ChatGPT hands it over as
markdown over a same-origin fetch.**

| Question | Measured answer |
|---|---|
| Is the report in the main document? | **No.** `document.body.innerText` is **499 chars** of chrome and the user's own prompt on a finished run. `[data-turn=assistant]` is the string `"ChatGPT said:"` — 15 chars |
| Is it in a frame? | **Yes** — `connector-openai-deep-research.web-sandbox.oaiusercontent.com`, 402×484, `contentDocument` **null**. So H4 is *true of the DOM* |
| Shadow DOM (H5)? | **Dead** — zero shadow roots |
| Are frames evaluable over IWDP? | ⛔ **No.** Three `frame` targets enumerate; `Runtime.evaluate` in a `Target.sendMessageToTarget` envelope returns nothing for all three, while the same envelope works on the page target |
| ⭐ H7 — the network | **`GET /api/auth/session` → `accessToken`, then `GET /backend-api/conversation/{id}` with `Authorization: Bearer` → HTTP 200, 579,966 chars.** Cookies alone give 404 *"Log in to view this conversation."* |
| Where in that JSON? | `mapping[<tool node>].message.metadata.chatgpt_sdk.widget_state` (543,733 chars) → **`.report_message.content.parts[0]` = 65,690 chars of MARKDOWN**, 30 headings |
| Completion signal | `widget_state.status == "completed"`, plus `research_started_at` / `research_stopped_at` |

**Consequences — the plan gets simpler:**

* ⭐ **No `innerHTML` primitive, no `html_to_markdown`, no frame traversal, no `WKFrameInfo`, no
  download tier** for ChatGPT Deep Research. It is a same-origin `fetch`, identical on both surfaces.
* ⭐ **§3.3's "H4 reachable in-app only" branch does not arise**, so **§15.1's owner decision is
  moot** — the Safari path is not forced out by extraction.
* ⭐ **The DOM offers no completion signal for a DR run** — `stop-button` never appears, and a
  finished page is textually indistinguishable from an unstarted one in the main document. Use
  `widget_state.status`. Anything keyed on the DOM here is a guard that cannot fire.
* ⚠ **This is ONE platform's answer.** Claude and Gemini are unmeasured; the DOM ladder remains the
  assumption for them until someone repeats this.
* ⚠ Fetch the token per extraction, as the page's own client does. Do not cache it, do not poll it.

**Fixtures** (reaching this page cost one unit of the monthly cap — do not spend another):
`dg-research-ios/artifacts/gate_zero/chatgpt_dr_report.md` · `…/chatgpt_dr_widget_state.json` ·
`…/chatgpt_dr_completed.html`. Full verbatim record in `dg-research-ios/docs/DEVIATIONS.md`.

**Tooling built for this and kept:** `bin/gate_zero_run.py` drives one DR run in-app end to end
(UA-selected surface, measured tap calibration, HID-opened menu, verified send). `bin/gate_zero_probe.py`
gained UA surface selection, an HTML dump, a positive completion verdict and a fixed frame ranking —
**four defects in the gate's own tooling, each found by taking the measurement rather than by reading
the code.** They are catalogued in `DEVIATIONS.md`; the shortest one is that PROBE 4 read a
`<script>` body as the page's longest text — 434,403 chars against 881 rendered.

### 3.1 What was known, and what was only suspected (the record)

**Known (measured 2026-07-30).** Against real ChatGPT with Deep Research on, `await_response` read the
`response_container` and got **15 chars**, then **204 chars**, then sat on **`Pro thinking`** (27 chars)
while `Stop answering` was on screen. The harvest then found 0 sources and reported read drift. So
**something is wrong with what we read, or when we read it.**

⚠ **Suspected, NOT established: that the report lives in a cross-origin iframe.** An earlier draft of this
recipe asserted that as fact. It is one hypothesis among several, and the evidence does not single it out —
`iwdp.py:182-185` notes a `frame` target exists and does not accept `Runtime`, but WebKit exposes frame
targets on essentially every page, so *existence is not evidence the report is in one*.

**Every hypothesis consistent with the same three reads:**

| # | Hypothesis | How to distinguish | If true, the fix is |
|---|---|---|---|
| H1 | **Premature read.** A Pro DR run takes 10–30 min; `build_phase_bodies`' default `response_timeout` is **240 s** (`phases.py`, `REAL_RESPONSE_TIMEOUT` in `bin/e2e_simulator.py`). `Pro thinking` + `Stop answering` is exactly what mid-generation looks like | Let one run go to real completion by hand with a 30 min budget, then read | **Raise the timeout.** No architecture change. ⭐ Arguably the most likely |
| H2 | **Wrong node in the right document.** `els[last]` / our `resolve()` picks a newer or sibling turn | Census every `[data-turn]` with lengths after completion | A `report` key + the BE's wrong-document guards (§6) |
| H3 | **Same-origin sub-frame** | `document.querySelectorAll('iframe').length`, then try `contentDocument` | Plain JS — traverse `contentDocument`. Needs **neither** IWDP frame targets nor `WKFrameInfo` |
| H4 | **Cross-origin iframe** | `iframe` exists, `contentDocument` throws / is null, `src` origin ≠ page origin | Frame targets (IWDP) or `WKFrameInfo` (in-app) — the expensive branch |
| H5 | **Shadow DOM / custom elements.** Nothing in this repo pierces `shadowRoot`; Gemini is custom elements (`toolbox-drawer-item`, `message-content`) | Census elements with a non-null `shadowRoot` | A `shadowRoot`-piercing `querySelector`. JS-only |
| H6 | **Stale handle from the ~1 s document self-replacement** (§1.1 defect 3) | Re-resolve immediately before reading; compare | Already have `ensure_runtime_stable` — just use it at the read site |
| H7 | **The report is fetched over the network**, not rendered in the turn | Watch `Network` domain / look for a conversation-JSON or export endpoint | A network tier — read the response body instead of the DOM |

**Do not skip to H4.** It is the only hypothesis that costs architecture, and it is not the most likely.

### 3.2 The experiment — run this, in this order

✅ **Prerequisite SATISFIED 2026-08-08.** This used to read *"ask the owner to sign into ChatGPT inside
the app first, or step 3 cannot run at all."* The owner has since signed in **in-app** on all four
platforms, and the app's jar survives a rebuild (`build_app.sh` no longer uninstalls — see §14). Both
surfaces are usable. ⚠ Still name the surface you measured on; there are three jars.

⭐ **Use `bin/gate_zero_probe.py` — do not hand-run the JS below.** It carries these four probes
verbatim, prints their output **and** the pre-declared verdict, and — the part that matters — **refuses
to measure a page whose stop control is still on screen**. Confirming completion by elapsed time is
exactly how the original measurement went wrong. The raw probes are kept here so the tool can be
audited against its own spec.

```bash
# 0. Reach a COMPLETED Deep Research run. Do NOT rely on the pipeline's 240s default.
#    Drive it by hand, then leave the page open and probe it:
UDID=$(bash bin/sim.sh --udid)          # ⚠ resolve by NAME — see Appendix B
open -a Simulator                     # then, in Safari: chatgpt.com -> DR on -> send a real brief
#    Expect 10-30 minutes. The tool checks for the stop control; it will refuse an unfinished page.

.venv/bin/python bin/gate_zero_probe.py --udid "$UDID" --url chatgpt.com
```

The four probes it runs, **on that completed page**, recording every result:

```js
// PROBE 1 — turn census. Settles H1 and H2 outright.
[...document.querySelectorAll('[data-turn]')].map(t => ({
  turn: t.getAttribute('data-turn'), chars: (t.innerText||'').length,
  html: (t.innerHTML||'').length, head: (t.innerText||'').trim().slice(0,80) }))

// PROBE 2 — iframe census + same-origin test. Separates H3 from H4.
[...document.querySelectorAll('iframe')].map(f => { let access;
  try { access = f.contentDocument ? 'SAME-ORIGIN: ' + f.contentDocument.body.innerText.length + ' chars'
                                   : 'null contentDocument'; }
  catch (e) { access = 'THREW: ' + e.name; }
  return { src: f.src || '(none)', origin: (()=>{try{return new URL(f.src).origin}catch{return '?'}})(),
           pageOrigin: location.origin, w: f.clientWidth, h: f.clientHeight, access }; })

// PROBE 3 — shadow-root census. Settles H5.
(() => { const out = [];
  const walk = (root, depth) => { for (const el of root.querySelectorAll('*')) {
      if (el.shadowRoot) { out.push({ tag: el.tagName, depth,
          chars: (el.shadowRoot.textContent||'').length });
        if (depth < 4) walk(el.shadowRoot, depth+1); } } };
  walk(document, 0); return { count: out.length, biggest: out.sort((a,b)=>b.chars-a.chars).slice(0,8) }; })()

// PROBE 4 — where is the longest text on the page, wherever it lives?
(() => { let best = {chars: 0};
  for (const el of document.querySelectorAll('*')) { const n = (el.innerText||'').length;
    if (n > best.chars) best = { chars: n, tag: el.tagName, id: el.id,
      cls: (el.className||'').toString().slice(0,60),
      attrs: [...el.attributes].map(a=>a.name).join(','),
      inFrame: false }; }
  return best; })()
```

**Then, and only if PROBE 2 reports a cross-origin frame (H4):**

1. **IWDP half.** Enumerate the raw `Target.targetCreated` stream; for each `frame` target, attempt
   `Runtime.evaluate` inside a `Target.sendMessageToTarget` envelope. Establish whether the refusal is
   IWDP's, WebKit's, or an assumption in our own wrapper (`iwdp.py:182-185`).
2. **WKWebView half.** iOS exposes `evaluateJavaScript(_:in:contentWorld:)` taking a `WKFrameInfo`, with
   frames reachable from a navigation delegate. **This API exists on the platform and is absent from this
   codebase's abstraction** — `WebPage` exposes only
   `evaluateJSON / querySelector / querySelectorAll / attribute / innerText / click / insertText`
   (`InAppPipeline.swift:19-31`). Determine whether the DR frame is enumerable and evaluable there.

**Pass observable — define it before you start, so the answer is not a judgement call:** the report node
is found when a single element's markdown-converted text exceeds the BE's own tier floor of **2000 chars**
(`BE research.py:30095`) and does **not** trip `_is_sources_not_document` (`:20567`) or
`_looks_like_nav_sidebar` (`:20533`).

**Record all four probe outputs verbatim in `docs/DEVIATIONS.md`** — the measurement, not just the
conclusion. A negative result is a finding.

⭐ **Before you navigate away from that page, dump its full HTML to `artifacts/`.** Gate zero's
completed run and §0.1's captured-DOM fixture are **the same page**, and reaching it costs one unit
of the owner's monthly Deep Research cap. Probing it and then leaving means paying that cost twice —
once for the gate, once for the extractor fixture that items 2, 5 and 6 are all developed against.
`bin/capture_selectors.py` already writes candidate surveys; the dump belongs beside them.

### 3.3 Kill criteria — decide now, not in the moment

| Outcome | Consequence |
|---|---|
| **H1 / H2 / H6 — no frame involved** | ⭐ **Premise refuted, and the plan gets SIMPLER.** The fix is the timeout plus a `report` key and the wrong-document guards. §12 items 2, 5, 6 proceed unchanged; drop all frame work. **Expect this outcome and be pleased by it** |
| **H3 — same-origin sub-frame** | Traverse `contentDocument` in `resolve()`. A JS change on both halves, no new transport. Add a `frame` hint to the manifest entry |
| **H5 — shadow DOM** | Add a `shadowRoot`-piercing walk to `resolve()` and to the Swift `querySelector`. JS-only, but it touches every selector path — test it against all four platforms |
| **H4, reachable on both halves** | Add frame traversal to `resolve()` and the Swift `WebPage`; carry a `frame` hint on the manifest entry |
| **H4, reachable in-app ONLY** | **P2 extraction moves permanently to the in-app surface.** Safari keeps P0/P1 and the fast loop. Say so here and in `README.md` — never ship a Safari path that silently reads a shell. ⚠ Then §15.1 needs an owner decision, and §6's ladder needs a **Swift** implementation, which is currently unscoped |
| **H4, reachable on NEITHER** | DOM extraction is dead for ChatGPT DR. The **download tier becomes mandatory** rather than tier-1-of-3 (§6), or H7's network tier does. This branch most changes the plan — which is exactly why the spike comes first |
| **H7 — network** | Read the response body over the `Network` domain / a fetch shim. A different extractor entirely; re-scope §6 before building it |

⚠ **Do not start §12 item 5 before this resolves.** If the report is not where §6 assumes, the extractor's
entire input changes.

---

## 4. Owner decisions — LOCKED 2026-07-30. Implement; do not re-litigate.

| # | Decision | What the owner accepted |
|---|---|---|
| **B1** | **P2 runs SEQUENTIALLY**, one platform at a time | MobileSafari has one foreground tab, HID taps reach only it, and `open_isolated_tab`/`switch_to` raise `BackendUnsupported` **by design** (`substrate/backend.py:206-216`). Wall-clock becomes the **sum** of three DR runs, not the slowest. A documented deviation from the BE's concurrency |
| **B2** | **Full extraction ladder**, including the download tier | Closest to BE parity. ⚠ The download tier is **in-app only** — Safari gives no download-completion signal over IWDP (`substrate/backend.py:482-487`). In Safari it must be **skipped with a stated reason**, never silently |
| **B3** | **HID-driven native file picker** for NotebookLM sources | True file upload, as the BE does. ⚠ Owner explicitly accepted this is **the most fragile step in the stack**: AXe taps land on a **system sheet** outside the WebView. `substrate/backend.py:473-480` declares host→MobileSafari upload has no automation path, so this is in-app + picker-driving, not a `setFileInputFiles` port |
| **B4** | **Vendor an mp3 encoder (LAME)** for true `.mp3` | Byte-parity with the BE's `-c:a libmp3lame -b:a 160k` (`BE research.py:678`). ⚠ LAME is **LGPL-2.1** — fine for an internal unsigned build; a licensing question if this ever ships via the App Store. **Flagged, not decided (§15.3)** |
| **B5** | **Safari now, in-app before "done"** | Build and iterate in Safari (logins are live there). Then the owner signs into all four platforms **inside the app once**, and the same pipeline is proven in-app. The app is the production surface; a Safari-only pass does not prove what ships. ✅ **RE-AMENDED 2026-08-08: the sign-in is DONE, on both surfaces. Do not ask for it again** — see §1.2b. (This cell used to say the app's jar was deep-cleaned and to request a one-time in-app ChatGPT sign-in "at the start"; it also pointed at a numbered "§3.2 step 3" that 5.1 replaced with `bin/gate_zero_probe.py`.) What §3 still needs from the owner is a **completed Deep Research run**, which is quota, not credentials |

---

## 5. THE PHASE CONTRACT — implement exactly this

Every value below was read from the backend.

### 5.1 P0 — preflight

* Resolve `logged_in_marker` for **every platform this run will use** — with B1 that is chatgpt, claude,
  gemini, plus notebooklm for P3.
* **Pro-tier verification is out of scope**, matching the BE's own default: `skipInitVerify` defaults
  **TRUE** (`BE research.py:41918-42478`). Record as a deliberate deviation.
* Raise on a missing marker. **Never skip** — a silent skip reports success on a page nothing touched.

### 5.1b ⛔ CHATGPT IS USED TWICE, IN TWO DIFFERENT MODES — never conflate them

**Owner correction, 2026-08-08.** `chatgpt` appears in **both** P1 and P2, and they are not the same
job on the same page:

| | Mode | Product | Waits |
|---|---|---|---|
| **P1** | Deep Research **OFF** | the **brief** — P2's input | seconds to a couple of minutes |
| **P2** | Deep Research **ON** | a **full markdown report**, one of three | **10–30 minutes** |

Three consequences, each of which has already caused or nearly caused a defect:

1. **The DR toggle must be driven in BOTH directions.** P1 needs it **off** and P2 needs it **on**,
   in the same session, on the same account. `disable_deep_research()` is not an optional tidy-up —
   run 2 begins with DR already on from run 1's P2, which is exactly the idempotence bug §13.5 makes
   you run twice to catch. A toggle only ever driven on will silently give you a P1 "brief" that is
   a 30-minute deep research report.
2. **Completion detection differs by an order of magnitude.** The 240 s default that produced gate
   zero's bad read is *generous* for P1 and *absurd* for P2. One timeout for "chatgpt" is wrong for
   one of them whichever value you pick — key the wait on the **phase**, not the platform.
3. **Gate zero is a P2-CHATGPT question only.** The 15→204→27-char read happened with DR **on**.
   Nothing about it implicates P1's ChatGPT, and nothing about it implicates Claude or Gemini, whose
   own gaps are missing *selectors* (item 12), not an unresolved DOM location.

⚠ The selector manifest keys by **platform**, not by (platform, mode). ChatGPT is 7/7 today, and
that count was taken against **one** of these two modes. Appendix C's own warning applies with full
force: *selectors are a function of STATE, not platform* — idle, post-web-search and
post-deep-research are three different DOMs. Verify the P1 controls by driving them with DR **off**
before assuming 7/7 covers both.

### 5.2 P1 — the brief. Deep Research must be **OFF**.

⚠ **Two hard requirements the current code violates.**

**(a) The prompt is a wrapper, not the topic.** Verbatim, `BE research.py:31385-31390`:

```
Please create a detailed research report brief for a deep research LLM agent that covers this
topic: {topic}. Be as thorough as you can. Simply output the research brief, no preamble or
post-amble. I just need something I can copy and paste into a research agent LLM.
```

and when a feedback string is present, appended (`BE research.py:31392`):

```
\n\nUSER FEEDBACK (incorporate this): {feedback}
```

iOS currently types the bare `deps.topic` — `phases.py:947` (P1) and `:966` (P2) — a different request
entirely, which yields a chat answer rather than a brief.

**(b) Deep Research must be OFF and the Pro model selected.** `BE prompts.py:124`: *"Phase 1 writes a
quick research brief on the Pro model — it must **NOT** run in Deep Research mode."* The BE has a
dedicated hotspot: `hotspot_id="1a-disable-dr", phase=1, platform="chatgpt"` (`BE research.py:11394`).

⚠ **This is a live bug, not merely a gap.** DR state **persists across runs** — that is the entire
premise of persistent login — so run 2's P1 would execute in Deep Research mode.

⛔ **AND DISABLING IS NOT "TAP THE TOGGLE AGAIN". Read the BE's own words before implementing this.**
`BE research.py:11396-11399` (the `1a-disable-dr` hotspot's own `context_hint`):

> *"the composer has Deep Research active (placeholder 'Get a detailed report' / a 'Deep research' pill)
> — **REMOVE it by pressing Backspace in the empty message box; do NOT click the 'Deep research' tool
> (clicking adds a second one)**. Don't enable any other tool"*

So `disable_deep_research()` is **Backspace into an empty composer**, then verify the pill is gone with
`_toggle_off_predicate` — *not* a second tap on the menu item. A mirror-of-enable implementation would
**add a second tool** and leave P1 in a worse state than it started. (An earlier draft of this recipe got
this exactly wrong; it is corrected here because §14's rule — believe the BE's comments, they record
failures already paid for — applies to this recipe too.)

The verification machinery already exists (`_toggle_off_predicate`, `confirmed_off` in `phases.py`); only
the *action* is new, and it must be idempotent: check the predicate **before** acting, so an already-off
composer is left alone.

* **P1 must EXTRACT the brief as markdown** and return it, using the same machinery as P2 (§6).
* **Persist the brief** so P2 can consume it and a resumed run does not regenerate it.

⚠ **Two BE behaviours DELIBERATELY DESCOPED here — say so rather than silently dropping them:**

* **Pro/Thinking model selection.** The BE selects them explicitly (`BE research.py:16386-16390`). No
  selector for either has been captured on mobile web, and no work item covers it. Consequence: P1 runs
  on whatever model the account defaults to. **If brief quality is poor, this is the first thing to
  suspect.**
* **User PDF attachment.** The BE attaches user source documents to P1 and augments the brief from them
  (`_augment_brief_with_sources`, `BE research.py:36105`). This needs file upload, which is B3's fragile
  path — so **iOS P1 is topic-only**. Any run whose research depends on user-supplied sources must go to
  the desktop backend.

### 5.3 P2 — three deep-research runs, sequentially. Deep Research must be **ON**.

For each of `chatgpt`, `claude`, `gemini`, in series:

1. Navigate → **modal sweep** (§7) → re-establish composer readiness *after* navigation.
2. `enable_deep_research()` — already implemented, already verified idempotent on real ChatGPT.
3. **Deliver the BRIEF, not the topic.** The BE delivers brief *text* into the composer with verification
   and a fallback: `verified_paste_brief` (`BE research.py:13422`), `_verify_paste_landed` (`:13358`),
   `cua_paste_fallback` (`:13583`). ⭐ **Text delivery is BE-sanctioned**
   (`BE research.py:36100-36108`), so **P2 needs no file upload** — it does not inherit B3's fragility.
   Port the *verify-then-fallback shape*, not the CUA leg.
4. Send, then await completion with the **existing** three-signal wait: `data-state=complete` ∥ content
   stability ∥ **veto while the platform's own in-flight control is present**. All three landed
   2026-07-30 and are mutation-tested. Do not replace them with a bespoke poll.
5. **Extract the report as markdown** (§6) and **judge it** — `harvest.judge` is already point-keyed and
   reusable unchanged (`emubackend/harvest.py:90-162`).
6. **Write the document to Firestore** (§8).

⚠ **Claude's control is named `research`, not `deep research`** — searching Claude for the latter matches
nothing. Already encoded per-platform in `phases.py`; do not regress it.

### 5.4 P3 — NotebookLM. No iOS implementation exists at all.

Two separately-budgeted sub-steps in the BE:

* **3a upload** — `run_phase3_upload` (`BE research.py:38633-38973`), capped at
  `PHASE_3_UPLOAD_MAX_MIN=15` (`:556`). Opens a fresh tab at notebooklm.google.com, creates a
  **brand-new notebook**, uploads the three P2 markdown files.
* **3b audio** — (`BE research.py:38978`), capped at `PHASE_3_AUDIO_MAX_MIN=90` (`:557`). Generates the
  Audio Overview, waits for ready, downloads the `.m4a` (the BE uses a Playwright `page.on("download")`
  listener — `:39571`), transcodes, uploads to Storage (`:6336`), writes the `audios` doc (`:39869`) and
  `links` (`:39871-39882`).

⚠ **This is not a port — the BE never solved NotebookLM deterministically.** There is **no CSS selector**
in the BE for NotebookLM's Format dropdown, Length dropdown, or Generate button; they are clicked by
**Vision/CUA from prose** (`BE prompts.py:734-821`), and `BE research.py:39138-39140` states the DOM dump
exists precisely so a future run can "pin the (un-supplied) Generate + length controls". **iOS has no
Vision/CUA tier.** So P3 needs a **new deterministic implementation** of something only ever driven by a
vision model. Budget accordingly and expect to capture selectors nobody has. NotebookLM also ships **no
test ids at all** (Angular Material) — expect `aria-label`, role and text handles, verified by
**driving** them, not by resolving them.

**Audio, per B4 — cheaper than it first looks:**

* **Decode needs no dependency.** `AVAssetReader` + `AVAssetReaderTrackOutput` with `LinearPCM` output
  decodes the `.m4a` natively.
* **Encode uses vendored LAME**: PCM → mp3 at **160 kbit/s**, matching `-b:a 160k`.
* ⭐ **Inherit the BE's degradation semantics.** `_transcode_audio_to_mp3` is *"best-effort and
  non-raising"*: on a missing encoder it logs `"ffmpeg not found — delivering the original"` and
  **returns the source untouched** (`BE research.py:646-690`). An encoder failure must **not fail the
  run** — upload the `.m4a` and say so. "Full parity" *includes* this fallback.
* ⚠ Why the transcode exists at all: NotebookLM serves an `.m4a` whose `moov` atom sits at the end,
  which froze a podcast's Firestore doc at `durationSec: 0` (`BE research.py:578`). Whatever ships must
  actually fix that or the bug returns.

---

## 6. Markdown extraction — the BE has nine paths; iOS has one and it is the wrong one

| | Backend | iOS today |
|---|---|---|
| Converter | `html_to_markdown` = `markdownify(html, heading_style="ATX", bullets="-")` (`BE research.py:29084`) | none |
| Primitive | `_extract_html_to_md` reads `els[last].innerHTML` (`BE research.py:29152`) | **no `innerHTML` primitive at all** (`InAppPipeline.swift:19-31`) |
| ChatGPT ladder | `.md` download (`:30036`) → HTML→MD (`:30072`) → clipboard (`:30153`); extractor `:29983` | — |
| Gemini ladder | DOM-first (`:30285`); extractor `:30182` | — |
| Claude ladder | download-first (`:30750`); extractor `:30482` | — |
| Wrong-document guards | `_is_sources_not_document` (`:20567`), `_looks_like_nav_sidebar` (`:20533`) | — |
| Length floors | 500 / 2000 chars per tier (`:30054`, `:30095`); Claude 30 % length-sanity (`:24511`) | — |
| iOS's only extraction | — | `harvest_sources`: first non-empty `sources` css, `inner_text()` per node (`phases.py:883-895`) |

**Build, in this order:**

1. **An `innerHTML` primitive on both halves** — Python `PageShim` and the Swift `WebPage` protocol. This
   is the single missing capability everything else depends on.
2. **Port `html_to_markdown`.** Keep **all three** arguments the BE passes — `heading_style="ATX"`,
   `bullets="-"` and **`strip=['img','script','style']`** (`BE research.py:29084-29088`). Dropping the third
   silently changes every output. `markdownify` is small; vendor or reimplement under A8.
3. **A `report` manifest key** per platform — distinct from `response_container` (that is the *turn*, and
   the correct handle for the wait) and from `sources`.
4. **Port both wrong-document guards and the per-tier length floors.** These stop a sidebar or a citation
   list being saved as the research. Without them a plausible-but-wrong extraction is indistinguishable
   from success — the dominant failure class in this whole initiative.
5. **Reuse `harvest.judge` unchanged.** Its four verdicts — empty / all-unusable / all-identical /
   collapse-against-its-own-baseline — apply directly to a document.
6. Per B2, implement the **download tier** — and note the mechanism is **not decided by this recipe,
   because three exist and the repo names only two**:

   | Route | Where it works | Notes |
   |---|---|---|
   | `WKDownload` / `decidePolicyFor navigationResponse` | **in-app only** | The `WebPage` protocol has **no download primitive** (`InAppPipeline.swift:19-31`); this is new surface |
   | Files-container polling | Safari, awkwardly | `backend.py:482-487` — downloads land in the Simulator's Files container with **no completion signal** |
   | ⭐ **`fetch()` the URL in-page and return the bytes over `evaluate`** | **BOTH surfaces** | The repo's own note gestures at this (`backend.py:484-487`) and this recipe has never surfaced it. Same-origin so cookies ride along; base64 over the JS bridge. **Try this first — it may make B2's "in-app only" caveat moot** |

   Where a tier genuinely cannot run, **report the skip and its reason**; never degrade silently.

---

## 7. Modals, and the clarifying question that silently corrupts a run

### 7.1 Modal handling does not exist, and the schema cannot express it

* The only dismissal is **opener-scoped**: `_dismiss_opener` returns `True` immediately when the entry
  has no opener (`phases.py:578-579`), and fires only when the driver **itself** opened the menu
  (`phases.py:642-665`, gated on `opened`).
* Repo-wide grep for
  `modal|dialog|dismiss|overlay|popup|consent|onboarding|"Got it"|"Not now"|banner|upsell|splash`
  → **zero** handlers for cookie consent, onboarding tours, upsells or app-install banners.
* **The schema cannot hold a modal target**: `ALLOWED_KEYS` rejects any key outside the 13-name baseline
  (`emubackend/selectors.py:283-290`).
* The BE carries ~20 narrowly-targeted handlers **plus one literal sweep** for
  `Okay / Got it / Dismiss / [aria-label=Close]` (`BE research.py:28982`).

⭐ **Scoping counterweight — do not over-build.** The BE has **no** cookie-banner, consent, onboarding,
"Not now" or "Try Pro" dismissal either; `BE research.py:10769` explicitly instructs Vision that a cookie
banner is *not* a login wall. So the missing **general** dismisser is a smaller gap than it sounds. Build
only: **(a)** the BE's literal sweep, run after every navigation, and **(b)** the **platform-specific
gates**, which are the real ones — Gemini's **"Start research"** and Claude's **"Skip"**.

⭐ **Reuse what exists.** `_POPUP_STATE_JS` (`phases.py:131-149`) already contains a **generic** popup
detector whose fallback enumerates visible `[role=menu],[role=listbox],[role=dialog]`. It is wired
narrowly to openers; widening it is a call-site change, not new plumbing.

### 7.2 The clarifying question

```
grep -rniE "clarif"  (whole repo, incl. .venv artifacts docs fixtures)  → 0 lines
git log -S"clarif" --all                                               → 0 commits
```

Deep research often replies with a **clarifying question first**. Today that question **passes the wait**
— it is content, it is stable, generation has stopped — and then **fails the harvest**. So a run reports
a selector problem when the platform simply asked something.

Fix as a **fourth `classify_response` state** (`classify_response` is defined ~`phases.py:225` and already
has three: content / empty / error) plus a **reply-or-confirm** step. Gemini's `start_research` key exists in the baseline with an
**empty value and zero behaviour** — a dead slot to fill.

---

## 8. Delivering to the frontend — and an important correction

⚠ **The backend does NOT stream markdown. Assuming it does will make you build the wrong thing.**

* The **document** is written **once**: `save_document_to_firestore` does a single `.set()` putting the
  entire report into one `content` field at `users/{uid}/researches/{rid}/documents/{docType}`
  (`BE research.py:6400`), doc-ID-keyed so re-extractions upsert.
* What **streams** during a run is **telemetry only**: `agent_progress` events carrying `partialTextLen`
  (an int) and `partialTextPreview` — **the last 500 characters** (`BE research.py:22903`, `:22957`) —
  emitted at the poll tick (`POLL_PRO=30s`, `POLL_DEEP_RESEARCH=120s`; `:537`, `:544`).
* ⚠ **Code-vs-comment:** `BE research.py:22870` claims *"true token-level streaming"*. It is a character
  count plus a 500-char tail at minutes-scale granularity. **Believe the code.**
* The FE reads `doc.content` straight from the subcollection with **no fetch or reassembly**
  (`FE src/components/DocumentViewer.tsx:341`).

**iOS writes none of it.** The complete write surface is three shapes: a root-doc `status`/`backendRunId`
patch (`emubackend/pipeline.py:176-186`), `pipeline_events` appends (`:147`), and a device heartbeat
(`ios/Sources/SuperResearchDeviceCore/PairingCoordinator.swift:119-132`). Content is harvested and then
**actively discarded** — `InAppPipeline.swift:548` drops the answer with `_ =`, and `phases.py:987` logs
only `p3:{name}:{ok}:{count}`.

⭐ **For Firestore the transport is already built and rules-verified on both halves — a content write is
a new CALL SITE, not new plumbing.** ⚠ **This is NOT true of Storage** — see the warning below.

**The exact docType contract** (`BE research.py:6405-6412`, verified). Five documents per run, not three:

| docType | Produced by | Notes |
|---|---|---|
| `brief` | P1 | the input to every P2 agent |
| `chatgpt` · `gemini` · `claude` | P2 | lowercase platform key |
| **`consolidated`** | **post-P2** | ⚠ **Missing from every earlier draft of this plan.** The BE builds it by plain concatenation: `# Consolidated Research Report: {topic}` then `## {name} Research` per agent (`BE research.py:43465-43474`). It is trivial to produce and the FE displays it — **build it** |

Field shape, exactly (`BE research.py:6405-6412`) — note `id` and `type`, which an earlier draft omitted:

```
{ "id": doc_type, "name": name or f"{doc_type}.md", "type": doc_type,
  "content": content, "size": f"{len(content)/1024:.0f} KB",
  "createdAt": int(time.time()*1000) }
```

plus `deviceId` (§10.1 — the rules require it and no gate currently checks).

**And the streaming events:** `agent_progress` carrying `partialTextLen` + `partialTextPreview` (last 500
chars), so the FE's existing live view lights up. ⚠ Precision: a **~500 ms MutationObserver** feeds the
preview buffer (`BE research.py:22935-22965`); only the *emission* runs at the poll cadence. So "not
streaming" is about emission granularity, not about how the text is collected.

---

## 8b. ⛔ THE RUN'S TWO ENDS — intake from the web app, handoff to the cloud

**Added 2026-08-08 on the owner's requirement:** *a run fired from the web app must complete
end-to-end — P0–P3 on the phone, P4 and P5 in the cloud as usual, consistently with the Windows,
Linux and Mac backends.* Every earlier draft of this recipe planned the **middle** of a run and
neither end. §12's items 1–19 take a topic that is already in hand and stop at an audio file. **A
run cannot start and cannot finish.** These are items 20 and 21, and 21 is on the critical path
because without it a finished run is invisible to the product.

### 8b.1 Intake — how a run reaches this device

**The owner's action, stated exactly:** they submit a topic in the web app with this device
**paired and selected**. "Selected" is `activeDeviceId` in the user's `settings/prefs`, written by
the sidebar device picker — and ⚠ **if it is unset and the account has exactly one device, that
device is used implicitly**, which is how a single-device account works without anyone touching a
picker. The submit resolves that device and writes into **`devices/{deviceId}/queue/{docId}`**
(`FE src/lib/firestore.ts:2517, 2522`; the rule requires `submittedBy == auth.uid`). Legacy devices
used `research_tokens/{token}/queue/` — modern devices do not.

⛔ **`queue` is NOT `commands`, and the difference is the whole of this item.** This app already
polls **`devices/{id}/commands`** — restart, update, check-update, ping, clear_local_storage — in
`DeviceBackend.pollCommands()`. It has **never** read `devices/{id}/queue`, which is the *research
lifecycle* channel. Follow `pollCommands` as the model for shape (the `processed` guard, the
staleness bound, the delete-after-handling) and then write the queue reader beside it. A reviewer
skimming for "does it poll the device?" will find `pollCommands` and wrongly conclude this is done.

⛔ **CORRECTED 2026-08-08 — this said "four actions: `start`, `cancel`, `stop`, `resume`". There is
no `stop` action on the queue, and believing there is leaves the owner's Stop button dead.** Read
against the FE:

| Channel | Path | Vocabulary | Polled by this app? |
|---|---|---|---|
| Research **lifecycle** | `devices/{id}/queue` | **`start`, `cancel`, `resume`** — plus `ownerControl: "stop"\|"cancel"` on a *cancel* doc, for an owner controlling a sharer's run | **No** — item 20 |
| Device **operations** | `devices/{id}/commands` | `restart`, `update`, `check-update`, `ping`, `clear_local_storage` | Yes, `pollCommands()` |
| ⭐ Per-**run** control | **`users/{uid}/researches/{rid}/commands`** | **`stop`**, `pause`, `resume`, `config`, `add_context`, and every pipeline decision | **No — and this is the one the Stop button uses** |

`writeCommand` (`FE firestore.ts:2135`) writes the third one and stamps the parent research's
`deviceId` on each doc, which is exactly what the rule requires of the synthetic device user — so
the identity is already right. The desktop consumes it through `_start_command_listener`
(`BE research.py:9802`), which also carries a first-attach-replay staleness gate that must be
ported: **the 30-second stale check applies to the FIRST snapshot only.** Applying it to live
commands silently drops the owner's clicks whenever the browser clock that wrote `timestamp` is
skewed against the device's — which left runs stuck on pause in production.

**DoD 6b needs channels one and three.** Shipping only the queue gives the owner a run they can
start and cancel-while-queued but cannot **stop** once it is running.

⚠ **Two traps in the payload itself** (`buildQueuePayload`, `:2545`):
* It writes **both** `submittedAt: serverTimestamp()` **and** a client-ms `timestamp: Date.now()`,
  deliberately — the BE's stale-queue defense reads the **client** field because `serverTimestamp()`
  lands a few ms later. Read the same field the BE reads, or your staleness maths disagrees with the
  product's.
* **`uid` and `submittedBy` can legitimately DIFFER.** For an owner stopping a *sharer's* run, `uid`
  is the sharer's (whose tree the run lives in) and `submittedBy` is the owner's (which is what the
  rule constrains). Treating them as interchangeable writes the run into the wrong user's tree.
  `ownerControl` distinguishes the framing, and for `stop` it means **preserve** the running run
  rather than purge it.

⚠ The BE also **stale-skips** ZOMBIE and ABANDONED entries rather than running them
(`BE research.py:7519, 7578-7593`). Port that, or a phone that was offline for a day wakes up and
starts a stack of runs the owner abandoned.

The desktop backend learns about it through a Firestore **`on_snapshot` start-listener**
(`BE research.py:3201-3232`). ⛔ **iOS cannot do that.** Firestore `Listen` is gRPC-only and this
repo speaks REST, so the device must **poll**. Poll cadence is a bot-flag-adjacent choice only for
platform pages, not Firestore — but it is a battery choice, so state the interval and why.

⛔ **Polling is the easy half. The CLAIM is the half that corrupts data if you get it wrong.**
The owner may have a Mac backend and this phone paired to the **same account**, both watching the
same queue, and the phone has multiple workers of its own. `_try_claim_queue_doc`
(`BE research.py:4162-4230`) is the protocol, and its mechanism ports exactly:

1. `get()` the queue doc, keeping its `update_time`.
2. Early-out if `assignedWorker` or `processed` is already set — a sibling won.
3. `update({assignedWorker, claimedAt})` **with a precondition on that `update_time`**. Firestore
   linearizes single-document writes server-side, so the precondition gives the same guarantee as a
   transaction without needing one.
4. A **`FailedPrecondition`** on the update is the *expected* race-loss path. Return false; do not
   raise, do not retry the claim.

⭐ **REST can express this** — `currentDocument.updateTime` on a commit write — but
`FirestoreREST.swift` **has no precondition support today**, so item 20 includes adding it. A claim
without the precondition is not a weaker claim; it is **no claim at all**, and two backends will
both run the same research.

⚠ Retry only the *transient* failures the BE retries (unavailable, deadline-exceeded,
unauthenticated, internal), with its `250 ms × attempt` backoff. Retrying a `FailedPrecondition`
turns a clean race-loss into a stolen run.

### 8b.2 Handoff — P4 and P5 stay in the cloud

⭐ **This is the part that makes the phone consistent with every other backend, and it is
currently absent from the iOS repo entirely** — `beDone`, `needsFeTrigger` and `uploadYouTube`
appear only in `docs/FIRESTORE_CONTRACT.md:641-642`, never in code.

The desktop backend finishes P3 and does exactly three things (`BE research.py:51655-51670`, and
the resume path at `:48370-48383`):

1. `{"beDone": True, "beDoneAt": <ms>}` on the research doc. **The queue gate waits on this**, so a
   missing `beDone` stalls the owner's *next* run, not just this one.
2. `_fire_fe_p4_trigger` → `{"needsFeTrigger": True, "needsFeTriggerAt": <ms>}`. This is the FE
   catch-up backstop, and it is written **synchronously and first**, so the chain still completes
   from the web app on next open even if step 3 fails entirely.
3. `POST {FE_BASE_URL}/api/uploadYouTube` with `{research_id, ownerUid}`, authenticated with **the
   synthetic device user's own fresh ID token**. Cloud Run then runs P4 and chains P5 server-side
   and flips `status`. Only `uploadYouTube` is hit — it owns the P5 chain, and calling P5 as well
   would double it. `casRouteP4` dedups this against the FE catch-up, so both triggers coexist.

⭐ **The device principal is already the right principal.** The FE route authorises via
`authorizeSynthForResearch` (`FE src/lib/firebase-admin.ts:120-133`), which checks the token's
`deviceId` claim against the device doc — exactly the identity this app already holds. **No new
auth work.** The POST is long-lived (the route encodes and uploads inline, up to an hour) and must
not block the run loop, and a client disconnect can abort the route mid-encode — so detach it and
give it a long timeout, as the BE does.

⚠ **Order matters and is not cosmetic.** Marker first, then POST. Reversing them means a failed
POST leaves no backstop, and the run dies silently with the audio already paid for.

⚠ **`status` is NOT set to `completed` by the backend.** It stays `ongoing` through `beDone`; the
FE-P5 chain flips it. A phone that writes `completed` itself would report a run finished that has
no video and no email.

### 8b.3 ⛔ THREE COPIES OF `firestore.rules`, AND THE GATES VERIFY THE OLD ONE

**Measured 2026-08-08, and documented nowhere until now.** There are three copies and they disagree:

| Copy | State |
|---|---|
| **Deployed** (`super-research-492814`) | **Old** — the owner has not deployed since the app wave |
| **`dg-research/firestore.rules`** | **New** — grants the synthetic device `restingWorkerIds` (`:463`), pushed in `8b481ec` |
| **`dg-research-ios/fixtures/rules/firestore.rules`** | **Old** — still owner-only (`:469`). md5s differ |

⚠ **So every rules-based gate on this repo — `bin/rules_verify.py`'s 14/14, `c0fe_gate.sh`,
`c1_contract_gate.sh` — currently verifies against PRE-`8b481ec` rules.** A green rules gate is
therefore evidence about the *deployed* rules, not about the FE repo's. That is coincidentally the
safer of the two while the deploy is pending, but it is luck, not design.

**The FE repo is authoritative.** When you touch anything rules-adjacent: resync the fixture from
`dg-research/firestore.rules`, re-run the gate, and say in `DEVIATIONS.md` which copy you verified
against. **Never hand-edit the fixture** to make a gate pass — that turns the gate into a mirror of
your assumption. And a 403 on the worker-rest path is expected until the owner deploys; it is not a
defect in the app.

### 8b.4 What this adds to §12

| # | Work | Size | Depends |
|---|---|---|---|
| **20** | **Run intake** — the owner submits a topic with this device selected, and it runs. Poll `devices/{id}/queue` (**not** `commands`, which is already polled), handle all four actions (`start`/`cancel`/`stop`/`resume`), port `_try_claim_queue_doc`'s precondition claim, add `currentDocument.updateTime` to `FirestoreREST`, route a claimed run to a free worker, honour `processed`, read the **client-ms** `timestamp` the BE reads, keep `uid` and `submittedBy` distinct, and port the ZOMBIE/ABANDONED stale-skips. ⚠ **Test the race with TWO claimers against the emulator** — a single-claimer test passes against no claim protocol at all | **L** | — |
| **21** | ⭐ **P3→P4/P5 handoff**: `beDone`/`beDoneAt`, then the `needsFeTrigger` marker, then the detached authenticated POST to `/api/uploadYouTube`. **ON THE CRITICAL PATH** — without it the run never completes and the queue gate stalls the next one | **M** | 17 |

**The critical path becomes `1 → 2 → 12 → 7 → 8 → 14 → 16 → 17 → 21`, with 20 startable now** —
it needs neither gate zero nor the extractor, and it is what lets you test everything else the way
the owner actually uses it: by pressing go in the web app.

---

## 9. Documentation in this repo that is WRONG today — correct it as you go

Every row was written by a previous session and verified false on 2026-07-30. **A stale doc is worse than
no doc, because it stops the next person looking.**

| Claim | Where | Truth |
|---|---|---|
| The dismissal-asks-the-opener bug is **fixed** | `docs/DEVIATIONS.md:902-913` | Fixed in **Python only**. Swift `dismissOpener` still asks the **target** (`InAppPipeline.swift:156-161`), so with `text_contains:"Deep research"` the post-activation pill keeps matching and it can **never** return true — and the `false` is **discarded** at both call sites (`:271`, `:279`) where Python raises |
| Coverage is "15/25" | `emubackend/selectors.py:250` | **17/25**, verified by running the repo's own loader |
| "the 12 absent keys" | `selectors_mobile.json:19-30` | **8** absent. chatgpt **7/7** · gemini **5/7** · claude **4/7** · notebooklm **1/4** |
| — | `selectors_mobile.json:112-118` | `gemini.deep_research_toggle` declares **no `opener`** while its own provenance says it takes two steps (tap `button[aria-label="Upload and tools"]` first). It **will raise**, exactly as ChatGPT's did before the opener mechanism landed |
| A NotebookLM "selector gap" | `bin/coverage_gate.py:38` vs `selectors.py:80-85` | A **schema mismatch printed as a selector gap.** `REQUIRED = (logged_in_marker, composer, send, sources, response_container)` but `ALLOWED_KEYS['notebooklm']` contains **none** of the last four, and `_validate` **rejects** a manifest that adds them (`:283-290`). NotebookLM can never report "cleared" |
| The gate suite proves the real platform | `bin/all_gates.sh:75` | It takes **no `--platform`**, so the suite runs the **mock**. Green is not evidence until this is wired |
| "Synthesis & Podcast", "Podcast-style audio discussion generated", P4/P5 video+email | `ios/App/Landing.swift:86-112` | **No implementing code exists for any of it.** Build it or stop advertising it |
| The golden fixture came from real backend runs | `bin/c1_contract_gate.sh:8`, `ContractEmitter.swift:11` | Self-contradictory: `contract/fixtures.py:9-23`, `README.md:151-160` and `docs/RUNBOOK.md:166-168` all say real capture is impossible today and still owed. **Treat the fixture as this repo's belief about the contract plus a rules check — not an oracle from production** |
| ~~iOS unpair makes the device "disappear from the web app"~~ | `Operations.swift` | ✅ **Now TRUE** — unpair calls `unpair-self`, which deletes the doc. Fixed 2026-08-07; see §11 |

---

## 10. Two correctness risks no gate can currently catch

1. **The research-doc patch omits `deviceId`, which the rules require.** `deviceUpdatingFor` needs it
   (`fixtures/rules/firestore.rules:72-78`); the patches don't send it (`pipeline.py:178-182`,
   `ContractEmitter.swift:72-75`). **Both gates route around it** — `bin/c1_contract_gate.sh:30` signs in
   as the **owner** uid, so the owner branch satisfies the rule and the **device branch is never
   evaluated.** A genuine synthetic device writing to an FE-created doc would **403**.
2. **`expireAt` is written as a Firestore `stringValue`, not `timestampValue`,** on the Swift path
   (`FirestoreREST.swift:91-112` has no timestampValue case; `ContractEmitter.swift:102`). The 30-day TTL
   **silently never applies.** The golden fixture **cannot** catch it — both normalisers collapse a
   timestamp and an ISO string to the same `<iso8601>` marker (`contract/fixtures.py:99-101`,
   `ContractEmitter.swift:164`).

---

## 11. ✅ Device-operation bugs (retire / resurrect / unpair) — FIXED 2026-08-07/08

✅ **This whole section is DONE — §12 item 15 is closed. Read it as history, not as work.** The app wave
of 2026-08-06/08 rebuilt the operation catalogue around the fact that *the phone is the backend*, and
every row of the table below was fixed:

* **unpair** now calls `POST /api/devices/unpair-self` as the synthetic device user
  (`RESTPairingBackend.unpairSelf`), keeps the identity on failure so the op stays retryable, and moves
  the app to the not-paired screen. `release()`'s `status:"retired"` write — which no frontend code ever
  read — is gone.
* **retire / resurrect** are the **On Startup toggle**, which PATCHes `supervised`. The terminal's
  `--retire` means *disable autostart*, not *unpair*; the old entry's summary had the inversion written
  into its own copy. Neither is an operation row any more.
* **The `ios/App` blind spot is closed.** The model layer moved to `ios/Sources/SuperResearchDeviceCore`
  where `swift test` reaches it, and `AppLayerBoundaryTests` fails the suite if logic reappears in
  `ios/App`. Swift coverage went 104 → 199 tests.

⚠ **What is NOT done from the surrounding analysis:** §10's two correctness risks (item 18) — see the
note there. The original text is kept below verbatim, because its evidence is what made the fixes
right.

| Op | Terminal means | iOS does | Parity |
|---|---|---|---|
| **retire** | Turn **off** auto-start, **keep** the pairing: remove the supervisor artifact, kill the daemon, PATCH `supervised:false` (`BE research.py:52458-52474`, `:52576`) | Calls `release()` — **destroys the pairing**, and **never writes `supervised`** | **NO — inverted** |
| **resurrect** | Turn auto-start back on: install the supervisor, spawn the daemon, PATCH `supervised:true` (`BE research.py:52121`, `:52278`) | **Nothing.** No `case` in `perform`; falls to the `.daemon` stub returning *"not sent — the Mac control bridge has no transport yet"* (`DeviceBackend.swift:197-207`) | **MISSING** |
| **unpair** | `POST /api/devices/unpair-self` as the synth user → **device doc deleted**, synth Auth user deleted, secrets entry deleted, then local wipe (`BE research.py:52756-52765`; `FE unpair-self/route.ts:130-167`) | Same `release()` — one field PATCH + local Keychain wipe. **Zero occurrences of `unpair-self` in any `.swift` file** | **PARTIAL** (local half only) |

**The load-bearing detail.** `release()` writes `status:"retired"` — and **the frontend never reads
`devices.status`.** `mapModernDeviceDoc` does not map it (`FE src/lib/firestore.ts:596-666`); visibility
is `ownerUid == uid ∥ sharedWith contains uid` (`:753-759`) filtered by
`pairConfirmedAt ∥ lastHeartbeat > 0` (`:701-705`). `release()` clears none of those, and no client can
delete a device doc (`fixtures/rules/firestore.rules:489` — `allow create, delete: if false`). So the tile
**stays forever** as a red "Offline" dot.

**And `release()` is not atomic.** The real order is `stopHeartbeat()` → PATCH → `store.clear()`
(`DeviceBackend.swift:366-371`). So if the PATCH throws, control jumps to the `catch` and **`store.clear()`
never runs**: the identity survives, and the next foreground `resumeIfPaired()` brings the device back
online with `status:"active"`. Net effect — the toast says "Unpair failed" and the device reappears minutes
later. *(An earlier draft of this section claimed `store.clear()` runs first and destroys the `pollSecret`;
that was wrong on both the ordering and the consequence.)*

**Zero test coverage**: `ios/App/` is not a package target (`ios/Package.swift:22-28`) so `swift test`
never compiles `DeviceBackend.swift`, while `emubackend/tests/test_control.py:107-111` parameterises
`unpair`/`retire` and then **skips both**.

**Fix order:** split retire from unpair (route retire → `setSupervised(false)` + `stopHeartbeat()`); make
`release()` atomic; correct `Operations.swift:58`'s copy; wire or delete `resurrect`; reset the pairing
controller on release; then the M-sized *make unpair actually call `unpair-self`*.

---

## 12. ORDERED WORK LIST

**⚠ The critical path is `1 → 2 → 12 → 7 → 8 → 14 → 16 → 17 → 21`, and item 20 is startable
immediately** (it needs neither gate zero nor the extractor). Items 20 and 21 are the run's two ends —
intake from the web app and handoff to the cloud — and are specified in **§8b**. An earlier draft called it `1 → 2 → 5 → 6`,
which is wrong twice: it omits item **12** (without `gemini.deep_research_toggle`'s opener and the
`ALLOWED_KEYS` schema change, neither a gemini P2 nor a `report` key can exist), and it puts the two
**L**-sized items (16, 17) last on a path that does not name them. `5 → 6` runs in **parallel** with
`7 → 8`, it is not the long pole.

| # | Work | Size | Depends |
|---|---|---|---|
| ~~1~~ | ✅ **DONE 2026-08-08 — GATE ZERO resolved as H7** (§3.0). Recorded in `DEVIATIONS.md` with all four probes verbatim | — | — |
| **2** | ⭐ **RESCOPED BY H7.** For **ChatGPT DR**: a session-token fetch extractor (§3.0), which needs *no* `innerHTML` and *no* markdown conversion — the platform returns markdown. `html_to_markdown` and the `innerHTML` primitive are still needed for the **P1 brief** and for **Claude/Gemini**, whose containers are unmeasured. The `report` manifest key is unchanged and still gated on item 12's `ALLOWED_KEYS` | **M** | — |
| 3 | Make the wait reject an empty / speaker-prefix-only turn: route `classify_response`'s `empty` verdict into `await_response` **and** `harvest_sources`; port to Swift | **S** | — |
| 4 | Fix Swift `dismissOpener` to ask the **opener**; dismissal-parity test; correct `DEVIATIONS.md:902` | **S** | — |
| **5** | Extraction ladder + wrong-document guards + per-tier floors; reuse `harvest.judge` | **L** | 2 |
| **6** | `documents/{docType}` writer + `agent_progress` with `partialTextLen`/`partialTextPreview` | **M** | 5 |
| 7 | P1 correctness: the wrapper prompt, `disable_deep_research()`, extract-and-return the brief | **M** | 2 |
| 8 | P2 consumes the brief (not the topic); port `verified_paste_brief`'s verify-then-fallback shape | **M** | 7 |
| 9 | Re-point P3 at the document; keep the source harvest as telemetry only | **S** | 6 |
| 10 | Modal sweep after every navigation + Gemini "Start research" / Claude "Skip" gates | **M** | — |
| 11 | Clarifying question as a 4th `classify_response` state + reply/confirm | **M** | 10 |
| **12** | Capture the 8 missing selectors + `gemini.deep_research_toggle`'s opener; fix the `ALLOWED_KEYS` / `coverage_gate` schema mismatch. ⚠ **ON the critical path** — item 5 cannot add a `report` key until `ALLOWED_KEYS` accepts one, and item 14 has no gemini P2 without the opener | **M** | 1 |
| 13 | Wire `--platform` through `bin/all_gates.sh` so the suite runs a real platform | **S** | — |
| 14 | Sequential 3-platform P2 (B1). ⚠ **Items 10 and 11 are part of this one** — Gemini's "Start research" gate and a clarifying question both fire on P2's real happy path, so they are not optional extras to schedule later | **M** | 8 |
| ~~15~~ | ✅ **DONE 2026-08-08** — device-op fixes (§11). unpair calls `unpair-self`; retire/resurrect are the On Startup toggle; the `ios/App` test blind spot is closed | — | — |
| 16 | P3 NotebookLM: new notebook → **paste the consolidated markdown as a "Copied text" source** → Audio Overview → ready predicate. ✅ **The picker question is RESOLVED — measured 2026-08-08: "Copied text" is a first-class source type and the page carries ZERO `input[type=file]` elements on mobile, so no document picker, no `UIFileSharingEnabled`, no Files export, and no `set_input_files` equivalent is needed.** ⚠ The host is **`notebook.google.com`**, not `notebooklm.google.com`, and the product renders as **"Gemini Notebook"** — both break selectors keyed on the old names. See `DEVIATIONS.md`. | **L** | 14 |
| 17 | Audio: `AVAssetReader` decode + vendored LAME @160k + Storage upload + `links.audio_file`, **with the BE's non-raising fallback**. ⚠ **A Firebase Storage client does not exist** — `FirestoreREST.swift` is Firestore-only, and Storage rules were **not** part of the 14/14 rules verification. This item includes building that client and verifying those rules | **L** | 16 |
| 18 | The two correctness risks in §10, **re-measured 2026-08-08 and they are NOT symmetrical** — read this before assuming either is done. ⚠ **`deviceId` is missing from the research-doc patch on BOTH halves**: `ContractEmitter.startRun` sends only `status`+`backendRunId`, `finishRun` only `status`, and Python's `start_patch` sends neither. **The `deviceId` you will find in both `ContractEmitter.emit` and `contract/events.py` is on the pipeline_EVENT, which already has it on both halves — do not mistake that for the patch being covered.** ⚠ **`expireAt` IS crossed**: a real `timestampValue` on the Python path, still a `.string` on the Swift one (`FirestoreREST.swift` has no timestamp case at all). ⭐ **A correction of a correction**: an earlier 2026-08-08 edit of this row claimed `deviceId` was Swift-only-and-done, which would have let a session "finish" this item by fixing Python alone and then 403 on every research patch in the in-app run — the exact DoD 6 blocker the item exists to prevent | **S** | — |

| **19** | ⭐ **The `consolidated` document** — concatenate the three P2 reports per `BE research.py:43465-43474` and write it as the 5th docType (§8) | **S** | 6, 14 |

**Genuinely off the critical path** — do these while a long real run is in flight: **3, 4, 13**.

⚠ **Three items an earlier draft wrongly parked off-path:**

* **10 and 11** fire on P2's *real* happy path — Gemini's "Start research" gate and a clarifying question
  will both appear during item 14's first three-platform run. Treat them as part of 14.
* **18** blocks **DoD 6**: §10.1 says a genuine device write 403s without `deviceId`, and the in-app run
  authenticates as the device. Without item 18 the in-app half cannot write at all.
* **15** (device ops) is the only truly separable block — see the note in §11.

---

## 13. DEFINITION OF DONE

All of the following. If one is unmet, say which — do not reinterpret the bar.

1. **Gate zero resolved**, with its measurement recorded in `docs/DEVIATIONS.md`.
2. **P1 produces a real brief**: the wrapper prompt sent with DR **off**, the brief **extracted as
   markdown**, non-trivial in length, **written to Firestore** where the FE can render it.
3. **P2 produces three markdown reports** — chatgpt, claude, gemini, sequentially, each fed **the
   brief**, each judged by `harvest.judge`, each written to `documents/{docType}`.
   ⭐ **Plus the `consolidated` document** (§8) — five docTypes total, not three.
4. **P3 produces a podcast**: a new notebook holding the three reports, an Audio Overview generated and
   detected ready, audio downloaded, encoded (**or the fallback taken and logged**), uploaded to Storage,
   `links.audio_file` set.
5. **Run it TWICE.** The idempotence bugs only appear on run 2 — DR already on, a brief already present,
   a notebook already existing. This has caught a real defect before; it is not optional.
6. **Safari, then in-app** (B5). The in-app run is the one that proves what ships.
6b. ⭐ **FIRED FROM THE WEB APP, END TO END** (§8b). **The owner submits a topic in the web app
    with this device paired and selected, and the run completes exactly as it would on the original
    backend** — no terminal, no hand-driving, nothing typed on the phone. This device claims the run
    off its own queue without racing any other backend, runs P0–P3, writes the five documents, sets
    `beDone`, and hands off so **P4 and P5 complete in the cloud exactly as they do for the Windows,
    Linux and Mac backends** — same fields, same route, same order. `cancel`, `stop` and `resume`
    from the web app must work too: a run the owner cannot stop is not parity.
7. **`bin/all_gates.sh` green with `--platform` wired**, so "green" means the real platform.
8. **Every fix landed with tests AND mutation testing.** The 2026-07-30 session alone found **seven**
   tests passing for reasons unrelated to what they protect. Assert the **mechanism** — timing, call
   counts, which object was asked — never just the verdict.
9. **A8 verified**: `git status --porcelain` shows **zero tracked modifications** in `BE` and `FE`.
10. **No stale documentation**: every row of §9 corrected.
11. **The descopes are written down, not silently dropped**: no Pro/Thinking model selection, no user-PDF
    attachment in P1 (§5.2), Pro-tier verification skipped in P0 (§5.1), and P2 sequential rather than
    parallel (B1). A reader of the finished repo must be able to tell what was deliberately not built.

---

## 14. STANDING RULES — how the work gets done, not preferences

* **A8 as AMENDED in §0** — not "absolute" any more, and not open either. `BE` is read-only: read it
  freely, modify nothing, vendor rather than edit. `FE` is writable **with the owner's say-so, per
  change**. Neither licenses making the purity guard green.
* **The BE is the REFERENCE ARCHITECTURE — it already does this on Windows, Linux and Mac.**
  ⭐ **Appendix A2 maps it**: which symbol in its 62,869-line `research.py` implements each thing you
  are building. Use the map; do not grep hopefully, and do not reinvent a behaviour it already has.
  ⛔ Never call `setup_firestore_run` — see A2.
* **Read the BE to locate platform controls before writing your own.** It already drives these platforms
  and its comments record failures already paid for. `selfheal_intents.json` names all three research
  controls; the pressed-class-only misread that toggled a working DR **off** is documented in the BE's own
  words. This is how §5.2's prompt, §7.1's sweep and the toggle predicate were all recovered.
* **Tests land WITH each fix, and every one is mutation-tested** (`bin/mutate.py`). A passing test says
  nothing about whether it *could* fail.
* **When two guards protect the same outcome, a test that asserts only the outcome cannot tell you which
  guard is load-bearing.** Assert the mechanism.
* **A script-driven negative is not a negative.** Twice a "this control does not exist on mobile"
  conclusion came from a fixed 3-second sample; a real HID tap later showed **19** menu items. Poll, and
  prefer a real tap over a scripted one when the answer matters.
* **Presence is not readiness; stability is not completion.** Three separate places learned this the hard
  way (`ensure_runtime_stable`, `await_response`, `await_composer_ready`). Prefer a **duration** or a
  **positive platform signal** over a single read.
* **A readiness predicate must name the thing that depends on it.** A chain is right for *resolution* and
  wrong for *readiness* — any weak member satisfies it, so a splash shell with a logged-in marker and no
  composer reported "ready".
* **Never let a guard fail open.** An unreadable verdict must **refuse**, not fall through. A guard that
  fails open is worse than no guard, because it reports as present. (Learned twice — once in a shell
  script whose embedded Python had a quoting bug, so the guard silently never ran at all.)
* **Say which surface you measured on.** There are **three** cookie jars — Simulator Safari, the app
  (`com.distributedglobal.superresearch`), and the C1 harness (`com.distributedglobal.src1`) — each with
  its own `WKWebsiteDataStore`, and iOS gives an app no way to read Safari's. "The platform is signed in"
  is meaningless without the surface.
* **Never pass `--clean` to `build_app.sh` casually.** It is the only thing in the toolchain that runs
  `simctl uninstall`, which deletes the Data container: platform logins, Keychain API keys, pairing
  identity. A plain rebuild installs over the top and **keeps** the container.

---

## 15. DELIBERATELY UNRESOLVED — do not invent answers

1. **If gate zero shows frames are reachable in-app only**, does the Safari path remain as an iteration
   loop, or is it retired? §3.2 states the consequence; the owner has not chosen.
2. **Four `FE` defects — no longer A8-blocked (see §0), so these are now WORK, not a ticket to file.**
   The owner has authorised FE changes for this goal; ask before each one, then fix it here rather than
   describing it. Still unfixed as of 2026-08-08: the "full delete" mislabels
   (`account/page.tsx:791-793`, `lib/devices.ts:127-129`, `:135-137`); the missing `"owner-unlinked"`
   member of the `UnpairSelfResult.action` union (`lib/devices.ts:130`); `unpair-self/route.ts:21-22` and
   `:217` pointing at a "Reset" that is not a delete (Reset is `reset-pair-code`, which rotates the code
   and keeps the doc); and `reset-pair-code/route.ts:269-273` claiming a `pairConfirmedAt` clear hides a
   device that has heartbeat — it does not, `isPairConfirmed` falls back to `lastHeartbeat > 0`.
   ⚠ Also **owner Unlink leaks orphans**: Branch 3 clears `ownerUid` but stamps **no `expireAt`**, while
   `initiate-pair` does — so an unlinked device that never re-pairs lingers forever. (Observed: seven
   `devices/*` docs accumulated in one evening; five never claimed, one a permanent orphan.)
3. **LAME's LGPL-2.1 licence** (B4) is flagged, not decided.
4. **Python and Swift disagree on phase boundaries** — Python P1 = brief-send, P2 = DR + re-send; Swift
   P1 = DR + fill, P2 = send + wait (`phases.py:938-968` vs `InAppPipeline.swift:531-551`). No document
   states the intended mapping, and `test_inapp_parity.py` checks properties rather than the mapping.
   §5 defines the intended contract — **reconcile both halves to it and delete the ambiguity.**
5. *(Resolved as a chore, not a question: `verdict_chatgpt.json`'s "9 writes, 8 events" vs the mock's
   11/9 is unexplained because the check emits counts with no diff. **Add a diff** — it is a 10-line change,
   not a decision needing an owner.)*

---

## Appendix A — repo map (locate by symbol; lines drift)

**Python driver** (`iOS/emubackend/`)

| File | Role |
|---|---|
| `phases.py` | `PhaseDeps`, `PlatformDriver`, `build_phase_bodies` — the phase contract lives here. Also `_TOGGLE_STATE_JS`, `_POPUP_STATE_JS`, `_GENERATING_SELECTORS`, `classify_response`, `resolve` |
| `selectors.py` | `SelectorEntry` (incl. `opener`), `SelectorManifest`, `ALLOWED_KEYS`, `load_manifest` (merges onto the baseline, scoped to named platforms) |
| `intents.py` | `guarded_intent` with the **acceptance window**, the bake ledger, escalation gating, `confirmed_off` |
| `harvest.py` | `judge` — the four read-drift verdicts. Point-keyed, so reusable for documents |
| `pipeline.py` | `run_pipeline`, `RunContext`, the Firestore event writes |
| `substrate/backend.py` | `IOSSimulatorBackend`: `ensure_runtime_stable`, `_calibration`, `tap`, `key`. **`:206-216`** multi-tab refusal · **`:473-480`** upload refusal · **`:482-487`** download refusal |
| `substrate/page_shim.py` | `PageShim`, `ElementHandleShim` (`fill` uses the editor-aware path), `KeyboardShim`, `StaleHandleError` |
| `substrate/iwdp.py` | Socket discovery, `Target.sendMessageToTarget` envelopes, `Inspector`. **`:182-185`** page-target-only `Runtime` |
| `substrate/geometry.py` | `calibrate`, `SR_PROBE`, `CalibrationError` |
| `contract/` | `FirestoreRest`, `CaptureTransport`, the golden-fixture normaliser |

**Swift** (`iOS/ios/`)

| File | Role |
|---|---|
| `Sources/SuperResearchDeviceCore/InAppPipeline.swift` | `WebPage` protocol (**`:19-31`** — the primitive list), the in-app P0–P3, `dismissOpener` (**`:156-161`**, buggy) |
| `Sources/SuperResearchDeviceCore/FirestoreREST.swift` | REST client, `signIn(customToken:)`, value encoding (**`:91-112`**, no timestampValue) |
| `Sources/SuperResearchDeviceCore/RESTPairingBackend.swift` | `initiate-pair`, claim, confirm |
| `Sources/SuperResearchDeviceCore/ContractEmitter.swift` | The Swift Firestore write path — `:72-75` (patch, no `deviceId`), `:102` (`expireAt` as a string), `:164` (normaliser) |
| `Shared/C1Runner.swift` | The C1 run, parameterised on platform/manifest |
| `Sources/SuperResearchDeviceCore/WebAutomation.swift`, `App/WebViewInspection.swift` | The concrete `WKWebView` adapter — **where item 2's `innerHTML` primitive must land** |
| `Sources/SuperResearchDeviceCore/DeviceBackend.swift` | ⚠ **Moved out of `ios/App/` in the app wave** — `ios/App` is not a package target, so nothing there is compiled by `swift test`. Ops dispatch, `release` (now calls `unpairSelf`), `resumeIfPaired`, heartbeat, `setSupervised`, `pollCommands`. Old `App/` line anchors are all dead |
| `App/PairingFlow.swift` | The 5-stage pair flow: `beginPairing`, `restart`, **`cancel`** |
| `Sources/SuperResearchDeviceCore/Operations.swift` | The operation catalogue — **one Runtime group**, no Pairing/Maintenance split, no `retire`/`resurrect`/`upgrade`. ⚠ `App/Operations.swift` no longer exists |

**Scripts** (`iOS/bin/`) — `e2e_simulator.py` (mock **and** real, via `--platform`), `c1_in_app.sh`,
`c1_contract_gate.sh`, `capture_selectors.py`, `drive_selectors.py`, `coverage_gate.py`, `mutate.py`,
`secret_scan.py`, `all_gates.sh`, `build_app.sh`, `b0a_gate.py`, `c0fe_gate.sh`.

---

## Appendix A2 — ⭐ THE BACKEND AS REFERENCE ARCHITECTURE (map, verified 2026-08-08)

**The backend already does the thing you are building, on Windows, Linux and Mac. It is the
reference implementation, and reading it is the fastest correct route** — its comments record
failures already paid for in production. §14's rule stands: **read it freely, vendor rather than
edit, never modify it.**

⚠ **`research.py` is 62,869 lines in ONE file.** That is why "read the BE" kept meaning "grep
hopefully". Locate by the symbol below, never by the line — anchors drift, symbols do not.

| What you are building | Backend symbol | ~line |
|---|---|---|
| **P1 — the brief** | `run_phase1` | 35714 |
| **P2 — three DR agents** | `run_phase2`; per-agent restart `_restart_phase2_agent` | 43214 · 28385 |
| **P2→P3 handoff** | `_build_phase2_to_phase3_handoff` | 44438 |
| **P3 — NotebookLM upload** | `run_phase3_upload` | 45408 |
| **P3 — audio overview** | `run_phase3_audio` (note `prefer_existing_audio` — that is run 2) | 45914 |
| ⭐ **HTML → markdown** | **`html_to_markdown`** — item 2 ports THIS | 33700 |
| **Extraction tiers** | `_chatgpt_dom_tier`, `_gemini_dom_tier`; escalation `get_tier_escalation`, `emit_tier_transition` | 12075 · 12004 · 11565 · 11578 |
| **Wrong-document guards** | `_is_sources_not_document`, `_looks_like_nav_sidebar` | 24241 · 24207 |
| **"Is it still generating?"** | `is_agent_generating` — the in-flight veto §1.1 defect 5 ported | 13562 |
| **Paste the brief, verified** | `verified_paste_brief` — item 8 ports its verify-then-fallback shape | 15936 |
| **Self-heal wrapper** | `_selfheal_try` — copy the PATTERN, edit nothing | 36733 |
| **Write a document** | `save_document_to_firestore` — one `.set()`, whole report in `content` | 7362 |
| **Audio → Storage** | `upload_audio_to_storage`, `_upload_audio_via_storage_rest` | 7319 · 7033 |
| **Research-doc patch** | `_update_firestore_research` | 9200 |
| **Emit an event** | `emit_event` | 16197 |
| **Pending decision** | `_persist_pending_decision` | 9235 |
| **Queue claim** | `_try_claim_queue_doc` — item 20 ports this exactly | 4162 |
| **P3→P4/P5 handoff** | `_post_fe_p4p5_trigger`, `_fire_fe_p4_trigger` — item 21 | 9468 · 9444 |
| **Device ops** | `run_retire`, `run_resurrect`, `run_unpair`, `run_restart`, `run_doctor` | 60033 · 59590 · 60331 · 59989 · 60932 |
| **The daemon loop** | `run_daemon_loop` | 58520 |

⛔ **`setup_firestore_run` (`:8736`) is the one function you must NEVER call.** It writes
`owner.json` into `queues/<run_id>` **inside the BE checkout**, where the live production daemon's
disk-restore scans — calling it contaminates the running product. Several helpers
(`_update_firestore_research`, `emit_event`, `_persist_pending_decision`, `upload_audio_to_storage`)
are welded to module globals that only it arms, which is exactly why §B1 says **vendor one cohesive
contract layer** rather than importing them one at a time.

⚠ **Two places the backend's shape does NOT port, and both are decided already:** it runs P2's three
agents **concurrently** across browser tabs — iOS runs them **sequentially** (decision B1, one
foreground tab) — and it learns about queued work through a gRPC **snapshot listener**, where iOS
must **poll** (§8b.1). Everything else in this table is a port, not a redesign.

---

## Appendix B — toolchain and commands (verified 2026-07-29/30; re-lock on any Xcode bump)

Verified on this machine: **Xcode 26.6 (17F113)**, **iOS Simulator runtime 26.5 (23F77)**, device
**`SR-iPhone17Pro`** (iPhone 17 Pro, iOS 26.5).

⚠ **Never hardcode the UDID.** v5.0 pinned `EB3E3597-E62B-413B-B7E5-0FD286ACCC38` throughout and that
device **no longer exists** — on 2026-08-07 the Mac rebooted, CoreSimulatorService shut the working
device down and Simulator.app booted its own remembered one, and every pinned command then silently
targeted the wrong jar. The device is named rather than pinned for exactly that reason: **`bash
bin/sim.sh`** boots `SR-iPhone17Pro` by name and prints its UDID, creating it if absent. Use
`UDID=$(bash bin/sim.sh --udid)` in anything you write.

⚠ **The literal above is the only one allowed to remain, and only because it is history.** Inside
`dg-research-ios`, `test_no_script_or_document_pins_a_literal_udid` fails the suite on any UDID
literal in `bin/`, `emubackend/`, `docs/` or a root `*.md`. **This file sits outside that repo, so
nothing scans it — the discipline here is yours to keep.**

| Component | Pin | Fragility |
|---|---|---|
| DOM channel | `ios-webkit-debug-proxy` **1.9.2** | Needs explicit `-s unix:<socket>`; needs `::1 localhost` in `/etc/hosts`. ⚠ Every command must be wrapped in **`Target.sendMessageToTarget`** — since iOS 12.2 WebKit multiplexes the inspector per target, so a bare `Runtime.evaluate` fails with *"'Runtime' domain was not found"*, which reads as a missing feature rather than a missing envelope. Wait for `Target.targetCreated` with `type == "page"` — **a `frame` target also appears and does not accept `Runtime`** (this is gate zero, §3) |
| Native input | **AXe** (`brew install cameroncooke/axe/axe`) | Trusted taps/keys into real MobileSafari and the app. **Most fragile — re-lock every Xcode** |
| ~~idb~~ / ~~pymobiledevice3~~ | do **not** use | idb's 5-arg HID silently drops taps on iOS 26; pymobiledevice3's WebInspector is physical-device-only |

```bash
export PATH=/opt/homebrew/bin:$PATH          # AXe + IWDP live here
UDID=$(bash bin/sim.sh --udid)                 # ⚠ by NAME, never pinned — see above

xcrun simctl boot "$UDID"                    # windowless (bin/sim.sh does this too)
open -a Simulator                            # attach UI — REQUIRED to hand-sign-in

# ⚠ The IWDP socket path is RANDOM and REALLOCATED ON EVERY BOOT. Rediscover after each boot:
SOCK=$(xcrun simctl spawn "$UDID" launchctl print user/501/com.apple.webinspectord \
       | grep -oE 'RWI_LISTEN_SOCKET => \S+' | awk '{print $3}')
ios_webkit_debug_proxy -s "unix:$SOCK"       # tab list :9221, ws pages :9222+
# (bin/capture_selectors.py and IOSSimulatorBackend.start() both do this for you)

# gates
.venv/bin/python bin/e2e_simulator.py --udid "$UDID" --skip-reboot                 # mock substrate
.venv/bin/python bin/e2e_simulator.py --udid "$UDID" --platform chatgpt            # REAL, Safari jar
bash bin/build_app.sh "$UDID"                                                      # rebuild, KEEPS data
SIMCTL_CHILD_SR_C1=chatgpt xcrun simctl launch --console-pty "$UDID" com.distributedglobal.superresearch
PYTHONDONTWRITEBYTECODE=1 .venv/bin/python -m pytest emubackend/tests -q
PYTHONDONTWRITEBYTECODE=1 .venv/bin/python bin/mutate.py
(cd ios && swift test)

# ⛔ NEVER: xcrun simctl erase        — wipes every seeded login
# ⚠  --clean on build_app.sh          — the ONLY thing that uninstalls; destroys logins + keys + identity
```

**Two-channel architecture.** DOM reads and `execCommand` text go through **IWDP `Runtime.evaluate`**; all
trusted taps and keystrokes go through **AXe HID**. `simctl` has no tap command.

**Cookie jars — always name the surface.** Simulator Safari uses
`.../data/Library/Cookies/Cookies.binarycookies`; an app uses
`<container>/Library/HTTPStorages/*.sqlite` plus `<container>/Library/WebKit/…/WebsiteData`. UA
discriminator: the app pins `Version/17.0`, Simulator Safari reports `Version/26.5` — but ⚠ this breaks
under `SR_DESKTOP_WEB=1` (Mac UA), which is measured and useless anyway.

---

## Appendix C — platform DOM facts already measured (do not re-derive)

* **ChatGPT** uses `data-testid`. Deep research is **plus menu → item**, `role=menuitemradio`, carrying
  `aria-checked`; the menu paints **3 items then 19**; the opener is `[data-testid="composer-plus-btn"]`
  and exposes `aria-expanded` / `data-state` / `aria-controls`. Activating it leaves a **"Deep research"
  pill** in the composer (`inForm: true`) — that pill is the ON signal **and** the trap that broke
  target-based dismissal. Send is **mounted only when the composer is non-empty**.
* **Gemini** uses **`data-test-id`** (hyphenated). `[data-testid]` → 0 nodes vs 41. Its collapsed composer
  often shows **no stop button mid-run** (#897b), so an in-flight check needs `progressbar` /
  `data-is-streaming` too. Deep research is a **mode**, two taps, no `aria-pressed`.
* **Claude**'s control is named **`research`**, not "deep research". Its assistant turn carries no
  testid/id/name — use `div[data-is-streaming]`. Send stays mounted always.
* **NotebookLM** ships **no test ids at all** (Angular Material). Only `logged_in_marker` is captured.
* **`isTrusted === false` for every scripted event on ChatGPT/Claude/Gemini — and the message sends
  anyway.** No send control gates on trust, so `evaluateJavaScript` is the default and HID taps are the
  fallback — except where a control genuinely needs a real tap, e.g. the plus menu.
* **Selectors are a function of STATE, not platform.** idle / post-web-search / post-deep-research are
  three different DOMs. Verify by **driving**, not resolving — provenance distinguishes `resolved` from
  `DRIVEN` and the difference is load-bearing.

---

## Appendix D — environment

* **Firebase project** `super-research-492814`. The app's `ios/GoogleService-Info.plist` is **gitignored**
  and must be present, or the app silently falls back to `PreviewBackend`.
* **Pairing.** `initiate-pair` fields are `pollSecretHash` / `machineName` / `hostname` / `os`. The
  unauthenticated pending read sends **no** API key. `restingWorkerIds` is owner-only. `hid.screen_size`
  must take the **largest plausible-POINTS** `AXFrame`. Calibration needs one retry.
* **A device doc is created ONLY by an explicit "Start" tap or the retry button**
  (`PairingFlow.swift:265-267`, `:370`) → `initiate-pair`. Nothing auto-creates one; `resumeIfPaired` only
  **reads**; `SR_C1` mode returns from `didFinishLaunching` before any pairing UI exists
  (`App/main.swift:46-70`). **Do not create device docs the owner did not ask for.**
* **B0a/B1 need EXCLUSIVE use of the Simulator.** Never run two gates at once.
* **Secrets.** `bin/secret_scan.py` runs inside `all_gates.sh`. The Firebase **web** API key is public by
  design (it ships in the FE's service worker) — remediation is *restrict* (Cloud Console → Credentials →
  API restrictions + HTTP referrers), **not rotate**.

---

*This recipe leads with a spike because the last session's failures all reduced to reading the wrong
document, and no amount of selector work would have found that. Prove the DOM is reachable, then build the
extractor, then the writer, then the phases that use them. Report the numbers honestly: a refuted premise
found in a day is the recipe working, not failing.*
