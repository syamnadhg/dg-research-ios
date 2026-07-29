"""Tests for the A2 offline repair agent.

The recipe's gate for A2 is *"a proposed patch fixes a real historical breakage when replayed"* —
demonstrated end to end against a real Simulator by `bin/repair_demo.py`. These pin the judgement
underneath it, and in particular the two ways a repair layer goes wrong: proposing something for
every breakage (noise a reviewer learns to skim), and preferring a selector that looks specific but
breaks on the next copy edit.
"""

from __future__ import annotations

from emubackend import repair
from emubackend.repair import Candidate

C = Candidate


# ======================================================================================
# ranking — the whole judgement
# ======================================================================================


def test_stability_order_puts_testid_first_and_text_last():
    """Text breaks on any copy edit or locale change — a constant, silent class of change."""
    order = [k for k, _v in sorted(repair.STABILITY_RANK.items(), key=lambda kv: kv[1])]
    assert order[0] == "data-testid"
    assert order[-1] == "text"


def test_a_testid_outranks_an_id_which_outranks_role_plus_name():
    scores = [
        repair.rank_candidate(C(selector="s", kind=kind))
        for kind in ("data-testid", "id", "role+name", "attribute", "text")
    ]
    assert scores == sorted(scores, reverse=True), f"not monotonic: {scores}"


def test_an_invisible_candidate_is_penalised_hard_but_not_excluded():
    """Usually a different instance of the component — a desktop-only sibling or a collapsed menu.

    Not excluded, because occasionally the real control is briefly hidden.
    """
    visible = repair.rank_candidate(C(selector="s", kind="id", visible=True))
    hidden = repair.rank_candidate(C(selector="s", kind="id", visible=False))
    assert hidden < visible - 0.3
    assert hidden > 0, "penalised, not excluded"


def test_a_matching_accessible_name_raises_confidence():
    plain = repair.rank_candidate(C(selector="s", kind="id", accessible_name="Submit"))
    named = repair.rank_candidate(
        C(selector="s", kind="id", accessible_name="Send message"), expected_name="send"
    )
    assert named > plain


def test_being_in_the_expected_region_helps():
    outside = repair.rank_candidate(C(selector="s", kind="id"))
    inside = repair.rank_candidate(C(selector="s", kind="id", in_expected_region=True))
    assert inside > outside


def test_confidence_is_clamped_to_the_unit_interval():
    best = repair.rank_candidate(
        C(selector="s", kind="data-testid", accessible_name="Send", in_expected_region=True),
        expected_name="send",
    )
    assert 0.0 <= best <= 1.0


# ======================================================================================
# proposing — and declining to
# ======================================================================================


def test_the_best_candidate_is_proposed_with_the_rest_as_alternatives():
    proposal = repair.propose(
        "chatgpt",
        "send",
        ["#old-send"],
        [
            C(selector="button.b", kind="text", accessible_name="Send"),
            C(selector='[data-testid="send-button"]', kind="data-testid", accessible_name="Send"),
            C(selector="#send", kind="id", accessible_name="Send"),
        ],
        expected_name="send",
    )
    assert proposal is not None
    assert proposal.proposed == '[data-testid="send-button"]'
    assert "#send" in proposal.alternatives
    assert proposal.confidence >= 0.9


def test_no_candidates_means_no_proposal():
    """Proposing something for every breakage is how a repair layer starts emitting noise."""
    assert repair.propose("chatgpt", "send", ["#old"], []) is None


def test_a_hopeless_candidate_is_declined_rather_than_proposed():
    hopeless = C(selector="div", kind="unknown-kind", visible=False)
    assert repair.propose("chatgpt", "send", ["#old"], [hopeless]) is None


def test_a_weak_proposal_is_flagged_as_needing_human_derivation():
    proposal = repair.propose(
        "chatgpt", "send", ["#old"], [C(selector="button:nth-child(3)", kind="text")]
    )
    assert proposal is not None
    assert proposal.needs_human_derivation is True
    assert "NEEDS HUMAN" in proposal.describe()


def test_a_strong_proposal_is_marked_for_review_not_auto_apply():
    """A2 proposes; it never applies. A structural change is human-gated by design."""
    proposal = repair.propose(
        "chatgpt", "send", ["#old"], [C(selector='[data-testid="x"]', kind="data-testid")]
    )
    assert proposal is not None
    assert proposal.needs_human_derivation is False
    assert "REVIEW" in proposal.describe()


