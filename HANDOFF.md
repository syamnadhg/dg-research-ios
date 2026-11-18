# SuperResearch — Research Computer handoff

> # ⚠ SUPERSEDED 2026-08-08 — onboarding only, do not execute
>
> **This file did its job.** It was the one-time bootstrap for a fresh session on this Mac
> (unpack, toolchain, repos, memory), all of which is now long done. Four things in it are
> **actively wrong today**, so read it for history and take instructions from
> `EmulatorRecipe.md` v5.1 instead:
>
> 1. **§3's repo table is stale.** `dg-research-ios` is at `main` well past `dfddb4e`;
>    `dg-research-backend` has **no** uncommitted files (that wave was committed and pushed
>    upstream, and the local copy was a stale duplicate — see `docs/DEVIATIONS.md`);
>    `dg-research` has moved with the owner's authorisation.
> 2. **§3 rule 1 — "never discard the backend's uncommitted files" — no longer applies**, and
>    the guard that still shouts it is describing work that is safely upstream. Do NOT
>    `git stash pop` to make it quiet.
> 3. **§5a says to regenerate the A8 baseline first thing. Do not.** The reasoning it gives was
>    right for a box where the guarded repos would never move; they have since moved, on
>    purpose. See the A8 block in `EmulatorRecipe.md` §0.
> 4. **The ⛔ A8 rule at the end is amended** — the frontend is writable with the owner's
>    say-so, per change. The backend is still read-only.
>
> What is still worth reading: **§2's toolchain table**, **§4's reading list**, and **§5's
> "what proven actually means"**.

**You are a fresh Claude Code session on a second Mac. Read this file top to bottom and do
the steps in order.** Your work is the **iOS / emulator track**. The primary Mac is running
the backend end-to-end and the Hermes work in parallel — stay out of both.

Built 2026-08-05 from the primary Mac. Everything here is the state as of that moment,
including work committed nowhere.

**Everything in this zip belongs in one folder: `~/Downloads/SuperResearch/`.** That is
where the session on the primary machine runs from, and where yours should too.

---

## 1. Unpack

```bash
unzip SuperResearch-handoff-20260805.zip -d ~/Downloads/
cd ~/Downloads/SuperResearch
```

**Use `~/Downloads/SuperResearch` exactly.** Claude Code names its per-project memory
folder after the project path, so an identical path makes step 3 a single copy. A different
path works, you just adjust one folder name.

The folder then holds the four repos, `claude-memory/`, this file, and three iOS documents.

---

## 2. This machine starts bare — install the toolchain first

Nothing below is assumed present. **`EmulatorRecipe.md` Appendix B is the pinned
toolchain** (re-locked on any Xcode bump) — read it, then:

| Need | Why it stops you |
|---|---|
| Homebrew + `uv` | Step 2's venv command is `uv`; without it nothing else runs |
| **Xcode** + the **iOS 26.5 Simulator runtime** | Every `xcrun simctl` call and `swift build` |
| **AXe** — `brew install cameroncooke/axe/axe` | The *only* trusted-input channel. `simctl` has no tap command, and scripted taps read as `isTrusted === false`, which the platforms reject. Most fragile piece — re-lock every Xcode |
| **`ios-webkit-debug-proxy` 1.9.2** | The DOM/read channel |
| **`::1 localhost` in `/etc/hosts`** | The proxy fails without it |
| `firebase-tools` (Node) **+ Java** | `bin/c0fe_gate.sh` runs the Firestore + auth emulators |
| `export PATH=/opt/homebrew/bin:$PATH` | AXe and the proxy live there |

⚠ **Simulator state did not travel and cannot.** You have no booted device, no installed
app, and **no platform logins** — the primary's cookie jars hold all four sign-ins and are
not transferable. The `RUNBOOK.md` boots a specific device UDID that exists only on the
primary; create your own and use that. Owner sign-in per surface is a human step; ask.

### Dependencies — regenerate, never copy

