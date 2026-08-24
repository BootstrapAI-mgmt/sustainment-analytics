"""The contract between the numeric pipeline and anything that writes prose.

One rule, and everything else follows from it:

    A NUMBER MAY APPEAR IN GENERATED PROSE ONLY IF IT APPEARS IN THE
    STRUCTURED RESULT.

That is deliberately cruder than "the narrative should be accurate".
Accuracy is not machine-checkable; provenance is. Every figure in the
prose either traces to a field a solver produced, or the text does not
ship. It does not matter whether the untraceable figure happens to be
right -- an unverifiable number in a mission-critical brief is a defect
regardless of its value, because nothing downstream can tell it apart
from a wrong one.

REQUIRED_MENTIONS is the mirror image. Omission is the other way a
technically-true narrative misleads: a summary that reports a demand
forecast without saying the run was degraded is not lying about any
number, and is exactly as dangerous as one that is.

TWO THINGS THE FIRST VERSION OF THAT MIRROR CHECK GOT WRONG.

It looked up `result["quarantine_rate_pct"]`, but the field lives at
`result["meta"]["quarantine_rate_pct"]`, so the rule silently never
fired -- a third of the omission check was dead code that reported
success. Paths are now explicit and dotted, and a path that does not
resolve is a configuration error rather than a quiet pass.

It was satisfied by the mere presence of a token, so all of these passed
on a degraded result: "This run is not degraded in any way", "Nothing was
degraded; publish with confidence", "The estimate is undegraded". A
denial contains the word. Boolean facts therefore now require a specific
PHRASE that cannot be negated into existence, and numeric facts require
the VALUE itself to appear.
"""

from __future__ import annotations

from typing import Any


def get_path(obj: Any, path: str, default=None):
    """Resolve a dotted path, returning `default` if any hop is missing."""
    cur = obj
    for part in path.split("."):
        if not isinstance(cur, dict) or part not in cur:
            return default
        cur = cur[part]
    return cur


# Each entry: the fact, when it becomes mandatory, and what the narrative
# must contain for the check to be satisfied.
REQUIRED_MENTIONS = {
    "degraded": {
        "path": "degraded",
        "when": lambda v: bool(v),
        "require_phrase": "this run is degraded",
        "why": "a degraded result must announce itself in words a reader "
               "cannot mistake for a hedge",
    },
    "refused": {
        "path": "refused",
        "when": lambda v: bool(v),
        "require_phrase": "refused to publish",
        "why": "a refusal that is not stated reads as a normal result",
    },
    "quarantine_rate_pct": {
        "path": "meta.quarantine_rate_pct",
        "when": lambda v: isinstance(v, (int, float)) and v > 0,
        "require_value": True,
        "why": "records were dropped from the analysis and the reader is "
               "entitled to know how many",
    },
}


def collect_numbers(obj: Any, out: set = None) -> set:
    """Every numeric leaf anywhere in the result, flattened.

    Booleans are excluded on purpose: in Python True is an instance of
    int, so admitting them would silently license the digits 0 and 1
    anywhere in the prose.
    """
    if out is None:
        out = set()
    if isinstance(obj, bool):
        return out
    if isinstance(obj, (int, float)):
        out.add(float(obj))
        return out
    if isinstance(obj, dict):
        for v in obj.values():
            collect_numbers(v, out)
        return out
    if isinstance(obj, (list, tuple)):
        for v in obj:
            collect_numbers(v, out)
        return out
    return out


def derived_allowances(numbers) -> set:
    """Presentational restatements of values already present.

    A fraction stored as 0.887 will be written as 88.7%. Permitting the
    percent form of a stored fraction is a formatting allowance, not a new
    fact -- the value is still one the pipeline produced.

    Nothing else is granted. There is no allowance for sums, differences,
    or ratios of stored values: those are new claims, and a narrative that
    needs one should be given a field for it rather than permission to
    compute it.
    """
    out = set()
    for n in numbers:
        if 0.0 <= n <= 1.0:
            out.add(round(n * 100, 6))
    return out
