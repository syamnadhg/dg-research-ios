# EmulatorRecipe — Running the Super Research pipeline on an emulator with an AI self-heal agent

**Status:** Plan / build recipe — **v4 COMPLETE, 2026-07-27**. Decisions A1–A8 locked (**A8 reverses A6 — nothing outside `dg-research-ios` is modified**). **A7's "starts after the product queue" is a priority call, not a dependency** — see §0.5.7; §0.5.10 is armed now regardless.
**⚠ READ §0.5 ONLY.** §0.5 is the authoritative plan and states what is being built. Everything from §1 onward is verified *reference material* (existing-code ground truth, toolchain, hazards) — accurate and worth reading, but where it disagrees with §0.5 about what to build or in what order, §0.5 wins. Earlier premises (dodge Human Verification; native iOS app) have been retired by the owner.
**Audience:** A fresh Claude (or engineer) who must build **and test** this end-to-end.
**Repos referenced:** `~/Downloads/SuperResearch/dg-research` (FE, Next.js), `~/Downloads/SuperResearch/dg-research-backend` (BE, a compiled-Python monolith). This initiative adds a **new sibling repo** and touches neither in place.

> **v2 changelog (what precision was added over v1):** committed the port to a **source checkout** of the BE (the wheel is compiled — you cannot reuse or edit it) with a clear reimplement-orchestration / reuse-leaf-helpers split (§4); pinned the **concrete iOS Simulator toolchain** — DOM via `ios-webkit-debug-proxy`, trusted input via **AXe/baguette** (NOT `pymobiledevice3`, NOT `idb`, which is broken on iOS 26) — with a verified version matrix (Appendix F); fully specified **`PageShim`** and the two-channel iOS input model (§5); made **Phase 0 runnable standalone** — a self-contained wall-detector, an HV-metrics schema + report, a pacing/threshold spec, concrete logged-in assertions, and a background-tab probe (§6); added an **Environment & Setup** appendix — Firebase project, device pairing, env vars, 2FA, proxy (Appendix E); specified emulator **supervision** and the login-**seed** sequence concretely (§6 Phase 2, Appendix F); changed the go/no-go gate from HV *parity* to *materially fewer walls* and the e2e signal from *zero HV* to a *measured rate vs baseline* (§6, §8); gated any Android pivot on its own mini-spike (§9).
>
> **v2.1 changelog:** added the **north-star end state — Super Research as an installable native iOS app** (D5) — as a **staged delivery** (Stage 1 = host-driven proving ground = Track A as written; Stage 2 = the native `WKWebView` app) so the pipeline is proven on the mobile DOM before the app wrapper is built (§4 "Staged delivery"). Added the app's make-or-break feasibility gate to the spike (**Phase 0.E** — the embedded-WebView SSO block + `WKWebView` HV rate), a build phase (**Phase 7 — Package as an iOS app**), the app pivots (§9), and the app runtime/distribution appendix (**Appendix G**).

---

## 0.5 THE PLAN (v4 — AUTHORITATIVE). Read only this to know what we are building.

Everything from §1 onward is **reference material**: verified ground truth about the existing code, the toolchain, and the hazards. It is still accurate and still worth reading before you touch anything. But where it disagrees with this section on *what to build or in what order*, **this section wins.**

### 0.5.0 What we are building, in plain terms

**Three things, in this order: agent → emulator → app.** The first two are independent of each other; conflating them is what made earlier drafts confusing. The third depends on both.

**(1) The AGENT — a general supervisor that keeps runs alive when platforms change.**
An AI layer inside the pipeline that watches each step. When a button moves, a popup appears, a toggle silently doesn't take, or a page just isn't what we expected, it works out what to do instead of the run dying. It runs **on the Mac, inside the pipeline** — *not* inside the emulator.

> **The agent is NOT an emulator feature, and must not be built as one.** It sits above the browser, so the same agent supervises desktop Chrome today, Safari in the Simulator later, the app's WebView after that, and any other surface we add. Build it against the `BrowserBackend`/`PageShim` seam (§5) and the JS-probe + registry layer — never against a substrate-specific API. Owner, 2026-07-27: *"the agent isn't constrained to emulator and it can also be used as a supervisor in other places if needed."*
>
> **The one real nuance — portable machine, per-surface knowledge.** The agent's *machinery* (detect → diagnose → fix → record) is fully portable. Its *artifacts* are not: selectors, geometry and DOM predicates are specific to each surface, so mobile needs its own `selectors_mobile.json`. This is not a limitation to work around — it is the reason Track A comes first. **The agent is the machine that writes those mobile artifacts** (phase A2, from captured Simulator DOM), instead of anyone hand-deriving hundreds of them. Any earlier text calling the agent "substrate-agnostic" was loose: the brain is, the notes aren't.

**(2) The EMULATOR — where the browsing happens.**
Today SR drives desktop Chrome on the Mac. We add a second option: SR drives **Safari inside an iOS Simulator** on the same Mac.

> **The brain does not move into the emulator.** SR is compiled Python; Python does not run on iOS. SR stays on the Mac and reaches into the Simulator to click and read. Only the *browser* moves.

**(3) The APP — the end state, built last.** Once the agent works and the pipeline runs green against the Simulator, Super Research is packaged as an **installable native iOS app** that does the automation inside its own embedded WebView. This is genuinely a different, larger build (the Python brain cannot come with it), which is exactly why it is sequenced last and gated — see phases C0/C1 and Appendix G.

```
TODAY    SR (Mac, Python) ──drives──▶ desktop Chrome (Mac) ──▶ ChatGPT/Gemini/Claude
                ▲
                └── (1) the AGENT goes here — in the pipeline, whatever the browser

THEN     SR (Mac, Python) ──drives──▶ (2) Safari in iOS Simulator ──▶ same sites

FINALLY  (3) iOS APP ──▶ its own embedded WebView ──▶ same sites
             └── brain is rebuilt or lives on a server; it cannot come along
```

### 0.5.1 Decisions (owner-locked 2026-07-27; supersede D1–D5)