def test_the_rationale_is_readable_in_one_line():
    """A proposal a human must review is only reviewable if its reason reads off in one line —

    which is why the score is simple and inspectable rather than learned.
    """
    proposal = repair.propose(
        "chatgpt",
        "send",
        ["#old"],
        [C(selector='[data-testid="s"]', kind="data-testid", accessible_name="Send message",
           in_expected_region=True)],
        expected_name="send",
    )
    assert proposal is not None
    assert "data-testid" in proposal.rationale
    assert "name matches the intent" in proposal.rationale
    assert "inside the expected region" in proposal.rationale


def test_an_invisible_winner_says_so_loudly_in_its_rationale():
    proposal = repair.propose(
        "chatgpt", "send", ["#old"],
        [C(selector='[data-testid="s"]', kind="data-testid", visible=False)],
    )
    assert proposal is not None
    assert "NOT VISIBLE" in proposal.rationale


# ======================================================================================
# the patch — the output is DATA, which is the point
# ======================================================================================


def test_the_patch_keeps_the_old_selector_as_a_FALLBACK_after_the_new_one():
    """Platforms A/B-test their DOM, so the "broken" selector is often still right for a fraction of

    sessions. Dropping it converts a partial outage into a total one.
    """
    proposal = repair.propose(
        "chatgpt", "send", ["#old-send"], [C(selector='[data-testid="new"]', kind="data-testid")]
    )
    patch = repair.to_manifest_patch([proposal])
    css = patch["platforms"]["chatgpt"]["send"]["css"]
    assert css[0] == '[data-testid="new"]', "the proposal goes first"
    assert "#old-send" in css, "and the old one survives as a fallback"


def test_the_patch_records_provenance_and_that_it_is_only_proposed():
    proposal = repair.propose(
        "chatgpt", "send", ["#old"], [C(selector='[data-testid="new"]', kind="data-testid")]
    )
    entry = repair.to_manifest_patch([proposal])["platforms"]["chatgpt"]["send"]
    assert "repair-agent" in entry["provenance"]
    assert "PROPOSED" in entry["provenance"]
    assert "review before use" in entry["provenance"]


def test_low_confidence_proposals_are_excluded_from_the_patch_by_default():
    weak = repair.propose("chatgpt", "send", ["#old"], [C(selector="button", kind="text")])
    assert weak.needs_human_derivation
    assert repair.to_manifest_patch([weak])["platforms"] == {}
    assert repair.to_manifest_patch([weak], include_low_confidence=True)["platforms"] != {}


def test_the_patch_loads_as_a_real_manifest():
    """The output must be mergeable as-is, or a human has to hand-translate it and won't."""
    import json
    import tempfile
    from pathlib import Path

    from emubackend import selectors

    proposal = repair.propose(
        "chatgpt", "composer", ["#old"], [C(selector='[data-testid="composer"]', kind="data-testid")]
    )
    patch = repair.to_manifest_patch([proposal])
    with tempfile.TemporaryDirectory() as d:
        path = Path(d) / "patch.json"
        path.write_text(json.dumps(patch))
        manifest = selectors.load_manifest(path)
        assert manifest.source == str(path), f"the patch was rejected: {manifest.source}"
        assert manifest.require("chatgpt", "composer").css[0] == '[data-testid="composer"]'


def test_multiple_proposals_merge_into_one_patch():
    proposals = [
        repair.propose("chatgpt", "send", ["#a"], [C(selector='[data-testid="s"]', kind="data-testid")]),
        repair.propose("gemini", "composer", ["#b"], [C(selector="#c", kind="id")]),
    ]
    patch = repair.to_manifest_patch(proposals)
    assert set(patch["platforms"]) == {"chatgpt", "gemini"}


# ======================================================================================
# the honest ceiling
# ======================================================================================


def test_the_module_states_what_it_cannot_fix():
    """ROI is capped by read drift, quota and auth expiry — none of which a selector patch touches.

    Pinned as a test because the docstring is the only place that ceiling is recorded, and an
    undocumented ceiling is how this kind of layer gets oversold.
    """
    doc = repair.__doc__ or ""
    assert "changed **parse**" in doc or "changed parse" in doc
    assert "quota" in doc
    assert "half the outage surface" in doc
