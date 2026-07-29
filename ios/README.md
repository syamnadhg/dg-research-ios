# ios/ — the SwiftUI app (C0-FE, then C1)

## ⬅ Drop `GoogleService-Info.plist` here

C0-FE cannot authenticate without it. Register an **iOS app** in the Firebase console for
project `super-research-492814` (only a WEB app exists today), then put the downloaded
`GoogleService-Info.plist` in this directory.

It is `.gitignore`d — it carries an API key and must not be committed.

## What C0-FE has to prove

The FE-parity gate: this app must pair exactly as the backend does — pair code + QR, claimed
from the existing web app — and register as a normal device against the **unchanged** Firestore
contract. Pass ⇒ C1 can be a real paired device. Fail ⇒ C1 becomes a thin client.

The contract is already extracted and does not need re-deriving from the backend:
**`../docs/FIRESTORE_CONTRACT.md`**. Read §1 (the 13-step pairing sequence), §5 (the atomic
pair-confirm) and §10 (the traps) before writing any Swift.

Three things from that document that decide whether this gate passes:

1. **The server mints the pair code, not the device.** `POST /api/devices/initiate-pair`
   allocates it and creates the device doc; client create is `allow create: if false`. The
   device generates only a 256-bit pollSecret and sends its SHA-256 (of the **hex text** — see
   TRAP-01). Device-side pairing logic is just display hyphenation and the QR render.
2. **`pending/{secretHash}` is a SUBCOLLECTION of `devices/{deviceId}`**, with
   `allow get: if true` and `allow list: if false`. So the device must already know its
   `deviceId` to poll pre-auth — `initiate-pair` returns it.
3. **The atomic pair-confirm is part of every heartbeat tick, not a one-off.** The claim route
   sets `expireAt: now + 5min` under a Firestore TTL; the heartbeat writes
   `{pairConfirmedAt: true, expireAt: <delete>, lastHeartbeat: <int ms>, status: "active"}`.
   Miss the window and the device doc is deleted, and recovery is **impossible**
   (`allow create: if false`, and the synth update rule reads a `syntheticDeviceUid` that no
   longer exists). Note `pairConfirmedAt` is boolean `true`, not a timestamp.

⚠ The device doc carries **three** separate `allow update` rules, which Firestore ORs, each
with its own `hasOnly()` list. A write mixing fields from two lists satisfies **neither** and
is rejected wholesale.

**Pass criteria:** the FE Account page shows the device **Online** — not merely local success.

## Package layout, and why there are two

| Package | Builds offline? | Tested? |
|---|---|---|
| `ios/` — `SuperResearchDeviceCore` | **yes** | **53 tests** |
| `ios/FirebaseGlue/` — `SuperResearchFirebase` | no (fetches firebase-ios-sdk) | **not compile-verified here** |

The split is deliberate. Adding a Firebase dependency to the core would make `swift test` require a
~416k-object clone of `firebase-ios-sdk`, which did not complete in the environment this was written
in. Keeping it separate means all the logic worth testing stays runnable offline — and that is
genuinely all of it: secret hashing, code formatting, the write shapes, the pairing sequence, the
five-minute deadline, and the QR payload.

`FirebaseGlue` is the mechanical remainder: HTTP for `initiate-pair`, `signIn(withCustomToken:)`,
`getDocument`, `updateData`, `addSnapshotListener`. **It has never been built.** The API surface it
uses is listed in the file header so it can be checked against whichever SDK version you resolve;
expect at most a signature fix or two.

```bash
cd ios              && swift test    # 53 tests, offline, no plist
cd ios/FirebaseGlue && swift build   # needs network + a resolved firebase-ios-sdk
```

### The one genuinely open question

Whether the Firestore **iOS SDK** will issue a `getDocument` with no signed-in user, or insists on at
least an anonymous session. The rule permits the read (`allow get: if true` on
`pending/{secretHash}`), so REST unambiguously works; whether the SDK path does is untested.
`pollPending` implements **both** and falls back, because guessing wrong stalls pairing at the one
step with no error surface — the poll just never returns a token. Recorded in
`docs/FIRESTORE_CONTRACT.md` §13.
