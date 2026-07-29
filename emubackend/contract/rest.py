"""Firestore REST transport — the plumbing, with the two retries that are not optional.

Patterned on ``dg-research-backend/agent/facade/firestore_rest.py`` rather than invented, and
deliberately so: two of its behaviours look like defensive noise and are load-bearing.

**The credential retry.** The token provider is called **per request**, and on an auth failure
the request is retried **once** with a force-refreshed token. Re-sending the cached token would
just fail again, so the ``force=True`` is the whole mechanism.

⚠ **401 *and* 403, and the distinction is worth knowing.** The backend's REST client retries on
**401**. The backend's *gRPC* path (``research.py · _grpc_write_with_heal``) heals **403**,
because a stale gRPC credential surfaces as ``PermissionDenied`` rather than
``Unauthenticated``. Over REST there is no ``client._credentials`` to force-refresh, so that heal
has to be reimplemented here — and since a stale ID token can present as either code depending
on which layer rejects it, both are retried once. The cost of retrying a *genuine* rules denial
is one wasted request; the cost of not healing is a run that dies mid-flight on a token that had
simply aged out.

**No cross-field OR.** Firestore REST cannot express ``ownerUid == uid OR sharedWith contains
uid``. :meth:`FirestoreRest.list_devices` therefore unions **two** ``runQuery`` calls, copied from
upstream. Anyone who "simplifies" that into one query gets a silently short device list — owned
devices but no shared ones, or vice versa.
"""

from __future__ import annotations

from typing import Any, Callable

from emubackend.contract import values

__all__ = [
    "AUTH_RETRY_CODES",
    "FirestoreError",
    "FirestoreRest",
    "collection_url",
    "document_url",
]

#: Status codes that trigger exactly one force-refreshed retry. See the module docstring for
#: why 403 is here as well as 401.
AUTH_RETRY_CODES = (401, 403)

_DEFAULT_HOST = "https://firestore.googleapis.com/v1"


class FirestoreError(RuntimeError):
    """A Firestore REST call failed."""


def _base(project_id: str, database: str = "(default)", host: str = _DEFAULT_HOST) -> str:
    return f"{host}/projects/{project_id}/databases/{database}/documents"


def document_url(project_id: str, path: str, **kw) -> str:
    """URL for a document path like ``users/{uid}/researches/{rid}``."""
    return f"{_base(project_id, **kw)}/{path.strip('/')}"


def collection_url(project_id: str, path: str, **kw) -> str:
    return f"{_base(project_id, **kw)}/{path.strip('/')}"


