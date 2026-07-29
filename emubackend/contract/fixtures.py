"""Golden-fixture capture and replay for the Firestore write contract (§0.5.7b).

No automated e2e exists for this pipeline, so this is the only mechanical check that a second
backend is contract-faithful. The recipe makes it a first-class task rather than a nice-to-have,
and the argument is sound: the expensive part of the port is not line count, it is re-deriving
behaviours that took months of production fixes. A recorded write sequence is the cheapest way
to notice that one of them was re-derived *wrongly*.

⚠ **One recipe assumption does not hold, and it changes the plan.** §0.5.7b says to start
capturing real backend runs "now", on the basis that fixture material accrues slowly at 1–3
runs/week. Measured: ``~/.super-research/logs/backend.log`` is 25 MB and contains **no emitted
event stream** — the writes are not logged, so there is nothing to mine. Capturing a real backend
run therefore needs either a backend edit (forbidden by A8) or Firestore read credentials
(owner-gated). Neither is autonomous.

So this module deliberately delivers the two halves that *are* available, and the missing half is
recorded rather than faked:

* :class:`CaptureTransport` records what **our own** client writes — usable the moment the iOS
  orchestrator runs, with no credentials and no backend involvement.
* :func:`compare` is the engine, and it is the reusable part. It works against a fixture
  regardless of how that fixture was obtained, so an owner-supplied capture of a real backend run
  drops straight in.

**Normalisation is the whole design problem.** A raw write sequence never repeats: ``seq`` and
``timestamp`` are epoch millis, ``expireAt`` is now-plus-30-days, document ids are
server-assigned, and uid/rid/deviceId differ per run. Comparing raw records would fail every
time and the check would be abandoned within a day. Comparing *too* loosely would pass anything.
So volatile values are replaced by **type-and-shape markers**, identifiers are **tokenised**
consistently, and everything else must match exactly — including order.
"""

from __future__ import annotations

import json
import re
from dataclasses import dataclass, field
from pathlib import Path
from typing import Any, Callable

__all__ = [
    "VOLATILE_FIELDS",
    "CaptureTransport",
    "Difference",
    "WriteRecord",
    "compare",
    "load_fixture",
    "normalize",
    "save_fixture",
]

#: Fields whose *value* is unstable between runs but whose *presence and type* is contract.
#: Replaced with a marker so a fixture stays comparable, while a missing or retyped field still
#: fails. ``seq``/``timestamp`` are epoch millis; ``expireAt`` is relative to write time.
VOLATILE_FIELDS = ("seq", "timestamp", "expireAt", "lastHeartbeat", "acquiredAt")

_ID_SEGMENT = re.compile(r"[0-9A-Za-z_-]{16,}")


@dataclass
class WriteRecord:
    """One Firestore write, normalised away from transport detail."""

    op: str  # "patch" | "create" | "query" | "get"
    path: str
    fields: dict[str, Any] = field(default_factory=dict)
    delete_paths: list[str] = field(default_factory=list)

    def to_json(self) -> dict:
        return {
            "op": self.op,
            "path": self.path,
            "fields": self.fields,
            "delete_paths": self.delete_paths,
        }

    @classmethod
    def from_json(cls, raw: dict) -> WriteRecord:
        return cls(
            op=raw["op"],
            path=raw["path"],
            fields=raw.get("fields") or {},
            delete_paths=list(raw.get("delete_paths") or []),
        )


def _marker(value: Any) -> str:
    """A type-and-shape marker for a volatile value.

    Keeps the assertion meaningful: an ``int`` millis that becomes a string, or a field that
    disappears, still fails — which is exactly the class of bug the encoding traps describe.
    """
    if isinstance(value, bool):
        return "<bool>"
    if isinstance(value, int):
        return "<int>"
    if isinstance(value, float):
        return "<float>"
    if isinstance(value, str):
        # ISO-8601-ish strings are timestamps; anything else keeps its shape distinguishable.
        return "<iso8601>" if re.match(r"^\d{4}-\d{2}-\d{2}T", value) else "<str>"
    if value is None:
        return "<null>"
    return f"<{type(value).__name__}>"


def normalize(
    record: WriteRecord,
    *,
    tokens: dict[str, str] | None = None,
    volatile: tuple[str, ...] = VOLATILE_FIELDS,
) -> WriteRecord:
    """Make one record comparable across runs.

    *tokens* maps a concrete identifier to a stable token (``{"abc123uid": "{uid}"}``). Supply it
    when known; otherwise long opaque path segments are tokenised positionally, which is enough
    to compare structure without pretending to know which id meant what.
    """
    tokens = tokens or {}
    path = record.path
    for concrete, token in tokens.items():
        path = path.replace(concrete, token)
    # Any remaining long opaque segment is an id we were not told about.
    path = _ID_SEGMENT.sub(lambda m: "{id}", path)

    fields: dict[str, Any] = {}
    for key, value in sorted(record.fields.items()):
        if key in volatile:
            fields[key] = _marker(value)
        elif isinstance(value, str):
            replaced = value
            for concrete, token in tokens.items():
                replaced = replaced.replace(concrete, token)
            fields[key] = replaced
        elif isinstance(value, dict):
            fields[key] = normalize(
                WriteRecord(op="_", path="", fields=value), tokens=tokens, volatile=volatile
            ).fields
        else:
            fields[key] = value
    return WriteRecord(
        op=record.op, path=path, fields=fields, delete_paths=sorted(record.delete_paths)
    )


