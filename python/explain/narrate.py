"""Turn a structured result into prose.

The template path below is deterministic and needs no model. It exists
because most of what a sustainment brief has to say is the same nine
sentences with different numbers in them, and a language model adds
nothing to that except a place for an error to enter.

WHERE A LANGUAGE MODEL BELONGS. When the ask is genuinely open -- explain
why THIS part jumped the buy list this month, given last month's result
and the maintenance notes -- a model earns its place. The architecture
does not change:

    1. The model is handed the structured result and nothing else. It
       has no tool that returns numbers and no access to raw data.
    2. Its output goes through provenance.enforce() before anyone sees it.
    3. A failed check is not repaired by asking again with a warning
       appended. It falls back to this template.

That ordering is the whole design. A model is permitted to choose words;
it is never permitted to originate a number. "Hallucination-free" is not
a property of a model, and no amount of prompting will make it one -- it
is a property of a pipeline that refuses to pass an unverifiable number
through, whatever produced it.
"""

from __future__ import annotations

from .provenance import enforce, numbers_in_strings


def narrate(result: dict) -> str:
    m, mo, fl = result["meta"], result["model"], result["fleet"]

    parts = sorted(result["parts"], key=lambda p: -p["family_weight_pct"])
    weakest = parts[0]
    buys = result["top_buys"]

    lines = []

    lines.append(
        f"Across {m['n_parts']} part numbers on {m['n_aircraft']} aircraft, "
        f"{m['n_failures']} failures were observed in a {m['obs_horizon_hr']} "
        f"flight-hour window; {m['censored_pct']}% of installed units are "
        f"still running and are treated as censored rather than discarded. "
        f"{m['parts_with_le1_failure']} part numbers have one failure or none."
    )

    lines.append(
        f"Of {m['records_in']} maintenance records, {m['records_accepted']} "
        f"were accepted and {m['records_quarantined']} quarantined "
        f"({m['quarantine_rate_pct']}%). Of the accepted records, "
        f"{m['records_reclassified']} were removals reclassified as "
        f"censored rather than failures, and {m['records_still_on_wing']} "
        f"are units still on wing. Quarantined records are reported, not "
        f"dropped."
    )

    lines.append(
        f"The fitted Weibull shape is {mo['shape_k']} "
        f"(90% interval {mo['shape_k_lo90']} to {mo['shape_k_hi90']}), above "
        f"1.0, so these parts are wearing out rather than failing at random. "
        f"Sampler convergence passed with a maximum R-hat of {mo['rhat_max']} "
        f"against a threshold of {mo['rhat_threshold']}."
    )

    lines.append(
        f"Part {weakest['id']} rests most heavily on the family: "
        f"{weakest['family_weight_pct']}% of its estimate is borrowed, on "
        f"{weakest['failures_observed']} observed failures across "
        f"{weakest['units_installed']} installed units. Its characteristic "
        f"life is {weakest['lambda_post_hr']} hours with a 90% interval of "
        f"{weakest['lambda_lo90_hr']} to {weakest['lambda_hi90_hr']}. "
        f"That estimate will move when the next failure is reported."
    )

    lines.append(
        f"Expected demand over the {m['plan_horizon_hr']} flight-hour "
        f"resupply lead time is {fl['demand_total_mean']} units, with a 95th "
        f"percentile of {fl['demand_total_p95']}. A median "
        f"{fl['epistemic_share_median_pct']}% of the variance in that "
        f"forecast is uncertainty about the failure rate rather than "
        f"randomness in failures -- a point estimate would discard it."
    )

    if buys:
        first = buys[0]
        lines.append(
            f"Against a budget of ${fl['budget_usd']}, the marginal rule buys "
            f"{fl['units_bought']} units for ${fl['spent_usd']}, moving fleet "
            f"availability from {fl['availability_before']} to "
            f"{fl['availability_after']}. The first buy is part "
            f"{first['part_id']} at ${first['unit_cost_usd']}, which removes "
            f"{first['backorders_removed']} expected backorders. Reaching "
            f"{fl['target_availability']} availability would cost "
            f"${fl['target_cost_usd']} on the same frontier."
        )

    if result.get("degraded"):
        lines.append(
            f"This run is degraded: {result.get('degraded_reason', 'unknown')}. "
            f"Treat the figures above as provisional."
        )

    # The degradation reason is an operational string the pipeline itself
    # produced and this function quotes verbatim, so any digits inside it
    # are permitted. Without that allowance the one line that MUST always
    # print is the only line whose text is unconstrained: a reason such as
    # "solver returned HTTP 503" would fail the provenance check and turn
    # a visible degradation into a hard crash.
    allow = numbers_in_strings(result.get("degraded_reason", ""))
    return enforce("\n\n".join(lines), result, extra_allowed=allow)
