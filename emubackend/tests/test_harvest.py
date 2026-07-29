"""Tests for the harvest-shaped predicates.

The one that matters most is `test_the_p1_incident_is_caught`: the failure these exist for is a
run where every click landed, every state change occurred, extraction returned zero, and the run
reported success. A `non_empty` check does not catch it, and neither does anything selector-shaped.
"""

from __future__ import annotations

from emubackend import harvest
from emubackend.harvest import HarvestHistory, judge


def _history(point="p1.sources", counts=()):
    h = HarvestHistory()
    for c in counts:
        h.record(point, c)
    return h


# ======================================================================================
# the reference incident
# ======================================================================================


def test_the_p1_incident_is_caught():
    """Every click landed; the Pro+ET panel rendered sources as non-<a href>; extraction returned

    0 for an entire run and the run reported success. The collapse check catches it without
    needing to know what the right number is.
    """
    h = _history(counts=[38, 41, 40])
    verdict = judge("p1.sources", [], h)
    assert verdict.ok is False
    assert "empty harvest" in verdict.reason


def test_a_near_total_collapse_is_caught_even_though_it_is_non_empty():
    """The subtler shape of the same failure: 1 source where 40 are expected.

    `non_empty` passes this happily, which is why it is necessary and nowhere near sufficient.
    """
    h = _history(counts=[38, 41, 40])
    verdict = judge("p1.sources", ["https://one-source"], h)
    assert verdict.ok is False
    assert "collapse" in verdict.reason
    assert "baseline of 40" in verdict.reason


def test_a_healthy_harvest_against_an_established_baseline_passes():
    h = _history(counts=[38, 41, 40])
    assert judge("p1.sources", [f"s{i}" for i in range(37)], h).ok is True


def test_normal_variance_is_not_flagged():
    """Platforms legitimately return fewer sources for a narrower query.

    The ratio is deliberately loose: policing variance would trade a real detection for false
    alarms on healthy runs, and a noisy predicate gets switched off.
    """
    h = _history(counts=[40, 40, 40])
    assert judge("p1.sources", [f"s{i}" for i in range(20)], h).ok is True
    assert judge("p1.sources", [f"s{i}" for i in range(12)], h).ok is True


# ======================================================================================
# shape and type, not just count
# ======================================================================================


def test_items_that_are_all_unusable_fail_even_at_a_healthy_count():
    """40 empty strings is a parse that matched the wrong nodes."""
    h = _history(counts=[40, 40])
    verdict = judge("p1.sources", ["", "   ", "\n"], h)
    assert verdict.ok is False
    assert "none usable" in verdict.reason


def test_identical_items_indicate_one_node_matched_repeatedly():
    h = _history(counts=[40, 40])
    verdict = judge("p1.sources", ["same", "same", "same", "same"], h)
    assert verdict.ok is False
    assert "all identical" in verdict.reason


def test_two_identical_items_are_not_enough_to_conclude_that():
    """A genuine two-source harvest can legitimately repeat; three is where it becomes a pattern."""
    h = HarvestHistory()
    assert judge("p1.sources", ["same", "same"], h).ok is True


def test_dicts_are_judged_by_their_content():
    h = HarvestHistory()
    assert judge("p", [{"url": "x"}, {"url": "y"}], h).ok is True
    assert judge("p", [{"url": ""}, {"url": None}], h).ok is False


def test_the_default_usability_check_accepts_plain_text_sources():
    """The P1 panel rendered sources as text, not links. A default that demanded a URL would

    reproduce the very bug this module exists to catch.
    """
    h = HarvestHistory()
    assert judge("p", ["Some Journal, 2024", "Another Source"], h).ok is True


def test_a_custom_item_check_can_be_supplied():
    h = HarvestHistory()
    only_urls = lambda it: isinstance(it, str) and it.startswith("http")  # noqa: E731
    assert judge("p", ["not a url", "also not"], h, item_ok=only_urls).ok is False
    assert judge("p", ["http://a", "http://b"], h, item_ok=only_urls).ok is True


# ======================================================================================
# the baseline
# ======================================================================================


def test_no_baseline_means_no_collapse_verdict():
    """Honest about having nothing to compare against, rather than inventing a threshold."""
    h = HarvestHistory()
    verdict = judge("p1.sources", ["one"], h)
    assert verdict.ok is True
    assert verdict.baseline is None


def test_min_samples_gates_the_collapse_check():
    h = _history(counts=[40])
    assert judge("p1.sources", ["one"], h, min_samples=2).ok is True, "one sample is not a baseline"
    h2 = _history(counts=[40, 40])
    assert judge("p1.sources", ["one"], h2, min_samples=2).ok is False


def test_the_baseline_is_a_median_so_one_outlier_does_not_move_it():
    """With few samples a mean is dominated by exactly the outlier we are trying to detect."""
    h = _history(counts=[40, 41, 39, 0])
    assert h.baseline("p1.sources") == 39 or h.baseline("p1.sources") == 40


def test_an_even_number_of_samples_averages_the_middle_two():
    h = _history(counts=[10, 20])
    assert h.baseline("p1.sources") == 15


def test_a_failing_harvest_is_still_recorded_so_zero_cannot_become_normal():
    """Otherwise a run that harvests nothing throughout establishes a zero baseline, and zero

    then looks healthy for the rest of the run.
    """
    h = HarvestHistory()
    judge("p", [], h)
    judge("p", [], h)
    assert h.samples("p") == 2
    assert h.baseline("p") == 0


def test_a_zero_baseline_does_not_trigger_a_collapse_verdict():
    """Guards the arithmetic: a zero baseline must not make every harvest a "collapse".

    A run that harvested nothing so far establishes a baseline of 0, and the moment it finally
    harvests something that must read as recovery, not as a further collapse — otherwise the
    predicate condemns the exact harvest that proves things started working.

    Tested at the BOUNDARY (one item), because that is the only place the comparison can be got
    wrong: with two items the threshold has slack and an off-by-one hides. Found by bin/mutate.py.
    """
    h = _history(counts=[0, 0])
    assert judge("p1.sources", ["one"], h).ok is True, (
        "a single item against a zero baseline is recovery, not a collapse"
    )

    h2 = _history(counts=[0, 0])
    assert judge("p1.sources", ["one", "two"], h2).ok is True


def test_harvest_points_are_tracked_independently():
    h = HarvestHistory()
    for _ in range(3):
        h.record("p1.sources", 40)
        h.record("p2.steps", 5)
    assert h.baseline("p1.sources") == 40
    assert h.baseline("p2.steps") == 5
    assert judge("p2.steps", ["a", "b", "c", "d"], h).ok is True


# ======================================================================================
# adapting to the intent layer
# ======================================================================================


def test_harvest_predicate_wraps_an_extractor_for_the_intent_layer():
    """Without this the intent layer can only ever verify that something was clicked."""
    h = _history(counts=[40, 40])
    good = harvest.harvest_predicate("p1.sources", h, lambda: [f"s{i}" for i in range(38)])
    assert good() is True
    bad = harvest.harvest_predicate("p1.sources", h, lambda: [])
    assert bad() is False


def test_an_extractor_that_raises_is_a_failed_harvest_not_a_crash():
    h = HarvestHistory()

    def boom():
        raise RuntimeError("panel gone")

    assert harvest.harvest_predicate("p", h, boom)() is False


def test_an_extractor_returning_none_is_treated_as_empty():
    h = HarvestHistory()
    assert harvest.harvest_predicate("p", h, lambda: None)() is False
