# Runbook — the two owner actions, and what each one unlocks

Everything that could be built and verified without credentials is done. Two inputs remain, and
this is the shortest path from them to a finished iOS track.

**Do them in either order.** They unlock different clauses and do not depend on each other.

---

## Action 1 — platform logins → the 25 selector values

**Unlocks:** a P0–P3 run against *real* platforms, in the Simulator and in the app.

```bash
xcrun simctl boot EB3E3597-E62B-413B-B7E5-0FD286ACCC38   # or any iOS 26.5 device
open -a Simulator                                        # needed to type a password by hand
```

Sign in **once** per platform in Safari inside the Simulator: ChatGPT, Gemini, Claude, NotebookLM.

> ⚠ **Do not `simctl shutdown` straight after signing in.** Cookies take a few seconds to reach
> `Cookies.binarycookies`, and shutting down first loses the session in a way that is
> indistinguishable from "the platform logged us out". B0a measured the flush at ~3s. Give it ten.

Then, per platform:

```bash
cd dg-research-ios
python bin/capture_selectors.py --udid <UDID> --platform chatgpt --url https://chatgpt.com
python bin/capture_selectors.py --udid <UDID> --platform gemini  --url https://gemini.google.com
python bin/capture_selectors.py --udid <UDID> --platform claude  --url https://claude.ai
python bin/capture_selectors.py --udid <UDID> --platform notebooklm --url https://notebooklm.google.com
```

Each writes `artifacts/selectors/<platform>_candidates.json` (everything it saw, ranked) and
`artifacts/selectors/<platform>_draft.json` (a manifest that loads as-is).

**Review the drafts, then merge into `selectors_mobile.json` at the repo root.** Review rather than
paste: the tool only proposes rank‑1–3 visible candidates, but a plausible‑but‑wrong selector
produces the P1 failure — every click lands, extraction returns nothing, the run reports success.
A *gap* fails loudly at first use; a wrong value does not.

Check progress at any point:

```bash
PYTHONPATH=. .venv/bin/python -c \
  "from emubackend import selectors; m=selectors.load_manifest(); print(m.coverage()); print(m.missing())"
```

### Two things to carry into the review

- **A step predicate must assert *acceptance*, not *completion*.** A "send" predicate that waits for
  the response cannot be true when it is evaluated — the response arrives later — so it reports a
  false failure on every run, and with acting enabled it escalates onto a healthy page every time.
  Use "the container appeared", "the composer cleared", or best of all an observed request.
- **Never reuse the desktop sidebar markers for `logged_in_marker`.** They collapse on mobile and
  would report a logged-out page as logged in.

---

## Action 2 — register an iOS app → `GoogleService-Info.plist`

**Unlocks:** live-project pairing — the app appearing as a real device in the web app.

In the Firebase console for **`super-research-492814`** (only a WEB app exists today), add an **iOS**
app, then drop the downloaded `GoogleService-Info.plist` into `dg-research-ios/ios/`. It is
`.gitignore`d — it carries an API key.

> You chose to do this in the console rather than have me use your authenticated `firebase` CLI, so
> nothing here does it for you.

Then:

```bash
cd dg-research-ios/ios/FirebaseGlue && swift build   # needs network for the SDK fetch
```

⚠ That package has **never been built** — the SDK could not be fetched in the environment this was
written in. Expect at most a signature fix or two; the API surface it uses is listed in the header of
`FirebasePairingBackend.swift`, and the *sequence* it drives is already tested against a fake.

### The one open question it will answer

Whether the Firestore **iOS SDK** will perform an *unauthenticated* `getDocument` on
`devices/{id}/pending/{hash}`. The rule permits it (`allow get: if true`); whether the SDK does is
untested. `pollPending` implements the SDK path **and** a REST fallback, so pairing works either way
— but note which path was taken, because guessing wrong stalls pairing at the one step with no error
surface: the poll simply never returns a token.

### And the claim round-trip needs a human

Someone has to enter the pair code in the web app and confirm the Account page shows the device
**Online**. Local success is not the pass criterion.

---

## Then: the verification chain, in order

```bash
cd dg-research-ios

# offline — must be green before anything else
PYTHONPATH=. .venv/bin/python -m pytest emubackend/tests -q     # 316
python bin/mutate.py                                            # 80 mutations, all CAUGHT
(cd ios && swift test)                                          # 53

# the real rules, no credentials (start the emulator first)
firebase emulators:start --only firestore --config firebase.emulator.json --project demo-sr &
PYTHONPATH=. .venv/bin/python bin/rules_verify.py                # 14/14

# the Simulator
python bin/b0a_gate.py    --udid <UDID>                          # substrate, 4/4
python bin/b1_smoke.py    --udid <UDID>                          # the seam, 16/16
python bin/e2e_simulator.py --udid <UDID>                        # P0-P3 + reboot, 12/12
bash   bin/c0_in_app.sh   <UDID>                                 # in-app WKWebView, 11/11
```

Once `selectors_mobile.json` is filled, point `e2e_simulator.py` at it instead of the mock manifest
and the same run exercises real platforms. Nothing else changes — that is the whole point of the
data-driven browser layer.

---

## What is still genuinely out of reach, and why

- **A golden fixture from a real backend run.** `backend.log` carries no event stream (25 MB, none of
  it emissions), so capturing one needs Firestore read credentials. The compare engine is built and
  an owner-supplied capture drops straight in.
- **C1 on a real device.** Needs an Apple Developer account for signing and provisioning. The
  Simulator needs none — that is why the in-app gate could run at all. Plan **TestFlight / ad-hoc /
  enterprise**: public App Store review will very likely reject an automation app.
- **Whether the deployed ruleset matches `firestore.rules` in the repo.** Unverifiable read-only, and
  the contract doc names that drift as the historical cause of unexplained 403s. Worth a
  `firebase deploy --only firestore:rules` dry run before trusting the 14/14.
- **A0's failure taxonomy.** Needs the daemon restarted with the observation flags armed
  (`docs/` + recipe §0.5.10). Config only, no code — but it is the owner's machine and a release e2e
  is pending, so never cycle it unilaterally.
