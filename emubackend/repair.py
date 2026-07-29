"""Phase A2 — the offline repair agent. Consumes captured DOM, emits human-gated patches.

The recipe calls A2 *"the first real value"*, and the reason is architectural rather than
sentimental: its output is a **JSON patch to the selector manifest**, so a platform-change fix ships
as **data** — no version bump, no wheel rebuild, no republish. Iteration cost is the dominant tax on
this codebase, and this route avoids it entirely (§0.5.3).

It **proposes; it never applies.** That is the whole of decision A2's staged-autonomy position: a
structural change (a new selector, a changed parse) is exactly the class the recipe says must be
human-gated, because a plausible-but-wrong selector produces the P1 failure — every click lands,
extraction returns nothing, the run reports success. A *gap* fails loudly at first use; a wrong value
does not. So a proposal carries its evidence and its confidence, and something else decides.

**What it can and cannot fix, stated so the ROI is not oversold.** It repairs *moved controls* — a
selector that no longer matches but whose element is still findable by another route. It cannot
repair a changed **parse** (the P1 case: the sources were there, rendered as a shape the extractor
did not understand), because there is no selector to promote — the fix is new extraction logic. It
cannot repair quota, auth expiry, or rate limits at all. Roughly half the outage surface is outside
its reach, and pretending otherwise is how this kind of layer gets oversold.
"""

from __future__ import annotations

from dataclasses import dataclass, field
from typing import Any

__all__ = [
    "STABILITY_RANK",
    "Candidate",
    "Proposal",
    "propose",
    "rank_candidate",
    "to_manifest_patch",
]

#: Attribute kinds ordered by how well they survive a redesign. Lower is better.
#:
#: The ordering is the whole judgement in this module, so it is stated rather than implied:
#: ``data-testid`` exists *for* automation and changes deliberately; an ``id`` is usually stable but
#: is sometimes generated; ARIA role + accessible name is semantic and is what the platform's own
#: accessibility tests depend on, so it breaks loudly for them too; a bare attribute is weaker; and
#: **text is last**, because it breaks on any copy edit or locale change — a class of change that
#: happens constantly and silently.
STABILITY_RANK = {
    "data-testid": 1,
    "id": 2,
    "role+name": 3,
    "attribute": 4,
    "text": 5,
}

#: Below this, a proposal is recorded but flagged as needing human derivation rather than review.
#: Set so that only rank 1–3 clears it: those three are the kinds whose breakage is visible to the
#: platform's own tests, which is the closest thing to a guarantee available from outside.
CONFIDENCE_FLOOR = 0.6


@dataclass
class Candidate:
    """One element observed in the captured DOM, with the evidence for ranking it."""

    selector: str
    kind: str
    visible: bool = True
    accessible_name: str = ""
    tag: str = ""
    #: Set when the element sits inside the region the failing intent was operating on. A control
    #: found in the right container is far likelier to be the right control than a global match.
    in_expected_region: bool = False

    @property
    def rank(self) -> int:
        return STABILITY_RANK.get(self.kind, 9)


def rank_candidate(candidate: Candidate, *, expected_name: str = "") -> float:
    """A confidence in [0, 1]. Deliberately simple and inspectable.

    Not a learned score: a proposal a human has to review is only reviewable if the reason it scored
    highly can be read off in one line. A model here would buy a little accuracy and lose the thing
    that makes the gate work.
    """
    score = {1: 0.9, 2: 0.8, 3: 0.7, 4: 0.45, 5: 0.25}.get(candidate.rank, 0.1)
    if not candidate.visible:
        # An invisible match is usually a different instance of the same component — a desktop-only
        # sibling, or a collapsed menu — so it is penalised hard rather than excluded, because
        # occasionally the real control is briefly hidden.
        score -= 0.35
    if expected_name and expected_name.lower() in (candidate.accessible_name or "").lower():
        score += 0.1
    if candidate.in_expected_region:
        score += 0.05
    return max(0.0, min(1.0, round(score, 3)))


@dataclass
class Proposal:
    """A proposed manifest patch, with everything a reviewer needs and nothing they do not."""

    platform: str
    key: str
    failed_selectors: list[str]
    proposed: str
    kind: str
    confidence: float
    rationale: str
    alternatives: list[str] = field(default_factory=list)

    @property
    def needs_human_derivation(self) -> bool:
        """True when the best candidate is too weak to be worth reviewing as-is."""
        return self.confidence < CONFIDENCE_FLOOR

    def describe(self) -> str:
        head = "NEEDS HUMAN" if self.needs_human_derivation else "REVIEW"
        return (
            f"[{head} {self.confidence:.2f}] {self.platform}.{self.key}: "
            f"{self.failed_selectors} -> {self.proposed}  ({self.rationale})"
        )


def propose(
    platform: str,
    key: str,
    failed_selectors: list[str],
    candidates: list[Candidate],
    *,
    expected_name: str = "",
) -> Proposal | None:
    """Propose a replacement selector for a failing intent, or ``None`` if nothing is defensible.

    Returning ``None`` is a real outcome, not a failure to try. Proposing *something* for every
    breakage is how a repair layer starts emitting noise, and a reviewer who learns to skim
    proposals is worse than no proposals at all.
    """
    if not candidates:
        return None
    scored = sorted(
        ((rank_candidate(c, expected_name=expected_name), c) for c in candidates),
        key=lambda pair: (-pair[0], pair[1].rank),
    )
    best_score, best = scored[0]
    if best_score <= 0.1:
        return None
    return Proposal(
        platform=platform,
        key=key,
        failed_selectors=list(failed_selectors),
        proposed=best.selector,
        kind=best.kind,
        confidence=best_score,
        rationale=_rationale(best, best_score, expected_name),
        alternatives=[c.selector for _s, c in scored[1:4]],
    )


def _rationale(candidate: Candidate, score: float, expected_name: str) -> str:
    bits = [f"{candidate.kind} (stability rank {candidate.rank})"]
    if candidate.accessible_name:
        bits.append(f"name={candidate.accessible_name!r}")
    if expected_name and expected_name.lower() in (candidate.accessible_name or "").lower():
        bits.append("name matches the intent")
    if candidate.in_expected_region:
        bits.append("inside the expected region")
    if not candidate.visible:
        bits.append("⚠ NOT VISIBLE — likely a different instance of the component")
    return "; ".join(bits)


def to_manifest_patch(proposals: list[Proposal], *, include_low_confidence: bool = False) -> dict:
    """Render proposals as a manifest fragment, ready to merge after review.

    The old selectors are kept as **fallbacks after** the new one rather than discarded: platforms
    A/B-test their DOM, so the "broken" selector is often still correct for a fraction of sessions,
    and dropping it converts a partial outage into a total one.
    """
    platforms: dict[str, dict[str, Any]] = {}
    for proposal in proposals:
        if proposal.needs_human_derivation and not include_low_confidence:
            continue
        entry = platforms.setdefault(proposal.platform, {})
        entry[proposal.key] = {
            "css": [proposal.proposed, *proposal.failed_selectors],
            "provenance": (
                f"repair-agent:{proposal.kind}:confidence={proposal.confidence:.2f} "
                f"(PROPOSED — review before use)"
            ),
        }
    return {"version": 1, "surface": "ios-mobile-safari", "platforms": platforms}
