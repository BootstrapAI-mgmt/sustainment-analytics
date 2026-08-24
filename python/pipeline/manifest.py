"""Content-addressed stage keys.

A stage's cached result may be reused only when NOTHING that could change
its output has changed. That includes the obvious things -- its name, its
parameters -- and two that are easy to miss.

**Upstream identity.** Stage A is re-run with a new parameter, stage B's
own inputs look unchanged, B's cache is reused, and the pipeline emits a
result assembled from two different versions of the world. It does not
crash and it does not warn. Chaining the upstream key into the downstream
key makes that impossible to express.

**Upstream HEALTH.** A degraded input is a different input. This was
missed in the first version and it was the more dangerous of the two: a
downstream stage cached during a clean run was served, unchanged and
unmarked, into a run whose upstream had fallen back to stale data. The
degradation mark never reached the output, and the published narrative
looked exactly like a healthy one. Upstream entries are therefore hashed
as (key, degraded) pairs.

Order is preserved rather than sorted. Sorting made
`run(..., upstream=[baseline, target])` and `upstream=[target, baseline]`
share a key, so a stage computing `target - baseline` could be served the
negation of its own answer from cache.
"""

from __future__ import annotations

import hashlib
import json
from typing import Any, Iterable


class NotHashable(TypeError):
    """A parameter that cannot be canonically serialised."""


def canonical(obj: Any) -> str:
    """Stable JSON for hashing: sorted keys, no incidental whitespace.

    There is deliberately NO `default=` fallback. An earlier version used
    `default=str`, which meant an unrecognised parameter was hashed by its
    repr -- so `(1, 2)` and `[1, 2]` collided, and two distinct config
    objects collided whenever CPython happened to reuse an address, with
    the second run silently served the first one's result. A parameter
    this function cannot serialise is a parameter it cannot promise to
    distinguish, so it raises instead.
    """
    try:
        return json.dumps(_tag(obj), sort_keys=True, separators=(",", ":"),
                          allow_nan=False)
    except (TypeError, ValueError) as exc:
        raise NotHashable(
            f"cannot canonicalise {type(obj).__name__} for a stage key: {exc}. "
            f"Stage parameters must be JSON-native so that distinct values "
            f"are guaranteed to produce distinct keys."
        ) from exc


def _tag(obj: Any) -> Any:
    """Make container types visible to the hash.

    JSON renders a tuple and a list identically. Tagging keeps
    `{"h": (1, 2)}` and `{"h": [1, 2]}` apart, which they are.
    """
    if isinstance(obj, tuple):
        return {"__tuple__": [_tag(v) for v in obj]}
    if isinstance(obj, list):
        return [_tag(v) for v in obj]
    if isinstance(obj, dict):
        return {str(k): _tag(v) for k, v in obj.items()}
    return obj


def digest(*parts: Any) -> str:
    h = hashlib.sha256()
    for p in parts:
        h.update(canonical(p).encode("utf-8"))
        h.update(b"\x00")           # domain separator: ["a","b"] != ["ab"]
    return h.hexdigest()[:16]


def stage_key(name: str, code_version: str, params: dict,
              upstream: Iterable) -> str:
    """Identity of one stage invocation.

    `upstream` is an ordered iterable of (key, degraded) pairs.

    code_version is explicit rather than derived from the source file.
    Hashing the source would invalidate every cache on a comment change,
    and teams respond to that by disabling the cache -- which removes the
    protection entirely. An explicit version is a decision someone makes
    and can be reviewed in a diff.
    """
    ups = [[str(k), bool(d)] for k, d in upstream]
    return digest(name, code_version, params, ups)