class FirestoreRest:
    """Firestore REST operations scoped to one authenticated principal.

    *token_provider* is called as ``token_provider()`` normally and
    ``token_provider(force=True)`` on the retry, matching upstream's contract so a provider can
    be shared between the two.

    ⚠ **The token it returns MUST carry the ``deviceId`` custom claim.** Verified against the real
    rules in the emulator (`bin/rules_verify.py`): ``deviceWritingTo()`` and ``deviceMemberOf()``
    both require ``request.auth.token.deviceId is string``, and it is the *only* custom claim the
    ruleset reads — 15 times. Without it **every** write into the user tree
    (``users/{uid}/researches/...``, including all ``pipeline_events``) is denied, and the denial says
    "Missing or insufficient permissions" while naming neither the claim nor the rule. The claim is
    minted into the custom token by the claim route, so the provider must carry it through rather
    than re-minting a bare token.

    ⚠ **And note the asymmetry**, which is easy to get backwards: the *device document* rule pins on
    ``resource.data.syntheticDeviceUid == request.auth.uid`` and needs **no** claim, while the
    *user-tree* rules need the claim and ignore the uid. Two different mechanisms guarding two
    different paths — a heartbeat can succeed while every event write fails.

    *transport* is injectable so the whole class is testable without network. Defaulting to
    ``requests`` keeps the import lazy — the identity layer is useful without it.
    """

    def __init__(
        self,
        token_provider: Callable[..., str],
        project_id: str,
        *,
        database: str = "(default)",
        host: str = _DEFAULT_HOST,
        transport: Callable[..., Any] | None = None,
        timeout: float = 15.0,
    ):
        self._token = token_provider
        self.project_id = project_id
        self.database = database
        self.host = host
        self._transport = transport
        self._timeout = timeout

    # -- plumbing ----------------------------------------------------------------

    def _send(self, method: str, url: str, token: str, json_body: Any):
        transport = self._transport
        if transport is None:
            import requests  # imported lazily: only the network path needs it

            transport = requests.request
        return transport(
            method,
            url,
            headers={"Authorization": f"Bearer {token}"},
            json=json_body,
            timeout=self._timeout,
        )

    def request(
        self,
        method: str,
        url: str,
        *,
        json_body: Any = None,
        allow_missing: bool = False,
    ) -> Any:
        """One request, with a single force-refreshed retry on an auth failure."""
        resp = self._send(method, url, self._token(), json_body)
        if resp.status_code in AUTH_RETRY_CODES:
            # A fresh token, not the cached one — re-sending the same token would fail again.
            resp = self._send(method, url, self._token(force=True), json_body)
        if allow_missing and resp.status_code == 404:
            return None
        if not getattr(resp, "ok", 200 <= resp.status_code < 300):
            raise FirestoreError(
                f"{method} {url.split('/documents')[-1]} -> HTTP {resp.status_code}: "
                f"{str(getattr(resp, 'text', ''))[:300]}"
            )
        return resp.json() if getattr(resp, "content", True) else {}

    # -- reads -------------------------------------------------------------------

    def get_document(self, path: str) -> dict[str, Any] | None:
        raw = self.request(
            "GET",
            document_url(self.project_id, path, database=self.database, host=self.host),
            allow_missing=True,
        )
        return None if raw is None else decode_document(raw)

    def run_query(self, parent: str, structured_query: dict) -> list[dict[str, Any]]:
        """Run one ``structuredQuery`` under *parent* and return decoded documents."""
        url = (
            f"{_base(self.project_id, self.database, self.host)}"
            f"{'/' + parent.strip('/') if parent else ''}:runQuery"
        )
        rows = self.request("POST", url, json_body={"structuredQuery": structured_query}) or []
        out = []
        for entry in rows:
            doc = entry.get("document") if isinstance(entry, dict) else None
            if doc:
                out.append(decode_document(doc))
        return out

    def list_devices(self, uid: str) -> list[dict[str, Any]]:
        """Devices this account can reach: owned ∪ shared-with.

        ⚠ **Two queries, unioned by id, because Firestore REST has no cross-field OR.** Merging
        them into one query is not possible, and *dropping* one silently truncates the list —
        owned devices without shared ones, or the reverse. Neither errors.
        """
        seen: dict[str, dict[str, Any]] = {}
        for field, op in (("ownerUid", "EQUAL"), ("sharedWith", "ARRAY_CONTAINS")):
            docs = self.run_query(
                "",
                {
                    "from": [{"collectionId": "devices"}],
                    "where": {
                        "fieldFilter": {
                            "field": {"fieldPath": field},
                            "op": op,
                            "value": {"stringValue": uid},
                        }
                    },
                },
            )
            for doc in docs:
                did = doc.get("id")
                if did and did not in seen:
                    seen[did] = doc
        return list(seen.values())

    # -- writes ------------------------------------------------------------------

    def patch(
        self,
        path: str,
        fields: dict[str, Any],
        *,
        delete_paths: list[str] | None = None,
    ) -> dict[str, Any]:
        """Patch a document, optionally deleting fields.

        ⚠ Deleted fields are named in ``updateMask.fieldPaths`` and **omitted from the body** —
        that pairing *is* the delete. There is no ``DELETE_FIELD`` sentinel over REST, and
        sending ``null`` sets the field to null instead, which the frontend reads as
        present-but-null rather than absent. A "clear" that writes null therefore reports success
        and leaves the value live.
        """
        mask = values.update_mask_for(fields, delete_paths)
        url = document_url(self.project_id, path, database=self.database, host=self.host)
        query = "&".join(f"updateMask.fieldPaths={p}" for p in mask)
        body = {"fields": values.encode_fields(fields)}
        return self.request("PATCH", f"{url}?{query}", json_body=body)

    def create_with_auto_id(self, collection_path: str, fields: dict[str, Any]) -> dict:
        """POST to a collection so Firestore assigns the id — the ``pipeline_events`` shape."""
        url = collection_url(
            self.project_id, collection_path, database=self.database, host=self.host
        )
        return self.request("POST", url, json_body={"fields": values.encode_fields(fields)})


# -- decoding ---------------------------------------------------------------------------


def decode_value(value: dict[str, Any]) -> Any:
    """Decode one Firestore REST ``Value`` back to Python."""
    if "nullValue" in value:
        return None
    if "booleanValue" in value:
        return value["booleanValue"]
    if "integerValue" in value:
        return int(value["integerValue"])
    if "doubleValue" in value:
        return float(value["doubleValue"])
    if "stringValue" in value:
        return value["stringValue"]
    if "timestampValue" in value:
        return value["timestampValue"]  # left as the ISO string; callers parse if needed
    if "mapValue" in value:
        return {
            k: decode_value(v) for k, v in (value["mapValue"].get("fields") or {}).items()
        }
    if "arrayValue" in value:
        return [decode_value(v) for v in (value["arrayValue"].get("values") or [])]
    return None


def decode_document(doc: dict[str, Any]) -> dict[str, Any]:
    """Decode a document's fields and attach its id under ``"id"``."""
    out = {k: decode_value(v) for k, v in (doc.get("fields") or {}).items()}
    name = doc.get("name") or ""
    if name:
        out["id"] = name.rsplit("/", 1)[-1]
    return out