| # | Decision | Note |
|---|---|---|
| **A1** | **Substrate = iOS Simulator (Safari/WebKit)**, coexisting with desktop Chrome as a selectable backend. Desktop stays the fallback and the default. | Justified by A3 — the Simulator is the proving ground the app is built on. |
| **A2** | **Agent autonomy = STAGED.** Acts live on reversible, verifiable things (moved control, popup, toggle that didn't take). **Proposes** — never auto-applies — structural changes (flow redesign, changed parsing). Earns wider live scope per-intent as it proves out. | Full spec §0.5.9. |
| **A3** | **Native iOS app = YES, and it is the destination — but sequenced LAST.** Owner: *"We want app too. But first we need the emulator and everything working."* Build order is therefore agent → emulator → app; nothing earlier may depend on the app, and the app must not be started before Phase C0 clears. | This makes A1 coherent: the Simulator is Stage 1 (proving ground), the app is Stage 2. Carries its own hard feasibility gate — see C0 and §0.5.8. |
| **A4** | **Human Verification is no longer a driver.** Retired by the owner. Not a gate, not a success metric. Keep only a cheap regression check so a substrate switch cannot make it silently *worse*. | Kills the entire original premise of v1/v2. |
| ~~**A6**~~ | ~~**The supervisor work modifies `dg-research-backend` directly.**~~ **⛔ REVERSED by A8 on 2026-07-29 — see below. Do not implement A6.** | ~~Cost: version bump + 3-platform wheel rebuild + republish.~~ No longer incurred. |
| **A8** | **⭐ REVERSES A6. EVERYTHING lives in `dg-research-ios`. `dg-research-backend` and `dg-research` are NOT modified — at all.** Owner, 2026-07-29: *"all of it lives in dg-research-ios only… it just makes use of BE code and works together with FE just like how BE does."* This is now the **hardest constraint in the plan** and it overrides any earlier text that says otherwise. The agent wraps mutating intents **inside the iOS repo's own reimplemented P0–P3 orchestrator** (`emubackend/pipeline.py`, §4) — new code, so wrapping is a design property rather than a refactor. The BE is a **read-only dev dependency** (`-e ../dg-research-backend`, source checkout, because the wheel is compiled). | **This deletes the plan's biggest price, and MOVES its biggest risk rather than deleting it** (⚠ correcting an overclaim: predicates still never meet reality until iOS-orchestrator runs exist — the blast radius shrinks from a healthy production pipeline to the new iOS surface, which is the actual win). Gone: the ~1–2 week 30–60-site `research.py` refactor (§0.5.6 price 1), its "needs explicit sign-off", 30–60 never-tested predicates pointed at a healthy production page, the version bump, the mac/Windows/Linux wheel rebuilds, the republish, and the signed org BE PR for Track A. Track A's release overhead becomes **zero**. **Accepted cost:** the desktop-Chrome pipeline in production gains no new supervisor — it keeps its existing CUA + selfheal, unchanged and unregressed. Revisit putting the agent in the BE later, on its own merits, with A0's data in hand. **A5 is moot** (it approved the BE wrapping pass, which no longer exists). |
| **A9** | **BUILD ORDER REVISED: emulator first, agent later.** A8 invalidated both reasons the agent was sequenced first — under A8 it ships no live value on today's desktop product (healing capped at one intent), and its selector generator cannot precede the Simulator DOM it learns from. New order: **C0-FE → B0a → B1 (seam + vendored contract) → agent**. | A0 arming still happens NOW — free, run-volume-bound, and it tells us which failure classes to design predicates for. |
| **A10** | **DEVICE IDENTITY: the iOS pipeline gets its own state dir and its own paired device.** Vendor `auth/` into `dg-research-ios` with the three hardcoded path constants parameterized. | ⚠ `DG_RUNTIME_DIR` DOES NOT EXIST in the code — the state dir is hardcoded `~/.super-research`. Without this, `--pair` overwrites the production daemon's identity, or the iOS pipeline authenticates as the SAME deviceId and races it on one queue. This is the finding that would otherwise dead-end the first queue-triggered e2e. |
| **A7** | **This initiative starts AFTER the current product queue.** Order: (1) the app-update hang + the other issue MDs, (2) publish + a NEW org BE PR for those fixes, FE folded into the existing PR, Windows/Linux builds on the Windows box, (3) *then* Track A. | ⚠ **Exception — A0 observation is armed NOW, not at (3).** See §0.5.10. |
| ~~**A5**~~ | ⛔ **MOOT — struck by A8 (2026-07-29).** A5 approved the BE intent-wrapping pass in full, up front. That pass no longer exists: under A8 nothing in `research.py` is wrapped. The coverage-before-evidence trade it accepted is therefore void too — see the rewritten A1 row. | — |

### 0.5.2 What already exists — do not rebuild it

Verified in code 2026-07-27. The agent is **half-built and switched off**:

| Component | Reality | Default |
|---|---|---|
| `vision.py` (1,339 ln) | Claude-driven actor. `_PROPOSE_ACTION_TOOL` schema, `execute_action(page,…)`, Sonnet/Opus cost tables, `ACT_MAX_STEPS=8`, `CALL_BUDGET=50`, `ACT_REPEAT_LIMIT=3`, confidence floor 0.6. Staged modes `off→shadow→tier2→tier3`. | **`off`** — its docstring calls tier2 *"the ONE switch that arms the acting path."* Never flipped. |
| CUA | The incumbent escalator, **and the only supervision actually running today** — verified live in `backend.log` (131 hits; e.g. *"Uploading claude.md via CUA fallback"*, *"CUA will open customize itself (fail-open)"*). ~43 dispatch hotspots, 307 refs. | **ON, doing real work** |
| `selfheal.py` (1,186 ln) | Heuristic, zero LLM. Accessibility probe → durable-signal ranking (never CSS class) → confirmed-opposite toggle guard → verify-before-trust → registry with evict-3/promote-3. `promotion_candidates()` already anticipates human-gated promotion. | shadow; **1 of 6** intents acts |

**Verified against the live daemon (PID 1817, 2026-07-27): no `DG_SELFHEAL_*`, no `DG_VISION_TIER`, no `DG_CUA` variables are set in the running process.** So the defaults above are what is actually in force. In plain terms: **the oldest and least instrumented of the three supervisors is the one carrying production**, while the newer Claude-driven one with cost budgets, confidence thresholds and a staged rollout has never been invoked, and the cheap deterministic selector-repair layer is fully inert.

**Implication:** Track A is *consolidate and complete*, not *build from scratch*. Three overlapping ladders become one escalation order. **Do not write a fourth agent.**

> **⚠ CONSEQUENCE FOR A0 — there is no data to mine.** `DG_SELFHEAL_ENABLED` defaults OFF and its docstring is explicit: *"OFF ⇒ the whole subsystem is inert."* Confirmed on disk — `~/.super-research/logs/` contains **no** `selfheal_shadow.jsonl`, no capture snapshots, no vision shadow records. A0 as originally written ("mine the existing shadow logs, ~1 week") **cannot run.** It is re-specced below.

### 0.5.3 ⭐ The keystone: fixes ship as DATA, not as a release

`selfheal.py::load_intents()` **prefers** an external `selfheal_intents.json` (or `DG_SELFHEAL_INTENTS`) over the compiled `_INTENTS` baseline, with safe fallback when missing or corrupt. `selfheal.py` itself ships as **source**, not Nuitka-compiled.

So a platform-change fix is a **JSON patch** — no version bump, no mac wheel rebuild, no Windows/Linux builds, no 3-platform republish. Iteration cost is the dominant tax on this codebase; this route avoids it.

**This selects the architecture.** Prefer any design where the agent's output is a data patch over one where it is a code change. Extend the manifest schema from bare selectors to small **declarative action-plans** (open menu → submenu → toggle), interpreted in `selfheal.py`, so *flow* fixes also ship as data.

### 0.5.4 ⚠ The dominant failure class is READ DRIFT, not failed clicks

The reference case is our own **P1 raw-activity incident**: the panel opened, steps parsed, **every click landed, every state change occurred** — and source extraction returned **0 for an entire run**, because the Pro+ET panel renders sources as non-`<a href>`. The run "succeeded" and harvested nothing.

A step-scoped, selector-promoting design is structurally blind to this: nothing failed, there is no crisp predicate for *"these are the right sources,"* and there is nothing to promote because the fix is a new **parse**, not a new selector.

**Requirement:** extraction/parse correctness is a first-class target alongside action success. Use **harvest-shaped predicates** — count, shape and type of extracted items compared against the run's own history — not just "non-empty". An architecture that only heals clicks covers roughly half the outage surface.

### 0.5.5 What no agent can fix — so ROI is not over-promised

Quota exhaustion, auth/session expiry, product rate limits. These are a large slice of real incidents and **no agent architecture repairs them.** They need clean detection and hand-off to the human. Do not let the initiative be sold on them.

### 0.5.6 The three honest prices — accept these before Phase A1

1. ~~**There is no clean agent seam, and one is not free.**~~ **⛔ NO LONGER A PRICE — deleted by A8 (2026-07-29).** The original text is preserved below for context, but **do not do this work.** Under A8 the agent lives in the iOS repo's own reimplemented orchestrator, where mutating intents are written wrapped from the start — so there is no refactor of `research.py`, no sign-off needed, and none of the false-positive risk that came from pointing 30–60 untested predicates at a healthy production pipeline. What remains true and still shapes the iOS orchestrator's design: only *mutating* interactions (clicks, fills, keypresses) need intent-wrapping — reads do not — and `research.py::_selfheal_try` is the pattern to copy.
   > *Superseded original:* "112 functions take a raw `page`; ~222 `page.evaluate` calls are scattered through the pipeline. Minimum viable refactor: enumerate the ~30–60 semantic intents across P0–P3 and wrap those call sites… Mechanical, grep-driven, ~1–2 weeks. **Needs explicit sign-off.**"
2. **Invariants rot exactly like selectors — still the plan's biggest risk, now relocated to the iOS surface (A8).** `placeholder == "What do you want to research?"` dies on a copy change. A rotted predicate raises a *false* failure, which sends an agent to "fix" a **healthy** page — worse than the crash it replaced. Under A8 these predicates live in `emubackend/pipeline.py`, so the blast radius is the new iOS pipeline rather than the production desktop one — a real reduction, but the predicates are still written before they meet reality, and they can only bake on iOS-orchestrator runs that do not exist until B1. **Mandatory, non-negotiable: a predicate bakes in shadow — zero false positives across ≥20 real runs in which that intent actually executed — before it may ever trigger escalation. Per predicate, not in a batch.** An unbaked predicate that stays unbaked forever is a fine outcome — it still earns its keep as telemetry.

⚠ **Measured 2026-07-29, and it changes what these gates mean: `queues/` holds 3 run directories, all inside the last 7 days. The real rate is ~1-3 runs/week** (3 dirs in the last week, two of them 6-minute runs — state it as a range, not a point). This gate was originally written as "≥2 weeks of real runs", which at the actual rate is **two runs** — noise, not a bake, and it would hand out false confidence across 30–60 predicates independently. Hence the restatement in **runs, not weeks**: weeks silently means whatever the run rate happens to be, and nobody re-checks the rate. The same correction applies to A0's counts. Three honest consequences: (1) A3 is not reachable on the current run volume within any near timeframe; (2) if A3 is genuinely wanted, run volume has to be **manufactured** — a nightly scheduled run on fixed topics is the only lever, and it costs platform quota plus API spend, not effort; (3) absent that, **A2 is Track A's realistic destination**, which §0.5.8 already names as an acceptable and valuable outcome — it stops being a fallback and becomes the expected result. Do not restate either gate in wall-clock time again.
3. **iOS Simulator is macOS-only.** This backend cannot run on the Windows research computer. Desktop Chrome remains the only cross-platform path, which is another reason it stays the default (A1).

### 0.5.7 Build order

⚠ **BUILD ORDER REVISED 2026-07-29 (decision A9) — EMULATOR FIRST, AGENT LATER. The "Track A runs first" argument below is retained only to show why it no longer holds.**

**Why it collapsed.** Track A was sequenced first on two claims, and A8 invalidated both. (1) *"It ships value on the product you have today"* — under A8 it cannot: live healing in the BE is hardcoded to one intent, A2 can only refine the 6 intents the BE already consults, and nothing new can be wrapped without editing `research.py`. (2) *"It is how the mobile port gets cheap"* — the offline agent generates `selectors_mobile.json` **from captured Simulator DOM**, which does not exist until Track B runs. The generator cannot precede its own input. On top of that, A1's predicates can only bake on iOS-orchestrator runs, so building them before B1 produces predicates with no path to verification.

**The revised order:** **C0-FE → B0a → B1 (seam + vendored contract layer) → then the agent**, once there is an iOS orchestrator for its predicates to bake against and captured mobile DOM for A2 to learn from. **A0 arming still happens now** — it is free, it is run-volume-bound, and its failure taxonomy tells us which classes to design predicates for.

> *Superseded rationale (kept for the record):* "Track A runs first — including for iOS's own benefit. Beyond shipping value on the product you have today, the agent is how the mobile port gets cheap… Track A is the machine that builds Track B's inputs. It also de-risks: if iOS fails its gate, you still have the agent." The de-risking half is still true; the other two claims are not.

⚠ **LABEL COLLISION — read this before using either table.** The decisions table above and the phase table below both use `A<n>` labels, and they mean different things. **Decision A1** = iOS Simulator as the substrate; **Phase A1** = the intent-wrapping work. **Decision A2** = staged agent autonomy; **Phase A2** = the offline repair agent. **Decision A3** = the app is sequenced last; **Phase A3** = live staged escalation. Where this document says "per decision A3" it means app-last; "phase A3" means live escalation. Disambiguate before acting on either.

| Phase | What | Ships value? | Gate to pass |
|---|---|---|---|
| **A0** | **Arm observation, then measure** — re-specced, and it is now the **critical path**. There are no shadow logs to mine (see §0.5.2), so A0 is two steps: **(i)** turn on observation — `DG_SELFHEAL_ENABLED=1` + `DG_SELFHEAL_CAPTURE=1` (both observe-only; `DG_SELFHEAL_ACT` stays OFF) **with both log paths set explicitly (§0.5.10 — they default to CWD-relative `logs/`)**; `DG_VISION_TIER=shadow` is held back on cost grounds. Plus parse the CUA-fallback lines already in `backend.log`, which are the one existing signal; **(ii)** let real runs accumulate, then build the **failure taxonomy with counts**: moved-control vs read/parse drift vs flow change vs mid-wait interrupt vs quota/auth vs infra. Elapsed time is dominated by run volume, not effort — **start it on day one, before anything else.** | baseline | ⚠ **A9 reordered this: the agent now comes AFTER the emulator, so A0 no longer runs alongside A1 — it runs alongside C0-FE/B0a/B1 and feeds the agent when the agent starts.** A0 is still required, and has two jobs: it sets the **live-enablement order for A3** (turn on the intents that actually break, first), and it is the only honest measure of how often anything breaks, since no e2e test exists. **It still gates A3.** |
| **A1** | ⚠ **REWRITTEN FOR A8 — this row previously instructed the `research.py` refactor A8 forbids. Do not do that.** Instead: **write the iOS orchestrator's mutating intents already wrapped.** In `emubackend/pipeline.py`, every mutating interaction (click, fill, keypress) goes through a `_selfheal_try`-shaped wrapper from the moment it is written, each with an `outcome_predicate`. Copy the *pattern* from `research.py::_selfheal_try`; edit nothing there. Add network-level predicates beside DOM ones (§0.5.9), harvest-shaped predicates (§0.5.4), and the mid-wait sentinel (§0.5.9). **Nothing acts with flags off, and the iOS repo's own suites must prove the wrapper is a no-op.** | telemetry | **PER-PREDICATE gate.** A predicate is "baked" only after **≥20 runs in which that intent actually executed, with zero false positives** (runs, never wall-clock — §0.5.6(2)). ⚠ **Those runs are iOS-orchestrator runs.** Production desktop runs never execute `emubackend/pipeline.py`, so they contribute **zero** bake volume — baking cannot begin until B1 exists. Unbaked predicates may log, never escalate. A predicate that fires on a healthy page is reverted or rewritten, never tuned in place. |
| **A2** | **Offline repair agent.** Consumes shadow logs + captured DOM from failed runs; emits **human-gated patches**. ⚠ **Targets under A8:** `selectors_mobile.json` and the iOS repo's own intent registry — **not** a PR against the BE's `selfheal_intents.json`, which would touch `dg-research-backend`. The one A8-legal way to influence the live BE is pointing `DG_SELFHEAL_INTENTS` (`selfheal.py:126–131`, external manifest preferred over compiled `_INTENTS`) at a file the iOS repo owns — but note the ceiling: the BE only *consults* selfheal at its **6 wired intents**, so an external manifest can refine those and cannot add coverage the BE never calls. | ✅ yes | A proposed patch fixes a real historical breakage when replayed. |
| **A3** | **Live staged escalation, on the iOS surface.** Wire the *existing* `vision.py`/CUA as the escalator by **importing** it (do not build another, do not edit it). Enable one intent at a time in `emubackend/pipeline.py`, reversible + crisp-predicate first. Flow-scoped, failure budget, circuit breaker, full audit. ⚠ **On the desktop BE, live healing is permanently capped at ONE intent under A8** — `gemini.enable_deep_research` (`research.py:34044–34050`) is the only site behind `selfheal.act_enabled()`; every other site is shadow-observe only, and adding one means editing `research.py`. | ✅ yes | Per-intent, **all three**: (a) predicate baked per A1 (on iOS runs); (b) A0 shows it breaks often enough to justify the risk; (c) the action is reversible and verifiable. Failing (a) means shadow-only indefinitely — a valid resting state. |
| **B0** | ✅ **B0a PASSED 2026-07-29 — see §0.5.7c for the results and the four device behaviours it surfaced. B0b (owner-present) is still outstanding.** **iOS spike — GO/NO-GO** (§6 Phase 0, minus the HV gate). Split at the credential boundary: **B0a** (no credentials, fully automatable) proves trusted taps land in an iOS-26 Simulator's real MobileSafari, DOM reads round-trip, and a cookie survives a Simulator reboot. **B0b** (needs the owner) proves a login-gated action runs end-to-end and **comes back logged in after a reboot**. ⚠ **B0a must assert a tap on a SCROLLED page and with the keyboard open** — the coordinate mapping goes through Safari chrome offsets, URL-bar collapse/expansion, `visualViewport` scroll/zoom offsets and keyboard insets, so a toy-page-only assertion passes B0 and then dies in P2. ⚠ Bound the effort: if trusted taps cannot be produced after a bounded number of approaches, **stop and report** — a fast "this substrate does not work" is a good outcome and saves the whole Track B budget. | — | **Hard gate.** Any failure → iOS is out; desktop/Android pivot (§9). |
| **B1–B3** | ✅ **B1's SEAM IS BUILT AND PROVEN ON DEVICE (2026-07-29)** — `dg-research-ios/emubackend/substrate/`: injectable `window.__sr` runtime (handle registry + calibration overlay that works on any page + `isTrusted` recorder), `BrowserBackend`/`IOSSimulatorBackend`, `PageShim`/`ElementHandleShim`; `bin/b1_smoke.py` passes **16/16** against a real Simulator. ⚠ **A 5th device trap surfaced here, with no desktop analogue: IWDP reads a BACKGROUND tab fine, but AXe taps only reach the FOREGROUND one** — so a tap computed from a background tab lands on different content *and reports success*. Every input path now asserts foreground first, and the consequence for the P2 tab model is concrete: **one Simulator per platform, or strictly sequential single-tab** (`switch_to`/`open_isolated_tab` are `BackendUnsupported` — MobileSafari's tab switcher is UI-only). ⚠ **`upload` is `BackendUnsupported`**: there is no `DOM.setFileInputFiles` equivalent over IWDP and a real `<input type=file>` tap opens the native document picker ⇒ **NotebookLM source upload must run on the desktop backend**, which is exactly what coexistence is for. **STILL OWED for B1:** the vendored `emubackend/contract/` layer (~1.5–3k lines, ONE cohesive copy — never N one-off helpers), `auth/` vendored with its three hardcoded path constants parameterized (A10), and the golden-fixture capture harness (§0.5.7b — start early, fixtures accrue at 1–3 runs/week). The spec for all three is already written: `dg-research-ios/docs/FIRESTORE_CONTRACT.md` (1,677 lines, 40 traps, 13 honest unknowns). Then B2–B3: port P0–P3 behind the seam → mobile selector manifest, largely **generated by A2**. | — | Full pipeline green on the Simulator. |
| **B4** | Coexistence hardening: desktop stays default + fallback; per-worker Simulator; `DG_BROWSER_BACKEND` switch. | ✅ yes | Desktop path provably unaffected. |
| **C0** | ✅ **THE IN-APP AUTOMATION CHANNEL IS PROVEN, 11/11, IN A REAL NATIVE APP IN THE SIMULATOR (2026-07-29)** — `bin/c0_in_app.sh` + `ios/AppHarness/`, verdict at `artifacts/apphost/verdict.json`. ⚠ **And the app target needed NO Apple Developer account**: Simulator builds are unsigned, so ad-hoc `codesign -s -` suffices and the whole gate is reachable without any owner-gated credential. The developer account is only for a **real device** (C1). Built by hand with `swiftc -sdk iphonesimulator` + a written `Info.plist` — no `.xcodeproj` required. **⭐ THE MEASUREMENT C0 EXISTS FOR: `isTrusted === false` for a JS-dispatched click inside `WKWebView`** — so the constraint does **NOT** relax in your own web view. Any control a chat SPA gates on trust needs a genuine input path in the app; a synthetic click presents as *a phase that mysteriously never advances*. Plan C1 around that, not around hoping. Also proven in-app: the **same injected runtime** works (`evaluateJavaScript` really is `Runtime.evaluate`), re-injection is idempotent, the **handle registry survives across separate calls**, the **execCommand path** is what enables a model-gated send, and non-anchor sources harvest (the P1 shape). ⚠ **`readyState === 'complete'` is NOT a load signal** — `about:blank` reports it immediately, so polling it alone runs everything against the blank document: the runtime injects "successfully", re-injection says "already", the viewport looks plausible (the web view's own frame) and every selector finds nothing. Assert the **URL and a content marker** too. (Cost a real debugging cycle here; do not repeat it.) ⚠ Note the earlier finding still holds and is why the app harness exists: `WKWebView` will not instantiate under `swift test` — no app bundle, no WebProcess host, `InvalidTransition` before any page loads. **The gate needs an app, not a package test.** ⚠ ~~SCHEDULING FACT: C0 needs a REAL APP TARGET (an Xcode project or an XCUITest host) — it cannot be a SwiftPM test.~~ *(Superseded: an app target was built autonomously; see above.)* `WKWebView` will not instantiate under `swift test`: there is no app bundle and no WebProcess host, and it fails with `InvalidTransition` before any page loads. Planning C0 as "add a test to the package" does not work, so budget the app-target setup as part of the gate rather than discovering it at the gate. The automation bridge itself is written and **compiles** (`ios/Sources/SuperResearchDeviceCore/WebAutomation.swift`), and it reuses the **same injected runtime already proven against a real Simulator** through IWDP — `WKWebView.evaluateJavaScript` *is* `Runtime.evaluate`, so the handle registry and calibration surface carry over unchanged; only the ~40 lines of plumbing are unexercised. It ships `probeTrustedDispatch()` so C0 answers the `isTrusted`-in-WKWebView question **by measurement** rather than by assumption — ⚠ the constraint does not disappear in your own web view, and a synthetic click the SPAs reject is the failure mode that looks like a phase mysteriously never advancing. **App feasibility gate — GO/NO-GO** (the retained §6 Phase 0.E). Per platform, inside a bare `WKWebView`: can you actually **sign in**, and is the bot reputation tolerable? Google blocks OAuth in embedded WebViews (`disallowed_useragent`), so Gemini/NotebookLM login is the likely casualty. | — | **Hard gate.** Platforms that fail login in `WKWebView` do not ship in the app — they stay on the host-driven backend or are marked desktop-only. If *all* fail, the app becomes a thin client (Appendix G / G3) or is dropped. |
| **C0-FE** ⬅ **RUN THIS FIRST** | **FE-parity gate — GO/NO-GO. Owner requirement, 2026-07-29: "this must give a QR or pair code just like the BE, and a research fired from the web app or the agent must work the same."** Bare SwiftUI + Firebase Apple SDK, **no browser and no automation**. Verified feasible: the rules admit a custom-token client end-to-end — no `serverTimestamp` sentinels, no Admin-SDK-only writes in the device path, no client-side collection-group queries, and the queued→ongoing flip is an ordinary transaction the Apple SDK supports. Steps: **(a)** POST `/api/devices/initiate-pair` — ⚠ **the SERVER mints the pair code and creates the device doc; the device does NOT generate either** (client create on the device doc is `allow create: if false`). The device generates only a 256-bit pollSecret and sends its SHA-256, then displays the returned code — hyphenation (`format_for_display`) and the QR render are the only device-side pairing logic. **(b)** poll `pending/{secretHash}` (`allow get: if true`, which is what makes the pre-auth poll legal) and exchange the custom token via `Auth.signIn(withCustomToken:)`. **(c)** ⚠ **ATOMIC PAIR-CONFIRM — the step whose absence fails silently.** The claim route sets `expireAt: now+5min` under a Firestore TTL; the device must write the field-locked update `{pairConfirmedAt, expireAt: FieldValue.delete(), lastHeartbeat, status, …}` — touching **only** the `hasOnly()`-listed fields — **within 5 minutes**, or the device doc is deleted and the FE never shows it. Without this the gate appears to pass and then mysteriously vanishes. **(d)** hold a snapshot listener on `devices/{deviceId}/queue`. **(e)** write `pipeline_events` in the BE's exact shape: numeric `seq`, `timestamp`, payload `deviceId`, ms-ints throughout. | — | **Hard gate.** Pass criteria include **the FE Account page showing the device Online** — not just local success. Pass ⇒ C1 can be a real device (G1/G2). Fail ⇒ C1 is a thin client (G3) and the Mac stays the paired device. Either way the FE is **not** forked. **Run first:** cheapest gate in the plan (days, pure Firebase, no toolchain), its failure reshapes the end state, and it doubles as executable documentation of the exact contract Track B's orchestrator must reimplement. |
| **C1** | **Native iOS app** (retained §6 Phase 7). SwiftUI shell, one `WKWebView` per platform with a persistent `WKWebsiteDataStore`, `evaluateJavaScript` as the automation channel. **Wraps Stage 1 — does not re-derive it:** the mobile selector manifest, ported P0–P3 flows and the agent all carry over, because `WKWebView.evaluateJavaScript` is the same JS-eval channel as IWDP `Runtime.evaluate`. Pick the orchestration runtime per Appendix G (G1 Swift rewrite / G2 embedded Python / G3 thin client). Distribution is TestFlight / ad-hoc / enterprise — **public App Store review will very likely reject an automation app.** | ✅ the destination | A full P0–P3 run completes inside the app for every platform that passed C0. |

**⛔ THE ISOLATION RULE (A8, 2026-07-29) — read before writing any code.** `dg-research-backend` and `dg-research` are **not modified by this initiative**. Not a line. Three consequences that will each come up in practice:

* **A1 is no longer a refactor.** It is "write the iOS orchestrator's mutating intents already wrapped, each with an `outcome_predicate`." Same pattern (`_selfheal_try`), same predicate design, same shadow-first discipline — but applied to new code as it is written, not retrofitted into a 54k-line monolith. There is no BE edit and therefore no wheel/publish/org-PR consequence anywhere in Track A.
* **⚠ §4's "reuse the browser-independent leaf helpers by importing them" is MOSTLY FICTION — verified 2026-07-29.** `import research` itself is clean and safe (0.4s, `__main__`-guarded at 54720, patchright lazy inside `Browser.start`, `google.cloud` imports function-local, module level is constants/env/regex only — no threads, no Firestore, no mkdirs). But of the helpers §4 names, only **`ALERT_INTENTS`** (a plain 16-key dict), **`auth/`**, `narrate.py` and `selfheal.py` are genuinely importable. `_update_firestore_research` (8201), the `pipeline_events` writer `_emit_to_firestore` (8079), `emit_event` (13660), `_persist_pending_decision` (8236), `upload_audio_to_storage` (6336) and `_post_fe_p4p5_trigger` (8469) are all welded to module globals (`_fb_uid`, `_fb_research_id`, `_firebase_db`, `_fb_seq`, `_tracks_dir`, `_runtime`, `_controls`) that only `setup_firestore_run` (7753) arms — and **that function writes `owner.json` into `Path(__file__).parent/"queues"/<run_id>`, i.e. inside the "read-only" BE checkout, where the production daemon's disk-restore scans.** Calling it would contaminate the running product, not merely be fragile.
  **So: VENDOR, as ONE cohesive layer — `emubackend/contract.py`.** The Firestore-contract client (`_update_research_doc`/`_set_research_doc`, `_be_payload`, `_grpc_write_with_heal` and its 403-heal, the event writer plus its seq guard, the pendingDecision lifecycle, the heartbeat) is ~1.5–3k lines of coherent, rarely-changing code whose drift target is the **FE contract**, which changes visibly. Copy it once, with source-anchor comments. **Do not** copy helpers one-off as needs arise — that is how a vendored layer becomes an unmaintainable fork. Rejected alternative, recorded deliberately: import `research` as a library and monkeypatch `research.Browser` (Python resolves module globals at call time, so intra-module call sites would pick up the patch) — maximal reuse of battle-tested orchestration and zero BE edits, but it breaks silently on every BE update and still collides on shared state.
* **⚠ Namespace hazard — MEASURED 2026-07-29, and it is wider than stated here.** Putting the BE checkout on `sys.path` claims **nine** module/package names: `research, models, prompts, vision, `**`vision_test`**`, narrate, selfheal, auth, scripts`. It *also* contains plain directories with no `__init__.py` — `tests`, `tools`, `agent`, plus `build` and `dist` — and Python 3 merges same-named plain directories across `sys.path` entries into a single **implicit namespace package**, so reusing any of those names is unsafe too, in a quieter way. `build` is a live foot-gun rather than a technicality: the BE's `build/` holds a **complete copy of the sources** (`build/lib/research.py`, …), so `import build` resolves, and any packaging run in `dg-research-ios` would create a second one. **Resolution taken: everything the iOS repo owns lives under the single `emubackend` package, tests included** (`emubackend/tests/`), so the collision is impossible by construction rather than avoided by vigilance. Shell entry points go in a non-importable `bin/`.
* **⚠ DO NOT `pip install -e ../dg-research-backend` — it violates A8, invisibly.** The recipe specifies the BE as an editable dev dependency, but the BE's `[build-system]` is `setuptools.build_meta`, so `pip install -e` **executes that build backend inside the BE checkout** and regenerates `superresearch.egg-info/` there — writing into the very checkout the production `--serve` daemon runs from. The BE's `.gitignore` covers `*.egg-info/`, `build/` and `dist/`, so the write is **hidden from `git status`** rather than harmless. **Use a read-only `sys.path` append instead** (`emubackend/berepo.py`), which reaches an identical importable surface with zero writes. Verified cheap: walking `research.py`'s `ast.Module.body` shows its only non-stdlib **module-level** imports are `models` and `prompts`, both BE-local — so `import research` needs **no third-party dependency at all**. (A grep would answer this wrongly by also matching function-local imports, which is precisely why the import is fast.) A8 compliance is now enforced by `emubackend/purity.py`, which content-digests those three ignored directories rather than trusting git.
* **⚠ A10 — DEVICE IDENTITY: the iOS pipeline gets its OWN state dir and its OWN paired device (owner decision, 2026-07-29).** This is the issue that would otherwise dead-end the first queue-triggered e2e with nothing in the plan to catch it. **`DG_RUNTIME_DIR` does not exist in the code** — grep finds nothing; the state dir is hardcoded (`_STATE_DIR = Path.home()/".super-research"` at `research.py:4046`, plus `auth/keystore.py:43` and the `install_uuid` at `keystore.py:278`). So Appendix E's "register the harness with `superresearch --pair`" would mint a pairing **into the production daemon's own keystore, replacing its device identity**; and reusing `init_firebase()` (3697) makes the iOS pipeline authenticate as the **same deviceId** — two processes listening on one `devices/{id}/queue`, where the BE's claim coordination is a file-based worker-sentinel protocol (`research.py:263–295`) the iOS repo does not participate in ⇒ double-claim races, and every iOS write attributed to the production Mac device in the web app. **Chosen fix: vendor `auth/` into `dg-research-ios` with the three path constants parameterized**, so the iOS pipeline is a genuine second paired device. Consistent with the vendored contract layer above, no BE edits, and it makes the second device first-class rather than a hack. Correct Appendix E's `DG_RUNTIME_DIR` claim.
* **Arming A0 is CONFIG, not code.** The Day One flags (§0.5.10) are supervisor-env changes to the running BE, observe-only, no source edit — so they do not violate A8. A0's failure taxonomy still earns its place: the classes it measures (moved control, read drift, flow change, mid-wait interrupt, quota/auth) are **platform-side**, so they transfer to the mobile surface. But its role changes: it is now **input to the iOS orchestrator's predicate design**, not a gate on live enablement of BE intents. It no longer gates anything in the BE, because nothing in the BE is being changed.

**Also true under A8:** the desktop-Chrome pipeline keeps its existing CUA + selfheal exactly as they are. Nothing is removed and nothing regresses — it simply does not gain the new supervisor. That was the accepted cost.

**⚠ A1 is NOT gated by the release — correcting a claim made and withdrawn on 2026-07-29.** It was briefly asserted here that A1's ~30–60 `research.py` edits "collide" with the pending wheel rebuild / publish / org push. **They do not.** Commits are immutable snapshots, so later work on master cannot retroactively change what a wheel was built from; the org PR content is already frozen as cherry-picked commits in its own worktree; and publish consumes a pinned artifact. A7's "Track A after the publish cycle" was a **priority** decision about shipping product fixes first — never a technical dependency, and it is the owner's to revise.

The one real constraint is narrower and is about the **e2e**, not publish: the daemon runs from the **source checkout**, so whatever sits in the working tree is what gets loaded at the next restart — and the pre-e2e restart is precisely that moment. If A1's edits are on master then, the e2e exercises the refactor instead of the release candidate. **Fix: do A1 on a feature branch.** Master stays the release candidate, the daemon keeps running it, the e2e stays clean, and A1 proceeds fully in parallel. No waiting required.

**⚠ FE parity is a first-class requirement, not a nice-to-have (owner, 2026-07-29).** Super Research must remain one product to the user: the same pairing (QR / pair code), and a research fired from the web app *or* the chat agent behaving identically whatever the substrate. Two consequences, and they pull in opposite directions:

* **Stage 1 (emulator) gets this for free — no work at all.** The Mac still runs the BE and is still the paired device; the Simulator is only a different browser behind the `BrowserBackend` seam. Pairing, the queue trigger, `pipeline_events`, the FE contract: all untouched. Do not budget anything for it here, and do not let the requirement inflate Track B.
* **Stage 2 (the app) is where it becomes real work, and it is now gated** — see **C0-FE** above. When the app is the device, it has to do what the BE does today: generate and show a pair code, be claimed by the FE, exchange a custom token, register a device doc, listen on its queue, and report progress in the same schema. `auth/pairing.py`'s code alphabet and `format_for_display` are pure logic that must be reimplemented in Swift (or reused via G2) — the FE's claim endpoint is the fixed counterpart and does not change.

Grounds for optimism, worth stating because it is the load-bearing unknown: the Firebase Apple SDK supports custom-token sign-in and Firestore snapshot listeners as first-class features, so the *contract* half of C1 is genuinely portable. The hard part of C1 was never Firestore — it is the browser automation and the fact that the compiled-Python brain cannot run on iOS. C0-FE exists to confirm that split cheaply, before any app work is committed.

**Parallelism (restated for A9 + C0-FE, 2026-07-29):** run **C0-FE first** — cheapest gate, pure Firebase, no toolchain, and its failure reshapes the end state. **B0a** (substrate mechanics: trusted taps, DOM reads, cookie survives a Simulator reboot) runs in parallel with it; both are credential-free and machine-verifiable. **A0 arming happens now regardless** — it is config, it is free, and its clock is run-volume-bound, so every day unarmed is a day lost. **B1** (the seam plus the vendored `contract.py`) follows the two gates, and **the agent (A1/A2/A3) follows B1**, because its predicates can only bake on iOS-orchestrator runs and A2 can only generate `selectors_mobile.json` from captured Simulator DOM. **B0b, C0 and the FE claim round-trip need the owner present** (real accounts, 2FA, and observing whether login survives a reboot). **C1 must not start until B1–B4 are green**, per owner decision A3.

> **The app's three standing constraints** (not blockers, but design inputs, and none are solvable by effort): Google blocks OAuth inside embedded WebViews; iOS background-execution limits mean an app cannot run an unattended 90-minute pipeline the way a desktop daemon does (keep it foreground during a run, or push the long-running brain to a companion service); and the compiled-Python brain cannot run on iOS at all, so C1 always means either rebuilding the orchestration or making the app a client of it.

### 0.5.7b ⚠ MEASURED SCOPE of "reimplement P0-P3 orchestration" (2026-07-29) - and how to buy convergence

Do not treat this as a bounded task on the strength of the phrase. Measured against today's `research.py` (54,733 lines):

* **135 functions take `page`/`browser` = 24,764 lines.** This is the fork-and-rewrite-for-mobile layer, and it was always the port's price regardless of A8.
* The layer **A8 newly converts from "reuse" to "reimplement"** is the orchestration: `run_pipeline` 3,529 + `start_firestore_start_listener` 1,291 + `_start_device_command_listener` 751 + `_start_command_listener` 540 + `PipelineControls` 783 + the `emit_event`/pendingDecision/auto-skip seam ~600 + Phoenix rehydrate/enqueue ~600 + heartbeat/queue-ETA/claim ~1k, plus `run_server` (2,367) if any HTTP surface is kept -> **~9-11k lines of contract semantics.** `poll_all_agents_round_robin` (3,389) is a mixed browser/decision loop whose P2 alert/retry/skip/pause *control flow* must be mirrored too.
* The honest label: **a second backend implementing the same Firestore contract**, reusing only `selfheal`/`auth`/`narrate`/constants.

**What makes this expensive is not the line count** - it is that those 9-11k lines re-derive behaviours that took months of production fixes: pause/resume invariants, pendingDecision clobber rules, seq-cursor semantics, multi-worker claim races.

**⭐ Buy convergence with record/replay golden fixtures.** Before writing `emubackend/pipeline.py`, build a harness that captures real BE runs' **Firestore write sequences** as golden fixtures, then assert the new orchestrator reproduces them. **Start capturing now** - at 1-3 runs/week, fixture material accrues slowly, and this is the only mechanical check that the second backend is contract-faithful. It is also the closest thing to the e2e that does not exist.

### 0.5.7c ✅ B0a RESULT — **PASS, all four cases** (2026-07-29). The hard gate is cleared.

Run by `dg-research-ios/bin/b0a_gate.py`; verdict recorded at `dg-research-ios/artifacts/b0a/verdict.json`.
Environment: iPhone 17 Pro · iOS 26.5 · Xcode 26.6 · IWDP **1.9.2** · AXe **1.8.0** · screen **402×874pt**.

| Case | Result |
|---|---|
| **A** trusted tap, plain page | **PASS** — `isTrusted === true`, hit the intended element, top chrome measured **62pt** |
| **B** trusted tap, **scrolled** page | **PASS** — scrolled to y≈1740; `innerHeight` 714→**754**. ⚠ Note *which* chrome moved: iOS 26 collapses the **bottom** toolbar, not the top (top stayed 62pt). Assuming it was the URL bar would have produced a correct-looking but wrong model. |
| **C** trusted tap, **keyboard open** | **PASS** — keyboard raised by a *trusted* tap (a JS `.focus()` does not raise it), `visualViewport.height` 714→**377** |
| **D** cookie survives `simctl` reboot | **PASS** — reached `Cookies.binarycookies` in **3s**, still present after shutdown/boot |

**⇒ The §0.5.8 kill criterion "B0a fails → the iOS Simulator path is dead" does not fire.** Trusted input lands, the DOM channel round-trips, and state survives a reboot. Track B continues.

**Four device behaviours found, each now a guard in `emubackend/substrate/`** — all four are silent-failure modes, which is why they belong in the recipe rather than in a commit message:

1. **IWDP does not auto-discover the Simulator** (corrects Appendix F, see there).
2. **WebKit multiplexes the inspector behind the `Target` domain** (corrects Appendix F, see there).
3. **⚠ A tap is a *sequence*, and its `click` is late enough to be misattributed.** MobileSafari emits `pointerdown` → `touchstart` → `click`, and tap *N*'s `click` can land in the event list **ahead of** tap *N+1*'s own `pointerdown`, carrying **integer-rounded** coordinates. Taking "the first trusted event with coordinates" therefore silently returns the *previous* tap's position — observed as a derived scale of **241 instead of 1**, an error nowhere near its cause. Defences: filter the positioning event to `pointerdown`/`touchstart`, wait for the tap's own terminal `click`, and drain stragglers before arming.
4. **⚠ The keyboard shrinks `visualViewport.height`, not `window.innerHeight`.** Measured: 714→377 with `innerHeight` unchanged at 714 and `vvOffsetTop` still 0. Two consequences that pull opposite ways: any *visibility* check built on `innerHeight` will aim at a point **behind the keyboard**; but the coordinate *transform* is unaffected, so treating the keyboard as a transform change forces a recalibration whose own probe taps land on the keyboard. Visibility must use `vvHeight`; staleness must not.

**Plus one operational rule for the pipeline, not just the gate: never hard-stop a Simulator straight after a login.** Cookies take a few seconds to reach disk; `simctl shutdown` before the flush loses the session, and the symptom is indistinguishable from "the session did not persist" — i.e. it would have wrongly tripped the kill criterion above. Assert the credential is on disk before any deliberate restart.

**Method note worth carrying into B1–B3: the geometry is *measured*, never assumed.** Two probe taps solve `screen = client · scale + offset` for the page's current layout state, and the resulting calibration records that state and refuses to be used in another. Two points rather than one so `scale` is measured instead of `visualViewport.scale` being trusted — our probe page disables pinch-zoom, the chat platforms do not, which is exactly the difference that would let a one-point calibration pass the gate and fail in production.

### 0.5.8 Kill criteria — decide these now, not in the moment

- **B0 fails** (input doesn't land, or login doesn't survive a reboot) → the iOS *Simulator* path is dead, and with it the proving ground for the app. Revisit Android (Chrome + CDP, §9 / Appendix C) or stay desktop-only. Track A is unaffected and continues.
- **C0 fails for every platform** (no login inside `WKWebView`) → the self-contained app is not achievable as specced. Fall back to Appendix G3 — the app becomes a thin client to the existing backend — or drop it. Decide this the moment C0 reports, not at C1.
- **A0 shows moved-controls are a small minority** of incidents → shrink A3 hard and spend the effort on read-drift and quota/auth handling instead.
- **A1 predicates can't get their false-positive rate near zero** → do not proceed to A3 at all. Ship A2 (offline) and stop. This is an acceptable, valuable outcome.
- **A3's live escalation is never authorised** for customer runs → that is fine by design; A2 already delivered the value. Do not treat it as failure.

### 0.5.9 The agent, concretely (A2 = the specification of decision A2)

**Escalate at intent/FLOW granularity, never per-step.** A flow redesign (deep research moves from a composer toggle to a mode-selection screen; an interstitial appears) needs a restructured *sequence*, not a single replacement action. "Propose an action", singular, is the wrong unit.

**Acts live on** (reversible, verifiable): a moved or renamed control; an unexpected popup/modal/interstitial; a toggle that silently didn't take; a retryable transient. Always verify against the predicate afterwards; on failure, revert to hands-off and let the existing failure path run.

**Proposes only** (never auto-applies): flow-shape redesigns; changed extraction/parsing; anything touching more than one intent; anything it cannot verify. Output is a JSON patch (§0.5.3) through `promotion_candidates()` → human-gated PR.

**Never touches:** Human Verification walls (unchanged policy — every interaction raises the bot score), auth, quota, payments.

**Predicates — prefer network over DOM.** DOM predicates rot on copy changes; network predicates are far more redesign-stable, and we have full CDP on desktop and use none of it for verification. Specify *"Gemini started deep research"* as **any-2-of-4**: (1) pre-send DR chip pressed or research placeholder; (2) post-send DR plan / "Start research" surface appears; (3) response container in a long-running state >N s with a progress affordance; (4) **an observed request to the DR backend endpoint**. Signal (4) is the durable one.

**Mid-wait sentinel.** Deep research runs 5–30 min. A logout, quota modal or A/B popup arriving *during* the wait fails no step until long after the cause. On-failure escalation never fires at the right moment — this needs a cheap always-on watcher, not a hook.

**Guardrails, reused verbatim from `selfheal.py`/`vision.py`:** flags default OFF, shadow-first rollout, confirmed-opposite toggle gate, verify-before-trust, evict-3/promote-3, step cap, per-run cost budget, repeat limit, circuit breaker, full audit log.

### 0.5.10 ⚡ DAY ONE — do this before anything else, including the update-fix work

**A0's clock is run-volume-bound, not effort-bound.** Its length is set by how many real pipeline runs accumulate after observation is armed. The product queue in A7 (update fix → publish → org PRs) will take weeks — **weeks in which A0 data could be collecting for free.**

So arm observation *now*, before the update work starts. By the time Track A begins, A0 is largely done instead of just starting.

**Arm it (all observe-only — nothing acts, nothing user-visible):**

```bash
DG_SELFHEAL_ENABLED=1     # master switch: turns the subsystem from inert to observing
DG_SELFHEAL_CAPTURE=1     # record full probe snapshots
DG_SELFHEAL_CAPTURE_LOG=/Users/<you>/.super-research/logs/selfheal_capture.jsonl
DG_SELFHEAL_SHADOW_LOG=/Users/<you>/.super-research/logs/selfheal_shadow.jsonl
# DG_SELFHEAL_ACT stays UNSET — this is the switch that lets it click. Do not set it.
# DG_VISION_TIER=shadow   # HELD BACK — see cost note below.
```

⚠ **The two explicit log paths are not optional.** Verified `selfheal.py:137–148`: the shadow and capture logs default to `logs/` **relative to the process CWD**, not `~/.super-research/logs/`. Arm without them and the data lands wherever the daemon happened to start — which for A0, the critical path, means collecting nothing anyone will find. Set both to absolute paths and confirm the files appear after the first run.

⚠ **`DG_VISION_TIER=shadow` is deliberately held back.** It makes real Anthropic calls (bounded by `DEFAULT_CALL_BUDGET=50`/run), and under **A8** Vision will not be acting on the desktop path anyway — so the spend buys design curiosity rather than a decision. Arm the two `DG_SELFHEAL_*` flags first; add Vision shadow later if predicate design needs it.

Set these where the daemon actually reads its environment (the launchd plist / supervisor env — the running process showed **none** of these set, so verify with `ps eww -p <pid>` after a restart, not just by editing a file).

**Before arming, confirm three things:**
1. **Cost.** `DG_VISION_TIER=shadow` makes real Anthropic calls in parallel with CUA at escalation sites. It is bounded by `DEFAULT_CALL_BUDGET=50`/run and the Sonnet/Opus cost tables in `vision.py`, but it is not free. If that is unwelcome during the product-fix window, arm the two `DG_SELFHEAL_*` flags only — they are pure-local and cost nothing — and add Vision shadow later.
2. **Disk.** `DG_SELFHEAL_CAPTURE=1` writes a full DOM probe snapshot per intent per run. Check growth after a few runs; cap or rotate if needed.
3. **Inertness.** `DG_SELFHEAL_ACT` must remain unset. With the master switch on and ACT off, the engine observes and logs what it *would* heal, and clicks nothing.

**Then, at the start of Track A, A0 is simply: read what accumulated.** If nothing accumulated, that is itself the finding — it means the failure classes we are building for are rarer than assumed, and A3's scope should shrink accordingly (§0.5.8).

---

### 0.5.11 Definition of done

- A **failure taxonomy with counts** exists (A0) and is the stated basis for what was built.
- A replayed historical breakage is **fixed by an agent-proposed JSON patch** with no rebuild (A2).
- At least one intent recovers **live** in a real run, verified, with an audit trail (A3).
- The desktop path is **provably unchanged** — same suites green, default behaviour identical with all flags off.
- If B0 passed: a full P0–P3 run completes against Safari in the Simulator, and survives a Simulator reboot still logged in.
- **End state (C1):** Super Research installs and runs as a native iOS app for every platform that cleared C0, driving a full P0–P3 run from inside the app, registered as a normal device against the unchanged Firestore contract so the existing FE needs no fork.

---

## 0. How to use this document

Read §1–§4 first (ground truth + the honest premise-check), then build strictly in the **PHASE** order of §6. **Phase 0 is a hard go/no-go gate** — do not build the full port until Phase 0's spike has produced data and the owner has seen it. Every claim about existing code is anchored `research.py:<symbol>@<line>`; **line numbers drift — locate by the named symbol, not the raw line** (verified symbols listed in Appendix A).

**Five decisions were locked by the product owner** (do not re-litigate the *intent* behind them). **⚠ D1, D2 and D5 are AMENDED by §0.5** — the HV premise they rested on was retired 2026-07-27. Read §0.5 before acting on this table.

| # | Decision | Consequence for this recipe |
|---|----------|-----------------------------|
| D1 | **Emulator target = iOS Simulator (Safari/WebKit), primary** | Track A is iOS Simulator, chosen over an Android recommendation with the WebKit/tap-level caveat understood. Honored throughout — but see hazard **H2 (§3.2)**, which the spike must clear. |
| D2 | **Spike-first, gated** | The recipe **opens** with an empirical experiment (§6 Phase 0) before any full build. Everything after Phase 0 is conditional on it. |
| D3 | **Coexist, in a separate new repo** | ✅ **RESTORED IN FULL by A8 (2026-07-29)** — the A6 amendment that carved out Track A is reversed. `~/Downloads/SuperResearch/dg-research-ios/`, sibling to FE/BE, **touching neither, for ALL THREE tracks including the agent.** The BE is a read-only dev dependency (source checkout). Emulator = a **config-selectable browser backend**; desktop-Chrome stays the default + fallback and is not modified. |
| D4 | **AI agent = extend self-heal + propose-for-review** | Build on `selfheal.py`'s proven guardrails. On a platform UI change the agent **proposes** a fix that a human/gate accepts — never autonomous live mutation. |
| D5 | **End state = Super Research as an installable native iOS app** ("easily installed," runs on the emulator *as* the product) | The crucial deliverable is a self-contained **iOS app** (embedded `WKWebView`), installable on the Simulator and ultimately a real device — not a permanent host-side harness. Delivered in **stages** (§4): the host-driven Track A is the **proving ground**; the app is the end state. The app introduces hazard **H3 (§3.3)** — embedded-WebView SSO block + `WKWebView` bot reputation — which **Phase 0.E** must clear before the app build (Phase 7). |

---

## 1. Executive summary (read before building)

The Super Research backend is a single **53,296-line `research.py` monolith** that drives the user's **real desktop Google Chrome** via **patchright** (a stealth-patched Playwright fork), `launch_persistent_context(channel="chrome")`, headless=`False`, at a hardcoded **1280×800** viewport. It automates ChatGPT, Gemini, Claude, and NotebookLM through pipeline **phases 0–3**; **phases 4–5 are FE-owned and use no BE browser**. It fights two recurring failures:

- **(A) Human Verification (HV):** Cloudflare Turnstile (mostly Claude), reCAPTCHA/hCaptcha, "checking your browser." The **only** real mitigation is the stealth stack itself (patchright + real Chrome + a warm, persistent, logged-in profile). On a wall the code goes **hands-off** — it never touches the wall (every interaction raises the bot score) — and asks the human to solve it.
- **(B) Platform UI change:** the platforms restructure their DOM/flow; hardcoded selectors break. Partially mitigated by `selfheal.py` (heuristic, no-LLM selector re-derivation, mostly shadow-only) and an LLM Vision→CUA recovery ladder.

**The initiative's hypothesis:** moving the browser into a mobile **emulator** dodges (A), plus an AI agent tackles (B).

**The honest verdict from investigation (this is what spike-first exists to test):**

1. **"Emulator ⇒ no HV" is not well supported — it may be lateral or a regression.** An emulator removes no fingerprint surface; it swaps *desktop* tells for *mobile-emulator* tells (software-GPU renderer strings, absent/static motion sensors, virtualization mismatches). The highest-weight challenge drivers — **IP reputation, TLS/JA3, behavioral history, account age, CDP-automation signals** — are unchanged or worse. On an Android/CDP path specifically, `adb`+CDP likely **re-introduces the `Runtime.enable` leak patchright removes on desktop**. Every practitioner source prefers **real devices over emulators**. **iOS Simulator's one genuine edge:** it runs a **real Safari/WebKit engine on real Apple-GPU hardware** (no SwiftShader tell) and mobile-web reCAPTCHA is sometimes lighter — worth *measuring*, not assuming.

2. **The chosen iOS path has a structural conflict with a hard requirement (persistent login).** `safaridriver` and Appium-Safari sessions are **isolated and ephemeral** (clean profile, state destroyed on teardown, orange automation UI) — they cannot hold a logged-in session, which the pipeline requires across a ~90-min run and across runs. **The viable iOS path drives the *real* MobileSafari** (its profile persists in the CoreSimulator data dir), reading the DOM over `ios-webkit-debug-proxy` and performing trusted taps via a host-side HID injector — a **candidate path, unproven until Phase 0 clears it** (§3.2).

3. **(B) selector-breakage is orthogonal to the substrate.** No browser/device choice fixes it; the AI self-heal agent is an **independent workstream** worth building regardless.

**Consequence:** we honor D1 (iOS primary) but Phase 0 is a **head-to-head A/B** — iOS Simulator vs the current hardened-desktop baseline (vs an Android arm) — measuring *actual HV rate + automation fidelity + persistent-login viability*. **The data selects the production substrate; the hypothesis does not.** Pre-designed pivots (§9) are ready.

**The end state (D5) is a native iOS app.** "Easily installed, runs on the emulator as Super Research" means a self-contained iOS app with an embedded `WKWebView` doing the automation in-app — not the host-driven harness that Track A builds first. This is delivered in **stages** (§4 "Staged delivery"): Track A (host-drives-Simulator MobileSafari) is the **proving ground** that establishes the pipeline works on the mobile DOM and yields the mobile selectors/flows/self-heal; the **app wraps that same JS-eval automation inside its own `WKWebView`**. The app carries its own make-or-break risk (**H3, §3.3**): sites like Google **block OAuth sign-in inside embedded WebViews**, and `WKWebView` has a different (often worse) bot reputation than real MobileSafari — so **Phase 0.E** tests app-login feasibility before Phase 7 commits to the app build.

---

## 2. Current-state map (ground truth — verify by symbol before porting)

### 2.1 The one seam: the `Browser` class
- `class Browser` — `research.py@20649` (ctor `~20669`), constructed `Browser(_profile_dir(WORKER_ID), headless=False)` and threaded as a `browser` arg through **~231 call sites**. **The single abstraction seam** between pipeline and browser; where the emulator backend plugs in.
- **The seam is leaky.** `Browser` wraps only launch, tab open/close/switch, and low-level input. The real automation runs on **raw Playwright `Page` objects** from `new_tab()`/`open_isolated_tab()`: **~225 `page.evaluate`**, 27 `query_selector` (returning ElementHandles), ~56 direct `page.keyboard/mouse`, ~10 `set_input_files`, **~109 functions that take a raw `page` param**, ~279 `await page.` calls. **Porting is not "swap the launcher"** — it is "present an object faithful to the `Page` surface these functions use" (see §5's `PageShim`).

### 2.2 Launch / stealth (desktop-Chrome-specific)
- `chromium.launch_persistent_context(channel="chrome", user_data_dir=…)` — `research.py@20799-20857`. **Real installed Chrome, persistent profile.** Escalated on 2026-04-19 (STEALTH note `@20777-20798`) because plain Playwright + manual UA spoof got bot-blocked at login.
- Stealth **fully delegated to patchright**: code **must not** set `user_agent`/`extra_http_headers`/automation args (`@20794-20798`); the old hand-rolled spoof was removed (worse fingerprints).
- macOS quirks: drop `--use-mock-keychain` so cookies decrypt via real Keychain (`@20801-20831`); `chromium_sandbox=True` on darwin/win32 (`@20841-20842`).
- Viewport `1280×800` via `API_WIDTH/API_HEIGHT` (`@489-490`). **Load-bearing** — see §2.6.
- Profiles: `_profile_dir(n)` → `~/.super-research/browser-profile[-N]` (`@130,171-185`).
- Login seeding: `_seed_login_plain_chrome` (`@47460`) launches the user's real Chrome (no automation) so the human signs in + clears HV; patchright reopens the **same profile**.

### 2.3 Human Verification handling
- Single detector `detect_human_verification` — `research.py@33174-33265`. One `page.evaluate` → `(blocked, reason)`; **never raises**. Matches Cloudflare Turnstile iframes / `.cf-turnstile`, "just a moment"/"checking your browser," Claude in-app "performing security verification," reCAPTCHA, hCaptcha, "access denied." Strips composer-subtree text first (so a brief quoting these can't self-trigger — #751/#752/#896).
- **Phase-split policy:**
  - **P2 setup = hands-off, non-blocking.** `start_agent_no_gemini_wait` Layer-0 (`@34861-34894`): sets `_controls.hv_blocked[platform]`, never solves/pauses → `_hv_setup_fail_card` (`@33519`) → auto-grey+close after `HANDS_OFF_AUTO_SKIP_SEC` (default 300s, `@14182`). **Retry omitted** (re-nav raises the bot score).
  - **P1 (ChatGPT) / P3 (NotebookLM) = blocking 5-tier cascade.** `check_hv_gate` (`@34089`, callers `"chatgpt"`@P1 and `"notebooklm"`@P3 — note an inline comment at `@34888` wrongly says "P1/P5"; the code says P3) → `wait_for_verification_clearance` (`@33620`): checkbox-click → CUA → 180s cooldown+reload → CUA → kill-tab → user pause + 5s auto-resume poll. **For a positively-identified Cloudflare wall, all interaction tiers are skipped** (passive 15s settle, then Skip-only alert) per the 2026-07-06 directive.
- Alert intents `ALERT_INTENTS@14186-14214`: `hv_wall` (Cloudflare, Skip-only, auto-skip) vs `hv_solvable` (Resume+Skip).
- **The stealth stack is the only real HV mitigation** — there is no CAPTCHA-solving anywhere; Vision/CUA are told to escalate, never solve (`vision.py@287`, `prompts.py@38`). **So "the emulator dodges HV" must come entirely from the emulator's bot-score profile — nothing in the existing code helps it.**

### 2.4 Existing self-heal (the seed for the AI agent)
- `selfheal.py` (1,186 lines) — "Phoenix selector engine." **Pure heuristic, zero LLM calls.** Scoped to exactly **6 P2 setup intents** `{chatgpt,gemini,claude}.{enable_deep_research,select_model}` (manifest `_INTENTS@166-240`, editable `selfheal_intents.json`).
- Mechanism: injected-JS accessibility probe (`probe_region`) → semantic ranking of **durable signals** (accessible-name+role > text > value; **CSS class never scored** — #709) → **confirmed-opposite toggle guard** (`decide_toggle@617-641`) → click only if unambiguous → **verify-before-trust** re-runs the outcome predicate → persist to `~/.super-research/selectors.json` with health counters (**evict after 3 consecutive fails `_SELECTOR_EVICT_FAILS=3`, promote to "trusted" after 3 OKs `_PROMOTE_THRESHOLD=3`**). Atomic writes under fcntl/msvcrt lock; evictions audited.
- Triple flag-gated, **all default OFF** (`DG_SELFHEAL_ENABLED/_ACT/_CAPTURE`). **Only `gemini.enable_deep_research` ACTS today** (`research.py@33065-33074`); the other 5 are shadow-log-only. So the "existing self-heal" is mostly a **telemetry + guardrail foundation** — the acting side is largely greenfield.
- `promotion_candidates()` (`selfheal.py@941-959`) already yields trusted selectors "as candidates for a later human-gated auto-PR." **This is the propose-for-review hook (§7).**
- LLM recovery ladder (separate): DOM → **Vision** (`vision.py`, `AsyncAnthropic`, forced `propose_action` tool, `VISION_LIGHT=claude-sonnet-4-6`/`HEAVY=claude-opus-4-8`, `act_loop` max 8, 50-call budget) → **CUA** (`computer-use-2025-11-24`, `computer_20251124` tool, `claude-sonnet-4-6`, 30 iters, 1280×800). Modes via `DG_VISION_TIER` (default off). Dispatched at ~43 hotspots via `_shadow_observed_cua@13906`.

### 2.5 Run / packaging / delivery
- Entry: `superresearch = research:main` (`pyproject.toml@98-102`). Flags: `--serve`, `--daemon-loop`, `--pair`, `--login`, `--resume`, `--worker-id`, `--port`.
- **Trigger = Firestore push:** `start_firestore_start_listener@6177` on `devices/{deviceId}/queue/` → claim → enqueue → single `_job_worker` → `run_pipeline@39944`.
- **BE↔FE contract:** research-doc updates `_update_firestore_research@7895` + durable `pendingDecision` mirror (`_persist_pending_decision@7930`); `pipeline_events` subcollection is the **exclusive live pipeline-event transport** (writer `@7774-7809`) — completed-run replay reads the parent doc + agents map, not the event log; `documents@6118`/`audios@6080` subcollections + Firebase Storage REST audio upload (`upload_audio_to_storage@6051`); 5s heartbeat (`@4424`). Commands via per-research `_start_command_listener@8483` + device `_start_device_command_listener@4918`.
- **Browser-bound vs not:** P0 (login verify), P1 (ChatGPT only), P2 (3 parallel tabs, round-robin), P3 (NotebookLM) are BE-browser. **P4 (YouTube) + P5 (Docs/email) are FE-owned Cloud Run — zero BE browser** (`ARCHITECTURE.md@42-49,102-105`); BE **exits after P3**, then POSTs `_post_fe_p4p5_trigger@7003`. Browser-**independent** BE work (**the reusable leaf helpers, §4**): Firestore sync (`_update_firestore_research`, event writer, `pendingDecision`), narration (`narrate.py`), alert-intent copy (`ALERT_INTENTS`), title/summary, audio-duration probe, Storage upload, delivery trigger, pairing/auth (`auth/`).
- **Packaging (critical for §4):** Nuitka cp313 wheel — `research.py → _sr_core.<abi>`, plus `models/prompts/vision/narrate` compiled; **only `auth/`, `scripts/`, `selfheal.py` ship as readable source** (`tools/build_compiled.py`, `TOP_MODULES=[models,prompts,vision,narrate]`). **⇒ The shipped wheel is opaque and uneditable; development for this port must use a SOURCE checkout of `dg-research-backend`.** macOS build needs `MACOSX_DEPLOYMENT_TARGET=11.0` + **uv-managed CPython 3.13** (never Homebrew — see `superresearch-whl-build` memory). Supervisor: launchd `com.dgresearch.supervisor.plist` / Windows schtasks / Linux systemd-user runs `--daemon-loop` (`run_daemon_loop@49777`), respawning N `--serve` workers.
- **Testing:** 138-file **fully-mocked** pytest (CI = no browser/network/Firestore). **No automated e2e exists.** e2e today = manual `superresearch "<topic>"` or `--resume <queue-dir>`, watched via Firestore + `~/.super-research/logs/backend.log` + `DG_RUN_ID`-tagged shadow logs. **⇒ The recipe builds the e2e harness too (§8).**

### 2.6 Why "1280×800 desktop DOM" is baked deep (the porting cost)
Each is a structural desktop assumption that breaks on a ~390px mobile-web DOM:
- **Geometry gates** tuned to 1280 wide: ChatGPT activity panel "~267px" (`@17545,18084`), Claude artifact panel `width≥400 && right-of-center` (`@19637,20056-20072`), Gemini panel gate (`@20446`). CUA `display_width/height_px` (`@21350-21351`), Vision ratio fixtures.
- **Sidebar/nav login markers** (`LOGIN_PLATFORMS@10292-10329`): `nav[aria-label="Chat history"]`, `aside[class*=sidebar] a[href*="/c/"]`, `bard-sidenav`, `div[data-testid="chat-list"]` — all collapse behind a hamburger on mobile; `verify_login` would fall through to fail-open and mask real logouts.
- **Hover-only** Gemini model-picker submenus (`@31152-31342`) — no touch equivalent.
- **Keyboard-shortcut** flows: `Control+A/C/V` paste+extract (`@13123-13262,29537`), Enter submit, ~14 Escape dismissals; no Meta/darwin branch.
- **OS-native clipboard bridge** `pbpaste`/`powershell Get-Clipboard`/`xclip` (`@2378-2461`) reads the **host** clipboard — invisible to an emulator guest. Most portable extraction piece: in-page JS `_copy_via_hijack@28400` / `_run_with_clipboard_hijack@28866` — make it the model.
- **Upload/download**: `page.on("filechooser")` + `set_input_files` (`@20870,28155,32674,37178`), `expect_download`+`save_as` (`@28690,38476`). No equivalent when files live on the host and dialogs are native mobile sheets.
- **Multi-tab** P2 (`new_tab` per agent, `bring_to_front`, `_guard_popup`) assumes desktop tab semantics; mobile browsers freeze/discard background tabs — threatens the 90-min 3-tab poll (**probe this in Phase 0.D**).
- **Cross-origin iframes**: ChatGPT DR sandbox, Claude artifact iframes — may not render on mobile web, removing the progress-scrape + extraction surface.
- **Mobile feature parity is unverified**: Deep-Research toggles, Share/Export menus, NotebookLM audio may be **absent or app-gated** on mobile web (**first-class spike question, Phase 0.C**).

---

## 3. The hazards the spike must clear first (H1 substrate · H2 iOS input/login · H3 app)

### 3.1 H1 — the HV premise may be false or negative

> **⚠ SUPERSEDED by §0.5 (decision A4).** Human Verification was retired as a driver on 2026-07-27. H1 is **not a gate and not a success metric** — it survives only as a cheap non-blocking regression check so a substrate switch cannot make HV silently worse. Never block a build on it.
Does iOS-Simulator MobileSafari (real WebKit, real Apple GPU, mobile-channel flow) actually draw **materially fewer** walls than the current desktop-patchright baseline, **same account + IP + behavior**? The literature predicts *not* for emulators generally; iOS Simulator's real-WebKit-on-real-GPU edge makes it *worth measuring*, but the burden of proof is on the data. Phase 0.B measures it.

### 3.2 H2 — iOS automation vs persistent login + trusted input (the make-or-break)
`safaridriver`/Appium-Safari are **ephemeral** — do not build on them. The persistent-login path drives the **real MobileSafari** app and is a **two-channel** design (verified toolchain, Appendix F):
- **DOM/read channel:** `ios-webkit-debug-proxy` (IWDP) attaches to the booted Simulator's MobileSafari (auto-discovered at `localhost:9221` via the `webinspectord_sim` socket) exposing the **WebKit Remote Inspector** protocol → `Runtime.evaluate` for JS/DOM. *(Note: `pymobiledevice3`'s WebInspector is **physical-device-only** and does NOT drive the Simulator — use IWDP for the sim.)*
- **Input channel:** the WebKit protocol has **no input domain**, and **synthetic JS events are not trusted** (`isTrusted:false`), which these chat SPAs reject (ChatGPT's ProseMirror composer accepts only `document.execCommand('insertText',…)` for text; send/anti-automation need real taps). So trusted taps/keystrokes come from a **host-side HID injector**: **AXe** (`axe tap -x X -y Y --udid <UDID>`, `axe type '…'`) or **baguette** (Xcode-26 9-arg SimulatorKit HID). **`idb` is broken on iOS 26** (unmaintained since 2022; old 5-arg HID silently drops/crashes) and **`simctl` has no tap command** — do not use either for input.
- **Login persistence:** MobileSafari's cookies/keychain live in `~/Library/Developer/CoreSimulator/Devices/<UDID>/data/` and persist across `simctl shutdown`+`boot` and host reboot, wiped only by `simctl erase`. Sign in once with the UI open (`open -a Simulator`), then run windowless. Known sim cookie/keychain flakiness ⇒ **must be proven, not assumed**.

**Fidelity ceiling to accept:** DOM-read via JS-eval + text via `execCommand` + **coordinate taps** whose (x,y) you compute from `getBoundingClientRect()` and feed to AXe/baguette. No native filechooser/download events. **Phase 0 must prove (a) HID injection actually lands in the booted iOS-26 Simulator's real MobileSafari, (b) a full login-gated action runs end-to-end, and (c) it comes back logged in after a reboot.** If any fails → iOS fails the gate → pivot (§9). **The single biggest risk is (a):** the iOS-26 HID signature break makes input make-or-break, and AXe's vs baguette's docs disagree on which is fixed — settle it empirically first.

### 3.3 H3 — the native-app end state (D5): embedded-WebView SSO block + `WKWebView` bot reputation
The end state is an installed iOS app, and an app cannot drive the *system* MobileSafari or inject host-side HID (sandbox) — it drives its **own** `WKWebView`. Two forces make this a genuine feasibility question, not a formality:
- **Embedded-WebView sign-in block (the likely hard blocker).** Google explicitly **blocks OAuth/sign-in inside embedded WebViews** ("this browser or app may not be secure" / `disallowed_useragent`) to stop credential interception. **Gemini and NotebookLM require a Google login**, so a naïve `WKWebView` app likely cannot sign into them at all. ChatGPT/Claude can use email-password (not necessarily Google), so they may be reachable — but any Google-auth leg is at risk. Known mitigations (Safari-like UA on the web view, or doing the auth leg in `ASWebAuthenticationSession` then transferring the session) are fragile cat-and-mouse. **Phase 0.E must prove per-platform login actually works in a `WKWebView` before Phase 7.**
- **The `WKWebView` cookie/engine tradeoff.** `SFSafariViewController` shares Safari's cookies and engine but gives **no programmatic DOM access** (out-of-process — useless for automation). `WKWebView` gives full JS/DOM control (`evaluateJavaScript`, script injection) but has an **isolated cookie store** (`WKWebsiteDataStore`, persistable) and is treated as an embedded web view (the block above). So the app must use `WKWebView` and own its own login/persistence — and its bot-score profile is a *new* unknown (often worse than real Safari). **Phase 0.E measures `WKWebView` HV rate vs the MobileSafari arm.**
- **The orchestration runtime.** The compiled Python monolith and patchright cannot run in an iOS app. Phase 7 chooses a runtime for the app's brain (Swift rewrite of the P0–P3 orchestration driving the `WKWebView`; or embed the *browser-independent* Python via BeeWare/`python-apple-support`, iOS being an official Python 3.13 target, for Firestore/narration/self-heal while Swift owns the web view; or a thin companion service the app calls) — see Appendix G. **The mobile selectors/flows/self-heal proven in Track A port directly, because the app's `WKWebView.evaluateJavaScript` is the same JS-eval channel** as IWDP's `Runtime.evaluate`.

---

## 4. Target architecture

### Staged delivery (why the app is Stage 2, not Stage 1)
The end state (D5) is a native iOS app, but building it directly would gamble the whole effort on three simultaneously-unproven things (does mobile-web automation work at all; does the substrate reduce HV; does `WKWebView` login even succeed). So deliver in two stages that de-risk in order:
- **Stage 1 — Host-driven proving ground (Track A, everything in §5/§6 Phases 1–6).** A Python harness on the host drives the **real MobileSafari** in the Simulator (IWDP + AXe/baguette). This proves the pipeline runs on the mobile DOM, produces the **mobile selectors, flows, geometry, and self-heal manifest** (`selectors_mobile.json`), and gives the desktop-vs-iOS HV data — using the *best-case* browser (real Safari, best auth/bot posture). It is the fastest path to "does any of this work."
- **Stage 2 — Native iOS app (Phase 7, the D5 end state).** Wrap that same automation inside the app's own `WKWebView`. Because `WKWebView.evaluateJavaScript` is the **same JS-eval channel** as IWDP `Runtime.evaluate`, the Stage-1 selectors/flows/self-heal **port directly** — the app build is mostly (a) the SwiftUI/`WKWebView` shell + login/persistence, (b) the orchestration-runtime choice (Appendix G), and (c) clearing H3 (§3.3). Stage 2 begins only after **Phase 0.E** proves `WKWebView` login is feasible; if 0.E fails for a Google-auth platform, that platform falls back to the host-driven path or a mixed model (§9).

This staging also protects the investment: even if the app wrapper hits the embedded-WebView wall for Google platforms, Stage 1 remains a working mobile pipeline, and the app can still ship for the platforms whose login *does* work in `WKWebView`.

```
~/Downloads/SuperResearch/
├── dg-research/               (FE — untouched)
├── dg-research-backend/       (BE — untouched in place; but a SOURCE checkout is a dev dependency)
└── dg-research-ios/      (NEW — this initiative, D3)
    ├── pyproject.toml         (package: superresearch-emulator; own version; dev-dep: -e ../dg-research-backend)
    ├── emubackend/
    │   ├── backend.py         (BrowserBackend ABC — §5)
    │   ├── page_shim.py       (PageShim + ElementHandleShim — §5)
    │   ├── ios_webkit.py      (Track A: IWDP DOM-read + AXe/baguette taps against one persistent MobileSafari)
    │   ├── android_cdp.py     (Track B pivot: Android AVD Chrome via Appium UiAutomator2 + CDP)
    │   ├── desktop_ref.py     (Track C baseline: thin wrapper over the source BE's Browser)
    │   ├── pipeline.py        (reimplemented P0–P3 orchestrator — see below)
    │   ├── provision/         (emulator lifecycle: boot / seed-login / health / restart)
    │   ├── selfheal_agent/    (the propose-for-review AI agent — §7)
    │   └── spike/             (Phase 0 harness — §6: wall_detector.js, hv_metrics logger, report)
    ├── selectors_mobile.json  (mobile-DOM intent manifest — inherits selfheal_intents.json schema; shared by Stage 1 + the app)
    ├── tests/                 (unit + the new e2e harness — §8)
    └── ios-app/               (STAGE 2, Phase 7 — the D5 native app: Xcode/SwiftUI + WKWebView + orchestration runtime, Appendix G)
```

**Reuse vs reimplement (corrected — the wheel is compiled, §2.5):**
- **Dev against a SOURCE checkout of `dg-research-backend`.** The shipped wheel compiles `research.py → _sr_core` and is uneditable, so you cannot "reuse via the wheel" or "minimally edit the 112 functions" in it. Install the BE source editable in the emulator repo: `uv pip install -e ../dg-research-backend`.
- **Reimplement the P0–P3 orchestration** in `emubackend/pipeline.py`. `run_pipeline@39944` is *welded* to the `Browser` seam (it binds submitter identity, resolves the Anthropic key into `cua_client`, and interleaves browser phases with Firestore in one body) — it **cannot** be reused headless. Mirror its phase sequence but call the new `BrowserBackend`.
- **Reuse the browser-independent leaf helpers** by importing them from the BE source package: `_update_firestore_research`, the `pipeline_events` writer, `_persist_pending_decision`, `ALERT_INTENTS`, `_post_fe_p4p5_trigger`, `upload_audio_to_storage`, `narrate.py`, and the `auth/` pairing flow. These are leaf functions with no `Browser` dependency (verify each import resolves against the source tree; a few may need a thin extraction if they close over module globals).
- **The ~109 page-driver functions are forked + rewritten, not "minimally edited."** They need mobile-DOM re-derivation anyway (§2.6: selectors, geometry gates, hover→tap, keyboard→execCommand). `PageShim` (§5) absorbs the *transport* churn so the control flow of each function is preserved, but the selectors/interactions genuinely change. Fork the P0–P3 drivers (`setup_*_dr`, `detect_completion_*`, `scrape_progress_*`, `extract_*`, NotebookLM helpers) into `emubackend/` and rewrite against `PageShim` + `selectors_mobile.json`.

**Config seam:** `DG_BROWSER_BACKEND=ios|android|desktop` (default `desktop`), read where `run_pipeline`/`pipeline.py` constructs the browser.

---

## 5. `BrowserBackend` + `PageShim` (the core engineering artifact)

Two objects. **`BrowserBackend`** owns the substrate (launch/tabs/screenshot + the native-input transport). **`PageShim`** presents the exact `Page` surface the forked driver functions call, using page-method convention (matching the source), delegating to the backend underneath. Choose **one** convention — page-method — everywhere.

```python
# page_shim.py — the object the forked P0–P3 functions actually call.
class ElementHandleShim:
    # returned by page.query_selector / query_selector_all (source uses handles)
    async def click(self): ...             # → backend.tap(box_center)  OR  in-page el.click() where trusted-not-required
    async def inner_text(self): ...        # → evaluate 'el => el.innerText'
    async def get_attribute(self, name): ...
    async def bounding_box(self): ...      # → evaluate getBoundingClientRect → {x,y,width,height} in CSS px
    async def is_visible(self): ...
    async def scroll_into_view_if_needed(self): ...

class KeyboardShim:
    async def press(self, combo): ...      # 'Enter'/'Escape' → backend.key ; 'Control+A' → in-page select-all JS
    async def type(self, text): ...        # → for contenteditable use execCommand('insertText'); else set value + input event
    async def insert_text(self, text): ...

class MouseShim:
    async def click(self, x, y): ...       # → backend.tap(x,y)
    async def wheel(self, dx, dy): ...     # → backend.scroll
    async def move(self, x, y): ...

class PageShim:
    keyboard: KeyboardShim
    mouse: MouseShim
    async def goto(self, url): ...
    async def evaluate(self, js, *args): ...          # → backend.evaluate (the clean-porting core; ~225 sites)
    async def query_selector(self, sel) -> ElementHandleShim | None: ...
    async def query_selector_all(self, sel) -> list[ElementHandleShim]: ...
    async def set_input_files(self, sel, paths): ...  # → backend.upload (host→guest); may raise BackendUnsupported
    async def screenshot(self) -> bytes: ...
    def viewport(self) -> tuple[int,int]: ...         # REAL mobile metrics, NOT 1280×800
    # + the ~dozen other Page methods the seam audit shows (expect_download, bring_to_front, etc.)
```

```python
# backend.py — substrate transport. iOS composes TWO channels (§3.2).
class BrowserBackend(ABC):
    async def start(self): ...
    async def close(self): ...
    async def health(self) -> bool: ...            # §6 Phase 2 defines the iOS body concretely
    async def new_tab(self, url) -> PageShim: ...
    async def open_isolated_tab(self, url) -> PageShim: ...
    async def switch_to(self, page): ...
    async def bring_to_front(self, page): ...       # may be no-op on mobile
    async def evaluate(self, page, js, *args): ...  # iOS: IWDP Runtime.evaluate ; Android: CDP ; desktop: page.evaluate
    async def tap(self, page, x, y): ...            # iOS: AXe/baguette HID ; Android: adb/CDP ; desktop: mouse.click
    async def key(self, page, combo): ...           # iOS: AXe key ; else CDP/keyboard
    async def scroll(self, page, dx, dy): ...
    async def upload(self, page, sel, host_paths): ...   # iOS: pre-stage into sim + JS DataTransfer where supported, else BackendUnsupported
    async def download_capture(self, page, trigger): ...
    async def read_clipboard(self, page): ...       # prefer in-page JS hijack, never OS clipboard
    async def screenshot(self, page) -> bytes: ...
    def viewport(self) -> tuple[int,int]: ...
```

**`BackendUnsupported`** is a typed exception; the pipeline catches it to degrade (e.g. drop the OS-clipboard path for the JS hijack, or route an upload through a per-platform substitute). Every primitive a forked function calls is either implemented or explicitly degraded — enforced by a contract test (§8.1).

**Per-Track transport:**
- **iOS (A):** `evaluate` → IWDP `Runtime.evaluate`; `tap(x,y)` → AXe/baguette HID at CSS-px→device-px-scaled coords; text → `execCommand('insertText')` via evaluate, or AXe `type`; `upload` → usually `BackendUnsupported` (verify a per-platform substitute in Phase 0.C/0.D); `read_clipboard` → in-page JS hijack only. **Reset the CUA/Vision `display_width/height_px` to the real mobile viewport — never 1280×800.**
- **Android (B, pivot):** `evaluate`/`tap`/`scroll` → CDP over `adb forward tcp:9222 localabstract:chrome_devtools_remote`; native dialogs / OS CAPTCHA → **Appium UiAutomator2** native context; `upload` → `adb push` + `DOM.setFileInputFiles`. **Accept and measure the CDP `Runtime.enable` detectability regression (§1.1).**
- **Desktop (C, baseline):** pass-through to the source BE's `Browser@20649` so the Phase-0 A/B is apples-to-apples.

---

## 6. Build order — PHASES (Phase 0 is a hard gate)

### PHASE 0 — The Spike (GO/NO-GO). Build & run before anything else. (D2)

> **⚠ RENAMED + RESCOPED by §0.5.7.** The spike below is now **Phase B0**, and it is still a hard GO/NO-GO gate for iOS — but only on **0.A** (trusted input lands, a login-gated action runs, and login survives a reboot). **0.B (the HV A/B) is demoted to a non-blocking regression check** per A4. **0.E is retained and promoted to its own gate, phase C0** (app-login feasibility in `WKWebView`) — the app is in scope per A3, sequenced last. B0 may run in parallel with A0/A1 — run it early, its answer changes everything downstream. Separately, **Phase A0 ("measure the disease") is what happens first on the agent track.**

All Phase-0 code lives in `dg-research-ios/spike/` and is **self-contained** — it must not depend on the compiled `_sr_core`. Prereqs: the Environment & Setup appendix (Appendix E) must be satisfied first (Firebase project, a paired test device, a dedicated test account, egress plan).

**0.A — Persistent-login + trusted-input viability (H2, §3.2) — the cheapest kill-test; run first (≈1 day).**
Stand up one iOS-26 Simulator (Appendix F), MobileSafari signed into **one** platform by hand (seed sequence, §Phase-2 / Appendix F). Then, entirely through the two-channel stack:
1. **Prove input lands:** via AXe/baguette, tap a known on-screen control and confirm via IWDP `Runtime.evaluate` that the DOM reacted (e.g. the composer focused, `document.activeElement` matches). *(This is the make-or-break iOS-26 HID test — do it literally first.)*
2. **Read logged-in DOM:** assert the concrete **logged-in marker** (per-platform, hamburger-proof): ChatGPT — `document.querySelector('#prompt-textarea')` present AND no `[data-testid="login-button"]`; Claude — a `div.ProseMirror` composer present AND no `/login` in `location.pathname`; Gemini — a `rich-textarea`/contenteditable composer present AND no "Sign in" CTA. (Re-derive precisely during the spike; do not reuse the desktop sidebar markers, which collapse on mobile.)
3. **Drive a login-gated action end-to-end:** type a trivial prompt (`execCommand('insertText')`), tap send (AXe), and **capture a response** — assertion: the assistant-response region's text is non-empty and grew vs pre-send.
4. **Persistence:** `simctl shutdown` + `boot`, re-attach IWDP, confirm still logged in (step 2 marker holds) without re-auth.
**Pass = all 4 succeed.** Any failure (esp. step 1 or 4) → iOS is out → pivot (§9).

**0.B — HV pass-rate A/B (H1, §3.1).** Same dedicated account, **same egress** (Appendix E — for the spike, run all arms from the same host IP; do not build proxy infra yet), same pacing script, run **N≥40 sessions per arm** against `chatgpt.com`, `gemini.google.com`, `claude.ai`:
- Arm 1: **hardened desktop** (source BE `Browser`, patchright) — baseline.
- Arm 2: **iOS Simulator** MobileSafari (Track A).
- Arm 3: **Android AVD** Chrome (Track B) — **required if Android is a live pivot candidate** (see §9; do not allow a blind Android pivot).
- **Wall detection:** the spike runs the self-contained detector below via `evaluate` (independent of `_sr_core`):
  ```js
  // spike/wall_detector.js — returns {wall:bool, type:string}
  (() => {
    const q = s => document.querySelector(s);
    const t = (document.body.innerText || '').toLowerCase();
    if (q('iframe[src*="challenges.cloudflare.com"],iframe[src*="turnstile"],.cf-turnstile,.cf-challenge')) return {wall:true,type:'cloudflare'};
    if (t.includes('just a moment') || t.includes('checking your browser') || t.includes('checking if the site connection is secure')) return {wall:true,type:'cloudflare'};
    if (q('iframe[src*="recaptcha"],.g-recaptcha,#recaptcha')) return {wall:true,type:'recaptcha'};
    if (q('iframe[src*="hcaptcha"],.h-captcha')) return {wall:true,type:'hcaptcha'};
    if (t.includes('performing security verification') && !q('div[contenteditable=true],.ProseMirror')) return {wall:true,type:'claude-hv'};
    if (t.includes('verify you are human') || t.includes('are you a human') || t.includes('press and hold')) return {wall:true,type:'generic'};
    if (t.includes('access denied') && t.length < 1000) return {wall:true,type:'access-denied'};
    return {wall:false,type:''};
  })()
  ```
- **Metrics logger** — each session appends one JSONL line to `spike/hv_metrics.jsonl`:
  ```json
  {"arm":"ios","platform":"claude","session_id":"...","ts_iso":"...","wall_seen":true,"wall_type":"cloudflare","t_to_first_content_s":18.4,"human_required":false,"cleared":false}
  ```
- **Per-session reset (reconciled with persistent login):** the warm profile **stays logged in** across sessions; a "session" = a fresh app-cold navigation to the platform root (close the tab, re-open) after an idle gap — this is "cold-ish" without logging out. Log the idle gap used.
- **Pacing script** (identical across arms): before interacting, dwell a randomized 2–6 s, perform one human-like scroll, then act; randomize inter-action delays 0.8–2.5 s. Keep it in `spike/pacing.py` so all arms import the same one.
- **Report** `spike/hv_report.py`: per-arm, per-platform **wall-rate with a 95% Wilson confidence interval**, mean `t_to_first_content_s`, and `human_required` rate.
- **Gate (materially fewer, not parity):** iOS **PROCEEDs only if its wall-rate CI is non-overlapping-below the desktop baseline on at least the dominant wall (Claude/Cloudflare)** — i.e. a real reduction, since mere parity buys the entire §2.6/§9 porting cost + macOS-only constraint for zero net benefit. The exit report must weigh the measured HV delta against that cost explicitly.

**0.C — Mobile feature-parity probe.** On the iOS arm, manually confirm each pipeline-critical affordance **exists on mobile web**: ChatGPT Deep-Research toggle + activity panel + export; Gemini Deep Research + "Start research" + Share/Export; Claude Research tool + artifact panel + publish; **NotebookLM source upload + audio/podcast generation** (highest risk — may be desktop-only or app-gated). Any missing critical affordance = a scope cut or blocker — record it (coexistence lets that phase run on the desktop backend, §9).

**0.D — Automation-fidelity + tab-model probe.** On the iOS arm, confirm through the real two-channel stack: JS `evaluate` on the live DOM; **coordinate tap landing on the right element** (compute from `getBoundingClientRect`, tap via AXe, verify DOM reaction); text entry into each composer; file attach (or a working substitute); response extraction. **Also probe background-tab survival:** open 3 MobileSafari tabs (one per platform), background them for 10 min, confirm each tab's JS context + login survive — this decides the P2 tab model (sequential-single-tab vs multi-tab vs multi-simulator, §Phase 3). Record which primitives are `BackendUnsupported`.

**0.E — Native-app login feasibility (H3, §3.3 — gates the D5 end state / Phase 7).** This can run in parallel with 0.A–0.D and is required before Phase 7. Build a throwaway minimal iOS app: a SwiftUI shell hosting one `WKWebView` with a persistent `WKWebsiteDataStore` and an `evaluateJavaScript` bridge. Then, per platform (ChatGPT, Claude, **Gemini**, NotebookLM):
1. **Login-in-WebView test (the make-or-break):** attempt to sign in **inside the `WKWebView`**. Record whether it succeeds or hits the embedded-WebView block (`disallowed_useragent` / "browser or app may not be secure"). Test the two standard mitigations and record which (if any) works: (a) set the web view's `customUserAgent` to a Safari-like string; (b) do the auth leg in `ASWebAuthenticationSession` (which uses real Safari) and transfer the resulting cookies into the `WKWebsiteDataStore`. **Expect Google (Gemini/NotebookLM) to be the hard case.**
2. **Automation-in-WebView test:** confirm `evaluateJavaScript` can read the DOM and drive the composer (`execCommand('insertText')`) and that a tap on the send control works (in your own web view you have more input latitude than the isolated MobileSafari, but the `isTrusted` constraint still applies — record what's needed).
3. **`WKWebView` HV rate:** run a scaled-down version of 0.B's wall-detector inside the `WKWebView` (N≥20/platform) and compare its wall-rate to the **MobileSafari (0.B Arm 2)** rate. `WKWebView` is a *new* bot-score surface — this tells you whether the app substrate is worse than real Safari.
4. **Persistence:** confirm login survives app relaunch via the persistent `WKWebsiteDataStore`.
**0.E result feeds Phase-7 go/no-go per platform:** a platform whose login works in `WKWebView` (directly or via a mitigation) and whose HV rate is acceptable ships in the app; one that fails (likely a Google platform) falls back to the host-driven path or a mixed model (§9). Record all four per-platform outcomes in `spike/RESULTS.md`.

**Phase-0 exit report** → `spike/RESULTS.md`: a decision matrix with the measured numbers (0.A pass/fail, 0.B per-arm wall-rate CIs, 0.C parity list, 0.D fidelity + tab-survival, **0.E per-platform app-login + WKWebView-HV**) and **one** substrate recommendation — **PROCEED (iOS)**, **PIVOT (Android — only if its Arm-3 mini-spike also cleared)**, or **PIVOT (hardened-desktop + orthogonal levers)** — **plus a per-platform Phase-7 app-viability verdict** from 0.E. **Generalizability caveat to state in the report:** these numbers isolate the *substrate* effect on a single warmed account/IP; they must be revalidated at fleet scale (multiple accounts/egress IPs, over time) before any wide rollout. Do not start Phase 1 until this is written and the owner has seen it.

> **Phases 1–6 are conditional on Phase 0 recommending PROCEED for the chosen substrate.** Written for iOS (Track A); an Android pivot uses the same phase structure with `android_cdp.py` + Appium.

### PHASE 1 — Repo scaffold + backend seam
- Create `dg-research-ios/` (D3); `pyproject.toml` (`superresearch-ios`, own version; dev-dep `-e ../dg-research-backend`; runtime deps pinned per Appendix F). uv-managed CPython 3.13.
- Implement `BrowserBackend` + `PageShim`/`ElementHandleShim` (§5) + `desktop_ref.py` (Track C) and get the reimplemented `pipeline.py` green against the **desktop baseline** first (proves the orchestration + leaf-helper reuse before adding emulator risk).
- Wire `DG_BROWSER_BACKEND` (default `desktop`).

### PHASE 2 — iOS provisioning, login-seed, supervision
- `provision/ios.py`: create/boot the Simulator (Appendix F commands), attach IWDP, spawn AXe/baguette.
- **Login seed (exact sequence, resolves the headless-vs-hand-signin contradiction):** (1) `open -a Simulator` (you **cannot** hand-sign-in a windowless sim); (2) confirm Web Inspector is reachable (the sim's `webinspectord_sim` is on by default; ensure `::1 localhost` in `/etc/hosts` for IWDP's IPv6 discovery); (3) sign into each platform by hand, **handling 2FA** (Appendix E); (4) run 0.A step-4 persistence check; (5) close the Simulator window while the device stays **booted** (login lives in the data dir, not the window). Document a **re-seed** fallback for the known sim cookie/keychain flakiness and for any Xcode/runtime upgrade (which invalidates the toolchain pins).
- **Supervision (concrete — the emulator is a second stateful process):**
  - `BrowserBackend.health()` (iOS) = `simctl bootstatus <UDID>` reports booted **AND** IWDP `localhost:9221` tab-list is reachable **AND** a JS-eval ping (`Runtime.evaluate '1+1'`) round-trips within 5 s.
  - **Wedged** = health fails 3 consecutive polls (poll every 30 s) OR a JS-eval ping exceeds 15 s.
  - **Restart sequence:** `simctl shutdown <UDID>` → `boot` → re-attach IWDP → re-spawn injector → re-verify login marker (0.A step 2); if login is lost, raise a `login_required` alert via the reused FE event writer (do not silently loop).
  - **Integration point:** in `run_daemon_loop@49777`'s respawn loop, add boot-on-start and a health-poll task; a wedged emulator triggers the same restart the Python `--serve` respawn uses. Document this hook in `provision/supervisor_hook.md`.

### PHASE 3 — Port the P0–P3 browser layer, one phase at a time (forked, behind the seam)
Validate each phase against a live run before the next:
1. **P0 login verify** — re-derive `LOGIN_PLATFORMS` markers for mobile-web (hamburger-proof, per 0.A step 2); keep the cookie cross-check to avoid false "signed out."
2. **P1 ChatGPT brief** — mobile composer selector, submit via AXe, response wait; brief **attach** via the 0.C-proven substitute (or mark unsupported → desktop fallback).
3. **P2 3-platform Deep Research** — the heaviest: setup toggles per platform, mobile equivalents of the desktop geometry gates, and the **tab model decided by 0.D** (likely one MobileSafari tab per platform driven sequentially if background tabs don't survive, or multiple simulators). **Preserve the hands-off `hv_blocked` invariant at every touch point (§2.3, §Phase 4).**
4. **P3 NotebookLM** — only if 0.C confirmed mobile-web audio generation; else mark "P3 runs on desktop backend" (coexistence).
- Rework Vision/CUA to the real mobile viewport; rewrite the desktop-UI mission prompts for mobile layouts.
- Re-implement clipboard via **in-page JS hijack** everywhere (drop the OS-clipboard bridge).

### PHASE 4 — HV detection + policy on the new surface
- Port `detect_human_verification` to read the mobile DOM (reuse the `spike/wall_detector.js` signals, extended); re-derive the Cloudflare/Claude structural heuristics for mobile challenge layouts.
- **Preserve the phase-split policy exactly** (P2 hands-off non-blocking; P1/P3 blocking cascade with the Cloudflare skip). The human now solves a wall *inside the Simulator window* — document the operator UX and keep the 5s auto-resume poll analog.

### PHASE 5 — The AI self-heal agent (§7)

> **⚠ SUPERSEDED by §0.5.7 — this ordering is backwards.** The agent does **not** wait on the emulator port. It ships first on desktop Chrome (Track A: A0→A3), because it delivers value on the product that exists today *and* because the offline agent is what generates the mobile selector manifest that Track B needs — Track A is the machine that builds Track B's inputs. The sentence below is void.

~~Build after the pipeline runs green on the emulator (so the agent has a working baseline to repair against).~~

### PHASE 6 — Coexistence hardening + delivery
- Ensure P4/P5 (FE-owned) still trigger after P3 regardless of backend.
- Package `superresearch-ios` for macOS (uv 3.13). **State the constraint plainly: the host-driven iOS Track is macOS-only** — this backend cannot run on the Windows/Linux supervisor targets (a real limitation vs the desktop path).
- Multi-worker: each worker = its own Simulator + profile; budget resources.

### PHASE 7 — Package Super Research as a native iOS app (the D5 end state)
Begins only after **Phase 0.E** returns a viable per-platform verdict. Builds `dg-research-ios/ios-app/`. **This wraps the Stage-1 automation, it does not re-derive it** — the `selectors_mobile.json` manifest, the ported P0–P3 flows, and the self-heal agent all carry over because `WKWebView.evaluateJavaScript` is the same JS-eval channel as IWDP `Runtime.evaluate`.
- **App shell:** SwiftUI app hosting a `WKWebView` per active platform (or one reused sequentially per the 0.D tab-model finding), each with a persistent `WKWebsiteDataStore` for login continuity, an `evaluateJavaScript` bridge (the `BrowserBackend.evaluate`/`PageShim` surface, reimplemented against `WKWebView`), and the 0.E-chosen login mechanism (Safari-like UA and/or `ASWebAuthenticationSession` cookie transfer) for platforms that need it.
- **Input:** in the app's own `WKWebView` you drive the DOM directly via `evaluateJavaScript` (`execCommand('insertText')`, element `.click()` where trusted input isn't required); where a trusted gesture is genuinely required use `WKWebView`'s own gesture APIs — **no host-side HID injector (AXe/baguette) is involved in the app** (that was a Stage-1-only tool for the *system* MobileSafari).
- **Orchestration runtime (choose per Appendix G):** the P0–P3 orchestration + browser-independent brain (Firestore sync, narration, self-heal, delivery trigger) must run somewhere that is not the compiled Python monolith or patchright. Options: **(G1) Swift rewrite** of the orchestration driving the `WKWebView`; **(G2) embed the browser-independent Python** via BeeWare / `python-apple-support` (iOS is an official Python 3.13 target) for Firestore/narration/self-heal while Swift owns the web views; **(G3) thin companion service** (the existing Python on a paired host or Cloud Run) that the app calls, with only the web-view automation in-app. Pick based on how much of the brain must run on-device/offline vs how fast you need a shippable app.
- **Firestore/BE contract:** keep the same `devices/{deviceId}/queue` + `pipeline_events` contract so the existing FE works unchanged — the app registers as a device (Appendix E pairing) and drives the same doc/event schema. **Do not fork the FE.**
- **Per-platform coexistence:** platforms whose login/HV failed 0.E run via the host-driven Stage-1 backend (or are marked desktop-only); the app ships for the rest. The `DG_BROWSER_BACKEND` seam extends to `ios-app` as another selectable backend.
- **"Easily installed" (distribution — Appendix G):** Simulator install is `xcrun simctl install <UDID> SuperResearch.app` + `simctl launch`. Real-device distribution is **TestFlight** (the practical channel), **ad-hoc/development signing** (registered UDIDs), or **enterprise/MDM** for internal fleets. **State honestly: an automation app that drives third-party sites will very likely fail public App Store review** — plan for TestFlight/enterprise/ad-hoc. Document the signing identity + provisioning-profile steps.
- **On-device supervision limit:** iOS background-execution limits mean an app can't run an unattended 90-min pipeline the way a desktop daemon does. If unattended runs are required, keep the app foreground-active during a run (Simulator/kiosk-device model) or push the long-running brain to the G3 companion service and let the app be the web-view surface. Record this constraint.

---

## 7. The AI self-heal agent (extend self-heal + propose-for-review — D4)

> **⚠ AMENDED by §0.5.9.** Directionally right (reuse the guardrails, propose rather than auto-adopt), but v4 changes five things: (1) autonomy is **staged, not propose-only** — the agent DOES act live on reversible, verifiable problems, and proposes only structural ones (decision A2); (2) the **offline repair agent ships first** (phase A2) — no act-flag needed, value regardless; (3) escalation is **flow-granular, not step-granular**; (4) coverage must include **read/parse drift**, the dominant failure class, which this section does not address at all (§0.5.4); (5) do **not** build a new LLM escalator — wire the existing `vision.py`/CUA (phase A3). The "substrate-agnostic" claim in item 4 below is overstated: Tier 0/1 artifacts are substrate-specific.

**An evolution of `selfheal.py`, not a rewrite.** Reuse the guardrails verbatim: shadow-first rollout, confirmed-opposite toggle gate, verify-before-trust, evict-3/promote-3 registry, audit log, flags-default-OFF.

1. **Detection ownership.** Watch for *predicate failures* (a step whose outcome predicate returns false N times) across **all** hotspots, not just the 6 intents — the entry signal.
2. **Proposal generation.** On confirmed breakage, an LLM (reuse `vision.py`'s Anthropic client + model policy; `claude-opus-4-8` high-stakes, `claude-sonnet-4-6` otherwise) receives the intent's durable-signal contract, the probed accessibility tree (`probe_region`), the failing predicate, and the last-known-good selector, and **proposes** a new selector/flow (accessible-name+role first, **never CSS class** — enforce #709 in the prompt and a post-filter).
3. **Verify-before-trust, then PROPOSE — not auto-adopt (D4).** Validate the proposal against the real predicate in a shadow tab; if it verifies it goes to a **review queue**, not silent promotion: a human-gated auto-PR against `selectors_mobile.json` (the mechanism `promotion_candidates()@941-959` already anticipates) or an in-product approval card. Only after approval does it become a "trusted" registry entry.
4. **Substrate-agnostic.** It operates on the JS-probe + registry layer (ports to any `evaluate` channel), serving both emulator and desktop backends.

**Data contract:** `selectors_mobile.json` **inherits the `selfheal_intents.json` schema** (use that file as the concrete template — `signal_hints` of accessible_name/role/placeholder + `tier_sequence`), extended with mobile regions/predicates. The review-queue write target is that file; the propose path is `promotion_candidates()` → human-gated PR / registry-overlay.

**Explicitly NOT:** solve CAPTCHAs/HV (out of scope, as Vision/CUA today), or mutate compiled code (it can only propose changes to the source-shipped selector manifest + registry overlay — the Nuitka wheel can't be hot-patched, §2.5).

---

## 8. Testing & end-to-end validation (the recipe builds the e2e too)

There is **no automated e2e today** — you are building it. Two layers.

**8.1 Unit / contract (mirrors the BE's mocked suite).**
- Mock `BrowserBackend`; assert `pipeline.py`'s P0–P3 orchestration calls the right operations in order (parallels `tests/test_dispatcher_resume_contract.py`).
- **`BackendUnsupported` contract test:** every primitive the forked functions call is implemented or explicitly degraded.
- **`PageShim` fidelity tests:** `query_selector` returns an `ElementHandleShim` behaving like a Playwright handle; `keyboard.press('Control+A')` maps to select-all JS; `evaluate(js,*args)` marshals args.
- Golden tests for `selectors_mobile.json` + the self-heal agent (mirror `tests/fixtures/selfheal_golden/`).

**8.2 Live e2e harness (new).**
- `tests/e2e/run_live.py`: given a topic, run the full pipeline with `DG_BROWSER_BACKEND=ios` against the **dedicated test account** (paired per Appendix E), triggered **via the Firestore queue**, and **assert on Firestore state transitions** — research-doc `status`/`phase` progression, the `pipeline_events` sequence, `documents`/`audios` written (the same signals the FE consumes). Reuse `DG_RUN_ID` tagging.
- **"End-to-end works" =** a queue-triggered run reaches **P3 completion** (or the documented P3-on-desktop fallback), produces at least the **P1 brief + P2 deep-research docs**, and hands off to FE-owned P4/P5. **HV is a measured RATE compared to the desktop-baseline arm — NOT a binary zero.** A single wall in an otherwise-complete run that still beats baseline is a pass; report the incidence either way. (A binary-zero bar would fail a genuinely-successful port on one probabilistic wall.)
- Run the e2e on all live arms (iOS / desktop-baseline / Android-if-in-play) at least once so regressions vs baseline are visible.

---

## 9. Risk register & pre-designed pivots (the decision tree)

| If the spike shows… | Pivot to… | Why |
|---|---|---|
| iOS HID input won't land / can't hold login (0.A step 1 or 4 fails) | **Android AVD (Track B)** — **after its own Arm-3 mini-spike** (0.A-persistence + 0.B-HV on Android) clears | Never pivot to a substrate with zero HV/persistence data (that's the data-free choice D2 forbids). Android keeps a real Chrome profile across Quick-Boot snapshots; Appium can touch native/CAPTCHA UI. Accept + measure the CDP `Runtime.enable` regression. |
| iOS holds login but HV not materially below baseline (0.B fails the gate) | **Hardened desktop + orthogonal levers** | Premise refuted. Highest-leverage HV reducers are substrate-independent: residential/mobile-residential proxies, aged/warmed authenticated sessions, human-like pacing. Keep patchright. |
| Mobile web lacks a critical affordance (0.C) | **Mixed backend** | Coexistence (D3) runs the missing-affordance phase (likely P3/NotebookLM) on the desktop backend while others run on iOS. |
| Both premises hold but fidelity too low (0.D) | **Real iOS/Android device over the same channel** | Real devices out-rank any emulator on authenticity; ops cost (thermal, cabling, one-session/device, keep-awake) is the tradeoff — pilot **one** device before a farm. |
| Stage 1 holds, but a platform's login fails in `WKWebView` (0.E) — likely Google/Gemini/NotebookLM | **Ship the app for the platforms that pass; run the rest on the host-driven Stage-1 backend (mixed model)** | The embedded-WebView SSO block (§3.3) is platform-specific. Stage 1 stays a working pipeline, so the app degrades gracefully per platform instead of failing wholesale. |
| `WKWebView` HV rate materially worse than MobileSafari (0.E) | **Keep the host-driven Stage-1 backend as the production substrate; treat the app as a UX shell over the G3 companion service** | If the app's own web view is a worse bot surface, don't force automation into it — let the app be the surface/UX and keep the proven substrate doing the work. |
| Everything holds | **PROCEED (Phases 1–6, then Phase 7 app)** | Data-justified end-to-end, including the D5 app end state. |

**Standing risks through the build:** the emulator is a supervised second process (§Phase 2); the host-driven iOS backend is **macOS-only**; the mobile viewport invalidates all 1280×800 geometry; background-tab discard threatens the 90-min P2 poll; the Nuitka wheel can't be hot-patched (agent proposes source/registry changes only); the sim native-input injector (AXe/baguette) is tied to Apple's private HID signature and re-breaks on Xcode bumps — **re-lock the toolchain on every Xcode/runtime upgrade** and re-run 0.A step 1. **App-stage (D5) standing risks:** embedded-WebView SSO block (Google platforms) may permanently gate the app to a subset; `WKWebView` bot reputation is a distinct, ongoing unknown; **public App Store review will likely reject** an automation app (plan TestFlight/enterprise/ad-hoc); and iOS background-execution limits constrain unattended long runs on a real device (foreground/kiosk or the G3 companion service).

---

## 10. Appendices

### Appendix A — Verified existing-code anchors (locate by symbol; lines drift)
- Seam: `Browser@20649`, launch `@20799-20857`, stealth note `@20777-20798`, viewport `API_WIDTH/API_HEIGHT@489-490`.
- HV: `detect_human_verification@33174`, `wait_for_verification_clearance@33620`, `check_hv_gate@34089` (callers P1 chatgpt / P3 notebooklm), P2 hands-off `@34861-34894`, `_hv_setup_fail_card@33519`, `ALERT_INTENTS@14186-14214`, `HANDS_OFF_AUTO_SKIP_SEC@14182`.
- Self-heal: whole `selfheal.py`; `_INTENTS@166-240`, `decide_toggle@617-641`, `promotion_candidates@941-959`, `_SELECTOR_EVICT_FAILS=3`/`_PROMOTE_THRESHOLD=3`; wiring `research.py@103-107, 30887-30989`, only-acting heal `@33065-33074`.
- LLM ladder: `vision.py` (`propose_action@214-271`, modes `@676-695`), `models.py` (`CUA_MODEL@26`, `P2_MODEL_POLICY@100-113`), CUA loop `research.py@21314-21432`.
- Run/contract: trigger `@6177`, `run_pipeline@39944`, doc writer `@7895`, event writer `@7774-7809`, `pendingDecision@7930`, commands `_start_command_listener@8483` / `_start_device_command_listener@4918`, heartbeat `@4424`, delivery trigger `_post_fe_p4p5_trigger@7003`, `upload_audio_to_storage@6051`; clipboard `_copy_via_hijack@28400` / `_run_with_clipboard_hijack@28866`; phases/split `ARCHITECTURE.md@42-49,102-105`.
- Packaging/supervisor: `pyproject.toml@98-102`, `tools/build_compiled.py` (`TOP_MODULES=[models,prompts,vision,narrate]`; `selfheal.py` ships as source), `run_daemon_loop@49777`, `_seed_login_plain_chrome@47460`.

### Appendix B — Firestore state assertions for the e2e (what "works" checks)
Research doc `status`: `queued → ongoing → … → completed` (or the P3-fallback terminal); `phase` advances 0→3; `pipeline_events` contains the ordered `phase_start`/`agent_progress`/`login_required`(only if a wall)/…; `documents` has the P1 brief + the P2 per-platform docs; `audios` present iff P3 ran on this backend. Assert against these (they are the FE's own signals).

### Appendix C — Android quick commands (pivot Track B; gate on its own mini-spike first, §9)
```
sdkmanager "system-images;android-35;google_apis_playstore;arm64-v8a"   # Play image ⇒ real com.android.chrome + Google login (NOT AOSP/WebView)
avdmanager create avd -n sr -k "system-images;android-35;google_apis_playstore;arm64-v8a"
emulator -avd sr -no-window -no-boot-anim -noaudio     # headless; avoid -gpu swiftshader_indirect (WebGL tell) where possible
adb forward tcp:9222 localabstract:chrome_devtools_remote   # CDP bridge to on-device Chrome
```
Gotchas: Play image loses root; Quick-Boot snapshot restore 2–5 s but invalidated by any tooling upgrade; `connect_over_cdp` is single-context/low-fidelity; Playwright `_android` `newPage()` hangs (#21510) → prefer **Appium UiAutomator2 + auto-Chromedriver**; the CDP attach re-introduces the `Runtime.enable` tell.

### Appendix D — Glossary
HV = Human Verification (CAPTCHA/bot-wall). CUA = Anthropic computer-use agent. IWDP = ios-webkit-debug-proxy. HID = the host-side input-injection channel (AXe/baguette). Track A/B/C = iOS / Android / desktop backends. Seam = the `Browser` class boundary. Leaf helper = a browser-independent BE function reusable by import (§4).

### Appendix E — Environment & Setup (satisfy BEFORE Phase 0)
- **Firebase project:** the BE talks to a specific Firebase project (the one the FE/BE already use — get the project id + `FIREBASE_STORAGE_BUCKET` from the BE's config / `.dg-supervisor.env`). The e2e harness must point at the **same** project the paired device belongs to.
- **Device pairing (to trigger runs via `devices/{deviceId}/queue`):** register the harness as a paired device using the BE's own flow — `superresearch --pair` (auth: initiate-pair Cloud Function → custom-token exchange → refresh-token-scoped Firestore client, `auth/`). This yields a `deviceId` + stored credentials; the harness then writes/queues under that device.
- **Env vars:** `ANTHROPIC_API_KEY` (Vision/CUA + the self-heal agent), `FIREBASE_STORAGE_BUCKET`, the state dir `~/.super-research` (or `DG_RUNTIME_DIR` if overridden), Google creds for Firestore (the paired refresh-token credential), `DG_RUN_ID` for telemetry tagging, `DG_BROWSER_BACKEND=ios`. Optional flags: `DG_VISION_TIER`, `CUA_SCREEN_WIDTH/HEIGHT` (set to the real mobile viewport, not 1280×800).
- **Test account + 2FA:** use a **dedicated** ChatGPT/Gemini/Claude test account, not a personal one. Sign-in (incl. 2FA) happens **once, by hand, in the Simulator UI** during the seed (§Phase 2); after that the CoreSimulator data dir holds the session. Store no credentials in the repo.
- **Egress / proxy:** the BE has **zero proxy support** today (verified — no proxy code). For the Phase-0 A/B, run **all arms from the same host egress IP** (no proxy infra) so IP is held constant across arms; do **not** build proxying for the spike. Fleet-scale residential/mobile-residential proxying is a separate, later concern (and one of the substrate-independent HV levers, §9).

### Appendix F — iOS Simulator toolchain (VERIFIED early-2026; re-lock at build time)
Verified on this machine: **Xcode 26.6 (17F113)**, **iOS Simulator runtime 26.5 (23F77)**.

| Component | Pin | Role / fragility |
|---|---|---|
| Xcode | **26.6** | Year-versioned; the HID wire format is Xcode/iOS-26-specific. |
| iOS Simulator runtime | **26.5** (fallback 26.x/27) | The 5-arg→9-arg HID break lives here. |
| DOM channel | **ios-webkit-debug-proxy 1.9.2** (Jul 2025) — ✅ **verified working 2026-07-29** | Attaches to the sim's `webinspectord_sim` socket; `Runtime.evaluate`. **Fragile** — sim webview detection breaks on Xcode bumps; needs `::1 localhost` in `/etc/hosts` (IPv6, present on this machine). ⚠ Needs the explicit `-s unix:<socket>` flag — see the corrected command block below. ⚠ And commands must be wrapped in **`Target.sendMessageToTarget`**: since iOS 12.2 WebKit multiplexes the inspector per target, so a bare `Runtime.evaluate` fails with *"'Runtime' domain was not found"* — a message that reads as a missing feature rather than a missing envelope. Wait for `Target.targetCreated` with `type == "page"` (a `frame` target also appears and does not accept `Runtime`), then wrap every command; replies arrive as `Target.dispatchMessageFromTarget` with the real message as a JSON **string**, on its own inner `id` sequence. |
| Native input (sim) | **AXe** (`brew install cameroncooke/axe/axe`) **or baguette** (Xcode-26 9-arg SimulatorKit HID, digitizer `0x32`) | Trusted taps/keystrokes into the **real** MobileSafari. **Most fragile — re-lock every Xcode.** AXe README claims iOS-26.5/27 support; baguette disputes AXe is fixed → **0.A step 1 settles it empirically.** |
| ~~idb / fb-idb~~ | do NOT use for input on iOS 26 | Unmaintained since 2022; old 5-arg HID silently drops/crashes taps on iOS 26. |
| ~~pymobiledevice3~~ (for the sim) | not applicable | Its WebInspector is **physical-device-only** (usbmux/lockdown); it does **not** drive the Simulator. |

**Concrete commands:**
```
xcrun simctl list devices                        # find/boot a device UDID
xcrun simctl boot <UDID>                          # boots WITHOUT opening Simulator.app (windowless)
open -a Simulator                                 # attach UI to the booted device — REQUIRED to hand-sign-in (0.A seed)
# DOM/read channel — ⚠ CORRECTED 2026-07-29 (measured; the previous line was wrong).
# The simulator is NOT auto-discovered: a bare `ios_webkit_debug_proxy` returns an EMPTY
# device list on :9221. It needs an explicit socket, and the socket lives at a RANDOMLY
# NAMED path that is REALLOCATED ON EVERY BOOT, so it must be rediscovered after each
# `simctl boot`. IWDP's own --help example shows it under /private/tmp/ — the real path is
# under /private/var/tmp/. Read it out of the simulator's own launchd job:
SOCK=$(xcrun simctl spawn <UDID> launchctl print user/501/com.apple.webinspectord \
       | grep -oE 'RWI_LISTEN_SOCKET => \S+' | awk '{print $3}')
ios_webkit_debug_proxy -s "unix:$SOCK"            # JSON tab list on :9221, ws pages on :9222+
# native input channel (trusted taps/keystrokes into real MobileSafari):
axe tap -x <x> -y <y> --udid <UDID>               # compute (x,y) from getBoundingClientRect via IWDP evaluate
axe type '<text>' --udid <UDID>                   # or Runtime.evaluate document.execCommand('insertText', false, '<text>') for contenteditable
# persistence test (0.A step 4):
xcrun simctl shutdown <UDID> && xcrun simctl boot <UDID>   # re-attach IWDP, confirm still logged in
# NEVER: xcrun simctl erase <UDID>  — wipes the seeded login.
```
**Two-channel architecture:** DOM read + `execCommand` text via **IWDP `Runtime.evaluate`**; all trusted taps/keystrokes via **AXe/baguette HID**. `simctl` has **no** tap command (verified). Constraints: WebKit-only (**practically so — outside the EU DMA alternative-engine carve-out, no Blink Chrome on iOS**); tight Xcode↔runtime coupling; multi-GB runtimes; CoreSimulator can consume 50GB+.

### Appendix G — Native iOS app: runtime + distribution (IN SCOPE — decision A3, phase C1)

> **This is the destination, sequenced last** (agent → emulator → app). Nothing before C1 may depend on it, and C1 does not start until B1–B4 are green and C0 has cleared. The selectors, flows and agent all carry over from Stage 1. Hard constraint that shapes every option below: the compiled-Python + patchright backend **cannot run on iOS**, so C1 means either rebuilding the orchestration (G1/G2) or making the app a client of it (G3).
**Web-view choice (decisive):** use **`WKWebView`**, not `SFSafariViewController`. `SFSafariViewController` shares Safari cookies + engine but exposes **no programmatic DOM** (out-of-process) — useless for automation. `WKWebView` gives full `evaluateJavaScript`/script-injection control and a persistable `WKWebsiteDataStore`, at the cost of an isolated cookie store and embedded-WebView treatment (H3, §3.3).

**Orchestration-runtime options (pick in Phase 7 from 0.E + product needs):**
| Option | What runs where | Pros | Cons |
|---|---|---|---|
| **G1 Swift rewrite** | P0–P3 orchestration + brain reimplemented in Swift, driving `WKWebView` | Fully native, offline-capable, one artifact | Largest build; re-implements narration/self-heal/Firestore in Swift |
| **G2 Embedded Python (BeeWare / python-apple-support)** | Browser-independent Python (Firestore, narration, self-heal, alert intents) bundled into the app; Swift owns the `WKWebView`; a bridge connects them | Reuses the leaf-helper Python (§4) on-device; iOS is an official **Python 3.13** target | Bridge complexity; app size; patchright/desktop bits still excluded |
| **G3 Companion service** | Only web-view automation in-app; brain stays in the existing Python on a paired host or Cloud Run, called over the network | Fastest to a shippable app; least rewrite; keeps the proven substrate | Not self-contained/offline; needs a reachable service; if 0.E shows `WKWebView` is a poor bot surface, this is also the right fallback (app = UX shell) |

**Login/persistence in-app:** `WKWebsiteDataStore` (default persistent) holds cookies across relaunch. For platforms hit by the embedded-WebView SSO block, apply the 0.E-proven mitigation (Safari-like `customUserAgent`, or run the auth leg in `ASWebAuthenticationSession` — which uses real Safari — then copy cookies into the data store).

**Distribution ("easily installed"):**
- **Simulator:** `xcrun simctl install <UDID> path/to/SuperResearch.app` then `xcrun simctl launch <UDID> <bundle-id>`.
- **Real device:** **TestFlight** (invite testers; the practical unattended channel), **ad-hoc** (registered device UDIDs, 1-yr profile), or **enterprise/MDM** (internal fleet). Requires an Apple Developer account, a signing identity, and a provisioning profile.
- **Do not assume public App Store:** an app whose purpose is automating third-party sites will very likely be rejected under review guidelines — plan TestFlight/enterprise/ad-hoc from the start.

**Reuse guarantee:** the Stage-1 `selectors_mobile.json`, ported P0–P3 flows, and self-heal agent all run unchanged inside `WKWebView` because `evaluateJavaScript` == the IWDP `Runtime.evaluate` channel. The app build is the shell + login + runtime + distribution — not a re-derivation of the automation.

---

*This recipe leads with an empirical gate because its core assumptions are challenged by the current evidence and toolchain: (1) emulator ⇒ fewer HV (H1); (2) iOS can be the substrate with trusted input + persistent login (H2); and (3) the D5 end-state — a native `WKWebView` app — can actually sign into the platforms and isn't a worse bot surface (H3). Phase 0 is cheap, decisive, and must run before any full build — starting with the make-or-break tests that host-side HID input lands in the booted iOS-26 Simulator's real MobileSafari (0.A) and that platform login works inside a `WKWebView` (0.E). Deliver in stages: prove the pipeline host-driven, then wrap it as the app. Report the numbers honestly: a refuted premise found in a day is the recipe working, not failing.*