@dataclass(frozen=True)
class Difference:
    """One mismatch between a golden fixture and an actual sequence."""

    index: int
    kind: str
    detail: str

    def __str__(self) -> str:  # pragma: no cover - formatting only
        return f"[{self.index}] {self.kind}: {self.detail}"


def compare(golden: list[WriteRecord], actual: list[WriteRecord]) -> list[Difference]:
    """Compare two normalised sequences **in order**; empty result means faithful.

    Order matters and is not a stylistic choice: the frontend consumes ``pipeline_events`` by an
    ascending ``seq`` cursor, and the pendingDecision slot is single-valued, so a reordered
    sequence produces a different user-visible outcome even when every individual write is
    correct on its own.

    Reports *every* difference rather than stopping at the first, because a reimplementation
    usually diverges in a cluster and fixing them one round-trip at a time is what makes people
    give up on a fixture suite.
    """
    diffs: list[Difference] = []
    for i in range(max(len(golden), len(actual))):
        if i >= len(actual):
            diffs.append(
                Difference(i, "missing", f"expected {golden[i].op} {golden[i].path}, got nothing")
            )
            continue
        if i >= len(golden):
            diffs.append(
                Difference(i, "extra", f"unexpected {actual[i].op} {actual[i].path}")
            )
            continue
        g, a = golden[i], actual[i]
        if g.op != a.op:
            diffs.append(Difference(i, "op", f"expected {g.op!r}, got {a.op!r}"))
        if g.path != a.path:
            diffs.append(Difference(i, "path", f"expected {g.path!r}, got {a.path!r}"))
        for key in sorted(set(g.fields) | set(a.fields)):
            if key not in a.fields:
                diffs.append(Difference(i, "field-missing", f"{g.path}: {key!r} not written"))
            elif key not in g.fields:
                diffs.append(Difference(i, "field-extra", f"{g.path}: unexpected {key!r}"))
            elif g.fields[key] != a.fields[key]:
                diffs.append(
                    Difference(
                        i,
                        "field-value",
                        f"{g.path}.{key}: expected {g.fields[key]!r}, got {a.fields[key]!r}",
                    )
                )
        if g.delete_paths != a.delete_paths:
            diffs.append(
                Difference(
                    i,
                    "delete-paths",
                    f"{g.path}: expected {g.delete_paths}, got {a.delete_paths}",
                )
            )
    return diffs


class CaptureTransport:
    """Wrap a transport callable, recording every write it carries.

    Records **our own** client's writes, so it needs no credentials and no backend cooperation.
    Reads are recorded too (as ``query``/``get``) because a missing read is also a contract
    divergence — a reimplementation that skips the queued→ongoing read produces the right writes
    from the wrong state.
    """

    def __init__(self, inner: Callable[..., Any]):
        self._inner = inner
        self.records: list[WriteRecord] = []

    def __call__(self, method, url, headers=None, json=None, timeout=None):
        self.records.append(self._classify(method, url, json))
        return self._inner(method, url, headers=headers, json=json, timeout=timeout)

    @staticmethod
    def _classify(method: str, url: str, body: Any) -> WriteRecord:
        path = url.split("/documents", 1)[-1].split("?", 1)[0].strip("/")
        if ":runQuery" in url:
            return WriteRecord(op="query", path=path.replace(":runQuery", ""))
        if method == "GET":
            return WriteRecord(op="get", path=path)
        fields = _decode_body_fields(body)
        if method == "PATCH":
            mask = [
                v.split("=", 1)[1]
                for v in url.split("?", 1)[-1].split("&")
                if v.startswith("updateMask.fieldPaths=")
            ]
            return WriteRecord(
                op="patch",
                path=path,
                fields=fields,
                delete_paths=[m for m in mask if m not in fields],
            )
        return WriteRecord(op="create", path=path, fields=fields)


def _decode_body_fields(body: Any) -> dict[str, Any]:
    """Turn a REST ``{"fields": {...}}`` body back into plain Python for readability.

    Fixtures are read by humans when they fail, so storing raw ``{"integerValue": "17853…"}``
    envelopes would make a diff unreadable — and an unreadable diff is an ignored one.
    """
    from emubackend.contract import rest

    if not isinstance(body, dict) or "fields" not in body:
        return {}
    return {k: rest.decode_value(v) for k, v in (body["fields"] or {}).items()}


def save_fixture(path: Path, records: list[WriteRecord]) -> Path:
    path = Path(path)
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(
        "\n".join(json.dumps(r.to_json(), sort_keys=True) for r in records) + "\n",
        encoding="utf-8",
    )
    return path


def load_fixture(path: Path) -> list[WriteRecord]:
    return [
        WriteRecord.from_json(json.loads(line))
        for line in Path(path).read_text(encoding="utf-8").splitlines()
        if line.strip()
    ]
