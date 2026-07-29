"""Harvest-shaped predicates — because read drift, not failed clicks, is the dominant failure.

The reference incident is our own, and it is the reason this module exists rather than being an
extra: in the **P1 raw-activity** failure the panel opened, the steps parsed, **every click landed
and every state change occurred** — and source extraction returned **0 for an entire run**, because
the Pro+ET panel renders sources as something other than ``<a href>``. The run reported
**success** and harvested nothing.

A step-scoped, selector-promoting design is structurally blind to that. Nothing failed. There is no
crisp predicate for *"these are the right sources"*. And there is nothing to promote, because the
fix is a new **parse**, not a new selector. An architecture that only heals clicks covers roughly
half the outage surface.

So extraction correctness is a first-class target here, and the predicates compare **against the
run's own history** rather than against a threshold someone guessed:

* ``non_empty`` is necessary and nowhere near sufficient — 1 source where 40 are expected passes it.
* A **collapse** relative to this run's own earlier harvests is the signal that catches the P1
  incident, and it needs no knowledge of what the correct number is.
* **Shape and type** matter as much as count: 40 items that are all empty strings, or all the same
  value, is a parse that matched the wrong nodes.
"""

from __future__ import annotations

from dataclasses import dataclass, field
from typing import Any, Callable, Sequence

__all__ = [
    "COLLAPSE_RATIO",
    "HarvestHistory",
    "HarvestVerdict",
    "harvest_predicate",
    "judge",
]

#: A harvest below this fraction of the run's established baseline is treated as a collapse.
#: Chosen deliberately loose: platforms legitimately return fewer sources for a narrower query, so
#: the aim is to catch "the parse stopped matching" (which collapses to ~0), not to police
#: normal variance. Tightening it would trade a real detection for false alarms on healthy runs.
COLLAPSE_RATIO = 0.25


@dataclass
class HarvestHistory:
    """What this run has harvested so far, per named harvest point.

    Per-run rather than global on purpose: source counts vary hugely by topic and by account tier,
    so a cross-run baseline would either be too loose to catch anything or would flag every
    unusual-but-fine run. Within one run the comparison is apples to apples.
    """

    counts: dict[str, list[int]] = field(default_factory=dict)

    def record(self, point: str, count: int) -> None:
        self.counts.setdefault(point, []).append(int(count))

    def baseline(self, point: str) -> int | None:
        """The established count for *point*: the median of what we have seen.

        Median rather than mean or max — one anomalous harvest (either direction) should not move
        the baseline much, and with only a handful of samples a mean is dominated by the outlier
        we are trying to detect.
        """
        seen = sorted(self.counts.get(point) or [])
        if not seen:
            return None
        mid = len(seen) // 2
        if len(seen) % 2:
            return seen[mid]
        return (seen[mid - 1] + seen[mid]) // 2

    def samples(self, point: str) -> int:
        return len(self.counts.get(point) or [])


@dataclass(frozen=True)
class HarvestVerdict:
    """Whether a harvest looks like a real one, and why."""

    ok: bool
    reason: str
    count: int
    baseline: int | None = None

    def __str__(self) -> str:  # pragma: no cover - formatting only
        return f"{'ok' if self.ok else 'SUSPECT'} n={self.count} ({self.reason})"


def judge(
    point: str,
    items: Sequence[Any],
    history: HarvestHistory,
    *,
    min_samples: int = 2,
    collapse_ratio: float = COLLAPSE_RATIO,
    item_ok: Callable[[Any], bool] | None = None,
) -> HarvestVerdict:
    """Judge one harvest against this run's history and its own internal shape.

    *min_samples* exists so the first harvests of a run cannot be judged against a baseline that
    does not exist yet. Until then a harvest is only checked for emptiness and shape — being
    honest that there is nothing to compare against beats inventing a threshold.
    """
    count = len(items)
    baseline = history.baseline(point)
    samples = history.samples(point)

    if count == 0:
        # Recorded even though it fails, so a run that harvests nothing throughout does not
        # establish a zero baseline that later makes zero look normal.
        history.record(point, 0)
        return HarvestVerdict(False, "empty harvest", 0, baseline)

    check = item_ok or _default_item_ok
    usable = [it for it in items if check(it)]
    if not usable:
        history.record(point, count)
        return HarvestVerdict(
            False,
            f"{count} item(s) but none usable — the parse matched the wrong nodes",
            count,
            baseline,
        )

    distinct = len({_identity(it) for it in usable})
    if count >= 3 and distinct == 1:
        history.record(point, count)
        return HarvestVerdict(
            False,
            f"{count} item(s) but all identical — a selector matching one node repeatedly",
            count,
            baseline,
        )

    if baseline is not None and samples >= min_samples:
        # `max(1, …)` is doing two jobs, and the second is easy to lose in a refactor: besides
        # keeping the floor at one item, it makes a ZERO baseline harmless. Without it the
        # threshold would be 0, every count would be `>= 0`, and... the comparison would never
        # fire — but flip the comparison or the arithmetic and a zero baseline starts calling
        # every healthy harvest a collapse. An explicit `baseline > 0` clause here was removed as
        # genuinely unreachable (bin/mutate.py proved it), so this line carries the property alone.
        if count < max(1, int(baseline * collapse_ratio)):
            history.record(point, count)
            return HarvestVerdict(
                False,
                (
                    f"collapse: {count} vs a baseline of {baseline} from {samples} earlier "
                    f"harvest(s) — this is the P1 shape, where every click landed and the parse "
                    f"silently stopped matching"
                ),
                count,
                baseline,
            )

    history.record(point, count)
    return HarvestVerdict(
        True,
        f"{count} usable item(s)" + (f" against a baseline of {baseline}" if baseline else ""),
        count,
        baseline,
    )


def _default_item_ok(item: Any) -> bool:
    """A usable item: not None, and not a whitespace-only string.

    Deliberately minimal. A stricter default (say, requiring a URL) would silently reject valid
    harvests from a platform that renders sources as text — which is *exactly* the P1 situation,
    so building that assumption in would reproduce the bug it is meant to catch.
    """
    if item is None:
        return False
    if isinstance(item, str):
        return bool(item.strip())
    if isinstance(item, dict):
        return any(_default_item_ok(v) for v in item.values())
    return True


def _identity(item: Any) -> str:
    if isinstance(item, dict):
        return repr(sorted((k, repr(v)) for k, v in item.items()))
    return repr(item)


def harvest_predicate(
    point: str,
    history: HarvestHistory,
    extract: Callable[[], Sequence[Any]],
    **kw,
) -> Callable[[], bool]:
    """Adapt a harvest into an ``outcome_predicate`` for :mod:`emubackend.intents`.

    Lets an extraction step be wrapped exactly like a mutating one, which is the point of §0.5.4:
    without this, the intent layer can only ever verify that something was *clicked*.
    """

    def _predicate() -> bool:
        try:
            items = extract() or []
        except Exception:
            return False
        return judge(point, items, history, **kw).ok

    return _predicate
