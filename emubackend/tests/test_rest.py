"""Tests for the Firestore REST transport, with no network.

The transport is injectable precisely so these can assert on the *requests that would be sent* —
which is where the traps live. Every test here names the production failure it prevents.
"""

from __future__ import annotations

from datetime import datetime, timezone
from urllib.parse import parse_qsl, urlsplit

import pytest

from emubackend.contract import events, rest, values


class FakeResponse:
    def __init__(self, status_code=200, payload=None, text=""):
        self.status_code = status_code
        self._payload = payload if payload is not None else {}
        self.text = text
        self.content = b"x"

    @property
    def ok(self):
        return 200 <= self.status_code < 300

    def json(self):
        return self._payload


class FakeTransport:
    """Records every request and replies from a scripted queue."""

    def __init__(self, replies=None):
        self.calls: list[dict] = []
        self.replies = list(replies or [])

    def __call__(self, method, url, headers=None, json=None, timeout=None):
        self.calls.append(
            {"method": method, "url": url, "headers": headers or {}, "json": json}
        )
        return self.replies.pop(0) if self.replies else FakeResponse()

    @property
    def tokens(self):
        return [c["headers"].get("Authorization") for c in self.calls]


class TokenProvider:
    """Mimics upstream's `token_provider(force: bool = False)` contract."""

    def __init__(self):
        self.mints = 0
        self.forced = 0

    def __call__(self, force: bool = False):
        if force:
            self.forced += 1
            self.mints += 1
            return f"fresh-{self.mints}"
        return "cached"


def _client(replies=None):
    tp = TokenProvider()
    tr = FakeTransport(replies)
    return (
        rest.FirestoreRest(tp, "super-research-492814", transport=tr),
        tp,
        tr,
    )


# ======================================================================================
# the credential retry
# ======================================================================================


@pytest.mark.parametrize("code", [401, 403])
def test_an_auth_failure_retries_once_with_a_FORCE_REFRESHED_token(code):
    """Re-sending the cached token would fail again — the force=True IS the mechanism.

    403 is included because a stale credential surfaces as PermissionDenied on the gRPC path,
    and over REST there is no client._credentials to force-refresh, so that heal lives here.
    """
    client, tp, tr = _client([FakeResponse(code), FakeResponse(200, {"ok": 1})])
    assert client.request("GET", "https://x/documents/a") == {"ok": 1}
    assert tp.forced == 1
    assert tr.tokens == ["Bearer cached", "Bearer fresh-1"]


def test_the_auth_retry_happens_at_most_once():
    """A genuine rules denial must not become an infinite retry loop."""
    client, tp, tr = _client([FakeResponse(403), FakeResponse(403, text="denied")])
    with pytest.raises(rest.FirestoreError, match="403"):
        client.request("GET", "https://x/documents/a")
    assert len(tr.calls) == 2
    assert tp.forced == 1


def test_a_successful_request_never_forces_a_refresh():
    client, tp, tr = _client([FakeResponse(200, {"ok": 1})])
    client.request("GET", "https://x/documents/a")
    assert tp.forced == 0
    assert tr.tokens == ["Bearer cached"]


def test_a_non_auth_error_is_raised_without_a_retry():
    client, tp, tr = _client([FakeResponse(500, text="boom")])
    with pytest.raises(rest.FirestoreError, match="500"):
        client.request("GET", "https://x/documents/a")
    assert len(tr.calls) == 1


def test_allow_missing_turns_a_404_into_none():
    client, _, _ = _client([FakeResponse(404)])
    assert client.request("GET", "https://x/documents/a", allow_missing=True) is None


def test_a_404_without_allow_missing_still_raises():
    client, _, _ = _client([FakeResponse(404, text="nope")])
    with pytest.raises(rest.FirestoreError, match="404"):
        client.request("GET", "https://x/documents/a")


def test_the_error_message_names_the_path_not_the_whole_url():
    client, _, _ = _client([FakeResponse(500, text="boom")])
    with pytest.raises(rest.FirestoreError) as exc:
        client.request("GET", rest.document_url("p", "users/u/researches/r"))
    assert "/users/u/researches/r" in str(exc.value)
    assert "firestore.googleapis.com" not in str(exc.value)


# ======================================================================================
# field deletion — updateMask without the body
# ======================================================================================


def test_a_deleted_field_is_in_the_mask_and_absent_from_the_body():
    """Sending null instead sets the field to null, which the frontend reads as PRESENT.

    So a "clear" implemented with null reports success and leaves the value live — the exact
    shape of the atomic pair-confirm failing while appearing to work.
    """
    client, _, tr = _client([FakeResponse(200, {})])
    client.patch(
        "devices/dev-1",
        {"pairConfirmedAt": True, "lastHeartbeat": 1785319607000, "status": "active"},
        delete_paths=["expireAt"],
    )
    call = tr.calls[0]
    assert call["method"] == "PATCH"
    mask = [v for k, v in parse_qsl(urlsplit(call["url"]).query) if k == "updateMask.fieldPaths"]
    assert set(mask) == {"pairConfirmedAt", "lastHeartbeat", "status", "expireAt"}
    assert "expireAt" not in call["json"]["fields"]


