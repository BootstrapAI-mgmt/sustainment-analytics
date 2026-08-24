"""Provenance validator: does it catch what it claims to catch?

A validator is worth exactly as much as its worst false negative, so the
tests below are written as attacks. Each one is a way a plausible,
fluent, confident narrative could carry a number nobody computed.
"""

import json
import os
import sys

import pytest

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

from explain.provenance import ProvenanceError, check, enforce  # noqa: E402

# Base fixture: nothing flagged, so a test can exercise one rule at a
# time without every other mandatory-mention rule firing alongside it.
RESULT = {
    "meta": {"n_parts": 12, "n_failures": 30, "censored_pct": 93},
    "model": {"shape_k": 1.7, "rhat_max": 1.026},
    "fleet": {"availability_after": 0.823, "spent_usd": 36440,
              "demand_total_mean": 16.0},
}

# A run that quarantined records, for the mandatory-mention rules.
QUARANTINED = {
    "meta": dict(RESULT["meta"], quarantine_rate_pct=11.3),
    "model": RESULT["model"],
    "fleet": RESULT["fleet"],
}


def test_accepts_a_narrative_built_only_from_result_fields():
    text = ("12 part numbers produced 30 failures; 93% of units are still "
            "running. Availability reached 0.823 after $36,440 of buys.")
    assert enforce(text, RESULT) == text


def test_rejects_an_invented_number():
    text = "12 part numbers produced 30 failures, costing $412,000 last year."
    v = check(text, RESULT)
    assert any(x.kind == "unsourced_number" and x.value == 412000 for x in v)


def test_rejects_a_plausible_number_adjacent_to_a_real_one():
    # The dangerous case: 0.834 is not absurd, sits near the true 0.823,
    # and would survive any review that was not checking arithmetic.
    text = "Availability reached 0.834."
    v = check(text, RESULT)
    assert len(v) == 1 and v[0].value == 0.834


def test_allows_rounding_but_not_invented_precision():
    assert enforce("Availability reached 0.82.", RESULT)
    # 1.026 may be written as 1.03; writing 1.0261 asserts a digit the
    # pipeline never produced.
    with pytest.raises(ProvenanceError):
        enforce("R-hat was 1.0261.", RESULT)


def test_allows_a_stored_fraction_written_as_a_percentage():
    assert enforce("Availability reached 82.3%.", RESULT)


def test_rejects_arithmetic_the_pipeline_did_not_do():
    # 30 failures over 12 parts is 2.5 each. True, derivable, and still
    # refused: a derived figure is a new claim and belongs in a field.
    text = "That is 2.5 failures per part number."
    assert any(x.value == 2.5 for x in check(text, RESULT))


def test_rejects_a_narrative_that_hides_degradation():
    degraded = dict(RESULT, degraded=True,
                    degraded_reason="solver unavailable, used cached fit")
    text = "12 part numbers produced 30 failures. Availability reached 0.823."
    v = check(text, degraded)
    assert any(x.kind == "omitted_warning" for x in v)

    honest = text + " This run is degraded: the solver was unavailable."
    assert not [x for x in check(honest, degraded) if x.kind == "omitted_warning"]


def test_booleans_do_not_license_stray_digits():
    # True is an int in Python. If collect_numbers admitted it, the digit
    # 1 would be permitted anywhere in the prose forever.
    r = {"converged": True, "value": 42}
    assert any(x.value == 1 for x in check("There was 1 failure.", r))


def test_every_number_in_the_real_pipeline_narrative_traces():
    path = os.path.join(os.path.dirname(os.path.dirname(
        os.path.dirname(os.path.abspath(__file__)))), "results",
        "analysis_result.json")
    if not os.path.exists(path):
        pytest.skip("run matlab/demo_pipeline.m first")
    from explain.narrate import narrate
    with open(path) as fh:
        result = json.load(fh)
    text = narrate(result)          # narrate() enforces internally
    assert len(text) > 200


# ---- regressions from an adversarial review -------------------------

def test_exponent_notation_cannot_smuggle_a_magnitude():
    """"1e5" decomposed into the digits 1 and 5, both of which existed in
    the result, so a fabricated 100,000 passed a gate whose whole purpose
    is that a model may never originate a number."""
    for attack in ["The sampler drew 1e5 posterior samples.",
                   "Unit cost is 1.2e4 dollars.",
                   "The fleet flew 3x10^6 hours.",
                   "Backorder risk scales as 2^10 units."]:
        v = check(attack, RESULT)
        assert any(x.kind == "magnitude_notation" for x in v), attack


def test_hyphenated_designators_do_not_manufacture_negatives():
    """In a sustainment brief the part number IS the primary key. With no
    left boundary on the minus sign, "MIL-STD-1553" produced -1553 and any
    ISO date produced two phantom negatives, so truthful prose failed."""
    for text in ["Records from 1998-2004 for tail number A-1042.",
                 "Part MIL-STD-1553 was superseded.",
                 "As of 2026-08-24 the fleet was grounded."]:
        assert not [x.value for x in check(text, RESULT) if x.value and x.value < 0], text


def test_a_denial_does_not_satisfy_the_degradation_warning():
    """A bare token check is satisfied by the word appearing in a denial."""
    degraded = dict(RESULT, degraded=True, degraded_reason="solver unavailable")
    for denial in ["This run is not degraded in any way.",
                   "Nothing was degraded; publish with confidence.",
                   "The estimate is undegraded.",
                   "(Glossary: 'degraded' means a fallback ran.)"]:
        v = check(denial, degraded)
        assert any(x.kind == "omitted_warning" for x in v), denial

    honest = "This run is degraded: the solver was unavailable."
    assert not [x for x in check(honest, degraded) if x.kind == "omitted_warning"]


def test_the_quarantine_rule_is_wired_to_the_right_path():
    """It read result["quarantine_rate_pct"] while the field lives at
    result["meta"]["quarantine_rate_pct"], so a third of the omission
    check was dead code that always reported success."""
    v = check("Twelve part numbers were analysed.", QUARANTINED)
    assert any(x.kind == "omitted_warning" and "quarantine" in x.detail for x in v)

    # And stating the rate satisfies it -- boilerplate about quarantine
    # that names no number does not.
    vague = check("Quarantined records are reported, not dropped.", QUARANTINED)
    assert any(x.kind == "omitted_warning" for x in vague)

    ok = check("Twelve part numbers; 11.3% of records were quarantined.",
               QUARANTINED)
    assert not [x for x in ok if x.kind == "omitted_warning"]


def test_a_degradation_reason_containing_a_digit_does_not_crash_the_run():
    """The one line that must always print was the only line whose text was
    unconstrained, so "solver returned HTTP 503" turned a visible
    degradation into a hard failure."""
    from explain.provenance import numbers_in_strings
    degraded = dict(QUARANTINED, degraded=True,
                    degraded_reason="solver returned HTTP 503")
    text = ("Availability reached 0.823 and 11.3% of records were quarantined. "
            "This run is degraded: solver returned HTTP 503.")
    assert enforce(text, degraded,
                   extra_allowed=numbers_in_strings(degraded["degraded_reason"]))
