"""Numeric provenance validator.

Extracts every number from a block of prose and checks each one against
the values the pipeline actually produced. Anything that does not trace
is reported with its position and the sentence it appeared in.

Tolerance is derived from how the number was WRITTEN, not from a fixed
epsilon. A figure printed as "0.89" could legitimately have come from any
stored value within +/- 0.005, so that is the window it is checked
against; a figure printed as "0.8874" gets a window of +/- 0.00005. A
narrative may therefore round for readability but cannot invent
precision: writing "0.8874" when the pipeline holds 0.887 fabricates the
fourth digit and is caught.

TWO HOLES AN ADVERSARIAL PASS FOUND IN THE FIRST VERSION.

Exponent notation walked straight through. "The sampler drew 1e5
posterior samples" decomposed into the digits 1 and 5, both of which
happened to exist in the result, so a fabricated magnitude of 100,000
passed a gate whose entire purpose is that a model may never originate a
number. Same for "1.2e4", "3x10^6", and "2^10". Magnitude notation is now
rejected outright: if the pipeline computed a large number, the narrative
can quote it.

Hyphens manufactured phantom negatives. With no left boundary on the
optional minus sign, "records from 1998-2004 for tail number A-1042"
yielded 1998, -2004 and -1042, and every ISO date and part number in a
sustainment brief failed the check. In this domain the part number IS the
primary key, so that was a live defect and not a curiosity. The number
pattern now refuses to start immediately after a word character, a dot, a
comma, or a hyphen -- so a hyphenated designator is read as one token and
a genuine minus sign, which follows a space, still is.
"""

from __future__ import annotations

import re
from dataclasses import dataclass
from typing import Any, List

from .schema import (REQUIRED_MENTIONS, collect_numbers, derived_allowances,
                     get_path)

# A number may not begin immediately after a word character, a dot, a
# comma, or a hyphen. Matches 1234, 1,234, 12.5, -3, and the digits inside
# $1,200 and 88.7%; refuses the "2004" in "1998-2004" and the "1553" in
# "MIL-STD-1553".
NUMBER_RE = re.compile(r"(?<![\w.,-])-?(?:\d{1,3}(?:,\d{3})+|\d+)(?:\.\d+)?")

# Constructions that assert a magnitude the digits alone do not carry.
MAGNITUDE_RE = re.compile(
    r"\d\s*(?:[eE]\s*[-+]?\d"          # 1e5, 1.2E-4
    r"|\^\s*\d"                        # 2^10
    r"|[x×*]\s*10)",              # 3x10^6, 3 × 10
)


@dataclass
class Violation:
    kind: str
    detail: str
    value: float = None
    context: str = ""


class ProvenanceError(Exception):
    def __init__(self, violations: List[Violation]):
        lines = [f"  [{v.kind}] {v.detail}"
                 + (f"  ...{v.context}..." if v.context else "")
                 for v in violations]
        super().__init__("narrative failed provenance check:\n" + "\n".join(lines))
        self.violations = violations


def _decimals(token: str) -> int:
    return len(token.split(".")[1]) if "." in token else 0


def _tolerance(token: str) -> float:
    return 0.5 * (10 ** -_decimals(token))      # half a unit in the last place


def extract_numbers(text: str):
    for m in NUMBER_RE.finditer(text):
        token = m.group(0)
        yield token, float(token.replace(",", "")), m.start()


def _context(text: str, pos: int) -> str:
    return text[max(0, pos - 45):pos + 45].replace("\n", " ")


def check(text: str, result: Any, extra_allowed=()) -> List[Violation]:
    """Return every provenance violation in `text` against `result`."""
    allowed = collect_numbers(result)
    allowed |= derived_allowances(allowed)
    allowed |= {float(x) for x in extra_allowed}

    violations: List[Violation] = []
    low = text.lower()

    for m in MAGNITUDE_RE.finditer(text):
        violations.append(Violation(
            kind="magnitude_notation",
            detail=f"'{m.group(0).strip()}' asserts a magnitude the digits do "
                   f"not carry; quote the computed value instead",
            context=_context(text, m.start()),
        ))

    for token, value, pos in extract_numbers(text):
        tol = _tolerance(token)
        if not any(abs(value - a) <= tol for a in allowed):
            violations.append(Violation(
                kind="unsourced_number",
                detail=f"'{token}' does not trace to any field in the result",
                value=value,
                context=_context(text, pos),
            ))

    if isinstance(result, dict):
        for name, rule in REQUIRED_MENTIONS.items():
            value = get_path(result, rule["path"])
            if not rule["when"](value):
                continue

            if rule.get("require_phrase"):
                # A specific phrase, because a bare token is satisfied by a
                # denial: "this run is not degraded" contains "degraded".
                if rule["require_phrase"] not in low:
                    violations.append(Violation(
                        kind="omitted_warning",
                        detail=f"result is flagged '{name}' and the narrative "
                               f"never says \"{rule['require_phrase']}\" "
                               f"({rule['why']})",
                    ))
            elif rule.get("require_value"):
                tolerated = any(
                    abs(v - float(value)) <= _tolerance(tok)
                    for tok, v, _ in extract_numbers(text)
                )
                if not tolerated:
                    violations.append(Violation(
                        kind="omitted_warning",
                        detail=f"result carries {name} = {value} and the "
                               f"narrative never states it ({rule['why']})",
                    ))

    return violations


def enforce(text: str, result: Any, extra_allowed=()) -> str:
    """Return the text, or refuse.

    Deliberately returns the text rather than a boolean, so the natural
    way to use it is to wrap the narrative on its way out. Making the
    check easy to skip is the same as not having it.
    """
    violations = check(text, result, extra_allowed)
    if violations:
        raise ProvenanceError(violations)
    return text


def numbers_in_strings(*strings) -> set:
    """Numbers quoted verbatim from strings the pipeline itself produced.

    A degradation reason such as "solver returned HTTP 503" is an
    operational string, not a claim about the analysis, and the narrative
    interpolates it verbatim. Without this the one line that must always
    print -- the degradation banner -- is the only line whose text is
    unconstrained, so a reason containing a digit turns a degraded run
    into a hard crash instead of a visible degradation.
    """
    out = set()
    for s in strings:
        if isinstance(s, str):
            for _, v, _ in extract_numbers(s):
                out.add(v)
    return out
