> # ⛔ SUPERSEDED — history only, do not execute
>
> Replaced by **`EmulatorRecipe.md` v5.1**, which is the goal in full (2026-08-08). This file predates
> `EmulatorRecipe.md` v5: it points at a "§0.5" that no longer exists, most of its build order
> and every human checkpoint below is already done, its A8 rule has since been amended by the
> owner, and its instruction to install the backend as `-e ../dg-research-backend` would write
> `superresearch.egg-info/` into a guarded checkout. Read it for intent, never for steps.

# Goal: build Super Research's iOS track end to end

Build the whole thing: the emulator-driven pipeline, the supervisor agent, and the native iOS app. Work autonomously through everything that does not need credentials or a console, and **stop and ask** at the human checkpoints listed below rather than guessing or working around them.

## Read first

1. **`/Users/syamnadhg/Downloads/SuperResearch/EmulatorRecipe.md` — §0.5 ONLY** (701 lines; §1 onward is reference material that §0.5 supersedes). Decisions A1–A10.
2. Memory **`emulator-pipeline-initiative`** — read its two newest sections (the A8 isolation rule, and the Fable review + fortification). They correct earlier layers in the same file; when they disagree with older text, they win.
3. Memory **`g-ticket-progress`** and **`org-pr-staging-state`** — only so you know what NOT to disturb: a release is mid-flight (e2e → publish → org push), owner-driven.

⚠ Line numbers in the recipe have drifted. **Locate by symbol, never by line.**

## The one hard constraint (A8)

**`dg-research-backend` and `dg-research` are not modified. Not one line.** Everything lives in the new sibling repo `~/Downloads/SuperResearch/dg-research-ios`. The BE is a **read-only dev dependency** (`-e ../dg-research-backend`, source checkout — the shipped wheel is Nuitka-compiled and cannot be reused or edited). The FE is never forked; the iOS side must speak the existing Firestore contract so the web app needs no changes.

If you find yourself wanting to edit the BE to make something importable: **vendor it instead** (see the contract layer below).

## Build order (A9 — emulator first, agent later)

**C0-FE → B0a → B1 → agent (A1/A2) → C0 → C1.** The agent comes after B1 because its predicates can only bake on iOS-orchestrator runs, and A2 can only generate `selectors_mobile.json` from captured Simulator DOM — the generator cannot precede its own input.

### Step 0 — scaffold

Create `dg-research-ios` per §4's tree. Prove `import research` works from its venv (it does: clean, 0.4s, no import-time side effects).

⚠ **Namespace hazard:** the editable BE install claims the top-level names `research, models, prompts, vision, narrate, selfheal, auth, scripts`. **Never create your own top-level `models`, `auth`, or `scripts` module.**

### C0-FE — the cheapest gate, run it first

Bare SwiftUI + Firebase Apple SDK. No browser, no automation. Feasibility is already confirmed: the rules admit a custom-token client end to end — no `serverTimestamp` sentinels, no Admin-SDK-only writes in the device path, no client-side collection-group queries.

Two traps that are already known — do not rediscover them:

1. **The server mints the pair code, not the device.** `POST /api/devices/initiate-pair` allocates the code and creates the device doc (client create is `allow create: if false`). The device generates only a 256-bit pollSecret and sends its SHA-256, then displays the returned code. Only hyphenation (`format_for_display`) and the QR render are device-side.
2. **ATOMIC PAIR-CONFIRM — the step whose absence fails silently.** The claim route sets `expireAt: now+5min` under a Firestore TTL. The device must write the field-locked `{pairConfirmedAt, expireAt: FieldValue.delete(), lastHeartbeat, status}` update — touching **only** the `hasOnly()`-listed fields — inside that window, or the device doc is deleted and the FE never shows it. Without this the gate appears to pass and then vanishes.

