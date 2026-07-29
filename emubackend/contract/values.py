"""Firestore REST value encoding — where the wire type decides whether a rule passes.

Evidence: ``dg-research-backend/agent/facade/firestore_rest.py · to_value / update_research``,
via ``docs/FIRESTORE_CONTRACT.md`` §8.

Three encoding facts are load-bearing, and each fails as a **permission denial** rather than a
type error, which is what makes them expensive to diagnose:

1. **A Python ``int`` must encode as ``integerValue``.** Firestore rules evaluate
   ``integerValue`` as a *number*, so ``seq is number`` and ``timestamp is number`` pass. The same
   value as ``stringValue`` is **denied** — and the denial says "Missing or insufficient
   permissions", pointing at the rules rather than at the encoder.
2. **``datetime`` has no automatic encoding.** Upstream ``to_value()`` raises ``TypeError`` on
   one, deliberately, so ``expireAt`` has to be hand-encoded as ``timestampValue``. Silently
   coercing it here would paper over the one place the upstream design wants a decision.
3. **There is no ``DELETE_FIELD`` over REST.** A field delete is "name it in
   ``updateMask.fieldPaths`` and omit it from the body". Sending ``null`` instead sets the field
   to null, and the frontend distinguishes *absent* from *present-but-null* — so a null write
   looks like a successful clear and leaves a live value behind.
"""

from __future__ import annotations

from datetime import datetime, timezone
from typing import Any

__all__ = [
    "ValueEncodingError",
    "encode_fields",
    "timestamp_value",
    "to_value",
    "update_mask_for",
]


class ValueEncodingError(TypeError):
    """A value cannot be encoded for the Firestore REST API."""


def to_value(value: Any) -> dict:
    """Encode one Python value as a Firestore REST ``Value``.

    ``bool`` is checked before ``int`` because ``bool`` *is* an ``int`` in Python, and encoding
    ``True`` as ``integerValue: "1"`` would silently change the stored type.
    """
    if value is None:
        return {"nullValue": None}
    if isinstance(value, bool):
        return {"booleanValue": value}
    if isinstance(value, int):
        # integerValue is a STRING on the wire but still evaluates as a number in rules.
        return {"integerValue": str(value)}
    if isinstance(value, float):
        return {"doubleValue": value}
    if isinstance(value, str):
        return {"stringValue": value}
    if isinstance(value, datetime):
        raise ValueEncodingError(
            "datetime has no implicit encoding — use timestamp_value(dt) explicitly. Upstream "
            "to_value() raises here too; coercing silently would hide the one field (expireAt) "
            "whose encoding is a deliberate decision."
        )
    if isinstance(value, dict):
        return {"mapValue": {"fields": {k: to_value(v) for k, v in value.items()}}}
    if isinstance(value, (list, tuple)):
        return {"arrayValue": {"values": [to_value(v) for v in value]}}
    raise ValueEncodingError(f"no Firestore REST encoding for {type(value).__name__}")


def timestamp_value(dt: datetime) -> dict:
    """Encode a **timezone-aware** datetime as ``timestampValue``.

    Naive datetimes are refused rather than assumed to be UTC. A naive value read as local time
    shifts ``expireAt`` by the UTC offset, which for a TTL means the document expires hours early
    or late — and a device doc that expires early is deleted outright with no recovery path.
    """
    if dt.tzinfo is None:
        raise ValueEncodingError(
            "refusing a naive datetime: assuming UTC would shift a TTL by the local offset, and "
            "an expireAt that fires early deletes the document with no way back. Pass "
            "datetime.now(timezone.utc)."
        )
    iso = dt.astimezone(timezone.utc).isoformat().replace("+00:00", "Z")
    return {"timestampValue": iso}


def encode_fields(doc: dict[str, Any]) -> dict[str, dict]:
    """Encode a whole document body's ``fields`` map."""
    return {k: to_value(v) for k, v in doc.items()}


def update_mask_for(
    present: dict[str, Any], delete_paths: list[str] | None = None
) -> list[str]:
    """Build ``updateMask.fieldPaths`` for a patch.

    Deleted fields are listed here **and omitted from the body** — that pairing *is* the delete
    operation over REST. Returned as one list so the two halves cannot drift apart at the call
    site, which is how a "clear" ends up writing a null.
    """
    paths = list(present.keys())
    for path in delete_paths or []:
        if path in present:
            raise ValueEncodingError(
                f"{path!r} is in both the body and the delete list — a field cannot be set and "
                f"deleted in the same patch, and Firestore would apply the set"
            )
        paths.append(path)
    return paths
