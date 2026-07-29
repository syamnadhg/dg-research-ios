# Runbook

## Install and try the app right now

```bash
xcrun simctl boot EB3E3597-E62B-413B-B7E5-0FD286ACCC38   # any iOS 26.5 device
bash bin/build_app.sh EB3E3597-E62B-413B-B7E5-0FD286ACCC38
open -a Simulator
```

Unsigned, no Xcode project, no developer account — Simulator builds need none. Add `--shots` to
render the paired and unpaired states to `artifacts/app/shots/`.

The app currently runs against `PreviewBackend`, so it shows plausible state rather than live
Firestore. Everything it renders is real UI over real, tested logic; swapping in
`FirebasePairingBackend` is a one-line change once its package builds.

## ✅ Firebase iOS — done

App ID `1:441214203201:ios:47c2e9b9daaadd41b71dc0`, bundle `com.distributedglobal.superresearch`,
config at `ios/GoogleService-Info.plist` (gitignored — it carries an API key). `super-research-492814`
now has both a WEB and an IOS app. The build script bundles the plist automatically.

## One owner action remains

---

### Platform logins → the 25 selector values

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

## Building the Firebase package

The plist is in place; what is left is compiling the glue, which needs the SDK:

```bash
cd dg-research-ios/ios/FirebaseGlue && swift build   # needs network for the SDK fetch
```

⚠ That package has **never been built**, and the SDK's unavailability here is settled rather than
assumed — two independent attempts both died on the network (`swift package resolve` on ~416k objects,
and `git clone --depth 1` failing at ~6 MB with `fatal: early EOF`). It **does** parse cleanly
(`swiftc -parse`), and the *sequence* it drives is tested against a fake, so what is unverified is
**argument labels and async-ness on about a dozen well-known calls** — listed in the header of
`FirebasePairingBackend.swift`. Expect at most a signature fix or two, on a good connection.

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

## The owner's capture session — the one remaining checkpoint

Everything else in this repo is green and credential-free (`bash bin/all_gates.sh <UDID>`). This is the
step that needs a human, because the selectors the pipeline drives only exist on a **signed-in** page.

Two passes per platform, and the second one is the part that surprises people: **three of the seven keys
do not exist until a response has been produced** — `sources`, `response_container`, `activity_panel`.
On an idle page the capture reports "no candidate" for them, which reads as a tool failure when the DOM
simply has no such nodes yet.

```bash
UDID=$(xcrun simctl list devices booted | sed -n 's/.*(\([0-9A-F-]\{36\}\)) (Booted).*/\1/p' | head -1)

# 1. Sign in to the platform in the Simulator's Safari. 2FA, password manager, whatever it needs.
open -a Simulator

# 2. Pass one — the idle signed-in page. Captures composer / send / logged_in_marker / the toggle.
.venv/bin/python bin/capture_selectors.py --udid "$UDID" --platform chatgpt --url https://chatgpt.com

# 3. Ask it anything and let the answer finish, with sources visible. Then pass two.
.venv/bin/python bin/capture_selectors.py --udid "$UDID" --platform chatgpt --url https://chatgpt.com

# 4. Review artifacts/selectors/chatgpt_draft.json and merge into the real manifest. Review is not
#    ceremony: a plausible-but-wrong selector produces the P1 shape, where every click lands and
#    extraction returns nothing while the run reports success.

# 5. Then C1 runs against that platform with NO code change, and the coverage gate stops blocking:
bash bin/c1_in_app.sh "$UDID" chatgpt
.venv/bin/python bin/coverage_gate.py
```

While signed in, the other owner-gated question can be answered in the same session: **does the platform
gate any control the run must drive on `isTrusted`?** In the app's own `WKWebView` a script click cannot
move such a control (measured — `artifacts/apphost/verdict.json`, the BOUNDARY check); via AXe in the
Simulator it can. If a needed control is trust-gated, the app is a thin client for that step rather than
a full device, and that decides C1's final shape.
