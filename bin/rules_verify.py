#!/usr/bin/env python3
"""Verify our write shapes against the REAL `firestore.rules`, in the emulator, with no credentials.

This is the closest thing available to *"registers as a normal device against the unchanged Firestore
contract"* without the owner's project — and it is stronger than it might sound, because **the rules
ARE the contract.** A write that the real rules accept is a write the real project accepts; a write
they reject is one that would have failed in production with a 403 naming neither the field nor the
rule.

Why this needs nothing owner-gated: the Firestore emulator evaluates the real rules locally, and it
accepts an unsigned JWT as `request.auth`, so a synthetic-device principal can be impersonated
exactly as the rules see one. No plist, no API key, no network.

⚠ **What this does NOT prove:** that the deployed ruleset matches the repo's file. The contract doc
flags that drift as unverifiable read-only and names it as the historical cause of unexplained 403s.
This verifies our writes against the rules *as committed*, which is the half we can establish.

The negative cases matter more than the positive ones. `hasOnly()` is all-or-nothing across three
ORed rules, so the assertion that really protects us is that a write with **one extra field** is
rejected — an accept-only test would pass for a rule that permits everything.

Usage: bin/rules_verify.py   (expects the emulator already running on :8181)
"""

from __future__ import annotations

import base64
import hashlib
import json
import sys
import time
import urllib.error
import urllib.request
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(REPO))

from emubackend.contract import events as events_mod  # noqa: E402
from emubackend.contract import values  # noqa: E402

HOST = "http://127.0.0.1:8181"
PROJECT = "demo-sr"
BASE = f"{HOST}/v1/projects/{PROJECT}/databases/(default)/documents"

DEVICE_ID = "dev-rules-check"
OWNER_UID = "owner-uid-1"
SYNTH_UID = "synth-uid-1"
RESEARCH_ID = "rid-1"


def _b64(obj: dict) -> str:
    return base64.urlsafe_b64encode(json.dumps(obj).encode()).decode().rstrip("=")


def token_for(uid: str, claims: dict | None = None) -> str:
    """An unsigned JWT the emulator accepts as `request.auth`.

    The emulator does not verify the signature, which is what makes rules testing possible without
    any real credential. `sub`/`user_id` become `request.auth.uid`; anything else lands in
    `request.auth.token`.
    """
    payload = {
        "iss": f"https://securetoken.google.com/{PROJECT}",
        "aud": PROJECT,
        "sub": uid,
        "user_id": uid,
        "iat": int(time.time()),
        "exp": int(time.time()) + 3600,
        **(claims or {}),
    }
    return f"{_b64({'alg': 'none', 'typ': 'JWT'})}.{_b64(payload)}."


#: Sentinel meaning "send NO Authorization header". A plain "" is falsy and previously fell through
#: to the admin bypass, so a test intended to prove an *unauthenticated* read passed for entirely the
#: wrong reason — and the list-denied test failed for the same reason. Explicit sentinel, no falsy
#: coincidences.
NO_AUTH = object()


def request(method: str, path: str, *, body=None, token=None, query: str = ""):
    url = f"{BASE}/{path.strip('/')}" + (f"?{query}" if query else "")
    data = json.dumps(body).encode() if body is not None else None
    req = urllib.request.Request(url, data=data, method=method)
    req.add_header("Content-Type", "application/json")
    if token is not NO_AUTH:
        # "owner" is the emulator's admin bearer — it BYPASSES rules. Used only to seed state the
        # server would have created, never to prove a device-side write is permitted.
        req.add_header("Authorization", f"Bearer {token if token else 'owner'}")
    try:
        with urllib.request.urlopen(req, timeout=15) as resp:
            return resp.status, json.loads(resp.read().decode() or "{}")
    except urllib.error.HTTPError as exc:
        return exc.code, json.loads(exc.read().decode() or "{}")


def seed_device() -> None:
    """Create the device doc as the SERVER would, via the admin bypass.

    Legitimate: `/api/devices/initiate-pair` plus the claim route create this document with the
    Admin SDK, and client creation is `allow create: if false`. Seeding it here reproduces the
    server's half so the device-side writes can be tested against the rules.
    """
    fields = values.encode_fields(
        {
            "ownerUid": OWNER_UID,
            "syntheticDeviceUid": SYNTH_UID,
            "pairCode": "JPNTY4F9",
            "sharedWith": [],
            "status": "pending",
        }
    )
    request("PATCH", f"devices/{DEVICE_ID}", body={"fields": fields},
            query="&".join(f"updateMask.fieldPaths={k}" for k in
                           ["ownerUid", "syntheticDeviceUid", "pairCode", "sharedWith", "status"]))
    request("PATCH", f"users/{OWNER_UID}/researches/{RESEARCH_ID}",
            body={"fields": values.encode_fields({"status": "ongoing", "ownerUid": OWNER_UID})},
            query="updateMask.fieldPaths=status&updateMask.fieldPaths=ownerUid")