Then: poll `pending/{secretHash}` (`allow get: if true` is what makes the pre-auth poll legal), `Auth.signIn(withCustomToken:)`, hold a snapshot listener on `devices/{deviceId}/queue`, and write `pipeline_events` in the BE's exact shape — numeric `seq`, `timestamp`, payload `deviceId`, ms-ints throughout.

**Done when:** the FE Account page shows the device Online — not merely local success.

### B0a — substrate mechanics, no credentials

`idb` is **broken on iOS 26**; `pymobiledevice3` is **physical-device-only, not a Simulator tool**. The working pair is **`ios-webkit-debug-proxy`** for DOM reads plus **AXe** (or baguette) for trusted taps. Neither is installed yet. Xcode 26.6 and the iOS 26.5 runtime are present.

Two channels are genuinely required: synthetic JS events are rejected by the chat SPAs, and ProseMirror needs `execCommand('insertText')`.

**Done when:** a trusted tap lands (`isTrusted === true`) on a plain page, **on a scrolled page, and with the keyboard open**; DOM reads round-trip; a cookie set before `simctl` reboot survives it.

⚠ The scrolled-and-keyboard assertions are not optional. Coordinate mapping goes through Safari chrome offsets, URL-bar collapse/expansion, `visualViewport` scroll/zoom offsets and keyboard insets — a toy-page-only assertion passes B0a and then dies in P2.

⚠ **STOP-AND-REPORT BOUND:** if AXe cannot produce a trusted tap after a bounded number of approaches, **stop and report**. A fast "this substrate does not work" is a *good* outcome — it is what the gate exists to find, and it saves the entire Track B budget. Do not keep inventing workarounds.

### B1 — the seam and the vendored contract layer

`BrowserBackend` + `PageShim` per §5, then the vendored contract layer.

⚠ **§4's "reuse the browser-independent leaf helpers by import" is mostly fiction.** Only `ALERT_INTENTS`, `auth/`, `narrate.py` and `selfheal.py` are genuinely importable. `_update_firestore_research`, `_emit_to_firestore`, `emit_event`, `_persist_pending_decision`, `upload_audio_to_storage` and `_post_fe_p4p5_trigger` are all welded to module globals that only `setup_firestore_run` arms — **and that function writes `owner.json` into `Path(__file__).parent/"queues"/<run_id>`, inside the BE checkout, where the production daemon's disk-restore scans. Calling it would contaminate the running product. Never call it.**

**Vendor ONE cohesive `emubackend/contract.py`** (~1.5–3k lines): the Firestore-contract client, `_be_payload`, `_grpc_write_with_heal` and its 403-heal, the event writer plus its seq guard, the pendingDecision lifecycle, the heartbeat. Copy it once with source-anchor comments. **Do not copy helpers one-off as needs arise** — that is how a vendored layer becomes an unmaintainable fork.

⚠ **A10 — device identity.** `DG_RUNTIME_DIR` **does not exist in the code**; the state dir is hardcoded (`research.py:4046`, `auth/keystore.py:43`, the `install_uuid` at `keystore.py:278`). Vendor `auth/` with those three path constants **parameterized**, so the iOS pipeline is a genuine second paired device with its own state dir. Otherwise `--pair` overwrites the production daemon's identity, or you authenticate as the same `deviceId` and race it on one queue against a file-based worker-sentinel protocol you do not participate in.

**Never write into `~/.super-research/` or the BE checkout's `queues/`.** Those belong to the running product.

### Scope, stated honestly

135 functions take `page`/`browser` = **24,764 lines** — the fork-and-rewrite-for-mobile layer, always the port's price. The orchestration A8 converts to reimplementation is **~9–11k lines** of contract semantics. The honest label is *a second backend implementing the same Firestore contract*. The cost is not the line count — it is re-deriving behaviours that took months of production fixes: pause/resume invariants, pendingDecision clobber rules, seq-cursor semantics, multi-worker claim races.

