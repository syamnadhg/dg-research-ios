# Super Research — Firestore / Storage / Pairing Contract

**Authoritative spec for `dg-research-ios`.** Two consumers must be able to implement against
this document without re-reading the backend or frontend:

| Consumer | Phase | Language | Transport |
|---|---|---|---|
| iOS app client | **C0-FE** | Swift + Firebase iOS SDK | Firestore SDK (gRPC) + Storage SDK |
| Vendored contract layer | **B1** | Python | Firestore gRPC *or* Firestore REST |

Every statement below was re-verified against the live source files on **2026-07-29**.
Evidence is cited as `file · symbol` — **never a line number** (line numbers in older notes
have drifted). Where a source of truth could not be established, it is listed under
[§13 UNRESOLVED](#13--unresolved--verify-before-relying-on-this) rather than guessed at.

Source roots (read-only — do **not** write into them):
- FE / rules: `/Users/syamnadhg/Downloads/SuperResearch/dg-research`
- BE: `/Users/syamnadhg/Downloads/SuperResearch/dg-research-backend`

Firebase project: **`super-research-492814`** (pinned in `dg-research/.firebaserc`).
Public config, env-overridable — `dg-research-backend/auth/v2_flow.py · PROJECT_ID / WEB_API_KEY / FE_BASE_URL`:

```
FIREBASE_PROJECT_ID    default "super-research-492814"
FIREBASE_WEB_API_KEY   default "<FIREBASE_WEB_API_KEY redacted - read from env or the gitignored plist>"
RESEARCH_FE_BASE_URL   default "https://superresearch.io"   (trailing "/" rstripped)
```
These are read into module globals at **import time** — setting the env var after import is a no-op.

---

## 0. The one-paragraph model

A device is **not** a user. Pairing mints a *synthetic Firebase Auth user* whose uid is literally
`device-{deviceId}`, carrying three server-set custom claims. That synthetic user is a
**third principal** in the ruleset, distinct from both the human **owner** and any **sharer**.
Almost every mistake in this contract comes from assuming the device is a "device member" —
it is not. `isDeviceMember()` in `dg-research/firestore.rules` means *owner or sharer*, and it
**excludes** the synthetic device user everywhere it appears.

---

## 1. END-TO-END PAIRING SEQUENCE

Legend: **[D]** originated by the device · **[S]** originated by the server (FE route, Admin SDK)
· **[H]** originated by the human · **[G]** originated by Google Identity Platform.

### Step 1 — [D] Mint (or reuse) the pollSecret

```
pollSecret = 32 random bytes rendered as 64 lowercase hex chars
```
Evidence: `dg-research-backend/auth/v2_flow.py · generate_poll_secret` (`secrets.token_hex(32)`).

**REUSE an existing secret if one is persisted.** `research.py · cmd_pair_v2` calls
`load_poll_secret()` first and only mints when absent — same secret ⇒ same hash ⇒ same Firestore
pending path, which is what makes post-Reset re-pair possible at all.

Persist it **outside** the credential keystore (the BE keeps it in `research_config.json` via
`research.py · save_user_mode_state`), because a Reset wipes the keystore but the re-pair flow
polls the *same* pending path. On iOS: Keychain is fine, but it must be a **separate item from
the refresh token** so a credential wipe cannot take it with it.

### Step 2 — [D] Hash it

```
pollSecretHash = lowercase_hex( SHA256( ASCII_BYTES_OF_THE_64_CHAR_HEX_STRING ) )
```
Evidence: `dg-research-backend/auth/v2_flow.py · compute_poll_secret_hash`
— `hashlib.sha256(poll_secret.encode("ascii")).hexdigest()`.

⚠ This hashes the **64-character hex text**, not the 32 raw random bytes. See
[TRAP-01](#trap-01--hashing-the-bytes-instead-of-the-hex-text).

### Step 3 — [D→S] `POST {FE_BASE_URL}/api/devices/initiate-pair` (UNAUTHENTICATED)

Evidence: `dg-research/src/app/api/devices/initiate-pair/route.ts · POST`;
device side `dg-research-backend/auth/v2_flow.py · initiate_pair_remote`.

Request body — `Content-Type: application/json`, **no Authorization header**:

| Key | Type | Required | Origin | Notes |
|---|---|---|---|---|
| `pollSecretHash` | string | **yes** | [D] | `.toLowerCase()`d server-side, then matched against `/^[0-9a-f]{64}$/` |
| `machineName` | string \| null | no | [D] | stored as `null` when absent |
| `hostname` | string \| null | no | [D] | stored as `null` when absent |
| `os` | string \| null | no | [D] | BE sends `f"{platform.system()} {platform.release()}"` |

BE HTTP timeout: `15.0 s`. Route `maxDuration = 30`.

Responses:

| Status | Body | Meaning |
|---|---|---|
| 200 | `{deviceId: string, pairCode: string}` | success |
| 400 | `{error:"invalid_json"}` | body not JSON |
| 400 | `{error:"invalid_poll_secret_hash"}` | failed the regex |
| 429 | `{error:"rate_limited", retryAfterMs:number}` | **5 requests / 5 min per client IP** |
| 500 | `{error:"create_user_failed"}` | `createUser` failed for a non-`auth/uid-already-exists` reason |
| 503 | `{error:"code_generation_exhausted"}` | 5 pair-code candidates all collided |

Treat a 2xx that lacks either `deviceId` or `pairCode` as a hard failure
(`InitiatePairError` in the BE).

### Step 4 — [S] Server-side effects of Step 3, in order

1. Rate-limit check (`dg-research/src/lib/rate-limit.ts · checkAndIncrement`, key `initiate-pair:{ip}`).
2. `deviceId = randomUUID().replace(/-/g,"")` → **32 lowercase hex, no dashes, no hostname component**.
3. `syntheticDeviceUid = "device-" + deviceId`.
4. `adminAuth().createUser({uid: syntheticDeviceUid, disabled:false, displayName:"BE device "+deviceId.slice(0,6)})`.
   `auth/uid-already-exists` is swallowed.
5. Pair code: up to 5 candidates, each tested with `devices.where("pairCode","==",cand).limit(1)`.
6. `_internal/device_secrets/entries/{deviceId} = {pollSecretHash, createdAt: serverTimestamp()}`
   — **admin-only**, denied to every client by `match /_internal/{document=**}`. This is why a
   sharer who can read the device doc still cannot construct the pending path.
7. `devices/{deviceId}` created (see [§4.1](#41-devicesdeviceid)).

**The device never chooses its own `deviceId` and never generates its own `pairCode`.**

Pair code shape — `dg-research/src/lib/pair-code.ts · ALPHABET / CODE_LENGTH`:
```
ALPHABET    = "23456789ABCDEFGHJKMNPQRSTUVWXYZ"   // 31 chars: 2-9 + A-Z minus I, L, O. 0 and 1 also excluded.
CODE_LENGTH = 8                                    // ~39.6 bits
```

### Step 5 — [D] Display the code to the human

Canonical storage form is dashless uppercase. Display form inserts **one** hyphen after char 4:
`K7XQ-9B2M` (`dg-research/src/lib/pair-code.ts · formatForDisplay`; Python twin
`dg-research-backend/auth/pairing.py · format_for_display`, which returns a wrong-length code
**verbatim** rather than raising).

The BE renders a QR whose payload is the **raw unhyphenated 8-char code**
(`research.py · cmd_pair_v2 · _on_code`). If iOS shows a QR, match that — and if iOS ever
*accepts* a typed code, normalise with the same rules as
`dg-research/src/lib/pair-code.ts · normalizeCode`: uppercase, strip everything outside `A-Z0-9`,
require exactly 8, require every char in `ALPHABET` (it **rejects** `O`/`I`/`L`/`0`/`1` — it does
not fold them).

### Step 6 — [H→S] `POST /api/devices/claim` (the human, in a browser)

The device does **not** call this. Evidence: `dg-research/src/app/api/devices/claim/route.ts · POST`.

Request: `Authorization: Bearer <human's Firebase ID token>`, body `{code: string}`.

The entire decision runs inside `adminDb().runTransaction`, and **the branch is chosen from the
device doc's `pairState` / `ownerUid`, not from the request shape**:

| # | Precondition | Action | Mints a token? |
|---|---|---|---|
| 1 | `pairState === "awaiting-re-pair"` | requires `pairCodeExpiresAt.toMillis() >= now` (else **410 `code_expired`**) **and** `ownerUid === claimer` (else **403 `not_previous_owner`**) | **YES** |
| 2 | `pairState === "awaiting-initial-claim"` **OR** `ownerUid === null` | claimer becomes `ownerUid` | **YES** |
| 3a | active, `claimer === ownerUid` | `already-owner` — **no writes at all** | **NO** |
| 3b | active, `claimer ∈ sharedWith` | `already-shared` — **no writes at all** | **NO** |
| 3c | active, new uid | `share-claim`: `sharedWith: arrayUnion(claimer)`, `mutSeq: increment(1)`; rejects `revokedSharers` member with **403 `revoked_sharer`**, and `sharedWith.length >= SHARER_CAP (25)` with **409 `share_cap_reached`** | **NO** |

Response `200 {ok:true, action, deviceId}` where
`action ∈ {initial-pair, re-pair, share-claim, already-owner, already-shared}`.
Other statuses: `401 unauthorized`, `429 rate_limited` (+`retryAfterMs`; 5/5min per uid),
`400 invalid_json|invalid_code_format`, `404 code_not_found`,
`500 device_secret_missing` (the `_internal` entry is absent), `500 internal_error`.

On branches 1 and 2 the route, in transaction order:

1. `adminAuth().setCustomUserClaims(syntheticUid, {ownerUid, deviceId, sharedWith})`
   — **full overwrite**, all three always present. `sharedWith` is `[]` on initial-pair and the
   live array on re-pair.
2. `adminAuth().createCustomToken(syntheticUid)` — **one argument, no developerClaims**. The
   claims live on the *Auth user record*, so they surface only in the **exchanged ID token**,
   never in the custom token.
3. `writePendingCustomToken` — reads `_internal/device_secrets/entries/{deviceId}.pollSecretHash`
   inside the tx, then `tx.set(devices/{deviceId}/pending/{pollSecretHash}, {...})`.
4. `tx.update(devices/{deviceId}, {... expireAt: now + 5 min ...})` ⇒ **the deadline starts here**
   (see [§5](#5-the-atomic-pair-confirm)).

### Step 7 — [D] Poll the pending doc, UNAUTHENTICATED, by exact doc id

Evidence: `dg-research-backend/auth/v2_flow.py · poll_pending_token / _firestore_rest_url`.

```
GET https://firestore.googleapis.com/v1/projects/{PROJECT_ID}/databases/(default)/documents/devices/{deviceId}/pending/{pollSecretHash}
```
- No headers at all. Literal, unescaped `(default)` in the path.
- Per-request timeout `8.0 s`; interval `POLL_INTERVAL_SECONDS = 2.0`;
  overall deadline `DEFAULT_POLL_TIMEOUT_SECONDS = 15 * 60` checked at the **top** of each
  iteration (so `PollTimeout` fires without a final attempt).
- Success = HTTP 200 **and** a non-empty `fields.customToken.stringValue`.
- `404` (not claimed yet) / `403` (ruleset drift) / `5xx` / network error → sleep and retry.
  Only the outer deadline ends the loop.

Rule that makes this legal — `dg-research/firestore.rules · match /pending/{secretHash}`:
```
allow get: if true;
allow list: if false;
allow create, update, delete: if false;
```
The **only** protection on the customToken is the 256-bit doc id plus the list-denial. The device
can never list the subcollection and can never delete the doc after consuming it.

**Swift note:** the BE deliberately uses raw REST here because it has no Firebase auth yet. Whether
`Firestore.getDocument` works with no signed-in user is untested — see
[UNRESOLVED-07](#unresolved-07). Mirroring the REST call for this one read is the safe default.

### Step 8 — [D→G] Exchange the customToken

Evidence: `dg-research-backend/auth/pairing.py · exchange_custom_token`.

```
POST https://identitytoolkit.googleapis.com/v1/accounts:signInWithCustomToken?key={WEB_API_KEY}
body: {"token": <customToken>, "returnSecureToken": true}     timeout 10.0s
```
Response, **camelCase**: `idToken` (req), `refreshToken` (req), `expiresIn` (**string** of int,
default `"3600"`), `localId` (**optional — absent on current responses**), `isNewUser`, `kind`.

`uid = localId ?? jwtPayload.user_id ?? jwtPayload.sub`
(`dg-research-backend/auth/v2_flow.py · _uid_from_id_token` — a *no-verify* base64url decode of the
payload segment, re-padded to a multiple of 4). Missing any of `refreshToken` / `idToken` / `uid`
⇒ hard `CustomTokenExchangeError`.

Swift equivalent: `Auth.auth().signIn(withCustomToken:)`, then
`user.getIDTokenResult(forcingRefresh: true)` to read the three claims.

### Step 9 — [D] Persist the refresh token

The **only** credential written to durable storage is the **refresh token**
(`dg-research-backend/auth/credentials.py · RefreshTokenCredentials.bootstrap`):
`keystore.set("pending", install_uuid, refresh_token)` then `keystore.promote_pending(install_uuid)`.
The ID token and its expiry are **in-memory only**.

`expiry` must be **timezone-NAIVE UTC**:
`datetime.utcnow() + timedelta(seconds=max(0, expires_in - 300))`
(`_REFRESH_MARGIN_SECONDS = 300`). See [TRAP-13](#trap-13--aware-datetime-on-credsexpiry).

Also persist local state (`research.py · save_user_mode_state`) —
`{authMode:"user", deviceId, pairedUid, pollSecret}` merged into `research_config.json` via an
atomic `mkstemp` + `json.dump` + `flush` + `fsync` + `os.replace`. `cmd_pair_v2` writes this
**twice**: first with the *synthetic* uid as `pairedUid`, then again with the real `ownerUid` once
the owner lookup resolves.

### Step 10 — [D] ⏱ THE ATOMIC PAIR-CONFIRM WRITE — within 5 minutes of Step 6

```
PATCH https://firestore.googleapis.com/v1/projects/{PROJECT_ID}/databases/(default)/documents/devices/{deviceId}
      ?updateMask.fieldPaths=pairConfirmedAt&updateMask.fieldPaths=expireAt
Authorization: Bearer <fresh synth ID token>
Content-Type:  application/json
body: {"fields": {"pairConfirmedAt": {"booleanValue": true}}}
```
Evidence: `research.py · _pair_patch_device`, called from `cmd_pair_v2` and from
`_revoked_recovery_loop` as `_pair_patch_device(device_id, {"pairConfirmedAt": True}, delete_fields=["expireAt"])`.

`expireAt` appears in the **mask** and **not** in the body — that is what makes the server delete it.
`updateMask.fieldPaths` order is `list(set_fields.keys()) + list(delete_fields or [])`.
Single attempt, `timeout=10`, returns `bool`, **never raises**.

Full detail + the complete allow-list: [§5](#5-the-atomic-pair-confirm).

### Step 11 — [D] Owner lookup (optional, cosmetic)

A Firestore REST `GET documents/devices/{deviceId}` authed with the synth ID token. The device can
read its own doc **in full** — including `pairCode`, `ownerUid`, `ownerEmail`, `ownerDisplayName`
(there is no field-level security in Firestore). Evidence:
`dg-research/firestore.rules · match /devices/{deviceId} allow read`, third disjunct
`request.auth.uid == resource.data.syntheticDeviceUid`; BE side
`research.py · _fetch_device_meta_rest / _fetch_paired_email`.

### Step 12 — [D] Steady-state heartbeat, every 5 s

`research.py · _heartbeat_loop`, `HEARTBEAT_INTERVAL_SEC = 5`, each write wrapped in
`asyncio.wait_for(..., timeout=10.0)`:

```python
devices/{deviceId}.update({
    "lastHeartbeat": int(time.time() * 1000),   # INT MILLIS — never a Timestamp
    "status": "active",
    "pairConfirmedAt": True,
    "expireAt": DELETE_FIELD,                   # google.cloud.firestore.DELETE_FIELD
    "workerCount": <int>,
})
```
**The payload deliberately omits `deviceId`.** See [TRAP-05](#trap-05--putting-deviceid-in-the-device-doc-payload).

After `HEARTBEAT_REINIT_THRESHOLD = 3` consecutive failures the BE drops its client and hands
recovery to a reconnect loop. Version signalling (`version` / `updateAvailable` / …) is a
**separate** update throttled to `300_000 ms` precisely so a rules-lag 403 there cannot take the
liveness write down with it — copy that isolation.

### Step 13 — [D] Re-pair after a Reset (no initiate-pair)

`dg-research-backend/auth/v2_flow.py · do_redeem_reset` skips `/api/devices/initiate-pair`
entirely and polls the **same** `devices/{deviceId}/pending/{sha256(pollSecret)}` path, then
re-bootstraps and issues the identical pair-confirm PATCH from Step 10 before restarting.
Recovery gives up entirely at `research.py · MAX_RECOVERY_WALLCLOCK_SEC = 3600`.

---

## 2. PRINCIPALS AND CLAIMS

### 2.1 The three principals

| Principal | Identified in rules by | Is it `isDeviceMember()`? |
|---|---|---|
| **Owner** (human) | `request.auth.uid == userId` / `== resource.data.ownerUid` | yes |
| **Sharer** (human) | `request.auth.uid in resource.data.sharedWith` | yes |
| **Synthetic device user** | `request.auth.uid == resource.data.syntheticDeviceUid`, and in the *user tree* by the presence of the `request.auth.token.deviceId` claim | **NO** |

Helper functions, verbatim from `dg-research/firestore.rules`:

```
deviceOwnership(deviceId, userId)   get(devices/$(deviceId)).data.ownerUid == userId
                                 || userId in get(devices/$(deviceId)).data.sharedWith

deviceMemberOf(userId)             auth != null && auth.token.deviceId is string
                                 && deviceOwnership(auth.token.deviceId, userId)

deviceWritingTo(userId)            deviceMemberOf-style check PLUS
                                   request.resource.data.deviceId == auth.token.deviceId

deviceUpdatingFor(userId)          auth != null && auth.token.deviceId is string
                                 && resource.data.get('deviceId', auth.token.deviceId) == auth.token.deviceId
                                 && request.resource.data.deviceId == auth.token.deviceId
                                 && deviceOwnership(auth.token.deviceId, userId)
```

`deviceUpdatingFor` is the **self-heal** variant: a doc with **no** `deviceId` passes the first
clause by default and gets stamped on this write; a doc already stamped with a *different*
device's id can never be written. Regression-pinned by
`dg-research/tests/rules/firestore.rules.test.ts · it("synth user self-heals a deviceId-less doc (injects matching deviceId)")`
and `it("synth user CANNOT stamp a WRONG deviceId on a deviceId-less doc")`.

### 2.2 The custom claims — exactly three, always together

`dg-research/src/app/api/devices/claim/route.ts` and `dg-research/src/lib/devices/sync-claim.ts · syncDeviceClaim`:

```json
{ "ownerUid": "<human uid>", "deviceId": "<32 hex>", "sharedWith": ["<uid>", "..."] }
```
Written with `setCustomUserClaims` — a **full overwrite**, so all three are always present.
`syncDeviceClaim` returns early **without writing** when `syntheticDeviceUid` or `ownerUid` is
missing/non-string.

**Split-brain that matters:**

| Ruleset | Reads which claim | Resolves sharing from |
|---|---|---|
| `firestore.rules` | **only** `token.deviceId` | the **device DOC**, live, via `get()` |
| `storage.rules` | **only** `token.ownerUid` + `token.sharedWith` (`deviceId` used solely as an `is string` presence gate) | the **TOKEN**, stale until refresh |

`dg-research/storage.rules · deviceOwns(userId)`, verbatim:
```
request.auth.token.deviceId is string
&& ( request.auth.token.ownerUid == userId
     || (request.auth.token.sharedWith is list && userId in request.auth.token.sharedWith) )
```
There is **no** `firestore.get()` — Storage rules cannot read Firestore (an unknown function makes
the whole condition evaluate false ⇒ blanket 403). Consequence: a sharer added seconds ago works
instantly for Firestore and **403s on Storage** until the ID token refreshes. `SHARER_CAP = 25`
enforced by the claim route; the 1 KB claim budget is the underlying reason.

### 2.3 Pre-authentication readable paths — there are exactly three

| Path | Rule | Notes |
|---|---|---|
| `devices/{deviceId}/pending/{secretHash}` | `allow get: if true; allow list: if false` | the bootstrap hinges on this |
| `shares/{shareId}` | `allow get: if resource.data.get('revoked', false) != true` | list is owner-scoped; irrelevant to the device flow |
| Storage `album-art/{userId}/{allPaths=**}` | `allow read: if true` | every other Storage path requires auth |

### 2.4 No collection-group rules exist — anywhere

The only recursive wildcards in `dg-research/firestore.rules` are
`match /_internal/{document=**}` (deny) and the terminal `match /{document=**}` (deny). Verified by
grep: no `{path=**}` anywhere. Therefore **every** client-side `collectionGroup()` query is denied
for **every** principal — `queue`, `researches`, `pipeline_events`, `commands`, `pending`,
`feFifoWaiters`. Explicitly regression-tested for `pending`:
`dg-research/tests/rules/firestore.rules.test.ts` —
`await assertFails(getDocs(collectionGroup(ctx.firestore(), "pending")))`.

### 2.5 Rules v2 does not cascade

`match /users/{userId} { allow read, write: ... }` does **not** grant anything on subcollections;
only recursive `{document=**}` wildcards cascade. The enumerated set under `users/` is exactly:

```
settings/prefs
devices/{id}                      (legacy tree)
devices/{id}/commands/{id}        (legacy tree)
notifications/{id}
fcm_tokens/{id}
notify_dedup/{key}
sessions/{id}
agentSessions/{id}
researches/{rid}
researches/{rid}/messages/{id}
researches/{rid}/documents/{id}
researches/{rid}/audios/{id}
researches/{rid}/pipeline_events/{id}
researches/{rid}/commands/{id}
```
Anything not on that list falls to the terminal deny-all.

---

## 3. WHAT THE DEVICE MAY AND MAY NOT TOUCH

`M` = deviceMemberOf (owner/sharer only — **device denied**) · `W` = deviceWritingTo ·
`U` = deviceUpdatingFor · `S` = synth-only (`syntheticDeviceUid`) · `—` = no device branch.

| Path | read | create | update | delete |
|---|---|---|---|---|
| `devices/{id}` | ✅ synth | ❌ `if false` | ✅ S, `hasOnly(22)` | ❌ `if false` |
| `devices/{id}/pending/{hash}` | ✅ anonymous `get` (no `list`) | ❌ | ❌ | ❌ |
| `devices/{id}/queue/{qid}` | ✅ synth | ❌ **M only** | ✅ S, `hasOnly(['assignedWorker','claimedAt','restDeferredAt'])` | ✅ synth |
| `devices/{id}/commands/{cid}` | ✅ synth | ❌ **M only** | ✅ S, `hasOnly(['processed','staleSkipped'])` | ✅ synth |
| `devices/{id}/feFifoWaiters/{rid}` | ❌ M only | ❌ M only | ❌ M only | ❌ M only |
| `users/{uid}/researches/{rid}` | ✅ deviceMemberOf **OR** `deviceId` fast-path | ✅ W | ✅ U, **no `hasOnly`** | ❌ owner-only |
| `.../researches/{rid}/messages` | ✅ deviceMemberOf | ✅ W | ✅ U | ❌ owner-only |
| `.../researches/{rid}/documents` | ✅ deviceMemberOf | ✅ W | ✅ U | ❌ owner-only |
| `.../researches/{rid}/audios` | ✅ deviceMemberOf | ✅ W | ✅ U | ❌ owner-only |
| `.../researches/{rid}/pipeline_events` | ✅ deviceMemberOf | ✅ W **+ `seq is number` + `timestamp is number`** | ❌ **`if false`** | ❌ owner-only |
| `.../researches/{rid}/commands` | ✅ deviceMemberOf | ✅ W | ✅ **deviceMemberOf** (no `hasOnly`, no `deviceId` required) | ✅ deviceMemberOf |
| `users/{uid}/settings/prefs` | ✅ deviceMemberOf | — | ❌ owner-only write | — |
| `users/{uid}/fcm_tokens/{id}` | ✅ claim-only check (no doc `deviceId` needed) | ❌ | ❌ | ❌ |
| `users/{uid}/notifications/{id}` | ❌ **owner-only** | ✅ W | ✅ U | ❌ owner-only |
| `users/{uid}` (root doc) | ❌ | ❌ | ❌ | ❌ |
| `users/{uid}/sessions/{id}` | ❌ | ❌ | ❌ | ❌ |
| `users/{uid}/agentSessions/{id}` | ❌ | ❌ | ❌ | ❌ |
| `users/{uid}/devices/{id}` (legacy) | ❌ | ❌ | ❌ | ❌ |
| `users/{uid}/notify_dedup/{k}` | owner read only | ❌ `write: if false` | ❌ | ❌ |
| `announcements/{id}` | any signed-in user | ❌ `write: if false` | ❌ | ❌ |
| `_internal/{document=**}` | ❌ | ❌ | ❌ | ❌ |
| `research_tokens/*`, `pipeline_requests/*`, `agentLogins/*` | ❌ **no rule at all** | ❌ | ❌ | ❌ |

Notable asymmetries worth memorising:

- The **research root doc read** has a third disjunct — the device fast-path
  `resource.data.get('deviceId','') == request.auth.token.deviceId` — that deliberately **omits**
  the `deviceOwnership()` `get()`. Its **subcollections do not have this**; they gate on
  `deviceMemberOf` only. Expect "parent doc reads fine but everything under it 403s" as a real
  failure mode when the device doc is missing.
- The device can **create** a notification but can never **read** one back ⇒ no read-based
  idempotency is possible there.
- The device can **read** `fcm_tokens` but never write them.
- `settings/prefs` read routes through `deviceMemberOf`, so it works for a **sharer's** tree too.
  Pinned by `it("the OWNER cannot read the sharer's prefs (privacy pin)")` — the owner cannot.
- `research_tokens`, `pipeline_requests` and `agentLogins` have **no rule at all** yet the FE still
  contains legacy fallbacks that write to the first two (`dg-research/src/lib/firestore.ts ·
  resolveQueueCollection` legacy branch) and `firestore.indexes.json` still declares a TTL for
  `agentLogins`. **Do not port any of them** — a client write is `PERMISSION_DENIED` today.

**Admin-SDK-only writes** (no client, no device, ever): `devices/{id}` create + delete;
`devices/{id}/pending/*` create + update + delete; all of `_internal/**`;
`users/{uid}/notify_dedup/*`; `announcements/*`; and every device-doc field outside the three
allow-lists in [§5.2](#52-the-three-coexisting-update-rules).

---

## 4. VERBATIM FIELD TABLES

Wire types are as they must appear **in Firestore**. For the REST transport, see
[§8](#8-rest-transport-notes-for-the-python-layer).

### 4.1 `devices/{deviceId}`

Doc id = 32 lowercase hex. Evidence: `dg-research/src/app/api/devices/initiate-pair/route.ts`,
`.../claim/route.ts`, `.../reset-pair-code/route.ts`, `.../unpair-self/route.ts`,
`dg-research/firestore.rules · match /devices/{deviceId}`, `research.py · _heartbeat_loop`.

| Field | Wire type | Written by | Notes |
|---|---|---|---|
| `pairCode` | string(8) | **S** admin | rotated only by reset-pair-code |
| `ownerUid` | string \| **null** \| *absent* | **S** admin | literal `null` at initiate; **`FieldValue.delete()`d** (⇒ absent) by owner-unlink |
| `sharedWith` | array\<string\> | **S** admin | `[]` at initiate; max 25 |
| `revokedSharers` | array\<string\> | **S** admin | `arrayUnion` on unshare; deleted by reset |
| `syntheticDeviceUid` | string | **S** admin | `"device-" + deviceId` |
| `pairState` | string | **S** admin | `awaiting-initial-claim` \| `active` \| `awaiting-re-pair` |
| `machineName` | string \| null | **S** admin | from the initiate-pair body |
| `hostname` | string \| null | **S** admin | from the initiate-pair body |
| `os` | string \| null | **S** admin | from the initiate-pair body |
| `createdAt` | Timestamp | **S** admin | `serverTimestamp()` sentinel |
| `claimedAt` | Timestamp | **S** admin | `serverTimestamp()` sentinel |
| `pairCodeExpiresAt` | Timestamp | **S** admin | present only in `awaiting-re-pair`; deleted on claim |
| `pairCodeResetAt` | Timestamp | **S** admin | `serverTimestamp()` |
| `preResetUids` | array\<string\> | **S** admin | set by reset, deleted by claim |
| `mutSeq` | number | **S** admin | `FieldValue.increment(1)` on every `sharedWith` mutation |
| `ownerDisplayName` | string | **S** admin | best-effort `getUser()` |
| `ownerEmail` | string | **S** admin | best-effort `getUser()` |
| `expireAt` | Timestamp \| *deleted* | **S** admin sets; **D** deletes | 24 h at initiate · **5 min at claim** · 15 min at reset. **Only the device ever deletes it.** |
| `lastHeartbeat` | **int** epoch **millis** | **D** | never a Timestamp |
| `status` | string | **D** | `"active"` |
| `pairConfirmedAt` | **boolean `true`** | **D** | boolean despite the `-At` suffix |
| `logins` | map\<string, bool\> | **D** | keyed by service key |
| `authMode` | string | **D**? | allow-listed but **no BE write found** — see [UNRESOLVED-04](#unresolved-04) |
| `supervised` | bool | **D** *and* **owner** | the one field in **two** allow-lists |
| `currentRunId` | string | **D** (worker 1) | |
| `currentRunOwnerUid` | string | **D** (worker 1) | |
| `currentRunTitle` | string | **D** (worker 1) | topic truncated to 60 |
| `currentRunStartedAt` | int millis | **D** (worker 1) | |
| `currentRunPhase` | int | **D** (worker 1) | ETA input |
| `currentRunPhaseStartedAt` | int millis | **D** (worker 1) | ETA input |
| `workerCount` | int | **D** (worker 1) | FE capacity gate **and** the ETA parallelism divisor |
| `busyWorkerIds` | array\<int\> | **D** (all workers) | `arrayUnion` / `arrayRemove` |
| `workers` | map\<workerId, {uid, runId, title, phase:int, totalPhases:int}\> | **D** (all workers) | written via **dotted path** `workers.{id}`; surfaces in `affectedKeys()` as top-level `workers` |
| `queueOwners` | array\<{uid, runId, title, position:int}\> | **D** | **full-array overwrite** |
| `version` | string \| null | **D** (worker 1) | separate throttled write |
| `updateAvailable` | string \| null | **D** (worker 1) | separate throttled write |
| `updateStatus` | map `{state, current, latest, reason?, at:int}` | **D** | shape not fully verified — [UNRESOLVED-05](#unresolved-05) |
| `versionCheckedAt` | int millis | **D** | |
| `sourceCheckout` | bool | **D** | |
| `name` | string | **owner** (client) | FE display name resolves `name → machineName → hostname → docId` |
| `priority` | number | **owner** (client) | |
| `restingWorkerIds` | array\<int\> | **owner** (client) | |
| `feFifoCurrent` | map `{researchId, ownerUid, acquiredAt}` \| cleared | **owner + sharers** | the device is **not** a member and cannot write this |

`initiate-pair` never writes a `name` field. Omitting `machineName`/`hostname` from the initiate
request makes the tile display a raw 32-hex doc id.

### 4.2 `devices/{deviceId}/pending/{sha256hex(pollSecret)}`

Doc id = the 64-char lowercase-hex hash, server-validated by `/^[0-9a-f]{64}$/` after
`.toLowerCase()`. Written by the Admin SDK inside the claim transaction
(`dg-research/src/app/api/devices/claim/route.ts · writePendingCustomToken`).

| Field | Wire type | Written by | Notes |
|---|---|---|---|
| `customToken` | string | **S** admin | Firebase custom-token JWT. Read path: `fields.customToken.stringValue` |
| `createdAt` | Timestamp | **S** admin | `serverTimestamp()` sentinel |
| `expireAt` | Timestamp | **S** admin | `now + PENDING_TOKEN_TTL_MS` = **15 min** |

⚠ `dg-research/tests/rules/firestore.rules.test.ts` seeds a field named **`pendingCustomToken`**.
That name is **stale test-fixture data**; production writes and reads `customToken`.
The device may never delete this doc — it lingers until the TTL reaps it.

### 4.3 `devices/{deviceId}/queue/{autoId}`

FE-authored by `dg-research/src/lib/firestore.ts · buildQueuePayload` / `startPipelineViaFirestore`,
consumed by the device.

| Field | Wire type | Written by | Notes |
|---|---|---|---|
| `uid` | string | **owner/sharer** | the run's **true owner tree** — the BE writes back here. For owner-control this deliberately **differs** from `submittedBy` |
| `submittedBy` | string | **owner/sharer** | **rule-enforced** `== request.auth.uid` on create |
| `submittedByDisplayName` | string | **owner/sharer** | optional; omitted when the Auth displayName is empty |
| `submittedAt` | Timestamp | **owner/sharer** | `serverTimestamp()` sentinel — **primary FIFO key**, skew-immune |
| `timestamp` | **int** millis | **owner/sharer** | `Date.now()`; legacy FIFO fallback **and** the staleness-age source. In `buildQueuePayload` it is spread **after** `...body`, so a caller cannot override it |
| `action` | string | **owner/sharer** | `start` \| `cancel` \| `resume`; BE default is `"start"` |
| `researchId` | string | **owner/sharer** | required — missing ⇒ BE deletes the doc |
| `topic` | string | **owner/sharer** | required, `.strip()`ed, non-empty |
| `email`, `config`, `briefText`, `userSources`, `userLinks`, `backendRunId`, `ownerControl` | various | **owner/sharer** | optional; `ownerControl ∈ {"stop","cancel"}` |
| `assignedWorker` | **int** | **D** | presence alone means "claimed" |
| `claimedAt` | **int** millis | **D** | written exactly once — **there is no lease and no renewal** |
| `restDeferredAt` | **int** millis | **D** | re-bases the 12 h abandoned sweep |
| `processed` | bool | **legacy** | **READ** by the BE but **NOT** in the device update allow-list ⇒ the device can never mark a queue doc processed. Consumption is **by delete only** |
| `expireAt` | Timestamp | **S** admin | stamped by reset-pair-code, cleared by claim's re-pair branch |

Claim mechanics — `research.py · _try_claim_queue_doc`. **NOT a transaction.** It is a
read-then-conditional-update compare-and-set:

```python
snap = doc_ref.get()
if not snap.exists: return False
if d.get("assignedWorker") or d.get("processed"): return False
doc_ref.update({"assignedWorker": worker_id, "claimedAt": int(time.time()*1000)},
               option=db.write_option(last_update_time=snap.update_time))
```
Tri-state result: `True` claimed · `False` race lost / gone / already processed (skip, no retry) ·
`None` unexpected error after `max_attempts=3` (log + skip; the idle rescan retries later).
Transient retries cover `ServiceUnavailable`, `DeadlineExceeded`, `Unauthenticated`,
`InternalServerError` with `250ms * attempt` backoff. `FailedPrecondition` / `NotFound` = race loss.

First-attach replay triage (constants are **function-local** inside
`research.py · start_firestore_start_listener`): `ZOMBIE_GRACE_MS = 30_000`,
`ABANDONED_MAX_MS = 12 * 60 * 60 * 1000`.

### 4.4 `devices/{deviceId}/commands/{autoId}`

| Field | Wire type | Written by | Notes |
|---|---|---|---|
| `action` | string | **owner/sharer** | sharers may write **only** `"hard_reset"` or `"check-update"`; everything else is owner-only (default-closed allowlist in the rule) |
| `processed` | bool | **owner/sharer** creates `false`; **D** sets `true` | |
| `timestamp` | **int** millis | **owner/sharer** | `Date.now()`, **not** `serverTimestamp()` — the BE's 30 s stale gate is numeric |
| `submittedBy` | string | **owner/sharer** | rule-enforced `== auth.uid` |
| `staleSkipped` | bool | **D** | |
| *(extra)* | any | **owner/sharer** | e.g. `reason:"owner_reset_pair_code"` |

Device-writable set is exactly `hasOnly(['processed','staleSkipped'])`. The device may **delete**.
The device may **not create** (create requires `isDeviceMember()`).

### 4.5 `users/{uid}/researches/{rid}/pipeline_events/{autoId}`

Auto-id via `.add()` — no deterministic key. **Exactly one producer in the whole BE**:
`research.py · emit_event → _emit_to_firestore` (verified: a single
`collection("pipeline_events")` reference in `research.py`).

| Field | Wire type | Required | Written by | Notes |
|---|---|---|---|---|
| `type` | string | **yes** | **D** | verbatim event type. The **device branch is NOT type-restricted**; the *owner* branch is restricted to `['phase_start','phase_complete','phase_skipped','pipeline_complete']` |
| `timestamp` | **int** millis | **yes** (rule: `is number`) | **D** | `int(time.time()*1000)`. A Timestamp **fails the rule** |
| `seq` | **int** millis, monotonic | **yes** (rule: `is number`) | **D** | `new = int(time.time()*1000); if new <= _fb_seq: new = _fb_seq + 1`. **Not** a 0-based counter |
| `expireAt` | Timestamp | by convention (no rule) | **D** | tz-**aware** `datetime.now(timezone.utc) + timedelta(days=30)` |
| `deviceId` | string | **yes** for the device branch | **D** | **TOP-LEVEL**, sibling of `type`/`data` — **not** nested inside `data` |
| `phase` | int | optional | **D** | guard is `if phase is not None` ⇒ **`phase=0` IS written** |
| `agent` | string | optional | **D** | guard is `if agent:` ⇒ `agent=""` is **omitted**. **Not lowercased** by `emit_event` |
| `data` | map | optional | **D** | **omitted entirely when empty** by the BE; the FE emitter always writes `{}` |

`allow update: if false` — absolutely append-only. `allow delete` is owner-only.
**Guaranteed absent from `data`:** `suppress_generic_mirror` and `force_mirror` — `emit_event`
`.pop()`s both off the *same dict object* that `event['data']` references, before the write.

FE-authored events (`dg-research/src/lib/firestore.ts · emitFePipelineEvent`) carry
**no** `expireAt`, **no** `agent`, **no** `deviceId`, and **always** `data: {}` — one collection,
three different absence semantics. FE consumer:
`query(eventsCol, where("seq",">",lastSeq), orderBy("seq","asc"))` with `lastSeq` persisted in
`localStorage` under `pipeline_events:{uid}:{rid}:lastSeq[:{cursorKey}]`.

### 4.6 `users/{uid}/researches/{rid}` (the research root doc)

**There is no `hasOnly` on this doc** — `deviceUpdatingFor` gates the whole document, so unrelated
fields can ride along on one write. Every BE write goes through
`research.py · _update_research_doc` / `_set_research_doc`, both of which pass the payload through
`_be_payload` (which injects `deviceId`) and wrap it in `_grpc_write_with_heal`. Both return
`bool` and **never raise**.

| Field | Wire type | Written by | Notes |
|---|---|---|---|
| `deviceId` | string | **D** | injected into **every** BE write by `_be_payload` |
| `topic`, `title`, `summary` | string | FE + **D** | never write `title` when `titleLocked` is true |
| `status` | string | FE + **D** | `queued`\|`ongoing`\|`running`\|`paused`\|`paused_pending_repair`\|`paused_backend_restart`\|`stopped`\|`stopped_by_watchdog`\|`terminated_by_user_discard`\|`cancelled`\|`completed` |
| `backendRunId` | string | **D** | |
| `phase` | int | **D** | **must be written alongside `currentPhase`** |
| `currentPhase` | int | **D** | omit it and the homepage tile diagram glows the stale node forever |
| `phases` | array\<{phase:int, label, startedAt:int, status}\> | **D** | read-modify-write of the **whole array** |
| `agents` | map\<lowercased agent key, {status}\> | **D** | **merged nested map**, not an array |
| `assignedWorker` | int | **D** | |
| `pendingDecision` | map \| `DELETE_FIELD` | **D** | **single slot per research** — see [§7](#7-pendingdecision--the-single-slot-durable-mirror) |
| `pipelineConfig` | map | FE | |
| `submittedBy` | string | FE | |
| `createdAt` | Timestamp | FE | used by `orderBy("createdAt","desc")` |
| `updatedAt` | int millis | **D** | |
| `expireAt` | Timestamp | **S** admin | TTL; cleared on re-pair |
| `lastError` | string | **D** | |
| `beDone` / `beDoneAt` | bool / int millis | **D** | BE→FE handoff; status stays `ongoing` until FE-P5 flips it |
| `needsFeTrigger` / `needsFeTriggerAt` | bool / int millis | **D** | |
| `links.<kind>` | map `{url, ...}` | **D** | dotted-path merge, **one canonical slot per kind**: `brief`\|`chatgpt`\|`gemini`\|`claude`\|`notebooklm`\|`audio`\|`youtube` (also `links.phase1`/`links.phase2`) |
| `userSources` | array | **D** | `ArrayUnion` **append-log**, not keyed |
| `queuePosition` / `queuedBehindRunId` / `queuedBehindTitle` | int / string / string \| `DELETE_FIELD` | **D** | title truncated to 60 |
| `queueEtaMs` | int | **D** | **`< 0` is the "unknown" sentinel** — the FE suppresses the ETA line |
| `queueEtaComputedAt`, `queueTotalAhead`, `queueAheadFromSelf`, `queueAheadFromOthers` | int | **D** | |
| `cancelled` | bool | **D** | set `true` **only** for runs that were *queued and never started* |
| `stoppedAt` / `stoppedBy` | int millis / string | **D** | `stoppedBy ∈ {owner_stop, owner_cancel, hard_reset_active, hard_reset_drained, hard_reset_sweep}` |
| `cancelledReason` | string | **S** admin | `device_pair_expired` \| `device_retired` \| `device_unlinked` |
| `titleLocked` | bool | FE | sticky-once-true |

Canonical first-write pattern (the FE may not have created the doc yet):
```python
if not _update_research_doc(uid, rid, payload):
    _set_research_doc(uid, rid, payload, merge=True)
```

### 4.7 Other device-written subcollections

`.../researches/{rid}/documents/{docType}` → `{id, name, type, content, size, createdAt:int, deviceId}`
`.../researches/{rid}/audios/{audioId}` → `{id, name, duration:"M:SS", durationSec:int, createdAt:int, audioUrl?, deviceId}`
Both via `set(merge=True)` — doc-id-keyed upsert. Create = `deviceWritingTo`,
update = `deviceUpdatingFor`, delete = owner-only.

`.../researches/{rid}/commands/{autoId}` — the device's **live control channel**, deliberately
looser than the queue: update gates on **`deviceMemberOf`**, so there is **no `hasOnly`** and
**no `deviceId` requirement** on the ack write (legacy commands lack `deviceId` and would replay
forever otherwise). FE writes `{action, command_id, deviceId?, processed:false, timestamp:int, decisionId?}`;
the device acks `{processed:true}`, `{processed:true, pongedAt:int}` for `action=="ping"`, or
`{processed:true, staleSkipped:true}` for first-attach replays older than 30 s. Startup sweep is
`where('processed','==',true)` then delete. This is the **one** place `_be_payload` is deliberately
not used.

`users/{uid}/settings/prefs` — device **read-only**:
`{apiKeys: {gemini?, anthropic?, deepgram?, byDevice?: {[deviceId]: {gemini?, anthropic?, deepgram?}}}, ...}`.
The device **must** be able to read this or every run dies with "No API key"
(`research.py` reads `collection("settings").document("prefs")`). It reads it for **both** the
paired owner **and** the submitting sharer's tree.

---

## 5. THE ATOMIC PAIR-CONFIRM

### 5.1 The deadline

`dg-research/src/app/api/devices/claim/route.ts · BE_CONFIRM_DEADLINE_MS = 5 * 60 * 1000`.

Both the initial-pair and re-pair branches stamp
`expireAt: Timestamp.fromMillis(Date.now() + BE_CONFIRM_DEADLINE_MS)` — **replacing** whatever
`expireAt` was there (24 h at initiate, 15 min at reset). Re-pair additionally does
`pairConfirmedAt: FieldValue.delete()`, so a re-paired device **must confirm again**.

The three lifecycle values of the **same field** on the **same doc**:

| Stage | `expireAt` | Meaning |
|---|---|---|
| initiate-pair | `now + 24 h` | unclaimed cold code |
| claim (both minting branches) | **`now + 5 min`** | device must confirm |
| reset-pair-code | `now + 15 min` (`RESET_TTL_MS`) | owner must re-pair |

Enforced by a Firestore TTL policy declared as
`{collectionGroup:"devices", fieldPath:"expireAt", ttl:true}` in `dg-research/firestore.indexes.json`.

**The first authenticated write MUST be:**
```
{ pairConfirmedAt: true, expireAt: <deleted>, lastHeartbeat: <int millis>, status: "active" }
```
Miss the window and `devices/{deviceId}` is deleted outright. Recovery is **impossible**:
`allow create: if false`, and the synth update rule reads `resource.data.syntheticDeviceUid` —
which no longer exists. The only path back is a fresh `initiate-pair` (new `deviceId`, new synth
uid, orphaned Auth user, dead pollSecret path).

Nothing on the FE ever clears the device doc's own `expireAt`. The device is the only writer that
deletes it (`research.py · _pair_patch_device` during pair, `_heartbeat_loop` every tick thereafter).

The FE additionally hides the tile until `isPairConfirmed`
(`dg-research/src/lib/firestore.ts · isPairConfirmed`):
```ts
d.pairConfirmedAt === true || (typeof d.lastHeartbeat === "number" && d.lastHeartbeat > 0)
```
So an undeployed TTL is **invisible in the UI** while leaving real orphan docs in Firestore.

### 5.2 The three coexisting `update` rules

`dg-research/firestore.rules · match /devices/{deviceId}` carries **three separate
`allow update` statements**. Firestore **ORs** them, and each carries its **own** `hasOnly()` list.
A write is permitted only if it satisfies **at least one rule entirely** — mixing a synth-list
field with an owner-list field in one write satisfies **neither**. Pinned by
`it("synth user CANNOT update a non-allowed device field even alongside allowed ones")`:
`assertFails(updateDoc(..., {busyWorkerIds: arrayUnion(2), pairCode: "HACKED01"}))`.

**(A) SYNTHETIC DEVICE USER** — gate `request.auth.uid == resource.data.syntheticDeviceUid`.
`affectedKeys().hasOnly([...])` over exactly **22** keys, verbatim and complete:

```
lastHeartbeat
status
logins
authMode
pairConfirmedAt
expireAt
supervised
currentRunId
currentRunOwnerUid
currentRunTitle
currentRunStartedAt
currentRunPhase
currentRunPhaseStartedAt
workerCount
busyWorkerIds
workers
queueOwners
version
updateAvailable
updateStatus
versionCheckedAt
sourceCheckout
```

**(B) OWNER** — gate `request.auth.uid == resource.data.ownerUid`. `hasOnly` over **4** keys:
```
name  priority  supervised  restingWorkerIds
```

**(C) DEVICE MEMBER** (owner **or** sharer) — `hasOnly` over **1** key:
```
feFifoCurrent
```

`supervised` appears in **both** (A) and (B) — deliberate. The synthetic device user is **not** a
member and cannot write `feFifoCurrent`.

### 5.3 Swift form

```swift
// CORRECT — updateData with strictly allow-listed keys, no deviceId.
try await db.collection("devices").document(deviceId).updateData([
    "pairConfirmedAt": true,
    "expireAt":        FieldValue.delete(),
    "lastHeartbeat":   Int64(Date().timeIntervalSince1970 * 1000),
    "status":          "active",
])
```
**Never** `setData(_:)` without `merge: true` on an existing device doc: the implicit field
**removals** all land in `diff().affectedKeys()` and the whole write is denied.

---

## 6. STORAGE

`dg-research/storage.rules`.

| Path | device `read` | device `write` | owner |
|---|---|---|---|
| `audio/{userId}/{allPaths=**}` | ❌ **denied** | ✅ `create, update` via `deviceOwns(userId)` | read + delete only |
| `users/{userId}/researches/{rid}/sources/{filename}` | ✅ `deviceOwns(userId)` | ❌ | write ≤ 10 MB, `filename.matches('.*\\.(md\|txt\|pdf\|docx)$')` |
| `album-art/{userId}/{allPaths=**}` | ✅ **public** (`read: if true`) | ❌ | write < 5 MB, `contentType.matches('image/.*')` |
| everything else | ❌ | ❌ | ❌ |

Note the `sources` path uses a **single `{filename}` segment**, not `{allPaths=**}` — any nested
subpath under `sources/` falls to the deny-all catch-all.

Upload shape the BE uses (`research.py · _upload_audio_via_storage_rest`):
```
POST https://firebasestorage.googleapis.com/v0/b/{bucket}/o?uploadType=media&name={urlencoded objectPath}
Authorization: Firebase {idToken}
```
Playable URL is assembled from the **upload response's** `downloadTokens` (comma-separated; take
the **first** entry):
```
https://firebasestorage.googleapis.com/v0/b/{bucket}/o/{urlencoded objectPath}?alt=media&token={token}
```
**Never** call `getDownloadURL()` / `getMetadata()` after the upload — `allow read` on
`audio/{userId}` is `uid == userId` only, so the device 403s. Pinned by
`dg-research/tests/rules/storage.rules.test.ts · it("owner CAN read their own audio; synth and foreign CANNOT")`.

Before any **cross-tree** Storage upload, force a token refresh
(`getIDTokenResult(forcingRefresh: true)` / `_fresh_user_mode_id_token`) and silently retry a 403
with a fresh token — Storage authorization is 100 % token-claim-derived and therefore stale.

---

## 7. `pendingDecision` — the single-slot durable mirror

One field, one slot, per research. `research.py · _persist_pending_decision` writes the whole map;
`_clear_pending_decision` removes it with the **`DELETE_FIELD` sentinel** — never `null`, never
`{}` (the FE distinguishes absent from present-but-empty).

Five clobber rules, all load-bearing:

1. **Agent keep-guard** — `_clear_pending_decision(agent=X)` must **not** clear when
   `_pending_decision_active` and `_pending_decision_agent` is not `None` and `!= X`. A launch-failed
   agent's mirror is non-blocking, so the run advances and a *later* agent's blocking card takes the
   slot; a blanket clear then deletes the newer, still-live card. The loss is invisible until the
   user closes and reopens the chat.
2. **Agent-less clears are unconditional.** Scoping happens at the `emit_event` seam:
   `_clear_pending_decision(agent if event_type in ("agent_skipped","pipeline_resumed") else None)`.
   So `pipeline_stopped`, `phase_skipped` and `phase_restart` **always** pass `None`.
   `phase_restart` is in the clear set because clicking **Retry** emits `phase_restart` but **not**
   `pipeline_resumed`.
3. **`suppress_generic_mirror`** — a kind-specific persist (`pro_required`, `login_required`,
   `human_verification_required`, `agent_link_failed`) sets it so the generic `pipeline_error`
   mirror does not overwrite the richer payload.
4. **Late async upgrade must not steal the slot** —
   `owns_mirror = bool(_pending_decision_active and _pending_decision_did == decision_id)`;
   pass `suppress_generic_mirror=(not owns_mirror)`. This is the only reader of `_pending_decision_did`.
5. **Startup wipe** — every fresh **non-queued** run start writes `pendingDecision: DELETE_FIELD`
   in the *same* patch as `backendRunId`/`status`. The **queued** branch deliberately does not wipe.

The generic mirror gate is a four-way AND:
`type == "pipeline_error"` **AND** `data["actions"]` truthy **AND**
`(not data.get("quiet") or force_mirror)` **AND** `not suppress_generic_mirror`.
Persisting every `pipeline_error` would make transient 529/overload auto-retry banners durable.

`kind ∈ {login_required, human_verification_required, agent_link_failed, pro_required, pipeline_error}` —
unknown kinds are **skipped** by the FE. `auto_skip_deadline` is an **absolute epoch-ms** value,
not a duration.

---

## 8. REST transport notes for the Python layer

Evidence: `dg-research-backend/agent/facade/firestore_rest.py · to_value / update_research`.

- `to_value()` **raises `TypeError` on a `datetime`.** `expireAt` must be hand-encoded as
  `{"timestampValue": "<iso8601 with Z>"}`.
- `to_value()` encodes a Python `int` as `{"integerValue": "<string>"}`. Firestore rules still
  evaluate `integerValue` as a **number**, so `seq is number` / `timestamp is number` pass over
  REST. A `stringValue` would be **denied**.
- There is **no `DELETE_FIELD` over REST.** A field delete is expressed by listing the path in
  `updateMask.fieldPaths` while **omitting** it from the body — exactly what
  `research.py · _pair_patch_device` and `firestore_rest.py · update_research(delete_fields=…)` do.
- Firestore REST has **no cross-field OR**. `firestore_rest.py · FirestoreRest.list_devices` unions
  two `structuredQuery` `runQuery` calls (`ownerUid EQUAL`, `sharedWith ARRAY_CONTAINS`) — copy
  that rather than inventing a query.
- If you use REST instead of gRPC there is no `client._credentials` to force-refresh, so the 403
  self-heal ([TRAP-14](#trap-14--omitting-the-403-self-heal)) must re-mint the ID token itself.

---

## 9. QUERIES AND INDEXES

`dg-research/firestore.indexes.json` ships **`"indexes": []`** — **zero composite indexes**. Only
7 `fieldOverrides`, all TTL on `expireAt`, for collection groups:
`researches`, `queue`, `agentLogins`, `devices`, `pending`, `notify_dedup`, `entries`. Each declares
`indexes: [{order:"ASCENDING", queryScope:"COLLECTION"}]` **only** — which *replaces* the default
single-field index config for that field, so treat DESCENDING order and COLLECTION_GROUP scope on
`expireAt` as unavailable.

**There is no `fieldOverride` for `pipeline_events.expireAt`** even though `_emit_to_firestore`
writes a 30-day `expireAt` on every event — see [UNRESOLVED-02](#unresolved-02).

The six query shapes the existing clients actually run. **Copy these verbatim rather than inventing
new ones**:

```
devices/{id}/queue                                        .limit(50)          — UNORDERED
devices/{id}/commands        where("processed","==",true)
users/{uid}/researches       where("status","==","queued")
users/{uid}/researches       orderBy("createdAt","desc")
.../pipeline_events          where("seq",">",lastSeq) orderBy("seq","asc")
devices                      or(where("ownerUid","==",uid), where("sharedWith","array-contains",uid))
```

**Queue FIFO order is computed CLIENT-SIDE.** There is no `orderBy` and no index to support one.
Two different sorts exist and they disagree:

| Path | Key |
|---|---|
| listener pre-query (`research.py · start_firestore_start_listener` → `_queue_doc_fifo_ms`) | `submittedAt` (server, skew-immune) → fallback legacy client-ms `timestamp` → `None` sorts last |
| idle rescan (`research.py · _rescan_queue_for_unclaimed · _fifo_key`) | **legacy client-ms `timestamp` ONLY**; missing ⇒ `(1, 0, snap.id)` sorts last |

Tiebreaker is always the doc id. Scan windows are hard-capped and silently truncating:
listener pre-query `.limit(20)`, idle rescan `.limit(20)`, `_compute_queue_enrichment` `.limit(50)`.

FE liveness constants — `dg-research/src/lib/firestore.ts`:
```ts
export const DEVICE_OFFLINE_THRESHOLD_MS = 30_000;   // "Online" iff Date.now() - (d.lastHeartbeat||0) < this
export const DEVICE_STATUS_REFRESH_MS    =  2_000;   // nowTick re-render interval
```

---

## 10. ⚠ SILENT-FAILURE TRAPS

Every one of these fails **without an error at the point of the mistake**. Each entry names the
assertion that catches it — wire these as tests or startup assertions in both consumers.

---
### TRAP-01 — Hashing the bytes instead of the hex text
**What breaks:** `pollSecretHash` is wrong, so the claim route writes the customToken to a
different doc id than the one the device polls.
**Why silent:** hashing the 32 decoded bytes yields a perfectly valid-looking 64-hex string that
**passes** the route's `/^[0-9a-f]{64}$/`, gets a **200**, and is stored as the pending doc id.
The device then GETs a path that will never exist and times out after **15 minutes with no error
anywhere**.
**Assertion:** golden vector for `pollSecret = "0" * 64` (i.e. `"00" * 32`) — computed and verified
locally on 2026-07-29:
```
CORRECT   sha256(ascii_bytes_of_the_64_char_string)  = 60e05bd1b195af2f94112fa7197a5c88289058840ce7c6df9693756bc6250f55
WRONG     sha256(bytes.fromhex(secret))              = 66687aadf862bd776c8fc18b8e9f8e20089714856ee233b3902a591d0d5f2925
```
Both are valid 64-hex strings and both pass the server's regex. Assert your implementation produces
the **first** one.
**Evidence:** `auth/v2_flow.py · compute_poll_secret_hash`; `initiate-pair/route.ts · POLL_SECRET_HASH_RE`.

---
### TRAP-02 — Uppercase hex on the wire
**What breaks:** the route `.toLowerCase()`s before using the value as the doc id, so uppercase hex
is accepted with 200 but the device polls `.../pending/<UPPERCASE>` forever.
**Why silent:** 200 OK, then a 404 loop indistinguishable from "human hasn't typed the code yet".
**Assertion:** `assert hash == hash.lower() and re.fullmatch(r"[0-9a-f]{64}", hash)` before POSTing.

---
### TRAP-03 — Missing the 5-minute pair-confirm deadline
**What breaks:** Firestore TTL deletes `devices/{deviceId}` outright. `deviceOwnership()` then has
no lookup target, so **every** user-tree read and write 403s at once, and recovery is impossible
(`allow create: if false`).
**Why silent:** the pair *appeared* to work — the human saw "success" in the browser. The tile then
simply never appears (or vanishes), and `_pair_patch_device` is single-attempt, returns `False`, and
**never raises**.
**Assertion:** after custom-token exchange, assert the confirm write returned success **and** that a
re-read of `devices/{deviceId}` shows `pairConfirmedAt == true` and **no** `expireAt` field. Retry
the confirm write; do not rely on one attempt. Start the 5 s heartbeat immediately as a second net.

---
### TRAP-04 — `hasOnly()` is all-or-nothing
**What breaks:** **one** off-list key denies the **entire** write. In Swift, `setData(_:)` without
`merge: true` on an existing device doc is fatal — the implicit field **removals** all land in
`diff().affectedKeys()`.
**Why silent:** the heartbeat just stops landing; the device reads offline while it is working fine.
**Assertion:** unit-test the exact key set of every device-doc write against the 22/4/1 lists in
[§5.2](#52-the-three-coexisting-update-rules), and assert no single write mixes keys from two lists.
**Evidence:** `it("synth user CANNOT update a non-allowed device field even alongside allowed ones")`.

---
### TRAP-05 — Putting `deviceId` in the device-doc payload
**What breaks:** `deviceId` is not in the 22-key allow-list, so adding it (the natural instinct)
403s the **whole** heartbeat.
**Why silent:** it is the *inverse* of the user-tree rule, so it feels correct. The `_heartbeat_loop`
comment calls this out explicitly: "no deviceId field in the payload".
**Assertion:** `assert "deviceId" not in heartbeat_payload`.

---
### TRAP-06 — Omitting `deviceId` from a user-tree payload
**What breaks:** the exact inverse of TRAP-05. `deviceWritingTo` (create) and `deviceUpdatingFor`
(update) both require `request.resource.data.deviceId == token.deviceId`.
**Why silent:** for an **update**, `request.resource.data` is the **merged post-write** doc, so a
doc already stamped correctly passes *without* restating `deviceId` — the bug only appears on
docs that have never been stamped (the 2026-05-28 403 sweep).
**Assertion:** stamp it **unconditionally** on every user-tree write (`_be_payload`'s behaviour) and
assert `"deviceId" in payload` in the write helper.
**Additional trap:** `_be_payload` with no persisted `deviceId` **logs a WARN and returns the
payload unchanged** — the doomed write then 403s at the transport. Fail loudly at payload-build time.

---
### TRAP-07 — `pipeline_events` `seq`/`timestamp` as anything but an int
**What breaks:** `PERMISSION_DENIED`. The rule requires `seq is number` **AND**
`timestamp is number` on **both** branches. `serverTimestamp()`, a Swift `Date`, or a Firestore
`Timestamp` all fail. Forgetting `timestamp` entirely is easy because `emit_event` adds it
implicitly rather than callers passing it.
**Why silent:** it looks like a rules/auth problem, not a schema problem.
**Assertion:** type-assert `Int64` on both fields immediately before the write.

---
### TRAP-08 — `seq` as a 0-based per-run counter
**What breaks:** the FE filters server-side with `where("seq",">",lastSeq)` where `lastSeq` lives in
`localStorage`. FE-P4/P5 emit `Date.now() + offset`, so after any resume the cursor has already
advanced far past a 0-based counter and **every** post-resume BE event is dropped **forever** on
that browser.
**Why silent:** all the writes **succeed**. The failure is invisible server-side.
**Assertion:** `assert seq > 1_600_000_000_000` (i.e. plausibly epoch-ms) on every emit.
`_fb_seq` resets to 0 at both run setup and teardown and is **never** seeded from Firestore — that
is only safe because `seq` is ms-based.

---
### TRAP-09 — Unlocked read-modify-write on the `seq` monotonic guard
**What breaks:** `new = int(time*1000); if new <= _fb_seq: new = _fb_seq + 1; _fb_seq = new` has
**no lock**, and `emit_event` genuinely runs on two threads (the Firestore command-listener callback
invokes `emit_event("command_ack", …)` directly). Two emits in the same millisecond from different
threads can compute the **same** `seq`; the FE's client-side `if (seq > lastSeq)` then drops the
second **permanently**.
**Why silent:** both writes succeed; one event silently never renders.
**Assertion:** take a mutex around the compute-and-store, and assert strict monotonicity in a
concurrency test.

---
### TRAP-10 — `deviceId` nested inside `data` on a pipeline event
**What breaks:** `deviceWritingTo` compares `request.resource.data.deviceId`. A nested
`data.deviceId` is invisible to the rule ⇒ denied.
**Why silent:** the field *is* present in the document you inspected.
**Assertion:** assert `deviceId` is a top-level key of the event dict.

---
### TRAP-11 — `lastHeartbeat` as a Timestamp
**What breaks:** the FE computes `Date.now() - lastHeartbeat` directly.
`mapModernDeviceDoc` tolerates a Timestamp-like via `.toMillis()`, but a `serverTimestamp()`
**sentinel** or a seconds-based value makes the device read as **perpetually offline** (or `NaN`).
**Why silent:** the write succeeds; only the UI is wrong.
**Assertion:** `assert isinstance(v, int) and v > 1_600_000_000_000`.
Same for queue/command `timestamp` (numeric 30 s stale gate).

---
### TRAP-12 — `pairConfirmedAt` as anything but boolean `true`
**What breaks:** `isPairConfirmed` checks `=== true` **exactly**. A Timestamp, `1`, or `"true"`
fails the gate and the device **never appears in the list**.
**Why silent:** the `-At` suffix strongly implies a timestamp. The write is accepted.
**Assertion:** `assert payload["pairConfirmedAt"] is True`.

---
### TRAP-13 — Aware datetime on `creds.expiry`
**What breaks:** google-auth compares `expiry` against `datetime.utcnow()` (naive) inside
`Credentials.expired`. An aware datetime raises
*"can't compare offset-naive and offset-aware datetimes"* deep inside gRPC's auth-refresh path.
**Why silent:** it surfaces at the client as a **503 with an EMPTY exception message** — effectively
undebuggable from the symptom.
**Assertion:** `assert creds.expiry.tzinfo is None`.
**Evidence:** `auth/credentials.py · RefreshTokenCredentials.bootstrap` / `_REFRESH_MARGIN_SECONDS`.

---
### TRAP-14 — Omitting the 403 self-heal
**What breaks:** a freshly minted synth token routinely **lags** `deviceId`-claim propagation, so
the **first** user-tree write of most runs 403s. `research.py · _grpc_write_with_heal` force-refreshes
the credential (`_firebase_db._credentials.refresh(None)`) and retries **exactly once**.
**Why silent:** it does not fail *rarely* — it fails on most runs, and without the heal each such
write just "degrades gracefully" to nothing. The log line was demoted from WARN to INFO precisely
because it is routine.
**Assertions / invariants to preserve:**
- Retry **exactly once**, then **re-raise** (a heal that swallows turns "degraded" into "vanished").
- Throttle to one force-refresh per `_GRPC_HEAL_COOLDOWN_S = 30.0` and latch
  `_grpc_heal_structural` after `_GRPC_HEAL_STRUCTURAL_AFTER = 3` consecutive unhealed denials, both
  under `_grpc_heal_lock`.
- **Reset both counters on a SUCCESSFUL write** — otherwise one structural latch permanently
  disables the heal for the process lifetime.
- A denied **READ** must be healed too. `_do_phase_terminal_status_write` wraps the whole
  `get()` + upsert + `update()` inside one heal so the refresh re-runs **both** halves.
- Detection must string-match, not just check the exception class: a denied read **inside a
  transaction** surfaces as `ValueError("The transaction has no transaction ID, …")`, not
  `PermissionDenied` (`research.py · _is_synth_permission_denied`).
- Use an **uncached** config `deviceId` for the diagnostic
  (`research.py · _config_device_id_uncached`) — a stale memo cache after a mid-process re-pair
  inverts the token-vs-config comparison and points at the wrong cause.
- **Fragility:** the heal reads the **private** attribute `_firebase_db._credentials`. `init_firebase`
  type-asserts it and warns the heal is "NEUTERED" otherwise. A library upgrade that renames it
  disables the heal **silently**.

---
### TRAP-15 — Uncoalesced credential refresh
**What breaks:** `emit_event` fires thousands of times per run. Without coalescing, a burst of 403s
becomes a securetoken storm plus a non-atomic keystore rotation.
**Why silent:** it looks like intermittent network flakiness.
**Assertion:** all refreshes serialise behind one process-wide lock **and** re-check whether another
caller already rotated the token while this one waited (`auth/credentials.py · _REFRESH_LOCK` /
`refresh`). Note `keystore.cross_process_refresh_lock` **degrades to unlocked** after a 15 s timeout,
so the real safety net is the *re-read-before-POST* plus the *re-read-before-wipe* RC-5 guards at
both `RevokedError` sites (`auth/v2_flow.py · init_firestore_user_scoped` /
`research.py · _fresh_user_mode_id_token`). Reimplement the guards or a concurrent refresh will look
like a revoke and **wipe the credential**.

---
### TRAP-16 — Consuming the pending doc twice
**What breaks:** the device cannot delete the pending doc (rules deny it), and it lives for up to
15 minutes. A retry/reconnect that re-polls the same path gets the **same already-consumed**
customToken and `signInWithCustomToken` fails with `INVALID_CUSTOM_TOKEN`.
**Why silent:** an endless spin that looks like a network problem. The BE guards this by refusing to
enter the poll unless `_firebase_down_reason == "revoked"`.
**Assertion:** latch "already consumed" locally, keyed on the token string or a monotonic
pair-generation counter.

---
### TRAP-17 — Polling `pending` after an idempotent re-claim
**What breaks:** only **initial-pair** and **re-pair** mint a token. If the human enters a code for a
device that is already active-and-owned (or already shared), the route returns
`already-owner` / `already-shared` with **NO write to pending**.
**Why silent:** the device hangs for the full **15-minute** timeout with no error. It cannot
distinguish a rejected claim from a human who has not typed the code yet — all it ever sees is
"the pending doc never appeared". See also [UNRESOLVED-06](#unresolved-06).
**Assertion:** never poll unconditionally on "the user says they claimed it". Bound the wait and
surface an explicit "check that this device is not already paired" state.

---
### TRAP-18 — Treating the synthetic device user as a device member
**What breaks:** the device **cannot** create queue docs, **cannot** create device commands, and
**cannot read or write `feFifoWaiters` at all**. There is no rule that could ever allow it.
**Why silent:** the natural mental model ("the device is on the device") is wrong, and
`isDeviceMember` reads as if it includes it.
**Assertion:** an integration test asserting `PERMISSION_DENIED` on: create in
`devices/{id}/queue`, create in `devices/{id}/commands`, and read of `devices/{id}/feFifoWaiters`.
**Evidence:** `firestore.rules · match /queue/{queueId}` (`isDeviceMember` on create),
`match /feFifoWaiters/{researchId}` (member-only on all five verbs),
`it("owner CANNOT claim a queue doc (claim is synth-only)")`.

---
### TRAP-19 — Any `collectionGroup()` query
**What breaks:** denied for every principal, because **no collection-group rule exists anywhere**.
**Why silent:** it reads as an empty result if you don't check the error.
**Assertion:** `assertFails(getDocs(collectionGroup(db, "pending")))` — already in the FE test suite.
Always address `devices/{id}/queue`, `users/{uid}/researches/{rid}/pipeline_events`, etc. by their
concrete parent path.

---
### TRAP-20 — Inventing a new query shape
**What breaks:** with `"indexes": []` there are **zero** composite indexes. A range/inequality plus
an `orderBy` on a different field, or two range filters, fails at runtime with
**`FAILED_PRECONDITION`**.
**Why silent:** it is easy to misdiagnose as a rules problem, and it only appears once real data
exists. Worse: the 7 `expireAt` fieldOverrides declare **only** `{ASCENDING, COLLECTION}`, which
*replaces* the default single-field config for that field.
**Assertion:** restrict the client to the six shapes in [§9](#9-queries-and-indexes); assert in CI
that no other query shape is constructed.

---
### TRAP-21 — Reimplementing queue FIFO as `orderBy("submittedAt")`
**What breaks:** behaviour changes for legacy docs that lack the field (Firestore `order_by`
**excludes** docs missing the field entirely), and there is no index for it.
**Why silent:** the queue silently reorders or silently loses entries.
**Assertion:** port `_queue_doc_fifo_ms` verbatim (prefer `submittedAt`, fall back to client-ms
`timestamp`, demote missing to last, tiebreak on doc id) over an **unordered** `.limit(50)` scan.

---
### TRAP-22 — Marking a queue doc `processed`
**What breaks:** `processed` is **read** by the BE but is **absent** from the queue update
allow-list `['assignedWorker','claimedAt','restDeferredAt']`, so the write is denied outright.
Consumption is **by delete only**. (Device **command** docs are the opposite — `processed` **is**
allowed there.)
**Why silent:** the natural symmetry with commands makes it look right.
**Assertion:** integration test asserting denial of `update({processed:true})` on a queue doc.

---
### TRAP-23 — Replacing the claim CAS with a transaction
**What breaks:** the current `_try_claim_queue_doc` is deliberately a conditional update
(`last_update_time` precondition), **not** a transaction, because a denied read or a JWT-refresh
blip inside a tx surfaces as `ValueError("The transaction has no transaction ID, so it cannot be
rolled back")` — masking the real 403/`Unauthenticated`.
**Why silent:** the misleading `ValueError` hides the actual cause.
**Assertion:** keep it a CAS. **Inverse:** the research doc's `queued → ongoing` flip **must stay a
transaction** (`_flip_queued_to_ongoing · _flip_txn`, which flips only if `status == "queued"`) or a
concurrent cancel gets silently overwritten back to `ongoing`.

---
### TRAP-24 — Extending the claim payload to identify the process
**What breaks:** you cannot add a pid, hostname, lease expiry or process uuid to the claim update —
the queue update `hasOnly` list is exactly three keys, and any extra key denies the **entire** write.
**Why silent:** the whole claim fails, which reads as a race loss.
**Assertion:** integration test that a 4-key claim update is denied.

---
### TRAP-25 — Assuming Firestore and Storage resolve sharing the same way
**What breaks:** Firestore resolves `sharedWith` from the device **doc** (live `get()`); Storage
resolves it from the **token claim** (stale until refresh). A sharer added seconds ago works
instantly for Firestore and **403s on Storage**.
**Why silent:** the Firestore half works, so it looks like a Storage bug.
**Assertion:** call `getIDTokenResult(forcingRefresh: true)` before a cross-tree Storage upload, and
retry a 403 once with a fresh token.

---
### TRAP-26 — Reading back your own audio upload
**What breaks:** the device can **write** `audio/{userId}/**` but can never **read** or **delete**
it (`allow read`/`allow delete` are `uid == userId` only). `getDownloadURL()` / `getMetadata()` 403.
**Why silent:** the upload succeeded, so the 403 looks unrelated.
**Assertion:** build the URL from the upload response's `downloadTokens`; assert the code path never
calls a read API on that bucket prefix.

---
### TRAP-27 — Rotating or keystore-storing the pollSecret
**What breaks:** Reset revokes the refresh token and the keystore is wiped, but re-pair polls the
**same** `sha256(pollSecret)` path. Store the secret in the keystore and post-Reset auto-relink
becomes impossible; rotate it and the server's admin-only
`_internal/device_secrets/entries/{deviceId}` no longer matches, so the claim writes to a path you
will never read.
**Why silent:** `allow list: if false` means you cannot even discover the real path — a 404 loop
forever.
**Assertion:** assert the persisted secret is byte-identical across a simulated credential wipe, and
that `initiate-pair` is never re-called while a `deviceId` is already persisted.

---
### TRAP-28 — Losing the initial pair because `ownerUid` became *absent*
**What breaks:** `unpair-self`'s owner-unlink uses `FieldValue.delete()` on `ownerUid`, so the field
becomes **absent**, while `initiate-pair` writes literal `null`. The claim route matches
`pairState === "awaiting-initial-claim" || ownerUid === null`, and an absent field reads as
`undefined` (`undefined === null` is **false**) — so re-linking an owner-unlinked device relies
entirely on the `data.ownerUid ?? null` coercion.
**Why silent:** drop the coercion and the flow falls through to Branch 3 and creates a
**share-claim** instead of an initial pair — no token is minted and the device waits forever.
**Assertion:** if you ever reimplement claim-side logic, unit-test both `ownerUid: null` and
`ownerUid` absent.

---
### TRAP-29 — Trusting prose over constants for the offline window
**What breaks:** `DEVICE_OFFLINE_THRESHOLD_MS` is **30_000**, but comments in
`dg-research/src/lib/firestore.ts`, in `dg-research/firestore.rules`, and the BE's own
`_heartbeat_loop` docstring all still say **15 s**.
**Why silent:** you build a heartbeat cadence against the wrong window.
**Assertion:** import the constant; never hardcode from a comment.

---
### TRAP-30 — Assuming this repo's rules file is what is enforced
**What breaks:** Firestore enforces the **deployed** ruleset. The file's own header documents a
silent drift that was the root cause of the April 2026 "Permission denied" pairing bug, and the
2026-05-28 403 sweep was the same class of failure (fields present in the file, absent from the
deployed ruleset).
**Why silent:** every symptom points at the client.
**Assertion:** before concluding an iOS 403 is a client bug, confirm the **live** ruleset. Deploys
are `firebase deploy --only firestore:rules` / `--only storage` against `super-research-492814`.

---
### TRAP-31 — Legacy device fanout divergence
**What breaks:** `dg-research/src/lib/firestore.ts · listenToDevices` merges **two** listeners —
the modern top-level `devices` OR-query **and** the legacy `users/{uid}/devices` — with modern
winning by id. `isPairConfirmed` is applied **only** to the modern results;
`mapLegacyDeviceDoc` applies **no** pair-confirm gate and always renders.
**Why silent:** a modern-only reader shows a different device list than the Account page for any
account holding legacy entries — with no error.
**Assertion:** decide explicitly whether iOS reads the legacy tree, and document the choice. (Note
the device **cannot** read `users/{uid}/devices/**` at all — that tree is owner-only.)

---
### TRAP-32 — Non-atomic `install_uuid` creation
**What breaks:** `auth/keystore.py · install_uuid` writes with a plain `write_text`, **no** tmp+replace
and **no** lock. Two processes racing on a fresh install mint **different** UUIDs; the loser keeps a
UUID whose keyring slots are orphaned.
**Why silent:** the device simply "looks unpaired".
**Assertion:** make it atomic (`mkstemp` + `os.replace`) when vendoring; assert a re-read returns
the same value.

---
### TRAP-33 — Losing the `keystore.set()` shadow purge
**What breaks:** after a successful keyring write, `set()` purges any **file-fallback shadow** of that
slot. Without it, `get()` can return a **stale** token from `auth.json` on a transient keyring miss.
**Why silent:** an old refresh token that "sometimes" gets used.
**Assertion:** preserve the purge; test keyring-success-then-keyring-miss returns `None`, not the
stale file value. Relatedly, `_try_keyring()` must treat `keyring.backends.fail.Keyring` **and** an
empty `ChainerBackend` as "no backend" — `get_keyring()` never raises on a headless host, it returns
a sentinel whose every operation throws.

---
### TRAP-34 — Copying legacy FE fallbacks
**What breaks:** `research_tokens/*`, `pipeline_requests/*` and `agentLogins/*` have **no rule at
all** and are denied to every client, yet the FE still contains fallbacks that write to the first
two and `firestore.indexes.json` still declares a TTL for `agentLogins`.
**Why silent:** a plain `PERMISSION_DENIED` on a code path that looks blessed by precedent.
**Assertion:** grep the iOS/Python client for those three collection names; assert zero hits.

---
### TRAP-35 — Blocking the event loop with terminal-status writes
**What breaks:** multi-second synchronous Firestore I/O on the loop starves the 5 s heartbeat and
trips the 30 s offline threshold.
**Why silent:** the device shows **offline** while working perfectly.
**Assertion:** keep those writes on daemon threads (`_write_agent_terminal_status` /
`_write_phase_terminal_status`), and assert the heartbeat interval never exceeds ~2× nominal in a
load test.

---
### TRAP-36 — Rate-limit exhaustion masquerading as a pairing error
**What breaks:** `initiate-pair` is **5 per 5 minutes per client IP**. A test loop or a NAT'd device
farm exhausts it almost immediately.
**Why silent:** the response is `429 rate_limited`, not any pairing error, and only **allowed** calls
are recorded — so retrying into a 429 does not extend the lockout, which makes the state confusing.
**Assertion:** handle `429` + `retryAfterMs` explicitly and distinguish it in logs from a pairing
failure.

---
### TRAP-37 — Assuming `emit_event` will emit
**What breaks:** `research.py · emit_event` returns **early and emits nothing** if the module global
`_tracks_dir` is falsy (`if not _tracks_dir: return`). `_tracks_dir` is set only by
`init_tracks(run_name)`, which creates no directories and merely holds a `Path` as a name holder.
**Why silent:** a run with **zero** events and **zero** errors.
**Assertion:** if you vendor the emit path, assert the sentinel is set before the first emit — or
delete the sentinel entirely and assert on it in a test.

---
### TRAP-38 — Mixed-case `agent` across the event and the mirror
**What breaks:** `emit_event` writes `event['agent'] = agent` **verbatim** (no normalisation), while
`_persist_pending_decision` and `_write_agent_terminal_status` both **lowercase**. The FE dedups a
replayed live card against a hydrated card **across that boundary**.
**Why silent:** duplicate or missing cards, no error.
**Assertion:** normalise at the caller (`normalize_agent_key`) and assert both writes agree.

---
### TRAP-39 — Copying the dict before popping the mirror flags
**What breaks:** `emit_event` `.pop()`s `suppress_generic_mirror` and `force_mirror` off `data`, and
because `event['data'] = data` is a **reference**, the pops mutate the outgoing document. A
reimplementation that copies the dict first leaks both keys into every decision event.
**Why silent:** the events still write; only the schema is polluted.
**Assertion:** assert neither key ever appears in a written `pipeline_events` doc.

---
### TRAP-40 — Sharing one FE cursor key between two listeners
**What breaks:** two independent FE listeners subscribe per research (the per-chat one and the global
notifier). A shared `localStorage` `lastSeq` key let the always-on notifier burn the cursor past a
paused chat's `login_required` card before the user opened the chat.
**Why silent:** no card, and the run reads as "stuck at init".
**Assertion:** distinct `cursorKey` per listener; and never advance/persist `lastSeq` for a batch
you could not apply (the `shouldConsume` gate) — burning the cursor past un-applied events loses
them permanently across reloads.

---

## 11. WHAT MUST BE PARAMETERIZED WHEN VENDORING `auth/`

`dg-research-backend/auth/` is exactly 4 modules + `__init__.py`: `pairing.py`, `keystore.py`,
`credentials.py`, `v2_flow.py`. `__init__.py · __all__` re-exports only
`["credentials", "keystore", "pairing"]` — **not** `v2_flow`, which callers import explicitly as
`from auth import v2_flow`.

### 11.1 Already env-parameterized (only these three)

| Symbol | File | Env var | Default |
|---|---|---|---|
| `PROJECT_ID` | `auth/v2_flow.py` | `FIREBASE_PROJECT_ID` | `super-research-492814` |
| `WEB_API_KEY` | `auth/v2_flow.py` | `FIREBASE_WEB_API_KEY` | `<FIREBASE_WEB_API_KEY redacted - read from env or the gitignored plist>` |
| `FE_BASE_URL` | `auth/v2_flow.py` | `RESEARCH_FE_BASE_URL` | `https://superresearch.io` (rstripped) |

Read at **import time** into module globals.

### 11.2 NOT parameterized — must be made injectable

**Every one of these is an import-time module-level constant with ZERO env override.**

| Symbol | File | Current value | Why it must change |
|---|---|---|---|
| `SERVICE` | `auth/keystore.py` | `"super-research"` | keyring **service** name — shared service + shared `install_uuid` ⇒ shared credential slot |
| `_FALLBACK_DIR` | `auth/keystore.py` | `Path.home() / ".super-research"` | root of all four paths below |
| `_FALLBACK_PATH` | `auth/keystore.py` | `_FALLBACK_DIR / "auth.json"` | file-fallback refresh-token store (chmod 0600) |
| `_INSTALL_UUID_PATH` | `auth/keystore.py` | `_FALLBACK_DIR / "install_uuid"` | **the sole scoping key for every keyring account** |
| `_WIPE_LOG` | `auth/keystore.py` | `_FALLBACK_DIR / "keystore-audit.log"` | destructive-op audit |
| `_REFRESH_LOCK_PATH` | `auth/keystore.py` | `_FALLBACK_DIR / ".refresh.lock"` | cross-process refresh lock |
| `_STATE_DIR` | `research.py` | `Path.home() / ".super-research"` | (BE, not in `auth/`) |
| `RESEARCH_CONFIG_PATH` | `research.py` | `_STATE_DIR / "research_config.json"` | holds `deviceId`, `pairedUid`, **`pollSecret`** |

**There is no `DG_RUNTIME_DIR` knob** — a repo-wide grep for it returns only the standard Linux
`XDG_RUNTIME_DIR` (systemd unit generation, `agent/facade/autostart.py`,
`agent/facade/selfupdate.py`). A word-boundary grep for a standalone `DG_RUNTIME_DIR` returns
nothing. Setting an env var to redirect the keystore **silently does nothing**.

The only redirection the repo supports today is monkeypatching the module attributes — which is
exactly what `dg-research-backend/tests/test_track_d_keystore.py · isolated_home` does, with a
docstring that calls it out ("they're module constants").

### 11.3 The precedent to copy

`dg-research-backend/agent/facade/config.py`:
```python
STORE_SERVICE:  str = "super-agent"
STORE_DIR_NAME: str = ".super-agent"
def store_dir() -> Path: return Path.home() / STORE_DIR_NAME
```
Its comment states the isolation from `"super-research"` is **load-bearing** because the two hold
different Firebase users' tokens and "must never share a slot".

**Requirement for the vendored copy: BOTH the keyring `SERVICE` and the state directory must
differ from `("super-research", ~/.super-research)`.** Changing only one is insufficient. The exact
new names are unconstrained by code — see [UNRESOLVED-08](#unresolved-08).

Recommended shape when vendoring: turn all of §11.2 into a config object or lazy functions
(`store_dir()`-style) rather than module constants, so tests and a second identity do not have to
monkeypatch.

### 11.4 Non-path behaviour worth parameterizing too

- `poll_pending_token` does a bare `print("\n  customToken received — exchanging for refresh
  token...")` on success, and `cmd_pair_v2`'s callbacks use `\r`-overwritten lines plus ANSI
  reverse-video QR output. As a vendored library inside a GUI/agent this is unwanted output on a
  channel you may be parsing. Inject a logger/sink.
- `on_tick(elapsed_seconds)` is invoked once per cycle **before** the GET (so the first call is at
  `elapsed ≈ 0`) and **every exception it raises is swallowed**.
- `cmd_pair_v2 · _on_code` does **not** call `pairing.format_for_display` — it re-implements the
  same f-string inline. "Fixing" the helper does not change what the terminal prints.

---

## 12. DEVICE IDENTITY / WHY A SECOND DEVICE IS REQUIRED

### 12.1 The requirement

The iOS device **must** be its own `deviceId` with its own synthetic Firebase user, its own
`pollSecret`, its own `install_uuid`, and its own keyring service + state directory. It must **not**
ride the Mac's existing `deviceId`, and it must **not** run as a second process against the shared
`~/.super-research`.

### 12.2 Race 1 — the credential-slot collision (the destructive one)

Keystore slots are addressed by `(keyring SERVICE "super-research", f"{slot}:{install_uuid}")`
(`auth/keystore.py · _keyring_account`), and `install_uuid` comes from
`~/.super-research/install_uuid`. A vendored copy left with the stock constants on this Mac reads the
**same** `install_uuid` and therefore the **same keyring account** as the live production daemon.

Consequences, concretely:

1. `RefreshTokenCredentials.bootstrap` does `keystore.set("pending", iuid, refresh_token)` then
   `promote_pending(iuid)` — which sets `previous = old current`, `current = pending`, deletes
   `pending`. **The iOS pair OVERWRITES the production Mac's refresh token.**
2. Any `clear_all(iuid, reason=...)` — from a crash loop, an `--unpair`, or a **mis-detected**
   revoke — **de-authenticates the production device.**
3. `_fresh_user_mode_id_token()` forces a full securetoken round-trip on **every** call and is the
   function that wipes the keystore on a confirmed revoke. It is called by `_pair_patch_device`, so
   **the pair-confirm write itself becomes a potential de-auth trigger** when pointed at a shared
   keystore.

`try_recover` returns the **first non-empty slot** in `RECOVER_ORDER = ("pending","current","previous")`
**without validating it**, so a half-written cross-identity rotation is silently adopted.

### 12.3 Race 2 — the double-claim / dual-run race (if it shared a `deviceId`)

Suppose the iOS process instead shared the Mac's `deviceId` and ran a second queue consumer.

**(a) On a stock `workerCount == 1` install there is NO Firestore claim at all.** The claim + busy-gate
block in `research.py · start_firestore_start_listener` is entered only when
`_resting or _multi_worker_mode or _REST_DEFER_SEEN["v"]`, where
`_multi_worker_mode = load_worker_count() > 1`. So on a stock install every `ADDED` doc is processed
end-to-end with **zero Firestore mutual exclusion**.

**(b) The file-based dual-spawn guard INVERTS into a no-op.**
`research.py · _scan_sibling_locks_for_research(research_id, exclude_worker_id)` **skips any lock
whose `worker_id == exclude_worker_id`**. `WORKER_ID` defaults to `1` from argparse. Two processes
that both default to 1 write the **same** file `<checkout>/queues/.worker.1.lock`
(`research.py · _worker_lock_path` = `Path(__file__).parent / "queues" / f".worker.{worker_id}.lock"`),
clobbering each other's `{research_id, run_id, pid}` — and each one's scan filters the other out
**as itself**. Zero siblings are reported to all three consumers:
- the listener's duplicate-retry defense stops dropping duplicate queue docs;
- `_rehydrate_ongoing_for_tree` auto-resumes a run the other process is actively running (two
  browsers, two FE phase streams, two Doc/Email deliveries);
- the dead-worker reconciler can mark a live run `paused_backend_restart`.

**(c) Even with correct distinct `WORKER_ID`s the guard fails open.** `_scan_sibling_locks_for_research`
returns `[]` when `psutil` is missing, which allows auto-resume.

**(d) `assignedWorker` identifies a SLOT, never a process.** The claim CAS is safe *per doc* but tells
you nothing about which process won: `_owner_worker_of` maps `None`/`""`/`0`/non-numeric to `1`, so
both the legacy default and an imposter resolve to worker 1. Every worker-1-only gate then executes in
**both** processes: the heartbeat, the `currentRun*` publish, the orphan-Chrome sweep, hard_reset
orchestration, version publish, dead-marker reconciliation, and `update`/`check-update`/`restart`
(which use `WORKER_ID != 1 → continue`, so two "worker 1"s both act on a self-update/restart).

**(e) `run_id` collides.** It is minted as
`f"{safe_name(topic)}_{datetime.now().strftime('%Y%m%d_%H%M%S')}"` — one-second resolution, no worker
id, no uuid, no collision check. Two claimants of the same topic inside the same second produce the
**same** `run_id` ⇒ the same `queues/<run_id>` directory ⇒ `setup_firestore_run`'s **non-atomic**
`owner.json` `write_text` clobbers, run artifacts interleave, and a `.stop` sentinel touched for one
run stops the other.

**(f) Command consumption is destructive and first-listener-wins.** Two subscribers on
`users/{uid}/researches/{rid}/commands` means whichever fires first **executes AND deletes** the
Stop/Pause/Resume/Retry doc; the real runner never sees it and the run stays wedged. Same on
`devices/{deviceId}/commands`, where every non-`hard_reset` action is tail-deleted before dispatch.

**(g) Duplicate heartbeat publishers corrupt the ETA and queue math.** Both write
`workerCount` every 5 s — which is **both** the FE capacity gate **and** the parallelism divisor in
`_estimate_queue_eta_ms` (`(position-1) // W`). Both `arrayUnion([1])` into `busyWorkerIds` and
overwrite `workers.1`, so the FE stall detector's `busyWorkerIds.length < workerCount` reads a
fiction. `queueOwners` is a **full-array overwrite**, so two publishers erase each other's entries.

**(h) The busy gate is 100 % process-local** —
`_resting or _QUEUE_STATE.get("running") or job_queue.qsize() > 0 or _pending_enq_read() > 0`.
Process B is idle by its own books while process A is mid-pipeline, so B **never defers**. There is
no shared busy signal anywhere that the gate consults.

**(i) `_fb_seq` is per-process.** Two processes emitting into the same `pipeline_events` collection
interleave, and the FE's `where("seq",">",lastSeq)` **permanently drops** the lagging emitter's events.

**(j) A different checkout shares nothing.** `queues/` is `Path(__file__).parent`-relative, so a
process living in `dg-research-ios` shares **no** lock directory with the BE — there is literally no
file-based coordination, not even the broken kind. Only `~/.super-research/.supervisor.lock`
(`research.py · _acquire_supervisor_lock`, `fcntl.flock`/`msvcrt.locking`) is home-relative, and it
guards **only** `run_daemon_loop` — not `--serve` workers and not any non-`research.py` process. It
also returns `None` (degrade to unlocked) if the lock file cannot be created.

### 12.4 Conclusion

A **distinct `install_uuid` + distinct `SERVICE` + distinct `deviceId`** makes iOS a **separate
device** to Firestore and eliminates every race in §12.2 and §12.3 — at the cost of no shared
`queues/` and no shared worker locks (which is correct: they are separate machines).

Cost of a second identity: one extra `/api/devices/initiate-pair` call, one extra synthetic Auth
user, and a second tile in the owner's Account page. This matches memory note **A10**
("vendor `auth/` for a separate device identity").

**No client-visible way exists to re-initiate against an existing `deviceId`.**
`initiate-pair` keys `_internal/device_secrets/entries/{deviceId}` by `deviceId` and creates a **new**
synthetic Auth user per call, so re-running it strands the previous device doc (24 h TTL) and its
Auth user. The **only** re-entry point is the pending-poll re-pair path, which requires the
**original** `pollSecret`. Guard against accidental re-initiation.

---

## 13. ❓ UNRESOLVED — verify before relying on this

These are genuine gaps. **Do not** substitute a plausible guess.

<a name="unresolved-01"></a>
**UNRESOLVED-01 — Does the DEPLOYED ruleset match these files?**
Cannot be verified read-only from the repo. The `firestore.rules` header itself documents a silent
drift that caused the April 2026 pairing bug, and the 2026-05-28 403 sweep was the same class of
failure. **All five readers flagged this as the single most likely cause of an unexplained iOS 403.**
Verify against the live project before treating any 403 as a client bug.

<a name="unresolved-02"></a>
**UNRESOLVED-02 — Does the TTL policy on `pipeline_events.expireAt` exist?**
`research.py · _emit_to_firestore` writes a 30-day `expireAt` on every event and its docstring says
the policy is "configured manually in the console", but `firestore.indexes.json` has **no**
fieldOverride for `pipeline_events` (verified: the 7 overrides are `researches`, `queue`,
`agentLogins`, `devices`, `pending`, `notify_dedup`, `entries`). The field may be **inert** and the
subcollection may be growing unbounded (~1.5 MB per 90-minute run). Same open question for
`feFifoWaiters`, `notifications`, `sessions` and **both** `commands` subcollections — no TTL is
declared for any of them. Console-only config; confirm before relying on pruning.

<a name="unresolved-03"></a>
**UNRESOLVED-03 — Firestore TTL deletion latency.**
Google documents TTL deletion as happening "within 24 hours" of `expireAt`, **not at** `expireAt`.
Nothing in either repo compensates for that lag. So the real window in which an orphan device doc
physically exists (while being hidden by `isPairConfirmed`) is unbounded up to ~24 h, and a device
that confirms at t = 6 min **may or may not** survive. No code comment acknowledges this. Do not
build logic that depends on prompt deletion — in either direction.

<a name="unresolved-04"></a>
**UNRESOLVED-04 — `authMode` on the device doc.**
It is in the 22-key synth allow-list, but a grep of `research.py` finds `"authMode"` written **only**
into `research_config.json` (`save_user_mode_state`), **never** to Firestore. Purpose on the device
doc is unclear — possibly vestigial. `logins` **is** genuinely written (map\<serviceKey, bool\>,
built from a local `services` tuple), so that one is real.

<a name="unresolved-05"></a>
**UNRESOLVED-05 — Exact shape of `updateStatus`.**
Declared in `dg-research/src/lib/firestore.ts` (as `BackendUpdateStatus`) and written by
`research.py`'s update/heartbeat handlers, but not read end-to-end during this pass. The stated
`{state, current, latest, reason?, at:int}` shape is **second-hand from rules comments**, not verified
field-by-field. Irrelevant to pairing; verify if iOS needs to write it.

<a name="unresolved-06"></a>
**UNRESOLVED-06 — How does the device learn a claim was REJECTED?**
`share_cap_reached` / `revoked_sharer` / `code_expired` / `not_previous_owner` are HTTP errors
returned to the **web claimer**, never to the device. The device only ever observes "the pending doc
never appeared", so it **cannot distinguish** a rejected claim from a human who has not typed the
code yet. There is no device-visible signal. Any iOS UX for this has to be invented, not ported.
(Related and also unverified: whether a **sharer** claim ever writes a pending customToken. Reading
the code says branch 3c performs no pending write at all — but that path was not exercised
end-to-end.)

<a name="unresolved-07"></a>
**UNRESOLVED-07 — Will the Firebase iOS SDK do an UNAUTHENTICATED `getDocument`?**
The BE deliberately uses raw Firestore REST for the pending-doc poll precisely because it has no
auth yet. Whether `Firestore.getDocument` works cleanly with no signed-in user was **not tested**.
If the SDK insists on a signed-in user, mirror the BE and use the REST endpoint for that one read.

<a name="unresolved-08"></a>
**UNRESOLVED-08 — The vendored copy's SERVICE and state-dir names.**
Unconstrained by code. Only the requirement that **both** differ from
`("super-research", ~/.super-research)` is load-bearing. Candidate:
`SERVICE = "super-research-ios"` + `~/.super-research-ios`, mirroring the `super-agent` precedent.
Pick and document it before B1 starts.

<a name="unresolved-09"></a>
**UNRESOLVED-09 — Will iOS/Keychain present a usable `keyring` backend?**
If the vendored Python runs somewhere without a working keyring backend, the file fallback
(`chmod 0600 auth.json`) becomes the only store, and its security posture is filesystem ACLs only.
The repo makes the same tradeoff for headless Linux but logs an INFO about it only in the agent path
(`agent/facade/store.py`), **not** in `auth/keystore.py`.

<a name="unresolved-10"></a>
**UNRESOLVED-10 — The `notifications` device-write branch is unexercised.**
The rules permit the device to create **and** update `users/{uid}/notifications` via
`deviceWritingTo`/`deviceUpdatingFor`, and the rule comments describe BE-side pipeline-complete /
error notifications — but a grep of `research.py` for `collection("notifications")` returns
**nothing**. That branch is **unexercised in production**; an iOS client would be its first user.

<a name="unresolved-11"></a>
**UNRESOLVED-11 — Full `pipeline_events` `type` and `data` inventories.**
`data` is untyped and per-event-type. There are ~286 `emit_event` call sites and **no central
schema**. The rules pin only the four owner-branch types; the **device branch accepts any type**.
The decision-card keys are known (`error`, `details`, `actions[]`, `dismissible`, `alert_id`,
`recoverability`, `auto_skip_deadline`, `decision_id`, `intent`, `quiet`) and `command_ack` carries
(`command_id`, `decision_id`, `ack_action`) — but if iOS must emit a **specific** event type, read
that type's exact `data` keys off its emit site **and** off the matching branch in
`dg-research/src/hooks/usePipeline.ts · processEvent`.

<a name="unresolved-12"></a>
**UNRESOLVED-12 — Depth of the `_fb_seq` off-loop exposure.**
One off-loop producer is **confirmed** by reading the call site (`command_ack`, emitted directly on
the Firestore command-listener thread rather than marshalled through `call_soon_threadsafe`). All
~286 call sites were **not** audited for other thread contexts, so the true collision rate is
unquantified. One confirmed off-loop producer is enough to require the lock in
[TRAP-09](#trap-09--unlocked-read-modify-write-on-the-seq-monotonic-guard).

<a name="unresolved-13"></a>
**UNRESOLVED-13 — Not read in full during this pass.**
Stated here so no one mistakes silence for verification:
`_recompute_deferred_queue_positions_locked` (complete patch key set),
`QUEUE_ETA_PHASE_MS` literals and how `_phase_averages` is populated,
`_rest_keepalive_pass` / `_worker_is_resting` internals,
`_rehydrate_ongoing_for_tree`'s full worker-affinity branching,
`_clear_current_run_id_best_effort`,
and `dg-research/storage.rules`' `deviceAuthorizedFor()` (only `deviceOwns()` was read directly —
and note that `deviceAuthorizedFor` does **not** appear in the current `storage.rules` file at all;
it is referenced only in older prose).

---

## 14. CORRECTIONS TO PRIOR NOTES

Where earlier analysis contradicted the files, **the file wins**. Corrections made while writing this:

1. **`DEVICE_OFFLINE_THRESHOLD_MS` is 30_000, not 15_000.** Verified in
   `dg-research/src/lib/firestore.ts`. Prose in `firestore.ts`, `firestore.rules` and the BE's
   `_heartbeat_loop` docstring all still say 15 s and are **stale**. Any statement that the
   heartbeat "trips the FE's 15 s threshold" is wrong.
2. **The synth device-doc allow-list is exactly 22 keys, not "~25".** Counted directly from
   `dg-research/firestore.rules`. Full list in [§5.2](#52-the-three-coexisting-update-rules).
3. **`ZOMBIE_GRACE_MS` and `ABANDONED_MAX_MS` are function-LOCAL variables** inside
   `research.py · start_firestore_start_listener`'s `on_snapshot`, not module-level constants. The
   values (30_000 / 12 h) are correct.
4. **`SHARER_CAP = 25` is the enforcement; "~28" is the theoretical 1 KB budget.** Both numbers
   appear in the sources and mean different things — `claim/route.ts` caps at 25 deliberately
   ("conservatively"), `storage.rules`' comment estimates ~28.
5. **The rules test's `pendingCustomToken` field name is stale fixture data.** Production writes and
   reads `customToken`. Confirmed both in `claim/route.ts · writePendingCustomToken` and in
   `auth/v2_flow.py · _extract_custom_token`.
6. **The pair-code generator IS modulo-biased and the FE/BE are NOT statistically identical.**
   `initiate-pair/route.ts · generatePairCode` uses `ALPHABET[b % 31]` over random bytes
   (`256 % 31 = 8`, so the first 8 symbols `2-9` are slightly over-represented), while
   `auth/pairing.py · generate_code` uses unbiased `secrets.choice`. The "mirrors
   `auth/pairing.py:generate_code`" comment is true for the **alphabet and length only**. Two
   independent copies of `generatePairCode` exist (initiate-pair and reset-pair-code) and must stay
   in sync. Harmless for iOS — the **device never generates a code** — but do not port the comment
   as if it were a spec.
7. **`_internal/device_secrets/entries/{deviceId}` carries NO `expireAt`** and is therefore never
   TTL'd, even though the `entries` collectionGroup **does** have a TTL policy (shared with
   `_internal/rate_limits/entries/*`, which **do** set `expireAt`). Reset deliberately leaves the
   secret in place so the same pending path is reused; only a full retire (`unpair-self` branch 1)
   removes it.
8. **`emit_event` has 286-ish call sites but `pipeline_events` has exactly ONE producer.** Verified:
   a single `collection("pipeline_events")` reference in `research.py`. The vendored layer needs one
   funnel, not 286.
9. **`auth/` is 4 modules + `__init__`, and `__init__.__all__` excludes `v2_flow`.** Verified by
   `ls auth/` and reading `auth/__init__.py`.
10. **`research_tokens`, `pipeline_requests` and `agentLogins` genuinely have no rule.** Verified by
    grep of `firestore.rules` — the only hits are in comments.