def patch_as(uid: str, path: str, fields: dict, delete: list[str] | None = None, claims=None):
    mask = values.update_mask_for(fields, delete)
    return request(
        "PATCH",
        path,
        body={"fields": values.encode_fields(fields)},
        token=token_for(uid, claims),
        query="&".join(f"updateMask.fieldPaths={p}" for p in mask),
    )


#: ⚠ The ONLY custom claim the rules read — 15 times — is `deviceId`. Without it, `deviceWritingTo`
#: and `deviceMemberOf` both fail and EVERY user-tree write from the device is denied. It is minted
#: into the custom token by the claim route, so the token provider must carry it through.
SYNTH_CLAIMS = {"deviceId": DEVICE_ID}


def create_as(uid: str, collection: str, fields: dict, claims=None):
    return request(
        "POST", collection, body={"fields": values.encode_fields(fields)},
        token=token_for(uid, claims if claims is not None else SYNTH_CLAIMS),
    )


def main() -> int:
    results: list[dict] = []

    def check(name: str, ok: bool, detail: str) -> None:
        results.append({"check": name, "pass": ok, "detail": detail})
        print(f"  [{'PASS' if ok else 'FAIL'}] {name}: {detail}")

    # The vendored rules must match the frontend's, or this proves nothing about production.
    for name in ("firestore.rules", "firestore.indexes.json"):
        vend = REPO / "fixtures" / "rules" / name
        recorded = (REPO / "fixtures" / "rules" / f"{name}.sha256").read_text().strip()
        upstream = (REPO.parent / "dg-research" / name).read_bytes()
        actual = hashlib.sha256(upstream).hexdigest()
        check(
            f"vendored {name} matches the frontend",
            actual == recorded and vend.exists(),
            f"sha256 {actual[:16]}… — re-vendor if this fails, or the test proves nothing",
        )

    seed_device()

    # ---- the atomic pair-confirm, exactly as PairingCoordinator issues it -------------
    beat = {
        "lastHeartbeat": int(time.time() * 1000),
        "status": "active",
        "pairConfirmedAt": True,
    }
    # Note the asymmetry, which is easy to get wrong: the DEVICE-DOC rule pins on
    # `resource.data.syntheticDeviceUid == request.auth.uid` and needs NO claim, while the USER-TREE
    # rules need `auth.token.deviceId`. Two different mechanisms guarding two different paths.
    status, body = patch_as(SYNTH_UID, f"devices/{DEVICE_ID}", beat, delete=["expireAt"])
    check(
        "THE ATOMIC PAIR-CONFIRM IS ACCEPTED BY THE REAL RULES",
        status == 200,
        f"HTTP {status} — pairConfirmedAt + status + lastHeartbeat set, expireAt deleted",
    )

    # ---- and the negative case that actually protects us ------------------------------
    status, _ = patch_as(SYNTH_UID, f"devices/{DEVICE_ID}", {**beat, "name": "hijacked"})
    check(
        "one extra field REJECTS the whole write (hasOnly is all-or-nothing)",
        status == 403,
        f"HTTP {status} — 'name' is owner-only, so mixing lists satisfies NEITHER rule",
    )

    status, _ = patch_as(SYNTH_UID, f"devices/{DEVICE_ID}", {"ownerUid": "attacker"})
    check(
        "a device cannot transfer ownership",
        status == 403,
        f"HTTP {status} — ownerUid is outside the synth allow-list",
    )

    status, _ = patch_as(SYNTH_UID, f"devices/{DEVICE_ID}", {"pairCode": "AAAA2345"})
    check(
        "a device cannot rotate its own pair code",
        status == 403,
        f"HTTP {status} — pairCode is admin-only (Reset goes through a Cloud Function)",
    )

    status, _ = patch_as("some-other-uid", f"devices/{DEVICE_ID}", beat, delete=["expireAt"])
    check(
        "an unrelated principal cannot heartbeat the device",
        status == 403,
        f"HTTP {status} — the rule pins request.auth.uid to syntheticDeviceUid",
    )

    # ---- pipeline_events, built by our real writer ------------------------------------
    built = events_mod.build_event(
        event_type="phase_start", device_id=DEVICE_ID, seq=int(time.time() * 1000), phase=0
    )
    doc = dict(built.document)
    doc["expireAt"] = values.timestamp_value(doc["expireAt"])["timestampValue"]
    status, _ = create_as(
        SYNTH_UID, f"users/{OWNER_UID}/researches/{RESEARCH_ID}/pipeline_events", doc
    )
    check(
        "a pipeline_event from our real writer is ACCEPTED",
        status == 200,
        f"HTTP {status} — int seq/timestamp, top-level deviceId, phase 0 present",
    )

    # seq as a string is the encoding trap: rules require `is number`.
    bad = dict(doc)
    bad["seq"] = str(bad["seq"])
    status, _ = create_as(
        SYNTH_UID, f"users/{OWNER_UID}/researches/{RESEARCH_ID}/pipeline_events", bad
    )
    check(
        "a STRING seq is REJECTED (the encoding trap, proven)",
        status == 403,
        f"HTTP {status} — integerValue passes `is number`, stringValue does not",
    )

    # deviceId nested in data instead of top level.
    nested = {k: v for k, v in doc.items() if k != "deviceId"}
    nested["data"] = {"deviceId": DEVICE_ID}
    status, _ = create_as(
        SYNTH_UID, f"users/{OWNER_UID}/researches/{RESEARCH_ID}/pipeline_events", nested
    )
    check(
        "deviceId nested inside data is REJECTED",
        status == 403,
        f"HTTP {status} — the device branch reads the TOP-LEVEL field",
    )

    status, _ = create_as(
        SYNTH_UID, f"users/{OWNER_UID}/researches/{RESEARCH_ID}/pipeline_events", doc, claims={}
    )
    check(
        "WITHOUT the deviceId claim the same event is REJECTED",
        status == 403,
        f"HTTP {status} — deviceWritingTo() requires auth.token.deviceId; this is the dependency "
        f"that would have failed at the first real queue-triggered run",
    )

    status, _ = create_as(
        SYNTH_UID,
        f"users/{OWNER_UID}/researches/{RESEARCH_ID}/pipeline_events",
        doc,
        claims={"deviceId": "some-other-device"},
    )
    check(
        "a MISMATCHED deviceId claim is REJECTED",
        status == 403,
        f"HTTP {status} — the payload's deviceId must equal the claim, so a device cannot write "
        f"events attributed to another",
    )

    # ---- the pre-auth pending read ----------------------------------------------------
    request(
        "PATCH",
        f"devices/{DEVICE_ID}/pending/{'a' * 64}",
        body={"fields": values.encode_fields({"customToken": "tok"})},
        query="updateMask.fieldPaths=customToken",
    )
    status, body = request("GET", f"devices/{DEVICE_ID}/pending/{'a' * 64}", token=NO_AUTH)
    check(
        "the pending doc is readable WITHOUT auth (allow get: if true)",
        status == 200 and "fields" in body,
        f"HTTP {status} — this is what makes the pre-auth poll legal",
    )

    status, _ = request("GET", f"devices/{DEVICE_ID}/pending", token=NO_AUTH)
    check(
        "the pending subcollection cannot be LISTED",
        status in (403, 400),
        f"HTTP {status} — allow list: if false, so the secret cannot be brute-forced by enumeration",
    )

    decided = [r for r in results if r["pass"] is not None]
    verdict = {
        "gate": "rules-verify",
        "note": (
            "Our write shapes evaluated against the REAL firestore.rules in the emulator. Does NOT "
            "prove the DEPLOYED ruleset matches the repo file — that drift is unverifiable "
            "read-only and is the documented cause of unexplained 403s."
        ),
        "results": results,
        "pass": all(r["pass"] for r in decided),
    }
    out = REPO / "artifacts" / "rules"
    out.mkdir(parents=True, exist_ok=True)
    (out / "verdict.json").write_text(json.dumps(verdict, indent=2) + "\n")
    print(f"\nrules verification: {'PASS' if verdict['pass'] else 'FAIL'} -> {out / 'verdict.json'}")
    return 0 if verdict["pass"] else 1


if __name__ == "__main__":
    sys.exit(main())