**Buy convergence with record/replay golden fixtures:** capture real BE runs' Firestore write sequences and assert the new orchestrator reproduces them. Start capturing early — at 1–3 runs/week the material accrues slowly, and this is the only mechanical check that the second backend is contract-faithful. No automated e2e exists today, so this is also the first one.

### Agent (A1/A2) — after B1

Write the iOS orchestrator's mutating intents **already wrapped**, each with an `outcome_predicate` — copy the pattern from `research.py::_selfheal_try`, edit nothing there. Predicates bake per-intent: **≥20 runs in which that intent actually executed, zero false positives** (runs, never wall-clock). Unbaked predicates may log, never escalate. A predicate that fires on a healthy page is reverted or rewritten, never tuned in place.

Import `vision.py` / `selfheal.py` rather than reimplementing or editing them — take the machinery, supply your own selectors and geometry. The brain is portable; the notes are not.

## Human checkpoints — STOP and ask

The owner has committed to helping at each of these. Do not attempt workarounds.

1. **Register an iOS app in the Firebase project** → `GoogleService-Info.plist` with the bundle ID. **C0-FE cannot authenticate without it.** Ask early, since C0-FE runs first.
2. **Real platform logins + 2FA** (ChatGPT / Gemini / Claude / NotebookLM) — needed for B0b and for mobile selector discovery in B1–B3. One-time per platform; the session persists via the CoreSimulator data dir.
3. **The FE claim round-trip** — someone must enter the pair code in the web app and confirm the Account page shows the device Online.
4. **C0** — whether a human can sign in inside a bare `WKWebView` is the entire question; it cannot be automated on the owner's behalf. Google blocks OAuth in embedded WebViews (`disallowed_useragent`), so Gemini/NotebookLM are the likely casualties.
5. **Apple Developer account** — signing, provisioning, and TestFlight/ad-hoc distribution for C1 on a real device. The Simulator needs none of this. Public App Store review will very likely reject an automation app.
6. **Restarting the production daemon** — needed to arm A0's observation flags. Owner's machine, and a release e2e is pending, so never cycle it unilaterally.

## A0 arming (config only, not code — does not violate A8)

When the owner is ready to restart the daemon:

```
DG_SELFHEAL_ENABLED=1
DG_SELFHEAL_CAPTURE=1
DG_SELFHEAL_CAPTURE_LOG=<abs path>/.super-research/logs/selfheal_capture.jsonl
DG_SELFHEAL_SHADOW_LOG=<abs path>/.super-research/logs/selfheal_shadow.jsonl
# DG_SELFHEAL_ACT stays UNSET — that is the switch that clicks.
# DG_VISION_TIER=shadow held back: real Anthropic spend, and Vision won't act on desktop under A8.
```

⚠ **The absolute log paths are load-bearing.** Verified `selfheal.py:137–148`: both logs default to `logs/` **relative to the process CWD**, not `~/.super-research/logs/`. Armed without them, A0 collects where nobody looks. Verify with `ps eww -p <pid>` after the restart, not by reading the env file.

## Kill criteria — pre-agreed, do not relitigate in the moment

- **B0a fails** (no trusted taps, or login doesn't survive a reboot) → the iOS Simulator path is dead. Revisit Android (Chrome + CDP) or stay desktop-only. Report; do not push on.
- **C0 fails for every platform** → the self-contained app is not achievable; the app becomes a thin client (Appendix G3) or is dropped. Decide the moment C0 reports.
- **A1 predicates can't reach ~zero false positives** → do not proceed to live escalation. Ship the offline agent and stop. This is an acceptable, valuable outcome.

## Definition of done

A full P0–P3 run completes against Safari in the Simulator and survives a Simulator reboot still logged in; the same run completes from inside the native iOS app for every platform that cleared C0; the app pairs like the BE does (code + QR), is claimed from the existing web app, and registers as a normal device against the **unchanged** Firestore contract so the existing FE needs no fork; and `dg-research-backend` / `dg-research` show **zero** modifications throughout.
