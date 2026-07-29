#!/usr/bin/env python3
"""Seed the research document and mint the device's custom token — the server's half.

⚠ Uses the emulator's `Bearer owner` **admin bypass**, because that is what the real server is: the
Admin SDK, not subject to rules. An unsigned JWT is still a rules-evaluated principal and would be
rejected creating documents the rules forbid clients to create — the C0-FE fixture learned that the
hard way.

Everything the *device* then writes goes through the normal path and is judged by the real rules.
"""

from __future__ import annotations

import base64
import json
import sys
import time
import urllib.request
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(REPO))

from emubackend.contract import values  # noqa: E402

BASE = "http://127.0.0.1:8181/v1/projects/demo-sr/databases/(default)/documents"
ADMIN_BEARER = "owner"


def _b64(obj: dict) -> str:
    return base64.urlsafe_b64encode(json.dumps(obj).encode()).decode().rstrip("=")


def custom_token(uid: str, device_id: str) -> str:
    """⚠ The emulator skips the signature but validates the ENVELOPE: `aud` must be the

    IdentityToolkit audience and `iss`/`sub` a service-account identity. A bare {uid, claims} payload
    — all the Admin SDK asks for, since the SDK adds the envelope — fails INVALID_CUSTOM_TOKEN.
    """
    service_account = "firebase-adminsdk@demo-sr.iam.gserviceaccount.com"
    now = int(time.time())
    return ".".join(
        [
            _b64({"alg": "none", "typ": "JWT"}),
            _b64(
                {
                    "iss": service_account,
                    "sub": service_account,
                    "aud": (
                        "https://identitytoolkit.googleapis.com/"
                        "google.identity.identitytoolkit.v1.IdentityToolkit"
                    ),
                    "iat": now,
                    "exp": now + 3600,
                    "uid": uid,
                    # The only custom claim the rules read — and they read it fifteen times.
                    "claims": {"deviceId": device_id},
                }
            ),
            "",
        ]
    )


def patch(path: str, fields: dict) -> int:
    mask = "&".join(f"updateMask.fieldPaths={key}" for key in fields)
    request = urllib.request.Request(
        f"{BASE}/{path}?{mask}",
        method="PATCH",
        data=json.dumps({"fields": values.encode_fields(fields)}).encode(),
        headers={
            "Content-Type": "application/json",
            "Authorization": f"Bearer {ADMIN_BEARER}",
        },
    )
    with urllib.request.urlopen(request) as response:
        return response.status


def assert_clean(uid: str, research_id: str) -> None:
    """Fail loudly if events already exist.

    A leftover emulator from a previous invocation reads as an emitter writing too much — which is how
    "17 events, expected 9" got diagnosed as a fault in the app rather than in the harness. A
    precondition turns that into one clear line.
    """
    request = urllib.request.Request(
        f"{BASE}/users/{uid}/researches/{research_id}/pipeline_events",
        headers={"Authorization": f"Bearer {ADMIN_BEARER}"},
    )
    try:
        with urllib.request.urlopen(request) as response:
            existing = json.load(response).get("documents", [])
    except Exception:
        existing = []
    if existing:
        raise SystemExit(
            f"the emulator already holds {len(existing)} pipeline_events for {research_id} — it was "
            f"not started clean, so any count this gate reports would be meaningless"
        )


if __name__ == "__main__":
    uid, research_id, device_id = sys.argv[1], sys.argv[2], sys.argv[3]
    assert_clean(uid, research_id)
    patch(
        f"users/{uid}/researches/{research_id}",
        {
            "status": "queued",
            "ownerUid": uid,
            "assignedDeviceId": device_id,
            "topic": "quantum error correction, 2026 review",
            # Present so the run's opening write has something real to DELETE. A gate that seeds no
            # pendingDecision cannot tell a working delete from a no-op.
            "pendingDecision": "retry",
        },
    )
    # The device document, so the rules' device branch has an owner to match against.
    patch(
        f"devices/{device_id}",
        {"ownerUid": uid, "syntheticDeviceUid": uid, "status": "active", "sharedWith": []},
    )
    print(json.dumps({"customToken": custom_token(uid, device_id)}))
