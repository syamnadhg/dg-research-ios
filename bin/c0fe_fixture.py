#!/usr/bin/env python3
"""Stand in for the frontend's server side, so the C0-FE pairing gate can run with no credentials.

**What this is and is not.** The device half of pairing is the part under test — and it is the part
`dg-research-ios` owns. The *server* half is the frontend's: `/api/devices/initiate-pair` mints the
pair code and creates the device document, and the web app's claim writes the custom token. Neither is
reachable without the owner's project, so both are played here, against the emulator.

That is a fair substitution for exactly one reason: **the rules are the contract.** This fixture writes
as an admin principal, which the real server also is, and every write the *device* makes then goes
through the real `firestore.rules`. So what the gate proves is what matters — that the device's writes
are accepted, that its one forbidden write is rejected, and that the sequence completes inside the
five-minute confirm window.

⚠ **What it does not prove:** that the deployed ruleset matches this repo's file, or that the real
frontend route behaves exactly like this. Both stay owner-gated, and the gate's verdict says so.

The claim is deliberately delayed rather than pre-written: pre-writing it would let a device that never
polls pass the gate, and polling-then-claiming is the real sequence.
"""

from __future__ import annotations

import base64
import json
import sys
import threading
import time
import urllib.request
from http.server import BaseHTTPRequestHandler, HTTPServer
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(REPO))

from emubackend.contract import values  # noqa: E402

FIRESTORE = "http://127.0.0.1:8181"
PROJECT = "demo-sr"
BASE = f"{FIRESTORE}/v1/projects/{PROJECT}/databases/(default)/documents"

OWNER_UID = "owner-uid-c0fe"
SYNTH_UID = "synth-uid-c0fe"
#: Seconds between the device registering and the "human" claiming the code. Long enough that the
#: device must genuinely poll, short enough to keep the gate quick.
CLAIM_DELAY = 2.0

PORT = 8907


def _b64(obj: dict) -> str:
    return base64.urlsafe_b64encode(json.dumps(obj).encode()).decode().rstrip("=")


#: The emulator's **admin bearer**, which BYPASSES security rules.
#:
#: This is what the frontend's server side actually is: the Admin SDK, which is not subject to rules at
#: all. An unsigned JWT is *not* equivalent — it is still a rules-evaluated principal, and the first
#: attempt at this fixture used one and was rejected 403 creating the device document. Correctly so:
#: `allow create: if false` means **no client**, however authenticated, may create it.
#:
#: Used ONLY to seed the server-side state. Every write under test — every write the device makes — goes
#: through the normal path and is evaluated by the real rules.
ADMIN_BEARER = "owner"


def custom_token(uid: str, device_id: str) -> str:
    """A custom token for the device, carrying the `deviceId` claim.

    ⚠ **The claim is the point.** `deviceId` is the only custom claim the rules read, and they read it
    fifteen times — every write into the user tree depends on it. A token without it authenticates fine
    and then 403s on the first real write, with a message that mentions neither claims nor the field.
    The Auth emulator propagates custom claims into the ID token, so this is genuinely exercised rather
    than assumed.

    ⚠ The emulator skips the **signature** check but still validates the **envelope**: `aud` must be the
    IdentityToolkit audience and `iss`/`sub` a service-account identity. A bare `{"uid", "claims"}`
    payload — which is all the Admin SDK's own API asks you for — is rejected with
    `INVALID_CUSTOM_TOKEN: Invalid aud (audience): undefined`, because the SDK is what normally adds the
    envelope. Found by running it.
    """
    service_account = f"firebase-adminsdk@{PROJECT}.iam.gserviceaccount.com"
    now = int(time.time())
    header = _b64({"alg": "none", "typ": "JWT"})
    payload = _b64(
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
            "claims": {"deviceId": device_id},
        }
    )
    return f"{header}.{payload}."


def firestore_patch(path: str, fields: dict, delete: list[str] | None = None) -> int:
    mask = "&".join(
        f"updateMask.fieldPaths={key}" for key in list(fields) + list(delete or [])
    )
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


def create_device(device_id: str, pair_code: str, secret_hash: str) -> None:
    """What `/api/devices/initiate-pair` does server-side.

    ⚠ The device cannot do this itself — `allow create: if false` on the device document. An earlier
    draft of the C0-FE spec had the device generating its own pair code, which the rules would have
    rejected outright.
    """
    firestore_patch(
        f"devices/{device_id}",
        {
            "ownerUid": OWNER_UID,
            "syntheticDeviceUid": SYNTH_UID,
            "pairCode": pair_code,
            "status": "pending",
            "sharedWith": [],
            "secretHash": secret_hash,
        },
    )


def claim(device_id: str, secret_hash: str) -> None:
    """What the web app's claim does: arm the TTL and drop the custom token where the device can get it.

    ⚠ `expireAt` is the live grenade. It arms a TTL five minutes out, and only the device's
    pair-confirm removes it. If the confirm is late, the document is deleted and pairing appears to
    have succeeded before silently vanishing — which is why the gate asserts the confirm lands and
    that `expireAt` is gone afterwards.
    """
    firestore_patch(
        f"devices/{device_id}",
        {"expireAt": {"timestampValue": _iso(time.time() + 300)}, "status": "claimed"},
    )
    firestore_patch(
        f"devices/{device_id}/pending/{secret_hash}",
        {"customToken": custom_token(SYNTH_UID, device_id)},
    )


def _iso(epoch: float) -> str:
    return time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime(epoch))


class Handler(BaseHTTPRequestHandler):
    """Serves only `/api/devices/initiate-pair`. Anything else is a 404 on purpose."""

    def do_POST(self) -> None:  # noqa: N802 - BaseHTTPRequestHandler's name
        if self.path != "/api/devices/initiate-pair":
            self.send_error(404)
            return
        length = int(self.headers.get("Content-Length", "0"))
        body = json.loads(self.rfile.read(length) or "{}")
        # ⚠ `pollSecretHash` — the field name the REAL route uses
        # (`dg-research-backend/auth/v2_flow.py::initiate_pair_remote`). This fixture read
        # `secretHash` until the device was corrected to match production, at which point the gate
        # failed 0/4 — correctly. A fixture that accepts a field the real server does not is worse
        # than no fixture: it makes the gate green precisely when the app cannot pair.
        secret_hash = body.get("pollSecretHash", "")
        if not secret_hash:
            self.send_error(400, "pollSecretHash is required")
            return

        device_id = f"dev-c0fe-{int(time.time())}"
        pair_code = "JPNTY4F9"
        create_device(device_id, pair_code, secret_hash)

        # The claim happens on a timer, off-thread, so the device has to actually poll for it.
        threading.Timer(CLAIM_DELAY, claim, args=(device_id, secret_hash)).start()

        payload = json.dumps({"deviceId": device_id, "pairCode": pair_code}).encode()
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(payload)))
        self.end_headers()
        self.wfile.write(payload)

    def log_message(self, *args: object) -> None:
        pass  # quiet; the gate script owns the output


if __name__ == "__main__":
    server = HTTPServer(("127.0.0.1", PORT), Handler)
    print(f"c0fe fixture on http://127.0.0.1:{PORT} (claim delay {CLAIM_DELAY}s)", flush=True)
    server.serve_forever()