```bash
cd ~/Downloads/SuperResearch/dg-research-ios
uv venv && uv pip install -e '.[dev]'
```

⛔ **`'.[dev]'`, not `.`** — `pytest` and `websocket-client` are in the `dev` extra. Install
the base only and step 5's mandated `pytest` run dies with *No module named pytest*, and the
DOM channel has no websocket library.

Also regenerate as needed: `dg-research-ios/ios/**/.build` via `swift build`. You almost
certainly never need `dg-research-backend/.venv` or `dg-research/node_modules`.

**Not in the zip:** `dg-research-backend/.dg-supervisor.env`, which holds two API keys. You
do not need it. `dg-research-ios/ios/App/GoogleService-Info.plist` **is** included despite
being gitignored — the app cannot start without it, and it carries a Firebase client key.
Treat the folder as containing a credential.

---

## 3. Establish the four repos

Every repo ships with its full `.git`, so history, branches and remotes are already wired.
Nothing needs re-cloning. Verify:

```bash
cd ~/Downloads/SuperResearch
for d in dg-research-ios dg-research-backend dg-research dg-hermes-fleet; do
  echo "── $d"; git -C $d remote -v | sort -u; git -C $d status -sb | head -1
done
```

| Repo | Remotes | Branch | On arrival |
|---|---|---|---|
| **`dg-research-ios`** | `origin` → personal `dg-research-ios` | `main` | Clean, fully pushed at `dfddb4e`. **This is your repo** |
| `dg-research-backend` | `origin` → personal · `org` → org backend | `master` | **20 uncommitted files.** Read-only to you |
| `dg-research` | `origin` → personal · `org` → org frontend | `main` | Clean. Read-only to you |
| `dg-hermes-fleet` | `origin` → org fleet repo | `DGOPS-8583-super-research` | Committed locally, branch unpushed. Not yours |

### ⛔ Four rules about git

1. **Never discard the backend's uncommitted files.** No `git checkout`, `git restore`,
   `git stash`, `git clean` in `dg-research-backend`. That wave exists nowhere else and the
   primary machine is about to commit and push it. **This is the single worst thing you
   could do on this machine.**
2. **Do not commit in the backend either.** Committing is not discarding, but it moves the
   HEAD that the A8 guard pins, and it takes the wave out of the primary's hands.
3. **Only `dg-research-ios` is yours to change** — enforced in code, see step 5.
4. **Push nothing** without the owner asking.

`git fetch` may prompt for credentials (HTTPS remotes). You do not need to fetch to start —
everything is local.

**Deliberately left on the primary Mac:** `org-stage/` (staging for two open org pull
requests) and `wave-review/` (backend mutation harnesses). Several memory notes point at
both as live — they are, just not here. Ignore those pointers.

---

## 4. Load the memory, then actually read it

```bash
mkdir -p ~/.claude/projects/-Users-$(whoami)-Downloads-SuperResearch
cp -R ~/Downloads/SuperResearch/claude-memory \
      ~/.claude/projects/-Users-$(whoami)-Downloads-SuperResearch/memory
```

⚠ **The conversation from the primary machine is not in this zip** — only these notes. The
catch-up below is therefore not optional; it is the only context you get.

`MEMORY.md` is the index. Read it, then these six, in order:

| Read | For |
|---|---|
| `emulator-recipe-v5` | Which recipe file is authoritative |
| `emulator-pipeline-initiative` | The initiative's shape and decisions A1–A10 |
| `b0a-substrate-passed` | What is proven — **substrate** evidence, see the warning in step 5 |
| `ios-selector-capture-state` | ⚠ Self-flagged partly stale. Trust its *mechanisms*, re-check its counts |
| `ios-firestore-contract` | The pairing/queue/events contract, its traps and unknowns |
| `ios-session-state-0730` | ⚠ Self-flagged partly stale — the repo is now clean and fully pushed |

Two are flagged stale in their own descriptions. That is deliberate: verify against code
before acting. Both also end with a link to a note that does not exist — ignore it.