def test_the_pair_confirm_patch_encodes_its_types_the_way_the_rules_require():
    """pairConfirmedAt is boolean true; lastHeartbeat is an int millis, not a Timestamp."""
    client, _, tr = _client([FakeResponse(200, {})])
    client.patch(
        "devices/dev-1",
        {"pairConfirmedAt": True, "lastHeartbeat": 1785319607000, "status": "active"},
        delete_paths=["expireAt"],
    )
    fields = tr.calls[0]["json"]["fields"]
    assert fields["pairConfirmedAt"] == {"booleanValue": True}
    assert fields["lastHeartbeat"] == {"integerValue": "1785319607000"}
    assert fields["status"] == {"stringValue": "active"}


def test_patch_refuses_a_field_that_is_both_set_and_deleted():
    client, _, tr = _client([FakeResponse(200, {})])
    with pytest.raises(values.ValueEncodingError):
        client.patch("devices/d", {"expireAt": 1}, delete_paths=["expireAt"])
    assert tr.calls == [], "nothing should have been sent"


# ======================================================================================
# no cross-field OR
# ======================================================================================


def _device_doc(did, owner="u1", shared=None):
    return {
        "document": {
            "name": f"projects/p/databases/(default)/documents/devices/{did}",
            "fields": {
                "ownerUid": {"stringValue": owner},
                "sharedWith": {
                    "arrayValue": {"values": [{"stringValue": s} for s in (shared or [])]}
                },
            },
        }
    }


def test_list_devices_issues_two_queries_and_unions_them():
    """Firestore REST has no cross-field OR. One query silently truncates the list."""
    client, _, tr = _client(
        [
            FakeResponse(200, [_device_doc("owned")]),
            FakeResponse(200, [_device_doc("shared", owner="other", shared=["u1"])]),
        ]
    )
    devices = client.list_devices("u1")
    assert len(tr.calls) == 2
    fields = [
        c["json"]["structuredQuery"]["where"]["fieldFilter"]["field"]["fieldPath"]
        for c in tr.calls
    ]
    ops = [c["json"]["structuredQuery"]["where"]["fieldFilter"]["op"] for c in tr.calls]
    assert fields == ["ownerUid", "sharedWith"]
    assert ops == ["EQUAL", "ARRAY_CONTAINS"]
    assert {d["id"] for d in devices} == {"owned", "shared"}


def test_list_devices_deduplicates_a_device_matching_both_queries():
    client, _, _ = _client(
        [
            FakeResponse(200, [_device_doc("d1")]),
            FakeResponse(200, [_device_doc("d1")]),
        ]
    )
    assert [d["id"] for d in client.list_devices("u1")] == ["d1"]


def test_run_query_tolerates_readtime_only_rows():
    """runQuery interleaves rows without a `document` key; treating them as docs crashes."""
    client, _, _ = _client([FakeResponse(200, [{"readTime": "2026-01-01T00:00:00Z"}, _device_doc("d")])])
    assert [d["id"] for d in client.run_query("", {"from": [{"collectionId": "devices"}]})] == ["d"]


# ======================================================================================
# auto-id creation and decoding
# ======================================================================================


def test_create_with_auto_id_posts_to_the_collection():
    """pipeline_events uses .add() — an auto id, not a deterministic key."""
    client, _, tr = _client([FakeResponse(200, {})])
    built = events.build_event(
        event_type="phase_start",
        device_id="dev-1",
        seq=1785319607000,
        phase=0,
        now=datetime(2026, 7, 29, 12, 0, tzinfo=timezone.utc),
    )
    doc = dict(built.document)
    doc["expireAt"] = values.timestamp_value(doc["expireAt"])["timestampValue"]
    client.create_with_auto_id("users/u1/researches/r1/pipeline_events", doc)
    call = tr.calls[0]
    assert call["method"] == "POST"
    assert call["url"].endswith("/users/u1/researches/r1/pipeline_events")
    fields = call["json"]["fields"]
    assert fields["seq"] == {"integerValue": "1785319607000"}
    assert fields["phase"] == {"integerValue": "0"}, "phase 0 must survive to the wire"
    assert fields["deviceId"] == {"stringValue": "dev-1"}


def test_decode_round_trips_the_types_that_matter():
    encoded = {
        "name": "projects/p/databases/(default)/documents/devices/d1",
        "fields": values.encode_fields(
            {"n": 42, "s": "x", "b": True, "arr": [1, 2], "m": {"k": "v"}, "nil": None}
        ),
    }
    decoded = rest.decode_document(encoded)
    assert decoded["n"] == 42 and isinstance(decoded["n"], int)
    assert decoded["s"] == "x"
    assert decoded["b"] is True
    assert decoded["arr"] == [1, 2]
    assert decoded["m"] == {"k": "v"}
    assert decoded["nil"] is None
    assert decoded["id"] == "d1"


def test_get_document_returns_none_for_a_missing_doc():
    client, _, _ = _client([FakeResponse(404)])
    assert client.get_document("devices/nope") is None


def test_urls_are_built_against_the_configured_project_and_database():
    assert rest.document_url("proj", "/devices/d1/") == (
        "https://firestore.googleapis.com/v1/projects/proj/databases/(default)/documents/devices/d1"
    )