Then, in the repo: `dg-research-ios/README.md`, `docs/RUNBOOK.md`, `docs/DEVIATIONS.md`.

### The three loose documents in this folder

- **`EmulatorRecipe.md` — v5, the source of truth.** See step 5 for how to read it.
- **`EmulatorRecipe.v4-superseded.md` — history only.** Do not plan from it.
- **`IOS-BUILD-GOAL-PROMPT.md` — SUPERSEDED, history only. Do not execute it.** It predates
  v5: it points at a "§0.5" that no longer exists, its checkpoints describe work already
  done, its toolchain notes describe the *primary* machine, and it instructs installing the
  backend as `-e ../dg-research-backend`. **That instruction is now an A8 violation** — an
  editable install regenerates `superresearch.egg-info/` inside the backend checkout, which
  is exactly what the purity guard content-digests, in the checkout holding those 20
  irreplaceable files. Read it for intent, never for instructions.

**Before touching anything, say back in your own words:** what is proven, what remains, and
what A8 forbids. If you cannot, read again.

---

## 5. The goal — resume the emulator pipeline

Picking up where the primary left it. Stood down by the owner 2026-07-30, untouched since;
last commit `dfddb4e` on 2026-07-31. Nothing about the plan has changed.

### How to read v5 — this is not the v4 structure

`EmulatorRecipe.md` §0 tells you how to use it, and it is not "read §0.5 only" (that was
v4, and v5 supersedes every earlier §0.5 plan). What v5 says:

1. **Read §1, §2 and §3 before touching code.** §2 corrects a structural
   misunderstanding that cost a full session; §3 is a hard gate that decides the design of
   everything downstream.
2. **Do §3's spike first and record the result** in `docs/DEVIATIONS.md` either way. A
   negative result is a finding, not a failure.
3. **Work §12's list in order.** Critical path is marked.
4. Every claim carries a `file:line` anchor read on 2026-07-30 — locate by symbol; fix
   stale anchors in place.
5. **Where §15 says UNRESOLVED, do not invent an answer. Ask.**

Also read **§0.1 — what this work can destroy** before any real run. Deep Research quota is
a hard monthly cap on the owner's paid accounts, and bot-flagging risk falls on accounts
that cannot be replaced. Iterate against a **captured DOM**, not live runs.

### ⚠ What "proven" actually means — §2's reframe

The memory notes say the pipeline runs in the real Simulator, survives reboot, runs inside a
real native app, that the app is installable without a developer account, and that contract
writes verified against the real security rules. **All true, and all of it is *substrate*
evidence. None of it is pipeline parity.**

§2 is blunt about why: the iOS `P0–P3` is *a different pipeline wearing the same phase
numbers*. The product of a real run is a **markdown document**, and this repo has no
representation of one — P1 captures nothing, P2 runs one platform on the topic instead of
three on the brief, P3 harvests citation label text rather than the report. Do not cite
substrate green as product green.

### First actions, in this order

**a. Regenerate the A8 purity baseline.**

```bash
cd ~/Downloads/SuperResearch/dg-research-ios
PYTHONPATH=. .venv/bin/python -c "from emubackend import purity; purity.save_baseline()"
```

The guard pins both sibling repos' HEAD and flags any change. The shipped baseline is
stale: it pins older backend and frontend commits, because the owner authorised work in both
while this goal was down and both moved. On the primary machine regenerating was
deliberately deferred (those repos are about to move again). **Here they will not move at
all, so the baseline you take is correct for this machine.**

⚠ Two expected consequences, so neither reads as damage:

- This **writes a tracked file**, `fixtures/a8_baseline.json`. Your otherwise-clean repo is
  dirty from minute one. Expected — do not revert it, do not push it.
- The baseline records that the backend's `build/` and `dist/` exist. They shipped in this
  zip precisely so the guard sees the same shape the primary sees.

**b. Confirm the guard, then the suite.**

```bash
PYTHONPATH=. .venv/bin/python -c "from emubackend import purity; purity.assert_pristine()"
PYTHONPATH=. .venv/bin/python -m pytest emubackend/tests -q
```

⛔ **Run the baseline command FIRST.** The suite contains the guard's own tests, so before
regenerating it is **red** — measured on the primary just now: **2 failed, 589 passed, 3
skipped** of 594 collected, both failures in `test_a8_purity.py`, both caused by the stale
baseline. The failure prints **"A8 VIOLATED … stop and fix it"** followed by the moved
HEADs and the 20 modified backend files.

**That banner is not telling you to clean the backend.** The nearest-looking fix — making
the backend match the baseline — is exactly rule 1, the worst thing you can do here. The
baseline is wrong, not the backend. Regenerate, then re-run and report what you get.

**c. Then Gate Zero — §3, item 1 on the critical path.**

Where does the report DOM actually live? What is *known*: against real ChatGPT with Deep
Research on, the read returned 15 chars, then 204, then sat on "Pro thinking" while the stop
control was still on screen, and the harvest found zero sources. What is **suspected but not
established** is that the report sits in a cross-origin iframe — an earlier draft asserted
that as fact; §3 lists every hypothesis consistent with those three reads. Resolve it, record
the result in `docs/DEVIATIONS.md` whichever way it goes. **Nothing else starts until this
resolves.**

### The remaining work is §12, not three items

⚠ The memory notes mention a Safari-login credential gate, contract writes still on the
signed-out harness, and eight missing selectors. Those are **real but a subset** — the
selectors are §12 item 12. The actual list is §12's nineteen items, critical path
**1 → 2 → 12 → 7 → 8 → 14 → 16 → 17**, and it includes building things that do not exist
yet: the `innerHTML` primitive and markdown port, the extraction ladder with wrong-document
guards, the `documents/` writer, real P1 brief capture, three-platform P2, NotebookLM upload,
and audio with a Firebase Storage client. Items **3, 4 and 13** are genuinely off the
critical path — do those while a long real run is in flight.

§13 is the definition of done. §14 is standing rules on how the work gets done. `bin/` holds
the gate per stage (`all_gates.sh`, `b0a_gate.py`, `c0fe_gate.sh`, `c1_contract_gate.sh`,
`b1_smoke.py`) — those gates *are* done-ness, not a suggestion.

### ⛔ A8 — the one hard rule

**`dg-research-backend` and `dg-research` are not modified by this repo. Not a line.** The
backend is a read-only dependency reached through `emubackend/berepo.py`. Enforced by
`purity.assert_pristine()`, which pins both HEADs, flags tracked-file changes, flags *new
untracked* files, and content-digests `build/`, `dist/` and the egg-info — those are
gitignored in the backend, so a write there is invisible to `git status` rather than
harmless.

If you want to change the backend to make something work: stop, write down what you needed
and why, and ask.

### How the owner wants to be answered

Tight summary, then **fix by fix**, a line or two each: what broke → what was done → fixed
yes or no. No prose walls, no ticket numbers, no code identifiers in chat. Keep the honest
part — what is still broken and what you deliberately did not fix.

Tests land **with** each fix, and everything gets mutation-tested. A test that passes against
a guard that cannot run is not a test: assert the condition, never merely that an identifier
is present.

---

## 6. What the primary Mac is doing, so you do not duplicate

In flight there: a backend end-to-end run, then closing two open tickets, then verifying the
personal remotes, restaging the org pull requests with rewritten messages, building the
wheel, and finally the Hermes work. **None of it is yours.** If something here seems to need
a backend change, that is a question for the owner, not a task.

---

## 7. Report back, then wait

Once steps 1–4 are done and you can state the goal in your own words, tell the owner:

- repos and memory in place, plus anything that did not match this document
- the purity-guard result and the suite numbers **after** regenerating the baseline
- the Gate Zero result, if you got that far, recorded in `docs/DEVIATIONS.md`
- the next concrete step you intend and why that one

Then wait for their go-ahead.
